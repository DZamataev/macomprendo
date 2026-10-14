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
/// - each span is padded by `padding` on both sides, clamped to the stream. A region's start can
///   lie up to `backdateSamples` before the chunk in which the detector first reported speech
///   (sherpa backdates it — see `backdateSamples`), so `lookbackSamples` behind the current run
///   is kept; otherwise the span would start inside the region and clip real speech and its lead;
/// - a span is closed when a region arrives more than `joinGap` after it, when the stream has
///   advanced more than `joinGap` past its end with no new region *and the detector is not inside
///   speech* — while it is, an unreported region may still start inside the join window; or at
///   `finish()`;
/// - a span is cut early only when it is longer than
///   `SpeechSegmentSplitter.maximumDuration + SpeechSegmentSplitter.minimumRemainder` (35 s), at
///   the quietest frame of the last `SpeechSegmentSplitter.searchWindow` seconds before the cap,
///   keeping only the remainder open. Every open span is cut, whether a completed region backs it
///   or the detector is still reporting it (a *provisional* span), so a region the detector never
///   closes (speech over music) cannot grow the buffer either; when its region finally arrives the
///   span continues after what was already handed out — no overlap, no gap. Pieces shorter than
///   `SpeechSegmentSplitter.minimumDuration` are dropped.
///
/// Memory bound: while the detector is inside speech the open span is cut at the split threshold
/// from `accept`, whatever backs it, so `retainedSampleCount` never exceeds `retentionBound` = one
/// span at the 35 s split threshold (`maximumDuration + minimumRemainder`) plus the splitter's
/// search window and the lookback ≈ 41 s at 16 kHz (plus at most one chunk of overshoot); a span
/// stays open for at most `joinGap` past its end, so no more than that of silence is retained on
/// top. The sherpa detector keeps its own copy of the open region:
/// v1.13.4's `CircularBuffer::Push` *doubles* its capacity when it overflows ("No data loss!"), so
/// that copy grows with the region and the app cannot bound it without resetting the detector.
/// `retainedSampleCount` exposes the assembler's copy so a test can assert it directly.
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
    /// The detector's Silero window size, in samples, and its minimum speech duration. The
    /// session configures the model with exactly these; the assembler compensates for the region
    /// start they let sherpa backdate (see `lookbackSamples`).
    static let detectorWindowSize = 512
    static let detectorMinSpeechDuration: TimeInterval = 0.25
    /// Samples kept while no span is open: enough for the next region's leading padding *and* its
    /// backdated start (`lookbackSamples`, under 1 s at 16 kHz), plus the chunk that reports it. A
    /// region starting further back could only exist if the detector was inside speech while its
    /// audio streamed — which is the branch that opens a span, so nothing older is needed.
    static let idleRetention: TimeInterval = 1

    private let sampleRate: Int
    private let joinGapSamples: Int
    private let paddingSamples: Int
    private let capSamples: Int
    private let remainderSamples: Int
    private let frameSamples: Int
    private let windowSamples: Int
    private let minimumSamples: Int
    private let idleRetentionSamples: Int
    /// How far sherpa v1.13.4 can backdate a region's start behind the chunk in which `Detected`
    /// first turns true: `start = max(Tail − 2·WindowSize − MinSpeechDurationSamples, Head)` at
    /// the first window the model calls speech (`voice-activity-detector.cc`, `AcceptWaveform`),
    /// i.e. `2 · detectorWindowSize + detectorMinSpeechDuration` samples — 5,024 samples (≈ 0.31 s)
    /// with the bundled v4 model, whose `window_overlap` is 0, and with these constants, which the
    /// session configures the model from.
    private let backdateSamples: Int
    /// Audio kept behind the current speech run: the leading padding plus `backdateSamples`.
    private let lookbackSamples: Int

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
        /// End of the last completed region in the span, in stream samples. While the detector is
        /// inside speech it is the span's live edge — the position the stream has reached — so the
        /// audio of a region that is still being accumulated belongs to the span and can be cut.
        var endSample: Int
        /// True while no completed region has arrived for the span's run yet. It only decides the
        /// span's start when the region does arrive (`apply` drops the lookback the run needed);
        /// the cap cut applies to every open span.
        var provisional: Bool
    }

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        joinGapSamples = Int(Self.joinGap * Double(sampleRate))
        paddingSamples = Int(Self.padding * Double(sampleRate))
        capSamples = Int(SpeechSegmentSplitter.maximumDuration * Double(sampleRate))
        remainderSamples = Int(SpeechSegmentSplitter.minimumRemainder * Double(sampleRate))
        frameSamples = max(1, Int(SpeechSegmentSplitter.frameDuration * Double(sampleRate)))
        windowSamples = Int(SpeechSegmentSplitter.searchWindow * Double(sampleRate))
        minimumSamples = Int(SpeechSegmentSplitter.minimumDuration * Double(sampleRate))
        idleRetentionSamples = Int(Self.idleRetention * Double(sampleRate))
        backdateSamples = 2 * Self.detectorWindowSize
            + Int(Self.detectorMinSpeechDuration * Double(sampleRate))
        lookbackSamples = backdateSamples + paddingSamples
    }

    /// Samples currently held for spans that are not finished yet.
    var retainedSampleCount: Int { buffer.count }

    /// The stated bound on `retainedSampleCount` while the detector is inside speech (see the
    /// class doc): one span at the 35 s split threshold (`maximumDuration + minimumRemainder`),
    /// the splitter's search window and the lookback. A span the detector has left but that no
    /// later region closes is not cut again, so it holds its samples and the `joinGap` it waits
    /// before closing: `capSamples + joinGapSamples` there.
    var retentionBound: Int { capSamples + remainderSamples + windowSamples + lookbackSamples }

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
        if speechInProgress {
            if speechRunStart == nil { speechRunStart = previousTotal }
            if openSpan == nil, let runStart = speechRunStart {
                openSpan = Span(startSample: max(bufferStart, runStart - lookbackSamples),
                                endSample: totalSamples,
                                provisional: true)
            } else {
                // The detector is inside speech, so everything up to here belongs to the span
                // whether or not a completed region backs it yet: this is the span's live edge. A
                // region the detector never closes (speech over music) would otherwise keep the
                // buffer growing — the split below is not limited to a provisional span.
                openSpan?.endSample = totalSamples
            }
            segments += cutToCap()
        } else {
            if let span = openSpan, totalSamples > span.endSample + joinGapSamples {
                segments += flush(span)
                openSpan = nil
            }
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
            // A provisional span becomes exactly this region's span: its padded start — never
            // before what was already handed out, so the pieces stay contiguous — and the
            // region's end.
            if span.provisional {
                openSpan = Span(startSample: max(span.startSample, start - paddingSamples),
                                endSample: end,
                                provisional: false)
            } else {
                openSpan = Span(startSample: span.startSample,
                                endSample: max(span.endSample, end),
                                provisional: false)
            }
            return cutToCap()
        }
        var segments = flush(span)
        openSpan = nil
        segments += open(start: start, end: end)
        return segments
    }

    private func open(start: Int, end: Int) -> [SpeechSegment] {
        let paddedStart = max(bufferStart, start - paddingSamples)
        openSpan = Span(startSample: paddedStart, endSample: end, provisional: false)
        return cutToCap()
    }

    private func flush(_ span: Span) -> [SpeechSegment] {
        let end = min(totalSamples, span.endSample + paddingSamples)
        var segments: [SpeechSegment] = []
        var start = span.startSample
        while end - start > capSamples + remainderSamples {
            let cut = cutPoint(from: start)
            if let piece = makeSegment(from: start, to: cut) { segments.append(piece) }
            start = cut
        }
        if let piece = makeSegment(from: start, to: end) { segments.append(piece) }
        return segments
    }

    /// Cuts the open span down whenever it has grown past the split threshold, keeping only the
    /// remainder open. The cut follows the splitter's rule — only above
    /// `maximumDuration + minimumRemainder`, at the quietest frame of the last search-window
    /// seconds before the cap — measured from the span that is still open. Called from `apply`
    /// for a region-backed span and from `accept` for a provisional one.
    private func cutToCap() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        while let span = openSpan, span.endSample - span.startSample > capSamples + remainderSamples {
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
    /// piece; otherwise a short idle tail the next region may want padding from (a region can only
    /// start behind the stream position if the detector was inside speech, which opens a span).
    private func trim() {
        let keepFrom: Int
        if let span = openSpan {
            keepFrom = span.startSample
        } else {
            keepFrom = max(0, totalSamples - idleRetentionSamples)
        }
        if keepFrom > bufferStart {
            buffer.removeFirst(keepFrom - bufferStart)
            bufferStart = keepFrom
        }
    }
}
