import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TranscriptLibraryControllerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let run = TranscriptionRun(modelID: "base", engine: "whisperCpp", language: "ru",
                                       appVersion: "1.2.3")

    private func makeController(store: FakeTranscriptStore = FakeTranscriptStore(),
                                pasteboard: FakePasteboard = FakePasteboard(),
                                bookmarks: FakeFileBookmarks = FakeFileBookmarks(),
                                revealer: FakeFileRevealer = FakeFileRevealer())
        -> TranscriptLibraryController {
        TranscriptLibraryController(store: store, pasteboard: pasteboard,
                                    bookmarks: bookmarks, revealer: revealer)
    }

    /// Stores one transcript and returns its id. `status` defaults to `complete`, the state a
    /// finished job leaves behind; `.inProgress` leaves the row as a launch would find it.
    @discardableResult
    private func store(_ store: FakeTranscriptStore, title: String,
                       segments: [TranscriptSegment] = [],
                       status: TranscriptStatus = .complete) async throws -> Int64 {
        let id = await store.create(sourceKind: .file, title: title, sourceBookmark: nil,
                                    duration: 12, run: run, at: date)
        for segment in segments { try await store.appendSegment(segment, to: id) }
        if status != .inProgress {
            try await store.setStatus(status, reason: nil, for: id)
        }
        return id
    }

    private let twoSegments = [TranscriptSegment(start: 0, end: 1, text: "One."),
                               TranscriptSegment(start: 1, end: 2, text: "Two.")]

    // MARK: - Listing

    @Test func reloadListsNewestFirst() async throws {
        let store = FakeTranscriptStore()
        try await self.store(store, title: "first")
        try await self.store(store, title: "second")
        try await self.store(store, title: "third")
        let controller = makeController(store: store)

        await controller.reload()

        #expect(controller.headers.map(\.title) == ["third", "second", "first"])
        #expect(controller.headers.map(\.id) == [3, 2, 1])
        #expect(controller.error == nil)
    }

    // MARK: - Selecting

    @Test func selectLoadsSegments() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a", segments: twoSegments)
        let controller = makeController(store: store)

        await controller.select(id)

        #expect(controller.selected?.id == id)
        #expect(controller.selected?.segments == twoSegments)
        #expect(controller.error == nil)
    }

    @Test func selectNilClearsTheSelection() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a")
        let controller = makeController(store: store)
        await controller.select(id)
        #expect(controller.selected != nil)

        await controller.select(nil)

        #expect(controller.selected == nil)
    }

    @Test func reloadAfterSegmentAppendRefreshesSelected() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a",
                                      segments: [TranscriptSegment(start: 0, end: 1, text: "One.")])
        let controller = makeController(store: store)
        await controller.select(id)
        #expect(controller.selected?.segments.count == 1)

        // A running job writes a segment; the open transcript must follow it.
        try await store.appendSegment(TranscriptSegment(start: 1, end: 2, text: "Two."), to: id)
        await controller.reload()

        #expect(controller.selected?.segments.count == 2)
        #expect(controller.selected?.segments.last?.text == "Two.")
    }

    @Test func reloadDropsASelectedTranscriptThatIsGone() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a")
        let controller = makeController(store: store)
        await controller.select(id)
        #expect(controller.selected != nil)

        try await store.delete(id: id)
        await controller.reload()

        #expect(controller.selected == nil)
        #expect(controller.headers.isEmpty)
    }

    // MARK: - Deleting

    @Test func deleteOfTheSelectedClearsIt() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a")
        let controller = makeController(store: store)
        await controller.reload()
        await controller.select(id)

        await controller.delete(id)

        #expect(controller.selected == nil)
        #expect(controller.headers.isEmpty)
        #expect(controller.error == nil)
    }

    @Test func deleteOfAnotherTranscriptKeepsTheSelection() async throws {
        let store = FakeTranscriptStore()
        let kept = try await self.store(store, title: "kept")
        let doomed = try await self.store(store, title: "doomed")
        let controller = makeController(store: store)
        await controller.reload()
        await controller.select(kept)

        await controller.delete(doomed)

        #expect(controller.selected?.id == kept)
        #expect(controller.headers.map(\.id) == [kept])
    }

    // MARK: - Copying

    @Test func copyWritesPlainTextWithoutTimestamps() async throws {
        let store = FakeTranscriptStore()
        let pasteboard = FakePasteboard()
        let id = try await self.store(store, title: "talk.m4a", segments: twoSegments)
        let controller = makeController(store: store, pasteboard: pasteboard)
        await controller.select(id)

        controller.copySelected()

        #expect(pasteboard.readString() == "One.\nTwo.")
    }

    @Test func copyWithNothingSelectedWritesNothing() {
        let pasteboard = FakePasteboard(string: "before")
        let controller = makeController(pasteboard: pasteboard)

        controller.copySelected()

        #expect(pasteboard.readString() == "before")
        #expect(pasteboard.changeCount == 1)
    }

    // MARK: - Exporting

    @Test func exportRendersThroughTheExporter() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a", segments: twoSegments)
        let controller = makeController(store: store)
        await controller.select(id)

        let selected = try #require(controller.selected)
        for format in TranscriptExportFormat.allCases {
            #expect(controller.exportText(format) == TranscriptExporter.render(selected, as: format))
        }
        #expect(controller.exportText(.plainText) == "One.\nTwo.\n")
    }

    @Test func exportWithNothingSelectedIsNil() {
        let controller = makeController()

        #expect(controller.exportText(.plainText) == nil)
        #expect(controller.exportText(.subRip) == nil)
    }

    // MARK: - Launch maintenance

    @Test func launchMaintenanceMarksAbandonedJobs() async throws {
        let store = FakeTranscriptStore()
        let running = try await self.store(store, title: "interrupted", status: .inProgress)
        let finished = try await self.store(store, title: "finished", status: .complete)
        let controller = makeController(store: store)
        await controller.reload()

        await controller.performLaunchMaintenance()

        let marked = try #require(await store.snapshot(running))
        #expect(marked.header.status == .incomplete)
        #expect(marked.header.statusReason == "Macomprendo quit before it finished.")
        let untouched = try #require(await store.snapshot(finished))
        #expect(untouched.header.status == .complete)
        #expect(controller.headers.first { $0.id == running }?.status == .incomplete)
        #expect(controller.error == nil)
    }

    // MARK: - Failures

    @Test func aStoreFailureSetsError() async throws {
        let store = FakeTranscriptStore()
        await store.failNextReadOnce(.transcriptStore("the disk is full"))
        let controller = makeController(store: store)

        await controller.reload()

        #expect(controller.error
                == ErrorText.describe(MacomprendoError.transcriptStore("the disk is full")))
        #expect(controller.headers.isEmpty)
    }

    // MARK: - Races

    @Test func aStaleSelectDoesNotOverwriteANewerSelection() async throws {
        let store = FakeTranscriptStore()
        let first = try await self.store(store, title: "first")
        let second = try await self.store(store, title: "second")
        let controller = makeController(store: store)
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)

        // The first select is held inside its store read.
        let stale = Task { await controller.select(first) }
        await waitFor("the first select to reach the store read") { gate.waiterCount == 1 }

        // A newer selection lands and completes while the first read is still in flight.
        await controller.select(second)
        #expect(controller.selected?.id == second)

        gate.open()
        await stale.value

        // The stale read must not resurrect the older selection.
        #expect(controller.selected?.id == second)
    }

    @Test func aStaleSelectDoesNotResurrectADeletedTranscript() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a")
        let controller = makeController(store: store)
        await controller.reload()
        #expect(controller.headers.map(\.id) == [id])
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)

        // A select for `id` is held inside its store read.
        let stale = Task { await controller.select(id) }
        await waitFor("the select to reach the store read") { gate.waiterCount == 1 }

        // The transcript is deleted while that read is still in flight.
        await controller.delete(id)
        #expect(controller.selected == nil)
        #expect(controller.headers.isEmpty)

        gate.open()
        await stale.value

        // The stale read must not resurrect the deleted row.
        #expect(controller.selected == nil)
    }

    @Test func aReloadDuringDeleteDoesNotKeepTheDeletedRow() async throws {
        let store = FakeTranscriptStore()
        let doomed = try await self.store(store, title: "doomed")
        let controller = makeController(store: store)
        await controller.reload()
        #expect(controller.headers.map(\.id) == [doomed])

        // The delete is held inside the store before it commits the removal.
        let deleteGate = AsyncGate()
        await store.gateNextDelete(on: deleteGate)
        let deletion = Task { await controller.delete(doomed) }
        await waitFor("the delete to reach the store") { deleteGate.waiterCount == 1 }

        // A reload starts while the delete is in flight; its headers read captures the list with
        // the row still present, then holds before delivering it.
        let headersGate = AsyncGate()
        await store.gateNextHeadersRead(on: headersGate)
        let reload = Task { await controller.reload() }
        await waitFor("the reload to reach the headers read") { headersGate.waiterCount == 1 }

        // The delete commits first, then the stale reload read is released.
        deleteGate.open()
        await deletion.value
        headersGate.open()
        await reload.value

        // The reload that started during the delete must not undo its pruning.
        #expect(controller.headers.map(\.id) == [])
    }

    @Test func aSelectDuringReloadKeepsItsResult() async throws {
        let store = FakeTranscriptStore()
        let first = try await self.store(store, title: "first")
        let second = try await self.store(store, title: "second")
        let controller = makeController(store: store)
        await controller.select(first)
        #expect(controller.selected?.id == first)

        // A select for the second transcript is held inside its store read.
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)
        let selection = Task { await controller.select(second) }
        await waitFor("the select to reach the store read") { gate.waiterCount == 1 }

        // A reload runs to completion while that select is still in flight.
        await controller.reload()

        gate.open()
        await selection.value

        // The reload must not have invalidated the concurrent select.
        #expect(controller.selected?.id == second)
    }

    @Test func aDeleteStartedDuringASelectStillPrunesTheList() async throws {
        let store = FakeTranscriptStore()
        let doomed = try await self.store(store, title: "doomed")
        let kept = try await self.store(store, title: "kept")
        let controller = makeController(store: store)
        await controller.reload()
        #expect(controller.headers.map(\.id) == [kept, doomed])

        // A select is held inside its store read while the other row is deleted.
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)
        let selection = Task { await controller.select(kept) }
        await waitFor("the select to reach the store read") { gate.waiterCount == 1 }

        await controller.delete(doomed)

        // The delete must prune its row even though a select is in flight.
        #expect(controller.headers.map(\.id) == [kept])

        gate.open()
        await selection.value
    }

    @Test func aReloadReReadDoesNotRevertANewerSelection() async throws {
        let store = FakeTranscriptStore()
        let first = try await self.store(store, title: "first")
        let second = try await self.store(store, title: "second")
        let controller = makeController(store: store)
        await controller.select(first)
        #expect(controller.selected?.id == first)

        // The select of `second` starts first and is held inside its store read.
        let selectGate = AsyncGate()
        await store.gateNextRead(on: selectGate)
        let selection = Task { await controller.select(second) }
        await waitFor("the select to reach the store read") { selectGate.waiterCount == 1 }

        // A reload starts while that select is in flight; it re-reads the *current* selection
        // (`first`) and that re-read is held, so the reload resumes only after the select lands.
        let rereadGate = AsyncGate()
        await store.gateNextRead(of: first, on: rereadGate)
        let reload = Task { await controller.reload() }
        await waitFor("the reload to reach the transcript re-read") { rereadGate.waiterCount == 1 }

        selectGate.open()
        await selection.value
        #expect(controller.selected?.id == second)

        rereadGate.open()
        await reload.value

        // The reload's stale re-read of `first` must not revert the newer selection.
        #expect(controller.selected?.id == second)
    }

    @Test func aStaleReloadDoesNotClearANewerReloadsError() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a")
        let controller = makeController(store: store)
        await controller.select(id)
        #expect(controller.selected?.id == id)

        // The first reload's re-read of the open transcript is held.
        let rereadGate = AsyncGate()
        await store.gateNextRead(of: id, on: rereadGate)
        let stale = Task { await controller.reload() }
        await waitFor("the first reload to reach the re-read") { rereadGate.waiterCount == 1 }

        // A second reload starts and fails while the first is still in flight. Its failure is
        // the newest word on the list and must stand.
        await store.failNextReadOnce(.transcriptStore("the disk is full"))
        await controller.reload()
        #expect(controller.error
                == ErrorText.describe(MacomprendoError.transcriptStore("the disk is full")))

        // The stale reload resumes; clearing `error` here would drop the newer failure.
        rereadGate.open()
        await stale.value
        #expect(controller.error
                == ErrorText.describe(MacomprendoError.transcriptStore("the disk is full")))
    }

    @Test func anOlderReloadDoesNotRevertANewerReloadsSelection() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "talk.m4a",
                                      segments: [TranscriptSegment(start: 0, end: 1, text: "One.")])
        let controller = makeController(store: store)
        await controller.select(id)
        #expect(controller.selected?.segments.count == 1)

        // The first reload's re-read of the open transcript is held.
        let rereadGate = AsyncGate()
        await store.gateNextRead(of: id, on: rereadGate)
        let stale = Task { await controller.reload() }
        await waitFor("the first reload to reach the re-read") { rereadGate.waiterCount == 1 }

        // A segment lands while that re-read is in flight; a second reload picks it up and
        // completes.
        try await store.appendSegment(TranscriptSegment(start: 1, end: 2, text: "Two."), to: id)
        await controller.reload()
        #expect(controller.selected?.segments.count == 2)

        // The older reload resumes last; its stale snapshot must not revert the newer reload's.
        rereadGate.open()
        await stale.value
        #expect(controller.selected?.segments.count == 2)
        #expect(controller.selected?.segments.last?.text == "Two.")
    }

    @Test func deletingTheOpenRowDoesNotDropASelectOfAnotherRow() async throws {
        let store = FakeTranscriptStore()
        let open = try await self.store(store, title: "open")
        let wanted = try await self.store(store, title: "wanted")
        let controller = makeController(store: store)
        await controller.reload()
        await controller.select(open)
        #expect(controller.selected?.id == open)

        // A select of `wanted` is held inside its store read.
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)
        let selection = Task { await controller.select(wanted) }
        await waitFor("the select to reach the store read") { gate.waiterCount == 1 }

        // Deleting the *open* row must not drop the select that is opening another row; the
        // deleted row must not come back either.
        await controller.delete(open)
        #expect(controller.selected == nil)

        gate.open()
        await selection.value

        #expect(controller.selected?.id == wanted)
        #expect(controller.headers.map(\.id) == [wanted])
    }

    @Test func aDeleteOfAnotherRowDoesNotDropAnInFlightSelect() async throws {
        let store = FakeTranscriptStore()
        let open = try await self.store(store, title: "open")
        let wanted = try await self.store(store, title: "wanted")
        let doomed = try await self.store(store, title: "doomed")
        let controller = makeController(store: store)
        await controller.reload()
        await controller.select(open)
        #expect(controller.selected?.id == open)

        // A select of `wanted` is held inside its store read.
        let gate = AsyncGate()
        await store.gateNextRead(on: gate)
        let selection = Task { await controller.select(wanted) }
        await waitFor("the select to reach the store read") { gate.waiterCount == 1 }

        // Deleting an unrelated row must not invalidate the selection being opened.
        await controller.delete(doomed)

        gate.open()
        await selection.value

        #expect(controller.selected?.id == wanted)
        #expect(controller.headers.map(\.id) == [wanted, open])
    }

    // MARK: - Revealing a recording

    /// **Show in Finder** resolves the open call transcript's folder bookmark here,
    /// not in the view, and hands the folder to the revealer.
    @Test func revealSelectedRecordingRevealsTheBookmarkedFolder() async throws {
        let store = FakeTranscriptStore()
        let folder = URL(fileURLWithPath: "/recordings/rec 2026-10-15 16-42-07")
        let id = await store.create(sourceKind: .call, title: "Call 2026-10-15 16:42",
                                    sourceBookmark: Data(folder.path.utf8), duration: nil,
                                    run: run, at: date)
        try await store.setStatus(.complete, reason: nil, for: id)
        let revealer = FakeFileRevealer()
        let controller = makeController(store: store, revealer: revealer)
        await controller.select(id)

        controller.revealSelectedRecording()

        #expect(revealer.revealed == [folder])
        #expect(controller.error == nil)
    }

    /// A bookmark that no longer resolves reports the same failure `Resume` reports, and
    /// reveals nothing.
    @Test func revealSelectedRecordingReportsAMissingRecording() async throws {
        let store = FakeTranscriptStore()
        let folder = URL(fileURLWithPath: "/recordings/rec 2026-10-15 16-42-07")
        let id = await store.create(sourceKind: .call, title: "Call 2026-10-15 16:42",
                                    sourceBookmark: Data(folder.path.utf8), duration: nil,
                                    run: run, at: date)
        let revealer = FakeFileRevealer()
        let controller = makeController(store: store,
                                        bookmarks: FakeFileBookmarks(missing: [folder.path]),
                                        revealer: revealer)
        await controller.select(id)

        controller.revealSelectedRecording()

        #expect(revealer.revealed.isEmpty)
        #expect(controller.error == ErrorText.describe(MacomprendoError.callRecordingUnavailable))
    }

    /// A file transcript has no recording folder: the action does nothing at all.
    @Test func revealSelectedRecordingIgnoresAFileTranscript() async throws {
        let store = FakeTranscriptStore()
        let id = try await self.store(store, title: "lecture.mp3")
        let revealer = FakeFileRevealer()
        let controller = makeController(store: store, revealer: revealer)
        await controller.select(id)

        controller.revealSelectedRecording()

        #expect(revealer.revealed.isEmpty)
        #expect(controller.error == nil)
    }
}

