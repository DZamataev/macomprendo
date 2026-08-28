import Foundation

/// Who asked for the current playback. The Quick Panel shows two texts, so "read this aloud"
/// has to name one of them; the hotkey is its own source so only it shows the HUD.
enum SpeakSource: Hashable, Sendable {
    case hotkey
    case refineOriginal
    case refineRefined
    case summary
}

/// Hotkey #3 and the Quick Panel's playback controls. There is one in-flight read at a time
/// (invariant 7): starting from any source supersedes whatever was playing, and the hotkey
/// stops panel playback rather than starting a second read.
@MainActor final class SpeakController: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var active: SpeakSource?

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
            self.isPaused = speaking && self.speech.isPaused
            if !speaking { self.active = nil }
            // Panel playback has its own controls on screen; a floating HUD over the panel
            // would be noise, so only the hotkey path shows it.
            if speaking, self.active == .hotkey {
                self.toaster.show(.speaking(hint: Self.stopHint))
            } else {
                self.toaster.hide()
            }
        }
        // Surfaced exactly like the controller's own text-read failures. `onStateChange` has
        // already hidden the "Speaking…" HUD by the time this runs, so the toast survives.
        speech.onError = { [weak self] error in
            self?.toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    /// `text` is evaluated only when we are about to start speaking, so the selection is not
    /// read (and no ⌘C is simulated) when the hotkey is used to stop.
    func toggle(text: () async throws -> String) async {
        if speech.isSpeaking {
            stop()
            return
        }
        do {
            speak(try await text(), from: .hotkey)
        } catch {
            toaster.toast(ErrorText.describe(error), duration: 2.5)
        }
    }

    /// Starts reading `text`, superseding any playback already in progress.
    func speak(_ text: String, from source: SpeakSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toaster.toast(ErrorText.describe(MacomprendoError.noSelection), duration: 2.0)
            return
        }
        // Set before speaking: the backend calls `onStateChange` synchronously from `speak`,
        // and that closure decides whether to show the HUD from `active`.
        active = source
        isPaused = false
        speech.speak(trimmed, settings: settings().speech)
        isSpeaking = speech.isSpeaking
    }

    func pauseOrResume() {
        guard isSpeaking else { return }
        if speech.isPaused { speech.resume() } else { speech.pause() }
        isPaused = speech.isPaused
    }

    func stop() {
        speech.stop()
        isSpeaking = false
        isPaused = false
        active = nil
    }
}
