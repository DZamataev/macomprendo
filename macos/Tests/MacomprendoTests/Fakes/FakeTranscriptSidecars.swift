import Foundation
@testable import Macomprendo

/// In-memory `TranscriptSidecarFiling`: files live in a dictionary keyed by path. A folder is
/// "there" unless listed in `missingFolders`; `readFailures` / `saveFailures` /
/// `subtitleFailures` make that URL's next operations throw until cleared.
final class FakeTranscriptSidecars: TranscriptSidecarFiling, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var reads: [String] = []
    private var saves: [(path: String, text: String)] = []

    var missingFolders: Set<String> {
        get { lock.withLock { _missingFolders } }
        set { lock.withLock { _missingFolders = newValue } }
    }
    private var _missingFolders: Set<String> = []
    var readFailures: Set<String> {
        get { lock.withLock { _readFailures } }
        set { lock.withLock { _readFailures = newValue } }
    }
    private var _readFailures: Set<String> = []
    var saveFailures: Set<String> {
        get { lock.withLock { _saveFailures } }
        set { lock.withLock { _saveFailures = newValue } }
    }
    private var _saveFailures: Set<String> = []
    var subtitleFailures: Set<String> {
        get { lock.withLock { _subtitleFailures } }
        set { lock.withLock { _subtitleFailures = newValue } }
    }
    private var _subtitleFailures: Set<String> = []

    /// Path prefixes `canonical` rewrites, alias → target, as a symlinked folder would resolve.
    var aliases: [String: String] {
        get { lock.withLock { _aliases } }
        set { lock.withLock { _aliases = newValue } }
    }
    private var _aliases: [String: String] = [:]

    func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for (alias, target) in lock.withLock({ _aliases }) where path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: target + path.dropFirst(alias.count))
        }
        return url.standardizedFileURL
    }

    /// The file at `url`, or nil.
    func contents(_ url: URL) -> String? { lock.withLock { storage[url.path] } }
    /// Puts a file there as another editor would.
    func put(_ text: String?, at url: URL) { lock.withLock { storage[url.path] = text } }
    /// Every `saveNotes` call that reached the "disk", in order.
    var savedNotes: [(path: String, text: String)] { lock.withLock { saves } }
    var readCount: Int { lock.withLock { reads.count } }

    func readNotes(at url: URL) throws -> String {
        try lock.withLock {
            reads.append(url.path)
            if _readFailures.contains(url.path) {
                throw MacomprendoError.notesUnreadable("the file is not UTF-8 text")
            }
            return storage[url.path] ?? ""
        }
    }

    func saveNotes(_ text: String, at url: URL) throws {
        try lock.withLock {
            if _saveFailures.contains(url.path)
                || _missingFolders.contains(url.deletingLastPathComponent().path) {
                throw MacomprendoError.notesNotSaved("the folder no longer exists")
            }
            saves.append((url.path, text))
            storage[url.path] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : text
        }
    }

    func writeSubtitles(_ text: String, at url: URL) throws {
        try lock.withLock {
            if _subtitleFailures.contains(url.path)
                || _missingFolders.contains(url.deletingLastPathComponent().path) {
                throw MacomprendoError.callSubtitlesNotSaved("the disk is full")
            }
            storage[url.path] = text
        }
    }

    func fileExists(_ url: URL) -> Bool { lock.withLock { storage[url.path] != nil } }
}
