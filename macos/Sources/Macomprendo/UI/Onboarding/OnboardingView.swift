import SwiftUI

struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel

    init(viewModel: OnboardingViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Divider()
            step
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .task { await viewModel.refresh() }
        // Granting a permission happens in System Settings, which the wizard cannot observe.
        // Coming back to the app is the moment the answer may have changed, so re-read it then
        // — otherwise the step keeps showing a status that stopped being true.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Macomprendo").font(.title2).bold()
            Text("Four hotkeys for dictation and text. Two permissions and a model, and you are done.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var step: some View {
        switch viewModel.step {
        case .microphone:
            stepBody(icon: .microphone,
                     title: "Allow the microphone",
                     detail: "Macomprendo records only while you hold the dictation hotkey.") {
                statusRow(viewModel.micStatus)
                permissionButtons(grantTitle: "Allow microphone…") {
                    await viewModel.requestMicrophone()
                }
            }
        case .accessibility:
            stepBody(icon: .hotkeys,
                     title: "Allow accessibility",
                     detail: "Needed to paste the transcript into the app you were typing in.") {
                statusRow(viewModel.accessibilityStatus)
                permissionButtons(grantTitle: "Allow accessibility…") {
                    await viewModel.requestAccessibility()
                }
            }
        case .model:
            stepBody(icon: .download,
                     title: "Download a speech model",
                     detail: "Transcription runs on this Mac. large-v3-turbo is the most accurate; base is small and fast.") {
                Picker("Model", selection: $viewModel.selectedModelID) {
                    Text("Large v3 Turbo (recommended)").tag(ModelCatalog.defaultID)
                    Text("Base (lightweight)").tag(ModelCatalog.lightweightID)
                }
                .pickerStyle(.radioGroup)
                modelStateRow
                Button("Download") { Task { await viewModel.downloadSelectedModel() } }
                    .disabled(isDownloading)
            }
        case .ollama:
            stepBody(icon: .model,
                     title: "Ollama (optional)",
                     detail: "Refine and summarize use Ollama at http://localhost:11434. You can change this in Settings ▸ Providers.") {
                Button("Check for Ollama") { Task { await viewModel.detectOllama() } }
                switch viewModel.ollamaFound {
                case .some(true):
                    Label { Text("Ollama is running.") } icon: { Icon(.success, size: 14) }
                        .foregroundStyle(.green)
                case .some(false):
                    Label { Text("Not found — install it from ollama.com, or use an OpenAI-compatible endpoint.") }
                        icon: { Icon(.warning, size: 14) }
                        .foregroundStyle(.orange)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = viewModel.modelState { return true }
        return false
    }

    @ViewBuilder
    private var modelStateRow: some View {
        switch viewModel.modelState {
        case .notDownloaded:
            Text("Not downloaded yet.").font(.callout).foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading…") }
        case .downloaded:
            Label { Text("Downloaded.") } icon: { Icon(.success, size: 14) }
                .foregroundStyle(.green)
        case .failed(let message):
            Label { Text(message) } icon: { Icon(.warning, size: 14) }
                .foregroundStyle(.red)
        }
    }

    private func statusRow(_ status: PermissionStatus) -> some View {
        Group {
            switch status {
            case .granted:
                Label { Text("Granted.") } icon: { Icon(.success, size: 14) }
                    .foregroundStyle(.green)
            case .denied:
                Label { Text("Denied — turn Macomprendo on in System Settings, then come back.") }
                    icon: { Icon(.warning, size: 14) }
                    .foregroundStyle(.orange)
            case .undetermined:
                Label { Text("Not asked yet.") } icon: { Icon(.remove, size: 14) }
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// macOS shows its permission prompt only once per app; after that the grant button is
    /// inert and the switch lives in System Settings. "Check again" is what turns a grant made
    /// over there into something this window can see, and the caption says so, because a button
    /// that silently does nothing reads as a hang.
    private func permissionButtons(grantTitle: String,
                                   grant: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(grantTitle) { Task { await grant() } }
                Button("Check again") { Task { await viewModel.refresh() } }
            }
            Text("macOS asks only once. If you turned it on in System Settings, use Check again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepBody(icon: AppIcon,
                          title: String,
                          detail: String,
                          @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Icon(icon, size: 36).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private var footer: some View {
        HStack {
            Text("Step \(viewModel.step.rawValue + 1) of \(OnboardingViewModel.Step.allCases.count) · \(viewModel.step.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Back") { viewModel.back() }
                .disabled(viewModel.step == .microphone)
            Button(viewModel.step == .ollama ? "Finish" : "Continue") { viewModel.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canContinue)
        }
    }
}
