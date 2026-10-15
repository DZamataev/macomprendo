import Foundation

/// The moment this process launched, captured at first access. `AppModel` reads it in its init
/// — before any hotkey can start a recording — and hands it to `CallRecordingRecovery`, which
/// must never finalise a recording this process started.
enum ProcessLaunch {
    static let date = Date()
}

/// Launch recovery for call recordings a crash, a force-quit or a power loss cut short: every
/// folder whose `recording.json` still says `recording` is finalised, and each one the library
/// does not already know gets an `incomplete` call transcript, so it shows up in Transcripts and
/// `Resume` transcribes it.
///
/// Runs once at launch, after abandoned jobs are marked and before any job can start. A folder
/// still marked `recording` and started before this process launched can only belong to a
/// session the app did not finish; one started at or after the launch belongs to a recording
/// this process is still making, and is left alone. One folder's failure never stops the rest:
/// it is logged without the folder's or the title's name and skipped.
@MainActor
struct CallRecordingRecovery {
    private let folders: any CallRecordingFolderManaging
    private let store: any TranscriptStoring
    private let bookmarks: any FileBookmarking
    private let settings: @MainActor () -> Settings
    private let now: () -> Date
    private let launchDate: Date

    init(folders: any CallRecordingFolderManaging, store: any TranscriptStoring,
         bookmarks: any FileBookmarking, settings: @escaping @MainActor () -> Settings,
         now: @escaping () -> Date = Date.init,
         launchDate: Date = ProcessLaunch.date) {
        self.folders = folders
        self.store = store
        self.bookmarks = bookmarks
        self.settings = settings
        self.now = now
        self.launchDate = launchDate
    }

    /// Finalises every `.recording` folder and gives each one without a transcript an
    /// `incomplete` call transcript. Returns how many call transcripts it created.
    @discardableResult
    func recover() async -> Int {
        let unfinished = folders.unfinishedRecordings(
            in: CallRecordingLayout.directory(for: settings()))
        guard !unfinished.isEmpty else { return 0 }
        // Creating a row means knowing which folders already have one. Without that list a row
        // could be duplicated, so leave every folder `recording` for a later launch to retry.
        guard let known = await foldersKnownToTheLibrary() else {
            Log.app.error("Call recording recovery skipped: the transcript list could not be read")
            return 0
        }
        var created = 0
        for folder in unfinished {
            if await recover(folder, knownTo: known) { created += 1 }
        }
        return created
    }

    /// Finalises one folder and, when no transcript points at it, gives it an `incomplete` row.
    /// Returns whether a call transcript was created: a row counts from the moment it exists, so
    /// one whose status will not write is still counted and the next launch's abandoned-job pass
    /// repairs it.
    ///
    /// The row comes first and the `.finished` manifest second, the same order the recorder uses.
    /// The other order loses a recording for good: a `create` that fails, or a crash in that
    /// window, would leave the folder `finished` with no transcript pointing at it, and nothing
    /// sweeps for those. This way the folder stays `recording` and the next launch finalises it
    /// and creates no second row.
    private func recover(_ folder: URL, knownTo known: Set<String>) async -> Bool {
        let manifest: CallRecordingManifest
        do {
            manifest = try CallRecordingManifest.read(from: folder)
        } catch {
            Log.app.error("Call recording recovery could not read a recording")
            return false
        }
        // A folder started at or after this process launched is this process's own recording —
        // finalising it mid-recording would split one call into two transcripts. The manifest's
        // `startedAt` is `.iso8601`, whole seconds, so compare at that precision.
        guard Int(manifest.startedAt.timeIntervalSince1970) < Int(launchDate.timeIntervalSince1970)
        else {
            Log.app.info("Call recording recovery left a recording this launch started")
            return false
        }
        if known.contains(folder.standardizedFileURL.path) {
            finalise(manifest, in: folder)
            return false
        }
        // A row whose bookmark cannot be made is one the library could not find again on the next
        // launch either, so the folder would collect a second row. Leave it `recording` to retry.
        let bookmark: Data
        do {
            bookmark = try bookmarks.bookmark(for: folder)
        } catch {
            Log.app.error("Call recording recovery could not bookmark a recording")
            return false
        }
        let id: Int64
        do {
            id = try await store.create(
                sourceKind: .call,
                title: CallRecordingLayout.transcriptTitle(startedAt: manifest.startedAt),
                sourceBookmark: bookmark,
                duration: nil,
                run: TranscriptionRun.from(settings().transcriptionSource,
                                           language: settings().transcriptionLanguage),
                at: now())
        } catch {
            // Nothing points at the folder yet, so it stays `recording` and the next launch
            // recovers it: the row is what is missing, not the audio.
            Log.app.error("Call recording recovery could not store a transcript for a recording")
            return false
        }
        do {
            try await store.setStatus(.incomplete,
                                      reason: TranscriptLibraryController.abandonedJobReason,
                                      for: id)
        } catch {
            // The row is there; a status left `inProgress` is what the next launch's
            // abandoned-job pass repairs.
            Log.app.error("Call recording recovery could not mark a transcript incomplete")
        }
        finalise(manifest, in: folder)
        return true
    }

    /// Writes the manifest `.finished`. A failure leaves the folder `recording`, which is safe:
    /// the row exists by now, so the next launch finalises it and creates no second one.
    private func finalise(_ manifest: CallRecordingManifest, in folder: URL) {
        var finished = manifest
        finished.status = .finished
        do {
            try finished.write(to: folder)
        } catch {
            Log.app.error("Call recording recovery could not finalise a recording")
        }
    }

    /// The folders whose paths the library's call transcripts resolve to. `nil` when the library
    /// could not be listed at all.
    private func foldersKnownToTheLibrary() async -> Set<String>? {
        guard let headers = try? await store.headers() else { return nil }
        var paths: Set<String> = []
        for header in headers where header.sourceKind == .call {
            // A transcript whose bookmark no longer resolves does not point at the folder, so
            // the folder is recovered as if it had none.
            guard let transcript = try? await store.transcript(id: header.id),
                  let bookmark = transcript.sourceBookmark,
                  let url = try? bookmarks.resolve(bookmark) else { continue }
            paths.insert(url.standardizedFileURL.path)
        }
        return paths
    }
}
