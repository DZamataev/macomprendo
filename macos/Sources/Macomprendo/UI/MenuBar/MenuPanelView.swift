import AppKit
import SwiftUI

/// The status item's popover content. A placeholder until the spec's panel lands (Task 5):
/// just the two commands that keep the app usable — open Settings, and quit.
struct MenuPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    /// The status item's screen caps the panel on a short display; refreshed on every show
    /// (spec §6).
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macomprendo").font(.headline)
            Button("Settings…") {
                model.closeMenuPanel()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Macomprendo") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: max(maxHeight, 0), alignment: .top)
    }
}
