import Foundation
import SwiftUI

/// One backend's sub-tab in the Dictation settings.
enum DictationBackendTab: String, CaseIterable, Identifiable, Sendable {
    case whisperCpp
    case gigaAM
    case endpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisperCpp: "whisper.cpp"
        case .gigaAM: "GigaAM"
        case .endpoint: "OpenAI endpoint"
        }
    }

    /// `nil` for the endpoint tab, which lists no local models.
    var engine: ASREngine? {
        switch self {
        case .whisperCpp: .whisperCpp
        case .gigaAM: .gigaAM
        case .endpoint: nil
        }
    }

    /// Shown instead of parameter controls. Empty means "this tab has real controls".
    var parameterSummary: String {
        switch self {
        case .whisperCpp, .endpoint:
            ""
        case .gigaAM:
            "No settings. The Russian models take no language hint, the multilingual models "
                + "detect their own language, and decoding is greedy."
        }
    }
}

@MainActor
final class DictationTabModel: ObservableObject {
    @Published var modelStates: [String: ModelState] = [:]
    @Published var endpointProbe: EndpointProbeResult?
    /// True while a probe is in flight, so the Test button can say so and not be pressed twice.
    @Published private(set) var isProbing = false

    /// Read/write access to the live document, the same seam `PromptsTab`, `SpeechTab` and
    /// `QuickPanelController` use. `AppModel` conforms; tests pass `ScriptedSettingsHolder`.
    let holder: any SettingsHolding
    private let catalog: [LocalASRModel]

    init(holder: any SettingsHolding, catalog: [LocalASRModel] = ModelCatalog.all) {
        self.holder = holder
        self.catalog = catalog
    }

    var activeTab: DictationBackendTab {
        switch holder.settings.transcriptionSource {
        case .endpoint:
            return .endpoint
        case .local(let modelID):
            let engine = catalog.first { $0.id == modelID }?.engine ?? .whisperCpp
            return engine == .gigaAM ? .gigaAM : .whisperCpp
        }
    }

    func rows(for tab: DictationBackendTab) -> [LocalASRModel] {
        guard let engine = tab.engine else { return [] }
        return catalog.filter { $0.engine == engine }
    }

    /// Selecting a tab configures that backend. This deliberately gives a navigation control
    /// a persistent side effect — see the spec — so the status block states it in words
    /// rather than leaving it to be discovered by dictating.
    func select(tab: DictationBackendTab) {
        guard tab != activeTab else { return }
        switch tab {
        case .endpoint:
            holder.settings.transcriptionSource = .endpoint(
                id: holder.settings.lastTranscriptionEndpointID
                    ?? holder.settings.endpoints.first?.id
                    ?? Endpoint.ollamaLocalID,
                model: holder.settings.lastTranscriptionEndpointModel ?? "whisper-1"
            )
        case .whisperCpp, .gigaAM:
            guard let engine = tab.engine else { return }
            let remembered = holder.settings.lastModelByEngine[engine.rawValue]
            let fallback = catalog.first { $0.engine == engine }?.id
            guard let modelID = remembered ?? fallback else { return }
            holder.settings.transcriptionSource = .local(modelID: modelID)
        }
    }

    func select(modelID: String) {
        guard let engine = catalog.first(where: { $0.id == modelID })?.engine else { return }
        holder.settings.lastModelByEngine[engine.rawValue] = modelID
        holder.settings.transcriptionSource = .local(modelID: modelID)
    }

    /// Choosing a different endpoint or model invalidates any probe: it proved that *that*
    /// server answered on *that* model, and saying "ready" about a server never contacted is
    /// exactly the false positive the probe exists to prevent.
    func select(endpointID: UUID) {
        guard case .endpoint(let current, let model) = holder.settings.transcriptionSource,
              current != endpointID else { return }
        endpointProbe = nil
        holder.settings.lastTranscriptionEndpointID = endpointID
        holder.settings.transcriptionSource = .endpoint(id: endpointID, model: model)
    }

    func select(endpointModel: String) {
        guard case .endpoint(let id, let current) = holder.settings.transcriptionSource,
              current != endpointModel else { return }
        endpointProbe = nil
        holder.settings.lastTranscriptionEndpointModel = endpointModel
        holder.settings.transcriptionSource = .endpoint(id: id, model: endpointModel)
    }

    var readiness: BackendReadiness {
        BackendReadiness.of(source: holder.settings.transcriptionSource,
                            states: modelStates,
                            endpointProbe: endpointProbe)
    }

    var statusHeadline: String {
        readiness == .ready ? "Ready to use" : "Not ready"
    }

    var statusDetail: String {
        switch readiness {
        case .ready:
            "\(activeSourceName) is your active dictation model. Press your dictation hotkey "
                + "and it will be used."
        case .notReady(let reason, _):
            "\(reason) \(activeSourceName) is the selected backend, so dictation will fail "
                + "until this is fixed."
        }
    }

