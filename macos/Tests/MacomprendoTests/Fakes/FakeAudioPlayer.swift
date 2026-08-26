import Foundation
@testable import Macomprendo

@MainActor final class FakeAudioPlayer: AudioPlaying {
    var onFinished: (@MainActor () -> Void)?

    private(set) var played: [Data] = []
    private(set) var stopCount = 0

    /// Thrown by the next `play(_:)` call, then cleared.
    var playError: Error?

    /// `true` (the default) finishes each buffer synchronously, so a whole queue drains in one
    /// `await`. Set to `false` to hold a buffer open and drive it with `finishCurrent()`.
    var finishesImmediately = true

    func play(_ audioData: Data) throws {
        if let error = playError {
            playError = nil
            throw error
        }
        played.append(audioData)
        if finishesImmediately { onFinished?() }
    }

    func stop() { stopCount += 1 }

    /// Simulates the current buffer reaching its end.
    func finishCurrent() { onFinished?() }
}
