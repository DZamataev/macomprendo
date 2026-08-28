import SwiftUI

/// One pane with the streamed summary; Copy or Replace the selection in the source app.
struct SummaryLayout: View {
    @ObservedObject var controller: SummarizeController
    let presets: [PromptPreset]
    @ObservedObject var speak: SpeakController

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.error { errorBanner(error) }
            TextEditor(text: $controller.summary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Icon(.summarize, size: 14)
                .foregroundStyle(.secondary)

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

            Picker("", selection: $controller.selectedPresetID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: controller.selectedPresetID) { _, _ in controller.rerun() }

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

    private var footer: some View {
        HStack {
            Text("\(controller.source.count) characters summarized")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            SpeechControls(speak: speak, source: .summary, text: { controller.summary })
            Button { controller.copy() } label: {
                Label { Text("Copy") } icon: {
                    Icon(.copy, size: 14)
                }
            }
            Button { Task { await controller.replaceSelection() } } label: {
                Label { Text("Replace selection") } icon: {
                    Icon(.insert, size: 14)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }
}