    var activeSourceName: String {
        switch holder.settings.transcriptionSource {
        case .local(let modelID):
            catalog.first { $0.id == modelID }?.displayName ?? modelID
        case .endpoint(_, let model):
            "OpenAI endpoint · \(model)"
        }
    }
}

// MARK: - What the view renders

extension DictationTabModel {

    /// The id of the model the active local tab has selected, or `nil` on the endpoint tab.
    var selectedModelID: String? {
        if case .local(let modelID) = holder.settings.transcriptionSource { return modelID }
        return nil
    }

    /// What a sub-tab's label says about itself.
    enum TabIndicator: Sendable, Equatable {
        case ready
        case notReady
        /// Not the configured backend, so nothing about it is ready or broken — it simply is
        /// not what dictation will run. Marking it "not ready" would read as a fault.
        case inactive

        /// Empty for `.inactive`: an unconfigured backend must look different from a broken
        /// one, or a fresh install would show three alarming tabs.
        var marker: String {
            switch self {
            case .ready: "✅"
            case .notReady: "❌"
            case .inactive: ""
            }
        }
    }

    /// Only the active tab is ever `.ready` or `.notReady`: readiness is about what will run
    /// at hotkey-press time, and only one backend ever will.
    func indicator(for tab: DictationBackendTab) -> TabIndicator {
        guard tab == activeTab else { return .inactive }
        return readiness == .ready ? .ready : .notReady
    }

    /// The sub-tab's label, marker included. The marker is part of the *string* rather than a
    /// sibling icon because a segmented control renders its own title for certain, while a
    /// `Label`'s icon may be dropped by the style — and a readiness warning that might not
    /// render is not a warning. `✅`/`❌` are the symbols the spec itself uses for this screen.
    func tabTitle(for tab: DictationBackendTab) -> String {
        let marker = indicator(for: tab).marker
        return marker.isEmpty ? tab.title : "\(tab.title) \(marker)"
    }

    /// What a model's `languages` says, in words. `nil` means multilingual with no published
    /// list, which is whisper — not "no languages". Named in English, like the rest of the UI,
    /// rather than in the system language.
    static func languagesText(_ languages: [String]?) -> String {
        guard let languages, !languages.isEmpty else { return "90+ languages" }
        let english = Locale(identifier: "en_US")
        let names = languages.map { code in
            english.localizedString(forLanguageCode: code) ?? code
        }
        return names.joined(separator: ", ")
    }

    /// Thread counts offered for whisper.cpp. `nil` is "Automatic"; the rest are every count
    /// this machine could use.
    static func threadChoices(processorCount: Int) -> [Int?] {
        [nil] + Array(1...max(1, processorCount)).map { Optional($0) }
    }

    /// Labels a thread choice, naming what "Automatic" actually resolves to so the row is not
    /// a mystery. Derived from `WhisperParams` rather than restated, so the two cannot drift.
    static func threadLabel(_ choice: Int?, processorCount: Int) -> String {
        guard let choice else {
            let automatic = WhisperParams.make(language: nil, processorCount: processorCount).threads
            return "Automatic (\(automatic))"
        }
        return "\(choice)"
    }

    /// One published measurement, to one decimal. These are third-party numbers, quoted as
    /// published; the app measures nothing itself.
    static func benchmarkValue(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// The other models published on the same row, sorted by name so the same brief always
    /// renders the same way — a dictionary's own order does not survive a relaunch.
    static func comparisonText(_ comparedTo: [String: Double]) -> String {
        comparedTo
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \(benchmarkValue($0.value))" }
            .joined(separator: " · ")
    }

    /// What the Test button's caption says about the last probe. The failure reason itself
    /// lives in the status block; repeating a long server error beside the button would only
    /// push the controls apart.
    var probeCaption: String {
        switch endpointProbe {
        case .succeeded: "This endpoint transcribed a one-second test clip."
        case .failed: "The last test failed — the reason is in the status above."
        case nil: "Posts a one-second test clip to the real transcription route."
        }
    }

    /// Takes the download states straight from the live `ModelsViewModel` rows, so readiness
    /// tracks a download in progress instead of whatever was true when the tab opened.
    func adopt(_ rows: [ModelsViewModel.Row]) {
        modelStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
    }

    /// Runs the real `/v1/audio/transcriptions` probe and records the outcome. Takes the
    /// provider as a closure — `AppModel.transcriberProvider` in the app — so the whole
    /// path is testable and the view still never builds a provider itself.
    func probeEndpoint(using provider: () async throws -> any TranscriptionProvider) async {
        isProbing = true
        defer { isProbing = false }
        do {
            guard let transcriber = try await provider() as? OpenAICompatibleTranscriber else {
                endpointProbe = .failed("The active source is not an endpoint, so there is "
                                        + "nothing to test.")
                return
            }
            try await transcriber.probe()
            endpointProbe = .succeeded
        } catch {
            endpointProbe = .failed(ErrorText.describe(error))
        }
    }
}
