import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct FileTranscriptionControllerTests {
    private struct Rig {
        let controller: FileTranscriptionController
        let store: FakeTranscriptStore
        let decoder: ScriptedMediaDecoder
        let segmenter: ScriptedSegmenter
        let provider: FakeTranscriptionProvider
        let settings: SettingsHolder
        /// How many times the controller said the transcript list changed.
        let changes: Box<Int>
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
                         readiness: @escaping @MainActor () -> BackendReadiness = { .ready },
                         glossary: @escaping @MainActor () -> Glossary = { Glossary() },
                         pipelines: PipelineScript? = nil) -> Rig {
        let store = FakeTranscriptStore()
        let settings = SettingsHolder()
        let changes = Box(0)
        let controller = FileTranscriptionController(
            store: store,
            bookmarks: bookmarks,
            pipeline: {
                if let pipelines { return pipelines.next() }
                return Self.pipeline(decoder: decoder, segmenter: segmenter, provider: provider)
            },
            settings: { settings.value },
            glossary: glossary,
            readiness: readiness,
            now: { Self.fixedNow },
            transcriptsChanged: { changes.value += 1 })
        return Rig(controller: controller, store: store, decoder: decoder,
                   segmenter: segmenter, provider: provider, settings: settings,
                   changes: changes, createdAt: Self.fixedNow)
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
                                             position: 1, duration: 10)
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
                                                    position: 1, duration: 10)
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
                                                    position: 0, duration: 10)
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
                                                    position: 0, duration: 10)
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
            if case let .running(transcriptID, title, _, _) = rig.controller.state {
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
            if case let .running(transcriptID, _, _, _) = rig.controller.state {
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
