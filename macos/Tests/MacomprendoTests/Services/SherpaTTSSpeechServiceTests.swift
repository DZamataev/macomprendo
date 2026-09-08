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

    private func available(_ model: LocalModel) -> AvailableLocalVoice {
        AvailableLocalVoice(
            model: model,
            resolved: ResolvedLocalModel(
                engine: model.engine,
                files: [:],
                directory: URL(fileURLWithPath: "/tmp/\(model.id)", isDirectory: true)))
    }

    private func mixedService(
        models: [LocalModel],
        detector: any LanguageDetecting,
        chunkCharacterLimit: Int = 1_000
    ) -> (SherpaTTSService, FakeLocalSpeechGenerator, FakeAudioPlayer) {
        let manager = StubModelManager()
        for model in models {
            manager.states[model.id] = .downloaded
            manager.resolvedEngines[model.id] = model.engine
            manager.resolvedDirectories[model.id] = URL(
                fileURLWithPath: "/tmp/\(model.id)", isDirectory: true)
        }
        let generator = FakeLocalSpeechGenerator()
        let player = FakeAudioPlayer()
        return (
            SherpaTTSService(
                modelManager: manager,
                generator: generator,
                player: player,
                detector: detector,
                catalog: models,
                chunkCharacterLimit: chunkCharacterLimit),
            generator,
            player)
    }

    @Test func anExplicitDownloadedLanguageMappingWinsAndClampsItsSpeaker() throws {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")!
        var speech = settings(russian)
        speech.localSegmentationEnabled = true
        speech.localVoiceByLanguage["en"] = LocalVoiceSelection(
            modelID: kokoro.id, speakerID: Int.max)
        let russianText = "Это достаточно длинное русское предложение. "
        let englishText = "This is a sufficiently long English sentence."

        let plan = try SherpaTTSService.localVoicePlan(
            text: russianText + englishText,
            settings: speech,
            available: [available(russian), available(kokoro)],
            detector: ScriptedLanguageDetector([russianText: "ru", englishText: "en"]))

        #expect(plan == [
            PlannedSpeechRun(
                text: russianText,
                selection: LocalVoiceSelection(modelID: russian.id, speakerID: 0)),
            PlannedSpeechRun(
                text: englishText,
                selection: LocalVoiceSelection(modelID: kokoro.id,
                                               speakerID: kokoro.speakerCount - 1)),
        ])
    }

    @Test func availabilitySnapshotKeepsOnlyResolvedDirectoriesWithTheExpectedEngine() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")!
        let manager = StubModelManager()
        manager.resolvedDirectories[russian.id] = URL(
            fileURLWithPath: "/tmp/\(russian.id)", isDirectory: true)
        manager.resolvedEngines[russian.id] = russian.engine
        manager.resolvedDirectories[english.id] = URL(
            fileURLWithPath: "/tmp/\(english.id)", isDirectory: true)
        manager.resolvedEngines[english.id] = .sherpaKokoro
        manager.resolvedEngines[kokoro.id] = kokoro.engine
        let service = SherpaTTSService(
            modelManager: manager,
            generator: FakeLocalSpeechGenerator(),
            player: FakeAudioPlayer(),
            catalog: [russian, english, kokoro])

        let available = await service.availableVoices()

        #expect(available.map(\.model.id) == [russian.id])
    }

    @Test func anIncompatibleMappingFallsThroughToStableDownloadedAuto() throws {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let text = "This is a sufficiently long English sentence."
        var speech = settings(russian)
        speech.localSegmentationEnabled = true
        speech.localVoiceByLanguage["en"] = LocalVoiceSelection(
            modelID: russian.id, speakerID: 0)

        let plan = try SherpaTTSService.localVoicePlan(
            text: text,
            settings: speech,
            available: [available(russian), available(english)],
            detector: ScriptedLanguageDetector([text: "en"]))

        #expect(plan.map(\.selection) == [LocalVoiceSelection(modelID: english.id, speakerID: 0)])
    }

    @Test func aCompatibleDefaultWinsBeforeAnotherDownloadedAutoVoice() throws {
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")!
        let text = "This is a sufficiently long English sentence."
        var speech = settings(kokoro, speakerID: 7)
        speech.localSegmentationEnabled = true

        let plan = try SherpaTTSService.localVoicePlan(
            text: text,
            settings: speech,
            available: [available(english), available(kokoro)],
            detector: ScriptedLanguageDetector([text: "en"]))

        #expect(plan.map(\.selection) == [LocalVoiceSelection(modelID: kokoro.id, speakerID: 7)])
    }

    @Test func anUndetectedForeignScriptUsesTheFirstDownloadedCompatibleVoice() throws {
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let text = "Это достаточно длинное русское предложение."
        var speech = settings(english)
        speech.localSegmentationEnabled = true

        let plan = try SherpaTTSService.localVoicePlan(
            text: text,
            settings: speech,
            available: [available(english), available(russian)],
            detector: ScriptedLanguageDetector())

        #expect(plan.map(\.selection) == [LocalVoiceSelection(modelID: russian.id, speakerID: 0)])
    }

    @Test func anUndetectedArabicRunDoesNotTreatChineseAsScriptCompatible() throws {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")!
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        let plan = try SherpaTTSService.localVoicePlan(
            text: "مرحبا",
            settings: speech,
            available: [available(kokoro), available(russian)],
            detector: ScriptedLanguageDetector())

        #expect(plan.map(\.selection) == [LocalVoiceSelection(modelID: russian.id, speakerID: 0)])
    }

    @Test func aMissingDefaultLocalVoiceStillFailsTheWholePlan() {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let speech = settings(russian)

        #expect(throws: MacomprendoError.modelMissing(russian.id)) {
            try SherpaTTSService.localVoicePlan(
                text: "Hello.", settings: speech, available: [],
                detector: ScriptedLanguageDetector())
        }
    }

    @Test func mixedRussianEnglishRussianTextUsesTheResolvedVoiceForEveryRun() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let first = "Это первое достаточно длинное русское предложение. "
        let middle = "This is a sufficiently long English sentence. "
        let last = "Это второе достаточно длинное русское предложение."
        let detector = ScriptedLanguageDetector([first: "ru", middle: "en", last: "ru"])
        let (service, generator, _) = mixedService(
            models: [russian, english], detector: detector)
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        service.speak(first + middle + last, settings: speech)
        await service.drain()

        let requests = await generator.requests
        #expect(requests.map(\.text) == [
            first.trimmingCharacters(in: .whitespaces),
            middle.trimmingCharacters(in: .whitespaces),
            last,
        ])
        #expect(requests.map(\.configuration.modelID) == [russian.id, english.id, russian.id])
    }

    @Test func englishChineseEnglishCanReuseKokoroWithDifferentSpeakers() async {
        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")!
        let first = "This is the first sufficiently long English sentence. "
        let chinese = "这是一个足够长的中文句子用于语音测试。 "
        let last = "This is the second sufficiently long English sentence."
        let detector = ScriptedLanguageDetector([first: "en", chinese: "zh", last: "en"])
        let (service, generator, _) = mixedService(models: [kokoro], detector: detector)
        var speech = settings(kokoro, speakerID: 7)
        speech.localSegmentationEnabled = true
        speech.localVoiceByLanguage["zh"] = LocalVoiceSelection(
            modelID: kokoro.id, speakerID: 42)

        service.speak(first + chinese + last, settings: speech)
        await service.drain()

        let requests = await generator.requests
        #expect(requests.map(\.configuration.modelID) == [kokoro.id, kokoro.id, kokoro.id])
        #expect(requests.map(\.configuration.speakerID) == [7, 42, 7])
    }

    @Test func nextLanguageRunGeneratesWhileTheCurrentRunPlays() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let first = "Это достаточно длинное русское предложение. "
        let second = "This is a sufficiently long English sentence."
        let (service, generator, player) = mixedService(
            models: [russian, english],
            detector: ScriptedLanguageDetector([first: "ru", second: "en"]))
        player.finishesImmediately = false
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        service.speak(first + second, settings: speech)
        for _ in 0..<100 {
            if player.played.count == 1, await generator.requests.count == 2 { break }
            await Task.yield()
        }

        #expect(player.played.count == 1)
        #expect(await generator.requests.map(\.configuration.modelID) == [russian.id, english.id])
        player.finishCurrent()
        await settle()
        player.finishCurrent()
        await service.drain()
    }

    @Test func mixedLanguagePlanningHappensBeforePerRunChunking() async throws {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let first = "Это первое длинное предложение. Это второе длинное предложение. "
        let second = "This is the first long sentence. This is the second long sentence."
        let (service, generator, _) = mixedService(
            models: [russian, english],
            detector: ScriptedLanguageDetector([first: "ru", second: "en"]),
            chunkCharacterLimit: 24)
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        service.speak(first + second, settings: speech)
        await service.drain()

        let modelIDs = await generator.requests.map(\.configuration.modelID)
        let firstEnglish = try #require(modelIDs.firstIndex(of: english.id))
        #expect(firstEnglish > 0)
        #expect(modelIDs[..<firstEnglish].allSatisfy { $0 == russian.id })
        #expect(modelIDs[firstEnglish...].allSatisfy { $0 == english.id })
    }

    @Test func stopDropsAPrefetchedSecondLanguageRun() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let first = "Это достаточно длинное русское предложение. "
        let second = "This is a sufficiently long English sentence."
        let (service, generator, player) = mixedService(
            models: [russian, english],
            detector: ScriptedLanguageDetector([first: "ru", second: "en"]))
        player.finishesImmediately = false
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        service.speak(first + second, settings: speech)
        for _ in 0..<100 {
            if player.played.count == 1, await generator.requests.count == 2 { break }
            await Task.yield()
        }
        service.stop()
        await service.drain()
        player.finishCurrent()
        await settle()

        #expect(await generator.requests.count == 2)
        #expect(player.played.count == 1)
        #expect(!service.isSpeaking)
    }

    @Test func pauseHoldsAPrefetchedSecondLanguageRunUntilResume() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let english = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let first = "Это достаточно длинное русское предложение. "
        let second = "This is a sufficiently long English sentence."
        let (service, generator, player) = mixedService(
            models: [russian, english],
            detector: ScriptedLanguageDetector([first: "ru", second: "en"]))
        player.finishesImmediately = false
        var speech = settings(russian)
        speech.localSegmentationEnabled = true

        service.speak(first + second, settings: speech)
        for _ in 0..<100 {
            if player.played.count == 1, await generator.requests.count == 2 { break }
            await Task.yield()
        }
        service.pause()
        player.finishCurrent()
        await settle()
        #expect(player.played.count == 1)

        service.resume()
        for _ in 0..<100 where player.played.count < 2 { await Task.yield() }
        #expect(player.played.count == 2)
        player.finishCurrent()
        await service.drain()
    }

    @Test func aDeletedMappedModelFallsBackWithoutFailingLocalSpeech() async {
        let russian = ModelCatalog.model(id: "vits-piper-ru_RU-ruslan-medium")!
        let deletedEnglish = ModelCatalog.model(id: "vits-piper-en_US-lessac-medium")!
        let text = "This is a sufficiently long English sentence."
        let (service, generator, _) = mixedService(
            models: [russian], detector: ScriptedLanguageDetector([text: "en"]))
        var speech = settings(russian)
        speech.localSegmentationEnabled = true
        speech.localVoiceByLanguage["en"] = LocalVoiceSelection(
            modelID: deletedEnglish.id, speakerID: 0)
        var errors: [Error] = []
        service.onError = { errors.append($0) }

        service.speak(text, settings: speech)
        await service.drain()

        #expect(await generator.requests.map(\.configuration.modelID) == [russian.id])
        #expect(errors.isEmpty)
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

    @Test func lateCancellationCleanupCannotStopSupersedingPlayback() async {
        let r = rig(chunkCharacterLimit: 100)
        r.player.finishesImmediately = false
        r.service.speak("First.", settings: settings(r.model))
        for _ in 0..<50 {
            if r.player.played.count == 1 { break }
            await Task.yield()
        }

        r.service.speak("Second.", settings: settings(r.model))
        for _ in 0..<100 {
            if r.player.played.count == 2 { break }
            await Task.yield()
        }
        let stopsBeforeLateCleanup = r.player.stopCount

        r.service.cancelPlayback(for: 1)

        #expect(r.player.stopCount == stopsBeforeLateCleanup)
        #expect(r.player.isPlaying)
        #expect(r.service.isSpeaking)
        r.player.finishCurrent()
        await r.service.drain()
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
