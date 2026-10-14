import Foundation

/// Joins nearby VAD regions into speech spans *with the audio between them kept*, pads each span,
/// caps its length and hands out `SpeechSegment`s. Pure: it has no detector dependency — the
/// caller feeds it the sample stream, the completed VAD regions in stream coordinates and whether
/// the detector is still inside speech.
///
/// Rules (spec: *File transcription*, Pipeline step 3):
/// - a region starting at most `joinGap` after the open span's end extends the span, keeping the
///   audio between them, so speech the detector misses (a phrase over music) and a word cut off by
///   a short pause still reach the recogniser with their context;
/// - each span is padded by `padding` on both sides, clamped to the stream;
/// - a span is closed when a region arrives more than `joinGap` after it, when the stream has
///   advanced more than `joinGap` past its end with no new region *and the detector is not inside
///   speech* — while it is, an unreported region may still start inside the join window; or at
///   `finish()`;
/// - a span longer than `SpeechSegmentSplitter.maximumDuration` is cut early at the quietest frame
///   of the last `SpeechSegmentSplitter.searchWindow` seconds before the cap, keeping only the
///   remainder open, so speech never accumulates in memory unboundedly; pieces shorter than
///   `SpeechSegmentSplitter.minimumDuration` are dropped.
///
/// Memory bound: the buffer holds the open span's remainder (under one `maximumDuration` after a
/// cut), plus the samples since the last completed region — the join gap (under `joinGap`) and the
/// one region the detector is still accumulating. For the 20 s regions with 1 s gaps of the
/// memory-bound test that peaks just past 50 s, because a remainder close to the cap can meet a
/// whole next region; `retainedSampleCount` exposes it so a test can assert it directly.
final class SpeechSpanAssembler {
    /// A completed VAD region, in samples from the start of the stream.
    struct Region: Equatable, Sendable {
        let startSample: Int
        let endSample: Int
    }

    /// Regions closer than this to the open span's end extend it, keeping the audio between.
    static let joinGap: TimeInterval = 10
    /// Padding added on both sides of a span, clamped to the stream.
    static let padding: TimeInterval = 0.3
    /// Samples kept while no span is open and the detector is not inside speech: enough for the
    /// next region's leading padding. A region starting further back could only exist if the
    /// detector was inside speech while its audio streamed, which is the other branch.
    static let idleRetention: TimeInterval = 1

    private let sampleRate: Int
    private let joinGapSamples: Int
    private let paddingSamples: Int
    private let capSamples: Int
    private let frameSamples: Int
    private let windowSamples: Int
    private let minimumSamples: Int
    private let idleRetentionSamples: Int

    private var buffer: [Float] = []
    /// Stream sample index of `buffer[0]`.
    private var bufferStart = 0
    private var totalSamples = 0
    private var openSpan: Span?
    /// Stream index at the start of the chunk in which the detector was first seen inside speech;
    /// `nil` while it is not. Keeps the audio of a region that is still being accumulated.
    private var speechRunStart: Int?

