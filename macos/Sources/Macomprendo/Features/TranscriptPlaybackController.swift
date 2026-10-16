import Foundation

/// Drives audio playback for the transcript the Transcripts window has open: resolves what the
/// transcript plays (its source file, or the tracks of its call recording), keeps the player
/// bar's state, and maps the player's callbacks back into it.
///
/// One load runs at a time. Every fresh load and every `stop()` bumps a generation, and a load
/// that finishes after a newer one started drops its result instead of overwriting it. Transcript
/// text and file paths are never logged.
@MainActor
final class TranscriptPlaybackController: ObservableObject {
    /// What the unavailable strip offers beside the reason.
    enum Recovery: Equatable {
        case chooseFile
        case chooseFolder
    }

    enum State: Equatable {
        case idle
        case loading
        case unavailable(reason: String, recovery: Recovery?)
        case ready(position: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    }

    static let rates: [Float] = [1, 1.25, 1.5, 2]
    static let skipInterval: TimeInterval = 15

    @Published private(set) var state: State = .idle
    @Published private(set) var rate: Float = 1
    @Published private(set) var muted: Set<TranscriptSpeaker> = []
    @Published private(set) var availableSpeakers: Set<TranscriptSpeaker> = []
    @Published private(set) var activeSegmentIndex: Int?
    @Published var isFollowing = true
    /// A mid-playback failure, shown until the next `play()`.
    @Published private(set) var failure: String?

    private(set) var transcriptID: Int64?

    private let player: any TranscriptAudioPlaying
    private let bookmarks: any FileBookmarking
    private let folders: any CallRecordingFolderManaging
    private let store: any TranscriptStoring

    /// The transcript `open` last took on: `playSegment` reads its segments, and `relink`
    /// reopens it with the new bookmark.
    private var transcript: Transcript?
    private var timeline = PlaybackTimeline(segments: [])
    /// Bumped by every fresh load and by `stop()`; a load that finishes after a newer one
    /// started drops its result.
    private var generation = 0
    /// Set by the first `play` or `seek`: before that, positions move the bar but mark no
    /// segment.
    private var hasStarted = false

    init(player: any TranscriptAudioPlaying, bookmarks: any FileBookmarking,
         folders: any CallRecordingFolderManaging, store: any TranscriptStoring) {
        self.player = player
        self.bookmarks = bookmarks
        self.folders = folders
        self.store = store
        player.onPosition = { [weak self] position in self?.positionMoved(to: position) }
        player.onEnded = { [weak self] in self?.reachedTheEnd() }
        player.onFailed = { [weak self] error in self?.failed(with: error) }
    }

    /// Opens `transcript`, or clears everything with `nil`. A transcript that is already open
    /// (the same id, loaded or loading) only has its timeline refreshed — a running job appends
    /// segments and the view re-opens the transcript as they land; anything else is a fresh
    /// load, which stops whatever was playing.
    func open(_ transcript: Transcript?) async {
        guard let transcript else {
            stop()
            return
        }
        if transcript.id == transcriptID, isOpenOrLoading {
            self.transcript = transcript
            timeline = PlaybackTimeline(segments: transcript.segments)
            return
        }
        await start(transcript)
    }

    /// Starts, or continues, playback. At the end, the next `play` starts over from 0.
    func play() {
        guard case .ready(let position, let duration, _) = state else { return }
        failure = nil
        if position >= duration - 0.05 {
            // The restart must seek before it plays, and `seek` is async; the task's seek and
            // play run back to back, so no callback can slip in between them.
            Task { [weak self] in
                guard let self else { return }
                await self.seek(to: 0)
                self.startPlaying()
            }
        } else {
            startPlaying()
        }
    }

    func pause() {
        guard case .ready(let position, let duration, _) = state else { return }
        player.pause()
        state = .ready(position: position, duration: duration, isPlaying: false)
    }

    func togglePlayPause() {
        guard case .ready(_, _, let isPlaying) = state else { return }
        if isPlaying { pause() } else { play() }
    }

    /// Moves the playhead by `seconds`, clamped to the recording.
    func skip(by seconds: TimeInterval) async {
        guard case .ready(let position, _, _) = state else { return }
        await seek(to: position + seconds)
    }

    /// Moves the playhead to `position`, clamped to `0…duration`. Seeking is deliberate, so it
    /// turns follow on; the position itself arrives back through `onPosition`.
    func seek(to position: TimeInterval) async {
        guard case .ready(_, let duration, _) = state else { return }
        hasStarted = true
        isFollowing = true
        await player.seek(to: min(max(position, 0), duration))
    }

    /// Plays from a segment's start — the timestamp button's action.
    func playSegment(at index: Int) async {
        guard let transcript, transcript.segments.indices.contains(index) else { return }
        await seek(to: transcript.segments[index].start)
        play()
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.setRate(rate)
    }

    /// Silences or unsilences one side of a call. A side whose track is not loaded cannot be
    /// toggled.
    func toggleMuted(_ speaker: TranscriptSpeaker) {
        guard availableSpeakers.contains(speaker) else { return }
        if muted.contains(speaker) {
            muted.remove(speaker)
        } else {
            muted.insert(speaker)
        }
        player.setMuted(muted)
    }

    func stop() {
        generation += 1
        player.unload()
        state = .idle
        transcriptID = nil
        transcript = nil
        activeSegmentIndex = nil
        availableSpeakers = []
    }

