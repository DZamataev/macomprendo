import Combine
import Foundation

/// The prompt-language plumbing shared by the two Quick Panel controllers.
///
/// Both run presets of a single kind against `Settings.promptLanguage`, and both keep a
/// `selectedPresetID` across panel uses — so both have to notice a language switched in
/// Settings ▸ Refine & Summarize while their panel was closed. The rule lives here once
/// rather than being written out twice and drifting apart.
@MainActor protocol PromptLanguageSwitching: AnyObject, ObservableObject {
    /// The kind of preset this controller runs.
    var presetKind: PresetKind { get }
    var settingsHolder: any SettingsHolding { get }
    /// The preset the panel's picker shows. `nil` means "whatever the default is".
    var selectedPresetID: UUID? { get set }
    /// Re-processes the current text with whatever is selected now.
    func rerun()
}

extension PromptLanguageSwitching {
    /// The preset the next run must use: the stored selection while it still matches this
    /// controller's kind **and** the working language, otherwise that language's default.
    ///
    /// Checking the language — not only the kind — is what stops a selection made before a
    /// language switch from outliving it: `selectedPresetID` is non-nil forever after the first
    /// panel use, so a `kind`-only check pins the panel to the language it opened in.
    var activePreset: PromptPreset? {
        let settings = settingsHolder.settings
        if let id = selectedPresetID, let found = settings.preset(id: id),
           found.kind == presetKind, found.language == settings.promptLanguage {
            return found
        }
        return settings.defaultPreset(for: presetKind, language: settings.promptLanguage)
    }

    /// Drops a selection left behind by another language. Called when the panel opens, so a
    /// switch made in Settings reaches a panel that has already been used once — and the
    /// picker never shows a selection that is not in its own list.
    func refreshSelectedPreset() {
        selectedPresetID = activePreset?.id
    }

    /// A pick from the panel's preset menu. Bound directly instead of `.onChange(of:)`, which
    /// also fires for the programmatic write a language switch makes and would start a second,
    /// immediately cancelled stream — a wasted billable request on a hosted endpoint.
    func selectPreset(_ id: UUID?) {
        guard id != selectedPresetID else { return }
        selectedPresetID = id
        rerun()
    }
}

extension PromptLanguageSwitching where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// The working language for the whole Refine & Summarize feature. Writing it moves the
    /// selection to the new language's default preset and reruns exactly once, so one click
    /// reprocesses the same text with the other language's prompt set.
    var promptLanguage: String {
        get { settingsHolder.settings.promptLanguage }
        set {
            guard settingsHolder.settings.promptLanguage != newValue else { return }
            objectWillChange.send()
            settingsHolder.settings.promptLanguage = newValue
            selectedPresetID = settingsHolder.settings
                .defaultPreset(for: presetKind, language: newValue)?.id
            rerun()
        }
    }
}
