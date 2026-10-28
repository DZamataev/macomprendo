import Foundation

/// Turns recorded audio into text. Implemented locally by `WhisperCppTranscriber`
/// and remotely by `OpenAICompatibleTranscriber`.
protocol TranscriptionProvider: Sendable {
    /// - Parameters:
    ///   - pcm: mono samples normalised to `-1.0...1.0`.
    ///   - sampleRate: samples per second; the app records at 16000.
    ///   - language: ISO-639-1 code, or `nil` to auto-detect.
    /// - Returns: the transcript, already trimmed of surrounding whitespace.
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String

    /// The same transcription, with the language the recogniser detected — `nil` when it was
    /// told the language or cannot tell. Only whisper.cpp reports one; the phantom gate never
    /// acts on `nil` (spec `2026-10-28-phantom-gate-and-call-speakers`).
    func recognise(_ pcm: [Float], sampleRate: Int, language: String?) async throws
        -> RecognisedSpeech
}

/// A transcription and the language it was detected in.
struct RecognisedSpeech: Sendable, Equatable {
    let text: String
    /// ISO-639-1, e.g. `ru`; `nil` when nothing was detected.
    let language: String?
}

extension TranscriptionProvider {
    func recognise(_ pcm: [Float], sampleRate: Int, language: String?) async throws
        -> RecognisedSpeech {
        RecognisedSpeech(text: try await transcribe(pcm, sampleRate: sampleRate,
                                                    language: language),
                         language: nil)
    }
}
