import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct OnboardingViewModelTests {
    private func makeModel(permissions: FakePermissions = FakePermissions(),
                           models: StubModelManager = StubModelManager(),
                           detector: FakeOllamaDetector = FakeOllamaDetector(),
                           defaults: UserDefaults? = nil) -> OnboardingViewModel {
        OnboardingViewModel(permissions: permissions,
                            models: models,
                            detector: detector,
                            defaults: defaults ?? UserDefaults(suiteName: "test.onboarding.\(UUID().uuidString)")!)
    }

    @Test func startsOnTheMicrophoneStepWithTheDefaultModelSelected() {
        let viewModel = makeModel()
        #expect(viewModel.step == .microphone)
        #expect(viewModel.selectedModelID == ModelCatalog.defaultID)
        #expect(viewModel.selectedModelID == "large-v3-turbo")
    }

    @Test func refreshReadsBothPermissionStatuses() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .granted
        permissions.statuses[.accessibility] = .denied
        let viewModel = makeModel(permissions: permissions)

        await viewModel.refresh()
        #expect(viewModel.micStatus == .granted)
        #expect(viewModel.accessibilityStatus == .denied)
    }

    @Test func grantingTheMicrophoneUpdatesTheStatus() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .undetermined
        permissions.requestResults[.microphone] = .granted
        let viewModel = makeModel(permissions: permissions)

        await viewModel.requestMicrophone()
        #expect(viewModel.micStatus == .granted)
        #expect(permissions.openedPanes.isEmpty)
        #expect(viewModel.canContinue == true)
    }

    @Test func aDeniedMicrophoneOpensSystemSettingsAndBlocksContinuing() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .denied
        permissions.requestResults[.microphone] = .denied
        let viewModel = makeModel(permissions: permissions)

        await viewModel.requestMicrophone()
        #expect(viewModel.micStatus == .denied)
        #expect(permissions.openedPanes == [.microphone])
        #expect(viewModel.canContinue == false)
    }

    @Test func aDeniedAccessibilityPermissionOpensSystemSettings() async {
        let permissions = FakePermissions()
        permissions.statuses[.accessibility] = .denied
        permissions.requestResults[.accessibility] = .denied
        let viewModel = makeModel(permissions: permissions)

        await viewModel.requestAccessibility()
        #expect(viewModel.accessibilityStatus == .denied)
        #expect(permissions.openedPanes == [.accessibility])
    }

    @Test func downloadingTheSelectedModelReportsProgressThenCompletion() async {
        let models = StubModelManager()
        models.downloadFractions = [0.5, 1.0]
        let viewModel = makeModel(models: models)

        await viewModel.downloadSelectedModel()
        if case .downloaded = viewModel.modelState {
            // expected
        } else {
            Issue.record("expected .downloaded, got \(viewModel.modelState)")
        }
    }

    @Test func aFailedDownloadIsReported() async {
        let models = StubModelManager()
        models.downloadError = MacomprendoError.modelDownloadFailed("checksum mismatch")
        let viewModel = makeModel(models: models)

        await viewModel.downloadSelectedModel()
        #expect(viewModel.modelState
                == .failed(ErrorText.describe(MacomprendoError.modelDownloadFailed("checksum mismatch"))))
    }

    @Test func detectingOllamaProbesLocalhost() async {
        let detector = FakeOllamaDetector()
        detector.isRunningResult = true
        let viewModel = makeModel(detector: detector)

        await viewModel.detectOllama()
        #expect(viewModel.ollamaFound == true)
        #expect(detector.probed == [URL(string: "http://localhost:11434")!])
    }

    @Test func aMissingOllamaIsReportedWithoutFailing() async {
        let detector = FakeOllamaDetector()
        detector.isRunningResult = false
        let viewModel = makeModel(detector: detector)

        await viewModel.detectOllama()
        #expect(viewModel.ollamaFound == false)
    }

    @Test func nextAndBackWalkThroughTheSteps() {
        let viewModel = makeModel()
        viewModel.next()
        #expect(viewModel.step == .accessibility)
        viewModel.next()
        #expect(viewModel.step == .model)
        viewModel.back()
        #expect(viewModel.step == .accessibility)
    }

    @Test func nextOnTheLastStepFinishes() {
        let defaults = UserDefaults(suiteName: "test.onboarding.\(UUID().uuidString)")!
        let viewModel = makeModel(defaults: defaults)
        let finished = Counter()
        viewModel.onFinish = { finished.increment() }

        viewModel.next()   // accessibility
        viewModel.next()   // model
        viewModel.next()   // ollama
        viewModel.next()   // finish
        #expect(finished.count == 1)
        #expect(defaults.bool(forKey: OnboardingViewModel.completedKey) == true)
        #expect(OnboardingViewModel.shouldShow(defaults: defaults) == false)
    }

    @Test func onboardingShowsOnAFreshInstall() {
        let defaults = UserDefaults(suiteName: "test.onboarding.\(UUID().uuidString)")!
        #expect(OnboardingViewModel.shouldShow(defaults: defaults) == true)
    }

    @Test func onlyPermissionStepsBlockContinuing() {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .denied
        let viewModel = makeModel(permissions: permissions)
        viewModel.next()   // accessibility
        viewModel.next()   // model — optional
        #expect(viewModel.canContinue == true)
    }
}
