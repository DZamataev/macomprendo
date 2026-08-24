---
name: macomprendo-release
description: Use when cutting a Macomprendo release — version bump, build, sign, notarize, staple and publish, plus the prerequisites that must be in place first.
---

# Releasing Macomprendo

## Prerequisites

- A **Developer ID Application** certificate for team `68QJJA7HK9` in the login keychain.
  Check with `security find-identity -v -p codesigning`. An *Apple Development*
  certificate is enough for local dev builds but **cannot** be notarized.
- A notarytool keychain profile. `node scripts/configure-notarization.mjs` creates it from
  an App Store Connect API key; it stores the credentials in the keychain, never in the
  repo.
- A clean working tree on `main` with CI green.

## The sequence

```bash
npm run test:scripts
npm run test:swift
node scripts/release.mjs --bump patch      # or minor | major | 1.2.3
```

`release.mjs` performs, in order:

1. Refuse to continue on a dirty tree or a red test run.
2. Bump `MARKETING_VERSION` in `macos/project.yml`, then propagate it to the committed
   `.xcodeproj` and to a new `CHANGELOG.md` section (`lib/version.mjs` does the rewriting).
3. `node scripts/build-app.mjs` — `swift build` per architecture, `lipo` into a universal
   binary, assemble the `.app` around `macos/AppBundle/`, stamp the version with
   PlistBuddy, and codesign with the hardened runtime and
   `macos/AppBundle/Macomprendo.entitlements`.
4. `node scripts/notarize-app.mjs` — zip, `notarytool submit --wait`, `stapler staple`,
   `stapler validate`, then re-zip the stapled app and record its SHA-256.
5. Commit, tag `v<version>`, and `gh release create` with the stapled zip attached.

Each script accepts `--dry-run`; use it first.

## Verifying the artefact

```bash
codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app
spctl --assess --type execute --verbose dist/Macomprendo.app   # expect: accepted, source=Notarized Developer ID
xcrun stapler validate dist/Macomprendo.app
```

Then run through `docs/SMOKE_TEST.md` on a machine that has never seen the app: all five
hotkeys, both permission prompts, and a settings round-trip.

## If notarization is rejected

`xcrun notarytool log <submission-id> --keychain-profile <profile>` prints the reason.
The usual causes are a missing hardened runtime, an unsigned nested binary (the whisper
framework must be signed too), or entitlements the certificate does not allow.
