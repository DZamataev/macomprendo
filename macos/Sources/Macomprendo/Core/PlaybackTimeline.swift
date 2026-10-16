import Foundation

/// Which segment the playhead is on. Segments arrive sorted by `start` (the store orders them so).
struct PlaybackTimeline: Equatable, Sendable {
    /// How long the marker stays on a segment after its end, so a short breath does not blink it.
    static let grace: TimeInterval = 1
    /// No stored segment is longer than this, so the backward scan can stop here.
    static let lookback: TimeInterval = 120

    private let starts: [TimeInterval]
    private let ends: [TimeInterval]

    init(segments: [TranscriptSegment]) {
        starts = segments.map(\.start)
        ends = segments.map(\.end)
    }

    /// The latest-starting segment with `start ≤ position ≤ end + grace`, or nil.
    func activeIndex(at position: TimeInterval) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= position { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, starts[index] >= position - Self.lookback {
            if position <= ends[index] + Self.grace { return index }
            index -= 1
        }
        return nil
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour; anything not finite or negative is `0:00`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
