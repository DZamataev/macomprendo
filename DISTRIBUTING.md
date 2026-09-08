# Distributing Macomprendo

Macomprendo is distributed outside the Mac App Store as a Developer ID signed, notarized,
stapled ZIP. It is not sandboxed (see `docs/DECISIONS/ADR-0003-not-sandboxed.md`), so the
Mac App Store is not an option.

Everything below runs through Node scripts; there are no shell scripts in this repository.

## Prerequisites

- macOS 14 or newer with Xcode command-line tools (`xcode-select --install`).
- Node.js 20 or newer, then `npm ci` in the repository root.
- `xcodegen` (`brew install xcodegen`) if you change `macos/project.yml`.
- `gh` (`brew install gh`) authenticated with `gh auth login`, for releases.
- A **Developer ID Application** certificate for team `68QJJA7HK9`, installed in the login
  keychain with its private key. Confirm with:

  ```sh
  security find-identity -v -p codesigning
  ```

  The output must contain a line like
  `"Developer ID Application: Denis Zamataev (68QJJA7HK9)"`. Never commit the `.cer`, the
  `.p12` export, or the private key — `npm run audit` refuses any commit that contains them.
- `gitleaks` (`brew install gitleaks`), required by `npm run audit` to scan both the working
  tree and Git history for secrets.

### Still outstanding: model checksums

The whisper model catalog (`macos/Sources/Macomprendo/Services/ModelCatalog.swift`) ships
with every `sha256` field empty. Model downloads still work, but they are not
checksum-verified until this is fixed. Before a release ships checksum-verified model
downloads, run:

```sh
npm run fetch-model-hashes -- --download
```

This downloads all nine catalog models (~6 GB of traffic) to compute their digests and
rewrites `ModelCatalog.swift` in place. Run `npm run fetch-model-hashes` (no `--download`)
to refresh just the recorded sizes with a fast HEAD request, or add `--dry-run` to either
form to print the records without writing anything.

## 1. Store notarization credentials

Create an app-specific password at <https://appleid.apple.com> → Sign-In and Security →
App-Specific Passwords. Then:

```sh
NOTARY_APPLE_ID="you@example.com" npm run configure-notary
```

You are prompted for the password with local echo turned off; the value is written only to
`notarytool`'s stdin, never passed as a command-line argument, so it never appears in `ps`
output, shell history, or this repository. `xcrun notarytool store-credentials` stores it in
the login Keychain under the profile `macomprendo-notary`.

Override the defaults with `APPLE_TEAM_ID` (default `68QJJA7HK9`) and `NOTARYTOOL_PROFILE`
(default `macomprendo-notary`).

Verify it worked:

```sh
xcrun notarytool history --keychain-profile macomprendo-notary --output-format json | head -5
```

## 2. Build

```sh
npm run build                                   # host architecture, ad-hoc signed
npm run build -- --arch arm64,x86_64            # universal, ad-hoc signed
npm run build -- --dry-run                      # print the plan, touch nothing
npm run build -- --arch arm64,x86_64 \
  --sign "Developer ID Application: Denis Zamataev (68QJJA7HK9)"
```

The build compiles each architecture with
`swift build --package-path macos -c release --triple <arch>-apple-macosx14.0`, merges the
slices with `lipo`, assembles `dist/Macomprendo.app`, stamps
`CFBundleShortVersionString` / `CFBundleVersion` / `CFBundleIdentifier` with `PlistBuddy`,
signs, and finishes with `codesign --verify --deep --strict`.

An ad-hoc signature (`--sign -`, the default) is fine for local use. Passing a real identity
switches on the hardened runtime (`--options runtime --timestamp`) and applies
`macos/AppBundle/Macomprendo.entitlements`.

Other `build-app.mjs` flags: `--configuration release|debug` (default `release`),
`--deployment-target <v>` (default `14.0`), `--entitlements <path>`, `--version <X.Y.Z>`
(override `MARKETING_VERSION`), `--build-number <n>` (default: the version), and
`--dist <dir>` (default `dist/`).

**`error: command …/swift-version-<hash>.txt not registered` during `npm run build -- --arch
arm64,x86_64`:** stale/inconsistent state in `macos/.build` from alternating single-arch and
multi-arch (`--triple`) builds. Run `rm -rf macos/.build`, then re-run the build. This is a
SwiftPM/llbuild incremental-build issue, not a `build-app.mjs` bug — it surfaces for anyone
who has been doing ordinary single-architecture dev builds and then runs the universal build
for the first time.

