import AppKit
import Foundation
import Testing
@testable import Macomprendo

@Suite("Correction review marked text")
struct CorrectionReviewViewTests {
    private func review(_ text: String, _ terms: String...) -> CorrectionReview {
        CorrectionReview(Normalizer.normalise(text, with: Glossary(manualTerms: terms)))
    }

    /// The substrings every underlined run covers, in document order.
    private func markedRuns(_ attributed: AttributedString) -> [(text: String, tooltip: String?)] {
        attributed.runs.compactMap { run in
            guard run.appKit.underlineStyle != nil else { return nil }
            return (String(attributed[run.range].characters), run.appKit.toolTip)
        }
    }

    @Test func carriesTheInsertedTextUnchanged() {
        let review = review("обернул в Safe Area View и всё", "SafeAreaView")
        let attributed = CorrectionReviewView.markedText(for: review)

        #expect(String(attributed.characters) == review.text)
        #expect(String(attributed.characters) == "обернул в SafeAreaView и всё")
    }

    @Test func underlinesExactlyTheRewrittenSpans() {
        let review = review("Match HUD и Safe Area View", "MatchHUD", "SafeAreaView")
        let marked = markedRuns(CorrectionReviewView.markedText(for: review))

        #expect(marked.map(\.text) == ["MatchHUD", "SafeAreaView"])
    }

    @Test func marksWithAGreenUnderlineRatherThanAColourSwap() {
        // A recoloured word reads as an error state. The weight and colour of the surrounding
        // text must survive; only the underline is added.
        let attributed = CorrectionReviewView.markedText(for: review("открываю Match HUD", "MatchHUD"))

        for run in attributed.runs {
            #expect(run.appKit.foregroundColor == nil)
            #expect(run.appKit.backgroundColor == nil)
            #expect(run.appKit.font == nil)
        }
        let underlined = attributed.runs.filter { $0.appKit.underlineStyle != nil }
        #expect(underlined.count == 1)
        #expect(underlined.allSatisfy { $0.appKit.underlineColor == CorrectionReviewView.markColor })
        #expect(CorrectionReviewView.markColor == NSColor.systemGreen)
    }

    @Test func eachMarkedSpanCarriesWhatTheModelOriginallyProduced() {
        let review = review("Match HUD и Safe Area View", "MatchHUD", "SafeAreaView")
        let marked = markedRuns(CorrectionReviewView.markedText(for: review))

        #expect(marked.map(\.tooltip) == ["Match HUD", "Safe Area View"])
    }

    @Test func leavesUnrewrittenTextUntouched() {
        let attributed = CorrectionReviewView.markedText(for: review("открываю Match HUD", "MatchHUD"))
        let plain = attributed.runs.filter { $0.appKit.underlineStyle == nil }

        #expect(plain.map { String(attributed[$0.range].characters) } == ["открываю "])
        #expect(plain.allSatisfy { $0.appKit.toolTip == nil })
    }

    @Test func aReviewWithNoRewritesMarksNothing() {
        let attributed = CorrectionReviewView.markedText(
            for: CorrectionReview(Normalizer.normalise("ничего не поменялось", with: Glossary())))

        #expect(String(attributed.characters) == "ничего не поменялось")
        #expect(attributed.runs.allSatisfy { $0.appKit.underlineStyle == nil })
    }
}

@Suite("Correction review placement")
struct CorrectionReviewLayoutTests {
    @Test func sitsWhereTheRecordingHUDSitsSoItNeverCoversTheCaret() {
        // Top-centre of the screen the mouse is on — the placement the HUD already uses to
        // stay off the text the user is dictating into.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let origin = CorrectionReviewLayout.origin(panelSize: CorrectionReviewLayout.size,
                                                   screenFrame: screen,
                                                   visibleFrame: visible)

        #expect(origin == HUDLayout.origin(panelSize: CorrectionReviewLayout.size,
                                           screenFrame: screen,
                                           visibleFrame: visible,
                                           topInset: HUDLayout.topInset))
    }

    @Test func isWiderThanTheHUDBecauseItCarriesASentence() {
        #expect(CorrectionReviewLayout.size.width > HUDLayout.size.width)
    }
}
