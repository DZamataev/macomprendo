import AppKit

/// Shows or hides the Dock icon of an `LSUIElement` app.
@MainActor protocol ActivationPolicyControlling: AnyObject {
    func setDockIconVisible(_ visible: Bool)
}

/// Hardware/AppKit glue with no logic of its own, so it carries no unit test and is covered by
/// `docs/SMOKE_TEST.md` instead (invariant 3).
@MainActor final class NSAppActivationPolicy: ActivationPolicyControlling {
    func setDockIconVisible(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Becoming `.regular` does not by itself put the app in front or install its menu bar.
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}
