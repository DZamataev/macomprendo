# Hermes Kanban — running agent development on Macomprendo

> On-demand runbook. Read before setting up a multi-agent Kanban run for a
> Macomprendo effort. It records what this repository's constraints do to the
> generic Kanban feature. Generic Hermes documentation lives at
> <https://claude-code.nousresearch.com/docs/user-guide/features/kanban>; this file
> is only the delta.

## When to use it

Use Kanban when the work is a **multi-slice effort that must survive session
restarts** and where slices deserve independent review — a feature spec with
several behaviours, a migration, a research-then-implement chain.

Do not use it for a single change: a normal plan-and-approve session is cheaper.
Do not use `delegate_task` for this shape either — subagents die with the parent
process, so an overnight run loses everything.

## The invariant that shapes everything: one writer per worktree

Git has no cross-process write lock beyond `index.lock`. Two workers editing the
same checkout corrupt each other's staging, and a stale lock blocks everyone.

**Serialize every code-writing card into a single dependency chain.** Make each
card's parent the previous card's last stage, so the dispatcher can never run two
writers at once. Read-only cards (adversarial review) are safe to leave
unchained, but keep them behind the implementation they review.

Throughput is bounded by the chain, not by `max_concurrent_children`.
Parallelism would mean separate worktrees, which this repo rarely needs.

## Workspace: a dedicated worktree, never the operator's checkout

```bash
git worktree add .worktrees/<effort> -b <branch> HEAD
cd .worktrees/<effort>
npm ci                          # Node tooling for scripts/ and the audit
swift build --package-path macos   # warms SwiftPM and downloads the binary targets
```

Warming the build in the coordinating session matters more here than the
equivalent step in a JS repo: `macos/Packages/{WhisperBinary,SherpaOnnxBinary}`
are **binary targets fetched over the network** (whisper.cpp and sherpa-onnx
xcframeworks, tens of megabytes). A worker that hits a cold cache spends its
first turns downloading, and a network failure there reads like a build error.
After warming, a full `swift test` on this machine takes about 7 seconds.

Use `--workspace dir:<absolute path>` on every card. Relative paths are rejected
at dispatch. Do not use `scratch` (deleted on completion) and do not use the
`worktree` kind — the chain needs one shared tree, not a tree per card.

The spec a card implements must already be committed on the worktree's branch.
A worker cannot read a file that only exists in the operator's uncommitted
working tree.

## Role profiles, and why `default` is not enough

Each worker is a separate process with its own conversation, so context freshness
is free. Memory is not: profiles sharing a home share `memories/MEMORY.md`, so an
implementer's note becomes a reviewer's prior knowledge and destroys the
reviewer's blindness.

```bash
hermes profile create <name> --clone-from default --no-alias \
  --description "<what this role does — the decomposer routes on this>"
```

**`--clone-from` copies the memories too.** The generic advice that "memories
diverge from that moment" is true only going forward; the clone starts with every
note the source profile had, including project-specific knowledge from unrelated
repositories. After creating a role profile, **rewrite
`~/.hermes/profiles/<name>/memories/MEMORY.md` down to what that role should
know** — especially for the reviewer, whose whole value is not knowing.

The four roles on this repo:

| Profile | Model | Role |
|---|---|---|
| `macoimpl` | `claude-opus-5` | Writes the failing test, then the implementation |
| `macoreview` | `claude-opus-5` | Adversarial review, blind to intent |
| `macofix` | `claude-sonnet-5` | Applies or evidence-rejects raw findings |
| `macomanager` | `claude-sonnet-5` | Owns the board when a run is unattended |

All four route through the `teamclaude` provider inherited from the default
profile. The reviewer keeps the strongest model deliberately: its job is to catch
a Swift 6 data race or a missed cancellation path, and a reviewer that misses
those produces false confidence, which is worse than no review.

**Set up profiles before creating cards.** A card already `running` cannot be
reassigned (`cannot reassign: currently running`).

Per-role model overrides:

```bash
HERMES_HOME=~/.hermes/profiles/<name> hermes config set model <model>
```

`hermes profile show` keeps reporting the inherited `base_url`, which looks like
the override did not take. **Verify from the agent log, not from `profile show`
and not by asking the model:**

```bash
grep "OpenAI client created" ~/.hermes/profiles/<name>/logs/agent.log | tail -3
```

## Card bodies: what actually has to be in them

A worker knows nothing about your conversation. Everything below has to be in the
card body, or it does not exist.

Repository constraints worth restating on every code card:

- read `AGENTS.md` in the worktree root and the spec the card names before
  editing; the invariants there are not optional;
