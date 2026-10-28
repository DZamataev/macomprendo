import SwiftUI

struct GeneralTab: View {
    /// "System default" first, then each output; a chosen device that is unplugged stays listed
    /// so the picker never silently shows a different choice.
    nonisolated static func soundOutputOptions(_ devices: [AudioInputDevice],
                                               selected: String?) -> [MicrophoneOption] {
        var options = [MicrophoneOption(uid: nil, title: "System default")]
            + devices.map { MicrophoneOption(uid: $0.uid, title: $0.name) }
        if let selected, !devices.contains(where: { $0.uid == selected }) {
            options.append(MicrophoneOption(uid: selected, title: "Disconnected device"))
        }
        return options
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var savedAudio: SavedAudioModel
    /// Observed so a recording saved while this screen is open redraws the size readout.
    /// `AppModel` republishes only the dictation controller, so watching it is not enough.
    @ObservedObject var history: DictationHistoryController
    @ObservedObject var microphone: MicrophonePickerModel
    @ObservedObject var callRecordings: CallRecordingsSettingsModel
    /// The speaker models **Tell the other speakers apart** needs.
    @ObservedObject var speakerModels: ModelsViewModel
    @State private var viewModel: GeneralTabModel?
    @State private var launchAtLoginError: String?
    @State private var isDeleteAudioConfirmationPresented = false
    /// *Using the microphone now*, re-read once a second while the section is on screen.
    @State private var microphoneUsers: [CallApp] = []
    /// The manual Add row's own state: a bundle ID typed ahead of the app's first call.
    @State private var newBundleID = ""
    @State private var newCallAppKind: CallApp.Kind = .app

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

            Section("Microphone") {
                Picker("Microphone", selection: $microphone.selection) {
                    ForEach(microphone.options) { option in
                        Text(option.title).tag(option.uid)
                    }
                }
                if let caption = microphone.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Release the microphone after recording",
                       isOn: $model.settings.releaseMicrophoneAfterRecording)
                Text("Bluetooth headphones switch to a low-quality call mode while the microphone "
                     + "is open. On, they return to full sound as soon as recording stops. Off keeps "
                     + "the microphone open between recordings, so the next one starts a little "
                     + "sooner — but the headphones stay in call mode until you click Release "
                     + "Microphone in the menubar panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Call recordings") {
                Text(callRecordings.directory.path)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Choose…") { chooseRecordingFolder() }
                    Button("Show in Finder") { callRecordings.showInFinder() }
                }

                Text(callRecordings.totalSizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Transcribe calls", selection: $model.settings.callTranscription) {
                    ForEach(CallTranscriptionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(Self.callTranscriptionCaption(model.settings.callTranscription))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Save subtitles (.srt) in the recording folder",
                       isOn: $model.settings.saveCallSubtitles)
                Text("When a call's transcript is finished, its subtitles are saved next to the "
                     + "two tracks under the folder's name, and saved again after Resume or "
                     + "Transcribe Again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Tell the other speakers apart", isOn: $model.settings.identifyCallSpeakers)
                if model.settings.identifyCallSpeakers {
                    ForEach(speakerModels.rows) { row in
                        HStack {
                            Text("Speaker models · "
                                 + ModelsViewModel.sizeText(row.model.totalSizeBytes))
                            Spacer()
                            speakerModelState(row.id, row.state)
                        }
                    }
                }
                Text("When a call's transcript is finished, the far side is split by voice into "
                     + "Speaker 1, Speaker 2, … and transcribed again by turn; until then, and "
                     + "without the speaker models, it reads Others. Fast exchanges are often "
                     + "misattributed. Models: pyannote segmentation (MIT) and 3D-Speaker "
                     + "ERes2Net (Apache-2.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Record calls automatically", isOn: $model.settings.autoRecordCalls)
                Text((model.settings.autoRecordAllApps
                      ? "Starts recording when any app uses the microphone, "
                      : "Starts recording when a call app from the list below uses the microphone, ")
                     + "and stops when the call ends. Many places require everyone's consent "
                     + "before a call is recorded; telling them is up to you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Like the Glossary section: the list only matters with the switch on, and it
                // is long enough to bury the rest of the tab.
                if model.settings.autoRecordCalls {
                    Toggle("All apps", isOn: $model.settings.autoRecordAllApps)
                    Text("On, any app using the microphone counts as a call. Off, only the "
                         + "apps in the list below do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.settings.autoRecordAllApps {
                        callApps
                    }
                }
            }
            .task {
                await callRecordings.refreshSize()
                await speakerModels.refresh()
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

                Picker("Recording quality", selection: $model.settings.savedRecordingFormat) {
                    ForEach(SavedRecordingFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
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

                Toggle("Insert “OK” on a middle click in a text field",
                       isOn: $model.settings.shortDictationInsertsOK)
                Text("With middle-click dictation in hold mode, a click released before recording starts inserts “OK” into the focused text field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Add a space after dictated text", isOn: $model.settings.appendSpaceAfterDictation)
                Text("Dictate and original Dictate & Refine insertion get the space. History and refined text are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Play a sound when recording starts and stops", isOn: $model.settings.playRecordingSounds)
                Group {
                    Picker("Sound output", selection: $model.settings.recordingSoundsOutputUID) {
                        ForEach(Self.soundOutputOptions(model.env.audioInputDevices.outputDevices(),
                                                        selected: model.settings.recordingSoundsOutputUID)) {
                            Text($0.title).tag($0.uid)
                        }
                    }
                    // Previewed on release, not on every tick of the drag.
                    Slider(value: $model.settings.recordingSoundsVolume, in: 0...1) {
                        Text("Sound volume")
                    } onEditingChanged: { editing in
                        guard !editing else { return }
                        Task { await model.env.recordingCues.playStartSound(model.settings) }
                    }
                }
                .disabled(!model.settings.playRecordingSounds)
                Toggle("Mute system audio while recording", isOn: $model.settings.muteWhileRecording)
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
        // A dictation saved while this screen is open changes the directory behind the size
        // readout. `.task(id:)` re-runs whenever the revision moves, and the model skips the
        // directory walk when it has not.
        .task(id: history.savedAudioRevision) {
            reconcileLaunchAtLogin()
            await savedAudio.refreshIfSavedAudioChanged()
        }
        // Keeps the microphone list live while the tab is open: a headset switched on or a
        // dongle unplugged shows up without reopening Settings.
        .onAppear { microphone.startObserving() }
        .onDisappear { microphone.stopObserving() }
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

    /// Picks the recordings folder. Directories only — the panel creates one on demand so a
    /// new folder can be chosen in the same gesture.
    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        callRecordings.choose(url)
    }

    private static func callTranscriptionCaption(_ mode: CallTranscriptionMode) -> String {
        switch mode {
        case .whileRecording:
            "Text appears in Transcripts during the call. Uses the speech model throughout the call."
        case .afterRecording:
            "A call is transcribed as soon as it stops."
        case .manual:
            "A stopped call waits in Transcripts until you press Resume — "
                + "for a busy Mac, or to pick another model first."
        }
    }

    // MARK: - Call apps

    /// The list, *Using the microphone now* and the two adders. One stack rather than a row per
    /// app, so the one-second poll attaches to a single view: a modifier on a `Group` is
    /// distributed to its members and would start a poll per row.
    private var callApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($model.settings.autoRecordApps) { $app in
                callAppRow($app)
            }
            if !microphoneUsers.isEmpty {
                Text("Using the microphone now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(microphoneUsers) { app in
                    microphoneUserRow(app)
                }
            }
            manualCallAppRow
            Button("Restore Default Apps") {
                model.settings.autoRecordApps = CallApp.defaults
            }
        }
        // Polls while the section is on screen — and is cancelled with the view when the
        // switch goes off.
        .task {
            while !Task.isCancelled {
                microphoneUsers = model.microphoneUsersNotListed()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func callAppRow(_ app: Binding<CallApp>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.wrappedValue.name)
                Text(app.wrappedValue.bundleIDPrefix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            kindPicker(app.kind)
            Button {
                model.settings.autoRecordApps.removeAll { $0.id == app.wrappedValue.id }
            } label: {
                Icon(.remove, size: 12)
            }
            .accessibilityLabel("Remove \(app.wrappedValue.name)")
        }
    }

    private func microphoneUserRow(_ app: CallApp) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text(app.bundleIDPrefix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Add") { add(app) }
        }
    }

    private var manualCallAppRow: some View {
        HStack(spacing: 8) {
            TextField("Bundle ID", text: $newBundleID)
            kindPicker($newCallAppKind)
            Button("Add") {
                let bundleID = newBundleID.trimmingCharacters(in: .whitespaces)
                add(CallApp(name: bundleID, bundleIDPrefix: bundleID, kind: newCallAppKind))
                newBundleID = ""
            }
            .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func kindPicker(_ kind: Binding<CallApp.Kind>) -> some View {
        Picker("Kind", selection: kind) {
            Text("App").tag(CallApp.Kind.app)
            Text("Browser").tag(CallApp.Kind.browser)
        }
        .labelsHidden()
        .frame(width: 100)
    }

    /// One entry per bundle ID — a duplicate would break the list's identity, and a row the
    /// user just added must leave *Using the microphone now* at once, not a second later.
    private func add(_ app: CallApp) {
        guard !app.bundleIDPrefix.isEmpty,
              !model.settings.autoRecordApps.contains(where: { $0.id == app.id })
        else { return }
        model.settings.autoRecordApps.append(app)
        microphoneUsers.removeAll { $0.id == app.id }
    }

    @ViewBuilder
    private func speakerModelState(_ id: String, _ state: ModelState) -> some View {
        switch state {
        case .notDownloaded:
            Button("Download") { speakerModels.download(id) }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { speakerModels.cancelDownload(id) }
            }
        case .downloaded:
            HStack(spacing: 8) {
                Label { Text("Downloaded") } icon: { Icon(.success, size: 14) }
                    .foregroundStyle(.green)
                Button("Delete", role: .destructive) { Task { await speakerModels.delete(id) } }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label { Text(message) } icon: { Icon(.warning, size: 14) }
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { speakerModels.download(id) }
            }
        }
    }
}
