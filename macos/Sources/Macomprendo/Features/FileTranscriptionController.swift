import Foundation

/// Transcribes one source at a time through the long-audio pipeline, writing each segment into
/// the transcript store as it lands and reporting progress as one `State`: a file in one run,
/// a call recording as its two tracks in turn, shifted onto one clock and labelled by speaker.
///
/// Only one job runs at a time: a new `transcribe` or `resume` cancels the running one and the
/// cancelled job's row is left `incomplete` with the reason (`"Cancelled."` for a cancellation).
/// Every job carries a generation; a superseded job still finishes its own row's bookkeeping but
/// can no longer write `state`, so its late completion never overwrites the new job's state.
/// `shutdown()` stops the running job for app termination, waits for it — its pipeline task
/// included, so the local model's provider is released — and leaves the row with
/// `TranscriptLibraryController.abandonedJobReason` instead. Segment text is never logged.
@MainActor final class FileTranscriptionController: ObservableObject {
    enum State: Equatable {
        case idle
        case running(transcriptID: Int64, title: String, position: TimeInterval,
                     duration: TimeInterval, speaker: TranscriptSpeaker?)
        case finished(transcriptID: Int64)
        case failed(message: String, transcriptID: Int64?)
    }

    @Published private(set) var state: State = .idle

    private enum Job: Sendable {
        case transcribe(url: URL)
        /// `fileAt` is the source the user chose after the stored bookmark stopped resolving:
        /// a file for a file transcript, a recording folder for a call one. `nil` means
        /// resolve the bookmark.
        case resume(transcriptID: Int64, fileAt: URL?)
    }

    private let store: any TranscriptStoring
    private let bookmarks: any FileBookmarking
    private let pipeline: @MainActor () -> LongAudioPipeline
    private let settings: @MainActor () -> Settings
    private let glossary: @MainActor () -> Glossary
    private let readiness: @MainActor () -> BackendReadiness
    private let now: () -> Date
    private let transcriptsChanged: @MainActor () -> Void
    /// Reports a finished call transcript — both tracks landed and the row is `complete`, so
    /// the two cannot be told apart by the row alone. File jobs never call it.
    private let callFinished: @MainActor (_ transcriptID: Int64, _ title: String) -> Void

    private var jobTask: Task<Void, Never>?
    /// Bumped whenever a new job supersedes the running one. A job writes `state` only while its
    /// generation is current.
    private var generation = 0
    /// Set by `shutdown()`: a job stopped from there ends exactly as a job the app was killed
    /// during does — `incomplete` with the abandoned reason rather than `"Cancelled."` — so the
    /// row reads the same on the next launch, whether the quit path ran or the app died first.
    private var isShuttingDown = false

    init(store: any TranscriptStoring,
         bookmarks: any FileBookmarking,
         pipeline: @escaping @MainActor () -> LongAudioPipeline,
         settings: @escaping @MainActor () -> Settings,
         glossary: @escaping @MainActor () -> Glossary,
         readiness: @escaping @MainActor () -> BackendReadiness,
         now: @escaping () -> Date = Date.init,
         transcriptsChanged: @escaping @MainActor () -> Void = {},
         callFinished: @escaping @MainActor (_ transcriptID: Int64, _ title: String) -> Void = { _, _ in }) {
        self.store = store
        self.bookmarks = bookmarks
        self.pipeline = pipeline
        self.settings = settings
        self.glossary = glossary
        self.readiness = readiness
        self.now = now
        self.transcriptsChanged = transcriptsChanged
        self.callFinished = callFinished
    }

    /// Starts a job for `url`, cancelling any job already running. A backend that is not ready
    /// fails before any decoding starts and creates no row.
    func transcribe(fileAt url: URL) {
        guard !isShuttingDown else { return }
        let previous = supersede()
        switch readiness() {
        case .ready:
            start(.transcribe(url: url), after: previous)
        case let .notReady(reason, _):
            state = .failed(message: reason, transcriptID: nil)
        }
    }

    /// Continues an `incomplete` transcript from the end of its last stored segment — for a
    /// call, the end of its last track's last segment — cancelling any job already running.
    func resume(transcriptID: Int64) {
        guard !isShuttingDown else { return }
        let previous = supersede()
        start(.resume(transcriptID: transcriptID, fileAt: nil), after: previous)
    }

