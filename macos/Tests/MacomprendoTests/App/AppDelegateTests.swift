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

    /// The app's real surface is the status item, not a window: with the hidden
    /// `MenuBarExtra` anchor showing nothing at launch, closing the last window (Settings)
    /// must leave the app running (spec §7's cold-launch decision).
    @Test func closingTheLastWindowDoesNotTerminateTheApp() {
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake()
        )
        let delegate = AppDelegate(model: model, replyToTermination: { _ in })

        let shouldTerminate = delegate.applicationShouldTerminateAfterLastWindowClosed(
            NSApplication.shared)

        #expect(shouldTerminate == false)
    }
}
