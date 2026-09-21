import Foundation
import Testing
@testable import Macomprendo

@Suite("Factory packs ship in the bundle")
struct FactoryPackResourceTests {
    /// Every factory pack, in `names` order. Fails loudly rather than silently skipping.
    private func factoryPacks() throws -> [GlossaryPack] {
        try FactoryGlossaryPacks.names.map { name in
            try #require(FactoryGlossaryPacks.pack(name),
                         "factory pack \(name).txt is missing from the bundle")
        }
    }

    @Test(arguments: FactoryGlossaryPacks.names)
    func everyFactoryPackIsInTheBundle(name: String) throws {
        // `swift test` alone cannot prove invariant 17 — the xcodebuild bundle is checked by
        // hand — but a missing SwiftPM declaration fails right here.
        _ = try #require(FactoryGlossaryPacks.text(name), "\(name).txt is not in the bundle")
    }

    @Test(arguments: FactoryGlossaryPacks.names)
    func everyFactoryPackParsesCleanly(name: String) throws {
        let pack = try #require(FactoryGlossaryPacks.pack(name))
        #expect(pack.skippedLineCount == 0)
        #expect(!pack.terms.isEmpty)
    }

    @Test(arguments: FactoryGlossaryPacks.names)
    func everyFactoryPackIsAUnixTextFileWithAHeader(name: String) throws {
        let text = try #require(FactoryGlossaryPacks.text(name))
        // A CRLF pack would leave a carriage return on the end of every term, because trimming
        // it would break the byte-identical round trip.
        #expect(!text.contains("\r"))
        #expect(text.hasSuffix("\n"))
        // The file is read by humans and by agents, so it says what it is.
        #expect(text.hasPrefix("# pack: \(name)\n"))
    }

    @Test(arguments: FactoryGlossaryPacks.names)
    func everyFactoryPackIsSizedByTheDictationCriterionNotByTheStacksVocabulary(
        name: String
    ) throws {
        // A term earns its place only if the recogniser plausibly breaks it. That filter leaves
        // roughly a quarter of a stack's vocabulary; a pack drifting past 30 terms means the
        // filter was dropped and the next spec's prompt budget pays for it.
        let pack = try #require(FactoryGlossaryPacks.pack(name))
        #expect((15...30).contains(pack.terms.count))
    }

    @Test func theReadmeShipsBesideThePacks() throws {
        let url = try #require(ResourceBundle.current.url(
            forResource: "README", withExtension: "md", subdirectory: "Vocabulary"
        ))
        let readme = try String(contentsOf: url, encoding: .utf8)
        // It is the only documentation an agent gets, and the surprising part of the design —
        // a pack is off until named in packs.json — must be in it.
        #expect(readme.contains("packs.json"))
        #expect(readme.contains("\"enabled\""))
        #expect(!readme.contains("\r"))
    }

    @Test func noTwoFactoryPacksClaimTheSameTerm() throws {
        // Factory packs are shipped together and are meant to be enabled together, so a term in
        // two of them would be a collision the user gets warned about for no reason.
        let packs = try factoryPacks()
        #expect(Glossary(packs: packs).collisionCount == 0)
    }

    @Test func factoryTermsAreCanonicalSpellingsNotSentences() throws {
        for pack in try factoryPacks() {
            for term in pack.terms {
                #expect(!term.canonical.isEmpty)
                // A match window is at most four words, so a longer term can never match.
                #expect(term.canonical.split(separator: " ").count <= 4,
                        "\(pack.name) holds an unmatchable term: \(term.canonical)")
            }
        }
    }
}
