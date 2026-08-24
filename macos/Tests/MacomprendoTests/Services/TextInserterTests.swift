import Foundation
import Testing
@testable import Macomprendo

@Suite struct FakePasteboardContractTests {
    /// PasteTextInserter's restore guard depends on this; assert it explicitly.
    @Test func writingAdvancesTheChangeCount() {
        let pasteboard = FakePasteboard()
        let before = pasteboard.changeCount
        pasteboard.writeString("hello")
        #expect(pasteboard.changeCount > before)
        #expect(pasteboard.readString() == "hello")
    }
}

@Suite struct PasteTextInserterTests {
    private func makeInserter(pasteboard: FakePasteboard,
                              tracker: FakeFrontmostAppTracker,
                              keys: FakeKeySimulator) -> PasteTextInserter {
        PasteTextInserter(pasteboard: pasteboard, tracker: tracker, keySimulator: keys, restoreDelay: 0)
    }

    @Test func activatesTheAppWritesTheTextAndPastes() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.writeString("previous clipboard")
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()
        let app = FrontmostApp(pid: 7, bundleID: "com.apple.TextEdit", name: "TextEdit")

        let seenAtPasteTime = Box<String?>(nil)
        keys.onPressCommand = { _ in seenAtPasteTime.value = pasteboard.readString() }

        try await makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)
            .insert("dictated text", into: app, method: .paste)

        #expect(tracker.activated == [app])
        #expect(keys.pressed == ["v"])
        #expect(seenAtPasteTime.value == "dictated text")
        #expect(pasteboard.readString() == "previous clipboard")   // restored afterwards
    }

    @Test func doesNotRestoreWhenTheUserCopiedDuringThePaste() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.writeString("previous clipboard")
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()
        keys.onPressCommand = { _ in pasteboard.writeString("user copied this") }

        try await makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)
            .insert("dictated text", into: nil, method: .paste)

        #expect(pasteboard.readString() == "user copied this")
    }

    @Test func autoMethodPastesLikeThePasteMethod() async throws {
        let pasteboard = FakePasteboard()
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()

        try await makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)
            .insert("dictated text", into: nil, method: .auto)

        #expect(keys.pressed == ["v"])
        #expect(keys.typed.isEmpty)
    }

    @Test func typingMethodTypesAndLeavesThePasteboardAlone() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.writeString("previous clipboard")
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()

        try await makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)
            .insert("dictated text", into: nil, method: .typing)

        #expect(keys.typed == ["dictated text"])
        #expect(keys.pressed.isEmpty)
        #expect(pasteboard.readString() == "previous clipboard")
    }

    @Test func throwsInsertFailedWhenTheAppCannotBeActivated() async {
        let pasteboard = FakePasteboard()
        let tracker = FakeFrontmostAppTracker()
        tracker.activateResult = false
        let keys = FakeKeySimulator()
        let app = FrontmostApp(pid: 7, bundleID: nil, name: "Gone")
        let inserter = makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)

        await #expect(throws: MacomprendoError.insertFailed) {
            try await inserter.insert("dictated text", into: app, method: .paste)
        }
        #expect(keys.pressed.isEmpty)
    }

    @Test func skipsActivationWhenNoAppWasRemembered() async throws {
        let pasteboard = FakePasteboard()
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()

        try await makeInserter(pasteboard: pasteboard, tracker: tracker, keys: keys)
            .insert("dictated text", into: nil, method: .paste)

        #expect(tracker.activated.isEmpty)
        #expect(keys.pressed == ["v"])
    }

    /// `Task.sleep` returns (throwing) IMMEDIATELY the instant its enclosing task is
    /// cancelled — exactly what happens when `cancel()` races a still-in-flight
    /// `insert()`. A `try?`-wrapped `Task.sleep` would let the restore run right away,
    /// putting the user's old clipboard back before the receiving app has processed the
    /// synthetic ⌘V. `insert()`'s own contract says this delay "must run to completion";
    /// prove cancelling the caller's task doesn't shorten it.
    @Test func restoreDelaySurvivesCancellationOfTheCallersTask() async throws {
        let pasteboard = FakePasteboard()
        pasteboard.writeString("previous clipboard")
        let tracker = FakeFrontmostAppTracker()
        let keys = FakeKeySimulator()
        let pasted = AsyncGate()
        keys.onPressCommand = { _ in pasted.open() }
        let delay: TimeInterval = 0.1
        let inserter = PasteTextInserter(pasteboard: pasteboard, tracker: tracker,
                                         keySimulator: keys, restoreDelay: delay)

        let clock = ContinuousClock()
        let task = Task {
            try await inserter.insert("dictated text", into: nil, method: .paste)
        }

        await pasted.wait()   // the ⌘V has happened; the restore delay is now in flight
        let cancelledAt = clock.now
        task.cancel()          // races the restore, exactly as `cancel()` does on the controller

        _ = try? await task.value
        let elapsed = cancelledAt.duration(to: clock.now)

        // A cancellable delay would let this elapse in near-zero time instead of the real
        // ~100 ms — assert enough of it survived that the delay clearly wasn't skipped.
        #expect(elapsed >= .milliseconds(70))
        #expect(pasteboard.readString() == "previous clipboard")
    }
}
