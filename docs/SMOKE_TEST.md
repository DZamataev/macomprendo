# Manual smoke test

Run this checklist on a real Mac before every release, and after any change to the audio, permission,
hotkey, paste or HUD code. Unit tests cover the logic; this file covers the parts that need hardware,
TCC permissions and a window server.

**Build under test:** run `npm run install-app:signed`. Use this build for every manual check that
does not test the permission flow itself. Its Developer ID signature preserves Microphone and
Accessibility grants across rebuilds.

Do not reset permissions as routine smoke-test setup. Only permission-specific checks should quit
the app and run `npm run reset-permissions`. Add `--dry-run` to inspect the reset commands or
`--force` to reset while the app is running.

## Dictation (hotkey #1)

- [ ] Launch the app for the first time — no Dock icon; a segmented heart icon appears in the
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
- [ ] Settings ▸ Hotkeys ▸ Keyboard: switch to "Press to start, press to stop" — ⌥Space starts recording;
      a second press stops, transcribes and inserts.
- [ ] Settings ▸ General: set Insert text by = "Typing character by character", dictate into
      TextEdit — text is typed rather than pasted; the clipboard is untouched.
- [ ] Settings ▸ Hotkeys: record ⌃⌥D for Dictate, then use it — the new shortcut dictates;
      ⌥Space no longer does.
- [ ] **Middle mouse action.** Settings ▸ Hotkeys: enable “Middle mouse button click” and choose
      Dictate. Set Mouse ▸ Dictation behaviour to Hold, hold the middle button in TextEdit while
      speaking and release it: recording stops, transcribes and inserts; the recording starts
      0.6 s after the press. With Bluetooth headphones playing music, middle-click a link in
      Safari: no HUD appears and the music keeps playing. Set the **mouse** behaviour
      to Toggle: one click starts recording and the next stops it; the Keyboard behaviour remains
      unchanged. Select “Summarize selection”, select text in TextEdit and click the middle button:
      the Summary panel opens. Disable the toggle and confirm middle-button clicks no longer invoke
      Macomprendo.
- [ ] Menubar panel with a Macomprendo window open (Transcripts, Settings): click the status
  item — the panel opens once and stays; it does not vanish and reappear. A click into that
  window, Escape, or switching to another app (⌘Tab) closes it.
- [ ] Menubar panel, two displays: with the other display focused, click the status item in
  this display's menu bar — the panel opens under it and its arrow points at the icon on the
  first try. While it is open, a recording clock or percent that changes the item's width keeps
  the arrow on the icon.
- [ ] Menubar panel, two displays: with the panel open, click the status item (or anywhere) on
  the other display — the panel closes and does not reopen there; the next click opens it.
- [ ] Menubar panel, two displays: open the panel, scroll an unfocused window of another app on
  the other display without clicking, then click into it — the panel closes. A click on another
  app's window, the desktop or another app's menu-bar item closes it too; clicks inside the
  panel, its pop-up menus and Macomprendo's own windows do not close it by themselves.
- [ ] Menubar panel ▸ Options: the whole **Options** row (not just the caret) expands it, its
  label lines up with the commands above; every switch is mini-sized with its label on the left
  and the switch on the right. **Launch at login** there and in Settings ▸ General agree both ways,
  and one removed in System Settings ▸ General ▸ Login Items shows as off on the next opening.
- [ ] Menubar panel: Microphone, Dictation model and the translation selector all reach the
  panel's right edge; the translation caption names Refine & Summarize and its tooltip explains it.
- [ ] Menubar panel ▸ Options: switch "Dictate" off, press the hotkey — nothing happens;
      switching it back on restores it.
- [ ] **Very short dictation.** In Settings ▸ General, enable **Insert “OK” for a very short
      dictation**, then press and release the Dictate hotkey in under half a second — `OK` is
      inserted without waiting for speech recognition, and **no HUD appears at any point** —
      not even a flash. Hold the key (and, separately, the middle mouse button in hold mode) for
      about two seconds: the recording HUD appears roughly half a second after the press (about
      1.1 s for the middle button, which starts recording only after 0.6 s), its timer already
      past 0:00. Disable it and verify the same short recording follows the
      normal transcription path, with the recording HUD appearing immediately.
- [ ] **Trailing space.** In Settings ▸ General, enable “Add a space after dictated text”,
      dictate `hello` into TextEdit, and verify the insertion is `hello ` (with one trailing
      space). In Dictate & Refine, insert the Original text and verify it also ends in one space;
      refined text remains unchanged. Disable it and verify subsequent Dictate insertion has no
      extra space.
- [ ] Dictate into a full-screen app on a second display — the HUD appears on the screen with
      the mouse, above the full-screen app, and the text lands in the app.
- [ ] Menubar panel while dictating — no status line while idle; pressing the hotkey shows
      "Recording dictation…", then "Transcribing dictation…", then "Inserting text…", and the
      line goes away when the dictation ends. (Idle never reads "Ready".)
- [x] **Local-model memory.** Settings ▸ General ▸ Local models shows “Unload local model”
      with Immediately, 5, 10, 30 minutes, and Never; a fresh or upgraded install selects
      10 minutes. Set it to Never and dictate twice with the same local model:
      Console shows one “Loaded whisper model …” event and the second transcription starts without
      the model-loading pause. Change Threads and dictate again: the model loads once with the new
      configuration. Set the policy to 5 minutes, dictate again before five idle minutes have
      elapsed and confirm there is no new load; then wait five full idle minutes and confirm the
      next dictation loads the model again. Set the policy to Immediately and confirm each
      dictation loads afresh. Quit from the menubar while a model is resident and confirm
      Macomprendo exits without hanging.
- [ ] Settings ▸ Dictation: delete the downloaded model, then dictate — the HUD shows a "model
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

## Silent capture (hotkey #1)

A dead or hijacked input device delivers buffers of digital zeros while recording carries on;
only real hardware can produce that, so none of this is reachable from unit tests.

- [ ] **A muted microphone warns during the recording and inserts nothing after it.** Select a
      microphone in System Settings ▸ Sound ▸ Input, mute it there, then hold the dictation
      hotkey for five seconds. After about three seconds the HUD switches to **Not hearing
      anything — Check your input device.** while the recording keeps running and the elapsed
      time keeps climbing; Esc still cancels. On release nothing is pasted, the HUD shows **No
      sound was captured.** with the advice to check the input device and whether another app
      has taken it, and Dictation History gains no new row.
- [ ] **Unmute and dictate again** — the warning never appears, the transcript is inserted, and
      history records it as usual.
- [ ] **A deliberate short tap is unaffected.** With Settings ▸ General ▸ "Insert “OK” for a
      very short dictation" on and the microphone still muted, tap the hotkey for well under half
      a second — `OK` is inserted and the HUD shows the success, not the silence error.
- [ ] **Switching the input device mid-recording neither crashes nor loses the recording.**
      Start a dictation on one microphone (a silent one — e.g. a wireless headset whose dongle
      is plugged in but whose headset is off — reproduces the original crash), and while the
      HUD is recording pick the built-in microphone in the menubar Sound menu or System
      Settings ▸ Sound ▸ Input. Keep talking, release: the words said after the switch are
      transcribed. Then dictate again at once — the app records normally instead of quitting.

## Microphone picker (Settings ▸ General ▸ Microphone)

Device enumeration and binding are Core Audio calls, so only real hardware exercises them.

- [ ] **The list is live.** Open the picker: the first row reads **System default (…)** with
      the current default input in brackets, followed by every connected input device and no
      output-only devices. Plug in (or power on) a USB/Bluetooth microphone with Settings open —
      it appears without reopening the window; remove it — it disappears.
- [ ] **A chosen device is used while it is not the default.** Leave the system default on the
      built-in microphone, choose the external one, dictate: the level meter moves when you
      speak into the external microphone and the transcript is right.
- [ ] **A disconnected choice falls back and is kept.** With the external microphone chosen,
      switch it off: the picker shows **… — not connected** selected, with an orange caption
      naming the fallback. Dictate — the built-in microphone records. Switch the device back on
      — the caption goes, and the next dictation uses it again.
