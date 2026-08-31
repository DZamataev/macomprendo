# Transcription Backends Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GigaAM as a second local transcription engine beside whisper.cpp, generalise the model catalog to multi-file models with per-model briefs and benchmarks, and rebuild the Dictation tab as three backend sub-tabs where the active tab is the configured backend.

**Architecture:** sherpa-onnx is vendored as a second prebuilt xcframework (the ADR-0007 pattern, applied again) and exposed through `GigaAMTranscriber`, an actor implementing the existing, unchanged `TranscriptionProvider`. `ModelCatalog` grows from "one model = one ggml file" into `LocalASRModel`, which carries its engine, its file set, its languages and a user-facing brief; `ModelManager` downloads file sets; `ProviderFactory` dispatches on the resolved engine. The UI change is a presentation layer over that data — `TranscriptionSource` itself does not change shape.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, swift-testing, sherpa-onnx 1.13.4 xcframework, whisper.cpp 1.9.2 xcframework, Node ≥ 20 ESM for `scripts/`.

**Spec:** `docs/superpowers/specs/2026-08-31-transcription-backends-catalog-design.md`

## Global Constraints

- macOS 14+, Swift 6 strict concurrency. Providers are `Sendable` structs or actors; controllers are `@MainActor`.
- Layers point downward only: UI → Features → Services/Providers → Core. Never construct a concrete service outside `AppEnvironment`; never construct a provider outside `ProviderFactory`.
- TDD: the failing test comes first. Hardware-bound glue (whisper C calls, sherpa C calls, AVAudioEngine, NSPanel) stays thin and is covered by `docs/SMOKE_TEST.md` instead of unit tests.
- Every OS-facing type sits behind a protocol with a fake in `Tests/MacomprendoTests/Fakes/`.
- Every user-visible failure is a `MacomprendoError` with `errorDescription` and `recoverySuggestion`. **This plan adds no new cases.**
- Never log transcript text at default level. `Log.<category>.debug` with `privacy: .private` only.
- No telemetry and no network calls beyond user-configured endpoints and explicit model downloads.
- `macos/project.yml` is the source of truth for the Xcode project. Edit it, run `npm run gen`, commit the regenerated `.xcodeproj`.
- Icons come from `Icon(.case)`. Never write `Image(systemName:)` in a view.
- UI strings are English. There is no localization infrastructure in this app.
- Commit messages are conventional commits ending with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Verification commands: `npm run test:swift`, `npm run test:scripts`, `swift build --package-path macos`.

---

### Task 1: The catalog data model

Rewrites `ModelCatalog` around `LocalASRModel` and mechanically updates every consumer so the build stays green. No GigaAM entries and no multi-file downloads yet — a whisper model is a one-element file set.

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelCatalog.swift` (whole file)
- Modify: `macos/Sources/Macomprendo/Services/ModelManager.swift` (`WhisperModel` → `LocalASRModel`, `destinationURL`, `partialURL`, `model(_:)`)
- Modify: `macos/Sources/Macomprendo/UI/Settings/ModelsViewModel.swift` (`Row.model` type, `catalog` type, `recomputeDiskUsage`)
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift` (`row.model.sizeBytes` → `totalSizeBytes`)
- Test: `macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ASREngine`, `ModelFileRole`, `ModelFile`, `Benchmark`, `ModelBrief`, `LocalASRModel` (with `id`, `displayName`, `engine`, `languages: [String]?`, `files: [ModelFile]`, `brief`, `totalSizeBytes: Int64`, `file(_ role:) -> ModelFile?`), and `ModelCatalog.all: [LocalASRModel]`, `ModelCatalog.model(id:) -> LocalASRModel?`, `ModelCatalog.all(for:) -> [LocalASRModel]`, `ModelCatalog.defaultID`, `ModelCatalog.lightweightID`.

- [ ] **Step 1: Write the failing test**

