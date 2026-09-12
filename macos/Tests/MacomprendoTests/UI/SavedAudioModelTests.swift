import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SavedAudioModelTests {
    private func makeModel(store: FakeDictationHistoryStore,
                           revealer: FakeFileRevealer = FakeFileRevealer())
        -> (SavedAudioModel, DictationHistoryController) {
        let history = DictationHistoryController(store: store,
                                                 pasteboard: FakePasteboard(),
                                                 isEnabled: { true })
        return (SavedAudioModel(history: history, revealer: revealer), history)
    }

    @Test func recordingToggleFollowsTheHistoryToggle() {
        var settings = Settings.default
        settings.dictationHistoryEnabled = false
        #expect(SavedAudioModel.recordingToggleIsEnabled(settings) == false)

        settings.dictationHistoryEnabled = true
        #expect(SavedAudioModel.recordingToggleIsEnabled(settings))
    }

    @Test func sizeTextFormatsTheDirectoryByteCount() async {
        let store = FakeDictationHistoryStore()
        await store.setAudioDirectoryByteCount(1_500_000)
        let (model, _) = makeModel(store: store)

        await model.refreshSize()

        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 1_500_000,
                                                            countStyle: .file))
        #expect(model.errorMessage == nil)
    }

    @Test func sizeFailureIsReportedAndLeavesThePlaceholder() async {
        let store = FakeDictationHistoryStore()
        await store.setAudioDirectoryError(MacomprendoError.dictationHistory("unreadable"))
        let (model, _) = makeModel(store: store)

        await model.refreshSize()

        #expect(model.sizeText == SavedAudioModel.unknownSizeText)
        #expect(model.errorMessage != nil)
    }

    @Test func deleteSavedAudioRemovesRecordingsKeepsTranscriptsAndRefreshesTheSize() async {
        let store = FakeDictationHistoryStore()
        await store.setStoredAudioFilenames(["1.m4a", "2.m4a"])
        await store.setAudioDirectoryByteCount(4_096)
        let (model, _) = makeModel(store: store)

        await model.deleteSavedAudio()

        #expect(await store.deleteAudioReferencesCallCount == 1)
        #expect(await store.clearCallCount == 0)
        #expect(await store.audioDirectoryByteCountCallCount == 1)
        #expect(model.sizeText == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    @Test func revealAsksTheRevealerForTheAudioDirectory() {
        let store = FakeDictationHistoryStore()
        let revealer = FakeFileRevealer()
        let (model, _) = makeModel(store: store, revealer: revealer)

        model.reveal()

        #expect(revealer.revealed == [store.audioDirectoryURL])
    }
}
