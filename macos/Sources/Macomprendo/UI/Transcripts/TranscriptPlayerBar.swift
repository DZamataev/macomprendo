import SwiftUI

/// The player bar under the transcript detail's segment list: transport, seek bar, elapsed and
/// total time, speed, and — for a call — the two side toggles.
///
/// The bar is a thin rendering of `TranscriptPlaybackController`: it holds only the position of
/// an in-progress drag, so the slider follows the pointer while the player seeks once, on
/// release. Shown while `state` is `.loading` (controls disabled) or `.ready`.
struct TranscriptPlayerBar: View {
    @ObservedObject var playback: TranscriptPlaybackController
    let transcript: Transcript

    @State private var dragPosition: TimeInterval?

    var body: some View {
        HStack(spacing: 10) {
            skipButton(.skipBack, by: -TranscriptPlaybackController.skipInterval,
                       help: "Back 15 seconds")
            playPauseButton
            skipButton(.skipForward, by: TranscriptPlaybackController.skipInterval,
                       help: "Forward 15 seconds")
            seekSlider
            timeCaption
            rateMenu
            if transcript.header.sourceKind == .call {
                speakerToggle(.me)
                speakerToggle(.others)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
        .disabled(!isReady)
    }

    // MARK: - Controls

    private func skipButton(_ icon: AppIcon, by seconds: TimeInterval, help: String) -> some View {
        Button {
            Task { await playback.skip(by: seconds) }
        } label: {
            Icon(icon)
        }
        .buttonStyle(.borderless)
        .help(help)
        .fixedSize()
    }

    private var playPauseButton: some View {
        Button {
            playback.togglePlayPause()
        } label: {
            Icon(isPlaying ? .pause : .play, size: 18)
        }
        .buttonStyle(.borderless)
        .help(isPlaying ? "Pause" : "Play")
        .fixedSize()
    }

    private var seekSlider: some View {
        Slider(value: sliderValue, in: 0...max(duration, 0.01)) { editing in
            guard !editing, let target = dragPosition else { return }
            // The bar keeps showing the dropped position until the seek has landed, so the
            // playhead does not flash back to where it was.
            Task {
                await playback.seek(to: target)
                if dragPosition == target { dragPosition = nil }
            }
        }
    }

    private var timeCaption: some View {
        Text("\(PlaybackTimeline.clock(position)) / \(PlaybackTimeline.clock(duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var rateMenu: some View {
        Menu(Self.rateTitle(playback.rate)) {
            ForEach(TranscriptPlaybackController.rates, id: \.self) { rate in
                Button(Self.rateTitle(rate)) { playback.setRate(rate) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A call side's toggle: on = audible. A side whose track did not load is disabled and says
    /// why.
    private func speakerToggle(_ speaker: TranscriptSpeaker) -> some View {
        let missing = !playback.availableSpeakers.contains(speaker)
        return Toggle(speaker.label, isOn: Binding(
            get: { !playback.muted.contains(speaker) },
            set: { audible in
                if audible == playback.muted.contains(speaker) { playback.toggleMuted(speaker) }
            }
        ))
        .toggleStyle(.button)
        .disabled(missing)
        .help(missing ? "This side's track is missing" : "Play this side")
        .fixedSize()
    }

    // MARK: - State

    private var ready: (position: TimeInterval, duration: TimeInterval, isPlaying: Bool)? {
        guard case let .ready(position, duration, isPlaying) = playback.state else { return nil }
        return (position, duration, isPlaying)
    }

    private var position: TimeInterval { ready?.position ?? 0 }
    private var duration: TimeInterval { ready?.duration ?? 0 }
    private var isPlaying: Bool { ready?.isPlaying ?? false }
    private var isReady: Bool { ready != nil }

    private var sliderValue: Binding<TimeInterval> {
        Binding(get: { dragPosition ?? position }, set: { dragPosition = $0 })
    }

    /// `1×` / `1.25×` / `1.5×` / `2×` — whole numbers without a trailing `.0`.
    nonisolated static func rateTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }
}
