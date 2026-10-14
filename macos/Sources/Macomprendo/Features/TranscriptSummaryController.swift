import Combine
import Foundation

/// The summary pane of the Transcripts window.
///
/// `Summarize` runs the LLM configured for the Summarize feature against the open transcript
/// and streams the result into `text`: a single request when the transcript fits in one
/// `TranscriptChunker` part, a map-reduce when it does not — each part summarised on its own,
/// then the part summaries joined and summarised once more.
///
/// One run is in flight at a time. A new `summarize(_:)`, a `cancel()`, or a `show(_:)`
/// supersedes the previous run through the generation counter, and a superseded run writes
/// nothing — not `text`, `error`, `progress`, nor the store. Cancelling or failing leaves the
/// transcript's stored summary in place; a failure is reported through `error`. Transcript and
/// summary text is never logged.
@MainActor
final class TranscriptSummaryController: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var isRunning: Bool = false
    /// "Summarizing part 2 of 3…" while the parts are summarised, `nil` otherwise.
    @Published private(set) var progress: String?
    @Published private(set) var error: String?

    private let store: any TranscriptStoring
    private let llm: @MainActor () throws -> LLMTarget
    private let preset: @MainActor () -> PromptPreset?
    private let language: @MainActor () -> String
    private let chosenLanguage: @MainActor () -> String
    private let partLimit: Int

    private var task: Task<Void, Never>?
    private var generation = 0
    /// The stored summary to put back on screen when a run fails.
    private var previousSummary = ""

    init(store: any TranscriptStoring,
         llm: @escaping @MainActor () throws -> LLMTarget,
         preset: @escaping @MainActor () -> PromptPreset?,
         language: @escaping @MainActor () -> String,
         chosenLanguage: @escaping @MainActor () -> String,
         partLimit: Int = TranscriptChunker.defaultLimit) {
        self.store = store
        self.llm = llm
        self.preset = preset
        self.language = language
        self.chosenLanguage = chosenLanguage
        self.partLimit = partLimit
    }

    /// Shows the open transcript's stored summary (or clears the pane) and supersedes any run.
    func show(_ transcript: Transcript?) {
        supersede()
        error = nil
        text = transcript?.summary ?? ""
    }

    /// Summarises `transcript`, superseding any run already in flight.
    func summarize(_ transcript: Transcript) {
        supersede()
        previousSummary = transcript.summary ?? ""
        text = ""
        error = nil
        isRunning = true
        let generation = self.generation
        task = Task { [weak self] in await self?.run(transcript, generation: generation) }
    }

    /// Stops the in-flight run and puts the transcript's stored summary back on screen.
    func cancel() {
        guard isRunning else { return }
        supersede()
        text = previousSummary
    }

    /// Awaits the in-flight run. Used by tests.
    func drain() async {
        _ = await task?.value
    }

    // MARK: - Run

    /// Cancels the in-flight run and bumps the generation, so nothing the run still writes
    /// reaches `text`, `error`, `progress` or the store.
    private func supersede() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
        progress = nil
    }

    private func run(_ transcript: Transcript, generation: Int) async {
        defer {
            if generation == self.generation {
                isRunning = false
                progress = nil
            }
        }

        guard let preset = self.preset() else {
            fail(FeatureConfigError.noPreset(.summarize), generation: generation)
            return
        }
        let problems = PromptRenderer.validate(preset)
        guard problems.isEmpty else {
            if generation == self.generation {
                text = previousSummary
                error = problems.joined(separator: " ")
            }
            return
        }

        let parts = TranscriptChunker.parts(of: transcript.segments, limit: partLimit)
        guard !parts.isEmpty else {
            text = previousSummary
            return
        }

        let target: LLMTarget
        do {
            target = try llm()
        } catch {
            fail(error, generation: generation)
            return
        }

        if parts.count == 1 {
            await summarizeOne(parts[0], preset: preset, target: target,
                               transcript: transcript, generation: generation)
        } else {
            await summarizeInParts(parts, preset: preset, target: target,
                                   transcript: transcript, generation: generation)
        }
    }

    /// One part: the reply streams straight into `text`.
    private func summarizeOne(_ part: String, preset: PromptPreset, target: LLMTarget,
                              transcript: Transcript, generation: Int) async {
        do {
            guard let summary = try await reply(to: prompt(preset, text: part), on: target,
                                                generation: generation,
                                                onDelta: { self.text = $0 }) else { return }
            text = summary
            try await save(summary, for: transcript, generation: generation)
        } catch {
            fail(error, generation: generation)
        }
    }

    /// Several parts: each is summarised on its own (collected, not streamed into `text`),
    /// then the part summaries are joined by a blank line and summarised once more, streaming
    /// into `text`.
    private func summarizeInParts(_ parts: [String], preset: PromptPreset, target: LLMTarget,
                                  transcript: Transcript, generation: Int) async {
        var summaries: [String] = []
        do {
            for (index, part) in parts.enumerated() {
                guard generation == self.generation else { return }
                progress = "Summarizing part \(index + 1) of \(parts.count)…"
                guard let summary = try await reply(to: prompt(preset, text: part), on: target,
                                                    generation: generation, onDelta: { _ in })
                else { return }
                summaries.append(summary)
            }
            guard generation == self.generation else { return }
            progress = nil

            let combined = summaries.joined(separator: "\n\n")
            guard let summary = try await reply(to: prompt(preset, text: combined), on: target,
                                                generation: generation,
                                                onDelta: { self.text = $0 }) else { return }
            text = summary
            try await save(summary, for: transcript, generation: generation)
        } catch {
            fail(error, generation: generation)
        }
    }

    /// Every request renders the same preset, with no instruction.
    private func prompt(_ preset: PromptPreset, text: String) -> RenderedPrompt {
        PromptRenderer.render(preset, text: text, instruction: nil,
                              language: language(), chosenLanguage: chosenLanguage())
    }

    /// Streams one request to completion. `onDelta` sees the growing reply — a no-op for the
    /// map phase, which must not touch `text`. Returns `nil` when the run was cancelled or
    /// superseded; other failures are thrown to the caller.
    private func reply(to prompt: RenderedPrompt, on target: LLMTarget, generation: Int,
                       onDelta: (String) -> Void) async throws -> String? {
        var reply = ""
        do {
            for try await delta in target.provider.chat(prompt.messages, model: target.model,
                                                        options: ChatOptions()) {
                guard generation == self.generation else { return nil }
                reply += delta
                onDelta(reply)
            }
        } catch is CancellationError {
            return nil
        } catch MacomprendoError.cancelled {
            return nil
        }
        return generation == self.generation ? reply : nil
    }

    private func save(_ summary: String, for transcript: Transcript, generation: Int) async throws {
        guard generation == self.generation else { return }
        try await store.setSummary(summary, for: transcript.id)
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        text = previousSummary
        self.error = ErrorText.describe(error)
    }
}
