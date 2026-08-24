import Foundation
@testable import Macomprendo

@MainActor
final class FakeHUDPresenter: HUDPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present(_ controller: HUDController) { presentCount += 1 }
    func dismiss() { dismissCount += 1 }
}
