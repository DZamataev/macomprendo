import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechReadinessTests {

    private func settings(_ mutate: (inout SpeechSettings) -> Void = { _ in }) -> SpeechSettings {
        var s = SpeechSettings()
        mutate(&s)
        return s
    }

    // MARK: - System

    @Test func theSystemSourceIsAlwaysReady() {
        #expect(SpeechReadiness.of(source: .system, settings: settings(), modelStates: [:]) == .ready)
    }

    @Test func theSystemSourceIsReadyWithNoVoiceChosen() {
        // AVFoundation falls back to the system default voice, so speech is heard. Reporting
        // "not ready" here would be a lie the user cannot act on.
        let s = settings { $0.voiceID = nil }
        #expect(SpeechReadiness.of(source: .system, settings: s, modelStates: [:]) == .ready)
    }

    // MARK: - Local

    @Test func theLocalSourceNeedsAModelToBeChosen() {
        let s = settings { $0.localModelID = nil }
        let readiness = SpeechReadiness.of(source: .local, settings: s, modelStates: [:])
        #expect(readiness == .notReady(reason: "No voice has been chosen yet.", fix: .selectModel))
    }

    @Test func theLocalSourceIsReadyOnceItsModelIsDownloaded() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .downloaded])
        #expect(readiness == .ready)
    }

    @Test func anUndownloadedLocalModelOffersItsDownload() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .notDownloaded])
        #expect(readiness == .notReady(reason: "This voice has not been downloaded yet.",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    @Test func aModelWithNoRecordedStateReadsAsNotDownloaded() {
        // The states dictionary is populated asynchronously; an absent key means "not seen on
        // disk", which is the same actionable situation as a known-absent model.
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s, modelStates: [:])
        #expect(readiness == .notReady(reason: "This voice has not been downloaded yet.",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    @Test func aDownloadInProgressReportsProgressAndOffersNoButton() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .downloading(fraction: 0.42)])
        #expect(readiness == .notReady(reason: "Downloading… 42%", fix: nil))
    }

    @Test func aFailedDownloadReportsItsMessageAndOffersARetry() {
        let s = settings { $0.localModelID = "piper-ru" }
        let readiness = SpeechReadiness.of(source: .local, settings: s,
                                           modelStates: ["piper-ru": .failed("Checksum mismatch")])
        #expect(readiness == .notReady(reason: "Checksum mismatch",
                                       fix: .downloadModel(id: "piper-ru")))
    }

    // MARK: - Endpoint

    @Test func aFullyConfiguredEndpointIsReadyWithoutAnyProbe() {
        // Deliberately weaker than Dictation's rule: this claims "configured", not "verified".
        // A wrong key surfaces at the first hotkey press through the existing error toast.
        let s = settings { $0.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount }
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:]) == .ready)
    }

    @Test func anEndpointWithNoSavedKeyIsNotReady() {
        let s = settings { $0.endpointAPIKeyRef = nil }
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                == .notReady(reason: "No API key is saved for this server.", fix: .saveKey))
    }

    @Test func anEndpointMissingAFieldIsNotReady() {
        for mutate in [{ (s: inout SpeechSettings) in s.endpointModel = "" },
                       { (s: inout SpeechSettings) in s.endpointVoice = "  " }] {
            var s = SpeechSettings()
            s.endpointAPIKeyRef = SpeechSettings.endpointKeychainAccount
            mutate(&s)
            #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                    == .notReady(reason: "The server, model and voice must all be filled in.",
                                 fix: .fillEndpoint))
        }
    }

    @Test func aMissingFieldIsReportedBeforeAMissingKey() {
        // One fix button, so the order must be defined: fill the form, then save the key.
        var s = SpeechSettings()
        s.endpointModel = ""
        s.endpointAPIKeyRef = nil
        #expect(SpeechReadiness.of(source: .endpoint, settings: s, modelStates: [:])
                == .notReady(reason: "The server, model and voice must all be filled in.",
                             fix: .fillEndpoint))
    }
}
