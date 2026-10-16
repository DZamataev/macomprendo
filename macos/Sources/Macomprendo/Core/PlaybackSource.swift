import Foundation

/// One side of a call as playback places it: the track file and where its first sample sits on
/// the recording's timeline (the manifest's `startOffset`).
struct PlaybackTrack: Equatable, Sendable {
    let speaker: TranscriptSpeaker
    let url: URL
    let offset: TimeInterval
}

/// What a transcript plays: its source file, or the tracks of its call recording.
enum PlaybackSource: Equatable, Sendable {
    case file(URL)
    case call([PlaybackTrack])
}
