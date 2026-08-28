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

    /// The menu row is ONE string, not a name plus a separately-styled trailing view: a
    /// `MenuBarExtra(.menu)` item keeps only the first `Text` of a composite label and
    /// silently drops the rest, which is how the shortcut went missing the first time.
    @Test func theMenuTitleCarriesTheShortcutInTheSameString() {
        #expect(HotkeyAction.dictate.menuTitle(shortcut: "⌃D") == "Dictate — ⌃D")
        #expect(HotkeyAction.summarize.menuTitle(shortcut: "⌃⇧S") == "Summarize selection — ⌃⇧S")
    }

    @Test func theMenuTitleSaysWhenNothingIsBound() {
        #expect(HotkeyAction.refineSelection.menuTitle(shortcut: nil) == "Refine selection — not set")
        #expect(HotkeyAction.refineSelection.menuTitle(shortcut: "  ") == "Refine selection — not set")
    }

    @Test func everyActionProducesANonEmptyMenuTitleForBothStates() {
        for action in HotkeyAction.allCases {
            #expect(action.menuTitle(shortcut: "⌃D").hasPrefix(action.displayName))
            #expect(action.menuTitle(shortcut: nil).hasSuffix(HotkeyAction.unboundShortcutText))
        }
    }
}
