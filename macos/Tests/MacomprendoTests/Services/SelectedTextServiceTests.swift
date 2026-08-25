import Foundation
import Testing
@testable import Macomprendo

@Suite struct SelectedTextServiceTests {
    private func service(ax: String?, pasteboard: ScriptedPasteboard,
                         keys: ScriptedKeySimulator,
                         copyTimeout: TimeInterval = 0.05,
                         pollInterval: TimeInterval = 0.005) -> AXSelectedTextService {
        AXSelectedTextService(ax: ScriptedAXReader(text: ax), pasteboard: pasteboard,
                              keySimulator: keys, copyTimeout: copyTimeout, pollInterval: pollInterval)
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

    // F3: a cancelled read must exit the poll loop immediately (not silently swallow the
    // cancellation and busy-spin through the rest of copyTimeout) while still restoring
    // the pasteboard unconditionally on this path.
    @Test func cancellationDuringThePollLoopExitsImmediatelyAndStillRestores() async {
        let pasteboard = ScriptedPasteboard(initialString: "user clipboard")
        let keys = ScriptedKeySimulator()             // no onPress: the change count never moves
        let svc = service(ax: nil, pasteboard: pasteboard, keys: keys,
                          copyTimeout: 5, pollInterval: 0.01)

        let task = Task { try await svc.read() }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = await task.result

        #expect(pasteboard.readString() == "user clipboard")
        #expect(pasteboard.restoreCount == 1)
        switch result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("expected the cancelled read to throw CancellationError")
        }
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
