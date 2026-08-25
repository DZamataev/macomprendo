import Foundation

/// Hotkey #3. Pressing the hotkey while speaking stops; otherwise it reads the supplied text.
@MainActor final class SpeakController: ObservableObject {
    @Published private(set) var isSpeaking = false

    /// Shown under "Speaking…" in the HUD.
    static let stopHint = "Press the Speak hotkey again to stop."

    private let speech: any SpeechSynthesizing
    private let toaster: any Toasting
    private let settings: @MainActor () -> Settings

    init(speech: any SpeechSynthesizing,
         toaster: any Toasting,
         settings: @escaping @MainActor () -> Settings) {
        self.speech = speech
        self.toaster = toaster
        self.settings = settings
        speech.onStateChange = { [weak self] in
            guard let self else { return }
            let speaking = self.speech.isSpeaking
            self.isSpeaking = speaking
            if speaking {
                self.toaster.show(.speaking(hint: Self.stopHint))
            } else {
                self.toaster.hide()
            }
        }
    }

    /// `text` is evaluated only when we are about to start speaking, so the selection is not
    /// read (and no ⌘C is simulated) when the hotkey is used to stop.
    func toggle(text: () async throws -> String) async {
        if speech.isSpeaking {
            speech.stop()
            isSpeaking = false
            return
        }
        do {
            let raw = try await text()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                toaster.toast(ErrorText.describe(MacomprendoError.noSelection), duration: 2.0)
                return
            }
            speech.speak(trimmed, settings: settings().speech)
            isSpeaking = speech.isSpeaking
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }
}
