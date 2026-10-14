import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptExporterTests {

    private func transcript(segments: [TranscriptSegment],
                            summary: String? = nil,
                            duration: TimeInterval? = 3725) -> Transcript {
        Transcript(
            header: TranscriptHeader(id: 1, createdAt: Date(timeIntervalSince1970: 0),
                                     sourceKind: .file, title: "lecture.mp3",
                                     duration: duration, status: .complete, statusReason: nil),
            run: TranscriptionRun(modelID: "base", engine: "whisperCpp", language: nil,
                                  appVersion: "1.0"),
            sourceBookmark: nil,
            summary: summary,
            segments: segments)
    }

    private let two = [
        TranscriptSegment(start: 1.5, end: 4.25, text: "Hello there."),
        TranscriptSegment(start: 3661.0, end: 3662.004, text: "Past one hour."),
    ]

    @Test func plainTextIsOneSegmentPerLineWithoutTimestamps() {
        #expect(TranscriptExporter.render(transcript(segments: two), as: .plainText)
                == "Hello there.\nPast one hour.\n")
    }

    @Test func subRipNumbersCuesFromOneAndFormatsPastAnHour() {
        let expected = """
            1
            00:00:01,500 --> 00:00:04,250
            Hello there.

            2
            01:01:01,000 --> 01:01:02,004
            Past one hour.

            """
        #expect(TranscriptExporter.render(transcript(segments: two), as: .subRip) == expected)
    }

    @Test func markdownCarriesTitleMetadataSummaryAndTimestamps() {
        let text = TranscriptExporter.render(transcript(segments: two, summary: "Short."),
                                             as: .markdown)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "# lecture.mp3")
        #expect(lines[2].hasSuffix(" · 1:02:05 · base"))
        #expect(text.contains("## Summary\n\nShort.\n"))
        #expect(text.contains("## Transcript\n\n**[00:01]** Hello there.\n**[1:01:01]** Past one hour.\n"))
    }

    @Test func markdownWithoutSummaryHasNoSummarySection() {
        let text = TranscriptExporter.render(transcript(segments: two), as: .markdown)
        #expect(!text.contains("## Summary"))
        #expect(text.contains("## Transcript"))
    }

    @Test func anEmptyTranscriptExportsWithoutCues() {
        let empty = transcript(segments: [])
        #expect(TranscriptExporter.render(empty, as: .plainText) == "")
        #expect(TranscriptExporter.render(empty, as: .subRip) == "")
    }

    @Test func clockSwitchesToHoursAtOneHour() {
        #expect(TranscriptExporter.clock(0) == "00:00")
        #expect(TranscriptExporter.clock(59.9) == "00:59")
        #expect(TranscriptExporter.clock(3599) == "59:59")
        #expect(TranscriptExporter.clock(3600) == "1:00:00")
    }

    @Test func everyFormatHasItsExtension() {
        #expect(TranscriptExportFormat.allCases.map(\.fileExtension) == ["txt", "srt", "md"])
    }
}

@Suite struct TranscriptTests {
    @Test func resumeStartsAtTheLastSegmentEnd() {
        let header = TranscriptHeader(id: 1, createdAt: .now, sourceKind: .file, title: "t",
                                      duration: 10, status: .incomplete, statusReason: "x")
        let run = TranscriptionRun(modelID: nil, engine: nil, language: nil, appVersion: "1")
        let empty = Transcript(header: header, run: run, sourceBookmark: nil, summary: nil,
                               segments: [])
        #expect(empty.resumePosition == 0)
        let some = Transcript(header: header, run: run, sourceBookmark: nil, summary: nil,
                              segments: [TranscriptSegment(start: 1, end: 7.5, text: "a")])
        #expect(some.resumePosition == 7.5)
    }
}
