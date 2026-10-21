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
    @ObservedObject var playback: TranscriptPlaybackController

    /// The transcript **Transcribe Again** was asked for, while its confirmation is up.
    @State private var transcribeAgainID: Int64?
    /// A failure from writing an export. Export is the one action whose failure belongs to no
    /// controller, so the window reports it itself.
    @State private var actionError: String?
    /// The list row being renamed from its context menu, and its draft title.
    @State private var renamingID: Int64?
    @State private var renameDraft = ""
    /// The segment whose timestamp is under the pointer, so it can underline like a link.
    @State private var hoveredSegment: Int?
    /// The call transcript being recorded live right now, whose audio cannot play yet.
    @State private var liveTranscriptID: Int64?

    private func isRecordingLive(_ transcript: Transcript?) -> Bool {
        transcript != nil && transcript?.id == liveTranscriptID
    }

    /// The segment list sits at its bottom, so new text should scroll into view.
    @State private var pinnedToBottom = true
    /// Geometry read on every scroll tick: kept out of view state so a tick does not re-render.
    @State private var scrollMetrics = ScrollMetrics()
    private static let scrollSpace = "transcriptSegments"
    private static let bottomID = "transcriptBottom"

    private final class ScrollMetrics {
        var contentFrame: CGRect = .zero
        var viewportHeight: CGFloat = 0
    }

    private func setPinned(_ pinned: Bool) {
        if pinned != pinnedToBottom { pinnedToBottom = pinned }
    }
    @FocusState private var isRenameFieldFocused: Bool

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
            // The window opens on whatever the list already had selected, which no change
            // event fires for.
            await playback.open(library.selected, recording: isRecordingLive(library.selected))
        }
        .onChange(of: library.selected) { _, selected in
            Task { await playback.open(selected, recording: isRecordingLive(selected)) }
        }
        // Read through `onReceive`, not observed: the recorder publishes its meters ten times a
        // second, and the whole window would re-render with them.
        .onReceive(model.callRecording.$liveTranscriptID.removeDuplicates()) { id in
            liveTranscriptID = id
            Task { await playback.open(library.selected, recording: isRecordingLive(library.selected)) }
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
        .confirmationDialog("Transcribe again?",
                            isPresented: Binding(get: { transcribeAgainID != nil },
                                                 set: { if !$0 { transcribeAgainID = nil } }),
                            titleVisibility: .visible) {
            Button("Transcribe Again") {
                guard let id = transcribeAgainID else { return }
                transcription.transcribeAgain(transcriptID: id)
            }
        } message: {
            Text("The current text is replaced by a new transcription of the whole recording, "
                + "with the model selected in Settings. The audio is not touched.")
        }
    }

    /// Not for the transcript a job is writing right now: it is being transcribed already.
    private func canTranscribeAgain(_ header: TranscriptHeader) -> Bool {
        header.status != .inProgress
    }

    // MARK: - The list

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(library.headers) { header in
                row(header)
                    .tag(header.id)
                    .contextMenu {
                        Button("Rename") { beginRename(header) }
                        Button("Transcribe Again…") { transcribeAgainID = header.id }
                            .disabled(!canTranscribeAgain(header))
                        Divider()
                        Button("Delete…", role: .destructive) { confirmDelete(header) }
                            .disabled(!TranscriptLibraryController.canDelete(header))
                    }
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
                if renamingID == header.id {
                    TextField("Title", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .focused($isRenameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { renamingID = nil }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else {
                    Text(header.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

    private func beginRename(_ header: TranscriptHeader) {
        renameDraft = header.title
        renamingID = header.id
        isRenameFieldFocused = true
    }

    /// Enter or leaving the field saves; Esc cleared `renamingID` first, so it saves nothing.
    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        let title = renameDraft
        Task { await library.rename(id, to: title) }
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
            errorBanner(message, resume: resumeChoice)
        }
    }

    /// Which source the banner offers to pick again for a failed `Resume`: the file for a file
    /// transcript, the recording folder for a call one. `nil` when the failure has no picker
    /// to offer here.
    private enum ResumeChoice {
        case sourceFile(Int64)
        case recordingFolder(Int64)
    }

    /// The id a **Choose File…** / **Choose Folder…** would resume: the open transcript's
    /// `Resume` failed because its stored source no longer resolves.
    private var resumeChoice: ResumeChoice? {
        guard case let .failed(_, transcriptID) = transcription.state,
              let id = transcriptID, id == library.selected?.id
        else { return nil }
        if transcription.canChooseSourceFile { return .sourceFile(id) }
        if transcription.canChooseRecordingFolder { return .recordingFolder(id) }
        return nil
    }

    private func transcriptDetail(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(transcript)
            Divider()
            if case let .running(id, _, position, duration, speaker) = transcription.state,
               id == transcript.id {
                progressRow(position: position, duration: duration, speaker: speaker)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !transcript.segments.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                                    segmentRow(segment, index: index,
                                               isActive: index == playback.activeSegmentIndex)
                                        .id(index)
                                }
                            }
                        }
                        Color.clear.frame(height: 0).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.frame(in: .named(Self.scrollSpace)),
                                             initial: true) { old, new in
                            scrollMetrics.contentFrame = new
                            setPinned(Self.pinnedToBottom(
                                wasPinned: pinnedToBottom, old: old, new: new,
                                viewportHeight: scrollMetrics.viewportHeight))
                        }
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                        scrollMetrics.viewportHeight = height
                        let frame = scrollMetrics.contentFrame
                        setPinned(Self.pinnedToBottom(wasPinned: pinnedToBottom, old: frame,
                                                      new: frame, viewportHeight: height))
                    }
                })
                .background(ScrollWheelObserver { if playback.isFollowing { playback.isFollowing = false } })
                .overlay(alignment: .bottomTrailing) { backToCurrent(proxy: proxy) }
                .onChange(of: playback.activeSegmentIndex) { _, index in
                    guard playback.isFollowing, isPlaying, let index else { return }
                    follow(index, proxy: proxy)
                }
                .onChange(of: SegmentTail(transcriptID: transcript.id,
                                          count: transcript.segments.count)) { old, new in
                    // Playback following its marker owns the scroll position.
                    guard Self.followsNewSegments(from: old, to: new, pinned: pinnedToBottom),
                          !(isPlaying && playback.isFollowing) else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            playbackFooter(transcript)
        }
    }

    private func header(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TranscriptTitleField(title: transcript.header.title) { title in
                Task { await library.rename(transcript.id, to: title) }
            }
            .id(transcript.id)
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
            .fixedSize()

            exportMenu

            Button {
                model.textFeatures?.summarize.start(text: transcript.plainText,
                                                    canReplaceSelection: false)
            } label: {
                Label { Text("Summarize") } icon: { Icon(.summarize, size: 14) }
            }
            .help("Summarize in the Quick Panel with the LLM configured for Summarize")
            .fixedSize()

            if transcript.header.status == .incomplete {
                Button {
                    transcription.resume(transcriptID: transcript.id)
                } label: {
                    Label { Text("Resume") } icon: { Icon(.play, size: 14) }
                }
                .help("Continue transcribing from the last stored segment")
                .fixedSize()
            }

            if canTranscribeAgain(transcript.header) {
                Button {
                    transcribeAgainID = transcript.id
                } label: {
                    Label { Text("Transcribe Again") } icon: { Icon(.refresh, size: 14) }
                }
                .help("Replace the text with a new transcription of the whole recording")
                .fixedSize()
            }

            if transcript.header.sourceKind == .call {
                // The folder's bookmark is resolved by the library, not here.
                Button {
                    library.revealSelectedRecording()
                } label: {
                    Label { Text("Show in Finder") } icon: { Icon(.folder, size: 14) }
                }
                .help("Show this call's recording folder in Finder")
                .fixedSize()
            }

            Spacer()

            Button {
                confirmDelete(transcript.header)
            } label: {
                Label { Text("Delete") } icon: { Icon(.delete, size: 14) }
            }
            .help(TranscriptLibraryController.canDelete(transcript.header)
                  ? "Delete this transcript"
                  : "Cancel the transcription before deleting it")
            .disabled(!TranscriptLibraryController.canDelete(transcript.header))
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        // A narrow window takes the room from the gap before Delete, never from a label.
        .lineLimit(1)
    }

    /// A pull-down of the three formats: choosing one opens the save panel filtered to that
    /// format's extension and writes the rendered transcript there.
    private var exportMenu: some View {
        Menu {
            ForEach(TranscriptExportFormat.allCases) { format in
                Button(format.displayName) { export(format) }
            }
        } label: {
            Label { Text("Export") } icon: { Icon(.download, size: 14) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Write the transcript to a file")
    }

    private func progressRow(position: TimeInterval, duration: TimeInterval,
                             speaker: TranscriptSpeaker? = nil) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(Self.progressText(position: position, duration: duration, speaker: speaker))
            Spacer()
            Button("Cancel") { transcription.cancel() }
        }
        .padding(10)
    }

    /// A segment row. The row itself takes only `isActive` — a marker move re-renders two rows,
    /// not the list. Every row carries the same padding so the active row's tint does not move
    /// the text.
    private func segmentRow(_ segment: TranscriptSegment, index: Int, isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                Task { await playback.playSegment(at: index) }
            } label: {
                Text("[\(TranscriptExporter.clock(segment.start))]")
                    .font(.caption.monospacedDigit())
                    .underline(hoveredSegment == index)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Play from here")
            .onHover { hovered in hoveredSegment = hovered ? index : nil }
            .fixedSize()
            Text(TranscriptExporter.speakerPrefix(segment) + segment.text)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        // The tint is a row marker, not a text bubble: a short segment's row is as wide as a
        // long one's.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Keeps the active segment in view with a little context above it.
    private func follow(_ index: Int, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.25))
        }
    }

    /// Shown while playing and the user has scrolled away from the marker: brings the list back
    /// to it and turns follow on again.
    @ViewBuilder private func backToCurrent(proxy: ScrollViewProxy) -> some View {
        if isPlaying, !playback.isFollowing, let index = playback.activeSegmentIndex {
            Button("Back to current") {
                playback.isFollowing = true
                follow(index, proxy: proxy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(10)
        }
    }

    /// The bar under the list — or, when the audio cannot be played, the strip in its place. A
    /// mid-playback failure shows its strip under the bar until the next **Play**.
    @ViewBuilder private func playbackFooter(_ transcript: Transcript) -> some View {
        switch playback.state {
        case .loading, .ready, .recording:
            Divider()
            TranscriptPlayerBar(playback: playback, transcript: transcript)
            if let failure = playback.failure {
                unavailableStrip(reason: failure, recovery: nil)
            }
        case let .unavailable(reason, recovery):
            Divider()
            unavailableStrip(reason: reason, recovery: recovery)
        case .idle:
            EmptyView()
        }
    }

    private func unavailableStrip(reason: String,
                                  recovery: TranscriptPlaybackController.Recovery?) -> some View {
        HStack(spacing: 6) {
            Icon(.warning, size: 14)
            Text("Audio unavailable — \(reason)")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch recovery {
            case .chooseFile:
                bannerButton("Choose File…") { choosePlaybackSourceFile() }
            case .chooseFolder:
                bannerButton("Choose Folder…") { choosePlaybackRecordingFolder() }
            case nil:
                EmptyView()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var isPlaying: Bool {
        if case .ready(_, _, true) = playback.state { return true }
        return false
    }

    /// No transcript open: the drop zone, plus the progress of a job whose transcript is not
    /// (yet) in the list — the feedback a drop needs before its first segment lands.
    private var emptyState: some View {
        VStack(spacing: 0) {
            if case let .running(_, title, position, duration, speaker) = transcription.state {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    progressRow(position: position, duration: duration, speaker: speaker)
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

    private func errorBanner(_ message: String, resume: ResumeChoice? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Icon(.warning, size: 14)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            switch resume {
            case .sourceFile(let id):
                bannerButton("Choose File…") { chooseSourceFile(for: id) }
            case .recordingFolder(let id):
                bannerButton("Choose Folder…") { chooseRecordingFolder(for: id) }
            case nil:
                EmptyView()
            }
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func bannerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .fixedSize()
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

    /// Picks the recording folder again for a call `Resume` whose stored bookmark or a track
    /// file no longer resolves. The chosen folder continues the job and becomes the row's
    /// bookmark.
    private func chooseRecordingFolder(for id: Int64) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcription.resume(transcriptID: id, fileAt: url)
    }

    /// Picks the audio file again for an unavailable file transcript. Playback relinks to it and
    /// the library re-reads the row, so the new bookmark also serves **Show in Finder**. This is
    /// playback only — it does not start or resume transcription.
    private func choosePlaybackSourceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinkPlayback(to: url)
    }

    /// Picks the recording folder again for an unavailable call transcript, with the same panel
    /// configuration as `Resume`'s.
    private func choosePlaybackRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relinkPlayback(to: url)
    }

    private func relinkPlayback(to url: URL) {
        Task {
            await playback.relink(to: url)
            guard let id = playback.transcriptID else { return }
            await library.select(id)
        }
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

    // MARK: - Deleting

    /// Asks before deleting — from the action bar or a row's context menu, which need not be
    /// the open transcript. A SwiftUI confirmation cannot carry a checkbox, so this is an
    /// `NSAlert` sheet whose suppression button is the "also move the source" box, checked by
    /// default. The source goes to the Trash, never straight away, so it can be put back.
    private func confirmDelete(_ header: TranscriptHeader) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(header.title)”?"
        alert.informativeText = "The transcript and its text are removed permanently. "
            + "A source moved to the Trash can be put back from there."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = Self.deleteSourceTitle(for: header.sourceKind)
        alert.suppressionButton?.state = .on
        let id = header.id
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let movingSource = alert.suppressionButton?.state == .on
            Task { await library.delete(id, movingSourceToTrash: movingSource) }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    nonisolated static func deleteSourceTitle(for kind: TranscriptSourceKind) -> String {
        switch kind {
        case .file: "Also move the source file to the Trash"
        case .call: "Also move the call recording to the Trash"
        }
    }

    // MARK: - Pure labels

    /// Which transcript is open and how many segments it shows, so a growing transcript can be
    /// told apart from opening another one.
    struct SegmentTail: Equatable {
        let transcriptID: Int64
        let count: Int
    }

    /// A segment that lands in the open transcript scrolls it down only while the user sits at
    /// the bottom; scrolled up, they are reading earlier text and the view stays put.
    nonisolated static func followsNewSegments(from old: SegmentTail, to new: SegmentTail,
                                               pinned: Bool) -> Bool {
        pinned && old.transcriptID == new.transcriptID && new.count > old.count
    }

    /// Whether the view is stuck to the bottom after the content's frame (in the scroll view's
    /// own space) moved from `old` to `new`. Only a scroll moves the content's top; a frame that
    /// only grew is new text pushing the bottom out of view, and keeps the pin as it was.
    nonisolated static func pinnedToBottom(wasPinned: Bool, old: CGRect, new: CGRect,
                                           viewportHeight: CGFloat) -> Bool {
        let bottomInView = new.maxY <= viewportHeight + 24
        if abs(new.minY - old.minY) < 0.5, abs(new.height - old.height) >= 0.5 {
            return wasPinned || bottomInView
        }
        return bottomInView
    }
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

    /// `Transcribing — 12:40 / 58:03`; a call job's two tracks name their speaker:
    /// `Transcribing Me — 12:40 / 58:03`. The wording itself lives in
    /// `TranscriptProgressText`, shared with the menubar panel so the two cannot drift.
    nonisolated static func progressText(position: TimeInterval, duration: TimeInterval,
                                         speaker: TranscriptSpeaker? = nil) -> String {
        TranscriptProgressText.progressText(position: position, duration: duration,
                                            speaker: speaker)
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

/// The open transcript's title, editable in place: a click puts the caret in it, and every
/// change is saved as it is typed. Clearing it and leaving the field brings the stored title
/// back, since a blank title is never stored.
private struct TranscriptTitleField: View {
    let title: String
    let save: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(title: String, save: @escaping (String) -> Void) {
        self.title = title
        self.save = save
        _draft = State(initialValue: title)
    }

    var body: some View {
        TextField("Title", text: $draft)
            .textFieldStyle(.plain)
            .font(.headline)
            .lineLimit(1)
            .focused($isFocused)
            .help("Click to rename")
            .onChange(of: draft) { _, value in save(value) }
            .onChange(of: title) { _, stored in
                // A rename from the list while this field is idle.
                if !isFocused { draft = stored }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = title
                }
            }
            .onSubmit { isFocused = false }
    }
}