**"Accessibility access is granted in System Settings, but the app says it is not":** an
ad-hoc signed build has no stable code identity — no Team ID, no certificate chain — so macOS
records the privacy grant against that build's code hash. Every rebuild changes the hash, the
grant stops applying, and `AXIsProcessTrusted()` returns false while System Settings still
shows the toggle switched on, because that list is drawn by bundle id and path. The app is
then genuinely untrusted: it cannot read the selection or paste. Two ways out, and the first
is the real fix:

- Install with `npm run install-app:signed`. Its Developer ID designated requirement stays stable
  across rebuilds, so the grant survives them.
- Clear the stale grant and start over: quit the app, run `npm run reset-permissions`, launch,
  and grant again. Do this once after switching from ad-hoc to a real identity, or when testing
  the permission flow itself. Do not make it part of ordinary local testing.

### What the build copies into the bundle

`swift build` leaves sidecars next to the executable, and `scripts/build-app.mjs` discovers
and copies all of them rather than assuming a fixed list:

| Emitted | Goes to | Why |
|---|---|---|
| every `*.bundle` | `Contents/Resources/` | Every SwiftPM resource bundle found next to the executable — our own target's (`Macomprendo_Macomprendo.bundle`, the vendored Phosphor SVG icons, see `docs/DECISIONS/ADR-0008`) and any dependency's that ships its own (`KeyboardShortcuts_KeyboardShortcuts.bundle`). SwiftPM's generated `Bundle.module` accessor finds them via `Bundle.main.resourceURL`. |
| `*.framework` | `Contents/Frameworks/` | Slices of a binary xcframework target, **only if they are dynamic**. An `@executable_path/../Frameworks` rpath is added and each framework is signed before the enclosing app. |

whisper.cpp is consumed as a **prebuilt xcframework** (`docs/DECISIONS/ADR-0007`), and its
slice is **dynamically linked** — the executable's load commands reference
`@rpath/whisper.framework/Versions/Current/whisper` — so `whisper.framework` is copied into
`Contents/Frameworks` and signed as nested code in its own right. Its Metal resources travel
inside the framework, so there are no separate ggml resource bundles to copy.

sherpa-onnx is also consumed as a prebuilt xcframework (`docs/DECISIONS/ADR-0009`). Its
`SherpaOnnxC.framework` slice is a second dynamic framework in the bundle, alongside the
already dynamic `whisper.framework`. The build copies both to `Contents/Frameworks`, adds
`@executable_path/../Frameworks`, and signs each framework before signing the app itself.

Resource bundles are **not** signed individually — not because `codesign` always refuses
them, but because they are *resources*, not nested code, and are sealed by the app's own
signature instead. The two bundles here aren't even alike: `Macomprendo_Macomprendo.bundle`
is declared `.copy(...)` (not `.process(...)`) in `macos/Package.swift`, so SwiftPM emits it
as a plain directory with **no** `Info.plist`, and `codesign` genuinely refuses it as a
signing target ("bundle format unrecognized, invalid, or unsuitable" — confirmed by signing
it directly). `KeyboardShortcuts_KeyboardShortcuts.bundle` comes from the KeyboardShortcuts
package's own `.process(...)`-declared resources, **does** have an `Info.plist`, and
`codesign` accepts it individually without complaint. Neither is signed on its own regardless
— only nested *code* needs its own signature before the enclosing app. Both
`whisper.framework` and `SherpaOnnxC.framework` are signed nested code.

Re-run the discovery after any vendored xcframework bump or any change to the app target's
resources or dependencies:

```sh
BIN=$(swift build --package-path macos -c release --triple arm64-apple-macosx14.0 --show-bin-path)
ls -d "$BIN"/*.bundle 2>/dev/null || echo "(no .bundle)"
ls -d "$BIN"/*.framework 2>/dev/null || echo "(no .framework)"
otool -L "$BIN/Macomprendo" | grep -Ei 'whisper|SherpaOnnxC' || echo "framework is statically linked"
```

Current result for this project:

```text
$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle
$BIN/Macomprendo_Macomprendo.bundle
$BIN/whisper.framework
$BIN/SherpaOnnxC.framework

@rpath/whisper.framework/Versions/Current/whisper (compatibility version 0.0.0, current version 0.0.0)
@rpath/SherpaOnnxC.framework/Versions/A/SherpaOnnxC (compatibility version 0.0.0, current version 0.0.0)
```

