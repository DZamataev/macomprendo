import Foundation
import Testing
@testable import Macomprendo

private let autoCallBase = Date(timeIntervalSince1970: 1_800_000_000)
private let autoCallZoom = CallApp(name: "Zoom", bundleIDPrefix: "us.zoom.xos", kind: .app)

/// `AutoCallRecorder`: the poll loop and the two `toggle()` calls, over the real
/// `CallRecordingController` built from the existing call-capture fakes.
@MainActor
@Suite struct AutoCallRecorderTests {
    @MainActor
    private final class Harness {
        let monitor = FakeAudioProcessMonitor()
        let toasts = Box<[String]>([])
        let now = Box(autoCallBase)
        let controller: CallRecordingController
        let recorder: AutoCallRecorder

        init(interval: Duration = .seconds(3_600)) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AutoCallRecorder-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let settings = SettingsHolder()
            controller = CallRecordingController(
                microphone: ScriptedCallCapture(),
                systemAudio: ScriptedCallCapture(),
                folders: FakeCallRecordingFolders(realDirectoryRoot: root),
                makeWriter: { _, _, _ in FakeCallTrackWriter() },
                permissions: FakePermissions(),
                store: FakeTranscriptStore(),
                bookmarks: FakeFileBookmarks(),
                settings: { settings.value },
                tick: .milliseconds(1),
                liveTranscriber: { id in
                    LiveCallTranscriber(transcriptID: id, store: FakeTranscriptStore(),
                                        pipeline: { LongAudioPipeline(
                                            decoder: ScriptedMediaDecoder(),
                                            segmenter: ScriptedSegmenter(),
                                            transcriber: { FakeTranscriptionProvider() },
                                            language: nil) },
                                        settings: .default, glossary: Glossary(),
                                        transcriptsChanged: {})
                },
                transcribe: { _ in })
            recorder = AutoCallRecorder(
                monitor: monitor,
                recorder: controller,
                apps: { [autoCallZoom] in [autoCallZoom] },
                toast: { [toasts] in toasts.value.append($0) },
                ownPID: 99,
                now: { [now] in now.value },
                interval: interval)
        }

        /// One poll at `second` seconds after the base time.
        func tick(at second: TimeInterval) {
            now.value = autoCallBase.addingTimeInterval(second)
            recorder.tick()
        }
    }

    @Test func aScriptedCallRecordsOnceAndStopsWhenItEnds() async throws {
        let harness = try Harness()
        harness.monitor.processes = [AudioProcessActivity(pid: 10, bundleID: "us.zoom.xos",
                                                          isRunningInput: true,
                                                          isRunningOutput: false)]

        for second in 0...2 {
            harness.tick(at: TimeInterval(second))
            #expect(!harness.controller.isRecording)
        }
        harness.tick(at: 3)
        await harness.controller.drain()
        #expect(harness.controller.isRecording)
        #expect(harness.toasts.value == ["Recording call — Zoom"])

        harness.monitor.processes = []
        for second in 4...18 {
            harness.tick(at: TimeInterval(second))
        }
        #expect(harness.controller.isRecording)
        #expect(harness.toasts.value == ["Recording call — Zoom"])

        harness.tick(at: 19)
        await harness.controller.drain()
        #expect(!harness.controller.isRecording)
        #expect(harness.toasts.value == ["Recording call — Zoom",
                                         "Call ended — recording stopped"])
    }

    @Test func nothingIsPolledWhileStopped() async throws {
        let harness = try Harness(interval: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.monitor.snapshotCount == 0)

        harness.recorder.start()
        await waitFor("the loop to poll") { harness.monitor.snapshotCount > 0 }
        harness.recorder.stop()
        let reads = harness.monitor.snapshotCount
        try await Task.sleep(for: .milliseconds(150))

        #expect(!harness.recorder.isRunning)
        #expect(harness.monitor.snapshotCount == reads)
    }
}
