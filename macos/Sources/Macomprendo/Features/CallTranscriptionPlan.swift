import Foundation

/// One stretch of a call's transcription: a track file, where the track sits on the call's
/// clock, and where its decoding should start.
struct CallTranscriptionStep: Equatable, Sendable {
    let speaker: TranscriptSpeaker
    /// The track file's name inside the recording folder.
    let file: String
    /// The track's `startOffset`: what its track-local times are shifted by to land on the
    /// call's clock.
    let offset: TimeInterval
    /// Track-local position to resume decoding from.
    let from: TimeInterval
}

/// What a `Resume` of a call transcript still has to transcribe.
enum CallTranscriptionPlan {
    /// The tracks in order Me, Others; a track with no `startOffset` never produced audio and
    /// is skipped. The last track with stored segments resumes from the end of its last
    /// segment (track-local, so the file's own offset comes back off); any track after it runs
    /// from 0, and the tracks before it are done — Me having no segments there simply means it
    /// was heard to hold no speech.
    static func steps(manifest: CallRecordingManifest,
                      stored: [TranscriptSegment]) -> [CallTranscriptionStep] {
        let tracks = [TranscriptSpeaker.me, .others].compactMap { speaker in
            manifest.track(speaker).flatMap { track in
                track.startOffset.map { (speaker, track.file, $0) }
            }
        }
        let resuming = tracks.lastIndex { speaker, _, _ in
            stored.contains { $0.speaker == speaker }
        }
        return tracks.enumerated().compactMap { index, track in
            let (speaker, file, offset) = track
            if let resuming, index < resuming { return nil }
            // A stored end before the track's own offset would ask for a negative start; it
            // cannot mean anything but "from the beginning".
            let from: TimeInterval = index == resuming
                ? max(0, (stored.last { $0.speaker == speaker }?.end ?? 0) - offset)
                : 0
            return CallTranscriptionStep(speaker: speaker, file: file, offset: offset, from: from)
        }
    }
}
