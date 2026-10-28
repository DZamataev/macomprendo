import Foundation
import SherpaOnnxC

/// One stretch of one voice, as diarization reports it: seconds from the start of the audio and
/// the clusterer's own label for the voice, which means nothing beyond telling voices apart.
struct SpeakerTurn: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

/// Tells the voices in a stretch of audio apart (spec `2026-10-28-phantom-gate-and-call-speakers`).
protocol SpeakerDiarizing: Sendable {
    /// Whether the models it needs are downloaded — checked before the audio is decoded, so a
    /// call without them costs nothing.
    func isReady() async -> Bool
    /// Every turn, in start order. Throws `modelMissing` when the models are not downloaded.
    /// Cancelling the caller stops the wait, not necessarily the native work behind it.
    func diarize(_ samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn]
}

/// Offline diarization through the vendored sherpa-onnx C API: pyannote segmentation 3.0, the
/// 3D-Speaker ERes2Net base embedding extractor and fast clustering by distance.
struct SherpaSpeakerDiarizer: SpeakerDiarizing {
    /// Distance threshold for clustering voices, the number of voices being unknown. Measured on
    /// a five-person call: 1.0 found 27 voices, 1.2 the five, 1.4 one.
    static let clusteringThreshold: Float = 1.2
    static let minimumTurn: Float = 0.3
    static let mergedGap: Float = 0.5

    /// More threads are slower, not faster: a 51-minute track took 250 s on 2, 207–259 s on 4
    /// and 354 s on 12 of an M4 Max's 16 cores. Four also leave the rest of the machine free.
    static let maximumThreads = 4

    private let models: any ModelManaging
    private let threads: Int

    init(models: any ModelManaging,
         threads: Int = min(maximumThreads,
                            max(1, ProcessInfo.processInfo.activeProcessorCount - 2))) {
        self.models = models
        self.threads = threads
    }

    func isReady() async -> Bool {
        await models.resolved(ModelCatalog.speakerDiarizationID) != nil
    }

    func diarize(_ samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        guard let resolved = await models.resolved(ModelCatalog.speakerDiarizationID),
              let segmentation = resolved.files[.segmentation],
              let embedding = resolved.files[.speakerEmbedding] else {
            throw MacomprendoError.modelMissing(ModelCatalog.speakerDiarizationID)
        }
        guard !samples.isEmpty else { return [] }
        let threads = threads
        // sherpa ignores its progress callback's return value, so the native run cannot be
        // stopped: it runs detached, and a cancelled caller stops waiting for it.
        return try await DetachedWork.value {
            try Self.run(samples, sampleRate: sampleRate, segmentation: segmentation,
                         embedding: embedding, threads: threads)
        }
    }

    private static func run(_ samples: [Float], sampleRate: Int, segmentation: URL,
                            embedding: URL, threads: Int) throws -> [SpeakerTurn] {
        let diarizer: OpaquePointer? = segmentation.path.withCString { segmentationPath in
            embedding.path.withCString { embeddingPath in
                "cpu".withCString { provider in
                    var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                    config.segmentation.pyannote.model = segmentationPath
                    config.segmentation.num_threads = Int32(threads)
                    config.segmentation.provider = provider
                    config.embedding.model = embeddingPath
                    config.embedding.num_threads = Int32(threads)
                    config.embedding.provider = provider
                    config.clustering.num_clusters = -1
                    config.clustering.threshold = clusteringThreshold
                    config.min_duration_on = minimumTurn
                    config.min_duration_off = mergedGap
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }
        guard let diarizer else {
            throw MacomprendoError.speakersNotIdentified("sherpa-onnx rejected the speaker models")
        }
        defer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) }
        guard Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(diarizer)) == sampleRate else {
            throw MacomprendoError.speakersNotIdentified("the speaker models need 16 kHz audio")
        }
        let result = samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, buffer.baseAddress,
                                                       Int32(buffer.count))
        }
        guard let result else {
            throw MacomprendoError.speakersNotIdentified("diarization produced no result")
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0,
              let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }
        return (0..<count).map { index in
            let segment = segments[index]
            return SpeakerTurn(start: TimeInterval(segment.start), end: TimeInterval(segment.end),
                               speaker: Int(segment.speaker))
        }
    }
}
