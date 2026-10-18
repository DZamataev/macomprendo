import Foundation
@testable import Macomprendo

/// The menubar panel in a headless test: records the closes the model asks for.
@MainActor
final class FakeStatusItemHost: StatusItemHosting {
    private(set) var closePanelCount = 0
    var isPanelShown = false

    func closePanel() {
        closePanelCount += 1
        isPanelShown = false
    }
}
