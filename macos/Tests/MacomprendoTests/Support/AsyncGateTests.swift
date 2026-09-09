import Foundation
import Testing

@testable import Macomprendo

@Suite("AsyncGate")
struct AsyncGateTests {
    @Test func aMissedOpenResumesAtTheConfiguredDeadline() async {
        let timeoutObserved = AsyncGate(timeout: .seconds(1), onTimeout: {})
        let gate = AsyncGate(timeout: .milliseconds(5)) {
            timeoutObserved.open()
        }

        await gate.wait()

        #expect(timeoutObserved.opened)
        #expect(gate.waiterCount == 0)
    }
}