whisper and SherpaOnnxC are dynamically linked, so both frameworks are copied and signed; both
`.bundle` directories are copied unsigned and sealed by the app's signature.

`build-app.mjs` only hard-fails when **no** resource bundle at all is found next to the
executable (`resourceBundles.length === 0`) — it does not check that any *specific* bundle
(such as `Macomprendo_Macomprendo.bundle`) is among them. If `KeyboardShortcuts_KeyboardShortcuts.bundle`
were still present but ours had somehow stopped being emitted, the build would succeed and warn
about nothing; the app would simply ship without its icons. The `find … | wc -l` check in
`docs/SMOKE_TEST.md`'s release checklist is what actually verifies *our* bundle specifically.
Missing `.framework` entries are only a problem when `otool -L` says the corresponding slice is
dynamic.

## 3. Notarize and package

```sh
npm run notarize
```

This discovers the Developer ID identity (`security find-identity -v -p codesigning`),
rebuilds a universal signed app, archives it with
`ditto -c -k --sequesterRsrc --keepParent`, submits it with
`xcrun notarytool submit --wait --timeout 60m --output-format json`, and requires
`"status": "Accepted"`. On any other status it downloads the notary log to
`dist/notary-log-<submission-id>.json` and stops.

On success it staples the ticket, validates it, re-verifies the signature, runs a Gatekeeper
assessment (`spctl --assess --type execute`), and produces:

```text
dist/Macomprendo-<version>-macos.zip
dist/Macomprendo-<version>-macos.zip.sha256
```

**`<version>` is `MARKETING_VERSION` from `macos/project.yml` at the moment `notarize-app.mjs`
runs.** Running `npm run notarize` on its own — before any version bump — names and packages
the ZIP with the version currently on disk, and everything the ZIP contains (the app's own
`CFBundleShortVersionString`) is stamped with that same version. That is fine for testing
notarization in isolation; it is **not** how to get a notarized ZIP attached to a release —
see step 4.

The ZIP is created *after* stapling, so a downloader gets an offline notarization ticket.

Useful flags: `--dry-run` (print the plan), `--sign "<identity>"` (when several Developer ID
identities are installed), `--profile <name>`, `--timeout 30m`.

**A real notarization run — an actual submission to Apple, stapling, and a Gatekeeper
acceptance check — has never been executed against this toolchain.** Everything above is
verified by `scripts/__tests__/notarize-app.test.mjs` against a faked `notarytool`, and
`--dry-run` prints the exact same step list `planNotarize` builds for a real run (both branches
consume the one array); but that only proves the *steps* are the ones that would run, not that
Apple's notary service accepts what gets submitted. The network round-trip to Apple itself —
a real "Accepted" status, a genuine staple, a live Gatekeeper acceptance — is unverified until
an operator with the certificate runs it for real.

## 4. Release

```sh
npm run release -- --dry-run patch              # resolve version, validate changelog, print the plan
npm run release -- patch                        # notes-only release, with a confirmation prompt
npm run release -- 1.0.0 --yes                  # explicit version, no prompt
npm run release -- --notarize patch             # build, sign, notarize and attach the ZIP
```

**Run notarization through `--notarize`, not as a separate `npm run notarize` beforehand.**
`notarize-app.mjs` names and stamps the ZIP with whatever `MARKETING_VERSION` is in
`macos/project.yml` *at the moment it runs* — and `release.mjs` refuses to accept a version
that is not newer than the one currently declared, so there is no way to pre-bump the file
yourself before notarizing. Run `npm run notarize` ahead of time and you get a ZIP stamped
with the *old*, pre-bump version, which cannot be renamed into correctness after the fact
because the version is also baked into the app's own `Info.plist` inside it.

`release.mjs` solves this with the `--notarize` flag: it inserts the notarize step into the
release plan itself, **after** the version bump has already rewritten
`macos/project.yml` and `CHANGELOG.md`, and **before** the release commit — so the ZIP
`notarize-app.mjs` builds carries the version actually being released, and a failed
notarization never leaves a bumped, committed tree with no artifact to show for it.

The release script:

