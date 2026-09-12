import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var dictation: DictationTabModel
    @ObservedObject var models: ModelsViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
            .task {
                await models.refresh()
                dictation.adopt(models.rows)
            }
            .onChange(of: models.rows) { _, rows in
                dictation.adopt(rows)
            }
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

        Divider()

        Toggle("Save dictation history", isOn: $model.settings.dictationHistoryEnabled)
        Button("Dictation History…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.dictationHistory)
        }

        Divider()

        Picker("Active dictation model", selection: activeSource) {
            ForEach(dictation.selectableSources) { entry in
                Text(entry.menuTitle).tag(entry.source)
            }
        }
        .disabled(!dictation.hasReadySource)

        Picker("Translate into", selection: $model.settings.translationTarget) {
            ForEach(TranslationTarget.allOptions, id: \.self) { target in
                Text(Self.translationTargetLabel(
                    target,
                    promptLanguage: model.settings.promptLanguage,
                    systemLanguageCode: TranslationTarget.currentSystemLanguageCode
                )).tag(target)
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

        // Same activation reason as "Settings…" above: without `NSApp.activate` this
        // window can open behind every other app's windows.
        Button("About Macomprendo…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.about)
        }

        Divider()

        Button("Quit Macomprendo") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var activeSource: Binding<TranscriptionSource> {
        Binding(get: { dictation.activeSource }, set: { dictation.activate($0) })
    }

    nonisolated static func translationTargetLabel(_ target: TranslationTarget,
                                       promptLanguage: String,
                                       systemLanguageCode: String?) -> String {
        target.pickerLabel(promptLanguage: promptLanguage, systemLanguageCode: systemLanguageCode)
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
