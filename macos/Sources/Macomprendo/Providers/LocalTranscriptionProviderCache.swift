import Foundation

/// Keeps one local ASR provider resident between dictations. The provider itself owns the
/// native whisper.cpp or sherpa-onnx context; releasing the cache's last reference lets that
/// provider destroy the context in its existing `deinit` path. Cache bookkeeping is
/// main-actor isolated so a Settings change can invalidate it synchronously, before a dictation
/// using the new configuration starts.
@MainActor
final class LocalTranscriptionProviderCache {
    struct Configuration: Equatable, Sendable {
        var source: TranscriptionSource
        var whisper: WhisperOptions
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Entry {
        var configuration: Configuration
        var provider: any TranscriptionProvider
        var idleTimeout: LocalModelIdleTimeout
        var generation: Int
        var activeCalls = 0
        var idleSince: ContinuousClock.Instant? = nil
    }

    private struct Lease: TranscriptionProvider {
        let provider: any TranscriptionProvider
        let cache: LocalTranscriptionProviderCache
        let generation: Int

        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            await cache.beginUsing(generation)
            do {
                let text = try await provider.transcribe(pcm, sampleRate: sampleRate, language: language)
                await cache.finishUsing(generation)
                return text
            } catch {
                await cache.finishUsing(generation)
                throw error
            }
        }
    }

    private let sleep: Sleep
    private let now: () -> ContinuousClock.Instant
    private var desiredConfiguration: Configuration?
    private var desiredIdleTimeout = LocalModelIdleTimeout.tenMinutes
    private var isConfigured = false
    private var entry: Entry?
    private var evictionTask: Task<Void, Never>?
    private var generation = 0

    init(
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sleep = sleep
        self.now = now
    }

    var isEmpty: Bool { entry == nil }
    var cachedConfiguration: Configuration? { entry?.configuration }

    /// Applies the current settings before any asynchronous provider lookup can begin. A lookup
    /// that later completes for an older configuration can still be used by its original caller,
    /// but it cannot replace the provider retained for the current settings.
    func configure(configuration: Configuration?, idleTimeout: LocalModelIdleTimeout) {
        let configurationChanged = !isConfigured || desiredConfiguration != configuration
        let timeoutChanged = !isConfigured || desiredIdleTimeout != idleTimeout
        isConfigured = true
        desiredConfiguration = configuration
        desiredIdleTimeout = idleTimeout

        if configurationChanged || configuration == nil || idleTimeout == .immediately {
            removeAll()
            return
        }
        guard timeoutChanged else { return }

        entry?.idleTimeout = idleTimeout
        if entry?.activeCalls == 0 {
            scheduleEviction()
        }
    }

    /// `candidate` is deliberately constructed before this call. `ProviderFactory` therefore
    /// still validates that the selected model files exist on every dictation, while a cache hit
    /// discards the new, still-unloaded candidate and returns the resident provider.
    func provider(
        _ candidate: any TranscriptionProvider,
        configuration: Configuration
    ) -> any TranscriptionProvider {
        guard isConfigured, desiredConfiguration == configuration else { return candidate }
        guard desiredIdleTimeout != .immediately else { return candidate }

        if entry?.configuration != configuration {
            removeAll()
            generation += 1
            entry = Entry(configuration: configuration,
                          provider: candidate,
                          idleTimeout: desiredIdleTimeout,
                          generation: generation)
        }

        guard let entry else { return candidate }
        return Lease(provider: entry.provider, cache: self, generation: entry.generation)
    }

    /// Clears a failed lookup only if it still belongs to the configuration selected now.
    func removeAll(ifMatching configuration: Configuration) {
        guard desiredConfiguration == configuration else { return }
        removeAll()
    }

    func removeAll() {
        evictionTask?.cancel()
        evictionTask = nil
        entry = nil
    }

    private func beginUsing(_ expectedGeneration: Int) {
        guard entry?.generation == expectedGeneration else { return }
        evictionTask?.cancel()
        evictionTask = nil
        entry?.activeCalls += 1
        entry?.idleSince = nil
    }

    private func finishUsing(_ expectedGeneration: Int) {
        guard var current = entry, current.generation == expectedGeneration else { return }
        current.activeCalls = max(0, current.activeCalls - 1)
        if current.activeCalls == 0 {
            current.idleSince = now()
        }
        entry = current
        if current.activeCalls == 0 {
            scheduleEviction()
        }
    }

    private func scheduleEviction() {
        evictionTask?.cancel()
        evictionTask = nil
        guard let entry,
              entry.activeCalls == 0,
              let idleSince = entry.idleSince,
              let duration = entry.idleTimeout.duration else {
            return
        }
        let deadline = idleSince.advanced(by: duration)
        let current = now()
        guard current < deadline else {
            self.entry = nil
            return
        }
        let expectedGeneration = entry.generation
        let remaining = current.duration(to: deadline)
        let sleep = self.sleep
        evictionTask = Task { [weak self] in
            do {
                try await sleep(remaining)
                try Task.checkCancellation()
                self?.evict(expectedGeneration)
            } catch {
                // Cancellation means the provider became active again or the cache was cleared.
            }
        }
    }

    private func evict(_ expectedGeneration: Int) {
        guard entry?.generation == expectedGeneration, entry?.activeCalls == 0 else { return }
        entry = nil
        evictionTask = nil
    }
}
