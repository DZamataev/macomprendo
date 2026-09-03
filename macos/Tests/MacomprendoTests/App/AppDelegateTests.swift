import AppKit
import Testing
@testable import Macomprendo

@Suite @MainActor struct AppDelegateTests {
    @Test func terminationWaitsForTheLocalModelCacheToBeCleared() async {
        let cache = LocalTranscriptionProviderCache()
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(localTranscriptionCache: cache)
        )
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never
        _ = cache.provider(
            FakeTranscriptionProvider(),
            configuration: .init(source: .local(modelID: "base"), whisper: WhisperOptions())
        )
        let replied = Box(false)
        let cacheWasEmptyAtReply = Box(false)
        let delegate = AppDelegate(model: model, replyToTermination: {
            cacheWasEmptyAtReply.value = cache.isEmpty
            replied.value = $0
        })

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(reply == .terminateLater)
        await waitFor("termination reply") { replied.value }
        #expect(replied.value)
        #expect(cacheWasEmptyAtReply.value)
        #expect(cache.isEmpty)
    }
}
