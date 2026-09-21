import Foundation
import Testing
@testable import Macomprendo

/// The warning shown beside the middle-mouse toggle. Pure, so the wording is unit-tested:
/// it names other apps' settings, and wrong directions there are worse than none.
@Suite("Middle-mouse conflict notice")
struct MiddleMouseConflictNoticeTests {

    @Test func theNoticeIsOnlyOfferedWhileTheButtonIsInUse() {
        var settings = Settings.default
        settings.middleMouseAction = nil
        #expect(HotkeysTab.middleMouseConflictNotice(settings) == nil)

        settings.middleMouseAction = .dictate
        #expect(HotkeysTab.middleMouseConflictNotice(settings) != nil)
    }

    // The notice exists to save a confused user a support round trip, so it has to say what
    // goes wrong, where to fix it, and in which app — naming the setting as that app spells it.
    @Test func theNoticeNamesTheAppsThatAlsoTakeTheButtonAndWhereToTurnItOff() throws {
        var settings = Settings.default
        settings.middleMouseAction = .dictate

        let notice = try #require(HotkeysTab.middleMouseConflictNotice(settings))

        #expect(notice.contains("Warp"))
        #expect(notice.contains("Middle-click paste"))
        #expect(notice.contains("Settings ▸ Features"))
        #expect(notice.contains("iTerm2"))
        #expect(notice.contains("Pointer"))
        // tmux binds the button itself, so the fix is a line in a config file rather than a
        // checkbox — and it applies inside whichever terminal is hosting it.
        #expect(notice.contains("tmux"))
        #expect(notice.contains("MouseDown2Pane"))
    }

    // The button is global, so the conflict is not about dictation specifically: picking any
    // other action leaves the same two apps competing for the same click.
    @Test func theNoticeIsTheSameForEveryAction() {
        let notices = MiddleMouseAction.allCases.map { action -> String? in
            var settings = Settings.default
            settings.middleMouseAction = action
            return HotkeysTab.middleMouseConflictNotice(settings)
        }

        #expect(notices.allSatisfy { $0 != nil })
        #expect(Set(notices.compactMap { $0 }).count == 1)
    }

    // Terminal.app is deliberately absent: macOS has no selection clipboard, and it does not
    // paste on a middle click at all. Herdr is absent too, for the opposite reason — it
    // forwards the button into the pane rather than pasting, so the fix belongs to whatever
    // runs there. Naming either would send the user hunting for a setting that does not exist.
    @Test func theNoticeDoesNotSendTheUserToASettingThatDoesNotExist() throws {
        var settings = Settings.default
        settings.middleMouseAction = .dictate

        let notice = try #require(HotkeysTab.middleMouseConflictNotice(settings))

        #expect(notice.contains("Terminal.app") == false)
        #expect(notice.localizedCaseInsensitiveContains("herdr") == false)
    }
}
