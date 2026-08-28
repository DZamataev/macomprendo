import Foundation
@testable import Macomprendo

@MainActor final class FakeActivationPolicy: ActivationPolicyControlling {
    private(set) var calls: [Bool] = []

    func setDockIconVisible(_ visible: Bool) { calls.append(visible) }
}