- **TDD is invariant 3**: the failing test comes first, and the card should ask
  for evidence that it failed (paste the failure) before the implementation;
- everything OS-facing sits behind a protocol with a fake in
  `macos/Tests/MacomprendoTests/Fakes/`;
- Swift 6 strict concurrency: providers are `Sendable`, controllers are
  `@MainActor`, one in-flight task per controller;
- every user-visible failure is a `MacomprendoError` case with
  `errorDescription` and `recoverySuggestion`;
- never log transcript or audio content at default level;
- local commits authorized only when the card says so; **push, PR, merge, rebase,
  reset, amend, revert, force, branch deletion forbidden**;
- `npm run test:swift` is cheap here (about 7 s) — unlike a large JS suite, every
  card can afford to run it, and should;
- record objective blockers instead of guessing.

### Write outcomes, not mechanisms

A card body is the worker's specification, and a worker implements what it says —
including the parts you wrote carelessly. "A row whose file has vanished offers no
control rather than a dead button" sounded reasonable when it was written into a
card here; it produced a Play button that disappeared the moment a recording was
deleted, a test that asserted that disappearance, and a reviewer with no grounds
to object.

State the outcome the user should see and let the worker choose the mechanism:

> A recording the user deleted outside the app must still offer Play, and pressing
> it must say the file is gone. Restoring the file must make playback work again.

That phrasing is checkable, survives a redesign, and would have failed the wrong
implementation on the first run.

### Repo-specific traps to name in the card

- **`AGENTS.md` and `CLAUDE.md` are write-protected.** A card whose work implies
  an edit there blocks on an approval prompt no unattended run can answer. Say so
  up front and have the card report the exact text instead of attempting the
  write. `CLAUDE.md` is a symlink to `AGENTS.md`; never edit it.
- **A new resource directory must be declared twice** (invariant 17): `resources:`
  in `macos/Package.swift` *and* a `type: folder, buildPhase: resources` entry in
  `macos/project.yml`. `swift test` stays green when the second is missing, so the
  card must check both.
- **`macos/project.yml` is the source of truth for the Xcode project.** A card
  that adds files must leave `npm run gen` a no-op, which means running it and
  committing the regenerated `.xcodeproj`. `brew install xcodegen` is a
  prerequisite — verify it exists before assigning such a card.
- **Icons come from `Icon(.case)`** (invariant 12). A card that adds UI must not
  reach for `Image(systemName:)`.
- **Hardware-bound glue is exempt from unit tests** (invariant 3) — AVAudioEngine,
  AX, CGEvent, NSPanel — and belongs in `docs/SMOKE_TEST.md` instead. Say which
  side of that line the slice sits on, or the worker will either over-test glue or
  under-test logic.

## Adversarial review as a card, not a habit

The review stage is worth having only if three properties hold, and all three are
properties of the *card body*:

1. **No author named.** Naming one invites deference.
2. **No intent stated.** Stating it forfeits the reconstruct-intent-from-the-diff
   test.
3. **Findings read raw**, not re-summarized by the implementer before acting.

The reviewer card must instruct: read only the handoff's `START_HEAD`/`END_HEAD`
range and the surrounding source; do not read the spec, the ADR, or the
implementation card; return indexed `F1…` findings with `path:line`, consequence
and a concrete fix; say *zero actionable findings* explicitly when there are none;
modify nothing.

That only works if the implementer's completion summary is **neutral**: hashes,
changed files, verification commands and results, mutation evidence, blockers —
and no explanation of what the change was *for*.

The remediation card is a third role: it reads both the handoff and the raw
findings, applies or evidence-rejects each one, and stops after two failed
attempts on the same finding rather than churning.

## Proving a test actually tests

A green suite proves nothing about a test that cannot fail. Ask code cards for
**mutation evidence**: break the real source until the new assertion fails, paste
the failure, restore, re-run green. On this repo the cheapest form is inverting a
condition or returning a wrong constant from the function under test.

This matters most for the parts of Macomprendo whose failure mode is silence —
retention that deletes nothing, an error that never surfaces, a setting that
round-trips to its default.

### What mutation evidence cannot buy you

A test can be mutation-proof and still assert the wrong rule. Three defects
survived a twelve-finding adversarial review on the first run here, and every one
of them was covered by a passing test:

- the history window did not show a new dictation until it was closed and
  reopened — `append` wrote to the database and never touched the published list;
- the Settings size readout never moved, because it was read once in `.task`;
- deleting a recording in Finder made the Play control **disappear**, because
  playability was decided from a cached directory listing that was pruned on the
  first failed read.

