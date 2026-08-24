# Macomprendo

A menubar-only macOS app that turns global hotkeys into voice and text actions:
dictate into any app, dictate and refine, speak the selection, summarize the
selection, refine the selection.

Transcription runs locally with whisper.cpp, or through any OpenAI-compatible
`/v1/audio/transcriptions` endpoint. Refine and summarize run through Ollama or
any OpenAI-compatible chat-completions endpoint. Nothing is sent anywhere you
did not configure — see [PRIVACY.md](PRIVACY.md).

Requires macOS 14 or later.

## Building

```bash
brew install xcodegen        # once
npm ci                       # once
npm run test:scripts         # Node tooling tests
npm run test:swift           # Swift unit tests
npm run gen                  # regenerate macos/Macomprendo.xcodeproj
open macos/Macomprendo.xcodeproj
```

The first Swift build downloads a ~54 MB prebuilt `whisper.xcframework`; later
builds reuse it.

## Layout

| Path | What lives there |
|---|---|
| `macos/Sources/Macomprendo` | App, Core, Services, Providers, Features, UI |
| `macos/Tests/MacomprendoTests` | swift-testing unit tests and fakes |
| `scripts/` | Node ≥ 20 tooling (build, release, agent config) |
| `docs/` | Architecture, decisions, specs and plans |

Agent instructions live in [AGENTS.md](AGENTS.md).

## Licence

MIT — see [LICENSE](LICENSE).
