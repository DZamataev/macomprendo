import Foundation

/// Transcribes one audio or video file at a time through the long-audio pipeline, writing each
/// segment into the transcript store as it lands and reporting progress as one `State`.
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
                     duration: TimeInterval)
        case finished(transcriptID: Int64)
        case failed(message: String, transcriptID: Int64?)
    }

    @Published private(set) var state: State = .idle

    private enum Job: Sendable {
        case transcribe(url: URL)
        /// `fileAt` is the URL the user chose after the stored bookmark stopped resolving;
        /// `nil` means resolve the bookmark.
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
         transcriptsChanged: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.bookmarks = bookmarks
        self.pipeline = pipeline
        self.settings = settings
        self.glossary = glossary
        self.readiness = readiness
        self.now = now
        self.transcriptsChanged = transcriptsChanged
    }

    /// Starts a job for `url`, cancelling any job already running. A backend that is not ready
    /// fails before any decoding starts and creates no row.
    func transcribe(fileAt url: URL) {
        let previous = supersede()
        switch readiness() {
        case .ready:
            start(.transcribe(url: url), after: previous)
        case let .notReady(reason, _):
            state = .failed(message: reason, transcriptID: nil)
        }
    }

    /// Continues an `incomplete` transcript from the end of its last stored segment, cancelling
    /// any job already running.
    func resume(transcriptID: Int64) {
        let previous = supersede()
        start(.resume(transcriptID: transcriptID, fileAt: nil), after: previous)
    }

    /// Continues an `incomplete` transcript from the end of its last stored segment, using
    /// `url` as its source instead of the stored bookmark — the path the window offers when
    /// the bookmark no longer resolves. A fresh bookmark for `url` replaces the stale one,
    /// so the next `Resume` finds the file again.
    func resume(transcriptID: Int64, fileAt url: URL) {
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
            let url: URL
            if let chosenURL {
                // The user picked the source file again: it becomes the row's source before
                // any decoding starts, so a job that fails later still leaves `Resume` a
                // bookmark that resolves. A bookmark that cannot be made fails the job —
                // without it the row would ask for the file again.
                try await store.setSourceBookmark(try bookmarks.bookmark(for: chosenURL), for: id)
                url = chosenURL
            } else {
                do {
                    guard let bookmark = transcript.sourceBookmark else {
                        throw MacomprendoError.sourceFileUnavailable
                    }
                    url = try bookmarks.resolve(bookmark)
                } catch {
                    // The row keeps the reason it stopped with; only the state reports that the
                    // source cannot be found.
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
        } catch {
            // A cancellation before the row is marked must not touch it: `Resume` was never
            // under way. Once marked, the row is this job's to finish.
            await settle(error, transcriptID: marked ? id : nil, generation: generation)
        }
    }

    private func run(url: URL, from start: TimeInterval, resuming: Transcript?,
                     generation: Int) async {
        let currentSettings = settings()
        let currentGlossary = currentSettings.glossaryEnabled ? glossary() : Glossary()
        let currentPipeline = pipeline()
        let title = resuming?.header.title ?? url.lastPathComponent
        var transcriptID = resuming?.id
        var duration: TimeInterval = 0
        var storedSegments = 0
        do {
            // A job cancelled while it waited behind a superseded one must not even open the
            // file: decoding starts only once this check has passed.
            try Task.checkCancellation()
            // Best effort: a file that cannot be bookmarked still transcribes — only `Resume`
            // then loses its way back to the source.
            let bookmark = resuming == nil ? try? bookmarks.bookmark(for: url) : nil
            // Cancelling this task — `cancel()`, a superseding job, `shutdown()` — must reach
            // the pipeline as it happens, not when this code next runs: the producing task is
            // what holds the provider, and it must not be free to start another segment in the
            // gap between the cancellation and the loop unwinding.
            try await withTaskCancellationHandler(operation: {
                for try await event in currentPipeline.run(url, from: start) {
                    try Task.checkCancellation()
                    switch event {
                    case let .opened(openedDuration):
                        duration = openedDuration
                        if resuming == nil {
                            transcriptID = try await store.create(
                                sourceKind: .file, title: url.lastPathComponent,
                                sourceBookmark: bookmark, duration: openedDuration,
                                run: TranscriptionRun.from(currentSettings.transcriptionSource,
                                                           language: currentSettings.transcriptionLanguage),
                                at: now())
                        }
                        guard generation == self.generation, let id = transcriptID else { continue }
                        state = .running(transcriptID: id, title: title, position: start,
                                         duration: openedDuration)

                    case let .segment(segmentStart, segmentEnd, text):
                        let normalised = currentSettings.glossaryEnabled
                            ? Normalizer.normalise(text, with: currentGlossary)
                            : NormalisationResult(text: text, rewrites: [])
                        guard let id = transcriptID else { continue }
                        try await store.appendSegment(
                            TranscriptSegment(start: segmentStart, end: segmentEnd,
                                              text: normalised.text,
                                              rawText: normalised.rewrites.isEmpty ? nil : text),
                            to: id)
                        storedSegments += 1
                        transcriptsChanged()

                    case let .position(position):
                        guard generation == self.generation, let id = transcriptID else { continue }
                        state = .running(transcriptID: id, title: title, position: position,
                                         duration: duration)
                    }
                }
            }, onCancel: {
                currentPipeline.stop()
            })
            try Task.checkCancellation()
            if let id = transcriptID {
                if storedSegments == 0, resuming == nil {
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
            await settle(error, transcriptID: transcriptID, generation: generation)
        }
        // The job is not over when its event stream is: the pipeline's producing task holds the
        // provider — and with it the local model's native context — until it ends. Stop it
        // explicitly (the stream's own termination callback is not ordered against this point)
        // and wait for it, so this job's task, and `shutdown()` waiting on it, end only once
        // that reference is released. A superseding job therefore also cannot start while the
        // job it replaced still holds the provider.
        currentPipeline.stop()
        await currentPipeline.awaitCompletion()
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
