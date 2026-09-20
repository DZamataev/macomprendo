import Foundation
import Testing
@testable import Macomprendo

/// What a history row records about the run that produced it. Pure, so it needs no recogniser.
@Suite("Transcription run derivation")
struct TranscriptionRunTests {

    @Test func localSourceYieldsItsCatalogEngine() {
        let run = TranscriptionRun.from(.local(modelID: "gigaam-v3-e2e-ctc"),
                                        language: "ru", appVersion: "0.2.0")

        #expect(run.modelID == "gigaam-v3-e2e-ctc")
        // Becomes `sherpaOfflineASR` after ADR-0014; readers accept both, because the corpus
        // records what actually ran.
        #expect(run.engine == LocalEngine.gigaAM.rawValue)
        #expect(run.language == "ru")
        #expect(run.appVersion == "0.2.0")
    }

    @Test func aWhisperModelYieldsTheWhisperEngine() {
        let run = TranscriptionRun.from(.local(modelID: "large-v3-turbo"),
                                        language: "ru", appVersion: "0.2.0")

        #expect(run.modelID == "large-v3-turbo")
        #expect(run.engine == LocalEngine.whisperCpp.rawValue)
    }

    // A model id the catalog has never heard of still records the id: knowing which model ran
    // matters more than knowing which runtime opened it.
    @Test func anUnknownLocalModelKeepsItsIDAndRecordsNoEngine() {
        let run = TranscriptionRun.from(.local(modelID: "not-in-the-catalog"),
                                        language: nil, appVersion: "0.2.0")

        #expect(run.modelID == "not-in-the-catalog")
        #expect(run.engine == nil)
    }

    @Test func endpointSourceYieldsItsConfiguredModel() {
        let run = TranscriptionRun.from(.endpoint(id: UUID(), model: "whisper-1"),
                                        language: nil, appVersion: "0.2.0")

        #expect(run.engine == "endpoint")
        #expect(run.modelID == "whisper-1")
        // nil means auto, and must stay nil rather than becoming "".
        #expect(run.language == nil)
    }

    // A blank language setting is the same thing as automatic, and storing "" would make the
    // corpus unable to tell the two apart.
    @Test func aBlankLanguageIsRecordedAsAutomatic() {
        let run = TranscriptionRun.from(.local(modelID: "large-v3-turbo"),
                                        language: "   ", appVersion: "0.2.0")

        #expect(run.language == nil)
    }

    @Test func theCurrentAppVersionIsNeverEmpty() {
        #expect(TranscriptionRun.currentAppVersion.isEmpty == false)
    }
}
