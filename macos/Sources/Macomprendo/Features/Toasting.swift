import Foundation

/// The one thing controllers need from the HUD. Keeps them testable without AppKit.
@MainActor protocol Toasting: AnyObject {
    func toast(_ message: String, duration: TimeInterval)
}

extension HUDController: Toasting {}
