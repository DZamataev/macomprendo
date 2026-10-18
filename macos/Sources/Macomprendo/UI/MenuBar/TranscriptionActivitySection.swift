import AppKit
import SwiftUI

/// The panel's transcription card (spec §4): the one running background job — a file's percent
/// or a call track's speaker and clock, indeterminate where no honest ratio exists — or its
/// failure message. The whole card is a button: it closes the panel, activates the app, selects
/// that job's transcript by id and opens (or raises) the Transcripts window, so a job is
/// reachable while its window is not.
///
/// The controller is observed here rather than by the panel, so a transcription event rebuilds
/// this card and nothing else.
struct TranscriptionActivitySection: View {
    @ObservedObject var transcription: FileTranscriptionController

    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    var body: some View {
        if let activity = MenuPanelPresentation.transcriptionActivity(transcription.state) {
            Button {
                open(activity)
            } label: {
                card(activity)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(accessibilityLabel(activity))
            // Over the card rather than inside it: a button in another button's label does
            // not get its own clicks. The panel stays open, and the job becomes `incomplete`
            // with what it has so far — Resume continues it, Transcribe Again starts over.
            .overlay(alignment: .bottomTrailing) {
                if !activity.isFailure {
                    Button {
                        transcription.cancel()
                    } label: {
                        Label { Text("Stop") } icon: { Icon(.stop, size: 11) }
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.titleAndIcon)
                    .help("Stop transcribing. Resume continues it later, or Transcribe Again starts over with another model.")
                    .padding(8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// The spec's order: close the panel, activate, select by id, then open the window — the
    /// library keeps a selection made before the window exists (`reload` re-reads it rather
    /// than clearing it), so the window lands on the running transcript.
    private func open(_ activity: MenuPanelPresentation.TranscriptionActivity) {
        model.closeMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            if let id = activity.transcriptID {
                await model.transcriptLibrary.select(id)
            }
            openWindow(id: WindowID.transcripts)
        }
    }

    private func card(_ activity: MenuPanelPresentation.TranscriptionActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if activity.isFailure {
                    Icon(.warning, size: 12)
                        .foregroundStyle(.red)
                }
                Text(activity.caption)
                    .font(.caption)
                    .foregroundStyle(activity.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if case .percent(let percent) = activity.progress {
                    Text("\(percent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if !activity.isFailure {
                    // Indeterminate: the pipeline has not supplied a ratio worth claiming.
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let title = activity.title {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .percent(let percent)? = activity.progress {
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
            }
            if let detail = activity.detail {
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private var tileBackground: Color {
        isHovering
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
            : Color(nsColor: .quaternarySystemFill)
    }

    private func accessibilityLabel(_ activity: MenuPanelPresentation.TranscriptionActivity)
        -> String {
        guard !activity.isFailure else {
            return "Transcription failed: \(activity.caption). Open Transcripts"
        }
        var parts = ["Open Transcripts"]
        if let title = activity.title { parts.append(title) }
        parts.append(activity.caption)
        if case .percent(let percent) = activity.progress {
            parts.append("\(percent) percent transcribed")
        }
        if let detail = activity.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}
