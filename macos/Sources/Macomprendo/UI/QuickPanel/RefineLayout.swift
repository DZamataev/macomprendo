import SwiftUI

/// Play / Pause / Resume plus Stop for one text in the Quick Panel. Seeking is deliberately
/// absent: `AVSpeechSynthesizer` exposes no position, so a scrubber could not behave the same
/// on both speech sources (see the spec's Part 6).
struct SpeechControls: View {
    @ObservedObject var speak: SpeakController
    let source: SpeakSource
    let text: () -> String

    private var isActive: Bool { speak.active == source }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isActive {
                    speak.pauseOrResume()
                } else {
                    speak.speak(text(), from: source)
                }
            } label: {
                Icon(icon, size: 14)
            }
            .help(helpText)

            if isActive {
                Button { speak.stop() } label: {
                    Icon(.stop, size: 14)
                }
                .help("Stop reading")
            }
        }
    }

    private var icon: AppIcon {
        guard isActive else { return .speak }
        return speak.isPaused ? .play : .pause
    }

    private var helpText: String {
        guard isActive else { return "Read aloud" }
        return speak.isPaused ? "Resume reading" : "Pause reading"
    }
}

/// Original | Refined side by side, both editable, with per-side Copy and Insert.
struct RefineLayout: View {
    @ObservedObject var controller: RefineController
    let presets: [PromptPreset]
    @ObservedObject var speak: SpeakController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.error { errorBanner(error) }
            HStack(spacing: 0) {
                pane(title: "Original", text: $controller.original, side: .original, source: .refineOriginal)
                Divider()
                pane(title: "Refined", text: $controller.refined, side: .refined, source: .refineRefined)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(PromptLanguage.allCases) { language in
                    Button(language.displayName) { controller.promptLanguage = language.code }
                }
            } label: {
                Icon(.globe, size: 14)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Prompt language")

            // Bound through `selectPreset(_:)` rather than `$controller.selectedPresetID` plus
            // `.onChange`: that also fired for the programmatic write the globe menu makes, so
            // every language switch started two streams and cancelled the first.
            Picker("", selection: Binding(get: { controller.selectedPresetID },
                                          set: { controller.selectPreset($0) })) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)

            TextField("Extra instruction (⌘↩ to run again)", text: $controller.instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit { controller.rerun() }

            if controller.isStreaming {
                ProgressView().controlSize(.small)
                Button { controller.stop() } label: {
                    Icon(.stop, size: 14)
                }
                .help("Stop streaming")
            } else {
                Button { controller.rerun() } label: {
                    Icon(.refresh, size: 14)
                }
                .help("Run again (⌘↩)")
            }

            // Invisible button that owns the ⌘↩ shortcut for the whole panel.
            Button("") { controller.rerun() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .frame(width: 0)
        }
        .padding(10)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warning, size: 14)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func pane(title: String, text: Binding<String>, side: RefineSide, source: SpeakSource) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                SpeechControls(speak: speak, source: source, text: { text.wrappedValue })
                Button { controller.copy(side) } label: {
                    Icon(.copy, size: 14)
                }
                .help("Copy \(title.lowercased())")
                Button { Task { await controller.insert(side) } } label: {
                    Icon(.insert, size: 14)
                }
                .help("Insert \(title.lowercased()) into the previous app")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
