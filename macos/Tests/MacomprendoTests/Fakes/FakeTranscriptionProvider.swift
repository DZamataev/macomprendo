import Foundation
@testable import Macomprendo

final class FakeTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    struct Call: Equatable {
        var pcm: [Float]
        var sampleRate: Int
        var language: String?
    }

    private let lock = NSLock()
    private var _result: Result<String, Error> = .success("hello")
    private var _delay: Duration = .zero
    private var _gate: AsyncGate?
    private var _received: [Call] = []

    var result: Result<String, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    /// Sleep before returning, so tests can cancel an in-flight transcription.
    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    var received: [Call] { lock.withLock { _received } }

    var gate: AsyncGate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        lock.withLock { _received.append(Call(pcm: pcm, sampleRate: sampleRate, language: language)) }
        if let gate { await gate.wait() }
        let delay = self.delay
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
