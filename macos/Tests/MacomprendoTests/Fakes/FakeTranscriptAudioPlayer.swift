import Foundation
@testable import Macomprendo

/// Records what the playback controller asks for and lets a test play the player's part:
/// `emitPosition`, `finish`, `fail`. `holdLoads` parks every `load` until `releaseLoad()`, so a
/// test can open a second transcript while the first is still loading.
@MainActor
final class FakeTranscriptAudioPlayer: TranscriptAudioPlaying {
    var onPosition: (@MainActor (TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor (MacomprendoError) -> Void)?

    var loadResult: Result<PlaybackLoad, MacomprendoError> =
        .success(PlaybackLoad(duration: 60, speakers: []))
    var holdLoads = false

    private(set) var loaded: [PlaybackSource] = []
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private(set) var muted: Set<TranscriptSpeaker> = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var unloadCount = 0
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingLoads: Int { pending.count }

    func load(_ source: PlaybackSource) async throws -> PlaybackLoad {
        loaded.append(source)
        isPlaying = false
        if holdLoads {
            await withCheckedContinuation { pending.append($0) }
        }
        return try loadResult.get()
    }

    func releaseLoad() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to position: TimeInterval) async {
        seeks.append(position)
        onPosition?(position)
    }

    func setRate(_ rate: Float) { self.rate = rate }
    func setMuted(_ muted: Set<TranscriptSpeaker>) { self.muted = muted }

    func unload() {
        unloadCount += 1
        isPlaying = false
    }

    func emitPosition(_ position: TimeInterval) { onPosition?(position) }
    func finish() { isPlaying = false; onEnded?() }
    func fail(_ error: MacomprendoError) { isPlaying = false; onFailed?(error) }
}