Replace the body of `ModelCatalogTests` with tests that describe the new shape. Keep `containsExactlyTheNineOfferedModelsInOrder` unchanged — it must keep passing.

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct ModelCatalogTests {

    @Test func containsExactlyTheNineOfferedModelsInOrder() {
        #expect(ModelCatalog.all.map(\.id) == [
            "tiny", "tiny.en", "base", "base.en",
            "small", "small.en", "medium", "medium.en",
            "large-v3-turbo"
        ])
    }

    @Test func defaultAndLightweightIDsAreInTheCatalog() {
        #expect(ModelCatalog.defaultID == "large-v3-turbo")
        #expect(ModelCatalog.lightweightID == "base")
        #expect(ModelCatalog.model(id: ModelCatalog.defaultID) != nil)
        #expect(ModelCatalog.model(id: ModelCatalog.lightweightID) != nil)
    }

    @Test func everyWhisperEntryIsASingleGGMLFileFromHuggingFace() throws {
        for model in ModelCatalog.all where model.engine == .whisperCpp {
            #expect(model.files.count == 1, "\(model.id) should be one file")
            let file = try #require(model.file(.ggml))
            #expect(file.fileName == "ggml-\(model.id).bin")
            #expect(file.downloadURL == URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model.id).bin"
            )!)
        }
    }

    @Test func totalSizeIsTheSumOfTheFileSet() {
        let model = LocalASRModel(
            id: "x", displayName: "X", engine: .gigaAM, languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "x-model.onnx", sizeBytes: 100,
                          sha256: "", downloadURL: URL(string: "https://example.com/m")!),
                ModelFile(role: .tokens, fileName: "x-tokens.txt", sizeBytes: 23,
                          sha256: "", downloadURL: URL(string: "https://example.com/t")!)
            ],
            brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                              sourceURL: URL(string: "https://example.com")!)
        )
        #expect(model.totalSizeBytes == 123)
        #expect(model.file(.tokens)?.fileName == "x-tokens.txt")
        #expect(model.file(.encoder) == nil)
    }

    @Test func localFileNamesAreUniqueAcrossTheWholeCatalog() {
        let names = ModelCatalog.all.flatMap { $0.files.map(\.fileName) }
        #expect(names.count == Set(names).count, "two catalog entries share a local file name")
    }

    @Test func everyEntryDeclaresAValidFileSetForItsEngine() {
        for model in ModelCatalog.all {
            let roles = Set(model.files.map(\.role))
            switch model.engine {
            case .whisperCpp:
                #expect(roles == [.ggml], "\(model.id) is not a whisper file set")
            case .gigaAM:
                let ctc: Set<ModelFileRole> = [.ctcModel, .tokens]
                let transducer: Set<ModelFileRole> = [.encoder, .decoder, .joiner, .tokens]
                #expect(roles == ctc || roles == transducer, "\(model.id) is not a sherpa file set")
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos --filter ModelCatalogTests`
Expected: FAIL — `cannot find 'LocalASRModel' in scope`, `cannot find 'ModelFile' in scope`.

- [ ] **Step 3: Rewrite `ModelCatalog.swift`**

Keep the one-line-per-entry literal format: `scripts/fetch-model-hashes.mjs` rewrites these lines in place and will be taught the new shape in Task 6.

```swift
import Foundation

/// Which local runtime opens a model.
enum ASREngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM
}

/// The part a file plays in a model. A whisper model is one `.ggml`; a sherpa CTC model is
/// `.ctcModel` + `.tokens`; a sherpa transducer is `.encoder` + `.decoder` + `.joiner` + `.tokens`.
enum ModelFileRole: String, Sendable, CaseIterable {
    case ggml
    case ctcModel
    case encoder
    case decoder
    case joiner
    case tokens
}

/// One file belonging to a model.
struct ModelFile: Sendable, Equatable {
    let role: ModelFileRole
    /// The name this file is stored under in the models directory. Chosen here, NOT derived
    /// from `downloadURL`: several upstream repositories publish unrelated models under the
    /// identical basenames `model.int8.onnx` and `tokens.txt`.
    let fileName: String
    /// Approximate, for pre-download UI only. The authoritative size is the `Content-Length`
    /// that `LocalModelManager` reads with a HEAD request.
    let sizeBytes: Int64
    /// Lowercase hex digest, or `""` when not yet recorded. An empty value makes verification
    /// soft-fail with a logged warning.
    let sha256: String
    let downloadURL: URL
}

/// A published measurement, quoted rather than measured by this app.
struct Benchmark: Sendable, Equatable {
    let language: String
    let dataset: String
    /// e.g. "WER %" — lower is better.
    let metric: String
    let value: Double
    /// Published numbers for other models on the same row, for context.
    let comparedTo: [String: Double]
}

/// What the Dictation tab tells the user about a model.
struct ModelBrief: Sendable, Equatable {
    let summary: String
    let strengths: [String]
    let limitations: [String]
    let benchmarks: [Benchmark]
    /// Where the numbers come from. Rendered as a link so they can be re-checked.
    let sourceURL: URL
}

/// One downloadable local ASR model.
struct LocalASRModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: ASREngine
    /// `nil` means multilingual with no published list (whisper). A non-nil list is the set of
    /// languages the publisher reports ASR quality for.
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    func file(_ role: ModelFileRole) -> ModelFile? { files.first { $0.role == role } }
}

/// The models Macomprendo offers.
///
/// IMPORTANT: the `ModelFile(...)` literals below are rewritten in place by
/// `scripts/fetch-model-hashes.mjs`. Keep each on ONE line and write `sizeBytes` as plain
/// digits with no `_` separators, or the rewrite will fail.
enum ModelCatalog {

    static let defaultID = "large-v3-turbo"
    static let lightweightID = "base"

    static let all: [LocalASRModel] = whisper

    static func model(id: String) -> LocalASRModel? {
        all.first { $0.id == id }
    }

    static func all(for engine: ASREngine) -> [LocalASRModel] {
        all.filter { $0.engine == engine }
    }

    // MARK: - whisper.cpp

    private static let whisperSource = URL(string: "https://github.com/openai/whisper#available-models-and-languages")!

    private static let whisper: [LocalASRModel] = [
        whisperModel("tiny", "Tiny (multilingual)", 77691713, multilingual: true),
        whisperModel("tiny.en", "Tiny (English)", 77704715, multilingual: false),
        whisperModel("base", "Base (multilingual)", 147951465, multilingual: true),
        whisperModel("base.en", "Base (English)", 147964211, multilingual: false),
        whisperModel("small", "Small (multilingual)", 487601967, multilingual: true),
        whisperModel("small.en", "Small (English)", 487614201, multilingual: false),
        whisperModel("medium", "Medium (multilingual)", 1533763059, multilingual: true),
        whisperModel("medium.en", "Medium (English)", 1533774781, multilingual: false),
        whisperModel("large-v3-turbo", "Large v3 Turbo", 1624555275, multilingual: true)
    ]

    private static func whisperModel(
        _ id: String,
        _ displayName: String,
        _ sizeBytes: Int64,
        multilingual: Bool
    ) -> LocalASRModel {
        LocalASRModel(
            id: id,
            displayName: displayName,
            engine: .whisperCpp,
            languages: multilingual ? nil : ["en"],
            files: [
                ModelFile(role: .ggml, fileName: "ggml-\(id).bin", sizeBytes: sizeBytes, sha256: "", downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")!)
            ],
            brief: ModelBrief(
                summary: multilingual
                    ? "OpenAI's Whisper, running locally. Handles 90+ languages and detects the spoken language on its own."
                    : "English-only Whisper. Faster and slightly more accurate than the multilingual build of the same size, and useless for anything else.",
                strengths: multilingual
                    ? ["Broad language coverage", "Automatic language detection", "Punctuation and casing"]
                    : ["Fastest option for English", "Punctuation and casing"],
                limitations: multilingual
                    ? ["Larger models are slow on CPU", "Weaker on Russian than the GigaAM models"]
                    : ["English only — other languages are transcribed as nonsense"],
                benchmarks: [],
                sourceURL: whisperSource
            )
        )
    }
}
```

- [ ] **Step 4: Update the three consumers so the package compiles**

In `ModelManager.swift` change the catalog type and derive paths from the single file:

```swift
    private let catalog: [LocalASRModel]

    init(directory: URL, http: any HTTPClient) {
        self.init(directory: directory, http: http, catalog: ModelCatalog.all)
    }

    init(directory: URL, http: any HTTPClient, catalog: [LocalASRModel]) {
        self.modelsDirectory = directory
        self.http = http
        self.catalog = catalog
    }

    private func model(_ id: String) -> LocalASRModel? {
        catalog.first { $0.id == id }
    }

    /// Task 2 replaces this with a per-file lookup; for now a model is still one file.
    private func onlyFile(of model: LocalASRModel) -> ModelFile {
        // Every catalog entry in this task has exactly one file, and `ModelCatalogTests`
        // enforces the shape, so a violation is a programmer error rather than a user-facing one.
        guard let file = model.files.first else {
            preconditionFailure("catalog entry \(model.id) has no files")
        }
        return file
    }

    private func destinationURL(for model: LocalASRModel) -> URL {
        modelsDirectory.appendingPathComponent(onlyFile(of: model).fileName)
    }

    private func partialURL(for model: LocalASRModel) -> URL {
        modelsDirectory.appendingPathComponent(onlyFile(of: model).fileName + ".partial")
    }
```

Inside `performDownload`, replace `model.downloadURL` with `onlyFile(of: model).downloadURL`, `model.sizeBytes` with `onlyFile(of: model).sizeBytes`, and `model.sha256` with `onlyFile(of: model).sha256`.

In `ModelsViewModel.swift`:

```swift
    struct Row: Identifiable, Equatable {
        let model: LocalASRModel
        var state: ModelState
        var id: String { model.id }
    }

    private let catalog: [LocalASRModel]

    init(models: any ModelManaging, catalog: [LocalASRModel] = ModelCatalog.all) {
```

and in the same file `recomputeDiskUsage` must sum the whole set:

```swift
    private func recomputeDiskUsage() {
        diskUsage = rows.reduce(into: Int64(0)) { total, row in
            if case .downloaded = row.state { total += row.model.totalSizeBytes }
        }
    }
```

In `DictationTab.swift`, change `ModelsViewModel.sizeText(row.model.sizeBytes)` to `ModelsViewModel.sizeText(row.model.totalSizeBytes)`.

- [ ] **Step 5: Run the full suite**

Run: `npm run test:swift`
Expected: PASS. Then `swift build --package-path macos` — expected: no new warnings.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/Services macos/Sources/Macomprendo/UI/Settings macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift
git commit -m "$(cat <<'EOF'
refactor(models): describe catalog entries as engine + file set

LocalASRModel replaces WhisperModel so a model can be more than one file and can
name the runtime that opens it. Whisper entries become one-file sets and keep
their ggml-*.bin names, so models already on disk are still found.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Multi-file downloads and engine-aware resolution

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelManager.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift` (construct `LocalModelManager`)
- Modify: `macos/Sources/Macomprendo/Providers/ProviderFactory.swift` (call site only)
- Modify: `macos/Tests/MacomprendoTests/Fakes/StubModelManager.swift`, `macos/Tests/MacomprendoTests/Fakes/FakeModelManager.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/ModelsViewModelTests.swift` (six `.downloaded(URL(...))` literals)
- Test: `macos/Tests/MacomprendoTests/Services/WhisperModelManagerTests.swift` → renamed `LocalModelManagerTests.swift`

**Interfaces:**
- Consumes: `LocalASRModel`, `ModelFile`, `ModelFileRole`, `ASREngine` from Task 1.
- Produces: `ResolvedLocalModel(engine:files:)` with `files: [ModelFileRole: URL]`; `ModelManaging.resolved(_ id: String) async -> ResolvedLocalModel?`; `ModelState.downloaded` with no associated value; `actor LocalModelManager` (renamed from `WhisperModelManager`).

- [ ] **Step 1: Write the failing tests**

Add to the manager's test file:

```swift
    private func twoFileModel() -> LocalASRModel {
        LocalASRModel(
            id: "two", displayName: "Two", engine: .gigaAM, languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "two-model.onnx", sizeBytes: 8,
                          sha256: "", downloadURL: URL(string: "https://example.com/model.onnx")!),
                ModelFile(role: .tokens, fileName: "two-tokens.txt", sizeBytes: 2,
                          sha256: "", downloadURL: URL(string: "https://example.com/tokens.txt")!)
            ],
            brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                              sourceURL: URL(string: "https://example.com")!)
        )
    }

    @Test func downloadsEveryFileInTheSetAndReportsProgressAcrossTheWholeSet() async throws {
        let directory = try temporaryDirectory()
        let http = StubHTTPClient()
        http.stub("HEAD", path: "/model.onnx", headers: ["Content-Length": "8", "Accept-Ranges": "bytes"])
        http.stubStream("GET", path: "/model.onnx", chunks: [Data("abcdefgh".utf8)])
        http.stub("HEAD", path: "/tokens.txt", headers: ["Content-Length": "2", "Accept-Ranges": "bytes"])
        http.stubStream("GET", path: "/tokens.txt", chunks: [Data("ru".utf8)])
        let manager = LocalModelManager(directory: directory, http: http, catalog: [twoFileModel()])

        var fractions: [Double] = []
        for try await fraction in manager.download("two") { fractions.append(fraction) }

        #expect(fractions.last == 1.0)
        // Progress spans the whole 10-byte set, so finishing the 8-byte file is 0.8, not 1.0.
        #expect(fractions.contains { abs($0 - 0.8) < 0.001 })
        #expect(await manager.state(of: "two") == .downloaded)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("two-model.onnx").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("two-tokens.txt").path))
    }

    @Test func isNotDownloadedUntilEveryFileIsPresent() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abcdefgh".utf8).write(to: directory.appendingPathComponent("two-model.onnx"))
        let manager = LocalModelManager(directory: directory, http: StubHTTPClient(), catalog: [twoFileModel()])

        #expect(await manager.state(of: "two") == .notDownloaded)
        #expect(await manager.resolved("two") == nil)
    }

    @Test func resolvedCarriesTheEngineAndOneURLPerRole() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abcdefgh".utf8).write(to: directory.appendingPathComponent("two-model.onnx"))
        try Data("ru".utf8).write(to: directory.appendingPathComponent("two-tokens.txt"))
        let manager = LocalModelManager(directory: directory, http: StubHTTPClient(), catalog: [twoFileModel()])

        let resolved = try #require(await manager.resolved("two"))
        #expect(resolved.engine == .gigaAM)
        #expect(resolved.files[.ctcModel] == directory.appendingPathComponent("two-model.onnx"))
        #expect(resolved.files[.tokens] == directory.appendingPathComponent("two-tokens.txt"))
    }

    @Test func deleteRemovesEveryFileInTheSet() async throws {
        let directory = try temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abcdefgh".utf8).write(to: directory.appendingPathComponent("two-model.onnx"))
        try Data("ru".utf8).write(to: directory.appendingPathComponent("two-tokens.txt"))
        let manager = LocalModelManager(directory: directory, http: StubHTTPClient(), catalog: [twoFileModel()])

        try await manager.delete("two")

        #expect(await manager.state(of: "two") == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("two-tokens.txt").path))
    }

    @Test func aFailureOnTheSecondFileLeavesTheModelNotDownloaded() async throws {
        let directory = try temporaryDirectory()
        let http = StubHTTPClient()
        http.stub("HEAD", path: "/model.onnx", headers: ["Content-Length": "8", "Accept-Ranges": "bytes"])
        http.stubStream("GET", path: "/model.onnx", chunks: [Data("abcdefgh".utf8)])
        http.stubError("HEAD", path: "/tokens.txt", error: .providerUnreachable(endpointName: "example.com"))
        let manager = LocalModelManager(directory: directory, http: http, catalog: [twoFileModel()])

        await #expect(throws: MacomprendoError.self) {
            for try await _ in manager.download("two") {}
        }
        #expect(await manager.state(of: "two") != .downloaded)
    }
```

Replace every existing `.downloaded(someURL)` expectation in this file with `.downloaded`, and every `manager.localURL(for:)` assertion with the equivalent `manager.resolved(_:)` lookup.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path macos --filter ModelManager`
Expected: FAIL — `cannot find 'LocalModelManager' in scope`.

- [ ] **Step 3: Change the state enum and the protocol**

```swift
/// Where one catalog model stands on this machine.
enum ModelState: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    /// Every file in the model's set is present. Paths come from `ModelManaging.resolved(_:)`
    /// rather than from this case: a model is a file set, so there is no single URL to carry.
    case downloaded
    case failed(String)
}

/// A model whose every file is on disk, with the runtime that opens it.
struct ResolvedLocalModel: Sendable, Equatable {
    let engine: ASREngine
    let files: [ModelFileRole: URL]
}

protocol ModelManaging: AnyObject, Sendable {
    func state(of id: String) async -> ModelState
    /// `nil` when the model is unknown or any file of its set is missing.
    func resolved(_ id: String) async -> ResolvedLocalModel?
    /// Yields the completed fraction (0...1) across the whole file set. Verifies each file's
    /// SHA-256 and moves it into place atomically. Cancelling the consuming task cancels the
    /// download and leaves partial files for a later resume.
    func download(_ id: String) -> AsyncThrowingStream<Double, Error>
    func delete(_ id: String) async throws
    var modelsDirectory: URL { get }
}
```

- [ ] **Step 4: Generalise the manager**

Rename `actor WhisperModelManager` to `actor LocalModelManager` and replace the query, delete and download bodies:

```swift
    func state(of id: String) async -> ModelState {
        if let known = states[id] {
            switch known {
            case .downloading, .failed: return known
            case .notDownloaded, .downloaded: break
            }
        }
        guard let model = model(id) else { return .notDownloaded }
        return isComplete(model) ? .downloaded : .notDownloaded
    }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        guard let model = model(id), isComplete(model) else { return nil }
        var urls: [ModelFileRole: URL] = [:]
        for file in model.files { urls[file.role] = destinationURL(for: file) }
        return ResolvedLocalModel(engine: model.engine, files: urls)
    }

    func delete(_ id: String) async throws {
        guard let model = model(id) else { throw MacomprendoError.modelMissing(id) }
        for file in model.files {
            try? FileManager.default.removeItem(at: destinationURL(for: file))
            try? FileManager.default.removeItem(at: partialURL(for: file))
        }
        states[id] = .notDownloaded
    }

    private func isComplete(_ model: LocalASRModel) -> Bool {
        model.files.allSatisfy {
            FileManager.default.fileExists(atPath: destinationURL(for: $0).path)
        }
    }

    private func destinationURL(for file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.fileName)
    }

    private func partialURL(for file: ModelFile) -> URL {
        modelsDirectory.appendingPathComponent(file.fileName + ".partial")
    }
