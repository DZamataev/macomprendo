import AppKit
import SwiftUI

/// What the post-dictation review panel shows and how long it stays.
///
/// Split from the window for the same reason `HUDController` is: every decision with a rule
/// behind it — the duration, replacement, the hover pause — is unit-tested here, and the
/// `NSPanel` below it holds nothing but placement and ordering (invariant 3).
///
/// It holds transcript content through `review`, so nothing here may reach a log line at
/// default level.
@MainActor
final class CorrectionReviewController: ObservableObject {
    /// The review on screen, or `nil` when the panel is down.
    @Published private(set) var review: CorrectionReview?

    /// Two seconds: long enough to read a line of corrected text, short enough not to linger
    /// over the document it went into. Hovering holds the panel open for longer reads.
    static let autoHideDuration: TimeInterval = 2

    private let sleep: @Sendable (TimeInterval) async -> Void
    /// Called when the timer, not the caller, takes the panel down — the window presenter
    /// orders the panel out. `dismiss()` does not fire it: its caller is already hiding.
    /// Settable because the presenter owns the controller and cannot hand `self` to its own
    /// initialiser's argument list.
    var onAutoHide: @MainActor () -> Void
    private var isPointerInside = false
    private(set) var hideTask: Task<Void, Never>?

    init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         },
         onAutoHide: @escaping @MainActor () -> Void = {}) {
        self.sleep = sleep
        self.onAutoHide = onAutoHide
    }

    /// Replaces whatever is on screen and restarts the timer — a second dictation's
    /// corrections supersede the first's rather than stacking beside them.
    ///
    /// While the pointer is inside, the content is replaced but no timer starts: the user is
    /// mid-read, and pulling the text away because another dictation finished elsewhere would
    /// lose them the sentence they were looking at.
    func present(_ review: CorrectionReview) {
        self.review = review
        restartTimer()
    }

    /// Takes the panel down now. Reports nothing back: the caller is already hiding it.
    func dismiss() {
        cancelTimer()
        review = nil
    }

    /// The pointer entering pauses the countdown; leaving restarts the full duration, so a
    /// span that was hovered is readable for as long again after the pointer moves away.
    func pointerInsideChanged(_ isInside: Bool) {
        isPointerInside = isInside
        if isInside {
            cancelTimer()
        } else {
            restartTimer()
        }
    }

    private func cancelTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func restartTimer() {
        cancelTimer()
        guard review != nil, !isPointerInside else { return }
        let duration = Self.autoHideDuration
        hideTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(duration)
            guard !Task.isCancelled else { return }
            self.review = nil
            self.hideTask = nil
            self.onAutoHide()
        }
    }
}
