import Foundation

/// One glossary entry: the spelling the term must be pasted in, plus the optional Cyrillic
/// forms a later spec will rewrite. Parsed and stored here; nothing reads the forms yet.
struct GlossaryTerm: Equatable, Sendable {
    /// How the term must appear in pasted text — `auto-till-dry`, not `Auto-Till-Dry`.
    let canonical: String
    /// The forms listed after `=`, in file order. Empty for a bare term line.
    let cyrillicForms: [String]

    init(canonical: String, cyrillicForms: [String] = []) {
        self.canonical = canonical
        self.cyrillicForms = cyrillicForms
    }
}

/// A named, switchable file of terms (ADR-0012). The file format is a published contract, so
/// parsing tolerates anything: a malformed line is skipped and counted, never thrown.
///
/// Whether a pack is *enabled* is not stored here — it lives in `packs.json` beside the packs.
struct GlossaryPack: Sendable {
    /// The pack name, which is the file name without its extension.
    let name: String

    /// The parsed terms, in file order. Assigning a different list means the pack no longer
    /// round-trips to its original text, so serialisation falls back to rendering the terms.
    var terms: [GlossaryTerm] {
        didSet { if terms != oldValue { sourceText = nil } }
    }

    /// How many lines were skipped as malformed. Surfaced in the UI so a pack that is not
    /// doing what the user thinks is visible.
    private(set) var skippedLineCount: Int

    /// The text this pack was parsed from, kept so writing it back is byte-identical.
    private var sourceText: String?

    init(name: String, terms: [GlossaryTerm] = [], skippedLineCount: Int = 0) {
        self.name = name
        self.terms = terms
        self.skippedLineCount = skippedLineCount
        self.sourceText = nil
    }

    /// Parses a pack file's text. Comments (`#`) and blank lines are ignored, a term line is its
    /// canonical spelling trimmed of surrounding whitespace — interior spaces are significant, so
    /// `git rebase` is one term — and `term = form, form` carries Cyrillic forms. A duplicate term
    /// keeps its first occurrence. A line is malformed when its `=` has an empty side.
    static func parse(_ text: String, name: String) -> GlossaryPack {
        var terms: [GlossaryTerm] = []
        var seen: Set<String> = []
        var skipped = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let canonical: String
            let forms: [String]
            if let equals = line.firstIndex(of: "=") {
                let left = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
                let right = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else {
                    skipped += 1
                    continue
                }
                canonical = left
                forms = right.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                canonical = line
                forms = []
            }

            guard seen.insert(canonical).inserted else { continue }
            terms.append(GlossaryTerm(canonical: canonical, cyrillicForms: forms))
        }

        var pack = GlossaryPack(name: name, terms: terms, skippedLineCount: skipped)
        pack.sourceText = text
        return pack
    }

    /// The text to write back to the pack file. Returns the parsed text verbatim — comments,
    /// blank lines, order and odd spacing included — unless a term actually changed, because the
    /// in-app editor writes the file's text directly.
    func serialise() -> String {
        if let sourceText { return sourceText }
        return terms.map { term in
            term.cyrillicForms.isEmpty
                ? term.canonical
                : "\(term.canonical) = \(term.cyrillicForms.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}
