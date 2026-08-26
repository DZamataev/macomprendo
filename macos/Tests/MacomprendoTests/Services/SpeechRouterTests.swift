import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechRouterTests {
    private struct Rig {
        let router: SpeechRouter
        let system: ScriptedSpeech
        let endpoint: ScriptedSpeech
    }

    private func rig() -> Rig {
        let system = ScriptedSpeech()
        system.available = [Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default")]
        let endpoint = ScriptedSpeech()
        endpoint.available = [Voice(id: "alloy", name: "alloy", language: "endpoint", quality: "premium")]
        return Rig(router: SpeechRouter(system: system, endpoint: endpoint),
                   system: system, endpoint: endpoint)
    }

    private func settings(_ source: SpeechSource) -> SpeechSettings {
        SpeechSettings(voiceID: "en.alex", source: source)
    }

    @Test func speakGoesToTheSystemBackendByDefault() {
        let r = rig()
        r.router.speak("hello", settings: settings(.system))
        #expect(r.system.spoken.map(\.text) == ["hello"])
        #expect(r.endpoint.spoken.isEmpty)
    }

    @Test func speakGoesToTheEndpointBackendWhenSelected() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        #expect(r.endpoint.spoken.map(\.text) == ["hello"])
        #expect(r.system.spoken.isEmpty)
        // Switching source mid-utterance must not orphan the other backend's audio.
        #expect(r.system.stopCount == 1)
    }

    @Test func stopStopsBothBackends() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        r.router.stop()
        #expect(r.system.stopCount == 2)   // once on speak, once on stop
        #expect(r.endpoint.stopCount == 1)
    }

    @Test func isSpeakingIsTrueWhenEitherBackendSpeaks() {
        let r = rig()
        #expect(!r.router.isSpeaking)
        r.router.speak("hello", settings: settings(.endpoint))
        #expect(r.router.isSpeaking)
        r.endpoint.finish()
        #expect(!r.router.isSpeaking)
    }

    @Test func stateChangesFromBothBackendsAreRepublished() {
        let r = rig()
        var changes = 0
        r.router.onStateChange = { changes += 1 }
        r.system.finish()
        r.endpoint.finish()
        #expect(changes == 2)
    }

    @Test func errorsFromBothBackendsAreRepublished() {
        let r = rig()
        var errors: [Error] = []
        r.router.onError = { errors.append($0) }
        r.system.failWith(MacomprendoError.audioPlayback("x"))
        r.endpoint.failWith(MacomprendoError.speechKeyMissing)
        #expect(errors.count == 2)
        #expect(errors.last as? MacomprendoError == .speechKeyMissing)
    }

    @Test func voicesForASourceIgnoreTheCurrentSelection() {
        let r = rig()
        #expect(r.router.voices(for: .system).map(\.id) == ["en.alex"])
        #expect(r.router.voices(for: .endpoint).map(\.id) == ["alloy"])
        // A plain backend only knows its own catalog, whatever source is asked for.
        #expect(r.endpoint.voices(for: .system).map(\.id) == ["alloy"])
    }
}
