# Privacy

Macomprendo has no analytics, crash reporting or update checks. It makes network requests only to endpoints you configure and for model downloads you start.

## Network requests

- Local transcription keeps audio on your Mac.
- Endpoint transcription uploads recorded audio to that endpoint's `/v1/audio/transcriptions` route.
- System voices and Local TTS keep selected text and generated speech on your Mac.
- Endpoint speech sends selected text to that endpoint's `/v1/audio/speech` route.
- Refine and summarize send selected or dictated text to your chosen endpoint. The default is Ollama at `http://localhost:11434`, which runs on your Mac.
- Model downloads fetch archives and weights from pinned Hugging Face or GitHub release URLs when you request them.

## Stored data

Settings live in `UserDefaults` under `settings.v1`. API keys live in the login Keychain under `com.dzamataev.macomprendo`. The app does not put keys in settings, logs or exports.

Dictation history is off by default. When enabled, it stores accepted Dictate text and the original accepted Dictate & Refine transcript before LLM processing. The local SQLite database is at `~/Library/Application Support/Macomprendo/dictation-history.sqlite3` and holds up to the newest 100,000 entries. Disabling history stops new writes and keeps existing entries. Clear History deletes them.

"Save the original recording" is also off by default. It works only when dictation history is on. With both settings enabled, each history entry has an AAC `.m4a` recording in `~/Library/Application Support/Macomprendo/dictation-audio/`. Recordings use 48 kbit/s, 16 kHz mono audio.

"Keep history for" sets the retention period for transcripts and recordings. The default is 90 days. The app deletes older entries automatically. Clear History deletes transcripts and recordings. Delete saved audio removes recordings and keeps transcripts. Turning recording off stops new recordings and keeps existing files.

Your macOS account and, if enabled, FileVault protect these files. The database stores plaintext, and the app does not encrypt recordings. Macomprendo is not sandboxed, so any program running under your macOS account can read them. The app adds no protection beyond your account.

Macomprendo writes to the unified system log under `com.dzamataev.macomprendo`. It never logs transcripts or LLM text at the default level.
