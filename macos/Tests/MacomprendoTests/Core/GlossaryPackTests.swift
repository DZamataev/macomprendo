import Foundation
import Testing
@testable import Macomprendo

// MARK: - Parsing

@Test func parsesTermsAndIgnoresCommentsAndBlanks() {
    let pack = GlossaryPack.parse("""
    # pack: typescript
    # a comment

    jq
    git rebase
    """, name: "typescript")
    #expect(pack.name == "typescript")
    #expect(pack.terms.map(\.canonical) == ["jq", "git rebase"])
    #expect(pack.skippedLineCount == 0)
}

@Test func parsesCyrillicForms() {
    let pack = GlossaryPack.parse("TextEditor = текст-эдитор, текстэдитор", name: "p")
    #expect(pack.terms.first?.canonical == "TextEditor")
    #expect(pack.terms.first?.cyrillicForms == ["текст-эдитор", "текстэдитор"])
}

@Test func aTermWithoutAnEqualsHasNoForms() {
    let pack = GlossaryPack.parse("xcodebuild", name: "p")
    #expect(pack.terms.first?.cyrillicForms.isEmpty == true)
}

@Test func surroundingWhitespaceIsTrimmedButInteriorWhitespaceIsSignificant() {
    let pack = GlossaryPack.parse("   git rebase   \n\t Safe Area View\t", name: "p")
    #expect(pack.terms.map(\.canonical) == ["git rebase", "Safe Area View"])
}

@Test func whitespaceAroundTheEqualsAndCommasIsTrimmed() {
    let pack = GlossaryPack.parse("  TextEditor   =   текст-эдитор ,  текстэдитор  ", name: "p")
    #expect(pack.terms.first?.canonical == "TextEditor")
    #expect(pack.terms.first?.cyrillicForms == ["текст-эдитор", "текстэдитор"])
}

@Test func aCommentIsRecognisedAfterLeadingWhitespace() {
    let pack = GlossaryPack.parse("   # not a term\njq", name: "p")
    #expect(pack.terms.map(\.canonical) == ["jq"])
    #expect(pack.skippedLineCount == 0)
}

@Test func anEqualsInsideATermIsSplitAtTheFirstOne() {
    let pack = GlossaryPack.parse("a = b = c", name: "p")
    #expect(pack.terms.first?.canonical == "a")
    #expect(pack.terms.first?.cyrillicForms == ["b = c"])
}

@Test func duplicateTermKeepsTheFirst() {
    let pack = GlossaryPack.parse("""
    jq = джейкью
    nvm
    jq = гэкью
    """, name: "p")
    #expect(pack.terms.map(\.canonical) == ["jq", "nvm"])
    #expect(pack.terms.first?.cyrillicForms == ["джейкью"])
    #expect(pack.skippedLineCount == 0)
}

@Test func malformedLinesAreSkippedAndCounted() {
    let pack = GlossaryPack.parse("""
    jq
    =
    = текст
    TextEditor =
    nvm
    """, name: "p")
    #expect(pack.terms.map(\.canonical) == ["jq", "nvm"])
    #expect(pack.skippedLineCount == 3)
}

@Test func aPackWithOnlyMalformedLinesStillParses() {
    let pack = GlossaryPack.parse("=\n", name: "p")
    #expect(pack.terms.isEmpty)
    #expect(pack.skippedLineCount == 1)
}

@Test func emptyTextIsAnEmptyPack() {
    let pack = GlossaryPack.parse("", name: "p")
    #expect(pack.terms.isEmpty)
    #expect(pack.skippedLineCount == 0)
}

// MARK: - Serialisation

@Test func roundTripIsByteIdentical() {
    let text = """
    # pack: typescript
    # Terms the recogniser gets wrong. One per line.

    jq
      nvm\u{20}\u{20}
    git rebase
    TextEditor   =  текст-эдитор ,текстэдитор
    =
    xcodebuild
    """
    #expect(GlossaryPack.parse(text, name: "typescript").serialise() == text)
}

@Test func roundTripPreservesATrailingNewline() {
    let text = "jq\n\n"
    #expect(GlossaryPack.parse(text, name: "p").serialise() == text)
}

@Test func aPackBuiltWithoutSourceTextSerialisesItsTerms() {
    let pack = GlossaryPack(name: "p", terms: [
        GlossaryTerm(canonical: "jq"),
        GlossaryTerm(canonical: "TextEditor", cyrillicForms: ["текст-эдитор", "текстэдитор"]),
    ])
    #expect(pack.serialise() == "jq\nTextEditor = текст-эдитор, текстэдитор")
}

@Test func changingATermDropsTheOriginalTextAndSerialisesTheTerms() {
    var pack = GlossaryPack.parse("# pack: p\n\njq\n", name: "p")
    pack.terms = [GlossaryTerm(canonical: "nvm")]
    #expect(pack.serialise() == "nvm")
}
