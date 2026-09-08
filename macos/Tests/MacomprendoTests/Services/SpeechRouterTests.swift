import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeechRouterTests {
    private struct Rig {
        let router: SpeechRouter
        let system: ScriptedSpeech
        let local: ScriptedSpeech
        let endpoint: ScriptedSpeech
    }

    private func rig() -> Rig {
        let system = ScriptedSpeech()
        system.available = [Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default")]
        let local = ScriptedSpeech()
        let endpoint = ScriptedSpeech()
        endpoint.available = [Voice(id: "alloy", name: "alloy", language: "endpoint", quality: "premium")]
        return Rig(
            router: SpeechRouter(system: system, local: local, endpoint: endpoint),
            system: system,
            local: local,
            endpoint: endpoint
        )
    }

    private func settings(_ source: SpeechSource) -> SpeechSettings {
        SpeechSettings(voiceID: "en.alex", source: source)
    }

    @Test func speakGoesToTheSystemBackendByDefault() {
        let r = rig()
        r.router.speak("hello", settings: settings(.system))
        #expect(r.system.spoken.map(\.text) == ["hello"])
        #expect(r.local.spoken.isEmpty)
        #expect(r.endpoint.spoken.isEmpty)
    }

    @Test func speakGoesOnlyToTheLocalBackendWhenSelected() {
        let r = rig()
        r.router.speak("hello", settings: settings(.local))
        #expect(r.local.spoken.map(\.text) == ["hello"])
        #expect(r.system.spoken.isEmpty)
        #expect(r.endpoint.spoken.isEmpty)
        #expect(r.system.stopCount == 1)
        #expect(r.endpoint.stopCount == 1)
    }

    @Test func speakGoesToTheEndpointBackendWhenSelected() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        #expect(r.endpoint.spoken.map(\.text) == ["hello"])
        #expect(r.system.spoken.isEmpty)
        #expect(r.local.spoken.isEmpty)
        #expect(r.system.stopCount == 1)
        #expect(r.local.stopCount == 1)
    }

    @Test func stopStopsAllBackends() {
        let r = rig()
        r.router.speak("hello", settings: settings(.endpoint))
        r.router.stop()
        #expect(r.system.stopCount == 2)
        #expect(r.local.stopCount == 2)
        #expect(r.endpoint.stopCount == 1)
    }

    @Test func isSpeakingIsTrueWhenAnyBackendSpeaks() {
        let r = rig()
        #expect(!r.router.isSpeaking)
        r.router.speak("hello", settings: settings(.local))
        #expect(r.router.isSpeaking)
        r.local.finish()
        #expect(!r.router.isSpeaking)
    }

    @Test func stateChangesFromAllBackendsAreRepublished() {
        let r = rig()
        var changes = 0
        r.router.onStateChange = { changes += 1 }
        r.system.finish()
        r.local.finish()
        r.endpoint.finish()
        #expect(changes == 3)
    }

    @Test func errorsFromAllBackendsAreRepublished() {
        let r = rig()
        var errors: [Error] = []
        r.router.onError = { errors.append($0) }
        r.system.failWith(MacomprendoError.audioPlayback("x"))
        r.local.failWith(MacomprendoError.modelMissing("y"))
        r.endpoint.failWith(MacomprendoError.speechKeyMissing)
        #expect(errors.count == 3)
        #expect(errors.last as? MacomprendoError == .speechKeyMissing)
    }

    @Test func voicesForASourceIgnoreTheCurrentSelection() {
        let r = rig()
        #expect(r.router.voices(for: .system).map(\.id) == ["en.alex"])
        #expect(r.router.voices(for: .local).isEmpty)
        #expect(r.router.voices(for: .endpoint).map(\.id) == ["alloy"])
        #expect(r.endpoint.voices(for: .system).map(\.id) == ["alloy"])
    }

    @Test func pauseAndResumeGoToTheActiveBackend() {
        let r = rig()
        r.router.speak("hello", settings: settings(.local))

        r.router.pause()
        #expect(r.local.pauseCount == 1)
        #expect(r.system.pauseCount == 0)
        #expect(r.endpoint.pauseCount == 0)
        #expect(r.router.isPaused)

        r.router.resume()
        #expect(r.local.resumeCount == 1)
        #expect(r.system.resumeCount == 0)
        #expect(r.endpoint.resumeCount == 0)
    }

    @Test func pausingBeforeAnythingIsSpokenTargetsTheSystemBackend() {
        let r = rig()
        r.router.pause()
        #expect(r.system.pauseCount == 1)
        #expect(r.local.pauseCount == 0)
        #expect(r.endpoint.pauseCount == 0)
    }
}
