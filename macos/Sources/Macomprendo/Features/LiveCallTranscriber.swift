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
            // This run is the feed's only consumer: whether it stops, fails or is cancelled, the
            // capture must stop buffering audio for it.
            defer { feed.finish() }
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
            } catch MacomprendoError.cancelled {
            } catch {
                Log.app.error("""
                    Live transcription of a call track stopped for \(speaker.rawValue, privacy: .public) \
                    (\(String(describing: type(of: error)), privacy: .public)); Stop catches the track up
                    """)
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
