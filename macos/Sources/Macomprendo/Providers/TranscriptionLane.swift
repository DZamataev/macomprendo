import Foundation

/// Serialises calls into one local speech model, letting an interactive dictation overtake
/// the file segments already waiting behind it.
///
/// A plain actor would not do the job: `run` awaits `body` while still on the actor, so the
/// actor is reentrant and a newcomer could take the lane in that window. The lane therefore
/// tracks ownership with an explicit `busy` flag and hands the lane directly to the next
/// waiter on release — interactive waiters first, then background waiters, first come first
/// served within each queue — so a newcomer cannot slip in between.
actor TranscriptionLane {
    enum Priority: Sendable {
        case interactive
        case background
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var interactiveWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []

    /// How many callers are suspended waiting for the lane. Explicit state tests can poll
    /// instead of guessing with a sleep.
    var waiterCount: Int { interactiveWaiters.count + backgroundWaiters.count }

    /// Runs `body` when the lane is free. Callers waiting with `.interactive` are always
    /// resumed before callers waiting with `.background`; within one priority, first come
    /// first served. A caller cancelled while waiting throws `CancellationError` without
    /// running `body` and without blocking the callers behind it.
    func run<T: Sendable>(_ priority: Priority,
                          _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { release() }
        return try await body()
    }

    private func acquire(_ priority: Priority) async throws {
        if !busy {
            busy = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            // The handler runs outside the actor, so hop back in before touching the queues.
            Task { await self.cancelWaiting(id) }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        switch waiter.priority {
        case .interactive: interactiveWaiters.append(waiter)
        case .background: backgroundWaiters.append(waiter)
        }
    }

    private func release() {
        guard let waiter = nextWaiter() else {
            busy = false
            return
        }
        // The lane goes straight to the next waiter: `busy` stays true, so a newcomer
        // arriving before that waiter resumes cannot take it in between.
        waiter.continuation.resume()
    }

    private func nextWaiter() -> Waiter? {
        if !interactiveWaiters.isEmpty { return interactiveWaiters.removeFirst() }
        if !backgroundWaiters.isEmpty { return backgroundWaiters.removeFirst() }
        return nil
    }

    private func cancelWaiting(_ id: UUID) {
        // Removing the waiter before resuming keeps this exactly-once: a waiter `release`
        // already popped is no longer in a queue, and must not be resumed twice.
        if let index = interactiveWaiters.firstIndex(where: { $0.id == id }) {
            interactiveWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}

/// A provider whose every call goes through a lane at a fixed priority.
struct LaneTranscriptionProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    let lane: TranscriptionLane
    let priority: TranscriptionLane.Priority

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        let base = self.base
        return try await lane.run(priority) {
            try await base.transcribe(pcm, sampleRate: sampleRate, language: language)
        }
    }
}
