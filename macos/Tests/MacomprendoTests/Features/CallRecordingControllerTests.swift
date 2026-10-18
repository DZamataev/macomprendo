import Foundation
import Testing
@testable import Macomprendo

private enum CallTestTime {
    static let now = Date(timeIntervalSince1970: 1_792_071_727)
    static let sessionStart: TimeInterval = 4_000_000
}

private func trackURL(_ folder: URL, _ speaker: TranscriptSpeaker) -> URL {
    folder.appendingPathComponent(
        CallRecordingLayout.trackFileName(folderName: folder.lastPathComponent, track: speaker))
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecordingController-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `CallRecordingController`: the start/stop state machine over the two captures, the track
/// writers, `recording.json` and the transcript row.
@MainActor
@Suite struct CallRecordingControllerTests {
    // MARK: - Rig

    /// Records every writer the controller's factory produced, keyed by its file URL, so a test
    /// can set a track's `startOffset` or fire its `onFailure` the way the writer's own queue would.
    private final class WriterBook: @unchecked Sendable {
        private let lock = NSLock()
        private var writersByURL: [URL: FakeCallTrackWriter] = [:]
        private var failuresByURL: [URL: @Sendable (MacomprendoError) -> Void] = [:]
        private var sessionStartsByURL: [URL: TimeInterval] = [:]
        private var order: [URL] = []

        func record(url: URL, sessionStart: TimeInterval, writer: FakeCallTrackWriter,
                    onFailure: @escaping @Sendable (MacomprendoError) -> Void) {
            lock.withLock {
                writersByURL[url] = writer
                failuresByURL[url] = onFailure
                sessionStartsByURL[url] = sessionStart
                order.append(url)
            }
        }

        /// The track URLs the factory was asked for, in order.
        var urls: [URL] { lock.withLock { order } }

        func writer(_ speaker: TranscriptSpeaker, in folder: URL) -> FakeCallTrackWriter? {
            lock.withLock { writersByURL[trackURL(folder, speaker)] }
        }

        func sessionStart(_ speaker: TranscriptSpeaker, in folder: URL) -> TimeInterval? {
            lock.withLock { sessionStartsByURL[trackURL(folder, speaker)] }
        }

        /// Fires a track's `onFailure` as the real writer's private queue would.
        func fail(_ speaker: TranscriptSpeaker, in folder: URL, with error: MacomprendoError) {
            lock.withLock { failuresByURL[trackURL(folder, speaker)] }?(error)
        }
    }

    /// Wraps the default writer so a test can see how far the stop has got when each track file
    /// is finished — the "captures stopped before writers finish" order.
    private final class OrderLoggingWriter: CallTrackWriting, @unchecked Sendable {
        let inner = FakeCallTrackWriter()
        private let onFinish: @Sendable () -> Void

        init(log: Box<[Int]>, microphone: ScriptedCallCapture, systemAudio: ScriptedCallCapture) {
            onFinish = {
                log.value.append(microphone.stopCount > 0 ? 1 : 0)
                log.value.append(systemAudio.stopCount > 0 ? 1 : 0)
            }
        }

        var startOffset: TimeInterval? {
            get { inner.startOffset }
            set { inner.startOffset = newValue }
        }

        func consume(_ samples: [Float], at time: TimeInterval) {
            inner.consume(samples, at: time)
        }

        func finish() async throws {
            onFinish()
            try await inner.finish()
        }
    }

    /// Holds `finish()` until the test opens the gate — an in-flight stop a concurrent
    /// `shutdown()` has to reach while it is still `.stopping`.
    private final class GatedFinishWriter: CallTrackWriting, @unchecked Sendable {
        private let inner: any CallTrackWriting
        private let gate: AsyncGate

        init(_ inner: any CallTrackWriting, gate: AsyncGate) {
            self.inner = inner
            self.gate = gate
        }

        var startOffset: TimeInterval? { inner.startOffset }

        func consume(_ samples: [Float], at time: TimeInterval) {
            inner.consume(samples, at: time)
        }

        func finish() async throws {
            await gate.wait()
            try await inner.finish()
        }
    }

    @MainActor
    private final class Rig {
        let root: URL
        let microphone: ScriptedCallCapture
        let systemAudio: ScriptedCallCapture
        let folders: FakeCallRecordingFolders
        let permissions: FakePermissions
        let store: FakeTranscriptStore
        /// What the controller writes rows through, so a test can arm a failing `create`.
        let storeCreateFailure: CreateFailingTranscriptStore
        let bookmarks: FakeFileBookmarks
        let settings: SettingsHolder
        let writers: WriterBook
        let transcribes: Box<[Int64]>
        let changes: Box<Int>
        let clockValue: Box<TimeInterval>
        let nowValue: Box<Date>
        let orderLog: Box<[Int]>
        let controller: CallRecordingController

        init(orderLogging: Bool = false,
             finishGate: AsyncGate? = nil,
             secondWriterError: MacomprendoError? = nil,
             createFailure: MacomprendoError? = nil,
             tick: Duration = .milliseconds(1)) throws {
            let root = try tempDirectory()
            let microphone = ScriptedCallCapture()
            let systemAudio = ScriptedCallCapture()
            let folders = FakeCallRecordingFolders(realDirectoryRoot: root)
            let permissions = FakePermissions()
            let store = FakeTranscriptStore()
            let storeCreateFailure = CreateFailingTranscriptStore(wrapping: store)
            if let createFailure { storeCreateFailure.failNextCreateOnce(createFailure) }
            let bookmarks = FakeFileBookmarks()
            let settings = SettingsHolder()
            let writers = WriterBook()
            let transcribes = Box<[Int64]>([])
            let changes = Box(0)
            let clockValue = Box(CallTestTime.sessionStart)
            let nowValue = Box(CallTestTime.now)
            let orderLog = Box<[Int]>([])

            let factory: CallTrackWriterFactory = { url, sessionStart, onFailure in
                // A factory whose second call fails: `abortStart` must still finish the
                // writer the first call handed out.
                if let secondWriterError, !writers.urls.isEmpty {
                    throw secondWriterError
                }
                let product: any CallTrackWriting
                if orderLogging {
                    let writer = OrderLoggingWriter(log: orderLog, microphone: microphone,
                                                    systemAudio: systemAudio)
                    writers.record(url: url, sessionStart: sessionStart, writer: writer.inner,
                                   onFailure: onFailure)
                    product = writer
                } else {
                    let writer = FakeCallTrackWriter()
                    writers.record(url: url, sessionStart: sessionStart, writer: writer,
                                   onFailure: onFailure)
                    product = writer
                }
                guard let finishGate else { return product }
                return GatedFinishWriter(product, gate: finishGate)
            }

            controller = CallRecordingController(
                microphone: microphone,
                systemAudio: systemAudio,
                folders: folders,
                makeWriter: factory,
                permissions: permissions,
                store: storeCreateFailure,
                bookmarks: bookmarks,
                settings: { settings.value },
                clock: { clockValue.value },
                now: { nowValue.value },
                tick: tick,
                transcribe: { id in transcribes.value.append(id) },
                transcriptsChanged: { changes.value += 1 })

            self.root = root
            self.microphone = microphone
            self.systemAudio = systemAudio
            self.folders = folders
            self.permissions = permissions
            self.store = store
            self.storeCreateFailure = storeCreateFailure
            self.bookmarks = bookmarks
            self.settings = settings
            self.writers = writers
            self.transcribes = transcribes
            self.changes = changes
            self.clockValue = clockValue
            self.nowValue = nowValue
            self.orderLog = orderLog
        }

        var folder: URL { folders.folders.first! }
        var meWriter: FakeCallTrackWriter? { writers.writer(.me, in: folder) }
        var othersWriter: FakeCallTrackWriter? { writers.writer(.others, in: folder) }
    }

    private func startRecording(_ rig: Rig) async {
        rig.controller.toggle()
        await rig.controller.drain()
        #expect(rig.controller.state == .recording(startedAt: rig.nowValue.value))
        #expect(rig.controller.isRecording)
    }

    // MARK: - Starting

    @Test func startingCreatesTheFolderWritersManifestAndBothCaptures() async throws {
        let rig = try Rig()
        rig.settings.value.callRecordingsDirectory = rig.root.path

        await startRecording(rig)

        #expect(rig.folders.created.map(\.directory) == [URL(fileURLWithPath: rig.root.path)])
        #expect(rig.folders.created.map(\.startedAt) == [CallTestTime.now])
        let folder = try #require(rig.folders.folders.first)

        let manifest = try CallRecordingManifest.read(from: folder)
        #expect(manifest.status == .recording)
        #expect(manifest.startedAt == CallTestTime.now)
        #expect(manifest.track(.me)?.file == CallRecordingLayout.trackFileName(
            folderName: folder.lastPathComponent, track: .me))
        #expect(manifest.track(.others)?.file == CallRecordingLayout.trackFileName(
            folderName: folder.lastPathComponent, track: .others))
        #expect(manifest.track(.me)?.startOffset == nil)
        #expect(manifest.track(.others)?.startOffset == nil)

        #expect(rig.writers.urls == [trackURL(folder, .me), trackURL(folder, .others)])
        #expect(rig.writers.sessionStart(.me, in: folder) == CallTestTime.sessionStart)
        #expect(rig.writers.sessionStart(.others, in: folder) == CallTestTime.sessionStart)
        #expect(rig.microphone.startCount == 1)
        #expect(rig.systemAudio.startCount == 1)
        #expect(rig.folders.removed.isEmpty)
    }

    @Test func aNilSettingUsesTheDefaultRecordingsDirectory() async throws {
        let rig = try Rig()

        await startRecording(rig)

        #expect(rig.folders.created.map(\.directory) == [CallRecordingLayout.defaultDirectory])
    }

    @Test func audioReachesItsOwnTrackAndItsLevelAppearsAfterATick() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        rig.microphone.emit(CallAudioChunk(samples: [0.5, -0.5, 0.5, -0.5],
                                           time: CallTestTime.sessionStart))
        await waitFor("the microphone's level to appear") { rig.controller.levels.me > 0 }
        #expect(rig.controller.levels.others == 0)
        #expect(rig.writers.writer(.me, in: folder)?.consumed.map(\.samples) == [4])
        #expect(rig.writers.writer(.others, in: folder)?.consumed.isEmpty == true)

        rig.systemAudio.emit(CallAudioChunk(samples: [0, 0, 0, 0], time: CallTestTime.sessionStart))
        await waitFor("the system chunk to reach the Others writer") {
            rig.writers.writer(.others, in: folder)?.consumed.count == 1
        }
        #expect(rig.writers.writer(.me, in: folder)?.consumed.count == 1)
        #expect(rig.controller.levels.others == 0)
    }

    @Test func aTrackOffsetReachesTheManifestWhileStillRecording() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        rig.meWriter?.startOffset = 0.25

        await waitFor("the manifest to gain the microphone track's start offset") {
            (try? CallRecordingManifest.read(from: folder))?.track(.me)?.startOffset == 0.25
        }
        let manifest = try CallRecordingManifest.read(from: folder)
        #expect(manifest.status == .recording)
        #expect(manifest.track(.me)?.startOffset == 0.25)
        #expect(manifest.track(.others)?.startOffset == nil)
    }

    // MARK: - Permissions and start failures

    @Test func aDeniedMicrophoneFailsBeforeAnythingIsCreated() async throws {
        let rig = try Rig()
        rig.permissions.statuses = [.microphone: .denied]

        rig.controller.toggle()
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.permissionDenied(.microphone))))
        #expect(rig.folders.created.isEmpty)
        #expect(rig.microphone.startCount == 0)
        #expect(rig.systemAudio.startCount == 0)
        #expect(rig.writers.urls.isEmpty)
    }

    @Test func anUndeterminedMicrophoneIsRequestedAndGrantedContinues() async throws {
        let rig = try Rig()
        rig.permissions.statuses = [.microphone: .undetermined]
        rig.permissions.requestResults = [.microphone: .granted]

        await startRecording(rig)

        #expect(rig.permissions.requested == [.microphone])
        #expect(!rig.folders.created.isEmpty)
    }

    @Test func aFolderThatCannotBeCreatedFailsWithoutStartingAnything() async throws {
        let rig = try Rig()
        rig.folders.createError = MacomprendoError.callRecordingLocationUnavailable

        rig.controller.toggle()
        await rig.controller.drain()

        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.callRecordingLocationUnavailable)))
        #expect(rig.microphone.startCount == 0)
        #expect(rig.systemAudio.startCount == 0)
        #expect(rig.writers.urls.isEmpty)
        #expect(rig.folders.removed.isEmpty)
    }

    @Test func aSystemAudioStartFailureStopsTheMicrophoneFinishesTheWritersAndRemovesTheFolder()
        async throws {
        let rig = try Rig()
        rig.systemAudio.startError = MacomprendoError.systemAudioCaptureFailed("x")

        rig.controller.toggle()
        await rig.controller.drain()

        let folder = try #require(rig.folders.folders.first)
        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.systemAudioCaptureFailed("x"))))
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.writers.writer(.me, in: folder)?.finished == true)
        #expect(rig.writers.writer(.others, in: folder)?.finished == true)
        #expect(rig.folders.removed == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aSecondWriterCreationFailureFinishesTheFirstWriter() async throws {
        let rig = try Rig(secondWriterError: .callRecordingWriteFailed("second"))

        rig.controller.toggle()
        await rig.controller.drain()

        let folder = try #require(rig.folders.folders.first)
        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.callRecordingWriteFailed("second"))))
        #expect(rig.writers.urls == [trackURL(folder, .me)])
        #expect(rig.writers.writer(.me, in: folder)?.finished == true)
        #expect(rig.microphone.startCount == 0)
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.folders.removed == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Stopping

    @Test func stopFinalisesBothTracksWritesTheManifestAndStartsTheCallJob() async throws {
        let rig = try Rig(orderLogging: true)
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)
        rig.meWriter?.startOffset = 0.125
        rig.othersWriter?.startOffset = 0.5
        rig.nowValue.value = rig.nowValue.value.addingTimeInterval(5)
        await waitFor("the elapsed time to reach five seconds") { rig.controller.elapsed >= 5 }

        await rig.controller.stop()

        #expect(rig.controller.state == .idle)
        #expect(rig.controller.elapsed == 0)
        #expect(rig.controller.levels == CallLevels())
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        // Both track files were finished with both captures already stopped.
        #expect(rig.orderLog.value == [1, 1, 1, 1])

        let manifest = try CallRecordingManifest.read(from: folder)
        #expect(manifest.status == .finished)
        #expect(manifest.track(.me)?.startOffset == 0.125)
        #expect(manifest.track(.others)?.startOffset == 0.5)

        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.sourceKind == .call)
        #expect(stored?.header.title == CallRecordingLayout.transcriptTitle(
            startedAt: CallTestTime.now))
        #expect(stored?.header.duration == 5)
        #expect(stored?.header.status == .inProgress)
        #expect(stored?.header.createdAt == CallTestTime.now.addingTimeInterval(5))
        #expect(stored?.sourceBookmark == Data(folder.path.utf8))
        #expect(stored?.run == TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                     language: rig.settings.value.transcriptionLanguage))
        #expect(rig.transcribes.value == [1])
        #expect(rig.changes.value == 1)
        #expect(rig.folders.removed.isEmpty)
    }

    /// With transcription after Stop switched off, the call is kept for later: the row waits
    /// `incomplete` with a reason that says how to start it, and no job runs.
    @Test func withTranscriptionAfterStopOffTheRowWaitsAndNoJobStarts() async throws {
        let rig = try Rig()
        rig.settings.value.transcribeCallsAfterRecording = false
        await startRecording(rig)

        await rig.controller.stop()

        #expect(rig.transcribes.value.isEmpty)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == CallRecordingController.notTranscribedYetReason)
        #expect(rig.controller.state == .idle)
    }

    @Test func aToggleDuringStartingStopsAsSoonAsCaptureIsUp() async throws {
        let rig = try Rig()
        let gate = AsyncGate()
        rig.permissions.statuses = [.microphone: .undetermined]
        rig.permissions.requestResults = [.microphone: .granted]
        rig.permissions.statusGate = gate

        rig.controller.toggle()
        await waitFor("the start to suspend on the permission check") { gate.waiterCount == 1 }
        rig.controller.toggle()
        #expect(rig.controller.state == .starting)

        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.state == .idle)
        #expect(rig.microphone.startCount == 1)
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        let createCount = await rig.store.createCount
        #expect(createCount == 1)
        #expect(rig.transcribes.value == [1])
    }

    @Test func aWriterFailureStopsTheRecordingAndKeepsTheFilesAndTranscribesThem() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        rig.writers.fail(.me, in: folder, with: MacomprendoError.callRecordingWriteFailed("disk"))

        await waitFor("the failed state") {
            rig.controller.state == .failed(
                ErrorText.describe(MacomprendoError.callRecordingWriteFailed("disk")))
        }
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.sourceKind == .call)
        #expect(rig.transcribes.value == [1])
        #expect(rig.folders.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aWriterFailureArrivingAfterTheStopChangesNothing() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)
        await rig.controller.stop()
        #expect(rig.controller.state == .idle)
        #expect(rig.transcribes.value == [1])

        // A finished writer's queue can still report a failure; it must land nowhere.
        rig.writers.fail(.me, in: folder, with: MacomprendoError.callRecordingWriteFailed("late"))
        await Task.yield() // let the failure's hop to the main actor run before asserting

        #expect(rig.controller.state == .idle)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .inProgress)
        #expect(rig.transcribes.value == [1])
        #expect(rig.changes.value == 1)
    }

    @Test func aManifestRewriteFailureMidRecordingStopsWithAnError() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        // The folder turns unwritable mid-recording: the next rewrite of the manifest fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: folder.path)
        }
        rig.meWriter?.startOffset = 0.25

        await waitFor("the recording to stop with the location error") {
            rig.controller.state == .failed(
                ErrorText.describe(MacomprendoError.callRecordingLocationUnavailable))
        }
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        // A stop like any other: the files are kept and the job starts.
        #expect(rig.transcribes.value == [1])
        #expect(rig.changes.value == 1)
        #expect(rig.folders.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func systemWillSleepStopsLikeStop() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        await rig.controller.systemWillSleep()

        #expect(rig.controller.state == .idle)
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        let createCount = await rig.store.createCount
        #expect(createCount == 1)
        #expect(rig.transcribes.value == [1])
    }

    /// The row comes before the `.finished` manifest: a row that cannot be written must leave the
    /// recording `recording` for launch recovery to pick up — never finished with nothing
    /// pointing at it.
    @Test func aFailedTranscriptRowLeavesTheRecordingForLaunchRecovery() async throws {
        let rig = try Rig(createFailure: .transcriptStore("the disk is full"))
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        await rig.controller.stop()

        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.transcriptStore("the disk is full"))))
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        #expect(try CallRecordingManifest.read(from: folder).status == .recording)
        let createCount = await rig.store.createCount
        #expect(createCount == 0)
        #expect(rig.transcribes.value.isEmpty)
        #expect(rig.changes.value == 0)
        #expect(rig.folders.removed.isEmpty)
    }

    @Test func shutdownLeavesAnIncompleteRowAndNoJob() async throws {
        let rig = try Rig()
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        await rig.controller.shutdown()

        #expect(rig.controller.state == .idle)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.sourceKind == .call)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == TranscriptLibraryController.abandonedJobReason)
        #expect(rig.transcribes.value.isEmpty)
        #expect(rig.folders.removed.isEmpty)
    }

    @Test func shutdownDuringAnInFlightStopLeavesTheRowIncompleteAndStartsNoJob() async throws {
        let gate = AsyncGate()
        let rig = try Rig(finishGate: gate)
        await startRecording(rig)
        let folder = try #require(rig.folders.folders.first)

        // A stop, held in flight inside the first track's `finish()`...
        let stopTask = Task { await rig.controller.stop() }
        await waitFor("the stop to suspend finishing the first track") { gate.waiterCount == 1 }
        #expect(rig.controller.state == .stopping)

        // ...and the quit landing on it. Both are main-actor jobs and the shutdown's was
        // queued first, so its request lands before the gate releases the stop.
        let shutdownTask = Task { await rig.controller.shutdown() }
        gate.open()
        await shutdownTask.value
        await stopTask.value

        #expect(rig.controller.state == .idle)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        #expect(rig.microphone.stopCount == 1)
        #expect(rig.systemAudio.stopCount == 1)
        #expect(rig.meWriter?.finished == true)
        #expect(rig.othersWriter?.finished == true)
        let createCount = await rig.store.createCount
        #expect(createCount == 1)
        let stored = await rig.store.snapshot(1)
        #expect(stored?.header.status == .incomplete)
        #expect(stored?.header.statusReason == TranscriptLibraryController.abandonedJobReason)
        #expect(rig.transcribes.value.isEmpty)
        #expect(rig.changes.value == 1)
        #expect(rig.folders.removed.isEmpty)
    }

    @Test func shutdownWhileIdleDoesNothing() async throws {
        let rig = try Rig()

        await rig.controller.shutdown()

        #expect(rig.controller.state == .idle)
        #expect(rig.folders.created.isEmpty)
        let createCount = await rig.store.createCount
        #expect(createCount == 0)
        #expect(rig.transcribes.value.isEmpty)
    }

    @Test func aToggleAfterAFailureStartsANewRecording() async throws {
        let rig = try Rig()
        rig.folders.createError = MacomprendoError.callRecordingLocationUnavailable
        rig.controller.toggle()
        await rig.controller.drain()
        #expect(rig.controller.state == .failed(
            ErrorText.describe(MacomprendoError.callRecordingLocationUnavailable)))

        await startRecording(rig)

        #expect(rig.microphone.startCount == 1)
        #expect(rig.folders.created.count == 1)
        #expect(!rig.folders.folders.isEmpty)
    }

    @Test func elapsedAdvancesWithTicksAndResetsWhenIdle() async throws {
        let rig = try Rig()
        await startRecording(rig)

        rig.nowValue.value = rig.nowValue.value.addingTimeInterval(2)
        await waitFor("the elapsed time to advance") { rig.controller.elapsed >= 2 }

        await rig.controller.stop()

        #expect(rig.controller.elapsed == 0)
    }

    // MARK: - Hotkey handling

    /// `recordCall` toggles, exactly as the menu item does: a press while idle starts, the
    /// next press stops.
    @Test func aRecordCallKeyDownTogglesTheRecording() async throws {
        let rig = try Rig()

        rig.controller.handle(.keyDown(.recordCall))
        await rig.controller.drain()
        #expect(rig.controller.state == .recording(startedAt: rig.nowValue.value))

        rig.controller.handle(.keyDown(.recordCall))
        await rig.controller.drain()
        #expect(rig.controller.state == .idle)
        #expect(rig.microphone.stopCount == 1)
    }

    /// The key-up and every other action are not this controller's: nothing starts, nothing
    /// stops.
    @Test func keyUpAndOtherActionsDoNothing() async throws {
        let rig = try Rig()
        await startRecording(rig)

        rig.controller.handle(.keyUp(.recordCall))
        rig.controller.handle(.keyDown(.dictate))
        rig.controller.handle(.keyUp(.summarize))
        rig.controller.handle(.keyDown(.speak))
        await rig.controller.drain()

        #expect(rig.controller.state == .recording(startedAt: rig.nowValue.value))
        #expect(rig.microphone.stopCount == 0)

        let idle = try Rig()
        idle.controller.handle(.keyUp(.recordCall))
        idle.controller.handle(.keyDown(.dictate))
        await idle.controller.drain()
        #expect(idle.controller.state == .idle)
        #expect(idle.microphone.startCount == 0)
        #expect(idle.folders.created.isEmpty)
    }
}
