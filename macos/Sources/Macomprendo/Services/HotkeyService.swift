import Foundation
import KeyboardShortcuts

enum HotkeyAction: String, CaseIterable, Sendable {
    case dictate
    case dictateAndRefine
    case speak
    case summarize
    case refineSelection
    /// Records a call. A toggle: a press starts, the next stops. Never a middle-mouse or
    /// text-feature action.
    case recordCall

    var displayName: String {
        switch self {
        case .dictate: "Dictate"
        case .dictateAndRefine: "Dictate & Refine"
        case .speak: "Speak selection"
        case .summarize: "Summarize selection"
        case .refineSelection: "Refine selection"
        case .recordCall: "Record Call"
        }
    }
}

extension MiddleMouseAction {
    var hotkeyAction: HotkeyAction {
        switch self {
        case .dictate: .dictate
        case .dictateAndRefine: .dictateAndRefine
        case .speak: .speak
        case .summarize: .summarize
        case .refineSelection: .refineSelection
        }
    }
}

extension HotkeyAction {
    /// The shortcut currently bound to this action, as the library renders it ("⌥Space").
    /// Read when a surface builds its rows: the menubar panel rebuilds its root view on every
    /// opening, so a shortcut rebound in Settings ▸ Hotkeys shows up on the next open. The
    /// library's `shortcutByNameDidChange` notification is internal and cannot be observed.
    @MainActor
    func currentShortcutText() -> String? {
        KeyboardShortcuts.getShortcut(for: .forAction(self))?.description
    }
}

enum HotkeyEvent: Sendable, Equatable {
    case keyDown(HotkeyAction)
    case keyUp(HotkeyAction)

    var action: HotkeyAction {
        switch self {
        case .keyDown(let action), .keyUp(let action): action
        }
    }
}

protocol HotkeyServicing: AnyObject {
    var events: AsyncStream<HotkeyEvent> { get }
    func setEnabled(_ action: HotkeyAction, _ enabled: Bool)
}

@MainActor
extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
    static let dictateAndRefine = Self("dictateAndRefine", default: .init(.space, modifiers: [.option, .shift]))
    static let speak = Self("speak", default: .init(.s, modifiers: [.option]))
    static let summarize = Self("summarize", default: .init(.m, modifiers: [.option]))
    static let refineSelection = Self("refineSelection")
    /// No default: a hotkey that starts a global recording is chosen deliberately, as with
    /// Refine selection.
    static let recordCall = Self("recordCall")

    static func forAction(_ action: HotkeyAction) -> Self {
        switch action {
        case .dictate: .dictate
        case .dictateAndRefine: .dictateAndRefine
        case .speak: .speak
        case .summarize: .summarize
        case .refineSelection: .refineSelection
        case .recordCall: .recordCall
        }
    }
}

/// Persists which hotkeys the user has switched off in the menubar menu.
/// Kept out of `Settings` so the settings JSON schema does not change.
struct HotkeyEnablementStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ action: HotkeyAction) -> String { "hotkey.enabled.\(action.rawValue)" }

    func isEnabled(_ action: HotkeyAction) -> Bool {
        defaults.object(forKey: key(action)) as? Bool ?? true
    }

    func setEnabled(_ action: HotkeyAction, _ enabled: Bool) {
        defaults.set(enabled, forKey: key(action))
    }
}

final class KeyboardShortcutsHotkeyService: HotkeyServicing {
    let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    @MainActor
    init() {
        var streamContinuation: AsyncStream<HotkeyEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { streamContinuation = $0 }
        continuation = streamContinuation

        for action in HotkeyAction.allCases {
            let name = KeyboardShortcuts.Name.forAction(action)
            let sink = continuation
            KeyboardShortcuts.onKeyDown(for: name) { sink.yield(.keyDown(action)) }
            KeyboardShortcuts.onKeyUp(for: name) { sink.yield(.keyUp(action)) }
        }
    }

    func setEnabled(_ action: HotkeyAction, _ enabled: Bool) {
        Task { @MainActor in
            let name = KeyboardShortcuts.Name.forAction(action)
            if enabled {
                KeyboardShortcuts.enable(name)
            } else {
                KeyboardShortcuts.disable(name)
            }
        }
    }
}
