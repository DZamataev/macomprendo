import Foundation
@testable import Macomprendo

/// A decoder that hands back a scripted file instead of reading one: a fixed duration, a fixed
/// list of chunks, or a fixed error. Records every `open` it was asked for, so a test can prove
/// where decoding was told to start (e.g. a resume offset).
final class ScriptedMediaDecoder: MediaAudioDecoding, @unchecked Sendable {
    /// One `open(_:from:)` call: the file asked for and the second decoding started at.
    struct Request: Equatable {
        var url: URL
        var start: TimeInterval
    }

    private let lock = NSLock()
    private var _duration: TimeInterval
    private var _chunks: [[Float]]
    private var _openError: Error?
    private var _requests: [Request] = []

    init(duration: TimeInterval = 0, chunks: [[Float]] = [], openError: Error? = nil) {
        _duration = duration
        _chunks = chunks
        _openError = openError
    }

    /// Seconds of the whole file, reported on the returned `DecodedAudio`.
    var duration: TimeInterval {
        get { lock.withLock { _duration } }
        set { lock.withLock { _duration = newValue } }
    }

    /// The chunks the stream yields, in order; each element is one buffer of 16 kHz mono samples.
    var chunks: [[Float]] {
        get { lock.withLock { _chunks } }
        set { lock.withLock { _chunks = newValue } }
    }

    /// When set, `open` throws it instead of returning audio.
    var openError: Error? {
        get { lock.withLock { _openError } }
        set { lock.withLock { _openError = newValue } }
    }

    /// Every `open(_:from:)` call, in order.
    var requests: [Request] { lock.withLock { _requests } }

    func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio {
        let (chunks, duration, openError) = lock.withLock {
            _requests.append(Request(url: url, start: start))
            return (_chunks, _duration, _openError)
        }
        if let openError { throw openError }
        let stream = AsyncThrowingStream<[Float], Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return DecodedAudio(duration: duration, startOffset: start, chunks: stream)
    }
}
