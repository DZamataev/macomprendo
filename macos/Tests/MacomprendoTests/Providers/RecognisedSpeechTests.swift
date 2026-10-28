import Foundation
import Testing
@testable import Macomprendo

@Suite struct RecognisedSpeechTests {
    /// A provider that only knows `transcribe`, like every one but whisper.cpp.
    private struct TextOnly: TranscriptionProvider {
        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            "привет"
        }
    }

    @Test func aProviderThatCannotTellTheLanguageReportsNone() async throws {
        let speech = try await TextOnly().recognise([0], sampleRate: 16_000, language: nil)
        #expect(speech == RecognisedSpeech(text: "привет", language: nil))
    }

    /// A provider that detects a language, as whisper.cpp does.
    private struct Detecting: TranscriptionProvider {
        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            "*Sigh*"
        }
        func recognise(_ pcm: [Float], sampleRate: Int, language: String?) async throws
            -> RecognisedSpeech {
            RecognisedSpeech(text: "*Sigh*", language: "en")
        }
    }

    @Test func theLaneKeepsTheDetectedLanguage() async throws {
        let provider = LaneTranscriptionProvider(base: Detecting(), lane: TranscriptionLane(),
                                                 priority: .background)
        #expect(try await provider.recognise([0], sampleRate: 16_000, language: nil).language
                == "en")
    }

    @MainActor @Test func theLocalModelLeaseKeepsTheDetectedLanguage() async throws {
        let cache = LocalTranscriptionProviderCache()
        let configuration = LocalTranscriptionProviderCache.Configuration(
            source: .local(modelID: "base"), whisper: WhisperOptions())
        cache.configure(configuration: configuration, idleTimeout: .tenMinutes)
        let lease = cache.provider(Detecting(), configuration: configuration)
        #expect(try await lease.recognise([0], sampleRate: 16_000, language: nil).language == "en")
    }

    @Test func whisperLanguageCodesAreKeptOnlyForAutoDetection() {
        #expect(WhisperParams.reportedLanguage(requested: "auto", detected: "ru") == "ru")
        // A language the caller fixed is not a detection: the gate must not act on it.
        #expect(WhisperParams.reportedLanguage(requested: "en", detected: "en") == nil)
        #expect(WhisperParams.reportedLanguage(requested: "auto", detected: nil) == nil)
        #expect(WhisperParams.reportedLanguage(requested: "auto", detected: "") == nil)
    }
}
