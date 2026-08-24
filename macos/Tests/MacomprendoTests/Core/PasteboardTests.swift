import AppKit
import Foundation
import Testing
@testable import Macomprendo

/// Creates a private, uniquely-named pasteboard so these tests never touch the
/// user's real clipboard. Caller is responsible for `releaseGlobally()`.
private func makeTestPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("macomprendo.tests.\(UUID().uuidString)"))
}

@Test func systemPasteboardRoundTripsAStringThroughAPrivatePasteboard() {
    let native = makeTestPasteboard()
    defer { native.releaseGlobally() }
    let pasteboard = SystemPasteboard(native)

    pasteboard.writeString("hello")
    #expect(pasteboard.readString() == "hello")
}

@Test func systemPasteboardRestoresAMultiItemMultiTypeSnapshot() {
    let native = makeTestPasteboard()
    defer { native.releaseGlobally() }
    let pasteboard = SystemPasteboard(native)

    let typeA1 = NSPasteboard.PasteboardType("com.macomprendo.tests.a1")
    let typeA2 = NSPasteboard.PasteboardType("com.macomprendo.tests.a2")
    let typeB1 = NSPasteboard.PasteboardType("com.macomprendo.tests.b1")
    let typeB2 = NSPasteboard.PasteboardType("com.macomprendo.tests.b2")

    let dataA1 = Data("item1-typeA".utf8)
    let dataA2 = Data("item1-typeB".utf8)
    let dataB1 = Data("item2-typeA".utf8)
    let dataB2 = Data("item2-typeB".utf8)

    let itemA = NSPasteboardItem()
    itemA.setData(dataA1, forType: typeA1)
    itemA.setData(dataA2, forType: typeA2)

    let itemB = NSPasteboardItem()
    itemB.setData(dataB1, forType: typeB1)
    itemB.setData(dataB2, forType: typeB2)

    native.clearContents()
    native.writeObjects([itemA, itemB])

    let snapshot = pasteboard.snapshot()

    native.clearContents()
    pasteboard.writeString("something else entirely")
    #expect(pasteboard.readString() == "something else entirely")

    pasteboard.restore(snapshot)

    let restoredItems = native.pasteboardItems ?? []
    #expect(restoredItems.count == 2)
    #expect(restoredItems[0].data(forType: typeA1) == dataA1)
    #expect(restoredItems[0].data(forType: typeA2) == dataA2)
    #expect(restoredItems[1].data(forType: typeB1) == dataB1)
    #expect(restoredItems[1].data(forType: typeB2) == dataB2)
}

@Test func systemPasteboardRestoringAnEmptySnapshotClearsIt() {
    let native = makeTestPasteboard()
    defer { native.releaseGlobally() }
    let pasteboard = SystemPasteboard(native)

    pasteboard.writeString("will be cleared")
    #expect(pasteboard.readString() == "will be cleared")

    pasteboard.restore(PasteboardSnapshot())
    #expect(pasteboard.readString() == nil)
    #expect((native.pasteboardItems ?? []).isEmpty)
}

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
