import Foundation
import Testing
@testable import Macomprendo

/// Opt-in benchmark gym: one recording through the production long-audio pipeline
/// (`AVAssetMediaDecoder` → `SherpaSileroSegmenter` → local model via `ProviderFactory`),
/// once per catalog model, sequentially — the previous model's native context is released
/// before the next one starts, so neither timing nor memory carries over.
///
/// Disabled unless pointed at a fixture:
///
///     MACOMPRENDO_BENCH_FIXTURE=<audio or video path>                 (enables the test)
///     MACOMPRENDO_BENCH_OUT=<output directory>                        (required)
///     MACOMPRENDO_BENCH_MODELS=<comma-separated catalog ids>
///         default: large-v3-turbo,gigaam-v3-e2e-rnnt,parakeet-tdt-0.6b-v3
///     MACOMPRENDO_BENCH_LANGUAGE=<ISO-639-1, whisper only>            (optional)
///     MACOMPRENDO_BENCH_REFERENCE=<.txt or .srt reference>            (optional)
///     MACOMPRENDO_BENCH_LIMIT_SECONDS=<N>                             (optional, quick runs)
///
/// It writes `<out>/<model>.txt`, `<out>/<model>.srt` and merges this run's numbers into
/// `<out>/report.json` (rerunning with more models keeps the earlier entries). The report also
/// lists, per model, the segments that match a known whisper phantom phrase (`phantoms`), and the
/// printed table carries their count — the check reports, it never fails the run. The models are
/// read from `~/Library/Application Support/Macomprendo/models` — never downloaded — through
/// `LocalModelManager`, and the test fails only on errors, never on quality.
@Suite struct LongAudioBenchmarkTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static let fixtureURL = environment["MACOMPRENDO_BENCH_FIXTURE"]
        .map { URL(fileURLWithPath: $0) }
    private static let outputDirectory = environment["MACOMPRENDO_BENCH_OUT"]
        .map { URL(fileURLWithPath: $0) }
    private static let referenceURL = environment["MACOMPRENDO_BENCH_REFERENCE"]
        .map { URL(fileURLWithPath: $0) }
    private static let limitSeconds: TimeInterval? = environment["MACOMPRENDO_BENCH_LIMIT_SECONDS"]
        .flatMap(Double.init)
    /// `nil` means automatic detection. An empty value means the same thing.
    private static let language: String? = environment["MACOMPRENDO_BENCH_LANGUAGE"]
        .flatMap { $0.isEmpty ? nil : $0 }
    private static let modelIDs: [String] = (environment["MACOMPRENDO_BENCH_MODELS"]
        ?? "large-v3-turbo,gigaam-v3-e2e-rnnt,parakeet-tdt-0.6b-v3")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    private static let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Macomprendo/models")

    private static var isConfigured: Bool {
        guard let fixtureURL, FileManager.default.fileExists(atPath: fixtureURL.path) else { return false }
        return true
    }

    @Test("every requested model transcribes the fixture; numbers land in report.json",
          .enabled(if: LongAudioBenchmarkTests.isConfigured))
    func benchmarkFixture() async throws {
        let fixture = try #require(Self.fixtureURL)
        let out = try #require(
            Self.outputDirectory,
            "MACOMPRENDO_BENCH_OUT is required when MACOMPRENDO_BENCH_FIXTURE is set")
        let reference = try Self.loadReference()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        print("LongAudioBenchmark fixture: \(fixture.path)")
        print("LongAudioBenchmark models: \(Self.modelIDs.joined(separator: ", "))"
              + ", language: \(Self.language ?? "auto")"
              + ", limit: \(Self.limitSeconds.map { String(format: "%.0f s", $0) } ?? "none")"
              + ", reference: \(reference?.path ?? "none")")

        var rows = [Self.tableHeader(hasReference: reference != nil)]
        for modelID in Self.modelIDs {
            let outcome = try await measure(modelID: modelID, fixture: fixture, reference: reference)
            try Self.write(outcome, to: out, fixture: fixture, reference: reference)
            let row = Self.tableRow(outcome)
            print(row)
            rows.append(row)
        }
        print(rows.joined(separator: "\n"))
        print("LongAudioBenchmark report: \(out.appending(path: "report.json").path)")
    }

    /// The phantom check is deliberately testable without a model: it is a pure match over the
    /// WER normalisation, so a regression in the phrase list or the matcher shows up here rather
    /// than only in a 25-minute benchmark run. A plain "спасибо" is not a phantom — only the
    /// whole phrase is.
    @Test func knownPhantomPhrasesAreDetectedAfterNormalisation() throws {
        let segments = [
            TranscriptSegment(start: 0, end: 29.9,
                              text: "Ну, это уж всегда бывает, в принципе. Спасибо, Дмитрий!"),
            TranscriptSegment(start: 4466.0, end: 4469.4, text: "Субтитры сделал DimaTorzok"),
            TranscriptSegment(start: 4470.0, end: 4473.0, text: "СПАСИБО ЗА ПРОСМОТР!"),
            TranscriptSegment(start: 4474.0, end: 4476.0, text: "Продолжение следует…"),
            TranscriptSegment(start: 4477.0, end: 4479.0, text: "www.Amara.org"),
        ]
        let phantoms = Self.phantomSegments(in: segments)

        #expect(phantoms.map(\.segmentIndex) == [1, 2, 3, 4])
        let first = try #require(phantoms.first)
        #expect(first.start == 4466.0)
        #expect(first.text == "Субтитры сделал DimaTorzok")
    }

    // MARK: - Phantoms

    /// Phrases whisper.cpp has been caught inventing over a trailing stretch of music or silence
    /// — text that is not in the recording. Matched after `WordErrorRate`'s normalisation, so
    /// case and punctuation do not matter. Reported per model in `report.json` and as a table
    /// column; the benchmark still never fails on quality, only reports.
    static let phantomPhrases = [
        "субтитры сделал", "субтитры создавал", "редактор субтитров", "корректор",
        "продолжение следует", "спасибо за просмотр", "подписывайтесь на канал", "amara.org",
    ]

    /// One segment that matched a known phantom phrase.
    struct Phantom: Equatable {
        let segmentIndex: Int
        let start: TimeInterval
        let text: String
    }

    /// The segments whose text matches a known phantom phrase, in order. The index is the
    /// segment's position in the model's own list, so the tail of a long transcript can be
    /// checked at a glance.
    static func phantomSegments(in segments: [TranscriptSegment]) -> [Phantom] {
        let phrases = phantomPhrases.map(WordErrorRate.normalisedText)
        return segments.enumerated().compactMap { index, segment in
            let normalised = WordErrorRate.normalisedText(segment.text)
            guard phrases.contains(where: normalised.contains) else { return nil }
            return Phantom(segmentIndex: index, start: segment.start, text: segment.text)
        }
    }

    // MARK: - One model's run

    private func measure(modelID: String, fixture: URL, reference: Reference?) async throws -> ModelOutcome {
        guard let model = ModelCatalog.model(id: modelID) else {
            throw MacomprendoError.modelMissing(modelID)
        }
        let manager = LocalModelManager(directory: Self.modelsDirectory, http: StubHTTPClient())
        guard await manager.resolved(modelID) != nil else {
            throw MacomprendoError.modelMissing("\(modelID) — not installed, and the benchmark never downloads")
        }
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())
        let provider = try await factory.transcriber(
            for: .local(modelID: modelID), endpoints: [], models: manager, whisper: WhisperOptions())
        let timed = TimedTranscriber(wrapping: provider)

        let sampler = PeakMemorySampler()
        sampler.start()
        let loadStart = LoadAverage.current()
        let started = DispatchTime.now()

        var segments: [TranscriptSegment] = []
        var decodedSeconds: TimeInterval = 0
        var sourceDuration: TimeInterval = 0
        var stoppedAtLimit = false
        let pipeline = LongAudioPipeline(decoder: AVAssetMediaDecoder(),
                                         segmenter: SherpaSileroSegmenter(),
                                         transcriber: { timed },
                                         language: Self.language)
        do {
            events: for try await event in pipeline.run(fixture, from: 0) {
                switch event {
                case .opened(let duration):
                    sourceDuration = duration
                case .position(let seconds):
                    decodedSeconds = max(decodedSeconds, seconds)
                    if let limit = Self.limitSeconds, seconds >= limit {
                        // Everything up to this position — segments included — has already
                        // been yielded: the pipeline reports a position only after
                        // transcribing the chunk that reached it.
                        stoppedAtLimit = true
                        break events
                    }
                case .segment(let start, let end, let text):
                    segments.append(TranscriptSegment(start: start, end: end, text: text))
                    decodedSeconds = max(decodedSeconds, end)
                }
            }
        } catch {
            pipeline.stop()
            await pipeline.awaitCompletion()
            _ = sampler.stop()
            if let whisper = provider as? WhisperCppTranscriber { await whisper.release() }
            throw error
        }
        pipeline.stop()
        await pipeline.awaitCompletion()
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000

        // Free this model's native context before the next one is built: whisper.cpp aborts at
        // process exit while a context is alive, and a resident recognizer would both inflate
        // the next model's peak memory and speed its first call up dishonestly.
        if let whisper = provider as? WhisperCppTranscriber { await whisper.release() }
        let peakBytes = sampler.stop()
        let loadEnd = LoadAverage.current()

        let hypothesis = segments.map(\.text).joined(separator: " ")
        return ModelOutcome(
            modelID: modelID,
            engine: model.engine.rawValue,
            segments: segments,
            sourceDuration: sourceDuration,
            audioSeconds: decodedSeconds > 0 ? decodedSeconds : sourceDuration,
            wallSeconds: wallSeconds,
            peakFootprintBytes: peakBytes,
            transcribeDurations: timed.callDurations,
            stoppedAtLimit: stoppedAtLimit,
            loadAverageStart: loadStart,
            loadAverageEnd: loadEnd,
            werPercent: reference.map({ WordErrorRate.wer(reference: $0.text, hypothesis: hypothesis) * 100 }),
            cerPercent: reference.map({ WordErrorRate.cer(reference: $0.text, hypothesis: hypothesis) * 100 }),
            referenceWordCount: reference.map({ WordErrorRate.words($0.text).count }),
            hypothesisWordCount: WordErrorRate.words(hypothesis).count,
            phantoms: Self.phantomSegments(in: segments))
    }

    // MARK: - Output

    private static func write(_ outcome: ModelOutcome, to out: URL, fixture: URL,
                              reference: Reference?) throws {
        let header = TranscriptHeader(id: 0, createdAt: Date(), sourceKind: .file,
                                      title: fixture.lastPathComponent,
                                      duration: outcome.sourceDuration, status: .complete,
                                      statusReason: nil)
        let run = TranscriptionRun(modelID: outcome.modelID, engine: outcome.engine,
                                   language: Self.language, appVersion: "benchmark")
        let transcript = Transcript(header: header, run: run, sourceBookmark: nil, summary: nil,
                                    segments: outcome.segments)
        try TranscriptExporter.render(transcript, as: .plainText)
            .write(to: out.appending(path: "\(outcome.modelID).txt"), atomically: true, encoding: .utf8)
        try TranscriptExporter.render(transcript, as: .subRip)
            .write(to: out.appending(path: "\(outcome.modelID).srt"), atomically: true, encoding: .utf8)

        let reportURL = out.appending(path: "report.json")
        var report = existingReport(at: reportURL)
        report["fixture"] = fixture.path
        report["fixture_duration_seconds"] = outcome.sourceDuration
        report["language"] = Self.language ?? NSNull()
        report["limit_seconds"] = Self.limitSeconds ?? NSNull()
        report["reference"] = reference.map { ["path": $0.path, "format": $0.format] } ?? NSNull()
        report["updated_at"] = ISO8601DateFormatter().string(from: Date())
        var models = report["models"] as? [String: Any] ?? [:]
        models[outcome.modelID] = entry(outcome)
        report["models"] = models

        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: reportURL)
    }

    private static func entry(_ outcome: ModelOutcome) -> [String: Any] {
        var value: [String: Any] = [
            "model_id": outcome.modelID,
            "engine": outcome.engine,
            "audio_seconds": outcome.audioSeconds,
            "source_duration_seconds": outcome.sourceDuration,
            "wall_seconds": outcome.wallSeconds,
            "real_time_factor": outcome.realTimeFactor,
            "segment_count": outcome.segments.count,
            "segments": outcome.segments.map { ["start": $0.start, "end": $0.end] },
            "peak_phys_footprint_bytes": outcome.peakFootprintBytes,
            "peak_phys_footprint_megabytes": outcome.peakFootprintMegabytes,
            "first_transcribe_seconds": outcome.firstTranscribeSeconds,
            "median_transcribe_seconds": outcome.medianTranscribeSeconds,
            "model_load_seconds_estimate": outcome.modelLoadSecondsEstimate,
            "transcribe_calls": outcome.transcribeDurations.count,
            "stopped_at_limit": outcome.stoppedAtLimit,
            "load_average_start": outcome.loadAverageStart,
            "load_average_end": outcome.loadAverageEnd,
            "hypothesis_words": outcome.hypothesisWordCount,
            "phantoms": outcome.phantoms.map {
                ["segmentIndex": $0.segmentIndex, "start": $0.start, "text": $0.text] as [String: Any]
            },
        ]
        // WER/CER only when a reference was given — and always reported, never asserted on.
        if let wer = outcome.werPercent { value["wer_percent"] = wer }
        if let cer = outcome.cerPercent { value["cer_percent"] = cer }
        if let words = outcome.referenceWordCount { value["reference_words"] = words }
        return value
    }

    private static func existingReport(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let report = object as? [String: Any] else { return [:] }
        return report
    }

    private static func loadReference() throws -> Reference? {
        guard let url = referenceURL else { return nil }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let format = url.pathExtension.lowercased() == "srt" ? "srt" : "txt"
        return Reference(path: url.path,
                         format: format,
                         text: format == "srt" ? SubRipText.text(from: contents) : contents)
    }

    // MARK: - Table

    private static func tableHeader(hasReference: Bool) -> String {
        var header = pad("model", 32)
            + " " + pad("audio_s", 8) + " " + pad("wall_s", 8) + " " + pad("rtf", 6)
            + " " + pad("segs", 6) + " " + pad("peak_mb", 9) + " " + pad("phantoms", 9)
        if hasReference {
            header += " " + pad("wer_%", 7) + " " + pad("cer_%", 7)
        }
        return header
    }

    private static func tableRow(_ outcome: ModelOutcome) -> String {
        var row = pad(outcome.modelID, 32)
        row += String(format: " %8.1f %8.1f %6.2f %6d %9.1f",
                      outcome.audioSeconds, outcome.wallSeconds, outcome.realTimeFactor,
                      outcome.segments.count, outcome.peakFootprintMegabytes)
        row += String(format: " %9d", outcome.phantoms.count)
        if let wer = outcome.werPercent, let cer = outcome.cerPercent {
            row += String(format: " %7.2f %7.2f", wer, cer)
        }
        return row
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Values

    private struct Reference {
        let path: String
        let format: String
        let text: String
    }

    private struct ModelOutcome {
        let modelID: String
        let engine: String
        let segments: [TranscriptSegment]
        let sourceDuration: TimeInterval
        let audioSeconds: TimeInterval
        let wallSeconds: TimeInterval
        let peakFootprintBytes: UInt64
        let transcribeDurations: [Double]
        let stoppedAtLimit: Bool
        let loadAverageStart: [Double]
        let loadAverageEnd: [Double]
        let werPercent: Double?
        let cerPercent: Double?
        let referenceWordCount: Int?
        let hypothesisWordCount: Int
        let phantoms: [Phantom]

        var realTimeFactor: Double { audioSeconds > 0 ? wallSeconds / audioSeconds : 0 }
        var peakFootprintMegabytes: Double { Double(peakFootprintBytes) / 1_048_576 }
        var firstTranscribeSeconds: Double { transcribeDurations.first ?? 0 }
        /// A typical later call's duration — the first call's baseline.
        var medianTranscribeSeconds: Double {
            let later = transcribeDurations.dropFirst().sorted()
            guard !later.isEmpty else { return 0 }
            return later[later.count / 2]
        }
        /// How much longer the first (model-loading) call took than a typical one.
        var modelLoadSecondsEstimate: Double {
            transcribeDurations.isEmpty ? 0 : max(0, firstTranscribeSeconds - medianTranscribeSeconds)
        }
    }

    /// Forwards to the real provider and records how long every call took, in order, so the
    /// first call's extra latency — the model load — can be told apart from decoding work.
    private final class TimedTranscriber: TranscriptionProvider, @unchecked Sendable {
        private let wrapped: any TranscriptionProvider
        private let lock = NSLock()
        private var recorded: [Double] = []

        init(wrapping wrapped: any TranscriptionProvider) {
            self.wrapped = wrapped
        }

        var callDurations: [Double] { lock.withLock { recorded } }

        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            let started = DispatchTime.now()
            let text = try await wrapped.transcribe(pcm, sampleRate: sampleRate, language: language)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
                / 1_000_000_000
            lock.withLock { recorded.append(seconds) }
            return text
        }
    }

    /// Samples this process's `phys_footprint` every 0.5 s and keeps the maximum seen.
    private final class PeakMemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var task: Task<Void, Never>?

        func start() {
            sample()
            task = Task.detached { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { break }
                    sample()
                }
            }
        }

        /// The peak since `start()`, taken once more before the sampler stops.
        func stop() -> UInt64 {
            sample()
            task?.cancel()
            task = nil
            return lock.withLock { peak }
        }

        private func sample() {
            let value = Self.physFootprintBytes()
            lock.withLock { peak = max(peak, value) }
        }

        /// The resident dirty set the OS would reclaim — what Activity Monitor shows as Memory.
        static func physFootprintBytes() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }
    }

    /// The machine's 1/5/15-minute load averages, recorded per run so a busy machine shows up
    /// in the numbers themselves.
    private enum LoadAverage {
        static func current() -> [Double] {
            var loads = [Double](repeating: 0, count: 3)
            let count = getloadavg(&loads, 3)
            return count == 3 ? loads : []
        }
    }
}
