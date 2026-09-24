import Foundation
import Testing

/// Polls `condition` until it is true or `timeout` elapses, then records an issue.
///
/// The recorded message distinguishes the two ways this can time out, because they call for
/// opposite responses and the old message — a bare "timed out" — could not tell them apart:
///
/// - the condition never became true, which is a real defect in the code under test;
/// - the test runner was starved of CPU, so the polling loop barely ran. A whole-suite run
///   takes about a second on an idle machine; sharing the machine with a compile makes the
///   same run take twenty, and every `waitFor` in it reports a timeout it would not otherwise
///   have hit. Re-run on an idle machine before believing such a failure.
///
/// Starvation is inferred from the poll count: an unstarved loop sleeps 5 ms per iteration, so
/// a 2-second wait polls a few hundred times. A handful of polls across the same wall-clock
/// span means the loop was not being scheduled.
@MainActor
func waitFor(_ description: String,
             timeout: Duration = .seconds(2),
             _ condition: @MainActor () -> Bool) async {
    let pollInterval = Duration.milliseconds(5)
    let start = ContinuousClock.now
    let deadline = start.advanced(by: timeout)
    var polls = 0
    while ContinuousClock.now < deadline {
        if condition() { return }
        polls += 1
        try? await Task.sleep(for: pollInterval)
    }

    let elapsed = start.duration(to: ContinuousClock.now)
    let expectedPolls = elapsed / pollInterval
    let starved = polls * 4 < Int(expectedPolls)
    let diagnosis = starved
        ? "The loop polled \(polls) times where an unstarved run polls about \(Int(expectedPolls)); "
            + "the test runner was starved of CPU. Re-run on an idle machine — do not treat this "
            + "as a defect until it reproduces there."
        : "The loop polled \(polls) times and the condition never held."
    Issue.record("Timed out after \(elapsed) waiting for \(description). \(diagnosis)")
}
