import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechTextChunkerTests {
    @Test func shortTextIsOneChunk() {
        #expect(SpeechTextChunker.chunks(of: "One. Two. Three.", limit: 100) == ["One. Two. Three."])
    }

    @Test func blankTextProducesNoChunks() {
        #expect(SpeechTextChunker.chunks(of: "", limit: 100).isEmpty)
        #expect(SpeechTextChunker.chunks(of: "   \n\t ", limit: 100).isEmpty)
    }

    @Test func sentencesAreGroupedUpToTheLimit() {
        // "One." + " " + "Two." is exactly 9 characters; adding "Three." would not fit.
        #expect(SpeechTextChunker.chunks(of: "One. Two. Three.", limit: 9) == ["One. Two.", "Three."])
    }

    @Test func charactersAreCountedNotUTF8Bytes() {
        let text = "Привет мир. Как дела?"
        #expect("Привет мир.".count == 11)
        #expect("Привет мир.".utf8.count == 20)      // a byte budget would behave differently
        #expect("Как дела?".count == 9)

        // 11 + 1 + 9 = 21 characters: fits at 21, splits at 20.
        #expect(SpeechTextChunker.chunks(of: text, limit: 21) == ["Привет мир. Как дела?"])
        #expect(SpeechTextChunker.chunks(of: text, limit: 20) == ["Привет мир.", "Как дела?"])
        // A limit of 11 still holds the whole first sentence, which is 20 bytes.
        #expect(SpeechTextChunker.chunks(of: "Привет мир.", limit: 11) == ["Привет мир."])
    }

    @Test func aSentenceLongerThanTheLimitIsSplitAtWordBoundaries() {
        #expect(SpeechTextChunker.chunks(of: "alpha beta gamma delta", limit: 12)
                == ["alpha beta", "gamma delta"])
    }

    @Test func aWordLongerThanTheLimitIsSplitAtCharacterBoundaries() {
        #expect(SpeechTextChunker.chunks(of: "aaaaaaaaaaaa", limit: 5) == ["aaaaa", "aaaaa", "aa"])
        #expect("ПриветПриветПривет".count == 18)
        #expect(SpeechTextChunker.chunks(of: "ПриветПриветПривет", limit: 5)
                == ["Приве", "тПрив", "етПри", "вет"])
    }

    @Test func noChunkEverExceedsTheLimit() {
        let text = String(repeating: "Мама мыла раму очень тщательно. ", count: 40)
        for limit in [16, 64, 200] {
            let chunks = SpeechTextChunker.chunks(of: text, limit: limit)
            #expect(!chunks.isEmpty)
            #expect(chunks.allSatisfy { $0.count <= limit }, "limit \(limit)")
        }
    }

    @Test func sentenceSplittingKeepsClosingQuotesAndBreaksOnNewlines() {
        #expect(SpeechTextChunker.sentences(in: "He said \"Stop!\" Then left.\nNew line here")
                == ["He said \"Stop!\"", "Then left.", "New line here"])
    }

    @Test func abbreviationsAreRejoinedWhenTheyFitTheLimit() {
        // "Dr." looks like a sentence end, but the pieces are regrouped into one chunk.
        #expect(SpeechTextChunker.chunks(of: "Dr. Smith went home.", limit: 100)
                == ["Dr. Smith went home."])
    }

    @Test func aZeroLimitProducesNoChunks() {
        #expect(SpeechTextChunker.chunks(of: "anything", limit: 0).isEmpty)
        #expect(SpeechTextChunker.defaultCharacterLimit == 4096)
    }
}
