import AppKit
import Foundation

/// What the eligibility rule sees of a window: a snapshot rather than an `NSWindow`, so the
/// rule is a pure function unit-tested without AppKit and the raiser stays thin.
struct WindowSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable, CaseIterable {
        case settings, dictationHistory, transcripts, about, onboarding, quickPanel
        case statusItem, popover, hud, correctionReview, sheet, panelChooser, other
    }

    let kind: Kind
    let isVisible: Bool
    let isMiniaturized: Bool
}

enum WindowEligibility {
    /// Eligible: settings/history/transcripts/about/onboarding/quickPanel that are visible or
    /// miniaturized. Everything else (status item, popover, HUD, correction review, sheets,
    /// open/save panels, unknown) never; a closed (not visible, not miniaturized) retained
    /// window never.
    static func isEligible(_ window: WindowSnapshot) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        switch window.kind {
        case .settings, .dictationHistory, .transcripts, .about, .onboarding, .quickPanel:
            return true
        case .statusItem, .popover, .hud, .correctionReview, .sheet, .panelChooser, .other:
            return false
        }
    }
}

/// The `NSWindow` identifiers the raiser classifies by, set at each AppKit creation site so
/// classification never depends on class names or window order. SwiftUI's own windows carry
/// their `WindowID` scene id instead; these are for the windows the app creates itself.
enum WindowIdentifier {
    /// The SwiftUI Settings scene's window: SwiftUI names it; probe-confirmed, not ours to change.
    static let settings = "com_apple_SwiftUI_Settings_window"
    /// `OnboardingWindowController`'s window, retained after close.
    static let onboarding = "macomprendo-onboarding"
    /// The Quick Panel: raising it must reuse the open panel — closing it cancels its stream.
    static let quickPanel = "macomprendo-quick-panel"
    /// The recording HUD and the correction-review overlay: classified so a later eligibility
    /// change still has to decide on them explicitly, not because they can ever be eligible.
    static let hud = "macomprendo-hud"
    static let correctionReview = "macomprendo-correction-review"
}

@MainActor
protocol WindowRaising: AnyObject {
    /// Whether any eligible window exists right now (drives the command's disabled state).
    var hasEligibleWindows: Bool { get }
    /// Activates the app, deminiaturizes eligible minimized windows and orders every eligible
    /// window front; makes one key. Creates nothing, closes nothing.
    func raiseAll()
}

/// Raises the app's existing user windows. Deliberately thin: every decision is the pure
/// `WindowEligibility` rule, while the AppKit half — reading `NSApp.windows`, activating,
/// ordering — is covered by `docs/SMOKE_TEST.md`, not a unit test (invariant 3).
@MainActor
final class AppKitWindowRaiser: WindowRaising {
    var hasEligibleWindows: Bool { !eligibleWindows().isEmpty }

    func raiseAll() {
        let windows = eligibleWindows()
        guard !windows.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        for window in windows {
            window.orderFront(nil)
        }
        keyTarget(among: windows)?.makeKey()
    }

    private func eligibleWindows() -> [NSWindow] {
        NSApp.windows.filter { WindowEligibility.isEligible(snapshot(of: $0)) }
    }

    private func snapshot(of window: NSWindow) -> WindowSnapshot {
        WindowSnapshot(kind: Self.kind(of: window),
                       isVisible: window.isVisible,
                       isMiniaturized: window.isMiniaturized)
    }

    /// The one window that becomes key: the current key window when it is eligible, else the
    /// first eligible window that can take key focus.
    private func keyTarget(among windows: [NSWindow]) -> NSWindow? {
        if let key = NSApp.keyWindow, windows.contains(where: { $0 === key }) { return key }
        return windows.first(where: \.canBecomeKey)
    }

    /// Classifies by the identifiers set at each creation site. A SwiftUI `Window` scene's
    /// window carries exactly its scene id (probe: `id=dictation-history`); matched by prefix
    /// so a suffix SwiftUI might add later cannot unclassify the window.
    private static func kind(of window: NSWindow) -> WindowSnapshot.Kind {
        // A sheet belongs to its owner and must keep its modal relationship.
        if window.sheetParent != nil { return .sheet }
        // A file chooser is its own window (probe: `class=NSSavePanel` for a begun panel).
        if window is NSSavePanel { return .panelChooser }
        if let id = window.identifier?.rawValue {
            if id.hasPrefix(WindowID.dictationHistory) { return .dictationHistory }
            if id.hasPrefix(WindowID.transcripts) { return .transcripts }
            if id.hasPrefix(WindowID.about) { return .about }
            if id == WindowIdentifier.settings { return .settings }
            if id == WindowIdentifier.onboarding { return .onboarding }
            if id == WindowIdentifier.quickPanel { return .quickPanel }
            if id == WindowIdentifier.hud { return .hud }
            if id == WindowIdentifier.correctionReview { return .correctionReview }
        }
        // Class names are AppKit's only signal for its own status-item and popover windows
        // (both probe-verified present in `NSApp.windows` with nil identifiers).
        switch window.className {
        case "NSStatusBarWindow": return .statusItem
        case "_NSPopoverWindow": return .popover
        default: return .other
        }
    }
}
