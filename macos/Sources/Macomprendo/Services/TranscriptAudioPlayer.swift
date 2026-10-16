import AVFoundation
import Foundation

/// What a successful `load` reports: how long the audio runs and which call sides could be read.
struct PlaybackLoad: Equatable, Sendable {
    let duration: TimeInterval
    /// The call sides that could be read; empty for a file.
    let speakers: Set<TranscriptSpeaker>
}

/// Plays a transcript's audio: its file, or the tracks of its call recording. The playback
/// controller owns the state machine; this only loads, moves the playhead and reports back.
@MainActor protocol TranscriptAudioPlaying: AnyObject {
    /// About every 0.25 s while playing, and once after every seek.
    var onPosition: (@MainActor (TimeInterval) -> Void)? { get set }
    /// The item played to its end.
    var onEnded: (@MainActor () -> Void)? { get set }
    /// Playback failed mid-way (device gone, decode error); the player is paused.
    var onFailed: (@MainActor (MacomprendoError) -> Void)? { get set }
    /// Replaces whatever was loaded, paused at 0. Throws `transcriptPlaybackUnavailable`.
    func load(_ source: PlaybackSource) async throws -> PlaybackLoad
    func play()
    func pause()
    func seek(to position: TimeInterval) async
    /// Applies now if playing, and to every later `play()`.
    func setRate(_ rate: Float)
    func setMuted(_ muted: Set<TranscriptSpeaker>)
    /// Drops the item; nothing plays and no callback fires afterwards.
    func unload()
}

/// `AVPlayer` glue: no logic of its own beyond wiring, so it carries no unit test and is covered
/// by `docs/SMOKE_TEST.md` (invariant 3).
@MainActor
final class AVTranscriptAudioPlayer: TranscriptAudioPlaying {
    var onPosition: (@MainActor (TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor (MacomprendoError) -> Void)?

    private let player = AVPlayer()
    private var asset: PlaybackAsset?
    private var rate: Float = 1
    private var muted: Set<TranscriptSpeaker> = []
    private var timeObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0 else { return }
                self.onPosition?(time.seconds)
            }
        }
    }

    func load(_ source: PlaybackSource) async throws -> PlaybackLoad {
        unload()
        let asset = try await PlaybackComposition.make(source)
        let item = AVPlayerItem(asset: asset.asset)
        // Speech at 1.5× should sound faster, not higher.
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = PlaybackComposition.audioMix(for: asset, muted: muted)
        self.asset = asset
        observe(item)
        player.replaceCurrentItem(with: item)
        return PlaybackLoad(duration: asset.duration, speakers: Set(asset.trackIDs.keys))
    }

    func play() {
        player.defaultRate = rate
        player.play()
    }

    func pause() { player.pause() }

    func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        onPosition?(player.currentTime().seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    func setMuted(_ muted: Set<TranscriptSpeaker>) {
        self.muted = muted
        if let asset { player.currentItem?.audioMix = PlaybackComposition.audioMix(for: asset, muted: muted) }
    }

    func unload() {
        player.pause()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        asset = nil
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onEnded?() } })
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFailure("playback stopped unexpectedly") }
        })
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.reportFailure("the audio cannot be decoded") }
        }
    }

    private func reportFailure(_ reason: String) {
        player.pause()
        onFailed?(.transcriptPlaybackUnavailable(reason))
    }
}