- [ ] **A Bluetooth headset leaves call mode after recording.** With AirPods (or any Bluetooth
      headset) as the microphone and music playing, dictate a few words. Within a couple of
      seconds of the recording stopping the music returns to full quality, with Macomprendo
      still running. Repeat with a call recording. Then switch off Settings ▸ General ▸
      **Release the microphone after recording** and dictate again: the music stays in call
      quality, and the menubar panel shows **Release Microphone** under the microphone picker.
      Click it: the music returns to full quality and the row is gone the next time the panel
      opens.
- [ ] **A silent device is abandoned mid-recording.** Plug in a wireless headset's dongle with
      the headset switched off and make it the chosen (or default) microphone. Hold the
      dictation hotkey and start talking: within about two seconds the HUD reads **No signal
      from <headset> — switched to MacBook … Microphone** above a meter that moves with your
      voice. Release — the words are transcribed. Dictate again straight away: it starts on
      the headset again and falls back the same way.
- [ ] **A quiet room is not a dead device.** With a working microphone chosen, hold the hotkey
      for five seconds without speaking: no fallback notice appears (the three-second
      "Not hearing anything" warning may, if the room is very quiet).
- [ ] **Dictate & Refine says so too.** Repeat the silent-device step with the Dictate & Refine
      hotkey: a notice names both devices and the refined text reflects what you said.
- [ ] **Changing the choice mid-recording moves the recording.** Start a dictation on one
      device and, while recording, pick the other in Settings. Keep talking, release — the words
      after the switch are transcribed, and the next dictation starts normally.

## Glossary (Settings ▸ Dictation)

Everything here needs the real Application Support directory, Finder and a microphone, so none
of it is reachable from unit tests. `~/Library/Application Support/Macomprendo/Vocabulary/` is
referred to below as **the Vocabulary folder**.

- [ ] **A fresh install seeds six packs and enables none of them.** Quit the app, move the
      Vocabulary folder aside (`mv ~/Library/Application\ Support/Macomprendo/Vocabulary
      /tmp/vocab-backup`), and launch again. The folder is back and holds exactly
      `typescript.txt`, `react-native.txt`, `python.txt`, `go.txt`, `ruby.txt`, `godot.txt` and
      `README.md`. There is no `packs.json`, or an empty one. Open Settings ▸ Dictation ▸
      Glossary, turn **Correct recognised terms** on and decline the offer with **Not now**:
      every pack in the list is present with its term count and **every checkbox is off**.
- [ ] **The first-run offer is made once.** With the master switch off and
      `glossaryRecommendedPacksOffered` not yet set (the fresh state above), turn the switch on:
      the "Turn on the recommended packs?" dialog names the six packs. Choose **Not now**, turn
      the switch off and on again — the dialog does not reappear and `packs.json` is still
      empty. Repeat from the fresh state and choose **Turn them on**: all six checkboxes are on
      and `packs.json` lists the six names in that order.
- [ ] **A pack dropped in by hand appears after Reload and stays off.** With Settings open,
      write a file `smoke.txt` into the Vocabulary folder containing a comment line, a blank
      line and the single term `auto-till-dry`. Nothing changes in Settings until you click
      **Reload**; then `smoke` appears in the list reading "1 term", **unchecked**, with
      **Delete** offered (it is a user pack, not a factory one). Confirm the file's name is
      *not* in `packs.json`. Tick its checkbox and confirm `packs.json` now names `smoke` and
      that every `.txt` file in the folder is byte-identical to what it was before the tick
      (`shasum` the folder before and after).
- [ ] **An enabled pack corrects a dictated term.** Enable only the `typescript` pack, click
      into TextEdit and dictate a sentence containing *tsconfig json* and *NVM* — for example
      «Открой tsconfig json и поставь nvm». The pasted text reads `tsconfig.json` and `nvm`
      (dotted, lower-case), which is how they are spelled in `typescript.txt`. Turn the master
      switch off, dictate the same sentence: the transcript is pasted as the recogniser wrote
      it, uncorrected.
- [ ] **A replacement rule rewrites a listed form.** Create a pack `smoke-forms` holding
      `pytest = пайтест, пайтеста` and `pod install = под инсталл`, enable it, and dictate into
      TextEdit, pausing between words: «Пайтест. Без пайтеста не заметил. Сделал под инсталл, кот
      под диваном.» If the recogniser writes those words in Cyrillic, the pasted text reads
      `Pytest.`, `Без pytest`, `pod install` — and `под диваном` is untouched. If it writes them
      in Latin, normalisation handles them and the check is inconclusive: repeat inside a longer
      Russian sentence. Delete the pack afterwards.
- [ ] **The original transcript is kept beside the corrected one.** With dictation history on
      and a correction made as above, the History window shows the corrected text (nothing in
      the UI renders the raw form today). Verify the raw text was stored by querying the
      database directly:
      `sqlite3 ~/Library/Application\ Support/Macomprendo/dictation-history.sqlite3
      "select text, raw_text from dictation_history order by id desc limit 1;"` — `text` holds
      the corrected spelling, `raw_text` holds what the recogniser produced. Dictate a sentence
      with no glossary term in it and confirm `raw_text` is empty for that entry.
- [ ] **Editing a pack keeps its comments.** Click **Edit** on `typescript`: the sheet shows the
      file's own text — the `# pack: typescript` header and its comment block are visible, not a
      rendered term list. Add a line `smoke-edit-term`, click **Save**, close Settings, reopen it
      and click **Edit** again: the new line is there **and every original comment, blank line
      and term order is unchanged**. `diff` the file against `/tmp/vocab-backup/typescript.txt`
      to confirm the only difference is the line you added.
- [ ] **Reset restores a factory pack, Delete is offered only for user packs.** With the edit
      above still in place, click **Reset** on `typescript`: the file returns to the shipped
      text and the added line is gone. `typescript` offers no **Delete** button; `smoke` does,
      and deleting it removes the file without an error.
- [ ] **A malformed line is counted, not fatal.** Edit `smoke` to add a line that is only `=`.
      After saving, the row reads "1 line could not be read" next to its term count, and
      dictation still corrects the pack's remaining term.
- [ ] **An unreadable pack is named, not hidden.** `chmod 000` one `.txt` file in the folder and
      click **Reload**: the section shows an orange message naming that file, and the other
      packs still appear and still work. `chmod 644` it again and Reload: the message clears.
- [ ] **A malformed `packs.json` says so and dictation keeps working.** Write `not json` into
      `packs.json` and click **Reload**: an orange message says the config could not be read,
      every pack shows unchecked, and dictating still inserts text (uncorrected). Tick a pack to
      rewrite the file and confirm the message clears.
- [ ] **Show in Finder opens the folder.** Click **Show in Finder**: the Vocabulary folder opens
      with the packs and `README.md` in it.

## Post-dictation review panel (hotkey #1, with the glossary on)

The panel is an `NSPanel` over a real frontmost application; nothing below is reachable from
unit tests. Enable the `typescript` pack and turn **Correct recognised terms** on first.

- [ ] **The panel appears and the caret never moves.** Click into a TextEdit document so the
      caret is blinking, then dictate a sentence containing a glossary term — for example
      «Открой tsconfig json». The corrected text lands in TextEdit, the panel appears
      top-centre of the screen the mouse is on, **below the recording HUD's band**, and
      **the TextEdit caret is still blinking in
      the document**, with TextEdit still the active app (its title bar keeps its colour).
      This is the step that proves focus never moved; do not skip it and do not accept
      "the text arrived" as a substitute — a panel that took focus would have swallowed the
      paste.
- [ ] **The success HUD does not cover the panel.** In the same run, the green **Inserted**
      HUD appears above the panel and fades on its own; the marked sentence stays readable
      the whole time.
- [ ] **The panel marks what changed and names the source.** `tsconfig.json` carries a green
      underline in the same weight and colour as the rest of the sentence — it is not
      recoloured — and the line beneath reads `typescript · 1 correction`.
- [ ] **Hovering a marked span shows what the recogniser produced.** Rest the pointer on the
      underlined term: a tooltip shows the original spelling (`tsconfig json`).
