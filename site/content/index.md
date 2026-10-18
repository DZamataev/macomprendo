---
title: Free offline dictation for every app
description: Turn your voice into text, record calls, transcribe files and listen to selected text on your Mac. Use offline models or your own provider. Free and open source.
output: index.html
layout: home
groupSections: true
---

## Your voice into text

- Offline models: Whisper.cpp, GigaAM and NVIDIA Parakeet.
- Or your own OpenAI-compatible transcription endpoint, such as OpenAI API.
- Whisper supports 90+ languages, including English, Spanish, French, German, Italian, Portuguese, Dutch, Polish, Russian, Ukrainian, Turkish, Chinese, Japanese and Korean. Parakeet covers 25 European languages with punctuation, and multilingual GigaAM also covers Kazakh, Kyrgyz and Uzbek.
- Glossary: switchable packs of your jargon, so `tsconfig json` is pasted as `tsconfig.json` and a word heard as `пайтест` as `pytest`.
- AI refinement: use your own prompts to polish dictation before you paste. Connect Ollama, OpenAI API, OpenRouter or another compatible chat provider.

## Text into speech

- Offline voices: macOS system voices and local TTS models.
- Or your own OpenAI-compatible speech endpoint, such as OpenAI API.
- Mixed-language text: system and local speech switch to your configured voice for each language automatically.
- Local TTS in English, Chinese and Russian, even in the same passage.

## Calls and files into transcripts

- Transcribe File…, or a file dropped on the Transcripts window, turns any audio or video file into text with the model you already set up.
- The Transcripts window keeps every result with timestamps and playback: a seek bar, ±15 s skips, 1× to 2× speed, the playing segment highlighted and followed, and any timestamp to click and play from there.
- Resume an unfinished transcript, Transcribe Again after changing the model, Rename it, or export it as .txt, .srt or .md.
- Summarize a transcript through your own LLM, or Delete it and optionally move its source file to the Trash.
- Record Call from the panel or the Record Call hotkey captures your microphone and everything your Mac plays into two ordinary .m4a files, Me and Others, one folder per call, in a location you choose.
- Stop and it transcribes itself with Me and Others labels in the order each side spoke; mute either side as you play it back.
- A recording survives a quit or a crash and can be resumed after the next launch. Call recording needs macOS 14.2 and the system-audio permission; with local models, no audio leaves your Mac.

## Private

- Airplane ready: download models once, then dictate and listen without internet.
- Local AI: connect Ollama to edit and summarize text or refine your dictation on your Mac.
- API keys stay in Keychain. Optional history stays on your Mac.
- Remote providers receive audio or text only when you choose to use them. [Privacy details](privacy/).

## Free and open source

- No account.
- No subscription.
- No telemetry or usage data collected.
- Local models cost nothing to use. Paid APIs are optional.
- MIT-licensed code. Use it, change it, or vibe-code your own version.
- The distributed app is GPL-3.0 because of a bundled speech component. Models have their own licences. [Source code](https://github.com/DZamataev/macomprendo) and [licences](terms/).
