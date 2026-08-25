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

- [ ] With Dictation mode = Hold: hold ⌥⇧Space, say two sentences, release. The recording HUD
      shows a live level meter, then the Quick Panel opens with "Original" holding the
      transcript and "Refined" streaming.
- [ ] With Dictation mode = Toggle: press once to start, press again to stop; same result.
- [ ] Say nothing and release: a "Nothing heard." toast appears and no panel opens.
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
