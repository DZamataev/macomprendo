# Local transcription model retention plan

1. Add `LocalModelIdleTimeout` and `Settings.localModelIdleTimeout` in `Core/Settings.swift`; first write failing default, legacy-decoding, label, and JSON round-trip tests in `Core/SettingsTests.swift`.
2. Add `Providers/LocalTranscriptionProviderCache.swift`; drive it with focused RED/GREEN tests for same-configuration reuse, immediate mode, timed idle eviction after the last active call, `never`, configuration replacement, and `removeAll()`.
3. Construct one cache in `AppEnvironment.live()` and `AppEnvironment.fake()`. Route only active local dictation through it from `AppModel.transcriberProvider`; keep `AppModel.transcriber(for:)` uncached for endpoint probes.
4. Add AppModel tests proving Dictate and Dictate & Refine share the cached provider, relevant setting changes release it, and `shutdown()` clears it.
5. Add the typed `Unload local model` picker to Settings ▸ General. Update `docs/SMOKE_TEST.md` and `CHANGELOG.md`.
6. Make `AppDelegate.applicationShouldTerminate` return `.terminateLater`, await `AppModel.shutdown()`, then reply to macOS so cached native contexts are released before termination continues.
7. Run focused tests after each RED/GREEN cycle, then `npm run test:swift`, `npm run test:scripts`, `swift build --package-path macos`, `npm run gen`, and the unsigned Xcode build. Launch the built app and inspect the General picker and quit path on macOS.
