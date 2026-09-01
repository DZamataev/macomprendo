# Dictation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, local, text-only history for Dictate and Dictate & Refine with a 100,000-entry SQLite limit, a paged history window, per-row Copy, and explicit Clear History.

**Architecture:** A protocol-backed actor in Services owns the SQLite database and cursor paging. A shared `@MainActor` feature controller records accepted transcripts and drives the history window; both microphone flows call its unique acceptance hook. `AppEnvironment` constructs the live store, `AppModel` owns the shared controller, and SwiftUI exposes the preference, conditional menu command, and single-instance window.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, AppKit, system SQLite3, Swift Testing, SwiftPM, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-01-dictation-history.md`

## Global Constraints

- macOS 14+, Swift 6 strict concurrency; controllers and views are `@MainActor`, the mutable SQLite connection is actor-isolated.
- Dependencies point downward only: UI → Features → Services → Core. Construct the concrete SQLite service only in `AppEnvironment`.
- History defaults off and records only accepted, trimmed, non-empty microphone transcripts from Dictate and Dictate & Refine.
- Never record audio, selection-refine input, LLM output, target application, endpoint/model metadata, or readiness probes.
- Keep at most exactly 100,000 newest insertion-order entries; append and trimming are one transaction.
- Disabling history preserves existing rows and hides the menubar command. Clear is separate and confirmed.
- Never log transcript or LLM text at default level. Error text must not include transcript content.
- Use `Icon(.copy)` for Copy; no new icon is required.
- Every new user-visible failure is a `MacomprendoError` with description and recovery text.
- TDD is mandatory: add each failing test, observe the expected RED, then add the minimum production code.
- `macos/project.yml` remains the Xcode source of truth; regenerate the committed project after source/configuration changes.

## File map

- `Core/DictationHistoryEntry.swift`: Sendable entry, kind, and cursor page values.
- `Core/Settings.swift`: persisted opt-in preference with legacy decoding.
- `Core/MacomprendoError.swift`: history-storage failure case.
- `Services/DictationHistoryStore.swift`: storage protocol plus actor-backed SQLite implementation.
- `Features/DictationHistoryController.swift`: recording, paging, copy, clear, and non-fatal error state.
- `Features/DictationController.swift`: accepted direct-dictation commit point.
- `Features/DictationCapture.swift`: accepted Dictate & Refine commit point.
- `App/AppEnvironment.swift`, `App/AppModel.swift`, `App/TextFeatures.swift`: concrete construction and shared graph wiring.
- `UI/History/DictationHistoryView.swift`: paged list and row actions.
- `UI/MenuBar/MenuBarView.swift`, `UI/Settings/GeneralTab.swift`, `App/MacomprendoApp.swift`: entry points and preference.
- `Features/DockIconCoordinator.swift`: history-window Dock ownership.
- Tests mirror every production type; `Fakes/FakeDictationHistoryStore.swift` is the injected protocol double.

---

### Task 1: Core history contract and opt-in preference

**Files:**
- Create: `macos/Sources/Macomprendo/Core/DictationHistoryEntry.swift`
- Create: `macos/Tests/MacomprendoTests/Core/DictationHistoryEntryTests.swift`
- Modify: `macos/Sources/Macomprendo/Core/Settings.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/SettingsTests.swift`
- Modify: `macos/Sources/Macomprendo/Core/MacomprendoError.swift`
- Modify: `macos/Tests/MacomprendoTests/Core/MacomprendoErrorTests.swift`

**Interfaces:**
- Produces: `DictationHistoryKind`, `DictationHistoryEntry`, `DictationHistoryPage`, `Settings.dictationHistoryEnabled`, and `MacomprendoError.dictationHistory(String)`.
- Consumes: existing hand-written `Settings.init(from:)` migration pattern and `ErrorText.describe`.

- [ ] **Step 1: Write failing Core and Settings tests**

Add tests proving exact entry equality/identity, cursor data, the default-off preference,
legacy decode, enabled round trip, and complete error text:

```swift
@Test func historyEntryCarriesStableIdentityAndKind() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = DictationHistoryEntry(id: 42, createdAt: date,
                                      kind: .dictationAndRefine, text: "hello")
    #expect(entry.id == 42)
    #expect(entry.createdAt == date)
    #expect(entry.kind == .dictationAndRefine)
    #expect(entry.text == "hello")
}

