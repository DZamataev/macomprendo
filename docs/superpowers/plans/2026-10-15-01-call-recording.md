# Call Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the microphone and all system audio into two `.m4a` files per call, then transcribe both into one speaker-labelled (Me / Others) transcript in the existing Transcripts window.

**Architecture:** Two capture services (raw `AVAudioEngine` microphone, Core Audio global process tap) deliver 48 kHz mono chunks stamped with host-clock seconds to one writer per track. A `@MainActor` `CallRecordingController` owns start/stop and the recording folder; on stop it creates a `call` transcript row and hands it to `FileTranscriptionController`, which learns a call job: each track through the unchanged `LongAudioPipeline`, segments shifted by the track's start offset and labelled with a speaker.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation (`AVAudioEngine`, `AVAssetWriter`, `AVAudioConverter`), Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, aggregate devices), SQLite3, swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-15-call-recording-design.md` — read it before your task; it is the authority. Where this plan and the spec disagree, the spec wins.

## Global Constraints

- Repository root: `~/dev/macomprendo`. Work on branch `call-recording` in that checkout (no worktree). Never push. Never commit to `main`.
- Swift sources: `macos/Sources/Macomprendo/<Layer>/`; tests mirror them under `macos/Tests/MacomprendoTests/<Layer>/`; fakes in `macos/Tests/MacomprendoTests/Fakes/`.
- Layers point downward only: UI → Features → Services/Providers → Core. Concrete services are constructed only in `App/AppEnvironment.swift`.
- Everything OS-facing sits behind a protocol declared in the same file as its default implementation, with a fake in `Tests/…/Fakes`.
- TDD: write the failing test first, run it, see it fail, then implement. Hardware glue (process tap, `AVAudioEngine`, IOProc) stays thin and gets `docs/SMOKE_TEST.md` lines instead of unit tests.
- Swift 6 strict concurrency: services are `Sendable` structs, actors, or `final class … @unchecked Sendable` guarding state with `NSLock`; controllers are `@MainActor`.
- Every user-visible failure is a `MacomprendoError` case with `errorDescription` and `recoverySuggestion`, plus a row in `MacomprendoErrorTests`.
- Never log transcript text, file names or folder names at default level (invariant 6). OSStatus codes and sample rates are fine at `.info`/`.error` with `privacy: .public`.
- Icons in views come from `Icon(.case)`; the menu bar status item is the one SF Symbol exception.
- Comments: only a non-obvious reason or trap; no restating code or the spec.
- Exact values (verbatim from the spec):
  - folder name `rec yyyy-MM-dd HH-mm-ss` in local time, collision suffix ` (2)`, ` (3)`…; track files `<folder name> Me.m4a`, `<folder name> Others.m4a`; manifest `recording.json`;
  - transcript title `Call yyyy-MM-dd HH:mm`;
  - default recordings folder `~/Library/Application Support/Macomprendo/Recordings`;
  - tracks: 48 kHz mono `Float32` in, AAC 48 kbit/s out, `.m4a` fragmented MP4 with `movieFragmentInterval` 1 s;
  - gaps shorter than 50 ms are not padded;
  - level rows: ten cells, `▮` filled, `▯` empty; refreshed every 100 ms;
  - abandoned reason `Macomprendo quit before it finished.` (`TranscriptLibraryController.abandonedJobReason`);
  - deployment target 14.2;
  - `Info.plist` key `NSAudioCaptureUsageDescription`.
- Test command for one suite: `swift test --package-path macos --filter <SuiteOrTypeName>`. Full: `npm run test:swift`. Build: `swift build --package-path macos` (no new warnings).
- Commit after each task with a conventional commit message (`feat(calls): …`, `test(calls): …`, `docs(calls): …`). Stage only the task's files.
- Reference implementation for the process tap (read, do not copy verbatim): `~/.hermes/cache/scratch/call-research/q_macos_Sources_quill_Audio_SystemAudioRecorder.swift` (quill, tap-only aggregate) and `~/.hermes/cache/scratch/call-research/a_ProcessTap.swift` (AudioCap).

## File map

| File | Task | Responsibility |
|---|---|---|
| `Core/Transcript.swift` (modify) | 1 | `TranscriptSpeaker`, `TranscriptSegment.speaker`, speaker-aware `plainText` |
| `Core/CallRecording.swift` (create) | 1 | `CallRecordingLayout`, `CallRecordingManifest` |
| `Core/MacomprendoError.swift` (modify) | 1 | four new cases |
| `Core/Settings.swift` (modify) | 1 | `callRecordingsDirectory` |
| `Services/TranscriptStore.swift` (modify) | 2 | schema v2, `speaker` column |
| `Core/TranscriptExporter.swift` (modify) | 3 | speaker labels in txt/srt/md |
| `Services/CallTrackWriter.swift` (create) | 4 | `TrackTimeline`, `CallAudioSink`, `CallTrackWriting`, `AssetCallTrackWriter`, `MonoResampler` |
| `Services/CallRecordingFolders.swift` (create) | 5 | create folder, find unfinished, total size |
| `Services/CallAudioCapture.swift` (create) | 6 | `CallAudioChunk`, `CallAudioCapturing`, `HostClock`, `EngineCallMicrophoneCapture` |
| `Services/ProcessTapSystemAudioCapture.swift` (create) | 7 | global process tap |
| `Features/CallRecordingController.swift` (create) | 8 | recording state machine |
| `Features/FileTranscriptionController.swift` (modify), `Features/CallTranscriptionPlan.swift` (create) | 9 | call jobs |
| `Features/CallRecordingRecovery.swift` (create) | 10 | launch recovery |
| App/UI wiring | 11 | hotkey, environment, menu, settings, Transcripts window |
| docs | 12 | ADRs, architecture, smoke test, changelog |

---

### Task 1: Core values — speaker, layout, manifest, errors, setting

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Transcript.swift`
- Create: `macos/Sources/Macomprendo/Core/CallRecording.swift`
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift`
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Test: `macos/Tests/MacomprendoTests/Core/TranscriptTests.swift` (create or extend), `macos/Tests/MacomprendoTests/Core/CallRecordingTests.swift` (create), `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift` (extend), `macos/Tests/MacomprendoTests/Core/SettingsTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  enum TranscriptSpeaker: String, Sendable, Equatable, CaseIterable, Codable {
      case me, others
      var label: String   // "Me" / "Others"
  }
  // TranscriptSegment gains `let speaker: TranscriptSpeaker?`;
  // init(start:end:text:rawText: = nil, speaker: TranscriptSpeaker? = nil)
  // Transcript.plainText: "Me: text" lines when speaker != nil, bare text otherwise.

  enum CallRecordingLayout {
      static let manifestFileName = "recording.json"
      static var defaultDirectory: URL                       // ~/Library/Application Support/Macomprendo/Recordings
      static func baseName(startedAt: Date, timeZone: TimeZone = .current) -> String  // "rec 2026-10-15 16-42-07"
      static func folderName(base: String, attempt: Int) -> String                    // 1 → base; n → "base (n)"
      static func trackFileName(folderName: String, track: TranscriptSpeaker) -> String // "<folder> Me.m4a"
      static func transcriptTitle(startedAt: Date, timeZone: TimeZone = .current) -> String // "Call 2026-10-15 16:42"
  }

  struct CallRecordingManifest: Codable, Equatable, Sendable {
      static let currentVersion = 1
      enum Status: String, Codable, Sendable { case recording, finished }
      struct Track: Codable, Equatable, Sendable {
          var file: String
          var startOffset: TimeInterval?   // nil until the track's first sample
      }
      var version: Int
      var startedAt: Date
      var status: Status
      var tracks: [String: Track]          // keys are TranscriptSpeaker raw values
      init(startedAt: Date, folderName: String)  // version 1, .recording, both tracks, offsets nil
      func track(_ speaker: TranscriptSpeaker) -> Track?
      mutating func setStartOffset(_ offset: TimeInterval, for speaker: TranscriptSpeaker)
      static func read(from folder: URL) throws -> CallRecordingManifest
      func write(to folder: URL) throws
  }

  // MacomprendoError:
  case systemAudioCaptureFailed(String)
  case callRecordingLocationUnavailable
  case callRecordingWriteFailed(String)
  case callRecordingUnavailable

  // Settings:
  var callRecordingsDirectory: String?   // nil → CallRecordingLayout.defaultDirectory
  ```

