# Transcript Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play a transcript's audio in the Transcripts window: a player bar (seek bar, play/pause,
±15 s, speed, Me/Others toggles for calls) and an accent marker on the playing segment, with
follow-scrolling and clickable timestamps.

**Architecture:** Core holds the pure `PlaybackSource` and `PlaybackTimeline`. Services build the
`AVAsset` (`PlaybackComposition`: a file asset, or an `AVMutableComposition` placing each call
track at its `startOffset`) and play it through `TranscriptAudioPlaying` (`AVPlayer`). A
`@MainActor` `TranscriptPlaybackController` resolves the source from the transcript's bookmark
and drives the player; the SwiftUI view renders the bar, the marker and follow.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI + AppKit, AVFoundation (`AVPlayer`,
`AVMutableComposition`, `AVAudioMix`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-10-16-transcript-playback-design.md`

## Global Constraints

- Layers point downward only: UI → Features → Services/Providers → Core; no concrete service is
  constructed outside `AppEnvironment` (AGENTS.md invariant 1).
- OS-facing code sits behind a protocol declared next to its default implementation, with a fake
  in `macos/Tests/MacomprendoTests/Fakes` (invariant 2).
- TDD: a failing test before every behaviour; `AVPlayer` glue, the marker's look and follow are
  covered by `docs/SMOKE_TEST.md` (invariant 3).
- Never log transcript text or file paths at default level (invariant 6).
- Swift 6 strict concurrency; controllers are `@MainActor`; one in-flight load per controller —
  a newer `open` wins (invariant 7).
- Every user-visible failure is a `MacomprendoError` with `errorDescription` and
  `recoverySuggestion` (invariant 8). The one new case is
  `transcriptPlaybackUnavailable(String)`.
- Icons only through `Icon(.case)`; a new icon goes into `Resources/Icons/icons.json`, then
  `npm run sync-icons`, plus its `AppIcon` case and `fallbackSymbol` (invariant 12).
- New Swift files: run `npm run gen` (the `.xcodeproj` is generated from `macos/project.yml`;
  a second run must be a no-op) and commit the regenerated project (invariant 10).
- Active segment = the latest-starting segment with `start ≤ position ≤ end + 1 s`, looking back
  at most 120 s; nothing marked before the first Play/seek.
- Skip step 15 s; speeds exactly `1×, 1.25×, 1.5×, 2×`; pitch kept (`.timeDomain`); speed lasts
  for the controller's lifetime, mute toggles reset per transcript.
- Position updates about every 0.25 s while playing and once after every seek.
- Time format `m:ss` under an hour, `h:mm:ss` from an hour.
- Unavailable strip text: `Audio unavailable — <reason>`.
- Commits are conventional commits. Never push, never switch branches, never commit to `main`;
  stage only the files of your task.
- Definition of done per task: `npm run test:swift` green, `swift build --package-path macos`
  with no new warnings; the last task also runs `npm run test:scripts` and `npm run audit`.

---

### Task 1: Core — playback source, timeline, error case

**Files:**
- Create: `macos/Sources/Macomprendo/Core/PlaybackSource.swift`
- Create: `macos/Sources/Macomprendo/Core/PlaybackTimeline.swift`
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift` (new case in the enum, in
  `errorDescription` and in `recoverySuggestion`)
- Test: `macos/Tests/MacomprendoTests/Core/PlaybackTimelineTests.swift`
- Test: the existing `MacomprendoError` tests file (find it with
  `grep -rln "recoverySuggestion" macos/Tests`) — add the new case wherever cases are enumerated.

**Interfaces:**
- Produces:
  - `struct PlaybackTrack: Equatable, Sendable { let speaker: TranscriptSpeaker; let url: URL; let offset: TimeInterval }`
  - `enum PlaybackSource: Equatable, Sendable { case file(URL); case call([PlaybackTrack]) }`
  - `struct PlaybackTimeline: Equatable, Sendable` with `init(segments: [TranscriptSegment])`,
    `func activeIndex(at position: TimeInterval) -> Int?`, `static let grace: TimeInterval = 1`,
    `static let lookback: TimeInterval = 120`, `static func clock(_ seconds: TimeInterval) -> String`
  - `MacomprendoError.transcriptPlaybackUnavailable(String)`

- [ ] **Step 1: Write the failing tests** — `PlaybackTimelineTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

struct PlaybackTimelineTests {
    private func seg(_ start: TimeInterval, _ end: TimeInterval,
                     _ speaker: TranscriptSpeaker? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "t", speaker: speaker)
    }

    @Test func nothingIsActiveBeforeTheFirstSegment() {
        let timeline = PlaybackTimeline(segments: [seg(2, 4), seg(5, 7)])
        #expect(timeline.activeIndex(at: 0) == nil)
        #expect(timeline.activeIndex(at: 1.99) == nil)
    }

    @Test func aPositionInsideASegmentMarksIt() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(3, 5), seg(10, 12)])
        #expect(timeline.activeIndex(at: 0) == 0)
        #expect(timeline.activeIndex(at: 3) == 1)
        #expect(timeline.activeIndex(at: 11) == 2)
    }

    @Test func theMarkerOutlivesASegmentByTheGraceThenGoes() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(10, 12)])
        #expect(timeline.activeIndex(at: 2.9) == 0)
        #expect(timeline.activeIndex(at: 3.0) == 0)
        #expect(timeline.activeIndex(at: 3.01) == nil)
        #expect(timeline.activeIndex(at: 9.99) == nil)
    }

    @Test func overlappingSpeakersMarkTheLaterStart() {
        let timeline = PlaybackTimeline(segments: [seg(0, 30, .me), seg(5, 7, .others)])
        #expect(timeline.activeIndex(at: 4) == 0)
        #expect(timeline.activeIndex(at: 6) == 1)
        // The short reply is over (past its grace): back to the long one still running.
        #expect(timeline.activeIndex(at: 9) == 0)
    }

    @Test func theLastSegmentAndPastIt() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(3, 5)])
        #expect(timeline.activeIndex(at: 5.5) == 1)
        #expect(timeline.activeIndex(at: 60) == nil)
    }

    @Test func anEmptyTranscriptMarksNothing() {
        #expect(PlaybackTimeline(segments: []).activeIndex(at: 3) == nil)
    }

    @Test func theLookbackBoundsTheSearch() {
        // A segment longer than the lookback is not found from far inside it — the bound is
        // what keeps a long pause O(log n).
        let timeline = PlaybackTimeline(segments: [seg(0, 500)])
        #expect(timeline.activeIndex(at: 100) == 0)
        #expect(timeline.activeIndex(at: 400) == nil)
    }

    @Test(arguments: [
        (0.0, "0:00"), (59.9, "0:59"), (60, "1:00"), (3599, "59:59"), (3600, "1:00:00"),
        (3725, "1:02:05"), (-3, "0:00"), (.nan, "0:00"), (.infinity, "0:00"),
    ] as [(TimeInterval, String)])
    func clockFormats(seconds: TimeInterval, expected: String) {
        #expect(PlaybackTimeline.clock(seconds) == expected)
    }
}
```

In the error tests, add `.transcriptPlaybackUnavailable("x")` to whatever list enumerates cases,
and add:

```swift
@Test func transcriptPlaybackUnavailableExplainsAndPointsAtChoose() {
    let error = MacomprendoError.transcriptPlaybackUnavailable("the source file cannot be found")
    #expect(error.errorDescription == "Can't play this transcript's audio: the source file cannot be found.")
    #expect(error.recoverySuggestion == "If the file or the recording folder moved, choose it again with Choose File… or Choose Folder….")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path macos --filter "PlaybackTimelineTests|transcriptPlaybackUnavailable"`
Expected: compile failure — `PlaybackTimeline` / the case are not defined.

- [ ] **Step 3: Implement**

`Core/PlaybackSource.swift`:

```swift
import Foundation

/// One side of a call as playback places it: the track file and where its first sample sits on
/// the recording's timeline (the manifest's `startOffset`).
struct PlaybackTrack: Equatable, Sendable {
    let speaker: TranscriptSpeaker
    let url: URL
    let offset: TimeInterval
}

/// What a transcript plays: its source file, or the tracks of its call recording.
enum PlaybackSource: Equatable, Sendable {
    case file(URL)
    case call([PlaybackTrack])
}
```

`Core/PlaybackTimeline.swift`:

```swift
import Foundation

/// Which segment the playhead is on. Segments arrive sorted by `start` (the store orders them so).
struct PlaybackTimeline: Equatable, Sendable {
    /// How long the marker stays on a segment after its end, so a short breath does not blink it.
    static let grace: TimeInterval = 1
    /// No stored segment is longer than this, so the backward scan can stop here.
    static let lookback: TimeInterval = 120

    private let starts: [TimeInterval]
    private let ends: [TimeInterval]

    init(segments: [TranscriptSegment]) {
        starts = segments.map(\.start)
        ends = segments.map(\.end)
    }

    /// The latest-starting segment with `start ≤ position ≤ end + grace`, or nil.
    func activeIndex(at position: TimeInterval) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= position { low = mid + 1 } else { high = mid }
        }
        var index = low - 1
        while index >= 0, starts[index] >= position - Self.lookback {
            if position <= ends[index] + Self.grace { return index }
            index -= 1
        }
        return nil
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour; anything not finite or negative is `0:00`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
```

`MacomprendoError`: add `case transcriptPlaybackUnavailable(String)` next to
`callRecordingUnavailable`; `errorDescription`:
`return "Can't play this transcript's audio: \(reason)."`; `recoverySuggestion`:
`return "If the file or the recording folder moved, choose it again with Choose File… or Choose Folder…."`.
Fix any other exhaustive `switch` over `MacomprendoError` the compiler reports.

- [ ] **Step 4: Run to verify they pass** — same filter; then `npm run gen` (new files), and
  `npm run test:swift`.
- [ ] **Step 5: Commit** — `feat(playback): playback source, timeline and error`

---

### Task 2: Services — `PlaybackComposition`

**Files:**
- Create: `macos/Sources/Macomprendo/Services/PlaybackComposition.swift`
- Test: `macos/Tests/MacomprendoTests/Services/PlaybackCompositionTests.swift`

**Interfaces:**
- Consumes: `PlaybackSource`, `PlaybackTrack`, `MacomprendoError.transcriptPlaybackUnavailable` (Task 1).
- Produces:
  - `struct PlaybackAsset { let asset: AVAsset; let duration: TimeInterval; let trackIDs: [TranscriptSpeaker: CMPersistentTrackID] }`
    — `trackIDs` is empty for a file; for a call it holds exactly the sides that could be read.
  - `@MainActor enum PlaybackComposition` with
    `static func make(_ source: PlaybackSource) async throws -> PlaybackAsset` and
    `static func audioMix(for asset: PlaybackAsset, muted: Set<TranscriptSpeaker>) -> AVAudioMix?`

- [ ] **Step 1: Write the failing tests** — real short WAV files from `WAVEncoder`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@MainActor
struct PlaybackCompositionTests {
    /// A mono 48 kHz WAV of `seconds` length in a fresh temp directory.
    private func wav(_ seconds: Double, in directory: URL, name: String) throws -> URL {
        let samples = [Float](repeating: 0.1, count: Int(seconds * 48_000))
        let url = directory.appendingPathComponent(name)
        try WAVEncoder.encode(pcm: samples, sampleRate: 48_000).write(to: url)
        return url
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackCompositionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFileSourceLoadsWithTheFileDuration() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try wav(0.5, in: dir, name: "a.wav")

        let asset = try await PlaybackComposition.make(.file(url))

        #expect(abs(asset.duration - 0.5) < 0.01)
        #expect(asset.trackIDs.isEmpty)
    }

    @Test func aFileWithoutSoundIsUnavailable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: url)

        await #expect(throws: MacomprendoError.transcriptPlaybackUnavailable("the file has no playable sound")) {
            _ = try await PlaybackComposition.make(.file(url))
        }
    }

    @Test func aCallPlacesEachTrackAtItsOffset() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = try wav(0.4, in: dir, name: "me.wav")
        let others = try wav(0.3, in: dir, name: "others.wav")

        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: me, offset: 0),
            PlaybackTrack(speaker: .others, url: others, offset: 0.25),
        ]))

        #expect(Set(asset.trackIDs.keys) == [.me, .others])
        #expect(abs(asset.duration - 0.55) < 0.01)
        let composition = try #require(asset.asset as? AVMutableComposition)
        for (speaker, offset) in [(TranscriptSpeaker.me, 0.0), (.others, 0.25)] {
            let track = try #require(composition.track(withTrackID: asset.trackIDs[speaker]!))
            let firstMedia = try #require(track.segments.first { !$0.isEmpty })
            #expect(abs(firstMedia.timeMapping.target.start.seconds - offset) < 0.001)
        }
    }

    @Test func anUnreadableCallTrackIsLeftOutAndTheOtherPlays() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = try wav(0.2, in: dir, name: "me.wav")
        let broken = dir.appendingPathComponent("others.m4a")
        try Data("broken".utf8).write(to: broken)

        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: me, offset: 0),
            PlaybackTrack(speaker: .others, url: broken, offset: 0.1),
        ]))

        #expect(Set(asset.trackIDs.keys) == [.me])
    }

    @Test func aCallWithNoReadableTrackIsUnavailable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("me.m4a")
        try Data("broken".utf8).write(to: broken)

        await #expect(throws: MacomprendoError.transcriptPlaybackUnavailable("no track of the recording can be read")) {
            _ = try await PlaybackComposition.make(.call([PlaybackTrack(speaker: .me, url: broken, offset: 0)]))
        }
    }

    @Test func theMixSilencesTheMutedSide() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: try wav(0.2, in: dir, name: "me.wav"), offset: 0),
            PlaybackTrack(speaker: .others, url: try wav(0.2, in: dir, name: "o.wav"), offset: 0),
        ]))

        let mix = try #require(PlaybackComposition.audioMix(for: asset, muted: [.others]))

        func volume(_ speaker: TranscriptSpeaker) -> Float? {
            guard let params = mix.inputParameters.first(where: { $0.trackID == asset.trackIDs[speaker] })
            else { return nil }
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange.zero
            _ = params.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
        #expect(volume(.me) == 1)
        #expect(volume(.others) == 0)
    }

    @Test func aFileHasNoMix() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = try await PlaybackComposition.make(.file(try wav(0.2, in: dir, name: "a.wav")))
        #expect(PlaybackComposition.audioMix(for: asset, muted: []) == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `swift test --package-path macos --filter PlaybackCompositionTests`; expected: compile failure.

