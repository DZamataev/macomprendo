import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct DictationHistoryControllerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let safeHistoryError = MacomprendoError.dictationHistory(
        "An error occurred while accessing history."
    )

    private struct TranscriptBearingStoreError: LocalizedError, Sendable {
        let transcript: String

        var errorDescription: String? {
            "The history store rejected: \(transcript)"
        }
    }

    private actor CopyFeedbackSleeper {
        private let gates: [AsyncGate]
        private(set) var callCount = 0
        private(set) var completedCallCount = 0

        init(gates: [AsyncGate]) {
            self.gates = gates
        }

        func sleep(for _: Duration) async {
            let gate = gates[callCount]
            callCount += 1
            await gate.wait()
            completedCallCount += 1
        }
    }

    private func makeController(store: FakeDictationHistoryStore = FakeDictationHistoryStore(),
                                pasteboard: FakePasteboard = FakePasteboard(),
                                enabled: Bool = true,
                                pageSize: Int = 2,
                                copyFeedbackSleep: @escaping @Sendable (Duration) async -> Void = { _ in })
        -> DictationHistoryController {
        DictationHistoryController(store: store, pasteboard: pasteboard,
                                   isEnabled: { enabled }, pageSize: pageSize,
                                   now: { date }, copyFeedbackSleep: copyFeedbackSleep)
    }

    private func entry(_ id: Int64, text: String = "entry") -> DictationHistoryEntry {
        DictationHistoryEntry(id: id, createdAt: date, kind: .dictation, text: text)
    }

    private func waitForFetches(_ count: Int, in store: FakeDictationHistoryStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.fetchRequests.count == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) fetch requests")
    }

    private func waitForCopySleeps(_ count: Int, in sleeper: CopyFeedbackSleeper) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await sleeper.callCount == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) copy-feedback sleeps")
    }

    private func waitForCopiedEntryID(_ entryID: Int64?, in controller: DictationHistoryController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if controller.copiedEntryID == entryID { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for copied entry ID \(String(describing: entryID))")
    }

    private func waitForCompletedCopySleeps(_ count: Int, in sleeper: CopyFeedbackSleeper) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await sleeper.completedCallCount == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) completed copy-feedback sleeps")
    }

    @Test func recordingIsEncodedAndAttachedToTheAppendedEntry() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { true }, retention: { .ninetyDays },
            now: { date })

        let result = await controller.append(text: "hello", kind: .dictation)
        let error = await controller.saveRecording([0.1, 0.2], for: result.entry)

        #expect(result.error == nil)
        #expect(error == nil)
        #expect(await encoder.requests.map(\.pcm) == [[0.1, 0.2]])
        #expect(await encoder.requests.map(\.sampleRate) == [16_000])
        #expect(await store.attachRequests == [.init(filename: "1.m4a", entryID: 1)])
    }

    @Test func aRecordingSavedWhileTheWindowIsOpenBecomesImmediatelyPlayable() async {
        // A recording saved while the history window is open must not require a reopen (which
        // re-reads the directory via loadInitial) before its row offers playback — the window
        // must reflect the recording it just saved.
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { true }, retention: { .ninetyDays },
            now: { date })
        await store.setPages([DictationHistoryPage(entries: [], nextCursor: nil)])
        await controller.loadInitial()

        let result = await controller.append(text: "hello", kind: .dictation)
        let entry = try! #require(result.entry)
        let error = await controller.saveRecording([0.1, 0.2], for: entry)

        #expect(error == nil)
        #expect(controller.isPlayable(DictationHistoryEntry(
            id: entry.id, createdAt: entry.createdAt, kind: entry.kind, text: entry.text,
            audioFileName: "\(entry.id).m4a")))
        #expect(controller.entries.first(where: { $0.id == entry.id })?.audioFileName
                == "\(entry.id).m4a")
    }

    @Test func recordingPreferenceOffDoesNotCallEncoder() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { false }, retention: { .ninetyDays },
            now: { date })

        let result = await controller.append(text: "hello", kind: .dictation)
        #expect(await controller.saveRecording([0.1], for: result.entry) == nil)
        #expect(await encoder.requests.isEmpty)
        #expect(await store.attachRequests.isEmpty)
    }

    @Test func encoderFailureLeavesEntryUnattachedAndReturnsTheEncodingError() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let failure = MacomprendoError.audioEncoding("disk full")
        await encoder.setError(failure)
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { true }, retention: { .ninetyDays },
            now: { date })

        let result = await controller.append(text: "hello", kind: .dictation)
        #expect(await controller.saveRecording([0.1], for: result.entry) == failure)
        #expect(await store.attachRequests.isEmpty)
    }

    @Test func cancellationDuringSaveRecordingIsSilent() async {
        // Esc or a new hotkey press during the encode cancels this task on purpose, exactly
        // like every other cancellation path in the controller (`mappedHistoryError`,
        // `DictationCapture`, `DictationController.cancelledInFlight()`) — it must not leave
        // an "operation couldn't be completed" message sitting in the history window's error
        // banner for an action the user chose.
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        await encoder.setError(CancellationError())
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            encoder: encoder, shouldSaveRecording: { true }, retention: { .ninetyDays },
            now: { date })

        let result = await controller.append(text: "hello", kind: .dictation)
        let error = await controller.saveRecording([0.1], for: result.entry)

        #expect(error == nil)
        #expect(controller.errorMessage == nil)
        #expect(await store.attachRequests.isEmpty)
    }

    @Test func appendAppliesAgeRetentionAndDeletesExpiredAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: directory.appendingPathComponent("old.m4a"))
        let store = FakeDictationHistoryStore(audioDirectoryURL: directory)
        await store.setExpiredAudioFilenames(["old.m4a"])
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            retention: { .sevenDays }, now: { date })

        _ = await controller.append(text: "hello", kind: .dictation)

        #expect(await store.deleteOlderThanRequests == [date.addingTimeInterval(-7 * 86_400)])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.m4a").path))
    }

    @Test func launchMaintenancePurgesOrphansAndKeepsReferencedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["kept.m4a", "orphan.m4a"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let store = FakeDictationHistoryStore(audioDirectoryURL: directory)
        await store.setStoredAudioFilenames(["kept.m4a"])
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { true },
            retention: { .unlimited }, now: { date })

        #expect(await controller.performLaunchMaintenance() == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("kept.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("orphan.m4a").path))
    }

    @Test func disabledHistoryPerformsNoLaunchMaintenanceWork() async throws {
        // A user who has turned dictation history off must not have any transcripts deleted
        // by age retention just because the app launched — the feature performs no destructive
        // work while disabled.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: directory.appendingPathComponent("old.m4a"))
        let store = FakeDictationHistoryStore(audioDirectoryURL: directory)
        await store.setExpiredAudioFilenames(["old.m4a"])
        let controller = DictationHistoryController(
            store: store, pasteboard: FakePasteboard(), isEnabled: { false },
            retention: { .oneDay }, now: { date })

        #expect(await controller.performLaunchMaintenance() == nil)

        #expect(await store.deleteOlderThanRequests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.m4a").path))
    }

    @Test func disabledRecordingDoesNotTouchTheStore() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store, enabled: false)
        #expect(await controller.record(text: "hello", kind: .dictation) == nil)
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func enabledRecordingTrimsAndAppendsOnce() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store, enabled: true)
        #expect(await controller.record(text: "  hello \n", kind: .dictation) == nil)
        #expect(await store.appendRequests.map(\.text) == ["hello"])
        #expect(await store.appendRequests.map(\.date) == [date])
    }

    @Test func emptyRecordingDoesNotTouchTheStore() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store)
        #expect(await controller.record(text: " \n\t ", kind: .dictation) == nil)
        #expect(await store.appendRequests.isEmpty)
    }

    @Test func appendFailureIsReturnedAndPersistsAnErrorMessage() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("append failed")
        await store.setAppendError(failure)
        let controller = makeController(store: store)

        #expect(await controller.record(text: "hello", kind: .dictation) == safeHistoryError)
        #expect(controller.errorMessage == ErrorText.describe(safeHistoryError))
    }

    @Test func storageFailureNeverDisplaysTranscriptFromTheThrownError() async {
        let transcript = "private dictated words"
        let store = FakeDictationHistoryStore()
        await store.setAppendError(TranscriptBearingStoreError(transcript: transcript))
        let controller = makeController(store: store)

        _ = await controller.record(text: transcript, kind: .dictation)

        #expect(controller.errorMessage == "Dictation history is unavailable: An error occurred while accessing history. Open Dictation History and clear it, or check that Macomprendo can write to Application Support.")
        #expect(!controller.errorMessage!.contains(transcript))
    }

    @Test func initialLoadReplacesThePreviousPage() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(2, text: "old")], nextCursor: nil),
            DictationHistoryPage(entries: [entry(4, text: "new")], nextCursor: nil)
        ])
        let controller = makeController(store: store)

        await controller.loadInitial()
        await controller.loadInitial()

        #expect(controller.entries.map(\.id) == [4])
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, nil])
    }

    @Test func nextPageAppendsOnlyNewEntries() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3), entry(2)], nextCursor: 2),
            DictationHistoryPage(entries: [entry(2), entry(1)], nextCursor: nil)
        ])
        let controller = makeController(store: store)

        await controller.loadInitial()
        await controller.loadNextPage()

        #expect(controller.entries.map(\.id) == [3, 2, 1])
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, 2])
        #expect(!controller.hasMore)
    }

    @Test func nextPageDropsDuplicatesWithinTheFetchedPage() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(4)], nextCursor: 4),
            DictationHistoryPage(entries: [entry(3), entry(3), entry(2)], nextCursor: nil)
        ])
        let controller = makeController(store: store)

        await controller.loadInitial()
        await controller.loadNextPage()

        #expect(controller.entries.map(\.id) == [4, 3, 2])
    }

    @Test func secondPageLoadIsIgnoredWhileTheFirstIsActive() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(2)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let loading = Task { await controller.loadNextPage() }
        await waitForFetches(2, in: store)
        await controller.loadNextPage()

        #expect(await store.fetchRequests.count == 2)
        gate.open()
        await loading.value
    }

    @Test func clearEmptiesEntriesAndResetsTheCursor() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(5)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()

        await controller.clear()
        await controller.loadInitial()

        #expect(await store.clearCallCount == 1)
        #expect(await store.fetchRequests.map(\.beforeID) == [nil, nil])
        #expect(controller.entries.map(\.id) == [5])
    }

    @Test func fetchFailurePersistsAnErrorMessage() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("fetch failed")
        await store.setFetchError(failure)
        let controller = makeController(store: store)

        await controller.loadInitial()

        #expect(controller.entries.isEmpty)
        #expect(controller.errorMessage == ErrorText.describe(safeHistoryError))
        #expect(!controller.isLoading)
    }

    @Test func clearFailurePersistsAnErrorMessageWithoutThrowing() async {
        let store = FakeDictationHistoryStore()
        let failure = MacomprendoError.dictationHistory("clear failed")
        await store.setClearError(failure)
        let controller = makeController(store: store)

        await controller.clear()

        #expect(controller.errorMessage == ErrorText.describe(safeHistoryError))
        #expect(!controller.isLoading)
    }

    @Test func clearInvalidatesAnInFlightPageLoad() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(3)], nextCursor: 3),
            DictationHistoryPage(entries: [entry(2)], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        await controller.loadInitial()
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let loading = Task { await controller.loadNextPage() }
        await waitForFetches(2, in: store)
        await controller.clear()
        gate.open()
        await loading.value

        #expect(controller.entries.isEmpty)
        #expect(controller.hasMore)
    }

    @Test func cancelThenReloadIgnoresTheStalePage() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([
            DictationHistoryPage(entries: [entry(1, text: "stale")], nextCursor: nil),
            DictationHistoryPage(entries: [entry(2, text: "fresh")], nextCursor: nil)
        ])
        let controller = makeController(store: store)
        let gate = AsyncGate()
        await store.setFetchGate(gate)

        let firstLoad = Task { await controller.loadInitial() }
        await waitForFetches(1, in: store)
        controller.cancelLoading()
        let reloaded = Task { await controller.loadInitial() }
        await waitForFetches(2, in: store)
        gate.open()
        await firstLoad.value
        await reloaded.value

        #expect(controller.entries.map(\.text) == ["fresh"])
        #expect(!controller.isLoading)
    }

    // Catches lifecycle cancellation invalidating publication without cancelling the actual
    // store request, leaving scene-launched page work running after the window closes.
    @Test func cancelLoadingCancelsTheControllerOwnedStoreRequest() async {
        let store = FakeDictationHistoryStore()
        let gate = AsyncGate()
        await store.setFetchGate(gate)
        let controller = makeController(store: store)

        let loading = Task { await controller.loadInitial() }
        await waitForFetches(1, in: store)
        controller.cancelLoading()
        gate.open()
        await loading.value

        #expect(await store.cancelledFetchCount == 1)
        #expect(controller.entries.isEmpty)
        #expect(!controller.isLoading)
    }

    @Test func copyWritesTheCompleteTranscript() {
        let pasteboard = FakePasteboard()
        let controller = makeController(pasteboard: pasteboard)
        controller.copy(DictationHistoryEntry(id: 1, createdAt: .now,
                                              kind: .dictation, text: "full text"))
        #expect(pasteboard.readString() == "full text")
        #expect(controller.copiedEntryID == 1)
    }

    @Test func copyFeedbackExpiresAfterItsControlledLifetime() async {
        let gate = AsyncGate()
        let sleeper = CopyFeedbackSleeper(gates: [gate])
        let controller = makeController(copyFeedbackSleep: { duration in
            await sleeper.sleep(for: duration)
        })

        controller.copy(entry(1, text: "full text"))
        await waitForCopySleeps(1, in: sleeper)
        #expect(controller.copiedEntryID == 1)

        gate.open()
        await waitForCopiedEntryID(nil, in: controller)
        #expect(controller.copiedEntryID == nil)
    }

    @Test func olderCopyFeedbackExpiryCannotClearNewerCopyFeedback() async {
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let sleeper = CopyFeedbackSleeper(gates: [firstGate, secondGate])
        let controller = makeController(copyFeedbackSleep: { duration in
            await sleeper.sleep(for: duration)
        })

        controller.copy(entry(1, text: "first"))
        await waitForCopySleeps(1, in: sleeper)
        controller.copy(entry(2, text: "second"))
        await waitForCopySleeps(2, in: sleeper)

        firstGate.open()
        await waitForCompletedCopySleeps(1, in: sleeper)

        #expect(controller.copiedEntryID == 2)
        secondGate.open()
    }
}
