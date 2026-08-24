import Foundation
@testable import Macomprendo

final class StubLLMProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _endpoint = Endpoint.ollamaLocal()
    private var _models: Result<[String], Error> = .success([])

    var endpoint: Endpoint {
        get { lock.withLock { _endpoint } }
        set { lock.withLock { _endpoint = newValue } }
    }

    var models: Result<[String], Error> {
        get { lock.withLock { _models } }
        set { lock.withLock { _models = newValue } }
    }

    func listModels() async throws -> [String] {
        try models.get()
    }

    func chat(_ messages: [ChatMessage],
              model: String,
              options: ChatOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
