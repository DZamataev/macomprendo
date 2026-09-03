# Local transcription model retention

## Goal

Reuse an already-loaded local transcription model across nearby dictations, while letting the user decide how long an idle model remains in memory.

## Behaviour

- Settings ▸ General shows `Unload local model` in the Local models section.
- The choices are `Immediately after transcription`, `After 5 minutes idle`, `After 10 minutes idle`, `After 30 minutes idle`, and `Never`.
- The default, including settings documents written before this feature, is `After 10 minutes idle`.
- Direct Dictate and Dictate & Refine share the same retained local provider.
- A retained provider is reused while its model and applicable whisper.cpp options are unchanged.
- Changing the active source, whisper.cpp thread count, or translation flag releases an idle cached provider. Changing the retention setting applies immediately.
- Timed retention starts after the last in-flight transcription using the provider finishes. `Immediately` does not retain a provider; `Never` schedules no eviction.
- Endpoint transcription and endpoint probes remain uncached and do not evict the active local provider.
- Application termination clears the provider cache before macOS is told termination may continue. An in-flight call may keep its provider alive only until that call unwinds or the process exits.

## Acceptance

- Settings JSON round-trip and legacy decoding preserve the documented choices and default.
- Tests prove reuse, immediate disposal, timed eviction, no eviction for `Never`, configuration replacement, shared use across both microphone features, and explicit cache clearing.
- The Dictation settings UI exposes the typed setting for local backends.
- Manual smoke coverage verifies faster consecutive local dictations, idle eviction/reload, and clean application exit.
