import Foundation
import Testing
@testable import Macomprendo

@Suite struct ModelCatalogTests {

    @Test func containsExactlyTheNineOfferedModelsInOrder() {
        #expect(ModelCatalog.all.map(\.id) == [
            "tiny", "tiny.en", "base", "base.en",
            "small", "small.en", "medium", "medium.en",
            "large-v3-turbo"
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
        let model = LocalASRModel(
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
}
