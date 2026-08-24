---
name: macomprendo-build-test
description: Use when building, testing, regenerating the Xcode project, or running the Macomprendo app locally — the exact commands, what each one is for, and how to read the failures.
---

# Building and testing Macomprendo

## Prerequisites

```bash
brew install xcodegen   # 2.46 or newer
npm ci                  # installs picocolors, writes node_modules/
```

Xcode 16 or newer (Swift 6.0). Check with `swift --version`.

## The commands

| Command | What it does |
|---|---|
| `npm run test:swift` | `swift test --package-path macos` — the authoritative unit-test run |
| `npm run test:scripts` | `node --test 'scripts/__tests__/**/*.test.mjs'` |
| `swift build --package-path macos` | Compiles the app target; fastest feedback loop |
| `npm run gen` | Regenerates `macos/Macomprendo.xcodeproj` from `macos/project.yml` |
| `npm run icon` | Regenerates the placeholder `macos/AppBundle/AppIcon.icns` |
| `npm run sync-agents` | Repairs the `CLAUDE.md` and `.claude/skills` symlinks |
| `npm run sync-icons` | Re-vendors the Phosphor SVGs after editing `Resources/Icons/icons.json` |

The **first** Swift build downloads a ~54 MB prebuilt `whisper.xcframework` from the
whisper.cpp GitHub release and takes roughly 10 seconds longer than usual. Metal shaders
are already compiled into that binary, so nothing is built from C++ source. If the
download fails, `swift package resolve --package-path macos` retries it.

## Running the app

```bash
npm run gen
xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
open build/Build/Products/Debug/Macomprendo.app
```

The app is `LSUIElement`, so it has no Dock icon and no window: look for the waveform
in the menu bar. `pkill -f Macomprendo.app` stops it.

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
| `MODULE_NOT_FOUND` from `node --test` | The glob lost its quotes; Node must expand it, not the shell |
| `everyIconHasAVendoredSVG` fails | An `AppIcon` case has no SVG: add it to `Resources/Icons/icons.json` and run `npm run sync-icons` |
| An icon renders as an SF Symbol instead of Phosphor | The SVG is missing from the built bundle — check the `resources:` entry in `Package.swift` and the folder reference in `project.yml` |
| xcodebuild cannot find a package | Run `npm run gen` after editing `macos/project.yml` |