- [ ] **Step 1: Write failing tests**

  `CallRecordingTests.swift`:
  ```swift
  import Foundation
  import Testing
  @testable import Macomprendo

  struct CallRecordingLayoutTests {
      let moscow = TimeZone(identifier: "Europe/Moscow")!
      // 2026-10-15 13:42:07 UTC == 16:42:07 MSK
      let date = Date(timeIntervalSince1970: 1_792_071_727)

      @Test func baseNameUsesLocalTime() {
          #expect(CallRecordingLayout.baseName(startedAt: date, timeZone: moscow)
                  == "rec 2026-10-15 16-42-07")
      }
      @Test func folderNameAddsSuffixFromSecondAttempt() {
          #expect(CallRecordingLayout.folderName(base: "rec X", attempt: 1) == "rec X")
          #expect(CallRecordingLayout.folderName(base: "rec X", attempt: 2) == "rec X (2)")
      }
      @Test func trackFilesFollowTheFolder() {
          #expect(CallRecordingLayout.trackFileName(folderName: "rec X (2)", track: .me) == "rec X (2) Me.m4a")
          #expect(CallRecordingLayout.trackFileName(folderName: "rec X", track: .others) == "rec X Others.m4a")
      }
      @Test func transcriptTitle() {
          #expect(CallRecordingLayout.transcriptTitle(startedAt: date, timeZone: moscow)
                  == "Call 2026-10-15 16:42")
      }
      @Test func defaultDirectory() {
          #expect(CallRecordingLayout.defaultDirectory.path.hasSuffix(
              "Library/Application Support/Macomprendo/Recordings"))
      }
  }

  struct CallRecordingManifestTests {
      func tempFolder() throws -> URL {
          let url = FileManager.default.temporaryDirectory
              .appendingPathComponent(UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          return url
      }

      @Test func newManifestNamesBothTracks() {
          let m = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 0), folderName: "rec X")
          #expect(m.version == 1)
          #expect(m.status == .recording)
          #expect(m.track(.me) == .init(file: "rec X Me.m4a", startOffset: nil))
          #expect(m.track(.others) == .init(file: "rec X Others.m4a", startOffset: nil))
      }
      @Test func roundTrip() throws {
          let folder = try tempFolder()
          var m = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 1_792_071_727), folderName: "rec X")
          m.setStartOffset(0.184, for: .others)
          m.status = .finished
          try m.write(to: folder)
          #expect(try CallRecordingManifest.read(from: folder) == m)
          // no temp file is left beside it
          let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
          #expect(names == ["recording.json"])
      }
      @Test func unknownVersionIsRejected() throws {
          let folder = try tempFolder()
          let json = #"{"version":2,"startedAt":"2026-10-15T13:42:07Z","status":"finished","tracks":{}}"#
          try Data(json.utf8).write(to: folder.appendingPathComponent("recording.json"))
          #expect(throws: MacomprendoError.callRecordingUnavailable) {
              try CallRecordingManifest.read(from: folder)
          }
      }
      @Test func missingManifestIsUnavailable() throws {
          #expect(throws: MacomprendoError.callRecordingUnavailable) {
              try CallRecordingManifest.read(from: try tempFolder())
          }
      }
  }
  ```
  `TranscriptTests.swift` — add:
  ```swift
  @Test func plainTextLabelsSpeakers() {
      let t = Transcript.fixture(segments: [
          TranscriptSegment(start: 0, end: 1, text: "Hi", speaker: .me),
          TranscriptSegment(start: 1, end: 2, text: "Hello", speaker: .others)])
      #expect(t.plainText == "Me: Hi\nOthers: Hello")
  }
  @Test func plainTextWithoutSpeakersIsUnchanged() {
      let t = Transcript.fixture(segments: [TranscriptSegment(start: 0, end: 1, text: "Hi")])
      #expect(t.plainText == "Hi")
  }
  ```
  If no `Transcript.fixture` helper exists in the tests, add one in the test file (a `Transcript` with a `file` header, an empty `TranscriptionRun`, no bookmark, no summary). Find how existing tests build a `Transcript` (`grep -rn "Transcript(header" macos/Tests`) and reuse that.

  `MacomprendoErrorTests` — add the four cases to the table the suite iterates (both strings non-empty). `SettingsTests` — a document without `callRecordingsDirectory` decodes to `nil`; a value round-trips.

- [ ] **Step 2: Run, expect compile failure / FAIL**

  `swift test --package-path macos --filter "CallRecording|TranscriptTests|MacomprendoErrorTests|SettingsTests"`

- [ ] **Step 3: Implement**

  - `TranscriptSpeaker` in `Transcript.swift`; `label` returns `"Me"` / `"Others"`.
  - `plainText`: `segments.map { s in s.speaker.map { "\($0.label): \(s.text)" } ?? s.text }.joined(separator: "\n")`.
  - `CallRecording.swift`: dates via a `DateFormatter` with `locale = Locale(identifier: "en_US_POSIX")`, the given `timeZone`, formats `"yyyy-MM-dd HH-mm-ss"` and `"yyyy-MM-dd HH:mm"`. `defaultDirectory` = `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]/Macomprendo/Recordings`.
  - Manifest encoder: `JSONEncoder` with `dateEncodingStrategy = .iso8601`, `outputFormatting = [.prettyPrinted, .sortedKeys]`; decoder `.iso8601`. `write` uses `Data.write(to:options: .atomic)`. `read` maps any missing file / decode failure / `version != currentVersion` to `MacomprendoError.callRecordingUnavailable`.
  - Error strings:
    - `systemAudioCaptureFailed(reason)`: "System audio could not be recorded (\(reason))." / "Check System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then start the recording again."
    - `callRecordingLocationUnavailable`: "The call recordings folder cannot be written." / "Choose another folder in Settings ▸ General ▸ Call recordings."
    - `callRecordingWriteFailed(reason)`: "The call recording stopped because a file could not be written (\(reason))." / "Free some disk space or choose another folder in Settings ▸ General. What was recorded so far is kept."
    - `callRecordingUnavailable`: "The call recording cannot be found." / "Choose the recording's folder again, or restore it from the Trash."
  - `Settings.callRecordingsDirectory: String?` — follow the file's pattern exactly: property with a doc comment, default `nil` in the defaults list, `decodeIfPresent` in `init(from:)`, the `CodingKeys` case, and encoding if `encode(to:)` is hand-written.

- [ ] **Step 4: Run tests — PASS.** Then `npm run test:swift` to catch any `TranscriptSegment` initialiser breakage.
- [ ] **Step 5: Commit** — `feat(calls): speaker, recording layout and manifest`

