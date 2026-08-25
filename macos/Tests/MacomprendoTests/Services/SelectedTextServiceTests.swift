import Foundation
import Testing
@testable import Macomprendo

@Suite struct SelectedTextServiceTests {
    private func service(ax: String?, pasteboard: ScriptedPasteboard,
                         keys: ScriptedKeySimulator) -> AXSelectedTextService {
        AXSelectedTextService(ax: ScriptedAXReader(text: ax), pasteboard: pasteboard,
                              keySimulator: keys, copyTimeout: 0.05, pollInterval: 0.005)
    }

    @Test func accessibilityTextIsReturnedWithoutTouchingThePasteboard() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "user clipboard")
        let keys = ScriptedKeySimulator()
        let text = try await service(ax: "  selected words \n", pasteboard: pasteboard, keys: keys).read()
        #expect(text == "selected words")
        #expect(keys.presses.isEmpty)
        #expect(pasteboard.readString() == "user clipboard")
    }

    @Test func fallsBackToCommandCAndRestoresThePasteboard() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "user clipboard")
        let keys = ScriptedKeySimulator()
        keys.onPress = { key in if key == "c" { pasteboard.writeString("copied selection") } }

        let text = try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()

        #expect(text == "copied selection")
        #expect(keys.presses == ["c"])
        #expect(pasteboard.readString() == "user clipboard")
        #expect(pasteboard.restoreCount == 1)
    }

    @Test func whitespaceOnlyAccessibilityTextFallsBackToCopy() async throws {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        keys.onPress = { _ in pasteboard.writeString("from copy") }
        let text = try await service(ax: "   ", pasteboard: pasteboard, keys: keys).read()
        #expect(text == "from copy")
        #expect(keys.presses == ["c"])
    }

    @Test func throwsNoSelectionWhenNothingIsCopied() async {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()          // no onPress: the change count never moves
        await #expect(throws: MacomprendoError.noSelection) {
            try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()
        }
        #expect(pasteboard.readString() == "clip")
        #expect(pasteboard.restoreCount == 1)
    }

    @Test func throwsNoSelectionWhenTheCopiedTextIsBlank() async {
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        keys.onPress = { _ in pasteboard.writeString("   \n ") }
        await #expect(throws: MacomprendoError.noSelection) {
            try await service(ax: nil, pasteboard: pasteboard, keys: keys).read()
        }
    }
}
