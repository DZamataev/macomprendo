import Foundation
@testable import Macomprendo

@MainActor final class ScriptedToaster: Toasting {
    private(set) var messages: [String] = []
    private(set) var states: [HUDState] = []
    private(set) var hideCount = 0

    func toast(_ message: String, duration: TimeInterval) { messages.append(message) }
    func show(_ state: HUDState) { states.append(state) }
    func hide() { hideCount += 1 }
}
