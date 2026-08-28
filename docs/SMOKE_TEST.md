# Manual smoke test

Run this checklist on a real Mac before every release, and after any change to the audio, permission,
hotkey, paste or HUD code. Unit tests cover the logic; this file covers the parts that need hardware,
TCC permissions and a window server.

**Build under test:** the Xcode Debug build (`⌘R`).
Reset permissions when you want to rehearse a fresh install — quit the app first, then
`npm run reset-permissions` (add `--dry-run` to see the commands, `--force` to reset anyway).

> **An ad-hoc build loses its permissions on every rebuild.** macOS records a grant against the
> app's code identity; ad-hoc signing gives it none, so the grant is tied to that build's code
> hash and stops applying the moment you rebuild — while System Settings still shows the toggle
> switched on. The app then reports no accessibility access for a permission that looks granted.
> Sign with the Developer ID identity (`npm run build -- --sign "Developer ID Application: …"`)
> when you need permissions to survive a rebuild.

## Dictation (hotkey #1)

- [ ] Launch the app for the first time — no Dock icon; a waveform icon appears in the
      menubar; the Welcome window opens.
- [ ] Click "Allow microphone…" in onboarding — the macOS microphone prompt appears; after
      allowing, the step shows "Granted."
- [ ] Click "Allow accessibility…" — the Accessibility prompt appears; after enabling
      Macomprendo in System Settings and returning, the step shows "Granted."
- [ ] **The step notices a grant made in System Settings.** On the accessibility step, switch to
      System Settings, turn Macomprendo on, and switch back to the wizard without clicking
      anything: the status flips to "Granted." on its own. This is the only check of the
      `didBecomeActiveNotification` wiring in `OnboardingView` — a unit test cannot raise it.
- [ ] **"Check again" re-reads the status.** Turn the permission back off in System Settings,
      return, and click "Check again": the step drops back to "Denied." macOS shows its prompt
      only once per app, so after the first time "Allow accessibility…" does nothing visible —
      this button is what a stuck-looking step needs.
- [ ] Choose "Large v3 Turbo" and click Download — progress advances to 100%, then
      "Downloaded."
- [ ] Click "Check for Ollama" (with Ollama running) — "Ollama is running." (with Ollama
      stopped: the orange "Not found" hint)
- [ ] Click Finish — the window closes and does not reopen on the next launch.
- [ ] Open TextEdit, click into a document, hold ⌥Space and say "hello world" — the HUD
      appears top-centre of the screen with the mouse, the level meter moves, the timer counts
      up.
- [ ] Release ⌥Space — the HUD switches to "Transcribing…", then a ✓ that disappears after
      ~1.2 s; "hello world" is inserted at the caret in TextEdit.
- [ ] Before dictating, copy some text (⌘C), then dictate again — after insertion, ⌘V still
      pastes your original clipboard text.
- [ ] Dictate, and while the HUD says "Transcribing…" press ⌥Space again — the HUD shows
      "Cancelled"; nothing is inserted.
- [ ] Hold ⌥Space to start recording, then press Esc — the HUD shows "Cancelled"; nothing is
      inserted.
- [ ] Dictate, and while the HUD says "Transcribing…" press Esc — the HUD shows "Cancelled";
      nothing is inserted.
- [ ] Hold ⌥Space, say nothing, release — the HUD shows "Nothing heard"; nothing is inserted.
- [ ] Settings ▸ General: switch to "Press to start, press to stop" — ⌥Space starts recording;
      a second press stops, transcribes and inserts.
- [ ] Settings ▸ General: set Insert text by = "Typing character by character", dictate into
      TextEdit — text is typed rather than pasted; the clipboard is untouched.
- [ ] Settings ▸ Hotkeys: record ⌃⌥D for Dictate, then use it — the new shortcut dictates;
      ⌥Space no longer does.
- [ ] Menubar menu: switch "Dictate" off, press the hotkey — nothing happens; switching it back
      on restores it.
- [ ] Dictate into a full-screen app on a second display — the HUD appears on the screen with
      the mouse, above the full-screen app, and the text lands in the app.
- [ ] Menubar menu while idle / recording — the status line reads "Ready" / "Recording…".
- [ ] Settings ▸ Models: delete the downloaded model, then dictate — the HUD shows a "model
      missing" error with recovery text; downloading it again fixes dictation.
- [ ] Settings ▸ Providers: select "Ollama (local)", click "Test connection" — "Connected —
      N models" (with Ollama stopped: the unreachable error and its recovery text).
- [ ] Settings ▸ Providers ▸ Ollama: click "Pull qwen2.5:1.5b" — progress advances and finishes
      with "Pulled qwen2.5:1.5b".
