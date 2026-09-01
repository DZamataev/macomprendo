# Macomprendo

A menubar-only macOS app that turns global hotkeys into dictation, speech, and LLM text
actions. Transcription runs locally with whisper.cpp; refinement and summarization run through
Ollama or any OpenAI-compatible endpoint you configure. No telemetry, no account, no network
call you did not ask for.

Requires macOS 14 or newer. Universal (Apple silicon and Intel). MIT licensed.

## Features

| Action | Default hotkey | What happens |
|---|---|---|
| **Dictate** | ⌥Space | Records while held (or toggles), transcribes locally, pastes into the frontmost app |
| **Dictate & Refine** | ⌥⇧Space | Same capture, then a Quick Panel with the original and an LLM-refined version side by side |
| **Speak selection** | ⌥S | Reads the selected text aloud with a voice you choose; press again to stop |
| **Summarize selection** | ⌥M | Quick Panel with a streamed summary; Copy or Replace the selection |
| **Refine selection** | unassigned | The refine Quick Panel, applied to the current selection |

Other things it does:

- **Local transcription** with whisper.cpp and Metal. Models (`tiny` … `large-v3-turbo`) are
  downloaded on demand and stored in
  `~/Library/Application Support/Macomprendo/models/`.
- **Remote transcription** through any `/v1/audio/transcriptions` endpoint, if you prefer.
- **Optional local dictation history** for text-only Dictate and Dictate & Refine transcripts,
  browsed newest-first in a paged window and capped at 100,000 entries; audio is never saved.
- **Editable prompt presets** for both refine and summarize — Clean up, Formal, Casual,
  Shorten, Expand, Fix grammar, Translate, Brief, Bullets, TL;DR, Key actions — all of which
  you can rename, rewrite, reorder, delete, or add to.
- **Multiple endpoints**: add as many Ollama or OpenAI-compatible providers as you like, test
  the connection from Settings, and pick a different model per feature.

## Install

Download `Macomprendo-<version>-macos.zip` from the
[Releases page](https://github.com/DZamataev/macomprendo/releases), expand it, and drag
`Macomprendo.app` to `/Applications`. Once a release has been through the notarization step
(`npm run release -- --notarize`, see [DISTRIBUTING.md](DISTRIBUTING.md)), the build is signed
with a Developer ID certificate and notarized by Apple, so it opens without a Gatekeeper
warning. A notes-only release has no ZIP attached; build from source instead.

Verify the download if you like:

```sh
shasum -a 256 -c Macomprendo-<version>-macos.zip.sha256
```

### Build from source

```sh
git clone https://github.com/DZamataev/macomprendo.git
cd macomprendo
npm ci
npm run install-app
```

`npm run install-app` builds an ad-hoc signed app for your Mac's own architecture and
installs it into `/Applications`. See [DISTRIBUTING.md](DISTRIBUTING.md) for signed,
notarized, universal builds.

## First run

Onboarding asks for what it needs, and nothing else:

1. **Microphone** — required for dictation.
2. **Accessibility** — required to read the selected text and to paste into other apps. macOS
   grants this in System Settings → Privacy & Security → Accessibility; the app deep-links you
   there.
3. **A whisper model** — `large-v3-turbo` is recommended by default, `base` if you want
   something small and fast.
4. **Ollama** (optional) — checks whether it is running on `http://localhost:11434`; if not,
   it points you to ollama.com or an OpenAI-compatible endpoint instead. Refine and summarize
   default to Ollama's `qwen2.5:1.5b`, pulled from Settings ▸ Providers.

All hotkeys are rebindable in Settings → Hotkeys.

## Privacy

- **No telemetry.** The app contains no analytics, crash reporting, or update pinging.
- **Audio never leaves your Mac** unless you explicitly select a remote transcription endpoint.
- **Text never leaves your Mac** unless you use Refine or Summarize, which send it to the
  endpoint you configured — your local Ollama by default.
- **API keys live in the Keychain only.** They are never written to settings, logs, or exports.
- **Dictation history is opt-in.** When enabled, it stores text locally in SQLite; disabling
  preserves existing entries and Clear History removes them.
- **Transcripts and LLM output are never logged** at the default log level.
- **The clipboard is restored.** Copy/paste simulation snapshots the pasteboard and puts it
  back 300 ms later, guarded by a change-count check so anything you copied meanwhile survives.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layers, protocols, and how they fit together
- [DISTRIBUTING.md](DISTRIBUTING.md) — signing, notarization, releasing
- [docs/SMOKE_TEST.md](docs/SMOKE_TEST.md) — the manual checklist run before every release
- [docs/DECISIONS/](docs/DECISIONS/) — architecture decision records
- [CHANGELOG.md](CHANGELOG.md)

## License

MIT — see [LICENSE](LICENSE). © 2026 Denis Zamataev.
