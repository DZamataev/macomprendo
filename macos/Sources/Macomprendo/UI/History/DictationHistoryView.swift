import SwiftUI

struct DictationHistoryView: View {
    @ObservedObject var controller: DictationHistoryController
    @State private var isClearConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }

            if controller.entries.isEmpty, !controller.isLoading {
                VStack(spacing: 8) {
                    Icon(.clipboard, size: 28)
                        .foregroundStyle(.secondary)
                    Text("No dictation history")
                        .font(.headline)
                    Text("Saved dictations will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.entries) { entry in
                        historyRow(entry)
                            .onAppear { loadNextPageIfNeeded(for: entry) }
                    }

                    if controller.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .toolbar {
            Button("Clear History…") {
                isClearConfirmationPresented = true
            }
        }
        .confirmationDialog("Clear dictation history?",
                            isPresented: $isClearConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await controller.clear() }
            }
        } message: {
            Text("This permanently removes all saved dictation transcripts.")
        }
    }

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text(sourceLabel(for: entry.kind))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(entry.text)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)

            HStack {
                if controller.copiedEntryID == entry.id {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { controller.copy(entry) } label: {
                    Label { Text("Copy") } icon: {
                        Icon(.copy, size: 14)
                    }
                }
                .buttonStyle(.borderless)
                .help("Copy the complete transcript")
            }
        }
        .padding(.vertical, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warning, size: 14)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func loadNextPageIfNeeded(for entry: DictationHistoryEntry) {
        guard entry.id == controller.entries.last?.id, controller.hasMore else { return }
        Task { await controller.loadNextPage() }
    }

    private func sourceLabel(for kind: DictationHistoryKind) -> String {
        switch kind {
        case .dictation:
            "Dictation"
        case .dictationAndRefine:
            "Dictation & Refine"
        }
    }
}
