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
    var engine: LocalEngine? {
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

/// One row of the active-model selector.
struct SelectableSource: Identifiable, Equatable, Sendable {
    let source: TranscriptionSource
    let name: String
    /// False only for the active source when it can no longer run — it is listed anyway, so
    /// the `Picker`'s selection is always among its options and the user's own setting stays
    /// visible with its problem rather than silently vanishing.
    let isReady: Bool

    var id: TranscriptionSource { source }

    var menuTitle: String { isReady ? name : "\(name) — not ready" }
}

@MainActor
final class DictationTabModel: ObservableObject {
    @Published var modelStates: [String: ModelState] = [:]
    @Published var endpointProbe: EndpointProbeResult?
    /// True while a probe is in flight, so the Test button can say so and not be pressed twice.
    @Published private(set) var isProbing = false
    /// Which sub-tab is on screen. Pure view state: selection is the selector's job, so moving
    /// between tabs writes nothing and cannot change what transcribes.
    @Published var viewedTab: DictationBackendTab

    /// Read/write access to the live document, the same seam `PromptsTab`, `SpeechTab` and
    /// `QuickPanelController` use. `AppModel` conforms; tests pass `ScriptedSettingsHolder`.
    let holder: any SettingsHolding
    private let catalog: [LocalModel]

    init(holder: any SettingsHolding, catalog: [LocalModel] = ModelCatalog.all(kind: .asr)) {
        self.holder = holder
        self.catalog = catalog
        // Open where the active model lives. A read, not a write.
        viewedTab = Self.tab(of: holder.settings.transcriptionSource, in: catalog)
    }

    /// The sub-tab a source belongs to.
    static func tab(of source: TranscriptionSource,
                    in catalog: [LocalModel]) -> DictationBackendTab {
        switch source {
        case .endpoint:
            return .endpoint
        case .local(let modelID):
            let engine = catalog.first { $0.id == modelID }?.engine ?? .whisperCpp
            return engine == .gigaAM ? .gigaAM : .whisperCpp
        }
    }

    /// Brings the sub-tab a source lives on into view, so a fix button can point at the thing
    /// it is about. Navigation only — nothing is written.
    func reveal(_ source: TranscriptionSource) {
        viewedTab = Self.tab(of: source, in: catalog)
    }

    func rows(for tab: DictationBackendTab) -> [LocalModel] {
        guard let engine = tab.engine else { return [] }
        return catalog.filter { $0.engine == engine }
    }

    // MARK: - The active-model selector

    var activeSource: TranscriptionSource { holder.settings.transcriptionSource }

    /// The one control that changes what transcribes.
    func activate(_ source: TranscriptionSource) {
        guard source != holder.settings.transcriptionSource else { return }
        if case .endpoint(let id, let model) = source {
            holder.settings.lastTranscriptionEndpointID = id
            holder.settings.lastTranscriptionEndpointModel = model
        }
        holder.settings.transcriptionSource = source
    }

    /// The per-row shortcut. A shortcut for the selector, not a second source of truth.
    func select(modelID: String) {
        guard catalog.contains(where: { $0.id == modelID }) else { return }
        activate(.local(modelID: modelID))
    }

    /// Everything that can run right now, plus the active source when it cannot.
    var selectableSources: [SelectableSource] {
        var entries = catalog
            .filter { isReady(.local(modelID: $0.id)) }
            .map { SelectableSource(source: .local(modelID: $0.id),
                                    name: activeModelName($0),
                                    isReady: true) }

        if let endpoint = configuredEndpoint, isReady(endpoint) {
            entries.append(SelectableSource(source: endpoint, name: name(of: endpoint), isReady: true))
        }

        let active = holder.settings.transcriptionSource
        if !entries.contains(where: { $0.source == active }) {
            entries.append(SelectableSource(source: active, name: name(of: active), isReady: false))
        }
        return entries
    }

    /// Whether anything in the list can actually run. False on a fresh install, where the
    /// selector has nothing to offer and says so instead of showing a menu that cannot help.
    var hasReadySource: Bool {
        selectableSources.contains { $0.isReady }
    }

    /// Empty when the selector is usable — the same convention as `parameterSummary`.
    var selectorCaption: String {
        hasReadySource ? "" : "No model is ready — download one below."
    }

    /// Can this source transcribe right now? The same rule the status block uses, so the list
    /// and the status can never disagree.
    func isReady(_ source: TranscriptionSource) -> Bool {
        BackendReadiness.of(source: source, states: modelStates, endpointProbe: endpointProbe) == .ready
    }

    /// The endpoint the endpoint sub-tab has configured, which is not necessarily active.
    /// `nil` when no model name has been given: an endpoint without one cannot be probed and
    /// cannot transcribe.
    var configuredEndpoint: TranscriptionSource? {
        guard let id = configuredEndpointID else { return nil }
        let model = configuredEndpointModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return .endpoint(id: id, model: model)
    }

    // MARK: - Configuring the endpoint

    /// What the endpoint sub-tab's own controls show. They are configuration state, separate
    /// from the active source: only the active-model selector may change what transcribes.
    /// When no endpoint has been configured, fall back to the first picker option so the Test
    /// button reaches the server on screen rather than reporting that nothing is configured.
    var configuredEndpointID: UUID? {
        return holder.settings.lastTranscriptionEndpointID ?? holder.settings.endpoints.first?.id
    }

    var configuredEndpointModel: String {
        return holder.settings.lastTranscriptionEndpointModel ?? ""
    }

    /// Configuring an endpoint records it; it becomes active only when chosen in the selector.
    /// Either edit invalidates the probe, which proved that *that* server answered on *that*
    /// model name.
    func select(endpointID: UUID) {
        guard configuredEndpointID != endpointID else { return }
        endpointProbe = nil
        holder.settings.lastTranscriptionEndpointID = endpointID
    }

    func select(endpointModel: String) {
        guard configuredEndpointModel != endpointModel else { return }
        endpointProbe = nil
        holder.settings.lastTranscriptionEndpointModel = endpointModel
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
            "\(reason) \(activeSourceName) is the selected backend, but it is not verified "
                + "and dictation may fail until this is fixed."
        }
    }

    var activeSourceName: String { name(of: holder.settings.transcriptionSource) }

    /// How a source is named in the active-model selector and its status. Model display names
    /// describe a model family, so whisper entries carry their runtime prefix to distinguish them
    /// from other local backends.
    func name(of source: TranscriptionSource) -> String {
        switch source {
        case .local(let modelID):
            guard let model = catalog.first(where: { $0.id == modelID }) else { return modelID }
            return activeModelName(model)
        case .endpoint(_, let model):
            return "OpenAI endpoint · \(model)"
        }
    }

    private func activeModelName(_ model: LocalModel) -> String {
        switch model.engine {
        case .whisperCpp:
            "whisper.cpp — \(model.displayName)"
        case .gigaAM:
            "sherpa-onnx — \(model.displayName)"
        case .sherpaVits, .sherpaKokoro:
            model.displayName
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

    /// What the Test button's caption says about the last probe. A failure for the configured
    /// endpoint is shown here even when a different backend is active and owns the status block.
    var probeCaption: String {
        let configuredTarget = configuredEndpoint.flatMap { source -> EndpointProbeTarget? in
            guard case .endpoint(let id, let model) = source else { return nil }
            return EndpointProbeTarget(id: id, model: model)
        }
        return switch endpointProbe {
        case .succeeded(let target) where target == configuredTarget:
            "This endpoint transcribed a one-second test clip."
        case .failed(let target, let message) where target == configuredTarget:
            "The last test failed: \(message)"
        case .failed(target: nil, let message) where configuredTarget == nil:
            "The last test failed: \(message)"
        case .succeeded, .failed, nil:
            "Posts a one-second test clip to the real transcription route."
        }
    }

    /// Takes the download states straight from the live `ModelsViewModel` rows, so readiness
    /// tracks a download in progress instead of whatever was true when the tab opened.
    func adopt(_ rows: [ModelsViewModel.Row]) {
        modelStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
    }

    /// Runs the real `/v1/audio/transcriptions` probe against the **configured** endpoint,
    /// which is not necessarily the active source — testing a server before switching to it is
    /// the point of the endpoint sub-tab. The model decides *what* to probe and the caller
    /// only says how to build a provider for it, so the view still never builds one itself.
    func probeEndpoint(
        using provider: (TranscriptionSource) async throws -> any TranscriptionProvider
    ) async {
        await probeEndpoint(configuredEndpoint, using: provider)
    }

    /// Runs the probe against exactly the source supplied by the caller. The endpoint tab
    /// passes its configured source; the active status block passes the active source from its
    /// `FixAction`, so configuring endpoint B cannot redirect endpoint A's retry button.
    func probeEndpoint(
        _ source: TranscriptionSource?,
        using provider: (TranscriptionSource) async throws -> any TranscriptionProvider
    ) async {
        guard case .endpoint(let id, let model)? = source else {
            endpointProbe = .failed(
                target: nil,
                message: "No endpoint is configured yet — choose one and name a model first."
            )
            return
        }
        let target = EndpointProbeTarget(id: id, model: model)
        isProbing = true
        defer { isProbing = false }
        do {
            let built = try await provider(target.source)
            guard let transcriber = built as? OpenAICompatibleTranscriber else {
                endpointProbe = .failed(
                    target: target,
                    message: "That source is not an endpoint, so there is nothing to test."
                )
                return
            }
            try await transcriber.probe()
            // Recorded against what was probed, so the verdict cannot outlive the server and
            // model name it was obtained for.
            endpointProbe = .succeeded(target)
        } catch {
            endpointProbe = .failed(target: target, message: ErrorText.describe(error))
        }
    }
}
