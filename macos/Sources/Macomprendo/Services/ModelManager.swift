import CryptoKit
import Foundation

/// Where one catalog model stands on this machine.
enum ModelState: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    case downloaded(URL)
    case failed(String)
}

/// Manages the on-disk whisper model store.
protocol ModelManaging: AnyObject, Sendable {
    func state(of id: String) async -> ModelState
    func localURL(for id: String) async -> URL?
    /// Yields the completed fraction (0...1). Verifies SHA-256 and moves the file
    /// into place atomically. Cancelling the consuming task cancels the download
    /// and leaves the partial file for a later resume.
    func download(_ id: String) -> AsyncThrowingStream<Double, Error>
    func delete(_ id: String) async throws
    var modelsDirectory: URL { get }
}

/// Downloads whisper ggml models into `~/Library/Application Support/Macomprendo/models/`.
///
/// Resume is done with HTTP `Range` requests against a `<fileName>.partial` sidecar
/// rather than `URLSessionDownloadTask` resume data, so the whole flow stays behind
/// the `HTTPClient` seam and is unit-testable.
actor WhisperModelManager: ModelManaging {

    nonisolated let modelsDirectory: URL
    private let http: any HTTPClient
    private let catalog: [WhisperModel]
    private var states: [String: ModelState] = [:]
    /// Model ids with a download currently running, so a second concurrent
    /// `download(_:)` for the same id is rejected instead of racing the first
    /// one over the same `.partial` file.
    private var inFlight: Set<String> = []

    init(directory: URL, http: any HTTPClient) {
        self.init(directory: directory, http: http, catalog: ModelCatalog.all)
    }

    /// Catalog-injecting initialiser, used by tests.
    init(directory: URL, http: any HTTPClient, catalog: [WhisperModel]) {
        self.modelsDirectory = directory
        self.http = http
        self.catalog = catalog
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
        let destination = destinationURL(for: model)
        return FileManager.default.fileExists(atPath: destination.path)
            ? .downloaded(destination)
            : .notDownloaded
    }

    func localURL(for id: String) async -> URL? {
        guard let model = model(id) else { return nil }
        let destination = destinationURL(for: model)
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    // MARK: - Delete

    func delete(_ id: String) async throws {
        guard let model = model(id) else { throw MacomprendoError.modelMissing(id) }
        try? FileManager.default.removeItem(at: destinationURL(for: model))
        try? FileManager.default.removeItem(at: partialURL(for: model))
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
                    await setState(id, .failed(error.localizedDescription))
                    continuation.finish(throwing: error)
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

        let destination = destinationURL(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            states[id] = .downloaded(destination)
            continuation.yield(1.0)
            return
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        states[id] = .downloading(fraction: 0)

        // 1. HEAD for the authoritative size and range support.
        let head = try await http.send(HTTPRequest(method: "HEAD", url: model.downloadURL, timeout: 10))
        let total = Int64(head.header("Content-Length") ?? "") ?? model.sizeBytes
        let acceptsRanges = (head.header("Accept-Ranges") ?? "").lowercased() == "bytes"

        // 2. Decide whether to resume.
        let partial = partialURL(for: model)
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

        var lastReported = -1.0
        for try await chunk in http.stream(
            HTTPRequest(method: "GET", url: model.downloadURL, headers: headers, timeout: 60)
        ) {
            // This mostly guards other cancellation-triggered suspension points, not
            // consumer-side cancellation of this loop itself: per `HTTPClient`'s doc
            // comment, when this task (the consumer of `http.stream`) is the one that
            // gets cancelled mid-iteration, `AsyncThrowingStream` ends the `for await`
            // loop silently instead of throwing here, so this check never runs again
            // for that case. That is still safe: the loop simply stops early, and the
            // `received != total` completeness check below throws
            // `modelDownloadFailed`, same as any other truncated download.
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)

            let fraction = total > 0 ? min(1.0, Double(received) / Double(total)) : 0
            // A 1.6 GB download would otherwise emit tens of thousands of updates.
            if fraction - lastReported >= 0.01 || fraction >= 1.0 {
                lastReported = fraction
                states[id] = .downloading(fraction: fraction)
                continuation.yield(fraction)
            }
        }
        try handle.close()

        // 4. Verify: a truncated ggml file fails deep inside whisper.cpp with a
        //    useless message, so catch it here.
        if received != total {
            try? FileManager.default.removeItem(at: partial)
            throw MacomprendoError.modelDownloadFailed(
                "\(model.displayName): expected \(total) bytes, received \(received)"
            )
        }
        if model.sha256.isEmpty {
            Log.providers.warning(
                "No SHA-256 recorded for whisper model \(model.id, privacy: .public); skipping integrity check"
            )
        } else if try Self.sha256(of: partial) != model.sha256 {
            try? FileManager.default.removeItem(at: partial)
            throw MacomprendoError.modelDownloadFailed("\(model.displayName): checksum mismatch")
        }

        // 5. Atomic move: a half-written file is never visible as a usable model.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        states[id] = .downloaded(destination)
        continuation.yield(1.0)
    }

    // MARK: - Helpers

    private func setState(_ id: String, _ state: ModelState) {
        states[id] = state
    }

    private func model(_ id: String) -> WhisperModel? {
        catalog.first { $0.id == id }
    }

    private func destinationURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    private func partialURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName + ".partial")
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
