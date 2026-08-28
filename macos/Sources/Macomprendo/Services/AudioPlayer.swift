import AVFoundation
import Foundation

/// Plays one buffer of encoded audio at a time and reports when it is done.
@MainActor protocol AudioPlaying: AnyObject {
    /// Called on the main actor when the current buffer finishes on its own. It is not called
    /// for `stop()`.
    var onFinished: (@MainActor () -> Void)? { get set }
    /// Replaces whatever is playing. `AVAudioPlayer` sniffs the container, so WAV, MP3 and the
    /// other formats an OpenAI-compatible server may return all work. Throws
    /// `MacomprendoError.audioPlayback` when the bytes cannot be decoded or the output device
    /// refuses to start.
    func play(_ audioData: Data) throws
    func stop()
    var isPaused: Bool { get }
    /// No-op when nothing is playing. Keeps the playhead so `resume()` continues.
    func pause()
    func resume()
}

/// Thin `AVAudioPlayer` wrapper. Hardware-bound glue with no logic of its own, so it carries no
/// unit test and is covered by `docs/SMOKE_TEST.md` instead (invariant 3).
@MainActor final class AVAudioPlayerPlayer: NSObject, AudioPlaying {
    var onFinished: (@MainActor () -> Void)?
    private(set) var isPaused = false

    private var player: AVAudioPlayer?

    func play(_ audioData: Data) throws {
        stop()
        isPaused = false
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            self.player = player
            guard player.play() else {
                throw MacomprendoError.audioPlayback("the output device refused to start")
            }
        } catch let error as MacomprendoError {
            throw error
        } catch {
            throw MacomprendoError.audioPlayback(error.localizedDescription)
        }
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        isPaused = false
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    func resume() {
        guard let player, isPaused else { return }
        player.play()
        isPaused = false
    }
}

extension AVAudioPlayerPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player = nil
            self.onFinished?()
        }
    }
}
