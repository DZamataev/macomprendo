import Foundation
@testable import Macomprendo

actor FakeDictationAudioEncoder: DictationAudioEncoding {
    struct Request: Sendable, Equatable {
        let pcm: [Float]
        let sampleRate: Int
        let url: URL
    }

    private(set) var requests: [Request] = []

    private var error: (any Error)?
    private var bytesToWrite: Data?
    private var gate: AsyncGate?
    nonisolated let encodeInvoked = AsyncGate()

    func setGate(_ gate: AsyncGate?) {
        self.gate = gate
    }

    func setError(_ error: (any Error)?) {
        self.error = error
    }

    /// Lets a caller assert against a real file without running the codec.
    func setBytesToWrite(_ bytes: Data?) {
        bytesToWrite = bytes
    }

    func encode(_ pcm: [Float], sampleRate: Int, to url: URL) async throws {
        requests.append(Request(pcm: pcm, sampleRate: sampleRate, url: url))
        encodeInvoked.open()
        if let gate { await gate.wait() }
        if let error { throw error }
        if let bytesToWrite {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytesToWrite.write(to: url)
        }
    }
}