```

Split `performDownload` in two. The existing per-file logic — HEAD, resume decision, streaming onto `.partial`, the `Task.isCancelled` check, the size check, the SHA-256 check and the atomic move — moves **verbatim** into `downloadOne`, including its long explanatory comments. Only the progress arithmetic is new.

```swift
    private func performDownload(
        _ id: String,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        // Check-and-insert is atomic because this method runs actor-isolated.
        guard inFlight.insert(id).inserted else {
            throw MacomprendoError.modelDownloadFailed(
                "A download for this model is already in progress."
            )
        }
        defer { inFlight.remove(id) }

        guard let model = model(id) else { throw MacomprendoError.modelMissing(id) }

        if isComplete(model) {
            states[id] = .downloaded
            continuation.yield(1.0)
            return
        }

        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        states[id] = .downloading(fraction: 0)

        // Progress spans the whole set so a four-file transducer does not appear to finish
        // four times. Sizes come from the catalog rather than from HEAD, because the HEAD for
        // a later file has not happened yet when the first one starts streaming.
        let setTotal = max(1, model.totalSizeBytes)
        var completedBytes: Int64 = 0
        var lastReported = -1.0

        for file in model.files {
            if FileManager.default.fileExists(atPath: destinationURL(for: file).path) {
                completedBytes += file.sizeBytes
                continue
            }
            try await downloadOne(file) { bytesInThisFile in
                let fraction = min(1.0, Double(completedBytes + bytesInThisFile) / Double(setTotal))
                if fraction - lastReported >= 0.01 || fraction >= 1.0 {
                    lastReported = fraction
                    self.states[id] = .downloading(fraction: fraction)
                    continuation.yield(fraction)
                }
            }
            completedBytes += file.sizeBytes
        }

        states[id] = .downloaded
        continuation.yield(1.0)
    }

    /// Downloads one file of a set. `onProgress` receives the byte count written for THIS
    /// file so the caller can place it inside the set's overall progress.
    private func downloadOne(_ file: ModelFile, onProgress: (Int64) -> Void) async throws {
        // The body of the old performDownload from the HEAD request onward, with:
        //   model.downloadURL          → file.downloadURL
        //   model.sizeBytes            → file.sizeBytes
        //   model.sha256               → file.sha256
        //   model.displayName          → file.fileName   (in the two error messages)
        //   destinationURL(for: model) → destinationURL(for: file)
        //   partialURL(for: model)     → partialURL(for: file)
        //   continuation.yield(...)    → onProgress(received)
        // Keep every existing comment: they document the ignored-Range and cancellation
        // behaviours, which are unchanged by this refactor.
    }
```

- [ ] **Step 5: Update the call sites and both fakes**

In `AppEnvironment`, construct `LocalModelManager`. In `ProviderFactory.transcriber`, read the resolved model — Task 5 adds the engine switch, so for now:

```swift
        case .local(let modelID):
            guard let resolved = await models.resolved(modelID),
                  let modelURL = resolved.files[.ggml] else {
                throw MacomprendoError.modelMissing(modelID)
            }
            return WhisperCppTranscriber(modelURL: modelURL)
```

`StubModelManager` drops `localURL(for:)` and gains scriptable resolution:

```swift
    private var _resolvedFiles: [String: [ModelFileRole: URL]] = [:]
    private var _resolvedEngines: [String: ASREngine] = [:]

    var resolvedFiles: [String: [ModelFileRole: URL]] {
        get { lock.withLock { _resolvedFiles } }
        set { lock.withLock { _resolvedFiles = newValue } }
    }

    var resolvedEngines: [String: ASREngine] {
        get { lock.withLock { _resolvedEngines } }
        set { lock.withLock { _resolvedEngines = newValue } }
    }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        lock.withLock {
            guard let files = _resolvedFiles[id] else { return nil }
            return ResolvedLocalModel(engine: _resolvedEngines[id] ?? .whisperCpp, files: files)
        }
    }
```

Its `download` no longer sets `.downloaded(finalURL)` — it sets `.downloaded`. `FakeModelManager` gains the same method, mapping its existing `localURLs` entry to `[.ggml: url]` with a settable engine defaulting to `.whisperCpp`.

`ModelsViewModelTests` asserts on `.downloaded(URL(fileURLWithPath: "/tmp/ggml-base.bin"))` in six places, and `DictationTab.stateCaption(for:)` takes a `ModelState`; both stop compiling. Replace every such literal with plain `.downloaded`. While there, add the multi-file case the spec calls for:

```swift
    @Test func diskUsageSumsTheWholeFileSetOfEveryDownloadedModel() async {
        let manager = StubModelManager()
        manager.states = ["gigaam-v3-e2e-rnnt": .downloaded]
        let viewModel = ModelsViewModel(models: manager, catalog: ModelCatalog.all)

        await viewModel.refresh()

        let expected = ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")!.totalSizeBytes
        #expect(viewModel.diskUsage == expected)
    }
```

- [ ] **Step 6: Run the suite, rename the test file, run again**

```bash
npm run test:swift
git mv macos/Tests/MacomprendoTests/Services/WhisperModelManagerTests.swift macos/Tests/MacomprendoTests/Services/LocalModelManagerTests.swift
```

Rename the suite type to `LocalModelManagerTests`, then `npm run test:swift` again. Expected: PASS both times.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo macos/Tests/MacomprendoTests
git commit -m "$(cat <<'EOF'
feat(models): download models as file sets and resolve them with their engine

A model is complete only when every file of its set is on disk, progress is
reported across the whole set, and resolution hands callers one URL per role plus
the engine that opens them. ModelState.downloaded loses its single-URL payload.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Vendor the sherpa-onnx xcframework

**Files:**
- Create: `macos/Packages/SherpaOnnxBinary/Package.swift`
- Create: `macos/Sources/Macomprendo/Providers/SherpaRuntime.swift`
- Modify: `macos/Package.swift`, `macos/project.yml`
- Test: `macos/Tests/MacomprendoTests/Providers/SherpaRuntimeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `SherpaOnnx` product (module `SherpaOnnxC`), and `SherpaRuntime.version() -> String`, `SherpaRuntime.onnxruntimeVersion() -> String`.

- [ ] **Step 1: Write the failing test**

