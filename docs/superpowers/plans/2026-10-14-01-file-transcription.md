# File Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcribe any audio or video file with the configured backend, store the result with
timestamps, show it in a Transcripts window, export it, and summarise it.

**Architecture:** AVFoundation decodes the file to a 16 kHz mono stream; a bundled Silero VAD
(sherpa-onnx C API) cuts it into ≤ 30 s speech segments; each segment goes through the existing
`TranscriptionProvider`, is normalised by the glossary and appended to a separate SQLite store.
A `TranscriptionLane` lets a dictation overtake the file job between segments. `@MainActor`
controllers drive the window; summaries reuse the Summarize feature's LLM and default preset.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation, SQLite3,
sherpa-onnx 1.13.4 C API, swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-14-file-transcription-design.md`

## Global Constraints

- macOS 14.0 deployment target; Swift 6 language mode; no new package dependencies.
- Layers point downward only: UI → Features → Services/Providers → Core. Concrete services are
  constructed only in `AppEnvironment.live()` (`macos/Sources/Macomprendo/App/AppEnvironment.swift`).
- Every OS-facing service sits behind a protocol with a fake in `macos/Tests/MacomprendoTests/Fakes`.
- Never log transcript or summary text at default level (AGENTS.md invariant 6). Status
  reasons stored in the database carry error text only, never transcript text.
- Every user-visible failure is a `MacomprendoError` case with `errorDescription` and
  `recoverySuggestion`.
- A new resource directory is declared in **both** `macos/Package.swift` `resources:` and
  `macos/project.yml` (invariant 17).
- Any task that adds a Swift file runs `npm run gen` and commits the regenerated
  `macos/Macomprendo.xcodeproj`: the Xcode project lists files by name.
- Do not edit an existing test to make it pass. If one turns red, leave it red and report it.
- Stage only the paths the task lists, by name. Commit messages are conventional commits.
- `npm run test:swift` is green at the end of every task.
- Tests under load: `waitFor` (`Tests/MacomprendoTests/Support/Wait.swift`) reports a
  starvation timeout when a compile shares the machine. Let builds finish and re-run before
  believing such a failure.

## Verified before writing

Tasks 1–5 below quote code that was assembled in a throwaway clone at `4bf8d5b` and run:
the whole suite passed, `xcodebuild` Release succeeded with `silero_vad.onnx` inside the app
bundle, and `npm run audit` passed with the model file present. Facts established there:

- `silero_vad.onnx` from `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`
  is 643,854 bytes, SHA-256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`.
  Its licence is MIT (`https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE`).
- Silero's `max_speech_duration` does **not** cap segment length: 70 s of continuous speech came
  back as one 70 s segment with the limit at 25 s and at 10 s. `SpeechSegmentSplitter` caps it.
- The same probe ignored 2 s of low-level noise and 3 s silences, and placed a segment starting
  0.7 s into `say` output — `say` leads with ~0.7 s of silence.
- `AVAssetReaderTrackOutput` with LinearPCM Float32, 16 kHz, 1 channel resamples and downmixes
  a 44.1 kHz stereo WAV itself; `reader.timeRange` starting at 2 s of a 3 s file yields ~16,000
  samples.

Tasks 6–14 are specified by interface and test list; their executors write the code.

## Blockers — where an executor must stop

- None of the tasks needs network access except Task 3 Step 1 (downloading the model and the
  licence text). If the download fails or the SHA-256 differs from the value above, stop and
  report; do not substitute another Silero file.
- Task 13's eyeball check needs a person at the Mac (Denis). The executor builds, runs the app
  via `npm run install-app:signed`, and hands over the checklist; it does not claim the UI works.

---

### Task 1: Core transcript types, exporter and chunker

**Files:**
- Create: `macos/Sources/Macomprendo/Core/Transcript.swift`
- Create: `macos/Sources/Macomprendo/Core/TranscriptExporter.swift`
- Create: `macos/Sources/Macomprendo/Core/TranscriptChunker.swift`
- Test: `macos/Tests/MacomprendoTests/Core/TranscriptExporterTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptionRun` (`macos/Sources/Macomprendo/Core/DictationHistoryEntry.swift:11`).
- Produces: `TranscriptSourceKind { file, call }`, `TranscriptStatus { inProgress, complete,
  incomplete }`, `TranscriptSegment(start:end:text:rawText:)`, `TranscriptHeader`,
  `Transcript { header, run, sourceBookmark, summary, segments, id, plainText, resumePosition }`,
  `TranscriptExportFormat { plainText, subRip, markdown; fileExtension; displayName }`,
  `TranscriptExporter.render(_:as:) -> String`, `TranscriptExporter.clock(_:) -> String`,
  `TranscriptExporter.subRipTimestamp(_:) -> String`,
  `TranscriptChunker.parts(of:limit:) -> [String]`, `TranscriptChunker.defaultLimit = 12_000`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/MacomprendoTests/Core/TranscriptExporterTests.swift`:

```swift
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

@Suite struct TranscriptChunkerTests {

    private func segments(_ texts: [String]) -> [TranscriptSegment] {
        texts.enumerated().map { index, text in
            TranscriptSegment(start: Double(index), end: Double(index) + 1, text: text)
        }
    }

    @Test func aShortTranscriptIsOnePart() {
        #expect(TranscriptChunker.parts(of: segments(["a", "b", "c"]), limit: 100) == ["a\nb\nc"])
    }

    @Test func partsNeverSplitASegment() {
        // "aaaa\nbbbb" is 9 characters; adding "\ncccc" would make 14 > 10.
        let parts = TranscriptChunker.parts(of: segments(["aaaa", "bbbb", "cccc"]), limit: 10)
        #expect(parts == ["aaaa\nbbbb", "cccc"])
        #expect(parts.allSatisfy { $0.count <= 10 })
    }

    @Test func aSegmentLongerThanTheLimitIsItsOwnPart() {
        let long = String(repeating: "x", count: 25)
        #expect(TranscriptChunker.parts(of: segments(["a", long, "b"]), limit: 10)
                == ["a", long, "b"])
    }

    @Test func noSegmentsGiveNoParts() {
        #expect(TranscriptChunker.parts(of: []).isEmpty)
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
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --package-path macos --filter 'TranscriptExporterTests|TranscriptChunkerTests|TranscriptTests'`
Expected: build failure — `cannot find 'Transcript' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/Macomprendo/Core/Transcript.swift`:

```swift
import Foundation

/// Where a transcript's audio came from. `call` is reserved for call recording, which stores
/// into the same table; nothing produces it yet.
enum TranscriptSourceKind: String, Sendable, Equatable, CaseIterable {
    case file
    case call
}

enum TranscriptStatus: String, Sendable, Equatable, CaseIterable {
    case inProgress
    case complete
    case incomplete
}

/// One stretch of speech, timed from the start of the source.
struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// What the transcript shows: the recogniser output after glossary normalisation.
    let text: String
    /// The recogniser's own words, only when normalisation rewrote them — `nil` otherwise,
    /// as in dictation history.
    let rawText: String?

    init(start: TimeInterval, end: TimeInterval, text: String, rawText: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.rawText = rawText
    }
}

/// A transcript as the list shows it, without its segments.
struct TranscriptHeader: Identifiable, Sendable, Equatable {
    let id: Int64
    let createdAt: Date
    let sourceKind: TranscriptSourceKind
    let title: String
    /// Seconds. `nil` when the source reported no duration.
    let duration: TimeInterval?
    let status: TranscriptStatus
    /// Why an `incomplete` transcript stopped. Never contains transcript text or API keys.
    let statusReason: String?
}

struct Transcript: Sendable, Equatable {
    let header: TranscriptHeader
    let run: TranscriptionRun
    /// A bookmark to the source file, so `Resume` can reopen it after the file moved.
    let sourceBookmark: Data?
    let summary: String?
    let segments: [TranscriptSegment]

    var id: Int64 { header.id }

    /// Segment texts, one per line, without timestamps.
    var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Where `Resume` restarts decoding: the end of the last stored segment.
    var resumePosition: TimeInterval {
        segments.last?.end ?? 0
    }
}
```

Create `macos/Sources/Macomprendo/Core/TranscriptExporter.swift`:

```swift
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
                + "\(segment.text)\n"
        }.joined(separator: "\n")
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
        lines += transcript.segments.map { "**[\(clock($0.start))]** \($0.text)" }
        return lines.joined(separator: "\n") + "\n"
    }
}
```

Create `macos/Sources/Macomprendo/Core/TranscriptChunker.swift`:

```swift
import Foundation

/// Splits a transcript into parts an LLM can summarise one at a time. Pure.
enum TranscriptChunker {
    static let defaultLimit = 12_000

