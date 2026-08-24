import Foundation
import Testing
@testable import Macomprendo

private struct StubError: LocalizedError {
    var errorDescription: String? { "the login item is disabled in System Settings" }
}

@MainActor
@Suite struct GeneralTabModelTests {
    @Test func reconcilePullsSettingsToMatchTheSystemWhenTheyDisagree() {
        let manager = FakeLaunchAtLogin(enabled: true)
        let viewModel = GeneralTabModel(manager: manager)
        var settings = Settings.default
        settings.launchAtLogin = false

        viewModel.reconcile(settings: &settings)

        #expect(settings.launchAtLogin == true)
    }

    @Test func reconcileLeavesSettingsUntouchedWhenTheyAlreadyAgree() {
        let manager = FakeLaunchAtLogin(enabled: false)
        let viewModel = GeneralTabModel(manager: manager)
        var settings = Settings.default
        settings.launchAtLogin = false

        viewModel.reconcile(settings: &settings)

        #expect(settings.launchAtLogin == false)
        #expect(manager.setCalls.isEmpty)
    }

    @Test func setLaunchAtLoginUpdatesSettingsAndClearsAnyPriorError() {
        let manager = FakeLaunchAtLogin(enabled: false)
        let viewModel = GeneralTabModel(manager: manager)
        var settings = Settings.default
        settings.launchAtLogin = false

        viewModel.setLaunchAtLogin(true, settings: &settings)

        #expect(settings.launchAtLogin == true)
        #expect(viewModel.launchAtLoginError == nil)
        #expect(manager.setCalls == [true])
    }

    @Test func setLaunchAtLoginSurfacesTheThrownErrorAndLeavesSettingsUntouched() {
        let manager = FakeLaunchAtLogin(enabled: false)
        manager.errorToThrow = StubError()
        let viewModel = GeneralTabModel(manager: manager)
        var settings = Settings.default
        settings.launchAtLogin = false

        viewModel.setLaunchAtLogin(true, settings: &settings)

        #expect(settings.launchAtLogin == false)
        #expect(viewModel.launchAtLoginError?.contains("the login item is disabled in System Settings") == true)
    }
}