Mirrors `WhisperRuntimeTests`: proves the binary is linked and callable without loading a model. The assertions read real strings out of the linked library, so a broken link fails the test rather than passing it.

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SherpaRuntimeTests {

    @Test func reportsTheLinkedSherpaVersion() {
        let version = SherpaRuntime.version()
        #expect(!version.isEmpty)
        #expect(version.hasPrefix("1.13"), "linked sherpa-onnx is \(version), expected the 1.13 series")
    }

    @Test func reportsTheStaticallyLinkedOnnxruntimeVersion() {
        // onnxruntime is linked into this xcframework variant rather than shipped beside it;
        // a non-empty answer here is what proves that.
        #expect(!SherpaRuntime.onnxruntimeVersion().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos --filter SherpaRuntimeTests`
Expected: FAIL — `cannot find 'SherpaRuntime' in scope`.

- [ ] **Step 3: Add the binary package**

Create `macos/Packages/SherpaOnnxBinary/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// sherpa-onnx publishes prebuilt xcframeworks with every release. The
// `-shared-onnxruntime-static` variant is chosen deliberately: its SherpaOnnxC.framework is a
// universal (arm64 + x86_64) dynamic framework whose only dylib dependencies are Foundation,
// libSystem, libc++ and CoreFoundation — onnxruntime is linked in statically, so there is no
// second dylib to ship, sign or discover. See ADR-0009.
let package = Package(
    name: "SherpaOnnxBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SherpaOnnx", targets: ["sherpa-onnx"])
    ],
    targets: [
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.4-macos-shared-onnxruntime-static.xcframework.zip",
            checksum: "ef7daa86a1e5f5dcb0ccf53e4e475c3ae24414652c9ae9c3912a82140c86fb1a"
        )
    ]
)
```

`xcframework` is a rolling tag upstream. The checksum pins the content, so a replaced asset makes SwiftPM fail loudly at resolve time instead of silently building against different bytes. If that happens: download the asset, run `swift package compute-checksum <file>`, and record the new value here and in ADR-0009.

In `macos/Package.swift` add `.package(path: "Packages/SherpaOnnxBinary")` to `dependencies`, and `.product(name: "SherpaOnnx", package: "SherpaOnnxBinary")` to the executable target's dependencies.

In `macos/project.yml` add under `packages:`

```yaml
  SherpaOnnxBinary:
    path: Packages/SherpaOnnxBinary
```

and under the `Macomprendo` target's `dependencies:`

```yaml
      - package: SherpaOnnxBinary
        product: SherpaOnnx
```

- [ ] **Step 4: Write the runtime shim**

```swift
import Foundation
import SherpaOnnxC

/// Facts about the linked sherpa-onnx build, mirroring `WhisperRuntime`.
enum SherpaRuntime {
    /// e.g. "1.13.4".
    static func version() -> String {
        String(cString: SherpaOnnxGetVersionStr())
    }

    /// The onnxruntime linked *into* this xcframework variant, not a separate dylib.
    static func onnxruntimeVersion() -> String {
        String(cString: SherpaOnnxGetOnnxruntimeVersionStr())
    }
}
```

- [ ] **Step 5: Regenerate the Xcode project and run everything**

```bash
npm run gen
npm run test:swift
swift build --package-path macos
npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj
```

Expected: tests PASS, build has no new warnings, and the second `npm run gen` leaves the project unchanged.

- [ ] **Step 6: Commit**

```bash
git add macos/Packages/SherpaOnnxBinary macos/Package.swift macos/project.yml macos/Macomprendo.xcodeproj macos/Sources/Macomprendo/Providers/SherpaRuntime.swift macos/Tests/MacomprendoTests/Providers/SherpaRuntimeTests.swift
git commit -m "$(cat <<'EOF'
build(deps): vendor the sherpa-onnx macOS xcframework

Second application of the ADR-0007 pattern. The shared-onnxruntime-static variant
links onnxruntime in, so the app gains one self-contained dynamic framework and no
extra dylib to sign.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `GigaAMTranscriber`

**Files:**
- Create: `macos/Sources/Macomprendo/Providers/GigaAMTranscriber.swift`
- Test: `macos/Tests/MacomprendoTests/Providers/GigaAMTranscriberTests.swift`

**Interfaces:**
- Consumes: `ModelFileRole` (Task 1), `SherpaOnnxC` (Task 3).
- Produces: `actor GigaAMTranscriber: TranscriptionProvider` with `init(files: [ModelFileRole: URL]) throws`, and the pure `GigaAMConfigPlan` with `make(from:) -> GigaAMConfigPlan?`, cases `.ctc(model:tokens:)` and `.transducer(encoder:decoder:joiner:tokens:)`, plus `identifyingFile: URL` and `requiredFiles: [URL]`.

The C interop is thin glue covered by `SMOKE_TEST.md` (Task 11). What is unit-tested here is the pure mapping from a file set to a sherpa config, and the input guards.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct GigaAMTranscriberTests {

    private let model = URL(fileURLWithPath: "/models/m.onnx")
    private let tokens = URL(fileURLWithPath: "/models/t.txt")
    private let encoder = URL(fileURLWithPath: "/models/e.onnx")
    private let decoder = URL(fileURLWithPath: "/models/d.onnx")
    private let joiner = URL(fileURLWithPath: "/models/j.onnx")

    @Test func aCTCFileSetPlansACTCConfig() {
        #expect(GigaAMConfigPlan.make(from: [.ctcModel: model, .tokens: tokens])
                == .ctc(model: model, tokens: tokens))
    }

    @Test func aTransducerFileSetPlansATransducerConfig() {
        let plan = GigaAMConfigPlan.make(from: [
            .encoder: encoder, .decoder: decoder, .joiner: joiner, .tokens: tokens
        ])
        #expect(plan == .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens))
    }

    @Test func anIncompleteFileSetPlansNothing() {
        #expect(GigaAMConfigPlan.make(from: [.ctcModel: model]) == nil)
        #expect(GigaAMConfigPlan.make(from: [.encoder: encoder, .tokens: tokens]) == nil)
        #expect(GigaAMConfigPlan.make(from: [:]) == nil)
    }

    @Test func aGGMLFileSetIsNotAGigaAMModel() {
        #expect(GigaAMConfigPlan.make(from: [.ggml: model]) == nil)
    }

    @Test func tokensComeLastInTheRequiredFiles() {
        // The C bridging relies on this order: tokens is always the final pointer.
        let ctc = GigaAMConfigPlan.ctc(model: model, tokens: tokens)
        #expect(ctc.requiredFiles == [model, tokens])
        let rnnt = GigaAMConfigPlan.transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        #expect(rnnt.requiredFiles == [encoder, decoder, joiner, tokens])
    }

    @Test func constructionRejectsAFileSetItCannotPlan() {
        #expect(throws: MacomprendoError.self) {
            _ = try GigaAMTranscriber(files: [.ctcModel: model])
        }
    }

    @Test func rejectsAudioThatIsNotSixteenKilohertz() async throws {
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.self) {
            _ = try await transcriber.transcribe([0.1, 0.2], sampleRate: 44_100, language: nil)
        }
    }

    @Test func emptyAudioTranscribesToEmptyTextWithoutLoadingTheModel() async throws {
        // Nothing exists at the fake path, so reaching the loader would throw modelMissing.
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        #expect(try await transcriber.transcribe([], sampleRate: 16_000, language: nil) == "")
    }

    @Test func reportsTheMissingFileWhenTheModelIsNotOnDisk() async throws {
        let transcriber = try GigaAMTranscriber(files: [.ctcModel: model, .tokens: tokens])
        await #expect(throws: MacomprendoError.modelMissing("m.onnx")) {
            _ = try await transcriber.transcribe([0.1], sampleRate: 16_000, language: nil)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path macos --filter GigaAMTranscriberTests`
Expected: FAIL — `cannot find 'GigaAMConfigPlan' in scope`.

- [ ] **Step 3: Implement the pure plan and the actor**

```swift
import Foundation
import SherpaOnnxC

/// Which sherpa-onnx offline model config a resolved file set maps onto. Pure, so the
/// mapping is unit-tested without the C API or the filesystem.
enum GigaAMConfigPlan: Sendable, Equatable {
    case ctc(model: URL, tokens: URL)
    case transducer(encoder: URL, decoder: URL, joiner: URL, tokens: URL)

    static func make(from files: [ModelFileRole: URL]) -> GigaAMConfigPlan? {
        guard let tokens = files[.tokens] else { return nil }
        if let model = files[.ctcModel] {
            return .ctc(model: model, tokens: tokens)
        }
        if let encoder = files[.encoder], let decoder = files[.decoder], let joiner = files[.joiner] {
            return .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        }
        return nil
    }

    /// The file whose name identifies this model in error messages.
    var identifyingFile: URL {
        switch self {
        case .ctc(let model, _): model
        case .transducer(let encoder, _, _, _): encoder
        }
    }

    /// Every file the recognizer needs. **Tokens is always last** — the C bridging below
    /// depends on that order.
    var requiredFiles: [URL] {
        switch self {
        case .ctc(let model, let tokens): [model, tokens]
        case .transducer(let e, let d, let j, let t): [e, d, j, t]
        }
    }
}

/// Owns a sherpa-onnx offline recognizer and frees it exactly once when the last reference
/// goes. A plain final class, as `WhisperContextBox` is, so `deinit` can call the C destructor
/// without fighting actor isolation.
private final class SherpaRecognizerBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(pointer)
    }
}

/// Local transcription through sherpa-onnx: Russian for the v3 entries, and Russian, English,
/// Kazakh, Kyrgyz and Uzbek for the multilingual ones.
///
/// The recognizer is created lazily on the first `transcribe` and stays resident, because
/// loading a 225 MB ONNX graph costs a couple of seconds. Serialisation is free: the type is
/// an actor, and a sherpa recognizer is not safe for concurrent decoding.
actor GigaAMTranscriber: TranscriptionProvider {
    private let plan: GigaAMConfigPlan
    private var recognizerBox: SherpaRecognizerBox?

    init(files: [ModelFileRole: URL]) throws {
        guard let plan = GigaAMConfigPlan.make(from: files) else {
            throw MacomprendoError.modelMissing("GigaAM model files")
        }
        self.plan = plan
    }

    /// GigaAM models take no language parameter: the v3 entries are Russian-only and the
    /// multilingual entries decode character-wise across their languages with no hint. The
    /// argument is accepted and ignored rather than rejected — failing a dictation over a
    /// setting the UI does not offer would be worse than simply transcribing.
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        guard sampleRate == 16_000 else {
            // sherpa-onnx does no resampling; another rate silently produces garbage.
            throw MacomprendoError.audio("GigaAM requires 16 kHz mono audio, got \(sampleRate) Hz")
        }
        guard !pcm.isEmpty else { return "" }

        let recognizer = try loadedRecognizer()
        try Task.checkCancellation()

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw MacomprendoError.audio("sherpa-onnx could not create a decoding stream")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        pcm.withUnsafeBufferPointer { samples in
            SherpaOnnxAcceptWaveformOffline(
                stream, Int32(sampleRate), samples.baseAddress, Int32(samples.count)
            )
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw MacomprendoError.audio("sherpa-onnx returned no result")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedRecognizer() throws -> OpaquePointer {
        if let recognizerBox { return recognizerBox.pointer }

        for file in plan.requiredFiles where !FileManager.default.fileExists(atPath: file.path) {
            throw MacomprendoError.modelMissing(file.lastPathComponent)
        }

        let pointer = try makeRecognizer()
        Log.providers.info(
            "Loaded GigaAM model \(self.plan.identifyingFile.lastPathComponent, privacy: .public)"
        )

        let box = SherpaRecognizerBox(pointer: pointer)
        recognizerBox = box
        return box.pointer
    }

    /// Fills a zero-initialised config and hands it to sherpa. The C struct borrows every path
    /// pointer for the duration of the call, so each `withCString` scope must still be open
    /// when `SherpaOnnxCreateOfflineRecognizer` runs — hence the recursive nesting rather than
    /// an array of pointers built up and released beforehand.
    private func makeRecognizer() throws -> OpaquePointer {
        var config = SherpaOnnxOfflineRecognizerConfig()
        // Leave two cores for the UI and the audio thread, as WhisperParams does.
        config.model_config.num_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        config.model_config.debug = 0

        let paths = plan.requiredFiles.map(\.path)
        let created = Self.withCStrings(paths) { pointers in
            switch plan {
            case .ctc:
                config.model_config.nemo_ctc.model = pointers[0]
            case .transducer:
                config.model_config.transducer.encoder = pointers[0]
                config.model_config.transducer.decoder = pointers[1]
                config.model_config.transducer.joiner = pointers[2]
            }
            config.model_config.tokens = pointers[pointers.count - 1]
            return "cpu".withCString { provider -> OpaquePointer? in
                config.model_config.provider = provider
                return "greedy_search".withCString { method -> OpaquePointer? in
                    config.decoding_method = method
                    return SherpaOnnxCreateOfflineRecognizer(&config)
                }
            }
        }

        guard let created else {
            throw MacomprendoError.modelMissing(plan.identifyingFile.lastPathComponent)
        }
        return created
    }

    /// Bridges every string to a C string whose lifetime spans `body`, by nesting
    /// `withCString` one level per element.
    private static func withCStrings<R>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>]) -> R
    ) -> R {
        func step(_ index: Int, _ collected: [UnsafePointer<CChar>]) -> R {
            guard index < strings.count else { return body(collected) }
            return strings[index].withCString { pointer in
                step(index + 1, collected + [pointer])
            }
        }
        return step(0, [])
    }
}
```

Implementer's note: the exact spelling of the sherpa result accessors changes between releases. Read the header before trusting the names above:

```bash
find macos/.build -name c-api.h -path '*sherpa*' -exec grep -n 'Offline' {} +
```

Use whatever that header declares. Correct pointer lifetimes matter more than matching this code character for character.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path macos --filter GigaAMTranscriberTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Providers/GigaAMTranscriber.swift macos/Tests/MacomprendoTests/Providers/GigaAMTranscriberTests.swift
git commit -m "$(cat <<'EOF'
feat(providers): add GigaAMTranscriber on sherpa-onnx

Implements TranscriptionProvider unchanged: sherpa consumes float32 16 kHz
samples, which is what AudioRecorder already produces for whisper. The
file-set-to-config mapping is a pure type, testable without the C API.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Dispatch on the engine in `ProviderFactory`

**Files:**
- Modify: `macos/Sources/Macomprendo/Providers/ProviderFactory.swift`
- Test: `macos/Tests/MacomprendoTests/Providers/ProviderFactoryTests.swift`

**Interfaces:**
- Consumes: `ResolvedLocalModel` (Task 2), `GigaAMTranscriber` (Task 4).
- Produces: no signature change to `transcriber(for:endpoints:models:)`.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func buildsAWhisperTranscriberForAWhisperModel() async throws {
        let models = StubModelManager()
        models.resolvedEngines["base"] = .whisperCpp
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())

        let transcriber = try await factory.transcriber(
            for: .local(modelID: "base"), endpoints: [], models: models
        )

        #expect(transcriber is WhisperCppTranscriber)
    }

    @Test func buildsAGigaAMTranscriberForAGigaAMModel() async throws {
        let models = StubModelManager()
        models.resolvedEngines["gigaam-v3-e2e-ctc"] = .gigaAM
        models.resolvedFiles["gigaam-v3-e2e-ctc"] = [
            .ctcModel: URL(fileURLWithPath: "/models/gigaam-v3-e2e-ctc-model.onnx"),
            .tokens: URL(fileURLWithPath: "/models/gigaam-v3-e2e-ctc-tokens.txt")
        ]
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())

        let transcriber = try await factory.transcriber(
            for: .local(modelID: "gigaam-v3-e2e-ctc"), endpoints: [], models: models
        )

        #expect(transcriber is GigaAMTranscriber)
    }

    @Test func throwsModelMissingWhenTheModelIsNotResolved() async {
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())
        await #expect(throws: MacomprendoError.modelMissing("absent")) {
            _ = try await factory.transcriber(
                for: .local(modelID: "absent"), endpoints: [], models: StubModelManager()
            )
        }
    }

    @Test func throwsModelMissingWhenAGigaAMFileSetIsIncomplete() async {
        let models = StubModelManager()
        models.resolvedEngines["broken"] = .gigaAM
        models.resolvedFiles["broken"] = [.ctcModel: URL(fileURLWithPath: "/models/m.onnx")]
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())

        await #expect(throws: MacomprendoError.self) {
            _ = try await factory.transcriber(
                for: .local(modelID: "broken"), endpoints: [], models: models
            )
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path macos --filter ProviderFactoryTests`
Expected: FAIL on `buildsAGigaAMTranscriberForAGigaAMModel` — the factory still always returns a `WhisperCppTranscriber`.

- [ ] **Step 3: Implement**

```swift
        case .local(let modelID):
            guard let resolved = await models.resolved(modelID) else {
                throw MacomprendoError.modelMissing(modelID)
            }
            switch resolved.engine {
            case .whisperCpp:
                guard let modelURL = resolved.files[.ggml] else {
                    throw MacomprendoError.modelMissing(modelID)
                }
                return WhisperCppTranscriber(modelURL: modelURL)
            case .gigaAM:
                return try GigaAMTranscriber(files: resolved.files)
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Providers/ProviderFactory.swift macos/Tests/MacomprendoTests/Providers/ProviderFactoryTests.swift
git commit -m "$(cat <<'EOF'
feat(providers): pick the transcription engine from the resolved model

TranscriptionSource keeps its shape: the engine is a property of the catalog
entry, not of the setting.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: GigaAM catalog entries, briefs and the hash script

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/ModelCatalog.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift`
- Modify: `scripts/fetch-model-hashes.mjs`
- Modify: `scripts/__tests__/fetch-model-hashes.test.mjs` (existing, 174 lines — its records are keyed on model id)
- Create: `scripts/lib/model-hashes.mjs`
- Create: `scripts/__tests__/model-hashes.test.mjs`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: catalog ids `gigaam-v3-e2e-ctc`, `gigaam-v3-e2e-rnnt`, `gigaam-multilingual-ctc`, `gigaam-multilingual-large-ctc`; and `rewriteModelFileLiteral(line, { sizeBytes, sha256 })` from `scripts/lib/model-hashes.mjs`.

- [ ] **Step 1: Write the failing Swift tests**

```swift
    @Test func offersFourGigaAMModels() {
        #expect(ModelCatalog.all(for: .gigaAM).map(\.id) == [
            "gigaam-v3-e2e-ctc",
            "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc",
            "gigaam-multilingual-large-ctc"
        ])
    }

    @Test func theRussianEntriesDeclareRussianAndTheMultilingualOnesDeclareFive() {
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-ctc")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-large-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
    }

    @Test func everyGigaAMEntryHasAUsableBrief() {
        for model in ModelCatalog.all(for: .gigaAM) {
            #expect(!model.brief.summary.isEmpty, "\(model.id) has no summary")
            #expect(!model.brief.strengths.isEmpty, "\(model.id) lists no strengths")
            #expect(!model.brief.limitations.isEmpty, "\(model.id) lists no limitations")
        }
    }

    @Test func theMultilingualBriefsWarnThatThereIsNoPunctuation() {
        for id in ["gigaam-multilingual-ctc", "gigaam-multilingual-large-ctc"] {
            let model = ModelCatalog.model(id: id)!
            #expect(model.brief.limitations.contains { $0.lowercased().contains("punctuation") },
                    "\(id) does not warn about missing punctuation")
        }
    }

    @Test func everyBenchmarkIsAttributedToAnHTTPSSource() {
        for model in ModelCatalog.all where !model.brief.benchmarks.isEmpty {
            #expect(model.brief.sourceURL.scheme == "https", "\(model.id) benchmark source is not https")
        }
    }

    @Test func theTransducerEntryDeclaresFourFiles() {
        let rnnt = ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")!
        #expect(Set(rnnt.files.map(\.role)) == [.encoder, .decoder, .joiner, .tokens])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path macos --filter ModelCatalogTests`
Expected: FAIL — `offersFourGigaAMModels` gets `[]`.

- [ ] **Step 3: Add the entries**

Change `static let all: [LocalASRModel] = whisper` to `whisper + gigaAM` and append, keeping every `ModelFile(...)` literal on one line:

```swift
    // MARK: - GigaAM

    private static let gigaAMSource = URL(string: "https://github.com/salute-developers/GigaAM")!
    private static let gigaAMMultilingualSource = URL(string: "https://huggingface.co/ai-sage/GigaAM-Multilingual")!

    private static let v3CTCBase = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16/resolve/main"
    private static let v3RNNTBase = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main"
    private static let multilingualBase = "https://huggingface.co/iaa2005/GigaAM-Multilingual-sherpa-onnx-ctc/resolve/main"

    private static let gigaAM: [LocalASRModel] = [
        LocalASRModel(
            id: "gigaam-v3-e2e-ctc",
            displayName: "GigaAM v3 e2e CTC (Russian)",
            engine: .gigaAM,
            languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-v3-e2e-ctc-model.onnx", sizeBytes: 224900000, sha256: "", downloadURL: URL(string: "\(v3CTCBase)/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-ctc-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "\(v3CTCBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "Sber's GigaAM v3, fine-tuned end-to-end so it writes punctuation and normalises numbers while it transcribes. The fastest GigaAM option and the best default for Russian dictation.",
                strengths: ["Punctuation, capitalisation and spelled-out numbers", "About a seventh the size of Whisper Large v3 Turbo", "Fast on CPU"],
                limitations: ["Russian only — other languages come out as nonsense", "Slightly less accurate than the transducer below"],
                benchmarks: [],
                sourceURL: gigaAMSource
            )
        ),
        LocalASRModel(
            id: "gigaam-v3-e2e-rnnt",
            displayName: "GigaAM v3 e2e RNN-T (Russian)",
            engine: .gigaAM,
            languages: ["ru"],
            files: [
                ModelFile(role: .encoder, fileName: "gigaam-v3-e2e-rnnt-encoder.onnx", sizeBytes: 224600000, sha256: "", downloadURL: URL(string: "\(v3RNNTBase)/encoder.int8.onnx")!),
                ModelFile(role: .decoder, fileName: "gigaam-v3-e2e-rnnt-decoder.onnx", sizeBytes: 4600000, sha256: "", downloadURL: URL(string: "\(v3RNNTBase)/decoder.onnx")!),
                ModelFile(role: .joiner, fileName: "gigaam-v3-e2e-rnnt-joiner.onnx", sizeBytes: 2700000, sha256: "", downloadURL: URL(string: "\(v3RNNTBase)/joiner.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-rnnt-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "\(v3RNNTBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "The transducer sibling of the model above: the most accurate Russian option here, also with punctuation and normalisation built in.",
                strengths: ["Best Russian accuracy among the punctuating models", "Punctuation, capitalisation and spelled-out numbers"],
                limitations: ["Russian only", "Four files to download", "Slower than the CTC model"],
                benchmarks: [],
                sourceURL: gigaAMSource
            )
        ),
        LocalASRModel(
            id: "gigaam-multilingual-ctc",
            displayName: "GigaAM Multilingual CTC",
            engine: .gigaAM,
            languages: ["ru", "en", "kk", "ky", "uz"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-multilingual-ctc-model.onnx", sizeBytes: 224800000, sha256: "", downloadURL: URL(string: "\(multilingualBase)/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-multilingual-ctc-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "\(multilingualBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "A 220M character-wise model covering Russian, English, Kazakh, Kyrgyz and Uzbek. Far ahead of Whisper on the Turkic languages, well behind it on English.",
                strengths: ["Five languages in one model", "Best open quality on Kazakh, Kyrgyz and Uzbek", "Same size as the Russian CTC model"],
                limitations: ["No punctuation and no capitalisation — output is one lowercase run of words", "Weaker on English than Whisper Large v3"],
                benchmarks: [
                    Benchmark(language: "ru", dataset: "Common Voice", metric: "WER %", value: 7.1, comparedTo: ["Whisper large-v3": 9.1]),
                    Benchmark(language: "en", dataset: "FLEURS", metric: "WER %", value: 12.2, comparedTo: ["Whisper large-v3": 3.9]),
                    Benchmark(language: "kk", dataset: "FLEURS", metric: "WER %", value: 5.2, comparedTo: ["Whisper large-v3": 32.4]),
                    Benchmark(language: "ky", dataset: "Common Voice", metric: "WER %", value: 12.5, comparedTo: ["Whisper large-v3": 95.2]),
                    Benchmark(language: "uz", dataset: "FLEURS", metric: "WER %", value: 10.0, comparedTo: ["Whisper large-v3": 105.4])
                ],
                sourceURL: gigaAMMultilingualSource
            )
        ),
        LocalASRModel(
            id: "gigaam-multilingual-large-ctc",
            displayName: "GigaAM Multilingual Large CTC",
            engine: .gigaAM,
            languages: ["ru", "en", "kk", "ky", "uz"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-multilingual-large-ctc-model.onnx", sizeBytes: 591600000, sha256: "", downloadURL: URL(string: "\(multilingualBase)/large/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-multilingual-large-ctc-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "\(multilingualBase)/large/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "The 600M version of the multilingual model, and the most accurate model offered here on Russian — at more than twice the download and noticeably more CPU per second of audio.",
                strengths: ["Best Russian accuracy of every model offered here", "Best open quality on Kazakh, Kyrgyz and Uzbek"],
                limitations: ["No punctuation and no capitalisation", "592 MB download", "Slowest option on CPU", "Still behind Whisper on English"],
                benchmarks: [
                    Benchmark(language: "ru", dataset: "Common Voice", metric: "WER %", value: 5.1, comparedTo: ["Whisper large-v3": 9.1]),
                    Benchmark(language: "ru", dataset: "FLEURS", metric: "WER %", value: 3.0, comparedTo: ["Whisper large-v3": 3.1]),
                    Benchmark(language: "en", dataset: "FLEURS", metric: "WER %", value: 9.4, comparedTo: ["Whisper large-v3": 3.9]),
                    Benchmark(language: "kk", dataset: "FLEURS", metric: "WER %", value: 4.4, comparedTo: ["Whisper large-v3": 32.4])
                ],
                sourceURL: gigaAMMultilingualSource
            )
        )
    ]
```

- [ ] **Step 4: Write the failing node test for the rewriter**

Read `scripts/fetch-model-hashes.mjs` first. Three things about it that the rest of this task depends on:

- it matches `WhisperModel(id: "...")` on one line and keys rewrites on the **model id**. One model now has up to four files, so the key becomes the **`fileName`**, which Task 1's `localFileNamesAreUniqueAcrossTheWholeCatalog` test guarantees is unique catalog-wide;
- its `downloadURLFor(id)` hardcodes the whisper Hugging Face path and it iterates a hardcoded `MODEL_IDS`. Neither can produce a GigaAM URL, so records must instead be parsed out of the catalog source as `{ fileName, downloadURL }` pairs;
- **it does not read published hashes.** Without `--download` it only issues HEAD for `Content-Length` and leaves `sha256` empty; with `--download` it streams each file end to end through SHA-256. Add an `--only <substring>` filter on `fileName` so this task can hash the four GigaAM files without also pulling ~6 GB of whisper weights.

`scripts/__tests__/model-hashes.test.mjs`:

```js
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { rewriteModelFileLiteral, downloadURLOf } from '../lib/model-hashes.mjs'

const line = '                ModelFile(role: .tokens, fileName: "x-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "https://example.com/tokens.txt")!)'

test('rewrites sizeBytes and sha256 in place', () => {
  const out = rewriteModelFileLiteral(line, { sizeBytes: 4137, sha256: 'ab12' })
  assert.match(out, /sizeBytes: 4137/)
  assert.match(out, /sha256: "ab12"/)
  assert.match(out, /fileName: "x-tokens\.txt"/)
  assert.match(out, /role: \.tokens/)
})

test('reads the download URL out of a literal', () => {
  assert.equal(downloadURLOf(line), 'https://example.com/tokens.txt')
})

test('leaves a line that is not a ModelFile literal untouched', () => {
  const other = '    static let defaultID = "large-v3-turbo"'
  assert.equal(rewriteModelFileLiteral(other, { sizeBytes: 1, sha256: 'z' }), other)
  assert.equal(downloadURLOf(other), null)
})

test('ignores an interpolated URL it cannot resolve statically', () => {
  const interpolated = '                ModelFile(role: .tokens, fileName: "y.txt", sizeBytes: 1, sha256: "", downloadURL: URL(string: "\\(base)/tokens.txt")!)'
  assert.equal(downloadURLOf(interpolated), null)
})
```

The last test matters: the GigaAM literals build their URLs from `\(v3CTCBase)` and friends, so the script must resolve those constants before matching, or skip what it cannot resolve rather than writing a wrong hash. Implement whichever the existing script's structure makes cleaner, and make the test reflect the choice.

- [ ] **Step 5: Run the node test, then implement**

Run: `npm run test:scripts` — expected FAIL (`Cannot find module '../lib/model-hashes.mjs'`). Implement `scripts/lib/model-hashes.mjs`, have `fetch-model-hashes.mjs` import it, and re-run until green.

- [ ] **Step 6: Fill in the real sizes and hashes**

```bash
node scripts/fetch-model-hashes.mjs --download --only gigaam
git diff macos/Sources/Macomprendo/Services/ModelCatalog.swift
```

This transfers about 1.3 GB. Every GigaAM `sha256: ""` must come back holding a 64-character digest and every placeholder size must become an exact byte count. If a hash comes back empty, the script could not resolve that URL — fix the resolution rather than committing a blank.

Whisper's entries keep their empty `sha256`, exactly as they are on main today: filling them would cost another 6 GB of transfer for something this plan does not need. The spec pins the *community* GigaAM conversions by hash because nobody upstream has verified them; whisper's weights come from the same repository the project has always trusted.

- [ ] **Step 7: Run everything and commit**

```bash
npm run test:swift && npm run test:scripts
git add macos/Sources/Macomprendo/Services/ModelCatalog.swift macos/Tests/MacomprendoTests/Services/ModelCatalogTests.swift scripts
git commit -m "$(cat <<'EOF'
feat(models): offer four GigaAM models with briefs and benchmarks

Two Russian e2e entries from the sherpa-onnx maintainer's own repositories and two
multilingual entries from a community conversion, all pinned by SHA-256. Every
entry states in words what it is good at and what it will not do.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Backend readiness and the endpoint probe

**Files:**
- Create: `macos/Sources/Macomprendo/Features/BackendReadiness.swift`
- Modify: `macos/Sources/Macomprendo/Providers/OpenAICompatibleTranscriber.swift`
- Test: `macos/Tests/MacomprendoTests/Features/BackendReadinessTests.swift`

**Interfaces:**
- Consumes: `ModelState` (Task 2), `TranscriptionSource`.
- Produces: `BackendReadiness` (`.ready`, `.notReady(reason:fix:)`), `FixAction` (`.download(modelID:)`, `.testEndpoint(id:)`, `.selectModel`), `EndpointProbeResult` (`.succeeded`, `.failed(String)`), `BackendReadiness.of(source:states:endpointProbe:)`, and `OpenAICompatibleTranscriber.probe() async throws`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite struct BackendReadinessTests {

    private let endpointID = UUID()

    @Test func aDownloadedLocalModelIsReady() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .downloaded],
                                    endpointProbe: nil) == .ready)
    }

    @Test func anUndownloadedLocalModelOffersToDownloadIt() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .notDownloaded],
                                    endpointProbe: nil)
                == .notReady(reason: "This model has not been downloaded yet.",
                             fix: .download(modelID: "base")))
    }

    @Test func anUnknownModelIsTreatedAsNotDownloaded() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"), states: [:], endpointProbe: nil)
                == .notReady(reason: "This model has not been downloaded yet.",
                             fix: .download(modelID: "base")))
    }

    @Test func aDownloadInProgressIsNotReadyAndOffersNoFix() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .downloading(fraction: 0.4)],
                                    endpointProbe: nil)
                == .notReady(reason: "Downloading… 40%", fix: nil))
    }

    @Test func aFailedDownloadReportsTheFailureAndOffersARetry() {
        #expect(BackendReadiness.of(source: .local(modelID: "base"),
                                    states: ["base": .failed("checksum mismatch")],
                                    endpointProbe: nil)
                == .notReady(reason: "checksum mismatch", fix: .download(modelID: "base")))
    }

    @Test func anUnprobedEndpointIsNotReady() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:], endpointProbe: nil)
                == .notReady(reason: "This endpoint has not been tested yet.",
                             fix: .testEndpoint(id: endpointID)))
    }

    @Test func aSuccessfullyProbedEndpointIsReady() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:], endpointProbe: .succeeded) == .ready)
    }

    @Test func aFailedProbeReportsWhyAndOffersARetest() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "whisper-1"),
                                    states: [:], endpointProbe: .failed("HTTP 404"))
                == .notReady(reason: "HTTP 404", fix: .testEndpoint(id: endpointID)))
    }

    @Test func anEndpointWithABlankModelNameIsNotReadyEvenAfterASuccessfulProbe() {
        #expect(BackendReadiness.of(source: .endpoint(id: endpointID, model: "  "),
                                    states: [:], endpointProbe: .succeeded)
                == .notReady(reason: "No model name is set.", fix: .selectModel))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos --filter BackendReadinessTests`
Expected: FAIL — `cannot find 'BackendReadiness' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What the user should do about a backend that cannot run.
enum FixAction: Sendable, Equatable {
    case download(modelID: String)
    case testEndpoint(id: UUID)
    case selectModel
}

/// The outcome of the last endpoint probe in this session.
enum EndpointProbeResult: Sendable, Equatable {
    case succeeded
    case failed(String)
}

/// Whether the configured transcription backend can actually run right now. Computed on
/// demand, never stored: it is a view of state that already exists elsewhere.
enum BackendReadiness: Sendable, Equatable {
    case ready
    case notReady(reason: String, fix: FixAction?)

    static func of(
        source: TranscriptionSource,
        states: [String: ModelState],
        endpointProbe: EndpointProbeResult?
    ) -> BackendReadiness {
        switch source {
        case .local(let modelID):
            switch states[modelID] ?? .notDownloaded {
            case .downloaded:
                return .ready
            case .notDownloaded:
                return .notReady(reason: "This model has not been downloaded yet.",
                                 fix: .download(modelID: modelID))
            case .downloading(let fraction):
                return .notReady(reason: "Downloading… \(Int(fraction * 100))%", fix: nil)
            case .failed(let message):
                return .notReady(reason: message, fix: .download(modelID: modelID))
            }

        case .endpoint(let id, let model):
            // Checked before the probe: a probe can only have succeeded against some model
            // name, and a blank one would send an unusable request at hotkey-press time.
            guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .notReady(reason: "No model name is set.", fix: .selectModel)
            }
            switch endpointProbe {
            case .succeeded:
                return .ready
            case .failed(let message):
                return .notReady(reason: message, fix: .testEndpoint(id: id))
            case nil:
                return .notReady(reason: "This endpoint has not been tested yet.",
                                 fix: .testEndpoint(id: id))
            }
        }
    }
}
```

Add the probe to `OpenAICompatibleTranscriber`:

```swift
    /// Exercises the same route dictation will use. `listModels()` would only prove
    /// reachability and credentials; a status that says "ready" must mean that the thing
    /// which runs at hotkey-press time has run.
    func probe() async throws {
        _ = try await transcribe(Array(repeating: 0, count: 16_000), sampleRate: 16_000, language: nil)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/BackendReadiness.swift macos/Sources/Macomprendo/Providers/OpenAICompatibleTranscriber.swift macos/Tests/MacomprendoTests/Features/BackendReadinessTests.swift
git commit -m "$(cat <<'EOF'
feat(dictation): compute whether the configured backend can actually run

Local models are ready once downloaded; endpoints once a probe against the real
transcription route has succeeded. Each not-ready state names its fix.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Remember the selection per engine

**Files:**
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Test: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`

**Interfaces:**
- Consumes: `ASREngine` (Task 1).
- Produces: `Settings.lastModelByEngine: [String: String]`, `Settings.lastTranscriptionEndpointID: UUID?`, `Settings.lastTranscriptionEndpointModel: String?`.

`currentSchemaVersion` does **not** move: the new keys decode to their defaults through the hand-written `init(from:)`, exactly as `SpeechSettings`'s keys do.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func aDocumentWithoutTheNewSelectionKeysDecodesToEmptyDefaults() throws {
        let json = Data(#"{"schemaVersion":2,"dictationMode":"hold"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: json)

        #expect(settings.lastModelByEngine == [:])
        #expect(settings.lastTranscriptionEndpointID == nil)
        #expect(settings.lastTranscriptionEndpointModel == nil)
    }

    @Test func theSelectionKeysSurviveARoundTrip() throws {
        var settings = Settings.default
        let id = UUID()
        settings.lastModelByEngine = ["whisperCpp": "base", "gigaAM": "gigaam-v3-e2e-ctc"]
        settings.lastTranscriptionEndpointID = id
        settings.lastTranscriptionEndpointModel = "whisper-1"

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.lastModelByEngine["gigaAM"] == "gigaam-v3-e2e-ctc")
        #expect(decoded.lastModelByEngine["whisperCpp"] == "base")
        #expect(decoded.lastTranscriptionEndpointID == id)
        #expect(decoded.lastTranscriptionEndpointModel == "whisper-1")
    }

    @Test func addingTheSelectionKeysDoesNotMoveTheSchemaVersion() {
        #expect(Settings.currentSchemaVersion == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos --filter SettingsTests`
Expected: FAIL — `value of type 'Settings' has no member 'lastModelByEngine'`.

- [ ] **Step 3: Implement**

Add the stored properties:

```swift
    /// `ASREngine.rawValue` → the model id last selected for that engine, so returning to a
    /// backend's sub-tab restores what was chosen there rather than the engine's default.
    var lastModelByEngine: [String: String]
    /// The endpoint last configured for transcription. Stored as its two components rather
    /// than as a `TranscriptionSource?`, because only one of that enum's cases would ever be
    /// valid here and a type that can hold an impossible value invites the bug of writing one.
    var lastTranscriptionEndpointID: UUID?
    var lastTranscriptionEndpointModel: String?
```

Add them to the memberwise initialiser with defaults `[:]`, `nil`, `nil`, add the three `CodingKeys`, and decode them in `init(from:)`:

```swift
        lastModelByEngine = try c.decodeIfPresent([String: String].self, forKey: .lastModelByEngine) ?? [:]
        lastTranscriptionEndpointID = try c.decodeIfPresent(UUID.self, forKey: .lastTranscriptionEndpointID)
        lastTranscriptionEndpointModel = try c.decodeIfPresent(String.self, forKey: .lastTranscriptionEndpointModel)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Core/Settings.swift macos/Tests/MacomprendoTests/Core/SettingsTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): remember the selected model per engine

New keys decode to their defaults through the existing hand-written init(from:),
so the schema version does not move.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The Dictation tab as three backend sub-tabs

> **SUPERSEDED IN PART — read the spec before this section.** Partway through this task the
> design changed: an explicit active-model selector now sits above the sub-tabs and lists only
> ready-to-use backends, and the sub-tabs became pure navigation that no longer write
> `transcriptionSource`. `Settings.lastModelByEngine` is deleted with it, and there is one
> status block beside the selector rather than one per tab. The text below still describes the
> earlier "active sub-tab *is* the selection" design; where the two disagree, the spec's
> "The Dictation tab" section wins. See `docs/superpowers/HANDOFF-2026-08-31-transcription-backends.md`.

**Files:**
- Create: `macos/Sources/Macomprendo/UI/Settings/DictationTabModel.swift`
- Create: `macos/Sources/Macomprendo/UI/Settings/ModelBriefView.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/DictationTab.swift`
- Test: `macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift`

**Interfaces:**
- Consumes: `ASREngine`, `LocalASRModel`, `ModelBrief`, `Benchmark` (Tasks 1, 6); `BackendReadiness`, `FixAction`, `EndpointProbeResult` (Task 7); `Settings.lastModelByEngine` (Task 8).
- Produces: `DictationBackendTab` (`.whisperCpp`, `.gigaAM`, `.endpoint`) with `title`, `engine: ASREngine?`, `parameterSummary`; `DictationTabModel(holder:catalog:)` — injected through the **existing production** `SettingsHolding` protocol (`App/SettingsHolding.swift`, `var settings: Settings { get set }`), never the test-only `SettingsHolder` — with `activeTab`, `rows(for:)`, `select(tab:)`, `select(modelID:)`, `readiness`, `statusHeadline`, `statusDetail`, `activeSourceName`, `modelStates`, `endpointProbe`.

All decision logic lives in `DictationTabModel` so it is testable; the SwiftUI file only renders it.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Macomprendo

@Suite @MainActor struct DictationTabModelTests {

    private func tabModel(_ settings: Settings = .default) -> DictationTabModel {
        DictationTabModel(holder: ScriptedSettingsHolder(settings), catalog: ModelCatalog.all)
    }

    @Test func theActiveTabFollowsTheConfiguredSource() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "gigaam-v3-e2e-ctc")
        #expect(tabModel(settings).activeTab == .gigaAM)

        settings.transcriptionSource = .local(modelID: "base")
        #expect(tabModel(settings).activeTab == .whisperCpp)

        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        #expect(tabModel(settings).activeTab == .endpoint)
    }

    @Test func selectingATabMakesItsRememberedModelTheConfiguredSource() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "base")
        settings.lastModelByEngine = ["gigaAM": "gigaam-v3-e2e-rnnt"]
        let tab = tabModel(settings)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-v3-e2e-rnnt"))
    }

    @Test func selectingATabWithNoRememberedModelFallsBackToItsFirstEntry() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "base")
        let tab = tabModel(settings)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-v3-e2e-ctc"))
    }

    @Test func selectingAModelRecordsItAsThatEnginesRememberedChoice() {
        let tab = tabModel()

        tab.select(modelID: "gigaam-multilingual-large-ctc")

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-large-ctc"))
        #expect(tab.holder.settings.lastModelByEngine["gigaAM"] == "gigaam-multilingual-large-ctc")
    }

    @Test func returningToATabRestoresWhatWasChosenThereRatherThanTheDefault() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-multilingual-ctc")
        tab.select(tab: .whisperCpp)

        tab.select(tab: .gigaAM)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "gigaam-multilingual-ctc"))
    }

    @Test func selectingTheAlreadyActiveTabChangesNothing() {
        var settings = Settings.default
        settings.transcriptionSource = .local(modelID: "small")
        let tab = tabModel(settings)

        tab.select(tab: .whisperCpp)

        #expect(tab.holder.settings.transcriptionSource == .local(modelID: "small"))
    }

    @Test func eachTabListsOnlyItsOwnEnginesModels() {
        let tab = tabModel()
        #expect(tab.rows(for: .gigaAM).allSatisfy { $0.engine == .gigaAM })
        #expect(tab.rows(for: .gigaAM).count == 4)
        #expect(tab.rows(for: .whisperCpp).count == 9)
        #expect(tab.rows(for: .endpoint).isEmpty)
    }

    @Test func aReadyTabSaysThisIsTheActiveDictationModel() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .downloaded

        #expect(tab.readiness == .ready)
        #expect(tab.statusHeadline == "Ready to use")
        #expect(tab.statusDetail.contains("GigaAM v3 e2e CTC (Russian)"))
        #expect(tab.statusDetail.lowercased().contains("dictation"))
    }

    @Test func anUnreadyTabExplainsWhatIsWrongAndThatDictationWillFail() {
        let tab = tabModel()
        tab.select(tab: .gigaAM)
        tab.select(modelID: "gigaam-v3-e2e-ctc")
        tab.modelStates["gigaam-v3-e2e-ctc"] = .notDownloaded

        #expect(tab.statusHeadline == "Not ready")
        #expect(tab.statusDetail.contains("has not been downloaded"))
        #expect(tab.statusDetail.lowercased().contains("will fail"))
    }

    @Test func anEndpointSourceIsNamedByItsModel() {
        var settings = Settings.default
        settings.transcriptionSource = .endpoint(id: UUID(), model: "whisper-1")
        #expect(tabModel(settings).activeSourceName == "OpenAI endpoint · whisper-1")
    }

    @Test func gigaAMReportsThatItHasNoParametersToConfigure() {
        #expect(DictationBackendTab.gigaAM.parameterSummary.lowercased().contains("no settings"))
        #expect(DictationBackendTab.whisperCpp.parameterSummary.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path macos --filter DictationTabModelTests`
Expected: FAIL — `cannot find 'DictationTabModel' in scope`.

- [ ] **Step 3: Implement `DictationTabModel.swift`**

```swift
import Foundation
import SwiftUI

/// One backend's sub-tab in the Dictation settings.
enum DictationBackendTab: String, CaseIterable, Identifiable, Sendable {
    case whisperCpp
    case gigaAM
    case endpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisperCpp: "whisper.cpp"
        case .gigaAM: "GigaAM"
        case .endpoint: "OpenAI endpoint"
        }
    }

    /// `nil` for the endpoint tab, which lists no local models.
    var engine: ASREngine? {
        switch self {
        case .whisperCpp: .whisperCpp
        case .gigaAM: .gigaAM
        case .endpoint: nil
        }
    }

    /// Shown instead of parameter controls. Empty means "this tab has real controls".
    var parameterSummary: String {
        switch self {
        case .whisperCpp, .endpoint:
            ""
        case .gigaAM:
            "No settings. The Russian models take no language hint, the multilingual models "
                + "detect their own language, and decoding is greedy."
        }
    }
}

@MainActor
final class DictationTabModel: ObservableObject {
    @Published var modelStates: [String: ModelState] = [:]
    @Published var endpointProbe: EndpointProbeResult?

    /// Read/write access to the live document, the same seam `PromptsTab`, `SpeechTab` and
    /// `QuickPanelController` use. `AppModel` conforms; tests pass `ScriptedSettingsHolder`.
    let holder: any SettingsHolding
    private let catalog: [LocalASRModel]

    init(holder: any SettingsHolding, catalog: [LocalASRModel] = ModelCatalog.all) {
        self.holder = holder
        self.catalog = catalog
    }

    var activeTab: DictationBackendTab {
        switch holder.settings.transcriptionSource {
        case .endpoint:
            return .endpoint
        case .local(let modelID):
            let engine = catalog.first { $0.id == modelID }?.engine ?? .whisperCpp
            return engine == .gigaAM ? .gigaAM : .whisperCpp
        }
    }

    func rows(for tab: DictationBackendTab) -> [LocalASRModel] {
        guard let engine = tab.engine else { return [] }
        return catalog.filter { $0.engine == engine }
    }

    /// Selecting a tab configures that backend. This deliberately gives a navigation control
    /// a persistent side effect — see the spec — so the status block states it in words
    /// rather than leaving it to be discovered by dictating.
    func select(tab: DictationBackendTab) {
        guard tab != activeTab else { return }
        switch tab {
        case .endpoint:
            holder.settings.transcriptionSource = .endpoint(
                id: holder.settings.lastTranscriptionEndpointID
                    ?? holder.settings.endpoints.first?.id
                    ?? Endpoint.ollamaLocalID,
                model: holder.settings.lastTranscriptionEndpointModel ?? "whisper-1"
            )
        case .whisperCpp, .gigaAM:
            guard let engine = tab.engine else { return }
            let remembered = holder.settings.lastModelByEngine[engine.rawValue]
            let fallback = catalog.first { $0.engine == engine }?.id
            guard let modelID = remembered ?? fallback else { return }
            holder.settings.transcriptionSource = .local(modelID: modelID)
        }
    }

    func select(modelID: String) {
        guard let engine = catalog.first(where: { $0.id == modelID })?.engine else { return }
        holder.settings.lastModelByEngine[engine.rawValue] = modelID
        holder.settings.transcriptionSource = .local(modelID: modelID)
    }

    var readiness: BackendReadiness {
        BackendReadiness.of(source: holder.settings.transcriptionSource,
                            states: modelStates,
                            endpointProbe: endpointProbe)
    }

    var statusHeadline: String {
        readiness == .ready ? "Ready to use" : "Not ready"
    }

    var statusDetail: String {
        switch readiness {
        case .ready:
            "\(activeSourceName) is your active dictation model. Press your dictation hotkey "
                + "and it will be used."
        case .notReady(let reason, _):
            "\(reason) \(activeSourceName) is the selected backend, so dictation will fail "
                + "until this is fixed."
        }
    }

    var activeSourceName: String {
        switch holder.settings.transcriptionSource {
        case .local(let modelID):
            catalog.first { $0.id == modelID }?.displayName ?? modelID
        case .endpoint(_, let model):
            "OpenAI endpoint · \(model)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path macos --filter DictationTabModelTests`
Expected: PASS.

- [ ] **Step 5: Write `ModelBriefView` and rebuild `DictationTab`**

`ModelBriefView.swift` renders one `ModelBrief`: the summary as body text, `strengths` and `limitations` as short bulleted lines (use `Icon(.success)` and `Icon(.warning)` at 11 pt — never `Image(systemName:)`), and the benchmarks as a compact grid of `language · dataset · metric · value` with each `comparedTo` entry beside it, followed by `Link("Source", destination: brief.sourceURL)`. A brief with no benchmarks renders no table.

`DictationTab.swift` becomes:

```swift
struct DictationTab: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var tab: DictationTabModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: tabBinding) {
                ForEach(DictationBackendTab.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Form {
                switch tab.activeTab {
                case .whisperCpp, .gigaAM:
                    modelsSection
                    parametersSection
                case .endpoint:
                    endpointSection
                }
                statusSection
            }
            .formStyle(.grouped)
        }
        .task { await model.modelsViewModel.refresh() }
    }
}
```

- `modelsSection` renders one row per `tab.rows(for: tab.activeTab)` entry: a selection control that calls `tab.select(modelID:)`, the display name, `ModelsViewModel.sizeText(model.totalSizeBytes)`, the languages (or "90+ languages" when `languages == nil`), a `ModelBriefView`, and the existing download / cancel / delete control from the current `modelStateView`.
- `parametersSection` for whisper.cpp keeps the spoken-language picker and adds the thread count and the `translate` flag, which is currently pinned to `false` in `WhisperParams.make`; for GigaAM it renders `tab.activeTab.parameterSummary` as explanatory text and nothing else.
- `endpointSection` keeps today's endpoint picker and model field and adds a "Test" button that runs `OpenAICompatibleTranscriber.probe()` and stores the outcome in `tab.endpointProbe`.
- `statusSection` shows `Icon(.success)` or `Icon(.warning)` beside `tab.statusHeadline`, then `tab.statusDetail`, then a button for the `FixAction`: `.download(id)` calls `model.modelsViewModel.download(id)`, `.testEndpoint` runs the probe, `.selectModel` focuses the model field.

**Keep `static func stateCaption(for: ModelState?) -> String` and its exact wording.** The rebuild must not drop it: `ModelsViewModelTests.stateCaptionsNoLongerPointAtADeletedTab` covers it, and the per-model rows still use it. Its "download it under Speech models below" string is now wrong, though — that section no longer exists. Update that one case to "Not downloaded — use the Download button on this row." and update the assertion in `ModelsViewModelTests` to match.

Keep `tab.modelStates` in step with `model.modelsViewModel.rows` so readiness reflects live download progress.

- [ ] **Step 6: Run everything**

```bash
npm run test:swift
swift build --package-path macos
```

Expected: tests PASS, no new warnings.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/UI/Settings macos/Tests/MacomprendoTests/UI/DictationTabModelTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): give Dictation one sub-tab per transcription backend

