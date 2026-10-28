import Foundation
import Testing
@testable import Macomprendo

@Suite struct PhantomGateTests {

    /// A speech share that records whether the gate asked for it.
    private final class Probe: @unchecked Sendable {
        let value: Double
        private(set) var asked = 0
        init(_ value: Double) { self.value = value }
        func measure() throws -> Double {
            asked += 1
            return value
        }
    }

    private func verdict(detected: String?, expected: String?, speech: Probe,
                         duration: TimeInterval = 2) throws -> PhantomGate.Verdict {
        try PhantomGate.verdict(detected: detected, expected: expected, duration: duration,
                                speechFraction: speech.measure)
    }

    @Test func aSegmentWithNoDetectedLanguageIsKeptUnmeasured() throws {
        let speech = Probe(0)
        #expect(try verdict(detected: nil, expected: "ru", speech: speech) == .keep)
        #expect(speech.asked == 0)
    }

    @Test func theTranscriptsOwnLanguageIsKeptUnmeasured() throws {
        let speech = Probe(0)
        #expect(try verdict(detected: "ru", expected: "ru", speech: speech) == .keep)
        #expect(speech.asked == 0)
    }

    @Test func beforeAnyLanguageIsKnownOnlySilenceIsDropped() throws {
        #expect(try verdict(detected: "en", expected: nil, speech: Probe(0)) == .drop)
        #expect(try verdict(detected: "en", expected: nil, speech: Probe(0.3)) == .keep)
    }

    @Test func anotherLanguageOverSilenceIsDropped() throws {
        // `*Sigh*` on a Russian call: whisper says `en`, Silero hears nothing.
        #expect(try verdict(detected: "en", expected: "ru", speech: Probe(0)) == .drop)
        #expect(try verdict(detected: "en", expected: "ru", speech: Probe(0.09)) == .drop)
    }

    @Test func aShortStretchOfSpeechInAnotherLanguageIsDecodedAgain() throws {
        // `On sobie nie nienka` for «Он сегодня нянька»: real speech, wrong guess.
        #expect(try verdict(detected: "pl", expected: "ru", speech: Probe(0.55), duration: 2.5)
                == .redecode(language: "ru"))
        #expect(try verdict(detected: "en", expected: "ru", speech: Probe(0.1), duration: 5)
                == .redecode(language: "ru"))
    }

    @Test func aLongStretchInAnotherLanguageIsSomeoneReallySpeakingIt() throws {
        #expect(try verdict(detected: "en", expected: "ru", speech: Probe(0.8), duration: 5.1)
                == .keep)
    }

    @Test func theTallyLeaderIsTheLanguageWithTheMostSeconds() {
        var tally = LanguageTally()
        #expect(tally.leader == nil)
        tally.add("ru", seconds: 3)
        tally.add("en", seconds: 2)
        tally.add("en", seconds: 2)
        #expect(tally.leader == "en")
        tally.add(nil, seconds: 100)
        #expect(tally.leader == "en")
    }

    @Test func aTieKeepsTheLanguageThatLedFirst() {
        var tally = LanguageTally()
        tally.add("ru", seconds: 2)
        tally.add("en", seconds: 2)
        #expect(tally.leader == "ru")
    }
}
