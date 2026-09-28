# Hermes Kanban — multi-agent development on Macomprendo

> Per-repo runbook. Read it before putting a Macomprendo effort on a Hermes Kanban
> board. This repository holds what is specific to it: this file, the role preambles
> in `docs/agents/kanban/` and the settings in `.kanban/config.env`. The method's
> scripts come from the `hermes-kanban-development` skill (see **Stack** below);
> `scripts/kanban-card.sh` is a thin wrapper over its card script. Generic Hermes
> documentation: <https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban>.

Cards run as separate, non-interactive Hermes workers, one role per profile. One
foreground session — the **orchestrator** — plans, feeds the board and lands the
results. It is the board's only supervisor: every card it creates reports back into
it, so there is no watcher script and no cron job to run.

## Stack (required)

This method runs only on:

- **Hermes from the `develop` branch of the fork
  <https://github.com/DZamataev/hermes-agent>.** Upstream Hermes lacks what the
  cards rely on: completion contracts (`local-commit`, `local-commit-or-none`),
  whole summaries and block reasons in the session, delivery that survives the
  orchestrator's context compression, the idle-board line, and a worker's
  question to the orchestrator (`kanban_comment` with `await_reply_minutes`).
- **The kanban scripts and role templates from
  <https://github.com/DZamataev/hermes-tools>** (`kanban/install.sh --force`
  installs them as the `hermes-kanban-development` skill; `$K` below is its
  `scripts/` directory, by default
  `~/.hermes/skills/software-development/hermes-kanban-development/scripts`).

The card scripts refuse to create a card on a Hermes without these features.
After updating either, bring this repository's copy of the role templates up to
date: `python3 $K/kanban-sync.py --apply <this checkout>`, then review and commit
the diff.

## 1. When the board is worth it

Use it for a **multi-slice effort that must survive session restarts** and whose
slices deserve independent review: a spec with several behaviours, a migration, a
research-then-implement chain. Do not use it for a one-session change (a normal
plan-and-approve session is cheaper), for design interviews, or for work whose
acceptance is taste. `delegate_task` is the wrong shape too: subagents die with the
parent process.

| Work item | Goes to |
|---|---|
| product or design question | the foreground session, never a card |
| task with written acceptance checks | an implement → review → fix chain |
| research (read, probe, write one file) | a `research` card, no commits |
| anything needing eyes, ears, hands or credentials | a blocked `gate` card for the operator |

## 2. The pipeline

1. **Spec and plan** in `docs/superpowers/specs/` and `docs/superpowers/plans/`
   (see `AGENTS.md`, "Planning convention"). Design forks are settled with the
   operator in the foreground and land in the spec or an ADR, not in chat.
2. **Task files**, one per card, under `docs/agents/kanban/tasks/<slug>.md`: the
   spec or plan path (the worker reads acceptance from it, not from a paraphrase),
   the non-obvious constraint, the traps of section 7 that apply, and any constant
   that defines a threshold, by symbol and value. **Commit them on the effort's
   branch** — a worker cannot read a file that exists only in the operator's
   uncommitted tree.
3. **Cards**, only through the scripts (section 5).
4. **Landing** by the orchestrator (section 9).

### Write outcomes, not mechanisms

A task file is the worker's specification, and a worker implements what it says —
including the parts written carelessly. "A row whose file has vanished offers no
control rather than a dead button" sounded reasonable in a card here; it produced a
Play button that disappeared the moment a recording was deleted, a test asserting
that disappearance, and a reviewer with no grounds to object. State what the user
should see and let the worker choose the mechanism:

> A recording the user deleted outside the app must still offer Play, and pressing
> it must say the file is gone. Restoring the file must make playback work again.

### Slice by reachable capability

Slice by what becomes **reachable** in the app, not by module. Every producing card
needs a consumer card naming the call sites it converts, or the board goes green
while the feature is unreachable. Before saying "ready to test", check the entry
point (hotkey routing in `AppModel`, the Settings tab) and the default in
`Settings.default` yourself.

## 3. Bring-up

The setup choices are the orchestrator's; report them afterwards.

