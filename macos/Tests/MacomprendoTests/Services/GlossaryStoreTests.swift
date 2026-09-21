import Foundation
import Testing
@testable import Macomprendo

@Suite("Glossary store — the Vocabulary directory")
struct GlossaryStoreTests {
    private func makeStore() -> (DirectoryGlossaryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Vocabulary", isDirectory: true)
        return (DirectoryGlossaryStore(directoryURL: directory), directory)
    }

    private func fileBytes(in directory: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        var bytes: [String: Data] = [:]
        for url in urls { bytes[url.lastPathComponent] = try Data(contentsOf: url) }
        return bytes
    }

    // MARK: - Seeding

    @Test func seedingCopiesPacksAndReadmeOnceAndNeverOverwrites() async throws {
        let (store, directory) = makeStore()
        try await store.seed()

        let bundled = FactoryGlossaryPacks.names
        #expect(!bundled.isEmpty)
        for name in bundled {
            let text = try String(contentsOf: directory.appendingPathComponent("\(name).txt"),
                                  encoding: .utf8)
            #expect(text == FactoryGlossaryPacks.text(name))
        }
        let readme = try String(contentsOf: directory.appendingPathComponent("README.md"),
                                encoding: .utf8)
        #expect(readme == FactoryGlossaryPacks.readmeText)

        // A user's edit must survive an app update: new factory terms arrive only via Reset.
        let edited = bundled[0]
        let editedURL = directory.appendingPathComponent("\(edited).txt")
        try "# mine\nmyterm\n".write(to: editedURL, atomically: true, encoding: .utf8)
        try await store.seed()
        #expect(try String(contentsOf: editedURL, encoding: .utf8) == "# mine\nmyterm\n")
    }