@Test func historyPageCarriesTheNextCursor() {
    let page = DictationHistoryPage(entries: [], nextCursor: 41)
    #expect(page.nextCursor == 41)
}

@Test func dictationHistoryDefaultsOff() {
    #expect(Settings.default.dictationHistoryEnabled == false)
}

@Test func legacySettingsDecodeHistoryAsDisabled() throws {
    var object = try #require(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)) as? [String: Any])
    object.removeValue(forKey: "dictationHistoryEnabled")
    let decoded = try Settings.migrate(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.dictationHistoryEnabled == false)
}

@Test func enabledHistoryRoundTrips() throws {
    var settings = Settings.default
    settings.dictationHistoryEnabled = true
    #expect(try Settings.migrate(JSONEncoder().encode(settings)).dictationHistoryEnabled)
}
```

Add `.dictationHistory("database is read-only")` to the table-driven error test and assert
that `ErrorText.describe` contains both the failure description and a recovery instruction
without echoing any transcript.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --package-path macos --filter 'DictationHistoryEntryTests|SettingsTests|MacomprendoErrorTests'
```

Expected: compilation fails because the history values, preference, and error case do not
exist.

- [ ] **Step 3: Add the minimal Core implementation**

Create the values with these exact shapes:

```swift
enum DictationHistoryKind: String, Codable, Sendable, Equatable {
    case dictation
    case dictationAndRefine
}

struct DictationHistoryEntry: Identifiable, Sendable, Equatable {
    let id: Int64
    let createdAt: Date
    let kind: DictationHistoryKind
    let text: String
}

struct DictationHistoryPage: Sendable, Equatable {
    let entries: [DictationHistoryEntry]
    let nextCursor: Int64?
}
```

Add `dictationHistoryEnabled: Bool` to `Settings`, set it to `false` in `.default`, and
decode it with:

```swift
dictationHistoryEnabled = try c.decodeIfPresent(Bool.self,
                                                forKey: .dictationHistoryEnabled)
    ?? d.dictationHistoryEnabled
```

Add `case dictationHistory(String)` to `MacomprendoError`. Its description must be
`"Dictation history is unavailable: \(reason)"`; its recovery must be
`"Open Dictation History and clear it, or check that Macomprendo can write to Application Support."`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Core macos/Tests/MacomprendoTests/Core
git commit -m "feat(history): add core history contract"
```

### Task 2: SQLite store, paging, and build linkage

**Files:**
- Create: `macos/Sources/Macomprendo/Services/DictationHistoryStore.swift`
- Create: `macos/Tests/MacomprendoTests/Services/DictationHistoryStoreTests.swift`
- Modify: `macos/Package.swift`
- Modify: `macos/project.yml`

**Interfaces:**
- Consumes: Task 1's `DictationHistoryEntry`, `DictationHistoryKind`, `DictationHistoryPage`, and error case.
- Produces: `DictationHistoryStoring` and `SQLiteDictationHistoryStore` with the exact signatures below.

- [ ] **Step 1: Write failing store tests for schema, append, persistence, and paging**

Define a temporary URL helper in the test file and write tests against a real database:

```swift
private func makeStore(maximumEntryCount: Int = 100_000)
    -> (SQLiteDictationHistoryStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("history.sqlite3")
    return (SQLiteDictationHistoryStore(databaseURL: url,
                                        maximumEntryCount: maximumEntryCount), url)
}

@Test func appendPersistsAcrossReopenAndFetchesNewestFirst() async throws {
    let (store, url) = makeStore()
    let first = try await store.append(text: "first", kind: .dictation,
                                       at: Date(timeIntervalSince1970: 1))
    let second = try await store.append(text: "second", kind: .dictationAndRefine,
                                        at: Date(timeIntervalSince1970: 2))
    #expect(first.id < second.id)

    let reopened = SQLiteDictationHistoryStore(databaseURL: url)
    let page = try await reopened.fetchPage(beforeID: nil, limit: 20)
    #expect(page.entries.map(\.text) == ["second", "first"])
    #expect(page.nextCursor == nil)
}

