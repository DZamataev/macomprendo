import Foundation
import SwiftUI

enum HUDState: Equatable, Sendable {
    case hidden
    case recording(level: Float, elapsed: TimeInterval)
    case transcribing
    /// Text-to-speech is playing; `hint` tells the user how to stop it.
    case speaking(hint: String)
    case success(String)
    case error(String)
    case toast(String)
}

@MainActor
protocol HUDPresenting: AnyObject {
    func present(_ controller: HUDController)
    func dismiss()
}

/// Owns what the floating HUD shows and when it disappears again.
@MainActor
final class HUDController: ObservableObject {
    @Published private(set) var state: HUDState = .hidden
    /// The active transcription model's name, shown dim while recording and transcribing so a
    /// misconfiguration is visible before the transcript comes back wrong.
    @Published var modelCaption: String?

    private let presenter: (any HUDPresenting)?
    private let sleep: @Sendable (TimeInterval) async -> Void
    private(set) var hideTask: Task<Void, Never>?

    init(presenter: (any HUDPresenting)? = nil,
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.presenter = presenter
        self.sleep = sleep
    }

    static func autoHideDuration(for state: HUDState) -> TimeInterval? {
        switch state {
        case .success, .toast: 1.2
        case .error: 4
        case .hidden, .recording, .transcribing, .speaking: nil
        }
    }

    /// Pure, so the wording is unit-tested. `nonisolated` for the same reason
    /// `HUDView.elapsedText` is: `ObservableObject` members would otherwise inherit the
    /// main-actor isolation of the type.
    nonisolated static func caption(for source: TranscriptionSource) -> String {
        switch source {
        case .local(let modelID):
            ModelCatalog.model(id: modelID)?.displayName ?? modelID
        case .endpoint(_, let model):
            "OpenAI endpoint · \(model)"
        }
    }

    func show(_ state: HUDState) {
        present(state, autoHideAfter: Self.autoHideDuration(for: state))
    }

    func toast(_ message: String, duration: TimeInterval = 1.2) {
        present(.toast(message), autoHideAfter: duration)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        state = .hidden
        presenter?.dismiss()
    }

    private func present(_ newState: HUDState, autoHideAfter duration: TimeInterval?) {
        hideTask?.cancel()
        hideTask = nil
        state = newState
        if newState == .hidden {
            presenter?.dismiss()
            return
        }
        presenter?.present(self)
        guard let duration else { return }
        hideTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(duration)
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }
}
