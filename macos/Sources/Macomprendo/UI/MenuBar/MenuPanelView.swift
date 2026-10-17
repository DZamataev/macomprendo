import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The status item's popover content: the quick-access panel in the spec's order (§3) —
/// header, call block, dictation activity, transcription activity, the three selectors, the
/// file and history commands, the collapsed **Options** group, then the window and application
/// commands.
///
/// The host rebuilds this view on every show (spec §6), so `@State` starts fresh each opening:
/// that is what keeps **Options** collapsed and re-reads the shortcut annotations, which a
/// long-lived view would otherwise cache from launch.
struct MenuPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var dictation: DictationTabModel
    @ObservedObject var models: ModelsViewModel
    @ObservedObject var microphone: MicrophonePickerModel

    /// The status item's screen caps the panel on a short display; refreshed on every show
    /// (spec §6).
    let maxHeight: CGFloat

    @State private var optionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Macomprendo")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            CallRecordingPanelSection(controller: model.callRecording)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            dictationActivity

            TranscriptionActivitySection(transcription: model.fileTranscription)

            // Only this region scrolls once the caller's height cap is reached, so the
            // recording controls and the progress card always stay on screen (spec §6).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    selectors
                    divider
                    commandRows
                    divider
                    options
                    divider
                    windowRows
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: max(maxHeight, 0), alignment: .top)
        .task {
            // Readiness is computed from the models view model's rows, so refresh them before
            // the selector reads it — a fresh popover must not judge a freshly downloaded model
            // by launch-time state.
            await models.refresh()
            dictation.adopt(models.rows)
        }
        .onChange(of: models.rows) { _, rows in
            dictation.adopt(rows)
        }
    }

    // MARK: - Dictation activity (§3 non-idle dictation)

    @ViewBuilder private var dictationActivity: some View {
        switch model.dictation.state {
        case .idle:
            EmptyView()
        case .recording, .transcribing, .inserting:
            if let text = MenuPanelPresentation.dictationActivity(model.dictation.state) {
                dictationLine(text, isFailure: false)
            }
        case .failed(let message):
            dictationLine(message, isFailure: true)
        }
    }

    private func dictationLine(_ text: String, isFailure: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Icon(isFailure ? .warning : .waveform, size: 12)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(isFailure ? Color.red : Color.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Selectors (§3.4)

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                PanelCaption(text: "Microphone")
                Picker("Microphone", selection: microphoneSelection) {
                    ForEach(microphone.options) { option in
                        Text(option.title).tag(option.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let caption = microphone.caption {
                    note(caption)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                PanelCaption(text: "Dictation model")
                Picker("Dictation model", selection: activeSource) {
                    ForEach(dictation.selectableSources) { entry in
                        Text(entry.menuTitle).tag(entry.source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The library's own readiness rule: the active source stays listed even when
                // it cannot run, and the picker says why it is disabled.
                .disabled(!dictation.hasReadySource)
                if !dictation.hasReadySource {
                    note("No model is ready — set one up in Settings ▸ Dictation.")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                PanelCaption(text: "Translate into")
                Picker("Translate into", selection: $model.settings.translationTarget) {
                    ForEach(TranslationTarget.allOptions, id: \.self) { target in
                        Text(target.pickerLabel(
                            promptLanguage: model.settings.promptLanguage,
                            systemLanguageCode: TranslationTarget.currentSystemLanguageCode))
                            .tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // Each surface owns its device observation (spec §3): opening the panel starts it,
        // closing the panel stops it, and Settings keeps its own either way.
        .onAppear { microphone.startObserving() }
        .onDisappear { microphone.stopObserving() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var microphoneSelection: Binding<String?> {
        Binding(get: { microphone.selection }, set: { microphone.selection = $0 })
    }

    private var activeSource: Binding<TranscriptionSource> {
        Binding(get: { dictation.activeSource }, set: { dictation.activate($0) })
    }

    // MARK: - Commands (§3.5, §3.7)

    private var commandRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelCommandRow(icon: .fileAudio, title: "Transcribe File…") { transcribeFile() }
            PanelCommandRow(icon: .folder, title: "Transcripts…") { openTranscripts() }
            PanelCommandRow(icon: .history, title: "Dictation History…") { openHistoryWindow() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var windowRows: some View {
        let canRaise = model.windowRaiser.hasEligibleWindows
        return VStack(alignment: .leading, spacing: 1) {
            PanelCommandRow(icon: .appWindow, title: "Show All Windows",
                            isEnabled: canRaise,
                            help: canRaise ? nil : "No Macomprendo windows are open") {
                routeAfterClosing { model.windowRaiser.raiseAll() }
            }
            PanelCommandRow(icon: .settings, title: "Settings…", shortcut: "⌘,") {
                routeAfterClosing { openSettings() }
            }
            .keyboardShortcut(",", modifiers: .command)
            PanelCommandRow(icon: .shieldCheck, title: "Check permissions…") {
                routeAfterClosing { OnboardingWindowController.show(model: model) }
            }
            PanelCommandRow(icon: .info, title: "About Macomprendo…") {
                routeAfterClosing { openWindow(id: WindowID.about) }
            }
            PanelCommandRow(icon: .power, title: "Quit Macomprendo", shortcut: "⌘Q") {
                // The existing async shutdown: the termination delegate finalises a recording
                // and awaits the running job.
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    /// Closes the panel, activates the app, then routes (spec §6). An `LSUIElement` app must
    /// activate itself or the window it opens lands behind everything else.
    private func routeAfterClosing(_ route: () -> Void) {
        model.closeMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        route()
    }

    private func openTranscripts() {
        routeAfterClosing { openWindow(id: WindowID.transcripts) }
    }

    private func openHistoryWindow() {
        routeAfterClosing { openWindow(id: WindowID.dictationHistory) }
    }

    /// The same chooser as the old menu's item: any audio or video file, one at a time.
    /// Cancelling starts nothing; the window opens only after a selection.
    private func transcribeFile() {
        model.closeMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(id: WindowID.transcripts)
        model.fileTranscription.transcribe(fileAt: url)
    }

    // MARK: - Options (§3.6)

    private var options: some View {
        DisclosureGroup(isExpanded: $optionsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $model.settings.dictationHistoryEnabled) {
                    Text("Save dictation history")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 6)
                .frame(minHeight: 24)

                PanelCaption(text: "Enable hotkeys")
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    hotkeyToggle(action)
                }

                Text("Change shortcuts in Settings ▸ Hotkeys")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .padding(.top, 4)
        } label: {
            Text("Options")
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    /// A switch for one action's hotkey, annotated with the shortcut currently bound to it.
    /// The annotation is read from the live binding, not a launch-time cache, and an action
    /// with no shortcut shows none (spec §3).
    private func hotkeyToggle(_ action: HotkeyAction) -> some View {
        Toggle(isOn: Binding(get: { model.isEnabled(action) },
                             set: { model.setEnabled(action, $0) })) {
            HStack(spacing: 6) {
                Text(action.displayName)
                Spacer(minLength: 6)
                if let annotation = MenuPanelPresentation.shortcutAnnotation(
                    action.currentShortcutText()) {
                    Text(annotation)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .frame(minHeight: 24)
    }

    private var divider: some View {
        Divider()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
    }
}
