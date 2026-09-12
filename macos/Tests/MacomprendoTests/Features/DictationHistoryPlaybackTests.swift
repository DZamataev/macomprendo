import Foundation
import Testing
@testable import Macomprendo

/// Playback of a saved recording from the history window: which rows offer a control, what
/// starting one does to the previous one, and what a vanished file does.
@MainActor
@Suite struct DictationHistoryPlaybackTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: Int64, audio: String?) -> DictationHistoryEntry {
        DictationHistoryEntry(id: id, createdAt: date, kind: .dictation, text: "entry \(id)",
                              audioFileName: audio)
    }

    private func makeController(store: FakeDictationHistoryStore,
                                player: FakeAudioPlayer) -> DictationHistoryController {
        DictationHistoryController(store: store, pasteboard: FakePasteboard(),
                                   isEnabled: { true }, player: player, pageSize: 10,
                                   now: { date })
    }

    @Test func onlyEntriesThatReferenceARecordingArePlayable() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(
            entries: [entry(3, audio: "3.m4a"), entry(2, audio: "2.m4a"), entry(1, audio: nil)],
            nextCursor: nil)])
        // Only entry 3's file is actually on disk. Entry 2 still offers the control: whether
        // the file survives is discovered when playback is attempted, not by hiding the button.
        await store.setAudioFiles(["3.m4a": Data([0x01, 0x02])])
        let controller = makeController(store: store, player: FakeAudioPlayer())

        await controller.loadInitial()

        #expect(controller.isPlayable(entry(3, audio: "3.m4a")))
        #expect(controller.isPlayable(entry(2, audio: "2.m4a")))
        #expect(controller.isPlayable(entry(1, audio: nil)) == false)
    }

    @Test func playingASecondEntryStopsTheFirst() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(
            entries: [entry(2, audio: "2.m4a"), entry(1, audio: "1.m4a")], nextCursor: nil)])
        await store.setAudioFiles(["1.m4a": Data([0x01]), "2.m4a": Data([0x02])])
        let player = FakeAudioPlayer()
        player.finishesImmediately = false
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()

        await controller.togglePlayback(entry(1, audio: "1.m4a"))
        #expect(controller.playingEntryID == 1)

        await controller.togglePlayback(entry(2, audio: "2.m4a"))

        #expect(controller.playingEntryID == 2)
        #expect(player.played == [Data([0x01]), Data([0x02])])
        #expect(player.stopCount >= 1)
    }

    @Test func togglingTheSameEntryStopsPlayback() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles(["1.m4a": Data([0x01])])
        let player = FakeAudioPlayer()
        player.finishesImmediately = false
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()

        await controller.togglePlayback(entry(1, audio: "1.m4a"))
        let stopsWhilePlaying = player.stopCount
        await controller.togglePlayback(entry(1, audio: "1.m4a"))

        #expect(controller.playingEntryID == nil)
        #expect(player.stopCount == stopsWhilePlaying + 1)
        #expect(player.played.count == 1)
    }

    @Test func finishingPlaybackClearsTheActiveEntry() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles(["1.m4a": Data([0x01])])
        let player = FakeAudioPlayer()
        player.finishesImmediately = false
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()

        await controller.togglePlayback(entry(1, audio: "1.m4a"))
        player.finishCurrent()

        #expect(controller.playingEntryID == nil)
    }

    @Test func aVanishedFileReportsAnErrorAndKeepsOfferingTheControl() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles(["1.m4a": Data([0x01])])
        let player = FakeAudioPlayer()
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()
        #expect(controller.isPlayable(entry(1, audio: "1.m4a")))

        await store.setAudioFiles([:])
        await controller.togglePlayback(entry(1, audio: "1.m4a"))

        #expect(controller.playingEntryID == nil)
        #expect(player.played.isEmpty)
        // The entry still references a recording, so the control stays: hiding it would claim
        // the dictation never had one, and the user could not retry after restoring the file.
        #expect(controller.isPlayable(entry(1, audio: "1.m4a")))
        #expect(controller.errorMessage != nil)
    }

    @Test func aMissingFileIsReportedAsAMissingFileNotAnOutputDeviceProblem() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles([:])
        let controller = makeController(store: store, player: FakeAudioPlayer())
        await controller.loadInitial()

        await controller.togglePlayback(entry(1, audio: "1.m4a"))

        let message = controller.errorMessage ?? ""
        #expect(message.contains("no longer on disk"))
        // The old text pointed at the output device, which has nothing to do with a file
        // somebody deleted.
        #expect(!message.contains("output device"))
    }

    @Test func playbackWorksAgainOnceTheFileIsBack() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles([:])
        let player = FakeAudioPlayer()
        player.finishesImmediately = false
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()
        await controller.togglePlayback(entry(1, audio: "1.m4a"))
        #expect(player.played.isEmpty)

        await store.setAudioFiles(["1.m4a": Data([0x01])])
        await controller.togglePlayback(entry(1, audio: "1.m4a"))

        #expect(player.played.count == 1)
        #expect(controller.playingEntryID == 1)
        #expect(controller.errorMessage == nil)
    }

    @Test func anEntryWithNoRecordingOffersNoControl() async {
        let store = FakeDictationHistoryStore()
        let controller = makeController(store: store, player: FakeAudioPlayer())

        #expect(controller.isPlayable(entry(1, audio: nil)) == false)
    }

    @Test func deletingSavedAudioStopsPlaybackAndClearsPlayableEntries() async {
        let store = FakeDictationHistoryStore()
        await store.setPages([DictationHistoryPage(entries: [entry(1, audio: "1.m4a")],
                                                   nextCursor: nil)])
        await store.setAudioFiles(["1.m4a": Data([0x01])])
        await store.setStoredAudioFilenames(["1.m4a"])
        let player = FakeAudioPlayer()
        player.finishesImmediately = false
        let controller = makeController(store: store, player: player)
        await controller.loadInitial()
        await controller.togglePlayback(entry(1, audio: "1.m4a"))

        #expect(await controller.deleteSavedAudio() == nil)

        #expect(controller.playingEntryID == nil)
        // Playability follows the entry the controller holds, whose reference the delete
        // cleared — not a locally built copy that still names a file.
        #expect(controller.entries.allSatisfy { !controller.isPlayable($0) })
        #expect(controller.entries.allSatisfy { $0.audioFileName == nil })
        #expect(await store.deleteAudioReferencesCallCount == 1)
    }

    @Test func savedAudioByteCountComesFromTheStore() async throws {
        let store = FakeDictationHistoryStore()
        await store.setAudioDirectoryByteCount(2_048)
        let controller = makeController(store: store, player: FakeAudioPlayer())

        #expect(try await controller.savedAudioByteCount() == 2_048)
    }
}
