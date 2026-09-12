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
        do {
            let bytes = try await history.savedAudioByteCount()
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            errorMessage = nil
        } catch {
            sizeText = Self.unknownSizeText
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
