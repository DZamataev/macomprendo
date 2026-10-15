import Foundation

/// Launch recovery for call recordings a crash, a force-quit or a power loss cut short: every
/// folder whose `recording.json` still says `recording` is finalised, and each one the library
/// does not already know gets an `incomplete` call transcript, so it shows up in Transcripts and
/// `Resume` transcribes it.
///
/// Runs once at launch, after abandoned jobs are marked and before any job can start, so a
/// folder still marked `recording` can only belong to a session the app did not finish. One
/// folder's failure never stops the rest: it is logged without the folder's or the title's name
/// and skipped.
@MainActor
struct CallRecordingRecovery {
    private let folders: any CallRecordingFolderManaging
    private let store: any TranscriptStoring
    private let bookmarks: any FileBookmarking
    private let settings: @MainActor () -> Settings
    private let now: () -> Date

    init(folders: any CallRecordingFolderManaging, store: any TranscriptStoring,
         bookmarks: any FileBookmarking, settings: @escaping @MainActor () -> Settings,
         now: @escaping () -> Date = Date.init) {
        self.folders = folders
        self.store = store
        self.bookmarks = bookmarks
        self.settings = settings
        self.now = now
    }

    /// Finalises every `.recording` folder and gives each one without a transcript an
    /// `incomplete` call transcript. Returns how many incomplete transcripts it created.
    @discardableResult
    func recover() async -> Int {
        let unfinished = folders.unfinishedRecordings(in: recordingsDirectory)
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

    private var recordingsDirectory: URL {
        settings().callRecordingsDirectory.map { URL(fileURLWithPath: $0) }
            ?? CallRecordingLayout.defaultDirectory
    }

    /// Finalises one folder and, when no transcript points at it, gives it an `incomplete` row.
    /// Returns whether an incomplete transcript was created.
    private func recover(_ folder: URL, knownTo known: Set<String>) async -> Bool {
        let manifest: CallRecordingManifest
        do {
            manifest = try CallRecordingManifest.read(from: folder)
            var finished = manifest
            finished.status = .finished
            try finished.write(to: folder)
        } catch {
            Log.app.error("Call recording recovery could not finalise a recording")
            return false
        }
        guard !known.contains(folder.standardizedFileURL.path) else { return false }
        do {
            let id = try await store.create(
                sourceKind: .call,
                title: CallRecordingLayout.transcriptTitle(startedAt: manifest.startedAt),
                sourceBookmark: try? bookmarks.bookmark(for: folder),
                duration: nil,
                run: TranscriptionRun.from(settings().transcriptionSource,
                                           language: settings().transcriptionLanguage),
                at: now())
            try await store.setStatus(.incomplete,
                                      reason: TranscriptLibraryController.abandonedJobReason,
                                      for: id)
            return true
        } catch {
            // The folder is finalised and its files are kept; only the row is missing. A row this
            // left `inProgress` is what the next launch's abandoned-job pass repairs.
            Log.app.error("Call recording recovery could not store a transcript for a recording")
            return false
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
