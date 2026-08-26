import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct EndpointSpeechServiceTests {
    private struct Rig {
        let service: EndpointSpeechService
        let http: FakeHTTPClient
        let player: FakeAudioPlayer
        let keychain: InMemoryKeychainStore
    }

    /// The endpoint answers with raw audio bytes — a WAV header is enough for the fake player.
    private static let audioResponse = HTTPResponse(status: 200, headers: [:],
                                                    body: Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02]))

    /// The default six-character budget turns "One. Two. Three." into three one-sentence
    /// chunks, which is what makes the queue observable without a 4096-character fixture.
    private func rig(withKey: Bool = true, chunkCharacterLimit: Int = 6) -> Rig {
        let http = FakeHTTPClient()
        http.response = Self.audioResponse
        let player = FakeAudioPlayer()
        let keychain = InMemoryKeychainStore()
        if withKey { try? keychain.set("sk-SECRET", account: SpeechSettings.endpointKeychainAccount) }
        return Rig(service: EndpointSpeechService(http: http,
                                                  keychain: keychain,
                                                  player: player,
                                                  chunkCharacterLimit: chunkCharacterLimit),
                   http: http, player: player, keychain: keychain)
    }

    private func settings(withKey: Bool = true, instructions: String = "") -> SpeechSettings {
        SpeechSettings(source: .endpoint,
                       endpointVoice: "alloy",
                       endpointInstructions: instructions,
                       endpointAPIKeyRef: withKey ? SpeechSettings.endpointKeychainAccount : nil)
    }

    private func bodies(_ http: FakeHTTPClient) -> [[String: Any]] {
        http.requests.compactMap { request -> [String: Any]? in
            guard let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json
        }
    }

    private func inputs(_ http: FakeHTTPClient) -> [String] {
        bodies(http).compactMap { $0["input"] as? String }
    }

    /// Lets the service's task make progress when it is deliberately left mid-queue.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func chunksArePlayedInOrder() async {
        let r = rig()
        r.service.speak("One. Two. Three.", settings: settings())
        await r.service.drain()

        #expect(inputs(r.http) == ["One.", "Two.", "Three."])
        #expect(r.player.played == [Self.audioResponse.body,
                                    Self.audioResponse.body,
                                    Self.audioResponse.body])
        #expect(!r.service.isSpeaking)
    }

    @Test func theNextChunkIsFetchedWhileTheCurrentOnePlays() async {
        let r = rig()
        r.player.finishesImmediately = false
        r.service.speak("One. Two. Three.", settings: settings())
        await settle()

        // Chunk 1 is playing; chunk 2 has already been requested; chunk 3 has not.
        #expect(r.player.played.count == 1)
        #expect(r.http.requests.count == 2)

        r.player.finishCurrent()
        await settle()
        #expect(r.player.played.count == 2)
        #expect(r.http.requests.count == 3)

        r.player.finishCurrent()
        await settle()
        r.player.finishCurrent()
        await r.service.drain()
        #expect(r.player.played.count == 3)
        #expect(r.http.requests.count == 3)
    }

    @Test func isSpeakingStaysTrueUntilTheLastChunkFinishes() async {
        let r = rig()
        r.player.finishesImmediately = false
        var changes = 0
        r.service.onStateChange = { changes += 1 }

        r.service.speak("One. Two.", settings: settings())
        #expect(r.service.isSpeaking)
        await settle()
        #expect(r.service.isSpeaking)

        r.player.finishCurrent()
        await settle()
        #expect(r.service.isSpeaking)

        r.player.finishCurrent()
        await r.service.drain()
        #expect(!r.service.isSpeaking)
        #expect(changes == 2)
    }

    @Test func stopCancelsTheQueueAndStopsThePlayerWithoutAnError() async {
        let r = rig()
        r.player.finishesImmediately = false
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("One. Two. Three.", settings: settings())
        await settle()
        r.service.stop()
        // `stop()` clears the task handle, so `drain()` returns at once; `settle()` gives the
        // superseded task room to unwind and prove it stays silent.
        await r.service.drain()
        await settle()

        #expect(!r.service.isSpeaking)
        #expect(r.player.stopCount >= 1)
        #expect(r.player.played.count == 1)
        #expect(errors.isEmpty)
    }

    @Test func stopCancelsAnInFlightFetchInsteadOfLettingItRunToCompletion() async {
        let r = rig()
        r.http.isGated = true
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings())
        for _ in 0..<50 {
            if !r.http.requests.isEmpty { break }
            await Task.yield()
        }
        #expect(r.http.requests.count == 1)   // the fetch is genuinely in flight, not queued

        r.service.stop()
        // `stop()` clears the task handle, so `drain()` returns at once; `settle()` gives the
        // superseded task room to unwind and prove the fetch was actually cancelled rather
        // than left running to completion (or the 60 s timeout) with its result discarded.
        await r.service.drain()
        await settle()

        #expect(r.http.gateWasCancelled)
        #expect(!r.service.isSpeaking)
        #expect(r.player.played.isEmpty)
        #expect(errors.isEmpty)
    }

    @Test func speakingAgainSupersedesTheRunningRequest() async {
        let r = rig()
        r.player.finishesImmediately = false
        r.service.speak("One. Two. Three.", settings: settings())
        await settle()

        r.player.finishesImmediately = true
        r.service.speak("Fresh.", settings: settings())
        await r.service.drain()

        #expect(inputs(r.http).last == "Fresh.")
        #expect(!r.service.isSpeaking)
    }

    @Test func aMissingAPIKeyIsReportedThroughOnError() async {
        let r = rig(withKey: false)
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("Hello.", settings: settings(withKey: false))
        await r.service.drain()

        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError == .speechKeyMissing)
        #expect(r.http.requests.isEmpty)
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func anHTTPFailureStopsPlaybackAndReportsOnce() async {
        let r = rig()
        r.http.error = MacomprendoError.providerHTTP(status: 401, body: "invalid_api_key")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        r.service.speak("One. Two. Three.", settings: settings())
        await r.service.drain()

        #expect(errors.count == 1)
        #expect(errors.first as? MacomprendoError
                == .providerHTTP(status: 401, body: "invalid_api_key"))
        #expect(r.player.played.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func transportFailuresAreRenamedToTheConfiguredHost() async {
        let r = rig()
        r.http.error = MacomprendoError.providerUnreachable(endpointName: "10.0.0.1")
        var errors: [Error] = []
        r.service.onError = { errors.append($0) }

        var configured = settings()
        configured.endpointBaseURL = URL(string: "https://api.proxyapi.ru/openai")!
        r.service.speak("Hello.", settings: configured)
        await r.service.drain()

        #expect(errors.first as? MacomprendoError
                == .providerUnreachable(endpointName: "api.proxyapi.ru"))
    }

    @Test func styleInstructionsTravelWithEveryRequest() async {
        let r = rig()
        r.service.speak("One. Two.", settings: settings(instructions: "  Read slowly  "))
        await r.service.drain()

        #expect(inputs(r.http) == ["One.", "Two."])
        #expect(bodies(r.http).compactMap { $0["instructions"] as? String }
                == ["Read slowly", "Read slowly"])

        // With no style set, the field is absent rather than empty.
        let plain = rig()
        plain.service.speak("One.", settings: settings())
        await plain.service.drain()
        #expect(bodies(plain.http).count == 1)
        #expect(bodies(plain.http)[0].keys.contains("instructions") == false)
    }

    @Test func blankTextIsNotSpoken() async {
        let r = rig()
        r.service.speak("   \n ", settings: settings())
        await r.service.drain()

        #expect(r.http.requests.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    @Test func theVoiceCatalogHoldsTheBuiltInNames() {
        let r = rig()
        let voices = r.service.voices()
        #expect(voices.map(\.id) == ["alloy", "ash", "ballad", "coral", "echo", "fable",
                                     "nova", "onyx", "sage", "shimmer", "verse"])
        #expect(voices.allSatisfy { $0.language == "endpoint" && $0.quality == "premium" })
        #expect(voices.allSatisfy { $0.name == $0.id })
        #expect(voices.map(\.id).contains(SpeechSettings.defaultEndpointVoice))
    }
}