@Test func pagingUsesAnExclusiveInsertionCursor() async throws {
    let (store, _) = makeStore()
    for value in 1...5 {
        _ = try await store.append(text: "\(value)", kind: .dictation,
                                   at: Date(timeIntervalSince1970: 10))
    }
    let first = try await store.fetchPage(beforeID: nil, limit: 2)
    let second = try await store.fetchPage(beforeID: first.nextCursor, limit: 2)
    let third = try await store.fetchPage(beforeID: second.nextCursor, limit: 2)
    #expect(first.entries.map(\.text) == ["5", "4"])
    #expect(second.entries.map(\.text) == ["3", "2"])
    #expect(third.entries.map(\.text) == ["1"])
    #expect(third.nextCursor == nil)
}
```

Also assert invalid `limit` values throw `.dictationHistory`, stored kinds round-trip, and
the parent Application Support directory is created automatically.

- [ ] **Step 2: Run the store tests and verify RED**

Run:

```bash
swift test --package-path macos --filter DictationHistoryStoreTests
```

Expected: compilation fails because the protocol and SQLite actor are absent.

- [ ] **Step 3: Link the system SQLite library**

In the executable target in `Package.swift`, add:

```swift
linkerSettings: [.linkedLibrary("sqlite3")]
```

In the application target dependencies in `project.yml`, add:

```yaml
      - sdk: libsqlite3.tbd
```

- [ ] **Step 4: Implement the protocol and actor-backed store**

Use these exact public signatures:

```swift
protocol DictationHistoryStoring: Sendable {
    func append(text: String, kind: DictationHistoryKind, at: Date) async throws
        -> DictationHistoryEntry
    func fetchPage(beforeID: Int64?, limit: Int) async throws -> DictationHistoryPage
    func clear() async throws
}

actor SQLiteDictationHistoryStore: DictationHistoryStoring {
    static let defaultMaximumEntryCount = 100_000

    init(databaseURL: URL,
         maximumEntryCount: Int = SQLiteDictationHistoryStore.defaultMaximumEntryCount)
}
```

Open lazily so construction cannot fail before the UI can expose recovery. Create the parent
directory, open with `SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX`,
enable foreign keys, require `PRAGMA user_version` to be `0` or `1`, and create version 1 with:

```sql
CREATE TABLE IF NOT EXISTS dictation_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at REAL NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('dictation', 'dictationAndRefine')),
    text TEXT NOT NULL CHECK(length(trim(text)) > 0)
);
PRAGMA user_version = 1;
```

Append the already-trimmed text with a prepared statement inside `BEGIN IMMEDIATE`; trim
retention in that same transaction; commit only after both statements succeed, otherwise
roll back. Page with:

```sql
SELECT id, created_at, kind, text
FROM dictation_history
WHERE (?1 IS NULL OR id < ?1)
ORDER BY id DESC
LIMIT ?2;
```

Fetch `limit + 1` rows, return only `limit`, and set `nextCursor` to the last returned ID
only when the extra row proves more data exists. Centralize SQLite return-code checking and
map every failure to `.dictationHistory` using operation and SQLite message only.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all store tests pass.

- [ ] **Step 6: Commit**

```bash
git add macos/Package.swift macos/project.yml macos/Sources/Macomprendo/Services/DictationHistoryStore.swift macos/Tests/MacomprendoTests/Services/DictationHistoryStoreTests.swift
git commit -m "feat(history): persist entries in sqlite"
```

### Task 3: Retention, clear recovery, and concurrent store access

**Files:**
- Modify: `macos/Sources/Macomprendo/Services/DictationHistoryStore.swift`
- Modify: `macos/Tests/MacomprendoTests/Services/DictationHistoryStoreTests.swift`

**Interfaces:**
- Consumes and preserves all Task 2 signatures.
- Produces: strict count retention, explicit reset-on-clear, and lossless actor serialization.

- [ ] **Step 1: Add failing retention and concurrency tests**

```swift
@Test func appendTrimsTheOldestEntryInTheSameCommit() async throws {
    let (store, _) = makeStore(maximumEntryCount: 3)
    for value in 1...4 {
        _ = try await store.append(text: "\(value)", kind: .dictation,
                                   at: Date(timeIntervalSince1970: Double(value)))
    }
    let page = try await store.fetchPage(beforeID: nil, limit: 10)
    #expect(page.entries.map(\.text) == ["4", "3", "2"])
    #expect(SQLiteDictationHistoryStore.defaultMaximumEntryCount == 100_000)
}

