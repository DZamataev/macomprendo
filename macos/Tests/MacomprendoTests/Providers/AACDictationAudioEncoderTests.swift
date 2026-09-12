import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite("AAC dictation audio encoder")
struct AACDictationAudioEncoderTests {

    private let sampleRate = 16_000

    /// A three-second sine sweep, the same 16 kHz mono the recorder produces.
    private func sweep(seconds: Double = 3.0) -> [Float] {
        let frames = Int(Double(sampleRate) * seconds)
        return (0..<frames).map { index in
            let t = Double(index) / Double(sampleRate)
            let frequency = 220.0 + (2_000.0 - 220.0) * (t / seconds)
            return Float(0.5 * sin(2.0 * Double.pi * frequency * t))
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-encoder-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func encodingASweepProducesAReadable16kHzMonoM4A() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        let pcm = sweep()

        try await AACDictationAudioEncoder().encode(pcm, sampleRate: sampleRate, to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        // AAC pads the start with priming frames and the end up to a packet boundary.
        let difference = abs(Int(file.length) - pcm.count)
        #expect(difference < 4_096, "frame count \(file.length) against \(pcm.count)")
    }

    @Test func theEncodedFileIsAFractionOfTheEquivalentWAV() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        let pcm = sweep()

        try await AACDictationAudioEncoder().encode(pcm, sampleRate: sampleRate, to: url)

        let encoded = try Data(contentsOf: url).count
        let wav = WAVEncoder.encode(pcm: pcm, sampleRate: sampleRate).count
        #expect(encoded > 0)
        #expect(Double(encoded) < Double(wav) * 0.25, "\(encoded) bytes against \(wav) WAV bytes")
    }

    @Test func encodingCreatesIntermediateDirectories() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("clip.m4a")

        try await AACDictationAudioEncoder().encode(sweep(seconds: 0.5),
                                                    sampleRate: sampleRate, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anUnwritableDestinationSurfacesAsAMacomprendoError() async throws {
        let url = URL(fileURLWithPath: "/dev/null/x.m4a")

        await #expect(throws: MacomprendoError.self) {
            try await AACDictationAudioEncoder().encode(self.sweep(seconds: 0.5),
                                                        sampleRate: self.sampleRate, to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aDestinationOccupiedByADirectorySurfacesAsAMacomprendoError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        await #expect(throws: MacomprendoError.self) {
            try await AACDictationAudioEncoder().encode(self.sweep(seconds: 0.5),
                                                        sampleRate: self.sampleRate, to: url)
        }
    }

    @Test func emptySamplesSurfaceAsAMacomprendoError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.m4a")

        await #expect(throws: MacomprendoError.self) {
            try await AACDictationAudioEncoder().encode([], sampleRate: self.sampleRate, to: url)
        }
    }

    @Test func theFakeRecordsWhatItWasAskedToEncode() async throws {
        let fake = FakeDictationAudioEncoder()
        let url = temporaryDirectory().appendingPathComponent("clip.m4a")

        try await fake.encode([0, 0, 0], sampleRate: 16_000, to: url)

        let requests = await fake.requests
        #expect(requests == [.init(pcm: [0, 0, 0], sampleRate: 16_000, url: url)])
    }

    @Test func theAudioEncodingErrorDescribesFailureAndRecovery() {
        let error = MacomprendoError.audioEncoding("disk full")
        #expect(error.errorDescription?.contains("disk full") == true)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }
}
