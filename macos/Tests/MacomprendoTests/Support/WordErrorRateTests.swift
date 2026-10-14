import Testing

/// The normalisation and the two error rates the long-audio benchmark compares transcripts
/// with. Written before `WordErrorRate` exists, so the RED is on the record.
///
/// Normalisation, both sides alike: lowercase, `ё`→`е`, punctuation removed, whitespace
/// collapsed, digits kept. A hyphen separates words (`какой-то` == `какой то`); every other
/// punctuation mark is dropped without splitting the word it sits in (`don't` == `dont`).
@Suite struct WordErrorRateTests {

    private func close(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) < 0.000_1
    }

    @Test("identical text after normalisation is zero error")
    func identicalTextIsZero() {
        let reference = "Сейчас мы на оживлённом Невском проспекте!"
        let hypothesis = "сейчас мы на оживленном невском проспекте"
        #expect(close(WordErrorRate.wer(reference: reference, hypothesis: hypothesis), 0))
        #expect(close(WordErrorRate.cer(reference: reference, hypothesis: hypothesis), 0))
    }

    @Test("one substituted word in four")
    func substitution() {
        #expect(close(WordErrorRate.wer(reference: "мы идем домой сейчас", hypothesis: "мы идем дамой сейчас"),
                      1.0 / 4.0))
    }

    @Test("one inserted word")
    func insertion() {
        #expect(close(WordErrorRate.wer(reference: "красный дом", hypothesis: "красный большой дом"),
                      1.0 / 2.0))
    }

    @Test("one deleted word")
    func deletion() {
        #expect(close(WordErrorRate.wer(reference: "красный большой дом", hypothesis: "красный дом"),
                      1.0 / 3.0))
    }

    @Test("an empty reference is zero when the hypothesis is empty too")
    func emptyReferenceAndHypothesis() {
        #expect(close(WordErrorRate.wer(reference: "", hypothesis: ""), 0))
        #expect(close(WordErrorRate.cer(reference: "", hypothesis: ""), 0))
    }

    @Test("an empty reference against speech is a full error")
    func emptyReferenceWithHypothesis() {
        #expect(close(WordErrorRate.wer(reference: "", hypothesis: "привет"), 1))
        #expect(close(WordErrorRate.cer(reference: "", hypothesis: "привет"), 1))
    }

    @Test("normalisation: case, ё, punctuation, hyphen, digits, whitespace")
    func normalisation() {
        #expect(WordErrorRate.words("Ёлка-палка, 42!  Как  дела?") == ["елка", "палка", "42", "как", "дела"])
        #expect(WordErrorRate.words("don't") == ["dont"])
        // Hyphens separate words the way the recognisers write them.
        #expect(close(WordErrorRate.wer(reference: "какой-то странный день",
                                       hypothesis: "какой то странный день"), 0))
        // Digits survive as tokens and count as errors when wrong.
        #expect(close(WordErrorRate.wer(reference: "ждем 20 минут", hypothesis: "ждем 30 минут"), 1.0 / 3.0))
    }

    @Test("character error rate counts characters, not words")
    func characterErrorRate() {
        #expect(close(WordErrorRate.cer(reference: "кот", hypothesis: "кто"), 2.0 / 3.0))
    }

    @Test("Levenshtein distance on plain sequences")
    func distance() {
        #expect(WordErrorRate.levenshtein(of: [String](), with: [String]()) == 0)
        #expect(WordErrorRate.levenshtein(of: [String](), with: ["a"]) == 1)
        #expect(WordErrorRate.levenshtein(of: ["a", "b"], with: ["a", "b", "c"]) == 1)
        #expect(WordErrorRate.levenshtein(of: ["a", "b", "c"], with: ["a", "x", "c"]) == 1)
    }

    @Test("a SubRip file yields its cue text lines only")
    func subRipReader() {
        let srt = """
        1
        00:00:00,979 --> 00:00:06,720
        Андрей это тех лица разработки

        2
        00:00:09,240 --> 00:00:13,219
        так это Коля
        не будет правильно же

        3
        00:00:13,219 --> 00:00:16,160
        он мне не говорил что будет
        """

        let text = SubRipText.text(from: srt)
        #expect(text == "Андрей это тех лица разработки\nтак это Коля\nне будет правильно же\nон мне не говорил что будет")
    }

    @Test("a SubRip file without cue text is empty")
    func subRipReaderEmpty() {
        #expect(SubRipText.text(from: "") == "")
        #expect(SubRipText.text(from: "1\n00:00:00,000 --> 00:00:01,000\n") == "")
    }
}
