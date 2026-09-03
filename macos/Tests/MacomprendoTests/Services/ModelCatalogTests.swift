import Foundation
import Testing
@testable import Macomprendo

@Suite struct ModelCatalogTests {

    @Test func everyCatalogEntryReportsItsKindFromItsEngine() {
        #expect(LocalEngine.whisperCpp.kind == .asr)
        #expect(LocalEngine.gigaAM.kind == .asr)
        #expect(ModelCatalog.all.allSatisfy { $0.kind == .asr })
    }

    @Test func allByKindPartitionsTheCatalog() {
        #expect(ModelCatalog.all(kind: .asr).count == ModelCatalog.all.count)
        #expect(ModelCatalog.all(kind: .tts).isEmpty)
    }

    @Test func containsExactlyTheThirteenOfferedModelsInOrder() {
        #expect(ModelCatalog.all.map(\.id) == [
            "tiny", "tiny.en", "base", "base.en",
            "small", "small.en", "medium", "medium.en",
            "large-v3-turbo",
            "gigaam-v3-e2e-ctc", "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc", "gigaam-multilingual-large-ctc"
        ])
    }

    @Test func defaultAndLightweightIDsAreInTheCatalog() {
        #expect(ModelCatalog.defaultID == "large-v3-turbo")
        #expect(ModelCatalog.lightweightID == "base")
        #expect(ModelCatalog.model(id: ModelCatalog.defaultID) != nil)
        #expect(ModelCatalog.model(id: ModelCatalog.lightweightID) != nil)
    }

    @Test func everyModelHasAPositiveApproximateSizeAndANonEmptyDisplayName() {
        for model in ModelCatalog.all {
            #expect(!model.displayName.isEmpty, "missing display name for \(model.id)")
            for file in model.files {
                #expect(file.sizeBytes > 0, "missing size for \(model.id)'s \(file.fileName)")
            }
        }
    }

    @Test func modelIDsAreUnique() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    }

    @Test func lookupByIDIsExactAndReturnsNilForUnknownIDs() {
        #expect(ModelCatalog.model(id: "base")?.file(.ggml)?.fileName == "ggml-base.bin")
        #expect(ModelCatalog.model(id: "base.en")?.file(.ggml)?.fileName == "ggml-base.en.bin")
        #expect(ModelCatalog.model(id: "nonexistent") == nil)
        #expect(ModelCatalog.model(id: "BASE") == nil)
    }

    @Test func everyWhisperEntryIsASingleGGMLFileFromHuggingFace() throws {
        for model in ModelCatalog.all where model.engine == .whisperCpp {
            #expect(model.files.count == 1, "\(model.id) should be one file")
            let file = try #require(model.file(.ggml))
            #expect(file.fileName == "ggml-\(model.id).bin")
            #expect(file.downloadURL == URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model.id).bin"
            )!)
        }
    }

    @Test func totalSizeIsTheSumOfTheFileSet() {
        let model = LocalModel(
            id: "x", displayName: "X", engine: .gigaAM, languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "x-model.onnx", sizeBytes: 100,
                          sha256: "", downloadURL: URL(string: "https://example.com/m")!),
                ModelFile(role: .tokens, fileName: "x-tokens.txt", sizeBytes: 23,
                          sha256: "", downloadURL: URL(string: "https://example.com/t")!)
            ],
            brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                              sourceURL: URL(string: "https://example.com")!)
        )
        #expect(model.totalSizeBytes == 123)
        #expect(model.file(.tokens)?.fileName == "x-tokens.txt")
        #expect(model.file(.encoder) == nil)
    }

    @Test func localFileNamesAreUniqueAcrossTheWholeCatalog() {
        let names = ModelCatalog.all.flatMap { $0.files.map(\.fileName) }
        #expect(names.count == Set(names).count, "two catalog entries share a local file name")
    }

    @Test func everyEntryDeclaresAValidFileSetForItsEngine() {
        for model in ModelCatalog.all {
            let roles = Set(model.files.map(\.role))
            switch model.engine {
            case .whisperCpp:
                #expect(roles == [.ggml], "\(model.id) is not a whisper file set")
            case .gigaAM:
                let ctc: Set<ModelFileRole> = [.ctcModel, .tokens]
                let transducer: Set<ModelFileRole> = [.encoder, .decoder, .joiner, .tokens]
                #expect(roles == ctc || roles == transducer, "\(model.id) is not a sherpa file set")
            }
        }
    }

    @Test func offersFourGigaAMModels() {
        #expect(ModelCatalog.all(for: .gigaAM).map(\.id) == [
            "gigaam-v3-e2e-ctc",
            "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc",
            "gigaam-multilingual-large-ctc"
        ])
    }

    @Test func theRussianEntriesDeclareRussianAndTheMultilingualOnesDeclareFive() {
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-ctc")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-large-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
    }

    @Test func everyGigaAMEntryHasAUsableBrief() {
        for model in ModelCatalog.all(for: .gigaAM) {
            #expect(!model.brief.summary.isEmpty, "\(model.id) has no summary")
            #expect(!model.brief.strengths.isEmpty, "\(model.id) lists no strengths")
            #expect(!model.brief.limitations.isEmpty, "\(model.id) lists no limitations")
        }
    }

    @Test func theMultilingualBriefsWarnThatThereIsNoPunctuation() {
        for id in ["gigaam-multilingual-ctc", "gigaam-multilingual-large-ctc"] {
            let model = ModelCatalog.model(id: id)!
            #expect(model.brief.limitations.contains { $0.lowercased().contains("punctuation") },
                    "\(id) does not warn about missing punctuation")
        }
    }

    @Test func everyBenchmarkIsAttributedToAnHTTPSSource() {
        for model in ModelCatalog.all where !model.brief.benchmarks.isEmpty {
            #expect(model.brief.sourceURL.scheme == "https", "\(model.id) benchmark source is not https")
        }
    }

    @Test func theTransducerEntryDeclaresFourFiles() {
        let rnnt = ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")!
        #expect(Set(rnnt.files.map(\.role)) == [.encoder, .decoder, .joiner, .tokens])
    }

    // MARK: - languagesText

    @Test func aModelWithNoPublishedLanguageListIsCalledMultilingualRatherThanBlank() {
        #expect(LocalModel.languagesText(nil) == "90+ languages")
        #expect(LocalModel.languagesText([]) == "90+ languages")
    }

    @Test func aPublishedLanguageListIsNamedInWords() {
        #expect(LocalModel.languagesText(["ru"]) == "Russian")
        #expect(LocalModel.languagesText(["ru", "en"]) == "Russian, English")
        // An unknown code is shown as itself rather than dropped.
        #expect(LocalModel.languagesText(["zzz"]).contains("zzz"))
    }

    @Test func theInstancePropertyMatchesTheStaticFunctionForTheModelsOwnLanguages() {
        let model = LocalModel(id: "x", displayName: "X", engine: .gigaAM, languages: ["ru", "en"],
                                files: [],
                                brief: ModelBrief(summary: "", strengths: [], limitations: [],
                                                  benchmarks: [],
                                                  sourceURL: URL(string: "https://example.com")!))
        #expect(model.languagesText == "Russian, English")
        #expect(model.languagesText == LocalModel.languagesText(model.languages))
    }
}
