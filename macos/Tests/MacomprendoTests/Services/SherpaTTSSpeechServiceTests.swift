import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SherpaTTSSpeechServiceTests {
    private struct Rig {
        let service: SherpaTTSService
        let manager: StubModelManager
        let generator: FakeLocalSpeechGenerator
        let player: FakeAudioPlayer
        let model: LocalModel
    }

    private func rig(chunkCharacterLimit: Int = 6) -> Rig {
        let model = ModelCatalog.all(kind: .tts).first { $0.id == "vits-piper-ru_RU-ruslan-medium" }!
        let manager = StubModelManager()
        manager.states[model.id] = .downloaded
        manager.resolvedEngines[model.id] = model.engine
        manager.resolvedDirectories[model.id] = URL(fileURLWithPath: "/tmp/\(model.id)", isDirectory: true)
        let generator = FakeLocalSpeechGenerator()
        let player = FakeAudioPlayer()
        return Rig(
            service: SherpaTTSService(
                modelManager: manager,
                generator: generator,
                player: player,
                catalog: [model],
                chunkCharacterLimit: chunkCharacterLimit
            ),
            manager: manager,
            generator: generator,
            player: player,
            model: model
        )
    }

    private func settings(_ model: LocalModel, speakerID: Int = 0, speed: Float = 1) -> SpeechSettings {
        SpeechSettings(
            source: .local,
            localModelID: model.id,
            localSpeakerID: speakerID,
            localSpeed: speed
        )
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func chunksGenerateAndPlayCanonicalWAVInOrder() async {
        let r = rig()
        r.service.speak("One. Two. Three.", settings: settings(r.model, speed: 1.25))
        await r.service.drain()

        let requests = await r.generator.requests
        #expect(requests.map(\.text) == ["One.", "Two.", "Three."])
        #expect(requests.allSatisfy {
            $0.configuration.modelID == r.model.id
                && $0.configuration.engine == .sherpaVits
                && $0.configuration.speakerID == 0
                && $0.configuration.speed == 1.25
        })
        let expected = WAVEncoder.encode(pcm: [0, 0.5, -0.5], sampleRate: 22_050)
        #expect(r.player.played == [expected, expected, expected])
        #expect(!r.service.isSpeaking)
    }

    @Test func nextChunkGeneratesWhileTheCurrentChunkPlays() async {
        let r = rig(chunkCharacterLimit: 6)
        r.player.finishesImmediately = false
        r.service.speak("One. Two.", settings: settings(r.model))

        for _ in 0..<50 {
            if r.player.played.count == 1, await r.generator.requests.count == 2 { break }
            await Task.yield()
        }

        #expect(r.player.played.count == 1)
        #expect(await r.generator.requests.map(\.text) == ["One.", "Two."])
        r.player.finishCurrent()
        await settle()
        #expect(r.player.played.count == 2)
        r.player.finishCurrent()
        await r.service.drain()
    }

    @Test func speakingStateLastsUntilPlaybackFinishesByItself() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        var changes = 0
        r.service.onStateChange = { changes += 1 }

        r.service.speak("Hello.", settings: settings(r.model))
        await settle()
        #expect(r.service.isSpeaking)
        #expect(r.player.played.count == 1)

        r.player.finishCurrent()
        await r.service.drain()
        #expect(!r.service.isSpeaking)
        #expect(changes == 2)
    }

    @Test func pauseAndResumeDriveTheCurrentPlayer() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        r.service.speak("Hello.", settings: settings(r.model))
        await settle()

        r.service.pause()
        #expect(r.service.isPaused)
        #expect(r.player.pauseCount == 1)

        r.service.resume()
        #expect(!r.service.isPaused)
        #expect(r.player.resumeCount == 1)
        r.service.stop()
    }

    @Test func pauseDuringGenerationHoldsTheFirstBufferUntilResume() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        await r.generator.setGated(true)
        r.service.speak("Hello.", settings: settings(r.model))
        for _ in 0..<50 {
            if await !r.generator.requests.isEmpty { break }
            await Task.yield()
        }

        r.service.pause()
        await r.generator.releaseGate()
        await settle()
        #expect(r.player.played.isEmpty)
        #expect(r.service.isPaused)

        r.service.resume()
        #expect(r.player.played.count == 1)
        r.player.finishCurrent()
        await r.service.drain()
        #expect(!r.service.isSpeaking)
    }

    @Test func stopCancelsPlaybackWithoutPublishingAnError() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }
        r.service.speak("Hello.", settings: settings(r.model))
        await settle()

        r.service.stop()
        await settle()

        #expect(!r.service.isSpeaking)
        #expect(r.player.stopCount >= 1)
        #expect(errors.isEmpty)
    }

    @Test func stopDuringGenerationDropsLateAudioWithoutPublishingAnError() async {
        let r = rig(chunkCharacterLimit: 100)
        await r.generator.setGated(true)
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }
        r.service.speak("Hello.", settings: settings(r.model))
        for _ in 0..<50 {
            if await !r.generator.requests.isEmpty { break }
            await Task.yield()
        }

        r.service.stop()
        await r.generator.releaseGate()
        await settle()

        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
        #expect(errors.isEmpty)
    }

    @Test func supersededGenerationCannotClearTheNewPlaybackState() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        await r.generator.setGated(true)
        r.service.speak("First.", settings: settings(r.model))
        for _ in 0..<50 {
            if await !r.generator.requests.isEmpty { break }
            await Task.yield()
        }

        r.service.speak("Second.", settings: settings(r.model))
        await r.generator.releaseGate()
        for _ in 0..<100 {
            if r.player.played.count == 1 { break }
            await Task.yield()
        }

        #expect(await r.generator.requests.map(\.text) == ["First.", "Second."])
        #expect(r.player.played.count == 1)
        #expect(r.service.isSpeaking)

        r.player.finishCurrent()
        await r.service.drain()
        #expect(!r.service.isSpeaking)
    }

    @Test func generatorFailureIsPublishedOnceAndStopsSpeaking() async {
        let r = rig(chunkCharacterLimit: 100)
        await r.generator.setError(MacomprendoError.modelMissing(r.model.id))
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings(r.model))
        await r.service.drain()

        #expect(errors.map { $0 as? MacomprendoError } == [.modelMissing(r.model.id)])
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func missingResolvedModelFailsBeforeGeneration() async {
        let r = rig(chunkCharacterLimit: 100)
        r.manager.resolvedDirectories = [:]
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings(r.model))
        await r.service.drain()

        #expect(errors.map { $0 as? MacomprendoError } == [.modelMissing(r.model.id)])
        #expect(await r.generator.requests.isEmpty)
    }

    @Test func stalePersistedSpeakerClampsAtTheGenerationBoundary() async {
        let r = rig(chunkCharacterLimit: 100)
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings(r.model, speakerID: 1))
        await r.service.drain()

        #expect(errors.isEmpty)
        #expect(await r.generator.requests.first?.configuration.speakerID == 0)
        #expect(r.player.played.count == 1)
    }

    @Test func aGenerationErrorWhilePausedClearsThePausedState() async {
        let r = rig(chunkCharacterLimit: 100)
        await r.generator.setGated(true)
        r.service.speak("Hello.", settings: settings(r.model))
        for _ in 0..<50 {
            if await !r.generator.requests.isEmpty { break }
            await Task.yield()
        }
        r.service.pause()
        await r.generator.setError(MacomprendoError.modelMissing(r.model.id))
        await r.generator.releaseGate()

        await r.service.drain()

        #expect(!r.service.isSpeaking)
        #expect(!r.service.isPaused)
    }
}

private actor FakeLocalSpeechGenerator: LocalSpeechGenerating {
    struct Request: Sendable {
        let text: String
        let configuration: LocalTTSConfiguration
    }

    private(set) var requests: [Request] = []
    var error: Error?
    private var gated = false
    private var gate: CheckedContinuation<Void, Never>?

    func setError(_ error: Error?) {
        self.error = error
    }

    func setGated(_ gated: Bool) {
        self.gated = gated
    }

    func releaseGate() {
        gated = false
        gate?.resume()
        gate = nil
    }

    func generate(_ text: String, configuration: LocalTTSConfiguration) async throws -> LocalSpeechAudio {
        requests.append(Request(text: text, configuration: configuration))
        if gated {
            await withCheckedContinuation { gate = $0 }
        }
        if let error { throw error }
        return LocalSpeechAudio(samples: [0, 0.5, -0.5], sampleRate: 22_050)
    }
}