- [ ] **Hovering holds the panel open; leaving lets it go.** Move the pointer into the panel
      before two seconds are up and keep it there for ten — the panel stays. Move the pointer
      away and the panel disappears about two seconds later.
- [ ] **A second dictation replaces the content rather than stacking.** While the panel is
      visible, dictate another sentence with a glossary term: one panel remains, showing the
      new text and the new caption, and its two seconds start again.
- [ ] **The panel is visible above a full-screen application.** Put TextEdit into full screen,
      dictate a sentence with a glossary term, and the panel appears over it.
- [ ] **No panel when nothing was corrected.** Dictate a sentence with no glossary term, and
      with the master switch off dictate one that does contain a term: nothing appears either
      time.
- [ ] **A panel never outlives its dictation.** While a panel is visible, start another
      dictation and cancel it with Esc (or let it fail — unplug the network with an endpoint
      backend): the earlier panel disappears the moment the new recording starts, rather than
      staying on screen describing text the user has moved past.

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
- [ ] With Dictation mode = Toggle: press once to start. A recording HUD with a microphone
      indicator says "Press the hotkey again to transcribe." Press again to stop; the HUD
      changes to "Transcribing…", then the Quick Panel opens.
- [ ] Say nothing and release: the HUD's "Transcribing…" disappears, a "Nothing heard." toast
      appears, and no panel opens.
- [ ] Click Insert on either side: the text lands in the app that was frontmost when the
      hotkey fired (not in the panel), and the panel closes.
- [ ] Deny microphone permission in System Settings, trigger the hotkey: the permission error
      toast appears with a link to the correct System Settings pane. Re-grant afterwards.

## Dictation history

Use a recognizable short sentence for each successful recording in this section. Unless a check
says otherwise, “Save the original recording” (Settings ▸ General) is off, so only text is kept.

- [ ] **Default off and persistence.** On a fresh settings document, the menubar’s Dictation
      History section shows “Save dictation history” off while “Dictation History…” remains
      available. Enable it, quit and relaunch, and confirm it remains enabled; turn it off again
      and confirm it also remains off after relaunch.
- [ ] **Menu control and single window.** “Dictation History…” sits between the action controls
      and the model/translation selectors whether history recording is enabled or not. Open it
      twice from the menubar: the existing Dictation History window is activated rather than a
      second window appearing. Disable the setting while it is open; the existing entries remain
      usable, the item stays available, and new Dictate or Dictate & Refine transcripts are not
      added until history is enabled again.
- [ ] **Both microphone actions record.** Enable history, use Dictate for one recognizable
      sentence and Dictate & Refine for another, then open History. Both complete original
      transcripts appear with the Dictation and Dictation & Refine labels; with “Save the
      original recording” off, no Play control is offered on either row.
- [ ] **Excluded flows.** With history enabled, run Refine Selection, cancel a Dictate while
      recording or transcribing, dictate silence/blank text, and force a transcription failure
      (for example by selecting a missing model). None creates an entry.
- [ ] **Newest-first cursor paging and complete Copy.** With more entries than the initial page,
      fetch page 1 and note its oldest visible entry. Before fetching page 2, record a new
      recognizable transcript; then scroll to the last visible row. The older page continues from
      the noted entry with no duplicates or gaps, and loading a further older page remains stable
      despite the new row (an offset-based page would shift). Use a transcript longer than its row
      preview, click that row’s accessible Copy button, and paste elsewhere: the complete
      transcript—not the truncated preview—is pasted.
- [ ] **100,000-entry retention fixture.** Before launching the app, prepare a disposable
      `dictation-history.sqlite3` fixture containing 100,000 sequential entries. Enable history,
      record one more recognizable transcript, and confirm the new entry is present, the oldest
      fixture entry is gone, and the count remains 100,000.
- [ ] **Clear and disable behavior.** With several entries present, choose Clear History… and
      dismiss the confirmation: entries remain. Confirm Clear History: the empty state appears.
      Add an entry, disable history, and confirm existing entries remain visible while a new
      Dictate or Dictate & Refine transcript is not added.
- [ ] **Storage-error recovery.** With history enabled, make its Application Support directory
      temporarily unwritable, then dictate. The transcript still inserts or reaches Dictate &
      Refine, and a non-fatal history error is shown with recovery guidance. Separately, open a
      corrupt disposable database: the history window renders its error state, and confirmed
      Clear History restores an empty usable database.
- [ ] **Dock lifecycle.** With no Settings or onboarding window open, opening Dictation History
      makes the Dock icon appear. Closing it removes the icon; if Settings is also open, closing
      History leaves the icon visible until Settings closes.

## Saved recordings

Everything here needs a real microphone, real files on disk and Finder, so none of it is
reachable from unit tests. Start with dictation history enabled.

- [ ] **A recording appears on disk.** Settings ▸ General: turn on “Save the original
      recording” — it is selectable only while “Save dictation history” is on. Dictate one
      recognizable sentence, then click “Show in Finder” next to “Saved audio”:
      `~/Library/Application Support/Macomprendo/dictation-audio/` opens in Finder and contains
      one new `.m4a` file. The “Saved audio:” readout in Settings shows a non-zero size.
- [ ] **Play back from the history window.** Open Dictation History: the new entry has a Play
      control. Click it — the recording plays and the control becomes Stop; click Stop and it
      returns to Play. Start one entry, then click Play on a second: the first stops and only
      the second is heard. Older entries recorded before the setting was on offer no Play
      control.
- [ ] **The file plays outside the app.** Double-click the `.m4a` in Finder: it opens in the
      default player (QuickTime Player, not GarageBand) and is audible.
- [ ] **Lossless recording really is lossless.** Settings ▸ General: set “Recording quality” to
      “Lossless (ALAC, ~1.11 MB/min)” — the picker is selectable only while “Save the original
      recording” is on. Dictate one recognizable sentence, then run
      `afinfo ~/Library/Application\ Support/Macomprendo/dictation-audio/<id>.m4a`: the data
      format reads `alac`, not `aac`, and the file is roughly three times the size of a
      compressed recording of the same length. Play it from the history window: it plays.
- [ ] **Switching format between two dictations leaves both playable.** Set the quality back to
      “Compressed (AAC, ~0.35 MB/min)” and dictate again. `afinfo` reports `aac` for the new
      file and still `alac` for the previous one, both entries play from the history window, and
      both are `.m4a`.
- [ ] **The size readout tracks the larger files.** Note the “Saved audio:” figure, dictate one
      sentence of roughly the same length in each quality, and compare how much the figure grows
      each time: the lossless dictation adds several times more than the compressed one.
- [ ] **A recording deleted behind the app's back reports itself and stays retryable.** With the
      history window open, delete one entry's `.m4a` from `dictation-audio/` in Finder, then
      click that entry's Play control: the error names the missing file — "The saved recording
      is no longer on disk." — and does **not** blame the output device. The Play control stays
      where it is rather than disappearing, because the entry still records that a recording was
      made. Put the file back (Undo in Finder) and click Play again: it plays.
- [ ] **The window and the size readout follow a new dictation live.** Leave Dictation History
      open, leave Settings ▸ General open beside it, and dictate: the new entry appears at the
      top of the window without reopening it, and the "Saved audio:" readout grows — neither
      needs the window closed and opened again.
- [ ] **The length limit stops the recording and says why.** Settings ▸ Dictation: set
      “Maximum recording length” to 1 minute. Start a dictation in Toggle mode and keep talking
      past a minute without pressing the hotkey: recording stops on its own, transcription runs,
      and the HUD reads “Stopped at the 1-minute limit” rather than “Inserted”. Restore the
      length you normally use afterwards.
- [ ] **Turning the setting off preserves existing recordings.** Turn “Save the original
      recording” off, dictate again, and reopen History: the new entry has no Play control while
      the earlier ones still play, and the `.m4a` files already in `dictation-audio/` are still
      there.
- [ ] **Delete saved audio keeps the transcripts.** Settings ▸ General ▸ “Delete saved audio…”,
      dismiss the confirmation: the files remain. Confirm it: `dictation-audio/` is empty, the
      “Saved audio:” readout shows zero, and Dictation History still lists every transcript,
      now with no Play controls.