Each had tests. The third had a test that asserted exactly the wrong behaviour —
`aVanishedFileReportsAnErrorAndStopsOfferingTheControl` — written from a card body
that said a vanished file should "offer no control rather than a dead button".
The card was wrong, the implementation matched it, the test locked it in, and the
reviewer had no way to see the mistake because the card was its ground truth.

The lesson is not "write more tests". It is that **a card body's wording becomes
the specification**, and a plausible-sounding phrase in it will be implemented and
then defended by a test. Prefer stating the user-visible outcome ("a recording the
user deleted must still offer Play, and say the file is gone when pressed") over
the mechanism ("hide the control when the file is missing"). And treat any
end-to-end behaviour that only a human can see — a window open while something
else changes it — as un-reviewable by agents: it goes on the smoke test, or it
ships broken.

## Human gates

Anything needing eyes, taste, or an external side effect gets its own card created
with `--initial-status blocked`, so the dispatcher never runs it unprompted. Two
kinds recur here:

- **Judgement gates** — UI acceptance in a real menubar app, audio quality. An
  agent can produce and measure the artifacts; it must not pick.
- **Side-effect gates** — pushing, releasing, anything the outside world sees.

A gate card should carry everything the decision needs: artifact paths, a
verification protocol, and the exact question.

`hermes kanban edit` only backfills a result; it cannot rewrite a body. To turn a
granted gate into an autonomous card, **archive the gate and create a replacement**
carrying the whole procedure, then re-link the chain.

## Telegram notifications

The destination is operator-specific, so it lives in `.env.local` (gitignored;
`.env.example` documents the shape) rather than in this file:

```bash
set -a && . ./.env.local && set +a

hermes kanban --board <board> notify-subscribe <task> \
  --platform telegram \
  --chat-id "$KANBAN_NOTIFY_CHAT_ID" \
  --thread-id "$KANBAN_NOTIFY_THREAD_ID" \
  --user-id "$KANBAN_NOTIFY_CHAT_ID" \
  --chat-type thread --delivery-mode notify
```

Drop `--thread-id` and use `--chat-type dm` for a direct message instead of a
forum topic. Subscribe every card at creation time: a board with no
subscriptions is one you have to poll.

Notification text is hard-truncated in Hermes source, not configurable:

| Event | What reaches you |
|---|---|
| `completed` | the **first line** of the summary, 200 chars |
| `blocked` | `reason`, 160 chars |
| `gave_up` | `error`, 200 chars |
| `crashed`, `timed_out` | no free text at all |

So **block reasons must open with the decision or action required**, naming the
artifact or path, with context after the first 160 characters. Completion
summaries stay neutral despite the truncation — a mechanical opening line
(`START_HEAD … END_HEAD …, N files, gates green`) is the safe compromise.

## Watching a running card

Four levels, cheapest first:

```bash
hermes kanban --board <slug> list      # one line per card
hermes kanban --board <slug> stats     # counts by status and assignee
hermes kanban --board <slug> show <id> # body, comments, events, latest summary
hermes kanban --board <slug> runs <id> # attempts, outcomes, elapsed
hermes kanban --board <slug> log <id> --tail 100
tail -f ~/.hermes/profiles/<profile>/logs/agent.log   # the live transcript
```

The agent log is per **profile**, not per card: two cards sharing a profile
interleave their lines, which is one more reason roles get distinct profiles.

`hermes sessions list -p <profile>` maps cards to session ids (titled
`Work kanban task <id>`); `sessions export <session-id>` dumps the conversation.
Sessions live in the profile's SQLite state, not as loose files.

**You cannot attach to a running worker.** Workers are spawned without a PTY. To
change a running card's course, comment on the card — the text arrives in the
worker's next tool result. The log is read-only.

## Failure modes to expect

**The review card needs its range, and nobody gives it one automatically.** A
reviewer card that names `START_HEAD`/`END_HEAD` has no way to learn them unless
the coordinator comments them on the card, because card bodies are written before
the implementation exists. In the first run on this board the reviewer found only
the previous slice's handoff range, inferred the full branch range itself, and
said so on the card — which worked, but only because it was told to record what it
reviewed. Either comment the range when the last code card completes, or write the
card body to say "review `main..<branch>`" and skip the handshake.

**A card with no `--parent` dispatches immediately.** Dependencies are the only
thing holding a card back. Create the chain parent-first, or block the card in the
same breath as creating it.

**`--json` returns the new id under `id`**, not `task_id`. Reading the wrong key
yields `None`, and follow-up `link` calls fail with `unknown task(s): None` while
the cards themselves exist and dispatch on their own.

**A card body is immutable.** When the facts a card was written against change,
**recreate it** — archive the stale card, create the corrected one, re-link, and
re-subscribe. A correcting comment is worse than it looks: the body is the
assignment, and a worker that never opens the comments follows the stale one.

**Protocol violation.** A worker that exits without calling
`kanban_complete`/`kanban_block` is recorded as `protocol_violation`; the
dispatcher retries up to three consecutive times, then auto-blocks.

**Stale `index.lock`.** A worker that dies mid-commit leaves
`.git/worktrees/<name>/index.lock`. Confirm nobody holds it (`lsof` empty) and
check its timestamp against the run that died before removing it.

**Reassignment during a run is refused.** Plan the role split before dispatch.

**A card created by a worker inherits a scratch workspace, not yours.** Pass
`--workspace dir:/abs/path` explicitly at creation; the CLI wants a scheme, not a
bare path.

## Board bring-up, condensed

```bash
hermes kanban boards create <slug> --name "<name>" \
  --default-workdir <absolute worktree path> --switch

hermes kanban --board <slug> create "<title>" \
  --body "<full standing constraints + this slice's work>" \
  --assignee <role profile> --workspace dir:<abs path> \
  --parent <previous stage> \
  --max-runtime 2h --max-retries 2 \
  --completion-contract local-only \
  --goal --goal-max-turns 30
```

Use `--goal` for open-ended slices where one pass rarely finishes; skip it for
cheap mechanical cards — the per-turn judge is not free. Macomprendo slices are
small and its test suite is fast, so `--max-runtime 2h` is generous here where a
React Native repo would need `6h`.

The dispatcher runs inside the gateway on a 60 s tick;
`hermes kanban --board <slug> dispatch` nudges it immediately.

## What the coordinating session must still do

The chat session does not run between operator messages: there is no polling loop.
Autonomy comes from the dispatcher plus notification subscriptions. For genuinely
unattended supervision, schedule it with `cronjob`.

The coordinator's own jobs, which no worker can do:

- keep the spec current as cards resolve, rather than letting code drift from it;
- verify external side effects independently;
- apply the edits workers are forbidden to make (`AGENTS.md`);
- decide when a surprise finding deserves a new card instead of being absorbed
  silently into an existing slice;
- **carry an operator decision back through every artefact it touches.** A review
  finding can be technically right and still contradict a decision the operator
  already made. On the first run here, the reviewer judged the 90-day retention
  default unsafe for existing installs and the remediation card changed it — a
  sound call in general, and the wrong one for a product whose only user is the
  operator. Reverting it meant touching the source, its tests, the changelog, the
  spec, *and* a guard test that asserted the now-cancelled warning existed. Miss
  one and the repository disagrees with itself. When a finding overturns a
  decision rather than fixing a defect, put it to the operator instead of letting
  a card settle it.

## Results from the first run

One feature, six implementation slices, one review, one remediation, one human
gate. Recorded so a later effort can calibrate.

| | |
|---|---|
| Wall-clock, slice 1 start to remediation done | about 90 minutes |
| Fastest slice | 3 minutes (settings model) |
| Review | 12 findings in 17 minutes |
| Tests | 982 → 1064 Swift, 333 → 339 Node |
| Defects the board produced and closed itself | 12 |
| Defects only the operator found, after acceptance | 3 |
| Coordinator interventions | one decision reversal, one changelog fix, three post-acceptance fixes |

The review paid for itself on the first run: it caught that `0700` was applied
only to directories the app actually created, so every upgraded install kept its
transcript database at `0755` — and the test that claimed to cover it passed,
because it built a fresh path under a new UUID. That class of defect (a test that
cannot see the case it names) is exactly what an implementer cannot catch in its
own work.

The three defects it missed are just as instructive, and they share a shape: all
were **states a human sees and a test does not** — a window left open while
something else changes the data, a control whose disappearance is only wrong if
you know what the user expects next. Budget a real acceptance pass on hardware;
it is not a formality after a green board, it is where this class lands.

### Cost accounting

An honest tally for the whole effort, so the next one can be planned rather than
hoped for:

- **Setup is not free.** Four profiles, a worktree, a warmed build, nine card
  bodies and this runbook came before a single line of the feature was written.
  That investment amortises across later efforts on the same repo; it does not
  amortise inside one.
- **The chain, not the worker count, sets the pace.** Six serialized slices ran
  one at a time by construction. More workers would not have been faster.
- **The operator stays in the loop regardless.** One decision the board tried to
  make (retention defaults), one contradiction it created between code and
  changelog, and three defects it could not see. A board is a way to keep
  long-running work moving without a chat session held open — not a way to stop
  reading the diff.
