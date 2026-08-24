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
Transcripts are not stored: text goes to the frontmost app or the clipboard and
is then forgotten.

**Logging.** Macomprendo logs to the unified system log under the subsystem
`com.dzamataev.macomprendo`. Transcript and LLM text are never logged at the
default level.