- [ ] **Clear History empties the directory.** Turn the recording setting back on, dictate twice
      so files exist again, then confirm Clear History: the history window shows its empty state
      and `dictation-audio/` contains no files.
- [ ] **Age retention deletes entries and recordings together.** With entries and their
      recordings present, set Settings ▸ General ▸ “Keep history for” to 1 day and — using a
      disposable database — back-date an entry by more than a day before relaunching (or leave
      the Mac until the next day). After the next launch that entry is gone from the history
      window and its `.m4a` is gone from `dictation-audio/`.

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
- [ ] Settings ▸ Speech: switching sub-tabs leaves the selector and the status block unchanged.
- [ ] Preview is the first section inside System voices, Local TTS and Endpoint.
- [ ] System voices and Local TTS show sections in this order after Preview: mixed-language
      switching, parameters, voice choices, then per-language mappings. Both mixed-language
      switches are on with fresh settings.
- [ ] Each language in the System and Local TTS voice choices and mappings has its own visible
      container. Models and controls from adjacent languages do not run together.
- [ ] Selecting Endpoint with no saved API key shows "Not ready" and an "Add a key" button that
      opens the Endpoint tab with the key field focused.
- [ ] With Local TTS selected and no voice chosen, ⌥S shows a toast naming the problem and
      speaks nothing.
- [ ] Preview speaks through the active source, not through the viewed tab.
- [ ] In Local TTS, download **Piper — Ruslan (Russian)**. Progress advances to 100%, the row
      stays unavailable while the archive is being verified/extracted, then reads “Downloaded”.
- [ ] Choose Ruslan, activate Local TTS, enter a Russian preview sentence and click Preview — the
      sentence is audible. Select different Russian text in TextEdit and press ⌥S — that exact
      selection is read by the same local voice; press ⌥S again and playback stops immediately.
- [ ] Disconnect the Mac from the network after Ruslan is downloaded and repeat Preview and ⌥S —
      both still work. Reconnect when finished.
- [ ] While Local TTS is active, delete Ruslan and press Preview or ⌥S — a not-downloaded error is
      shown and System speech does not play. Downloading the same voice again restores Local TTS.
- [ ] Optional large-model check: download **Kokoro — Multilingual**, choose Speaker 102, preview
      English and Chinese text, then switch to a single-speaker Piper voice — Speaker clamps to 0
      and the Piper preview still succeeds.
- [ ] Local voices are grouped under localized language headings. Kokoro appears under both
      English and Chinese; selecting its Chinese row auditions a Chinese phrase, and downloading
      or deleting it updates both rows consistently.
- [ ] Turn on **Switch voices for mixed-language text** for Local TTS. "Voice per language" shows
      downloaded voices only; an undownloaded voice never appears in a mapping picker.
- [ ] Turn that switch off. "Voice per language" remains visible but its controls are disabled;
      Preview reads the whole text with the default Local voice.
- [ ] Download one Russian Piper voice and one English Piper voice. Keep Russian as the default,
      map English to the downloaded English voice, and Preview a long Russian → English → Russian
      passage. All three runs play in order and the first voice returns for the final run.
- [ ] With Kokoro downloaded, map English and Chinese to Kokoro with two different speakers.
      Preview a long English → Chinese → English passage: the speaker changes for Chinese and
      returns for English without loading a different model.
- [ ] During a mixed Local Preview, Pause and Resume continue the same passage; Stop prevents all
      remaining runs from playing. A second Speak hotkey press has the same stop behaviour.
- [ ] Delete a voice used only by a language mapping. The picker reads Auto and Preview selects a
      compatible downloaded Local voice (or the selected Local default); it never plays System
      speech. Delete the selected default too: Local becomes Not ready and Preview/⌥S reports the
      Local error without playing anything.

The production download → checksum → extraction → native generation → WAV path also has an opt-in
network smoke test (about 67 MB):

```bash
MACOMPRENDO_RUN_LOCAL_TTS_SMOKE=1 swift test --package-path macos \
  --filter LocalTTSIntegrationTests.realPiperRoundTrip
```

It writes `/tmp/macomprendo-local-tts-integration-ruslan-smoke.wav` and is disabled in the default
suite.

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
- [ ] Select text containing a substantial Chinese or Arabic run mixed into English and press ⌥S:
      nothing crashes; when a matching installed System voice exists it may switch at that script
      boundary, otherwise the configured voice remains the safe fallback.
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

## Menubar panel

The status item is app-owned (`StatusItemController`): one `NSStatusItem` and an `.applicationDefined`
`NSPopover` hosting the SwiftUI `MenuPanelView`. Left and right clicks toggle the same panel.
The pure presentation rules are unit-tested; everything below needs a pointer, a real recording
or the window server.

- [ ] **Hover stays put while the meters move.** During a real call, hold the pointer still over
      **Stop Recording** and over a different row while the level meters and the clock update:
      the highlight and the hit target stay fixed, no row moves or resizes, and clicking Stop
      works. This is the check the old `.menu` surface could never pass.
- [ ] **Transcription progress matches the Transcripts window.** Start a file transcription and
      open the panel: the card shows the title, `Transcribing file`, the processed position and
      duration, and the same integer percent as the Transcripts window. Close that window: the
      card stays. Click the card: the panel closes, Transcripts opens (or comes forward) with the
      running transcript selected. On completion or cancellation the card disappears. Repeat for
      a call: the card names `Me` / `Others` per track with the processed/total clock and **no**
      percentage — one track's ratio is never presented as the whole call.
- [ ] **Concurrent recording and transcription.** Record a call and transcribe a file at the
      same time: both the call block and the progress card show, a second job or a call-track
      transition does not disturb the recording indicator, and the status item keeps the
      recording clock first.
- [ ] **Clicks, Escape and keyboard shortcuts.** Left click, right click and a repeat click each
      toggle the same panel; a click into another app and into an existing Macomprendo window
      dismisses it; Escape closes it; keyboard focus moves through the rows; ⌘, opens Settings
      and ⌘Q quits from the key panel; the status button's highlight is never left stuck.
- [ ] **Every window command works after a cold launch.** Launch the app (no window opens) and,
      before Settings has ever appeared, use each command: **Transcribe File…** (chooser opens,
      cancelling starts nothing — no row, no job — and choosing a file starts the job and opens
      Transcripts), **Transcripts…**, **Dictation History…**, **Settings…**, **Check
      permissions…** and **About Macomprendo…**. The three pickers' menus open, each translation
      target renders, and the model picker shows every availability state (ready, not ready,
      nothing ready at all).
- [ ] **Show All Windows.** With several windows open, one minimized and none duplicated, run
      it: the panel closes, the app activates, the minimized window restores, every existing
      window comes forward, no window is created and no work restarts. With no eligible windows
      the row is disabled and its tooltip reads "No Macomprendo windows are open". With the
      onboarding window closed but retained it stays closed, and an excluded overlay (the HUD,
      the correction panel) never gains focus. With the Quick Panel streaming, raising it does
      not stop or restart its stream.
- [ ] **The microphone picker follows devices on both surfaces.** With Settings ▸ General and the
      panel open at once, connect, disconnect and change a device: both pickers update. Close one
      surface and change a device again: the other still updates. The persisted selection is not
      reset by closing the panel, and a chosen-but-disconnected device stays listed and selected
      with the fallback caption; actual capture follows the existing input policy.
- [ ] **Appearance.** Switch System, Light and Dark while the panel is open, then reopen it after
      a theme change: the native popover material and arrow, text, picker menus, disabled rows,
      hover and selected colours, meters and progress all stay readable. Check a non-blue accent,
      Increase Contrast, Reduce Transparency and Reduce Motion (meter ticks step instead of
      animating), and a menu-bar wallpaper whose contrast differs from the panel's theme.
- [ ] **Small screens and long labels.** On a short visible screen height and with multiple
      displays: **Options** and Quit remain reachable, Stop stays accessible, the region below
      the call and progress blocks scrolls as one region, and a long device, model or error label
      truncates instead of widening the panel or covering a shortcut.
- [ ] **VoiceOver.** With VoiceOver on, the recording state, each level meter, the progress card
      and every switch announce their state and hint, levels are not spoken ten times a second,
      and dismissing the panel or changing the theme cancels no background work.
