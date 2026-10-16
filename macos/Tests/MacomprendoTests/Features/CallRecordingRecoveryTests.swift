import Foundation
import Testing
@testable import Macomprendo

private func recoveryTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecordingRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `FileBookmarking` that can neither bookmark nor resolve anything — the folder launch recovery
/// has to leave alone rather than give a row the next launch could not find again.
private struct UnbookmarkableFileBookmarks: FileBookmarking {
    func bookmark(for url: URL) throws -> Data {
        throw MacomprendoError.sourceFileUnavailable
    }

    func resolve(_ bookmark: Data) throws -> URL {
        throw MacomprendoError.sourceFileUnavailable
    }
}

/// `CallRecordingRecovery`: the launch pass that finalises call recordings a crash left and
/// gives each one without a transcript an `incomplete` call transcript.
@MainActor
@Suite struct CallRecordingRecoveryTests {
    private let startedAt = Date(timeIntervalSince1970: 1_792_071_727)
    private let runStub = TranscriptionRun(modelID: nil, engine: nil, language: nil,
                                           appVersion: "test")

    @MainActor
    private final class Rig {
        let root: URL
        let folders: FakeCallRecordingFolders
        let store: FakeTranscriptStore
        /// What the recovery writes rows through, so a test can arm a failing `create`.
        let storeCreateFailure: CreateFailingTranscriptStore
        let bookmarks: FakeFileBookmarks
        let settings: SettingsHolder
        let nowValue: Box<Date>
        /// When the process that runs the recovery is taken to have launched — between the
        /// folders the other tests leave behind (an earlier process's) and the ones a recording
        /// made by *this* process would carry.
        let launchDate: Date
        let recovery: CallRecordingRecovery

        init() throws {
            let root = try recoveryTempDirectory()
            let folders = FakeCallRecordingFolders(realDirectoryRoot: root)
            let store = FakeTranscriptStore()
            let storeCreateFailure = CreateFailingTranscriptStore(wrapping: store)
            let bookmarks = FakeFileBookmarks()
            let settings = SettingsHolder()
            let nowValue = Box(Date(timeIntervalSince1970: 1_792_071_999))
            let launchDate = Date(timeIntervalSince1970: 1_792_071_900)
            let recovery = CallRecordingRecovery(
                folders: folders, store: storeCreateFailure, bookmarks: bookmarks,
                settings: { settings.value }, now: { nowValue.value }, launchDate: launchDate)
            settings.value.callRecordingsDirectory = root.path

            self.root = root
            self.folders = folders
            self.store = store
            self.storeCreateFailure = storeCreateFailure
            self.bookmarks = bookmarks
            self.settings = settings
            self.nowValue = nowValue
            self.launchDate = launchDate
            self.recovery = recovery
        }

        /// A real folder under the root carrying a `recording.json` still saying `recording`,
        /// exactly as a crash mid-recording leaves it.
        @discardableResult
        func makeUnfinishedFolder(startedAt date: Date) throws -> URL {
            let folder = try folders.create(in: root, startedAt: date)
            try CallRecordingManifest(startedAt: date, folderName: folder.lastPathComponent)
                .write(to: folder)
            return folder
        }
    }

    @Test func aRecordingFolderBecomesFinishedAndGainsAnIncompleteCallTranscript() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        rig.folders.unfinished = [folder]
        #expect(try CallRecordingManifest.read(from: folder).status == .recording)

        let created = await rig.recovery.recover()

