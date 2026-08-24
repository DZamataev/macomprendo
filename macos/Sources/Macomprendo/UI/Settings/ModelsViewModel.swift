import Foundation
import SwiftUI

@MainActor
final class ModelsViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let model: WhisperModel
        var state: ModelState
        var id: String { model.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var diskUsage: Int64 = 0
    private(set) var downloadTasks: [String: Task<Void, Never>] = [:]

    private let models: any ModelManaging
    private let catalog: [WhisperModel]

    init(models: any ModelManaging, catalog: [WhisperModel] = ModelCatalog.all) {
        self.models = models
        self.catalog = catalog
    }

    func refresh() async {
        var refreshed: [Row] = []
        for model in catalog {
            refreshed.append(Row(model: model, state: await models.state(of: model.id)))
        }
        rows = refreshed
        recomputeDiskUsage()
    }

    func download(_ id: String) {
        guard downloadTasks[id] == nil else { return }
        setState(.downloading(fraction: 0), for: id)
        downloadTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                for try await fraction in self.models.download(id) {
                    self.setState(.downloading(fraction: fraction), for: id)
                }
                self.setState(await self.models.state(of: id), for: id)
            } catch is CancellationError {
                // Cancellation is not a failure: reflect whatever `ModelManaging`
                // settled on (typically `.notDownloaded`, with the partial file kept
                // for a later resume) instead of showing `.failed`.
                self.setState(await self.models.state(of: id), for: id)
            } catch MacomprendoError.cancelled {
                // `WhisperModelManager.download` normalises its own internal
                // `CancellationError` to `MacomprendoError.cancelled` before it
                // reaches this stream, so both cases must be handled the same way.
                self.setState(await self.models.state(of: id), for: id)
            } catch {
                self.setState(.failed(ErrorText.describe(error)), for: id)
            }
            self.downloadTasks[id] = nil
            self.recomputeDiskUsage()
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
    }

    func delete(_ id: String) async {
        do {
            try await models.delete(id)
        } catch {
            setState(.failed(ErrorText.describe(error)), for: id)
            return
        }
        setState(await models.state(of: id), for: id)
        recomputeDiskUsage()
    }

    var diskUsageText: String {
        ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func setState(_ state: ModelState, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    private func recomputeDiskUsage() {
        diskUsage = rows.reduce(into: Int64(0)) { total, row in
            if case .downloaded = row.state { total += row.model.sizeBytes }
        }
    }
}
