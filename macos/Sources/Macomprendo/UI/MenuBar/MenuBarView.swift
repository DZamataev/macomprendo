import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)
        Divider()
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Macomprendo") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        switch model.settings.transcriptionSource {
        case .local(let modelID):
            return "Idle · local \(modelID)"
        case .endpoint(let id, let modelName):
            let endpointName = model.settings.endpoints.first { $0.id == id }?.name ?? "endpoint"
            return "Idle · \(endpointName) · \(modelName)"
        }
    }
}