    /// Whole segments joined by newlines, each part at most `limit` characters — except a
    /// single segment longer than `limit`, which becomes a part of its own rather than being
    /// cut mid-sentence. Empty input gives no parts.
    static func parts(of segments: [TranscriptSegment], limit: Int = defaultLimit) -> [String] {
        var parts: [String] = []
        var current = ""
        for segment in segments {
            let text = segment.text
            if current.isEmpty {
                current = text
            } else if current.count + 1 + text.count <= limit {
                current += "\n" + text
            } else {
                parts.append(current)
                current = text
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
```

- [ ] **Step 4: Run them green**

Run: `swift test --package-path macos --filter 'TranscriptExporterTests|TranscriptChunkerTests|TranscriptTests'`
Expected: all pass.

- [ ] **Step 5: Regenerate the project and commit**

```bash
npm run gen
git add macos/Sources/Macomprendo/Core/Transcript.swift \
        macos/Sources/Macomprendo/Core/TranscriptExporter.swift \
        macos/Sources/Macomprendo/Core/TranscriptChunker.swift \
        macos/Tests/MacomprendoTests/Core/TranscriptExporterTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(transcripts): core transcript types, exporter and chunker"
```

---

### Task 2: Error cases

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift` (cases at lines 30–31, the two switches)
- Test: `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift` (argument list, lines 4–26)

**Interfaces:**
- Produces: `MacomprendoError.mediaUnreadable(String)`, `.noAudioTrack`, `.noSpeechFound`,
  `.sourceFileUnavailable`, `.transcriptStore(String)`, `.speechDetector(String)`.

- [ ] **Step 1: Add the new cases to the test's argument list**

In `MacomprendoErrorTests.swift`, replace `    .silentCapture\n])` with:

```swift
    .silentCapture,
    .mediaUnreadable("unsupported format"),
    .noAudioTrack,
    .noSpeechFound,
    .sourceFileUnavailable,
    .transcriptStore("database is read-only"),
    .speechDetector("model file missing")
])
```

- [ ] **Step 2: Run it and see it fail**

Run: `swift test --package-path macos --filter everyErrorHasDescriptionAndRecovery`
Expected: build failure — `type 'MacomprendoError' has no member 'mediaUnreadable'`.

- [ ] **Step 3: Implement**

In `MacomprendoError.swift`, insert after `    case silentCapture` (before `    case cancelled`):

```swift
    case mediaUnreadable(String)
    case noAudioTrack
    case noSpeechFound
    case sourceFileUnavailable
    case transcriptStore(String)
    case speechDetector(String)
```

In `errorDescription`, insert after the `.silentCapture` case:

```swift
        case .mediaUnreadable(let reason):
            return "Macomprendo cannot read this file: \(reason)"
        case .noAudioTrack:
            return "This file has no audio track."
        case .noSpeechFound:
            return "No speech was found in this file."
        case .sourceFileUnavailable:
            return "The original file can no longer be found."
        case .transcriptStore(let reason):
            return "Transcripts are unavailable: \(reason)"
        case .speechDetector(let reason):
            return "The speech detector could not start: \(reason)"
```

In `recoverySuggestion`, insert after the `.silentCapture` case:

```swift
        case .mediaUnreadable:
            return "Check that the file opens in QuickTime Player. Files protected by DRM cannot be transcribed."
        case .noAudioTrack:
            return "Choose a recording or a video that has sound."
        case .noSpeechFound:
            return "The file contains only silence, music or noise. Check that it is the right file."
        case .sourceFileUnavailable:
            return "Choose the file again to continue transcribing it."
        case .transcriptStore:
            return "Check that the disk has free space and that Macomprendo can write to Application Support."
        case .speechDetector:
            return "Reinstall Macomprendo: the bundled speech detector model is missing or damaged."
```

- [ ] **Step 4: Run green**

Run: `swift test --package-path macos --filter everyErrorHasDescriptionAndRecovery`
Expected: 27 cases pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Core/MacomprendoError.swift \
        macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift
git commit -m "feat(transcripts): errors for file decoding, speech detection and the store"
```

---

### Task 3: Bundled Silero VAD, segment cap and segmenter

**Files:**
- Create: `macos/Sources/Macomprendo/Resources/SpeechDetection/silero_vad.onnx` (binary, downloaded)
- Create: `macos/Sources/Macomprendo/Resources/Licenses/silero-vad.txt` (downloaded)
- Create: `macos/Sources/Macomprendo/Services/SpeechSegmentSplitter.swift`
- Create: `macos/Sources/Macomprendo/Services/SpeechSegmenter.swift`
- Modify: `macos/Package.swift:24-28` (resources)
- Modify: `macos/project.yml:35-48` (excludes and folder entries)
- Modify: `macos/Sources/Macomprendo/Core/LicenseRegistry.swift` (append an entry after Phosphor Icons)
- Modify: `NOTICE` (Components table, after the Phosphor Icons row)
- Test: `macos/Tests/MacomprendoTests/Services/SpeechSegmentSplitterTests.swift` (create)
- Test: `macos/Tests/MacomprendoTests/Core/LicenseRegistryTests.swift:12-25` (expected names)
- Test: the `SherpaSileroSegmenterTests` suite lands in Task 4's test file, because its speech
  test decodes through `AVAssetMediaDecoder`; this task's segmenter is covered there.

**Interfaces:**
- Consumes: `MacomprendoError.speechDetector` (Task 2), `ResourceBundle.current`
  (`macos/Sources/Macomprendo/Core/ResourceBundle.swift`), `SherpaOnnxC` C API.
- Produces: `SpeechSegment { start, samples, sampleRate, duration, end }`,
  `SpeechSegmentSplitter.split(_:) -> [SpeechSegment]` with `maximumDuration = 30`,
  `searchWindow = 5`, `minimumDuration = 0.3`, `frameDuration = 0.02`;
  `protocol SpeechSegmenting: Sendable { func makeSession() throws -> any SpeechSegmentingSession }`;
  `protocol SpeechSegmentingSession: AnyObject { func accept(_:) -> [SpeechSegment]; func finish() -> [SpeechSegment] }`;
  `struct SherpaSileroSegmenter: SpeechSegmenting` with `init(modelURL: URL? = <bundled>)` and
  `static let sampleRate = 16_000`.

- [ ] **Step 1: Fetch the model and its licence, and verify them**

```bash
mkdir -p macos/Sources/Macomprendo/Resources/SpeechDetection
curl -fsSL -o macos/Sources/Macomprendo/Resources/SpeechDetection/silero_vad.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
shasum -a 256 macos/Sources/Macomprendo/Resources/SpeechDetection/silero_vad.onnx
curl -fsSL -o macos/Sources/Macomprendo/Resources/Licenses/silero-vad.txt \
  https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE
head -1 macos/Sources/Macomprendo/Resources/Licenses/silero-vad.txt
```

Expected: the digest is `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` and
the licence's first line is `MIT License`. Anything else: stop and report.

- [ ] **Step 2: Write the failing splitter tests and the licence expectation**

Create `macos/Tests/MacomprendoTests/Services/SpeechSegmentSplitterTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechSegmentSplitterTests {
    private let rate = 16_000

    private func loud(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in index % 2 == 0 ? 0.5 : -0.5 }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test func aSegmentWithinTheCapPassesThroughUnchanged() {
        let segment = SpeechSegment(start: 12, samples: loud(29.5), sampleRate: rate)
        #expect(SpeechSegmentSplitter.split(segment) == [segment])
    }

    @Test func aSegmentShorterThanTheMinimumIsDropped() {
        let segment = SpeechSegment(start: 0, samples: loud(0.29), sampleRate: rate)
        #expect(SpeechSegmentSplitter.split(segment).isEmpty)
    }

    @Test func aLongSegmentSplitsAtTheQuietestPointOfTheLastFiveSeconds() throws {
        // 27 s of speech, 0.2 s of silence, 10 s of speech: the cut belongs in the silence.
        let samples = loud(27) + quiet(0.2) + loud(10)
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 100, samples: samples, sampleRate: rate))
        #expect(pieces.count == 2)
        let first = try #require(pieces.first)
        #expect(first.start == 100)
        #expect(first.duration > 27 && first.duration < 27.2)
        #expect(pieces[1].start == first.end)
        #expect(pieces.map(\.samples.count).reduce(0, +) == samples.count)
    }

    @Test func everyPieceFitsTheCapWhateverTheInput() {
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 0, samples: loud(95), sampleRate: rate))
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.duration <= SpeechSegmentSplitter.maximumDuration })
        #expect(pieces.map(\.samples.count).reduce(0, +) == 95 * rate)
    }

    @Test func piecesAreContiguousAndOrdered() {
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 3, samples: loud(70), sampleRate: rate))
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            #expect(abs(previous.end - next.start) < 1e-9)
        }
    }
}
```

In `LicenseRegistryTests.listsEveryComponentTheAppRedistributes`, replace `            "Phosphor Icons",\n        ])` with:

```swift
            "Phosphor Icons",
            "Silero VAD",
        ])
```

- [ ] **Step 3: Run them and see them fail**

Run: `swift test --package-path macos --filter 'SpeechSegmentSplitterTests|LicenseRegistryTests'`
Expected: build failure — `cannot find 'SpeechSegment' in scope`.

- [ ] **Step 4: Implement the splitter and the segmenter**

Create `macos/Sources/Macomprendo/Services/SpeechSegmentSplitter.swift`:

```swift
import Foundation

/// A stretch of speech found in a longer recording.
struct SpeechSegment: Sendable, Equatable {
    /// Seconds from the start of the decoded stream.
    let start: TimeInterval
    let samples: [Float]
    let sampleRate: Int

    var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
    var end: TimeInterval { start + duration }
}

/// Caps segment length for the recogniser. Pure.
///
/// Silero VAD's own `max_speech_duration` only raises its threshold to *encourage* a split; on
/// 70 s of continuous speech it returned one 70 s segment with the limit at 25 s and at 10 s.
/// The cap therefore lives here instead.
enum SpeechSegmentSplitter {
    static let maximumDuration: TimeInterval = 30
    static let searchWindow: TimeInterval = 5
    static let minimumDuration: TimeInterval = 0.3
    /// 20 ms at 16 kHz: short enough to land between words, long enough to average out a
    /// single loud sample.
    static let frameDuration: TimeInterval = 0.02

