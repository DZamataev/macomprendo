import CryptoKit
import Foundation

/// Where one catalog model stands on this machine.
enum ModelState: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    /// Every file in the model's set is present. Paths come from `ModelManaging.resolved(_:)`
    /// rather than from this case: a model is a file set, so there is no single URL to carry.
    case downloaded
    case failed(String)
}

/// A model whose every file is on disk, with the runtime that opens it.
struct ResolvedLocalModel: Sendable, Equatable {
    let engine: LocalEngine
    let files: [ModelFileRole: URL]
    /// The extracted `models/<model-id>/` directory for archive models; `nil` for loose files.
    let directory: URL?

    init(engine: LocalEngine, files: [ModelFileRole: URL], directory: URL? = nil) {
        self.engine = engine
        self.files = files
        self.directory = directory
    }
}

/// Manages the on-disk local-model store.
protocol ModelManaging: AnyObject, Sendable {
    func state(of id: String) async -> ModelState
    /// `nil` when the model is unknown or any file of its set is missing.
    func resolved(_ id: String) async -> ResolvedLocalModel?
    /// Yields the completed fraction (0...1) across the whole file set. Verifies each file's
    /// SHA-256 and moves it into place atomically. Cancelling the consuming task cancels the
    /// download and leaves partial files for a later resume.
    func download(_ id: String) -> AsyncThrowingStream<Double, Error>
    func delete(_ id: String) async throws
    var modelsDirectory: URL { get }
}

