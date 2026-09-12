# Privacy

Macomprendo has no analytics, no crash reporting and no update checks. It never
phones home.

**What leaves your Mac.** Only requests you configure yourself:

- If transcription is set to a local whisper model, audio never leaves the Mac.
- If transcription is set to an endpoint, the recorded audio is uploaded to that
  endpoint's `/v1/audio/transcriptions`.
- System voices and Local TTS keep selected text and generated speech on the Mac.
- If speech is set to an endpoint, the selected text is sent to that endpoint's
  `/v1/audio/speech` route.
- Refine and summarize send the selected or dictated text to the endpoint you
  chose (Ollama on `http://localhost:11434` by default, which is also local).
- Local model archives and weights are fetched from their pinned Hugging Face or GitHub release
  URLs only when you ask to download them.

**What is stored.** Settings live in `UserDefaults` under the key `settings.v1`.
API keys live in the login Keychain under the service
`com.dzamataev.macomprendo` — never in settings, logs, or exported files.
Dictation history is off by default. When enabled, it stores accepted text from Dictate and
the original accepted microphone transcript from Dictate & Refine before any LLM processing, in
the local SQLite database at
`~/Library/Application Support/Macomprendo/dictation-history.sqlite3`.
The newest 100,000 entries are retained. Disabling history stops new writes but preserves
existing entries, while Clear History removes them.

**Saved recordings.** “Save the original recording” is off by default and has no effect unless
dictation history is on. While both are on, the microphone recording behind each history entry
is written as an AAC `.m4a` file (48 kbit/s, 16 kHz mono) into
`~/Library/Application Support/Macomprendo/dictation-audio/`, one file per entry. “Keep history
for” sets how long transcripts and their recordings are kept — 90 days by default — and anything
older is deleted automatically. Clear History deletes the transcripts and their recordings;
Delete saved audio removes the recordings and keeps the transcripts. Turning the setting off
stops new recordings but keeps the ones already on disk.

The database and the recordings are plaintext files protected by your macOS account and, when
enabled, FileVault. Macomprendo is deliberately not sandboxed, so any program running under your
macOS account can read them; the app adds no protection beyond the account itself.

**Logging.** Macomprendo logs to the unified system log under the subsystem
`com.dzamataev.macomprendo`. Transcript and LLM text are never logged at the
default level.