    /// Drops segments shorter than `minimumDuration` and cuts each longer than
    /// `maximumDuration` at its quietest frame inside the last `searchWindow` seconds before
    /// the cap, repeating until every piece fits.
    static func split(_ segment: SpeechSegment) -> [SpeechSegment] {
        guard segment.duration >= minimumDuration else { return [] }
        let rate = Double(segment.sampleRate)
        let cap = Int(maximumDuration * rate)
        let frame = max(1, Int(frameDuration * rate))
        let window = Int(searchWindow * rate)

        var pieces: [SpeechSegment] = []
        var offset = 0
        let samples = segment.samples
        while samples.count - offset > cap {
            let searchStart = offset + cap - window
            var quietest = offset + cap
            var quietestEnergy = Float.greatestFiniteMagnitude
            var frameStart = searchStart
            while frameStart + frame <= offset + cap {
                var energy: Float = 0
                for index in frameStart..<(frameStart + frame) {
                    energy += samples[index] * samples[index]
                }
                // `<=`: among equally quiet frames take the latest, so uniform speech is cut
                // as close to the cap as possible rather than five seconds early.
                if energy <= quietestEnergy {
                    quietestEnergy = energy
                    quietest = frameStart + frame / 2
                }
                frameStart += frame
            }
            pieces.append(SpeechSegment(start: segment.start + Double(offset) / rate,
                                        samples: Array(samples[offset..<quietest]),
                                        sampleRate: segment.sampleRate))
            offset = quietest
        }
        pieces.append(SpeechSegment(start: segment.start + Double(offset) / rate,
                                    samples: Array(samples[offset...]),
                                    sampleRate: segment.sampleRate))
        return pieces.filter { $0.duration >= minimumDuration }
    }
}
```

Create `macos/Sources/Macomprendo/Services/SpeechSegmenter.swift`:

```swift
import Foundation
import SherpaOnnxC

/// Finds speech in a stream of 16 kHz mono PCM.
protocol SpeechSegmenting: Sendable {
    /// A fresh detector for one recording. Sessions keep state between `accept` calls and are
    /// used from one task at a time.
    func makeSession() throws -> any SpeechSegmentingSession
}

protocol SpeechSegmentingSession: AnyObject {
    /// Feeds samples; returns the segments completed by them, each at most
    /// `SpeechSegmentSplitter.maximumDuration` long.
    func accept(_ samples: [Float]) -> [SpeechSegment]
    /// Ends the stream and returns whatever speech was still open.
    func finish() -> [SpeechSegment]
}

/// Silero VAD through the vendored sherpa-onnx C API, with the model bundled in
/// `Resources/SpeechDetection` (ADR-0015).
struct SherpaSileroSegmenter: SpeechSegmenting {
    static let sampleRate = 16_000

    private let modelURL: URL?

    init(modelURL: URL? = ResourceBundle.current.url(forResource: "silero_vad",
                                                      withExtension: "onnx",
                                                      subdirectory: "SpeechDetection")) {
        self.modelURL = modelURL
    }

    func makeSession() throws -> any SpeechSegmentingSession {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MacomprendoError.speechDetector("silero_vad.onnx is not in the app bundle")
        }
        return try SherpaSileroSession(modelPath: modelURL.path)
    }
}

private final class SherpaSileroSession: SpeechSegmentingSession {
    private let detector: OpaquePointer
    private let rate = SherpaSileroSegmenter.sampleRate

    init(modelPath: String) throws {
        var config = SherpaOnnxVadModelConfig()
        let created: OpaquePointer? = modelPath.withCString { model in
            "cpu".withCString { provider in
                config.silero_vad.model = model
                config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = 0.5
                config.silero_vad.min_speech_duration = 0.25
                // The detector only *encourages* a split here; SpeechSegmentSplitter enforces it.
                config.silero_vad.max_speech_duration = Float(SpeechSegmentSplitter.maximumDuration)
                config.silero_vad.window_size = 512
                config.sample_rate = Int32(SherpaSileroSegmenter.sampleRate)
                config.num_threads = 1
                config.provider = provider
                config.debug = 0
                return SherpaOnnxCreateVoiceActivityDetector(&config, 60)
            }
        }
        guard let created else {
            throw MacomprendoError.speechDetector("sherpa-onnx rejected the model")
        }
        detector = created
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    func accept(_ samples: [Float]) -> [SpeechSegment] {
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buffer.baseAddress,
                                                         Int32(buffer.count))
        }
        return drain()
    }

    func finish() -> [SpeechSegment] {
        SherpaOnnxVoiceActivityDetectorFlush(detector)
        return drain()
    }

    private func drain() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let front = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let segment = front.pointee
            let samples = Array(UnsafeBufferPointer(start: segment.samples, count: Int(segment.n)))
            SherpaOnnxDestroySpeechSegment(front)
            SherpaOnnxVoiceActivityDetectorPop(detector)
            segments += SpeechSegmentSplitter.split(
                SpeechSegment(start: Double(segment.start) / Double(rate),
                              samples: samples, sampleRate: rate))
        }
        return segments
    }
}
```

- [ ] **Step 5: Declare the resource directory twice, register the licence**

`macos/Package.swift`, in `resources:`:

```swift
                .copy("Resources/Icons"),
                .copy("Resources/Licenses"),
                .copy("Resources/SpeechDetection"),
                .copy("Resources/Vocabulary")
```

`macos/project.yml`, under the `Macomprendo` target's `sources:` — add `- "Resources/SpeechDetection"`
to `excludes` between `Licenses` and `Vocabulary`, and add before the `Vocabulary` folder entry:

```yaml
      - path: Sources/Macomprendo/Resources/SpeechDetection
        type: folder
        buildPhase: resources
```

`LicenseRegistry.all`, after the `Phosphor Icons` entry:

```swift
        LicenseEntry(
            component: "Silero VAD",
            spdx: "MIT",
            origin: "Bundled model file (Resources/SpeechDetection/silero_vad.onnx)",
            homepage: URL(string: "https://github.com/snakers4/silero-vad")!,
            resourceName: "silero-vad",
            isCopyleft: false,
            note: nil
        ),
