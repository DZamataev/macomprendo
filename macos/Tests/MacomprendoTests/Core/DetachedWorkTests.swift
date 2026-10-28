import Foundation
import Testing
@testable import Macomprendo

@Suite struct DetachedWorkTests {
    @Test func itReturnsTheWorksResult() async throws {
        #expect(try await DetachedWork.value { 41 + 1 } == 42)
    }

    @Test func itRethrowsTheWorksError() async {
        await #expect(throws: MacomprendoError.speakersNotIdentified("x")) {
            try await DetachedWork.value { () throws -> Int in
                throw MacomprendoError.speakersNotIdentified("x")
            }
        }
    }

    /// Work that cannot be interrupted — a native call — must not hold a cancelled caller: quitting
    /// mid-diarization would otherwise wait minutes for it.
    @Test func aCancelledCallerStopsWaitingWhileTheWorkStillRuns() async throws {
        let release = DispatchSemaphore(value: 0)
        let finished = AsyncGate()
        let caller = Task {
            try await DetachedWork.value { () -> Int in
                release.wait()
                finished.open()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        caller.cancel()
        let outcome = await caller.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        // The abandoned work is still blocked here, and finishes on its own once released.
        release.signal()
        await finished.wait()
    }

    @Test func aCallerCancelledBeforeItStartsDoesNotWait() async throws {
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DetachedWork.value { () -> Int in 1 }
        }
        let outcome = await caller.result
        #expect(throws: CancellationError.self) { try outcome.get() }
    }
}