---

### Task 2: Transcript store schema v2

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/TranscriptStore.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptStore.swift` (only if it rebuilds segments field by field)
- Test: `macos/Tests/MacomprendoTests/Services/TranscriptStoreTests.swift` (find the existing suite: `grep -rln SQLiteTranscriptStore macos/Tests`)

**Interfaces:**
- Consumes: `TranscriptSegment.speaker` (Task 1).
- Produces: `SQLiteTranscriptStore` persists and reads `speaker`; `PRAGMA user_version` is 2.

- [ ] **Step 1: Failing tests**
  ```swift
  @Test func speakerRoundTrips() async throws {
      let store = SQLiteTranscriptStore(databaseURL: tempDB())
      let id = try await store.create(sourceKind: .call, title: "Call", sourceBookmark: nil,
                                      duration: 10, run: .fixture, at: Date())
      try await store.appendSegment(TranscriptSegment(start: 1, end: 2, text: "a", speaker: .others), to: id)
      try await store.appendSegment(TranscriptSegment(start: 0, end: 1, text: "b", speaker: .me), to: id)
      let segments = try await store.transcript(id: id)!.segments
      #expect(segments.map(\.speaker) == [.me, .others])
  }

  @Test func versionOneDatabaseMigrates() async throws {
      let url = tempDB()
      // build a v1 database by hand: the exact v1 DDL (copy it from the current `connection()`
      // before you change it), one transcript, one segment, `PRAGMA user_version = 1`
      try makeVersionOneDatabase(at: url)
      let store = SQLiteTranscriptStore(databaseURL: url)
      let header = try #require(try await store.headers().first)
      let old = try #require(try await store.transcript(id: header.id))
      #expect(old.segments.map(\.speaker) == [nil])
      try await store.appendSegment(TranscriptSegment(start: 5, end: 6, text: "c", speaker: .me), to: header.id)
      #expect(try await store.transcript(id: header.id)!.segments.last?.speaker == .me)
      #expect(try userVersion(of: url) == 2)
  }

  @Test func reopeningVersionTwoKeepsData() async throws { /* open, append, new store instance on same URL, read back */ }
  ```
  Write `makeVersionOneDatabase` and `userVersion` with the `SQLite3` C API in the test file.

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**
  - In `connection()`: keep `CREATE TABLE IF NOT EXISTS` but add `speaker TEXT CHECK(speaker IN ('me', 'others'))` to the `transcript_segments` DDL; drop `PRAGMA user_version = 1;` from that batch. After it, read `PRAGMA user_version`: `0` (fresh) → set 2; `1` → `ALTER TABLE transcript_segments ADD COLUMN speaker TEXT CHECK(speaker IN ('me', 'others'))` then set 2, in one transaction; `2` → nothing; greater → throw `MacomprendoError.transcriptStore("the transcripts database is from a newer version")`.
  - `appendSegment` binds `segment.speaker?.rawValue` as `?6`; `segments(of:on:)` selects `speaker` and maps it with `TranscriptSpeaker(rawValue:)`.
- [ ] **Step 4: Run store suite and `npm run test:swift` — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): store a speaker per transcript segment`

---

### Task 3: Speaker labels in exports and the segment row

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/TranscriptExporter.swift`
- Modify: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift` (`segmentRow`)
- Test: `macos/Tests/MacomprendoTests/Core/TranscriptExporterTests.swift`

**Interfaces:**
- Consumes: `TranscriptSpeaker.label`, speaker-aware `Transcript.plainText` (Task 1).
- Produces: `TranscriptExporter.speakerPrefix(_ segment: TranscriptSegment) -> String` — `"Me: "` / `"Others: "` / `""`.

- [ ] **Step 1: Failing tests** (keep every existing exporter test unchanged — file transcripts must export exactly as before)
  ```swift
  @Test func callExports() {
      let t = Transcript.fixture(segments: [
          TranscriptSegment(start: 0, end: 1.5, text: "Hi", speaker: .me),
          TranscriptSegment(start: 3_725, end: 3_726, text: "Hello", speaker: .others)])
      #expect(TranscriptExporter.render(t, as: .plainText) == "Me: Hi\nOthers: Hello\n")
      #expect(TranscriptExporter.render(t, as: .subRip) ==
          "1\n00:00:00,000 --> 00:00:01,500\nMe: Hi\n\n2\n01:02:05,000 --> 01:02:06,000\nOthers: Hello\n")
      let md = TranscriptExporter.render(t, as: .markdown)
      #expect(md.contains("**[00:00] Me:** Hi\n"))
      #expect(md.contains("**[1:02:05] Others:** Hello\n"))
  }
  ```
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — `subRip` uses `speakerPrefix(segment) + segment.text`; markdown line becomes `"**[\(clock(start))]\(speaker.map { " \($0.label):" } ?? "")** \(text)"`; plain text already goes through `plainText`. In `TranscriptsView.segmentRow`, show `TranscriptExporter.speakerPrefix(segment) + segment.text` (keep the existing layout; no other view changes in this task).
- [ ] **Step 4: Run — PASS.** `swift build --package-path macos`.
- [ ] **Step 5: Commit** — `feat(calls): speaker labels in transcript exports and rows`

---

### Task 4: Track writer — timeline, resampler, fragmented AAC

**Files:**
- Create: `macos/Sources/Macomprendo/Services/CallTrackWriter.swift`
- Test: `macos/Tests/MacomprendoTests/Services/CallTrackWriterTests.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeCallTrackWriter.swift`

**Interfaces:**
- Consumes: `MacomprendoError.callRecordingWriteFailed` (Task 1).
- Produces:
  ```swift
  /// Places one track's chunks on the session clock. Pure.
  struct TrackTimeline: Sendable, Equatable {
      static let minimumGap: TimeInterval = 0.05
      let sampleRate: Double
      let sessionStart: TimeInterval            // host seconds
      private(set) var firstSampleTime: TimeInterval?
      private(set) var framesWritten: Int
      init(sampleRate: Double, sessionStart: TimeInterval)
      /// Frames of silence to write before a chunk of `frames` whose first sample is at `time`
      /// (host seconds). Also counts the chunk (and the silence) into `framesWritten`.
      mutating func place(frames: Int, at time: TimeInterval) -> Int
      var startOffset: TimeInterval? { get }    // firstSampleTime - sessionStart
  }

  /// Receives one track's audio: 48 kHz mono Float32, `time` = host seconds of the first sample.
  protocol CallAudioSink: AnyObject, Sendable {
      func consume(_ samples: [Float], at time: TimeInterval)
  }

  protocol CallTrackWriting: CallAudioSink {
      var startOffset: TimeInterval? { get }
      /// Flushes and closes the file. Throws `callRecordingWriteFailed`.
      func finish() async throws
  }

  typealias CallTrackWriterFactory = @Sendable (_ url: URL, _ sessionStart: TimeInterval,
      _ onFailure: @escaping @Sendable (MacomprendoError) -> Void) throws -> any CallTrackWriting

  final class AssetCallTrackWriter: CallTrackWriting, @unchecked Sendable {
      static let sampleRate: Double = 48_000
      static let bitRate = 48_000
      init(url: URL, sessionStart: TimeInterval,
           onFailure: @escaping @Sendable (MacomprendoError) -> Void) throws
      static let factory: CallTrackWriterFactory
  }

  /// Converts any PCM buffer to 48 kHz mono Float32. Keeps its converter while the input format is unchanged.
  final class MonoResampler: @unchecked Sendable {
      init(targetRate: Double = 48_000)
      func convert(_ buffer: AVAudioPCMBuffer) -> [Float]
  }
  ```

