import Foundation
import Testing
@testable import Macomprendo

@Suite struct SherpaTTSGeneratorTests {
    @Test func vitsPlanUsesThePiperArchiveLayout() throws {
        let directory = URL(fileURLWithPath: "/tmp/vits-piper-ru_RU-ruslan-medium")

        #expect(try SherpaTTSModelPlan.make(
            modelID: "vits-piper-ru_RU-ruslan-medium", engine: .sherpaVits, directory: directory
        ) == .vits(
            model: directory.appendingPathComponent("ru_RU-ruslan-medium.onnx"),
            tokens: directory.appendingPathComponent("tokens.txt"),
            dataDirectory: directory.appendingPathComponent("espeak-ng-data", isDirectory: true)
        ))
    }

    @Test func kokoroPlanUsesTheMultilingualArchiveLayout() throws {
        let directory = URL(fileURLWithPath: "/tmp/kokoro")

        #expect(try SherpaTTSModelPlan.make(
            modelID: "kokoro-multi-lang-v1_1", engine: .sherpaKokoro, directory: directory
        ) == .kokoro(
            model: directory.appendingPathComponent("model.onnx"),
            voices: directory.appendingPathComponent("voices.bin"),
            tokens: directory.appendingPathComponent("tokens.txt"),
            dataDirectory: directory.appendingPathComponent("espeak-ng-data", isDirectory: true),
            lexicons: [
                directory.appendingPathComponent("lexicon-us-en.txt"),
                directory.appendingPathComponent("lexicon-zh.txt"),
            ],
            ruleFSTs: [
                directory.appendingPathComponent("phone-zh.fst"),
                directory.appendingPathComponent("date-zh.fst"),
                directory.appendingPathComponent("number-zh.fst"),
            ]
        ))
    }

    @Test func generatorLoadsLazilyAndReusesTheSameModel() async throws {
        let backend = RecordingSherpaTTSBackend()
        let generator = SherpaSpeechGenerator(backend: backend)
        let first = LocalTTSConfiguration(
            modelID: "vits-piper-ru_RU-ruslan-medium", engine: .sherpaVits,
            directory: URL(fileURLWithPath: "/tmp/voice"), speakerID: 0, speed: 1
        )
        let second = LocalTTSConfiguration(
            modelID: "vits-piper-ru_RU-ruslan-medium", engine: .sherpaVits,
            directory: URL(fileURLWithPath: "/tmp/voice"), speakerID: 4, speed: 1.25
        )

        #expect(backend.loadCount == 0)
        #expect(try await generator.generate("one", configuration: first)
                == LocalSpeechAudio(samples: [0.25], sampleRate: 22_050))
        #expect(try await generator.generate("two", configuration: second)
                == LocalSpeechAudio(samples: [0.25], sampleRate: 22_050))
        #expect(backend.loadCount == 1)
        #expect(backend.requests == [
            .init(text: "one", speakerID: 0, speed: 1),
            .init(text: "two", speakerID: 4, speed: 1.25),
        ])
    }

    @Test func generatorRetainsTwoAlternatingModels() async throws {
        let backend = RecordingSherpaTTSBackend()
        let generator = SherpaSpeechGenerator(backend: backend)
        let first = LocalTTSConfiguration(
            modelID: "vits-piper-en_US-lessac-medium", engine: .sherpaVits,
            directory: URL(fileURLWithPath: "/tmp/first"), speakerID: 0, speed: 1
        )
        let second = LocalTTSConfiguration(
            modelID: "kokoro-multi-lang-v1_1", engine: .sherpaKokoro,
            directory: URL(fileURLWithPath: "/tmp/second"), speakerID: 7, speed: 0.9
        )

        _ = try await generator.generate("one", configuration: first)
        _ = try await generator.generate("two", configuration: second)
        _ = try await generator.generate("three", configuration: first)

        #expect(backend.loadCount == 2)
        #expect(backend.loadedModelIDs == ["vits-piper-en_US-lessac-medium", "kokoro-multi-lang-v1_1"])
    }

    @Test func aCacheHitPromotesTheModelBeforeLRUEviction() async throws {
        let backend = RecordingSherpaTTSBackend()
        let generator = SherpaSpeechGenerator(backend: backend, cacheCapacity: 2)
        let a = configuration("vits-piper-en_US-lessac-medium", directory: "/tmp/a")
        let b = configuration("vits-piper-ru_RU-ruslan-medium", directory: "/tmp/b")
        let c = configuration("kokoro-multi-lang-v1_1", engine: .sherpaKokoro, directory: "/tmp/c")

        _ = try await generator.generate("a1", configuration: a)
        _ = try await generator.generate("b1", configuration: b)
        _ = try await generator.generate("a2", configuration: a)
        _ = try await generator.generate("c1", configuration: c)
        _ = try await generator.generate("b2", configuration: b)

        #expect(backend.loadedModelIDs == [a.modelID, b.modelID, c.modelID, b.modelID])
    }

    @Test func aFailedLoadDoesNotEvictUsableCachedModels() async throws {
        let backend = RecordingSherpaTTSBackend()
        let generator = SherpaSpeechGenerator(backend: backend, cacheCapacity: 2)
        let a = configuration("vits-piper-en_US-lessac-medium", directory: "/tmp/a")
        let b = configuration("vits-piper-ru_RU-ruslan-medium", directory: "/tmp/b")
        let c = configuration("kokoro-multi-lang-v1_1", engine: .sherpaKokoro, directory: "/tmp/c")

        _ = try await generator.generate("a1", configuration: a)
        _ = try await generator.generate("b1", configuration: b)
        backend.fail(modelID: c.modelID)
        await #expect(throws: MacomprendoError.modelMissing(c.modelID)) {
            try await generator.generate("c1", configuration: c)
        }
        _ = try await generator.generate("a2", configuration: a)
        _ = try await generator.generate("b2", configuration: b)

        #expect(backend.loadedModelIDs == [a.modelID, b.modelID, c.modelID])
    }

    @Test func evictionReleasesTheNativeModelHandleImmediately() async throws {
        let backend = RecordingSherpaTTSBackend()
        let generator = SherpaSpeechGenerator(backend: backend, cacheCapacity: 2)
        let a = configuration("vits-piper-en_US-lessac-medium", directory: "/tmp/a")
        let b = configuration("vits-piper-ru_RU-ruslan-medium", directory: "/tmp/b")
        let c = configuration(
            "kokoro-multi-lang-v1_1", engine: .sherpaKokoro, directory: "/tmp/c")

        _ = try await generator.generate("a", configuration: a)
        _ = try await generator.generate("b", configuration: b)
        #expect(backend.releasedModelIDs.isEmpty)
        _ = try await generator.generate("c", configuration: c)

        #expect(backend.releasedModelIDs == [a.modelID])
    }

    private func configuration(
        _ modelID: String,
        engine: LocalEngine = .sherpaVits,
        directory: String
    ) -> LocalTTSConfiguration {
        LocalTTSConfiguration(
            modelID: modelID,
            engine: engine,
            directory: URL(fileURLWithPath: directory),
            speakerID: 0,
            speed: 1)
    }

    @Test func anIncompatibleEngineReportsTheExactModelAsMissing() {
        #expect(throws: MacomprendoError.modelMissing("asr-model")) {
            try SherpaTTSModelPlan.make(
                modelID: "asr-model", engine: .whisperCpp,
                directory: URL(fileURLWithPath: "/tmp/asr-model")
            )
        }
    }
}

