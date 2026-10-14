import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptionLaneTests {
    @Test func aSingleCallRunsAndReturnsItsResult() async throws {
        let base = FakeTranscriptionProvider()
        base.result = .success("hello")
        let lane = TranscriptionLane()
        let provider = LaneTranscriptionProvider(base: base, lane: lane, priority: .background)

        let text = try await provider.transcribe([0.1, 0.2], sampleRate: 16_000, language: "en")

        #expect(text == "hello")
        #expect(base.received == [
            FakeTranscriptionProvider.Call(pcm: [0.1, 0.2], sampleRate: 16_000, language: "en")
        ])
        let waiting = await lane.waiterCount
        #expect(waiting == 0)
    }

    @Test func callsNeverOverlap() async throws {
        let lane = TranscriptionLane()
        let gate = AsyncGate()
        let base = FakeTranscriptionProvider()
        base.gate = gate
        let inFlight = InFlightTranscriptions()
        let provider = LaneTranscriptionProvider(
            base: CountingTranscriptionProvider(base: base, counter: inFlight),
            lane: lane,
            priority: .background
        )

        let first = Task { try await provider.transcribe([0.1], sampleRate: 16_000, language: nil) }
        await waitFor("the first transcription to reach the model") { gate.waiterCount == 1 }
        #expect(inFlight.current == 1)

        let second = Task { try await provider.transcribe([0.2], sampleRate: 16_000, language: nil) }
        await waitUntil("the second transcription to queue behind the first") {
            await lane.waiterCount == 1
        }
        #expect(inFlight.current == 1)

        gate.open()
        let firstText = try await first.value
        let secondText = try await second.value

        #expect(firstText == "hello")
        #expect(secondText == "hello")
        #expect(base.received.map(\.pcm) == [[0.1], [0.2]])
        #expect(inFlight.peak == 1)
    }

    @Test func aWaitingInteractiveCallGoesBeforeAWaitingBackgroundCall() async throws {
        let lane = TranscriptionLane()
        let holderGate = AsyncGate()
        let order = OrderRecorder()

        let holder = Task {
            try await lane.run(.background) {
                order.record("holder")
                await holderGate.wait()
            }
        }
        await waitFor("the holder to take the lane") { order.recorded.contains("holder") }

        let background = Task {
            try await lane.run(.background) { order.record("background") }
        }
        await waitUntil("the background call to queue") { await lane.waiterCount == 1 }

        let interactive = Task {
            try await lane.run(.interactive) { order.record("interactive") }
        }
        await waitUntil("the interactive call to queue") { await lane.waiterCount == 2 }
        #expect(order.recorded == ["holder"])

        holderGate.open()
        try await holder.value
        try await background.value
        try await interactive.value

        #expect(order.recorded == ["holder", "interactive", "background"])
    }

    @Test func aCancelledWaiterThrowsAndDoesNotBlockTheNext() async throws {
        let lane = TranscriptionLane()
        let holderGate = AsyncGate()
        let order = OrderRecorder()

        let holder = Task {
            try await lane.run(.background) {
                order.record("holder")
                await holderGate.wait()
            }
        }
        await waitFor("the holder to take the lane") { order.recorded.contains("holder") }

        let cancelled = Task {
            try await lane.run(.background) { order.record("cancelled") }
        }
        await waitUntil("the cancelled call to queue") { await lane.waiterCount == 1 }

        let next = Task {
            try await lane.run(.background) { order.record("next") }
        }
        await waitUntil("the next call to queue behind it") { await lane.waiterCount == 2 }

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected the cancelled waiter to throw CancellationError.")
        } catch is CancellationError {
            // The waiter left the queue without running its body.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
        #expect(order.recorded == ["holder"])
        let queued = await lane.waiterCount
        #expect(queued == 1)

        holderGate.open()
        try await holder.value
        try await next.value

        #expect(order.recorded == ["holder", "next"])
    }

    @Test func aThrowingBodyReleasesTheLane() async throws {
        let lane = TranscriptionLane()

        do {
            _ = try await lane.run(.background) { () async throws -> String in
                throw MacomprendoError.audio("x")
            }
            Issue.record("Expected the body to throw.")
        } catch let error as MacomprendoError {
            #expect(error == .audio("x"))
        } catch {
            Issue.record("Expected MacomprendoError.audio, got \(error).")
        }

        let value = try await lane.run(.interactive) { "after the failure" }
        #expect(value == "after the failure")
        let waiting = await lane.waiterCount
        #expect(waiting == 0)
    }
}

/// `waitFor` (`Support/Wait.swift`) takes a synchronous condition, so it cannot read actor
/// state such as `TranscriptionLane.waiterCount`; this is its asynchronous counterpart.
private func waitUntil(_ description: String,
                       timeout: Duration = .seconds(5),
                       _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out after \(timeout) waiting for \(description).")
}

/// Counts transcriptions in flight and remembers the peak, so a test can prove the lane
/// never lets two of them run at once.
private final class InFlightTranscriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var peakRunning = 0

    func enter() {
        lock.withLock {
            running += 1
            peakRunning = max(peakRunning, running)
        }
    }

    func exit() { lock.withLock { running -= 1 } }

    var current: Int { lock.withLock { running } }
    var peak: Int { lock.withLock { peakRunning } }
}

/// Counts calls in flight around another provider, so the lane can be exercised through the
/// same `LaneTranscriptionProvider` shape production uses.
private struct CountingTranscriptionProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    let counter: InFlightTranscriptions

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        counter.enter()
        defer { counter.exit() }
        return try await base.transcribe(pcm, sampleRate: sampleRate, language: language)
    }
}

/// Records the order in which lane bodies run.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [String] = []

    func record(_ step: String) { lock.withLock { recordedSteps.append(step) } }

    var recorded: [String] { lock.withLock { recordedSteps } }
}
