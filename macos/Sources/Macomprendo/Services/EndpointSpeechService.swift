import Foundation

/// OpenAI's built-in voice names, embedded as data — the endpoint exposes no list route and no
/// network call is made to populate the picker. The Speech tab treats these as *suggestions*
/// beside a free-form field, because a local server (openedai-speech, Kokoro-FastAPI, an XTTS
/// wrapper) defines its own names. An unknown name simply returns an HTTP error, surfaced like
/// any other.
enum EndpointVoices {
    static let all: [Voice] = [
        "alloy", "ash", "ballad", "coral", "echo", "fable",
        "nova", "onyx", "sage", "shimmer", "verse"
    ].map { name in
        Voice(id: name, name: name, language: "endpoint", quality: "premium")
    }
}

/// Speaks text through any OpenAI-compatible `/v1/audio/speech` server: one HTTP request per
/// ≤4096-character chunk, played back sequentially with a single chunk of prefetch, so chunk
/// N+1 is already in flight while chunk N plays. The selection text leaves the machine only
/// while this backend is selected (invariant 9) and is never logged (invariant 6).
@MainActor final class EndpointSpeechService: SpeechSynthesizing {
    static let defaultChunkCharacterLimit = SpeechTextChunker.defaultCharacterLimit
    /// Synthesising a few thousand characters is slow; far above the 10 s used for metadata.
    static let requestTimeout: TimeInterval = 60

    private(set) var isSpeaking = false
    private(set) var isPaused = false
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let http: any HTTPClient
    private let keychain: any KeychainStoring
    private let player: any AudioPlaying
    /// Injectable only so tests can force a multi-chunk queue out of a short string.
    private let chunkCharacterLimit: Int
    private var task: Task<Void, Never>?
    /// The unstructured fetch `Task` currently being awaited in `play(chunks:settings:)`.
    /// `task.cancel()` alone does not propagate to it — an unstructured child is only linked
    /// to its parent's cancellation by explicitly cancelling it too, which is what
    /// `cancelCurrent()` does with this property. Without it, `stop()` left a live, billed
    /// network request running to completion (or the 60 s timeout) with its result discarded.
    private var inFlightFetch: Task<Data, Error>?
    private var playback: CheckedContinuation<Void, Error>?
    /// `speak` returns before the first chunk has been synthesised, so a pause can land
    /// while the audio is still in flight. `player.pause()` is a no-op then — there is
    /// nothing playing yet — so `playAndWait` holds the finished chunk back instead of
    /// starting it, or the pause the user asked for would be silently ignored and the
    /// sound would start anyway.
    private var heldAudio: Data?
    /// Bumped by every `speak`/`stop` so a superseded task cannot clobber the new state.
    private var generation = 0

    init(http: any HTTPClient,
         keychain: any KeychainStoring,
         player: any AudioPlaying,
         chunkCharacterLimit: Int = EndpointSpeechService.defaultChunkCharacterLimit) {
        self.http = http
        self.keychain = keychain
        self.player = player
        self.chunkCharacterLimit = chunkCharacterLimit
    }

    func voices() -> [Voice] { EndpointVoices.all }

