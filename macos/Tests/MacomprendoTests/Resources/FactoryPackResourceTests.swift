import Foundation
import Testing
@testable import Macomprendo

/// The factory packs as the app will read them: out of the bundle, by name, parsed by the same
/// parser a user's pack goes through.
///
/// This lives in the tests rather than in `Services` because Task 5's `GlossaryStore` owns the
/// real directory, seeding and `packs.json`. What is needed here — and by the control-dictation
/// regression pin — is only the bundled text.
enum FactoryPackFixture {
    /// The packs that ship in the bundle, in a fixed order so a collision would be deterministic.
    static let names = ["typescript", "react-native", "python", "go", "ruby", "godot"]

    /// The bundled file's text, or `nil` when the resource directory was not shipped — which is
    /// exactly what invariant 17 is about.
    static func text(_ name: String) -> String? {
        guard let url = ResourceBundle.current.url(
            forResource: name, withExtension: "txt", subdirectory: "Vocabulary"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func pack(_ name: String) -> GlossaryPack? {
        text(name).map { GlossaryPack.parse($0, name: name) }
    }

    /// Every factory pack, in `names` order. Fails loudly rather than silently skipping.
    static func all() throws -> [GlossaryPack] {
        try names.map { name in
            try #require(pack(name), "factory pack \(name).txt is missing from the bundle")
        }
    }
}

@Suite("Factory packs ship in the bundle")
struct FactoryPackResourceTests {
    @Test(arguments: FactoryPackFixture.names)
    func everyFactoryPackIsInTheBundle(name: String) throws {
        // `swift test` alone cannot prove invariant 17 — the xcodebuild bundle is checked by
        // hand — but a missing SwiftPM declaration fails right here.
        _ = try #require(FactoryPackFixture.text(name), "\(name).txt is not in the bundle")
    }

    @Test(arguments: FactoryPackFixture.names)
    func everyFactoryPackParsesCleanly(name: String) throws {
        let pack = try #require(FactoryPackFixture.pack(name))
        #expect(pack.skippedLineCount == 0)
        #expect(!pack.terms.isEmpty)
    }

    @Test(arguments: FactoryPackFixture.names)
    func everyFactoryPackIsAUnixTextFileWithAHeader(name: String) throws {
        let text = try #require(FactoryPackFixture.text(name))
        // A CRLF pack would leave a carriage return on the end of every term, because trimming
        // it would break the byte-identical round trip.
        #expect(!text.contains("\r"))
        #expect(text.hasSuffix("\n"))
        // The file is read by humans and by agents, so it says what it is.
        #expect(text.hasPrefix("# pack: \(name)\n"))
    }

    @Test(arguments: FactoryPackFixture.names)
    func everyFactoryPackIsSizedByTheDictationCriterionNotByTheStacksVocabulary(
        name: String
    ) throws {
        // A term earns its place only if the recogniser plausibly breaks it. That filter leaves
        // roughly a quarter of a stack's vocabulary; a pack drifting past 30 terms means the
        // filter was dropped and the next spec's prompt budget pays for it.
        let pack = try #require(FactoryPackFixture.pack(name))
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
        let packs = try FactoryPackFixture.all()
        #expect(Glossary(packs: packs).collisionCount == 0)
    }

    @Test func factoryTermsAreCanonicalSpellingsNotSentences() throws {
        for pack in try FactoryPackFixture.all() {
            for term in pack.terms {
                #expect(!term.canonical.isEmpty)
                // A match window is at most four words, so a longer term can never match.
                #expect(term.canonical.split(separator: " ").count <= 4,
                        "\(pack.name) holds an unmatchable term: \(term.canonical)")
            }
        }
    }
}
