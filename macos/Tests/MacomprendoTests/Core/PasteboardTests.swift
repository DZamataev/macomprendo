import Foundation
import Testing
@testable import Macomprendo

@Test func fakePasteboardRoundTripsAStringAndBumpsChangeCount() {
    let pasteboard = FakePasteboard()
    let before = pasteboard.changeCount
    pasteboard.writeString("hello")
    #expect(pasteboard.readString() == "hello")
    #expect(pasteboard.changeCount == before + 1)
}

@Test func anEmptyFakePasteboardReadsAsNil() {
    #expect(FakePasteboard().readString() == nil)
}

@Test func restoringASnapshotBringsBackThePreviousContents() {
    let pasteboard = FakePasteboard(string: "original")
    let snapshot = pasteboard.snapshot()

    pasteboard.writeString("replacement")
    #expect(pasteboard.readString() == "replacement")

    pasteboard.restore(snapshot)
    #expect(pasteboard.readString() == "original")
    #expect(pasteboard.restoreCalls == [snapshot])
}

@Test func snapshotsCarryTheRawTypeIdentifiers() {
    let pasteboard = FakePasteboard(string: "hi")
    let snapshot = pasteboard.snapshot()
    #expect(snapshot.items.count == 1)
    #expect(snapshot.items[0]["public.utf8-plain-text"] == Data("hi".utf8))
}