- [ ] **Shortcuts are re-read on every opening.** Rebind "Refine selection" in Settings ▸
      Hotkeys with the panel closed, then open **Options**: the new shortcut appears beside its
      switch on that first opening. An action with no shortcut shows none — never "not set".
- [ ] **Opening the running app again.** With Transcripts open behind another app, open
      Macomprendo from Finder or Spotlight: Transcripts comes forward and the panel stays closed.
      Open it again: the panel opens. With no window open, the first opening shows the panel.
      With a call recording, a long clock (`MM:SS`) still leaves the item left of the notch.

## Menubar hotkey display, per-language voices and prompt language

| Step | Expected |
|---|---|
| Rebind "Refine selection" in Settings ▸ Hotkeys, then open the panel ▸ Options | Each switch's trailing annotation shows its current shortcut; an unbound action shows none. The annotations are read on every opening, so a rebind made in Settings appears without relaunching. |
| Panel ▸ Microphone / Dictation model / Translate into | Microphone lists System default (naming the current device), connected inputs and the selected disconnected one; the model list offers every ready source (`whisper.cpp —` prefixed) plus the active one when it is not ready, and is disabled when nothing is ready; "Translate into" offers the system and prompt languages plus every fixed target, and the choice persists after relaunch and is used by a Translate preset. |
| Panel ▸ Transcribe File… → Cancel | No job starts: no transcript row, no progress card, nothing transcribed. |
| Settings ▸ Dictation | The speech-model list is here and the Models tab is gone |
| Settings ▸ Speech, pick a voice under "Voice per language" | A short phrase is heard immediately in that voice and in that language |
| Turn off "Play a sample when a voice is selected", pick another voice | Nothing is heard |
| Edit the preview text, press Preview | The edited text is read, switching voices at the script boundary |
| Turn off "Switch voices for mixed-language text", press Preview | The whole text is read by the default voice, in one go |
| Refine a selection, press the speak button in the Refined pane | The refined text is read; no "Speaking…" HUD appears over the panel |
| Press pause, then resume, on both speech sources (System voices and Endpoint) | Playback stops and continues where it left off, identically on both |
| Press pause on the Endpoint source before the first chunk has finished synthesising, then resume | Nothing plays until resume; resume then plays that first chunk from the start, instead of it being dropped or played twice |
| Start Speak in the Original pane, then press Speak in the Refined pane | Original's control reverts to its idle icon; only the Refined text plays — never both at once |
| Press Stop while a pane is reading | Playback stops immediately and the control reverts to its idle Speak icon |
| Start a read in a pane, then dismiss the panel (Esc, Insert, or Replace selection) | Playback stops with the panel — it has no controls and no HUD once the panel is gone |
| Press ⌥S to read a selection, open the Quick Panel over it, then dismiss the panel | The hotkey read keeps playing and keeps its "Speaking…" HUD; only ⌥S stops it |
| Pause the Original pane's read, then press Speak in the Refined pane | The refined text is heard — a `speak` issued while the synthesizer sits paused must not be swallowed |
| While the panel is reading, press ⌥S | Playback stops; the selection is not re-read (one hotkey press never starts a second, overlapping read) |
| Switch the language in the panel's globe menu | The preset list becomes that language's and the text is reprocessed |

> Seeking, scrubbing and a playback progress indicator are deliberately absent: `AVSpeechSynthesizer`
> exposes no position, so a scrubber could not behave the same on both speech sources. Pause/resume
> is the shipped scope — do not treat their absence as a bug.

## About window

| Step | Expected |
|---|---|
| Menubar ▸ "About Macomprendo…" | The window opens **in front of** every other app's windows, not behind them. A Dock icon appears while it is up and goes away when it closes (it is another `DockIconCoordinator` owner, alongside Settings and the wizard) |
| Read the header | The version and build match the build under test — compare against `Macomprendo.app ▸ Get Info`, or `defaults read …/Contents/Info CFBundleShortVersionString` and `CFBundleVersion` |
| Look at the disclosure block **without scrolling and without resizing the window** | It is fully legible at the window's default size and says all three things: the application as distributed is **GPL-3.0**, Macomprendo's own source is MIT, and the corresponding source is public (this app and sherpa-onnx) |
| Click "Privacy statement" | The browser opens `https://dzamataev.github.io/macomprendo/privacy/` and the live page loads — not a 404 |
| Look at the component list on first open | `whisper.cpp` is already selected and its licence text is showing; the pane is never blank |
| Select `espeak-ng`, `sherpa-onnx`, `onnxruntime` and `Phosphor Icons` in turn | Each shows its own full licence text. Scroll each to the end: the text finishes with its real closing paragraph, with no "…" and nothing cut off |
| Drag-select a paragraph of a licence and press ⌘C | The text is selectable and copies verbatim |
| Click a component's homepage link | The browser opens that project's page |
| Close the window, reopen it from the menubar | The component you last selected is still selected — reopening must not reset it |
| Narrow the window as far as it goes | It stops shrinking well before the licence text's hard-wrapped lines reflow illegibly |

> The window is a SwiftUI `Window` scene like Dictation History. If the Dock icon lingers
> after closing it, that is the same `.onDisappear` caveat recorded under **Dock icon**.

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
- [ ] The GitHub Actions **CI** workflow is green on `main` for the commit being released.

### After the tag is pushed

The `Release` workflow runs on every `vX.Y.Z` tag and publishes the release itself.

- [ ] The `Release` run for the tag is green (`gh run list --workflow Release`).
- [ ] The release contains exactly one platform ZIP mode and its matching `.sha256`:
      - without signing secrets: `Macomprendo-<version>-macos-unsigned.zip`;
      - with signing secrets: `Macomprendo-<version>-macos.zip`.
      In both modes, confirm the notes came from `CHANGELOG.md`.
- [ ] Download that ZIP and sidecar; `shasum -a 256 -c <sidecar>` reports `OK`.
- [ ] `lipo -archs` on the expanded app and both embedded frameworks prints `x86_64 arm64`.
- [ ] For an unsigned-mode release, `codesign -dv` reports `adhoc` and no notarization is
      expected.
- [ ] For a signed-mode release, `codesign -dv` reports the Developer ID Application authority,
      `xcrun stapler validate` succeeds, and `spctl --assess --type execute --verbose=4` reports
      `source=Notarized Developer ID`. The tag workflow performs this path automatically when
      all signing secrets are configured; do not run a second local release to replace it.

### Build artifact

- [ ] `npm run build -- --arch arm64,x86_64` succeeds.
- [ ] `lipo -archs dist/Macomprendo.app/Contents/MacOS/Macomprendo` prints `x86_64 arm64`.
- [ ] `ls dist/Macomprendo.app` contains only `Contents`; no resource bundle sits beside it.
- [ ] `ls dist/Macomprendo.app/Contents/Resources` contains `AppIcon.icns`, `LICENSE`, `Icons`,
      and `KeyboardShortcuts_KeyboardShortcuts.bundle`.
- [ ] `find dist/Macomprendo.app/Contents/Resources/Icons -type f | wc -l` prints a number
      greater than zero. This is the actual proof the vendored Phosphor SVGs shipped inside the
      app — the menubar heart uses its separate `StatusItem` resource folder, and missing
      icons degrade to SF Symbol fallbacks instead of making the process crash.
- [ ] `ls dist/Macomprendo.app/Contents/Frameworks` contains `whisper.framework` and
      `SherpaOnnxC.framework` — both are dynamically linked (confirm with
      `otool -L dist/Macomprendo.app/Contents/MacOS/Macomprendo | grep -E 'whisper|SherpaOnnxC'`),
      so this directory must be present, not absent. See DISTRIBUTING.md → "Xcode app layout"
      if a future vendored xcframework bump changes this.
- [ ] `codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app` reports the bundle as
      valid on disk and satisfying its designated requirement.
- [ ] `nm dist/Macomprendo.app/Contents/MacOS/Macomprendo | grep __llvm_profile` prints nothing
      and exits nonzero. Release builds must not carry test-coverage instrumentation or write
      `default.profraw` into their launch directory.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Macomprendo.app/Contents/Info.plist`
      prints `com.dzamataev.macomprendo`.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' …` matches
      `MARKETING_VERSION` in `macos/project.yml`.