The active sub-tab plus the selected row is the configured backend. Each tab shows
model briefs with published benchmarks, the parameters that backend really accepts,
and whether it can run right now.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Name the active model in the HUD

**Files:**
- Modify: `macos/Sources/Macomprendo/UI/RecordingHUD/HUDController.swift`
- Modify: `macos/Sources/Macomprendo/UI/RecordingHUD/HUDView.swift`
- Modify: `macos/Sources/Macomprendo/UI/RecordingHUD/HUDWindowPresenter.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Test: `macos/Tests/MacomprendoTests/UI/HUDViewTests.swift`, `macos/Tests/MacomprendoTests/UI/HUDControllerTests.swift`, `macos/Tests/MacomprendoTests/UI/HUDLayoutTests.swift`

**Interfaces:**
- Consumes: `TranscriptionSource`, `ModelCatalog` (Tasks 1, 6).
- Produces: `HUDController.modelCaption: String?`, `HUDController.caption(for: TranscriptionSource) -> String`, `HUDView.captionText(for:caption:) -> String?`, `HUDLayout.size` = 260 × 108.

- [ ] **Step 1: Write the failing tests**

In `HUDViewTests`:

```swift
    @Test func showsTheModelCaptionWhileRecordingAndTranscribing() {
        #expect(HUDView.captionText(for: .recording(level: 0.2, elapsed: 1), caption: "Large v3 Turbo")
                == "Large v3 Turbo")
        #expect(HUDView.captionText(for: .transcribing, caption: "Large v3 Turbo") == "Large v3 Turbo")
    }

    @Test func hidesTheModelCaptionWhileSpeaking() {
        // .speaking is text-to-speech; naming a transcription model there would mislead.
        #expect(HUDView.captionText(for: .speaking(hint: "Esc stops"), caption: "Large v3 Turbo") == nil)
    }

    @Test func hidesTheModelCaptionInEveryTerminalState() {
        for state: HUDState in [.hidden, .success("Inserted"), .error("Nope"), .toast("Hi")] {
            #expect(HUDView.captionText(for: state, caption: "Large v3 Turbo") == nil)
        }
    }

    @Test func showsNoCaptionWhenThereIsNoneOrItIsBlank() {
        #expect(HUDView.captionText(for: .transcribing, caption: nil) == nil)
        #expect(HUDView.captionText(for: .transcribing, caption: "") == nil)
    }
