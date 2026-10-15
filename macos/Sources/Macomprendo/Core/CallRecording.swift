import Foundation

/// Where call recordings live on disk and how their folders, tracks and titles are named.
/// One place so a recording folder, its two track files and the transcript row it produces
/// all agree on the same string.
enum CallRecordingLayout {
    static let manifestFileName = "recording.json"

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macomprendo", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// `rec 2026-10-15 16-42-07`, in local time. Hyphens where a clock has colons: a colon is
    /// shown as “/” by Finder and is illegal on some volumes (SMB, FAT).
    static func baseName(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "rec " + formatter("yyyy-MM-dd HH-mm-ss", timeZone).string(from: startedAt)
    }

    /// The first attempt keeps the bare base name; a collision gets ` (2)`, ` (3)`… so an
    /// earlier recording is never written over.
    static func folderName(base: String, attempt: Int) -> String {
        attempt <= 1 ? base : "\(base) (\(attempt))"
    }

    static func trackFileName(folderName: String, track: TranscriptSpeaker) -> String {
        "\(folderName) \(track.label).m4a"
    }

    /// The title a call recording's transcript row carries: `Call 2026-10-15 16:42`.
    static func transcriptTitle(startedAt: Date, timeZone: TimeZone = .current) -> String {
        "Call " + formatter("yyyy-MM-dd HH:mm", timeZone).string(from: startedAt)
    }

    /// `en_US_POSIX` so the digits and field order never follow the user's locale — a file
    /// named with Arabic-Indic digits or a day-first order would be no easier to read.
    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

/// A recording folder's `recording.json`: how a later launch knows a recording was cut short
/// and how the transcription job lines the two tracks up on one clock. Value type, so it can
/// be rewritten atomically after each state change.
struct CallRecordingManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    enum Status: String, Codable, Sendable {
        /// Set at start; a folder still carrying it when the app next launches was cut short.
        case recording
        case finished
    }

    /// One side's audio file inside the recording folder. `startOffset` is the file's first
    /// sample measured from `startedAt`, or `nil` until that track has produced one — a
    /// system-audio tap can start a fraction of a second after the microphone.
    struct Track: Codable, Equatable, Sendable {
        var file: String
        var startOffset: TimeInterval?
    }

    var version: Int
    var startedAt: Date
    var status: Status
    /// Keyed by `TranscriptSpeaker.rawValue`.
    var tracks: [String: Track]

    init(startedAt: Date, folderName: String) {
        version = Self.currentVersion
        self.startedAt = startedAt
        status = .recording
        tracks = [
            TranscriptSpeaker.me.rawValue: Track(
                file: CallRecordingLayout.trackFileName(folderName: folderName, track: .me),
                startOffset: nil),
            TranscriptSpeaker.others.rawValue: Track(
                file: CallRecordingLayout.trackFileName(folderName: folderName, track: .others),
                startOffset: nil),
        ]
    }

    func track(_ speaker: TranscriptSpeaker) -> Track? {
        tracks[speaker.rawValue]
    }

    mutating func setStartOffset(_ offset: TimeInterval, for speaker: TranscriptSpeaker) {
        tracks[speaker.rawValue]?.startOffset = offset
    }

    /// A missing file, a payload that will not decode, and a version this build does not know
    /// all mean the same thing to the user: this folder is not a recording this app can resume.
    static func read(from folder: URL) throws -> CallRecordingManifest {
        let url = folder.appendingPathComponent(CallRecordingLayout.manifestFileName)
        guard let data = try? Data(contentsOf: url) else {
            throw MacomprendoError.callRecordingUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CallRecordingManifest.self, from: data),
              manifest.version == currentVersion else {
            throw MacomprendoError.callRecordingUnavailable
        }
        return manifest
    }

    /// Atomic, so a crash mid-write leaves the previous manifest rather than a truncated one.
    /// A failure is the recordings folder being unwritable (invariant 8: nothing fails as a
    /// raw CocoaError), which is what `callRecordingLocationUnavailable` describes.
    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent(CallRecordingLayout.manifestFileName)
        do {
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw MacomprendoError.callRecordingLocationUnavailable
        }
    }
}