@Test func simultaneousAppendsLoseNoEntries() async throws {
    let (store, _) = makeStore(maximumEntryCount: 500)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for value in 0..<200 {
            group.addTask {
                _ = try await store.append(text: "entry \(value)", kind: .dictation,
                                           at: Date(timeIntervalSince1970: Double(value)))
            }
        }
        try await group.waitForAll()
    }
    #expect(try await store.fetchPage(beforeID: nil, limit: 500).entries.count == 200)
}
```

Add tests proving `clear()` leaves an empty usable store, remains idempotent, and can reset a
database whose `user_version` is `2`. Create the future-schema fixture with a test-only raw
SQLite helper, then assert fetch throws before clear and append succeeds after clear.

- [ ] **Step 2: Run focused tests and verify RED**

Run the Task 2 focused command. Expected: retention, reset, or concurrency tests fail with
more rows than allowed or an unrecoverable schema error.

- [ ] **Step 3: Implement transactional retention and explicit reset**

Within the append transaction, delete rows older than the newest configured count using the
indexed integer ID order. Reject a non-positive `maximumEntryCount` as a history error.

For healthy databases, `clear()` executes `DELETE FROM dictation_history` and resets the
sequence in one transaction. If opening or schema validation fails, `clear()` closes any
connection, removes the database plus `-wal` and `-shm` sidecars, then opens and creates a
fresh version-1 database. This destructive recovery is called only after UI confirmation.

- [ ] **Step 4: Run focused and Core tests and verify GREEN**

```bash
swift test --package-path macos --filter 'DictationHistoryStoreTests|MacomprendoErrorTests'
```

Expected: all selected tests pass under Swift 6 concurrency checking.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Services/DictationHistoryStore.swift macos/Tests/MacomprendoTests/Services/DictationHistoryStoreTests.swift
git commit -m "feat(history): enforce retention and recovery"
```

### Task 4: Shared history feature controller

**Files:**
- Create: `macos/Sources/Macomprendo/Features/DictationHistoryController.swift`
- Create: `macos/Tests/MacomprendoTests/Features/DictationHistoryControllerTests.swift`
- Create: `macos/Tests/MacomprendoTests/Fakes/FakeDictationHistoryStore.swift`

**Interfaces:**
- Consumes: Task 2's storage protocol and Task 1's values/error.
- Produces: one `@MainActor` controller shared by dictation flows and the history window.

- [ ] **Step 1: Create a configurable fake and failing controller tests**

The fake is an actor implementing the protocol. It records append arguments, serves scripted
pages, counts clear calls, and can throw a configured `MacomprendoError` per operation.

Test these exact behaviors:

```swift
@Test @MainActor func disabledRecordingDoesNotTouchTheStore() async {
    let store = FakeDictationHistoryStore()
    let controller = makeController(store: store, enabled: false)
    #expect(await controller.record(text: "hello", kind: .dictation) == nil)
    #expect(await store.appendRequests.isEmpty)
}

@Test @MainActor func enabledRecordingTrimsAndAppendsOnce() async {
    let store = FakeDictationHistoryStore()
    let controller = makeController(store: store, enabled: true)
    #expect(await controller.record(text: "  hello \n", kind: .dictation) == nil)
    #expect(await store.appendRequests.map(\.text) == ["hello"])
}

@Test @MainActor func copyWritesTheCompleteTranscript() {
    let pasteboard = FakePasteboard()
    let controller = makeController(pasteboard: pasteboard)
    controller.copy(DictationHistoryEntry(id: 1, createdAt: .now,
                                          kind: .dictation, text: "full text"))
    #expect(pasteboard.readString() == "full text")
}
```

