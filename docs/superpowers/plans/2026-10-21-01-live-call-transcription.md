# Live Call Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optionally transcribe a call recording while it is recorded, so its segments appear in the Transcripts window during the call; after Stop the ordinary call Resume catches up whatever live transcription had not stored.

**Architecture:** Each track's capture handler feeds, besides its writer, a `LiveTrackFeed` that places chunks on the session clock with the writer's own `TrackTimeline` arithmetic, resamples them to 16 kHz and exposes them as a `DecodedAudio`. `LongAudioPipeline` gains a `run` over an already open `DecodedAudio`; a `LiveCallTranscriber` runs one pipeline per track and appends segments to the row `CallRecordingController` creates at Start. Stop stops the live runs and calls the existing `transcribe(id)` (→ `FileTranscriptionController.resume`), whose plan now resumes every track from its own last segment.

**Tech Stack:** Swift 6 strict concurrency, AVFoundation capture already in place, SwiftUI, swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-21-live-call-transcription-design.md`; decision record `docs/adr/0020-live-call-transcription-from-capture.md`.

## Global Constraints

- Layers point downward only (UI → Features → Services/Providers → Core); concrete services are built only in `AppEnvironment` / `AppModel`. Every OS-facing piece sits behind a protocol with a fake in `macos/Tests/MacomprendoTests/Fakes` (AGENTS.md 1–2).
- TDD: write the named test, run it red, implement, run it green. SwiftUI rows are glue covered by `docs/SMOKE_TEST.md` (AGENTS.md 3).
- No transcript text, file name or folder name is logged at default level (AGENTS.md 6). Log lines in this plan carry none.
- Icons only through `Icon(.case)` (AGENTS.md 12).
- New Swift files (sources or tests): `swift test` picks them up by directory, `xcodebuild` does not until `npm run gen` regenerates `macos/Macomprendo.xcodeproj`. Any task that creates a file runs `npm run gen`, stages the project, and a second `npm run gen` must be a no-op (AGENTS.md 10).
- Run one suite with `swift test --package-path macos --filter <SuiteName>`; the full gate is `npm run test:swift` and `npm run test:scripts`, plus `swift build --package-path macos` with no new warnings.
- Conventional commits, one per task. Stage only the paths the task lists (plus the regenerated project). Never push.
- Comments: only a non-obvious reason or trap, one line where possible; no retelling of the code or the spec.
- Each task's report must say what in this plan was wrong, ambiguous or decided by the executor. Do not edit an existing test that contradicts the new behaviour unless this plan names it; leave it red and report it.

## File map

| File | Change |
|---|---|
| `macos/Sources/Macomprendo/Core/Settings.swift` | `CallTranscriptionMode`; `callTranscription` replaces `transcribeCallsAfterRecording`; legacy decode |
| `macos/Sources/Macomprendo/Core/Transcript.swift` | `TranscriptHeader.withDuration(_:)` |
| `macos/Sources/Macomprendo/Services/TranscriptStore.swift` | `setDuration(_:for:)` |
| `macos/Sources/Macomprendo/Services/LiveTrackFeed.swift` | **new** |
| `macos/Sources/Macomprendo/Features/CallTranscriptionPlan.swift` | per-track resume |
| `macos/Sources/Macomprendo/Features/LongAudioPipeline.swift` | `run(_ audio: DecodedAudio, joinGap:)` |
| `macos/Sources/Macomprendo/Features/FileTranscriptionController.swift` | segment normalisation extracted to `TranscriptSegment.normalised` |
| `macos/Sources/Macomprendo/Features/LiveCallTranscriber.swift` | **new** |
| `macos/Sources/Macomprendo/Features/CallRecordingController.swift` | mode at Start, feeds, row at Start, live run, Stop |
| `macos/Sources/Macomprendo/Features/TranscriptLibraryController.swift` | stale comment only |
| `macos/Sources/Macomprendo/App/AppModel.swift` | wiring |
| `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift`, `UI/MenuBar/MenuPanelView.swift`, `UI/MenuBar/CallRecordingPanelSection.swift` | picker, **Show Live Transcript** |
| `docs/SMOKE_TEST.md` | live-call pass |

---

### Task 1: `CallTranscriptionMode` setting and its three call sites

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift` (property at ~359, default at ~408, decode at ~506)
- Modify: `macos/Sources/Macomprendo/Features/CallRecordingController.swift:318`
- Modify: `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift:73-80`
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuPanelView.swift:267-269`
- Test: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift` (`CallRecordingSettingsTests`, ~627), `macos/Tests/MacomprendoTests/Features/CallRecordingControllerTests.swift:425`

**Interfaces — Produces:**

```swift
enum CallTranscriptionMode: String, Codable, Sendable, CaseIterable {
    case whileRecording, afterRecording, manual
    var title: String   // "While recording" / "After recording" / "Manually"
}
// Settings
var callTranscription: CallTranscriptionMode   // default .afterRecording
```

- [ ] **Step 1: Write the failing tests.** In `CallRecordingSettingsTests` replace `callsAreTranscribedAfterStopByDefaultAndTheChoiceRoundTrips` with:

```swift
@Test func callsAreTranscribedAfterRecordingByDefaultAndTheChoiceRoundTrips() throws {
    let json = Data(#"{"schemaVersion":2,"dictationMode":"hold"}"#.utf8)
    #expect(try Settings.migrate(json).callTranscription == .afterRecording)
    #expect(Settings.default.callTranscription == .afterRecording)

    var settings = Settings.default
    settings.callTranscription = .whileRecording
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).callTranscription
            == .whileRecording)
}

@Test func theOldAfterStopSwitchBecomesAMode() throws {
    let on = Data(#"{"schemaVersion":2,"transcribeCallsAfterRecording":true}"#.utf8)
    let off = Data(#"{"schemaVersion":2,"transcribeCallsAfterRecording":false}"#.utf8)
    #expect(try Settings.migrate(on).callTranscription == .afterRecording)
    #expect(try Settings.migrate(off).callTranscription == .manual)
}

@Test func theModeWinsOverTheOldSwitch() throws {
    let json = Data(#"""
        {"schemaVersion":2,"transcribeCallsAfterRecording":false,"callTranscription":"whileRecording"}
        """#.utf8)
    #expect(try Settings.migrate(json).callTranscription == .whileRecording)
}

@Test func theOldSwitchIsNotWrittenAgain() throws {
    let text = String(decoding: try JSONEncoder().encode(Settings.default), as: UTF8.self)
    #expect(!text.contains("transcribeCallsAfterRecording"))
}
```