```

In `HUDControllerTests`:

```swift
    @Test func namesALocalModelByItsCatalogDisplayName() {
        #expect(HUDController.caption(for: .local(modelID: "large-v3-turbo")) == "Large v3 Turbo")
        #expect(HUDController.caption(for: .local(modelID: "gigaam-v3-e2e-ctc"))
                == "GigaAM v3 e2e CTC (Russian)")
    }

    @Test func namesAnEndpointByItsModel() {
        #expect(HUDController.caption(for: .endpoint(id: UUID(), model: "whisper-1"))
                == "OpenAI endpoint · whisper-1")
    }

    @Test func fallsBackToTheRawIDForAModelNoLongerInTheCatalog() {
        #expect(HUDController.caption(for: .local(modelID: "removed-model")) == "removed-model")
    }
```

In `HUDLayoutTests`:

```swift
    @Test func theHUDIsTallEnoughForTheModelCaption() {
        #expect(HUDLayout.size == CGSize(width: 260, height: 108))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path macos --filter HUD`
Expected: FAIL — `type 'HUDView' has no member 'captionText'`.

- [ ] **Step 3: Implement**

`HUDWindowPresenter.swift`: `static let size = CGSize(width: 260, height: 108)`.

`HUDController.swift`:

```swift
    /// The active transcription model's name, shown dim while recording and transcribing so a
    /// misconfiguration is visible before the transcript comes back wrong.
    @Published var modelCaption: String?

    /// Pure, so the wording is unit-tested. `nonisolated` for the same reason
    /// `HUDView.elapsedText` is: `ObservableObject` members would otherwise inherit the
    /// main-actor isolation of the type.
    nonisolated static func caption(for source: TranscriptionSource) -> String {
        switch source {
        case .local(let modelID):
            ModelCatalog.model(id: modelID)?.displayName ?? modelID
        case .endpoint(_, let model):
            "OpenAI endpoint · \(model)"
        }
    }
```

`HUDView.swift`:

```swift
    /// Which states name the model. `.speaking` deliberately does not: it belongs to
    /// text-to-speech, where a transcription model's name would be actively misleading.
    nonisolated static func captionText(for state: HUDState, caption: String?) -> String? {
        guard let caption, !caption.isEmpty else { return nil }
        switch state {
        case .recording, .transcribing: return caption
        case .hidden, .speaking, .success, .error, .toast: return nil
        }
    }
```

and wrap the existing `content` so the caption sits under it:

```swift
        VStack(spacing: 4) {
            content
            if let caption = Self.captionText(for: controller.state, caption: controller.modelCaption) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: HUDLayout.size.width, height: HUDLayout.size.height)
```

In `AppModel`, set `hud.modelCaption = HUDController.caption(for: settings.transcriptionSource)` at construction and wherever `transcriptionSource` changes, so the caption never lags the setting.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm run test:swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/UI/RecordingHUD macos/Sources/Macomprendo/App/AppModel.swift macos/Tests/MacomprendoTests/UI
git commit -m "$(cat <<'EOF'
feat(hud): name the active transcription model while recording

Shown dim under the level meter during recording and transcribing, and never
during speech playback, where a transcription model name would mislead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: ADR, docs, and a real signed build

The dynamic-framework path in `scripts/build-app.mjs` exists but has never run: whisper's slices are static, so `listFrameworks` has always returned an empty list. This task proves it works before the feature is called done.

**Files:**
- Create: `docs/DECISIONS/ADR-0009-sherpa-onnx-gigaam.md`
- Modify: `docs/SMOKE_TEST.md`, `DISTRIBUTING.md`, `CHANGELOG.md`, `AGENTS.md`

- [ ] **Step 1: Write ADR-0009**

Follow ADR-0007's shape — Status / Context / Decision / Consequences.

Context: GigaAM has no whisper.cpp-style runtime; sherpa-onnx supports both its CTC and transducer variants and publishes prebuilt macOS xcframeworks per release; writing log-mel feature extraction and RNN-T decoding by hand would be numeric code whose errors corrupt text silently rather than failing.

Decision: vendor `sherpa-onnx-v1.13.4-macos-shared-onnxruntime-static.xcframework.zip` as a `binaryTarget` in `macos/Packages/SherpaOnnxBinary`, checksum `ef7daa86a1e5f5dcb0ccf53e4e475c3ae24414652c9ae9c3912a82140c86fb1a`.

Consequences: the `.app` grows by roughly 18 MB; `SherpaOnnxC.framework` is the first dynamic framework in the bundle, so `Contents/Frameworks`, the added rpath and innermost-out signing are exercised for the first time; upstream's `xcframework` tag is a rolling tag, so upgrading means downloading the asset, re-running `swift package compute-checksum` and re-verifying; and the two multilingual catalog entries come from a community conversion with no official sherpa export, pinned by SHA-256 and covered by a dedicated smoke-test step.

- [ ] **Step 2: Add the smoke tests**

Append to `docs/SMOKE_TEST.md`:

```markdown
## GigaAM local transcription

1. Settings ▸ Dictation ▸ GigaAM. Each of the four models downloads to completion and the
   status block turns to "Ready to use".
2. With `gigaam-v3-e2e-ctc` selected, dictate a Russian sentence containing a number.
   Expect punctuation, capitalisation, and the number spelled out.
3. Repeat with `gigaam-v3-e2e-rnnt`: same expectations, and no crash on the four-file set.
4. With `gigaam-multilingual-ctc` selected, dictate Russian: expect correct words with **no**
   punctuation and no capitals. Then dictate English and confirm it transcribes at all.
5. Repeat step 4 with `gigaam-multilingual-large-ctc`. Neither multilingual entry has an
   upstream sherpa-onnx export, so nobody has verified their embedded ONNX metadata for us:
   confirm the model loads rather than failing inside sherpa.
6. Switch between two GigaAM models and dictate after each. Memory in Activity Monitor
   returns to roughly its previous level, showing the old recognizer was freed.
7. Start a dictation, then press the hotkey again mid-transcription: the first task is
   cancelled and no text is inserted twice.
8. The HUD names the active model while recording, and does not name it while Speak plays.
9. Switch the Dictation sub-tab to one whose model is not downloaded, then press the
   dictation hotkey: the failure names the missing model rather than failing opaquely.
```

- [ ] **Step 3: Run the signed build and verify the framework**

```bash
node scripts/build-app.mjs --sign -
codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app
ls dist/Macomprendo.app/Contents/Frameworks
otool -l dist/Macomprendo.app/Contents/MacOS/Macomprendo | grep -A 2 LC_RPATH
```

Expected: `SherpaOnnxC.framework` present in `Contents/Frameworks`, `codesign --verify` passes, and the rpath includes `@executable_path/../Frameworks`. Then launch the built `.app` and dictate once with a GigaAM model, to prove the framework resolves at runtime and not merely at build time.

If `Contents/Frameworks` is empty, the discovery step did not see the framework: inspect what `swift build` emitted next to the executable and fix `listFrameworks` in `scripts/build-app.mjs` rather than hard-coding a name.

- [ ] **Step 4: Update the operator docs**

`DISTRIBUTING.md` — extend "What the build copies into the bundle" with `SherpaOnnxC.framework`, noting it is the first dynamic framework in the bundle and is signed before the app itself.

`AGENTS.md` — add `Packages/SherpaOnnxBinary` to the project map and note in the invariants that there are now two vendored xcframeworks, both upgraded deliberately.

`CHANGELOG.md` under `Unreleased`:

```markdown
### Added
- GigaAM local transcription: four Sber models covering Russian with punctuation, and
  Russian, English, Kazakh, Kyrgyz and Uzbek without it, alongside whisper.cpp.
- Dictation settings now have one sub-tab per backend, each with model briefs, published
  benchmarks, the parameters that backend accepts, and a readiness status.
- The recording HUD names the model that will transcribe.

### Changed
- Models are described as file sets, so a model can consist of more than one file.
```

- [ ] **Step 5: Final verification and commit**

```bash
npm run test:swift && npm run test:scripts
swift build --package-path macos
npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj
git add docs DISTRIBUTING.md CHANGELOG.md AGENTS.md
git commit -m "$(cat <<'EOF'
docs: record the sherpa-onnx decision and the GigaAM smoke tests

ADR-0009 extends ADR-0007 to a second vendored xcframework. The smoke tests cover
what cannot be unit-tested: real transcription, punctuation behaviour per model
line, recognizer lifetime, and the signed bundle.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```