- [ ] **Step 3: Implement** — `Services/PlaybackComposition.swift`:

```swift
import AVFoundation
import Foundation

/// The asset a transcript plays, and which composition track carries each call side.
struct PlaybackAsset {
    let asset: AVAsset
    let duration: TimeInterval
    /// Empty for a file; for a call, exactly the sides that could be read.
    let trackIDs: [TranscriptSpeaker: CMPersistentTrackID]
}

/// Builds the `AVAsset` for a `PlaybackSource`: the file itself, or a composition that puts each
/// call track at its `startOffset`, so the mix sounds like the conversation did. Deterministic and
/// file-based, so it is unit-tested with generated audio rather than smoke-tested.
@MainActor
enum PlaybackComposition {
    static func make(_ source: PlaybackSource) async throws -> PlaybackAsset {
        switch source {
        case .file(let url):
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
                  let duration = try? await asset.load(.duration) else {
                throw MacomprendoError.transcriptPlaybackUnavailable("the file has no playable sound")
            }
            return PlaybackAsset(asset: asset, duration: duration.seconds, trackIDs: [:])
        case .call(let tracks):
            let composition = AVMutableComposition()
            var ids: [TranscriptSpeaker: CMPersistentTrackID] = [:]
            var end: TimeInterval = 0
            for track in tracks {
                // One unreadable side must not take the other down with it.
                let asset = AVURLAsset(url: track.url)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let range = try? await source.load(.timeRange),
                      let target = composition.addMutableTrack(
                          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                do {
                    try target.insertTimeRange(
                        range, of: source, at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
                } catch {
                    composition.removeTrack(target)
                    continue
                }
                ids[track.speaker] = target.trackID
                end = max(end, track.offset + range.duration.seconds)
            }
            guard !ids.isEmpty else {
                throw MacomprendoError.transcriptPlaybackUnavailable("no track of the recording can be read")
            }
            return PlaybackAsset(asset: composition, duration: end, trackIDs: ids)
        }
    }

    /// Per-side volume for a call (0 for a muted side, 1 otherwise); nil for a file.
    static func audioMix(for asset: PlaybackAsset, muted: Set<TranscriptSpeaker>) -> AVAudioMix? {
        guard !asset.trackIDs.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = asset.trackIDs.map { speaker, id in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            parameters.setVolume(muted.contains(speaker) ? 0 : 1, at: .zero)
            return parameters
        }
        return mix
    }
}
```

