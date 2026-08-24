import SwiftUI

@main
struct MacomprendoApp: App {
    @StateObject private var model: AppModel

    init() {
        let model = AppModel(store: UserDefaultsSettingsStore(),
                             keychain: SystemKeychainStore(),
                             env: .live())
        model.start()
        _model = StateObject(wrappedValue: model)
    }

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