- [ ] Remove `dist/.derived-data`, then launch
      `dist/Macomprendo.app/Contents/MacOS/Macomprendo`. It remains running for at least five
      seconds and the log contains no resource-bundle fatal error. This catches an app that only
      works while Xcode's build products are still available. Confirm the launch directory gains
      no `.profraw` file.

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

- [ ] `npm run install-app:signed` installs into `/Applications` and relaunches the app without
      invalidating existing TCC grants.
- [ ] Running it a second time while the app is open quits the running copy and relaunches it.
- [ ] No `.macomprendo-update.*` directory is left behind in the install directory.
- [ ] On a fresh user account, onboarding asks for Microphone, then Accessibility, and the
      System Settings deep links open the correct panes.

### Manual verification (human only — no agent can perform these)

- [ ] **Icons in Settings look like Phosphor glyphs, not system symbols.** Open Settings and
      look at any tab with icons (Hotkeys, Providers, Models…). Every icon in the app is drawn
      by `Icon.swift`, which loads a vendored Phosphor SVG from the app's `Icons/` resources
      (see ADR-0008) — Phosphor's glyphs have a noticeably different weight and shape from
      Apple's SF Symbols. If the SVG can't be found, `Icon.swift` falls back **silently** to a
      similar but not identical SF Symbol (`AppIcon.fallbackSymbol`) — no error, no log line, and
      the app keeps running normally. So this row is a judgement call about how the icons *look*,
      not a pass/fail the app itself reports, and a "yes, they look like Phosphor icons" here is
      the closest a human glance gets to confirming the resources loaded — it is not conclusive on
      its own (use the `find`/`wc -l` check in Build artifact for that). The status item is not
      evidence either way: `StatusItemController` loads the custom heart from `StatusItem/`,
      not `Icons/`, and uses `record.circle` during recording (AGENTS.md invariant 12).
- [ ] **The status-item heart stays legible at 1× and 2×.** Check light/dark menu bars and
      the highlighted button: a filled heart with three waveform bars cut out of it, the
      bars still separate. Recording still shows `record.circle`.
- [ ] **Dictation produces a transcript.** Press the dictation hotkey once, say a sentence, and
      confirm text is inserted. This is the only proof that the whisper xcframework
      (`whisper.framework`, dynamically linked — see ADR-0007) actually loaded and ran on this
      machine; a linking or Metal-resource problem would only surface here, not in a headless
      test or a dry run.

### Documentation

- [ ] `CHANGELOG.md` has entries under `## [Unreleased]` describing everything in this release.
- [ ] `README.md` install instructions match the artifact names actually produced.
- [ ] `DISTRIBUTING.md` lists the resources and frameworks in the current Xcode app product.

## sherpa-onnx local transcription (GigaAM, Parakeet)

Run these checks from the signed `dist/Macomprendo.app` assembled by the release build above,
not from an Xcode or `swift run` development build. They are the acceptance gate for the real
sherpa-onnx recognizer and ONNX decode path.

1. Settings ▸ Dictation ▸ sherpa-onnx. Download each of the five models to completion. After each
   download, click "Use this model" (or select it in the active-model selector) and confirm
   the status block turns to "Ready to use".
2. With `gigaam-v3-e2e-ctc` selected, dictate a Russian sentence containing a number.
   Expect punctuation, capitalisation, and the number spelled out.
3. Repeat with `gigaam-v3-e2e-rnnt`: same expectations, and no crash on the four-file set.
4. With `gigaam-multilingual-ctc` selected, dictate Russian: expect correct words with **no**
   punctuation and no capitals. Then dictate English and confirm it transcribes at all.
5. Repeat step 4 with `gigaam-multilingual-large-ctc`. Neither multilingual entry has an
   upstream sherpa-onnx export, so nobody has verified their embedded ONNX metadata for us:
   confirm the model loads rather than failing inside sherpa.
6. With `parakeet-tdt-0.6b-v3` selected, dictate a Russian sentence, then an English one
   without changing anything: both come out with punctuation and capitals in their own
   language. Before downloading, the model's brief names CC BY 4.0. The decode path itself is
   also covered by `MACOMPRENDO_PARAKEET_DIR=<dir> swift test --package-path macos --filter
   parakeetTranscribesRealSpeech`, where `<dir>` holds sherpa's four file names and 16 kHz
   mono WAVs under `test_wavs/`.
7. Switch between two GigaAM models and dictate after each. Memory in Activity Monitor
   returns to roughly its previous level, showing the old recognizer was freed.
8. Start a dictation, then press the hotkey again mid-transcription: the first task is
   cancelled and no text is inserted twice.
9. The HUD names the active model while recording, and does not name it while Speak plays.
10. Make a downloaded GigaAM model active, delete it from its row while it remains selected,
   then press the dictation hotkey: the failure names the missing model rather than failing
   opaquely.

## File transcription

The decoder is `AVAssetReader` and the VAD model is bundled, so nothing here is reachable from a
headless test. Use the signed `npm run install-app:signed` build and real files.

- [ ] **mp3, m4a and an mp4 with video all transcribe.** For each, use **Transcribe File…**, pick
      the file: the Transcripts window opens, a row appears as soon as the job starts, the detail
      shows `Transcribing — mm:ss / mm:ss` with a **Cancel** button, segments land as
      `[hh:mm:ss] text`, and the finished row loses its badge and is selected.
- [ ] **A video with no audio track fails cleanly.** Try a video that has no audio: the job fails
      with **This file has no audio track.** and its recovery text, and no transcript row is left
      behind.
- [ ] **An hour-long file keeps memory flat and progress moving.** Transcribe a long podcast and
      watch Activity Monitor: memory stays flat (the file is decoded one chunk at a time; peak
      memory tracks the model, not the length) and the progress line advances to the end without
      jumping backwards.
- [ ] **A dropped file starts a job.** With no transcript selected, drop an audio or video file on
      the window body: the job starts, the drop zone shows the file name and its progress, and the
      row appears as segments land.
- [ ] **Starting a job while one runs cancels the first.** Start a long file, then start another:
      the first row becomes **Incomplete** with reason **Cancelled.**, keeps the segments it had,
      and the new job runs.
- [ ] **Dictating while a file transcribes.** Start a file job on a long file, then dictate a
      sentence: the dictation inserts as usual while the file job keeps going. The dictation waits
      at most for the segment in flight; the file job is not cancelled.
- [ ] **Each of the three backends transcribes a file.** Run the same short file with a local
      whisper model, a sherpa-onnx model, and an OpenAI-compatible endpoint: all three write
      segments. With a backend that is not ready, the job fails before any decoding with the
      backend's reason, and no row appears.
- [ ] **Quit mid-job, relaunch, Incomplete and Resume.** With the local whisper model selected,
      start a long file and quit Macomprendo from the menu while it runs. The app quits without a
      crash report (Console ▸ Crash Reports), pausing at most a second or two while the in-flight
      segment finishes. Relaunch: the transcript is **Incomplete** with reason **Macomprendo quit
      before it finished.** Click **Resume**: it continues from the last stored segment and
      completes.
- [ ] **Resume after the source moved or was deleted.** Make an `incomplete` transcript, then move
      or delete its source file. Click **Resume**: the window reports **The original file can no
      longer be found.** and offers **Choose File…**. Choose the file — at its new location, or a
      fresh copy: the job resumes from the same position and the chosen file becomes the bookmark,
      so a later **Resume** finds it.
- [ ] **Summarize opens the Quick Panel without Replace selection.** Select a completed transcript
      and click **Summarize**: the Summarize Quick Panel opens with the transcript's plain text (no
      timestamps), the Summarize feature's model and presets, and no **Replace selection**. Copy
      pastes the summary, and the panel closes without changing the transcript. Then press ⌥M
      (Summarize selection) and confirm **Replace selection** is back for the hotkey path.
