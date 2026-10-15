import SwiftUI

/// The menu's level readout: ten cells, filled in proportion to the level of the last 100 ms.
/// Pure, so the rows are unit-tested without a controller or a menu.
enum CallLevelMeter {
    static let cellCount = 10

    /// `round(level * 10)` cells of `▮`, the rest `▯`; `level` clamped to 0…1.
    static func text(_ level: Float) -> String {
        let filled = Int((min(max(level, 0), 1) * Float(cellCount)).rounded())
        return String(repeating: "▮", count: filled)
            + String(repeating: "▯", count: cellCount - filled)
    }
}

/// The status item's label. It is deliberately an SF Symbol (invariant 12's one exception):
/// a menu bar status item must be a template image, and the vendored `Icon(.case)` SVGs
/// cannot be one. While a call is being recorded the elapsed time sits next to the symbol,
/// so the menu bar itself is the recording indicator. The label carries the app's name —
/// the symbol alone has none — and the recording state for VoiceOver.
struct CallRecordingMenuLabel: View {
    @ObservedObject var controller: CallRecordingController

    var body: some View {
        if controller.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "record.circle")
                Text(TranscriptExporter.clock(controller.elapsed))
            }
            .accessibilityLabel(
                "Macomprendo — recording call, \(TranscriptExporter.clock(controller.elapsed))")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Macomprendo")
        }
    }
}

/// The call rows of the menu, next to **Transcribe File…**: the state line, the two level
/// meters and the Record Call / Stop Recording item. The hotkey toggles the same action.
struct CallRecordingMenu: View {
    @ObservedObject var controller: CallRecordingController

    var body: some View {
        // A failed start's message stays until the next start replaces it.
        if case let .failed(message) = controller.state {
            Text(message)
        }
        if controller.isRecording {
            Text("Recording call — \(TranscriptExporter.clock(controller.elapsed))")
            Text("Me      " + CallLevelMeter.text(controller.levels.me))
            Text("Others  " + CallLevelMeter.text(controller.levels.others))
            Button {
                controller.toggle()
            } label: {
                // `+` on Text yields ONE Text, not a composite label, so the shortcut survives
                // into the NSMenuItem — see `HotkeyAction.menuSeparator`.
                Text("Stop Recording")
                    + Text(HotkeyAction.menuSeparator
                           + HotkeyAction.recordCall.menuTrailing(
                               shortcut: HotkeyAction.recordCall.currentShortcutText()))
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Record Call") { controller.toggle() }
        }
    }
}
