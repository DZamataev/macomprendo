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

    @Test func everyDownloadURLPointsAtTheHuggingFaceGGMLFile() {
        for model in ModelCatalog.all {
            #expect(model.downloadURL == URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model.id).bin"
            )!, "wrong URL for \(model.id)")
        }
    }

    @Test func fileNameMatchesTheLastPathComponentOfTheDownloadURL() {
        for model in ModelCatalog.all {
            #expect(model.fileName == "ggml-\(model.id).bin")
            #expect(model.fileName == model.downloadURL.lastPathComponent)
        }
    }

    @Test func everyModelHasAPositiveApproximateSizeAndANonEmptyDisplayName() {
        for model in ModelCatalog.all {
            #expect(model.sizeBytes > 0, "missing size for \(model.id)")
            #expect(!model.displayName.isEmpty, "missing display name for \(model.id)")
        }
    }

    @Test func modelIDsAreUnique() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    }

    @Test func lookupByIDIsExactAndReturnsNilForUnknownIDs() {
        #expect(ModelCatalog.model(id: "base")?.fileName == "ggml-base.bin")
        #expect(ModelCatalog.model(id: "base.en")?.fileName == "ggml-base.en.bin")
        #expect(ModelCatalog.model(id: "nonexistent") == nil)
        #expect(ModelCatalog.model(id: "BASE") == nil)
    }
}
