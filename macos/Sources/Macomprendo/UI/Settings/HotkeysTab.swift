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
            }
        }
        .formStyle(.grouped)
        .padding()
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
