import KeyboardShortcuts
import SwiftUI

struct HotkeysTab: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictate", name: .dictate)
                KeyboardShortcuts.Recorder("Dictate & Refine", name: .dictateAndRefine)
                KeyboardShortcuts.Recorder("Speak selection", name: .speak)
                KeyboardShortcuts.Recorder("Summarize selection", name: .summarize)
                KeyboardShortcuts.Recorder("Refine selection", name: .refineSelection)
            } footer: {
                Text("Switch individual hotkeys off in the menubar menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