private final class RecordingSherpaTTSBackend: SherpaTTSBackend, @unchecked Sendable {
    struct Request: Equatable {
        let text: String
        let speakerID: Int
        let speed: Float
    }

    private let lock = NSLock()
    private var recordedModelIDs: [String] = []
    private var recordedReleasedModelIDs: [String] = []
    private var recordedRequests: [Request] = []
    private var failingModelIDs: Set<String> = []

    var loadCount: Int { lock.withLock { recordedModelIDs.count } }
    var loadedModelIDs: [String] { lock.withLock { recordedModelIDs } }
    var releasedModelIDs: [String] { lock.withLock { recordedReleasedModelIDs } }
    var requests: [Request] { lock.withLock { recordedRequests } }

    func fail(modelID: String) {
        _ = lock.withLock { failingModelIDs.insert(modelID) }
    }

    func load(_ identity: SherpaTTSModelIdentity) throws -> any LoadedSherpaTTSModel {
        let shouldFail = lock.withLock {
            recordedModelIDs.append(identity.modelID)
            return failingModelIDs.contains(identity.modelID)
        }
        if shouldFail { throw MacomprendoError.modelMissing(identity.modelID) }
        return RecordingLoadedSherpaTTS(
            record: { [weak self] request in
                self?.lock.withLock { self?.recordedRequests.append(request) }
            },
            onDeinit: { [weak self] in
                self?.lock.withLock { self?.recordedReleasedModelIDs.append(identity.modelID) }
            })
    }
}

private final class RecordingLoadedSherpaTTS: LoadedSherpaTTSModel, @unchecked Sendable {
    private let record: (RecordingSherpaTTSBackend.Request) -> Void
    private let onDeinit: () -> Void

    init(
        record: @escaping (RecordingSherpaTTSBackend.Request) -> Void,
        onDeinit: @escaping () -> Void
    ) {
        self.record = record
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }

    func generate(text: String, speakerID: Int, speed: Float) throws -> LocalSpeechAudio {
        record(.init(text: text, speakerID: speakerID, speed: speed))
        return LocalSpeechAudio(samples: [0.25], sampleRate: 22_050)
    }
}
