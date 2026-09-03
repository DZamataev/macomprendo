import Foundation
import SwiftUI

/// The active-source selector, its status, and sub-tab navigation for Settings ▸ Speech.
///
/// Deliberately the same shape as `DictationTabModel`: the selector is the only control that
/// changes what speaks, and moving between sub-tabs writes nothing. `SpeechTabModel` keeps the
/// things that are about voices rather than about sources — the system voice catalog, the
/// audition phrases and the Keychain write.
@MainActor
final class SpeechSourceModel: ObservableObject {
    /// Which sub-tab is on screen. Pure view state.
    @Published var viewedTab: SpeechSource
    /// Download states for the TTS catalog, adopted from the live `ModelsViewModel` rows so
    /// readiness tracks a download in progress rather than whatever was true on open.
    @Published var modelStates: [String: ModelState] = [:]

    let holder: any SettingsHolding
    private let catalog: [LocalModel]

    init(holder: any SettingsHolding, catalog: [LocalModel] = ModelCatalog.all(kind: .tts)) {
        self.holder = holder
        self.catalog = catalog
        // Open where the active source lives. A read, not a write.
        viewedTab = holder.settings.speech.source
    }

    // MARK: - The selector

    var activeSource: SpeechSource { holder.settings.speech.source }

    /// The one control that changes what speaks.
    func activate(_ source: SpeechSource) {
        guard source != holder.settings.speech.source else { return }
        objectWillChange.send()
        holder.settings.speech.source = source
    }

    /// Brings a source's sub-tab into view so a fix button can point at the thing it is
    /// about. Navigation only — nothing is written.
    func reveal(_ source: SpeechSource) {
        viewedTab = source
    }

    // MARK: - The local catalog

    var ttsModels: [LocalModel] { catalog }

    var selectedModel: LocalModel? {
        guard let id = holder.settings.speech.localModelID else { return nil }
        return catalog.first { $0.id == id }
    }

    /// Records which local voice is configured. Configuring is not activating: the source
    /// becomes live only through `activate(_:)`.
    func select(modelID: String) {
        guard catalog.contains(where: { $0.id == modelID }) else { return }
        objectWillChange.send()
        holder.settings.speech.localModelID = modelID
    }

    // MARK: - Status

    var readiness: SpeechReadiness {
        SpeechReadiness.of(source: activeSource,
                           settings: holder.settings.speech,
                           modelStates: modelStates)
    }

    var statusHeadline: String {
        readiness == .ready ? "Ready to use" : "Not ready"
    }

    var statusDetail: String {
        switch readiness {
        case .ready:
            "\(name(of: activeSource)) will read your selection. Press the Speak hotkey to hear it."
        case .notReady(let reason, _):
            "\(reason) \(name(of: activeSource)) is the selected source, so the Speak hotkey "
                + "will report this instead of speaking."
        }
    }

    /// How a source is named in the selector and its status. The local source names the voice
    /// itself when one is chosen, because "Local TTS" alone does not say what will be heard.
    func name(of source: SpeechSource) -> String {
        switch source {
        case .system, .endpoint:
            return source.displayName
        case .local:
            guard let model = selectedModel else { return source.displayName }
            return "\(source.displayName) · \(model.displayName)"
        }
    }

    /// Takes the download states straight from the live `ModelsViewModel` rows.
    func adopt(_ rows: [ModelsViewModel.Row]) {
        modelStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
    }
}
