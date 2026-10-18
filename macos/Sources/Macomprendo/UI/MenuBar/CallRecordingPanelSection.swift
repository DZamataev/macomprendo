import SwiftUI

/// The panel's call block (spec §3.2): **Record Call** while idle; while a call is being
/// recorded the live state line, the full-width **Stop Recording** button, and then the two
/// capsule level meters — Stop above the meters. Every row has a fixed height: the meters and
/// the clock tick ten times a second, and nothing may move under the pointer (spec §6).
///
/// The controller is observed here and nowhere else in the panel, so a level tick re-renders
/// this subtree only — never the rows around it.
struct CallRecordingPanelSection: View {
    @ObservedObject var controller: CallRecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isRecording {
                recordingGroup
            } else {
                recordButton
            }
            if case let .failed(message) = controller.state {
                startFailure(message)
            }
        }
    }

    private var recordButton: some View {
        Button {
            controller.toggle()
        } label: {
            HStack(spacing: 7) {
                Icon(.record, size: 14)
                Text("Record Call")
                Spacer(minLength: 6)
                // An unbound shortcut is omitted, never drawn as "not set" (spec §3).
                if let annotation = MenuPanelPresentation.shortcutAnnotation(
                    HotkeyAction.recordCall.currentShortcutText()) {
                    Text(annotation)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    private var recordingGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("Recording call")
                Spacer(minLength: 6)
                Text(TranscriptExporter.clock(controller.elapsed))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording call, \(TranscriptExporter.clock(controller.elapsed))")

            Button {
                controller.toggle()
            } label: {
                HStack(spacing: 6) {
                    Icon(.stop, size: 14)
                    Text("Stop Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            meterRow("Me", level: controller.levels.me)
            meterRow("Others", level: controller.levels.others)
        }
    }

    private func meterRow(_ label: String, level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            LevelMeter(level: level)
                .accessibilityLabel("\(label) level")
        }
        .frame(height: 24)
    }

    /// A failed start keeps its recovery text until the next attempt replaces it (spec §3.2).
    private func startFailure(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Icon(.warning, size: 12)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.red)
    }
}
