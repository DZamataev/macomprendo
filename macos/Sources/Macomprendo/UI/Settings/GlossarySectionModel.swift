import Foundation
import SwiftUI

/// One pack as the Glossary section draws it. A value type rather than a live reference, so a
/// redraw cannot ask the store anything.
struct GlossaryPackRow: Identifiable, Equatable, Sendable {
    let name: String
    /// How many terms the pack's file holds, before any collision with another source.
    let termCount: Int
    /// Lines the parser could not read. A pack with one bad line still works, so this is the
    /// only way its owner learns the line is being ignored.
    let skippedLineCount: Int
    /// Terms this pack lost to a higher source and that therefore rewrite nothing. Zero while
    /// the pack is off, because a disabled pack contributes no terms and can collide with
    /// nothing.
    let inertTermCount: Int
    let isFactory: Bool
    let isEnabled: Bool

    var id: String { name }

    /// A factory pack's file can be restored from the bundle; a user's cannot.
    var canReset: Bool { isFactory }
    /// Deleting a factory pack's file would only undo itself on the next seed, so a factory
    /// pack is switched off instead.
    var canDelete: Bool { !isFactory }

    /// The plain half of the row's caption.
    var detailText: String {
        termCount == 1 ? "1 term" : "\(termCount) terms"
    }