```

`NOTICE`, after the `| [Phosphor Icons](https://phosphoricons.com) | MIT | Vendored SVGs |` row:

```markdown
| [Silero VAD](https://github.com/snakers4/silero-vad) | MIT | Bundled model file (`silero_vad.onnx`) |
```

- [ ] **Step 6: Run green, including the packaging gate**

```bash
swift test --package-path macos --filter 'SpeechSegmentSplitterTests|LicenseRegistryTests'
npm run gen
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
ls -l build/dd/Build/Products/Release/Macomprendo.app/Contents/Resources/SpeechDetection/silero_vad.onnx
npm run audit
```

Expected: tests pass; `BUILD SUCCEEDED`; the `ls` shows 643854 bytes — a green build without
this file in the bundle is the invariant-17 failure; `npm run audit` passes.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/Resources/SpeechDetection/silero_vad.onnx \
        macos/Sources/Macomprendo/Resources/Licenses/silero-vad.txt \
        macos/Sources/Macomprendo/Services/SpeechSegmentSplitter.swift \
        macos/Sources/Macomprendo/Services/SpeechSegmenter.swift \
        macos/Tests/MacomprendoTests/Services/SpeechSegmentSplitterTests.swift \
        macos/Tests/MacomprendoTests/Core/LicenseRegistryTests.swift \
        macos/Sources/Macomprendo/Core/LicenseRegistry.swift \
        macos/Package.swift macos/project.yml macos/Macomprendo.xcodeproj NOTICE
git commit -m "feat(transcripts): bundle Silero VAD and cap speech segments at 30 s"
```

---

### Task 4: Media decoder (and the real segmenter tests)

**Files:**
- Create: `macos/Sources/Macomprendo/Services/MediaAudioDecoder.swift`
- Test: `macos/Tests/MacomprendoTests/Services/MediaAudioDecoderTests.swift` (create; holds
  `MediaAudioDecoderTests` and `SherpaSileroSegmenterTests`)

**Interfaces:**
- Consumes: Task 2 errors, Task 3 segmenter.
- Produces: `struct DecodedAudio: Sendable { duration; startOffset; chunks: AsyncThrowingStream<[Float], Error> }`;
  `protocol MediaAudioDecoding: Sendable { func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio }`;
  `struct AVAssetMediaDecoder: MediaAudioDecoding` with `static let sampleRate = 16_000`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/MacomprendoTests/Services/MediaAudioDecoderTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct MediaAudioDecoderTests {

    /// A 44.1 kHz stereo WAV of a 440 Hz tone: neither the rate nor the channel count the
    /// decoder emits, so the test proves it resamples and downmixes.
    private func writeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 44_100)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func collect(_ audio: DecodedAudio) async throws -> [Float] {
        var all: [Float] = []
        for try await chunk in audio.chunks { all += chunk }
        return all
    }

    @Test func decodesToSixteenKilohertzMonoWithTheFileDuration() async throws {
        let url = try writeTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try await AVAssetMediaDecoder().open(url, from: 0)
        let samples = try await collect(audio)

        #expect(abs(audio.duration - 2) < 0.01)
        #expect(audio.startOffset == 0)
        #expect(abs(samples.count - 32_000) < 400)
        #expect(samples.contains { abs($0) > 0.3 })
    }

    @Test func decodingFromAnOffsetSkipsTheStart() async throws {
        let url = try writeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try await AVAssetMediaDecoder().open(url, from: 2)
        let samples = try await collect(audio)

        #expect(abs(audio.duration - 3) < 0.01)
        #expect(audio.startOffset == 2)
        #expect(abs(samples.count - 16_000) < 400)
    }

    @Test func aFileThatIsNotMediaIsUnreadable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-media-\(UUID().uuidString).mp3")
        try Data("plain text, not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect {
            _ = try await AVAssetMediaDecoder().open(url, from: 0)
        } throws: { error in
            guard let error = error as? MacomprendoError else { return false }
            if case .mediaUnreadable = error { return true }
            return error == .noAudioTrack
        }
    }
}

@Suite struct SherpaSileroSegmenterTests {

    @Test func theBundledModelLoads() throws {
        _ = try SherpaSileroSegmenter().makeSession()
    }

    @Test func aMissingModelIsASpeechDetectorError() {
        let segmenter = SherpaSileroSegmenter(modelURL: URL(fileURLWithPath: "/nonexistent.onnx"))
        #expect(throws: MacomprendoError.speechDetector("silero_vad.onnx is not in the app bundle")) {
            _ = try segmenter.makeSession()
        }
    }

    @Test func silenceYieldsNoSegments() throws {
        let session = try SherpaSileroSegmenter().makeSession()
        var segments = session.accept(Array(repeating: 0, count: 16_000 * 5))
        segments += session.finish()
        #expect(segments.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func spokenWordsBetweenSilencesYieldTimedSegments() async throws {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmenter-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "This is a short sentence for the speech detector."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        var speech: [Float] = []
        for try await chunk in try await AVAssetMediaDecoder().open(aiff, from: 0).chunks {
            speech += chunk
        }
        let silence = [Float](repeating: 0, count: 16_000 * 3)
        let stream = silence + speech + silence

        let session = try SherpaSileroSegmenter().makeSession()
        var segments: [SpeechSegment] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 16_000, stream.count)
            segments += session.accept(Array(stream[offset..<end]))
            offset = end
        }
        segments += session.finish()

        let first = try #require(segments.first)
        // `say` itself leads with ~0.7 s of silence, so speech begins near 3.7 s.
        #expect(first.start > 2.5)
        #expect(first.start < 4.5)
        #expect(segments.allSatisfy { $0.duration <= SpeechSegmentSplitter.maximumDuration })
        let last = try #require(segments.last)
        #expect(last.end < Double(stream.count) / 16_000)
    }
}
```

The speech test runs `/usr/bin/say` headless (no window) and is skipped where it is absent.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --package-path macos --filter 'MediaAudioDecoderTests|SherpaSileroSegmenterTests'`
Expected: build failure — `cannot find 'AVAssetMediaDecoder' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/Macomprendo/Services/MediaAudioDecoder.swift`:

```swift
import AVFoundation
import Foundation

/// A file opened for decoding: its length, and its audio as 16 kHz mono chunks.
struct DecodedAudio: Sendable {
    /// Seconds of the whole file, regardless of where decoding starts.
    let duration: TimeInterval
    /// Where `chunks` begins, in seconds from the start of the file.
    let startOffset: TimeInterval
    let chunks: AsyncThrowingStream<[Float], Error>
}

protocol MediaAudioDecoding: Sendable {
    /// Opens the first audio track of `url` and decodes it from `start` seconds on.
    func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio
}

/// AVFoundation decoding: anything QuickTime Player opens, audio or video, resampled and
/// downmixed by `AVAssetReader` itself so the whole file is never held in memory.
struct AVAssetMediaDecoder: MediaAudioDecoding {
    static let sampleRate = 16_000

    func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw MacomprendoError.mediaUnreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw MacomprendoError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MacomprendoError.mediaUnreadable(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MacomprendoError.mediaUnreadable("the audio track cannot be converted")
        }
        reader.add(output)
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: .positiveInfinity)
        guard reader.startReading() else {
            throw MacomprendoError.mediaUnreadable(
                reader.error?.localizedDescription ?? "decoding could not start")
        }

        let box = ReaderBox(reader: reader, output: output)
        let chunks = AsyncThrowingStream<[Float], Error> { continuation in
            let task = Task.detached {
                do {
                    while let samples = try box.next() {
                        try Task.checkCancellation()
                        if !samples.isEmpty { continuation.yield(samples) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.cancel()
            }
        }
        let seconds = duration.seconds
        return DecodedAudio(duration: seconds.isFinite ? seconds : 0,
                            startOffset: max(0, start),
                            chunks: chunks)
    }
}

/// `AVAssetReader` is not `Sendable`; this box is only touched by the decoding task and by
/// `cancel()`, which `AVAssetReader.cancelReading()` documents as safe from another thread.
private final class ReaderBox: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    /// The next buffer's samples; `nil` at the end of the file.
    func next() throws -> [Float]? {
        guard let buffer = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MacomprendoError.mediaUnreadable(
                    reader.error?.localizedDescription ?? "decoding failed")
            }
            return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                       destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            throw MacomprendoError.mediaUnreadable("a decoded buffer could not be read")
        }
        return samples
    }

    func cancel() {
        reader.cancelReading()
    }
}
```

- [ ] **Step 4: Run green**

Run: `swift test --package-path macos --filter 'MediaAudioDecoderTests|SherpaSileroSegmenterTests'`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
npm run gen
git add macos/Sources/Macomprendo/Services/MediaAudioDecoder.swift \
        macos/Tests/MacomprendoTests/Services/MediaAudioDecoderTests.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(transcripts): decode any audio or video file to 16 kHz mono"
```

---

### Task 5: Transcript store

**Files:**
- Create: `macos/Sources/Macomprendo/Services/TranscriptStore.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptStore.swift`
- Test: `macos/Tests/MacomprendoTests/Services/TranscriptStoreTests.swift` (create)

**Interfaces:**
- Consumes: Task 1 types, `MacomprendoError.transcriptStore`, `TranscriptionRun.unknownAppVersion`
  (`macos/Sources/Macomprendo/Services/TranscriptionRunDerivation.swift:12`).
- Produces: `protocol TranscriptStoring: Sendable` (methods below), `actor SQLiteTranscriptStore`
  with `init(databaseURL:)`, and the test double `FakeTranscriptStore`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/MacomprendoTests/Services/TranscriptStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptStoreTests {
    private let run = TranscriptionRun(modelID: "base", engine: "whisperCpp", language: "ru",
                                       appVersion: "1.2.3")

    private func makeStore() -> (SQLiteTranscriptStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)
        return (SQLiteTranscriptStore(databaseURL: directory.appendingPathComponent("t.sqlite3")),
                directory)
    }

    @Test func aCreatedTranscriptReadsBackWithItsSegmentsInOrder() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = try await store.create(sourceKind: .file, title: "talk.m4a",
                                        sourceBookmark: Data([1, 2, 3]), duration: 61.5,
                                        run: run, at: Date(timeIntervalSince1970: 1000))
        try await store.appendSegment(TranscriptSegment(start: 0.5, end: 3, text: "One."), to: id)
        try await store.appendSegment(
            TranscriptSegment(start: 4, end: 9, text: "Two pytest.", rawText: "Two пайтест."),
            to: id)

        let transcript = try #require(try await store.transcript(id: id))
        #expect(transcript.header == TranscriptHeader(
            id: id, createdAt: Date(timeIntervalSince1970: 1000), sourceKind: .file,
            title: "talk.m4a", duration: 61.5, status: .inProgress, statusReason: nil))
        #expect(transcript.run == run)
        #expect(transcript.sourceBookmark == Data([1, 2, 3]))
        #expect(transcript.summary == nil)
        #expect(transcript.segments == [
            TranscriptSegment(start: 0.5, end: 3, text: "One."),
            TranscriptSegment(start: 4, end: 9, text: "Two pytest.", rawText: "Two пайтест."),
        ])
    }

    @Test func statusAndReasonTransition() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: nil, run: run, at: .now)

        try await store.setStatus(.incomplete, reason: "Cancelled.", for: id)
        var header = try #require(try await store.headers().first)
        #expect(header.status == .incomplete)
        #expect(header.statusReason == "Cancelled.")
        #expect(header.duration == nil)

        // A reason is meaningless for any other status and is not kept.
        try await store.setStatus(.complete, reason: "ignored", for: id)
        header = try #require(try await store.headers().first)
        #expect(header.status == .complete)
        #expect(header.statusReason == nil)
    }

    @Test func headersAreNewestFirst() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for title in ["first", "second", "third"] {
            _ = try await store.create(sourceKind: .file, title: title, sourceBookmark: nil,
                                       duration: 1, run: run, at: .now)
        }
        #expect(try await store.headers().map(\.title) == ["third", "second", "first"])
    }

    @Test func summaryIsStoredAndCleared() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        try await store.setSummary("In short.", for: id)
        #expect(try await store.transcript(id: id)?.summary == "In short.")
        try await store.setSummary(nil, for: id)
        #expect(try await store.transcript(id: id)?.summary == nil)
    }

    @Test func deletingATranscriptDeletesItsSegments() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        try await store.appendSegment(TranscriptSegment(start: 0, end: 1, text: "x"), to: id)
        try await store.delete(id: id)
        #expect(try await store.transcript(id: id) == nil)
        #expect(try await store.headers().isEmpty)

        // A new transcript never inherits the deleted one's segments.
        let next = try await store.create(sourceKind: .file, title: "b", sourceBookmark: nil,
                                          duration: 1, run: run, at: .now)
        #expect(try await store.transcript(id: next)?.segments.isEmpty == true)
    }

    @Test func abandonedJobsBecomeIncompleteAndFinishedOnesStay() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let running = try await store.create(sourceKind: .file, title: "running",
                                             sourceBookmark: nil, duration: 1, run: run, at: .now)
        let done = try await store.create(sourceKind: .file, title: "done",
                                          sourceBookmark: nil, duration: 1, run: run, at: .now)
        try await store.setStatus(.complete, reason: nil, for: done)

        try await store.markAbandonedJobs(reason: "Macomprendo quit before it finished.")

        #expect(try await store.transcript(id: running)?.header.status == .incomplete)
        #expect(try await store.transcript(id: running)?.header.statusReason
                == "Macomprendo quit before it finished.")
        #expect(try await store.transcript(id: done)?.header.status == .complete)
    }

    @Test func updatingAMissingTranscriptIsAnError() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: MacomprendoError.transcriptStore("no transcript has identifier 42")) {
            try await store.setStatus(.complete, reason: nil, for: 42)
        }
    }

    @Test func aSecondStoreOnTheSameFileSeesTheData() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "kept", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        let reopened = SQLiteTranscriptStore(
            databaseURL: directory.appendingPathComponent("t.sqlite3"))
        #expect(try await reopened.transcript(id: id)?.header.title == "kept")
    }
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --package-path macos --filter TranscriptStoreTests`
Expected: build failure — `cannot find 'SQLiteTranscriptStore' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/Macomprendo/Services/TranscriptStore.swift`:

```swift
import Foundation
import SQLite3

