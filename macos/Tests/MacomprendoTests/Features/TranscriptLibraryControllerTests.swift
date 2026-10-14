import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TranscriptLibraryControllerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let run = TranscriptionRun(modelID: "base", engine: "whisperCpp", language: "ru",
                                       appVersion: "1.2.3")

    private func makeController(store: FakeTranscriptStore = FakeTranscriptStore(),
                                pasteboard: FakePasteboard = FakePasteboard())
        -> TranscriptLibraryController {
        TranscriptLibraryController(store: store, pasteboard: pasteboard)
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
}

extension FakeTranscriptStore {
    /// Arms the next read (`headers()` or `transcript(id:)`) to fail. The property is
    /// actor-isolated, so a test cannot assign it from outside the actor.
    func failNextReadOnce(_ error: MacomprendoError) { failNextRead = error }

    /// Arms the next `transcript(id:)` read to suspend on `gate`. The property is
    /// actor-isolated, so a test cannot assign it from outside the actor.
    func gateNextRead(on gate: AsyncGate) { readGate = gate }
}
