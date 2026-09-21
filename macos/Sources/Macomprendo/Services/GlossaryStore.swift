import Foundation

/// The packs that ship inside the app bundle, and the text they seed a fresh install with.
///
/// Listing the names here rather than enumerating the bundle keeps their order fixed, which
/// matters twice: it is the order the Glossary section shows them in, and — once they are
/// enabled — the order a key collision is resolved by.
enum FactoryGlossaryPacks {
    /// The six bundled packs, in the order they are presented.
    static let names = ["typescript", "react-native", "python", "go", "ruby", "godot"]

    /// The bundled pack's text, or `nil` when the resource directory was not shipped — which is
    /// exactly what invariant 17 is about.
    static func text(_ name: String) -> String? {
        contents(ofResource: name, withExtension: "txt")
    }

    /// The bundled pack, parsed by the same parser a user's pack goes through.
    static func pack(_ name: String) -> GlossaryPack? {
        text(name).map { GlossaryPack.parse($0, name: name) }
    }

    /// The directory's own documentation, seeded beside the packs so the format explains itself
    /// without the app's source.
    static var readmeText: String? {
        contents(ofResource: "README", withExtension: "md")
    }

    private static func contents(ofResource name: String, withExtension ext: String) -> String? {
        guard let url = ResourceBundle.current.url(
            forResource: name, withExtension: ext, subdirectory: "Vocabulary"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// One pack as the Glossary section sees it: its parsed contents, whether it is enabled, and
/// whether the bundle carries a pack of the same name.
struct GlossaryPackState: Sendable {
    let pack: GlossaryPack
    /// Derived from the bundle at load time and never stored, so it cannot drift from reality.
    /// A factory pack offers Reset and refuses Delete; a user pack is the other way round.
    let isFactory: Bool
    /// Whether `packs.json` names this pack. A pack on disk is off until it does.
    let isEnabled: Bool

    var name: String { pack.name }
}

/// Everything one read of the Vocabulary directory produces.
struct GlossaryState: Sendable {
    /// Every pack file on disk: the bundled ones first in their fixed order, then the user's own
    /// by name.
    var packs: [GlossaryPackState] = []
    /// `packs.json`'s contents, verbatim — including names with no file, which are kept so that
    /// deleting a pack never requires editing the config.
    var enabled: [String] = []
    /// Set when `packs.json` existed but could not be read. A missing file is not a failure: it
    /// is the state a fresh install seeds.
    var message: String?

    /// The enabled packs, in `packs.json` order, skipping names with no file on disk and
    /// applying a name repeated in the config only once — a pack applied twice would collide
    /// every one of its own terms with itself and report them as inert. This is the list
    /// `Glossary` is built from, so its order decides a key collision.
    var enabledPacks: [GlossaryPack] {
        let byName = Dictionary(packs.map { ($0.name, $0.pack) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return enabled.compactMap { name in
            guard seen.insert(name).inserted else { return nil }
            return byName[name]
        }
    }
}

/// Owns `~/Library/Application Support/Macomprendo/Vocabulary/`: seeding it from the bundle,
/// reading the packs and `packs.json` back, and every edit the Glossary section can make.
///
/// Reading never throws — an unreadable config must not take dictation down with it — while a
/// write the user asked for reports a `MacomprendoError` when it cannot be done.
protocol GlossaryStoring: Sendable {
    /// The directory the packs live in, for Show in Finder.
    var directoryURL: URL { get }

    /// Seeds if the directory has never been seeded, then reads it.
    func load() async throws -> GlossaryState

    /// Reads the directory without seeding it. Used by the Reload button and by Settings.
    func reload() async -> GlossaryState

    /// Copies every bundled pack and `README.md` that is not already on disk. A pack is never
    /// overwritten, so a user's edit survives an app update; new factory terms arrive only
    /// through `resetPack(named:)`. Enables nothing.
    func seed() async throws

    /// Writes a new pack holding only the documenting header.
    func createPack(named name: String) async throws

    /// Copies an existing pack's text under a new name. The copy is a user pack, and off.
    func duplicatePack(named name: String, as newName: String) async throws

    /// Removes a user pack's file and its `enabled` entry. A factory pack is refused: seeding
    /// would restore the file, so disabling is the only way to switch one off.
    func deletePack(named name: String) async throws

    /// Restores one factory pack's bundled text, discarding the user's edits to it.
    func resetPack(named name: String) async throws

    /// Writes the editor's text back to a pack file verbatim.
    func write(_ text: String, toPackNamed name: String) async throws

    /// Adds or removes a name in `packs.json`, and rewrites nothing else.
    func setEnabled(_ enabled: Bool, forPackNamed name: String) async throws
}

actor DirectoryGlossaryStore: GlossaryStoring {
    /// The text a new pack starts as, so the first file a user creates already documents the
    /// format for whoever opens it next — including an agent.
    static let newPackHeader = """
    # pack: %@
    # One term per line, in the spelling you want pasted.
    # `term = форма, форма` also rewrites those Cyrillic forms to the term.

    """

    nonisolated let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    // MARK: - Reading

    func load() async throws -> GlossaryState {
        try seed()
        return read()
    }

    func reload() async -> GlossaryState {
        read()
    }

    private func read() -> GlossaryState {
        let bytes = configBytes()
        let outcome = GlossaryPackConfig.decode(from: bytes.data)
        var state = GlossaryState(enabled: outcome.config.enabled)
        let enabledNames = Set(outcome.config.enabled)
        var messages = [outcome.message].compactMap { $0 }
        if bytes.unreadable {
            messages.append("packs.json is there but could not be read, so no glossary packs "
                + "are enabled. Check the file, then use Reload.")
        }

        let listing = packNamesOnDisk()
        if listing.failed {
            messages.append("The \(directoryURL.lastPathComponent) folder could not be read, so "
                + "no packs are listed. Check the folder, then use Reload.")
        }

        var unreadable: [String] = []
        for name in listing.names {
            guard let text = try? String(contentsOf: packURL(name), encoding: .utf8) else {
                // The file exists but its bytes are not text. Skipping it silently would show a
                // glossary that is quietly smaller than the folder says it is.
                unreadable.append(name)
                continue
            }
            state.packs.append(GlossaryPackState(
                pack: GlossaryPack.parse(text, name: name),
                isFactory: FactoryGlossaryPacks.text(name) != nil,
                isEnabled: enabledNames.contains(name)
            ))
        }
        if !unreadable.isEmpty {
            // Only the file names, which the user chose; a pack's contents never enter a message.
            messages.append(
                (unreadable.count == 1
                    ? "\(unreadable[0]).txt could not be read, so that pack is not listed."
                    : "These packs could not be read and are not listed: "
                        + unreadable.joined(separator: ", ") + ".")
                    + " Fix or remove the file, then use Reload."
            )
        }

        state.message = messages.isEmpty ? nil : messages.joined(separator: " ")
        return state
    }

    /// Every `.txt` file in the directory: the bundled names first in their fixed order, then
    /// the user's own by name. A file removed behind the app's back simply does not appear.
    ///
    /// `failed` separates "the folder is not there yet", which is the state a fresh install is
    /// in and reports nothing, from "the folder is there and could not be enumerated", which is
    /// a failure the user has to hear about.
    private func packNamesOnDisk() -> (names: [String], failed: Bool) {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
        } catch {
            let exists = FileManager.default.fileExists(atPath: directoryURL.path)
            return ([], exists)
        }
        let found = Set(urls.filter { $0.pathExtension == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent })
        let factory = FactoryGlossaryPacks.names.filter(found.contains)
        let user = found.subtracting(factory).sorted()
        return (factory + user, false)
    }

    // MARK: - Seeding

    func seed() throws {
        try createDirectory()
        for name in FactoryGlossaryPacks.names {
            guard let text = FactoryGlossaryPacks.text(name) else { continue }
            try writeIfAbsent(text, to: packURL(name))
        }
        if let readme = FactoryGlossaryPacks.readmeText {
            try writeIfAbsent(readme, to: directoryURL.appendingPathComponent("README.md"))
        }
        // `packs.json` is deliberately not written: seeding enables nothing, and a missing file
        // is the one "nothing enabled" state `GlossaryPackConfig` reports no message for.
    }

    private func createDirectory() throws {
        // Owner-only, matching the history store: this keeps a second account on the same Mac
        // out. The app is deliberately unsandboxed (ADR-0003), so any process running as this
        // user still reads these files.
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // `createDirectory` applies `attributes` only to directories it actually creates, so
            // a directory made before this was tightened must be tightened explicitly here.
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: directoryURL.path)
        } catch {
            throw MacomprendoError.glossary(
                "create the Vocabulary folder: \(error.localizedDescription)"
            )
        }
    }

    private func writeIfAbsent(_ text: String, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try writeFile(text, to: url)
    }

    // MARK: - Editing

    func createPack(named name: String) throws {
        let name = try validatedNewName(name)
        try createDirectory()
        try writeFile(Self.newPackHeader.replacingOccurrences(of: "%@", with: name),
                      to: packURL(name))
    }

    func duplicatePack(named name: String, as newName: String) throws {
        let newName = try validatedNewName(newName)
        let text = try packText(named: name)
        try createDirectory()
        try writeFile(text, to: packURL(newName))
    }

    func deletePack(named name: String) throws {
        _ = try packText(named: name)
        guard FactoryGlossaryPacks.text(name) == nil else {
            throw MacomprendoError.glossary(
                "\"\(name)\" ships with Macomprendo, so deleting its file would only undo itself"
            )
        }
        do {
            try FileManager.default.removeItem(at: packURL(name))
        } catch {
            throw MacomprendoError.glossary("delete \"\(name)\": \(error.localizedDescription)")
        }
        // Deleting through the app also forgets the pack; a file removed behind the app's back
        // keeps its name, because the config makes no filesystem judgements.
        var config = GlossaryPackConfig.decode(from: configData()).config
        guard config.enabled.contains(name) else { return }
        config.enabled.removeAll { $0 == name }
        try writeConfig(config)
    }

    func resetPack(named name: String) throws {
        guard let text = FactoryGlossaryPacks.text(name) else {
            throw MacomprendoError.glossary(
                "\"\(name)\" does not ship with Macomprendo, so there is no version to restore"
            )
        }
        try createDirectory()
        try writeFile(text, to: packURL(name))
    }

    func write(_ text: String, toPackNamed name: String) throws {
        _ = try packText(named: name)
        try writeFile(text, to: packURL(name))
    }

    func setEnabled(_ enabled: Bool, forPackNamed name: String) throws {
        var config = GlossaryPackConfig.decode(from: configData()).config
        if enabled {
            guard !config.enabled.contains(name) else { return }
            // Appended rather than sorted: order is meaningful, and the pack the user switched
            // on last loses a collision against the ones already on.
            config.enabled.append(name)
        } else {
            guard config.enabled.contains(name) else { return }
            config.enabled.removeAll { $0 == name }
        }
        try writeConfig(config)
    }

    // MARK: - Files

    private func packURL(_ name: String) -> URL {
        directoryURL.appendingPathComponent("\(name).txt")
    }

    private var configURL: URL { directoryURL.appendingPathComponent("packs.json") }

    private func configData() -> Data? {
        try? Data(contentsOf: configURL)
    }

    /// `packs.json`'s bytes, or `nil` when there is no such file. `unreadable` separates the two
    /// cases `nil` data would otherwise merge: a file that was never written, which is the
    /// seeded state and reports nothing, and a file that is there and cannot be read, which is
    /// a failure the user has to hear about.
    private func configBytes() -> (data: Data?, unreadable: Bool) {
        if let data = configData() { return (data, false) }
        return (nil, FileManager.default.fileExists(atPath: configURL.path))
    }

    private func writeConfig(_ config: GlossaryPackConfig) throws {
        try createDirectory()
        do {
            try config.encoded().write(to: configURL, options: .atomic)
        } catch {
            throw MacomprendoError.glossary("write packs.json: \(error.localizedDescription)")
        }
    }

    private func packText(named name: String) throws -> String {
        guard let text = try? String(contentsOf: packURL(name), encoding: .utf8) else {
            throw MacomprendoError.glossary("there is no pack called \"\(name)\" in the folder")
        }
        return text
    }

    private func writeFile(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            // The pack's text is user content and never enters an error message (invariant 6).
            throw MacomprendoError.glossary(
                "write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    /// A name a new file may be written under: non-empty, free of the characters that would make
    /// it something other than one file in this folder, and not already taken — **including by a
    /// bundled pack**, because a user pack shadowing a bundled name would be treated as factory
    /// and offer Reset instead of Delete.
    private func validatedNewName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.contains("/"), !name.contains(":"),
              !name.contains("\n"),
              name != ".", name != ".."
        else {
            throw MacomprendoError.glossaryPackNameInvalid(name)
        }
        guard FactoryGlossaryPacks.text(name) == nil,
              !FileManager.default.fileExists(atPath: packURL(name).path)
        else {
            throw MacomprendoError.glossaryPackNameTaken(name)
        }
        return name
    }
}
