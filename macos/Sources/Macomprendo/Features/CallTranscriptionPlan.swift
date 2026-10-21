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
    /// The tracks in order Me, Others; a track with no `startOffset` never produced audio and is
    /// skipped. Each track resumes from the end of its own last stored segment (track-local, so the
    /// file's own offset comes back off), or from 0 without one — live transcription stores both
    /// tracks at once, so no track is done because another has segments (ADR-0020).
    static func steps(manifest: CallRecordingManifest,
                      stored: [TranscriptSegment]) -> [CallTranscriptionStep] {
        [TranscriptSpeaker.me, .others].compactMap { speaker in
            guard let track = manifest.track(speaker), let offset = track.startOffset else {
                return nil
            }
            let lastEnd = stored.filter { $0.speaker == speaker }.map(\.end).max()
            // A stored end before the track's own offset would ask for a negative start; it
            // cannot mean anything but "from the beginning".
            return CallTranscriptionStep(speaker: speaker, file: track.file, offset: offset,
                                         from: max(0, (lastEnd ?? offset) - offset))
        }
    }
}
