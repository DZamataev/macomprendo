import Foundation

/// Pure helpers shared by the recorder and the HUD level meter.
enum AudioMath {
    /// The amplitude below which a recording is treated as containing no speech at all,
    /// in dBFS. Far below the quietest real speech measured in the archive (−26 dBFS) and
    /// far above a working microphone's noise floor (−66 dBFS between words), so this is a
    /// test for "nothing at all", not a judgement about "too quiet".
    static let silenceThresholdDB: Float = -60

    /// `silenceThresholdDB` as a Float32 amplitude (0.001).
    static let silenceThreshold: Float = pow(10, silenceThresholdDB / 20)

    /// Root-mean-square amplitude of a Float32 PCM buffer (0…1 for normalised audio).
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Largest absolute sample value in a Float32 PCM buffer; 0 for an empty buffer.
    ///
    /// Peak rather than RMS because the question is "did the microphone ever produce
    /// anything?": an RMS over a mostly-silent recording holding one loud word sits under
    /// any sensible threshold, and a gate built on it would discard real speech.
    static func peak(_ samples: [Float]) -> Float {
        var maximum: Float = 0
        for sample in samples { maximum = max(maximum, abs(sample)) }
        return maximum
    }

    /// Whether a buffer holds no speech: its peak is below `silenceThreshold`. The
    /// boundary is inclusive upward, so a recording peaking at exactly the threshold is
    /// kept rather than discarded.
    static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < silenceThreshold
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