        #expect(created == 1)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        let stored = try #require(await rig.store.snapshot(1))
        #expect(stored.header.sourceKind == .call)
        #expect(stored.header.title == CallRecordingLayout.transcriptTitle(startedAt: startedAt))
        #expect(stored.header.duration == nil)
        #expect(stored.header.status == .incomplete)
        #expect(stored.header.statusReason == TranscriptLibraryController.abandonedJobReason)
        #expect(stored.header.createdAt == rig.nowValue.value)
        #expect(stored.sourceBookmark == Data(folder.path.utf8))
        #expect(stored.run == TranscriptionRun.from(rig.settings.value.transcriptionSource,
                                                    language: rig.settings.value.transcriptionLanguage))
    }

    @Test func recoveringTwiceCreatesOneTranscript() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        rig.folders.unfinished = [folder]

        #expect(await rig.recovery.recover() == 1)
        #expect(await rig.recovery.recover() == 0)

        #expect(await rig.store.createCount == 1)
    }

    /// A folder started at or after this process launched belongs to a recording this process
    /// is still making: finalising it mid-recording would split one call into two transcripts.
    /// The comparison is at whole-second precision, the precision `.iso8601` stores.
    @Test func aRecordingStartedByThisLaunchIsLeftAlone() async throws {
        let rig = try Rig()
        let before = try rig.makeUnfinishedFolder(startedAt: startedAt)
        let atLaunch = try rig.makeUnfinishedFolder(startedAt: rig.launchDate)
        let after = try rig.makeUnfinishedFolder(startedAt: rig.launchDate.addingTimeInterval(60))
        rig.folders.unfinished = [before, atLaunch, after]

        let created = await rig.recovery.recover()

        #expect(created == 1)
        #expect(try CallRecordingManifest.read(from: before).status == .finished)
        #expect(try CallRecordingManifest.read(from: atLaunch).status == .recording)
        #expect(try CallRecordingManifest.read(from: after).status == .recording)
        #expect(await rig.store.createCount == 1)
        #expect(await rig.store.snapshot(1)?.header.sourceKind == .call)
    }

    /// The window the row-before-manifest ordering exists for: a crash between the row and the
    /// `.finished` write leaves a still-`recording` folder a call row already points at. The pass
    /// has to finalise it and create no second row.
    @Test func anExistingCallTranscriptPointingAtTheFolderIsNotDuplicated() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        let id = await rig.store.create(
            sourceKind: .call, title: "Existing call",
            sourceBookmark: try rig.bookmarks.bookmark(for: folder),
            duration: 30, run: runStub, at: rig.nowValue.value)
        rig.folders.unfinished = [folder]

        let created = await rig.recovery.recover()

        #expect(created == 0)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        #expect(await rig.store.createCount == 1)
        #expect(await rig.store.snapshot(id)?.header.status == .inProgress)
    }

    @Test func aFileTranscriptPointingAtTheFolderDoesNotStopTheCallTranscript() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        _ = await rig.store.create(
            sourceKind: .file, title: "meeting.m4a",
            sourceBookmark: try rig.bookmarks.bookmark(for: folder),
            duration: nil, run: runStub, at: rig.nowValue.value)
        rig.folders.unfinished = [folder]

        #expect(await rig.recovery.recover() == 1)
        #expect(await rig.store.createCount == 2)
    }

    /// A row that cannot be written must not cost the recording: the folder stays `recording`,
    /// with nothing pointing at it, for the next launch to pick up again.
    @Test func aCreateFailureLeavesTheFolderForTheNextLaunchToRecover() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        rig.folders.unfinished = [folder]
        rig.storeCreateFailure.failNextCreateOnce(.transcriptStore("the disk is full"))

        #expect(await rig.recovery.recover() == 0)
        #expect(try CallRecordingManifest.read(from: folder).status == .recording)
        #expect(await rig.store.snapshot(1) == nil)

        #expect(await rig.recovery.recover() == 1)
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)
        #expect(await rig.store.snapshot(1)?.header.status == .incomplete)
    }

    @Test func aFolderWhoseBookmarkCannotBeMadeIsLeftForTheNextLaunch() async throws {
        let rig = try Rig()
        let folder = try rig.makeUnfinishedFolder(startedAt: startedAt)
        rig.folders.unfinished = [folder]
        let recovery = CallRecordingRecovery(
            folders: rig.folders, store: rig.storeCreateFailure,
            bookmarks: UnbookmarkableFileBookmarks(), settings: { rig.settings.value },
            now: { rig.nowValue.value })

        #expect(await recovery.recover() == 0)
        #expect(try CallRecordingManifest.read(from: folder).status == .recording)
        #expect(await rig.store.snapshot(1) == nil)
    }

    @Test func aStatusFailureOnOneFolderStillCountsAndTheNextIsStillRecovered() async throws {
        let rig = try Rig()
        let first = try rig.makeUnfinishedFolder(startedAt: startedAt)
        let second = try rig.makeUnfinishedFolder(startedAt: startedAt.addingTimeInterval(60))
        rig.folders.unfinished = [first, second]
        await rig.store.failNextStatusOnce(.transcriptStore("disk"))

        let created = await rig.recovery.recover()

        // The row exists, so it counts even though its status write failed — the next launch's
        // abandoned-job pass gives it the `incomplete` this pass could not write.
        #expect(created == 2)
        #expect(try CallRecordingManifest.read(from: first).status == .finished)
        #expect(try CallRecordingManifest.read(from: second).status == .finished)
        #expect(await rig.store.createCount == 2)
        #expect(await rig.store.snapshot(1)?.header.status == .inProgress)
        #expect(await rig.store.snapshot(2)?.header.status == .incomplete)
    }
}

extension FakeTranscriptStore {
    /// Arms the next `setStatus` to fail. The property is actor-isolated, so a test cannot
    /// assign it from outside the actor.
    func failNextStatusOnce(_ error: MacomprendoError) { failNextStatus = error }
}
