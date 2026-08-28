import SwiftUI

/// Original | Refined side by side, both editable, with per-side Copy and Insert.
struct RefineLayout: View {
    @ObservedObject var controller: RefineController
    let presets: [PromptPreset]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = controller.error { errorBanner(error) }
            HStack(spacing: 0) {
                pane(title: "Original", text: $controller.original, side: .original)
                Divider()
                pane(title: "Refined", text: $controller.refined, side: .refined)
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

    private func pane(title: String, text: Binding<String>, side: RefineSide) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
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