If Swift 6 rejects a `Sendable` crossing here (`AVAsset` across `await` on the main actor), keep
the `@MainActor` isolation and fix the specific diagnostic minimally; record it in the report.

- [ ] **Step 4: Run to verify they pass**; `npm run gen`; `npm run test:swift`.
- [ ] **Step 5: Commit** — `feat(playback): compose a call's tracks on the recording timeline`

---

### Task 3: Services — `TranscriptAudioPlaying`, its AVPlayer implementation, the fake, environment

**Files:**
- Create: `macos/Sources/Macomprendo/Services/TranscriptAudioPlayer.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptAudioPlayer.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` (new
  `var transcriptAudioPlayer: any TranscriptAudioPlaying`, constructed in the default/live
  environment next to `historyAudioPlayer: AVAudioPlayerPlayer()`)
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift` (parameter
  `transcriptAudioPlayer: any TranscriptAudioPlaying = FakeTranscriptAudioPlayer()`, passed through)
- Test: `macos/Tests/MacomprendoTests/Fakes/FakeTranscriptAudioPlayerTests.swift` — only
  the fake's own gating behaviour (the controller tests in Task 4 lean on it).

**Interfaces:**
- Consumes: `PlaybackSource`, `PlaybackComposition`, `PlaybackAsset` (Tasks 1–2).
- Produces:

```swift
struct PlaybackLoad: Equatable, Sendable {
    let duration: TimeInterval
    /// The call sides that could be read; empty for a file.
    let speakers: Set<TranscriptSpeaker>
}

@MainActor protocol TranscriptAudioPlaying: AnyObject {
    /// About every 0.25 s while playing, and once after every seek.
    var onPosition: (@MainActor (TimeInterval) -> Void)? { get set }
    /// The item played to its end.
    var onEnded: (@MainActor () -> Void)? { get set }
    /// Playback failed mid-way (device gone, decode error); the player is paused.
    var onFailed: (@MainActor (MacomprendoError) -> Void)? { get set }
    /// Replaces whatever was loaded, paused at 0. Throws `transcriptPlaybackUnavailable`.
    func load(_ source: PlaybackSource) async throws -> PlaybackLoad
    func play()
    func pause()
    func seek(to position: TimeInterval) async
    /// Applies now if playing, and to every later `play()`.
    func setRate(_ rate: Float)
    func setMuted(_ muted: Set<TranscriptSpeaker>)
    /// Drops the item; nothing plays and no callback fires afterwards.
    func unload()
}
```

- [ ] **Step 1: Write the fake and its test** — `FakeTranscriptAudioPlayer.swift`:

```swift
import Foundation
@testable import Macomprendo

