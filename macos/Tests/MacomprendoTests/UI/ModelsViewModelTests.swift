import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct ModelsViewModelTests {
    private func makeCatalog() -> [WhisperModel] {
        [
            WhisperModel(id: "base",
                         displayName: "Base",
                         fileName: "ggml-base.bin",
                         sizeBytes: 148_000_000,
                         sha256: "aaa",
                         downloadURL: URL(string: "https://example.invalid/ggml-base.bin")!),
            WhisperModel(id: "large-v3-turbo",
                         displayName: "Large v3 Turbo",
                         fileName: "ggml-large-v3-turbo.bin",
                         sizeBytes: 1_620_000_000,
                         sha256: "bbb",
                         downloadURL: URL(string: "https://example.invalid/ggml-large-v3-turbo.bin")!)
        ]
    }

    @Test func refreshBuildsARowPerCatalogEntry() async {
        let manager = StubModelManager()
        manager.states = ["base": .downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin"))]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())

        await viewModel.refresh()

        #expect(viewModel.rows.map(\.id) == ["base", "large-v3-turbo"])
        #expect(viewModel.rows[0].state == .downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin")))
        #expect(viewModel.rows[1].state == .notDownloaded)
    }

    @Test func diskUsageCountsOnlyDownloadedModels() async {
        let manager = StubModelManager()
        manager.states = ["base": .downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin"))]
        let viewModel = ModelsViewModel(models: manager, catalog: makeCatalog())

        await viewModel.refresh()
        #expect(viewModel.diskUsage == 148_000_000)
        #expect(viewModel.diskUsageText.isEmpty == false)
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
        manager.states = ["base": .downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin"))]
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
                == "Not downloaded — download it under Speech models below.")
        #expect(DictationTab.stateCaption(for: .downloading(fraction: 0.42)) == "Downloading… 42%")
        #expect(DictationTab.stateCaption(for: .downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin")))
                == "Ready.")
        #expect(DictationTab.stateCaption(for: .failed("boom")) == "boom")
    }
}
