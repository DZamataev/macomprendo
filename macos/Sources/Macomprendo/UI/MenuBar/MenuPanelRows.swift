import AppKit
import SwiftUI

/// The panel's one command row: a fixed-width icon column, the label, and an optional trailing
/// shortcut annotation. Hover paints the system's selected-content background with its own
/// selected-content text colour — not a permanent tint — so the same row stays legible in light
/// and dark, with a non-blue accent and with Increase Contrast (spec §6). Secondary text is
/// dimmed, never dropped, so the shortcut does not vanish under the highlight.
struct PanelCommandRow: View {
    let icon: AppIcon
    let title: String
    var shortcut: String?
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(icon, size: 14)
                    .frame(width: 16)
                    .foregroundStyle(foreground)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(foreground)
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(secondaryForeground)
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle(isHovering: isHovering))
        .onHover { hovering in isHovering = isEnabled && hovering }
        .disabled(!isEnabled)
        .helpIfPresent(help)
    }

    private var foreground: Color {
        isHovering ? Color(nsColor: .selectedMenuItemTextColor) : .primary
    }

    private var secondaryForeground: Color {
        isHovering ? Color(nsColor: .selectedMenuItemTextColor).opacity(0.8) : .secondary
    }
}

/// The row's hover fill. A `ButtonStyle` cannot hold the hover state itself, so the row owns
/// it and passes it in.
private struct PanelRowButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering
                          ? Color(nsColor: .selectedContentBackgroundColor)
                          : .clear))
    }
}

/// The small caption above a picker's value (spec §3: caption above value).
struct PanelCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// `.help(nil)` still registers a tooltip on the row; only attach one when there is text,
    /// which is what keeps the enabled rows tooltip-free.
    @ViewBuilder func helpIfPresent(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}