    /// Continues an `incomplete` transcript, using `url` as its source instead of the stored
    /// bookmark — the path the window offers when the bookmark no longer resolves: the source
    /// file for a file transcript, the recording folder for a call one. A fresh bookmark for
    /// `url` replaces the stale one, so the next `Resume` finds the source again.
    func resume(transcriptID: Int64, fileAt url: URL) {
        guard !isShuttingDown else { return }
        let previous = supersede()
        start(.resume(transcriptID: transcriptID, fileAt: url), after: previous)
    }

    func cancel() {
        jobTask?.cancel()
    }

    /// Stops the running job because the app is quitting, and waits for it to finish — its
    /// pipeline task included, so no reference to the file's provider survives this call. The
    /// row is left `incomplete` with `TranscriptLibraryController.abandonedJobReason`: the same
    /// state and reason launch maintenance gives a job the app was killed during, so `Resume`
    /// continues it either way.
    func shutdown() async {
        isShuttingDown = true
        let job = jobTask
        job?.cancel()
        await job?.value
    }

    /// Awaits the in-flight job. Used by tests.
    func drain() async {
        _ = await jobTask?.value
    }

    /// `true` when the shown failure is a `Resume` whose stored bookmark no longer resolves —
    /// the one failure the window answers with **Choose File…**. Derived from the message the
    /// job failed with rather than kept as a fourth piece of state beside `state`, so the two
    /// cannot drift apart.
    var canChooseSourceFile: Bool {
        guard case let .failed(message, _) = state else { return false }
        return message == ErrorText.describe(MacomprendoError.sourceFileUnavailable)
    }

    /// `true` when the shown failure is a call `Resume` whose recording folder or a track file
    /// cannot be found or read — the one failure the window answers with **Choose Folder…**.
    /// Derived from the message like `canChooseSourceFile`, for the same reason.
    var canChooseRecordingFolder: Bool {
        guard case let .failed(message, _) = state else { return false }
        return message == ErrorText.describe(MacomprendoError.callRecordingUnavailable)
    }

    /// Drops a shown failure. The window calls it when the user moves to another transcript;
    /// a job's own state writes replace `.failed` when one starts. Any other state is left
    /// alone — a finished job's selection must survive.
    func clearFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: - Jobs

    /// Cancels the running job and makes `generation` belong to the next one.
    private func supersede() -> Task<Void, Never>? {
        let previous = jobTask
        previous?.cancel()
        generation += 1
        return previous
    }

