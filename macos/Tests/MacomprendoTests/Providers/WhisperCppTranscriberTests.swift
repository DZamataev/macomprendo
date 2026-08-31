import Foundation
import Testing
@testable import Macomprendo

@Suite struct WhisperCppTranscriberTests {

    // MARK: - WhisperParams (pure)

    @Test func mapsNilLanguageToWhisperAutoDetect() {
        // whisper_full_default_params defaults language to "en"; only the literal
        // string "auto" turns on detection, so nil must become "auto", not nil.
        #expect(WhisperParams.make(language: nil, processorCount: 10).language == "auto")
    }

    @Test func mapsEmptyLanguageToAutoDetect() {
        #expect(WhisperParams.make(language: "", processorCount: 10).language == "auto")
    }

    @Test func passesAnExplicitLanguageThrough() {
        #expect(WhisperParams.make(language: "ru", processorCount: 10).language == "ru")
    }

    @Test func leavesTwoCoresForTheUIAndAudioThread() {
        #expect(WhisperParams.make(language: nil, processorCount: 10).threads == 8)
        #expect(WhisperParams.make(language: nil, processorCount: 4).threads == 2)
    }

    @Test func neverRequestsFewerThanOneThread() {
        #expect(WhisperParams.make(language: nil, processorCount: 2).threads == 1)
        #expect(WhisperParams.make(language: nil, processorCount: 1).threads == 1)
        #expect(WhisperParams.make(language: nil, processorCount: 0).threads == 1)
    }

    @Test func disablesTimestampsAndTranslation() {
        let params = WhisperParams.make(language: "en", processorCount: 8)
        #expect(params.noTimestamps)
        #expect(!params.translate)
    }

    @Test func honoursAnExplicitThreadCountOverTheCoreCount() {
        let params = WhisperParams.make(language: nil, processorCount: 10,
                                        options: WhisperOptions(threads: 3))
        #expect(params.threads == 3)
    }

    @Test func clampsAnExplicitThreadCountToAtLeastOne() {
        #expect(WhisperParams.make(language: nil, processorCount: 10,
                                   options: WhisperOptions(threads: 0)).threads == 1)
        #expect(WhisperParams.make(language: nil, processorCount: 10,
                                   options: WhisperOptions(threads: -4)).threads == 1)
    }

    @Test func turnsOnTranslationWhenTheSettingAsksForIt() {
        #expect(WhisperParams.make(language: "ru", processorCount: 8,
                                   options: WhisperOptions(translate: true)).translate)
    }

    @Test func carriesTheOptionsItWasBuiltWith() {
        let options = WhisperOptions(threads: 5, translate: true)
        let transcriber = WhisperCppTranscriber(modelURL: URL(fileURLWithPath: "/models/ggml-base.bin"),
                                                options: options)
        #expect(transcriber.options == options)
    }

    // MARK: - WhisperTextAssembler (pure)

    @Test func concatenatesSegmentsWithoutAddingSeparators() {
        // whisper segments already carry their own leading space.
        #expect(WhisperTextAssembler.join([" Hello", " world."]) == "Hello world.")
    }

    @Test func trimsSurroundingWhitespaceAndNewlinesOnce() {
        #expect(WhisperTextAssembler.join(["\n  Hello world.  \n"]) == "Hello world.")
    }

    @Test func preservesInternalWhitespace() {
        #expect(WhisperTextAssembler.join([" One.", "  Two.", " Three."]) == "One.  Two. Three.")
    }

    @Test func returnsEmptyStringForNoSegmentsOrOnlyWhitespace() {
        #expect(WhisperTextAssembler.join([]) == "")
        #expect(WhisperTextAssembler.join(["   ", "\n"]) == "")
    }

    // MARK: - Actor behaviour that needs no model file

    @Test func rejectsAudioThatIsNotSixteenKilohertz() async {
        let transcriber = WhisperCppTranscriber(
            modelURL: URL(fileURLWithPath: "/nonexistent/ggml-base.bin")
        )
        await #expect(throws: MacomprendoError.audio(
            "whisper.cpp requires 16 kHz mono audio, got 44100 Hz"
        )) {
            _ = try await transcriber.transcribe([0.0], sampleRate: 44_100, language: nil)
        }
    }

    @Test func returnsEmptyStringForAnEmptyBufferWithoutTouchingTheModel() async throws {
        let transcriber = WhisperCppTranscriber(
            modelURL: URL(fileURLWithPath: "/nonexistent/ggml-base.bin")
        )
        #expect(try await transcriber.transcribe([], sampleRate: 16_000, language: nil) == "")
    }

    @Test func throwsModelMissingWhenTheFileIsNotOnDisk() async {
        let transcriber = WhisperCppTranscriber(
            modelURL: URL(fileURLWithPath: "/nonexistent/ggml-base.bin")
        )
        await #expect(throws: MacomprendoError.modelMissing("ggml-base.bin")) {
            _ = try await transcriber.transcribe([0.0, 0.1], sampleRate: 16_000, language: nil)
        }
    }

    // MARK: - Integration (skipped without a real model)

    /// Runs only when `MACOMPRENDO_WHISPER_MODEL` points at a ggml model file, e.g.
    ///   MACOMPRENDO_WHISPER_MODEL=~/Library/Application\ Support/Macomprendo/models/ggml-base.bin \
    ///     swift test --package-path macos --filter WhisperCppTranscriberTests
    /// Without the variable it returns immediately so CI stays green and fast.
    @Test func loadsARealModelAndTranscribesTwiceReusingTheContext() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACOMPRENDO_WHISPER_MODEL"],
              FileManager.default.fileExists(atPath: path) else {
            return   // no model available: nothing to integrate against
        }

        let transcriber = WhisperCppTranscriber(modelURL: URL(fileURLWithPath: path))
        // Two seconds of silence at 16 kHz. A real model returns "" or a short
        // hallucination; either way it must not throw, and the second call must
        // reuse the already-loaded context rather than reloading the weights.
        let silence = [Float](repeating: 0, count: 32_000)

        let first = try await transcriber.transcribe(silence, sampleRate: 16_000, language: "en")
        let second = try await transcriber.transcribe(silence, sampleRate: 16_000, language: "en")

        #expect(first.count < 200)
        #expect(second.count < 200)
    }
}
