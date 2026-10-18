import AppKit
import SwiftUI

/// A pop-up button that takes the full width it is offered. SwiftUI's menu-style `Picker`
/// sizes itself to its current title on macOS and ignores `.frame(maxWidth: .infinity)`, so
/// the three selectors ended at different widths.
struct PanelPopUpButton<Value: Hashable>: NSViewRepresentable {
    struct Item: Equatable {
        let title: String
        let value: Value
    }

    let items: [Item]
    @Binding var selection: Value
    var isEnabled = true

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = items.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            // `addItems(withTitles:)` drops duplicates; one item per entry keeps indices aligned.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if let index = items.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PanelPopUpButton

        init(parent: PanelPopUpButton) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.items.indices.contains(index) else { return }
            parent.selection = parent.items[index].value
        }
    }
}
