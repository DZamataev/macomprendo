import AVFoundation
import Foundation

/// The asset a transcript plays, and which composition track carries each call side.
/// `@unchecked`: the composition is never mutated after `make` returns it, and Xcode 16's SDK
/// does not yet mark `AVAsset`/`AVAssetTrack` `Sendable`, so building it off the main actor and
/// handing it back would not compile otherwise.
struct PlaybackAsset: @unchecked Sendable {
    let asset: AVAsset
    let duration: TimeInterval
    /// Empty for a file; for a call, exactly the sides that could be read.
    let trackIDs: [TranscriptSpeaker: CMPersistentTrackID]
}

/// Builds the `AVAsset` for a `PlaybackSource`: the file itself, or a composition that puts each
/// call track at its `startOffset`, so the mix sounds like the conversation did. Deterministic and
/// file-based, so it is unit-tested with generated audio rather than smoke-tested. Nonisolated:
/// on Xcode 16's SDK `loadTracks` returns non-`Sendable` tracks, which a main-actor caller may not
/// receive.
enum PlaybackComposition {
    static func make(_ source: PlaybackSource) async throws -> PlaybackAsset {
        switch source {
        case .file(let url):
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
                  (try? await asset.load(.isPlayable)) == true,
                  let duration = try? await asset.load(.duration) else {
                throw MacomprendoError.transcriptPlaybackUnavailable("the file has no playable sound")
            }
            return PlaybackAsset(asset: asset, duration: duration.seconds, trackIDs: [:])
        case .call(let tracks):
            let composition = AVMutableComposition()
            var ids: [TranscriptSpeaker: CMPersistentTrackID] = [:]
            var end: TimeInterval = 0
            for track in tracks {
                // One unreadable or unplayable side must not take the other down with it.
                let asset = AVURLAsset(url: track.url)
                guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      (try? await asset.load(.isPlayable)) == true,
                      let range = try? await source.load(.timeRange),
                      let target = composition.addMutableTrack(
                          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                do {
                    try target.insertTimeRange(
                        range, of: source, at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
                } catch {
                    composition.removeTrack(target)
                    continue
                }
                ids[track.speaker] = target.trackID
                end = max(end, track.offset + range.duration.seconds)
            }
            guard !ids.isEmpty else {
                throw MacomprendoError.transcriptPlaybackUnavailable("no track of the recording can be read")
            }
            return PlaybackAsset(asset: composition, duration: end, trackIDs: ids)
        }
    }

    /// Per-side volume for a call (0 for a muted side, 1 otherwise); nil for a file.
    static func audioMix(for asset: PlaybackAsset, muted: Set<TranscriptSpeaker>) -> AVAudioMix? {
        guard !asset.trackIDs.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = asset.trackIDs.map { speaker, id in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            parameters.setVolume(muted.contains(speaker) ? 0 : 1, at: .zero)
            return parameters
        }
        return mix
    }
}
