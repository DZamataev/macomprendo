import Foundation

/// Wraps normalised Float32 PCM in a canonical 44-byte-header WAV file
/// (RIFF/WAVE, one 16-byte `fmt ` chunk, one `data` chunk), 16-bit mono.
/// Remote transcription endpoints want a real audio file, not raw samples.
enum WAVEncoder {

    private static let bitsPerSample = 16
    private static let channels = 1

    /// - Parameters:
    ///   - pcm: samples in `-1.0...1.0`; anything outside is clamped.
    ///   - sampleRate: samples per second, e.g. 16000.
    static func encode(pcm: [Float], sampleRate: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = pcm.count * blockAlign

        var data = Data(capacity: 44 + dataSize)

        // RIFF header
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(ascii: "WAVE")

        // fmt chunk (16-byte PCM variant)
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))                    // PCM, uncompressed
        data.append(littleEndian: UInt16(channels))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(byteRate))
        data.append(littleEndian: UInt16(blockAlign))
        data.append(littleEndian: UInt16(bitsPerSample))

        // data chunk
        data.append(ascii: "data")
        data.append(littleEndian: UInt32(dataSize))
        for sample in pcm {
            data.append(littleEndian: UInt16(bitPattern: int16(from: sample)))
        }

        return data
    }

    /// Signed 16-bit PCM spans -32768...32767, so the negative side scales by 32768
    /// and the positive side by 32767. Clamping keeps a hot mic from trapping.
    private static func int16(from sample: Float) -> Int16 {
        let clamped = min(max(sample, -1.0), 1.0)
        return Int16(clamped < 0 ? clamped * 32768.0 : clamped * 32767.0)
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
