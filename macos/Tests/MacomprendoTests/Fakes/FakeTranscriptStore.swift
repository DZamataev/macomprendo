import Foundation
@testable import Macomprendo

actor FakeTranscriptStore: TranscriptStoring {
    private var nextID: Int64 = 1
    private var transcripts: [Int64: Transcript] = [:]

    var failNextAppend: MacomprendoError?
    /// Armed by a test to make the next read — `headers()` or `transcript(id:)` — fail once.
    var failNextRead: MacomprendoError?
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

    func headers() throws -> [TranscriptHeader] {
        try consumeReadFailure()
        return transcripts.values.map(\.header).sorted { $0.id > $1.id }
    }

    func transcript(id: Int64) throws -> Transcript? {
        try consumeReadFailure()
        return transcripts[id]
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

    func delete(id: Int64) {
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
