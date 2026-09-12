import Foundation

/// The testable core of the General tab's saved-audio controls: the size readout, the reveal
/// action and the delete action. Kept out of `GeneralTab` so they can be tested with fakes
/// instead of driving SwiftUI.
@MainActor
final class SavedAudioModel: ObservableObject {
    /// Shown before the first successful read, and after one that failed.
    static let unknownSizeText = "—"

    @Published private(set) var sizeText = SavedAudioModel.unknownSizeText
    @Published private(set) var errorMessage: String?

    private let history: DictationHistoryController
    private let revealer: any FileRevealing
    /// The controller revision the current `sizeText` was read at. A refresh is only worth a
    /// directory walk when this has fallen behind.
    private var readAtRevision: Int?

    init(history: DictationHistoryController, revealer: any FileRevealing) {
        self.history = history
        self.revealer = revealer
    }

    /// Saving a recording is meaningful only while history itself is on, so the recording
    /// toggle follows it rather than silently persisting a setting that does nothing.
    nonisolated static func recordingToggleIsEnabled(_ settings: Settings) -> Bool {
        settings.dictationHistoryEnabled
    }

    func refreshSize() async {
        await read(at: history.savedAudioRevision)
    }

    /// Re-reads the size only when the audio directory has actually changed since the last
    /// read — a dictation saved while this screen is open, a delete, or a retention pass.
    /// Walking the directory on every redraw would be the alternative.
    func refreshIfSavedAudioChanged() async {
        await refreshIfSavedAudioChanged(to: history.savedAudioRevision)
    }

    private func refreshIfSavedAudioChanged(to revision: Int) async {
        guard readAtRevision != revision else { return }
        await read(at: revision)
    }

    private func read(at revision: Int) async {
        do {
            let bytes = try await history.savedAudioByteCount()
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            readAtRevision = revision
            errorMessage = nil
        } catch {
            sizeText = Self.unknownSizeText
            // Leave `readAtRevision` behind so the next opportunity retries rather than
            // treating a failed read as an up-to-date one.
            readAtRevision = nil
            let mapped = error as? MacomprendoError
                ?? MacomprendoError.dictationHistory(error.localizedDescription)
            errorMessage = ErrorText.describe(mapped)
        }
    }

    func deleteSavedAudio() async {
        if let error = await history.deleteSavedAudio() {
            errorMessage = ErrorText.describe(error)
        } else {
            errorMessage = nil
        }
        await refreshSize()
    }

    func reveal() {
        revealer.reveal(history.audioDirectoryURL)
    }
}
