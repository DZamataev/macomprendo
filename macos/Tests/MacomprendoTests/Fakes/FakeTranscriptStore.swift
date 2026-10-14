import Foundation
@testable import Macomprendo

actor FakeTranscriptStore: TranscriptStoring {
    private var nextID: Int64 = 1
    private var transcripts: [Int64: Transcript] = [:]

    var failNextAppend: MacomprendoError?
    /// Armed by a test to make the next read — `headers()` or `transcript(id:)` — fail once.
    var failNextRead: MacomprendoError?
    /// Armed by a test to hold the next `transcript(id:)` read until the gate opens, then clear
    /// itself so later reads run unblocked. The value is captured first, so the held read
    /// delivers a snapshot taken before whatever the test does while it waits — the window in
    /// which a stale result can land after a newer operation finished. `nil` (the default)
    /// never waits: reads behave exactly as before.
    var readGate: AsyncGate?
    /// Armed by a test to hold the next `transcript(id:)` read *for one id* until the gate opens,
    /// then clear itself so later reads run unblocked. Unlike `readGate` (which holds the next
    /// read whatever its id), this holds one id's read while another id's read runs unblocked —
    /// the deterministic ordering a reload's re-read of one transcript needs while a select of
    /// another is in flight. The value is captured first, as with `readGate`. An id absent from
    /// the map never waits.
    var readGatesByID: [Int64: AsyncGate] = [:]
    /// Armed by a test to hold the next `headers()` read until the gate opens, then clear itself
    /// so later reads run unblocked. The list is captured first, so the held read delivers the
    /// snapshot taken before whatever the test does while it waits — the window in which a stale
    /// list can land after a newer operation finished. `nil` (the default) never waits: list
    /// reads behave exactly as before.
    var headersGate: AsyncGate?
    /// Armed by a test to hold the next `delete(id:)` until the gate opens, then clear itself so
    /// later deletes run unblocked. The row is removed only after the gate opens, so a delete
    /// held here is genuinely in flight — the store has not committed the removal yet. `nil`
    /// (the default) never waits: deletes behave exactly as before.
    var deleteGate: AsyncGate?
    private(set) var createCount = 0

    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) -> Int64 {
        let id = nextID
        nextID += 1
        createCount += 1
        let header = TranscriptHeader(id: id, createdAt: at, sourceKind: sourceKind,
                                      title: title, duration: duration,
                                      status: .inProgress, statusReason: nil)
        transcripts[id] = Transcript(header: header, run: run, sourceBookmark: sourceBookmark,
                                     summary: nil, segments: [])
        return id
    }

    func appendSegment(_ segment: TranscriptSegment, to id: Int64) throws {
        if let error = failNextAppend {
            failNextAppend = nil
            throw error
        }
        guard let transcript = transcripts[id] else {
            throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
        }
        transcripts[id] = Transcript(header: transcript.header, run: transcript.run,
                                     sourceBookmark: transcript.sourceBookmark,
                                     summary: transcript.summary,
                                     segments: transcript.segments + [segment])
    }

    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) throws {
        guard let transcript = transcripts[id] else {
            throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
        }
        let header = transcript.header
        let updated = TranscriptHeader(id: header.id, createdAt: header.createdAt,
                                       sourceKind: header.sourceKind, title: header.title,
                                       duration: header.duration, status: status,
                                       statusReason: status == .incomplete ? reason : nil)
        transcripts[id] = Transcript(header: updated, run: transcript.run,
                                     sourceBookmark: transcript.sourceBookmark,
                                     summary: transcript.summary, segments: transcript.segments)
    }

    func setSummary(_ summary: String?, for id: Int64) throws {
        guard let transcript = transcripts[id] else {
            throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
        }
        transcripts[id] = Transcript(header: transcript.header, run: transcript.run,
                                     sourceBookmark: transcript.sourceBookmark,
                                     summary: summary, segments: transcript.segments)
    }

    func headers() async throws -> [TranscriptHeader] {
        try consumeReadFailure()
        let headers = transcripts.values.map(\.header).sorted { $0.id > $1.id }
        if let gate = headersGate {
            headersGate = nil
            await gate.wait()
        }
        return headers
    }

    func transcript(id: Int64) async throws -> Transcript? {
        try consumeReadFailure()
        let transcript = transcripts[id]
        if let gate = readGatesByID[id] {
            readGatesByID[id] = nil
            await gate.wait()
        }
        if let gate = readGate {
            readGate = nil
            await gate.wait()
        }
        return transcript
    }

    /// Throws and disarms `failNextRead` when a test armed it.
    private func consumeReadFailure() throws {
        if let error = failNextRead {
            failNextRead = nil
            throw error
        }
    }

    func snapshot(_ id: Int64) -> Transcript? {
        transcripts[id]
    }

    func delete(id: Int64) async {
        if let gate = deleteGate {
            deleteGate = nil
            await gate.wait()
        }
        transcripts.removeValue(forKey: id)
    }

    func markAbandonedJobs(reason: String) {
        for (id, transcript) in transcripts where transcript.header.status == .inProgress {
            let header = transcript.header
            let updated = TranscriptHeader(id: header.id, createdAt: header.createdAt,
                                           sourceKind: header.sourceKind, title: header.title,
                                           duration: header.duration, status: .incomplete,
                                           statusReason: reason)
            transcripts[id] = Transcript(header: updated, run: transcript.run,
                                         sourceBookmark: transcript.sourceBookmark,
                                         summary: transcript.summary,
                                         segments: transcript.segments)
        }
    }
}