- [ ] **Step 1: Failing tests**
  ```swift
  struct TrackTimelineTests {
      @Test func firstChunkSetsOffsetWithoutPadding() {
          var t = TrackTimeline(sampleRate: 48_000, sessionStart: 100)
          #expect(t.place(frames: 480, at: 100.184) == 0)
          #expect(t.startOffset! == 0.184, "offset")
          #expect(t.framesWritten == 480)
      }
      @Test func twoSecondHoleIsPadded() {
          var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
          _ = t.place(frames: 48_000, at: 0)           // 0…1 s
          #expect(t.place(frames: 480, at: 3.0) == 96_000)
          #expect(t.framesWritten == 48_000 + 96_000 + 480)
      }
      @Test func thirtyMillisecondHoleIsNotPadded() {
          var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
          _ = t.place(frames: 48_000, at: 0)
          #expect(t.place(frames: 480, at: 1.03) == 0)
      }
      @Test func lateClockNeverPadsNegative() {
          var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
          _ = t.place(frames: 48_000, at: 0)
          #expect(t.place(frames: 480, at: 0.9) == 0)
      }
  }

  struct AssetCallTrackWriterTests {
      @Test func writesPlayableAACWithPaddedGap() async throws {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
          let writer = try AssetCallTrackWriter(url: url, sessionStart: 10, onFailure: { _ in })
          let second = [Float](repeating: 0.1, count: 48_000)
          writer.consume(second, at: 10.5)              // 1 s at offset 0.5
          writer.consume(second, at: 13.5)              // 2 s hole → padded
          try await writer.finish()
          #expect(writer.startOffset == 0.5)
          let duration = try await AVURLAsset(url: url).load(.duration).seconds
          #expect(abs(duration - 4.0) < 0.1)
          let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
          let format = try #require(try await track.load(.formatDescriptions).first)
          #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
      }
      @Test func unwritableLocationThrows() {
          #expect(throws: MacomprendoError.self) {
              _ = try AssetCallTrackWriter(url: URL(fileURLWithPath: "/nonexistent-dir/x.m4a"),
                                           sessionStart: 0, onFailure: { _ in })
          }
      }
  }

  struct MonoResamplerTests {
      @Test func stereo44kBecomesMono48k() throws {
          let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
          buffer.frameLength = 44_100
          let samples = MonoResampler().convert(buffer)
          #expect(abs(samples.count - 48_000) <= 64)
      }
  }
  ```
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**
  - `TrackTimeline.place`: first call → `firstSampleTime = time`, pad 0. Later: `expected = firstSampleTime! + Double(framesWritten) / sampleRate`; `gap = time - expected`; pad `gap >= minimumGap ? Int((gap * sampleRate).rounded()) : 0`; `framesWritten += pad + frames`.
  - `AssetCallTrackWriter`: `AVAssetWriter(outputURL:fileType: .m4a)` (constructor failure → `callRecordingWriteFailed(error.localizedDescription)`); `movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)`; one `AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000])`, `expectsMediaDataInRealTime = true`; `startWriting()` + `startSession(atSourceTime: .zero)` in `init` (failure throws `callRecordingWriteFailed`). All further work runs on a private serial `DispatchQueue`: `consume` copies the samples and enqueues; the queue asks the timeline for padding, appends zeros then samples as `CMSampleBuffer`s with presentation time `framesWritten` at timescale 48 000. Build sample buffers exactly as `Providers/DictationAudioEncoder.swift` `sampleBuffer(from:at:)` does (copy that helper into this file as a private static function — do not make the encoder's private helper shared). When `input.isReadyForMoreMediaData` is false, keep the buffer in a FIFO and drain it before the next append and in `finish()`. The first append failure (`append` returns false or `writer.status == .failed`) calls `onFailure(.callRecordingWriteFailed(...))` once and drops later audio. `startOffset` reads the timeline under a lock. `finish()` drains the queue, `markAsFinished()`, `await finishWriting()`, and throws `callRecordingWriteFailed` unless `.completed`. `factory` = `{ try AssetCallTrackWriter(url: $0, sessionStart: $1, onFailure: $2) }`.
  - `MonoResampler`: `AVAudioConverter` from the buffer's format to `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)`, recreated when the input format changes; `convert(to:error:withInputFrom:)` with an output capacity of `ceil(frames * 48000 / inRate) + 32`; returns the channel-0 floats. Multichannel input is downmixed by the converter (set `converter.channelMap`/rely on default downmix — verify the stereo test).
  - `FakeCallTrackWriter`: records `consumed: [(samples: Int, time: TimeInterval)]`, `finished: Bool`, settable `startOffset`, optional `finishError`.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): fragmented AAC track writer on the session clock`

---

### Task 5: Recording folders

**Files:**
- Create: `macos/Sources/Macomprendo/Services/CallRecordingFolders.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeCallRecordingFolders.swift`
- Test: `macos/Tests/MacomprendoTests/Services/CallRecordingFoldersTests.swift`

**Interfaces:**
- Consumes: `CallRecordingLayout`, `CallRecordingManifest` (Task 1).
- Produces:
  ```swift
  protocol CallRecordingFolderManaging: Sendable {
      /// Creates `<directory>/<rec …>` (creating `directory` too), adding " (2)"… on collision.
      /// Throws `callRecordingLocationUnavailable`.
      func create(in directory: URL, startedAt: Date) throws -> URL
      /// Folders directly inside `directory` whose manifest status is `.recording`.
      func unfinishedRecordings(in directory: URL) -> [URL]
      /// Bytes of every regular file under `directory`; 0 when it does not exist.
      func totalSize(of directory: URL) -> Int64
      /// Removes a folder this service created. Best effort.
      func remove(_ folder: URL)
  }
  struct FileSystemCallRecordingFolders: CallRecordingFolderManaging {
      init(timeZone: TimeZone = .current)
  }
  ```
- [ ] **Step 1: Failing tests** (real temp directories):
  - `create` returns `…/rec 2026-10-15 16-42-07` (fixed date, `Europe/Moscow` zone); a second `create` with the same date returns `… (2)`; a third `… (3)`.
  - `create` in a directory whose parent is a regular file throws `MacomprendoError.callRecordingLocationUnavailable`.
  - `unfinishedRecordings` returns only the folder whose manifest is `.recording` (set up: one `.recording`, one `.finished`, one with no manifest, one plain file).
  - `totalSize` sums a 10-byte and a 20-byte file in nested folders = 30; a missing directory = 0.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** with `FileManager`: `createDirectory(withIntermediateDirectories: true)` for `directory`, then for the folder with `withIntermediateDirectories: false` in a loop over attempts 1…999 (an "already exists" error moves to the next attempt; any other error → `callRecordingLocationUnavailable`). `totalSize` uses `enumerator(at:includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])` and sums `totalFileAllocatedSize ?? fileSize`. In the fake: an in-memory list, a settable `createError`, `unfinished: [URL]`, `size: Int64`, `removed: [URL]`.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): recording folders`

---

### Task 6: Capture protocol and the microphone capture

**Files:**
- Create: `macos/Sources/Macomprendo/Services/CallAudioCapture.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/ScriptedCallCapture.swift`
- Test: `macos/Tests/MacomprendoTests/Services/EngineCallMicrophoneCaptureTests.swift`

