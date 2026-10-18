import Foundation

/// The two sides' most recent meter values, 0…1, for the menu's level rows.
struct CallLevels: Equatable, Sendable {
    var me: Float = 0
    var others: Float = 0
}

/// One call recording, start to finish: the microphone and system-audio captures feeding the
/// two track writers through one session clock, the `recording.json` a later launch recovers
/// from, and the transcript row the transcription job takes over.
///
/// Capture handlers run on an audio thread and do exactly two things — store a level in a
/// lock-guarded box and enqueue the samples in the writer's own queue. Everything else happens
/// on the main actor: a ticker copies the box into `levels` and `elapsed`, and one in-flight
/// task runs the start and stop flows. `CallAudioCapturing.start(_:)`'s rule that the handler
/// must never call back into the capture holds by construction: the handler captures nothing
/// but the writer and the box, never this controller.
@MainActor
final class CallRecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var levels = CallLevels()
    @Published private(set) var elapsed: TimeInterval = 0

    /// Everything between a start attempt and the end of its finalisation — what the menu shows
    /// as recording and what a toggle ends.
    var isRecording: Bool {
        switch state {
        case .starting, .recording, .stopping: true
        case .idle, .failed: false
        }
    }

    private let microphone: any CallMicrophoneCapturing
    private let systemAudio: any CallAudioCapturing
    private let folders: any CallRecordingFolderManaging
    private let makeWriter: CallTrackWriterFactory
    private let permissions: any PermissionsChecking
    private let store: any TranscriptStoring
    private let bookmarks: any FileBookmarking
    private let settings: @MainActor () -> Settings
    private let clock: @Sendable () -> TimeInterval
    private let now: () -> Date
    private let tick: Duration
    private let transcribe: @MainActor (Int64) -> Void
    private let transcriptsChanged: @MainActor () -> Void

    private var activeTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var folder: URL?
    private var manifest: CallRecordingManifest?
    private var meWriter: (any CallTrackWriting)?
    private var othersWriter: (any CallTrackWriting)?
    private var startedAt: Date?
    /// The running session's levels; replaced at every start so a chunk from a stopped capture
    /// cannot reach the next recording's meter.
    private var levelBox = CallLevelBox()
    /// A stop asked for while `.starting`. The start flow runs it as soon as capture is up, so
    /// a stop is never lost.
    private var pendingStop = false
    /// `pendingStop` is a stop for app termination: the row is left `incomplete` and no job starts.
    private var pendingQuit = false
    /// The first thing that went wrong. A writer failure or a failed `finish()` still stops and
    /// transcribes exactly as a user stop does — but ends as `failed(remembered)`.
    private var rememberedError: MacomprendoError?

    init(microphone: any CallMicrophoneCapturing,
         systemAudio: any CallAudioCapturing,
         folders: any CallRecordingFolderManaging,
         makeWriter: @escaping CallTrackWriterFactory,
         permissions: any PermissionsChecking,
         store: any TranscriptStoring,
         bookmarks: any FileBookmarking,
         settings: @escaping @MainActor () -> Settings,
         clock: @escaping @Sendable () -> TimeInterval = HostClock.now,
         now: @escaping () -> Date = Date.init,
         tick: Duration = .milliseconds(100),
         transcribe: @escaping @MainActor (Int64) -> Void,
         transcriptsChanged: @escaping @MainActor () -> Void = {}) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.folders = folders
        self.makeWriter = makeWriter
        self.permissions = permissions
        self.store = store
        self.bookmarks = bookmarks
        self.settings = settings
        self.clock = clock
        self.now = now
        self.tick = tick
        self.transcribe = transcribe
        self.transcriptsChanged = transcriptsChanged
    }

    // MARK: - Commands

    /// A press of the Record Call / Stop Recording hotkey: the same toggle the menu item
    /// runs. The key-up and every other action are not this controller's.
    func handle(_ event: HotkeyEvent) {
        guard event == .keyDown(.recordCall) else { return }
        toggle()
    }

    /// A press of the Record Call / Stop Recording item: starts when idle or failed, stops
    /// while starting or recording. A press while already stopping is a stop in progress.
    func toggle() {
        switch state {
        case .idle, .failed:
            beginStart()
        case .starting, .recording:
            requestStop(quit: false)
        case .stopping:
            break
        }
    }

    /// Stops and waits for the finalised recording and the job it starts.
    func stop() async {
        requestStop(quit: false)
        await drain()
    }

    /// System sleep stops the recording exactly as Stop does.
    func systemWillSleep() async {
        await stop()
    }

    /// The reason a call waits untranscribed when transcription after Stop is switched off.
    static let notTranscribedYetReason = "Not transcribed yet — press Resume to transcribe it."

    /// The app is quitting: finalise, create the row `incomplete` with
    /// `TranscriptLibraryController.abandonedJobReason`, start no job. Does nothing when no
    /// recording is under way.
    func shutdown() async {
        guard isRecording else { return }
        requestStop(quit: true)
        await drain()
    }

    /// Awaits the in-flight task. Used by tests.
    func drain() async {
        _ = await activeTask?.value
    }

    // MARK: - Starting

    private func beginStart() {
        activeTask?.cancel()
        pendingStop = false
        pendingQuit = false
        rememberedError = nil
        levels = CallLevels()
        elapsed = 0
        state = .starting
        activeTask = Task { [weak self] in await self?.runStart() }
    }

    private func runStart() async {
        guard await permissions.ensureGranted(.microphone) else {
            fail(MacomprendoError.permissionDenied(.microphone))
            return
        }
        let startedAt = now()
        let directory = CallRecordingLayout.directory(for: settings())
        let folder: URL
        do {
            folder = try folders.create(in: directory, startedAt: startedAt)
        } catch {
            fail(error)
            return
        }

        let sessionStart = clock()
        let box = CallLevelBox()
        do {
            let manifest = CallRecordingManifest(startedAt: startedAt,
                                                 folderName: folder.lastPathComponent)
            try manifest.write(to: folder)
            self.manifest = manifest
            // Each writer is kept as soon as it exists: if the second factory call throws,
            // `abortStart` must still finish the first, which has already started writing.
            let meWriter = try makeWriter(Self.trackURL(folder, .me), sessionStart,
                                          failureHandler())
            self.meWriter = meWriter
            let othersWriter = try makeWriter(Self.trackURL(folder, .others), sessionStart,
                                              failureHandler())
            self.othersWriter = othersWriter
            levelBox = box
            try microphone.start(handler(writer: meWriter, speaker: .me, box: box))
            try systemAudio.start(handler(writer: othersWriter, speaker: .others, box: box))
        } catch {
            await abortStart(error, folder: folder)
            return
        }

        self.folder = folder
        self.startedAt = startedAt
        state = .recording(startedAt: startedAt)
        startTicker()
        if pendingStop {
            await runStop()
        }
    }

    /// A start that fails after the folder exists: close the writers, take the folder away
    /// again, and report. Nothing has been recorded, so no transcript is created.
    private func abortStart(_ error: Error, folder: URL) async {
        microphone.stop()
        systemAudio.stop()
        try? await meWriter?.finish()
        try? await othersWriter?.finish()
        folders.remove(folder)
        fail(error)
    }

    // MARK: - Stopping

    private func requestStop(quit: Bool) {
        switch state {
        case .starting:
            if quit { pendingQuit = true }
            pendingStop = true
        case .recording:
            if quit { pendingQuit = true }
            beginStop()
        case .stopping:
            // A quit that lands on a stop already in flight still has to reach its row:
            // `runStop` reads the flag at the store decision, not when it starts.
            if quit { pendingQuit = true }
        case .idle, .failed:
            break
        }
    }

    private func beginStop() {
        state = .stopping
        activeTask = Task { [weak self] in await self?.runStop() }
    }

    private func runStop() async {
        pendingStop = false
        state = .stopping
        tickerTask?.cancel()
        tickerTask = nil
        guard let folder = self.folder, let meWriter, let othersWriter,
              let startedAt = self.startedAt else {
            endStop()
            return
        }
        let duration = now().timeIntervalSince(startedAt)
        elapsed = duration
        microphone.stop()
        systemAudio.stop()
        do { try await meWriter.finish() } catch { remember(error) }
        do { try await othersWriter.finish() } catch { remember(error) }

        var manifest = self.manifest
            ?? CallRecordingManifest(startedAt: startedAt, folderName: folder.lastPathComponent)
        if let offset = meWriter.startOffset {
            manifest.setStartOffset(offset, for: .me)
        }
        if let offset = othersWriter.startOffset {
            manifest.setStartOffset(offset, for: .others)
        }

        // The row comes first, the `.finished` manifest second. The other order loses a call: a
        // `create` that fails, or a crash in this window, would leave the folder finished with no
        // transcript pointing at it, and nothing ever sweeps for those.
        let id: Int64
        do {
            id = try await store.create(
                sourceKind: .call,
                title: CallRecordingLayout.transcriptTitle(startedAt: startedAt),
                sourceBookmark: try? bookmarks.bookmark(for: folder),
                duration: duration,
                run: TranscriptionRun.from(settings().transcriptionSource,
                                           language: settings().transcriptionLanguage),
                at: now())
        } catch {
            // The manifest is still `recording` on disk, so launch recovery picks the recording
            // up: the row is what is missing, not the audio.
            endStop(error)
            return
        }

        manifest.status = .finished
        do {
            try manifest.write(to: folder)
        } catch {
            // The row exists; the folder stays `recording` and launch recovery finalises it.
            remember(error)
        }

        // Read at the decision, not when the stop began: a `shutdown()` that landed on
        // this stop while it was in flight must still leave the row incomplete.
        let quit = pendingQuit
        pendingQuit = false
        if quit {
            do {
                try await store.setStatus(.incomplete,
                                          reason: TranscriptLibraryController.abandonedJobReason,
                                          for: id)
            } catch {
                // The row is there; the next launch's abandoned-job pass repairs its status.
                remember(error)
            }
        } else if settings().transcribeCallsAfterRecording {
            transcribe(id)
        } else {
            do {
                try await store.setStatus(.incomplete, reason: Self.notTranscribedYetReason,
                                          for: id)
            } catch {
                remember(error)
            }
        }
        transcriptsChanged()
        endStop()
    }

    private func remember(_ error: Error) {
        guard rememberedError == nil else { return }
        rememberedError = (error as? MacomprendoError)
            ?? .callRecordingWriteFailed(error.localizedDescription)
    }

    /// Ends a session: the first remembered failure becomes `failed`, otherwise `idle`, and
    /// everything the session held is dropped.
    private func endStop(_ fallback: Error? = nil) {
        let message = rememberedError.map(ErrorText.describe)
            ?? fallback.map(ErrorText.describe)
        rememberedError = nil
        resetSession()
        if let message {
            state = .failed(message)
        } else {
            state = .idle
        }
    }

    /// A failure that never reached a session: the permission check, the folder, an aborted
    /// start. The recording never was, so there is nothing to keep.
    private func fail(_ error: Error) {
        let message = rememberedError.map(ErrorText.describe) ?? ErrorText.describe(error)
        rememberedError = nil
        resetSession()
        state = .failed(message)
    }

    private func resetSession() {
        tickerTask?.cancel()
        tickerTask = nil
        levelBox = CallLevelBox()
        meWriter = nil
        othersWriter = nil
        folder = nil
        manifest = nil
        startedAt = nil
        levels = CallLevels()
        elapsed = 0
    }

    // MARK: - Capture plumbing

    /// The closure the capture delivers on. Audio thread: the box and the writer's own queue
    /// only — it never touches this controller, which the capture's lock forbids.
    private func handler(writer: any CallTrackWriting, speaker: TranscriptSpeaker,
                         box: CallLevelBox) -> @Sendable (CallAudioChunk) -> Void {
        { chunk in
            box.store(AudioMath.level(fromRMS: AudioMath.rms(chunk.samples)), for: speaker)
            writer.consume(chunk.samples, at: chunk.time)
        }
    }

    private func failureHandler() -> @Sendable (MacomprendoError) -> Void {
        { [weak self] error in
            Task { @MainActor in
                self?.writerFailed(error)
            }
        }
    }

    private func writerFailed(_ error: MacomprendoError) {
        guard isRecording else { return }
        remember(error)
        requestStop(quit: false)
    }

    // MARK: - Ticker

    private func startTicker() {
        tickerTask?.cancel()
        let interval = tick
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.onTick()
            }
        }
    }

    private func onTick() {
        levels = levelBox.snapshot
        guard case let .recording(startedAt) = state else { return }
        elapsed = now().timeIntervalSince(startedAt)
        syncManifestOffsets()
    }

    /// Rewrites the manifest once a track's first sample time becomes known, so a crash — which
    /// no `finished` write ever follows — still tells launch recovery where each track starts.
    /// The rewrite stays `recording`.
    private func syncManifestOffsets() {
        guard let folder = self.folder, var manifest = self.manifest else { return }
        var changed = false
        let writers: [((any CallTrackWriting)?, TranscriptSpeaker)] = [
            (meWriter, .me), (othersWriter, .others)]
        for (writer, speaker) in writers {
            guard let offset = writer?.startOffset,
                  manifest.track(speaker)?.startOffset != offset else { continue }
            manifest.setStartOffset(offset, for: speaker)
            changed = true
        }
        guard changed else { return }
        self.manifest = manifest
        do {
            try manifest.write(to: folder)
        } catch {
            // The folder became unwritable mid-recording; the writers will fail next anyway.
            remember(error)
            beginStop()
        }
    }

    private static func trackURL(_ folder: URL, _ speaker: TranscriptSpeaker) -> URL {
        folder.appendingPathComponent(
            CallRecordingLayout.trackFileName(folderName: folder.lastPathComponent,
                                              track: speaker))
    }
}

/// The published levels cross threads: capture handlers run on an audio thread, the ticker
/// reads on the main actor.
private final class CallLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var me: Float = 0
    private var others: Float = 0

    func store(_ level: Float, for speaker: TranscriptSpeaker) {
        lock.withLock {
            switch speaker {
            case .me: me = level
            case .others: others = level
            }
        }
    }

    var snapshot: CallLevels {
        lock.withLock { CallLevels(me: me, others: others) }
    }
}
