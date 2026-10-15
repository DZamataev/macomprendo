import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Transcripts window: the stored transcripts on the left, the open one on the right —
/// its progress, segments, run and actions — and a drop zone that starts a job.
///
/// All state lives on the controllers; the view is a thin rendering of them (invariant 1).
/// The only state it owns is the export failure the AppKit save panel can produce, which no
/// controller sees.
struct TranscriptsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var library: TranscriptLibraryController
    @ObservedObject var transcription: FileTranscriptionController

    @State private var isDeleteConfirmationPresented = false
    /// A failure from writing an export. Export is the one action whose failure belongs to no
    /// controller, so the window reports it itself.
    @State private var actionError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            transcription.transcribe(fileAt: url)
            return true
        }
        .task {
            // Readiness — what a job's preflight consults — is computed from the models view
            // model's rows, which nothing has refreshed when this window opens straight from
            // the menu. Refresh them first, so a job started or resumed from this window is
            // not refused as "not downloaded" on stale state (R9).
            await model.modelsViewModel.refresh()
            model.dictationTabModel.adopt(model.modelsViewModel.rows)
            await library.reload()
        }
        .onChange(of: library.selected?.id) { _, _ in
            actionError = nil
            // A failure belongs to the job it came from; moving to another transcript takes
            // its banner away.
            transcription.clearFailure()
        }
        .onChange(of: transcription.state) { _, state in
            // The list learns about a job's segments from `transcriptsChanged`, but a job's
            // first `.running` may arrive before any segment, and its settle lands after the
            // last append. `listEffect` decides what each state asks of the list.
            switch Self.listEffect(for: state, headers: library.headers) {
            case .none:
                break
            case .reload:
                Task { await library.reload() }
            case .reloadAndSelect(let id):
                Task {
                    await library.reload()
                    await library.select(id)
                }
            }
        }
        .confirmationDialog("Delete this transcript?",
                            isPresented: $isDeleteConfirmationPresented,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let id = library.selected?.id else { return }
                Task { await library.delete(id) }
            }
        } message: {
            Text("This permanently removes the transcript and its segments. "
                + "The source file is not touched.")
        }
    }

    // MARK: - The list

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(library.headers) { header in
                row(header).tag(header.id)
            }
        }
    }

    /// Selecting asks the controller to load the transcript; it publishes `selected` when the
    /// read lands, so the row the user clicked is not shown open before its content is here.
    private var selection: Binding<Int64?> {
        Binding(get: { library.selected?.id },
                set: { id in Task { await library.select(id) } })
    }

    private func row(_ header: TranscriptHeader) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(header.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = header.duration {
                        Text(TranscriptExporter.clock(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let badge = Self.statusBadge(header.status) {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - The detail

    private var detail: some View {
        VStack(spacing: 0) {
            banners
            if let transcript = library.selected {
                transcriptDetail(transcript)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var banners: some View {
        if let error = library.error {
            errorBanner(error)
        }
        if let actionError {
            errorBanner(actionError)
        }
        // `State.failed` already carries `ErrorText.describe(_:)` of the failure. Shown only
        // for the open transcript — or a job with no row yet — so a failure that belongs to
        // another transcript never sits over this one; selecting another transcript clears it.
        if case let .failed(message, transcriptID) = transcription.state,
           transcriptID == nil || transcriptID == library.selected?.id {
            errorBanner(message, chooseSourceFileFor: chooseFileTarget)
        }
    }

    /// The id **Choose File…** would resume: the open transcript's `Resume` failed because its
    /// stored bookmark no longer resolves.
    private var chooseFileTarget: Int64? {
        guard case let .failed(_, transcriptID) = transcription.state,
              let id = transcriptID, id == library.selected?.id,
              transcription.canChooseSourceFile
        else { return nil }
        return id
    }

    private func transcriptDetail(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(transcript)
            Divider()
            if case let .running(id, _, position, duration, _) = transcription.state,
               id == transcript.id {
                progressRow(position: position, duration: duration)
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !transcript.segments.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                                segmentRow(segment)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }

    private func header(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transcript.header.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(Self.caption(date: transcript.header.createdAt,
                              duration: transcript.header.duration,
                              run: transcript.run))
                .font(.caption)
                .foregroundStyle(.secondary)
            if transcript.header.status == .incomplete, let reason = transcript.header.statusReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            actions(transcript)
                .padding(.top, 2)
        }
        .padding(10)
    }

    private func actions(_ transcript: Transcript) -> some View {
        HStack(spacing: 10) {
            Button {
                library.copySelected()
            } label: {
                Label { Text("Copy") } icon: { Icon(.copy, size: 14) }
            }
            .help("Copy the transcript text, without timestamps")

            exportMenu

            Button {
                model.textFeatures?.summarize.start(text: transcript.plainText,
                                                    canReplaceSelection: false)
            } label: {
                Label { Text("Summarize") } icon: { Icon(.summarize, size: 14) }
            }
            .help("Summarize in the Quick Panel with the LLM configured for Summarize")

            if transcript.header.status == .incomplete {
                Button {
                    transcription.resume(transcriptID: transcript.id)
                } label: {
                    Label { Text("Resume") } icon: { Icon(.play, size: 14) }
                }
                .help("Continue transcribing from the last stored segment")
            }

            Spacer()

            Button {
                isDeleteConfirmationPresented = true
            } label: {
                Label { Text("Delete") } icon: { Icon(.delete, size: 14) }
            }
            .help("Delete this transcript")
        }
        .buttonStyle(.borderless)
    }

    /// A pull-down of the three formats: choosing one opens the save panel filtered to that
    /// format's extension and writes the rendered transcript there.
    private var exportMenu: some View {
        Menu {
            ForEach(TranscriptExportFormat.allCases) { format in
                Button(format.displayName) { export(format) }
            }
        } label: {
            Label { Text("Export…") } icon: { Icon(.download, size: 14) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Write the transcript to a file")
    }

    private func progressRow(position: TimeInterval, duration: TimeInterval) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(Self.progressText(position: position, duration: duration))
            Spacer()
            Button("Cancel") { transcription.cancel() }
        }
        .padding(10)
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("[\(TranscriptExporter.clock(segment.start))]")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(TranscriptExporter.speakerPrefix(segment) + segment.text)
                .textSelection(.enabled)
        }
    }

    /// No transcript open: the drop zone, plus the progress of a job whose transcript is not
    /// (yet) in the list — the feedback a drop needs before its first segment lands.
    private var emptyState: some View {
        VStack(spacing: 0) {
            if case let .running(_, title, position, duration, _) = transcription.state {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    progressRow(position: position, duration: duration)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Icon(.waveform, size: 28)
                    .foregroundStyle(.secondary)
                Text("Drop an audio or video file here")
                    .font(.headline)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String, chooseSourceFileFor id: Int64? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warning, size: 14)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            if let id {
                Button("Choose File…") { chooseSourceFile(for: id) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    /// Picks the source file again for a `Resume` whose stored bookmark no longer resolves.
    /// The chosen file continues from the same position and becomes the row's bookmark.
    private func chooseSourceFile(for id: Int64) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcription.resume(transcriptID: id, fileAt: url)
    }

    // MARK: - Export

    private func export(_ format: TranscriptExportFormat) {
        guard let text = library.exportText(format), let transcript = library.selected else {
            return
        }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let base = (transcript.header.title as NSString).deletingPathExtension
        let stem = base.isEmpty ? transcript.header.title : base
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        actionError = nil
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            actionError = ErrorText.describe(
                MacomprendoError.exportFailed(error.localizedDescription))
        }
    }

    // MARK: - Pure labels

    /// What a change of the transcription state asks of the list. A job's row is created
    /// before its first segment, so the first `.running` state of a brand-new job may arrive
    /// before any `transcriptsChanged` reload has run: reload once so the row shows. A job
    /// that settles reloads — its badge and reason land after the last append — and a
    /// finished job is also opened.
    enum ListEffect: Equatable {
        case none
        case reload
        case reloadAndSelect(Int64)
    }

    nonisolated static func listEffect(for state: FileTranscriptionController.State,
                                       headers: [TranscriptHeader]) -> ListEffect {
        switch state {
        case let .running(transcriptID, _, _, _, _):
            return headers.contains { $0.id == transcriptID } ? .none : .reload
        case let .finished(transcriptID):
            return .reloadAndSelect(transcriptID)
        case .idle, .failed:
            return .reload
        }
    }

    /// `Transcribing — 12:40 / 58:03`.
    nonisolated static func progressText(position: TimeInterval, duration: TimeInterval) -> String {
        "Transcribing — \(TranscriptExporter.clock(position)) / \(TranscriptExporter.clock(duration))"
    }

    /// The badge the list shows for a status that is not simply finished; `nil` for `complete`.
    nonisolated static func statusBadge(_ status: TranscriptStatus) -> String? {
        switch status {
        case .inProgress: "In progress"
        case .incomplete: "Incomplete"
        case .complete: nil
        }
    }

    /// `model · engine · language` — the run the header names.
    nonisolated static func runDescription(_ run: TranscriptionRun) -> String {
        [run.modelID, run.engine, run.language ?? "Automatic"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The header's caption: date, duration and the run, in that order.
    nonisolated static func caption(date: Date, duration: TimeInterval?,
                                    run: TranscriptionRun) -> String {
        var parts = [date.formatted(date: .abbreviated, time: .shortened)]
        if let duration {
            parts.append(TranscriptExporter.clock(duration))
        }
        let runText = runDescription(run)
        if !runText.isEmpty {
            parts.append(runText)
        }
        return parts.joined(separator: " · ")
    }
}