Also test initial page replacement, next-page append without duplicates, no second load while
one is active, clear empties state and resets the cursor, empty-text rejection, and append,
fetch, and clear failures becoming persistent `errorMessage` values without throwing to the
caller.

- [ ] **Step 2: Run tests and verify RED**

```bash
swift test --package-path macos --filter DictationHistoryControllerTests
```

Expected: compilation fails because the controller and fake do not exist.

- [ ] **Step 3: Implement the controller**

Use this state and API:

```swift
@MainActor
final class DictationHistoryController: ObservableObject {
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var copiedEntryID: Int64?

    init(store: any DictationHistoryStoring,
         pasteboard: any PasteboardProtocol,
         isEnabled: @escaping @MainActor () -> Bool,
         pageSize: Int = 100,
         now: @escaping @Sendable () -> Date = Date.init)

    func record(text: String, kind: DictationHistoryKind) async -> MacomprendoError?
    func loadInitial() async
    func loadNextPage() async
    func clear() async
    func copy(_ entry: DictationHistoryEntry)
    func cancelLoading()
}
```

`record` checks the current enabled closure, trims/rejects blank text, awaits exactly one
append, and returns the mapped error without throwing. Page loads use one cancellable task or
generation token so a stale load cannot append after `clear`/reload. `copy` writes directly
and briefly marks the copied row. Error messages use `ErrorText.describe`.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Step 2 command. Expected: all controller tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/DictationHistoryController.swift macos/Tests/MacomprendoTests/Features/DictationHistoryControllerTests.swift macos/Tests/MacomprendoTests/Fakes/FakeDictationHistoryStore.swift
git commit -m "feat(history): add shared history controller"
```

### Task 5: Record accepted direct dictations

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/DictationController.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/DictationControllerTests.swift`

**Interfaces:**
- Consumes: Task 4's `DictationHistoryController.record(text:kind:)`.
- Produces: one history append per accepted direct transcript, independent of insertion outcome.

- [ ] **Step 1: Extend the test harness and add failing behavior tests**

Give the harness a `FakeDictationHistoryStore`, construct the shared history controller with
an enabled flag, and inject it into `DictationController`. Add tests proving:

```swift
@Test func acceptedTranscriptIsRecordedBeforeInsertion() async throws {
    let rig = makeHarness(historyEnabled: true, transcript: "  recorded text \n")
    rig.controller.handle(.keyDown(.dictate))
    try await waitFor { rig.controller.state == .recording }
    rig.controller.handle(.keyUp(.dictate))
    try await waitFor { rig.controller.state == .idle }
    #expect(await rig.historyStore.appendRequests.map(\.text) == ["recorded text"])
    #expect(await rig.historyStore.appendRequests.map(\.kind) == [.dictation])
}
```

Add disabled, blank, provider-error, provider cancellation, explicit cancellation, insertion
failure, and history-store failure cases. The insertion-failure test must still see one history
row. The store-failure test must still see inserted text and a user-visible HUD warning that
contains `Dictation history is unavailable`.

- [ ] **Step 2: Run direct-dictation tests and verify RED**

```bash
swift test --package-path macos --filter DictationControllerTests
```

Expected: compile failure for the missing initializer argument or behavior failure with zero
append requests.

- [ ] **Step 3: Add the unique direct commit point**

Inject `history: DictationHistoryController`. Immediately after the existing trim/non-empty
guard and before `.inserting`, call:

```swift
let historyError = await history.record(text: text, kind: .dictation)
```

Continue insertion regardless. On successful insertion, show the existing success state when
`historyError == nil`; otherwise keep the controller terminal state non-failed but show
`ErrorText.describe(historyError)` as the non-fatal HUD warning. If insertion also fails, keep
the insertion failure as the primary action error and leave the history controller's persistent
error available in the history window. Never log `text`.

- [ ] **Step 4: Run tests and verify GREEN**

