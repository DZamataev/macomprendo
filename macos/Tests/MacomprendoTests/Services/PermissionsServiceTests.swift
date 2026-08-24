import Foundation
import Testing
@testable import Macomprendo

@Suite struct PrivacyPaneTests {
    @Test func microphoneOpensThePrivacyMicrophonePane() {
        #expect(PrivacyPane.url(for: .microphone).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @Test func accessibilityOpensThePrivacyAccessibilityPane() {
        #expect(PrivacyPane.url(for: .accessibility).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
}

@Suite struct FakePermissionsTests {
    @Test func reportsScriptedStatusAndRecordsRequests() async {
        let permissions = FakePermissions()
        permissions.statuses[.microphone] = .denied
        permissions.requestResults[.microphone] = .granted

        #expect(await permissions.status(of: .microphone) == .denied)
        #expect(await permissions.request(.microphone) == .granted)
        #expect(permissions.requested == [.microphone])
        #expect(await permissions.status(of: .microphone) == .granted)
    }

    @Test func recordsOpenedPanes() {
        let permissions = FakePermissions()
        permissions.openSystemSettings(for: .accessibility)
        #expect(permissions.openedPanes == [.accessibility])
    }

    @Test func defaultsToGrantedSoControllerTestsStayShort() async {
        let permissions = FakePermissions()
        #expect(await permissions.status(of: .microphone) == .granted)
        #expect(await permissions.status(of: .accessibility) == .granted)
    }
}
