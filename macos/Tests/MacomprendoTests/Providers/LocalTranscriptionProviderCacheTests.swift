import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct LocalTranscriptionProviderCacheTests {
    private func configuration(
        modelID: String = "base",
        threads: Int? = nil,
        translate: Bool = false
    ) -> LocalTranscriptionProviderCache.Configuration {
        LocalTranscriptionProviderCache.Configuration(
            source: .local(modelID: modelID),
            whisper: WhisperOptions(threads: threads, translate: translate)
        )
    }

    private func retained(
        _ candidate: any TranscriptionProvider,
        in cache: LocalTranscriptionProviderCache,
        configuration: LocalTranscriptionProviderCache.Configuration,
        idleTimeout: LocalModelIdleTimeout
    ) -> any TranscriptionProvider {
        cache.configure(configuration: configuration, idleTimeout: idleTimeout)
        return cache.provider(candidate, configuration: configuration)
    }

    private func transcribe(_ provider: any TranscriptionProvider) async throws {
        _ = try await provider.transcribe([0.1], sampleRate: 16_000, language: "en")
    }

    private func spinUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    @Test func reusesTheSameProviderForTheSameConfiguration() async throws {
        let cache = LocalTranscriptionProviderCache()
        let first = FakeTranscriptionProvider()
        let unusedCandidate = FakeTranscriptionProvider()

        try await transcribe(retained(first, in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .tenMinutes))
        try await transcribe(retained(unusedCandidate, in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .tenMinutes))

        #expect(first.received.count == 2)
        #expect(unusedCandidate.received.isEmpty)
    }

    @Test func immediatelyDoesNotRetainAProvider() async throws {
        let cache = LocalTranscriptionProviderCache()
        let first = FakeTranscriptionProvider()
        let second = FakeTranscriptionProvider()

        try await transcribe(retained(first, in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .immediately))
        try await transcribe(retained(second, in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .immediately))

        #expect(first.received.count == 1)
        #expect(second.received.count == 1)
        #expect(cache.isEmpty)
    }

    @Test func changingTheConfigurationReplacesTheRetainedProvider() async throws {
        let cache = LocalTranscriptionProviderCache()
        let first = FakeTranscriptionProvider()
        let second = FakeTranscriptionProvider()

        try await transcribe(retained(first, in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .never))
        try await transcribe(retained(second, in: cache,
                                       configuration: configuration(threads: 6),
                                       idleTimeout: .never))

        #expect(first.received.count == 1)
        #expect(second.received.count == 1)
    }

    @Test func timedEvictionStartsAfterTheLastTranscriptionFinishes() async throws {
        let transcriptionGate = AsyncGate()
        let expiryGate = AsyncGate()
        let base = FakeTranscriptionProvider()
        base.gate = transcriptionGate
        let cache = LocalTranscriptionProviderCache(sleep: { _ in await expiryGate.wait() })
        let retainedProvider = retained(base, in: cache,
                                        configuration: configuration(),
                                        idleTimeout: .fiveMinutes)

        let call = Task { try await self.transcribe(retainedProvider) }
        await spinUntil { base.received.count == 1 }
        #expect(expiryGate.waiterCount == 0)

        transcriptionGate.open()
        try await call.value
        await spinUntil { expiryGate.waiterCount == 1 }
        #expect(expiryGate.waiterCount == 1)
        #expect(cache.isEmpty == false)

        expiryGate.open()
        await spinUntil { cache.isEmpty }
        #expect(cache.isEmpty)
    }

    @Test func timedEvictionWaitsForEveryOverlappingTranscription() async throws {
        let transcriptionGate = AsyncGate()
        let expiryGate = AsyncGate()
        let base = FakeTranscriptionProvider()
        base.gate = transcriptionGate
        let cache = LocalTranscriptionProviderCache(sleep: { _ in await expiryGate.wait() })

        let firstProvider = retained(base, in: cache,
                                     configuration: configuration(),
                                     idleTimeout: .fiveMinutes)
        let firstCall = Task { try await self.transcribe(firstProvider) }
        await spinUntil { transcriptionGate.waiterCount == 1 }

        let secondProvider = retained(FakeTranscriptionProvider(), in: cache,
                                      configuration: configuration(),
                                      idleTimeout: .fiveMinutes)
        let secondCall = Task { try await self.transcribe(secondProvider) }
        await spinUntil { transcriptionGate.waiterCount == 2 }

        transcriptionGate.openOne()
        await spinUntil { transcriptionGate.waiterCount == 1 }
        #expect(expiryGate.waiterCount == 0)
        #expect(cache.isEmpty == false)

        transcriptionGate.open()
        try await firstCall.value
        try await secondCall.value
        await spinUntil { expiryGate.waiterCount == 1 }
        #expect(expiryGate.waiterCount == 1)

        expiryGate.open()
        await spinUntil { cache.isEmpty }
        #expect(cache.isEmpty)
    }

    @Test func reapplyingTheSameSettingsDoesNotRestartTheIdleTimer() async throws {
        let expiryGate = AsyncGate()
        let cache = LocalTranscriptionProviderCache(sleep: { _ in await expiryGate.wait() })
        let selectedConfiguration = configuration()

        try await transcribe(retained(FakeTranscriptionProvider(), in: cache,
                                       configuration: selectedConfiguration,
                                       idleTimeout: .fiveMinutes))
        await spinUntil { expiryGate.waiterCount == 1 }

        cache.configure(configuration: selectedConfiguration, idleTimeout: .fiveMinutes)
        await Task.yield()

        #expect(expiryGate.waiterCount == 1)
        expiryGate.open()
    }

    @Test func neverSchedulesNoEviction() async throws {
        let expiryGate = AsyncGate()
        let cache = LocalTranscriptionProviderCache(sleep: { _ in await expiryGate.wait() })

        try await transcribe(retained(FakeTranscriptionProvider(), in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .never))
        await Task.yield()

        #expect(expiryGate.waiterCount == 0)
        #expect(cache.isEmpty == false)
    }

    @Test func removeAllAndImmediateTimeoutClearTheRetainedProvider() async throws {
        let cache = LocalTranscriptionProviderCache()

        try await transcribe(retained(FakeTranscriptionProvider(), in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .never))
        #expect(cache.isEmpty == false)

        cache.removeAll()
        #expect(cache.isEmpty)

        try await transcribe(retained(FakeTranscriptionProvider(), in: cache,
                                       configuration: configuration(),
                                       idleTimeout: .never))
        cache.configure(configuration: configuration(), idleTimeout: .immediately)
        #expect(cache.isEmpty)
    }
}