**Interfaces:**
- Consumes: `AudioInputEngine`, `AVAudioInputEngine`, `AudioInputDeviceListing`, `AVAudioEngineRecorder.resolveInputDevice(preferredUID:devices:systemDefault:excluding:)` (all existing, `Services/AudioRecorder.swift`, `Services/AudioInputDevices.swift`), `MonoResampler` (Task 4). Existing fakes: `FakeAudioInputEngine`, `FakeAudioInputDevices`.
- Produces:
  ```swift
  /// 48 kHz mono Float32 with the host-clock time (seconds) of its first sample.
  struct CallAudioChunk: Sendable { let samples: [Float]; let time: TimeInterval }

  protocol CallAudioCapturing: AnyObject, Sendable {
      /// Starts delivering chunks to `handler` on an arbitrary thread. Throws a `MacomprendoError`.
      func start(_ handler: @escaping @Sendable (CallAudioChunk) -> Void) throws
      /// Stops delivery. Idempotent. No chunk is delivered after it returns.
      func stop()
  }

  enum HostClock {
      static func seconds(forHostTime hostTime: UInt64) -> TimeInterval  // AVAudioTime.seconds(forHostTime:)
      static func now() -> TimeInterval                                  // seconds(forHostTime: mach_absolute_time())
  }

  final class EngineCallMicrophoneCapture: CallAudioCapturing, @unchecked Sendable {
      init(engine: any AudioInputEngine, devices: any AudioInputDeviceListing,
           clock: @escaping @Sendable () -> TimeInterval = HostClock.now)
      /// Same contract as `AVAudioEngineRecorder.setPreferredInputDevice(uid:)`: applies at once,
      /// a running capture moves to the newly chosen device.
      func setPreferredInputDevice(uid: String?)
  }

  /// The microphone side: a capture that follows the chosen input device.
  protocol CallMicrophoneCapturing: CallAudioCapturing {
      func setPreferredInputDevice(uid: String?)
  }
  // EngineCallMicrophoneCapture conforms to CallMicrophoneCapturing; so does ScriptedCallCapture.
  ```
  A separate `AVAudioInputEngine` instance from dictation's recorder (constructed in Task 11) — never voice processing.

- [ ] **Step 1: Failing tests** with `FakeAudioInputEngine` and `FakeAudioInputDevices` (read both fakes first to drive them):
  - `start` (after `setPreferredInputDevice(uid:)`) binds the device `resolveInputDevice` picks for the preferred UID, installs a tap, starts the engine.
  - A 44.1 kHz stereo buffer pushed through the fake tap reaches the handler as ~48 000 samples per second of input, with `time == clock() - Double(frames)/44_100` (inject a fixed clock).
  - `onConfigurationChange` with the engine stopped restarts it on the resolved device; chunks keep flowing.
  - Device list change to a new preferred device switches device.
  - `stop` removes the tap, stops the engine; a buffer pushed after `stop` is not delivered.
  - `start` with no input device at all throws `MacomprendoError.audio(...)` (use the same message style as the recorder).
  - `ScriptedCallCapture` (fake): `startError`, `isRunning`, and `func emit(_ chunk: CallAudioChunk)` that calls the stored handler.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — mirror the device-following parts of `AVAudioEngineRecorder` (`bindLocked`, `restartOnResolvedDeviceLocked`, `inputDevicesChanged` via `devices.changes()`), without the silent-device fallback, the cap, or the in-memory sample buffer. Tap in the engine's `inputFormat`, convert with `MonoResampler`, stamp `time = clock() - Double(buffer.frameLength) / buffer.format.sampleRate`. Guard state with `NSLock`.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): raw microphone capture for calls`

---

### Task 7: System audio through a global process tap (hardware glue) + platform 14.2

**Files:**
- Create: `macos/Sources/Macomprendo/Services/ProcessTapSystemAudioCapture.swift`
- Modify: `macos/Package.swift` (`platforms: [.macOS("14.2")]`)
- Modify: `macos/project.yml` (every `deploymentTarget` `macOS: "14.0"` / `"14.0"` and `MACOSX_DEPLOYMENT_TARGET` → `14.2`)
- Modify: `macos/AppBundle/Info.plist` (add `NSAudioCaptureUsageDescription` = "Macomprendo records what your Mac plays during a call you record, so the other side can be transcribed.")
- Regenerate: `macos/Macomprendo.xcodeproj` via `npm run gen`
- Modify: `docs/SMOKE_TEST.md` (call-recording section, see Task 12 list — add the tap lines here)

**Interfaces:**
- Consumes: `CallAudioCapturing`, `CallAudioChunk`, `HostClock` (Task 6), `MonoResampler` (Task 4), `MacomprendoError.systemAudioCaptureFailed` (Task 1).
- Produces: `final class ProcessTapSystemAudioCapture: CallAudioCapturing, @unchecked Sendable { init() }`.

No unit tests (hardware). Keep it thin and do this:

- [ ] **Step 1: Implement `start`**
  1. Own process object: `AudioObjectGetPropertyData(kAudioObjectSystemObject, kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: getpid())`.
  2. `let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject])`; `description.muteBehavior = .unmuted`; `description.isPrivate = true`; `description.name = "Macomprendo call"`.
  3. `AudioHardwareCreateProcessTap(description, &tapID)`.
  4. Tap UID: `kAudioTapPropertyUID` on `tapID`. Tap format: `kAudioTapPropertyFormat` → `AudioStreamBasicDescription` → `AVAudioFormat(streamDescription:)`.
  5. Aggregate: `AudioHardwareCreateAggregateDevice` with `[kAudioAggregateDeviceNameKey: "Macomprendo call", kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true, kAudioAggregateDeviceSubDeviceListKey: [], kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]]` — tap-only, no main sub-device (as quill).
  6. `AudioDeviceCreateIOProcIDWithBlock` on the aggregate with a private serial queue; in the block wrap `inInputData` in an `AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy:)`, convert with `MonoResampler`, and call the handler with `CallAudioChunk(samples:, time: HostClock.seconds(forHostTime: inInputTime.pointee.mHostTime))`. Then `AudioDeviceStart`.
  7. Any non-`noErr` status → tear down what was created, throw `.systemAudioCaptureFailed("<step> \(status)")`, and `Log.audio.error` the step and status (public).
  8. Add a listener (`AudioObjectAddPropertyListenerBlock`) on `kAudioHardwarePropertyDefaultOutputDevice`: on change, tear down and rebuild steps 2–6 on the private queue, keeping the same handler. A rebuild failure logs and leaves the capture stopped (the timeline pads nothing further; the level row shows silence).
- [ ] **Step 2: Implement `stop`**: remove the listener, `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`; idempotent; after it returns no chunk is delivered (set a stopped flag checked under the lock in the IO block).
- [ ] **Step 3: Platform + plist**: edit `Package.swift`, `project.yml`, `Info.plist`; run `npm run gen`; then `swift build --package-path macos` and the xcodebuild command from AGENTS.md (`CODE_SIGNING_ALLOWED=NO`) — both succeed with no new warnings. `npm run gen` a second time must leave `git status` unchanged.
- [ ] **Step 4: Smoke-test lines** in `docs/SMOKE_TEST.md` under a new "Call recording" heading: tap over built-in speakers, wired headphones, AirPods with the Mac's mic, AirPods with their own mic; switching output mid-call; declining System Audio Recording (Others stays empty, the recording continues).
- [ ] **Step 5: `npm run test:swift` green. Commit** — `feat(calls): system audio through a global process tap; require macOS 14.2`

