import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SherpaOfflineTranscriberTests {

    private let model = URL(fileURLWithPath: "/models/m.onnx")
    private let tokens = URL(fileURLWithPath: "/models/t.txt")
    private let encoder = URL(fileURLWithPath: "/models/e.onnx")
    private let decoder = URL(fileURLWithPath: "/models/d.onnx")
    private let joiner = URL(fileURLWithPath: "/models/j.onnx")

    @Test func aCTCFileSetPlansACTCConfig() {
        #expect(SherpaOfflineConfigPlan.make(from: [.ctcModel: model, .tokens: tokens])
                == .ctc(model: model, tokens: tokens))
    }

    @Test func aTransducerFileSetPlansATransducerConfig() {
        let plan = SherpaOfflineConfigPlan.make(from: [
            .encoder: encoder, .decoder: decoder, .joiner: joiner, .tokens: tokens
        ])
        #expect(plan == .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens))
    }

    @Test func anIncompleteFileSetPlansNothing() {
        #expect(SherpaOfflineConfigPlan.make(from: [.ctcModel: model]) == nil)
        #expect(SherpaOfflineConfigPlan.make(from: [.encoder: encoder, .tokens: tokens]) == nil)
        #expect(SherpaOfflineConfigPlan.make(from: [:]) == nil)
    }

    @Test func aGGMLFileSetIsNotAGigaAMModel() {
        #expect(SherpaOfflineConfigPlan.make(from: [.ggml: model]) == nil)
    }

    @Test func tokensComeLastInTheRequiredFiles() {
        // The C bridging relies on this order: tokens is always the final pointer.
        let ctc = SherpaOfflineConfigPlan.ctc(model: model, tokens: tokens)
        #expect(ctc.requiredFiles == [model, tokens])
        let rnnt = SherpaOfflineConfigPlan.transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        #expect(rnnt.requiredFiles == [encoder, decoder, joiner, tokens])
    }

    @Test func constructionRejectsAFileSetItCannotPlan() {
        #expect(throws: MacomprendoError.self) {
            _ = try SherpaOfflineTranscriber(files: [.ctcModel: model])
        }
    }

    @Test func rejectsAudioThatIsNotSixteenKilohertz() async throws {
        let transcriber = try SherpaOfflineTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.self) {
            _ = try await transcriber.transcribe([0.1, 0.2], sampleRate: 44_100, language: nil)
        }
    }

    @Test func emptyAudioTranscribesToEmptyTextWithoutLoadingTheModel() async throws {
        // Nothing exists at the fake path, so reaching the loader would throw modelMissing.
        let transcriber = try SherpaOfflineTranscriber(files: [.ctcModel: model, .tokens: tokens])
        #expect(try await transcriber.transcribe([], sampleRate: 16_000, language: nil) == "")
    }

    @Test func reportsTheMissingFileWhenTheModelIsNotOnDisk() async throws {
        let transcriber = try SherpaOfflineTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.modelMissing("m.onnx")) {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }

    // MARK: - Integration (skipped without a real model)

    /// Runs only when `MACOMPRENDO_PARAKEET_DIR` holds the four Parakeet files as sherpa names
    /// them (`encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`) and
    /// 16 kHz mono WAVs under `test_wavs/`. Prints each transcript so a person can judge it;
    /// asserts only what a TDT-decoded transcript must have — words, and Parakeet's own
    /// punctuation. A TDT joiner decoded as a plain transducer produces neither.
    @Test func parakeetTranscribesRealSpeechWithPunctuation() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACOMPRENDO_PARAKEET_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: path)
        let transcriber = try SherpaOfflineTranscriber(files: [
            .encoder: directory.appendingPathComponent("encoder.int8.onnx"),
            .decoder: directory.appendingPathComponent("decoder.int8.onnx"),
            .joiner: directory.appendingPathComponent("joiner.int8.onnx"),
            .tokens: directory.appendingPathComponent("tokens.txt"),
        ])
        let wavs = try FileManager.default
            .contentsOfDirectory(at: directory.appendingPathComponent("test_wavs"),
                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        try #require(!wavs.isEmpty)

        for wav in wavs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1 else { continue }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                count: Int(buffer.frameLength)))

            let text = try await transcriber.transcribe(pcm, sampleRate: 16_000, language: nil)
            print("PARAKEET \(wav.lastPathComponent): \(text)")
            #expect(text.split(separator: " ").count >= 3, "\(wav.lastPathComponent): \(text)")
            #expect(text.contains { ".,?!".contains($0) }, "\(wav.lastPathComponent): \(text)")
        }
    }
}
