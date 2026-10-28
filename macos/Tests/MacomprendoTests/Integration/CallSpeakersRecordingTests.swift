import Foundation
import Testing
@testable import Macomprendo

/// Opt-in end-to-end run on a real call recording: `FileTranscriptionController` with every real
/// component — `AVAssetMediaDecoder`, `SherpaSileroSegmenter` (segments and the phantom gate's
/// speech share), `WhisperCppTranscriber`, `SherpaSpeakerDiarizer` and a temporary
/// `SQLiteTranscriptStore` — as **Resume** runs it after Stop. It writes the call's `.srt` into
/// the folder it is given, so point it at a *copy* of a recording folder:
///
///     MACOMPRENDO_CALL_FOLDER=<copy of a recording folder: recording.json + both tracks>
///     MACOMPRENDO_CALL_MODEL=<whisper ggml model path>                      (optional)
///     MACOMPRENDO_CALL_MODELS_DIR=<models directory>                        (optional)
///
/// The models directory defaults to `~/Library/Application Support/Macomprendo/models`, and the
/// speaker models are downloaded into it when they are not there yet.
@MainActor
@Suite(.serialized) struct CallSpeakersRecordingTests {
    private nonisolated static let environment = ProcessInfo.processInfo.environment
    private nonisolated static let folderURL = environment["MACOMPRENDO_CALL_FOLDER"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    private nonisolated static let modelsDirectory = environment["MACOMPRENDO_CALL_MODELS_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Macomprendo/models")
    private nonisolated static let whisperURL = environment["MACOMPRENDO_CALL_MODEL"]
        .map { URL(fileURLWithPath: $0) }
        ?? modelsDirectory.appending(path: "ggml-large-v3-turbo.bin")

    private nonisolated static var isConfigured: Bool {
        guard let folderURL else { return false }
        return FileManager.default.fileExists(
            atPath: folderURL.appending(path: "recording.json").path)
            && FileManager.default.fileExists(atPath: whisperURL.path)
    }

    @Test("a real call finishes with its far side told apart by voice",
          .enabled(if: CallSpeakersRecordingTests.isConfigured))
    func aRealCallIsDiarized() async throws {
        let folder = try #require(Self.folderURL)
        let models = LocalModelManager(directory: Self.modelsDirectory,
                                       http: URLSessionHTTPClient())
        if await models.resolved(ModelCatalog.speakerDiarizationID) == nil {
            for try await _ in models.download(ModelCatalog.speakerDiarizationID) {}
        }
        let databaseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "call-speakers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: databaseDirectory) }
        let store = SQLiteTranscriptStore(
            databaseURL: databaseDirectory.appending(path: "transcripts.sqlite3"))
        let bookmarks = FakeFileBookmarks()
        let id = try await store.create(sourceKind: .call, title: folder.lastPathComponent,
                                        sourceBookmark: try bookmarks.bookmark(for: folder),
                                        duration: nil,
                                        run: TranscriptionRun(modelID: "large-v3-turbo",
                                                              engine: "whisperCpp",
                                                              language: nil, appVersion: "test"),
                                        at: Date())
        try await store.setStatus(.incomplete, reason: "Cancelled.", for: id)

        let transcriber = WhisperCppTranscriber(modelURL: Self.whisperURL)
        let warnings = Box<[String?]>([])
        let controller = FileTranscriptionController(
            store: store, bookmarks: bookmarks, folders: FileSystemCallRecordingFolders(),
            sidecars: FileSystemTranscriptSidecars(),
            diarizer: SherpaSpeakerDiarizer(models: models),
            trackDecoder: AVAssetMediaDecoder(),
            pipeline: {
                LongAudioPipeline(decoder: AVAssetMediaDecoder(),
                                  segmenter: SherpaSileroSegmenter(),
                                  transcriber: { transcriber }, language: nil,
                                  speechPresence: SherpaSileroSegmenter())
            },
            settings: { Settings.default },
            glossary: { Glossary() },
            readiness: { .ready },
            callFinished: { _, _, warning in warnings.value.append(warning) })

        let started = ContinuousClock.now
        controller.resume(transcriptID: id)
        await controller.drain()
        await transcriber.release()
        let elapsed = ContinuousClock.now - started

        let stored = try #require(try await store.transcript(id: id))
        let others = stored.segments.filter { $0.speaker == .others }
        let voices = Set(others.compactMap(\.voice))
        print("""
            call speakers: \(stored.segments.count) segments, \(others.count) on the far side, \
            \(voices.count) voices, in \(elapsed)
            """)
        #expect(stored.header.status == .complete)
        #expect(warnings.value == [nil])
        #expect(voices.count >= 2)
        #expect(others.allSatisfy { $0.voice != nil })
        let srt = try String(contentsOf: TranscriptSidecars.subtitlesURL(callFolder: folder),
                             encoding: .utf8)
        #expect(srt.contains("Speaker 1: "))
    }
}