- [ ] **Delete from the list.** Right-click a transcript that is not the open one ▸ **Delete…**:
  a sheet asks, with **Also move the source file to the Trash** (a call: **…the call
  recording…**) checked. Delete: the row goes, the open transcript stays open, and the source
  file / the recording folder is in the Trash (Put Back works). Uncheck the box: the source stays
  where it was. Cancel deletes nothing. A source already moved elsewhere: the transcript is still
  deleted. A source the Trash refuses (e.g. a read-only volume): the transcript stays and the
  window says why. The action bar's Delete asks the same way.
- [ ] **Onboarding ▸ System audio (optional).** Menubar panel ▸ Check permissions…, step 3 of 5:
  **Allow system audio…** makes macOS ask once (after a reset of the permission); the step says
  "Asked…"; **Open System Settings** opens Privacy & Security ▸ Screen & System Audio Recording.
  Continue works without asking. With a call recording running, the step says system audio is
  already allowed and does not touch the recording.
- [ ] **Stop a transcription from the panel.** While a file or call is transcribing, the panel's
  progress card has **Stop**: the job stops, the panel stays open, the transcript is
  **Incomplete** with what was done; **Resume** continues it, **Transcribe Again** starts over.
- [ ] **Transcribe calls later.** Settings ▸ General ▸ Call recordings ▸ switch off **Transcribe a
  call as soon as it stops**, record and stop a call: no job starts; the transcript waits as
  Incomplete with "Not transcribed yet — press Resume to transcribe it."; Resume transcribes it.
  The panel's Options ▸ **Transcribe calls after Stop** is the same switch: flipping either
  updates the other.
