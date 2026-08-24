import Foundation

/// Pure helpers shared by the recorder and the HUD level meter.
enum AudioMath {
    /// Root-mean-square amplitude of a Float32 PCM buffer (0…1 for normalised audio).
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS amplitude to a 0…1 meter value on a dBFS scale.
    /// `floorDB` (default -60 dBFS) and anything quieter maps to 0; full scale maps to 1.
    static func level(fromRMS rms: Float, floorDB: Float = -60) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let normalized = (db - floorDB) / -floorDB
        return min(max(normalized, 0), 1)
    }
}

/// Streaming linear-interpolation resampler for mono Float32 audio.
/// Keeps the fractional read position and the unconsumed tail between calls so
/// consecutive buffers from an audio tap join seamlessly.
struct PCMResampler: Sendable {
    private let ratio: Double
    private var position: Double = 0
    private var pending: [Float] = []

    init(inputRate: Double, outputRate: Double) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        ratio = inputRate / outputRate
    }

    mutating func resample(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var buffer = pending
        buffer.append(contentsOf: input)

        var output: [Float] = []
        output.reserveCapacity(Int(Double(buffer.count) / ratio) + 1)
        while position + 1 < Double(buffer.count) {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            output.append(buffer[index] + (buffer[index + 1] - buffer[index]) * fraction)
            position += ratio
        }

        let consumed = min(Int(position), buffer.count)
        pending = Array(buffer[consumed...])
        position -= Double(consumed)
        return output
    }
}
