import Foundation

/// A stretch of one voice to transcribe as one segment.
struct PlannedTurn: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// 1-based, numbered by first appearance: what the transcript prints as `Speaker N`.
    let voice: Int
}

/// Turns diarization turns into the stretches a call's Others track is transcribed by: one
/// voice's turns are merged across short pauses, no stretch outgrows what the recogniser takes
/// at once, and voices get the numbers people read. Pure.
enum SpeakerTurnPlanner {
    /// One voice's turns closer than this share a stretch — the spike's choice, short enough
    /// that a reply from someone else always falls between them.
    static let mergeGap: TimeInterval = 0.8
    /// The longest stretch: `SpeechSegmentSplitter.maximumDuration`, what long audio feeds the
    /// recogniser at once.
    static let maximumDuration: TimeInterval = SpeechSegmentSplitter.maximumDuration

    static func plan(_ turns: [SpeakerTurn]) -> [PlannedTurn] {
        let ordered = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var voices: [Int: Int] = [:]
        var runs: [PlannedTurn] = []
        for turn in ordered {
            let voice = voices[turn.speaker] ?? {
                voices[turn.speaker] = voices.count + 1
                return voices.count
            }()
            if let last = runs.last, last.voice == voice,
               turn.start - last.end < mergeGap,
               max(last.end, turn.end) - last.start <= maximumDuration {
                runs[runs.count - 1] = PlannedTurn(start: last.start,
                                                   end: max(last.end, turn.end), voice: voice)
            } else {
                runs.append(PlannedTurn(start: turn.start, end: turn.end, voice: voice))
            }
        }
        return runs.flatMap(cut)
    }

    /// A single turn longer than the limit, cut into equal pieces under it.
    private static func cut(_ run: PlannedTurn) -> [PlannedTurn] {
        let length = run.end - run.start
        let pieces = max(1, Int((length / maximumDuration).rounded(.up)))
        let step = length / Double(pieces)
        return (0..<pieces).map { (index: Int) -> PlannedTurn in
            let start: Double = run.start + Double(index) * step
            let end: Double = index == pieces - 1 ? run.end : start + step
            return PlannedTurn(start: start, end: end, voice: run.voice)
        }
    }
}