/// Records what the playback controller asks for and lets a test play the player's part:
/// `emitPosition`, `finish`, `fail`. `holdLoads` parks every `load` until `releaseLoad()`, so a
/// test can open a second transcript while the first is still loading.
@MainActor
final class FakeTranscriptAudioPlayer: TranscriptAudioPlaying {
    var onPosition: (@MainActor (TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor (MacomprendoError) -> Void)?

    var loadResult: Result<PlaybackLoad, MacomprendoError> =
        .success(PlaybackLoad(duration: 60, speakers: []))
    var holdLoads = false

    private(set) var loaded: [PlaybackSource] = []
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private(set) var muted: Set<TranscriptSpeaker> = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var unloadCount = 0
    private var pending: [CheckedContinuation<Void, Never>] = []

    var pendingLoads: Int { pending.count }

    func load(_ source: PlaybackSource) async throws -> PlaybackLoad {
        loaded.append(source)
        isPlaying = false
        if holdLoads {
            await withCheckedContinuation { pending.append($0) }
        }
        return try loadResult.get()
    }

    func releaseLoad() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func play() { isPlaying = true }
    func pause() { isPlaying = false }

    func seek(to position: TimeInterval) async {
        seeks.append(position)
        onPosition?(position)
    }

    func setRate(_ rate: Float) { self.rate = rate }
    func setMuted(_ muted: Set<TranscriptSpeaker>) { self.muted = muted }

    func unload() {
        unloadCount += 1
        isPlaying = false
    }

    func emitPosition(_ position: TimeInterval) { onPosition?(position) }
    func finish() { isPlaying = false; onEnded?() }
    func fail(_ error: MacomprendoError) { isPlaying = false; onFailed?(error) }
}
```

`FakeTranscriptAudioPlayerTests.swift`:

```swift
import Testing
@testable import Macomprendo

@MainActor
struct FakeTranscriptAudioPlayerTests {
    @Test func aHeldLoadWaitsForItsRelease() async throws {
        let player = FakeTranscriptAudioPlayer()
        player.holdLoads = true
        let load = Task { try await player.load(.file(URL(fileURLWithPath: "/a.m4a"))) }
        while player.pendingLoads == 0 { await Task.yield() }
        player.releaseLoad()
        #expect(try await load.value.duration == 60)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --package-path macos --filter FakeTranscriptAudioPlayerTests`; expected: compile failure (`TranscriptAudioPlaying` missing).

- [ ] **Step 3: Implement** — `Services/TranscriptAudioPlayer.swift`: the `PlaybackLoad` struct and
  the protocol above verbatim, then the `AVPlayer` implementation:

```swift
/// `AVPlayer` glue: no logic of its own beyond wiring, so it carries no unit test and is covered
/// by `docs/SMOKE_TEST.md` (invariant 3).
@MainActor
final class AVTranscriptAudioPlayer: TranscriptAudioPlaying {
    var onPosition: (@MainActor (TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailed: (@MainActor (MacomprendoError) -> Void)?

    private let player = AVPlayer()
    private var asset: PlaybackAsset?
    private var rate: Float = 1
    private var muted: Set<TranscriptSpeaker> = []
    private var timeObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0 else { return }
                self.onPosition?(time.seconds)
            }
        }
    }

    func load(_ source: PlaybackSource) async throws -> PlaybackLoad {
        unload()
        let asset = try await PlaybackComposition.make(source)
        let item = AVPlayerItem(asset: asset.asset)
        // Speech at 1.5× should sound faster, not higher.
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = PlaybackComposition.audioMix(for: asset, muted: muted)
        self.asset = asset
        observe(item)
        player.replaceCurrentItem(with: item)
        return PlaybackLoad(duration: asset.duration, speakers: Set(asset.trackIDs.keys))
    }

    func play() {
        player.defaultRate = rate
        player.play()
    }

    func pause() { player.pause() }

    func seek(to position: TimeInterval) async {
        let time = CMTime(seconds: position, preferredTimescale: 600)
        _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        onPosition?(player.currentTime().seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    func setMuted(_ muted: Set<TranscriptSpeaker>) {
        self.muted = muted
        if let asset { player.currentItem?.audioMix = PlaybackComposition.audioMix(for: asset, muted: muted) }
    }

    func unload() {
        player.pause()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        asset = nil
    }

    private func observe(_ item: AVPlayerItem) {
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onEnded?() } })
        itemObservers.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFailure("playback stopped unexpectedly") }
        })
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.reportFailure("the audio cannot be decoded") }
        }
    }

    private func reportFailure(_ reason: String) {
        player.pause()
        onFailed?(.transcriptPlaybackUnavailable(reason))
    }
}
```

`deinit` cannot touch main-actor state under Swift 6; rely on `unload()` from the controller and
let the periodic observer be removed with the player. Fix concurrency diagnostics minimally and
record them in the report. Wire `transcriptAudioPlayer: AVTranscriptAudioPlayer()` in
`AppEnvironment` (the same place `AVAudioPlayerPlayer()` is built) and the fake default in
`FakeEnvironment`.

- [ ] **Step 4: Run** — the fake test passes; `npm run gen`; `npm run test:swift`;
  `swift build --package-path macos` with no new warnings.
- [ ] **Step 5: Commit** — `feat(playback): transcript audio player behind a protocol`

---

### Task 4: Features — `TranscriptPlaybackController`

**Files:**
- Create: `macos/Sources/Macomprendo/Features/TranscriptPlaybackController.swift`
- Test: `macos/Tests/MacomprendoTests/Features/TranscriptPlaybackControllerTests.swift`

**Interfaces:**
- Consumes: `TranscriptAudioPlaying`, `PlaybackLoad`, `FakeTranscriptAudioPlayer` (Task 3);
  `PlaybackTimeline`, `PlaybackSource`, `PlaybackTrack` (Task 1); existing `FileBookmarking`
  (`FakeFileBookmarks` stores the path as the bookmark bytes), `CallRecordingFolderManaging`
  (`FakeCallRecordingFolders().fileExists` answers from the real disk),
  `TranscriptStoring.setSourceBookmark(_:for:)`, `CallRecordingManifest.read(from:)` /
  `write(to:)`, `CallRecordingLayout.manifestFileName`, `ErrorText.describe(_:)`.
- Produces (used by Tasks 5–6):

```swift
@MainActor final class TranscriptPlaybackController: ObservableObject {
    enum Recovery: Equatable { case chooseFile, chooseFolder }
    enum State: Equatable {
        case idle
        case loading
        case unavailable(reason: String, recovery: Recovery?)
        case ready(position: TimeInterval, duration: TimeInterval, isPlaying: Bool)
    }
    static let rates: [Float] = [1, 1.25, 1.5, 2]
    static let skipInterval: TimeInterval = 15
    @Published private(set) var state: State
    @Published private(set) var rate: Float
    @Published private(set) var muted: Set<TranscriptSpeaker>
    @Published private(set) var availableSpeakers: Set<TranscriptSpeaker>
    @Published private(set) var activeSegmentIndex: Int?
    @Published var isFollowing: Bool
    /// A mid-playback failure, shown until the next `play()`.
    @Published private(set) var failure: String?
    private(set) var transcriptID: Int64?
    init(player: any TranscriptAudioPlaying, bookmarks: any FileBookmarking,
         folders: any CallRecordingFolderManaging, store: any TranscriptStoring)
    func open(_ transcript: Transcript?) async
    func play()
    func pause()
    func togglePlayPause()
    func skip(by seconds: TimeInterval) async
    func seek(to position: TimeInterval) async
    func playSegment(at index: Int) async
    func setRate(_ rate: Float)
    func toggleMuted(_ speaker: TranscriptSpeaker)
    func stop()
    func relink(to url: URL) async
}
```

Behaviour (spec § Behaviour, verbatim rules):
- `open(nil)` == `stop()`. `open(t)` for the transcript already loaded (`t.id == transcriptID`
  and state is `.ready` or `.loading`) only refreshes the timeline from `t.segments` (a running
  job adds segments). Otherwise: bump a generation counter, `player.unload()`, reset `muted = []`,
  `activeSegmentIndex = nil`, `isFollowing = true`, `failure = nil`, `hasStarted = false`, keep
  `rate`; resolve the source; `.unavailable` on failure, else `.loading`, `await player.load`,
  and if the generation moved meanwhile drop the result. On success: `state = .ready(0, d, false)`,
  `availableSpeakers = load.speakers`, `player.setRate(rate)`, `player.setMuted([])`.
- Source resolution reasons (exact strings): file — no bookmark or it fails to resolve →
  `("the source file cannot be found", .chooseFile)`; call — folder bookmark missing/unresolved
  → `("the recording folder cannot be found", .chooseFolder)`; manifest unreadable →
  `("recording.json cannot be read", .chooseFolder)`; no track with a `startOffset` whose file
  exists → `("neither track file is there", .chooseFolder)`. Tracks in order Me, Others;
  `url = folder.appendingPathComponent(track.file)`.
- A `player.load` error → `.unavailable(reason:, recovery: nil)`, where reason is the payload of
  `transcriptPlaybackUnavailable` or `ErrorText.describe(error)` otherwise.
- `play()`: no-op unless `.ready`; clears `failure`; at the end (`position >= duration - 0.05`)
  seeks to 0 first; sets `hasStarted`; `player.play()`; `isPlaying = true`.
- `pause()`: `player.pause()`, `isPlaying = false`. `togglePlayPause()` picks one.
- `skip(by:)` → `seek(to: position + seconds)`. `seek(to:)` clamps to `0…duration`, sets
  `hasStarted` and `isFollowing = true`, `await player.seek` (position arrives via `onPosition`).
- `playSegment(at:)` seeks to that segment's `start` and plays.
- `onPosition(t)`: update `.ready` position; `activeSegmentIndex = hasStarted ? timeline.activeIndex(at: t) : nil`
  (assign only when it changes). `onEnded`: `.ready(duration, duration, false)`.
  `onFailed(e)`: `isPlaying = false`, `failure = reason` (same extraction as load errors).
- `setRate` stores and forwards; `toggleMuted` flips membership (ignored for a speaker not in
  `availableSpeakers`) and forwards the whole set.
- `stop()`: bump generation, `player.unload()`, `.idle`, `transcriptID = nil`,
  `activeSegmentIndex = nil`, `availableSpeakers = []`.
- `relink(to:)`: for the open transcript, `bookmarks.bookmark(for: url)`,
  `store.setSourceBookmark(_, for: id)`, then reopen that transcript with the new bookmark
  (force a reload even though the id is the same). Errors → `.unavailable(reason:
  ErrorText.describe(error), recovery:)` keeping the previous recovery.

- [ ] **Step 1: Write the failing tests** — `TranscriptPlaybackControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import Macomprendo

@MainActor
struct TranscriptPlaybackControllerTests {
    private let segments = [
        TranscriptSegment(start: 0, end: 2, text: "a", speaker: nil),
        TranscriptSegment(start: 3, end: 5, text: "b", speaker: nil),
        TranscriptSegment(start: 40, end: 42, text: "c", speaker: nil),
    ]

    private func transcript(id: Int64 = 1, kind: TranscriptSourceKind = .file,
                            bookmarkPath: String? = "/audio/lecture.mp3",
                            segments: [TranscriptSegment]? = nil) -> Transcript {
        Transcript(
            header: TranscriptHeader(id: id, createdAt: Date(timeIntervalSince1970: 0),
                                     sourceKind: kind, title: "t", duration: nil,
                                     status: .complete, statusReason: nil),
            run: TranscriptionRun(modelID: nil, engine: nil, language: nil, appVersion: "1.0"),
            sourceBookmark: bookmarkPath.map { Data($0.utf8) },
            summary: nil,
            segments: segments ?? self.segments)
    }

    private func make(player: FakeTranscriptAudioPlayer = FakeTranscriptAudioPlayer(),
                      bookmarks: FakeFileBookmarks = FakeFileBookmarks(),
                      store: FakeTranscriptStore = FakeTranscriptStore())
        -> (TranscriptPlaybackController, FakeTranscriptAudioPlayer) {
        (TranscriptPlaybackController(player: player, bookmarks: bookmarks,
                                      folders: FakeCallRecordingFolders(), store: store), player)
    }

    /// A real call folder: `recording.json` plus the track files named in it.
    private func callFolder(meOffset: TimeInterval? = 0, othersOffset: TimeInterval? = 0.4,
                            writeMe: Bool = true, writeOthers: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 0),
                                             folderName: folder.lastPathComponent)
        manifest.tracks[TranscriptSpeaker.me.rawValue]?.startOffset = meOffset
        manifest.tracks[TranscriptSpeaker.others.rawValue]?.startOffset = othersOffset
        try manifest.write(to: folder)
        for (speaker, write) in [(TranscriptSpeaker.me, writeMe), (.others, writeOthers)] where write {
            let file = manifest.tracks[speaker.rawValue]!.file
            try Data().write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    // MARK: - Resolving the source

    @Test func aFileTranscriptLoadsItsSourceFile() async {
        let (controller, player) = make()
        await controller.open(transcript())
        #expect(player.loaded == [.file(URL(fileURLWithPath: "/audio/lecture.mp3"))])
        #expect(controller.state == .ready(position: 0, duration: 60, isPlaying: false))
        #expect(controller.transcriptID == 1)
    }

    @Test func aMovedSourceFileIsUnavailableWithChooseFile() async {
        let (controller, player) = make(bookmarks: FakeFileBookmarks(missing: ["/audio/lecture.mp3"]))
        await controller.open(transcript())
        #expect(controller.state == .unavailable(reason: "the source file cannot be found", recovery: .chooseFile))
        #expect(player.loaded.isEmpty)
    }

    @Test func aCallLoadsBothTracksAtTheirOffsets() async throws {
        let folder = try callFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me, .others]))

        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))

        let manifest = try CallRecordingManifest.read(from: folder)
        #expect(player.loaded == [.call([
            PlaybackTrack(speaker: .me, url: folder.appendingPathComponent(manifest.tracks["me"]!.file), offset: 0),
            PlaybackTrack(speaker: .others, url: folder.appendingPathComponent(manifest.tracks["others"]!.file), offset: 0.4),
        ])])
        #expect(controller.availableSpeakers == [.me, .others])
    }

    @Test func aCallWithOneTrackFileMissingPlaysTheOther() async throws {
        let folder = try callFolder(writeOthers: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me]))

        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))

        guard case .call(let tracks) = player.loaded.first else { Issue.record("no call loaded"); return }
        #expect(tracks.map(\.speaker) == [.me])
        #expect(controller.availableSpeakers == [.me])
    }

    @Test func aTrackWithoutAnOffsetIsLeftOut() async throws {
        let folder = try callFolder(othersOffset: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        guard case .call(let tracks) = player.loaded.first else { Issue.record("no call loaded"); return }
        #expect(tracks.map(\.speaker) == [.me])
    }

    @Test func aCallWithNoTrackFilesIsUnavailable() async throws {
        let folder = try callFolder(writeMe: false, writeOthers: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, _) = make()
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        #expect(controller.state == .unavailable(reason: "neither track file is there", recovery: .chooseFolder))
    }

    @Test func aMissingRecordingFolderIsUnavailable() async {
        let (controller, _) = make(bookmarks: FakeFileBookmarks(missing: ["/rec gone"]))
        await controller.open(transcript(kind: .call, bookmarkPath: "/rec gone"))
        #expect(controller.state == .unavailable(reason: "the recording folder cannot be found", recovery: .chooseFolder))
    }

    @Test func anUnreadableManifestIsUnavailable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rec \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, _) = make()
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        #expect(controller.state == .unavailable(reason: "recording.json cannot be read", recovery: .chooseFolder))
    }

    @Test func aLoadErrorIsUnavailableWithoutRecovery() async {
        let (controller, player) = make()
        player.loadResult = .failure(.transcriptPlaybackUnavailable("the file has no playable sound"))
        await controller.open(transcript())
        #expect(controller.state == .unavailable(reason: "the file has no playable sound", recovery: nil))
    }

    // MARK: - Transport

    @Test func playPauseAndTheEnd() async {
        let (controller, player) = make()
        await controller.open(transcript())
        controller.play()
        #expect(player.isPlaying)
        #expect(controller.state == .ready(position: 0, duration: 60, isPlaying: true))
        controller.togglePlayPause()
        #expect(!player.isPlaying)

        controller.play()
        player.finish()
        #expect(controller.state == .ready(position: 60, duration: 60, isPlaying: false))
        controller.play()
        // The next Play after the end starts over.
        while player.seeks.last != 0 { await Task.yield() }
        #expect(player.isPlaying)
    }

    @Test func skipsClampToTheRecording() async {
        let (controller, player) = make()
        await controller.open(transcript())
        await controller.skip(by: -TranscriptPlaybackController.skipInterval)
        await controller.seek(to: 50)
        await controller.skip(by: TranscriptPlaybackController.skipInterval)
        #expect(player.seeks == [0, 50, 60])
        #expect(controller.state == .ready(position: 60, duration: 60, isPlaying: false))
    }

    @Test func playingASegmentSeeksPlaysAndFollows() async {
        let (controller, player) = make()
        await controller.open(transcript())
        controller.isFollowing = false
        await controller.playSegment(at: 1)
        #expect(player.seeks == [3])
        #expect(player.isPlaying)
        #expect(controller.isFollowing)
        #expect(controller.activeSegmentIndex == 1)
    }

    @Test func positionsMoveTheMarkerOnlyAfterPlaybackStarted() async {
        let (controller, player) = make()
        await controller.open(transcript())
        player.emitPosition(1)
        #expect(controller.activeSegmentIndex == nil)
        controller.play()
        player.emitPosition(1)
        #expect(controller.activeSegmentIndex == 0)
        player.emitPosition(4)
        #expect(controller.activeSegmentIndex == 1)
        player.emitPosition(20)
        #expect(controller.activeSegmentIndex == nil)
    }

    @Test func aFailureMidwayPausesAndReportsUntilTheNextPlay() async {
        let (controller, player) = make()
        await controller.open(transcript())
        controller.play()
        player.fail(.transcriptPlaybackUnavailable("playback stopped unexpectedly"))
        #expect(controller.failure == "playback stopped unexpectedly")
        #expect(controller.state == .ready(position: 0, duration: 60, isPlaying: false))
        controller.play()
        #expect(controller.failure == nil)
    }

    // MARK: - Rate and mute

    @Test func theRateOutlivesATranscriptAndMutesDoNot() async throws {
        let folder = try callFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me, .others]))
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        controller.setRate(1.5)
        controller.toggleMuted(.others)
        #expect(player.rate == 1.5)
        #expect(player.muted == [.others])

        await controller.open(transcript(id: 2, kind: .call, bookmarkPath: folder.path))
        #expect(controller.rate == 1.5)
        #expect(player.rate == 1.5)
        #expect(controller.muted.isEmpty)
        #expect(player.muted.isEmpty)
    }

    @Test func aMissingSideCannotBeToggled() async throws {
        let folder = try callFolder(writeOthers: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me]))
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        controller.toggleMuted(.others)
        #expect(controller.muted.isEmpty)
    }

    // MARK: - Switching and stopping

    @Test func reopeningTheSameTranscriptOnlyRefreshesTheTimeline() async {
        let (controller, player) = make()
        await controller.open(transcript(segments: [segments[0]]))
        controller.play()
        await controller.open(transcript())
        #expect(player.loaded.count == 1)
        #expect(player.isPlaying)
        player.emitPosition(41)
        #expect(controller.activeSegmentIndex == 2)
    }

    @Test func aNewerOpenWinsOverASlowerLoad() async {
        let (controller, player) = make()
        player.holdLoads = true
        let first = Task { await controller.open(transcript(id: 1)) }
        while player.pendingLoads == 0 { await Task.yield() }
        let second = Task { await controller.open(transcript(id: 2, bookmarkPath: "/audio/two.mp3")) }
        while player.pendingLoads < 2 { await Task.yield() }
        player.releaseLoad()
        player.releaseLoad()
        await first.value
        await second.value
        #expect(controller.transcriptID == 2)
        #expect(controller.state == .ready(position: 0, duration: 60, isPlaying: false))
        #expect(player.unloadCount >= 2)
    }

    @Test func stopUnloadsAndForgets() async {
        let (controller, player) = make()
        await controller.open(transcript())
        controller.play()
        controller.stop()
        #expect(!player.isPlaying)
        #expect(controller.state == .idle)
        #expect(controller.transcriptID == nil)
        await controller.open(nil)
        #expect(controller.state == .idle)
    }

    // MARK: - Relinking

    @Test func relinkStoresTheBookmarkAndLoads() async throws {
        let store = FakeTranscriptStore()
        let id = try await store.create(sourceKind: .file, title: "t", sourceBookmark: Data("/old".utf8),
                                        duration: nil, run: TranscriptionRun(modelID: nil, engine: nil,
                                                                             language: nil, appVersion: "1"),
                                        at: .now)
        let (controller, player) = make(bookmarks: FakeFileBookmarks(missing: ["/old"]), store: store)
        await controller.open(transcript(id: id, bookmarkPath: "/old"))
        #expect(controller.state == .unavailable(reason: "the source file cannot be found", recovery: .chooseFile))

        await controller.relink(to: URL(fileURLWithPath: "/new/lecture.mp3"))

        #expect(try await store.transcript(id: id)?.sourceBookmark == Data("/new/lecture.mp3".utf8))
        #expect(player.loaded == [.file(URL(fileURLWithPath: "/new/lecture.mp3"))])
        #expect(controller.state == .ready(position: 0, duration: 60, isPlaying: false))
    }
}
```

Adjust only mechanical details the compiler forces (e.g. `FakeTranscriptStore.create`'s exact
labels — read its signature first); keep every expectation.

- [ ] **Step 2: Run to verify they fail** — `swift test --package-path macos --filter TranscriptPlaybackControllerTests`; expected: compile failure.
- [ ] **Step 3: Implement** the controller to the behaviour list above. Wire the player's
  callbacks in `init` with `[weak self]`. Keep the current `Transcript` (needed by `relink`) and
  the `PlaybackTimeline`. No logging of paths or text.
- [ ] **Step 4: Run** the filter, then `npm run gen`, `npm run test:swift`.
- [ ] **Step 5: Commit** — `feat(playback): transcript playback controller`

---

### Task 5: App wiring — construct, stop on recording start, pass to the window

**Files:**
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift` (a `lazy var transcriptPlayback`
  next to `transcriptLibrary`; in the `cancellables` setup, a sink on `callRecording.$state`
  that calls `transcriptPlayback.stop()` when the state becomes `.recording`)
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift` (pass
  `playback: model.transcriptPlayback` into `TranscriptsView`; `onDisappear` also calls
  `model.transcriptPlayback.stop()`)
- Modify: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift` — only add
  `@ObservedObject var playback: TranscriptPlaybackController` and
  `.onChange(of: library.selected) { _, selected in Task { await playback.open(selected) } }`
  plus the same call in `.task` for the initial selection. The bar and marker are Task 6.
- Test: the existing `AppModelTests` (find with `grep -rln "AppModelTests" macos/Tests`).

**Interfaces:**
- Consumes: `TranscriptPlaybackController` (Task 4), `env.transcriptAudioPlayer` (Task 3).
- Produces: `AppModel.transcriptPlayback: TranscriptPlaybackController`.

```swift
lazy var transcriptPlayback = TranscriptPlaybackController(player: env.transcriptAudioPlayer,
                                                           bookmarks: env.fileBookmarks,
                                                           folders: env.callRecordingFolders,
                                                           store: env.transcriptStore)
```

```swift
// A call should not start with the app talking; the tap would not record it anyway.
callRecording.$state
    .sink { [weak self] state in
        if case .recording = state { self?.transcriptPlayback.stop() }
    }
    .store(in: &cancellables)
```

- [ ] **Step 1: Write the failing test** in `AppModelTests`: build the model with a
  `FakeTranscriptAudioPlayer` through `FakeEnvironment`, open a file transcript in
  `model.transcriptPlayback` (a `FakeTranscriptStore` row with a bookmark the default
  `FakeFileBookmarks` resolves), `play()`, then start a call recording the way existing
  `AppModelTests` call-recording tests do (reuse their setup — `ScriptedCallCapture`, permissions
  granted — read them first), wait for `.recording`, and expect `player.isPlaying == false` and
  `model.transcriptPlayback.state == .idle`. If no existing `AppModelTests` test starts a call
  recording, start one through `model.callRecording.toggle()` with the same fakes the
  `CallRecordingControllerTests` use.
- [ ] **Step 2: Run to verify it fails** (`stop` never called → still playing).
- [ ] **Step 3: Implement** the three edits above.
- [ ] **Step 4: Run** the test, `npm run test:swift`, `swift build --package-path macos`.
- [ ] **Step 5: Commit** — `feat(playback): wire transcript playback into the app`

---

### Task 6: UI — player bar, marker, timestamps, follow; docs

Read the `frontend-design` guidance in spirit, inside native macOS conventions: the bar must look
like part of the window, not a web widget.

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptPlayerBar.swift`
- Create: `macos/Sources/Macomprendo/UI/Transcripts/ScrollWheelObserver.swift`
- Modify: `macos/Sources/Macomprendo/UI/Transcripts/TranscriptsView.swift`
- Modify: `macos/Sources/Macomprendo/Resources/Icons/icons.json`, `UI/Components/Icon.swift`
  (new icons), then `npm run sync-icons`
- Modify: `docs/SMOKE_TEST.md`, `CHANGELOG.md` (`Unreleased`), `docs/ARCHITECTURE.md`
  (Transcripts section)

**Interfaces:**
- Consumes: everything `TranscriptPlaybackController` produces (Task 4); `playback` already on
  the view (Task 5); `PlaybackTimeline.clock` (Task 1).

**Bar** (`TranscriptPlayerBar(playback:transcript:)`), shown at the bottom of the detail under a
`Divider()` when `state` is `.loading` or `.ready`:
- Height about 36 pt, `.padding(.horizontal, 10)`, `.background(.bar)`.
- Left to right: skip back (`Icon(.skipBack)` = Phosphor `arrow-counter-clockwise`, help
  "Back 15 seconds"), play/pause (`Icon(.play)` / `Icon(.pause)`, 18 pt, help "Play"/"Pause"),
  skip forward (`Icon(.skipForward)` = Phosphor `arrow-clockwise`, help "Forward 15 seconds");
  a `Slider` over `0…duration` that shows the controller's position except while dragging
  (`onEditingChanged`: keep a local `@State` drag value; seek once on release); the time
  `"\(clock(position)) / \(clock(duration))"` in `.monospacedDigit()` `.secondary` caption;
  a `Menu` titled `"1×"` / `"1.25×"` / `"1.5×"` / `"2×"` with `TranscriptPlaybackController.rates`
  (`.menuStyle(.borderlessButton)`, `.fixedSize()`); for a call transcript, two
  `Toggle(isOn:)` with `.toggleStyle(.button)` labelled `Me` and `Others` — on = audible, bound
  to `!muted.contains(speaker)` → `toggleMuted`; a side not in `availableSpeakers` is
  `.disabled(true)` with help "This side's track is missing".
- While `.loading`, the controls are disabled.
- Buttons are `.buttonStyle(.borderless)`; no control shrinks its label (`.fixedSize()`), the
  slider takes the remaining width.

**Unavailable strip**, in the same place when `state` is `.unavailable`, or under the bar when
`failure != nil`: one line, `Icon(.warning)` (existing `warning-circle`) +
`Text("Audio unavailable — \(reason)")` secondary, and for `.chooseFile` / `.chooseFolder` a
`Choose File…` / `Choose Folder…` button that runs an `NSOpenPanel` (same configuration as the
view's existing `chooseSourceFile` / `chooseRecordingFolder`) and then
`await playback.relink(to: url)` followed by `await library.select(id)` (refreshes the
library's bookmark for Show in Finder). It does **not** start transcription.

**Segments:**
- Wrap the detail's `ScrollView` in `ScrollViewReader`; give each segment row `.id(index)`.
- `segmentRow(segment, index:, isActive:)`: the timestamp `[mm:ss]` becomes a
  `Button` with `.buttonStyle(.plain)`, `.foregroundStyle(.secondary)`, hover underline
  (`.onHover` → `@State` hovered index is fine, or `NSCursor.pointingHand.push/pop`), help
  "Play from here", action `Task { await playback.playSegment(at: index) }`; the text keeps
  `.textSelection(.enabled)`.
- Active row: `.padding(.vertical, 2).padding(.horizontal, 6)` on every row (so rows don't jump)
  and, when active, `.background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))`.
  The row takes `isActive: Bool` only — do not pass the controller into rows.
- Follow: `.onChange(of: playback.activeSegmentIndex)` → if `isFollowing`, playing, and non-nil,
  `withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.25)) }`.
- `ScrollWheelObserver` (`NSViewRepresentable`, `.background` of the `ScrollView`): installs
  `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` in `viewDidMoveToWindow` when it has
  a window, removes it when the window goes to nil and in `dismantleNSView`; for an event whose
  `window === view.window` and whose `locationInWindow` converted into the view lies in its
  `bounds`, it calls `onUserScroll()` and returns the event unchanged. The view passes
  `{ playback.isFollowing = false }`.
- **Back to current**: when playing, `!isFollowing`, and `activeSegmentIndex != nil`, an overlay
  button at the list's bottom trailing edge (`.buttonStyle(.borderedProminent)`,
  `.controlSize(.small)`, padding 10): "Back to current" → `isFollowing = true` and scroll as
  above.

**Icons**: add `arrow-counter-clockwise` and `arrow-clockwise` to `icons.json`, run
`npm run sync-icons`, add `case skipBack = "arrow-counter-clockwise"` /
`case skipForward = "arrow-clockwise"` with fallback symbols `"gobackward.15"` /
`"goforward.15"`. The existing `IconTests` cover them.

**Docs**:
- `docs/SMOKE_TEST.md`: a **Transcript playback** section with these checks: file transcript
  (audio file and a video file — sound only); call transcript with both sides, then each side
  muted; each speed, voices keep their pitch; dragging the seek bar seeks on release; clicking a
  timestamp plays from there; the marker follows speech and the list scrolls; a manual scroll
  stops following and shows **Back to current**, which returns; a moved source file shows the
  strip and **Choose File…** brings playback back without starting transcription; playback while
  dictating; starting a call recording stops playback; closing the window stops playback.
- `CHANGELOG.md` `Unreleased`: "**Play a transcript's audio** in the Transcripts window: a seek
  bar, ±15 s, 1×–2× speed, **Me** / **Others** toggles for calls; the segment being played is
  marked and the list follows it; click a timestamp to play from there."
- `docs/ARCHITECTURE.md` Transcripts section: one paragraph naming `TranscriptPlaybackController`,
  `TranscriptAudioPlaying` / `AVTranscriptAudioPlayer`, `PlaybackComposition` and
  `PlaybackTimeline`, and that a call plays as a composition of its tracks at their offsets.

- [ ] **Step 1:** Icons first (TDD through `IconTests`): add the two cases → `swift test --filter everyIcon` fails → `icons.json` + `npm run sync-icons` → passes.
- [ ] **Step 2:** Build the bar, strip, rows, follow and observer; `npm run gen` for the new files.
- [ ] **Step 3:** `swift build --package-path macos` (no new warnings), `npm run test:swift`,
  `npm run test:scripts`, `npm run audit`; `npm run gen` twice → no diff.
- [ ] **Step 4: Commit** — `feat(playback): player bar, playing-segment marker and follow` and
  `docs(playback): smoke test, changelog, architecture` (two commits).

---

## Self-review

- Spec coverage: bar (Task 6) · seek-on-release (6) · ±15 s clamp (4) · speeds & pitch (3, 4) ·
  Me/Others + missing side (2, 4, 6) · stop on transcript switch / window close / recording
  start (4, 5) · plays while transcribing (4: same-id refresh) · marker rule & before-first-play
  (1, 4) · follow + Back to current (6) · timestamps play (4, 6) · unavailable reasons &
  recovery & relink without transcription (4, 6) · undecodable file (2) · one missing track (2, 4)
  · mid-way failure (3, 4) · error case (1) · interaction with recording (5) · smoke/docs (6).
- Types: `PlaybackLoad`, `PlaybackAsset.trackIDs`, `TranscriptPlaybackController.State/Recovery`,
  `skipInterval`, `rates`, `availableSpeakers`, `activeSegmentIndex`, `isFollowing`, `failure`
  are spelled the same in every task.
