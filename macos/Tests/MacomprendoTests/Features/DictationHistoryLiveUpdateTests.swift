import Foundation
import Testing
@testable import Macomprendo

/// A dictation that lands while the history window or the Settings screen is open must show up
/// there without the user closing and reopening it. Both surfaces read the controller, so both
/// regressions live here.
@MainActor
@Suite struct DictationHistoryLiveUpdateTests {
    private func makeController(store: FakeDictationHistoryStore,
                                encoder: FakeDictationAudioEncoder? = nil,
                                savesRecording: Bool = false) -> DictationHistoryController {
        DictationHistoryController(store: store,
                                   pasteboard: FakePasteboard(),
                                   isEnabled: { true },
                                   encoder: encoder,
                                   shouldSaveRecording: { savesRecording })
    }

    @Test func anAppendedEntryAppearsInAnAlreadyLoadedWindow() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [], nextCursor: nil)])
        let controller = makeController(store: store)
        await controller.loadInitial()
        #expect(controller.entries.isEmpty)

        _ = await controller.append(text: "the new dictation", kind: .dictation)

        #expect(controller.entries.map(\.text) == ["the new dictation"])
    }

    @Test func theNewestEntryIsFirst() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [], nextCursor: nil)])
        let controller = makeController(store: store)
        await controller.loadInitial()

        _ = await controller.append(text: "older", kind: .dictation)
        _ = await controller.append(text: "newer", kind: .dictation)

        #expect(controller.entries.map(\.text) == ["newer", "older"])
    }

    @Test func anEntryIsNotDuplicatedWhenItsRecordingIsAttached() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [], nextCursor: nil)])
        let encoder = FakeDictationAudioEncoder()
        let controller = makeController(store: store, encoder: encoder, savesRecording: true)
        await controller.loadInitial()

        let appended = await controller.append(text: "with audio", kind: .dictation)
        _ = await controller.saveRecording([0.1, 0.2], for: appended.entry)

        #expect(controller.entries.count == 1)
        #expect(controller.entries.first?.audioFileName != nil)
    }

    @Test func anAppendWhileHistoryIsOffChangesNothing() async {
        let store = FakeDictationHistoryStore()
        let controller = DictationHistoryController(store: store,
                                                    pasteboard: FakePasteboard(),
                                                    isEnabled: { false })

        _ = await controller.append(text: "ignored", kind: .dictation)

        #expect(controller.entries.isEmpty)
    }

    // MARK: - The saved-audio size readout

    @Test func savingARecordingBumpsTheSavedAudioRevision() async {
        let store = FakeDictationHistoryStore()
        let encoder = FakeDictationAudioEncoder()
        let controller = makeController(store: store, encoder: encoder, savesRecording: true)
        let before = controller.savedAudioRevision

        let appended = await controller.append(text: "with audio", kind: .dictation)
        _ = await controller.saveRecording([0.1], for: appended.entry)

        #expect(controller.savedAudioRevision > before)
    }

    @Test func deletingSavedAudioBumpsTheSavedAudioRevision() async {
        let store = FakeDictationHistoryStore()
        await store.setStoredAudioFilenames(["1.m4a"])
        let controller = makeController(store: store)
        let before = controller.savedAudioRevision

        _ = await controller.deleteSavedAudio()

        #expect(controller.savedAudioRevision > before)
    }

    @Test func retentionDeletingRecordingsBumpsTheSavedAudioRevision() async {
        let store = FakeDictationHistoryStore()
        await store.setExpiredAudioFilenames(["old.m4a"])
        let controller = DictationHistoryController(store: store,
                                                    pasteboard: FakePasteboard(),
                                                    isEnabled: { true },
                                                    retention: { .thirtyDays })
        let before = controller.savedAudioRevision

        _ = await controller.applyRetention()

        #expect(controller.savedAudioRevision > before)
    }

    @Test func retentionThatDeletesNoRecordingsLeavesTheRevisionAlone() async {
        let store = FakeDictationHistoryStore()
        let controller = DictationHistoryController(store: store,
                                                    pasteboard: FakePasteboard(),
                                                    isEnabled: { true },
                                                    retention: { .thirtyDays })
        let before = controller.savedAudioRevision

        _ = await controller.applyRetention()

        #expect(controller.savedAudioRevision == before)
    }

    @Test func clearingHistoryBumpsTheSavedAudioRevision() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store)
        let before = controller.savedAudioRevision

        await controller.clear()

        #expect(controller.savedAudioRevision > before)
    }

    @Test func theSizeReadoutFollowsARecordingSavedWhileSettingsIsOpen() async {
        let store = FakeDictationHistoryStore()
        await store.setAudioDirectoryByteCount(0)
        let encoder = FakeDictationAudioEncoder()
        let controller = makeController(store: store, encoder: encoder, savesRecording: true)
        let model = SavedAudioModel(history: controller, revealer: FakeFileRevealer())
        await model.refreshSize()
        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))

        await store.setAudioDirectoryByteCount(96_000)
        let appended = await controller.append(text: "with audio", kind: .dictation)
        _ = await controller.saveRecording([0.1], for: appended.entry)
        await model.refreshIfSavedAudioChanged()

        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 96_000,
                                                            countStyle: .file))
    }

    @Test func theSizeReadoutIsNotReReadWhenNothingChanged() async {
        let store = FakeDictationHistoryStore()
        await store.setAudioDirectoryByteCount(4_096)
        let controller = makeController(store: store)
        let model = SavedAudioModel(history: controller, revealer: FakeFileRevealer())
        await model.refreshSize()
        let readsAfterFirstRefresh = await store.audioDirectoryByteCountCallCount

        await model.refreshIfSavedAudioChanged()

        #expect(await store.audioDirectoryByteCountCallCount == readsAfterFirstRefresh)
    }
}
