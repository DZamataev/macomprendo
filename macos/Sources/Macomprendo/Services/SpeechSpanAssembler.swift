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
/// - a span longer than `SpeechSegmentSplitter.maximumDuration` is cut early at the quietest frame
///   of the last `SpeechSegmentSplitter.searchWindow` seconds before the cap, keeping only the
///   remainder open. A run the detector is still reporting is a *provisional span*, cut the same
///   way, so a region the detector never closes (speech over music) cannot grow the buffer either;
///   when its region finally arrives the span continues after what was already handed out — no
///   overlap, no gap. Pieces shorter than `SpeechSegmentSplitter.minimumDuration` are dropped.
///
/// Memory bound: while a region is still being reported the buffer holds the provisional span's
/// remainder (under one `maximumDuration` after a cut) plus the lookback — at most
/// `retentionBound` ≈ 36 s at 16 kHz. Once a completed region backs the span it additionally
/// holds the join gap and the one region the detector is still accumulating: just over 50 s for
/// the 20 s regions with 1 s gaps of the memory-bound test, because a remainder close to the cap
/// can meet a whole next region. The sherpa detector keeps its own copy of the open region (a
/// 60 s circular buffer), so the process holds roughly that much again; `retainedSampleCount`
/// exposes the assembler's copy so a test can assert it directly.
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
    /// Samples kept while no span is open and the detector is not inside speech: enough for the
    /// next region's leading padding *and* its backdated start (`lookbackSamples`, under 1 s at
    /// 16 kHz), plus the chunk that reports it. A region starting further back could only exist
    /// if the detector was inside speech while its audio streamed, which is the other branch.
    static let idleRetention: TimeInterval = 1

    private let sampleRate: Int
    private let joinGapSamples: Int
    private let paddingSamples: Int
    private let capSamples: Int
    private let frameSamples: Int
    private let windowSamples: Int
    private let minimumSamples: Int
    private let idleRetentionSamples: Int
    /// How far sherpa v1.13.4 can backdate a region's start behind the chunk in which `Detected`
    /// first turns true: `start = max(Tail − 2·WindowSize − MinSpeechDurationSamples, Head)` at
    /// the first window the model calls speech (`voice-activity-detector.cc`, `AcceptWaveform`),
    /// i.e. `2 · detectorWindowSize + detectorMinSpeechDuration` samples ≈ 0.31 s at 16 kHz.
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
        /// End of the last completed region in the span, in stream samples; the live edge while
        /// the span is provisional.
        var endSample: Int
        /// True while the span is a run the detector is still reporting and no completed region
        /// has arrived for it yet. Provisional spans are cut at the cap from `accept` so such a
        /// run cannot grow the buffer; a completed region turns the span into a region-backed one.
        var provisional: Bool
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
        backdateSamples = 2 * Self.detectorWindowSize
            + Int(Self.detectorMinSpeechDuration * Double(sampleRate))
        lookbackSamples = backdateSamples + paddingSamples
    }

    /// Samples currently held for spans that are not finished yet.
    var retainedSampleCount: Int { buffer.count }

    /// The stated bound on `retainedSampleCount` while a region is still being reported (see the
    /// class doc): one span, the splitter's search window and the lookback.
    var retentionBound: Int { capSamples + windowSamples + lookbackSamples }

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
            // A run the detector is reporting and has not closed: a provisional span. It is cut
            // at the cap like any other, so a region that never closes cannot grow the buffer.
            if openSpan == nil, let runStart = speechRunStart {
                openSpan = Span(startSample: max(bufferStart, runStart - lookbackSamples),
                                endSample: totalSamples,
                                provisional: true)
            } else if openSpan?.provisional == true {
                openSpan?.endSample = totalSamples
            }
            if openSpan?.provisional == true {
                segments += cutToCap()
            }
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
    /// Called from `apply` for a region-backed span and from `accept` for a provisional one.
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
    /// piece; otherwise everything older than the current speech run's lookback (a region being
    /// accumulated can start `backdateSamples` behind it) or a short idle tail the next region
    /// may want padding from.
    private func trim() {
        let keepFrom: Int
        if let span = openSpan {
            keepFrom = span.startSample
        } else if let runStart = speechRunStart {
            keepFrom = max(0, runStart - lookbackSamples)
        } else {
            keepFrom = max(0, totalSamples - idleRetentionSamples)
        }
        if keepFrom > bufferStart {
            buffer.removeFirst(keepFrom - bufferStart)
            bufferStart = keepFrom
        }
    }
}
