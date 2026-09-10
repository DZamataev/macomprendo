---
title: Dictation and text tools that stay on your Mac
description: A menubar-only macOS app for dictation, speech, refinement and summarization. Runs offline with your own models, or through any endpoint you configure. Free, MIT, no account, no telemetry.
output: index.html
layout: home
groupSections: true
---

# Your models. Your keys. Your machine.

Macomprendo is a menubar-only macOS app that turns speech into text and reshapes the text you
already have. Transcription runs **on your Mac** with whisper.cpp or GigaAM. Speech synthesis
runs on your Mac too. Refinement and summarization go to your local Ollama — or to any
endpoint you choose.

No account. No subscription. No telemetry. No update pinging. Open source, and the code is on
GitHub.

- [**Download for macOS**]({{downloadURL}}) — version {{version}}, universal, Developer ID
  signed, notarized
- Verify it first: `shasum -a 256 -c Macomprendo-{{version}}-macos.zip.sha256`
  ([checksum]({{checksumURL}}))

Requires macOS 14 or newer. Apple silicon and Intel.

## Five hotkeys

- **Dictate** — hold, speak, release. The text lands in whatever you were typing into.
- **Dictate & Refine** — same capture, then a panel showing the raw transcript beside an
  LLM-cleaned version. Pick the one you want.
- **Speak selection** — reads the selected text aloud, switching voices per language when a
  passage mixes them.
- **Summarize selection** — a streamed summary you can copy or paste over the original.
- **Refine selection** — rewrite what you have already written, using your own prompt presets.

All five are rebindable, and the middle mouse button can drive one of them.

## Offline

Whisper models from `tiny` to `large-v3-turbo` run in-process with Metal. GigaAM handles
Russian. Piper and Kokoro voices synthesise speech locally. Download a model once and the
audio never leaves the machine again.

## Private

Audio and text go only where you send them. API keys live in the login Keychain, never in
settings, logs or exports. Dictation history is off by default and, when enabled, stays in a
local database. Transcripts are never written to the system log.

## Open source

Built in the open and released by a GitHub Actions workflow whose runs you can read. The
published ZIP is checksummed, signed and notarized before it is attached — the maintainer
never uploads a locally built app. The app's own code is MIT; the distributed build is
GPL-3.0 because of a bundled framework, and the [licensing notice](terms/) says exactly why.

## Yours to configure

Point it at OpenAI, at a self-hosted OpenAI-compatible server, at a proxy, or at Ollama on
`localhost`. Add as many providers as you like and pick a different model for each feature.
Rewrite the prompt presets, or add your own.
