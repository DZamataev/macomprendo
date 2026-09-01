import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Text(sourceDescription).font(.caption)

        Divider()

        ForEach(HotkeyAction.allCases, id: \.self) { action in
            Toggle(isOn: Binding(
                get: { model.isEnabled(action) },
                set: { model.setEnabled(action, $0) })) {
                    // `+` on Text yields ONE Text, not a composite label, so the whole row
                    // survives into the NSMenuItem — see `HotkeyAction.menuTitle(shortcut:)`.
                    Text(action.displayName)
                        + Text(HotkeyAction.menuSeparator
                               + action.menuTrailing(shortcut: action.currentShortcutText()))
                        .foregroundStyle(.secondary)
                }
        }

        if model.settings.dictationHistoryEnabled {
            Button("Dictation History…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dictation-history")
            }
        }

        Divider()

        // `LSUIElement` apps never activate themselves when a SwiftUI `Settings` scene
        // opens, so a bare `SettingsLink` can open the window behind everything else with
        // no way for the user to notice. Activate the app in the same action so the
        // window actually comes to the front.
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check permissions…") {
            OnboardingWindowController.show(model: model)
        }

        Divider()

        Button("Quit Macomprendo") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var sourceDescription: String {
        switch model.settings.transcriptionSource {
        case .local(let modelID):
            "Local model: \(modelID)"
        case .endpoint(let id, let model):
            "Endpoint: \(endpointName(id)) · \(model)"
        }
    }

    private func endpointName(_ id: UUID) -> String {
        model.settings.endpoints.first { $0.id == id }?.name ?? "unknown"
    }
}
