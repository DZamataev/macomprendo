import Foundation
import Testing
@testable import Macomprendo

@Suite struct SSEParserTests {

    private static let fixture = """
    data: {"choices":[{"delta":{"content":"Hel"}}]}

    data: {"choices":[{"delta":{"content":"lo"}}]}

    data: [DONE]

    """

    @Test func dispatchesOneEventPerBlankLine() {
        var parser = SSEParser()
        let events = parser.feed(Data(Self.fixture.utf8))
        #expect(events == [
            SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hel"}}]}"#),
            SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"lo"}}]}"#),
            SSEEvent(event: nil, data: "[DONE]")
        ])
    }

    @Test func stripsExactlyOneLeadingSpaceAfterTheColon() {
        var parser = SSEParser()
        #expect(parser.feed(Data("data:  spaced\n\n".utf8)) == [SSEEvent(event: nil, data: " spaced")])
        var tight = SSEParser()
        #expect(tight.feed(Data("data:tight\n\n".utf8)) == [SSEEvent(event: nil, data: "tight")])
    }

    @Test func joinsMultipleDataLinesWithNewlines() {
        var parser = SSEParser()
        let events = parser.feed(Data("data: line one\ndata: line two\n\n".utf8))
        #expect(events == [SSEEvent(event: nil, data: "line one\nline two")])
    }

    @Test func carriesTheEventFieldAndResetsItAfterDispatch() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: ping\ndata: 1\n\ndata: 2\n\n".utf8))
        #expect(events == [
            SSEEvent(event: "ping", data: "1"),
            SSEEvent(event: nil, data: "2")
        ])
    }

    @Test func ignoresCommentsAndUnknownFields() {
        var parser = SSEParser()
        let events = parser.feed(Data(": keep-alive\nid: 7\nretry: 3000\ndata: payload\n\n".utf8))
        #expect(events == [SSEEvent(event: nil, data: "payload")])
    }

    @Test func blankLineWithoutDataDispatchesNothing() {
        var parser = SSEParser()
        #expect(parser.feed(Data("\n\n\n".utf8)) == [])
    }

    @Test func finishDispatchesATrailingEventWithoutBlankLine() {
        var parser = SSEParser()
        #expect(parser.feed(Data("data: last".utf8)) == [])
        #expect(parser.finish() == [SSEEvent(event: nil, data: "last")])
        #expect(parser.finish() == [])
    }

    @Test func producesTheSameEventsForEveryByteOffsetSplit() {
        let bytes = Array(Self.fixture.utf8)
        let expected = [
            SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hel"}}]}"#),
            SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"lo"}}]}"#),
            SSEEvent(event: nil, data: "[DONE]")
        ]
        for cut in 0...bytes.count {
            var parser = SSEParser()
            var events = parser.feed(Data(bytes[0..<cut]))
            events += parser.feed(Data(bytes[cut...]))
            events += parser.finish()
            #expect(events == expected, "wrong events when split at byte \(cut)")
        }
    }

    @Test func producesTheSameEventsForThreeWaySplits() {
        let bytes = Array(Self.fixture.utf8)
        for first in stride(from: 0, through: bytes.count, by: 7) {
            for second in stride(from: first, through: bytes.count, by: 11) {
                var parser = SSEParser()
                var events = parser.feed(Data(bytes[0..<first]))
                events += parser.feed(Data(bytes[first..<second]))
                events += parser.feed(Data(bytes[second...]))
                events += parser.finish()
                #expect(events.count == 3, "wrong count for cuts \(first)/\(second)")
                #expect(events.last?.data == "[DONE]")
            }
        }
    }
}
