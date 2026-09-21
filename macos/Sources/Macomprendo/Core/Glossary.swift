import Foundation

/// Every term the app is told to recognise as jargon — the enabled packs plus the user's own
/// list — flattened into a set keyed for matching.
///
/// The key is what makes normalisation work: `Xcode build`, `xcodebuild`, `XcodeBuild` and
/// `xcode-build` all key to the same letters, so a window of transcript text can be recognised
/// as a term however the recogniser shaped it. Two terms can therefore share a key
/// (`react-native` and `React Native`); the one from the higher source wins and the loser is
/// counted, because a silent collision is a term the user believes is active and is not.
struct Glossary: Sendable {
    /// One winning term, with the pack it came from so a rewrite can name its source.
    struct Entry: Equatable, Sendable {
        /// The spelling the matched text is rewritten to.
        let canonical: String
        /// The owning pack's name, or `nil` when the term came from the manual list.
        let packName: String?
    }

    private let entriesByKey: [String: Entry]

    /// How many terms each pack lost to a higher source, by pack name. A term counted here is
    /// inert: it is in an enabled pack and still never rewrites anything, which is the failure
    /// this feature is most likely to produce, so the Glossary section names the pack rather
    /// than only the total.
    let inertTermCountsByPack: [String: Int]

    /// How many manual terms lost a collision — only ever to another manual term, the manual
    /// list being the highest source.
    let manualInertTermCount: Int

    /// How many terms lost a key collision. Surfaced in the Glossary section so a pack that is
    /// not doing what the user thinks is visible.
    var collisionCount: Int {
        manualInertTermCount + inertTermCountsByPack.values.reduce(0, +)
    }

    /// How many distinct keys the glossary matches on.
    var termCount: Int { entriesByKey.count }

    /// Builds the keyed set. Source order decides a collision, highest first: the manual list,
    /// then the packs in the order they were given, which is `packs.json` order. There is no
    /// further fallback — a pack absent from `packs.json` is disabled and contributes no terms,
    /// so it cannot take part in a collision at all.
    ///
    /// A term whose key is empty (`---`) can never be matched and is dropped without counting as
    /// a collision: nothing about it is ambiguous.
    init(packs: [GlossaryPack] = [], manualTerms: [String] = []) {
        var entries: [String: Entry] = [:]
        var packLosses: [String: Int] = [:]
        var manualLosses = 0

        func insert(_ canonical: String, packName: String?) {
            let key = Self.key(for: canonical)
            guard !key.isEmpty else { return }
            guard entries[key] == nil else {
                if let packName {
                    packLosses[packName, default: 0] += 1
                } else {
                    manualLosses += 1
                }
                return
            }
            entries[key] = Entry(canonical: canonical, packName: packName)
        }

        for term in manualTerms { insert(term, packName: nil) }
        for pack in packs {
            for term in pack.terms { insert(term.canonical, packName: pack.name) }
        }

        self.entriesByKey = entries
        self.inertTermCountsByPack = packLosses
        self.manualInertTermCount = manualLosses
    }

    /// The term matching `key`, or `nil`.
    func entry(forKey key: String) -> Entry? { entriesByKey[key] }

    /// A string's normalised key: lowercased, with every space, hyphen, underscore, dot and
    /// other non-alphanumeric character removed. So `MainMenu.tscn` and `MainMenu tscn` share a
    /// key, and the canonical spelling restores the dot.
    ///
    /// Unicode-aware but deliberately script-blind: a Cyrillic string keys to Cyrillic
    /// characters and will never match a Latin term. Transliterating inside the key to "help"
    /// would fake a mechanism this spec does not ship.
    static func key(for text: String) -> String {
        var key = ""
        key.reserveCapacity(text.count)
        for character in text.lowercased() where character.isLetter || character.isNumber {
            key.append(character)
        }
        return key
    }
}
