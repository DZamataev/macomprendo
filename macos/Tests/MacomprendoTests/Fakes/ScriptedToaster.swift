import Foundation
@testable import Macomprendo

@MainActor final class ScriptedToaster: Toasting {
    private(set) var messages: [String] = []
    func toast(_ message: String, duration: TimeInterval) { messages.append(message) }
}
