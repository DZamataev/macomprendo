import Foundation

/// The part of the HUD that feature controllers drive. Keeps them testable without AppKit.
@MainActor protocol Toasting: AnyObject {
    func toast(_ message: String, duration: TimeInterval)
    func show(_ state: HUDState)
    func hide()
}

extension HUDController: Toasting {}
