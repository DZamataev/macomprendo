import SwiftUI

/// The Dictation tab's Glossary section: the master switch, the pack list with its two
/// warning counts, the pack editor, the manual list, and Reload / Show in Finder.
///
/// Every decision lives in `GlossarySectionModel`, which is unit-tested; this file only
/// draws it.
struct GlossarySection: View {
    @ObservedObject var model: GlossarySectionModel

    /// The New pack / Duplicate name sheet. Pure view state: nothing is written until the
    /// sheet's Create button runs the model's action.
    @State private var newPackName = ""
    /// Set when the name sheet is duplicating rather than creating.
    @State private var duplicatedPackName: String?
    @State private var isNamingPack = false

    var body: some View {
        Section("Glossary") {
            Toggle("Correct recognised terms", isOn: Binding(
                get: { model.isGlossaryEnabled },
                set: { model.setGlossaryEnabled($0) }))
            Text("Rewrites terms from the packs below to the spelling they are listed in, "
                 + "after transcription. The original text is kept in history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isGlossaryEnabled {
                packList
                manualTermsField
                footer
            }
        }
        .task { await model.refresh() }
        .confirmationDialog("Turn on the recommended packs?",
                            isPresented: Binding(get: { model.isRecommendedOfferPresented },
                                                 set: { if !$0 { model.declineRecommendedPacks() } }),
                            titleVisibility: .visible) {
            Button("Turn them on") { Task { await model.acceptRecommendedPacks() } }
            Button("Not now", role: .cancel) { model.declineRecommendedPacks() }
        } message: {
            Text("\(model.recommendedPackNames.joined(separator: ", ")). "
                 + "Without a pack switched on nothing is corrected. You can change this any "
                 + "time below.")
        }
        .sheet(isPresented: Binding(get: { model.editedPackName != nil },
                                    set: { if !$0 { model.cancelEdits() } })) {
            editor
        }
        .sheet(isPresented: $isNamingPack) { nameSheet }
    }

    // MARK: - The packs

    @ViewBuilder
    private var packList: some View {
        if let message = model.message {
            Label { Text(message) } icon: { Icon(.warning, size: 14) }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let errorMessage = model.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if model.rows.isEmpty {
            Text("No packs in the folder yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // Grows with its contents rather than scrolling. A scroll view nested inside the
            // tab's own scroll view traps the wheel: the pointer over the list scrolls the
            // list, and the page underneath refuses to move. The tab scrolls; this does not.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.rows) { row in
                    packRow(row)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func packRow(_ row: GlossaryPackRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(row.name, isOn: Binding(
                get: { row.isEnabled },
                set: { enabled in
                    Task { await model.setEnabled(enabled, forPackNamed: row.name) }
                }))
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = row.warningText {
                    Label { Text(warning) } icon: { Icon(.warning, size: 11) }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button("Edit") { model.edit(packNamed: row.name) }
            Button("Duplicate") { beginNaming(duplicating: row.name) }
            if row.canReset {
                Button("Reset") { Task { await model.resetPack(named: row.name) } }
            }
            if row.canDelete {
                Button("Delete", role: .destructive) {
                    Task { await model.deletePack(named: row.name) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Button("New pack") { beginNaming(duplicating: nil) }
            Spacer(minLength: 8)
            Button("Reload") { Task { await model.refresh() } }
            Button("Show in Finder") { model.reveal() }
        }
    }

    // MARK: - The manual list

    private var manualTermsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your own terms")
                .font(.callout)
            TextEditor(text: $model.manualTermsText)
                .font(.body.monospaced())
                .frame(minHeight: 60, maxHeight: 90)
            Text("One term per line, in the spelling you want pasted. These outrank every "
                 + "pack.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sheets

    /// The file's own text, so saving writes it back verbatim — comments, blank lines and
    /// order included.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.editedPackName ?? "")
                .font(.headline)
            TextEditor(text: $model.editedText)
                .font(.body.monospaced())
                .frame(minWidth: 460, minHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelEdits() }
                Button("Save") { Task { await model.saveEdits() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private var nameSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(duplicatedPackName.map { "Duplicate “\($0)”" } ?? "New pack")
                .font(.headline)
            TextField("Name", text: $newPackName)
                .frame(minWidth: 260)
            Text("The name becomes the file name. A new pack is off until you switch it on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isNamingPack = false }
                Button("Create") { createNamedPack() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPackName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func beginNaming(duplicating name: String?) {
        duplicatedPackName = name
        newPackName = name.map { "\($0) copy" } ?? ""
        isNamingPack = true
    }

    private func createNamedPack() {
        let name = newPackName
        let source = duplicatedPackName
        isNamingPack = false
        Task {
            if let source {
                await model.duplicatePack(named: source, as: name)
            } else {
                await model.createPack(named: name)
            }
        }
    }
}
