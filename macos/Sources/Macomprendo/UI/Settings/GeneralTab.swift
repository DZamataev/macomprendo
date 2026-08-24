import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchError: String?

    var body: some View {
        Form {
            Toggle("Launch Macomprendo at login", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))

            Picker("Dictation", selection: $model.settings.dictationMode) {
                Text("Hold the shortcut").tag(DictationMode.hold)
                Text("Press to start, press to stop").tag(DictationMode.toggle)
            }

            Picker("Insert text by", selection: $model.settings.insertMethod) {
                Text("Automatic").tag(InsertMethod.auto)
                Text("Pasting (⌘V)").tag(InsertMethod.paste)
                Text("Typing").tag(InsertMethod.typing)
            }

            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // PLAN 3 REPLACES THIS: direct SMAppService use is a deliberate foundation-only shim.
    // Plan 3 introduces LaunchAtLoginManaging (see map Amendments) — do not copy this pattern.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            model.settings.launchAtLogin = enabled
            launchError = nil
        } catch {
            Log.ui.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            launchError = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
