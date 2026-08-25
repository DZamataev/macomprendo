import Foundation
@testable import Macomprendo

@MainActor final class ScriptedPanelHost: QuickPanelHosting {
    var onEscape: (@MainActor () -> Void)?
    var onFrameChange: (@MainActor (CGRect) -> Void)?
    private(set) var isVisible = false
    private(set) var shownFrames: [CGRect] = []
    private(set) var hideCount = 0

    func show(frame: CGRect) {
        shownFrames.append(frame)
        isVisible = true
    }

    func hide() {
        isVisible = false
        hideCount += 1
    }

    /// Simulates the user pressing Esc in the panel.
    func pressEscape() { onEscape?() }

    /// Simulates the user dragging or resizing the panel.
    func dragTo(_ frame: CGRect) { onFrameChange?(frame) }
}