In `CallRecordingControllerTests.withTranscriptionAfterStopOffTheRowWaitsAndNoJobStarts` change line 425 to `rig.settings.value.callTranscription = .manual` (this plan names it).

- [ ] **Step 2: Run red.** `swift test --package-path macos --filter CallRecordingSettingsTests` — fails to compile (`callTranscription` unknown).

- [ ] **Step 3: Implement.** In `Settings.swift`, next to the other small enums at the top:

```swift
/// When a recorded call is transcribed.
enum CallTranscriptionMode: String, Codable, Sendable, CaseIterable {
    case whileRecording
    case afterRecording
    case manual

    var title: String {
        switch self {
        case .whileRecording: "While recording"
        case .afterRecording: "After recording"
        case .manual: "Manually"
        }
    }
}
```

Replace the property and its doc comment:

```swift
/// When a call is transcribed: live during the recording, as soon as it stops, or only on
/// Resume — the call then waits `incomplete`.
var callTranscription: CallTranscriptionMode
```

Default: `callTranscription: .afterRecording`. Inside `Settings` add

```swift
/// Keys read once to migrate an older settings file and never written again.
private enum LegacyCodingKeys: String, CodingKey {
    case transcribeCallsAfterRecording
}
```

and replace the `transcribeCallsAfterRecording = …` decode with

```swift
callTranscription = try c.decodeIfPresent(CallTranscriptionMode.self, forKey: .callTranscription)
    ?? decoder.container(keyedBy: LegacyCodingKeys.self)
        .decodeIfPresent(Bool.self, forKey: .transcribeCallsAfterRecording)
        .map { $0 ? .afterRecording : .manual }
    ?? d.callTranscription
```

`CallRecordingController.swift:318`: `} else if settings().transcribeCallsAfterRecording {` → `} else if settings().callTranscription != .manual {` (Task 7 replaces this with the mode read at Start).

`GeneralTab.swift`: replace the `Toggle("Transcribe a call as soon as it stops", …)` and its caption `Text` with

```swift
Picker("Transcribe calls", selection: $model.settings.callTranscription) {
    ForEach(CallTranscriptionMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(mode)
    }
}
Text(Self.callTranscriptionCaption(model.settings.callTranscription))
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
```

with, in the view,

```swift
private static func callTranscriptionCaption(_ mode: CallTranscriptionMode) -> String {
    switch mode {
    case .whileRecording:
        "Text appears in Transcripts during the call. Uses the speech model throughout the call."
    case .afterRecording:
        "A call is transcribed as soon as it stops."
    case .manual:
        "A stopped call waits in Transcripts until you press Resume — "
            + "for a busy Mac, or to pick another model first."
    }
}
```

`MenuPanelView.swift`: replace the `PanelSwitchRow(title: "Transcribe calls after Stop", …)` and its `.help` with the pattern the panel already uses for its other choices (lines 105–109):

```swift
VStack(alignment: .leading, spacing: 3) {
    PanelCaption(text: "Transcribe calls")
    PanelPopUpButton(items: CallTranscriptionMode.allCases.map { .init(title: $0.title, value: $0) },
                     selection: $model.settings.callTranscription)
        .accessibilityLabel("Transcribe calls")
}
```

Match the horizontal insets of the surrounding Options rows; if the rows around it are inset with `PanelMetrics.textInset`, apply the same.

- [ ] **Step 4: Run green.** `swift test --package-path macos --filter CallRecordingSettingsTests` and `--filter CallRecordingControllerTests` — PASS. `grep -rn transcribeCallsAfterRecording macos/Sources macos/Tests` shows only `LegacyCodingKeys`, its decode, and the two legacy-JSON tests.

- [ ] **Step 5: Commit.** `feat(calls): transcribe-calls mode replaces the after-Stop switch`

---

### Task 2: `setDuration` in the transcript store

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/TranscriptStore.swift` (protocol ~6-26, implementation next to `setTitle` ~112)
- Modify: `macos/Sources/Macomprendo/Core/Transcript.swift:53` (next to `retitled`)
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptStore.swift` (next to `setTitle`, ~87), `macos/Tests/MacomprendoTests/Fakes/CreateFailingTranscriptStore.swift` (next to `setTitle`, ~50)
- Test: `macos/Tests/MacomprendoTests/Services/TranscriptStoreTests.swift`

**Interfaces — Produces:** `func setDuration(_ duration: TimeInterval, for id: Int64) async throws` on `TranscriptStoring`; `TranscriptHeader.withDuration(_ duration: TimeInterval?) -> TranscriptHeader`.

- [ ] **Step 1: Failing test** in `TranscriptStoreTests`, after `aTitleCanBeChangedAndMissingRowsAreAnError`:

```swift
@Test func aDurationCanBeSetAndMissingRowsAreAnError() async throws {
    let (store, directory) = makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = try await store.create(sourceKind: .call, title: "Call 2026-10-21 12:00",
                                    sourceBookmark: nil, duration: nil, run: run, at: .now)

    try await store.setDuration(754.5, for: id)
    #expect(try await store.transcript(id: id)?.header.duration == 754.5)
    #expect(try await store.headers().first?.duration == 754.5)

    await #expect(throws: MacomprendoError.transcriptStore("no transcript has identifier 42")) {
        try await store.setDuration(1, for: 42)
    }
}
```

- [ ] **Step 2: Run red.** `swift test --package-path macos --filter TranscriptStoreTests`.

- [ ] **Step 3: Implement.** Protocol:

```swift
/// A call transcribed live has its row before its length is known; Stop writes it.
func setDuration(_ duration: TimeInterval, for id: Int64) async throws
```

`SQLiteTranscriptStore`:

