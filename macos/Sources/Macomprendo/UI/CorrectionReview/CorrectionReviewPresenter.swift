import Foundation

/// Shows the post-dictation review panel. Shaped like `HUDPresenting`: the controller decides
/// *whether* and *what*, the presenter owns only the window, so every decision above it is
/// unit-tested against a fake and only the `NSPanel` is smoke-tested (invariant 3).
///
/// A `CorrectionReview` carries transcript content, so an implementation must never log it at
/// default level.
@MainActor
protocol CorrectionReviewPresenting: AnyObject {
    /// Shows `review`, replacing whatever is on screen. Never stacks: a new dictation's
    /// corrections supersede the previous one's.
    func present(_ review: CorrectionReview)
    /// Hides the panel, if one is showing.
    func dismiss()
}
