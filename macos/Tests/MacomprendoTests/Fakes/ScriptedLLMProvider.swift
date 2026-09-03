import Foundation
@testable import Macomprendo

struct ChatCall: Equatable {
    var messages: [ChatMessage]
    var model: String
}

/// Thread-safe recorder shared by the value-type provider and the test.
final class LLMCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatCall] = []

    var calls: [ChatCall] { lock.withLock { recorded } }

    func record(_ call: ChatCall) { lock.withLock { recorded.append(call) } }
}

/// Yields `deltas` in order, then finishes — or throws `failure` after the deltas.
struct ScriptedLLMProvider: LLMProvider {
    var endpoint: Endpoint = .ollamaLocal()
    var deltas: [String] = []
    var failure: MacomprendoError?
    /// Pause before each delta, so a test can cancel mid-stream.
    var delayPerDelta: Duration = .zero
    /// When set together with `pauseAfterDeltaCount`, the stream suspends at `gate` right
    /// after yielding that many deltas — until the test calls `gate.open()`. This lets a test
    /// cancel deterministically between two specific deltas instead of racing a fixed sleep
    /// against `delayPerDelta` (flaky under load).
    var gate: AsyncGate?
    var pauseAfterDeltaCount: Int = 0
    var recorder = LLMCallRecorder()

    func listModels() async throws -> [String] { ["scripted-model"] }

    func chat(_ messages: [ChatMessage], model: String,
              options: ChatOptions) -> AsyncThrowingStream<String, Error> {
        recorder.record(ChatCall(messages: messages, model: model))
        let deltas = self.deltas
        let failure = self.failure
        let delay = self.delayPerDelta
        let gate = self.gate
        let pauseAfter = self.pauseAfterDeltaCount
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, delta) in deltas.enumerated() {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(delta)
                    if let gate, index + 1 == pauseAfter {
                        await gate.wait()
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    }
                }
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
