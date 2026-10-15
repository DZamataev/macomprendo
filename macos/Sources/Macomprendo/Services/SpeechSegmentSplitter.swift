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
/// A span is split only when it is longer than `maximumDuration + minimumRemainder` (35 s): the
/// cut is the quietest frame of the last `searchWindow` seconds before the 30 s cap, so every
/// piece is 5–35 s. A span up to 35 s reaches the recogniser whole, because a thin remainder of
/// padding and outro music is what whisper invents credit lines from (issue #25).
///
/// Silero VAD's own `max_speech_duration` only raises its threshold to *encourage* a split; on
/// 70 s of continuous speech it returned one 70 s segment with the limit at 25 s and at 10 s.
/// The cap therefore lives here instead.
enum SpeechSegmentSplitter {
    static let maximumDuration: TimeInterval = 30
    /// The shortest remainder a cut may leave: a span is split only when it is longer than
    /// `maximumDuration + minimumRemainder` (35 s). The cut stays the quietest frame of the last
    /// `searchWindow` seconds before `maximumDuration`, so every piece is 5–35 s — except a whole
    /// span that was short to begin with, which is never split. The 2.9 s tail that whisper
    /// large-v3-turbo turned into "Субтитры сделал DimaTorzok" (issue #25) is why: it held only
    /// padding, outro music and a 0.84 s VAD blip, and whisper.cpp v1.9.2 reported a no-speech
    /// probability of 0.000 for it, so segmentation, not a threshold, had to prevent it.
    static let minimumRemainder: TimeInterval = 5
    static let searchWindow: TimeInterval = 5
    static let minimumDuration: TimeInterval = 0.3
    /// 20 ms at 16 kHz: short enough to land between words, long enough to average out a
    /// single loud sample.
    static let frameDuration: TimeInterval = 0.02

    /// Drops segments shorter than `minimumDuration` and splits each longer than
    /// `maximumDuration + minimumRemainder` at its quietest frame inside the last `searchWindow`
    /// seconds before the cap, repeating while the remainder is still over the threshold. Every
    /// piece is at least `minimumRemainder` long; a whole span that was shorter to begin with is
    /// never split at all.
    static func split(_ segment: SpeechSegment) -> [SpeechSegment] {
        guard segment.duration >= minimumDuration else { return [] }
        let rate = Double(segment.sampleRate)
        let cap = Int(maximumDuration * rate)
        let remainder = Int(minimumRemainder * rate)
        let frame = max(1, Int(frameDuration * rate))
        let window = Int(searchWindow * rate)

        var pieces: [SpeechSegment] = []
        var offset = 0
        let samples = segment.samples
        while samples.count - offset > cap + remainder {
            let quietest = quietestCut(in: samples, offset: offset, cap: cap, frame: frame,
                                       window: window)
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

    /// The cut point a piece starting at `offset` should take when it reaches the cap: the middle
    /// of the quietest `frame`-sample frame in the last `window` samples before `offset + cap`,
    /// or `offset + cap` itself when no frame fits.
    ///
    /// Among equally quiet frames the latest wins (`<=`), so uniform speech is cut as close to
    /// the cap as possible rather than a window early.
    static func quietestCut(in samples: [Float], offset: Int, cap: Int, frame: Int,
                            window: Int) -> Int {
        let searchStart = offset + cap - window
        var quietest = offset + cap
        var quietestEnergy = Float.greatestFiniteMagnitude
        var frameStart = searchStart
        while frameStart + frame <= offset + cap {
            var energy: Float = 0
            for index in frameStart..<(frameStart + frame) {
                energy += samples[index] * samples[index]
            }
            if energy <= quietestEnergy {
                quietestEnergy = energy
                quietest = frameStart + frame / 2
            }
            frameStart += frame
        }
        return quietest
    }
}