```bash
# once per machine: the three role profiles (existing ones are kept)
bash $K/kanban-profiles.sh maco
# once per effort: a board, a worktree, a warm build
hermes kanban boards create macomprendo-<effort> --name "Macomprendo — <effort>"
git worktree add -b <effort>/chain .worktrees/<effort> main
cd .worktrees/<effort>
npm ci
npm run sync-graph
swift build --package-path macos && npm run test:swift
```

- **Board.** `.kanban/config.env` names the default board (`KANBAN_BOARD`). For an
  effort on its own board, change it in the worktree's copy of that file and commit
  it on the effort's branch; the scripts read the config of the tree they run from.
- **Profiles before cards.** A claimed card keeps the model it started with, and a
  running card cannot be reassigned. Pin models first (section 4), then create
  cards.
- **Warm the worktree before the first card.** `macos/Packages/{WhisperBinary,
  SherpaOnnxBinary}` are binary targets fetched over the network (tens of
  megabytes). A worker on a cold cache spends its first turns downloading, and a
  network failure there reads like a build error. `graphify-out/` is git-ignored,
  so without `npm run sync-graph` the workers are blind to the knowledge graph;
  rebuilding it from scratch would cost over a million tokens. Re-run
  `sync-graph` after landing into the worktree's base.
- **`xcodegen`** must be installed (`brew install xcodegen`) before any card that
  adds a Swift file: such a card has to leave `npm run gen` a no-op.
- **Notification target** — `KANBAN_NOTIFY_CHAT_ID`, `KANBAN_NOTIFY_THREAD_ID` —
  goes into `.env.local` of the primary checkout (gitignored; `.env.example`
  documents the shape). Never into a tracked file: a chat id names a private group,
  and `npm run audit` refuses to publish one.
- **Verify** after the first chain: `hermes kanban --board <b> list` shows the head
  `running`, `show <child>` has the right `parents:`, `notify-list <id>` shows the
  chat and the session.

## 4. Roles and profiles

| Role | Profile | Preamble | Sees |
|---|---|---|---|
| orchestrator | the foreground session | — | everything; owns the board, the spec, `AGENTS.md`, merges |
| implement | `macoimpl` | `common.md` | the repo, the task, the spec it names |
| research | `macoimpl` | `research.md` | the repo and the web; writes one new file |
| adversarial review | `macoreview` | `review.md` | the diff and the repo's rules — **not** the task, spec, plan or author |
| fix | `macofix` | `fix.md` | the raw findings and the implementation summary |
| gate | the operator | `gate.md` | absolute artifact paths, one command, numbered questions |

- **One profile per role.** Profiles sharing a home share `memories/MEMORY.md`, and
  a reviewer that can read the implementer's notes is not blind.
- `hermes profile create --clone-from` copies `MEMORY.md` **wholesale**, notes from
  unrelated repositories included. `kanban-profiles.sh maco` rewrites every new
  profile's memory to its role before any card runs; `--force-memory` redoes it for
  existing ones.
- **Models are pinned in the profiles, not recorded here** — they change with quota.
  `kanban-profiles.sh maco --model-review <provider>:<model>` pins one;
  `--fallback-<role> <provider>:<model>` writes that profile's `fallback_providers`.
  The rule: **the reviewer runs on a different model family than the author.** A
  weak reviewer that misses a Swift 6 race or a missed cancellation path produces
  false confidence, which is worse than no review. When quota forces one family for
  all roles, the review is a second pass, not an independent one; say so in the
  hand-off.
- Implement and fix profiles get `kanban.worker_fallback: wait`: a quota wall
  requeues the card as `rate_limited` instead of finishing it on a weaker model.
  The reviewer stays on `allow`.
- **Check routing:** `HERMES_HOME=~/.hermes/profiles/<p> hermes config get
  model.default` (configured) and `grep "OpenAI client created"
  ~/.hermes/profiles/<p>/logs/agent.log` (actual — only after a real run).
  `hermes profile show` prints the inherited `base_url` and misleads.
- A config change binds at the next spawn. **Never kill a running worker to apply
  one.**

## 5. Cards

