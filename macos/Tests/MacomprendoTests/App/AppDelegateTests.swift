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


    // MARK: - Opening the running app again (Finder, Spotlight, Launchpad)

    private func reopenFixture(windows: Bool, isActive: Bool, activatedAgo: TimeInterval?)
        -> (raiser: FakeWindowRaiser, host: FakeStatusItemHost, handled: Bool) {
        let raiser = FakeWindowRaiser()
        raiser.hasEligibleWindows = windows
        let host = FakeStatusItemHost()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(makeStatusItem: { _ in host }, windowRaiser: raiser))
        model.start()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let clock = Box(start)
        let delegate = AppDelegate(model: model, replyToTermination: { _ in },
                                   isAppActive: { isActive }, now: { clock.value })
        if let activatedAgo {
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            clock.value = start.addingTimeInterval(activatedAgo)
        }
        let handled = delegate.applicationShouldHandleReopen(NSApplication.shared,
                                                             hasVisibleWindows: windows)
        return (raiser, host, handled)
    }

    @Test func reopeningAnInactiveAppWithWindowsRaisesThemFirst() {
        let r = reopenFixture(windows: true, isActive: false, activatedAgo: nil)
        #expect(r.raiser.raiseAllCount == 1)
        #expect(r.host.revealPanelCount == 0)
        #expect(r.handled == false)
    }

    /// The reopening click itself activates the app just before the reopen arrives; that
    /// activation must not count as the windows already being in front.
    @Test func theActivationOfTheReopeningClickStillRaisesTheWindows() {
        let r = reopenFixture(windows: true, isActive: true, activatedAgo: 0.1)
        #expect(r.raiser.raiseAllCount == 1)
        #expect(r.host.revealPanelCount == 0)
    }

    @Test func reopeningAnAlreadyActiveAppOpensThePanel() {
        let r = reopenFixture(windows: true, isActive: true, activatedAgo: 30)
        #expect(r.raiser.raiseAllCount == 0)
        #expect(r.host.revealPanelCount == 1)
    }

    @Test func reopeningWithNoWindowsOpensThePanel() {
        let r = reopenFixture(windows: false, isActive: false, activatedAgo: nil)
        #expect(r.raiser.raiseAllCount == 0)
        #expect(r.host.revealPanelCount == 1)
        #expect(r.handled == false)
    }
}
