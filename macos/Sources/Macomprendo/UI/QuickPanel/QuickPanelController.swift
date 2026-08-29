import AppKit
import Foundation

enum QuickPanelLayout: Equatable, Sendable {
    case refine
    case summary
}

/// The AppKit window behind the Quick Panel, kept behind a protocol so the controller is testable.
@MainActor protocol QuickPanelHosting: AnyObject {
    var onEscape: (@MainActor () -> Void)? { get set }
    var onFrameChange: (@MainActor (CGRect) -> Void)? { get set }
    var isVisible: Bool { get }
    func show(frame: CGRect)
    func hide()
}

/// Owns the Quick Panel's visibility, current layout and per-screen frame memory.
@MainActor final class QuickPanelController: ObservableObject {
    static let panelSize = CGSize(width: 680, height: 420)
    static let topInset: CGFloat = 80

    @Published private(set) var layout: QuickPanelLayout = .refine
    @Published private(set) var isVisible = false

    private let holder: any SettingsHolding
    /// Run whenever the panel is dismissed, whichever way. Injected rather than reached for:
    /// the panel lives in UI and must not know `SpeakController`, so the composition root
    /// supplies the "stop a read this panel started" call (see `TextFeatures.live`).
    private let onDismiss: @MainActor () -> Void
    private var host: (any QuickPanelHosting)?
    private var currentScreenKey: String?

    init(holder: any SettingsHolding, onDismiss: @escaping @MainActor () -> Void = {}) {
        self.holder = holder
        self.onDismiss = onDismiss
    }

    /// Called by the composition root once the SwiftUI content (which needs the controllers) exists.
    func attach(_ host: any QuickPanelHosting) {
        self.host = host
        host.onEscape = { [weak self] in self?.dismiss() }
        host.onFrameChange = { [weak self] frame in self?.rememberFrame(frame) }
    }

    /// Stable across launches — deliberately not `hashValue`, whose seed changes per process.
    static func screenKey(name: String, frame: CGRect) -> String {
        "\(name)#\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height))"
    }

    static func defaultFrame(inScreenFrame screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.midX - panelSize.width / 2,
               y: screenFrame.maxY - panelSize.height - topInset,
               width: panelSize.width,
               height: panelSize.height)
    }

    /// Presents on the screen holding the mouse — an `LSUIElement` app has no key window
    /// to infer a screen from, and the menu-bar item lives on `NSScreen.main`, which would
    /// otherwise always win regardless of where the user is working.
    func present(layout: QuickPanelLayout) {
        let target = HUDLayout.screenUnderMouse(mouseLocation: NSEvent.mouseLocation,
                                                 screens: NSScreen.screens)
        present(layout: layout,
                screenName: target?.localizedName ?? "default",
                screenFrame: target?.visibleFrame ?? CGRect(origin: .zero, size: Self.panelSize))
    }

    func present(layout: QuickPanelLayout, screenName: String, screenFrame: CGRect) {
        self.layout = layout
        let key = Self.screenKey(name: screenName, frame: screenFrame)
        currentScreenKey = key
        let frame = holder.settings.quickPanelFrames[key] ?? Self.defaultFrame(inScreenFrame: screenFrame)
        host?.show(frame: frame)
        isVisible = true
    }

    func dismiss() {
        onDismiss()
        host?.hide()
        isVisible = false
    }

    private func rememberFrame(_ frame: CGRect) {
        guard let key = currentScreenKey else { return }
        holder.settings.quickPanelFrames[key] = frame
    }
}
