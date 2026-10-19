import Foundation
import Testing
@testable import Macomprendo

private func process(_ pid: pid_t, _ bundleID: String?, input: Bool = false,
                     output: Bool = false) -> AudioProcessActivity {
    AudioProcessActivity(pid: pid, bundleID: bundleID, isRunningInput: input,
                         isRunningOutput: output)
}

@Suite struct CallAppTests {
    @Test func anAppUsingTheMicrophoneIsTheActiveCall() {
        let zoom = CallApp.defaults.first { $0.name == "Zoom" }!
        let processes = [process(10, "us.zoom.xos", input: true)]

        #expect(CallApp.activeCall(in: processes, apps: CallApp.defaults, excludingPID: 99) == zoom)
    }

    @Test func anAppPlayingWithoutTheMicrophoneIsNoCall() {
        let processes = [process(10, "us.zoom.xos", output: true)]

        #expect(CallApp.activeCall(in: processes, apps: CallApp.defaults, excludingPID: 99) == nil)
    }

    @Test func aBrowserNeedsMicrophoneAndOutputAcrossItsProcesses() {
        let chrome = CallApp(name: "Google Chrome", bundleIDPrefix: "com.google.Chrome",
                             kind: .browser)
        let call = [process(10, "com.google.Chrome", output: true),
                    process(11, "com.google.Chrome.helper", input: true)]

        #expect(CallApp.activeCall(in: call, apps: [chrome], excludingPID: 99) == chrome)
        #expect(CallApp.activeCall(in: [call[1]], apps: [chrome], excludingPID: 99) == nil)
    }

    @Test func thePrefixMatchesOnlyAtADotBoundary() {
        let teams = CallApp(name: "Microsoft Teams (classic)",
                            bundleIDPrefix: "com.microsoft.teams", kind: .app)
        let chrome = CallApp(name: "Google Chrome", bundleIDPrefix: "com.google.Chrome",
                             kind: .browser)

        #expect(teams.matches(bundleID: "com.microsoft.teams"))
        #expect(teams.matches(bundleID: "com.microsoft.teams.helper"))
        #expect(!teams.matches(bundleID: "com.microsoft.teams2"))
        #expect(chrome.matches(bundleID: "com.google.Chrome.helper"))
        #expect(!chrome.matches(bundleID: "com.google.Chromex"))
    }

    @Test func ourOwnProcessNeverMatches() {
        let processes = [process(42, "us.zoom.xos", input: true)]

        #expect(CallApp.activeCall(in: processes, apps: CallApp.defaults, excludingPID: 42) == nil)
    }

    @Test func theFirstListedAppWins() {
        let first = CallApp(name: "First", bundleIDPrefix: "com.example.first", kind: .app)
        let second = CallApp(name: "Second", bundleIDPrefix: "com.example.second", kind: .app)
        let processes = [process(1, "com.example.second", input: true),
                         process(2, "com.example.first", input: true)]

        #expect(CallApp.activeCall(in: processes, apps: [first, second], excludingPID: 99) == first)
    }

    @Test func aProcessWithoutBundleIDNeverMatches() {
        let processes = [process(1, nil, input: true)]

        #expect(CallApp.activeCall(in: processes, apps: CallApp.defaults, excludingPID: 99) == nil)
    }

    @Test func defaultsHaveUniquePrefixesAndBothKinds() {
        let prefixes = CallApp.defaults.map(\.bundleIDPrefix)

        #expect(Set(prefixes).count == prefixes.count)
        #expect(Set(CallApp.defaults.map(\.kind)) == [.app, .browser])
        #expect(!CallApp.defaults.isEmpty)
    }
}
