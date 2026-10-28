import Foundation

/// Reads and writes the plain-text files that travel with a transcript: its notes and a call's
/// subtitles (`TranscriptSidecars` names them). Behind a protocol so the notes coordinator and
/// the transcription job are tested without a disk (invariant 2).
///
/// Nothing here creates a folder: a sidecar belongs next to a recording or source that exists,
/// and writing into a recreated empty folder would hide that the recording moved.
protocol TranscriptSidecarFiling: Sendable {
    /// The notes at `url`; `""` when there is no file. A file that cannot be read or is not
    /// UTF-8 throws `notesUnreadable` — never `""`, which an autosave would then write over it.
    func readNotes(at url: URL) throws -> String
    /// Writes `text` atomically, or removes the file when `text` is blank. Throws
    /// `notesNotSaved`.
    func saveNotes(_ text: String, at url: URL) throws
    /// Writes `text` atomically, replacing any earlier file. Throws `callSubtitlesNotSaved`.
    func writeSubtitles(_ text: String, at url: URL) throws
    func fileExists(_ url: URL) -> Bool
    /// One spelling per file: symlinks in the folders above it resolved, so a recording folder
    /// named through a symlinked recordings directory and the same folder reached through its
    /// bookmark (which resolves symlinks) are one notes file. The file itself need not exist.
    func canonical(_ url: URL) -> URL
}

struct FileSystemTranscriptSidecars: TranscriptSidecarFiling {
    func readNotes(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        } catch {
            throw MacomprendoError.notesUnreadable(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacomprendoError.notesUnreadable("the file is not UTF-8 text")
        }
        return text
    }

    func saveNotes(_ text: String, at url: URL) throws {
        guard parentExists(url) else {
            throw MacomprendoError.notesNotSaved("the folder no longer exists")
        }
        do {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if fileExists(url) { try FileManager.default.removeItem(at: url) }
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        } catch {
            throw MacomprendoError.notesNotSaved(error.localizedDescription)
        }
    }

    func writeSubtitles(_ text: String, at url: URL) throws {
        guard parentExists(url) else {
            throw MacomprendoError.callSubtitlesNotSaved("the recording folder no longer exists")
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw MacomprendoError.callSubtitlesNotSaved(error.localizedDescription)
        }
    }

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func canonical(_ url: URL) -> URL {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
    }

    /// `.atomic` writes through a temporary file and would fail anyway, but with a message
    /// about a temporary file; checking first names the real reason.
    private func parentExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path,
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