```swift
func setDuration(_ duration: TimeInterval, for id: Int64) throws {
    let db = try connection()
    let statement = try prepare("UPDATE transcripts SET duration_s = ?1 WHERE id = ?2", on: db)
    defer { sqlite3_finalize(statement) }
    try check(sqlite3_bind_double(statement, 1, duration), on: db)
    try check(sqlite3_bind_int64(statement, 2, id), on: db)
    try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    try requireOneChange(id, on: db)
}
```

`TranscriptHeader`:

```swift
func withDuration(_ duration: TimeInterval?) -> TranscriptHeader {
    TranscriptHeader(id: id, createdAt: createdAt, sourceKind: sourceKind, title: title,
                     duration: duration, status: status, statusReason: statusReason)
}
```

`FakeTranscriptStore` (same shape as its `setTitle`, without a write counter):

```swift
func setDuration(_ duration: TimeInterval, for id: Int64) throws {
    guard let transcript = transcripts[id] else {
        throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
    }
    transcripts[id] = Transcript(header: transcript.header.withDuration(duration),
                                 run: transcript.run,
                                 sourceBookmark: transcript.sourceBookmark,
                                 summary: transcript.summary, segments: transcript.segments)
}
```

`CreateFailingTranscriptStore`: `func setDuration(_ duration: TimeInterval, for id: Int64) async throws { try await inner.setDuration(duration, for: id) }`.

- [ ] **Step 4: Run green.** `--filter TranscriptStoreTests`; `swift build --package-path macos`.

- [ ] **Step 5: Commit.** `feat(transcripts): store can set a transcript's duration`

---

### Task 3: Call Resume continues every track from its own end

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/CallTranscriptionPlan.swift:17-43`
- Test: `macos/Tests/MacomprendoTests/Features/CallTranscriptionPlanTests.swift`

**Interfaces:** `CallTranscriptionPlan.steps(manifest:stored:) -> [CallTranscriptionStep]` — signature unchanged.

- [ ] **Step 1: Tests.** Replace `tracksBeforeTheLastStoredOneAreDone` (this plan names it; it encodes the old rule) with:

```swift
@Test func aTrackWithoutSegmentsRunsFromZeroEvenBeforeAStoredOne() {
    // Live transcription stores both sides at once: Others having segments says nothing about Me.
    let steps = CallTranscriptionPlan.steps(
        manifest: Self.manifest(me: 0.2, others: 0.5),
        stored: [Self.segment(end: 50.0, speaker: .others)])
    #expect(steps == [Self.step(.me, offset: 0.2, from: 0),
                      Self.step(.others, offset: 0.5, from: 49.5)])
}

@Test func bothTracksWithSegmentsResumeEachFromItsOwnEnd() {
    let steps = CallTranscriptionPlan.steps(
        manifest: Self.manifest(me: 0.2, others: 0.5),
        stored: [Self.segment(end: 30.0, speaker: .me),
                 Self.segment(end: 41.0, speaker: .others),
                 Self.segment(end: 45.0, speaker: .me)])
    #expect(steps == [Self.step(.me, offset: 0.2, from: 44.8),
                      Self.step(.others, offset: 0.5, from: 40.5)])
}
```

- [ ] **Step 2: Run red.** `swift test --package-path macos --filter CallTranscriptionPlanTests` — the two new tests fail.

- [ ] **Step 3: Implement.** Replace the body and its doc comment:

```swift
/// The tracks in order Me, Others; a track with no `startOffset` never produced audio and is
/// skipped. Each track resumes from the end of its own last stored segment (track-local, so the
/// file's own offset comes back off), or from 0 without one — live transcription stores both
/// tracks at once, so no track is done because another has segments (ADR-0020).
static func steps(manifest: CallRecordingManifest,
                  stored: [TranscriptSegment]) -> [CallTranscriptionStep] {
    [TranscriptSpeaker.me, .others].compactMap { speaker in
        guard let track = manifest.track(speaker), let offset = track.startOffset else {
            return nil
        }
        let lastEnd = stored.filter { $0.speaker == speaker }.map(\.end).max()
        // A stored end before the track's own offset would ask for a negative start; it
        // cannot mean anything but "from the beginning".
        return CallTranscriptionStep(speaker: speaker, file: track.file, offset: offset,
                                     from: max(0, (lastEnd ?? offset) - offset))
    }
}
```

- [ ] **Step 4: Run green.** `--filter CallTranscriptionPlanTests` and `--filter FileTranscriptionControllerTests` (its call-resume tests, e.g. `aCallResumeContinuesTheHalfDoneTrackThenTheRest`, must still pass; report any that does not).

- [ ] **Step 5: Commit.** `feat(calls): call resume continues each track from its own last segment`

---

### Task 4: `LongAudioPipeline` runs an already open stream

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/LongAudioPipeline.swift:72-120`
- Test: `macos/Tests/MacomprendoTests/Features/LongAudioPipelineTests.swift`

**Interfaces — Produces:**

```swift
func run(_ audio: DecodedAudio,
         joinGap: TimeInterval = SpeechSpanAssembler.joinGap) -> AsyncThrowingStream<LongAudioEvent, Error>
```

Same events, errors, cancellation, `stop()` and `awaitCompletion()` as `run(_:from:joinGap:)`; `opened` carries `audio.duration`.

- [ ] **Step 1: Failing test:**

```swift
@Test func anAlreadyOpenStreamRunsLikeAFileWithoutTheDecoder() async throws {
    let decoder = ScriptedMediaDecoder()
    let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)], [Self.segment(at: 1)]])
    let provider = FakeTranscriptionProvider()
    let chunks = AsyncThrowingStream<[Float], Error> { continuation in
        continuation.yield(Self.second())
        continuation.yield(Self.second())
        continuation.finish()
    }

    let events = try await collect(
        make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
            .run(DecodedAudio(duration: 0, startOffset: 0, chunks: chunks)))

    #expect(events == [
        .opened(duration: 0),
        .segment(start: 0, end: 1, text: "hello"),
        .position(1),
        .segment(start: 1, end: 2, text: "hello"),
        .position(2),
    ])
    #expect(decoder.requests.isEmpty)
}
```

- [ ] **Step 2: Run red.** `--filter LongAudioPipelineTests`.

- [ ] **Step 3: Implement.** Keep the producer body unchanged except its first line; route both public entry points through one private one:

