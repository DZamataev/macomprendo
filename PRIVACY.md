# Privacy

Macomprendo has no analytics, crash reporting or update checks. It makes network requests only to endpoints you configure and for model downloads you start.

## Network requests

- Local transcription keeps audio on your Mac.
- Endpoint transcription uploads recorded audio to that endpoint's `/v1/audio/transcriptions` route. For a transcribed file or a recorded call this is the file's or the call's speech, both sides of a call, sent in short pieces.
- System voices and Local TTS keep selected text and generated speech on your Mac.
- Endpoint speech sends selected text to that endpoint's `/v1/audio/speech` route.
- Refine and summarize send selected or dictated text, or a transcript you summarize, to your chosen endpoint. The default is Ollama at `http://localhost:11434`, which runs on your Mac.
- Model downloads fetch archives and weights from pinned Hugging Face or GitHub release URLs when you request them.

## Stored data

Settings live in `UserDefaults` under `settings.v1`. API keys live in the login Keychain under `com.dzamataev.macomprendo`. The app does not put keys in settings, logs or exports.

Dictation history is off by default. When enabled, it stores accepted Dictate text and the original accepted Dictate & Refine transcript before LLM processing, the transcript as recognised before any glossary correction, and which model, engine and language produced it. The local SQLite database is at `~/Library/Application Support/Macomprendo/dictation-history.sqlite3` and holds up to the newest 100,000 entries. Disabling history stops new writes and keeps existing entries. Clear History deletes them.

"Save the original recording" is also off by default. It works only when dictation history is on. With both settings enabled, each history entry has an `.m4a` recording in `~/Library/Application Support/Macomprendo/dictation-audio/`. Recordings are 16 kHz mono, compressed AAC at 48 kbit/s by default or lossless ALAC if you choose it.

"Keep history for" sets the retention period for transcripts and recordings. The default is 90 days. The app deletes older entries automatically. Clear History deletes transcripts and recordings. Delete saved audio removes recordings and keeps transcripts. Turning recording off stops new recordings and keeps existing files.

Transcripts of files and calls are kept in a separate local SQLite database at `~/Library/Application Support/Macomprendo/transcripts.sqlite3` until you delete them: the text with timestamps, the title, which model produced it, and a bookmark to the source file or call recording so it can be resumed and played. Deleting a transcript removes its text; its source is kept unless you choose to move it to the Trash.

Record Call captures your microphone and everything your Mac plays, including the other people on the call. Each call is a folder in `~/Library/Application Support/Macomprendo/Recordings/`, or the folder you choose in Settings ▸ General, holding two `.m4a` files (your side and everyone else's, 48 kHz mono AAC) and a small `recording.json`. Recordings are kept until you delete them. Many places require the consent of everyone on a call before it is recorded; telling them is up to you.

Glossary packs are plain text files in `~/Library/Application Support/Macomprendo/Vocabulary/`; your own glossary terms are kept in settings. Neither is sent anywhere.

Your macOS account and, if enabled, FileVault protect these files. The databases store plaintext, and the app does not encrypt recordings. Macomprendo is not sandboxed, so any program running under your macOS account can read them. The app adds no protection beyond your account.

Macomprendo writes to the unified system log under `com.dzamataev.macomprendo`. It never logs transcripts or LLM text at the default level.