    /// Runs `job` as the current one. It first awaits the superseded job, so that job's
    /// bookkeeping (its row's reason) is finished before the new job writes anything — the two
    /// can never interleave their store writes.
    private func start(_ job: Job, after previous: Task<Void, Never>?) {
        let generation = self.generation
        jobTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            switch job {
            case let .transcribe(url):
                await self.run(url: url, from: 0, resuming: nil, generation: generation)
            case let .resume(transcriptID, fileAt):
                await self.runResume(id: transcriptID, fileAt: fileAt, generation: generation)
            }
        }
    }

    private func runResume(id: Int64, fileAt chosenURL: URL?, generation: Int) async {
        var marked = false
        do {
            try Task.checkCancellation()
            // `Resume` is a job like any other: a backend that is not ready fails it with the
            // backend's reason before its row is touched, exactly as a fresh `transcribe` does.
            if case let .notReady(reason, _) = readiness() {
                fail(reason, transcriptID: id, generation: generation)
                return
            }
            guard let transcript = try await store.transcript(id: id) else {
                fail(ErrorText.describe(MacomprendoError.transcriptStore(
                        "no transcript has identifier \(id)")),
                     transcriptID: nil, generation: generation)
                return
            }
            try Task.checkCancellation()
            switch transcript.header.sourceKind {
            case .file:
                let url: URL
                if let chosenURL {
                    // The user picked the source file again: it becomes the row's source before
                    // any decoding starts, so a job that fails later still leaves `Resume` a
                    // bookmark that resolves. A bookmark that cannot be made fails the job —
                    // without it the row would ask for the file again.
                    try await store.setSourceBookmark(try bookmarks.bookmark(for: chosenURL),
                                                      for: id)
                    url = chosenURL
                } else {
                    do {
                        guard let bookmark = transcript.sourceBookmark else {
                            throw MacomprendoError.sourceFileUnavailable
                        }
                        url = try bookmarks.resolve(bookmark)
                    } catch {
                        // The row keeps the reason it stopped with; only the state reports that
                        // the source cannot be found.
                        fail(ErrorText.describe(MacomprendoError.sourceFileUnavailable),
                             transcriptID: id, generation: generation)
                        return
                    }
                }
                try Task.checkCancellation()
                try await store.setStatus(.inProgress, reason: nil, for: id)
                marked = true
                await run(url: url, from: transcript.resumePosition, resuming: transcript,
                          generation: generation)

            case .call:
                await resumeCall(transcript, id: id, folderAt: chosenURL, generation: generation)
            }
        } catch {
            // A cancellation before the row is marked must not touch it: `Resume` was never
            // under way. Once marked, the row is this job's to finish.
            await settle(error, transcriptID: marked ? id : nil, generation: generation)
        }
    }

    /// The `.call` half of `resume`: finds the recording folder, plans what is left to
    /// transcribe and runs it. Until the row is marked `inProgress` the job can still fail
    /// without touching it — the folder, the manifest and every planned track file have to
    /// check out first — so a `Resume` whose recording is not there leaves the row exactly as
    /// it was and reports the failure the window answers with **Choose Folder…**.
    private func resumeCall(_ transcript: Transcript, id: Int64, folderAt chosenURL: URL?,
                            generation: Int) async {
        var marked = false
        do {
            let folder: URL?
            if let chosenURL {
                folder = chosenURL
            } else {
                folder = transcript.sourceBookmark.flatMap { try? bookmarks.resolve($0) }
            }
            // A folder that will not resolve, a `recording.json` that will not read, a track the
            // manifest names but the disk no longer has: all the same failure to the user. The
            // chosen folder replaces the stale bookmark only once it has proven it is one this
            // build can resume, so choosing badly cannot cost a bookmark that still works.
            guard let folder, let manifest = try? CallRecordingManifest.read(from: folder) else {
                failCallRecordingUnavailable(id: id, generation: generation)
                return
            }
            if chosenURL != nil {
                try await store.setSourceBookmark(try bookmarks.bookmark(for: folder), for: id)
            }
            let steps = CallTranscriptionPlan.steps(manifest: manifest,
                                                    stored: transcript.segments)
            guard steps.allSatisfy({ FileManager.default.fileExists(
                atPath: folder.appendingPathComponent($0.file).path) }) else {
                failCallRecordingUnavailable(id: id, generation: generation)
                return
            }
            try Task.checkCancellation()
            try await store.setStatus(.inProgress, reason: nil, for: id)
            marked = true
            await runCall(folder: folder, steps: steps, resuming: transcript,
                          generation: generation)
        } catch {
            await settle(error, transcriptID: marked ? id : nil, generation: generation)
        }
    }

    private func failCallRecordingUnavailable(id: Int64, generation: Int) {
        fail(ErrorText.describe(MacomprendoError.callRecordingUnavailable), transcriptID: id,
             generation: generation)
    }

    /// Runs one file through the pipeline, creating its row as the file opens. `Resume` enters
    /// here from the end of the last stored segment.
    private func run(url: URL, from start: TimeInterval, resuming: Transcript?,
                     generation: Int) async {
        let currentSettings = settings()
        let currentGlossary = currentSettings.glossaryEnabled ? glossary() : Glossary()
        let title = resuming?.header.title ?? url.lastPathComponent
        let progress = JobProgress(transcriptID: resuming?.id)
        let currentPipeline = pipeline()
        do {
            // Best effort: a file that cannot be bookmarked still transcribes — only `Resume`
            // then loses its way back to the source.
            let bookmark = resuming == nil ? try? bookmarks.bookmark(for: url) : nil
            try await consume(currentPipeline, url: url, from: start, title: title,
                              progress: progress, generation: generation,
                              settings: currentSettings, glossary: currentGlossary,
                              createRow: resuming == nil
                                  ? { openedDuration in
                                      try await self.store.create(
                                          sourceKind: .file, title: url.lastPathComponent,
                                          sourceBookmark: bookmark,
                                          duration: openedDuration,
                                          run: TranscriptionRun.from(
                                              currentSettings.transcriptionSource,
                                              language: currentSettings.transcriptionLanguage),
                                          at: self.now())
                                    }
                                  : nil)
            try Task.checkCancellation()
            if let id = progress.transcriptID {
                if progress.storedSegments == 0, resuming == nil {
                    // Nothing worth keeping: the empty transcript goes away with the failure.
                    try await store.delete(id: id)
                    fail(ErrorText.describe(MacomprendoError.noSpeechFound), transcriptID: nil,
                         generation: generation)
                } else {
                    try await store.setStatus(.complete, reason: nil, for: id)
                    if generation == self.generation {
                        state = .finished(transcriptID: id)
                    }
                }
            }
        } catch {
            await settle(error, transcriptID: progress.transcriptID, generation: generation)
        }
        // A file job waits for its pipeline only once its row reads what it is going to read:
        // settling must not be held up by a provider call still in flight.
        await finish(currentPipeline)
    }

    /// Runs the tracks a call `Resume` still owes, each through its own pipeline and in the
    /// plan's order. Zero segments in the whole transcript — this job's and any earlier run's —
    /// means the recording held no speech worth keeping: the empty row goes away with the
    /// failure, while the recording itself stays. Otherwise the row completes and `callFinished`
    /// reports it, so the app can say the transcript is ready.
    private func runCall(folder: URL, steps: [CallTranscriptionStep], resuming: Transcript,
                         generation: Int) async {
        let currentSettings = settings()
        let currentGlossary = currentSettings.glossaryEnabled ? glossary() : Glossary()
        let title = resuming.header.title
        let progress = JobProgress(transcriptID: resuming.id)
        var interrupted: LongAudioPipeline?
        do {
            for step in steps {
                try Task.checkCancellation()
                let pipeline = pipeline()
                interrupted = pipeline
                try await consume(pipeline, url: folder.appendingPathComponent(step.file),
                                  from: step.from, timeShift: step.offset,
                                  speaker: step.speaker, title: title, progress: progress,
                                  generation: generation, settings: currentSettings,
                                  glossary: currentGlossary)
                // Each track's provider is released before the next track's pipeline starts.
                await finish(pipeline)
                interrupted = nil
            }
            try Task.checkCancellation()
            if resuming.segments.count + progress.storedSegments == 0 {
                try await store.delete(id: resuming.id)
                fail(ErrorText.describe(MacomprendoError.noSpeechFound), transcriptID: nil,
                     generation: generation)
            } else {
                try await store.setStatus(.complete, reason: nil, for: resuming.id)
                if generation == self.generation {
                    state = .finished(transcriptID: resuming.id)
                    callFinished(resuming.id, title)
                }
            }
        } catch {
            await settle(error, transcriptID: progress.transcriptID, generation: generation)
        }
        // The interrupted track's provider is released only once the row's bookkeeping above
        // has landed: settling must not be held up by a provider call still in flight.
        if let interrupted {
            await finish(interrupted)
        }
    }

    /// The mutable bookkeeping of one running job, shared between the job's method and the
    /// consumer that lands its events: the row it writes into, the current track's length on
    /// its own clock, and how many segments this job has stored. A class, because the row a
    /// file job creates mid-run has to reach the caller even when the consumer later throws —
    /// that row is the job's to settle.
    private final class JobProgress {
        var transcriptID: Int64?
        var duration: TimeInterval = 0
        var storedSegments = 0

        init(transcriptID: Int64?) {
            self.transcriptID = transcriptID
        }
    }

    /// Lands one pipeline run's events in the job's row: every segment is normalised and
    /// appended, and the position is published as `.running`. A file job passes no shift and no
    /// speaker; a call job a track's `startOffset` and speaker, so events land on the call's
    /// clock. The caller stops and awaits the pipeline afterwards; on a throw this only stops
    /// the producing task, so the row's bookkeeping is never held up by a provider call still
    /// in flight.
    private func consume(_ pipeline: LongAudioPipeline,
                         url: URL, from start: TimeInterval,
                         timeShift: TimeInterval = 0, speaker: TranscriptSpeaker? = nil,
                         title: String, progress: JobProgress, generation: Int,
                         settings: Settings, glossary: Glossary,
                         createRow: ((TimeInterval) async throws -> Int64)? = nil) async throws {
        do {
            // A job cancelled while it waited behind a superseded one must not even open the
            // file: decoding starts only once this check has passed.
            try Task.checkCancellation()
            // Cancelling this task — `cancel()`, a superseding job, `shutdown()` — must reach
            // the pipeline as it happens, not when this code next runs: the producing task is
            // what holds the provider, and it must not be free to start another segment in the
            // gap between the cancellation and the loop unwinding.
            try await withTaskCancellationHandler(operation: {
                for try await event in pipeline.run(url, from: start) {
                    try Task.checkCancellation()
                    switch event {
                    case let .opened(openedDuration):
                        progress.duration = openedDuration
                        if let createRow {
                            progress.transcriptID = try await createRow(openedDuration)
                        }
                        guard generation == self.generation,
                              let id = progress.transcriptID else { continue }
                        state = .running(transcriptID: id, title: title,
                                         position: start + timeShift,
                                         duration: openedDuration + timeShift,
                                         speaker: speaker)

                    case let .segment(segmentStart, segmentEnd, text):
                        let normalised = settings.glossaryEnabled
                            ? Normalizer.normalise(text, with: glossary)
                            : NormalisationResult(text: text, rewrites: [])
                        guard let id = progress.transcriptID else { continue }
                        try await store.appendSegment(
                            TranscriptSegment(start: segmentStart + timeShift,
                                              end: segmentEnd + timeShift,
                                              text: normalised.text,
                                              rawText: normalised.rewrites.isEmpty ? nil : text,
                                              speaker: speaker),
                            to: id)
                        progress.storedSegments += 1
                        transcriptsChanged()

                    case let .position(position):
                        guard generation == self.generation,
                              let id = progress.transcriptID else { continue }
                        state = .running(transcriptID: id, title: title,
                                         position: position + timeShift,
                                         duration: progress.duration + timeShift,
                                         speaker: speaker)
                    }
                }
            }, onCancel: {
                pipeline.stop()
            })
            // A cancelled job's stream simply ends; without this it would go on to finish its
            // row as if it had transcribed everything.
            try Task.checkCancellation()
        } catch {
            pipeline.stop()
            throw error
        }
    }

    /// The job is not over when its event stream is: the pipeline's producing task holds the
    /// provider — and with it the local model's native context — until it ends. Stop it
    /// explicitly (the stream's own termination callback is not ordered against this point) and
    /// wait for it, so this job's task, and `shutdown()` waiting on it, end only once that
    /// reference is released; the next track's pipeline cannot start before this returns.
    private func finish(_ pipeline: LongAudioPipeline) async {
        pipeline.stop()
        await pipeline.awaitCompletion()
    }

    // MARK: - Endings

    /// A failure with no row to mark: a failed preflight, an unreadable file, a transcript that
    /// no longer exists. Only the current job may touch `state`.
    private func fail(_ message: String, transcriptID: Int64?, generation: Int) {
        guard generation == self.generation else { return }
        state = .failed(message: message, transcriptID: transcriptID)
    }

    /// Ends a job with an error: its row, when it has one, becomes `incomplete` with the error's
    /// text — `"Cancelled."` for a cancellation, `abandonedJobReason` when the cancellation
    /// came from `shutdown()` — and the state returns to `.idle` for a cancellation, `.failed`
    /// otherwise. The store write happens even when the job was superseded, because the row is
    /// still this job's; the state write only when it is current.
    private func settle(_ error: Error, transcriptID: Int64?, generation: Int) async {
        let cancelled = Self.isCancellation(error)
        let reason = cancelled && isShuttingDown
            ? TranscriptLibraryController.abandonedJobReason
            : ErrorText.describe(error)
        if let transcriptID {
            // Nothing useful is left to do if the store cannot record the reason.
            try? await store.setStatus(.incomplete, reason: reason, for: transcriptID)
        }
        guard generation == self.generation else { return }
        state = cancelled ? .idle : .failed(message: reason, transcriptID: transcriptID)
    }

    /// Both the cooperative `CancellationError` and the provider-mapped `MacomprendoError.cancelled`
    /// mean the same thing: the job was stopped, not that it stumbled.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? MacomprendoError, error == .cancelled { return true }
        return false
    }
}
