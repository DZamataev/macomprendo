# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Project foundation: SwiftPM and XcodeGen builds, Core settings/keychain/error
  layer, menubar app shell, Node tooling and CI.
- Providers layer: transcription via a local whisper.cpp model or any
  OpenAI-compatible endpoint; refine and summarize via Ollama or any
  OpenAI-compatible chat endpoint; a whisper model catalog with in-app,
  resumable downloads (checksum-verified once catalog hashes are published).
- The Dictate hotkey now works end-to-end: the app model wires the global
  hotkey service, the recording HUD and the dictation controller together at
  launch and routes hold/toggle key events to them.
- First-launch onboarding: step-by-step permissions (microphone, accessibility),
  model selection and download, and optional Ollama detection. Applies the
  selected model to settings on finish.
