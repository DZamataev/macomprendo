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

    /// The separator is padded on both sides: the menu row is one run of text, so without the
    /// spaces it reads "Dictate—⌃D" instead of as an annotation of the action.
    @Test func theSeparatorIsPaddedOnBothSides() {
        #expect(HotkeyAction.menuSeparator.hasPrefix(" "))
        #expect(HotkeyAction.menuSeparator.hasSuffix(" "))
        #expect(HotkeyAction.menuSeparator.trimmingCharacters(in: .whitespaces) == "—")
    }

    /// What `MenuBarView` renders, composed the same way it composes it. Pins the shape of the
    /// row — that it leads with the action and ends with the shortcut or "not set" — without
    /// claiming anything about the styling, which only the smoke test can see.
    @Test func theRowLeadsWithTheActionAndEndsWithTheShortcut() {
        for action in HotkeyAction.allCases {
            let bound = action.displayName + HotkeyAction.menuSeparator
                + action.menuTrailing(shortcut: "⌃D")
            #expect(bound.hasPrefix(action.displayName))
            #expect(bound.hasSuffix("⌃D"))

            let unbound = action.displayName + HotkeyAction.menuSeparator
                + action.menuTrailing(shortcut: nil)
            #expect(unbound.hasSuffix(HotkeyAction.unboundShortcutText))
        }
    }

    @Test func translationTargetPickerNamesItsComputedAndFixedChoices() {
        #expect(MenuBarView.translationTargetLabel(.systemLanguage,
                                                   promptLanguage: "ru",
                                                   systemLanguageCode: "de")
                == "System language (German)")
        #expect(MenuBarView.translationTargetLabel(.fixed("ja"),
                                                   promptLanguage: "ru",
                                                   systemLanguageCode: "de")
                == "Japanese")
    }
}