```swift
func run(_ url: URL, from start: TimeInterval,
         joinGap: TimeInterval = SpeechSpanAssembler.joinGap)
    -> AsyncThrowingStream<LongAudioEvent, Error> {
    run(opening: { [decoder] in try await decoder.open(url, from: start) }, joinGap: joinGap)
}

/// The same run over audio that is already open — a call track's live feed (ADR-0020).
func run(_ audio: DecodedAudio,
         joinGap: TimeInterval = SpeechSpanAssembler.joinGap)
    -> AsyncThrowingStream<LongAudioEvent, Error> {
    run(opening: { audio }, joinGap: joinGap)
}

private func run(opening open: @escaping @Sendable () async throws -> DecodedAudio,
                 joinGap: TimeInterval) -> AsyncThrowingStream<LongAudioEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let decoded = try await open()
                // … the rest of today's body, unchanged …
```

Keep the existing doc comment on the URL `run`.

- [ ] **Step 4: Run green.** `--filter LongAudioPipelineTests` (all old tests too).

- [ ] **Step 5: Commit.** `feat(transcription): long-audio pipeline runs an already open audio stream`

---

### Task 5: `LiveTrackFeed`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/LiveTrackFeed.swift`
- Test: `macos/Tests/MacomprendoTests/Services/LiveTrackFeedTests.swift`

**Interfaces — Consumes:** `CallAudioSink` (`CallTrackWriter.swift:42`), `TrackTimeline`, `PCMResampler` (`AudioMath.swift:53`), `AssetCallTrackWriter.sampleRate` (48 000), `AVAssetMediaDecoder.sampleRate` (16 000).
**Produces:**

```swift
final class LiveTrackFeed: CallAudioSink, @unchecked Sendable {
    init(sessionStart: TimeInterval)
    let audio: DecodedAudio                 // 16 kHz mono, duration 0, startOffset 0
    var startOffset: TimeInterval? { get }  // as the writer's
    func consume(_ samples: [Float], at time: TimeInterval)
    func finish()
}
```

- [ ] **Step 1: Failing tests.**

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct LiveTrackFeedTests {
    private static let sessionStart: TimeInterval = 1_000
    private static func capture(seconds: Double, level: Float = 0.5) -> [Float] {
        [Float](repeating: level, count: Int(seconds * AssetCallTrackWriter.sampleRate))
    }

    private func drain(_ feed: LiveTrackFeed) async throws -> [Float] {
        feed.finish()
        var out: [Float] = []
        for try await chunk in feed.audio.chunks { out += chunk }
        return out
    }

    @Test func aTwoSecondHoleBecomesTwoSecondsOfSilenceAt16kHz() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 3)

        let out = try await drain(feed)
        #expect(abs(out.count - 64_000) <= 2)
        #expect(out[16_010..<47_990].allSatisfy { $0 == 0 })
        #expect(out[48_010..<63_990].allSatisfy { $0 == 0.5 })
    }

    @Test func aHoleUnderFiftyMillisecondsIsNotPadded() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 1.03)

        let out = try await drain(feed)
        #expect(abs(out.count - 32_000) <= 2)
    }

    @Test func theStartOffsetMatchesTheWritersTimeline() {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        #expect(feed.startOffset == nil)
        feed.consume(Self.capture(seconds: 0.01), at: Self.sessionStart + 0.25)
        var timeline = TrackTimeline(sampleRate: AssetCallTrackWriter.sampleRate,
                                     sessionStart: Self.sessionStart)
        _ = timeline.place(frames: 480, at: Self.sessionStart + 0.25)
        #expect(feed.startOffset == timeline.startOffset)
    }

    @Test func anEmptyChunkDoesNotClaimTheFirstSample() {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume([], at: Self.sessionStart + 5)
        #expect(feed.startOffset == nil)
    }

    @Test func finishEndsTheStreamAndLaterAudioIsDropped() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        let out = try await drain(feed)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 1)
        #expect(abs(out.count - 16_000) <= 2)
    }
}
```

- [ ] **Step 2: Run red.** `swift test --package-path macos --filter LiveTrackFeedTests` — does not compile.

- [ ] **Step 3: Implement** `LiveTrackFeed.swift`:

```swift
import Foundation

/// One call track's capture for live transcription: placed on the session clock by the same
/// `TrackTimeline` arithmetic as the track writer, so its times are the track file's times, and
/// resampled to the 16 kHz the pipeline reads. Unbounded: a slow model makes it grow (ADR-0020).
final class LiveTrackFeed: CallAudioSink, @unchecked Sendable {
    let audio: DecodedAudio
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let lock = NSLock()
    private var timeline: TrackTimeline
    private var resampler = PCMResampler(inputRate: AssetCallTrackWriter.sampleRate,
                                         outputRate: Double(AVAssetMediaDecoder.sampleRate))

