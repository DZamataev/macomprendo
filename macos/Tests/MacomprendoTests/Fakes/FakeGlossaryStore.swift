import Foundation
@testable import Macomprendo

/// An in-memory `GlossaryStoring`: packs and `packs.json` in dictionaries instead of a folder,
/// so a controller or view model under test never touches the disk.
///
/// It records every mutation so a test can assert that toggling a pack, for instance, wrote the
/// config and nothing else.
actor FakeGlossaryStore: GlossaryStoring {
    enum Mutation: Equatable, Sendable {
        case seed
        case create(String)
        case duplicate(String, String)
        case delete(String)
        case reset(String)
        case write(String)
        case setEnabled(Bool, String)
    }

    nonisolated let directoryURL: URL

    private(set) var mutations: [Mutation] = []
    private(set) var loadCallCount = 0
    private(set) var reloadCallCount = 0

    /// Pack texts by name, as if they were files.
    private var texts: [String: String] = [:]
    /// Names the fake reports as bundled, so `isFactory` can be steered without a bundle.
    private var factoryNames: Set<String> = []
    private var enabled: [String] = []
    private var message: String?
    private var nextError: (any Error)?

    init(directoryURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeVocabulary", isDirectory: true)) {
        self.directoryURL = directoryURL
    }

    // MARK: - Steering

    func setPack(_ text: String, named name: String, isFactory: Bool = false) {
        texts[name] = text
        if isFactory { factoryNames.insert(name) } else { factoryNames.remove(name) }
    }

    func setEnabledNames(_ names: [String]) {
        enabled = names
    }

    func setMessage(_ message: String?) {
        self.message = message
    }

    /// Makes the next mutating call throw, then clears itself.
    func setNextError(_ error: (any Error)?) {
        nextError = error
    }

    var state: GlossaryState { currentState() }

    // MARK: - GlossaryStoring

    func load() async throws -> GlossaryState {
        loadCallCount += 1
        try consumeError()
        return currentState()
    }

    func reload() async -> GlossaryState {
        reloadCallCount += 1
        return currentState()
    }

    func seed() async throws {
        try consumeError()
        mutations.append(.seed)
    }

    func createPack(named name: String) async throws {
        try consumeError()
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            throw MacomprendoError.glossaryPackNameInvalid(name)
        }
        guard texts[name] == nil else { throw MacomprendoError.glossaryPackNameTaken(name) }
        texts[name] = "# pack: \(name)\n"
        mutations.append(.create(name))
    }

    func duplicatePack(named name: String, as newName: String) async throws {
        try consumeError()
        guard let text = texts[name] else {
            throw MacomprendoError.glossary("there is no pack called \"\(name)\" in the folder")
        }
        guard texts[newName] == nil else { throw MacomprendoError.glossaryPackNameTaken(newName) }
        texts[newName] = text
        mutations.append(.duplicate(name, newName))
    }

    func deletePack(named name: String) async throws {
        try consumeError()
        guard texts[name] != nil else {
            throw MacomprendoError.glossary("there is no pack called \"\(name)\" in the folder")
        }
        guard !factoryNames.contains(name) else {
            throw MacomprendoError.glossary("\"\(name)\" ships with Macomprendo")
        }
        texts[name] = nil
        enabled.removeAll { $0 == name }
        mutations.append(.delete(name))
    }

    func resetPack(named name: String) async throws {
        try consumeError()
        guard factoryNames.contains(name) else {
            throw MacomprendoError.glossary("\"\(name)\" does not ship with Macomprendo")
        }
        mutations.append(.reset(name))
    }

    func write(_ text: String, toPackNamed name: String) async throws {
        try consumeError()
        guard texts[name] != nil else {
            throw MacomprendoError.glossary("there is no pack called \"\(name)\" in the folder")
        }
        texts[name] = text
        mutations.append(.write(name))
    }

    func setEnabled(_ isEnabled: Bool, forPackNamed name: String) async throws {
        try consumeError()
        if isEnabled {
            if !enabled.contains(name) { enabled.append(name) }
        } else {
            enabled.removeAll { $0 == name }
        }
        mutations.append(.setEnabled(isEnabled, name))
    }

    // MARK: - Helpers

    private func consumeError() throws {
        if let nextError {
            self.nextError = nil
            throw nextError
        }
    }

    private func currentState() -> GlossaryState {
        let enabledNames = Set(enabled)
        let packs = texts.keys.sorted().map { name in
            GlossaryPackState(pack: GlossaryPack.parse(texts[name] ?? "", name: name),
                              isFactory: factoryNames.contains(name),
                              isEnabled: enabledNames.contains(name))
        }
        return GlossaryState(packs: packs, enabled: enabled, message: message)
    }
}
