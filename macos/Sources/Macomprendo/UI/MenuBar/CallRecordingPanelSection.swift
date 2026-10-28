import SwiftUI

/// The panel's call block (spec §3.2): **Record Call** while idle; while a call is being
/// recorded the live state line, the full-width **Stop Recording** button, and then the two
/// capsule level meters — Stop above the meters. Every row has a fixed height: the meters and
/// the clock tick ten times a second, and nothing may move under the pointer (spec §6).
///
/// The controller is observed here and nowhere else in the panel, so a level tick re-renders
/// this subtree only — never the rows around it.
struct CallRecordingPanelSection: View {
    @ObservedObject var controller: CallRecordingController
    /// The call's notes drafts. Not observed here: the editor observes it, so typing never
    /// re-renders the meters' subtree and a meter tick never rebuilds the editor.
    let notes: TranscriptNotesController
    /// Opens the live row's transcript; the panel knows nothing about windows.
    var showLiveTranscript: (Int64) -> Void = { _ in }
    /// Whether the call's notes editor is open. Inline rather than a popover: the panel closes
    /// on any click in another of our windows, which a child popover is (spec §2). Reset with
    /// the rest of the panel's state on every opening.
    @State private var isNotesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isRecording {
                recordingGroup
            } else {
                recordButton
            }
            if case let .failed(message) = controller.state {
                startFailure(message)
            }
        }
    }

    private var recordButton: some View {
        Button {
            controller.toggle()
        } label: {
            HStack(spacing: 7) {
                Icon(.record, size: 14)
                Text("Record Call")
                Spacer(minLength: 6)
                // An unbound shortcut is omitted, never drawn as "not set" (spec §3).
                if let annotation = MenuPanelPresentation.shortcutAnnotation(
                    HotkeyAction.recordCall.currentShortcutText()) {
                    Text(annotation)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    private var recordingGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("Recording call")
                Spacer(minLength: 6)
                Text(TranscriptExporter.clock(controller.elapsed))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording call, \(TranscriptExporter.clock(controller.elapsed))")

            Button {
                controller.toggle()
            } label: {
                HStack(spacing: 6) {
                    Icon(.stop, size: 14)
                    Text("Stop Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            meterRow("Me", level: controller.levels.me)
            meterRow("Others", level: controller.levels.others)

            // Last, so a button that appears never moves a row under the pointer (spec §6).
            if let id = controller.liveTranscriptID {
                Button {
                    showLiveTranscript(id)
                } label: {
                    HStack(spacing: 6) {
                        Icon(.folder, size: 14)
                        Text("Show Live Transcript")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let folder = controller.recordingFolder {
                notesGroup(TranscriptSidecars.notesURL(callFolder: folder))
            }
        }
    }

    /// **Notes** while recording: links from the call's chat go straight into the notes file
    /// in the recording folder. Last in the block, so opening it moves nothing under the
    /// pointer (spec §6).
    private func notesGroup(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isNotesExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Icon(.notes, size: 14)
                    Text(isNotesExpanded ? "Hide Notes" : "Notes")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Notes for this call, kept next to the recording")

            if isNotesExpanded {
                TranscriptNotesEditor(notes: notes, url: url, minHeight: 90)
                    .id(url)
                    .frame(maxHeight: 160)
            }
        }
    }

    private func meterRow(_ label: String, level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            LevelMeter(level: level)
                .accessibilityLabel("\(label) level")
        }
        .frame(height: 24)
    }

    /// A failed start keeps its recovery text until the next attempt replaces it (spec §3.2).
    private func startFailure(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Icon(.warning, size: 12)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.red)
    }
}