Always through the tool. The role preamble lives in `docs/agents/kanban/`, so a card
can never be created without its prohibitions and its gate.

```bash
# one slice: implement → review → fix, after the previous slice, with an operator gate
python3 $K/kanban-chain.py --title "Microphone picker" \
  --task docs/agents/kanban/tasks/mic-picker.md \
  --workdir "$PWD" --after <previous-fix-id> \
  --gate-task docs/agents/kanban/tasks/mic-picker-gate.md
# a single card (research writes one new file; no worktree needed)
scripts/kanban-card.sh research "Audio device APIs" docs/agents/kanban/tasks/devices.md "$PWD"
```

`kanban-chain.py` prints `impl=… review=… fix=… [gate=…] [session=…]`. `--hold`
creates the chain without releasing it; `--dry-run` prints what it would create.

What the tool guarantees, so you know it when working by hand:

- **Race-free chains.** Every card is created `--initial-status blocked`, its
  parents are read back with `show --json`, and only then are implement, review and
  fix released and the dispatcher nudged. A card whose parent did not resolve would
  otherwise be claimed on the next tick. The gate stays blocked.
- **Every card follows two destinations:** the chat from `.env.local` and the
  orchestrating session (`--platform tui --chat-id $HERMES_SESSION_KEY`). A chain
  whose session subscription did not land is left blocked. `create --json` skips
  Hermes' own auto-subscribe, which is why this is explicit.
- Implement cards carry `--completion-contract local-commit`: the board refuses
  `done` until the tree is clean and HEAD moved since the run started. Fix cards
  carry `local-commit-or-none`: the same, or a clean unmoved tree declared with
  `metadata.no_change` (a review with nothing to apply).
- Bodies go through stdin (`--body-file -`); `--workspace dir:<absolute path>`;
  retries per role and `--max-runtime` come from `.kanban/config.env`.
  Macomprendo slices are small and the suite runs in seconds, so `2h` is generous.
- `create --json` returns the id under **`id`**, not `task_id`; an empty id stops
  the tool instead of producing `--parent None`.

Board mechanics the tool cannot enforce:

- **One writer per worktree.** Cards sharing a workspace are chained; the next
  slice's implement card is parented on the previous slice's fix card. Two workers
  in one checkout corrupt each other's index, and a stale `index.lock` blocks
  everyone. Research cards that each write one *new* file may share the primary
  checkout.
- **A body is frozen at creation.** When a queued card's inputs move, create a new
  card with its own parents and `hermes kanban replace OLD --with NEW`: OLD's
  children and subscriptions move to NEW and OLD is archived in one step (refused
  while OLD is running — block it first). A bare `archive` releases the children.
  Comment only on a running card; a correcting comment longer than the section it
  corrects is the signal to recreate.
- Never keep a board command in a shell variable: zsh (the terminal tool) does not
  word-split it, and every call fails silently.
- `unset HERMES_DELEGATED_CHILD_CONTEXT` before board writes from a session that
  inherited it (the tool does this for its own calls).

## 6. Review and fix

The review is worth having only if the reviewer is blind to intent:

1. no author named — naming one invites deference;
2. no intent stated — the reviewer reconstructs it from the diff;
3. findings read **raw** by the fix card, not re-summarised.

So the implementer's summary is **neutral**: first line exactly
`START_HEAD..END_HEAD, N files, gate: green`, then files, commands and output,
mutation evidence, blockers — nothing about purpose. The reviewer takes its range
from that first line (falling back to `main..HEAD`), runs the gate itself and
**states the range it reviewed**. It returns `F1…` findings with `path:line`,
consequence, fix and severity, and says *zero actionable findings* in words when
there are none.

The fix card applies each finding with a test and a manual mutation check, or
rejects it with proof. A finding that argues with an ADR or the spec, or overturns
a default the operator chose, comes back as **needs decision** — never settled by a
card. (On the first run here, a reviewer judged the 90-day retention default unsafe
and the fix card changed it; reverting that touched the source, its tests, the
changelog, the spec and a guard test.) A symptom-shaped finding is fixed on every
path that produces it. Two failed attempts on one finding: stop and record.
Findings the fixer rejected are the operator's first suspects at acceptance: name
them in the hand-off.

