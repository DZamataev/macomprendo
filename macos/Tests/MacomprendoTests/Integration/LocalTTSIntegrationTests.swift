import Foundation
import Testing
@testable import Macomprendo

@Suite struct LocalTTSIntegrationTests {
    @Test(
        "downloads, extracts, creates, generates and encodes a real Piper model",
        .enabled(if: ProcessInfo.processInfo.environment["MACOMPRENDO_RUN_LOCAL_TTS_SMOKE"] == "1")
    )
    func realPiperRoundTrip() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macomprendo-local-tts-integration", isDirectory: true)
        let manager = LocalModelManager(directory: root, http: URLSessionHTTPClient())
        let modelID = "vits-piper-ru_RU-ruslan-medium"

        for try await _ in manager.download(modelID) {}
        let resolved = try #require(await manager.resolved(modelID))
        let directory = try #require(resolved.directory)
        let generator = SherpaSpeechGenerator()
        let audio = try await generator.generate(
            "Проверка локального синтеза речи.",
            configuration: LocalTTSConfiguration(
                modelID: modelID, engine: resolved.engine, directory: directory,
                speakerID: 0, speed: 1
            )
        )

        #expect(audio.samples.count > 1_000)
        #expect(audio.sampleRate > 0)
        let wav = WAVEncoder.encode(pcm: audio.samples, sampleRate: audio.sampleRate)
        #expect(wav.starts(with: Data("RIFF".utf8)))
        try wav.write(to: root.appendingPathComponent("ruslan-smoke.wav"), options: .atomic)
    }
}
