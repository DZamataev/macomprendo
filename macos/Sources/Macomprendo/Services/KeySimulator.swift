import CoreGraphics
import Foundation

protocol KeySimulating: Sendable {
    /// Posts ⌘+`key` (e.g. ⌘V, ⌘C) to the frontmost app.
    func pressCommand(_ key: Character) async
    /// Types `text` verbatim as synthetic key events.
    func type(_ text: String) async
}

struct CGEventKeySimulator: KeySimulating {
    /// Delay between typed chunks so the receiving app keeps up.
    var chunkDelay: TimeInterval = 0.005

    init(chunkDelay: TimeInterval = 0.005) {
        self.chunkDelay = chunkDelay
    }

    static func keyCode(for key: Character) -> CGKeyCode? {
        switch Character(key.lowercased()) {
        case "v": 9      // kVK_ANSI_V
        case "c": 8      // kVK_ANSI_C
        case "a": 0      // kVK_ANSI_A
        case "x": 7      // kVK_ANSI_X
        default: nil
        }
    }

    /// Splits `text` so no chunk exceeds `maxUTF16` UTF-16 units and no character is cut in half.
    static func chunks(of text: String, maxUTF16: Int) -> [String] {
        guard !text.isEmpty, maxUTF16 > 0 else { return [] }
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits + units > maxUTF16, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func pressCommand(_ key: Character) async {
        guard let code = Self.keyCode(for: key),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            Log.ui.error("Could not build ⌘\(String(key), privacy: .public) key event")
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func type(_ text: String) async {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for chunk in Self.chunks(of: text, maxUTF16: 20) {
            var units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: UInt64(max(0, chunkDelay) * 1_000_000_000))
        }
    }
}