Run the Step 2 command. Expected: all direct-dictation tests pass, including existing race and
pasteboard-restoration coverage.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Macomprendo/Features/DictationController.swift macos/Tests/MacomprendoTests/Features/DictationControllerTests.swift
git commit -m "feat(history): record direct dictations"
```

### Task 6: Record Dictate & Refine and wire the shared graph

**Files:**
- Modify: `macos/Sources/Macomprendo/Features/DictationCapture.swift`
- Modify: `macos/Sources/Macomprendo/Features/RefineController.swift`
- Modify: `macos/Sources/Macomprendo/App/AppEnvironment.swift`
- Modify: `macos/Sources/Macomprendo/App/AppModel.swift`
- Modify: `macos/Sources/Macomprendo/App/TextFeatures.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/DictationCaptureTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/RefineControllerTests.swift`
- Modify: `macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift`
- Modify: `macos/Tests/MacomprendoTests/App/AppModelTests.swift`
- Modify: `macos/Tests/MacomprendoTests/App/TextFeaturesTests.swift`

**Interfaces:**
- Consumes: the shared history controller and store protocol.
- Produces: one live SQLite store/controller shared by both microphone paths; no selection or probe recording.

- [ ] **Step 1: Add failing capture and graph tests**

Inject the history controller into `DictationCapture`. Test enabled success records exactly one
`.dictationAndRefine` entry before `onTranscript`; disabled, blank, error, and cancelled flows
record none. Add `onHistoryError: (@MainActor (MacomprendoError) -> Void)?` coverage proving a
store failure still delivers the transcript once and reports a warning once.

In `RefineControllerTests`, prove `.selection("selected")` creates no history entry while a
captured dictation does. In `AppModelTests`/`TextFeaturesTests`, inject one fake store into the
environment and prove both direct Dictate and Dictate & Refine reach that same instance.

- [ ] **Step 2: Run affected tests and verify RED**

```bash
swift test --package-path macos --filter 'DictationCaptureTests|RefineControllerTests|AppModelTests|TextFeaturesTests'
```

Expected: compilation fails for missing history dependencies or the success test observes no
append.

- [ ] **Step 3: Add the capture commit point and warning callback**

Inject `history: DictationHistoryController` into `DictationCapture`. After the final
cancellation check and trim/non-empty guard, call:

```swift
if let error = await history.record(text: text, kind: .dictationAndRefine) {
    onHistoryError?(error)
}
onTranscript?(text)
```

Set `capture.onHistoryError` in `RefineController` to show a 2.5-second
`ErrorText.describe(error)` toast. Do not put recording logic in `beginRefine`, because selection
refine also calls it.

- [ ] **Step 4: Wire one shared live instance**

Add `var dictationHistory: any DictationHistoryStoring` to `AppEnvironment`. In `.live()`,
construct `SQLiteDictationHistoryStore` at Application Support
`Macomprendo/dictation-history.sqlite3`. Add a fake-store parameter/default in
`AppEnvironment.fake()`.

In `AppModel.init`, construct and retain:

```swift
let history: DictationHistoryController
```

using `env.dictationHistory`, `env.pasteboard`, and
`{ snapshot.current.dictationHistoryEnabled }`. Pass it to `DictationController`; pass the same
instance through `TextFeatures.live` to `DictationCapture`.

- [ ] **Step 5: Run affected and full feature tests and verify GREEN**

```bash
swift test --package-path macos --filter 'DictationCaptureTests|RefineControllerTests|DictationControllerTests|AppModelTests|TextFeaturesTests'
```

Expected: all selected tests pass and the existing selection-refine tests append nothing.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Macomprendo/App macos/Sources/Macomprendo/Features macos/Tests/MacomprendoTests/App macos/Tests/MacomprendoTests/Features macos/Tests/MacomprendoTests/Fakes/FakeEnvironment.swift
git commit -m "feat(history): record refined dictation transcripts"
```

### Task 7: Preference, conditional menu command, and history window

