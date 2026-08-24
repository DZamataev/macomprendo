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
- Menubar menu, General and Hotkeys settings tabs: per-hotkey enable toggles,
  a "Check permissions…" entry that reopens onboarding, a launch-at-login
  toggle backed by `SMAppService` that reconciles with System Settings on
  appear, dictation/insert-method pickers, and shortcut recorders for all
  five hotkeys.
- Models and Dictation settings tabs: download, cancel and delete whisper
  models with live progress and disk-usage totals, and choose between local
  transcription or an endpoint plus spoken language from the Dictation tab.
- Providers settings tab: add, edit and remove LLM/transcription endpoints,
  store and clear their API keys in the Keychain, test a connection's model
  count, and pull an Ollama model with live progress.
- Esc now cancels an in-progress dictation (recording or transcribing), matching
  the HUD's cancel hint.

### Fixed
- The menubar's "Settings…" item now activates the app before opening the
  Settings window, so it reliably comes to the front instead of opening behind
  everything else on an `LSUIElement` app.
- "Check permissions…" now reopens the onboarding wizard on the first step
  that still needs attention instead of wherever it was last left.
