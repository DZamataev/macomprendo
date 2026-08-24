---
name: macomprendo-add-provider
description: Use when adding or changing an LLM or transcription backend in Macomprendo — the protocols to implement, where the factory picks it up, and how to test it without a network.
---

# Adding a provider

Providers live in `macos/Sources/Macomprendo/Providers/`. They are `Sendable` structs
that take an `Endpoint` and an injected `HTTPClient`; they never read `Settings` or the
Keychain themselves.

## The two protocols

```swift
protocol LLMProvider: Sendable {
    var endpoint: Endpoint { get }
    func listModels() async throws -> [String]
    func chat(_ messages: [ChatMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<String, Error>
}

protocol TranscriptionProvider: Sendable {
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String
}
```

`chat` yields **text deltas**, not whole messages. Cancelling the consuming `Task` must
cancel the underlying request.

## Steps

1. **Add the `EndpointKind` case** in `Core/Endpoint.swift` if the new backend speaks a
   dialect that is neither `.ollama` nor `.openAICompatible`. Most do not — an
   OpenAI-compatible server needs no new case, only a new `Endpoint` row in Settings.
2. **Create `Providers/<Name>Provider.swift`** with the struct and its `init(endpoint:
   apiKey:http:)`. Build requests through `HTTPRequest`, never `URLRequest` directly.
3. **Parse the stream** with `Streaming/SSEParser` (OpenAI-style `data:` lines terminated
   by `data: [DONE]`) or `Streaming/NDJSONParser` (Ollama-style, one JSON object per
   line). Both are fed raw `Data` chunks and cope with splits at any byte boundary — do
   not add a third parser.
4. **Map failures to `MacomprendoError`**: a transport failure becomes
   `.providerUnreachable(endpointName:)`, a non-2xx becomes `.providerHTTP(status:body:)`,
   an unparseable stream becomes `.providerStreamMalformed`.
5. **Register it in `Providers/ProviderFactory.swift`.** The factory is the only thing
   that reads the Keychain (via `KeychainStoring`) and turns an `Endpoint` into a
   provider. Ollama endpoints also answer on `/v1/…`, so the factory prefers the native
   Ollama API only when `kind == .ollama` — that is what `/api/tags` and `/api/pull` need.
6. **Never construct the provider outside the factory**, and never construct the factory
   outside `AppEnvironment`.

## Testing

Use `Tests/MacomprendoTests/Fakes/StubHTTPClient.swift`: it records every `HTTPRequest`
and replays scripted responses or chunk sequences per URL path. Cover, at minimum:

- the request — method, path, headers (including `Authorization: Bearer …` only when a
  key exists), and the encoded body;
- the happy-path stream, fed as chunks **split at awkward boundaries** (mid-JSON,
  mid-`data:` line, `\r\n` split across chunks);
- a non-2xx response mapping to `.providerHTTP`;
- a truncated stream mapping to `.providerStreamMalformed`;
- cancellation — cancel the consuming task and assert the stream finishes.

No test may touch the network. If you need a real server to be sure, add a line to
`docs/SMOKE_TEST.md` instead.
