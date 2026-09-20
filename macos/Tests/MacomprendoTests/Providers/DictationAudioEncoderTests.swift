import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite("Dictation audio encoder")
struct DictationAudioEncoderTests {

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
            .appendingPathComponent("dictation-encoder-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The codec actually inside the container. The extension stays `.m4a` for both formats,
    /// so this is the only honest check that the requested one was used. The file is bound to
    /// a local: `streamDescription` points into the format object, which a temporary would
    /// already have released.
    private func audioFormatID(of url: URL) throws -> AudioFormatID {
        let file = try AVAudioFile(forReading: url)
        return file.fileFormat.streamDescription.pointee.mFormatID
    }

    @Test func encodingASweepProducesAReadable16kHzMonoM4A() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        let pcm = sweep()

        try await DictationAudioEncoder().encode(pcm, sampleRate: sampleRate, format: .aac, to: url)

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

        try await DictationAudioEncoder().encode(pcm, sampleRate: sampleRate, format: .aac, to: url)

        let encoded = try Data(contentsOf: url).count
        let wav = WAVEncoder.encode(pcm: pcm, sampleRate: sampleRate).count
        #expect(encoded > 0)
        #expect(Double(encoded) < Double(wav) * 0.25, "\(encoded) bytes against \(wav) WAV bytes")
    }

    // Catches a format argument that is accepted and then ignored.
    @Test func aacProducesAnAACFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")

        try await DictationAudioEncoder().encode(sweep(seconds: 1), sampleRate: sampleRate,
                                                 format: .aac, to: url)

        #expect(try audioFormatID(of: url) == kAudioFormatMPEG4AAC)
    }

    @Test func losslessProducesAnAppleLosslessFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")

        try await DictationAudioEncoder().encode(sweep(seconds: 1), sampleRate: sampleRate,
                                                 format: .lossless, to: url)

        #expect(try audioFormatID(of: url) == kAudioFormatAppleLossless)
    }

    @Test func losslessKeepsTheSampleRateChannelCountAndLength() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        let pcm = sweep()

        try await DictationAudioEncoder().encode(pcm, sampleRate: sampleRate,
                                                 format: .lossless, to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        let difference = abs(Int(file.length) - pcm.count)
        #expect(difference < 4_096, "frame count \(file.length) against \(pcm.count)")
    }

    // The whole point of the option: lossless costs materially more disk for the same audio.
    @Test func aacRemainsTheSmallerFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let aacURL = directory.appendingPathComponent("aac.m4a")
        let losslessURL = directory.appendingPathComponent("lossless.m4a")
        let pcm = sweep()

        try await DictationAudioEncoder().encode(pcm, sampleRate: sampleRate,
                                                 format: .aac, to: aacURL)
        try await DictationAudioEncoder().encode(pcm, sampleRate: sampleRate,
                                                 format: .lossless, to: losslessURL)

        let aacBytes = try Data(contentsOf: aacURL).count
        let losslessBytes = try Data(contentsOf: losslessURL).count
        #expect(aacBytes < losslessBytes, "\(aacBytes) AAC bytes against \(losslessBytes) lossless")
    }

    @Test func encodingCreatesIntermediateDirectories() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("clip.m4a")

        try await DictationAudioEncoder().encode(sweep(seconds: 0.5),
                                                 sampleRate: sampleRate, format: .aac, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anUnwritableDestinationSurfacesAsAMacomprendoError() async throws {
        let url = URL(fileURLWithPath: "/dev/null/x.m4a")

        await #expect(throws: MacomprendoError.self) {
            try await DictationAudioEncoder().encode(self.sweep(seconds: 0.5),
                                                     sampleRate: self.sampleRate,
                                                     format: .aac, to: url)
        }
    }

    @Test func anUnwritableLosslessDestinationAlsoSurfacesAsAMacomprendoError() async throws {
        let url = URL(fileURLWithPath: "/dev/null/x.m4a")

        await #expect(throws: MacomprendoError.self) {
            try await DictationAudioEncoder().encode(self.sweep(seconds: 0.5),
                                                     sampleRate: self.sampleRate,
                                                     format: .lossless, to: url)
        }
    }

    @Test func aDestinationOccupiedByADirectorySurfacesAsAMacomprendoError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.m4a")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        await #expect(throws: MacomprendoError.self) {
            try await DictationAudioEncoder().encode(self.sweep(seconds: 0.5),
                                                     sampleRate: self.sampleRate,
                                                     format: .aac, to: url)
        }
    }

    @Test func emptySamplesSurfaceAsAMacomprendoError() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.m4a")

        await #expect(throws: MacomprendoError.self) {
            try await DictationAudioEncoder().encode([], sampleRate: self.sampleRate,
                                                     format: .aac, to: url)
        }
    }

    @Test func theAudioEncodingErrorDescribesFailureAndRecovery() {
        let error = MacomprendoError.audioEncoding("disk full")
        #expect(error.errorDescription?.contains("disk full") == true)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }
}