    private struct Span {
        /// Where the next piece begins: the padded span start at first, a cut point after a cut.
        var startSample: Int
        /// End of the last completed region in the span, in stream samples.
        var endSample: Int
    }

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        joinGapSamples = Int(Self.joinGap * Double(sampleRate))
        paddingSamples = Int(Self.padding * Double(sampleRate))
        capSamples = Int(SpeechSegmentSplitter.maximumDuration * Double(sampleRate))
        frameSamples = max(1, Int(SpeechSegmentSplitter.frameDuration * Double(sampleRate)))
        windowSamples = Int(SpeechSegmentSplitter.searchWindow * Double(sampleRate))
        minimumSamples = Int(SpeechSegmentSplitter.minimumDuration * Double(sampleRate))
        idleRetentionSamples = Int(Self.idleRetention * Double(sampleRate))
    }

    /// Samples currently held for spans that are not finished yet.
    var retainedSampleCount: Int { buffer.count }

    /// Appends `samples` to the stream and applies the regions the detector completed while
    /// accepting them, in order. Returns the segments this call flushed.
    func accept(samples: [Float],
                regions: [Region],
                speechInProgress: Bool) -> [SpeechSegment] {
        let previousTotal = totalSamples
        buffer.append(contentsOf: samples)
        totalSamples += samples.count

        var segments: [SpeechSegment] = []
        for region in regions {
            segments += apply(region)
        }
        if !speechInProgress, let span = openSpan, totalSamples > span.endSample + joinGapSamples {
            segments += flush(span)
            openSpan = nil
        }
        if speechInProgress {
            if speechRunStart == nil { speechRunStart = previousTotal }
        } else {
            speechRunStart = nil
        }
        trim()
        return segments
    }

    /// Ends the stream: flushes the open span and returns its segments. Everything not handed out
    /// (a piece shorter than the minimum) is dropped with the buffer.
    func finish() -> [SpeechSegment] {
        let segments = openSpan.map(flush) ?? []
        openSpan = nil
        buffer.removeAll(keepingCapacity: false)
        bufferStart = totalSamples
        speechRunStart = nil
        return segments
    }

    // MARK: - Regions

    private func apply(_ region: Region) -> [SpeechSegment] {
        let start = max(0, region.startSample)
        let end = min(region.endSample, totalSamples)
        guard end > start else { return [] }
        guard let span = openSpan else { return open(start: start, end: end) }
        if start <= span.endSample + joinGapSamples {
            openSpan = Span(startSample: span.startSample, endSample: max(span.endSample, end))
            return cutToCap()
        }
        var segments = flush(span)
        openSpan = nil
        segments += open(start: start, end: end)
        return segments
    }

    private func open(start: Int, end: Int) -> [SpeechSegment] {
        let paddedStart = max(bufferStart, start - paddingSamples)
        openSpan = Span(startSample: paddedStart, endSample: end)
        return cutToCap()
    }

    private func flush(_ span: Span) -> [SpeechSegment] {
        let end = min(totalSamples, span.endSample + paddingSamples)
        var segments: [SpeechSegment] = []
        var start = span.startSample
        while end - start > capSamples {
            let cut = cutPoint(from: start)
            if let piece = makeSegment(from: start, to: cut) { segments.append(piece) }
            start = cut
        }
        if let piece = makeSegment(from: start, to: end) { segments.append(piece) }
        return segments
    }

    /// Cuts the open span down whenever it has grown past the cap, keeping only the remainder
    /// open. The cut follows the splitter's rule, measured from the span that is still open.
    private func cutToCap() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        while let span = openSpan, span.endSample - span.startSample > capSamples {
            let cut = cutPoint(from: span.startSample)
            if let piece = makeSegment(from: span.startSample, to: cut) { segments.append(piece) }
            openSpan?.startSample = cut
        }
        return segments
    }

    private func cutPoint(from startSample: Int) -> Int {
        bufferStart + SpeechSegmentSplitter.quietestCut(in: buffer,
                                                        offset: startSample - bufferStart,
                                                        cap: capSamples,
                                                        frame: frameSamples,
                                                        window: windowSamples)
    }

    private func makeSegment(from: Int, to: Int) -> SpeechSegment? {
        let start = max(from, bufferStart)
        let end = min(to, totalSamples)
        guard end > start, end - start >= minimumSamples else { return nil }
        return SpeechSegment(start: Double(start) / Double(sampleRate),
                             samples: Array(buffer[(start - bufferStart)..<(end - bufferStart)]),
                             sampleRate: sampleRate)
    }

    // MARK: - Memory

    /// Drops samples nothing can need any more: while a span is open, everything before its next
    /// piece; otherwise everything older than the current speech run (one region being
    /// accumulated) or a short idle tail the next region may want padding from.
    private func trim() {
        let keepFrom: Int
        if let span = openSpan {
            keepFrom = span.startSample
        } else if let runStart = speechRunStart {
            keepFrom = min(runStart, max(0, totalSamples - idleRetentionSamples))
        } else {
            keepFrom = max(0, totalSamples - idleRetentionSamples)
        }
        if keepFrom > bufferStart {
            buffer.removeFirst(keepFrom - bufferStart)
            bufferStart = keepFrom
        }
    }
}
