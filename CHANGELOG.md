# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Local TTS can download checksum-pinned Piper and Kokoro archives, extract them atomically, and
  read selections entirely offline through sherpa-onnx; Russian and English Piper voices plus a
  103-speaker multilingual Kokoro model are available in Settings ▸ Speech.
- Local TTS voices are grouped by language and can switch downloaded model-and-speaker selections
  across Russian, English, and Chinese language runs without falling back to
  System speech; a bounded native-handle cache keeps alternating models warm.
- Settings ▸ General can replace direct Dictate recordings shorter than half a second with `OK`
  without loading or calling a speech-recognition provider.
- Local dictation models can stay resident between nearby dictations, with configurable immediate,
  5/10/30-minute, or never-unload policies; cached native contexts are cleared before app exit.
- Settings ▸ General can append one space after text inserted by Dictate or original Dictate &
  Refine, while keeping saved transcripts and refined text unchanged.
- Settings ▸ Hotkeys can bind the middle mouse button to any existing dictation or text action,
  with Hold/Toggle configured independently from keyboard hotkeys.
- `npm run install-app:signed` installs a Developer ID-signed local build, preserving macOS
  Microphone and Accessibility permissions between rebuilds after one permission reset.
- Dictation History entries now have a Refine action that opens the Refine panel with the
  saved transcript.
- The menubar now groups dictation history controls and exposes selectors for the active
  dictation model (with backend prefixes) and translation target.
- Optional local dictation history saves text-only Dictate and Dictate & Refine transcripts,
  capped at 100,000 entries and browsed in a paged window with per-entry copying and a
  confirmed clear action; audio is never saved.
- GigaAM local transcription: four Sber models covering Russian with punctuation, and
  Russian, English, Kazakh, Kyrgyz and Uzbek without it, alongside whisper.cpp.
- Dictation settings now separate backends into sub-tabs with local-model briefs, published
  benchmarks and backend-specific parameters, plus an active-model selector and one readiness
  status for the selected source.
- The recording HUD names the model that will transcribe.
- Dictate & Refine now shows a recording HUD in Toggle mode until the second hotkey press.
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
- Dictation settings tab: choose between local transcription or an endpoint
  plus the spoken language, and download, cancel and delete whisper models
  with live progress and disk-usage totals.
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
- Speech settings tab: pick a default voice grouped by language, map a
  separate voice to each language for mixed-script text (with a toggle to
  turn that switching off), adjust rate, pitch and volume, edit the preview
  text and preview it on demand, and optionally audition a voice with a
  short phrase in its own language as soon as it is selected.
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
- A Dock icon now appears while the onboarding wizard or the Settings window is
  open, and disappears when both are closed, so either window can be brought
  back to the front (⌘Tab, the Dock) instead of vanishing behind other apps
  with no way back except the menubar.
- The Quick Panel can now read its own text aloud: Refine's Original and
  Refined panes and Summarize's summary each get a Speak/Pause/Resume control
  plus Stop while playing, independent of the Speak selection hotkey. Closing
  the panel stops a read the panel started — its controls go with it — while a
  read started with the Speak hotkey keeps its HUD and keeps playing.
- The menubar menu now shows each action's current hotkey beside its
  checkmark; an unbound action reads "not set".
- Refine and Summarize now have a working language, switchable from Settings ▸
  Refine & Summarize and from the Quick Panel's globe menu. Factory prompt
  presets are seeded in English, Russian, Spanish, German, French, Portuguese
  and Chinese — twelve per language, 84 in all, written natively rather than
  translated — including a new "Translate & organize" preset.

### Changed
- Settings ▸ Speech now has an active-source selector with an explicit readiness status above
  three sub-tabs — System voices, Local TTS and Endpoint — matching Settings ▸ Dictation.
  Moving between sub-tabs no longer changes which source speaks.
- The Speak hotkey and the Speech tab's Preview button report why the active source cannot
  speak instead of failing silently or through another source when it is not ready.
- Models are described as file sets, so a model can consist of more than one file.
- The Models tab is gone; speech models are now configured in Settings ▸
  Dictation.
- The four summarize presets now state explicitly that the summary is written
  in the language of the text, instead of leaving it to the model to infer.

### Fixed
- The Settings window no longer clips its own tabs. It is now 760×560 and
  resizable rather than fixed at 640×480: Refine & Summarize carries three
  pickers above a preset list and an editor, and at the old width the tab was
  wider than the window and cut off on both edges.
- Settings ▸ Providers no longer squeezes the endpoint editor into a column a
  few characters wide. The split view gave the endpoint list everything the
  editor did not claim, and the editor had no minimum width to claim any.
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
- Repeated rapid cancel/restart cycles in Dictate & Refine can no longer let
  an older recorder stop tear down the newest recording.
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
