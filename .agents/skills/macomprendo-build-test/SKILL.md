---
name: macomprendo-build-test
description: Use when building, testing, regenerating the Xcode project, or running the Macomprendo app locally — the exact commands, what each one is for, and how to read the failures.
---

# Building and testing Macomprendo

## Prerequisites

```bash
brew install xcodegen gitleaks  # project generation + working-tree/history secret scans
npm ci                         # installs picocolors, writes node_modules/
```

Xcode 16 or newer (Swift 6.0). Check with `swift --version`.

## The commands

| Command | What it does |
|---|---|
| `npm run test:swift` | `swift test --package-path macos` — the authoritative unit-test run |
| `npm run test:scripts` | `node --test scripts/__tests__/*.test.mjs` |
| `npm run audit` | Repository safety checks plus Gitleaks scans of the working tree and Git history |
| `npm run install-app:signed` | Builds, signs, installs, and opens the normal local test app without invalidating TCC grants |
| `swift build --package-path macos` | Compiles the app target; fastest feedback loop |
| `npm run gen` | Regenerates `macos/Macomprendo.xcodeproj` from `macos/project.yml` |
| `npm run icon` | Regenerates the placeholder `macos/AppBundle/AppIcon.icns` |
| `npm run sync-agents` | Repairs the `CLAUDE.md` and `.claude/skills` symlinks |
| `npm run sync-graph` | Copies the git-ignored `graphify-out/` knowledge graph into this checkout and refreshes it (`--check` to verify only) |
| `npm run sync-icons` | Re-vendors the Phosphor SVGs after editing `Resources/Icons/icons.json` |

The **first** Swift build downloads a ~54 MB prebuilt `whisper.xcframework` from the
whisper.cpp GitHub release and takes roughly 10 seconds longer than usual. Metal shaders
are already compiled into that binary, so nothing is built from C++ source. If the
download fails, `swift package resolve --package-path macos` retries it.

## In a fresh worktree

`graphify-out/` is generated and git-ignored, so `git worktree add` produces a tree with
no knowledge graph. Run this before starting work there:

```bash
npm ci
npm run sync-graph
```

It copies `graph.json`, the extraction cache and the manifest from the checkout that owns
`.git`, installs the ignore rule into the shared `.git/info/exclude` (so a branch whose
`.gitignore` predates that rule still cannot commit the graph), rewrites the recorded scan
root, and runs the AST-only `graphify update` so the graph reflects that branch —
deterministic, offline, no API key, a few seconds. Then ask the graph instead of grepping:

```bash
graphify query "how does a hotkey reach the transcription provider"
graphify path "AppEnvironment" "LocalModelManager"
graphify explain "MacomprendoError"
```

Document, spec and image changes are *not* covered by `graphify update` — those need the
`graphify` skill's `--update` flow, which costs LLM tokens. Run it only when the docs
actually moved.

## Running the app

```bash
npm run install-app:signed
```

Use this command for every local UI and hardware test that does not test the permission flow
itself. Its stable Developer ID signature preserves the existing Microphone and Accessibility
grants across rebuilds. Do not run `npm run reset-permissions` as routine setup. Use it only when
the test explicitly covers first-run permission prompts, denied access, or grant recovery.

The app is `LSUIElement`, so it has no Dock icon and no window. Look for the waveform in the menu
bar. Quit it from that menu before replacing the installation by hand.

To reset its state: `defaults delete com.dzamataev.macomprendo`.

## The unsigned CI build

```bash
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Reading failures

| Symptom | Cause |
|---|---|
| `type 'Bundle?' has no member 'module'` | A dependency ships resources it never declared — it cannot be an SPM dependency |
| `static property … is not concurrency-safe` | Add `@MainActor`, or make the type `Sendable` |
| `requires that 'Settings' conform to 'Scene'` | Our Core `Settings` is shadowing SwiftUI's — write `SwiftUI.Settings` |
| `Could not find '…/*.test.mjs'` or `Cannot find module '…/__tests__'` from `node --test` | The test path was spelled as a Node-expanded glob (broken before v21) or a bare directory (broken on v22); use the shell glob `scripts/__tests__/*.test.mjs` |
| `everyIconHasAVendoredSVG` fails | An `AppIcon` case has no SVG: add it to `Resources/Icons/icons.json` and run `npm run sync-icons` |
| An icon renders as an SF Symbol instead of Phosphor | The SVG is missing from the built bundle — check the `resources:` entry in `Package.swift` and the folder reference in `project.yml` |
| xcodebuild cannot find a package | Run `npm run gen` after editing `macos/project.yml` |
