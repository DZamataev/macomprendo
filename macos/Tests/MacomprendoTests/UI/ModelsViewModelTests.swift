import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct ModelsViewModelTests {
    private static let testBrief = ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                                               sourceURL: URL(string: "https://example.invalid")!)

    private func makeCatalog() -> [LocalModel] {
        [
            LocalModel(id: "base",
                          displayName: "Base",
                          engine: .whisperCpp,
                          languages: nil,
                          files: [ModelFile(role: .ggml, fileName: "ggml-base.bin", sizeBytes: 148_000_000,
                                            sha256: "aaa", downloadURL: URL(string: "https://example.invalid/ggml-base.bin")!)],
                          brief: Self.testBrief),
            LocalModel(id: "large-v3-turbo",
                          displayName: "Large v3 Turbo",
                          engine: .whisperCpp,
                          languages: nil,
                          files: [ModelFile(role: .ggml, fileName: "ggml-large-v3-turbo.bin", sizeBytes: 1_620_000_000,
                                            sha256: "bbb", downloadURL: URL(string: "https://example.invalid/ggml-large-v3-turbo.bin")!)],
                          brief: Self.testBrief)
        ]
    }

    /// A synthetic multi-file entry: the catalog itself still holds only one-file
    /// whisper models.
    private func twoFileModel() -> LocalModel {
        LocalModel(id: "two-file",
                      displayName: "Two File",
                      engine: .gigaAM,
                      languages: ["ru"],
                      files: [
                          ModelFile(role: .ctcModel, fileName: "two-model.onnx", sizeBytes: 300,
                                    sha256: "ccc", downloadURL: URL(string: "https://example.invalid/model.onnx")!),
                          ModelFile(role: .tokens, fileName: "two-tokens.txt", sizeBytes: 5,
                                    sha256: "ddd", downloadURL: URL(string: "https://example.invalid/tokens.txt")!)
                      ],
                      brief: Self.testBrief)
    }

    @Test func refreshBuildsARowPerCatalogEntry() async {
        let manager = StubModelManager()
        manager.states = ["base": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())

        await viewModel.refresh()

        #expect(viewModel.rows.map(\.id) == ["base", "large-v3-turbo"])
        #expect(viewModel.rows[0].state == .downloaded)
        #expect(viewModel.rows[1].state == .notDownloaded)
    }

    @Test func diskUsageCountsOnlyDownloadedModels() async {
        let manager = StubModelManager()
        manager.states = ["base": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())

        await viewModel.refresh()
        #expect(viewModel.diskUsage == 148_000_000)
        #expect(viewModel.diskUsageText.isEmpty == false)
    }

    @Test func diskUsageSumsTheWholeFileSetOfEveryDownloadedModel() async {
        let manager = StubModelManager()
        manager.states = ["two-file": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog() + [twoFileModel()])

        await viewModel.refresh()

        // 300 + 5, not just the first file of the set.
        #expect(viewModel.diskUsage == 305)
    }

    @Test func archiveDiskUsageUsesTheExtractedFootprintNotTheDownloadSize() async {
        let archive = LocalModel(
            id: "voice", displayName: "Voice", engine: .sherpaVits, languages: ["en"],
            files: [ModelFile(role: .archive, fileName: "voice.tar.bz2", sizeBytes: 5,
                              sha256: "eee", downloadURL: URL(string: "https://example.invalid/voice.tar.bz2")!)],
            brief: Self.testBrief,
            installedSizeBytes: 99,
            archiveSentinel: "model.onnx"
        )
        let manager = StubModelManager()
        manager.states = ["voice": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: [archive])

        await viewModel.refresh()

        #expect(viewModel.diskUsage == 99)
    }

    @Test func downloadReportsProgressAndEndsDownloaded() async {
        let manager = StubModelManager()
        manager.downloadFractions = [0.5, 1.0]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())
        await viewModel.refresh()

        viewModel.download("base")
        await viewModel.downloadTasks["base"]?.value

        if case .downloaded = viewModel.rows[0].state {
            // expected
        } else {
            Issue.record("expected base to be .downloaded, got \(viewModel.rows[0].state)")
        }
        #expect(viewModel.diskUsage == 148_000_000)
    }

    @Test func aFailedDownloadShowsTheErrorOnTheRow() async {
        let manager = StubModelManager()
        manager.downloadError = MacomprendoError.modelDownloadFailed("SHA-256 mismatch")
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())
        await viewModel.refresh()

        viewModel.download("base")
        await viewModel.downloadTasks["base"]?.value

        #expect(viewModel.rows[0].state
                == .failed(ErrorText.describe(MacomprendoError.modelDownloadFailed("SHA-256 mismatch"))))
    }

    @Test func aCancelledDownloadIsNotShownAsFailed() async {
        let manager = StubModelManager()
        manager.downloadError = MacomprendoError.cancelled
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())
        await viewModel.refresh()

        viewModel.download("base")
        await viewModel.downloadTasks["base"]?.value

        #expect(viewModel.rows[0].state == .notDownloaded)
    }

    @Test func deleteRemovesTheModelAndItsDiskUsage() async {
        let manager = StubModelManager()
        manager.states = ["base": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())
        await viewModel.refresh()

        await viewModel.delete("base")

        #expect(manager.deleted == ["base"])
        #expect(viewModel.rows[0].state == .notDownloaded)
        #expect(viewModel.diskUsage == 0)
    }

    @Test func cancellingADownloadClearsTheTask() async {
        let manager = StubModelManager()
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())
        await viewModel.refresh()

        viewModel.download("base")
        viewModel.cancelDownload("base")
        #expect(viewModel.downloadTasks["base"] == nil)
    }

    @Test func stateCaptionsNoLongerPointAtADeletedTab() {
        #expect(DictationTab.stateCaption(for: nil) == "Checking…")
        #expect(DictationTab.stateCaption(for: .notDownloaded)
                == "Not downloaded — use the Download button on this row.")
        #expect(DictationTab.stateCaption(for: .downloading(fraction: 0.42)) == "Downloading… 42%")
        #expect(DictationTab.stateCaption(for: .downloaded) == "Ready.")
        #expect(DictationTab.stateCaption(for: .failed("boom")) == "boom")
    }
}