- [ ] Settings ▸ Providers: add an OpenAI-compatible endpoint, type an API key, click "Save
      key", quit and relaunch — the key is still there (read back from the Keychain), and
      `settings.v1` in UserDefaults contains no secret.
- [ ] **Keychain fallback path:** with that same endpoint's key already saved, go back to
      Settings ▸ Providers, type a *different* key over it, and click "Save key" again — the
      caption still reads "Key saved to the Keychain."; quitting and relaunching reads back the
      new key, not the old one. (Saving over an existing key exercises
      `SystemKeychainStore.set`'s `SecItemUpdate` path directly; saving a key for the first
      time, as in the step above, exercises its `SecItemAdd` fallback, taken when
      `SecItemUpdate` returns `errSecItemNotFound`. This is deliberately excluded from CI
      because Keychain access is flaky in that environment.)
- [ ] Settings ▸ Dictation: switch the source to that endpoint with model `whisper-1`, dictate
      — audio is sent to the endpoint and the transcript is inserted.
- [ ] Deny the microphone in System Settings, then press the hotkey — the HUD shows the
      permission error and the Privacy ▸ Microphone pane opens.
- [ ] Turn Accessibility off in System Settings, then press the hotkey — the HUD shows the
      permission error and the Privacy ▸ Accessibility pane opens.
- [ ] Settings ▸ General: toggle "Launch at login" on, check System Settings ▸ General ▸ Login
      Items — Macomprendo is listed; toggling it off removes it.

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

Setup: Settings ▸ Speech ▸ Speech source = "Endpoint". Point Base URL at your own OpenAI-compatible server — for this machine api.openai.com is region-blocked, so use a reseller such as `https://api.proxyapi.ru/openai` or a local server on `http://localhost:8000`.

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
- [ ] Clear the Base URL field and type an incomplete URL (e.g. `htp:/x`), then click away and
      reopen the tab: the stored Base URL is unchanged (the field shows the last valid URL, not
      the garbage).
- [ ] Point Base URL at a local server that returns MP3 instead of WAV (openedai-speech with
      `response_format` ignored): audio still plays.
- [ ] Switch the source back to "System voices" while endpoint audio is playing: the audio
      keeps playing; press ⌥S once to stop it, and again to read with a system voice.
- [ ] Clear the API key field and press "Save key": the caption reads "Key removed." and the
      Keychain item is gone.
- [ ] Open Console.app filtered on subsystem `com.dzamataev.macomprendo` and repeat a ⌥S with
      the endpoint source selected: **no** log line contains the selected text or the API key.

## Dock icon

| Step | Expected |
|---|---|
| Open Settings from the menubar | A Dock icon appears while the window is up |
| Close the Settings window | The Dock icon disappears; the menubar item stays |
| Open "Check permissions…", then Settings, then close Settings | The Dock icon stays while the wizard is still open |
| Close the wizard too | The Dock icon disappears |

> `.onDisappear` on a SwiftUI `Settings` scene is not a documented contract. If closing the
> Settings window leaves the Dock icon behind, replace the `.onAppear`/`.onDisappear` pair with
> a glue object observing `NSWindow.willCloseNotification` and reconciling against
> `NSApp.windows`; the `DockIconCoordinator` API does not change.

## Release checklist

Run this list on a Mac that has *not* been used to develop the current change, if possible.
Every box must be ticked before `npm run release`.

### Automated gates

- [ ] `npm ci` succeeds from a clean `node_modules`.
- [ ] `npm run test:scripts` — all Node tests pass.
- [ ] `swift test --package-path macos` — all Swift tests pass.
- [ ] `npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj` — the committed Xcode
      project matches `macos/project.yml`.
- [ ] `npm run sync-agents -- --check` — the agent-config symlinks are intact.
- [ ] `npm run audit` — the public repository audit passes.
- [ ] `npm run build -- --dry-run` — the build plan prints without error.
- [ ] `npm run release -- --dry-run patch` — the version resolves and the changelog validates.

### Build artifact

- [ ] `npm run build -- --arch arm64,x86_64` succeeds.
- [ ] `lipo -archs dist/Macomprendo.app/Contents/MacOS/Macomprendo` prints `x86_64 arm64`.
- [ ] `ls dist/Macomprendo.app/Contents/Resources` contains `AppIcon.icns`, `LICENSE`,
      `Macomprendo_Macomprendo.bundle` (the vendored Phosphor icons), and
      `KeyboardShortcuts_KeyboardShortcuts.bundle`.
