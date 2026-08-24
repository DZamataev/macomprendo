import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(model.statusText)
        Text(sourceDescription).font(.caption)

        Divider()

        ForEach(HotkeyAction.allCases, id: \.self) { action in
            Toggle(action.displayName, isOn: Binding(
                get: { model.isEnabled(action) },
                set: { model.setEnabled(action, $0) }))
        }

        Divider()

        SettingsLink {
            Text("Settings…")
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
