import Foundation
import Testing
@testable import Macomprendo

@Suite struct WhisperModelManagerTests {

    // MARK: - Fixtures

    /// sha256("hello")
    private static let helloDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    private static let payload = Data("hello".utf8)
    private static let modelPath = "/ggerganov/whisper.cpp/resolve/main/ggml-test.bin"

    private func makeModel(sha256: String) -> LocalASRModel {
        LocalASRModel(
            id: "test",
            displayName: "Test",
            engine: .whisperCpp,
            languages: nil,
            files: [
                ModelFile(
                    role: .ggml,
                    fileName: "ggml-test.bin",
                    sizeBytes: 5,
                    sha256: sha256,
                    downloadURL: URL(string: "https://huggingface.co\(Self.modelPath)")!
                )
            ],
            brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                              sourceURL: URL(string: "https://example.invalid")!)
        )
    }

    private func makeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macomprendo-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stub that answers the HEAD probe and serves `chunks` for the GET.
    private func makeHTTP(
        total: Int = 5,
        acceptRanges: Bool = true,
        chunks: [Data] = [payload]
    ) -> StubHTTPClient {
        let http = StubHTTPClient()
        var headers = ["Content-Length": "\(total)"]
        if acceptRanges { headers["Accept-Ranges"] = "bytes" }
        http.stub("HEAD", path: Self.modelPath, headers: headers)
        http.stubStream("GET", path: Self.modelPath, chunks: chunks)
        return http
    }

    private func collect(_ stream: AsyncThrowingStream<Double, Error>) async throws -> [Double] {
        var fractions: [Double] = []
        for try await fraction in stream { fractions.append(fraction) }
        return fractions
    }

    // MARK: - sha256

    @Test func sha256MatchesTheKnownDigestOfHello() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sha-\(UUID().uuidString).bin")
        try Self.payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try WhisperModelManager.sha256(of: url) == Self.helloDigest)
    }

    @Test func sha256HandlesFilesLargerThanOneReadBlock() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sha-big-\(UUID().uuidString).bin")
        let big = Data(repeating: 0x41, count: 3 * 1024 * 1024 + 7)   // > 1 MiB block
        try big.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digest = try WhisperModelManager.sha256(of: url)
        #expect(digest.count == 64)
        #expect(digest == digest.lowercased())
    }

    // MARK: - Download happy path

    @Test func downloadWritesTheFileAndReportsCompletion() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: Self.helloDigest)]
        )

        let fractions = try await collect(manager.download("test"))

        let destination = directory.appendingPathComponent("ggml-test.bin")
        #expect(try Data(contentsOf: destination) == Self.payload)
        #expect(fractions.last == 1.0)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".partial"))
    }

    @Test func downloadSendsHeadThenGet() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = makeHTTP()
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: "")])

        _ = try await collect(manager.download("test"))

        let methods = http.requests(forPath: Self.modelPath).map(\.method)
        #expect(methods == ["HEAD", "GET"])
        #expect(http.requests(forPath: Self.modelPath)[1].headers["Range"] == nil)
    }

    @Test func downloadCreatesTheModelsDirectoryIfMissing() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macomprendo-absent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        _ = try await collect(manager.download("test"))

        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ggml-test.bin").path
        ))
    }

    @Test func downloadIsANoOpWhenTheModelIsAlreadyPresent() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.payload.write(to: directory.appendingPathComponent("ggml-test.bin"))
        let http = makeHTTP()
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: "")])

        let fractions = try await collect(manager.download("test"))

        #expect(fractions == [1.0])
        #expect(http.requests.isEmpty)
    }

    // MARK: - Resume

    @Test func resumesFromAPartialFileWithARangeHeader() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // "he" already downloaded; the server will send the remaining "llo".
        try Data("he".utf8).write(to: directory.appendingPathComponent("ggml-test.bin.partial"))
        let http = makeHTTP(chunks: [Data("llo".utf8)])
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        _ = try await collect(manager.download("test"))

        #expect(http.requests(forPath: Self.modelPath)[1].headers["Range"] == "bytes=2-")
        #expect(try Data(contentsOf: directory.appendingPathComponent("ggml-test.bin")) == Self.payload)
    }

    @Test func discardsThePartialFileWhenTheServerDoesNotAcceptRanges() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("XX".utf8).write(to: directory.appendingPathComponent("ggml-test.bin.partial"))
        let http = makeHTTP(acceptRanges: false)
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        _ = try await collect(manager.download("test"))

        #expect(http.requests(forPath: Self.modelPath)[1].headers["Range"] == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ggml-test.bin")) == Self.payload)
    }

    @Test func discardsAPartialFileThatIsAlreadyAtLeastAsLargeAsTheTotal() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("far too many bytes".utf8)
            .write(to: directory.appendingPathComponent("ggml-test.bin.partial"))
        let http = makeHTTP()
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        _ = try await collect(manager.download("test"))

        #expect(http.requests(forPath: Self.modelPath)[1].headers["Range"] == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ggml-test.bin")) == Self.payload)
    }

    // MARK: - Concurrency

    @Test func rejectsASecondConcurrentDownloadOfTheSameModel() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Gate the GET stream after its first chunk, so the first download is
        // guaranteed to still be mid-flight (suspended, `inFlight` populated) when
        // the second concurrent attempt starts, rather than racing on timing.
        let gate = Gate()
        let http = GatedHTTPClient(
            inner: makeHTTP(chunks: [Data("he".utf8), Data("llo".utf8)]), gate: gate
        )
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        var firstIterator = manager.download("test").makeAsyncIterator()
        let firstProgress = try await firstIterator.next()
        #expect(firstProgress != nil)

        await #expect(throws: MacomprendoError.modelDownloadFailed(
            "A download for this model is already in progress."
        )) {
            for try await _ in manager.download("test") {}
        }

        // Let the first download proceed to completion, unaffected by the rejection.
        await gate.open()
        var fractions = [firstProgress!]
        while let value = try await firstIterator.next() {
            fractions.append(value)
        }
        #expect(fractions.last == 1.0)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ggml-test.bin")) == Self.payload)
    }

    @Test func cancellingTheConsumingTaskPreservesThePartialFileAndDoesNotStickAtFailed() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The gate holds back every chunk after the first, so the download is
        // guaranteed to still be mid-flight (partial file has exactly "he" on disk,
        // "llo" not yet delivered) at the moment we cancel.
        let gate = Gate()
        let http = GatedHTTPClient(
            inner: makeHTTP(chunks: [Data("he".utf8), Data("llo".utf8)]), gate: gate
        )
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        let firstChunkReceived = Gate()
        let consumer = Task {
            var iterator = manager.download("test").makeAsyncIterator()
            _ = try await iterator.next()             // "he" chunk reported
            await firstChunkReceived.open()
            _ = try? await iterator.next()             // suspended waiting on the gated "llo" chunk
        }

        await firstChunkReceived.wait()
        consumer.cancel()

        let partial = directory.appendingPathComponent("ggml-test.bin.partial")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: partial) == Data("he".utf8))

        let state = await manager.state(of: "test")
        if case .failed = state {
            Issue.record("expected state(of:) not to stick at .failed after cancellation, got \(state)")
        }

        // The manager's own in-flight bookkeeping clears asynchronously as the
        // cancelled download unwinds, so poll briefly instead of assuming it has
        // already happened by the time `consumer.cancel()` returns.
        var accepted = false
        for _ in 0..<500 {
            var secondIterator = manager.download("test").makeAsyncIterator()
            do {
                let first = try await secondIterator.next()
                accepted = (first != nil)
                break
            } catch let error as MacomprendoError
            where error == .modelDownloadFailed("A download for this model is already in progress.") {
                await Task.yield()
                continue
            }
        }
        #expect(accepted, "a subsequent download call should be accepted, not rejected as already in progress")
    }

    @Test func aFinishedDownloadDoesNotLeaveAStaleInFlightEntryBlockingTheNextOne() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = makeHTTP()
        let manager = WhisperModelManager(directory: directory, http: http, catalog: [makeModel(sha256: Self.helloDigest)])

        _ = try await collect(manager.download("test"))

        // If the first attempt's id were still marked in-flight, this would throw
        // "already in progress" instead of taking the already-downloaded fast path.
        let fractions = try await collect(manager.download("test"))

        #expect(fractions == [1.0])
    }

    // MARK: - Verification failures

    @Test func failsAndCleansUpWhenTheChecksumDoesNotMatch() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(),
            catalog: [makeModel(sha256: String(repeating: "0", count: 64))]
        )

        await #expect(throws: MacomprendoError.modelDownloadFailed("Test: checksum mismatch")) {
            for try await _ in manager.download("test") {}
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ggml-test.bin").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ggml-test.bin.partial").path
        ))
    }

    @Test func acceptsTheFileWhenTheCatalogHashIsEmpty() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        let fractions = try await collect(manager.download("test"))

        #expect(fractions.last == 1.0)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ggml-test.bin")) == Self.payload)
    }

    @Test func failsWhenFewerBytesArriveThanAdvertised() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory,
            http: makeHTTP(total: 5, chunks: [Data("hel".utf8)]),
            catalog: [makeModel(sha256: "")]
        )

        await #expect(throws: MacomprendoError.modelDownloadFailed(
            "Test: expected 5 bytes, received 3"
        )) {
            for try await _ in manager.download("test") {}
        }
    }

    @Test func throwsModelMissingForAnUnknownID() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        await #expect(throws: MacomprendoError.modelMissing("ghost")) {
            for try await _ in manager.download("ghost") {}
        }
    }

    // MARK: - state / localURL / delete

    @Test func stateIsNotDownloadedThenDownloadedAcrossADownload() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        #expect(await manager.state(of: "test") == .notDownloaded)
        #expect(await manager.localURL(for: "test") == nil)

        _ = try await collect(manager.download("test"))

        let destination = directory.appendingPathComponent("ggml-test.bin")
        #expect(await manager.state(of: "test") == .downloaded(destination))
        #expect(await manager.localURL(for: "test") == destination)
    }

    @Test func stateIsFailedAfterAFailedDownload() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory,
            http: makeHTTP(total: 5, chunks: [Data("h".utf8)]),
            catalog: [makeModel(sha256: "")]
        )

        do {
            for try await _ in manager.download("test") {}
            Issue.record("expected the download to fail")
        } catch {
            // expected: only 1 of the advertised 5 bytes arrived
        }

        let state = await manager.state(of: "test")
        guard case .failed = state else {
            Issue.record("expected .failed, got \(state)")
            return
        }
    }

    @Test func stateAndLocalURLAreNilForAnUnknownID() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        #expect(await manager.state(of: "ghost") == .notDownloaded)
        #expect(await manager.localURL(for: "ghost") == nil)
    }

    @Test func deleteRemovesTheModelAndAnyPartialFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.payload.write(to: directory.appendingPathComponent("ggml-test.bin"))
        try Data("xx".utf8).write(to: directory.appendingPathComponent("ggml-test.bin.partial"))
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        try await manager.delete("test")

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-test.bin").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ggml-test.bin.partial").path))
        #expect(await manager.state(of: "test") == .notDownloaded)
    }

    @Test func deleteSucceedsWhenNothingIsOnDisk() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        try await manager.delete("test")   // must not throw
        #expect(await manager.state(of: "test") == .notDownloaded)
    }

    @Test func deleteThrowsModelMissingForAnUnknownID() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        await #expect(throws: MacomprendoError.modelMissing("ghost")) {
            try await manager.delete("ghost")
        }
    }

    @Test func exposesTheModelsDirectory() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = WhisperModelManager(
            directory: directory, http: makeHTTP(), catalog: [makeModel(sha256: "")]
        )

        #expect(manager.modelsDirectory == directory)
    }
}

// MARK: - Concurrency test helpers

/// Lets a test suspend a producer until it explicitly releases it, to force genuine
/// task overlap instead of relying on incidental scheduling order.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Wraps another `HTTPClient` and, on its GET stream only, suspends before
/// forwarding every chunk after the first until `gate` is opened — so a test can
/// guarantee a download is genuinely still mid-flight before it starts a second one.
private final class GatedHTTPClient: HTTPClient, Sendable {
    private let inner: any HTTPClient
    private let gate: Gate

    init(inner: any HTTPClient, gate: Gate) {
        self.inner = inner
        self.gate = gate
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await inner.send(request)
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        guard request.method.uppercased() == "GET" else { return inner.stream(request) }
        let upstream = inner.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var isFirstChunk = true
                    for try await chunk in upstream {
                        if !isFirstChunk { await gate.wait() }
                        isFirstChunk = false
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
