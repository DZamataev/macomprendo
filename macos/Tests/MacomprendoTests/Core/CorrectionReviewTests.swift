import Foundation
import Testing
@testable import Macomprendo

/// Builds a pack from term lines, the way a pack file would be read from disk.
private func reviewPack(_ name: String, _ terms: String...) -> GlossaryPack {
    GlossaryPack.parse(terms.joined(separator: "\n"), name: name)
}

@Suite("Correction review value")
struct CorrectionReviewTests {
    @Test func isBuiltDirectlyFromTheNormalisationResult() {
        // A projection, not a recomputation: the value carries the normalisation result's text
        // and rewrites unchanged, so nothing downstream re-reads the glossary or re-matches.
        let glossary = Glossary(
            packs: [reviewPack("typescript", "TypeScript")],
            manualTerms: ["MatchHUD"]
        )
        let result = Normalizer.normalise("пишу на Type Script и Match HUD", with: glossary)
        let review = CorrectionReview(result)

        #expect(review.text == result.text)
        #expect(review.rewrites == result.rewrites)
        #expect(review.rewrites.map(\.original) == ["Type Script", "Match HUD"])
        #expect(review.rewrites.map(\.term) == ["TypeScript", "MatchHUD"])
        #expect(review.rewrites.map(\.packName) == ["typescript", nil])
    }

    @Test func captionListsEachPackOnceInFirstOccurrenceOrder() {
        let glossary = Glossary(packs: [
            reviewPack("typescript", "TypeScript", "nvm"),
            reviewPack("personal", "MatchHUD"),
        ])
        let result = Normalizer.normalise(
            "пишу на Type Script, ставлю NVM, открываю Match HUD",
            with: glossary
        )
        let review = CorrectionReview(result)

        #expect(review.rewrites.count == 3)
        #expect(review.caption == "typescript, personal · 3 corrections")
    }

    @Test func captionNamesAPackOnceHoweverOftenItFires() {
        let glossary = Glossary(packs: [
            reviewPack("personal", "MatchHUD"),
            reviewPack("typescript", "TypeScript"),
        ])
        let result = Normalizer.normalise(
            "Match HUD и Type Script и снова Match HUD",
            with: glossary
        )
        let review = CorrectionReview(result)

        #expect(review.rewrites.count == 3)
        #expect(review.caption == "personal, typescript · 3 corrections")
    }

    @Test func manualTermsCaptionAsManual() {
        let glossary = Glossary(manualTerms: ["MatchHUD"])
        let review = CorrectionReview(Normalizer.normalise("открываю Match HUD", with: glossary))

        #expect(review.rewrites.map(\.packName) == [String?.none])
        #expect(review.caption == "manual · 1 correction")
    }

    @Test func manualIsNamedOnceAlongsideThePacksThatFired() {
        let glossary = Glossary(
            packs: [reviewPack("typescript", "TypeScript")],
            manualTerms: ["MatchHUD", "SafeAreaView"]
        )
        let result = Normalizer.normalise(
            "Match HUD, Type Script и Safe Area View",
            with: glossary
        )
        let review = CorrectionReview(result)

        #expect(review.rewrites.count == 3)
        #expect(review.caption == "manual, typescript · 3 corrections")
    }

    @Test func aReviewWithNoRewritesHasNoCaption() {
        let review = CorrectionReview(Normalizer.normalise("ничего не поменялось", with: Glossary()))

        #expect(review.rewrites.isEmpty)
        #expect(review.caption == "")
    }

    @Test func rangesIndexTheFinalText() {
        // `Safe Area View` → `SafeAreaView` shortens the text as normalisation proceeds, so a
        // range computed against the input and carried through unadjusted would select the
        // wrong words without crashing. Every range must be valid against `text` and select the
        // canonical spelling it claims.
        let glossary = Glossary(packs: [
            reviewPack("swiftui", "SafeAreaView", "NavigationStack"),
        ])
        let result = Normalizer.normalise(
            "обернул в Safe Area View, внутри Navigation Stack, и всё",
            with: glossary
        )
        let review = CorrectionReview(result)

        #expect(review.text == "обернул в SafeAreaView, внутри NavigationStack, и всё")
        #expect(review.rewrites.count == 2)
        for rewrite in review.rewrites {
            #expect(rewrite.range.lowerBound >= review.text.startIndex)
            #expect(rewrite.range.upperBound <= review.text.endIndex)
            #expect(String(review.text[rewrite.range]) == rewrite.term)
        }
        #expect(review.rewrites.map { String(review.text[$0.range]) }
            == ["SafeAreaView", "NavigationStack"])
    }
}
