import Foundation
@testable import Macomprendo

actor FakeDictationAudioEncoder: DictationAudioEncoding {
    struct Request: Sendable, Equatable {
        let frameCount: Int
        let sampleRate: Int
        let url: URL
    }

    private(set) var requests: [Request] = []

    private var error: (any Error)?
    private var bytesToWrite: Data?

    func setError(_ error: (any Error)?) {
        self.error = error
    }

    /// Lets a caller assert against a real file without running the codec.
    func setBytesToWrite(_ bytes: Data?) {
        bytesToWrite = bytes
    }

    func encode(_ pcm: [Float], sampleRate: Int, to url: URL) async throws {
        requests.append(Request(frameCount: pcm.count, sampleRate: sampleRate, url: url))
        if let error { throw error }
        if let bytesToWrite {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytesToWrite.write(to: url)
        }
    }
}
