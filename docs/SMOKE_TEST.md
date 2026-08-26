# Manual smoke test

Run this checklist on a real Mac before every release, and after any change to the audio, permission,
hotkey, paste or HUD code. Unit tests cover the logic; this file covers the parts that need hardware,
TCC permissions and a window server.

**Build under test:** the Xcode Debug build (`⌘R`).
Reset permissions when you want to rehearse a fresh install:
`tccutil reset Microphone com.dzamataev.macomprendo && tccutil reset Accessibility com.dzamataev.macomprendo`

## Dictation (hotkey #1)

| # | Step | Expected |
|---|------|----------|
| 1 | Launch the app for the first time | No Dock icon; a waveform icon appears in the menubar; the Welcome window opens |
| 2 | Click "Allow microphone…" in onboarding | The macOS microphone prompt appears; after allowing, the step shows "Granted." |
| 3 | Click "Allow accessibility…" | The Accessibility prompt appears; after enabling Macomprendo in System Settings and returning, the step shows "Granted." |
| 4 | Choose "Large v3 Turbo" and click Download | Progress advances to 100%, then "Downloaded." |
| 5 | Click "Check for Ollama" (with Ollama running) | "Ollama is running." (with Ollama stopped: the orange "Not found" hint) |
| 6 | Click Finish | Window closes and does not reopen on the next launch |
| 7 | Open TextEdit, click into a document, hold ⌥Space and say "hello world" | HUD appears top-centre of the screen with the mouse, level meter moves, timer counts up |
| 8 | Release ⌥Space | HUD switches to "Transcribing…", then a ✓ that disappears after ~1.2 s; "hello world" is inserted at the caret in TextEdit |
| 9 | Before dictating, copy some text (⌘C), then dictate again | After insertion, ⌘V still pastes your original clipboard text |
| 10 | Dictate, and while the HUD says "Transcribing…" press ⌥Space again | HUD shows "Cancelled"; nothing is inserted |
| 11 | Hold ⌥Space to start recording, then press Esc | HUD shows "Cancelled"; nothing is inserted |
| 12 | Dictate, and while the HUD says "Transcribing…" press Esc | HUD shows "Cancelled"; nothing is inserted |
| 13 | Hold ⌥Space, say nothing, release | HUD shows "Nothing heard"; nothing is inserted |
| 14 | Settings ▸ General: switch to "Press to start, press to stop" | ⌥Space starts recording; a second press stops, transcribes and inserts |
| 15 | Settings ▸ General: set Insert text by = "Typing character by character", dictate into TextEdit | Text is typed rather than pasted; the clipboard is untouched |
| 16 | Settings ▸ Hotkeys: record ⌃⌥D for Dictate, then use it | The new shortcut dictates; ⌥Space no longer does |
| 17 | Menubar menu: switch "Dictate" off, press the hotkey | Nothing happens; switching it back on restores it |
| 18 | Dictate into a full-screen app on a second display | The HUD appears on the screen with the mouse, above the full-screen app, and the text lands in the app |
| 19 | Menubar menu while idle / recording | Status line reads "Ready" / "Recording…" |
| 20 | Settings ▸ Models: delete the downloaded model, then dictate | HUD shows a "model missing" error with recovery text; downloading it again fixes dictation |
| 21 | Settings ▸ Providers: select "Ollama (local)", click "Test connection" | "Connected — N models" (with Ollama stopped: the unreachable error and its recovery text) |
| 22 | Settings ▸ Providers ▸ Ollama: click "Pull qwen2.5:1.5b" | Progress advances and finishes with "Pulled qwen2.5:1.5b" |
| 23 | Settings ▸ Providers: add an OpenAI-compatible endpoint, type an API key, click "Save key", quit and relaunch | The key is still there (read back from the Keychain), and `settings.v1` in UserDefaults contains no secret |
| 24 | Settings ▸ Dictation: switch the source to that endpoint with model `whisper-1`, dictate | Audio is sent to the endpoint and the transcript is inserted |
| 25 | Deny the microphone in System Settings, then press the hotkey | HUD shows the permission error and the Privacy ▸ Microphone pane opens |
| 26 | Turn Accessibility off in System Settings, then press the hotkey | HUD shows the permission error and the Privacy ▸ Accessibility pane opens |
| 27 | Settings ▸ General: toggle "Launch at login" on, check System Settings ▸ General ▸ Login Items | Macomprendo is listed; toggling it off removes it |

## Refine selection (hotkey #5, unassigned by default)

Assign a shortcut in Settings ▸ Hotkeys first.

