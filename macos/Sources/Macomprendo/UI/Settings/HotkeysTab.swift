import KeyboardShortcuts
import SwiftUI

struct HotkeysTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictate", name: .dictate)
                KeyboardShortcuts.Recorder("Dictate & Refine", name: .dictateAndRefine)
                KeyboardShortcuts.Recorder("Speak selection", name: .speak)
                KeyboardShortcuts.Recorder("Summarize selection", name: .summarize)
                KeyboardShortcuts.Recorder("Refine selection", name: .refineSelection)

                Picker("Dictation behaviour", selection: $model.settings.dictationMode) {
                    Text("Hold to talk").tag(DictationMode.hold)
                    Text("Press to start, press to stop").tag(DictationMode.toggle)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Switch individual hotkeys off in the menubar menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse") {
                Toggle("Middle mouse button click", isOn: middleMouseEnabled)
                Picker("Action", selection: middleMouseAction) {
                    ForEach(MiddleMouseAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .disabled(model.settings.middleMouseAction == nil)

                Picker("Dictation behaviour", selection: $model.settings.middleMouseMode) {
                    Text("Hold to talk").tag(DictationMode.hold)
                    Text("Press to start, press to stop").tag(DictationMode.toggle)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.settings.middleMouseAction == nil)

                Text("Hold the button for Dictate in Hold mode; click it again to stop in Toggle mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let notice = HotkeysTab.middleMouseConflictNotice(model.settings) {
                    Label { Text(notice) } icon: { Icon(.warning, size: 14) }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Shown while the middle button drives an action. Apps that paste on a middle click keep
    /// doing so — the monitor observes the event rather than consuming it — so the click does
    /// two things at once and the app looks broken. `nil` while the button is unused.
    ///
    /// Only apps whose setting was verified are named, and each is named as that app spells
    /// it. Terminal.app is deliberately absent: macOS has no selection clipboard, so it never
    /// pasted on a middle click, and sending the user to look would waste their time.
    nonisolated static func middleMouseConflictNotice(_ settings: Settings) -> String? {
        guard settings.middleMouseAction != nil else { return nil }
        return "Apps that paste on a middle click still will — the click does both. "
            + "In Warp, turn off Settings ▸ Features ▸ Editor ▸ Middle-click paste. "
            + "In iTerm2, clear the middle-button action in Preferences ▸ Pointer."
    }

    private var middleMouseEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.middleMouseAction != nil },
            set: { enabled in
                model.settings.middleMouseAction = enabled
                    ? model.settings.middleMouseAction ?? .dictate
                    : nil
            })
    }

    private var middleMouseAction: Binding<MiddleMouseAction> {
        Binding(
            get: { model.settings.middleMouseAction ?? .dictate },
            set: { model.settings.middleMouseAction = $0 })
    }
}
