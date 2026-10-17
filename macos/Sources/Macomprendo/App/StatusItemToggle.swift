import Foundation

/// The status item's click policy (spec §6). A transient popover can be dismissed on the
/// mouse-down of a repeat click, and the button's mouse-up action then fires — so a show
/// request arriving just after a close is that same click, not a second one, and would
/// reopen a panel the click meant to close. Kept pure and clock-injected so the ordering
/// rule is testable without AppKit.
enum StatusItemToggle {
    enum Decision: Equatable {
        case show
        case close
        case ignore
    }

    /// How long after a close a show request is presumed to belong to that close's click.
    /// 0.25 s is gbar's measured dead-zone for the same transient-popover ordering trap.
    static let closeRecency: TimeInterval = 0.25

    static func decide(isShown: Bool, lastClosedAt: Date?, now: Date) -> Decision {
        if isShown { return .close }
        if let lastClosedAt, now.timeIntervalSince(lastClosedAt) < closeRecency {
            return .ignore
        }
        return .show
    }
}
