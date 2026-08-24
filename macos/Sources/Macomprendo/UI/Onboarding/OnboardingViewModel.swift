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
        case microphone, accessibility, model, ollama

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
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
        case .model, .ollama: true
        }
    }

    func refresh() async {
        micStatus = await permissions.status(of: .microphone)
        accessibilityStatus = await permissions.status(of: .accessibility)
        modelState = await models.state(of: selectedModelID)
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