---

### Task 8: CallRecordingController

**Files:**
- Create: `macos/Sources/Macomprendo/Features/CallRecordingController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/CallRecordingControllerTests.swift`

**Interfaces:**
- Consumes: `CallAudioCapturing` + `ScriptedCallCapture` (Task 6), `CallTrackWriterFactory`/`CallTrackWriting` + `FakeCallTrackWriter` (Task 4), `CallRecordingFolderManaging` + `FakeCallRecordingFolders` (Task 5), `CallRecordingLayout`, `CallRecordingManifest`, `TranscriptSpeaker` (Task 1), existing `PermissionsChecking` (`ScriptedPermissions`/`FakePermissions`), `TranscriptStoring` (`FakeTranscriptStore`), `FileBookmarking` (`FakeFileBookmarks`), `TranscriptionRun.from(_:language:)`, `AudioMath.rms`/`AudioMath.level(fromRMS:)`, `TranscriptLibraryController.abandonedJobReason`, `ErrorText.describe`.
- Produces:
  ```swift
  struct CallLevels: Equatable, Sendable { var me: Float = 0; var others: Float = 0 }

  @MainActor final class CallRecordingController: ObservableObject {
      enum State: Equatable {
          case idle, starting
          case recording(startedAt: Date)
          case stopping
          case failed(String)
      }
      @Published private(set) var state: State
      @Published private(set) var levels: CallLevels
      @Published private(set) var elapsed: TimeInterval
      var isRecording: Bool        // .starting, .recording, .stopping

      init(microphone: any CallMicrophoneCapturing,
           systemAudio: any CallAudioCapturing,
           folders: any CallRecordingFolderManaging,
           makeWriter: @escaping CallTrackWriterFactory,
           permissions: any PermissionsChecking,
           store: any TranscriptStoring,
           bookmarks: any FileBookmarking,
           settings: @escaping @MainActor () -> Settings,
           clock: @escaping @Sendable () -> TimeInterval = HostClock.now,
           now: @escaping () -> Date = Date.init,
           tick: Duration = .milliseconds(100),
           transcribe: @escaping @MainActor (Int64) -> Void,
           transcriptsChanged: @escaping @MainActor () -> Void = {})

      func handle(_ event: HotkeyEvent)   // keyDown(.recordCall) → toggle(); everything else ignored
      func toggle()                       // idle/failed → start; starting/recording → stop
      func stop() async                   // finalise + start the call job
      func systemWillSleep() async        // same as stop()
      func shutdown() async               // finalise, row incomplete with abandonedJobReason, no job
      func drain() async                  // awaits the in-flight task; tests
  }
  ```
  `HotkeyAction.recordCall` does not exist until Task 11 — in this task `handle` matches `event == .keyDown(.recordCall)` only after Task 11 adds the case. **Ruling for this task:** implement `toggle()`/`stop()`/`systemWillSleep()`/`shutdown()` and test them; add `handle(_:)` and its test in Task 11.