**Files:**
- Create: `macos/Sources/Macomprendo/UI/History/DictationHistoryView.swift`
- Modify: `macos/Sources/Macomprendo/UI/MenuBar/MenuBarView.swift`
- Modify: `macos/Sources/Macomprendo/UI/Settings/GeneralTab.swift`
- Modify: `macos/Sources/Macomprendo/App/MacomprendoApp.swift`
- Modify: `macos/Sources/Macomprendo/Features/DockIconCoordinator.swift`
- Modify: `macos/Tests/MacomprendoTests/Features/DockIconCoordinatorTests.swift`
- Modify: `macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift`

**Interfaces:**
- Consumes: `AppModel.history`, `Settings.dictationHistoryEnabled`, and `Icon(.copy)`.
- Produces: conditional menu access and one paged, accessible history window.

- [ ] **Step 1: Add failing pure-state tests**

Extend `DockIconCoordinatorTests` with `.history` ownership alongside Settings/Onboarding:

```swift
@Test @MainActor func historyKeepsDockVisibleUntilTheLastWindowCloses() {
    let policy = FakeActivationPolicy()
    let coordinator = DockIconCoordinator(policy: policy)
    coordinator.open(.settings)
    coordinator.open(.history)
    coordinator.close(.settings)
    #expect(policy.visibilityChanges == [true])
    coordinator.close(.history)
    #expect(policy.visibilityChanges == [true, false])
}
```

Extract a small internal computed label/visibility helper only if needed for
`MenuBarLabelTests`; assert the history command is visible exactly when
`dictationHistoryEnabled` is true. Do not add a third-party view-testing dependency.

- [ ] **Step 2: Run UI-adjacent tests and verify RED**

```bash
swift test --package-path macos --filter 'DockIconCoordinatorTests|MenuBarLabelTests'
```

Expected: `.history` or the menu visibility contract is absent.

- [ ] **Step 3: Add the preference and conditional menu command**

In General > Dictation add:

```swift
Toggle("Save dictation history", isOn: $model.settings.dictationHistoryEnabled)
Text("Stores transcribed text locally. Audio is never saved.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

Add `@Environment(\.openWindow)` to `MenuBarView`. When enabled, show
`Button("Dictation History…")` that activates `NSApp` and calls
`openWindow(id: "dictation-history")`. When disabled, emit no menu row.

- [ ] **Step 4: Build the paged history view**

Create a newest-first `List` over `controller.entries`. Each row shows a localized
date/time, source label, bounded transcript preview, and:

```swift
Button { controller.copy(entry) } label: {
    Label { Text("Copy") } icon: { Icon(.copy, size: 14) }
}
.buttonStyle(.borderless)
.help("Copy the complete transcript")
```

When the last row appears and `hasMore` is true, call `loadNextPage()`. Show ProgressView,
empty content, and persistent `errorMessage` banner as appropriate. Add a toolbar
**Clear History…** button with a destructive confirmation dialog; only the confirmed action
calls `await controller.clear()`.

- [ ] **Step 5: Add the single-instance Window scene and Dock ownership**

Add `.history` to `DockIconCoordinator.Owner`. In `MacomprendoApp.body`, add:

```swift
Window("Dictation History", id: "dictation-history") {
    DictationHistoryView(controller: model.history)
        .onAppear {
            model.dockIcon.open(.history)
            Task { await model.history.loadInitial() }
        }
        .onDisappear {
            model.history.cancelLoading()
            model.dockIcon.close(.history)
        }
}
.defaultSize(width: 720, height: 560)
```

Keep the already-open window alive if the preference is disabled; only the menu command
disappears.

- [ ] **Step 6: Run tests and compile**

```bash
swift test --package-path macos --filter 'DictationHistoryControllerTests|DockIconCoordinatorTests|MenuBarLabelTests'
swift build --package-path macos
```

Expected: tests pass and the app compiles with no new warnings.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Macomprendo/UI macos/Sources/Macomprendo/App/MacomprendoApp.swift macos/Sources/Macomprendo/Features/DockIconCoordinator.swift macos/Tests/MacomprendoTests/Features/DockIconCoordinatorTests.swift macos/Tests/MacomprendoTests/UI/MenuBarLabelTests.swift
git commit -m "feat(history): add history window and controls"
```

