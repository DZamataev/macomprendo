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

    @Test func generatorReloadsWhenTheResolvedModelChanges() async throws {
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

        #expect(backend.loadCount == 2)
        #expect(backend.loadedModelIDs == ["vits-piper-en_US-lessac-medium", "kokoro-multi-lang-v1_1"])
    }

    @Test func localSpeechErrorHasDescriptionAndRecovery() {
        let error = MacomprendoError.localSpeech("model could not be loaded")

        #expect(error.errorDescription?.contains("model could not be loaded") == true)
        #expect(error.recoverySuggestion?.contains("Models") == true)
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
    private var recordedRequests: [Request] = []

    var loadCount: Int { lock.withLock { recordedModelIDs.count } }
    var loadedModelIDs: [String] { lock.withLock { recordedModelIDs } }
    var requests: [Request] { lock.withLock { recordedRequests } }

    func load(_ identity: SherpaTTSModelIdentity) throws -> any LoadedSherpaTTSModel {
        lock.withLock { recordedModelIDs.append(identity.modelID) }
        return RecordingLoadedSherpaTTS { [weak self] request in
            self?.lock.withLock { self?.recordedRequests.append(request) }
        }
    }
}

private final class RecordingLoadedSherpaTTS: LoadedSherpaTTSModel, @unchecked Sendable {
    private let record: (RecordingSherpaTTSBackend.Request) -> Void

    init(record: @escaping (RecordingSherpaTTSBackend.Request) -> Void) {
        self.record = record
    }

    func generate(text: String, speakerID: Int, speed: Float) throws -> LocalSpeechAudio {
        record(.init(text: text, speakerID: speakerID, speed: speed))
        return LocalSpeechAudio(samples: [0.25], sampleRate: 22_050)
    }
}