- [ ] **Step 1: Failing tests** (fakes for everything; `tick: .milliseconds(1)`; fixed `now` and `clock`):
  1. Start: state goes `starting → recording(startedAt: now)`; `folders.create` called with `settings.callRecordingsDirectory` (or `CallRecordingLayout.defaultDirectory` when nil); a manifest with `.recording` and both file names exists in the created folder (use a real temp folder from a `FakeCallRecordingFolders` that creates real directories, or read what the controller wrote through the folder URL); two writers made for `<folder>/<folder name> Me.m4a` and `… Others.m4a` with `sessionStart == clock()`; both captures started.
  2. Chunks: `microphone.emit` reaches the Me writer only, `systemAudio.emit` the Others writer only; after a tick, `levels.me > 0` for a non-silent chunk and `levels.others == 0`.
  3. When a writer first reports a `startOffset`, the manifest on disk gains it (still `.recording`).
  4. Microphone permission `.denied` → `failed(ErrorText.describe(.permissionDenied(.microphone)))`, no folder created, no capture started. `.notDetermined` → `request` called; granted continues.
  5. `folders.create` throws → `failed(... callRecordingLocationUnavailable ...)`, nothing started.
  6. System capture `start` throws `.systemAudioCaptureFailed("x")` → microphone stopped, writers finished, folder removed (`folders.removed`), state `failed`.
  7. `stop()`: captures stopped before writers finish; both writers finished; manifest `.finished` with both offsets; `store.create(sourceKind: .call, title: CallRecordingLayout.transcriptTitle(startedAt: now), sourceBookmark: bookmark of the folder, duration: elapsed, run: from settings, at: now)`; `transcribe(id)` called once with that id; state `.idle`.
  8. `toggle()` during `.starting` (make `permissions.request` suspend until released) → once capture is up the controller stops at once; exactly one transcript and one `transcribe` call.
  9. A writer `onFailure(.callRecordingWriteFailed("disk"))` → the recording stops as in 7 (transcript created, `transcribe` called) and state ends `failed(ErrorText.describe(.callRecordingWriteFailed("disk")))`.
  10. `systemWillSleep()` behaves as `stop()`.
  11. `shutdown()`: manifest `.finished`; transcript created then `setStatus(.incomplete, reason: TranscriptLibraryController.abandonedJobReason)`; `transcribe` NOT called. `shutdown()` while idle does nothing.
  12. `toggle()` after `failed` starts a new recording.
  13. `elapsed` advances with ticks while recording (inject `now` as a mutable box) and resets to 0 when idle.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**
  - One in-flight `Task` (`activeTask`), as other controllers. A `pendingStop` flag set by `toggle()` in `.starting`.
  - Levels: each capture handler computes `AudioMath.level(fromRMS: AudioMath.rms(samples))` and stores it in a lock-guarded box with the writer call; a `@MainActor` ticker task (`Task.sleep(for: tick)`) copies the box into `levels`, updates `elapsed = now().timeIntervalSince(startedAt)`, and rewrites the manifest once when a writer's `startOffset` first becomes non-nil. Writes off the main actor are unnecessary for a tiny JSON file; keep it simple.
  - Writer `onFailure` hops to the main actor and runs the stop path with a remembered error.
  - Stop order: `microphone.stop()`, `systemAudio.stop()`, `try await` both `finish()` (a finish error becomes the remembered `callRecordingWriteFailed`), write manifest `.finished` with offsets, create the row, then `transcribe(id)` (stop) or `setStatus(.incomplete, reason: abandonedJobReason)` (shutdown), call `transcriptsChanged()`, set state.
  - A store failure while creating the row → `failed(ErrorText.describe(error))`; the folder stays (launch recovery does not pick it up because it is `.finished` — acceptable, the files are still in Finder).
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): call recording controller`

---

### Task 9: Call jobs in FileTranscriptionController

**Files:**
- Create: `macos/Sources/Macomprendo/Features/CallTranscriptionPlan.swift`
- Modify: `macos/Sources/Macomprendo/Features/FileTranscriptionController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/CallTranscriptionPlanTests.swift`, extend `macos/Tests/MacomprendoTests/Features/FileTranscriptionControllerTests.swift`

**Interfaces:**
- Consumes: `CallRecordingManifest` (Task 1), `TranscriptSegment.speaker` (Task 1), existing `LongAudioPipeline`/`ScriptedMediaDecoder`/`ScriptedSegmenter`/`ScriptedTranscriber`, `FakeTranscriptStore`, `FakeFileBookmarks`.
- Produces:
  ```swift
  struct CallTranscriptionStep: Equatable, Sendable {
      let speaker: TranscriptSpeaker
      let file: String               // track file name inside the folder
      let offset: TimeInterval       // the track's startOffset
      let from: TimeInterval         // track-local position to resume decoding from
  }
  enum CallTranscriptionPlan {
      /// Tracks in order Me, Others; a track with no startOffset is skipped. Resumes the last
      /// track that has segments from the end of its last segment (track-local), then the rest from 0.
      static func steps(manifest: CallRecordingManifest,
                        stored: [TranscriptSegment]) -> [CallTranscriptionStep]
  }

  // FileTranscriptionController:
  //  State.running gains `speaker: TranscriptSpeaker?` as its last associated value
  //  (nil for files): .running(transcriptID:title:position:duration:speaker:)
  //  resume(transcriptID:) / resume(transcriptID:fileAt:) dispatch on header.sourceKind;
  //  for .call, `fileAt` is a folder.
  //  var canChooseRecordingFolder: Bool   // failed with callRecordingUnavailable
  //  init gains `callFinished: @escaping @MainActor (_ transcriptID: Int64, _ title: String) -> Void = { _, _ in }`
  ```
- [ ] **Step 1: Failing tests**
  - `CallTranscriptionPlan`: no segments → `[me from 0, others from 0]`; Me segments ending at 120.0 with Me offset 0.2 → `[me from 119.8, others from 0]`; Others segments ending at 50 with offset 0.5 → `[others from 49.5]`; Others offset nil → `[me …]` only; `from` never negative.
  - Controller, call job (manifest written to a temp folder; `FakeFileBookmarks` resolves to it; scripted pipeline yields per URL):
    1. Me track runs before Others (pipeline URLs in order `…Me.m4a`, `…Others.m4a`).
    2. Stored segments are shifted (`start + offset`, `end + offset`) and carry the speaker.
    3. State `.running(… speaker: .me)` then `.running(… speaker: .others)`; ends `.finished(id)`; status `.complete`; `callFinished(id, title)` called once.
    4. Only Others has speech → complete, not an error.
    5. Neither has speech (and the row had none) → transcript deleted, `.failed(noSpeechFound)`.
    6. Resume after Me was half done → Me resumes from the plan's `from`, then Others.
    7. Bookmark unresolvable → `.failed(callRecordingUnavailable)`, `canChooseRecordingFolder == true`, row untouched.
    8. A track file missing → same as 7.
    9. `resume(transcriptID:fileAt: folder)` with a folder holding a valid manifest → the bookmark is replaced (`store.setSourceBookmark`) and the job runs; a folder without a manifest → `callRecordingUnavailable`.
    10. File jobs unchanged: every existing test still passes with `speaker: nil` added to `.running` expectations.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — in `runResume`, after loading the transcript, branch on `transcript.header.sourceKind`: `.file` keeps today's path; `.call` resolves the folder (bookmark or chosen URL, the chosen one validated by `CallRecordingManifest.read` and bookmarked before decoding), reads the manifest (`callRecordingUnavailable` on failure), checks each step's file exists, marks the row `.inProgress`, and runs the steps through a new `runCall` that reuses the existing per-event logic (normalisation, append, `transcriptsChanged`, generation checks, cancellation handler, `stop()`/`awaitCompletion()` after each pipeline) with `start + step.offset`, `end + step.offset`, `speaker: step.speaker`. The `.opened(duration)` event never creates a row for a call. After the last step: zero segments in the whole transcript → delete + `noSpeechFound`; otherwise `.complete`, `.finished(id)`, `callFinished(id, title)`. Cancellation and errors go through the existing `settle`. Update `TranscriptsView.listEffect`/`progressText` call sites for the new associated value (progress text itself changes in Task 11).
- [ ] **Step 4: Run — PASS** (`--filter "FileTranscription|CallTranscriptionPlan"`, then `npm run test:swift`).
- [ ] **Step 5: Commit** — `feat(calls): transcribe both call tracks with speakers and offsets`

---

### Task 10: Launch recovery of interrupted recordings

**Files:**
- Create: `macos/Sources/Macomprendo/Features/CallRecordingRecovery.swift`
- Test: `macos/Tests/MacomprendoTests/Features/CallRecordingRecoveryTests.swift`

**Interfaces:**
- Consumes: `CallRecordingFolderManaging` (Task 5), `CallRecordingManifest`, `CallRecordingLayout` (Task 1), `TranscriptStoring`, `FileBookmarking`, `TranscriptionRun.from`, `TranscriptLibraryController.abandonedJobReason`.
- Produces:
  ```swift
  @MainActor struct CallRecordingRecovery {
      init(folders: any CallRecordingFolderManaging, store: any TranscriptStoring,
           bookmarks: any FileBookmarking, settings: @escaping @MainActor () -> Settings,
           now: @escaping () -> Date = Date.init)
      /// Finalises every `.recording` folder and gives each one without a transcript an
      /// `incomplete` call transcript. Returns how many transcripts it created.
      @discardableResult func recover() async -> Int
  }
  ```
- [ ] **Step 1: Failing tests** (temp folders, `FakeTranscriptStore`, `FakeFileBookmarks`):
  - A `.recording` folder → manifest becomes `.finished`; one call transcript created with title from the manifest's `startedAt`, `duration: nil`, bookmark of the folder, status `incomplete`, reason `abandonedJobReason`.
  - Running `recover()` twice creates one transcript in total.
  - A `.recording` folder that an existing call transcript's bookmark already resolves to → finalised, no new transcript.
  - Store errors are swallowed per folder (the next folder is still processed) and logged without names.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — directory from settings (or default); `folders.unfinishedRecordings`; existing call transcripts: `store.headers()` filtered to `.call`, each `store.transcript(id:)` bookmark resolved via `bookmarks.resolve`, compared by `standardizedFileURL.path`.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** — `feat(calls): recover recordings interrupted by a crash`

---

### Task 11: Wiring — hotkey, environment, app model, menu bar, settings, Transcripts window

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/HotkeyService.swift` (`HotkeyAction.recordCall`, `displayName` "Record Call", `KeyboardShortcuts.Name.recordCall = Self("recordCall")` with no default, `forAction`)
- Modify: every exhaustive `switch` over `HotkeyAction` the compiler reports (e.g. text-feature routing, middle-mouse mapping) — `recordCall` is never a middle-mouse or text action
- Modify: `macos/Sources/Macomprendo/Features/CallRecordingController.swift` (`handle(_:)`) + its test
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` (+ `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift`)
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift`
- Create: `macos/Sources/Macomprendo/UI/MenuBar/CallRecordingMenu.swift` (label view + menu rows + pure meter text)
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift`
- Create: `macos/Sources/Macomprendo/UI/Settings/CallRecordingsSettingsModel.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift`, `macos/Sources/Macomprendo/UI/Settings/HotkeysTab.swift`
- Modify: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift`
- Test: `macos/Tests/MacomprendoTests/UI/CallRecordingMenuTests.swift`, `macos/Tests/MacomprendoTests/UI/CallRecordingsSettingsModelTests.swift`, extend `TranscriptsView` static-helper tests, extend `AppModel` routing tests if they exist (`grep -rn "func route" macos/Tests`)

