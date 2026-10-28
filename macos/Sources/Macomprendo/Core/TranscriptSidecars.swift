import Foundation

/// Where the files that travel with a transcript live: a call's subtitles and every
/// transcript's notes. Pure naming, so the recorder, the transcription job and the window
/// agree on one string without touching the disk.
///
/// A call's files sit inside its recording folder and carry the folder's current name, as its
/// tracks do. A file transcript's notes sit next to the source with its last extension swapped
/// for `.notes.txt`. A folder renamed after its notes were written leaves them under the old
/// name; that is accepted (spec §2).
enum TranscriptSidecars {
    static let notesSuffix = ".notes.txt"

    /// `<folder>/<folder name>.srt`
    static func subtitlesURL(callFolder: URL) -> URL {
        callFolder.appendingPathComponent(callFolder.lastPathComponent + ".srt",
                                          isDirectory: false)
    }

    /// `<folder>/<folder name>.notes.txt`
    static func notesURL(callFolder: URL) -> URL {
        callFolder.appendingPathComponent(callFolder.lastPathComponent + notesSuffix,
                                          isDirectory: false)
    }

    /// `/a/meeting.mp4` → `/a/meeting.notes.txt`
    static func notesURL(sourceFile: URL) -> URL {
        let stem = sourceFile.deletingPathExtension().lastPathComponent
        return sourceFile.deletingLastPathComponent()
            .appendingPathComponent(stem + notesSuffix, isDirectory: false)
    }

    /// The notes of a transcript whose bookmark resolved to `source`: the recording folder for
    /// a call, the source file otherwise.
    static func notesURL(kind: TranscriptSourceKind, source: URL) -> URL {
        switch kind {
        case .call: notesURL(callFolder: source)
        case .file: notesURL(sourceFile: source)
        }
    }
}