extension FakeTranscriptStore {
    /// Arms the next read (`headers()` or `transcript(id:)`) to fail. The property is
    /// actor-isolated, so a test cannot assign it from outside the actor.
    func failNextReadOnce(_ error: MacomprendoError) { failNextRead = error }

    /// Arms the next `transcript(id:)` read to suspend on `gate`. The property is
    /// actor-isolated, so a test cannot assign it from outside the actor.
    func gateNextRead(on gate: AsyncGate) { readGate = gate }

    /// Arms the next `transcript(id:)` read *for `id`* to suspend on `gate`, so one transcript's
    /// read can be held while another's runs unblocked. The property is actor-isolated, so a test
    /// cannot assign it from outside the actor.
    func gateNextRead(of id: Int64, on gate: AsyncGate) { readGatesByID[id] = gate }

    /// Arms the next `headers()` read to suspend on `gate`. The property is actor-isolated, so a
    /// test cannot assign it from outside the actor.
    func gateNextHeadersRead(on gate: AsyncGate) { headersGate = gate }

    /// Arms the next `delete(id:)` to suspend on `gate`, before it commits the removal. The
    /// property is actor-isolated, so a test cannot assign it from outside the actor.
    func gateNextDelete(on gate: AsyncGate) { deleteGate = gate }
}