### Proving a test actually tests

Every new guarantee gets a manual mutation check: break the real source line, see
the targeted assertion fail, restore, run green. Here the cheapest form is
inverting a condition or returning a wrong constant. It matters most where
Macomprendo's failure mode is silence: retention that deletes nothing, an error
that never surfaces, a setting that round-trips to its default.

A test can be mutation-proof and still assert the wrong rule. On the first run,
three defects survived a twelve-finding review, each covered by a passing test:
the history window did not show a new dictation until reopened; the Settings size
readout never moved; deleting a recording in Finder made Play **disappear** — with
a test asserting exactly that, written from a card that said so. The card was
wrong, the code matched it, the test locked it in, and the reviewer could not see
it. Treat end-to-end behaviour only a human sees as un-reviewable by agents: it
goes into `docs/SMOKE_TEST.md` and a gate card, or it ships broken.

## 7. Traps specific to this repository

The role preambles repeat these; name the ones that apply in the task file too.

- **`AGENTS.md` and `CLAUDE.md` are write-protected.** An edit there blocks on an
  approval prompt no unattended run can answer. Workers return the exact text; the
  orchestrator applies it. `CLAUDE.md` is a symlink; never edit it.
- **A new resource directory is declared twice** (invariant 17): `resources:` in
  `macos/Package.swift` and a folder entry in `macos/project.yml`. `swift test`
  stays green without the second.
- **`macos/project.yml` is the source of truth** for the Xcode project. A card that
  adds or removes files leaves `npm run gen` a no-op and commits the `.xcodeproj`.
- **Icons come from `Icon(.case)`**, never `Image(systemName:)` (invariant 12).
- **Hardware-bound glue is exempt from unit tests** (invariant 3): AVAudioEngine,
  AX, CGEvent, NSPanel, whisper C calls. The task says which side of that line a
  slice sits on, or the worker over-tests glue or under-tests logic.
- **The suite is timing-sensitive under load.** `waitFor` tests time out when a
  build compiles in the same tree at the same moment; the timeout message reports
  the poll count and suspected starvation. Re-run on an idle tree first.
- **Build outputs have one writer too.** Before building in a worktree yourself,
  check no worker is compiling there (`pgrep -fl 'swift-build|xcodebuild'`).
- **A dead worker leaves `.git/worktrees/<name>/index.lock`.** Remove it only when
  `lsof` shows nobody holding it and its mtime matches a run that has ended.
- **Workers do not inherit the interactive shell.** A toolchain path a card needs
  goes into its task file.

## 8. What agents cannot check here

Route each of these to a gate card with `docs/SMOKE_TEST.md` steps:

- anything on real audio hardware: microphones, device switching, input levels;
- global hotkeys, simulated ⌘C/⌘V, the pasteboard restore, Accessibility and
  microphone permission prompts (TCC);
- panels and HUDs: placement, timing, focus never moving, full-screen apps;
- signing, notarisation, the installed app (`npm run install-app:signed`);
- a window left open while something else changes its data.

