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

    @Test func aCallStillRecordingIsUnavailableUntilItStops() async throws {
        let folder = try callFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        let call = transcript(kind: .call, bookmarkPath: folder.path)

        await controller.open(call, recording: true)
        #expect(controller.state == .unavailable(
            reason: TranscriptPlaybackController.stillRecordingReason, recovery: nil))
        #expect(player.loaded.isEmpty)
        #expect(controller.transcriptID == 1)

        // Stop finishes the files; the same transcript then loads them afresh.
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me, .others]))
        await controller.open(call)
        #expect(player.loaded.count == 1)
        #expect(controller.state == .ready(position: 0, duration: 30, isPlaying: false))
    }

    @Test func aPlayingCallThatStartsRecordingLiveStopsThePlayer() async throws {
        let folder = try callFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        let call = transcript(kind: .call, bookmarkPath: folder.path)
        player.loadResult = .success(PlaybackLoad(duration: 30, speakers: [.me, .others]))
        await controller.open(call)
        let unloadsBefore = player.unloadCount

        await controller.open(call, recording: true)

        #expect(player.unloadCount > unloadsBefore)
        #expect(controller.state == .unavailable(
            reason: TranscriptPlaybackController.stillRecordingReason, recovery: nil))
    }

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

        guard case .call(let tracks)? = player.loaded.first else { Issue.record("no call loaded"); return }
        #expect(tracks.map(\.speaker) == [.me])
        #expect(controller.availableSpeakers == [.me])
    }

    @Test func aTrackWithoutAnOffsetIsLeftOut() async throws {
        let folder = try callFolder(othersOffset: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (controller, player) = make()
        await controller.open(transcript(kind: .call, bookmarkPath: folder.path))
        guard case .call(let tracks)? = player.loaded.first else { Issue.record("no call loaded"); return }
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
        let id = await store.create(sourceKind: .file, title: "t", sourceBookmark: Data("/old".utf8),
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
