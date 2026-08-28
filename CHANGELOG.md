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
- The remaining four hotkeys now work end-to-end: Dictate & Refine, Refine
  selection and Summarize selection open a floating Quick Panel over a
  streamed LLM response, with Copy/Insert/Replace actions and a live-editable
  instruction field, and Speak selection reads the selection aloud (a second
  press stops it immediately). Refine and Summarize each ship with seeded
  factory prompt presets (Clean up, Formal, Casual, Shorten, Expand, Fix
  grammar, Translate for Refine; Brief, Bullets, TL;DR, Key actions for
  Summarize).
- Speech settings tab: pick a voice grouped by language, adjust rate, pitch
  and volume, and preview the current settings against a sample sentence.
- Speak selection now switches system voices mid-utterance for mixed-script
  text, so a Cyrillic run inside an otherwise Latin sentence (and vice versa)
  is read in a matching installed voice instead of the configured one
  mangling it. Speech settings gained a source picker: alongside System
  voices, an Endpoint source sends the selection to any OpenAI-compatible
  `/v1/audio/speech` server (OpenAI itself, a proxy, or a local server such
  as openedai-speech or Kokoro-FastAPI) with a configurable base URL, model,
  voice and style instructions, and its own API key stored in the Keychain.
- Refine & Summarize settings tab: choose the endpoint and model per feature,
  browse, add, duplicate, reorder, delete and set the default preset for
  each, edit a preset's system prompt and user template with placeholder
  validation shown on selecting or saving a preset, restore deleted factory
  presets, and test a preset against sample text with a live streamed preview.
- Node release toolchain (`scripts/`, Node ≥ 20 ESM): `npm run build` assembles a
  universal, ad-hoc or Developer ID signed `Macomprendo.app`, discovering and copying
  whichever SwiftPM resource bundles and dynamic frameworks the build actually emits;
  `npm run notarize` builds, submits to Apple's notary service, staples the ticket and
  packages a checksummed ZIP; `npm run configure-notary` stores notarization credentials
  in the Keychain without ever putting a password on a command line; `npm run release`
  bumps the version, finalizes `CHANGELOG.md`, runs the full test suite, tags, pushes and
  publishes a GitHub release, optionally attaching a notarized build with `--notarize`;
  `npm run install-app` builds and atomically installs into `/Applications` with a
  restorable backup; `npm run audit` refuses to publish credentials, Xcode user state, or
  machine-specific paths; `npm run reset-permissions` clears the app's Accessibility and
  Microphone grants so the next launch asks again, refusing to run while the app is open.
  All of it is covered by `node:test` unit tests.
- Documentation: this README, `DISTRIBUTING.md`, `docs/ARCHITECTURE.md`,
  `docs/SMOKE_TEST.md`, `PRIVACY.md`, and ADR-0001 through ADR-0008.

### Fixed
- The onboarding permission steps no longer show a stale answer: they re-read
  the permission whenever the app comes back to the front, and a "Check again"
  button re-reads it on demand. macOS shows its permission prompt only once, so
  after the first time the grant button did nothing visible and a permission
  turned on in System Settings was never noticed — the step looked stuck.
- The menubar's "Settings…" item now activates the app before opening the
  Settings window, so it reliably comes to the front instead of opening behind
  everything else on an `LSUIElement` app.
- "Check permissions…" now reopens the onboarding wizard on the first step
  that still needs attention instead of wherever it was last left.
- Dictation no longer gets stuck: a provider-side cancellation (without the
  user pressing Esc) now stops the escape-key monitor and clears the HUD
  instead of leaving it on "Transcribing…" forever.
- The recording level meter and timer no longer go dead for the rest of the
  app's lifetime after a dictation hits the maximum recording length once.
- Cancelling dictation mid-paste can no longer restore your previous
  clipboard before the dictated text has actually been pasted.
- Speak selection now shows a "Speaking…" HUD state with a stop hint for the
  whole utterance, instead of leaving the HUD blank while audio plays.
- A second "Test" run in the Prompts settings tab no longer lets a stale
  first run clear `isTesting` or overwrite the newer run's streamed output.
- Speak selection's script segmentation is asymmetric: a short Cyrillic run next
  to Latin text always gets its own voice switch, instead of sometimes being
  absorbed and read letter-by-letter by an English voice ("Cyrillic letter
  E…"). Only short Latin runs still merge into a neighboring Cyrillic run
  (accented but intelligible), and the merge threshold now counts letters
  only, ignoring attached digits/punctuation.

### Security
- Not sandboxed by necessity (see ADR-0003), but hardened runtime, Developer ID
  signed, notarized and stapled before distribution.
- Pasteboard contents are snapshotted and restored after every simulated ⌘C/⌘V,
  guarded by a change-count check so a copy made during the 300 ms window is
  never clobbered.
- API keys live in the Keychain only; they are never written to `settings.v1`,
  logs, or exported files, and transcripts/LLM text are never logged at the
  default log level.
- `npm run audit` blocks publication of credentials (`.p8`/`.p12`/`.pem`/`.cer`/
  `.key`/`.mobileprovision`, keychains), Xcode user state, notary logs, and
  machine-specific `/Users/<name>` paths, and runs Gitleaks over the working
  tree and git history when it is installed.