- [ ] `find dist/Macomprendo.app/Contents/Resources/Macomprendo_Macomprendo.bundle -type f | wc -l`
      prints a number greater than zero. This is the actual proof the vendored Phosphor SVGs
      shipped inside the built app — nothing about the running app's *appearance* proves it (the
      menubar icon is a hardcoded SF Symbol, not drawn from this bundle, and a missing bundle
      degrades every other icon silently to a similar-looking SF Symbol instead of failing
      visibly; see the "Icons in Settings" row below).
- [ ] `ls dist/Macomprendo.app/Contents/Frameworks` contains `whisper.framework` — whisper is
      dynamically linked (confirm with
      `otool -L dist/Macomprendo.app/Contents/MacOS/Macomprendo | grep whisper`), so this
      directory must be present, not absent. See DISTRIBUTING.md → "What the build copies into
      the bundle" if a future whisper xcframework bump changes this.
- [ ] `codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app` reports the bundle as
      valid on disk and satisfying its designated requirement.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Macomprendo.app/Contents/Info.plist`
      prints `com.dzamataev.macomprendo`.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' …` matches
      `MARKETING_VERSION` in `macos/project.yml`.

### Notarized artifact

Requires the Developer ID Application certificate for team `68QJJA7HK9` from DISTRIBUTING.md's
prerequisites, installed in the login keychain.

- [ ] `npm run notarize` finishes with `Notarized release: dist/Macomprendo-<version>-macos.zip`.
- [ ] `xcrun stapler validate dist/Macomprendo.app` reports the ticket is valid.
- [ ] `spctl --assess --type execute --verbose=4 dist/Macomprendo.app` prints `accepted` and
      `source=Notarized Developer ID`.
- [ ] `shasum -a 256 -c dist/Macomprendo-<version>-macos.zip.sha256` passes.
- [ ] Expanding the ZIP on a Mac that has never seen the app opens it with no Gatekeeper warning.

> **This block has never been executed for real.** Everything above is covered by unit tests
> against a faked `notarytool`/`codesign`/`spctl`, and `--dry-run` prints the exact same steps
> that a real run would execute (both share one generated step list), but that only proves the
> *steps* are right — not that Apple's notary service accepts what gets submitted. An actual
> submission — network round-trip, real "Accepted" status, a genuine staple and a live
> Gatekeeper check — has not happened yet.
> The first time an operator runs `npm run notarize` (standalone, or via
> `npm run release -- --notarize <bump>`) for real, tick every box above deliberately instead of
> assuming the tests already proved it.

### Install and first run

- [ ] `npm run install-app` installs into `/Applications` and relaunches the app.
- [ ] Running it a second time while the app is open quits the running copy and relaunches it.
- [ ] No `.macomprendo-update.*` directory is left behind in the install directory.
- [ ] On a fresh user account, onboarding asks for Microphone, then Accessibility, and the
      System Settings deep links open the correct panes.

### Manual verification (human only — no agent can perform these)

- [ ] **Icons in Settings look like Phosphor glyphs, not system symbols.** Open Settings and
      look at any tab with icons (Hotkeys, Providers, Models…). Every icon in the app is drawn
      by `Icon.swift`, which loads a vendored Phosphor SVG from `Macomprendo_Macomprendo.bundle`
      (see ADR-0008) — Phosphor's glyphs have a noticeably different weight and shape from
      Apple's SF Symbols. If the SVG can't be found, `Icon.swift` falls back **silently** to a
      similar but not identical SF Symbol (`AppIcon.fallbackSymbol`) — no error, no log line, and
      the app keeps running normally. So this row is a judgement call about how the icons *look*,
      not a pass/fail the app itself reports, and a "yes, they look like Phosphor icons" here is
      the closest a human glance gets to confirming the bundle loaded — it is not conclusive on
      its own (use the `find`/`wc -l` check in Build artifact for that). The menubar's own status
      item is not evidence either way: it is deliberately hardcoded to the SF Symbol `waveform`
      (`MenuBarExtra("Macomprendo", systemImage: "waveform")` in `MacomprendoApp.swift`), per
      CLAUDE.md invariant 12 — it never draws from this bundle, with or without it present.
- [ ] **Dictation produces a transcript.** Press the dictation hotkey once, say a sentence, and
      confirm text is inserted. This is the only proof that the whisper xcframework
      (`whisper.framework`, dynamically linked — see ADR-0007) actually loaded and ran on this
      machine; a linking or Metal-resource problem would only surface here, not in a headless
      test or a dry run.

### Documentation

- [ ] `CHANGELOG.md` has entries under `## [Unreleased]` describing everything in this release.
- [ ] `README.md` install instructions match the artifact names actually produced.
- [ ] `DISTRIBUTING.md` lists the bundle and framework names currently emitted by `swift build`.
