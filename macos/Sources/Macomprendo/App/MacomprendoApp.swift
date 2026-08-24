import AppKit
import SwiftUI

/// Single, main-actor-isolated instance shared by the SwiftUI scenes and the app delegate.
@MainActor
enum AppRoot {
    static let model = AppModel(store: UserDefaultsSettingsStore(),
                                keychain: SystemKeychainStore(),
                                env: .live())
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppRoot.model
        model.start()
        OnboardingWindowController.showIfNeeded(model: model)
    }
}

@main
struct MacomprendoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppRoot.model

    var body: some Scene {
        // The status item is deliberately an SF Symbol template image (spec §2, §3.5).
        // `AppIcon` raw values are SVG file names and must not be used here.
        MenuBarExtra("Macomprendo", systemImage: "waveform") {
            MenuBarView().environmentObject(model)
        }
        .menuBarExtraStyle(.menu)

        // `Settings` alone would resolve to our own Core type, so qualify the scene.
        SwiftUI.Settings {
            SettingsView().environmentObject(model)
        }
    }
}
