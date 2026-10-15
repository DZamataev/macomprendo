import Foundation
import Testing
@testable import Macomprendo

/// The General tab's Call recordings section: the folder shown, the size readout, the folder
/// picker and the reveal action.
@MainActor
@Suite struct CallRecordingsSettingsModelTests {
    private func makeModel(holder: ScriptedSettingsHolder = ScriptedSettingsHolder(),
                           folders: FakeCallRecordingFolders = FakeCallRecordingFolders(),
                           revealer: FakeFileRevealer = FakeFileRevealer())
        -> CallRecordingsSettingsModel {
        CallRecordingsSettingsModel(holder: holder, folders: folders, revealer: revealer)
    }

    @Test func refreshSizeShowsTheFolderTotal() async {
        let folders = FakeCallRecordingFolders()
        folders.size = 1_400_000_000
        let model = makeModel(folders: folders)

        await model.refreshSize()

        // Formatted through the same locale-aware formatter the saved-audio readout uses, so
        // the assertion pins the shape of the sentence, not the separator this Mac renders.
        #expect(model.totalSizeText == "Recordings use "
                + ByteCountFormatter.string(fromByteCount: 1_400_000_000, countStyle: .file))
    }

    @Test func theDefaultDirectoryIsShownWhenNoFolderIsChosen() {
        let model = makeModel()

        #expect(model.directory == CallRecordingLayout.defaultDirectory)
    }

    @Test func theChosenDirectoryIsShownWhenSet() {
        let holder = ScriptedSettingsHolder()
        holder.settings.callRecordingsDirectory = "/Volumes/Archive/Calls"
        let model = makeModel(holder: holder)

        #expect(model.directory == URL(fileURLWithPath: "/Volumes/Archive/Calls"))
    }

    @Test func chooseWritesThePathIntoSettings() {
        let holder = ScriptedSettingsHolder()
        let model = makeModel(holder: holder)
        let chosen = URL(fileURLWithPath: "/Volumes/Archive/Calls", isDirectory: true)

        model.choose(chosen)

        #expect(holder.settings.callRecordingsDirectory == chosen.path)
        // The path the section now draws is the chosen folder's, however the panel spelled it.
        #expect(model.directory.path == chosen.path)
    }

    @Test func showInFinderRevealsTheChosenDirectory() {
        let holder = ScriptedSettingsHolder()
        holder.settings.callRecordingsDirectory = "/Volumes/Archive/Calls"
        let revealer = FakeFileRevealer()
        let model = makeModel(holder: holder, revealer: revealer)

        model.showInFinder()

        #expect(revealer.revealed == [URL(fileURLWithPath: "/Volumes/Archive/Calls")])
    }
}
