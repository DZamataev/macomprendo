# Macomprendo — agent instructions

Menubar-only macOS app (macOS 14+, Swift 6, SwiftUI + AppKit). Global hotkeys drive
five actions: dictate, dictate & refine, speak selection, summarize selection, refine
selection. Transcription is whisper.cpp locally or an OpenAI-compatible endpoint; refine
and summarize go through Ollama or an OpenAI-compatible chat endpoint.

## Project map

| Path | Contents |
|---|---|
| `macos/Sources/Macomprendo/App` | `@main`, `AppModel` (owns `Settings`), `AppEnvironment` (composition root) |
| `macos/Sources/Macomprendo/Core` | `Settings`, `SettingsStore`, `Endpoint`, `KeychainStore`, `MacomprendoError`, `Log`, `Pasteboard` |
| `macos/Sources/Macomprendo/Services` | OS-facing protocols + default implementations (hotkeys, audio, AX, paste, speech, models, permissions) |
| `macos/Sources/Macomprendo/Providers` | `HTTPClient`, LLM and transcription providers, stream parsers, `WAVEncoder` |
| `macos/Sources/Macomprendo/Features` | `@MainActor` controllers with explicit state enums; `Prompts/` holds `PromptPreset`, the renderer and `FactoryPresets`, whose `Factory/` subfolder has one content file per language |
| `macos/Sources/Macomprendo/UI` | MenuBar, Settings tabs (General, Hotkeys, Dictation, Speech, Refine & Summarize, Providers), Quick Panel, Recording HUD, Onboarding, Components |
| `macos/Sources/Macomprendo/Resources/Icons` | Vendored Phosphor SVGs + `icons.json` + their MIT licence |
| `macos/Packages/{WhisperBinary,SherpaOnnxBinary}` | Local SwiftPM wrappers for the deliberately vendored whisper.cpp and sherpa-onnx xcframeworks |
| `macos/Tests/MacomprendoTests` | swift-testing tests mirroring the source tree; `Fakes/` holds protocol doubles |
| `scripts/` | Node ≥ 20 ESM tooling; `lib/` holds shared helpers; `__tests__/` holds `node:test` tests |
| `docs/` | `ARCHITECTURE.md`, `SMOKE_TEST.md`, `DECISIONS/ADR-*.md`, `superpowers/{specs,plans}` |
| `DISTRIBUTING.md` | Signing, notarization, and releasing — the operator-facing counterpart to `scripts/` |

## Commands

```bash
npm run test:swift     # swift test --package-path macos
npm run test:scripts   # node --test 'scripts/__tests__/**/*.test.mjs'
npm run gen            # xcodegen generate --spec macos/project.yml
npm run sync-agents    # repair the AGENTS.md / skills symlinks
npm run sync-icons     # vendor the Phosphor SVGs listed in Resources/Icons/icons.json
npm run icon           # regenerate the placeholder macos/AppBundle/AppIcon.icns
npm run reset-permissions  # clear this app's Accessibility/Microphone TCC grants
swift build --package-path macos
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo \
  -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

`brew install xcodegen` is a prerequisite for `npm run gen`.

## Invariants

1. **Layers point downward only.** UI → Features → Services/Providers → Core. Core
   imports nothing from the layers above it. Never construct a concrete service outside
   `AppEnvironment`.
2. **Everything OS-facing sits behind a protocol** declared next to its default
   implementation, so controllers are unit-testable with fakes from `Tests/…/Fakes`.
3. **TDD.** Write the failing test first. Hardware-bound glue (AVAudioEngine, AX,
   CGEvent, whisper C calls, NSPanel) stays thin and is covered by `docs/SMOKE_TEST.md`
   instead.
4. **The pasteboard is always restored** after a simulated ⌘C/⌘V — snapshot first,
   restore after 300 ms, and skip the restore if `changeCount` moved in the meantime.
5. **Secrets never leave the Keychain.** `Settings` stores `apiKeyRef` (a Keychain
   account name), never the key. Keys must not appear in logs, settings exports, or
   error text.
6. **Never log transcript or LLM text at default level.** Use `Log.<category>.debug`
   with `privacy: .private` if you must.
7. **Swift 6 strict concurrency.** Providers are `Sendable` structs or actors;
   controllers are `@MainActor`; one in-flight task per controller and a new hotkey
   press cancels the previous one.
8. **Every failure becomes a `MacomprendoError`** with `errorDescription` and
   `recoverySuggestion`; nothing fails silently.
9. **No telemetry, no network calls** other than the endpoints the user configured and
   explicit model downloads.
10. **`macos/project.yml` is the source of truth** for the Xcode project. Edit it, then
    run `npm run gen` and commit the regenerated `.xcodeproj`.
11. **`AGENTS.md` is the source of truth** for agent instructions. Edit it, never
    `CLAUDE.md` (a symlink). Skills live in `.agents/skills/`, never `.claude/skills`.
12. **Icons come from `Icon(.case)`.** Never write `Image(systemName:)` in a view. To add
    an icon, add it to `macos/Sources/Macomprendo/Resources/Icons/icons.json`, run
    `npm run sync-icons`, add the `AppIcon` case and its `fallbackSymbol`, and commit the
    SVG. The menubar status item is the one deliberate exception: it must be an SF Symbol
    template image.
13. **Vendored xcframeworks are upgraded deliberately.** whisper.cpp and sherpa-onnx are
    binary targets: record their release artefact and checksum, re-run framework discovery,
    and verify local transcription after every upgrade.

## How to…

| Task | Skill |
|---|---|
| Understand the layering before changing anything | `macomprendo-architecture` |
| Build, test, regenerate the project, run the app | `macomprendo-build-test` |
| Add an LLM or transcription provider | `macomprendo-add-provider` |
| Add a hotkey-driven feature | `macomprendo-add-hotkey-feature` |
| Cut a release | `macomprendo-release` |
| Write or change a Node script | `macomprendo-scripts` |

Skills live in `.agents/skills/macomprendo-*/SKILL.md`.

## Definition of done

- [ ] A failing test existed before the implementation, and now passes.
- [ ] `npm run test:swift` and `npm run test:scripts` are both green.
- [ ] `swift build --package-path macos` produces no new warnings.
- [ ] New OS-facing code sits behind a protocol and has a fake in `Tests/…/Fakes`.
- [ ] New user-visible failures are `MacomprendoError` cases with recovery text.
- [ ] `macos/project.yml` and the committed `.xcodeproj` agree (`npm run gen` is a no-op).
- [ ] `CHANGELOG.md` `Unreleased` mentions anything user-visible.
- [ ] The commit message is a conventional commit.

## Planning convention

Specs live in `docs/superpowers/specs/YYYY-MM-DD-<name>.md`, plans in
`docs/superpowers/plans/YYYY-MM-DD-NN-<name>.md`, architecture decisions in
`docs/DECISIONS/ADR-000N-<slug>.md`. Write the spec, then the plan, then the code —
and update the spec rather than letting the code drift away from it.
