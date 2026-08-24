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
}
