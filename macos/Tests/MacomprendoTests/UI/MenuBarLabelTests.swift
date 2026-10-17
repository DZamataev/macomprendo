import Foundation
import Testing
@testable import Macomprendo

/// What remains of the old menu-row tests. The NSMenu presentation they covered — the inline
/// `"<action> — <shortcut>"` row, the `"not set"` placeholder and `MenuBarView`'s translation
/// helper — is retired with `MenuBarView` itself; the panel omits an absent shortcut instead
/// (`MenuPanelPresentation.shortcutAnnotation`) and calls `TranslationTarget.pickerLabel`
/// directly (covered by `TranslationTargetTests`).
@Suite struct MenuBarLabelTests {
    @Test func everyActionStillHasADisplayName() {
        #expect(HotkeyAction.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}
