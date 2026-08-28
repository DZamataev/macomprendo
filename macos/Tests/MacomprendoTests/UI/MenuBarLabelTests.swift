import Foundation
import Testing
@testable import Macomprendo

@Suite struct MenuBarLabelTests {
    @Test func aBoundShortcutIsShownAsIs() {
        #expect(HotkeyAction.dictate.menuTrailing(shortcut: "⌥Space") == "⌥Space")
        #expect(HotkeyAction.dictateAndRefine.menuTrailing(shortcut: "⌥⇧Space") == "⌥⇧Space")
    }

    @Test func anUnboundShortcutSaysSoRatherThanShowingNothing() {
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: nil) == "not set")
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: "") == "not set")
        #expect(HotkeyAction.refineSelection.menuTrailing(shortcut: "   ") == "not set")
    }

    @Test func everyActionStillHasADisplayName() {
        #expect(HotkeyAction.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