- [ ] Select a sentence in TextEdit and press the shortcut. The Quick Panel opens top-center
      of the screen holding the mouse, 680×420, above the frontmost window, and TextEdit stays
      the active app (its title bar keeps colour).
- [ ] "Original" shows exactly the selected text; "Refined" fills in progressively; the
      spinner and Stop button are visible while it streams.
- [ ] Press Stop mid-stream: streaming halts, the partial text stays, no error banner appears.
- [ ] Type "make it one sentence" in the instruction field and press ⌘↩: "Refined" clears and
      re-streams.
- [ ] Change the preset picker to "Formal": it re-runs automatically.
- [ ] Click "Copy" on the Refined side: a "Copied." toast appears and the panel stays open;
      ⌘V in TextEdit pastes the refined text.
- [ ] Click "Insert" on the Refined side: TextEdit comes forward, the selected text is
      replaced by the refined version, and the panel closes.
- [ ] Reopen the panel, drag it to the bottom-left, press Esc, reopen: it appears where it was
      dragged. On a second display it remembers a separate position.
- [ ] Stop Ollama (`pkill ollama`) and trigger the hotkey: a red banner names the endpoint and
      suggests starting Ollama or choosing another endpoint. Restart Ollama afterwards.

## Dictate & Refine (hotkey #2, ⌥⇧Space)

- [ ] With Dictation mode = Hold: hold ⌥⇧Space, say two sentences, release. Nothing appears
      while recording (this hotkey has no Esc-to-cancel, so the HUD's usual level meter and
      "Esc cancels" hint would be a false promise); on release the HUD shows "Transcribing…",
      then the Quick Panel opens with "Original" holding the transcript and "Refined" streaming.
- [ ] With Dictation mode = Toggle: press once to start, press again to stop; same result.
- [ ] Say nothing and release: the HUD's "Transcribing…" disappears, a "Nothing heard." toast
      appears, and no panel opens.
- [ ] Click Insert on either side: the text lands in the app that was frontmost when the
      hotkey fired (not in the panel), and the panel closes.
- [ ] Deny microphone permission in System Settings, trigger the hotkey: the permission error
      toast appears with a link to the correct System Settings pane. Re-grant afterwards.

## Summarize selection (hotkey #4, ⌥M)

- [ ] Select three paragraphs in Safari and press ⌥M: the Quick Panel opens in the single-pane
      summary layout with the "Brief" preset and streams a summary.
- [ ] Switch the preset to "Bullets": it re-runs and produces a bullet list.
- [ ] Press "Copy": a toast appears, the panel stays open, ⌘V pastes the summary.
- [ ] In TextEdit, select a paragraph, press ⌥M, then "Replace selection": the selected
      paragraph is replaced by the summary and the panel closes.
- [ ] Press ⌥M with nothing selected: a "nothing selected" toast appears, no panel opens.
- [ ] Copy something to the clipboard, then press ⌥M in an app without Accessibility selection
      support (Terminal): the summary is produced via the ⌘C fallback **and** the clipboard
      still holds what you copied before.

## Speak selection (hotkey #3, ⌥S)

- [ ] Select a paragraph and press ⌥S: it is read aloud with the voice chosen in
      Settings ▸ Speech.
- [ ] Press ⌥S again while it is speaking: it stops immediately and does **not** re-read the
      selection or touch the clipboard.
- [ ] Let an utterance finish on its own, then press ⌥S again: it starts speaking again.
- [ ] The HUD shows "Speaking…" with the stop hint for the whole utterance and disappears the
      moment playback ends or is stopped with ⌥S.
- [ ] Press ⌥S with nothing selected: a "nothing selected" toast appears, nothing is spoken, and
      no "Speaking…" HUD appears.
- [ ] Change rate, pitch and volume in Settings ▸ Speech and press "Preview": the change is
      audible; the next ⌥S uses the new values.

## Settings ▸ Speech

- [ ] Voices are grouped by language with the system language's group listed under its
      localized name; enhanced/premium voices carry a quality badge.
- [ ] Selecting a voice persists across an app restart.

## Settings ▸ Refine & Summarize

- [ ] Each feature segment shows its own endpoint + model picker; "Reload" repopulates the
      model list from the endpoint (and shows an orange message when it is unreachable).
- [ ] Both preset lists show the factory presets in order with the default marked.
- [ ] Add, rename, duplicate, reorder (drag) and delete presets; all changes survive an app
      restart and appear in the Quick Panel's picker in the same order.
- [ ] Remove `{text}` from a template: a red validation line appears; the Quick Panel shows the
      same message in its error banner instead of calling the model.
- [ ] "Test with sample text" streams a result into the read-only box; "Stop" halts it.
- [ ] Delete presets until one remains, then delete again: "At least one refine preset must
      exist." is shown and nothing is deleted.
