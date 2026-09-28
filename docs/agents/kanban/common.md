## Standing constraints (read first)

- **Workspace:** `{{WORKDIR}}`. Only that tree; never the operator's checkout or
  another worktree. Its branch already exists. Local commits are **required**
  (the card cannot complete over a dirty tree or an unmoved HEAD). Push, PR,
  merge, rebase, reset, amend, revert, force and branch deletion are
  **forbidden**.
- **Read first:** `{{RULES}}` at the root of the tree, then the ticket, spec or
  plan the task names. Their invariants are not optional. `AGENTS.md` and
  `CLAUDE.md` are write-protected: if your work implies an edit there, put the
  exact text in your summary and do not attempt the write.
- **Gate:** `{{GATE}}` exits 0 and its last line contains `{{GATE_OK}}`. Quote
  the final lines. It takes a few seconds here, so run it after every change.
  Also run `npm run test:scripts` when you touch `scripts/`, and `npm run gen`
  when you add or remove a Swift file (commit the regenerated `.xcodeproj`).
- **TDD (invariant 3):** the failing test comes first; quote the RED output.
  For every new guarantee, a **manual** mutation check: break the real source
  line, run, quote the failure, restore, run green. No helper scripts for
  mutations.
- **Constants** that define a threshold or tolerance come from the source or
  the task, by symbol and value. Never invent a second one.
- **Obstacle** (missing access, an ambiguous acceptance check, a contradiction
  with an ADR or spec): `kanban_block` with a reason that **opens with the
  action required and the path** — the notification shows about 160
  characters. Do not guess a workaround.
- **Finish** only with `kanban_complete`. The summary is **neutral**: first line
  exactly `START_HEAD..END_HEAD, N files, gate: green`, then changed files, the
  commands run with their output, the mutation proofs, blockers. Not a word
  about why the change was made — a blind reviewer reads it next.

### This repository

- Layers point downward only: UI → Features → Services/Providers → Core. Construct
  concrete services only in `AppEnvironment`.
- Everything OS-facing sits behind a protocol with a fake in
  `macos/Tests/MacomprendoTests/Fakes/`.
- Hardware-bound glue (AVAudioEngine, AX, CGEvent, NSPanel, whisper C calls) stays
  thin and goes into `docs/SMOKE_TEST.md`, not unit tests. Say in the summary which
  side of that line the slice sits on.
- Swift 6 strict concurrency: providers are `Sendable` structs or actors,
  controllers are `@MainActor`, one in-flight task per controller.
- Every user-visible failure is a `MacomprendoError` case with `errorDescription`
  and `recoverySuggestion`. Never log transcript, audio or LLM text at default level.
- Icons come from `Icon(.case)`; never `Image(systemName:)` in a view.
- A new resource directory is declared twice: `resources:` in `macos/Package.swift`
  **and** a folder entry in `macos/project.yml`. `swift test` stays green without
  the second.
- `CHANGELOG.md` `Unreleased` mentions anything user-visible.
- **The suite is timing-sensitive under load.** Tests using `waitFor` time out when
  a build compiles in the same tree at the same moment. A `waitFor` timeout reports
  its poll count and says when it suspects CPU starvation; re-run on an idle tree
  before hunting a defect.
- Use `graphify explain "<Symbol>" --graph {{WORKDIR}}/graphify-out/graph.json`
  before a repo-wide grep for a Swift identifier.
- Evidence as you go: append every RED run and every mutation's failing and
  green output to `$TMPDIR/$HERMES_KANBAN_TASK-evidence.log` the moment you get
  it, and build the summary from that file. Your context may be compacted
  before the end; output you did not save is gone. Not in the tree: a stray
  file there fails the clean-tree check at `kanban_complete`.
- Long suites (e2e and the like) run in the background with a completion
  notice and you wait for it: a foreground call hits the tool timeout. While
  one runs, do not touch the tree — no mutations, no edits: a dev server
  reloads on the change and the running tests fail for that reason, not for
  the code. Mutations come after the suite has finished.
- A question only the orchestrator can settle (which of two readings of the
  ticket, a naming or UX choice): ask on your own card and wait —
  `kanban_comment(task_id=$HERMES_KANBAN_TASK, body="<question + the default
  you would pick>", await_reply_minutes=10)`. The reply comes back in `replies`;
  empty means no answer: proceed on the default and note it in the summary, or
  block if you cannot. Do not ask what the repo or the ticket already answers.

## Task
