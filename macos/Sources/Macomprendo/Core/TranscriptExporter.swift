import Foundation

enum TranscriptExportFormat: String, Sendable, CaseIterable, Identifiable {
    case plainText
    case subRip
    case markdown

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .subRip: "srt"
        case .markdown: "md"
        }
    }

    var displayName: String {
        switch self {
        case .plainText: "Plain text (.txt)"
        case .subRip: "Subtitles (.srt)"
        case .markdown: "Markdown (.md)"
        }
    }
}

/// Renders a transcript for export. Pure, so every format is unit-tested without a file.
enum TranscriptExporter {

    static func render(_ transcript: Transcript, as format: TranscriptExportFormat) -> String {
        switch format {
        case .plainText: plainText(transcript)
        case .subRip: subRip(transcript)
        case .markdown: markdown(transcript)
        }
    }

    /// `12:03` below an hour, `1:02:03` from an hour on — what the transcript rows show.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// `HH:MM:SS,mmm`, the only timestamp form SubRip players accept.
    static func subRipTimestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    private static func plainText(_ transcript: Transcript) -> String {
        transcript.segments.isEmpty ? "" : transcript.plainText + "\n"
    }

    private static func subRip(_ transcript: Transcript) -> String {
        transcript.segments.enumerated().map { index, segment in
            "\(index + 1)\n"
                + "\(subRipTimestamp(segment.start)) --> \(subRipTimestamp(segment.end))\n"
                + "\(speakerPrefix(segment))\(segment.text)\n"
        }.joined(separator: "\n")
    }

    /// `"Me: "` / `"Others: "` for a call recording's segments, `""` for every other transcript —
    /// so file and dictation exports stay byte-for-byte as they were.
    static func speakerPrefix(_ segment: TranscriptSegment) -> String {
        segment.speaker.map { "\($0.label): " } ?? ""
    }

    private static func markdown(_ transcript: Transcript) -> String {
        let header = transcript.header
        var metadata = [header.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = header.duration { metadata.append(clock(duration)) }
        if let model = transcript.run.modelID { metadata.append(model) }

        var lines = ["# \(header.title)", "", metadata.joined(separator: " · "), ""]
        if let summary = transcript.summary, !summary.isEmpty {
            lines += ["## Summary", "", summary, ""]
        }
        lines += ["## Transcript", ""]
        // A blank line per segment: Markdown folds adjacent lines into one paragraph.
        let segments = transcript.segments.map { segment in
            "**[\(clock(segment.start))]\(segment.speaker.map { " \($0.label):" } ?? "")** \(segment.text)"
        }
        if !segments.isEmpty { lines.append(segments.joined(separator: "\n\n")) }
        return lines.joined(separator: "\n") + "\n"
    }
}