- [ ] Delete the default preset: the default moves to the first remaining preset.
- [ ] "Restore factory presets" re-adds every deleted factory preset at the end of its list and
      leaves custom presets untouched (no duplicates).

## Mixed-language speech, system voices (hotkey #3, ⌥S)

Setup: in Settings ▸ Speech pick "System voices" and an **English** voice (e.g. Samantha).
Install a Russian voice first if none is present (System Settings ▸ Accessibility ▸ Spoken
Content ▸ System Voice ▸ Manage Voices…).

- [ ] Select a paragraph that is entirely English and press ⌥S: it reads exactly as before —
      one continuous utterance, no seam, no pause at the start.
- [ ] Select a paragraph with a long Russian sentence followed by a long English sentence and
      press ⌥S: **both** languages are intelligible and the voice audibly changes at the
      script boundary, not mid-word.
- [ ] The "Speaking…" HUD stays up for the *whole* passage, including across the voice switch,
      and disappears only when the last sentence ends.
- [ ] Press ⌥S again mid-passage: playback stops immediately, the HUD disappears, and the
      remaining sentences are not read.
- [ ] Select a Russian sentence containing one English word ("Я купил новый iPhone вчера…")
      and press ⌥S: the whole sentence is read by the Russian voice — the voice does **not**
      flip for the single word.
- [ ] Select text containing Chinese or Arabic characters mixed into English and press ⌥S:
      nothing crashes; the foreign characters are read (or skipped) by the surrounding voice.
- [ ] Remove every Russian voice from the system, then repeat the mixed selection: it still
      reads without crashing, using the configured voice throughout.

## Endpoint speech source (hotkey #3, ⌥S)

Setup: Settings ▸ Speech ▸ Speech source = "Endpoint", and either an OpenAI-compatible API key
(Base URL should point at your OpenAI-compatible server — e.g. `https://api.openai.com` for OpenAI,
`https://api.proxyapi.ru/openai` for a reseller, or `http://localhost:8000` for a local server)
or a local server on `http://localhost:8000`.

- [ ] With no key saved, press Preview: a toast reads
      "No speech API key. Add one in Settings ▸ Speech." and nothing plays.
- [ ] Paste a **wrong** key, press "Save key", press Preview: a toast names the HTTP status the
      server returned; nothing plays; the app stays responsive.
- [ ] Paste the real key and press "Save key": the field clears immediately, the caption reads
      "Key saved to the Keychain.", and the key is **not** visible anywhere in the UI.
      Confirm with Keychain Access that an item `speech.endpoint` exists for service
      `com.dzamataev.macomprendo`.
- [ ] Press Preview: the sample sentence plays in the configured voice within a few seconds.
- [ ] Pick a different name from the "Built-in" menu and press Preview: the voice audibly
      changes. Type a name the server does not know and press Preview: a toast names the HTTP
      error.
- [ ] Type "Read this slowly and sadly" into Style instructions and press Preview with
      `gpt-4o-mini-tts`: the delivery changes. Clear the field and press Preview: normal
      delivery returns.
- [ ] The rate/pitch/volume sliders are **not** shown while Endpoint is selected; switch back to
      "System voices" and they reappear.
- [ ] Select a mixed Russian/English paragraph in TextEdit and press ⌥S: it is read by one
      natural voice that switches languages mid-sentence without changing timbre.
- [ ] The "Speaking…" HUD is visible from the moment ⌥S is pressed until the last chunk ends,
      including the gaps between chunks of a long selection.
- [ ] Select five or more paragraphs (over ~4000 characters) and press ⌥S: playback is
      continuous, in order, with only a short gap between chunks.
- [ ] Press ⌥S again mid-audio: playback stops within a second, the HUD disappears, and **no**
      error toast appears.
- [ ] Turn Wi-Fi off and press ⌥S: a toast reads `Could not reach "<your host>".` — the host
      you typed into Base URL, not a raw URL — with its recovery suggestion. Turn Wi-Fi back on.
- [ ] Point Base URL at a local server that returns MP3 instead of WAV (openedai-speech with
      `response_format` ignored): audio still plays.
- [ ] Switch the source back to "System voices" while endpoint audio is playing: the endpoint
      audio stops; the next ⌥S uses a system voice.
- [ ] Clear the API key field and press "Save key": the caption reads "Key removed." and the
      Keychain item is gone.
- [ ] Open Console.app filtered on subsystem `com.dzamataev.macomprendo` and repeat a ⌥S with
      the endpoint source selected: **no** log line contains the selected text or the API key.
