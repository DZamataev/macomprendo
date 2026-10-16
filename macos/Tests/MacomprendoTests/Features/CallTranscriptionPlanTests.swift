import Foundation
import Testing
@testable import Macomprendo

@Suite struct CallTranscriptionPlanTests {
    private static let folderName = "rec 2026-10-15 16-42-07"

    private static func manifest(me: TimeInterval? = nil,
                                 others: TimeInterval? = nil) -> CallRecordingManifest {
        var manifest = CallRecordingManifest(startedAt: Date(timeIntervalSince1970: 1_000_000),
                                             folderName: folderName)
        if let me { manifest.setStartOffset(me, for: .me) }
        if let others { manifest.setStartOffset(others, for: .others) }
        return manifest
    }

    private static func step(_ speaker: TranscriptSpeaker, offset: TimeInterval,
                             from: TimeInterval) -> CallTranscriptionStep {
        CallTranscriptionStep(speaker: speaker,
                              file: CallRecordingLayout.trackFileName(folderName: folderName,
                                                                      track: speaker),
                              offset: offset, from: from)
    }

    private static func segment(end: TimeInterval,
                                speaker: TranscriptSpeaker) -> TranscriptSegment {
        TranscriptSegment(start: end - 1, end: end, text: "text", speaker: speaker)
    }

    @Test func withNothingStoredBothTracksStartFromZero() {
        let steps = CallTranscriptionPlan.steps(manifest: Self.manifest(me: 0.2, others: 0.5),
                                                stored: [])
        #expect(steps == [Self.step(.me, offset: 0.2, from: 0),
                          Self.step(.others, offset: 0.5, from: 0)])
    }

    @Test func theLastStoredTrackResumesFromItsOwnLastSegment() {
        // Me's last segment ends at 120.0 on the call's clock and its file starts 0.2 in, so
        // its own clock reads 119.8; Others has not begun and runs from 0.
        let steps = CallTranscriptionPlan.steps(
            manifest: Self.manifest(me: 0.2, others: 0.5),
            stored: [Self.segment(end: 120.0, speaker: .me)])
        #expect(steps == [Self.step(.me, offset: 0.2, from: 119.8),
                          Self.step(.others, offset: 0.5, from: 0)])
    }

    @Test func tracksBeforeTheLastStoredOneAreDone() {
        // Others having segments means Me was transcribed — with no speech. Me is not redone.
        let steps = CallTranscriptionPlan.steps(
            manifest: Self.manifest(me: 0.2, others: 0.5),
            stored: [Self.segment(end: 50.0, speaker: .others)])
        #expect(steps == [Self.step(.others, offset: 0.5, from: 49.5)])
    }

    @Test func aTrackWithoutAnOffsetIsSkipped() {
        let onlyMe = CallTranscriptionPlan.steps(manifest: Self.manifest(me: 0.2), stored: [])
        #expect(onlyMe == [Self.step(.me, offset: 0.2, from: 0)])

        let onlyOthers = CallTranscriptionPlan.steps(manifest: Self.manifest(others: 0.5),
                                                     stored: [])
        #expect(onlyOthers == [Self.step(.others, offset: 0.5, from: 0)])
    }

    @Test func theResumePositionIsNeverNegative() {
        // A stored end before the track's own offset would ask for a negative start.
        let steps = CallTranscriptionPlan.steps(manifest: Self.manifest(me: 0.2, others: 0.5),
                                                stored: [Self.segment(end: 0.1, speaker: .me)])
        #expect(steps.first?.from == 0)
    }

    @Test func eachStepCarriesTheFileTheManifestNames() {
        var manifest = Self.manifest(me: 0.2, others: 0.5)
        manifest.tracks[TranscriptSpeaker.me.rawValue] =
            CallRecordingManifest.Track(file: "renamed Me.m4a", startOffset: 0.2)
        let steps = CallTranscriptionPlan.steps(manifest: manifest, stored: [])
        #expect(steps.first?.file == "renamed Me.m4a")
    }
}