A gate card carries absolute artifact paths, one copy-pasteable command (usually
`npm run install-app:signed` in the chain's worktree plus the smoke section) and
numbered questions. The operator's verdict splits three ways, handled in one turn:
accepted parts (complete the gate), a stated design rule (a docs commit on `main`,
now), defects (a new chain and a new gate). `hermes kanban edit` cannot rewrite a
body: to turn a gate into an autonomous card, create the replacement and `replace`.

## 9. Supervising, landing, returning

The orchestrating session supervises the board by being subscribed to every card:
completions (the whole run summary) and blocks arrive in it as turns, and it
verifies, lands and re-plans as they come.

- **Keep the session open** — the desktop tab or TUI — while the board runs,
  overnight included, with the Mac awake.
- **A closed session stops landing, not work.** Cards keep moving along their
  chains; finished chains wait. On return, do the returning pass below first.
- **The Mac asleep stops everything.** Workers resume after wake; a suite that
  timed out across the sleep is re-run, never trusted.
- **One orchestrator per board.** A second session landing the same chains
  duplicates merges.

**Hermes build.** See **Stack**: without the fork a subscription dies at the
orchestrator's first context compaction, a model fallback is silent, `done` is
accepted over an uncommitted tree and the session gets only a summary's first
line. The card scripts check the build before creating anything and refuse
without it.

**Landing a chain** (its fix card is done), in its worktree: clean `git status`,
the gate, and `KANBAN_LAND_CHECKS` of `.kanban/config.env` (`npm run test:scripts`,
`npm run audit`, `swift build --package-path macos` with no new warnings,
`npm run gen` a no-op). Then in the primary checkout `git merge --ff-only
<effort>/chain`, or a merge commit plus the gate again; abort on conflict. **Push
only on the operator's explicit word**, and confirm with `git ls-remote origin
refs/heads/main`. Update the spec where the code moved it.

**Returning to a board** ("status"): `list`, read `Latest summary:` of every card
that finished, land what can be landed, then answer with one line per slice (what
landed, elapsed, findings, tests before → after), gate questions numbered,
rejected findings named. If the next eligible card is a gate, install the build
yourself and still give the command.

## 10. Watching and stopping

```bash
hermes kanban --board <b> list            # one line per card
hermes kanban --board <b> show <id>       # body, comments, events, latest summary
hermes kanban --board <b> runs <id>       # attempts, outcomes, elapsed, fallbacks
tail -f ~/.hermes/profiles/<profile>/logs/agent.log   # the live transcript
hermes sessions export <session-id>       # afterwards
```

You cannot attach to a worker; comment on a running card to steer it (the text
arrives in its next tool result). A worker with a question it cannot settle from
the repo asks on its own card and holds its run for the answer
(`kanban_comment` with `await_reply_minutes`): the session gets a ❓ with the
question and the command to answer, `hermes kanban --board <b> comment <id>
"<answer>"`. Answer from the spec and ADRs; a product question goes to the
operator first. No answer in time is not a failure: the worker proceeds on its
stated default or blocks. The dispatcher reclaims crashed, stale and
protocol-violating workers with bounded retries; do not kill workers by hand —
`block` a card you need stopped. A worker's block reason and an operator's stall
diagnosis are hypotheses: re-run the quoted check and read the board before acting.

Before a reboot: `hermes pause --reason …` (global, stops dispatch only) **and** a
comment on each running card: commit what exists, then `kanban_block` with the
resume point.

Notification text is truncated in Hermes, not configurable:

| Event | Chat | Orchestrating session |
|---|---|---|
| completed | first line of the summary, ~200 chars | the whole run summary, up to 4000 chars, plus `· fallback A → B` |
| blocked | the whole reason, up to 4000 chars | the same; a block the session made itself is not reported back to it |
| question | the whole question and the command to answer | the same, and it wakes the session |
| gave_up | the error, ~200 chars | the same |
| crashed, timed_out | no text | no text |

So block reasons open with the action and the path; completion summaries keep a
mechanical first line.

## 11. Standing authorizations

None recorded yet. When the operator grants one twice, write it here with what it
does **not** cover.

## 12. Calibration from the first run

One feature, six implementation slices, one review, one remediation, one gate.

| | |
|---|---|
| Wall-clock, slice 1 start to remediation done | about 90 minutes |
| Fastest slice | 3 minutes (settings model) |
| Review | 12 findings in 17 minutes |
| Tests | 982 → 1064 Swift, 333 → 339 Node |
| Defects the board produced and closed itself | 12 |
| Defects only the operator found, after acceptance | 3 |

The review paid for itself: it caught that `0700` was applied only to directories
the app created, so every upgraded install kept its transcript database at `0755`,
while the test claiming to cover it passed on a fresh UUID path. The three misses
were all states a human sees and a test does not. Budget a real acceptance pass on
hardware; it is where that class lands.

Cost: setup (profiles, a warm worktree, card bodies) comes before the first line of
the feature and amortises across efforts, not within one. The chain, not the
worker count, sets the pace. The operator stays in the loop regardless — a board
keeps long work moving without a chat held open; it does not replace reading the
diff.
