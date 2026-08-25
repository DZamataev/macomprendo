import ApplicationServices
import Foundation

protocol SelectedTextReading: Sendable {
    /// The current selection, trimmed. Throws `MacomprendoError.noSelection` when there is none.
    func read() async throws -> String
}

protocol AXReading: Sendable {
    /// `kAXSelectedTextAttribute` of the system-wide focused element, or nil when unavailable.
    func focusedSelectedText() -> String?
}

struct SystemAXReader: AXReading {
    func focusedSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        // Safe: the CFTypeID check above proves this is an AXUIElement.
        let element = focusedRef as! AXUIElement
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                            &selectedRef) == .success,
              let text = selectedRef as? String
        else { return nil }
        return text
    }
}

/// Reads the selection through the Accessibility API, falling back to a simulated ⌘C.
/// The fallback snapshots the pasteboard first and always restores it.
struct AXSelectedTextService: SelectedTextReading {
    private let ax: any AXReading
    private let pasteboard: any PasteboardProtocol
    private let keySimulator: any KeySimulating
    private let copyTimeout: TimeInterval
    private let pollInterval: TimeInterval

    init(ax: any AXReading,
         pasteboard: any PasteboardProtocol,
         keySimulator: any KeySimulating,
         copyTimeout: TimeInterval = 0.3,
         pollInterval: TimeInterval = 0.02) {
        self.ax = ax
        self.pasteboard = pasteboard
        self.keySimulator = keySimulator
        self.copyTimeout = copyTimeout
        self.pollInterval = pollInterval
    }

    func read() async throws -> String {
        if let direct = ax.focusedSelectedText() {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return try await readViaCopy()
    }

    private func readViaCopy() async throws -> String {
        let snapshot = pasteboard.snapshot()
        let before = pasteboard.changeCount

        await keySimulator.pressCommand("c")

        var copied: String?
        var waited: TimeInterval = 0
        while waited < copyTimeout {
            if pasteboard.changeCount != before {
                copied = pasteboard.readString()
                break
            }
            try? await Task.sleep(for: .seconds(pollInterval))
            waited += pollInterval
        }

        pasteboard.restore(snapshot)

        let trimmed = (copied ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacomprendoError.noSelection }
        return trimmed
    }
}
