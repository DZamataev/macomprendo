import Foundation

/// A stretch of speech found in a longer recording.
struct SpeechSegment: Sendable, Equatable {
    /// Seconds from the start of the decoded stream.
    let start: TimeInterval
    let samples: [Float]
    let sampleRate: Int

    var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
    var end: TimeInterval { start + duration }
}

/// Caps segment length for the recogniser. Pure.
///
/// Silero VAD's own `max_speech_duration` only raises its threshold to *encourage* a split; on
/// 70 s of continuous speech it returned one 70 s segment with the limit at 25 s and at 10 s.
/// The cap therefore lives here instead.
enum SpeechSegmentSplitter {
    static let maximumDuration: TimeInterval = 30
    static let searchWindow: TimeInterval = 5
    static let minimumDuration: TimeInterval = 0.3
    /// 20 ms at 16 kHz: short enough to land between words, long enough to average out a
    /// single loud sample.
    static let frameDuration: TimeInterval = 0.02

    /// Drops segments shorter than `minimumDuration` and cuts each longer than
    /// `maximumDuration` at its quietest frame inside the last `searchWindow` seconds before
    /// the cap, repeating until every piece fits.
    static func split(_ segment: SpeechSegment) -> [SpeechSegment] {
        guard segment.duration >= minimumDuration else { return [] }
        let rate = Double(segment.sampleRate)
        let cap = Int(maximumDuration * rate)
        let frame = max(1, Int(frameDuration * rate))
        let window = Int(searchWindow * rate)

        var pieces: [SpeechSegment] = []
        var offset = 0
        let samples = segment.samples
        while samples.count - offset > cap {
            let searchStart = offset + cap - window
            var quietest = offset + cap
            var quietestEnergy = Float.greatestFiniteMagnitude
            var frameStart = searchStart
            while frameStart + frame <= offset + cap {
                var energy: Float = 0
                for index in frameStart..<(frameStart + frame) {
                    energy += samples[index] * samples[index]
                }
                // `<=`: among equally quiet frames take the latest, so uniform speech is cut
                // as close to the cap as possible rather than five seconds early.
                if energy <= quietestEnergy {
                    quietestEnergy = energy
                    quietest = frameStart + frame / 2
                }
                frameStart += frame
            }
            pieces.append(SpeechSegment(start: segment.start + Double(offset) / rate,
                                        samples: Array(samples[offset..<quietest]),
                                        sampleRate: segment.sampleRate))
            offset = quietest
        }
        pieces.append(SpeechSegment(start: segment.start + Double(offset) / rate,
                                    samples: Array(samples[offset...]),
                                    sampleRate: segment.sampleRate))
        return pieces.filter { $0.duration >= minimumDuration }
    }
}
