import Foundation
import whisper

/// Facts about the linked whisper.cpp build. Plan 2 adds `WhisperCppTranscriber` here.
enum WhisperRuntime {
    /// whisper.cpp's capability string, e.g. "MTL : EMBED_LIBRARY = 1 | CPU : SSE3 = 1 | … " (v1.9.2 output).
    static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }
}

/// The whisper.cpp parameters the Dictation tab offers. Kept apart from `WhisperParams`,
/// which is what those choices resolve to for one call.
struct WhisperOptions: Sendable, Equatable {
    /// `nil` leaves the thread count to the machine's core count.
    var threads: Int?
    /// whisper.cpp's own flag: transcribe non-English speech into English.
    var translate: Bool

    init(threads: Int? = nil, translate: Bool = false) {
        self.threads = threads
        self.translate = translate
    }
}

/// The decisions that go into a `whisper_full_params`, extracted so they can be
/// unit-tested without loading a model.
struct WhisperParams: Sendable, Equatable {
    /// ISO-639-1 code, or the literal `"auto"`. Never nil: `whisper_full_default_params`
    /// defaults to `"en"`, so auto-detection must be requested explicitly.
    var language: String
    var threads: Int
    var noTimestamps: Bool
    var translate: Bool

    static func make(
        language: String?,
        processorCount: Int,
        options: WhisperOptions = WhisperOptions()
    ) -> WhisperParams {
        let resolved = (language?.isEmpty == false) ? language! : "auto"
        return WhisperParams(
            language: resolved,
            threads: threadCount(options.threads, processorCount: processorCount),
            noTimestamps: true,
            translate: options.translate
        )
    }

    /// Automatic leaves two cores for the UI and the audio thread. An explicit count is
    /// clamped at both ends: `Settings` is JSON a user can export, edit and re-import, so a
    /// nonsense value must not reach `whisper_full_params.n_threads`.
    private static func threadCount(_ requested: Int?, processorCount: Int) -> Int {
        guard let requested else { return max(1, processorCount - 2) }
        return min(max(1, requested), max(1, processorCount))
    }
}

/// Joins whisper segments into a transcript. Segments already carry their own
/// leading space (`" Hello"`, `" world."`), so they are concatenated with no
/// separator and trimmed once at the end.
enum WhisperTextAssembler {
    static func join(_ segments: [String]) -> String {
        segments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns a `whisper_context` and frees it exactly once when the last reference goes.
/// Keeping the pointer in a plain final class (rather than directly on the actor)
/// lets `deinit` call `whisper_free` without fighting actor isolation.
private final class WhisperContextBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}

/// Local transcription via whisper.cpp, Metal-accelerated.
///
/// The model is loaded lazily on the first `transcribe` and stays resident, because
/// loading `large-v3-turbo` costs a couple of seconds. Serialisation is free: the
/// type is an actor, and whisper contexts are not safe for concurrent `whisper_full`.
actor WhisperCppTranscriber: TranscriptionProvider {
    /// The user's thread count and translate flag. `nonisolated` and immutable so
    /// `ProviderFactory`'s wiring can be asserted without awaiting the actor.
    nonisolated let options: WhisperOptions

    private let modelURL: URL
    private var contextBox: WhisperContextBox?

    init(modelURL: URL, options: WhisperOptions = WhisperOptions()) {
        self.modelURL = modelURL
        self.options = options
    }

    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        guard sampleRate == 16_000 else {
            // whisper.cpp does no resampling; another rate silently produces garbage.
            throw MacomprendoError.audio(
                "whisper.cpp requires 16 kHz mono audio, got \(sampleRate) Hz"
            )
        }
        guard !pcm.isEmpty else { return "" }

        let context = try loadedContext()
        let settings = WhisperParams.make(
            language: language,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            options: options
        )

        try Task.checkCancellation()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(settings.threads)
        params.no_timestamps = settings.noTimestamps
        params.translate = settings.translate
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false

        // `params.language` borrows the pointer for the duration of whisper_full,
        // so the C string must outlive the call — hence the nested withCString.
        let status = settings.language.withCString { languagePointer -> Int32 in
            params.language = languagePointer
            return pcm.withUnsafeBufferPointer { samples -> Int32 in
                whisper_full(context, params, samples.baseAddress, Int32(samples.count))
            }
        }
        guard status == 0 else {
            throw MacomprendoError.audio("whisper_full failed with status \(status)")
        }

        var segments: [String] = []
        for index in 0..<whisper_full_n_segments(context) {
            guard let text = whisper_full_get_segment_text(context, index) else { continue }
            segments.append(String(cString: text))
        }
        return WhisperTextAssembler.join(segments)
    }

    private func loadedContext() throws -> OpaquePointer {
        if let contextBox { return contextBox.pointer }

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MacomprendoError.modelMissing(modelURL.lastPathComponent)
        }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true          // Metal; explicit so we do not rely on the default

        guard let pointer = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            throw MacomprendoError.modelMissing(modelURL.lastPathComponent)
        }
        Log.providers.info("Loaded whisper model \(self.modelURL.lastPathComponent, privacy: .public)")

        let box = WhisperContextBox(pointer: pointer)
        contextBox = box
        return box.pointer
    }
}
