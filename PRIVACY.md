# Privacy

Macomprendo has no analytics, no crash reporting and no update checks. It never
phones home.

**What leaves your Mac.** Only requests you configure yourself:

- If transcription is set to a local whisper model, audio never leaves the Mac.
- If transcription is set to an endpoint, the recorded audio is uploaded to that
  endpoint's `/v1/audio/transcriptions`.
- Refine and summarize send the selected or dictated text to the endpoint you
  chose (Ollama on `http://localhost:11434` by default, which is also local).
- Whisper model downloads are fetched from Hugging Face when you ask for them.

**What is stored.** Settings live in `UserDefaults` under the key `settings.v1`.
API keys live in the login Keychain under the service
`com.dzamataev.macomprendo` — never in settings, logs, or exported files.
Dictation history is off by default. When enabled, it stores accepted text from Dictate and
the original accepted microphone transcript from Dictate & Refine before any LLM processing, in
the local SQLite database at
`~/Library/Application Support/Macomprendo/dictation-history.sqlite3`; audio is never saved.
The newest 100,000 entries are retained. Disabling history stops new writes but preserves
existing entries, while Clear History removes them. The database is plaintext protected by
your macOS account and, when enabled, FileVault.

**Logging.** Macomprendo logs to the unified system log under the subsystem
`com.dzamataev.macomprendo`. Transcript and LLM text are never logged at the
default level.
