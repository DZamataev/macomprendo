import Foundation
import Testing
@testable import Macomprendo

@Suite struct NDJSONParserTests {

    private static let fixture = """
    {"message":{"content":"Hel"},"done":false}
    {"message":{"content":"lo"},"done":false}
    {"message":{"content":""},"done":true}

    """

    private func strings(_ documents: [Data]) -> [String] {
        documents.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func returnsOneDocumentPerLine() {
        var parser = NDJSONParser()
        let documents = parser.feed(Data(Self.fixture.utf8))
        #expect(strings(documents) == [
            #"{"message":{"content":"Hel"},"done":false}"#,
            #"{"message":{"content":"lo"},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#
        ])
    }

    @Test func skipsBlankAndWhitespaceOnlyLines() {
        var parser = NDJSONParser()
        let documents = parser.feed(Data("{\"a\":1}\n\n   \n{\"b\":2}\n".utf8))
        #expect(strings(documents) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func trimsSurroundingWhitespaceAndCarriageReturns() {
        var parser = NDJSONParser()
        let documents = parser.feed(Data("  {\"a\":1}  \r\n".utf8))
        #expect(strings(documents) == [#"{"a":1}"#])
    }

    @Test func buffersAcrossChunkBoundaries() {
        var parser = NDJSONParser()
        #expect(parser.feed(Data("{\"a\"".utf8)).isEmpty)
        #expect(parser.feed(Data(":1}".utf8)).isEmpty)
        #expect(strings(parser.feed(Data("\n".utf8))) == [#"{"a":1}"#])
    }

    @Test func finishReturnsATrailingLineWithoutNewline() {
        var parser = NDJSONParser()
        #expect(parser.feed(Data("{\"a\":1}".utf8)).isEmpty)
        #expect(strings(parser.finish()) == [#"{"a":1}"#])
        #expect(parser.finish().isEmpty)
    }

    @Test func producesTheSameDocumentsForEveryByteOffsetSplit() {
        let bytes = Array(Self.fixture.utf8)
        let expected = [
            #"{"message":{"content":"Hel"},"done":false}"#,
            #"{"message":{"content":"lo"},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#
        ]
        for cut in 0...bytes.count {
            var parser = NDJSONParser()
            var documents = parser.feed(Data(bytes[0..<cut]))
            documents += parser.feed(Data(bytes[cut...]))
            documents += parser.finish()
            #expect(strings(documents) == expected, "wrong framing when split at byte \(cut)")
        }
    }

    @Test func decodedDocumentsSurviveJSONDecoder() throws {
        struct Chunk: Decodable { let done: Bool }
        var parser = NDJSONParser()
        let documents = parser.feed(Data(Self.fixture.utf8))
        let flags = try documents.map { try JSONDecoder().decode(Chunk.self, from: $0).done }
        #expect(flags == [false, false, true])
    }
}
