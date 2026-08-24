import SwiftUI

@main
struct MacomprendoApp: App {
    var body: some Scene {
        // The status item is deliberately an SF Symbol template image (spec §2, §3.5).
        // Phosphor icons are for in-app UI only.
        MenuBarExtra("Macomprendo", systemImage: "waveform") {
            Button("Quit Macomprendo") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }
}
