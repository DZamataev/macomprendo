# Manual smoke test

Run this checklist on a real Mac before every release, and after any change to the audio, permission,
hotkey, paste or HUD code. Unit tests cover the logic; this file covers the parts that need hardware,
TCC permissions and a window server.

**Build under test:** `npm run build` output, or the Xcode Debug build (`⌘R`).
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
| 11 | Hold ⌥Space, say nothing, release | HUD shows "Nothing heard"; nothing is inserted |
| 12 | Settings ▸ General: switch to "Press to start, press to stop" | ⌥Space starts recording; a second press stops, transcribes and inserts |
| 13 | Settings ▸ General: set Insert text by = "Typing character by character", dictate into TextEdit | Text is typed rather than pasted; the clipboard is untouched |
| 14 | Settings ▸ Hotkeys: record ⌃⌥D for Dictate, then use it | The new shortcut dictates; ⌥Space no longer does |
| 15 | Menubar menu: switch "Dictate" off, press the hotkey | Nothing happens; switching it back on restores it |
| 16 | Dictate into a full-screen app on a second display | The HUD appears on the screen with the mouse, above the full-screen app, and the text lands in the app |
| 17 | Menubar menu while idle / recording | Status line reads "Ready" / "Recording…" |
| 18 | Settings ▸ Models: delete the downloaded model, then dictate | HUD shows a "model missing" error with recovery text; downloading it again fixes dictation |
| 19 | Settings ▸ Providers: select "Ollama (local)", click "Test connection" | "Connected — N models" (with Ollama stopped: the unreachable error and its recovery text) |
| 20 | Settings ▸ Providers ▸ Ollama: click "Pull qwen2.5:1.5b" | Progress advances and finishes with "Pulled qwen2.5:1.5b" |
| 21 | Settings ▸ Providers: add an OpenAI-compatible endpoint, type an API key, click "Save key", quit and relaunch | The key is still there (read back from the Keychain), and `settings.v1` in UserDefaults contains no secret |
| 22 | Settings ▸ Dictation: switch the source to that endpoint with model `whisper-1`, dictate | Audio is sent to the endpoint and the transcript is inserted |
| 23 | Deny the microphone in System Settings, then press the hotkey | HUD shows the permission error and the Privacy ▸ Microphone pane opens |
| 24 | Turn Accessibility off in System Settings, then press the hotkey | HUD shows the permission error and the Privacy ▸ Accessibility pane opens |
| 25 | Settings ▸ General: toggle "Launch at login" on, check System Settings ▸ General ▸ Login Items | Macomprendo is listed; toggling it off removes it |
