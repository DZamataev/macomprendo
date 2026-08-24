import Foundation
import Testing
@testable import Macomprendo

@Suite struct LineSplitterTests {

    @Test func splitsCompleteLinesOnUnixNewlines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("alpha\nbeta\n".utf8)) == ["alpha", "beta"])
        #expect(splitter.flush() == nil)
    }

    @Test func stripsCarriageReturnBeforeNewline() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("alpha\r\nbeta\r\n".utf8)) == ["alpha", "beta"])
    }

    @Test func preservesEmptyLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("data: x\n\ndata: y\n\n".utf8)) == ["data: x", "", "data: y", ""])
    }

    @Test func buffersPartialLineUntilTerminatorArrives() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("al".utf8)) == [])
        #expect(splitter.feed(Data("ph".utf8)) == [])
        #expect(splitter.feed(Data("a\nbe".utf8)) == ["alpha"])
        #expect(splitter.feed(Data("ta\n".utf8)) == ["beta"])
    }

    @Test func splitsCarriageReturnAndNewlineAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("alpha\r".utf8)) == [])
        #expect(splitter.feed(Data("\nbeta\n".utf8)) == ["alpha", "beta"])
    }

    @Test func flushReturnsTrailingPartialLineExactlyOnce() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("alpha\nbet".utf8)) == ["alpha"])
        #expect(splitter.flush() == "bet")
        #expect(splitter.flush() == nil)
    }

    @Test func reassemblesMultiByteUTF8SplitAcrossChunks() {
        // "héllo\n" in UTF-8: 0x68 0xC3 0xA9 0x6C 0x6C 0x6F 0x0A — split inside "é".
        var splitter = LineSplitter()
        #expect(splitter.feed(Data([0x68, 0xC3])) == [])
        #expect(splitter.feed(Data([0xA9, 0x6C, 0x6C, 0x6F, 0x0A])) == ["héllo"])
    }

    @Test func handlesEveryByteOffsetOfAFixture() {
        let fixture = "first line\r\nsecond line\n\nthird line\n"
        let bytes = Array(fixture.utf8)
        for cut in 0...bytes.count {
            var splitter = LineSplitter()
            var lines = splitter.feed(Data(bytes[0..<cut]))
            lines += splitter.feed(Data(bytes[cut...]))
            if let tail = splitter.flush() { lines.append(tail) }
            #expect(lines == ["first line", "second line", "", "third line"],
                    "wrong framing when split at byte \(cut)")
        }
    }
}