    /// Replaces the open transcript's source with `url`: the new bookmark is stored on the row —
    /// so the next launch finds the source again — and playback reloads from it. It does not
    /// start transcription.
    func relink(to url: URL) async {
        guard let id = transcriptID, let transcript else { return }
        let previousRecovery = currentRecovery
        do {
            let bookmark = try bookmarks.bookmark(for: url)
            try await store.setSourceBookmark(bookmark, for: id)
            // The store write awaited: a newer open may have taken the transcript over meanwhile.
            guard id == transcriptID else { return }
            let reopened = Transcript(header: transcript.header, run: transcript.run,
                                      sourceBookmark: bookmark, summary: transcript.summary,
                                      segments: transcript.segments)
            await start(reopened)
        } catch {
            guard id == transcriptID else { return }
            state = .unavailable(reason: ErrorText.describe(error), recovery: previousRecovery)
        }
    }

    // MARK: - Loading

    /// A fresh load: stops the player, resolves what `transcript` plays and loads it. A result
    /// that a newer `start` or a `stop` superseded is dropped.
    private func start(_ transcript: Transcript) async {
        generation += 1
        let generation = self.generation
        player.unload()
        muted = []
        activeSegmentIndex = nil
        isFollowing = true
        failure = nil
        hasStarted = false
        self.transcript = transcript
        timeline = PlaybackTimeline(segments: transcript.segments)
        transcriptID = transcript.id

        do {
            let source = try resolveSource(for: transcript)
            state = .loading
            let load = try await player.load(source)
            guard generation == self.generation else { return }
            state = .ready(position: 0, duration: load.duration, isPlaying: false)
            availableSpeakers = load.speakers
            player.setRate(rate)
            player.setMuted([])
        } catch let unavailable as SourceUnavailable {
            state = .unavailable(reason: unavailable.reason, recovery: unavailable.recovery)
        } catch {
            guard generation == self.generation else { return }
            state = .unavailable(reason: Self.reason(for: error), recovery: nil)
        }
    }

    /// Why the source cannot be resolved, and what the strip should offer. The reasons are the
    /// exact strings the spec names.
    private struct SourceUnavailable: Error {
        let reason: String
        let recovery: Recovery
    }

    private func resolveSource(for transcript: Transcript) throws -> PlaybackSource {
        switch transcript.header.sourceKind {
        case .file:
            guard let bookmark = transcript.sourceBookmark,
                  let url = try? bookmarks.resolve(bookmark) else {
                throw SourceUnavailable(reason: "the source file cannot be found",
                                        recovery: .chooseFile)
            }
            return .file(url)

        case .call:
            guard let bookmark = transcript.sourceBookmark,
                  let folder = try? bookmarks.resolve(bookmark) else {
                throw SourceUnavailable(reason: "the recording folder cannot be found",
                                        recovery: .chooseFolder)
            }
            guard let manifest = try? CallRecordingManifest.read(from: folder) else {
                throw SourceUnavailable(reason: "recording.json cannot be read",
                                        recovery: .chooseFolder)
            }
            // Me then Others, so the sides read in a stable order. A track without a
            // `startOffset` cannot be placed on the recording's clock, and one whose file is
            // gone would only add silence — both are left out; with none left there is nothing
            // to play.
            let tracks = [TranscriptSpeaker.me, .others].compactMap { speaker -> PlaybackTrack? in
                guard let track = manifest.track(speaker),
                      let offset = track.startOffset else { return nil }
                let url = folder.appendingPathComponent(track.file)
                guard folders.fileExists(url) else { return nil }
                return PlaybackTrack(speaker: speaker, url: url, offset: offset)
            }
            guard !tracks.isEmpty else {
                throw SourceUnavailable(reason: "neither track file is there",
                                        recovery: .chooseFolder)
            }
            return .call(tracks)
        }
    }

    // MARK: - Player callbacks

    private func positionMoved(to position: TimeInterval) {
        guard case .ready(_, let duration, let isPlaying) = state else { return }
        state = .ready(position: position, duration: duration, isPlaying: isPlaying)
        let index = hasStarted ? timeline.activeIndex(at: position) : nil
        if index != activeSegmentIndex { activeSegmentIndex = index }
    }

    private func reachedTheEnd() {
        guard case .ready(_, let duration, _) = state else { return }
        state = .ready(position: duration, duration: duration, isPlaying: false)
    }

    private func failed(with error: MacomprendoError) {
        guard case .ready(let position, let duration, _) = state else { return }
        state = .ready(position: position, duration: duration, isPlaying: false)
        failure = Self.reason(for: error)
    }

    private func startPlaying() {
        guard case .ready(let position, let duration, _) = state else { return }
        hasStarted = true
        player.play()
        state = .ready(position: position, duration: duration, isPlaying: true)
    }

    // MARK: - State helpers

    private var isOpenOrLoading: Bool {
        switch state {
        case .ready, .loading: true
        case .idle, .unavailable: false
        }
    }

    /// The recovery the strip shows now, so a failed `relink` keeps offering it.
    private var currentRecovery: Recovery? {
        guard case .unavailable(_, let recovery) = state else { return nil }
        return recovery
    }

    /// A player failure's reason: the `transcriptPlaybackUnavailable` payload, or the error's
    /// own text.
    private static func reason(for error: Error) -> String {
        if let error = error as? MacomprendoError,
           case .transcriptPlaybackUnavailable(let reason) = error {
            return reason
        }
        return ErrorText.describe(error)
    }
}
