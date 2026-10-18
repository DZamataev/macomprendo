import Foundation

/// Probes whether an Ollama server answers at `url`.
protocol OllamaDetecting: Sendable {
    func isRunning(at url: URL) async -> Bool
}

/// `GET {baseURL}/api/tags` returns 200 with `{"models":[…]}` when Ollama is running.
struct HTTPOllamaDetector: OllamaDetecting {
    let http: any HTTPClient

    init(http: any HTTPClient) {
        self.http = http
    }

    func isRunning(at url: URL) async -> Bool {
        let request = HTTPRequest(method: "GET",
                                  url: url.appendingPathComponent("api/tags"),
                                  headers: [:],
                                  body: nil,
                                  timeout: 5)
        guard let response = try? await http.send(request) else { return false }
        return (200..<300).contains(response.status)
    }
}

/// First-launch flow: microphone, accessibility, a whisper model, and an optional Ollama check.
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Equatable {
        case microphone, accessibility, systemAudio, model, ollama

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .systemAudio: "System audio (optional)"
            case .model: "Speech model"
            case .ollama: "Ollama (optional)"
            }
        }
    }

    static let completedKey = "hasCompletedOnboarding"

    @Published private(set) var step: Step = .microphone
    @Published private(set) var micStatus: PermissionStatus = .undetermined
    @Published private(set) var accessibilityStatus: PermissionStatus = .undetermined
    @Published private(set) var modelState: ModelState = .notDownloaded
    @Published private(set) var ollamaFound: Bool?
    @Published var selectedModelID: String = ModelCatalog.defaultID
    /// What the last system-audio request found; `nil` until the user asks.
    @Published private(set) var systemAudioProbe: SystemAudioProbe?

    /// The outcome of asking for system audio. macOS publishes no status for it, so this is
    /// what the attempt itself reported, not a permission state.
    enum SystemAudioProbe: Equatable {
        /// A capture started: macOS asked, or already had an answer.
        case asked
        /// A call is being recorded, so system audio is in use and already allowed.
        case inUse
        case failed(String)
    }

    /// Starts a system-audio capture once — the only way to make macOS ask. Injected: the
    /// capture belongs to `AppEnvironment` and must not be started while a call records.
    var probeSystemAudio: (@MainActor () async -> SystemAudioProbe)?
    var openSystemAudioSettings: (@MainActor () -> Void)?

    var onFinish: (@MainActor () -> Void)?
    var applySelection: (@MainActor (String) -> Void)?

    private let permissions: any PermissionsChecking
    private let models: any ModelManaging
    private let detector: any OllamaDetecting
    private let defaults: UserDefaults
    private let ollamaURL: URL

    init(permissions: any PermissionsChecking,
         models: any ModelManaging,
         detector: any OllamaDetecting,
         defaults: UserDefaults = .standard,
         ollamaURL: URL = URL(string: "http://localhost:11434")!) {
        self.permissions = permissions
        self.models = models
        self.detector = detector
        self.defaults = defaults
        self.ollamaURL = ollamaURL
    }

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedKey)
    }

    var canContinue: Bool {
        switch step {
        case .microphone: micStatus == .granted
        case .accessibility: accessibilityStatus == .granted
        case .systemAudio, .model, .ollama: true
        }
    }

    func refresh() async {
        micStatus = await permissions.status(of: .microphone)
        accessibilityStatus = await permissions.status(of: .accessibility)
        modelState = await models.state(of: selectedModelID)
    }

    /// Re-entry point for "Check permissions…": refreshes every status from the OS/disk,
    /// then jumps to the first step that still needs the user's attention, rather than
    /// leaving the wizard on whatever step it was cached at from a previous run.
    func resetToFirstIncompleteStep() async {
        await refresh()
        if micStatus != .granted {
            step = .microphone
        } else if accessibilityStatus != .granted {
            step = .accessibility
        } else if case .downloaded = modelState {
            step = .ollama
        } else {
            step = .model
        }
    }

    func requestMicrophone() async {
        micStatus = await permissions.request(.microphone)
        if micStatus != .granted {
            permissions.openSystemSettings(for: .microphone)
        }
    }

    func requestAccessibility() async {
        accessibilityStatus = await permissions.request(.accessibility)
        if accessibilityStatus != .granted {
            permissions.openSystemSettings(for: .accessibility)
        }
    }

    func requestSystemAudio() async {
        guard let probeSystemAudio else { return }
        systemAudioProbe = await probeSystemAudio()
    }

    func downloadSelectedModel() async {
        modelState = .downloading(fraction: 0)
        do {
            for try await fraction in models.download(selectedModelID) {
                modelState = .downloading(fraction: fraction)
            }
            modelState = await models.state(of: selectedModelID)
        } catch is CancellationError {
            modelState = await models.state(of: selectedModelID)
        } catch MacomprendoError.cancelled {
            modelState = await models.state(of: selectedModelID)
        } catch {
            modelState = .failed(ErrorText.describe(error))
        }
    }

    func detectOllama() async {
        ollamaFound = await detector.isRunning(at: ollamaURL)
    }

    func next() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            finish()
        }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            step = previous
        }
    }

    func finish() {
        if case .downloaded = modelState {
            applySelection?(selectedModelID)
        }
        defaults.set(true, forKey: Self.completedKey)
        onFinish?()
    }
}