- [ ] **No delete while transcribing.** While a transcript is being transcribed (a file job, or
  a call's tracks after Stop), its **Delete…** (context menu) and **Delete** (action bar) are
  disabled, the latter with the help "Cancel the transcription before deleting it"; after
  Cancel they work again. A call being recorded has no transcript yet, so nothing to delete.
- [ ] **Transcribe Again.** On a complete call transcript press **Transcribe Again** and confirm:
  the row goes to Transcribing, the old text is replaced, and the Me / Others turns interleave in
  the order they were spoken. With the source file moved, the job fails with **Choose File…** and
  the old text is still there.
- [ ] **Rename.** Right-click a transcript in the list ▸ **Rename**: the title becomes a field;
  Enter saves, Esc keeps the old title. Click the open transcript's title, type: the list row
  follows each keystroke; clearing the title and clicking away restores it. Relaunch: the new
  title is still there.
- [ ] **Export writes all three formats.** For a completed transcript use **Export ▸ Plain text
      (.txt)**, **Subtitles (.srt)** and **Markdown (.md)**: the `.txt` holds the segment lines with
      no timestamps; the `.srt` numbers cues from 1 with `HH:MM:SS,mmm --> HH:MM:SS,mmm` and opens
      in a player; the `.md` has a `#` title, a metadata line (date, duration, model) and
      `**[hh:mm:ss]**` lines under `## Transcript`. Export to a folder you cannot write to: an error
      banner names the failure and the window stays open.
- [ ] **A WebM file fails as unreadable.** Try the same recording as WebM/Opus: the job fails with
      **Macomprendo cannot read this file…** (AVFoundation cannot open WebM), the recovery text
      suggests QuickTime Player, and no row is left behind.
- [ ] **Delete removes the transcript and keeps the source.** Delete a transcript and confirm: the
      row and its segments go, the source file on disk is untouched, and the confirmation says so.
- [ ] **No transcript text in the log.** With Console.app filtered on subsystem
      `com.dzamataev.macomprendo`, transcribe a file and Summarize it: no log line contains segment
      or summary text.

### Opt-in long-audio tests

Two suites run only when their environment variables point at real recordings, and they are skipped
in the default `swift test` run. Recordings and benchmark output live in the gitignored `.media/`.

- [ ] **Real-recording regression test.** Point it at a recording and a UTF-8 file holding one
      expected phrase per line, then run:

```bash
MACOMPRENDO_LONG_AUDIO_FIXTURE=<recording> \
MACOMPRENDO_LONG_AUDIO_EXPECT=<phrases file> \
MACOMPRENDO_LONG_AUDIO_LANGUAGE=ru \
swift test --package-path macos --filter LongAudioRecordingTests
```

      Every phrase must appear in the joined, normalised transcript. `MACOMPRENDO_LONG_AUDIO_MODEL`
      overrides the whisper model (default
      `~/Library/Application Support/Macomprendo/models/ggml-large-v3-turbo.bin`). Segment
      boundaries drift a little between decodes of the same file; a missing phrase is a failure,
      the drift is not.

- [ ] **Benchmark gym.** Run one recording through the production pipeline once per catalog model:

```bash
MACOMPRENDO_BENCH_FIXTURE=<recording> \
MACOMPRENDO_BENCH_OUT=.media/bench/<date> \
MACOMPRENDO_BENCH_MODELS=large-v3-turbo,gigaam-v3-e2e-rnnt,parakeet-tdt-0.6b-v3 \
MACOMPRENDO_BENCH_LANGUAGE=ru \
MACOMPRENDO_BENCH_REFERENCE=<.txt or .srt reference> \
swift test --package-path macos --filter LongAudioBenchmarkTests
```

      It writes `<out>/<model>.txt`, `<out>/<model>.srt` and merges RTF, wall time, peak memory and
      WER/CER into `<out>/report.json`, releasing each model before the next. It fails only on
      errors, never on quality. `MACOMPRENDO_BENCH_LIMIT_SECONDS` stops a run early, and the models
      are read from `~/Library/Application Support/Macomprendo/models` — never downloaded.

## Call recording

The system side is a global Core Audio process tap (`ProcessTapSystemAudioCapture`): it hears
every process except Macomprendo, read through a private aggregate device built around the tap
alone. The tap is unmuted — the call keeps playing while it is recorded — and the first tap
raises the one-time **System Audio Recording** prompt (Privacy & Security ▸ Screen & System
Audio Recording).

- [ ] **Call over the built-in speakers.** Record a call playing through the Mac's speakers and
      check the **Others** track: the remote side is there, complete enough to transcribe, and
      the call itself kept playing.
- [ ] **Call over wired headphones.** Repeat with wired headphones: the Others track still holds
      the remote side.
- [ ] **Call over AirPods using the Mac's microphone.** Repeat with AirPods and the Mac's own
      microphone selected: the Others track holds the remote side while **Me** fills in.
- [ ] **Call over AirPods using their own microphone.** Repeat with the AirPods' microphone
      selected — the call runs in the hands-free profile: the Others track still holds the remote
      side.
- [ ] **Switching the output mid-call.** Start recording with the speakers, then switch the
      system output to AirPods (or headphones) during the call: the recording continues, the tap
      rebuilds on the new route within about a second, the Others track resumes with at most a
      short gap, and the app does not need a restart.
- [ ] **Declining System Audio Recording.** With the grant off or declined — turn Macomprendo off
      under Privacy & Security ▸ Screen & System Audio Recording, or answer **Don't Allow** on a
      first run — record a call: **Me** fills in, **Others** stays empty (no level movement, no
      Others segments in the transcript), and the recording still stops and transcribes normally.
- [ ] **Unplugging the chosen microphone mid-call.** Choose a USB or Bluetooth microphone in
      Settings ▸ General ▸ Microphone, start a recording and keep talking, then unplug it (or switch
      it off) while the call is still recording: the **Me** track continues on the fallback — the
      system default, then the built-in microphone — with at most a short gap where the device went
      away, and the recording does not stop. Plug it back in and the capture moves back to it; the
      recording still finalises and transcribes.
- [ ] **Dictating during a recording.** While a call is being recorded, press the dictation hotkey
      and dictate a sentence into TextEdit: it transcribes and inserts as usual, and the call
      recording keeps going — both level rows keep moving and the elapsed time keeps climbing. Stop
      the call afterwards: the recording is complete and both tracks are there.
- [ ] **The status item timer and the panel's call block.** Start a recording: the status item
      shows `record.circle` with the elapsed time beside it (`12:04`, `1:02:04` past an hour) and
      keeps counting while the panel is closed. Open the panel: the call block shows the red dot
      and `Recording call` with the same clock, the full-width **Stop Recording** button, then the
      two level rows `Me` and `Others`. Talk and play something through the Mac: both meters move
      while no row moves or resizes, and the clock's digits stay put.
- [ ] **Quit mid-recording, relaunch, Resume.** With the local whisper model selected, start a
      recording, talk, then quit Macomprendo from the menubar. The app exits without a crash report
      (Console ▸ Crash Reports). Relaunch: the recording is in the Transcripts window as
      **Incomplete** with reason **Macomprendo quit before it finished.**, its folder's
      `recording.json` now reads `finished`, and **Resume** transcribes both tracks.
- [ ] **Killing the app mid-recording, then relaunching.** Start a recording, talk for at least ten
      seconds, then kill the app outright (`pkill -9 Macomprendo`, or Force Quit): the two `.m4a`
      files are playable up to the last second (open them in QuickTime — at most the final second is
      lost), and `recording.json` still reads `recording`. Relaunch: the folder is finalised
      `finished`, an **Incomplete** call transcript appears with reason **Macomprendo quit before it
      finished.**, and **Resume** transcribes it. Launching once more creates no duplicate row.
- [ ] **A one-hour call keeps memory flat and the files play.** Record a call for about an hour with
      Activity Monitor open: memory stays flat — the encoder writes as it goes, and peak memory
      tracks nothing but the two writers — while the menu's elapsed time keeps advancing. Stop: both
      tracks finalise, play end to end in QuickTime without a gap, and the transcript covers the
      whole call.

## Automatic call recording

Detection reads Core Audio's process list once a second — locally, without touching the microphone
and without a permission — and starts and stops a recording through the ordinary **Record Call**
path. Off by default.

- [ ] **The switch.** Menubar panel ▸ **Options** ▸ *Record calls automatically*, and the same
      toggle in Settings ▸ General ▸ Call recordings: with it off, a call records nothing.
- [ ] **Using the microphone now.** Start QuickTime ▸ New Audio Recording (or hold the microphone
      in any app not on the list) with the switch on and open Settings ▸ General: the app appears
      under *Using the microphone now* within a second, with its real name. **Add** moves it into
      the list above and it leaves that block; a row's remove button takes it out again; **Restore
      Default Apps** puts the built-in list back.
- [ ] **A FaceTime call records itself.** Turn the switch on and call someone in FaceTime. About
      three seconds in, the recording starts by itself with the HUD toast `Recording call —
      FaceTime`; end the call and fifteen seconds later it stops with `Call ended — recording
      stopped`. The transcript appears in Transcripts, and both its level rows have audio.
      **While the call is running**, read the entry FaceTime shows under *Using the microphone
      now*: the built-in row assumes `com.apple.FaceTime`. If that is not what holds the
      microphone, press **Add**, note the real bundle ID here, and correct the spec's table.
- [ ] **A Safari Google Meet call records itself.** Join a Meet in Safari with someone talking:
      the browser row needs input and output at once, and Meet does both. Read Safari's bundle ID
      under *Using the microphone now* during the call and check it against
      `com.apple.WebKit.GPU`; correct as above if it differs.
- [ ] **A Telegram call records itself.** Repeat with Telegram and Telegram Desktop, and read the
      bundle ID that actually holds the microphone; correct `ru.keepcoder.Telegram` /
      `org.telegram.desktop` if it is not the one.
- [ ] **A short microphone blip starts nothing.** Hold the microphone for two seconds — Sound ▸
      Input's level meter, or a voice note you cancel — with the switch on: no recording starts.
- [ ] **Muting does not stop the recording.** Mute yourself in a running call for ten seconds: the
      recording keeps going (the fifteen-second grace covers apps that release the microphone
      while muted).
- [ ] **A hand stop is respected.** Stop an automatic recording from the panel: it does not start
      again for the rest of that call. A recording you started by hand is never stopped by the
      feature, and a call after the first one has really ended records again.
- [ ] **Quitting does not start a recording.** With a call running and the switch on, quit
      Macomprendo from the panel: the running recording is finalised as usual and nothing new
      starts on the way out.

## Live call transcription

Settings ▸ General ▸ **Transcribe calls**: **While recording**; a local model selected. The
live pass runs both tracks' pipelines on the background priority, so the panel and dictation stay
responsive.

- [ ] **The panel offers the live transcript.** Start a call that plays through the speakers (a
      video call, or a podcast plus speaking) and press **Record Call**: the panel shows **Show
      Live Transcript** under the two level rows. Nothing moves when it appears — Stop and both
      rows stay where they were.
- [ ] **It opens the live row.** Press **Show Live Transcript**: the panel closes, Transcripts
      opens with `Call <date>` selected, and its badge reads *In progress*. Speak a phrase and
      pause: within a few seconds a `Me:` row appears, and the remote side's phrases arrive as
      `Others:` rows in the order they were spoken.
- [ ] **Dictation still answers.** During the call, dictate into another app: it returns without a
      noticeable delay, and the live rows keep landing.
- [ ] **Stop finishes it.** Press **Stop Recording**: the progress row reads `Transcribing Me — …`,
      then the toast *Call transcript ready*; the transcript is *Complete*, shows its duration, and
      holds no duplicated phrase at the moment of Stop.
- [ ] **The other two modes stay quiet.** Repeat with **Manually** and **After recording**: no
      **Show Live Transcript** button and no live rows while recording, and Stop behaves as before.
- [ ] **Quit mid-call, then Resume.** Quit Macomprendo during a live recording: on relaunch the
      call is *Incomplete*, and **Resume** finishes it without duplicating the rows the live pass
      had already written.

## Transcript playback

The bar under the segment list is `AVPlayer` glue plus SwiftUI, so none of it is reachable from a
headless test. Playback needs no transcription: a transcript that is still being transcribed, or
is incomplete, plays whatever audio exists.

- [ ] **A file transcript plays, audio or video.** Open a finished file transcript and press
      **Play**: the sound plays, the time runs and the seek bar moves. Repeat with a video file's
      transcript: only its sound plays, with no picture.
- [ ] **A call transcript plays both sides.** Open a call transcript and press **Play**: the
      conversation plays in order, Me and Others interleaved at their recorded offsets. Switch
      **Me** off: only the other side is heard. Switch **Others** off instead: only your side.
      With both off, the time still advances in silence.
- [ ] **A call missing one track.** Delete one of the call's two track files and open the
      transcript: the other side still plays, and the missing side's toggle is disabled with the
      tooltip "This side's track is missing".
- [ ] **Every speed keeps the pitch.** Play a passage at 1.25×, 1.5× and 2×: speech is faster
      and keeps its pitch (no chipmunk voices). The chosen speed still applies to the next
      transcript opened in the window.
- [ ] **Dragging the seek bar seeks on release.** Drag the playhead: the bar follows the pointer
      while the audio keeps playing, and the audio jumps to the dropped position on release.
      Click a point on the bar without dragging: it seeks there too.
- [ ] **Clicking a timestamp plays from there.** Hover a segment's `[mm:ss]` — it underlines like
      a link — and click it: playback starts at that segment.
- [ ] **The marker follows the speech.** While playing, the segment being spoken is tinted and
      the list scrolls to keep it in view with a little context above it; a pause of more than a
      second unmarks it, and in a longer pause nothing is marked.
- [ ] **A manual scroll stops following; Back to current returns.** While playing, scroll the
      list by hand: following stops and **Back to current** appears over the list's bottom edge.
      Press it: the list scrolls back to the marker and follows again.
- [ ] **A moved source file shows the strip; Choose File… relinks playback.** Move a file
      transcript's source file, then open the transcript: the strip reads
      `Audio unavailable — the source file cannot be found` with **Choose File…**. Choose the
      file at its new location: playback loads from it and plays, and no transcription job
      starts. For a call, move its recording folder: **Choose Folder…** relinks it the same way.
- [ ] **Playback while dictating.** Start playback, then dictate a sentence: the dictation
      inserts as usual and the audio keeps playing.
- [ ] **Starting a call recording stops playback.** While a transcript plays, start a call
      recording: playback stops.
- [ ] **Closing the window stops playback.** Close the Transcripts window while audio plays:
      the sound stops.