    func speak(_ text: String, settings: SpeechSettings) {
        cancelCurrent()
        isPaused = false
        generation += 1
        let generation = self.generation

        let chunks = SpeechTextChunker.chunks(of: text, limit: chunkCharacterLimit)
        guard !chunks.isEmpty else {
            // cancelCurrent() above stops any previous playback but doesn't touch isSpeaking;
            // without this, speak()-with-blank-text called while already speaking left the
            // flag (and the HUD it drives) stuck true forever, since no future task would
            // ever call finish().
            setSpeaking(false)
            return
        }

        setSpeaking(true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.play(chunks: chunks, settings: settings)
                self.finish(generation: generation, error: nil)
            } catch {
                self.finish(generation: generation, error: error)
            }
        }
    }

    func stop() {
        generation += 1
        cancelCurrent()
        isPaused = false
        setSpeaking(false)
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        player.pause()
        isPaused = true
        onStateChange?()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let audio = heldAudio {
            heldAudio = nil
            do { try player.play(audio) } catch { resumePlayback(throwing: error) }
        } else {
            player.resume()
        }
        onStateChange?()
    }

    /// Awaits the in-flight speech task. Used by tests.
    func drain() async { _ = await task?.value }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? MacomprendoError) == .cancelled
    }

    // MARK: - Private

    private func cancelCurrent() {
        task?.cancel()
        task = nil
        inFlightFetch?.cancel()
        inFlightFetch = nil
        // The job being cancelled owns any chunk it was holding back for a pause; a superseded
        // `speak()`/`stop()` must not let a stale buffer surface as though it belonged to
        // whatever runs next.
        heldAudio = nil
        resumePlayback(throwing: MacomprendoError.cancelled)
        player.stop()
    }

    private func finish(generation: Int, error: Error?) {
        guard generation == self.generation else { return }   // a newer speak owns the state
        setSpeaking(false)
        guard let error, !Self.isCancellation(error) else { return }
        player.stop()
        onError?(error)
    }

    private func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }

    /// A missing or blank key fails before anything is sent. A local server without auth is
    /// still reachable: save any non-empty placeholder key (documented in Settings ▸ Speech),
    /// which beats an extra "no auth" toggle.
    private func apiKey(_ settings: SpeechSettings) throws -> String {
        guard let account = settings.endpointAPIKeyRef,
              let key = try? keychain.get(account: account),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MacomprendoError.speechKeyMissing }
        return key
    }

    private func play(chunks: [String], settings: SpeechSettings) async throws {
        let key = try apiKey(settings)
        var next: Task<Data, Error>? = fetch(chunks[0], key: key, settings: settings)
        defer { next?.cancel() }                              // never orphan a prefetch

        for index in chunks.indices {
            guard let current = next else { break }
            // Tracked so `cancelCurrent()` can cancel the request actually in flight, not just
            // the prefetch below — an unstructured `Task` is not cancelled by its creator's
            // cancellation alone.
            inFlightFetch = current
            next = index + 1 < chunks.count
                ? fetch(chunks[index + 1], key: key, settings: settings)
                : nil
            let audio: Data
            do {
                audio = try await current.value
            } catch {
                // Only clear tracking that still belongs to *this* fetch: a superseded task's
                // cancelled unwind can resume after the new generation has already recorded
                // its own in-flight fetch here (the old task's resumption waits on the fake or
                // real transport's cancellation propagation, which is not instantaneous), and
                // an unconditional nil-out would wipe the new generation's tracking so a later
                // `stop()` silently fails to cancel the request actually in flight.
                if inFlightFetch == current { inFlightFetch = nil }
                throw error
            }
            if inFlightFetch == current { inFlightFetch = nil }
            try Task.checkCancellation()
            try await playAndWait(audio)
        }
    }

    private func fetch(_ chunk: String, key: String, settings: SpeechSettings) -> Task<Data, Error> {
        let http = self.http
        return Task {
            let request = try SpeechRequestBuilder.request(baseURL: settings.endpointBaseURL,
                                                           apiKey: key,
                                                           model: settings.endpointModel,
                                                           voice: settings.endpointVoice,
                                                           input: chunk,
                                                           instructions: settings.endpointInstructions,
                                                           timeout: Self.requestTimeout)
            do {
                let response = try await http.send(request)
                return try SpeechRequestBuilder.audio(from: response)
            } catch let error as MacomprendoError {
                throw SpeechRequestBuilder.mapped(error, baseURL: settings.endpointBaseURL)
            }
        }
    }

    private func playAndWait(_ audio: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playback = continuation
                player.onFinished = { [weak self] in self?.resumePlayback(throwing: nil) }
                // Paused before this chunk finished fetching: hold it rather than starting it.
                // `resume()` plays it from here; the continuation stays pending until then.
                guard !isPaused else { heldAudio = audio; return }
                do { try player.play(audio) } catch { resumePlayback(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.player.stop()
                self?.resumePlayback(throwing: CancellationError())
            }
        }
    }

    private func resumePlayback(throwing error: Error?) {
        guard let continuation = playback else { return }
        playback = nil
        player.onFinished = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
