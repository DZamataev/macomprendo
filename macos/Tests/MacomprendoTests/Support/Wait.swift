import Foundation
import Testing

/// Polls `condition` until it is true or `timeout` elapses, then records an issue.
@MainActor
func waitFor(_ description: String,
             timeout: Duration = .seconds(2),
             _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(description)")
}