protocol TranscriptStoring: Sendable {
    /// Creates an `inProgress` transcript and returns its identifier.
    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) async throws -> Int64
    func appendSegment(_ segment: TranscriptSegment, to id: Int64) async throws
    /// `reason` is stored only for `incomplete`, and must hold no transcript text.
    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) async throws
    func setSummary(_ summary: String?, for id: Int64) async throws
    /// Every transcript, newest first.
    func headers() async throws -> [TranscriptHeader]
    func transcript(id: Int64) async throws -> Transcript?
    func delete(id: Int64) async throws
    /// Turns every `inProgress` transcript into `incomplete`. Called once at launch, when no
    /// job can be running, so any `inProgress` row belongs to a job the app did not finish.
    func markAbandonedJobs(reason: String) async throws
}

/// Transcripts in their own database, apart from dictation history (ADR-0016).
actor SQLiteTranscriptStore: TranscriptStoring {
    private let databaseURL: URL
    private var handle: TranscriptDatabaseHandle?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) throws -> Int64 {
        let db = try connection()
        let statement = try prepare("""
            INSERT INTO transcripts
                (created_at, source_kind, title, source_bookmark, duration_s, status,
                 model_id, engine, language, app_version)
            VALUES (?1, ?2, ?3, ?4, ?5, 'inProgress', ?6, ?7, ?8, ?9)
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, at.timeIntervalSince1970), on: db)
        try bind(sourceKind.rawValue, 2, statement, db)
        try bind(title, 3, statement, db)
        try bind(sourceBookmark, 4, statement, db)
        try bind(duration, 5, statement, db)
        try bind(run.modelID, 6, statement, db)
        try bind(run.engine, 7, statement, db)
        try bind(run.language, 8, statement, db)
        try bind(run.appVersion, 9, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        return sqlite3_last_insert_rowid(db)
    }

    func appendSegment(_ segment: TranscriptSegment, to id: Int64) throws {
        let db = try connection()
        let statement = try prepare("""
            INSERT INTO transcript_segments (transcript_id, start_s, end_s, text, raw_text)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        try check(sqlite3_bind_double(statement, 2, segment.start), on: db)
        try check(sqlite3_bind_double(statement, 3, segment.end), on: db)
        try bind(segment.text, 4, statement, db)
        try bind(segment.rawText, 5, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) throws {
        let db = try connection()
        let statement = try prepare(
            "UPDATE transcripts SET status = ?1, status_reason = ?2 WHERE id = ?3", on: db)
        defer { sqlite3_finalize(statement) }
        try bind(status.rawValue, 1, statement, db)
        try bind(status == .incomplete ? reason : nil, 2, statement, db)
        try check(sqlite3_bind_int64(statement, 3, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        try requireOneChange(id, on: db)
    }

    func setSummary(_ summary: String?, for id: Int64) throws {
        let db = try connection()
        let statement = try prepare("UPDATE transcripts SET summary = ?1 WHERE id = ?2", on: db)
        defer { sqlite3_finalize(statement) }
        try bind(summary, 1, statement, db)
        try check(sqlite3_bind_int64(statement, 2, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        try requireOneChange(id, on: db)
    }

    func headers() throws -> [TranscriptHeader] {
        let db = try connection()
        let statement = try prepare("""
            SELECT id, created_at, source_kind, title, duration_s, status, status_reason
            FROM transcripts ORDER BY id DESC
            """, on: db)
        defer { sqlite3_finalize(statement) }
        var result: [TranscriptHeader] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try check(step, expected: SQLITE_ROW, on: db)
            result.append(try header(from: statement))
        }
        return result
    }

    func transcript(id: Int64) throws -> Transcript? {
        let db = try connection()
        let statement = try prepare("""
            SELECT id, created_at, source_kind, title, duration_s, status, status_reason,
                   source_bookmark, summary, model_id, engine, language, app_version
            FROM transcripts WHERE id = ?1
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        try check(step, expected: SQLITE_ROW, on: db)

        let header = try header(from: statement)
        let run = TranscriptionRun(modelID: text(statement, 9), engine: text(statement, 10),
                                   language: text(statement, 11),
                                   appVersion: text(statement, 12) ?? TranscriptionRun.unknownAppVersion)
        return Transcript(header: header, run: run, sourceBookmark: data(statement, 7),
                          summary: text(statement, 8), segments: try segments(of: id, on: db))
    }

    func delete(id: Int64) throws {
        let db = try connection()
        // Segments go with their transcript through ON DELETE CASCADE.
        let statement = try prepare("DELETE FROM transcripts WHERE id = ?1", on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    func markAbandonedJobs(reason: String) throws {
        let db = try connection()
        let statement = try prepare("""
            UPDATE transcripts SET status = 'incomplete', status_reason = ?1
            WHERE status = 'inProgress'
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try bind(reason, 1, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    // MARK: - Rows

    private func header(from statement: OpaquePointer) throws -> TranscriptHeader {
        guard let kind = text(statement, 2).flatMap(TranscriptSourceKind.init(rawValue:)),
              let title = text(statement, 3),
              let status = text(statement, 5).flatMap(TranscriptStatus.init(rawValue:))
        else {
            throw MacomprendoError.transcriptStore("a stored transcript is invalid")
        }
        let duration: TimeInterval? = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 4)
        return TranscriptHeader(
            id: sqlite3_column_int64(statement, 0),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            sourceKind: kind, title: title, duration: duration, status: status,
            statusReason: text(statement, 6))
    }

    private func segments(of id: Int64, on db: OpaquePointer) throws -> [TranscriptSegment] {
        let statement = try prepare("""
            SELECT start_s, end_s, text, raw_text FROM transcript_segments
            WHERE transcript_id = ?1 ORDER BY start_s, id
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        var result: [TranscriptSegment] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try check(step, expected: SQLITE_ROW, on: db)
            result.append(TranscriptSegment(start: sqlite3_column_double(statement, 0),
                                            end: sqlite3_column_double(statement, 1),
                                            text: text(statement, 2) ?? "",
                                            rawText: text(statement, 3)))
        }
        return result
    }

    // MARK: - SQLite

    private func connection() throws -> OpaquePointer {
        if let handle { return handle.pointer }
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw MacomprendoError.transcriptStore(error.localizedDescription)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw MacomprendoError.transcriptStore(message)
        }
        do {
            try execute("PRAGMA foreign_keys = ON", on: opened)
            try execute("""
                CREATE TABLE IF NOT EXISTS transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'call')),
                    title TEXT NOT NULL,
                    source_bookmark BLOB,
                    duration_s REAL,
                    status TEXT NOT NULL
                        CHECK(status IN ('inProgress', 'complete', 'incomplete')),
                    status_reason TEXT,
                    model_id TEXT,
                    engine TEXT,
                    language TEXT,
                    app_version TEXT,
                    summary TEXT
                );
                CREATE TABLE IF NOT EXISTS transcript_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    transcript_id INTEGER NOT NULL
                        REFERENCES transcripts(id) ON DELETE CASCADE,
                    start_s REAL NOT NULL,
                    end_s REAL NOT NULL,
                    text TEXT NOT NULL,
                    raw_text TEXT
                );
                CREATE INDEX IF NOT EXISTS transcript_segments_by_start
                    ON transcript_segments (transcript_id, start_s);
                PRAGMA user_version = 1;
                """, on: opened)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
        handle = TranscriptDatabaseHandle(opened)
        return opened
    }

    private func requireOneChange(_ id: Int64, on db: OpaquePointer) throws {
        guard sqlite3_changes(db) == 1 else {
            throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
        }
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil), on: db)
    }

    private func prepare(_ sql: String, on db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), on: db)
        guard let statement else { throw MacomprendoError.transcriptStore("no statement") }
        return statement
    }

    private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, index, value, -1, transient), on: db)
    }

    private func bind(_ value: Data?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        try check(result, on: db)
    }

    private func bind(_ value: Double?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        try check(sqlite3_bind_double(statement, index, value), on: db)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK,
                       on db: OpaquePointer) throws {
        guard result == expected else {
            throw MacomprendoError.transcriptStore(String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// Closes the connection when the store goes away; a class so the actor needs no `deinit`.
private final class TranscriptDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}
```

- [ ] **Step 4: Add the fake later tasks use**

Create `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptStore.swift`: an `actor
FakeTranscriptStore: TranscriptStoring` keeping transcripts in a dictionary keyed by an
incrementing `Int64` starting at 1, with these test hooks:
`var failNextAppend: MacomprendoError?` (thrown once by `appendSegment`, then cleared),
`func snapshot(_ id: Int64) -> Transcript?`, and `var createCount: Int`. Its behaviour must
match the SQLite store on every point `TranscriptStoreTests` pins: newest-first `headers()`,
`reason` kept only for `.incomplete`, `transcriptStore("no transcript has identifier N")` when
`setStatus`/`setSummary` hit a missing id, and `markAbandonedJobs` touching only `inProgress`.

- [ ] **Step 5: Run green and commit**

```bash
swift test --package-path macos --filter TranscriptStoreTests
npm run gen
git add macos/Sources/Macomprendo/Services/TranscriptStore.swift \
        macos/Tests/MacomprendoTests/Services/TranscriptStoreTests.swift \
        macos/Tests/MacomprendoTests/Fakes/FakeTranscriptStore.swift \
        macos/Macomprendo.xcodeproj
git commit -m "feat(transcripts): SQLite transcript store"
```

---

### Task 6: TranscriptionLane — dictation overtakes a file job

**Files:**
- Create: `macos/Sources/Macomprendo/Providers/TranscriptionLane.swift`
- Test: `macos/Tests/MacomprendoTests/Providers/TranscriptionLaneTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptionProvider` (`macos/Sources/Macomprendo/Providers/TranscriptionProvider.swift:5`).
- Produces:

```swift
actor TranscriptionLane {
    enum Priority: Sendable { case interactive, background }
    /// Runs `body` when the lane is free. Callers waiting with `.interactive` are always
    /// resumed before callers waiting with `.background`; within one priority, first come
    /// first served. A caller cancelled while waiting throws `CancellationError` without
    /// running `body` and without blocking the callers behind it.
    func run<T: Sendable>(_ priority: Priority,
                          _ body: @Sendable () async throws -> T) async throws -> T
}

/// A provider whose every call goes through a lane at a fixed priority.
struct LaneTranscriptionProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    let lane: TranscriptionLane
    let priority: TranscriptionLane.Priority
}
```

Near neighbour, and why it does not cover this: `LocalTranscriptionProviderCache.Lease`
(`LocalTranscriptionProviderCache.swift:26-42`) counts active calls only for idle eviction; it
neither serialises nor orders them. `SherpaOfflineTranscriber` is an actor, which serialises
but in no guaranteed order, and `WhisperCppTranscriber` makes no ordering promise either. Do
not change either type in this task.

Implementation notes the tests pin: the lane is reentrant (an actor awaiting `body`), so it
keeps an explicit `busy` flag and two FIFO arrays of waiters; releasing hands the lane directly
to the next waiter (interactive queue first) rather than clearing `busy`, so a newcomer cannot
slip in between. Cancellation while waiting uses `withTaskCancellationHandler`; the handler
removes the waiter by identifier and resumes it with `CancellationError`. `body` throwing still
releases the lane.

- [ ] **Step 1: Write the failing tests** — `TranscriptionLaneTests` (a `@Suite struct`), using
  `AsyncGate` (`macos/Tests/MacomprendoTests/Support/AsyncGate.swift`) and
  `FakeTranscriptionProvider` (its `gate` property):
  1. `aSingleCallRunsAndReturnsItsResult` — happy path through `LaneTranscriptionProvider`.
  2. `callsNeverOverlap` — two background calls; the second's body does not start until the
     first's gate opens (assert with a counter of concurrently running bodies, max 1).
  3. `aWaitingInteractiveCallGoesBeforeAWaitingBackgroundCall` — hold the lane with a gated
     background call; enqueue background B, then interactive I; open the gate; record order
     `[holder, I, B]`.
  4. `aCancelledWaiterThrowsAndDoesNotBlockTheNext` — hold the lane; enqueue W1 (task to be
     cancelled) and W2; cancel W1; W1 throws `CancellationError`; open; W2 runs.
  5. `aThrowingBodyReleasesTheLane` — first body throws `MacomprendoError.audio("x")`; the next
     call still runs.
- [ ] **Step 2: Run them and see them fail** — `swift test --package-path macos --filter TranscriptionLaneTests`; expected: `cannot find 'TranscriptionLane' in scope`.
- [ ] **Step 3: Implement** `TranscriptionLane.swift` as specified above.
- [ ] **Step 4: Run green**, 5 tests.
- [ ] **Step 5: Commit** — `npm run gen`; `git add` the two files and `macos/Macomprendo.xcodeproj`; `feat(transcripts): lane that lets dictation overtake file segments`.

---

### Task 7: File bookmarks

**Files:**
- Create: `macos/Sources/Macomprendo/Services/FileBookmarks.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeFileBookmarks.swift`
- Test: `macos/Tests/MacomprendoTests/Services/FileBookmarksTests.swift` (create)

**Interfaces:**
- Produces:

```swift
protocol FileBookmarking: Sendable {
    func bookmark(for url: URL) throws -> Data
    /// Throws `MacomprendoError.sourceFileUnavailable` when the data no longer resolves to an
    /// existing file.
    func resolve(_ bookmark: Data) throws -> URL
}
struct FoundationFileBookmarks: FileBookmarking   // URL.bookmarkData(options: []) /
                                                  // URL(resolvingBookmarkData:bookmarkDataIsStale:)
```

The app is not sandboxed (`com.apple.security.app-sandbox` is `false` in
`macos/AppBundle/Macomprendo.entitlements`), so plain bookmarks — not security-scoped ones — are correct.
`FakeFileBookmarks` maps `Data(url.path.utf8)` back to the URL and throws
`sourceFileUnavailable` for anything in a `missing: Set<String>` of paths.

- [ ] **Step 1: Failing tests** — `FileBookmarksTests`: (1) `aBookmarkResolvesToTheSameFile`
  (temp file round trip, compare `standardizedFileURL.path`); (2) `aBookmarkFollowsAMovedFile`
  (move the file within the temp dir after bookmarking; resolves to the new path);
  (3) `aDeletedFileIsUnavailable` (delete, resolve → `.sourceFileUnavailable`);
  (4) `garbageDataIsUnavailable`.
- [ ] **Step 2: See them fail** — `swift test --package-path macos --filter FileBookmarksTests`.
- [ ] **Step 3: Implement**; resolution also checks `FileManager.default.fileExists(atPath:)`.
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `npm run gen`; add the three files and the project; `feat(transcripts): bookmark source files for resume`.

---

### Task 8: LongAudioPipeline

**Files:**
- Create: `macos/Sources/Macomprendo/Features/LongAudioPipeline.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedMediaDecoder.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedSegmenter.swift`
- Test: `macos/Tests/MacomprendoTests/Features/LongAudioPipelineTests.swift` (create)

**Interfaces:**
- Consumes: `MediaAudioDecoding`/`DecodedAudio` (Task 4), `SpeechSegmenting`/`SpeechSegment`
  (Task 3), `TranscriptionProvider`.
- Produces:

```swift
enum LongAudioEvent: Sendable, Equatable {
    /// Once, first: the whole file's duration.
    case opened(duration: TimeInterval)
    /// A transcribed segment, timed from the start of the FILE (decoder `startOffset` added).
    /// `text` is the provider's output trimmed of whitespace; never empty — empty results
    /// are not emitted.
    case segment(start: TimeInterval, end: TimeInterval, text: String)
    /// After each decoded chunk: seconds from the start of the file decoded so far.
    case position(TimeInterval)
}

struct LongAudioPipeline: Sendable {
    init(decoder: any MediaAudioDecoding,
         segmenter: any SpeechSegmenting,
         transcriber: @escaping @Sendable () async throws -> any TranscriptionProvider,
         language: String?,
         retryDelay: Duration = .seconds(1),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })

    /// Finishes normally at the end of the file. Throws the decoder's or segmenter's error,
    /// or the provider's error after three attempts. Terminating the stream (the consumer's
    /// task cancelled) cancels decoding and transcription.
    func run(_ url: URL, from start: TimeInterval) -> AsyncThrowingStream<LongAudioEvent, Error>
}
```

Rules the tests pin: the provider is obtained once per run via `transcriber()`; each segment
is sent as `transcribe(segment.samples, sampleRate: 16_000, language: language)`; a failing
call is retried after `retryDelay` up to two more times; `CancellationError` and
`MacomprendoError.cancelled` are never retried; the segmenter session is created inside the
stream's task (sessions are not `Sendable`); after the decoder's stream ends, `finish()` is
drained like `accept`.

Fakes: `ScriptedMediaDecoder` — `duration`, `chunks: [[Float]]`, optional `openError`, and
records every `(url, start)` it was asked for; it reports `startOffset = start`.
`ScriptedSegmenter` — a list of `[SpeechSegment]` returned by successive `accept` calls (empty
once exhausted) and a list returned by `finish()`.

- [ ] **Step 1: Failing tests** — `LongAudioPipelineTests`:
  1. `emitsOpenedSegmentsAndPositionsInOrder` — happy path: 2 chunks of 16,000 samples, one
     segment per chunk; expect `[.opened(10), .segment(…), .position(1), .segment(…), .position(2)]`.
  2. `segmentTimesIncludeTheResumeOffset` — `run(url, from: 120)`; a segment at 2 s is emitted
     at 122 s.
  3. `emptyTranscriptionsAreNotEmitted` — provider returns `"  "`; no `.segment`, positions still
     emitted.
  4. `aFailingSegmentIsRetriedTwiceThenThrows` — provider always throws `.providerUnreachable`;
     3 calls recorded, two sleeps of `retryDelay`, stream throws that error.
  5. `aSegmentThatSucceedsOnRetryIsEmitted` — first call throws, second succeeds.
  6. `cancellationIsNotRetried` — provider throws `CancellationError`; 1 call.
  7. `aDecoderOpenErrorIsThrownBeforeAnyEvent` — `openError = .noAudioTrack`.
  8. `finishDrainsTheLastSegment` — segment only from `finish()`; it is emitted.
- [ ] **Step 2: See them fail** — `swift test --package-path macos --filter LongAudioPipelineTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `npm run gen`; add the four files and the project; `feat(transcripts): long-audio pipeline`.

---

### Task 9: FileTranscriptionController

**Files:**
- Create: `macos/Sources/Macomprendo/Features/FileTranscriptionController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/FileTranscriptionControllerTests.swift` (create, `@MainActor @Suite`)

**Interfaces:**
- Consumes: `LongAudioPipeline` (Task 8), `TranscriptStoring` + `FakeTranscriptStore` (Task 5),
  `FileBookmarking` + `FakeFileBookmarks` (Task 7), `BackendReadiness`
  (`macos/Sources/Macomprendo/Features/BackendReadiness.swift:28`), `Normalizer.normalise(_:with:)`
  (`macos/Sources/Macomprendo/Core/Normalizer.swift:69`), `Glossary`, `Settings`
  (`glossaryEnabled`, `transcriptionSource`, `transcriptionLanguage`),
  `TranscriptionRun.from(_:language:)` (`macos/Sources/Macomprendo/Services/TranscriptionRunDerivation.swift:23`),
  `ErrorText.describe(_:)`.
- Produces:

```swift
@MainActor final class FileTranscriptionController: ObservableObject {
    enum State: Equatable {
        case idle
        case running(transcriptID: Int64, title: String, position: TimeInterval, duration: TimeInterval)
        case finished(transcriptID: Int64)
        case failed(message: String, transcriptID: Int64?)
    }
    @Published private(set) var state: State

    init(store: any TranscriptStoring,
         bookmarks: any FileBookmarking,
         pipeline: @escaping @MainActor () -> LongAudioPipeline,
         settings: @escaping @MainActor () -> Settings,
         glossary: @escaping @MainActor () -> Glossary,
         readiness: @escaping @MainActor () -> BackendReadiness,
         now: @escaping () -> Date = Date.init,
         transcriptsChanged: @escaping @MainActor () -> Void = {})

    func transcribe(fileAt url: URL)      // cancels any running job first
    func resume(transcriptID: Int64)      // cancels any running job first
    func cancel()
    func drain() async                    // awaits the in-flight job; tests only
}
```

Behaviour (spec § Pipeline, § Interruption and resume):
- Readiness not `.ready` → `.failed(message: <its reason>, transcriptID: nil)`, no row created.
- `transcribe`: bookmark the URL (failure → no bookmark, not an error), wait for `.opened`, then
  `store.create(sourceKind: .file, title: url.lastPathComponent, …, duration:, run: TranscriptionRun.from(settings.transcriptionSource, language: settings.transcriptionLanguage), at: now())`.
  A decoder error before `.opened` → `.failed(message:, transcriptID: nil)` and no row.
- Each `.segment`: normalise when `settings().glossaryEnabled` (store `rawText` only when the
  normalisation made rewrites), `appendSegment`, call `transcriptsChanged()`. Each `.position`
  updates `state`.
- End of stream: zero segments stored for a fresh job → `store.delete`, `.failed(noSpeechFound)`;
  otherwise `setStatus(.complete)` and `.finished`.
- Any thrown error after the row exists, including cancellation: `setStatus(.incomplete,
  reason: ErrorText.describe(error))` (cancellation's reason is `"Cancelled."`), state
  `.failed(message:, transcriptID:)` — for cancellation, state returns to `.idle` instead.
- `resume`: load the transcript; `bookmarks.resolve` it (failure →
  `.failed(sourceFileUnavailable)`); set status back to `.inProgress`; run the pipeline
  `from: transcript.resumePosition`; same rules, except a resumed job that adds no segment still
  ends `.complete` (its earlier segments exist).
- Never log segment text.

- [ ] **Step 1: Failing tests** — happy path (`aFileBecomesACompleteTranscriptWithNormalisedSegments`);
  `progressFollowsPositions`; `aBackendThatIsNotReadyFailsWithoutCreatingARow`;
  `anOpenErrorFailsWithoutCreatingARow`; `noSpeechDeletesTheTranscriptAndFails`;
  `cancelKeepsSegmentsAndMarksIncomplete`; `aNewJobCancelsTheRunningOne`;
  `aSegmentFailureMarksIncompleteWithTheErrorText`; `resumeContinuesFromTheLastSegmentEnd`
  (assert the decoder was asked for `from: <last end>` and the new segments are appended);
  `resumeWithAMissingFileFails`; `rawTextIsKeptOnlyWhenNormalisationRewrote`.
  Build the pipeline from `ScriptedMediaDecoder`, `ScriptedSegmenter`, `FakeTranscriptionProvider`
  with `sleep: { _ in }`. Use `drain()` rather than sleeps.
- [ ] **Step 2: See them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `npm run gen`; `feat(transcripts): file transcription controller`.

---

### Task 10: TranscriptLibraryController

**Files:**
- Create: `macos/Sources/Macomprendo/Features/TranscriptLibraryController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/TranscriptLibraryControllerTests.swift` (create, `@MainActor @Suite`)

**Interfaces:**
- Consumes: `TranscriptStoring`, `PasteboardProtocol` (+ `FakePasteboard`), `TranscriptExporter`.
- Produces:

```swift
@MainActor final class TranscriptLibraryController: ObservableObject {
    @Published private(set) var headers: [TranscriptHeader]
    @Published private(set) var selected: Transcript?
    @Published private(set) var error: String?
    init(store: any TranscriptStoring, pasteboard: any PasteboardProtocol)
    func reload() async                 // headers; refreshes `selected` if it still exists
    func select(_ id: Int64?) async
    func delete(_ id: Int64) async      // clears `selected` when it was the deleted one
    func copySelected()                 // plain text, no timestamps
    func exportText(_ format: TranscriptExportFormat) -> String?   // nil with nothing selected
    func performLaunchMaintenance() async   // markAbandonedJobs("Macomprendo quit before it finished.")
}
```

Store errors land in `error` as `ErrorText.describe(error)`; nothing throws to the view.

- [ ] **Step 1: Failing tests** — reload lists newest first; select loads segments; reload after
  a segment append refreshes `selected`; delete of the selected clears it; copy writes
  `plainText`; export renders through `TranscriptExporter`; launch maintenance marks abandoned
  jobs; a store failure sets `error`.
- [ ] **Steps 2–4:** see fail, implement, green.
- [ ] **Step 5: Commit** — `npm run gen`; `feat(transcripts): transcript library controller`.

---

### Task 11: TranscriptSummaryController

**Files:**
- Create: `macos/Sources/Macomprendo/Features/TranscriptSummaryController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/TranscriptSummaryControllerTests.swift` (create, `@MainActor @Suite`)

**Interfaces:**
- Consumes: `LLMTarget` (`macos/Sources/Macomprendo/Features/LLMTarget.swift:4`),
  `PromptRenderer.render(_:text:instruction:language:chosenLanguage:)`
  (`macos/Sources/Macomprendo/Features/Prompts/PromptRenderer.swift:55`),
  `PromptRenderer.validate(_:)`, `ChatOptions()`, `TranscriptChunker`, `TranscriptStoring`,
  `ScriptedLLMProvider` + `LLMCallRecorder` (`macos/Tests/MacomprendoTests/Fakes/ScriptedLLMProvider.swift`).
- Produces:

```swift
@MainActor final class TranscriptSummaryController: ObservableObject {
    @Published private(set) var text: String
    @Published private(set) var isRunning: Bool
    @Published private(set) var progress: String?     // "Summarizing part 2 of 3…" while mapping
    @Published private(set) var error: String?
    init(store: any TranscriptStoring,
         llm: @escaping @MainActor () throws -> LLMTarget,
         preset: @escaping @MainActor () -> PromptPreset?,
         language: @escaping @MainActor () -> String,
         chosenLanguage: @escaping @MainActor () -> String,
         partLimit: Int = TranscriptChunker.defaultLimit)
    func show(_ transcript: Transcript?)   // text = stored summary or ""
    func summarize(_ transcript: Transcript)
    func cancel()
    func drain() async
}
```

Rules: parts = `TranscriptChunker.parts(of: transcript.segments, limit: partLimit)`. One part →
stream the reply into `text`. Several parts → each part's reply collected in full (no streaming
into `text`, `progress` updated), then the part replies joined by `"\n\n"` are sent once more and
streamed into `text`. Every request renders the same preset with `instruction: nil`. On success
`store.setSummary(text, for:)`. Cancel or failure restores `text` to the previously stored
summary and leaves the store untouched; failure sets `error`. No preset → `error =
ErrorText.describe(FeatureConfigError.noPreset(.summarize))`.

AppModel wiring (Task 12) passes `llm: { try self.llmTarget(for: .summarize) }`,
`preset: { settings.defaultPreset(for: .summarize, language: settings.promptLanguage) }`,
`language: { RefineController.uiLanguageName() }`, and `chosenLanguage:` exactly as
`SummarizeController.runStream` computes it (`SummarizeController.swift:90-92`).

- [ ] **Step 1: Failing tests** — `aShortTranscriptIsOneStreamedRequest` (1 call, text = deltas
  joined, summary stored); `aLongTranscriptIsMappedThenReduced` (`partLimit` small; N+1 calls,
  the last call's user message contains each part reply); `cancelKeepsThePreviousSummary`
  (use `ScriptedLLMProvider.gate`); `aFailureSetsErrorAndKeepsThePreviousSummary`;
  `noPresetIsAnError`.
- [ ] **Steps 2–4:** see fail, implement, green.
- [ ] **Step 5: Commit** — `npm run gen`; `feat(transcripts): map-reduce transcript summary`.

---

### Task 12: Wiring into AppEnvironment and AppModel

**Files:**
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` (stored properties lines 21–57; `live()` lines 60–119)
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift` (parameters and initialiser call)
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` (transcriber closure lines 165–189; `start()` lines 234–250)
- Modify: `macos/Sources/Macomprendo/Core/WindowID.swift:7-10`
- Modify: `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift:8-13`
- Test: `macos/Tests/MacomprendoTests/Core/WindowIDTests.swift`, `macos/Tests/MacomprendoTests/App/AppModelTests.swift`

**Interfaces:**
- `AppEnvironment` gains `transcriptStore: any TranscriptStoring`,
  `mediaDecoder: any MediaAudioDecoding`, `speechSegmenter: any SpeechSegmenting`,
  `fileBookmarks: any FileBookmarking`, `transcriptionLane: TranscriptionLane`. `live()` builds
  `SQLiteTranscriptStore(databaseURL: applicationSupportDirectory.appendingPathComponent("transcripts.sqlite3"))`,
  `AVAssetMediaDecoder()`, `SherpaSileroSegmenter()`, `FoundationFileBookmarks()`,
  `TranscriptionLane()`. `AppEnvironment.fake(...)` gains defaulted parameters
  `transcriptStore: FakeTranscriptStore()`, `mediaDecoder: ScriptedMediaDecoder()`,
  `speechSegmenter: ScriptedSegmenter()`, `fileBookmarks: FakeFileBookmarks()`,
  `transcriptionLane: TranscriptionLane()`.
- `AppModel`: the existing `transcriberProvider` closure wraps the cached local provider in
  `LaneTranscriptionProvider(base:, lane: env.transcriptionLane, priority: .interactive)`; a new
  `backgroundTranscriberProvider` is the same closure with `.background`. Endpoint providers are
  not wrapped (concurrent remote requests are fine). AppModel owns `lazy var fileTranscription:
  FileTranscriptionController`, `lazy var transcriptLibrary: TranscriptLibraryController`,
  `lazy var transcriptSummary: TranscriptSummaryController`, with `readiness: { self.dictationTabModel.readiness }`
  (`DictationTabModel.swift:217`) and `transcriptsChanged: { Task { await self.transcriptLibrary.reload() } }`.
  `start()` runs `transcriptLibrary.performLaunchMaintenance()` once, before anything else can
  start a job.
- `WindowID.transcripts = "transcripts"`; `DockIconCoordinator.Owner.transcripts`.

- [ ] **Step 1: Failing tests** — `WindowIDTests` asserts `WindowID.transcripts == "transcripts"`
  and distinctness; `AppModelTests` (find its suite declaration first and keep its isolation):
  `dictationTranscriberGoesThroughTheLaneAtInteractivePriority` (local source; the provider
  returned is a `LaneTranscriptionProvider` with `.interactive`),
  `fileTranscriberUsesBackgroundPriority`, `anEndpointSourceIsNotWrapped`,
  `startMarksAbandonedTranscriptsIncomplete` (seed `FakeTranscriptStore` with an `inProgress`
  row).
- [ ] **Steps 2–4:** see fail, implement, green — then the full suite: `npm run test:swift`.
- [ ] **Step 5: Commit** — `npm run gen`; `feat(transcripts): wire transcription services into the app`.

---

### Task 13: Transcripts window and menu item

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift`
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift` (add a `Window` scene after the Dictation History one, lines 64–78)
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift` (after `Dictation History…`, line 44)
- Modify: `macos/Sources/Macomprendo/Resources/Icons/icons.json` only if a new icon is needed
  (invariant 12: icons via `Icon(.case)`, never `Image(systemName:)`; adding one means
  `npm run sync-icons` and an `AppIcon` case with its `fallbackSymbol`).

**Interfaces:** consumes `model.fileTranscription`, `model.transcriptLibrary`,
`model.transcriptSummary`, `model.dockIcon`, `WindowID.transcripts`.

Layout (spec § Transcripts window): `NavigationSplitView`; sidebar = `transcriptLibrary.headers`
(title, date, `TranscriptExporter.clock(duration)`, a badge for `inProgress`/`incomplete`);
detail = progress row while `fileTranscription.state` is `.running` for this transcript
(`Transcribing — 12:40 / 58:03` + Cancel), summary block when non-empty, segments as
`[clock] text` rows, the run (model · engine · language), and the actions Copy, Export… (a
menu of `TranscriptExportFormat.allCases` → `NSSavePanel` with `allowedContentTypes` from the
extension → write `exportText`), Summarize, Resume (only `incomplete`), Delete (confirmation
dialog). Empty state = drop zone `Drop an audio or video file here`. `.dropDestination(for:
URL.self)` on the whole content starts `fileTranscription.transcribe(fileAt:)`. On appear:
`model.dockIcon.open(.transcripts)` and `await transcriptLibrary.reload()`; on disappear:
`dockIcon.close(.transcripts)`. Failures from `state` show inline, with `ErrorText` text.

Menu: `Button("Transcribe File…")` — `NSApp.activate(ignoringOtherApps: true)`, an `NSOpenPanel`
with `allowedContentTypes = [.audiovisualContent]`, then `openWindow(id: WindowID.transcripts)`
and `model.fileTranscription.transcribe(fileAt:)`; and `Button("Transcripts…")` opening the
window.

- [ ] **Step 1:** Implement; `swift build --package-path macos` with no new warnings; `npm run gen`.
- [ ] **Step 2: Eyeball check (a person at the Mac).** `npm run install-app:signed`, then hand
  Denis this list and wait for his answer: menu shows both items; transcribing a short mp3
  shows progress and then segments; a dropped mp4 works; Cancel leaves an `incomplete` row
  with Resume; Export writes each of the three formats; Summarize streams; the Dock icon shows
  while the window is open and goes when it closes.
- [ ] **Step 3: Commit** — `feat(transcripts): Transcripts window and menu items`.

---

### Task 14: Documents

**Files:**
- Create: `docs/adr/0015-long-audio-segmentation-with-silero-vad.md`
- Create: `docs/adr/0016-transcripts-store-separate-from-dictation-history.md`
- Modify: `docs/ARCHITECTURE.md` (new `### Long-audio transcription` section after `### Audio capture`, before `## Rules` at line 118)
- Modify: `docs/SMOKE_TEST.md` (append a *File transcription* section with the spec's smoke list)
- Modify: `CHANGELOG.md` (`## [Unreleased]`, line 7: an `### Added` entry)

Follow the shape of `docs/adr/0014-sherpa-offline-engine-rename-and-parakeet.md`. ADR-0015
records: bundled vs downloaded (and the catalog ripple that decided it), the measured failure of
`max_speech_duration`, the 30 s / 5 s / 0.3 s numbers. ADR-0016 records: separate database,
`source_kind` reserved for `call`, no retention, `markAbandonedJobs` at launch.

- [ ] **Step 1:** Write the five documents.
- [ ] **Step 2:** `npm run audit` (scans untracked files too).
- [ ] **Step 3: Commit** — `docs(transcripts): ADRs, architecture, smoke test and changelog`.

---

### Task 15: Final gates

- [ ] `npm run test:swift` and `npm run test:scripts` green.
- [ ] `npm run audit` green.
- [ ] `swift build --package-path macos` — no new warnings.
- [ ] `npm run gen` is a no-op (`git status --short macos/Macomprendo.xcodeproj` empty).
- [ ] Release `xcodebuild` succeeds and the built app contains
  `Contents/Resources/SpeechDetection/silero_vad.onnx`.
- [ ] `~/.local/bin/graphify update "$(git rev-parse --show-toplevel)"`.

## Spec coverage

| Spec section | Task |
|---|---|
| Entry points | 13 |
| Transcripts window | 10, 13 |
| Pipeline 1–6 | 8, 9 (preflight, store), 3–5 (decode, segment, store) |
| Sharing the local model with dictation | 6, 12 |
| Interruption and resume | 7, 9, 10 (launch maintenance) |
| Summary | 11, 12 |
| Export | 1, 13 |
| Errors | 2 |
| Store schema | 5 |
| VAD model, licence | 3 |
| Privacy | 9, 11 (no text in logs), Global Constraints |
| Testing, smoke | each task, 14 |
| Documents | 14 |
