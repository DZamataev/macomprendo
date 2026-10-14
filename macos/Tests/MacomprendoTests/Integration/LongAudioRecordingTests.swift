import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

/// Opt-in regression test on a real recording: the operator's own file through the whole real
/// pipeline — `AVAssetMediaDecoder` → `SherpaSileroSegmenter` → `WhisperCppTranscriber` via
/// `LongAudioPipeline`. It exists because operator acceptance lost two phrases at VAD segment
/// boundaries on a real 78 s Russian voice-over, which synthetic test audio never caught.
///
/// Disabled unless the operator points it at a recording and a list of phrases to look for:
///
///     MACOMPRENDO_LONG_AUDIO_FIXTURE=<audio or video path>
///     MACOMPRENDO_LONG_AUDIO_EXPECT=<UTF-8 file, one expected phrase per line>
///     MACOMPRENDO_LONG_AUDIO_LANGUAGE=<ISO-639-1>                  (optional)
///     MACOMPRENDO_LONG_AUDIO_MODEL=<whisper ggml model path>       (optional)
///
/// The model defaults to `~/Library/Application Support/Macomprendo/models/ggml-large-v3-turbo.bin`.
/// The recording and the phrases stay outside the repository.
@Suite struct LongAudioRecordingTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static let fixtureURL = environment["MACOMPRENDO_LONG_AUDIO_FIXTURE"]
        .map { URL(fileURLWithPath: $0) }
    private static let expectURL = environment["MACOMPRENDO_LONG_AUDIO_EXPECT"]
        .map { URL(fileURLWithPath: $0) }
    private static let modelURL = environment["MACOMPRENDO_LONG_AUDIO_MODEL"]
        .map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Macomprendo/models/ggml-large-v3-turbo.bin")
    private static let language = environment["MACOMPRENDO_LONG_AUDIO_LANGUAGE"]

    private static var isConfigured: Bool {
        guard let fixtureURL, let expectURL,
              FileManager.default.fileExists(atPath: fixtureURL.path),
              FileManager.default.fileExists(atPath: expectURL.path),
              FileManager.default.fileExists(atPath: modelURL.path) else { return false }
        return true
    }

    @Test("a real recording transcribes every expected phrase",
          .enabled(if: LongAudioRecordingTests.isConfigured))
    func realRecordingContainsEveryExpectedPhrase() async throws {
        let fixture = try #require(Self.fixtureURL)
        let expectations = try #require(Self.expectURL)

        let pipeline = LongAudioPipeline(decoder: AVAssetMediaDecoder(),
                                         segmenter: SherpaSileroSegmenter(),
                                         transcriber: {
                                             WhisperCppTranscriber(modelURL: Self.modelURL)
                                         },
                                         language: Self.language)
        var segments: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        for try await event in pipeline.run(fixture, from: 0) {
            if case .segment(let start, let end, let text) = event {
                segments.append((start, end, text))
            }
        }
        // The stream is finished, but its task may still hold the transcriber. whisper.cpp v1.9.2
        // asserts in a Metal static destructor when the context is still alive as swift-testing
        // calls exit() — a pre-existing teardown issue, not something this test adds. Give the
        // task a moment to release it so the process exits cleanly.
        try await Task.sleep(for: .seconds(2))

        // Both sides are normalised the way a human comparing them would: case, `ё`→`е`,
        // punctuation dropped, whitespace collapsed.
        let transcript = Self.normalise(segments.map(\.text).joined(separator: " "))
        let expected = try String(contentsOf: expectations, encoding: .utf8)
            .split(whereSeparator: { $0.isNewline })
            .map { Self.normalise(String($0)) }
            .filter { !$0.isEmpty }
        let missing = expected.filter { !transcript.contains($0) }
        let boundaries = segments
            .map { String(format: "%.2f\u{2013}%.2f", $0.start, $0.end) }
            .joined(separator: ", ")

        print("LongAudioRecording segment boundaries: \(boundaries)")
        print("LongAudioRecording joined transcript: \(transcript)")

        #expect(missing.isEmpty,
                "missing phrases: \(missing.joined(separator: " | ")); segments: \(boundaries)")
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
