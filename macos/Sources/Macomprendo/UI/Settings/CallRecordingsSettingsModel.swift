import Foundation

/// The testable core of the General tab's Call recordings section: the folder shown, the size
/// readout, the folder picker and the reveal action. Kept out of `GeneralTab` so it can be
/// tested with fakes instead of driving SwiftUI.
@MainActor
final class CallRecordingsSettingsModel: ObservableObject {
    /// Shown before the first successful read.
    static let unknownSizeText = "Recordings use —"

    @Published private(set) var totalSizeText = CallRecordingsSettingsModel.unknownSizeText

    private let holder: any SettingsHolding
    private let folders: any CallRecordingFolderManaging
    private let revealer: any FileRevealing

    init(holder: any SettingsHolding, folders: any CallRecordingFolderManaging,
         revealer: any FileRevealing) {
        self.holder = holder
        self.folders = folders
        self.revealer = revealer
    }

    /// The recordings folder the settings name, else the default — the same resolution the
    /// recorder and launch recovery use.
    var directory: URL {
        CallRecordingLayout.directory(for: holder.settings)
    }

    /// `Recordings use 1.4 GB`, through the same locale-aware formatter the saved-audio
    /// readout uses.
    nonisolated static func sizeText(_ bytes: Int64) -> String {
        "Recordings use " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func choose(_ url: URL) {
        guard holder.settings.callRecordingsDirectory != url.path else { return }
        // `settings` lives on the holder, not here: without this the section would keep drawing
        // the old path (see the swiftui-macos-ui skill).
        objectWillChange.send()
        holder.settings.callRecordingsDirectory = url.path
    }

    func showInFinder() {
        revealer.reveal(directory)
    }

    /// Measures the folder off the main actor: a recordings folder can hold gigabytes.
    func refreshSize() async {
        let folders = folders
        let directory = directory
        let bytes = await Task.detached(priority: .utility) {
            folders.totalSize(of: directory)
        }.value
        totalSizeText = Self.sizeText(bytes)
    }
}