    init(sessionStart: TimeInterval) {
        let (chunks, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        audio = DecodedAudio(duration: 0, startOffset: 0, chunks: chunks)
        self.continuation = continuation
        timeline = TrackTimeline(sampleRate: AssetCallTrackWriter.sampleRate,
                                 sessionStart: sessionStart)
    }

    var startOffset: TimeInterval? {
        lock.withLock { timeline.startOffset }
    }

    func consume(_ samples: [Float], at time: TimeInterval) {
        // An empty chunk would claim the track's first sample without any audio, as in the writer.
        guard !samples.isEmpty else { return }
        let output = lock.withLock {
            let pad = timeline.place(frames: samples.count, at: time)
            return resampler.resample([Float](repeating: 0, count: pad) + samples)
        }
        if !output.isEmpty { continuation.yield(output) }
    }

    func finish() {
        continuation.finish()
    }
}
```

- [ ] **Step 4: Run green.** `--filter LiveTrackFeedTests`. If a count tolerance fails by a few samples, widen it only after checking `PCMResampler`'s pending-tail behaviour explains it; report it.

- [ ] **Step 5:** `npm run gen` (twice; second is a no-op). **Commit.** `feat(calls): live feed of a call track on the session clock at 16 kHz`

---

### Task 6: `LiveCallTranscriber` and shared segment normalisation

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/FileTranscriptionController.swift:478-491` (extract), append the extension at the end of the file
- Create: `macos/Sources/Macomprendo/Features/LiveCallTranscriber.swift`
- Test: `macos/Tests/MacomprendoTests/Features/LiveCallTranscriberTests.swift`

**Interfaces — Consumes:** `LongAudioPipeline.run(_ audio: DecodedAudio, joinGap:)` (Task 4), `LiveTrackFeed` (Task 5).
**Produces:**

```swift
extension TranscriptSegment {
    static func normalised(text: String, start: TimeInterval, end: TimeInterval,
                           speaker: TranscriptSpeaker?, settings: Settings,
                           glossary: Glossary) -> TranscriptSegment
}

@MainActor
final class LiveCallTranscriber {
    init(transcriptID: Int64, store: any TranscriptStoring,
         pipeline: @escaping @MainActor () -> LongAudioPipeline,
         settings: Settings, glossary: Glossary,
         transcriptsChanged: @escaping @MainActor () -> Void)
    func start(_ feed: LiveTrackFeed, speaker: TranscriptSpeaker)
    /// Returns once no run can append again and neither holds its provider.
    func stop() async
}
```

- [ ] **Step 1: Extract the normaliser (refactor, no test change).** Append to `FileTranscriptionController.swift`:

```swift
extension TranscriptSegment {
    /// A transcribed segment as it is stored: glossary-normalised when the glossary is on,
    /// the provider's text kept as `rawText` only when a rewrite changed it.
    static func normalised(text: String, start: TimeInterval, end: TimeInterval,
                           speaker: TranscriptSpeaker?, settings: Settings,
                           glossary: Glossary) -> TranscriptSegment {
        let result = settings.glossaryEnabled
            ? Normalizer.normalise(text, with: glossary)
            : NormalisationResult(text: text, rewrites: [])
        return TranscriptSegment(start: start, end: end, text: result.text,
                                 rawText: result.rewrites.isEmpty ? nil : text,
                                 speaker: speaker)
    }
}
```

and in `consume`'s `.segment` case use it:

```swift
case let .segment(segmentStart, segmentEnd, text):
    guard let id = progress.transcriptID else { continue }
    try await store.appendSegment(
        .normalised(text: text, start: segmentStart + timeShift,
                    end: segmentEnd + timeShift, speaker: speaker,
                    settings: settings, glossary: glossary),
        to: id)
    progress.storedSegments += 1
    transcriptsChanged()
```

Run `--filter FileTranscriptionControllerTests` — green.

- [ ] **Step 2: Failing tests** `LiveCallTranscriberTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct LiveCallTranscriberTests {
    private static let sessionStart: TimeInterval = 1_000
    private static let oneSecond = [Float](repeating: 0.5,
                                           count: Int(AssetCallTrackWriter.sampleRate))

    /// One fresh pipeline per call, each with its own segmenter that turns its first chunk into
    /// one segment at 0, and the provider at the same index.
    private func pipelines(_ providers: [FakeTranscriptionProvider])
        -> @MainActor () -> LongAudioPipeline {
        let next = Box(0)
        return {
            let provider = providers[next.value]
            next.value += 1
            let segment = SpeechSegment(start: 0,
                                        samples: [Float](repeating: 0.1,
                                                         count: AVAssetMediaDecoder.sampleRate),
                                        sampleRate: AVAssetMediaDecoder.sampleRate)
            return LongAudioPipeline(decoder: ScriptedMediaDecoder(),
                                     segmenter: ScriptedSegmenter(acceptScript: [[segment]]),
                                     transcriber: { provider }, language: nil)
        }
    }

    private func makeRow(_ store: FakeTranscriptStore) async throws -> Int64 {
        try await store.create(sourceKind: .call, title: "Call", sourceBookmark: nil,
                               duration: nil, run: TranscriptionRun.from(
                                   Settings.default.transcriptionSource, language: nil),
                               at: .now)
    }

    @Test func segmentsFromBothTracksLandWithSpeakerAndTheirTracksOffset() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let changes = Box(0)
        let live = LiveCallTranscriber(
            transcriptID: id, store: store,
            pipeline: pipelines([FakeTranscriptionProvider(), FakeTranscriptionProvider()]),
            settings: .default, glossary: Glossary(),
            transcriptsChanged: { changes.value += 1 })
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        let others = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        live.start(others, speaker: .others)

        me.consume(Self.oneSecond, at: Self.sessionStart + 0.25)
        others.consume(Self.oneSecond, at: Self.sessionStart + 0.5)
        // `waitFor` polls synchronously; `transcriptsChanged` fires after each append lands.
        await waitFor("both tracks' segments to be stored") { changes.value == 2 }
        await live.stop()

        let segments = try #require(await store.snapshot(id)?.segments)
        #expect(Set(segments.map(\.speaker)) == [.me, .others])
        #expect(segments.first { $0.speaker == .me }?.start == 0.25)
        #expect(segments.first { $0.speaker == .others }?.start == 0.5)
        #expect(changes.value == 2)
    }

    @Test func aFailingTrackLeavesTheOtherRunning() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let failing = FakeTranscriptionProvider()
        failing.result = .failure(MacomprendoError.transcriptStore("boom"))
        let changes = Box(0)
        let live = LiveCallTranscriber(
            transcriptID: id, store: store,
            pipeline: pipelines([failing, FakeTranscriptionProvider()]),
            settings: .default, glossary: Glossary(),
            transcriptsChanged: { changes.value += 1 })
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        let others = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        live.start(others, speaker: .others)

        me.consume(Self.oneSecond, at: Self.sessionStart)
        others.consume(Self.oneSecond, at: Self.sessionStart)
        await waitFor("the Others segment to be stored") { changes.value == 1 }
        await live.stop()
        #expect(await store.snapshot(id)?.segments.map(\.speaker) == [.others])
    }

    @Test func stopReturnsWithTheFeedsStillOpenAndNothingIsAppendedAfter() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let provider = FakeTranscriptionProvider()
        let gate = AsyncGate()
        provider.gate = gate
        let live = LiveCallTranscriber(
            transcriptID: id, store: store, pipeline: pipelines([provider]),
            settings: .default, glossary: Glossary(), transcriptsChanged: {})
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        me.consume(Self.oneSecond, at: Self.sessionStart)
        await waitFor("the segment to reach the provider") { provider.received.count == 1 }

        let stopped = Task { await live.stop() }
        gate.open()
        await stopped.value

        #expect(await store.snapshot(id)?.segments.isEmpty == true)
    }
}
```

`waitFor` (`Support/Wait.swift:19`) takes a synchronous `@MainActor` condition, so it cannot read the actor store; tests wait on the `transcriptsChanged` count instead. `AsyncGate.open()` is synchronous (`Support/AsyncGate.swift:40`). The failing provider retries three times with the pipeline's default 1 s delay — if that makes the test slow, report it rather than adding a delay parameter.

- [ ] **Step 3: Run red.** `--filter LiveCallTranscriberTests` — does not compile.

- [ ] **Step 4: Implement** `LiveCallTranscriber.swift`:

```swift
import Foundation

/// Transcribes a call's tracks while it is recorded: one `LongAudioPipeline` run per track over
/// its `LiveTrackFeed`, each segment appended to the call's row as soon as it is transcribed. A
/// run that fails just ends; the catch-up after Stop transcribes that track from its file.
@MainActor
final class LiveCallTranscriber {
    private let transcriptID: Int64
    private let store: any TranscriptStoring
    private let pipeline: @MainActor () -> LongAudioPipeline
    private let settings: Settings
    private let glossary: Glossary
    private let transcriptsChanged: @MainActor () -> Void
    private var runs: [(pipeline: LongAudioPipeline, task: Task<Void, Never>)] = []

    init(transcriptID: Int64, store: any TranscriptStoring,
         pipeline: @escaping @MainActor () -> LongAudioPipeline,
         settings: Settings, glossary: Glossary,
         transcriptsChanged: @escaping @MainActor () -> Void) {
        self.transcriptID = transcriptID
        self.store = store
        self.pipeline = pipeline
        self.settings = settings
        self.glossary = glossary
        self.transcriptsChanged = transcriptsChanged
    }

    func start(_ feed: LiveTrackFeed, speaker: TranscriptSpeaker) {
        let pipeline = pipeline()
        let task = Task { [store, transcriptID, settings, glossary, transcriptsChanged] in
            do {
                for try await event in pipeline.run(feed.audio,
                                                    joinGap: SpeechSpanAssembler.callJoinGap) {
                    guard case let .segment(start, end, text) = event else { continue }
                    try Task.checkCancellation()
                    // A segment needs audio before it, so the first chunk has set the offset.
                    let shift = feed.startOffset ?? 0
                    try await store.appendSegment(
                        .normalised(text: text, start: start + shift, end: end + shift,
                                    speaker: speaker, settings: settings, glossary: glossary),
                        to: transcriptID)
                    transcriptsChanged()
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("Live transcription of a call track stopped; Stop catches it up")
            }
        }
        runs.append((pipeline, task))
    }

    func stop() async {
        for run in runs {
            run.pipeline.stop()
            run.task.cancel()
        }
        for run in runs {
            await run.task.value
            await run.pipeline.awaitCompletion()
        }
        runs = []
    }
}
```

- [ ] **Step 5: Run green.** `--filter LiveCallTranscriberTests`, `--filter FileTranscriptionControllerTests`.

- [ ] **Step 6:** `npm run gen` (twice). **Commit.** `feat(calls): live call transcriber appends segments while recording`

---

### Task 7: `CallRecordingController` runs live transcription in `whileRecording`

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/CallRecordingController.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift:111-160`
- Modify: `macos/Sources/Macomprendo/Features/TranscriptLibraryController.swift:154` (comment only)
- Test: `macos/Tests/MacomprendoTests/Features/CallRecordingControllerTests.swift`

**Interfaces — Consumes:** `CallTranscriptionMode` (Task 1), `setDuration` (Task 2), `LiveTrackFeed` (Task 5), `LiveCallTranscriber` (Task 6).
**Produces:** `CallRecordingController.init(…, liveTranscriber: @escaping @MainActor (Int64) -> LiveCallTranscriber, transcribe: …, transcriptsChanged: …)`; `@Published private(set) var liveTranscriptID: Int64?` — the row being filled live, `nil` otherwise.

Behaviour (spec *While recording*, *Stop*, *Quit and crash*):
- The mode is read once at Start into `mode`.
- `whileRecording`: two feeds made with the writers' `sessionStart`; each capture handler calls `writer.consume` then `feed?.consume`. After both captures start and **before** `state = .recording` (so a stop arriving meanwhile becomes `pendingStop`, and never runs alongside), the row is created (`duration: nil`, `at: now()`), the live transcriber is built and started for both feeds, `liveTranscriptID` set, `transcriptsChanged()` called. If `create` throws: log, finish both feeds, `mode = .afterRecording`, continue.
- Stop: captures stop → `meFeed?.finish(); othersFeed?.finish()` → `await live?.stop()` → writers finish → offsets → row: the live row gets `setDuration(duration)` (failure → `remember`), otherwise today's `create` → manifest `finished` → quit: `incomplete` / `abandonedJobReason`; `mode != .manual`: `transcribe(id)`; `manual`: `incomplete` / `notTranscribedYetReason`.
- `resetSession()` clears feeds, `live`, `liveTranscriptID`, and resets `mode` to `.afterRecording`.

- [ ] **Step 1: Rig.** In `Rig.init`, add before `controller = …`:

```swift
let liveSegment = SpeechSegment(start: 0,
                                samples: [Float](repeating: 0.1,
                                                 count: AVAssetMediaDecoder.sampleRate),
                                sampleRate: AVAssetMediaDecoder.sampleRate)
let live: @MainActor (Int64) -> LiveCallTranscriber = { id in
    LiveCallTranscriber(
        transcriptID: id, store: storeCreateFailure,
        pipeline: {
            LongAudioPipeline(decoder: ScriptedMediaDecoder(),
                              segmenter: ScriptedSegmenter(acceptScript: [[liveSegment]]),
                              transcriber: { FakeTranscriptionProvider() }, language: nil)
        },
        settings: settings.value, glossary: Glossary(),
        transcriptsChanged: { changes.value += 1 })
}
```

and pass `liveTranscriber: live,` to the controller.

- [ ] **Step 2: Failing tests** (new `// MARK: - Live transcription` section):

```swift
@Test func whileRecordingCreatesTheRowAtStartAndFillsItFromTheCapture() async throws {
    let rig = try Rig()
    rig.settings.value.callTranscription = .whileRecording
    await startRecording(rig)

    let row = await rig.store.snapshot(1)
    #expect(row?.header.sourceKind == .call)
    #expect(row?.header.status == .inProgress)
    #expect(row?.header.duration == nil)
    #expect(row?.sourceBookmark == Data(rig.folder.path.utf8))
    #expect(rig.controller.liveTranscriptID == 1)

    rig.microphone.emit(CallAudioChunk(
        samples: [Float](repeating: 0.5, count: Int(AssetCallTrackWriter.sampleRate)),
        time: CallTestTime.sessionStart + 0.25))
    // One change for the row at Start, one for the segment.
    await waitFor("the live Me segment to be stored") { rig.changes.value == 2 }
    let segment = try #require(await rig.store.snapshot(1)?.segments.first)
    #expect(segment.speaker == .me)
    #expect(segment.start == 0.25)
    await rig.controller.stop()
}

@Test func whileRecordingStopSetsTheDurationAndCatchesUpTheSameRow() async throws {
    let rig = try Rig()
    rig.settings.value.callTranscription = .whileRecording
    await startRecording(rig)
    rig.nowValue.value = rig.nowValue.value.addingTimeInterval(5)

    await rig.controller.stop()

    #expect(rig.transcribes.value == [1])
    #expect(await rig.store.snapshot(1)?.header.duration == 5)
    #expect(await rig.store.snapshot(2) == nil)
    #expect(try CallRecordingManifest.read(from: rig.folder).status == .finished)
    #expect(rig.controller.liveTranscriptID == nil)
    #expect(rig.controller.state == .idle)
}

@Test func whileRecordingQuitLeavesTheRowIncompleteWithoutCatchUp() async throws {
    let rig = try Rig()
    rig.settings.value.callTranscription = .whileRecording
    await startRecording(rig)

    await rig.controller.shutdown()

    let row = await rig.store.snapshot(1)
    #expect(row?.header.status == .incomplete)
    #expect(row?.header.statusReason == TranscriptLibraryController.abandonedJobReason)
    #expect(rig.transcribes.value.isEmpty)
}

@Test func whileRecordingWithoutARowAtStartRecordsAndTranscribesAfterStop() async throws {
    let rig = try Rig(createFailure: .transcriptStore("full"))
    rig.settings.value.callTranscription = .whileRecording
    await startRecording(rig)
    #expect(rig.controller.liveTranscriptID == nil)

    await rig.controller.stop()

    #expect(rig.transcribes.value.count == 1)
    #expect(rig.controller.state == .idle)
}

@Test func theModeIsReadAtStart() async throws {
    let rig = try Rig()
    rig.settings.value.callTranscription = .manual
    await startRecording(rig)
    rig.settings.value.callTranscription = .afterRecording

    await rig.controller.stop()

    #expect(rig.transcribes.value.isEmpty)
    #expect(await rig.store.snapshot(1)?.header.statusReason
            == CallRecordingController.notTranscribedYetReason)
}
```

Check `FakeTranscriptStore.snapshot` returns `nil` for a missing id and that `CreateFailingTranscriptStore.failNextCreateOnce` fails exactly the first `create`; adapt and report if not.

- [ ] **Step 3: Run red.** `--filter CallRecordingControllerTests`.

- [ ] **Step 4: Implement.**

New state (next to the writers):

```swift
private let makeLiveTranscriber: @MainActor (Int64) -> LiveCallTranscriber
/// The transcript row being filled live; `nil` unless this recording runs `whileRecording`.
@Published private(set) var liveTranscriptID: Int64?
/// Read once at Start: a change during the recording is for the next one.
private var mode: CallTranscriptionMode = .afterRecording
private var meFeed: LiveTrackFeed?
private var othersFeed: LiveTrackFeed?
private var live: LiveCallTranscriber?
```

`init` gains `liveTranscriber: @escaping @MainActor (Int64) -> LiveCallTranscriber,` before `transcribe:`; assign `self.makeLiveTranscriber = liveTranscriber`.

In `runStart`, after `let sessionStart = clock()`:

```swift
mode = settings().callTranscription
if mode == .whileRecording {
    meFeed = LiveTrackFeed(sessionStart: sessionStart)
    othersFeed = LiveTrackFeed(sessionStart: sessionStart)
}
```

The two `start` calls become `handler(writer: meWriter, feed: meFeed, speaker: .me, box: box)` and the same for Others. After the `do/catch` that starts capture and before `self.folder = folder`:

```swift
if mode == .whileRecording {
    await startLive(folder: folder, startedAt: startedAt)
}
```

```swift
/// Runs while still `.starting`, so a stop arriving now waits as `pendingStop`.
private func startLive(folder: URL, startedAt: Date) async {
    guard let meFeed, let othersFeed else { return }
    do {
        let id = try await store.create(
            sourceKind: .call,
            title: CallRecordingLayout.transcriptTitle(startedAt: startedAt),
            sourceBookmark: try? bookmarks.bookmark(for: folder),
            duration: nil,
            run: TranscriptionRun.from(settings().transcriptionSource,
                                       language: settings().transcriptionLanguage),
            at: now())
        let live = makeLiveTranscriber(id)
        live.start(meFeed, speaker: .me)
        live.start(othersFeed, speaker: .others)
        self.live = live
        liveTranscriptID = id
        transcriptsChanged()
    } catch {
        // No row, no live text: the call is still recorded and transcribed after Stop.
        Log.app.error("Live call transcription could not create its transcript")
        meFeed.finish()
        othersFeed.finish()
        mode = .afterRecording
    }
}
```

In `runStop`, right after `systemAudio.stop()`:

```swift
meFeed?.finish()
othersFeed?.finish()
await live?.stop()
```

Replace the row creation block with:

```swift
let id: Int64
if let liveID = liveTranscriptID {
    id = liveID
    do { try await store.setDuration(duration, for: id) } catch { remember(error) }
} else {
    do {
        id = try await store.create(…today's arguments unchanged…)
    } catch {
        endStop(error)
        return
    }
}
```

The decision: `} else if mode != .manual {` replaces Task 1's `settings().callTranscription != .manual`.

`handler`:

```swift
private func handler(writer: any CallTrackWriting, feed: LiveTrackFeed?,
                     speaker: TranscriptSpeaker,
                     box: CallLevelBox) -> @Sendable (CallAudioChunk) -> Void {
    { chunk in
        box.store(AudioMath.level(fromRMS: AudioMath.rms(chunk.samples)), for: speaker)
        writer.consume(chunk.samples, at: chunk.time)
        feed?.consume(chunk.samples, at: chunk.time)
    }
}
```

`resetSession()` adds `meFeed = nil; othersFeed = nil; live = nil; liveTranscriptID = nil; mode = .afterRecording`. `abortStart` also calls `meFeed?.finish(); othersFeed?.finish()` (no live exists yet there).

`AppModel.swift`: add a private helper and use it for `fileTranscription`'s `pipeline:` too:

```swift
private func longAudioPipeline() -> LongAudioPipeline {
    LongAudioPipeline(decoder: env.mediaDecoder, segmenter: env.speechSegmenter,
                      transcriber: backgroundTranscriberProvider,
                      language: settings.transcriptionLanguage)
}
```

(`env` must be reachable from a method; if it is only a constructor local, keep the closure inline twice and report.) Then in `callRecording`:

```swift
liveTranscriber: { [unowned self] id in
    LiveCallTranscriber(
        transcriptID: id, store: env.transcriptStore,
        pipeline: { [unowned self] in self.longAudioPipeline() },
        settings: self.settings, glossary: self.glossary,
        transcriptsChanged: { [weak self] in Task { await self?.transcriptLibrary.reload() } })
},
```

`TranscriptLibraryController.swift:154`: the parenthesis `(A call has no row at all until its recording stops.)` becomes `(A call recorded live has its row, in progress, from Start.)`.

- [ ] **Step 5: Run green.** `--filter CallRecordingControllerTests`, then `npm run test:swift`; `swift build --package-path macos` with no new warnings.

- [ ] **Step 6: Commit.** `feat(calls): transcribe a call live while it records`

---

### Task 8: **Show Live Transcript**, smoke test, docs

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/CallRecordingPanelSection.swift`
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuPanelView.swift:37` and next to `openTranscripts()` (~218)
- Modify: `docs/SMOKE_TEST.md` (new section after `## Automatic call recording`)

- [ ] **Step 1: Panel button.** `CallRecordingPanelSection` gains `var showLiveTranscript: (Int64) -> Void = { _ in }`. At the end of `recordingGroup`, after the two `meterRow`s (last, so a button appearing never moves a row under the pointer):

```swift
if let id = controller.liveTranscriptID {
    Button {
        showLiveTranscript(id)
    } label: {
        HStack(spacing: 6) {
            Icon(.folder, size: 14)
            Text("Show Live Transcript")
        }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
}
```

`MenuPanelView`: `CallRecordingPanelSection(controller: model.callRecording, showLiveTranscript: showLiveTranscript)` and

```swift
private func showLiveTranscript(_ id: Int64) {
    routeAfterClosing {
        openWindow(id: WindowID.transcripts)
        Task { await model.transcriptLibrary.select(id) }
    }
}
```

If opening the window resets the selection (check `TranscriptsView`'s `.onAppear`/`.task`), select after it instead and report how.

- [ ] **Step 2: Smoke test section** in `docs/SMOKE_TEST.md`, following the format of `## Call recording`:

```markdown
## Live call transcription

Settings ▸ General ▸ **Transcribe calls**: **While recording**; a local model selected.

1. Start a call that plays through the speakers (a video call, or a podcast plus speaking).
   **Record Call**. The panel shows **Show Live Transcript** under the meters.
2. **Show Live Transcript** opens Transcripts with `Call <date>` selected, *In progress*.
   Speak a phrase and pause: within a few seconds a `Me:` row appears; the remote side's
   phrases appear as `Others:` rows, in spoken order.
3. During the call, dictate into another app: the dictation returns without a noticeable delay.
4. **Stop Recording**. The progress row reads `Transcribing Me — …`, then the toast
   *Call transcript ready*; the transcript is *Complete*, shows its duration, and holds no
   duplicated phrase at the moment of Stop.
5. Repeat with **Manually** and **After recording**: no live rows, and Stop behaves as before.
6. Quit Macomprendo during a live recording: on relaunch the call is *Incomplete*;
   **Resume** finishes it without duplicating the live rows.
```

- [ ] **Step 3: Build and manual check.** `swift build --package-path macos`; `npm run test:swift`; `npm run test:scripts`; `npm run audit`. Run steps 1–2 of the smoke section with `npm run install-app:signed` if the operator is at the Mac; otherwise report it as not run.

- [ ] **Step 4: Commit.** `feat(calls): show live transcript from the panel; smoke test`

---

## Spec coverage

| Spec requirement | Task |
|---|---|
| Three-mode setting, migration, default, old key not written | 1 |
| Settings ▸ General picker and caption; panel picker | 1 |
| Mode read once at Start | 7 (`theModeIsReadAtStart`) |
| Row at Start, `inProgress`, no duration; fallback when it cannot be created | 7 |
| Two concurrent runs at background priority | 6 (one pipeline per track), 7 wiring through `backgroundTranscriberProvider` |
| Offsets, speaker, `appendSegment`, `transcriptsChanged` | 6 |
| A failing track ends alone | 6 |
| Show Live Transcript | 8 |
| Stop order; abandon in-flight; `setDuration`; catch-up via `transcribe(id)` | 2, 7 |
| Per-track resume | 3 |
| Quit / crash | 7 (quit test); crash needs no code: `markAbandonedJobs` turns `inProgress` → `incomplete` and recovery sees the bookmark |
| Live feed: timeline, padding, 16 kHz | 5 |
| Pipeline over an open stream | 4 |
| Smoke pass | 8 |
