import Foundation
import Testing
@testable import Macomprendo

private final class GatedModelManager: ModelManaging, @unchecked Sendable {
    let modelsDirectory = URL(fileURLWithPath: "/tmp/macomprendo-models", isDirectory: true)
    let gate = AsyncGate()
    private let succeeds: Bool

    init(succeeds: Bool) { self.succeeds = succeeds }

    func state(of id: String) async -> ModelState { .downloaded }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        await gate.wait()
        guard succeeds else { return nil }
        return ResolvedLocalModel(engine: .whisperCpp,
                                  files: [.ggml: URL(fileURLWithPath: "/models/\(id).bin")])
    }

    func download(_ id: String) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func delete(_ id: String) async throws {}
}

@Suite @MainActor struct StaleTranscriptionCacheTests {
    private func configuration(_ id: String) -> LocalTranscriptionProviderCache.Configuration {
        .init(source: .local(modelID: id), whisper: WhisperOptions())
    }

    private func waitForGate(_ gate: AsyncGate) async {
        for _ in 0..<1_000 {
            if gate.waiterCount == 1 { return }
            await Task.yield()
        }
    }

    @Test func staleSuccessfulLookupDoesNotReplaceCurrentEntry() async {
        let manager = GatedModelManager(succeeds: true)
        let cache = LocalTranscriptionProviderCache()
        let env = AppEnvironment.fake(models: manager, localTranscriptionCache: cache)
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(), env: env)
        model.settings.localModelIdleTimeout = .never
        model.settings.transcriptionSource = .local(modelID: "old")
        let stale = Task { try? await model.transcriberProvider() }
        await waitForGate(manager.gate)
        model.settings.transcriptionSource = .local(modelID: "current")
        _ = cache.provider(FakeTranscriptionProvider(),
                           configuration: configuration("current"))
        manager.gate.open()
        _ = await stale.value
        #expect(cache.cachedConfiguration == configuration("current"))
    }

    @Test func staleFailedLookupDoesNotClearCurrentEntry() async {
        let manager = GatedModelManager(succeeds: false)
        let currentConfiguration = configuration("current")
        let cache = LocalTranscriptionProviderCache()
        let env = AppEnvironment.fake(models: manager, localTranscriptionCache: cache)
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(), env: env)
        model.settings.localModelIdleTimeout = .never
        model.settings.transcriptionSource = .local(modelID: "old")
        let stale = Task { try? await model.transcriberProvider() }
        await waitForGate(manager.gate)
        model.settings.transcriptionSource = .local(modelID: "current")
        _ = cache.provider(FakeTranscriptionProvider(),
                           configuration: currentConfiguration)
        manager.gate.open()
        _ = await stale.value
        #expect(cache.cachedConfiguration == currentConfiguration)
    }
}
