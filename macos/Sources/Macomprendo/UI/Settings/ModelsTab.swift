import SwiftUI

struct ModelsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ModelsTabContent(viewModel: model.modelsViewModel)
    }
}

private struct ModelsTabContent: View {
    @ObservedObject var viewModel: ModelsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech models")
                .font(.headline)
            Text("Models are stored in ~/Library/Application Support/Macomprendo/models.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(viewModel.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model.displayName)
                        Text(ModelsViewModel.sizeText(row.model.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    stateView(row)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)

            HStack {
                Text("Disk usage: \(viewModel.diskUsageText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await viewModel.refresh() } }
            }
        }
        .padding()
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private func stateView(_ row: ModelsViewModel.Row) -> some View {
        switch row.state {
        case .notDownloaded:
            Button("Download") { viewModel.download(row.id) }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90)
                Button("Cancel") { viewModel.cancelDownload(row.id) }
            }
        case .downloaded:
            HStack(spacing: 8) {
                Label { Text("Ready") } icon: { Icon(.success, size: 14) }
                    .foregroundStyle(.green)
                Button("Delete", role: .destructive) { Task { await viewModel.delete(row.id) } }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Label { Text(message) } icon: { Icon(.warning, size: 14) }
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { viewModel.download(row.id) }
            }
        }
    }
}
