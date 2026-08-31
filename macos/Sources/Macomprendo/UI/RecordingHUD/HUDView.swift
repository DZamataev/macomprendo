import SwiftUI

struct HUDView: View {
    @ObservedObject var controller: HUDController

    var body: some View {
        VStack(spacing: 4) {
            content
            if let caption = Self.captionText(for: controller.state, caption: controller.modelCaption) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
            .frame(width: HUDLayout.size.width, height: HUDLayout.size.height)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .hidden:
            Color.clear
        case .recording(let level, let elapsed):
            VStack(spacing: 8) {
                LevelMeter(level: level)
                HStack(spacing: 6) {
                    Text("Recording")
                    Text(Self.elapsedText(elapsed)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Release to transcribe · Esc cancels")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        case .recordingPrompt(let hint):
            VStack(spacing: 6) {
                Icon(.microphoneFill, size: 20).foregroundStyle(Color.red)
                Text("Recording…").font(.caption)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(12)
        case .transcribing:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        case .speaking(let hint):
            VStack(spacing: 6) {
                Icon(.speak, size: 20).foregroundStyle(Color.accentColor)
                Text("Speaking…").font(.caption)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(12)
        case .success(let message):
            label(message, icon: .success, tint: .accentColor)
        case .error(let message):
            label(message, icon: .warning, tint: .red)
        case .toast(let message):
            label(message, icon: .warning, tint: .secondary)
        }
    }

    private func label(_ message: String, icon: AppIcon, tint: Color) -> some View {
        VStack(spacing: 6) {
            Icon(icon, size: 20).foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(12)
    }

    /// Pure formatting, no actor state — `nonisolated` so it can be called from a
    /// synchronous nonisolated context (e.g. a `swift-testing` test) without an `await`.
    /// `HUDView` conforms to `View`, whose `body` requirement is main-actor-isolated;
    /// without this, the compiler infers the same isolation for every member of the type,
    /// including this one, even though it touches nothing actor-isolated.
    nonisolated static func elapsedText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Which states name the model. `.speaking` deliberately does not: it belongs to
    /// text-to-speech, where a transcription model's name would be actively misleading.
    nonisolated static func captionText(for state: HUDState, caption: String?) -> String? {
        guard let caption, !caption.isEmpty else { return nil }
        switch state {
        case .recording, .recordingPrompt, .transcribing: return caption
        case .hidden, .speaking, .success, .error, .toast: return nil
        }
    }
}
