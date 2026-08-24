import Foundation
import Testing
@testable import Macomprendo

@Suite struct WAVEncoderTests {

    @Test func producesTheExactBytesForAFourSampleFile() {
        let data = WAVEncoder.encode(pcm: [0.0, 1.0, -1.0, 0.5], sampleRate: 16_000)

        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,   // "RIFF"
            0x2C, 0x00, 0x00, 0x00,   // ChunkSize = 36 + 8 = 44
            0x57, 0x41, 0x56, 0x45,   // "WAVE"
            0x66, 0x6D, 0x74, 0x20,   // "fmt "
            0x10, 0x00, 0x00, 0x00,   // Subchunk1Size = 16
            0x01, 0x00,               // AudioFormat = 1 (PCM)
            0x01, 0x00,               // NumChannels = 1
            0x80, 0x3E, 0x00, 0x00,   // SampleRate = 16000
            0x00, 0x7D, 0x00, 0x00,   // ByteRate = 32000
            0x02, 0x00,               // BlockAlign = 2
            0x10, 0x00,               // BitsPerSample = 16
            0x64, 0x61, 0x74, 0x61,   // "data"
            0x08, 0x00, 0x00, 0x00,   // Subchunk2Size = 8
            0x00, 0x00,               //  0.0 ->      0
            0xFF, 0x7F,               //  1.0 ->  32767
            0x00, 0x80,               // -1.0 -> -32768
            0xFF, 0x3F                //  0.5 ->  16383
        ]

        #expect(Array(data) == expected)
    }

    @Test func headerIsExactlyFortyFourBytesAndDataIsTwoBytesPerSample() {
        let data = WAVEncoder.encode(pcm: Array(repeating: 0.25, count: 100), sampleRate: 16_000)
        #expect(data.count == 44 + 200)
    }

    @Test func encodesAnEmptyBufferAsAValidHeaderOnly() {
        let data = WAVEncoder.encode(pcm: [], sampleRate: 16_000)
        #expect(data.count == 44)
        #expect(Array(data[4..<8]) == [0x24, 0x00, 0x00, 0x00])   // ChunkSize = 36
        #expect(Array(data[40..<44]) == [0x00, 0x00, 0x00, 0x00]) // Subchunk2Size = 0
    }

    @Test func writesSampleRateAndByteRateForOtherRates() {
        let data = WAVEncoder.encode(pcm: [0.0], sampleRate: 44_100)
        #expect(Array(data[24..<28]) == [0x44, 0xAC, 0x00, 0x00])  // 44100
        #expect(Array(data[28..<32]) == [0x88, 0x58, 0x01, 0x00])  // 88200
    }

    @Test func clampsSamplesOutsideTheNormalisedRangeInsteadOfOverflowing() {
        let data = WAVEncoder.encode(pcm: [2.5, -3.0], sampleRate: 16_000)
        #expect(Array(data[44..<46]) == [0xFF, 0x7F])   //  32767
        #expect(Array(data[46..<48]) == [0x00, 0x80])   // -32768
    }

    @Test func mapsNaNToSilenceInsteadOfTrappingAndStillClampsInfinities() {
        // A NaN sample compares false against every bound, so it slips through
        // `min`/`max` clamping untouched; feeding it to `Int16(_:)` unguarded
        // aborts the process. ±infinity already clamps correctly.
        let data = WAVEncoder.encode(pcm: [.nan, .infinity, -.infinity], sampleRate: 16_000)
        #expect(Array(data[44..<46]) == [0x00, 0x00])   //  NaN ->      0
        #expect(Array(data[46..<48]) == [0xFF, 0x7F])   // +inf ->  32767
        #expect(Array(data[48..<50]) == [0x00, 0x80])   // -inf -> -32768
    }

    @Test func roundTripsThroughAVAudioFileReadableStructure() throws {
        // Sanity check that the bytes are a file macOS itself accepts.
        let data = WAVEncoder.encode(pcm: [0.1, -0.1, 0.2, -0.2], sampleRate: 16_000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wav-encoder-\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reread = try Data(contentsOf: url)
        #expect(Array(reread[0..<4]) == Array("RIFF".utf8))
        #expect(Array(reread[8..<12]) == Array("WAVE".utf8))
        #expect(reread.count == data.count)
    }
}