/// Downloads local ASR models into `~/Library/Application Support/Macomprendo/models/`.
///
/// A model is a set of files — one ggml blob for whisper.cpp, several tensors plus a
/// token table for a sherpa-onnx transducer — and counts as downloaded only when every
/// one of them is present.
///
/// Resume is done with HTTP `Range` requests against a `<fileName>.partial` sidecar
/// rather than `URLSessionDownloadTask` resume data, so the whole flow stays behind
/// the `HTTPClient` seam and is unit-testable.
actor LocalModelManager: ModelManaging {

    nonisolated let modelsDirectory: URL
    private let http: any HTTPClient
    private let catalog: [LocalModel]
    private let archiveExtractor: any ArchiveExtracting
    private var states: [String: ModelState] = [:]
    /// Model ids with a download currently running, so a second concurrent
    /// `download(_:)` for the same id is rejected instead of racing the first
    /// one over the same `.partial` file.
    private var inFlight: Set<String> = []
    /// Deletion invalidates any suspended operation that captured an older value.
    private var operationEpochs: [String: Int] = [:]

    // Both kinds: this manager downloads TTS models too.
    init(directory: URL, http: any HTTPClient) {
        self.init(directory: directory, http: http, catalog: ModelCatalog.all,
                  archiveExtractor: TarArchiveExtractor())
    }

    /// Catalog and extractor injecting initialiser, used by tests.
    init(directory: URL,
         http: any HTTPClient,
         catalog: [LocalModel],
         archiveExtractor: any ArchiveExtracting = TarArchiveExtractor()) {
        self.modelsDirectory = directory
        self.http = http
        self.catalog = catalog
        self.archiveExtractor = archiveExtractor
    }

    // MARK: - Queries

    func state(of id: String) async -> ModelState {
        if let known = states[id] {
            switch known {
            case .downloading, .failed: return known
            case .notDownloaded, .downloaded: break
            }
        }
        guard let model = model(id) else { return .notDownloaded }
        return isComplete(model) ? .downloaded : .notDownloaded
    }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        guard let model = model(id), isComplete(model) else { return nil }
        if model.file(.archive) != nil {
            return ResolvedLocalModel(engine: model.engine, files: [:],
                                      directory: extractedDirectory(for: model))
        }
        var urls: [ModelFileRole: URL] = [:]
        for file in model.files { urls[file.role] = destinationURL(for: file) }
        return ResolvedLocalModel(engine: model.engine, files: urls)
    }

    // MARK: - Delete

    func delete(_ id: String) async throws {
        guard let model = model(id) else { throw MacomprendoError.modelMissing(id) }
        operationEpochs[id, default: 0] += 1
        do {
            try removeArtifacts(for: model)
        } catch {
            states[id] = isComplete(model) ? .downloaded : .notDownloaded
            throw MacomprendoError.modelDownloadFailed("Could not delete \(id).")
        }
        states[id] = .notDownloaded
    }

    // MARK: - Download

    nonisolated func download(_ id: String) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performDownload(id, continuation: continuation)
                    continuation.finish()
                } catch {
                    // A raw `CancellationError` reaches here either from
                    // `Task.checkCancellation()` inside the GET loop, or from any
                    // other suspension point that reacted to the consumer cancelling
                    // this stream; normalise both to `.cancelled` so callers only ever
                    // see `MacomprendoError`.
                    let mapped: Error = (error is CancellationError) ? MacomprendoError.cancelled : error
                    await recordTerminalState(id, error: mapped)
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performDownload(
        _ id: String,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        // Check-and-insert happens atomically here because this whole method runs
        // actor-isolated: no other call can observe `inFlight` between the check and
        // the insert. Removed in every exit path (success, failure, cancellation) via
        // `defer`, so a finished or failed attempt never blocks a later one.
        guard inFlight.insert(id).inserted else {
            throw MacomprendoError.modelDownloadFailed(
                "A download for this model is already in progress."
            )
        }
        defer { inFlight.remove(id) }

        guard let model = model(id) else { throw MacomprendoError.modelMissing(id) }
        let operationEpoch = operationEpochs[id, default: 0]

        if isComplete(model) {
            states[id] = .downloaded
            continuation.yield(1.0)
            return
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        states[id] = .downloading(fraction: 0)

        // Progress spans the whole set so a four-file transducer does not appear to finish
        // four times. Sizes come from the catalog rather than from HEAD, because the HEAD for
        // a later file has not happened yet when the first one starts streaming.
        let setTotal = max(1, model.totalSizeBytes)
        var completedBytes: Int64 = 0
        var lastReported = -1.0

        for file in model.files {
            // `downloadOne` only observes cancellation once it is streaming, so without this
            // a consumer who cancels between two files would still see the next file's HEAD
            // go out. A one-file model had no such window; a file set does.
            try Task.checkCancellation()

            let destination = destinationURL(for: file)
            if FileManager.default.fileExists(atPath: destination.path) {
                if file.role != .archive || file.sha256.isEmpty
                    || (try? Self.sha256(of: destination)) == file.sha256 {
                    completedBytes += file.sizeBytes
                    continue
                }
                try FileManager.default.removeItem(at: destination)
            }
            try await downloadOne(file) { bytesInThisFile in
                let fraction = min(1.0, Double(completedBytes + bytesInThisFile) / Double(setTotal))
                // A 1.6 GB download would otherwise emit tens of thousands of updates.
                // `lastReported < 1.0` keeps that true even when the server sends more than
                // the catalog's recorded size: the fraction then pins at 1.0 and would
                // otherwise wave every remaining chunk straight past the throttle.
                if fraction - lastReported >= 0.01 || (fraction >= 1.0 && lastReported < 1.0) {
                    lastReported = fraction
                    self.states[id] = .downloading(fraction: fraction)
                    continuation.yield(fraction)
                }
            }
            try requireCurrentOperation(id: id, epoch: operationEpoch, model: model)
            completedBytes += file.sizeBytes
        }

        if let archive = model.file(.archive) {
            let archiveURL = destinationURL(for: archive)
            let directory = extractedDirectory(for: model)
            try await archiveExtractor.extract(archive: archiveURL, to: directory, modelID: model.id)
            guard !Task.isCancelled, operationEpochs[id, default: 0] == operationEpoch else {
                // `Process`-backed extraction cannot be interrupted safely mid-write. Once it
                // returns, discard its result instead of publishing a cancelled download.
                try? FileManager.default.removeItem(at: directory)
                throw MacomprendoError.cancelled
            }
            guard isComplete(model) else {
                throw MacomprendoError.modelDownloadFailed(model.id)
            }
            // Cleanup cannot make a successfully extracted, engine-ready model unusable.
            do {
                try FileManager.default.removeItem(at: archiveURL)
            } catch {
                Log.providers.warning(
                    "Could not clean downloaded archive for \(id, privacy: .public); extracted model remains usable"
                )
            }
        }

        states[id] = .downloaded
        continuation.yield(1.0)
    }

    /// Downloads one file of a set. `onProgress` receives the byte count written for THIS
    /// file so the caller can place it inside the set's overall progress.
    private func downloadOne(_ file: ModelFile, onProgress: (Int64) -> Void) async throws {
        // 1. HEAD for the authoritative size and range support.
        let head = try await http.send(HTTPRequest(method: "HEAD", url: file.downloadURL, timeout: 10))
        let total = Int64(head.header("Content-Length") ?? "") ?? file.sizeBytes
        let acceptsRanges = (head.header("Accept-Ranges") ?? "").lowercased() == "bytes"

        // 2. Decide whether to resume.
        let partial = partialURL(for: file)
        var received = resumableByteCount(at: partial, total: total, acceptsRanges: acceptsRanges)
        if received == 0 {
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }

        var headers: [String: String] = [:]
        if received > 0 { headers["Range"] = "bytes=\(received)-" }

        // 3. Stream the body onto the partial file.
        //
        // NOTE: `HTTPClient.stream` deliberately does not expose the response status
        // (see its doc comment), so if a server ignores our `Range` header and sends
        // the full 200 body instead of a 206 partial one, we cannot detect that from
        // the status here. It still fails safely in practice: we append onto the
        // existing `received` bytes, so `received` overshoots `total` and the
        // completeness check below throws `modelDownloadFailed` and cleans up. The one
        // gap is a pathological, currently-accepted limitation: an ignored-Range body
        // that happens to be exactly `total - received` bytes long (matching the
        // expected remainder count) combined with an empty catalog `sha256` (which
        // skips verification, see Task 13) would pass unnoticed. That closes once
        // `ModelCatalog`'s hashes are filled in, since the checksum check would then
        // catch the wrong bytes.
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        for try await chunk in http.stream(
            HTTPRequest(method: "GET", url: file.downloadURL, headers: headers, timeout: 60)
        ) {
            // This mostly guards other cancellation-triggered suspension points, not
            // consumer-side cancellation of this loop itself: per `HTTPClient`'s doc
            // comment, when this task (the consumer of `http.stream`) is the one that
            // gets cancelled mid-iteration, `AsyncThrowingStream` ends the `for await`
            // loop silently instead of throwing here, so this check never runs again
            // for that case. That case is caught by the `Task.isCancelled` check right
            // below the loop instead.
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)

            onProgress(received)
        }
        try handle.close()

        // Cancellation is not a truncated download: keep the partial file for a
        // later resume instead of falling into the "received != total" cleanup
        // below, which would delete it and report a misleading download failure.
        // This is the loop-ends-silently case described above; `Task.checkCancellation()`
        // covers the other case by throwing `CancellationError` directly instead, which
        // skips straight past the rest of this function and is normalised to
        // `.cancelled` by `download(_:)` the same way.
        if Task.isCancelled {
            throw MacomprendoError.cancelled
        }

        // 4. Verify: a truncated ggml file fails deep inside whisper.cpp with a
        //    useless message, so catch it here. Only reached when not cancelled, so
        //    this cleanup never races with the cancellation path above.
        if received != total {
            try? FileManager.default.removeItem(at: partial)
            throw MacomprendoError.modelDownloadFailed(
                "\(file.fileName): expected \(total) bytes, received \(received)"
            )
        }
        if file.sha256.isEmpty {
            Log.providers.warning(
                "No SHA-256 recorded for model file \(file.fileName, privacy: .public); skipping integrity check"
            )
        } else if try Self.sha256(of: partial) != file.sha256 {
            try? FileManager.default.removeItem(at: partial)
            throw MacomprendoError.modelDownloadFailed("\(file.fileName): checksum mismatch")
        }

        // 5. Atomic move: a half-written file is never visible as a usable model.
        let destination = destinationURL(for: file)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: - Helpers

    private func recordTerminalState(_ id: String, error: Error) {
        // A rejected duplicate never owned the active operation and must not overwrite its state.
        guard !inFlight.contains(id) else { return }
        if error is CancellationError || (error as? MacomprendoError) == .cancelled {
            states[id] = .notDownloaded
        } else {
            states[id] = .failed(error.localizedDescription)
        }
    }

    private func model(_ id: String) -> LocalModel? {
        catalog.first { $0.id == id }
    }

    private func isComplete(_ model: LocalModel) -> Bool {
        if model.file(.archive) != nil {
            guard let sentinel = model.archiveSentinel, !sentinel.isEmpty else { return false }
            let url = extractedDirectory(for: model).appendingPathComponent(sentinel)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        return model.files.allSatisfy {
            FileManager.default.fileExists(atPath: destinationURL(for: $0).path)
        }
    }

    private func extractedDirectory(for model: LocalModel) -> URL {
        modelsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    private func destinationURL(for file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.fileName)
    }

    private func partialURL(for file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.fileName + ".partial")
    }

    private func requireCurrentOperation(id: String, epoch: Int, model: LocalModel) throws {
        guard !Task.isCancelled, operationEpochs[id, default: 0] == epoch else {
            try? removeArtifacts(for: model)
            throw MacomprendoError.cancelled
        }
    }

    private func removeArtifacts(for model: LocalModel) throws {
        let fileManager = FileManager.default
        var urls = model.files.flatMap { [destinationURL(for: $0), partialURL(for: $0)] }
        if model.file(.archive) != nil { urls.append(extractedDirectory(for: model)) }
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Bytes we can keep from a previous attempt: only when the server supports
    /// ranges and the partial file is strictly smaller than the full download.
    private func resumableByteCount(at partial: URL, total: Int64, acceptsRanges: Bool) -> Int64 {
        guard acceptsRanges,
              let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value < total else { return 0 }
        return size.int64Value
    }

    /// Streams the file through SHA-256 in 1 MiB blocks so a 1.6 GB model is never
    /// resident in memory. Returns a lowercase hex digest.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