1. Reads `MARKETING_VERSION` from `macos/project.yml` and resolves the next version.
2. Validates that `CHANGELOG.md` has entries under `## [Unreleased]`.
3. Preflight: clean working tree, branch `main`, `gh` authenticated, `HEAD == origin/main`,
   tag `vX.Y.Z` absent on the remote.
4. Prints the release notes and, before asking to publish, states plainly whether a build will
   be attached: with `--notarize`, "The notarized build will be built fresh and attached:
   Macomprendo-X.Y.Z-macos.zip."; without it, "This will publish release notes only; no build
   artifact will be attached (pass --notarize to build, sign, notarize and attach one)." The
   confirmation prompt itself repeats which of the two you are about to do.
5. Writes the new version into `macos/project.yml`, `macos/Macomprendo.xcodeproj/project.pbxproj`
   and `CHANGELOG.md` (`## [Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD`).
6. Runs `npm run test:scripts`, `swift test --package-path macos`, an unsigned
   `xcodebuild … CODE_SIGNING_ALLOWED=NO build`, and `git diff --check`.
7. **Only with `--notarize`:** runs `node scripts/notarize-app.mjs` here — after step 5's
   version bump, before the commit in step 8 — to build, sign and notarize a fresh universal
   app and produce `dist/Macomprendo-X.Y.Z-macos.zip`.
8. Commits `chore(release): X.Y.Z`, tags `vX.Y.Z`, pushes both.
9. Creates the GitHub release with the changelog section as the notes, attaching the ZIP from
   step 7 only when `--notarize` was passed — a notes-only release never attaches whatever ZIP
   happens to already be sitting in `dist/` from an earlier, differently-versioned run.

If a step in 6–9 fails, `release.mjs` prints exactly which irreversible steps already
happened (files rewritten, commit created, pushed, tagged, tag pushed, release published) and
the command that undoes each one — check that output before retrying.

`--notarize` makes the release slow (it contacts Apple and can take many minutes) and
requires the Developer ID certificate from the Prerequisites section above. Omit it to
publish release notes now and attach a build later with a manual `npm run notarize` plus
`gh release upload`.

## 5. Install locally

```sh
npm run install-app                                   # build + install into /Applications (ad-hoc)
npm run install-app:signed                            # Developer ID-signed build + install
npm run install-app -- --no-open
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app
MACOS_SIGN_IDENTITY="Developer ID Application: Denis Zamataev (68QJJA7HK9)" npm run install-app
```

`install-app:signed` is the normal local-testing command for a checkout with this project's
Developer ID certificate. It uses a stable designated requirement (without requesting a
notarization timestamp), which preserves Microphone and Accessibility grants across rebuilds.
Switch from an ad-hoc build once, run `npm run reset-permissions`, then grant permissions again;
subsequent signed installs retain them. Plain `install-app` remains ad-hoc for contributors
without the certificate. Pass `--sign <identity>` or set `MACOS_SIGN_IDENTITY` to use another
signing identity.

The installer stages the new bundle inside the destination directory, quits any running copy,
moves the old app to a backup, swaps in the new one, verifies the signature, and restores the
backup if anything fails.

## Before publishing anything

```sh
npm run audit
```

Refuses any tree containing Xcode user state, `.swiftpm`, `.xcuserstate`, archives, dSYMs,
notary logs, `.p8`/`.p12`/`.pem`/`.cer`/`.key`/`.mobileprovision` files, non-example `.env`
files, or a machine-specific `/Users/<name>` path (`/Users/test`, `/Users/example` and
`/Users/shared` are allowed, for exactly this kind of documentation). It also runs
`git diff --check` and invokes `gitleaks` twice: once over the working tree and once over the
Git history.

## Verification the tooling performs

- Developer ID signing with hardened runtime and a secure timestamp
- Nested frameworks signed before the enclosing app (SwiftPM resource bundles are copied
  unsigned and sealed by the app's own signature — see "What the build copies into the
  bundle" above)
- Universal architecture report (`lipo -archs`) after assembly
- Synchronous `notarytool` submission with an explicit `Accepted` check
- Ticket stapling plus `stapler validate`
- `codesign --verify --deep --strict`
- Gatekeeper assessment with `spctl`
- SHA-256 sidecar for the published ZIP

All of the above is exercised by `scripts/__tests__/*.test.mjs` against faked `codesign`,
`notarytool`, `spctl` and `git`/`gh` binaries — real Apple notarization itself has not yet
been run; see the note at the end of step 3.

Apple's reference: [Customizing the notarization
workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