    @Test func seedingCreatesTheDirectoryOwnerOnly() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
    }

    @Test func seedingLeavesTheConfigEmpty() async throws {
        let (store, directory) = makeStore()
        try await store.seed()

        // `packs.json` is not even written: a missing file is the seeded state, and
        // `GlossaryPackConfig` reports no message for it.
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("packs.json").path))

        let state = await store.reload()
        #expect(state.enabled.isEmpty)
        #expect(state.message == nil)
        #expect(!state.packs.isEmpty)
        #expect(state.packs.allSatisfy { !$0.isEnabled })
        #expect(state.enabledPacks.isEmpty)
    }

    @Test func loadSeedsAndReloadDoesNot() async throws {
        let (store, directory) = makeStore()
        let reloaded = await store.reload()
        #expect(reloaded.packs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let loaded = try await store.load()
        #expect(loaded.packs.count == FactoryGlossaryPacks.names.count)
    }

    // MARK: - Factory is derived

    @Test func factoryIsDerivedFromTheBundleNotStored() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")

        let state = await store.reload()
        let factory = state.packs.filter(\.isFactory).map(\.name)
        #expect(factory == FactoryGlossaryPacks.names)
        #expect(state.packs.first { $0.name == "mine" }?.isFactory == false)

        // Nothing on disk records the flag, so it cannot drift: the only inputs are the file
        // names and the bundle.
        let written = try fileBytes(in: directory)
        for (_, data) in written {
            #expect(!(String(data: data, encoding: .utf8) ?? "").contains("isFactory"))
        }
    }

    @Test func aFactoryPackFileDeletedFromDiskIsRestoredBySeeding() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let name = FactoryGlossaryPacks.names[0]
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).txt"))

        let state = try await store.load()
        #expect(state.packs.contains { $0.name == name })
    }

    // MARK: - New pack

    @Test func newPackWritesTheDocumentingHeaderAndNothingElse() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")

        let text = try String(contentsOf: directory.appendingPathComponent("mine.txt"),
                              encoding: .utf8)
        #expect(text == """
        # pack: mine
        # One term per line, in the spelling you want pasted.
        # `term = форма, форма` also rewrites those Cyrillic forms to the term.

        """)
        let pack = try #require(await store.reload().packs.first { $0.name == "mine" })
        #expect(pack.pack.terms.isEmpty)
        #expect(pack.pack.skippedLineCount == 0)
        #expect(!pack.isEnabled)
    }

    @Test func newPackRejectsInvalidAndCollidingNames() async throws {
        let (store, _) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")

        for bad in ["", "   ", "a/b", "a:b", ".", "..", "mine",
                    FactoryGlossaryPacks.names[0]] {
            await #expect(throws: MacomprendoError.self) {
                try await store.createPack(named: bad)
            }
        }

        // A bundled name must be refused even when no file carries it yet, because a user pack
        // shadowing a bundled name would be treated as factory.
        let (fresh, _) = makeStore()
        await #expect(throws: MacomprendoError.self) {
            try await fresh.createPack(named: FactoryGlossaryPacks.names[0])
        }
    }

    @Test func duplicateCopiesAPacksTextUnderANewName() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let source = FactoryGlossaryPacks.names[0]
        try await store.duplicatePack(named: source, as: "copy")

        let original = try Data(contentsOf: directory.appendingPathComponent("\(source).txt"))
        let copy = try Data(contentsOf: directory.appendingPathComponent("copy.txt"))
        #expect(original == copy)

        let state = await store.reload()
        #expect(state.packs.first { $0.name == "copy" }?.isFactory == false)
        #expect(state.enabled.isEmpty)

        await #expect(throws: MacomprendoError.self) {
            try await store.duplicatePack(named: source, as: "copy")
        }
        await #expect(throws: MacomprendoError.self) {
            try await store.duplicatePack(named: "absent", as: "other")
        }
    }

    // MARK: - Enabling

    @Test func togglingRewritesOnlyTheConfig() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let before = try fileBytes(in: directory)

        let first = FactoryGlossaryPacks.names[0]
        let second = FactoryGlossaryPacks.names[1]
        try await store.setEnabled(true, forPackNamed: second)
        try await store.setEnabled(true, forPackNamed: first)

        var state = await store.reload()
        // Order is meaningful — it decides a key collision — so enabling appends.
        #expect(state.enabled == [second, first])
        #expect(state.enabledPacks.map(\.name) == [second, first])

        try await store.setEnabled(false, forPackNamed: second)
        state = await store.reload()
        #expect(state.enabled == [first])

        // Enabling twice must not duplicate the name.
        try await store.setEnabled(true, forPackNamed: first)
        state = await store.reload()
        #expect(state.enabled == [first])

        var after = try fileBytes(in: directory)
        #expect(after.removeValue(forKey: "packs.json") != nil)
        #expect(after == before)
    }

    @Test func aNameInTheConfigWithNoFileIsSkippedWithoutError() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try GlossaryPackConfig(enabled: ["absent", FactoryGlossaryPacks.names[0]])
            .encoded()
            .write(to: directory.appendingPathComponent("packs.json"))

        let state = await store.reload()
        #expect(state.message == nil)
        #expect(state.enabled == ["absent", FactoryGlossaryPacks.names[0]])
        #expect(state.enabledPacks.map(\.name) == [FactoryGlossaryPacks.names[0]])
    }

    @Test func anUnreadableConfigIsAMessageNotAThrow() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("packs.json"))

        let state = await store.reload()
        #expect(state.enabled.isEmpty)
        #expect(state.message?.isEmpty == false)
        // Pack names are user content: the decoder's error must never be quoted (invariant 6).
        #expect(state.message?.contains("not json") == false)
    }

    // MARK: - Delete, reset, write

    @Test func deletedPackFileDisappearsWithoutError() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")
        try await store.setEnabled(true, forPackNamed: "mine")

        // Deleted behind the app's back, not through it: the name stays in packs.json.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("mine.txt"))

        let state = await store.reload()
        #expect(!state.packs.contains { $0.name == "mine" })
        #expect(state.enabled == ["mine"])
        #expect(state.message == nil)
        #expect(state.enabledPacks.isEmpty)
    }

    @Test func deleteRemovesAUserPackAndItsEnabledEntry() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")
        try await store.setEnabled(true, forPackNamed: "mine")
        try await store.setEnabled(true, forPackNamed: FactoryGlossaryPacks.names[0])

        try await store.deletePack(named: "mine")

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mine.txt").path))
        let state = await store.reload()
        #expect(state.enabled == [FactoryGlossaryPacks.names[0]])
    }

    @Test func aFactoryPackCannotBeDeletedOnlyDisabled() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let name = FactoryGlossaryPacks.names[0]

        await #expect(throws: MacomprendoError.self) {
            try await store.deletePack(named: name)
        }
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(name).txt").path))

        await #expect(throws: MacomprendoError.self) {
            try await store.deletePack(named: "absent")
        }
    }

    @Test func resetRestoresOnePackFromTheBundle() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        let name = FactoryGlossaryPacks.names[0]
        let url = directory.appendingPathComponent("\(name).txt")
        let untouched = FactoryGlossaryPacks.names[1]
        try "# gutted\n".write(to: url, atomically: true, encoding: .utf8)
        try await store.createPack(named: "mine")

        try await store.resetPack(named: name)

        #expect(try String(contentsOf: url, encoding: .utf8) == FactoryGlossaryPacks.text(name))
        // Reset touches one pack.
        #expect(try String(contentsOf: directory.appendingPathComponent("\(untouched).txt"),
                           encoding: .utf8) == FactoryGlossaryPacks.text(untouched))

        // A user pack has no bundled text to restore.
        await #expect(throws: MacomprendoError.self) {
            try await store.resetPack(named: "mine")
        }
    }

    @Test func writeStoresTheEditorsTextVerbatim() async throws {
        let (store, directory) = makeStore()
        try await store.seed()
        try await store.createPack(named: "mine")

        let text = "# pack: mine\n\n  jq  \nTextEditor = текст-эдитор\n"
        try await store.write(text, toPackNamed: "mine")

        #expect(try String(contentsOf: directory.appendingPathComponent("mine.txt"),
                           encoding: .utf8) == text)
        let pack = try #require(await store.reload().packs.first { $0.name == "mine" })
        #expect(pack.pack.terms.map(\.canonical) == ["jq", "TextEditor"])
        // Byte-identical round trip: the pack the store hands back re-serialises to the file.
        #expect(pack.pack.serialise() == text)

        await #expect(throws: MacomprendoError.self) {
            try await store.write("x", toPackNamed: "absent")
        }
    }
}