### Task 8: Privacy/docs, generated project, and end-to-end verification

**Files:**
- Modify: `PRIVACY.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/SMOKE_TEST.md`
- Modify: `macos/Macomprendo.xcodeproj/project.pbxproj` (generated)
- Modify only if implementation differs: `docs/superpowers/specs/2026-09-01-dictation-history.md`

**Interfaces:**
- Consumes: the completed feature behavior.
- Produces: accurate user/privacy documentation, regenerated Xcode project, and final verification evidence.

- [ ] **Step 1: Update user and architecture documentation**

In `PRIVACY.md`, replace the statement that transcripts are never stored with the exact
opt-in behavior: off by default; text only; both dictation actions; local SQLite path; 100,000
limit; disable preserves; Clear removes; no audio; plaintext protected by the macOS account
and FileVault when enabled.

Add a concise feature bullet to README and `CHANGELOG.md` Unreleased. Add the Core value,
storage protocol/actor, controller, and history window to `docs/ARCHITECTURE.md` without
changing layer directions.

- [ ] **Step 2: Extend the smoke-test checklist**

Add manual cases for default-off and persistence, conditional menu visibility, recording
both kinds, exclusion of selection refine/cancel/blank/failure, newest-first paging, complete
row Copy, 100,000 retention using a prepared fixture, Clear confirmation, disabling without
purge, storage-error recovery, single window activation, and Dock icon lifecycle.

- [ ] **Step 3: Regenerate and prove project stability**

```bash
npm run gen
git status --short macos/Macomprendo.xcodeproj/project.pbxproj
npm run gen
git diff --exit-code -- macos/Macomprendo.xcodeproj/project.pbxproj
```

Expected: the first generation includes the new sources and SQLite link; the second is a
no-op.

- [ ] **Step 4: Run the complete definition-of-done verification**

```bash
npm run test:swift
npm run test:scripts
swift build --package-path macos
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: every command exits 0, all tests pass, and no new warnings or whitespace errors are
introduced.

- [ ] **Step 5: Review privacy and transcript leakage**

```bash
rg -n 'Log\.|Logger\.' macos/Sources/Macomprendo | rg -i 'history|transcript|text'
rg -n 'dictationHistory|dictation_history' macos/Sources/Macomprendo PRIVACY.md README.md docs
```

Inspect every match. Expected: no default-level log interpolates entry text, privacy wording
matches the implementation, and only the configured SQLite file persists transcripts.

- [ ] **Step 6: Commit**

```bash
git add PRIVACY.md README.md CHANGELOG.md docs/ARCHITECTURE.md docs/SMOKE_TEST.md docs/superpowers/specs/2026-09-01-dictation-history.md macos/Macomprendo.xcodeproj/project.pbxproj
git commit -m "docs(history): document local transcript storage"
```

### Task 9: Final whole-branch review and fix gate

**Files:**
- Review all files changed since `24c8e36`.
- Modify only files required to address verified review findings.

**Interfaces:**
- Consumes: Tasks 1–8 and the authoritative spec.
- Produces: a reviewer-approved branch with all residual findings either fixed or explicitly ruled non-load-bearing.

- [ ] **Step 1: Generate the complete diff and dispatch a final reviewer**

```bash
git diff --stat 24c8e36..HEAD
git diff --check 24c8e36..HEAD
```

Review for spec compliance, SQLite safety and statement finalization, transaction rollback,
Swift 6 isolation, cancellation races, privacy leakage, menu/window lifecycle, paging
duplicates/gaps, and test quality.

- [ ] **Step 2: Apply one bounded fix round with failing regression tests**

For every accepted defect, first add a focused regression test and observe RED, then apply the
smallest fix and rerun the relevant focused suite. Do not expand product scope.

- [ ] **Step 3: Re-run the complete verification**

Run Task 8 Step 4 again. Expected: all commands exit 0.

- [ ] **Step 4: Commit review fixes if any**

```bash
git add -u
git commit -m "fix(history): address final review findings"
```

Skip the commit only when the final review is clean and `git status --short` has no feature
changes left uncommitted.
