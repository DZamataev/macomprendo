import SwiftUI

/// A transcript's notes: a multiline editor bound to the shared `TranscriptNotesController`
/// draft for `url`. Opening re-reads the file (unless a draft is unsaved); closing saves at
/// once. Used in the Transcripts window's Notes popover and inline in the menubar panel while a
/// call is recorded. Its own view, so a parent that re-renders often (the panel's level meters)
/// does not rebuild the editor's state.
struct TranscriptNotesEditor: View {
    @ObservedObject var notes: TranscriptNotesController
    let url: URL
    var minHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { notes.text(for: url) },
                                         set: { notes.edit($0, for: url) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .disabled(!notes.isEditable(url))
                    .accessibilityLabel("Notes")
                if notes.text(for: url).isEmpty, notes.isEditable(url) {
                    Text("Links from the chat, agenda, anything about this call…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: minHeight)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            if let error = notes.error(for: url) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Icon(.warning, size: 12)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
        }
        .onAppear { notes.load(url) }
        .onDisappear { notes.flush(url) }
    }
}
