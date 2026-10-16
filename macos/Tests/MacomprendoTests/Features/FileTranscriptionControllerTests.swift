import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct FileTranscriptionControllerTests {
    /// One `callFinished` the controller reported.
    private struct CallFinished: Equatable {
        let transcriptID: Int64
        let title: String
    }

    private struct Rig {
        let controller: FileTranscriptionController
        let store: FakeTranscriptStore
        let decoder: ScriptedMediaDecoder
        let segmenter: ScriptedSegmenter
        let provider: FakeTranscriptionProvider
        let settings: SettingsHolder
        /// How many times the controller said the transcript list changed.
        let changes: Box<Int>
        /// Every `callFinished` the controller reported: the id and title of a completed call.
        let calls: Box<[CallFinished]>
        let createdAt: Date
    }

    /// One pipeline per `pipeline()` call, for tests where a second job supersedes a first.
    @MainActor private final class PipelineScript {
        private var pipelines: [LongAudioPipeline]

        init(_ pipelines: [LongAudioPipeline]) { self.pipelines = pipelines }

        func next() -> LongAudioPipeline { pipelines.removeFirst() }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_000_000)
    private static let fileURL = URL(fileURLWithPath: "/files/podcast.mp3")

    private static func chunk(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    private static func segment(start: TimeInterval, seconds: Double = 1) -> SpeechSegment {
        SpeechSegment(start: start, samples: chunk(seconds: seconds), sampleRate: 16_000)
    }

    private static func pipeline(decoder: ScriptedMediaDecoder,
                                 segmenter: ScriptedSegmenter,
                                 provider: FakeTranscriptionProvider) -> LongAudioPipeline {
        LongAudioPipeline(decoder: decoder, segmenter: segmenter,
                          transcriber: { provider }, language: nil, sleep: { _ in })
    }

    private func makeRig(decoder: ScriptedMediaDecoder,
                         segmenter: ScriptedSegmenter,
                         provider: FakeTranscriptionProvider = FakeTranscriptionProvider(),
                         bookmarks: FakeFileBookmarks = FakeFileBookmarks(),
                         folders: FakeCallRecordingFolders = FakeCallRecordingFolders(),
                         readiness: @escaping @MainActor () -> BackendReadiness = { .ready },
                         glossary: @escaping @MainActor () -> Glossary = { Glossary() },
                         pipelines: PipelineScript? = nil) -> Rig {
        let store = FakeTranscriptStore()
        let settings = SettingsHolder()
        let changes = Box(0)
        let calls = Box<[CallFinished]>([])
        let controller = FileTranscriptionController(
            store: store,
            bookmarks: bookmarks,
            folders: folders,
            pipeline: {
                if let pipelines { return pipelines.next() }
                return Self.pipeline(decoder: decoder, segmenter: segmenter, provider: provider)
            },
            settings: { settings.value },
            glossary: glossary,
            readiness: readiness,
            now: { Self.fixedNow },
            transcriptsChanged: { changes.value += 1 },
            callFinished: { id, title in
                calls.value.append(CallFinished(transcriptID: id, title: title))
            })
        return Rig(controller: controller, store: store, decoder: decoder,
                   segmenter: segmenter, provider: provider, settings: settings,
                   changes: changes, calls: calls, createdAt: Self.fixedNow)
    }

    // MARK: - A fresh job

    @Test func aFileBecomesACompleteTranscriptWithNormalisedSegments() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)],
                                                                      [Self.segment(start: 5)]]),
                          glossary: { Glossary(manualTerms: ["xcodebuild"]) })
        rig.settings.value.glossaryEnabled = true
        rig.provider.result = .success("Открыл Xcode build")

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: 1))
        #expect(rig.segmenter.sessionJoinGaps == [SpeechSpanAssembler.joinGap])
        let createCount = await rig.store.createCount
        #expect(createCount == 1)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.sourceKind == .file)
        #expect(stored?.header.title == "podcast.mp3")
        #expect(stored?.header.duration == 10)
        #expect(stored?.header.status == .complete)
        #expect(stored?.header.createdAt == rig.createdAt)
        #expect(stored?.sourceBookmark == Data(Self.fileURL.path.utf8))
        #expect(stored?.run == TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                     language: rig.settings.value.transcriptionLanguage))
        #expect(stored?.segments == [
            TranscriptSegment(start: 0, end: 1, text: "Открыл xcodebuild",
                              rawText: "Открыл Xcode build"),
            TranscriptSegment(start: 5, end: 6, text: "Открыл xcodebuild",
                              rawText: "Открыл Xcode build"),
        ])
        #expect(rig.changes.value == 2)
    }

    @Test func progressFollowsPositions() async {
        let gate = AsyncGate()
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[], [Self.segment(start: 0)]]))
        rig.provider.gate = gate

        rig.controller.transcribe(fileAt: Self.fileURL)
        await waitFor("the first chunk's position to reach the state") {
            rig.controller.state == .running(transcriptID: 1, title: "podcast.mp3",
                                             position: 1, duration: 10, speaker: nil)
        }

        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: 1))
    }

    @Test func aBackendThatIsNotReadyFailsWithoutCreatingARow() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(),
                          readiness: { .notReady(reason: "This model has not been downloaded yet.",
                                                 fix: .download(modelID: "large-v3-turbo")) })

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(message: "This model has not been downloaded yet.",
                                                transcriptID: nil))
        let createCount = await rig.store.createCount
        #expect(createCount == 0)
        #expect(rig.decoder.requests.isEmpty)
    }

    @Test func anOpenErrorFailsWithoutCreatingARow() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(
                              openError: MacomprendoError.mediaUnreadable("no audio track")),
                          segmenter: ScriptedSegmenter())

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.mediaUnreadable("no audio track")),
            transcriptID: nil))
        let createCount = await rig.store.createCount
        #expect(createCount == 0)
    }

    @Test func noSpeechDeletesTheTranscriptAndFails() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter())

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.noSpeechFound), transcriptID: nil))
        let stored = await rig.store.snapshot(1)
        #expect(stored == nil)
    }

    // MARK: - Interruption

    @Test func cancelKeepsSegmentsAndMarksIncomplete() async {
        let gate = AsyncGate()
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)],
                                                                      [Self.segment(start: 5)]]))
        rig.provider.gate = gate

        rig.controller.transcribe(fileAt: Self.fileURL)
        await waitFor("the first segment to reach the provider") { gate.waiterCount == 1 }
        gate.openOne()
        await waitFor("the first segment to land and the second to reach the provider") {
            gate.waiterCount == 1
                && rig.controller.state == .running(transcriptID: 1, title: "podcast.mp3",
                                                    position: 1, duration: 10, speaker: nil)
        }

        rig.controller.cancel()
        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .idle)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
        #expect(stored?.segments == [TranscriptSegment(start: 0, end: 1, text: "hello")])
        #expect(rig.changes.value == 1)
    }

    @Test func aNewJobCancelsTheRunningOne() async {
        let gate = AsyncGate()
        let firstProvider = FakeTranscriptionProvider()
        firstProvider.gate = gate
        let secondProvider = FakeTranscriptionProvider()
        secondProvider.result = .success("second")

        let first = Self.pipeline(decoder: ScriptedMediaDecoder(duration: 10,
                                                                chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                                  provider: firstProvider)
        let second = Self.pipeline(decoder: ScriptedMediaDecoder(duration: 20,
                                                                 chunks: [Self.chunk(seconds: 1)]),
                                   segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                                   provider: secondProvider)
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([first, second]))

        rig.controller.transcribe(fileAt: URL(fileURLWithPath: "/files/first.mp3"))
        await waitFor("the first job to reach the provider") {
            gate.waiterCount == 1
                && rig.controller.state == .running(transcriptID: 1, title: "first.mp3",
                                                    position: 0, duration: 10, speaker: nil)
        }

        rig.controller.transcribe(fileAt: URL(fileURLWithPath: "/files/second.mp3"))
        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: 2))
        let firstStored = await rig.store.snapshot(1)
        #expect(firstStored?.header.status == .incomplete)
        #expect(firstStored?.header.statusReason == "Cancelled.")
        #expect(firstStored?.segments.isEmpty == true)
        let secondStored = await rig.store.snapshot(2)
        #expect(secondStored?.header.status == .complete)
        #expect(secondStored?.segments.map(\.text) == ["second"])
        let createCount = await rig.store.createCount
        #expect(createCount == 2)
    }

    @Test func aSupersededJobNeverOverwritesTheNewJobsFailure() async {
        let gate = AsyncGate()
        let firstURL = URL(fileURLWithPath: "/files/first.mp3")
        let readiness = Box<BackendReadiness>(.ready)
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                          readiness: { readiness.value })
        rig.provider.gate = gate

        rig.controller.transcribe(fileAt: firstURL)
        await waitFor("the first job to reach the provider") {
            gate.waiterCount == 1
                && rig.controller.state == .running(transcriptID: 1, title: "first.mp3",
                                                    position: 0, duration: 10, speaker: nil)
        }

        // The second job fails before it starts anything; the first job's cancellation lands
        // afterwards and must leave the verdict alone.
        readiness.value = .notReady(reason: "This model has not been downloaded yet.",
                                    fix: .download(modelID: "large-v3-turbo"))
        rig.controller.transcribe(fileAt: URL(fileURLWithPath: "/files/second.mp3"))
        #expect(rig.controller.state == .failed(message: "This model has not been downloaded yet.",
                                                transcriptID: nil))

        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(message: "This model has not been downloaded yet.",
                                                transcriptID: nil))
        let firstStored = await rig.store.snapshot(1)
        #expect(firstStored?.header.status == .incomplete)
        #expect(firstStored?.header.statusReason == "Cancelled.")
        #expect(rig.decoder.requests.map(\.url) == [firstURL])
    }

    @Test func aSegmentFailureMarksIncompleteWithTheErrorText() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]))
        await rig.store.failNextAppendOnce(.transcriptStore("the disk is full"))

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        let expected = ErrorText.describe(MacomprendoError.transcriptStore("the disk is full"))
        #expect(rig.controller.state == .failed(message: expected, transcriptID: 1))
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == expected)
        #expect(stored?.segments.isEmpty == true)
        #expect(rig.changes.value == 0)
    }

    @Test func aJobCancelledWhileQueuedNeverOpensTheFile() async {
        let gate = AsyncGate()
        let firstProvider = FakeTranscriptionProvider()
        firstProvider.gate = gate
        let firstDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let secondDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let first = Self.pipeline(decoder: firstDecoder,
                                  segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                                  provider: firstProvider)
        let second = Self.pipeline(decoder: secondDecoder,
                                   segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                                   provider: FakeTranscriptionProvider())
        let rig = makeRig(decoder: secondDecoder, segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([first, second]))

        rig.controller.transcribe(fileAt: URL(fileURLWithPath: "/files/first.mp3"))
        await waitFor("the first job to reach the provider") { gate.waiterCount == 1 }

        // The second job supersedes the first and queues behind it (its task awaits the first's
        // settlement); cancel it before the first job has settled.
        rig.controller.transcribe(fileAt: URL(fileURLWithPath: "/files/second.mp3"))
        rig.controller.cancel()

        gate.open()
        await rig.controller.drain()

        #expect(secondDecoder.requests.isEmpty)
        #expect(rig.controller.state == .idle)
    }

    /// Waits for the job's row to be settled in the store. The controller's `state` is *not* a
    /// signal here: with the pipeline running ahead of the consumer it still reads `.idle`
    /// before the job's first event has been processed, so it can look "settled" before the job
    /// has even started.
    private func waitForSettle(in store: FakeTranscriptStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.snapshot(1)?.header.status == .incomplete { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for the transcript row to settle")
    }

    // MARK: - Quitting

    /// Quitting mid-job: the job is cancelled *and awaited*, and its row reads exactly as if
    /// the app had been killed — the reason launch maintenance writes — so `Resume` offers the
    /// same continuation.
    @Test func shutdownStopsTheJobAndMarksTheRowAsQuit() async {
        let gate = AsyncGate()
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 2)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0),
                                                                       Self.segment(start: 5)]]))
        rig.provider.gate = gate

        rig.controller.transcribe(fileAt: Self.fileURL)
        await waitFor("the first segment to reach the provider") { gate.waiterCount == 1 }

        let shutdown = Task { await rig.controller.shutdown() }
        // The bookkeeping lands while the producing task is still inside the provider…
        await waitForSettle(in: rig.store)

        gate.open()
        await shutdown.value

        #expect(rig.controller.state == .idle)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == TranscriptLibraryController.abandonedJobReason)
        #expect(stored?.segments.isEmpty == true)
        // The provider is no longer in use: the chunk's second segment never reached it.
        #expect(rig.provider.received.count == 1)
    }

    /// The pipeline's producing task holds the provider — and, with it, the local model's
    /// native whisper context — until it ends. `shutdown()` waits for that end, so by the time
    /// it returns the job's own reference is gone and `LocalTranscriptionProviderCache`'s
    /// `removeAll()` (which `AppModel.shutdown()` calls next) can free the context before the
    /// process exits.
    @Test func shutdownReleasesTheJobsReferenceToTheProvider() async {
        let gate = AsyncGate()
        let box = WeakProviderBox()
        let decoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]])
        // The provider exists only inside this closure: the weak box is the one way to see it
        // deallocate, which makes it the proof that nothing on the job's side still holds it.
        let pipeline = LongAudioPipeline(decoder: decoder, segmenter: segmenter,
                                         transcriber: {
                                             let provider = FakeTranscriptionProvider()
                                             provider.gate = gate
                                             box.provider = provider
                                             return provider
                                         },
                                         language: nil, sleep: { _ in })
        let rig = makeRig(decoder: decoder, segmenter: segmenter,
                          pipelines: PipelineScript([pipeline]))

        rig.controller.transcribe(fileAt: Self.fileURL)
        await waitFor("the segment to reach the provider") { gate.waiterCount == 1 }

        let shutdown = Task { await rig.controller.shutdown() }
        await waitForSettle(in: rig.store)
        gate.open()
        await shutdown.value

        #expect(box.provider == nil)
    }

    /// The quit path is one-way: once `shutdown()` has begun, `transcribe` must not start a job.
    /// A job started after it would build the provider the quit path exists to release, and its
    /// row would be left behind by a launch maintenance that already ran.
    @Test func noJobStartsOnceTheAppIsQuitting() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]))

        await rig.controller.shutdown()
        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .idle)
        #expect(rig.decoder.requests.isEmpty)
        let createCount = await rig.store.createCount
        #expect(createCount == 0)
    }

    /// The same for both `resume` entry points: quitting must not reopen a stored transcript.
    @Test func noResumeStartsOnceTheAppIsQuitting() async throws {
        let path = "/files/meeting.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 60,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]))
        let id = await rig.store.create(sourceKind: .file, title: "meeting.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 60,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.appendSegment(TranscriptSegment(start: 0, end: 12, text: "earlier"),
                                          to: id)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        await rig.controller.shutdown()
        rig.controller.resume(transcriptID: id)
        rig.controller.resume(transcriptID: id, fileAt: URL(fileURLWithPath: path))
        await rig.controller.drain()

        #expect(rig.controller.state == .idle)
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
        #expect(stored?.segments.map(\.text) == ["earlier"])
    }

    // MARK: - Resume

    @Test func resumeContinuesFromTheLastSegmentEnd() async throws {
        let gate = AsyncGate()
        let path = "/files/meeting.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 60,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)],
                                                                      [Self.segment(start: 10)]]))
        rig.provider.gate = gate

        let id = await rig.store.create(sourceKind: .file, title: "meeting.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 60,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.appendSegment(TranscriptSegment(start: 0, end: 12, text: "earlier"),
                                          to: id)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        rig.controller.resume(transcriptID: id)
        await waitFor("the resumed job to be running") {
            if case let .running(transcriptID, title, _, _, _) = rig.controller.state {
                return transcriptID == id && title == "meeting.m4a"
            }
            return false
        }
        let midRun = await rig.store.snapshot(id)
        #expect(midRun?.header.status == .inProgress)

        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        #expect(rig.decoder.requests.map(\.start) == [12])
        #expect(rig.decoder.requests.map(\.url) == [URL(fileURLWithPath: path)])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .complete)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0, end: 12, text: "earlier"),
            TranscriptSegment(start: 12, end: 13, text: "hello"),
            TranscriptSegment(start: 22, end: 23, text: "hello"),
        ])
    }

    // MARK: - Transcribe Again

    @Test func transcribeAgainReplacesTheTextFromTheStart() async throws {
        let path = "/files/meeting.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 60,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)],
                                                                      [Self.segment(start: 10)]]))
        let id = await rig.store.create(sourceKind: .file, title: "meeting.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 60,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.appendSegment(TranscriptSegment(start: 0, end: 12, text: "old"), to: id)
        try await rig.store.setStatus(.complete, reason: nil, for: id)

        rig.controller.transcribeAgain(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        #expect(rig.decoder.requests.map(\.start) == [0])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .complete)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0, end: 1, text: "hello"),
            TranscriptSegment(start: 10, end: 11, text: "hello"),
        ])
    }

    @Test func transcribeAgainWithAMissingFileKeepsTheText() async throws {
        let path = "/files/gone.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [path]))
        let id = await rig.store.create(sourceKind: .file, title: "gone.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 10,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.appendSegment(TranscriptSegment(start: 0, end: 5, text: "keep"), to: id)
        try await rig.store.setStatus(.complete, reason: nil, for: id)

        rig.controller.transcribeAgain(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.sourceFileUnavailable), transcriptID: id))
        let stored = await rig.store.snapshot(id)
        #expect(stored?.segments == [TranscriptSegment(start: 0, end: 5, text: "keep")])
        #expect(stored?.header.status == .complete)
    }

    @Test func resumeWithAMissingFileFails() async throws {
        let path = "/files/gone.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [path]))

        let id = await rig.store.create(sourceKind: .file, title: "gone.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 10,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.sourceFileUnavailable), transcriptID: id))
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
    }

    @Test func resumeWithABackendThatIsNotReadyFailsWithoutTouchingTheRow() async throws {
        let path = "/files/meeting.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 60,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(),
                          readiness: { .notReady(reason: "This model has not been downloaded yet.",
                                                 fix: .download(modelID: "large-v3-turbo")) })

        let id = await rig.store.create(sourceKind: .file, title: "meeting.m4a",
                                        sourceBookmark: Data(path.utf8), duration: 60,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(message: "This model has not been downloaded yet.",
                                                transcriptID: id))
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
    }

    /// The window's **Choose File…**: `Resume` was told which file to use because the stored
    /// bookmark no longer resolves, so the chosen file is decoded and becomes the row's source.
    @Test func resumeWithANewlyChosenFileUsesItAndReplacesTheBookmark() async throws {
        let gate = AsyncGate()
        let chosen = "/files/renamed.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 60,
                                                        chunks: [Self.chunk(seconds: 1),
                                                                 Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)],
                                                                      [Self.segment(start: 10)]]),
                          bookmarks: FakeFileBookmarks(missing: ["/files/gone.m4a"]))
        rig.provider.gate = gate

        let id = await rig.store.create(sourceKind: .file, title: "meeting.m4a",
                                        sourceBookmark: Data("/files/gone.m4a".utf8), duration: 60,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.appendSegment(TranscriptSegment(start: 0, end: 12, text: "earlier"),
                                          to: id)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        rig.controller.resume(transcriptID: id, fileAt: URL(fileURLWithPath: chosen))
        await waitFor("the resumed job to be running") {
            if case let .running(transcriptID, _, _, _, _) = rig.controller.state {
                return transcriptID == id
            }
            return false
        }
        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        // The chosen file, not the stored bookmark — which by itself cannot be resolved here.
        #expect(rig.decoder.requests.map(\.url) == [URL(fileURLWithPath: chosen)])
        #expect(rig.decoder.requests.map(\.start) == [12])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .complete)
        #expect(stored?.sourceBookmark == Data(chosen.utf8))
        #expect(stored?.segments == [
            TranscriptSegment(start: 0, end: 12, text: "earlier"),
            TranscriptSegment(start: 12, end: 13, text: "hello"),
            TranscriptSegment(start: 22, end: 23, text: "hello"),
        ])
    }

    @Test func resumeWithANewlyChosenFileForAMissingTranscriptFails() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter())

        rig.controller.resume(transcriptID: 42, fileAt: URL(fileURLWithPath: "/files/choice.m4a"))
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.transcriptStore(
                "no transcript has identifier 42")),
            transcriptID: nil))
        #expect(rig.decoder.requests.isEmpty)
    }

    /// The window shows **Choose File…** for exactly one failure: a `Resume` whose stored
    /// bookmark no longer resolves.
    @Test func onlyAMissingStoredBookmarkOffersChoosingTheFile() async throws {
        let gone = "/files/gone.m4a"
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [gone]))
        #expect(!rig.controller.canChooseSourceFile)     // idle

        let id = await rig.store.create(sourceKind: .file, title: "gone.m4a",
                                        sourceBookmark: Data(gone.utf8), duration: 10,
                                        run: TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                                   language: nil),
                                        at: Self.fixedNow)
        try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.sourceFileUnavailable), transcriptID: id))
        #expect(rig.controller.canChooseSourceFile)
        #expect(!rig.controller.canChooseRecordingFolder)
    }

    @Test func anotherFailureDoesNotOfferChoosingTheFile() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(
                              openError: MacomprendoError.mediaUnreadable("no audio track")),
                          segmenter: ScriptedSegmenter())

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.mediaUnreadable("no audio track")),
            transcriptID: nil))
        #expect(!rig.controller.canChooseSourceFile)
    }

    // MARK: - Call jobs

    private static let callTitle = "Call 2026-10-15 16:42"

    /// A recording folder on disk: a manifest whose tracks start at `me`/`others` and — with
    /// `tracks` — an empty file for each track it names. The audio is scripted; only the
    /// folder's shape is real.
    private func makeRecordingFolder(me: TimeInterval? = 0, others: TimeInterval? = 0,
                                     tracks: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("macomprendo-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = CallRecordingManifest(startedAt: Self.fixedNow,
                                             folderName: folder.lastPathComponent)
        if let me { manifest.setStartOffset(me, for: .me) }
        if let others { manifest.setStartOffset(others, for: .others) }
        manifest.status = .finished
        try manifest.write(to: folder)
        if tracks {
            for speaker in TranscriptSpeaker.allCases {
                guard let file = manifest.track(speaker)?.file else { continue }
                try Data().write(to: folder.appendingPathComponent(file))
            }
        }
        return folder
    }

    private func trackURL(_ folder: URL, _ speaker: TranscriptSpeaker) -> URL {
        folder.appendingPathComponent(
            CallRecordingLayout.trackFileName(folderName: folder.lastPathComponent,
                                              track: speaker))
    }

    /// The row Task 8's recorder leaves for the job: a `.call` transcript bookmarked to its
    /// recording folder, `incomplete` once the job that created it stopped. `leaveInProgress`
    /// keeps the row exactly as the recorder leaves it — `inProgress`, waiting for the job.
    private func makeCallRow(in rig: Rig, folder: URL,
                             segments: [TranscriptSegment] = [],
                             leaveInProgress: Bool = false) async throws -> Int64 {
        let id = await rig.store.create(sourceKind: .call, title: Self.callTitle,
                                        sourceBookmark: Data(folder.path.utf8), duration: 60,
                                        run: TranscriptionRun.from(
                                            rig.settings.value.transcriptionSource,
                                            language: nil),
                                        at: Self.fixedNow)
        for segment in segments {
            try await rig.store.appendSegment(segment, to: id)
        }
        if !leaveInProgress {
            try await rig.store.setStatus(.incomplete, reason: "Cancelled.", for: id)
        }
        return id
    }

    @Test func aCallTranscribesMeThenOthers() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let decoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]])
        let provider = FakeTranscriptionProvider()
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(decoder: decoder, segmenter: segmenter,
                                            provider: provider),
                              Self.pipeline(decoder: decoder, segmenter: segmenter,
                                            provider: provider)]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        #expect(decoder.requests.map(\.url) == [trackURL(folder, .me),
                                                trackURL(folder, .others)])
        // Call tracks are cut at the other side's turns, not joined across them.
        #expect(segmenter.sessionJoinGaps == [SpeechSpanAssembler.callJoinGap,
                                              SpeechSpanAssembler.callJoinGap])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0.2, end: 1.2, text: "hello", speaker: .me),
            TranscriptSegment(start: 0.5, end: 1.5, text: "hello", speaker: .others),
        ])
    }

    @Test func callSegmentsAreShiftedOntoTheCallsClockAndCarryTheirSpeaker() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meProvider = FakeTranscriptionProvider()
        meProvider.result = .success("me says")
        let othersProvider = FakeTranscriptionProvider()
        othersProvider.result = .success("they say")
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: meProvider),
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 10)]]),
                                  provider: othersProvider)]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        let stored = await rig.store.snapshot(id)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0.2, end: 1.2, text: "me says", speaker: .me),
            TranscriptSegment(start: 10.5, end: 11.5, text: "they say", speaker: .others),
        ])
        #expect(stored?.header.status == .complete)
    }

    @Test func aCallJobReportsEachTrackThenFinishes() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meGate = AsyncGate()
        let meProvider = FakeTranscriptionProvider()
        meProvider.gate = meGate
        let othersGate = AsyncGate()
        let othersProvider = FakeTranscriptionProvider()
        othersProvider.gate = othersGate
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: meProvider),
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: othersProvider)]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await waitFor("Me's track to be running") {
            rig.controller.state == .running(transcriptID: id, title: Self.callTitle,
                                             position: 0.2, duration: 10.2, speaker: .me)
        }

        meGate.open()
        await waitFor("Others' track to be running") {
            rig.controller.state == .running(transcriptID: id, title: Self.callTitle,
                                             position: 0.5, duration: 10.5, speaker: .others)
        }

        othersGate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .complete)
        #expect(rig.calls.value == [CallFinished(transcriptID: id, title: Self.callTitle)])
    }

    @Test func onlyOthersHavingSpeechStillCompletes() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(),
                                  provider: FakeTranscriptionProvider()),
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .complete)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0.5, end: 1.5, text: "hello", speaker: .others),
        ])
    }

    @Test func noSpeechInEitherTrackDeletesTheTranscriptAndFails() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let othersDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(decoder: meDecoder, segmenter: ScriptedSegmenter(),
                                            provider: FakeTranscriptionProvider()),
                              Self.pipeline(decoder: othersDecoder, segmenter: ScriptedSegmenter(),
                                            provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.noSpeechFound), transcriptID: nil))
        #expect(await rig.store.snapshot(id) == nil)
        #expect(rig.calls.value.isEmpty)
        // Both tracks were transcribed: the recording holds no speech, and that is the failure.
        #expect(!meDecoder.requests.isEmpty)
        #expect(!othersDecoder.requests.isEmpty)
    }

    /// A plan with no steps — no track carries a `startOffset`, so nothing can be placed on the
    /// call's clock. The recording holds audio, so the row must not be deleted as speechless:
    /// it stays `incomplete` with the reason the window answers with **Choose Folder…**, the
    /// only pointer back to the recording.
    @Test func anEmptyPlanLeavesTheRowIncompleteAndOffersTheFolder() async throws {
        let folder = try makeRecordingFolder(me: nil, others: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter())
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        let expected = ErrorText.describe(MacomprendoError.callRecordingUnavailable)
        #expect(rig.controller.state == .failed(message: expected, transcriptID: id))
        #expect(rig.controller.canChooseRecordingFolder)
        #expect(rig.decoder.requests.isEmpty)
        #expect(rig.calls.value.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == expected)
    }

    @Test func aCallTranscribedAgainStartsBothTracksOver() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meDecoder = ScriptedMediaDecoder(duration: 60, chunks: [Self.chunk(seconds: 1)])
        let othersDecoder = ScriptedMediaDecoder(duration: 60, chunks: [Self.chunk(seconds: 1)])
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(decoder: meDecoder,
                                            segmenter: ScriptedSegmenter(
                                                acceptScript: [[Self.segment(start: 0)]]),
                                            provider: FakeTranscriptionProvider()),
                              Self.pipeline(decoder: othersDecoder,
                                            segmenter: ScriptedSegmenter(
                                                acceptScript: [[Self.segment(start: 0)]]),
                                            provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: folder, segments: [
            TranscriptSegment(start: 0.2, end: 30, text: "old me", speaker: .me),
            TranscriptSegment(start: 0.5, end: 40, text: "old others", speaker: .others),
        ])
        try await rig.store.setStatus(.complete, reason: nil, for: id)

        rig.controller.transcribeAgain(transcriptID: id)
        await rig.controller.drain()

        #expect(meDecoder.requests.map(\.start) == [0])
        #expect(othersDecoder.requests.map(\.start) == [0])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.segments == [
            TranscriptSegment(start: 0.2, end: 1.2, text: "hello", speaker: .me),
            TranscriptSegment(start: 0.5, end: 1.5, text: "hello", speaker: .others),
        ])
        #expect(stored?.header.status == .complete)
    }

    @Test func aCallResumeContinuesTheHalfDoneTrackThenTheRest() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meDecoder = ScriptedMediaDecoder(duration: 60, chunks: [Self.chunk(seconds: 1)])
        let othersDecoder = ScriptedMediaDecoder(duration: 60, chunks: [Self.chunk(seconds: 1)])
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: meDecoder,
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: FakeTranscriptionProvider()),
                              Self.pipeline(
                                  decoder: othersDecoder,
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: folder, segments: [
            TranscriptSegment(start: 11, end: 12, text: "earlier", speaker: .me),
        ])

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        // Me ended at 12.0 on the call's clock, 0.2 into its own file: it resumes at 11.8.
        #expect(meDecoder.requests.map(\.start) == [11.8])
        #expect(othersDecoder.requests.map(\.start) == [0])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.segments == [
            TranscriptSegment(start: 11, end: 12, text: "earlier", speaker: .me),
            TranscriptSegment(start: 12, end: 13, text: "hello", speaker: .me),
            TranscriptSegment(start: 0.5, end: 1.5, text: "hello", speaker: .others),
        ])
        #expect(stored?.header.status == .complete)
    }

    @Test func aCallResumeWithAnUnresolvableBookmarkOffersTheFolder() async throws {
        let missing = "/Volumes/gone/rec 2026-10-15 16-42-07"
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [missing]))
        let id = try await makeCallRow(in: rig, folder: URL(fileURLWithPath: missing))

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.callRecordingUnavailable),
            transcriptID: id))
        #expect(rig.controller.canChooseRecordingFolder)
        #expect(!rig.controller.canChooseSourceFile)
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
    }

    @Test func aCallResumeWithAMissingTrackFileFailsTheSameWay() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5, tracks: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter())
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.callRecordingUnavailable),
            transcriptID: id))
        #expect(rig.controller.canChooseRecordingFolder)
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
    }

    /// The recorder creates the row `inProgress` and immediately runs the job. A backend that
    /// is not ready fails the job before it marks the row — the fresh row must not stay
    /// `inProgress` with no reason: nothing repairs it while the app runs, and the next launch
    /// would call it a quit.
    @Test func aFreshCallRowWhoseBackendIsNotReadyIsMarkedIncomplete() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          readiness: { .notReady(reason: "This model has not been downloaded yet.",
                                                 fix: .download(modelID: "large-v3-turbo")) })
        let id = try await makeCallRow(in: rig, folder: folder, leaveInProgress: true)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: "This model has not been downloaded yet.", transcriptID: id))
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "This model has not been downloaded yet.")
    }

    /// The same when the folder will not resolve: the row is the recorder's, still `inProgress`,
    /// and the failure has to reach it with the reason the window shows.
    @Test func aFreshCallRowWithAnUnavailableFolderIsMarkedIncomplete() async throws {
        let missing = "/Volumes/gone/rec 2026-10-15 16-42-07"
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [missing]))
        let id = try await makeCallRow(in: rig, folder: URL(fileURLWithPath: missing),
                                       leaveInProgress: true)

        rig.controller.resume(transcriptID: id)
        await rig.controller.drain()

        let expected = ErrorText.describe(MacomprendoError.callRecordingUnavailable)
        #expect(rig.controller.state == .failed(message: expected, transcriptID: id))
        #expect(rig.controller.canChooseRecordingFolder)
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == expected)
    }

    @Test func choosingTheRecordingFolderReplacesTheStaleBookmark() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = "/Volumes/gone/rec old"
        let meDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          bookmarks: FakeFileBookmarks(missing: [stale]),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: meDecoder,
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: FakeTranscriptionProvider()),
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(),
                                  provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: URL(fileURLWithPath: stale))

        rig.controller.resume(transcriptID: id, fileAt: folder)
        await rig.controller.drain()

        #expect(rig.controller.state == .finished(transcriptID: id))
        #expect(meDecoder.requests.map(\.url) == [trackURL(folder, .me)])
        let stored = await rig.store.snapshot(id)
        #expect(stored?.sourceBookmark == Data(folder.path.utf8))
        #expect(stored?.header.status == .complete)
    }

    @Test func choosingAFolderWithoutAManifestKeepsTheBookmarkAndFails() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("macomprendo-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter())
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id, fileAt: empty)
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            message: ErrorText.describe(MacomprendoError.callRecordingUnavailable),
            transcriptID: id))
        #expect(rig.controller.canChooseRecordingFolder)
        #expect(rig.decoder.requests.isEmpty)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.sourceBookmark == Data(folder.path.utf8))
        #expect(stored?.header.status == .incomplete)
    }

    @Test func cancellingACallJobMarksTheRowIncomplete() async throws {
        let folder = try makeRecordingFolder(me: 0.2, others: 0.5)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = AsyncGate()
        let meProvider = FakeTranscriptionProvider()
        meProvider.gate = gate
        let othersDecoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.chunk(seconds: 1)])
        let rig = makeRig(decoder: ScriptedMediaDecoder(), segmenter: ScriptedSegmenter(),
                          pipelines: PipelineScript([
                              Self.pipeline(
                                  decoder: ScriptedMediaDecoder(
                                      duration: 10, chunks: [Self.chunk(seconds: 1)]),
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: meProvider),
                              Self.pipeline(
                                  decoder: othersDecoder,
                                  segmenter: ScriptedSegmenter(
                                      acceptScript: [[Self.segment(start: 0)]]),
                                  provider: FakeTranscriptionProvider())]))
        let id = try await makeCallRow(in: rig, folder: folder)

        rig.controller.resume(transcriptID: id)
        await waitFor("Me's track to reach the provider") { gate.waiterCount == 1 }

        rig.controller.cancel()
        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .idle)
        let stored = await rig.store.snapshot(id)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == "Cancelled.")
        #expect(othersDecoder.requests.isEmpty)
    }

    // MARK: - The shown failure

    /// The window clears the failure when the user moves to another transcript.
    @Test func clearFailureDropsAFailureAndLeavesOtherStatesAlone() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(
                              openError: MacomprendoError.mediaUnreadable("no audio track")),
                          segmenter: ScriptedSegmenter())

        rig.controller.clearFailure()
        #expect(rig.controller.state == .idle)          // nothing shown: a no-op

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        rig.controller.clearFailure()
        #expect(rig.controller.state == .idle)
        rig.controller.clearFailure()                   // and it stays cleared
        #expect(rig.controller.state == .idle)
    }

    @Test func clearFailureLeavesAFinishedJobAsItIs() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]))

        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()
        #expect(rig.controller.state == .finished(transcriptID: 1))

        rig.controller.clearFailure()
        #expect(rig.controller.state == .finished(transcriptID: 1))
    }

    // MARK: - Normalisation

    @Test func rawTextIsKeptOnlyWhenNormalisationRewrote() async {
        let rig = makeRig(decoder: ScriptedMediaDecoder(duration: 10,
                                                        chunks: [Self.chunk(seconds: 1)]),
                          segmenter: ScriptedSegmenter(acceptScript: [[Self.segment(start: 0)]]),
                          glossary: { Glossary(manualTerms: ["xcodebuild"]) })
        rig.settings.value.glossaryEnabled = true

        rig.provider.result = .success("Открыл Xcode build")
        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        rig.provider.result = .success("Открыл терминал")
        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        rig.settings.value.glossaryEnabled = false
        rig.provider.result = .success("Открыл Xcode build")
        rig.controller.transcribe(fileAt: Self.fileURL)
        await rig.controller.drain()

        let rewritten = await rig.store.snapshot(1)
        #expect(rewritten?.segments == [
            TranscriptSegment(start: 0, end: 1, text: "Открыл xcodebuild",
                              rawText: "Открыл Xcode build")])
        let untouched = await rig.store.snapshot(2)
        #expect(untouched?.segments == [TranscriptSegment(start: 0, end: 1,
                                                          text: "Открыл терминал")])
        let switchedOff = await rig.store.snapshot(3)
        #expect(switchedOff?.segments == [TranscriptSegment(start: 0, end: 1,
                                                            text: "Открыл Xcode build")])
    }
}

extension FakeTranscriptStore {
    /// Arms the next `appendSegment` to fail. The property is actor-isolated, so a test cannot
    /// assign it from outside the actor.
    func failNextAppendOnce(_ error: MacomprendoError) { failNextAppend = error }
}

/// Holds a weak reference to a provider a test cannot hold strongly — the provider lives only
/// inside a pipeline's `transcriber` closure — so its deallocation is observable.
private final class WeakProviderBox: @unchecked Sendable {
    weak var provider: FakeTranscriptionProvider?
}