**Interfaces:**
- Produces:
  ```swift
  enum CallLevelMeter {
      /// Ten cells: round(level * 10) filled "▮", the rest "▯"; level clamped to 0…1.
      static func text(_ level: Float) -> String
  }
  // TranscriptsView.progressText(position:duration:speaker:) →
  //   speaker nil:  "Transcribing — 12:40 / 58:03"
  //   speaker .me:  "Transcribing Me — 12:40 / 58:03"
  @MainActor final class CallRecordingsSettingsModel: ObservableObject {
      @Published private(set) var totalSizeText: String   // "Recordings use 1.4 GB" via ByteCountFormatter(.file)
      init(holder: …settings access as other tab models…, folders: any CallRecordingFolderManaging,
           revealer: any FileRevealing)
      var directory: URL
      func choose(_ url: URL)        // sets settings.callRecordingsDirectory = url.path
      func showInFinder()
      func refreshSize() async       // computes off the main actor
  }
  ```
- [ ] **Step 1: Failing tests**
  - `CallLevelMeter.text(0) == "▯▯▯▯▯▯▯▯▯▯"`, `text(0.5) == "▮▮▮▮▮▯▯▯▯▯"`, `text(1.4) == "▮▮▮▮▮▮▮▮▮▮"`, `text(-1)` all empty.
  - `progressText` with and without a speaker.
  - `CallRecordingController.handle(.keyDown(.recordCall))` toggles; `.keyUp(.recordCall)` and other actions do nothing.
  - `CallRecordingsSettingsModel`: `refreshSize` with `FakeCallRecordingFolders.size = 1_400_000_000` → `"Recordings use 1.4 GB"`; `choose` writes the path into settings; default directory shown when unset.
  - `AppModel.route(.keyDown(.recordCall))` reaches the call controller (only if an AppModel routing test pattern exists; otherwise skip).
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement**
  - `AppEnvironment`: `callMicrophone: any CallMicrophoneCapturing` = `EngineCallMicrophoneCapture(engine: AVAudioInputEngine(), devices: audioInputDevices)`; `AppModel` calls `env.callMicrophone.setPreferredInputDevice(uid:)` in the same `settings.didSet` branch that updates `env.recorder`, and once in `start()`. Also `systemAudio: ProcessTapSystemAudioCapture()`, `callRecordingFolders: FileSystemCallRecordingFolders()`, `callTrackWriter: AssetCallTrackWriter.factory`. Mirror in `FakeEnvironment` with the fakes.
  - `AppModel`: `lazy var callRecording = CallRecordingController(…, transcribe: { [unowned self] id in self.fileTranscription.resume(transcriptID: id) }, transcriptsChanged: { reload library })`; `route`: `case .recordCall: callRecording.handle(event)`; `start()`: after `transcriptLibrary.performLaunchMaintenance()` in the same task, `await CallRecordingRecovery(...).recover()` then reload the library; observe `NSWorkspace.shared.notificationCenter` `willSleepNotification` → `Task { await callRecording.systemWillSleep() }`; forward `callRecording.objectWillChange` like `dictation`'s; `fileTranscription`'s `callFinished` → `hud.toast("Call transcript ready", duration: 3)` (check the existing toast duration convention); `shutdown()`: `await callRecording.shutdown()` first, then the existing order.
  - `MacomprendoApp`: `MenuBarExtra { MenuBarView(...) } label: { CallRecordingMenuLabel(controller: model.callRecording) }` — the label shows `Image(systemName: "waveform")` idle and `Image(systemName: "record.circle")` + `Text(TranscriptExporter.clock(elapsed))` while recording. Keep the comment that the status item is deliberately an SF Symbol (invariant 12 exception).
  - `MenuBarView`: before **Transcribe File…**, when `callRecording.isRecording`: `Text("Recording call — \(clock(elapsed))")`, `Text("Me      " + CallLevelMeter.text(levels.me))`, `Text("Others  " + CallLevelMeter.text(levels.others))`, `Button("Stop Recording")` with the shortcut shown like other rows (`HotkeyAction.recordCall.menuTrailing(shortcut:)` pattern); otherwise `Button("Record Call")` → `callRecording.toggle()`. A `.failed(message)` state shows `Text(message)` above the button until the next start.
  - `GeneralTab`: `Section("Call recordings")` — path text (`.truncationMode(.middle)`), **Choose…** (`NSOpenPanel` `canChooseDirectories = true`, `canChooseFiles = false`, `canCreateDirectories = true`), **Show in Finder**, `Text(model.totalSizeText)`; `.task { await model.refreshSize() }`. Construct the model lazily in `AppModel` like `savedAudioModel`.
  - `HotkeysTab`: `KeyboardShortcuts.Recorder("Record Call", name: .recordCall)` matching the existing rows' form.
  - `TranscriptsView`: segment rows already prefixed (Task 3); progress uses the speaker; for `sourceKind == .call` add **Show Recording in Finder** (resolve the bookmark through a controller/library method — not in the view — and `fileRevealer.reveal`); the error banner offers **Choose Folder…** (directory panel → `transcription.resume(transcriptID:fileAt:)`) when `canChooseRecordingFolder`.
- [ ] **Step 4: Run all tests — PASS; `swift build` no new warnings; `npm run gen` no diff.**
- [ ] **Step 5: Commit** — `feat(calls): record calls from the menu bar and a hotkey`

---

### Task 12: Documents

**Files:**
- Create: `docs/adr/0017-call-audio-via-process-tap-with-raw-mic.md`
- Create: `docs/adr/0018-call-recording-folder-layout.md`
- Modify: `docs/ARCHITECTURE.md` (a *Call recording* section), `docs/SMOKE_TEST.md` (complete the Call recording section), `CHANGELOG.md` (`Unreleased`)

- [ ] **Step 1: ADR-0017** (format: copy the headings of `docs/adr/0016-…`): context — mic + whole-system audio, dictation must keep working during a call; decision — global process tap with a tap-only private aggregate, raw microphone, no echo cancellation; why not voice processing (moona3k/macparakeet `docs/research/vpio-process-tap-conflict.md`: with VPIO enabled the tap delivered header-only files, a following dictation engine read silence, and VPIO muffled the user's outgoing call audio); why not ScreenCaptureKit (Screen Recording permission); consequences — echo of the other side can appear under Me over speakers; Bluetooth hands-free tap silence is reported (meetrec) but unverified and accepted; macOS 14.2 minimum.
- [ ] **Step 2: ADR-0018**: folder per recording, names, two `.m4a` tracks (AAC 48 kbit/s, fragmented MP4, 1 s), `recording.json` (schema from the spec), offsets on the host clock with ≥50 ms gap padding, storage apart from transcripts, launch recovery.
- [ ] **Step 3: ARCHITECTURE.md, SMOKE_TEST.md** (add: unplugging the chosen microphone mid-call; dictating during a recording; menu bar timer and level rows with the menu open; quitting mid-recording then `Resume`; killing the app mid-recording and relaunching; a one-hour call with flat memory and playable files), **CHANGELOG** `Unreleased`: "Record calls: microphone and system audio into two files, transcribed with Me / Others labels." and "Requires macOS 14.2 or later."
- [ ] **Step 4: `npm run audit` passes.** Commit — `docs(calls): ADRs, architecture, smoke test and changelog`

---

## Definition of done (whole plan)

- `npm run test:swift`, `npm run test:scripts`, `npm run audit` green; `swift build --package-path macos` without new warnings; `npm run gen` is a no-op; the AGENTS.md xcodebuild command succeeds.
- Smoke test on the operator's Mac is the operator's acceptance step, after the branch is reviewed.
