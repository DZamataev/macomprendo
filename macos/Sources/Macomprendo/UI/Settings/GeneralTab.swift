import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var savedAudio: SavedAudioModel
    @State private var viewModel: GeneralTabModel?
    @State private var launchAtLoginError: String?
    @State private var isDeleteAudioConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { setLaunchAtLogin($0) }))

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Dictation") {
                Picker("Insert text by", selection: $model.settings.insertMethod) {
                    Text("Automatic").tag(InsertMethod.auto)
                    Text("Pasting (⌘V)").tag(InsertMethod.paste)
                    Text("Typing character by character").tag(InsertMethod.typing)
                }
                Text("Typing is slower but works in apps that block pasting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Save dictation history", isOn: $model.settings.dictationHistoryEnabled)
                Text("Transcripts are stored locally in plaintext. Recordings are stored only "
                     + "while “Save the original recording” is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Save the original recording", isOn: $model.settings.saveOriginalRecording)
                    .disabled(!SavedAudioModel.recordingToggleIsEnabled(model.settings))

                Picker("Keep history for", selection: $model.settings.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.displayName).tag(retention)
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Saved audio: \(savedAudio.sizeText)")
                    Spacer(minLength: 8)
                    Button("Show in Finder") { savedAudio.reveal() }
                    Button("Delete saved audio…") {
                        isDeleteAudioConfirmationPresented = true
                    }
                }

                if let savedAudioError = savedAudio.errorMessage {
                    Text(savedAudioError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Insert “OK” for a very short dictation",
                       isOn: $model.settings.shortDictationInsertsOK)
                Text("Recordings shorter than half a second skip speech recognition and insert “OK”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Add a space after dictated text", isOn: $model.settings.appendSpaceAfterDictation)
                Text("Dictate and original Dictate & Refine insertion get the space. History and refined text are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local models") {
                Picker("Unload local model", selection: $model.settings.localModelIdleTimeout) {
                    ForEach(LocalModelIdleTimeout.allCases, id: \.self) { timeout in
                        Text(timeout.displayName).tag(timeout)
                    }
                }
                Text("Keeping the model loaded makes consecutive dictations start faster. "
                     + "Changing the active model or whisper.cpp parameters unloads it immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Delete every saved recording?",
                            isPresented: $isDeleteAudioConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Delete saved audio", role: .destructive) {
                Task { await savedAudio.deleteSavedAudio() }
            }
        } message: {
            Text("This permanently removes every saved recording. Transcripts are kept.")
        }
        .task {
            reconcileLaunchAtLogin()
            await savedAudio.refreshSize()
        }
    }

    /// The system is the truth: on appear, pull `settings.launchAtLogin` back in line with
    /// reality in case the user removed the login item from System Settings directly.
    private func reconcileLaunchAtLogin() {
        viewModelForLaunchAtLogin().reconcile(settings: &model.settings)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let viewModel = viewModelForLaunchAtLogin()
        viewModel.setLaunchAtLogin(enabled, settings: &model.settings)
        launchAtLoginError = viewModel.launchAtLoginError
    }

    private func viewModelForLaunchAtLogin() -> GeneralTabModel {
        if let viewModel { return viewModel }
        let viewModel = GeneralTabModel(manager: model.env.launchAtLogin)
        self.viewModel = viewModel
        return viewModel
    }
}
