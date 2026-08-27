# ADR-0007: whisper.cpp is consumed as a prebuilt xcframework

## Status

Accepted — 2026-08-23

## Context

The obvious approach — adding `https://github.com/ggml-org/whisper.cpp` as a SwiftPM dependency —
does not work for this project. The upstream repository's `Package.swift` is oriented at Xcode
builds and does not resolve cleanly under plain `swift build`, which is the command this project
relies on for `swift test`, for the per-architecture release build, and for CI. Compiling ggml
from source would also mean owning its build flags, Metal shader packaging, and compile times on
every machine and every CI run.

whisper.cpp publishes an official `whisper-v1.9.2-xcframework.zip` release artifact containing
prebuilt slices for every Apple platform, with the Metal resources already packaged inside.

## Decision

whisper.cpp is vendored as that official xcframework and exposed through a local SwiftPM package
at `macos/Packages/WhisperBinary`, declared as a `binaryTarget`. `WhisperCppTranscriber` links
against it exactly as it would against a source build.

## Consequences

- `swift build`, `swift test`, and the release build all work with no Xcode-only steps.
- There are **no ggml Metal resource bundles to copy** into the app; the Metal resources travel
  inside the xcframework. `scripts/build-app.mjs` therefore discovers what SwiftPM actually emits
  next to the executable (`*.bundle` for our own target's resources, `*.framework` only if the
  slices are dynamic) rather than assuming a fixed list.
- Upgrading whisper.cpp is a deliberate act: download the new release artifact, replace the
  xcframework, re-run the discovery step in DISTRIBUTING.md, and verify transcription still works.
- The binary is committed or fetched as a release artifact rather than built, so its provenance
  must be recorded (version and checksum) alongside the package manifest.
- If a future upstream release ships a `swift build`-compatible `Package.swift`, this decision can
  be revisited; nothing above the `TranscriptionProvider` protocol would change.
