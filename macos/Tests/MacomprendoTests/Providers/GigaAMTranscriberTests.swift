import Foundation
import Testing
@testable import Macomprendo

@Suite struct GigaAMTranscriberTests {

    private let model = URL(fileURLWithPath: "/models/m.onnx")
    private let tokens = URL(fileURLWithPath: "/models/t.txt")
    private let encoder = URL(fileURLWithPath: "/models/e.onnx")
    private let decoder = URL(fileURLWithPath: "/models/d.onnx")
    private let joiner = URL(fileURLWithPath: "/models/j.onnx")

    @Test func aCTCFileSetPlansACTCConfig() {
        #expect(GigaAMConfigPlan.make(from: [.ctcModel: model, .tokens: tokens])
                == .ctc(model: model, tokens: tokens))
    }

    @Test func aTransducerFileSetPlansATransducerConfig() {
        let plan = GigaAMConfigPlan.make(from: [
            .encoder: encoder, .decoder: decoder, .joiner: joiner, .tokens: tokens
        ])
        #expect(plan == .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens))
    }

    @Test func anIncompleteFileSetPlansNothing() {
        #expect(GigaAMConfigPlan.make(from: [.ctcModel: model]) == nil)
        #expect(GigaAMConfigPlan.make(from: [.encoder: encoder, .tokens: tokens]) == nil)
        #expect(GigaAMConfigPlan.make(from: [:]) == nil)
    }

    @Test func aGGMLFileSetIsNotAGigaAMModel() {
        #expect(GigaAMConfigPlan.make(from: [.ggml: model]) == nil)
    }

    @Test func tokensComeLastInTheRequiredFiles() {
        // The C bridging relies on this order: tokens is always the final pointer.
        let ctc = GigaAMConfigPlan.ctc(model: model, tokens: tokens)
        #expect(ctc.requiredFiles == [model, tokens])
        let rnnt = GigaAMConfigPlan.transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        #expect(rnnt.requiredFiles == [encoder, decoder, joiner, tokens])
    }

    @Test func constructionRejectsAFileSetItCannotPlan() {
        #expect(throws: MacomprendoError.self) {
            _ = try GigaAMTranscriber(files: [.ctcModel: model])
        }
    }

    @Test func rejectsAudioThatIsNotSixteenKilohertz() async throws {
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.self) {
            _ = try await transcriber.transcribe([0.1, 0.2], sampleRate: 44_100, language: nil)
        }
    }

    @Test func emptyAudioTranscribesToEmptyTextWithoutLoadingTheModel() async throws {
        // Nothing exists at the fake path, so reaching the loader would throw modelMissing.
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        #expect(try await transcriber.transcribe([], sampleRate: 16_000, language: nil) == "")
    }

    @Test func reportsTheMissingFileWhenTheModelIsNotOnDisk() async throws {
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.modelMissing("m.onnx")) {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }
}
