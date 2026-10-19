import Foundation
import Testing
@testable import Macomprendo

private let base = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
private let zoom = CallApp(name: "Zoom", bundleIDPrefix: "us.zoom.xos", kind: .app)
private let chrome = CallApp(name: "Google Chrome", bundleIDPrefix: "com.google.Chrome",
                             kind: .browser)

@Suite struct AutoCallRecordPolicyTests {
    @Test func aCallLastingThreeSecondsStartsAndFifteenQuietSecondsStop() {
        var policy = AutoCallRecordPolicy()

        #expect(policy.observe(zoom, at: at(0), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(1), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(2), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(3), recorderBusy: false) == .start(zoom))

        for second in 4...9 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: true) == nil)
        }
        #expect(policy.observe(nil, at: at(10), recorderBusy: true) == nil)
        #expect(policy.observe(nil, at: at(20), recorderBusy: true) == nil)
        #expect(policy.observe(nil, at: at(24), recorderBusy: true) == nil)
        #expect(policy.observe(nil, at: at(25), recorderBusy: true) == .stop)
        #expect(policy.observe(nil, at: at(26), recorderBusy: false) == nil)
    }

    @Test func aTwoSecondBlipStartsNothing() {
        var policy = AutoCallRecordPolicy()

        #expect(policy.observe(zoom, at: at(0), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(1), recorderBusy: false) == nil)
        #expect(policy.observe(nil, at: at(2), recorderBusy: false) == nil)

        // A second run of exactly two seconds is still shorter than the 3 s filter.
        #expect(policy.observe(zoom, at: at(10), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(12), recorderBusy: false) == nil)
        #expect(policy.observe(nil, at: at(13), recorderBusy: false) == nil)
    }

    @Test func aShortGapKeepsTheRecording() {
        var policy = AutoCallRecordPolicy()
        #expect(policy.observe(zoom, at: at(0), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(3), recorderBusy: false) == .start(zoom))

        for second in 4...9 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: true) == nil)
        }
        // The microphone is released while muted for ten seconds, then the call resumes.
        #expect(policy.observe(nil, at: at(10), recorderBusy: true) == nil)
        #expect(policy.observe(nil, at: at(20), recorderBusy: true) == nil)
        #expect(policy.observe(zoom, at: at(21), recorderBusy: true) == nil)
        #expect(policy.observe(zoom, at: at(30), recorderBusy: true) == nil)
    }

    @Test func aManualRecordingIsNeverStopped() {
        var policy = AutoCallRecordPolicy()

        // The user records before the call starts.
        #expect(policy.observe(nil, at: at(0), recorderBusy: true) == nil)
        for second in 10...40 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: true) == nil)
        }
        for second in 41...60 {
            #expect(policy.observe(nil, at: at(Double(second)), recorderBusy: true) == nil)
        }
    }

    @Test func aBusyRecorderIsNeverStartedOver() {
        var policy = AutoCallRecordPolicy()

        for second in 0...10 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: true) == nil)
        }
    }

    @Test func aHandStopIsRespectedUntilTheCallIsOver() {
        var policy = AutoCallRecordPolicy()
        #expect(policy.observe(zoom, at: at(0), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(3), recorderBusy: false) == .start(zoom))
        for second in 4...9 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: true) == nil)
        }

        // The user stops the automatic recording by hand; the call goes on.
        #expect(policy.observe(zoom, at: at(10), recorderBusy: false) == nil)
        for second in 11...19 {
            #expect(policy.observe(zoom, at: at(Double(second)), recorderBusy: false) == nil)
        }

        // The call ends; the suppression is re-armed only after fifteen quiet seconds.
        for second in 20...34 {
            #expect(policy.observe(nil, at: at(Double(second)), recorderBusy: false) == nil)
        }
        #expect(policy.observe(nil, at: at(35), recorderBusy: false) == nil)

        // A new call records again.
        #expect(policy.observe(zoom, at: at(40), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(42), recorderBusy: false) == nil)
        #expect(policy.observe(zoom, at: at(43), recorderBusy: false) == .start(zoom))
    }

    @Test func switchingAppsMidCallIsOneCall() {
        var policy = AutoCallRecordPolicy()
        var decisions: [AutoCallRecordPolicy.Decision] = []

        for second in 0...3 {
            if let decision = policy.observe(zoom, at: at(Double(second)), recorderBusy: false) {
                decisions.append(decision)
            }
        }
        // The user hangs up in Zoom and joins the same call in Chrome: no quiet second between.
        for second in 4...20 {
            let call = second < 5 ? zoom : chrome
            if let decision = policy.observe(call, at: at(Double(second)), recorderBusy: true) {
                decisions.append(decision)
            }
        }

        #expect(decisions == [.start(zoom)])
    }
}
