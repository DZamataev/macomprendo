import Foundation
import Testing
@testable import Macomprendo

@Test func historyEntryCarriesStableIdentityAndKind() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date,
                                      kind: .dictationAndRefine, text: "hello")
    #expect(entry.id == 42)
    #expect(entry.createdAt == date)
    #expect(entry.kind == .dictationAndRefine)
    #expect(entry.text == "hello")
}

@Test func historyEntryEqualityIncludesAllStoredValues() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date,
                                      kind: .dictationAndRefine, text: "hello")
    #expect(entry == DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictationAndRefine, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 43, createdAt: date,
                                           kind: .dictationAndRefine, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictation, text: "hello"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date,
                                           kind: .dictationAndRefine, text: "goodbye"))
}

@Test func historyPageCarriesTheNextCursor() {
    let page = DictationHistoryPage(entries: [], nextCursor: 41)
    #expect(page.nextCursor == 41)
}

@Test func historyEntryDefaultsEveryProvenanceFieldToNil() {
    let entry = DictationHistoryEntry(id: 1, createdAt: Date(timeIntervalSince1970: 1),
                                      kind: .dictation, text: "hello")
    #expect(entry.rawText == nil)
    #expect(entry.modelID == nil)
    #expect(entry.engine == nil)
    #expect(entry.language == nil)
    #expect(entry.appVersion == nil)
}

// Two rows that differ only in what produced them are different rows: equality that ignored
// the run would let a test pass while the corpus lost its provenance.
@Test func historyEntryEqualityIncludesTheRawTextAndTheRun() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date, kind: .dictation, text: "npm",
                                      rawText: "NPM", modelID: "large-v3-turbo",
                                      engine: "whisperCpp", language: "ru", appVersion: "0.2.0")

    #expect(entry == DictationHistoryEntry(id: 42, createdAt: date, kind: .dictation, text: "npm",
                                           rawText: "NPM", modelID: "large-v3-turbo",
                                           engine: "whisperCpp", language: "ru",
                                           appVersion: "0.2.0"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date, kind: .dictation, text: "npm",
                                           rawText: nil, modelID: "large-v3-turbo",
                                           engine: "whisperCpp", language: "ru",
                                           appVersion: "0.2.0"))
    #expect(entry != DictationHistoryEntry(id: 42, createdAt: date, kind: .dictation, text: "npm",
                                           rawText: "NPM", modelID: "base",
                                           engine: "whisperCpp", language: "ru",
                                           appVersion: "0.2.0"))
}

@Test func aTranscriptionRunCarriesWhatProducedTheText() {
    let run = TranscriptionRun(modelID: "gigaam-v3-e2e-ctc", engine: "gigaAM",
                               language: nil, appVersion: "0.2.0")
    #expect(run.modelID == "gigaam-v3-e2e-ctc")
    #expect(run.engine == "gigaAM")
    #expect(run.language == nil)
    #expect(run.appVersion == "0.2.0")
}