    /// The reasons this pack is not doing what its owner thinks, or `nil` when there are
    /// none. A skipped line and an inert term are the two ways a pack quietly does less than
    /// its file says, so both are named here rather than left to the file.
    var warningText: String? {
        var parts: [String] = []
        if skippedLineCount > 0 {
            parts.append(skippedLineCount == 1
                ? "1 line could not be read"
                : "\(skippedLineCount) lines could not be read")
        }
        if inertTermCount > 0 {
            parts.append(inertTermCount == 1
                ? "1 term is spelled differently in a pack above it and does nothing"
                : "\(inertTermCount) terms are spelled differently in a pack above them "
                    + "and do nothing")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The testable core of the Dictation tab's Glossary section: the first-run offer, the pack
/// list with its two warning counts, every edit the section can make, and the manual list.
/// Kept out of `DictationTab` so all of it is unit-tested instead of driven through SwiftUI.
@MainActor
final class GlossarySectionModel: ObservableObject {
    /// The packs the first-run offer proposes: the bundled ones, in their fixed order.
    let recommendedPackNames = FactoryGlossaryPacks.names

    @Published private(set) var rows: [GlossaryPackRow] = []
    /// `packs.json` could not be read. A plain message, not a `MacomprendoError`: an
    /// unparsable config must not take dictation down with it (ADR-0012).
    @Published private(set) var message: String?
    /// The last refused or failed edit. Cleared by the next edit that succeeds.
    @Published private(set) var errorMessage: String?
    /// Shown while the recommended-packs offer is on screen.
    @Published private(set) var isRecommendedOfferPresented = false
    /// The pack whose text is open in the editor, or `nil` when none is.
    @Published private(set) var editedPackName: String?
    /// The editor's text. Written back verbatim, which is why it is the file's text rather
    /// than anything rendered from the parsed terms.
    @Published var editedText = ""

    /// The manual list as the user types it. Settings hold the parsed terms; the text on
    /// screen stays exactly as typed, so a blank line half-way through an edit is not deleted
    /// under the cursor.
    @Published var manualTermsText: String {
        didSet {
            let terms = Self.manualTerms(from: manualTermsText)
            guard terms != holder.settings.glossaryManualTerms else { return }
            holder.settings.glossaryManualTerms = terms
        }
    }

    /// The packs from the last read, so opening the editor needs no second directory read.
    private var packsByName: [String: GlossaryPack] = [:]

    private let holder: any SettingsHolding
    private let store: any GlossaryStoring
    private let revealer: any FileRevealing
    /// Told after every change that alters which terms are in force, so the glossary the
    /// dictation controllers read is rebuilt without waiting for a relaunch.
    private let glossaryChanged: @MainActor () async -> Void

    init(holder: any SettingsHolding,
         store: any GlossaryStoring,
         revealer: any FileRevealing,
         glossaryChanged: @escaping @MainActor () async -> Void) {
        self.holder = holder
        self.store = store
        self.revealer = revealer
        self.glossaryChanged = glossaryChanged
        self.manualTermsText = Self.manualTermsText(holder.settings.glossaryManualTerms)
    }

    // MARK: - The master switch and the first-run offer

    var isGlossaryEnabled: Bool { holder.settings.glossaryEnabled }

    /// Turning the switch on for the first time offers the recommended packs, because the
    /// packs seed disabled: without the offer the feature ships inert.
    ///
    /// The value itself lives in `Settings`, which belongs to `AppModel` — a different
    /// `ObservableObject`. The section observes only this model, so the change has to be
    /// published here or the toggle keeps drawing the value it had before the click and looks
    /// stuck; the user's next click then flips the setting straight back.
    func setGlossaryEnabled(_ enabled: Bool) {
        guard enabled != holder.settings.glossaryEnabled else { return }
        objectWillChange.send()
        holder.settings.glossaryEnabled = enabled
        guard enabled, !holder.settings.glossaryRecommendedPacksOffered else { return }
        isRecommendedOfferPresented = true
    }

    /// Enables every recommended pack, in their fixed order — which is also the order a key
    /// collision between two of them resolves by.
    func acceptRecommendedPacks() async {
        closeOffer()
        for name in recommendedPackNames {
            do {
                try await store.setEnabled(true, forPackNamed: name)
            } catch {
                report(error)
                break
            }
        }
        await refresh()
        await glossaryChanged()
    }

    /// Leaves `packs.json` empty. The offer is not made again: a user who said no once is not
    /// asked every time they switch the feature off and on.
    func declineRecommendedPacks() {
        closeOffer()
    }

    private func closeOffer() {
        isRecommendedOfferPresented = false
        holder.settings.glossaryRecommendedPacksOffered = true
    }

    // MARK: - Reading

    /// Re-reads the directory. The Reload button, and whenever the section appears — the spec
    /// deliberately does not watch the folder.
    func refresh() async {
        apply(await store.reload())
    }

    private func apply(_ state: GlossaryState) {
        message = state.message
        packsByName = Dictionary(state.packs.map { ($0.name, $0.pack) },
                                 uniquingKeysWith: { first, _ in first })
        // Built from exactly the packs that are on, in `packs.json` order, so the counts the
        // section shows come from the same rules the normaliser runs under.
        let glossary = Glossary(packs: state.enabledPacks,
                                manualTerms: holder.settings.glossaryManualTerms)
        rows = state.packs.map { pack in
            GlossaryPackRow(name: pack.name,
                            termCount: pack.pack.terms.count,
                            skippedLineCount: pack.pack.skippedLineCount,
                            inertTermCount: glossary.inertTermCountsByPack[pack.name] ?? 0,
                            isFactory: pack.isFactory,
                            isEnabled: pack.isEnabled)
        }
    }

    /// Terms in enabled packs that rewrite nothing because a higher source spells the same key
    /// differently, plus the manual list's own losses.
    var collisionCount: Int {
        rows.reduce(0) { $0 + $1.inertTermCount }
    }

    // MARK: - Editing

    func setEnabled(_ enabled: Bool, forPackNamed name: String) async {
        await mutate { try await self.store.setEnabled(enabled, forPackNamed: name) }
    }

    func createPack(named name: String) async {
        await mutate { try await self.store.createPack(named: name) }
    }

    func duplicatePack(named name: String, as newName: String) async {
        await mutate { try await self.store.duplicatePack(named: name, as: newName) }
    }

    func deletePack(named name: String) async {
        await mutate { try await self.store.deletePack(named: name) }
    }

    func resetPack(named name: String) async {
        await mutate { try await self.store.resetPack(named: name) }
    }

    /// Opens a pack's file text in the editor, from the last read of the directory. The text
    /// is the pack's own, which serialises back byte-for-byte — the editor writes the file's
    /// text, not a rendering of its terms.
    func edit(packNamed name: String) {
        guard let pack = packsByName[name] else {
            errorMessage = ErrorText.describe(
                MacomprendoError.glossary("there is no pack called \"\(name)\" in the folder"))
            return
        }
        editedText = pack.serialise()
        editedPackName = name
    }

    func saveEdits() async {
        guard let name = editedPackName else { return }
        let text = editedText
        await mutate { try await self.store.write(text, toPackNamed: name) }
        guard errorMessage == nil else { return }
        editedPackName = nil
    }

    /// Closes the editor and writes nothing, so an edit can be abandoned.
    func cancelEdits() {
        editedPackName = nil
        editedText = ""
    }

    func reveal() {
        revealer.reveal(store.directoryURL)
    }

    /// Runs one store edit, re-reads the directory afterwards — so a refused edit still leaves
    /// a readable list — and tells the app to rebuild the glossary.
    private func mutate(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            errorMessage = nil
        } catch {
            report(error)
        }
        await refresh()
        await glossaryChanged()
    }

    private func report(_ error: any Error) {
        // The pack's contents never enter a message; only its name, which the user typed.
        errorMessage = ErrorText.describe(error)
    }

    // MARK: - The manual list

    /// One term per line, blank lines dropped and surrounding whitespace trimmed — interior
    /// spaces are significant, exactly as in a pack file.
    nonisolated static func manualTerms(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func manualTermsText(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }
}
