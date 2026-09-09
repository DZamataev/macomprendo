---
name: macomprendo-release
description: Use when building, signing, notarizing, installing, or publishing a Macomprendo release, or when a release command fails
---

# Macomprendo Release

Every release action is an npm script backed by a Node ES module in `scripts/`. There are no
shell scripts. Full prose runbook: `DISTRIBUTING.md`. Manual checklist: `docs/SMOKE_TEST.md`.

## Prerequisites

- macOS 14+ with Xcode command-line tools, Node 20+, `npm ci` run once.
- `xcodegen` if `macos/project.yml` changes; `gitleaks` for the mandatory working-tree and Git
  history scans; `gh` authenticated (`gh auth login`) for releases.
- A **Developer ID Application** certificate for team `68QJJA7HK9`, in the login keychain with
  its private key — this already exists on the maintainer's machine. Confirm with
  `security find-identity -v -p codesigning`; an *Apple Development* certificate is not enough,
  it cannot be notarized.
- Notarization credentials, stored once with `npm run configure-notary`. It prompts for the
  Apple ID and an app-specific password (create one at appleid.apple.com → Sign-In and
  Security → App-Specific Passwords) and stores them in the login Keychain under the profile
  `macomprendo-notary`. The password is typed into a muted prompt and reaches `notarytool`
  only through its stdin — never a command-line argument — so it never appears in `ps`, shell
  history, or this repository.
- The whisper model catalog's `sha256` fields
  (`macos/Sources/Macomprendo/Services/ModelCatalog.swift`) are still empty. Model downloads
  work today but are not checksum-verified. Before a release ships checksum-verified model
  downloads, run `npm run fetch-model-hashes -- --download` (downloads ~6 GB to compute the
  digests) and commit the rewritten catalog.

## Commands

```sh
npm run build                                      # host arch, ad-hoc signed -> dist/Macomprendo.app
npm run build -- --arch arm64,x86_64               # universal, ad-hoc signed
npm run build -- --dry-run                         # print the step plan, change nothing
npm run build -- --arch arm64,x86_64 --sign "Developer ID Application: Denis Zamataev (68QJJA7HK9)"

npm run configure-notary                           # one-time: store the app-specific password
NOTARY_APPLE_ID="you@example.com" npm run configure-notary

npm run notarize                                   # universal signed build -> submit -> staple -> zip + sha256
npm run notarize -- --dry-run
npm run notarize -- --sign "Developer ID Application: Denis Zamataev (68QJJA7HK9)"

npm run install-app:signed                         # normal maintainer test build; preserves TCC grants
npm run install-app                                # ad-hoc fallback for contributors without the certificate
npm run install-app -- --no-open
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app

npm run audit                                      # repository checks + two Gitleaks scans
npm run release -- --dry-run patch                 # resolve version, validate changelog, print plan
npm run release -- --dry-run --notarize patch      # same, with the notarize step in the plan
npm run release -- patch                           # real release, notes only, with confirmation
npm run release -- --notarize patch                # real release, notarized build attached
npm run release -- 1.0.0 --yes                     # explicit version, no confirmation prompt

npm run fetch-model-hashes -- --download           # refresh whisper model SHA-256 digests
```

## Order of operations for a real release

1. Write the entries under `## [Unreleased]` in `CHANGELOG.md`. **This is load-bearing:**
   `release.mjs` refuses to run without them, and their content becomes the GitHub release
   notes verbatim (`gh release create … --notes-file`).
2. `npm run audit`
3. `npm run release -- --dry-run patch` (or `--dry-run --notarize patch` if this release will
   attach a build) — check the resolved version, the release notes, and the printed plan.
4. Work through the release checklist in `docs/SMOKE_TEST.md`.
5. Run the real release:
   - `npm run release -- patch` — publishes release notes only, no binary attached.
   - `npm run release -- --notarize patch` — builds, signs, and notarizes a fresh universal
     app for the version just bumped, and attaches its ZIP to the GitHub release.

**Do not run `npm run notarize` on its own and then release separately — that order cannot
produce a correctly-versioned artifact.** `notarize-app.mjs` names and stamps the ZIP (and the
app's own `Info.plist` inside it) with whatever `MARKETING_VERSION` is in `macos/project.yml`
*at the moment it runs*, and `release.mjs` refuses to accept a version that is not newer than
the one currently declared — so there is no way to pre-bump the file yourself before
notarizing. `--notarize` is the only path that runs correctly: it inserts the notarize step
into the release plan *after* the version bump has already rewritten `macos/project.yml` and
`CHANGELOG.md`, and *before* the release commit, so the ZIP that gets attached carries the
version that ends up tagged. `--notarize` also makes the release far slower — it is a real
network round trip to Apple, with a default 60-minute wait.

## Facts that trip people up

- Version source of truth is `MARKETING_VERSION` in `macos/project.yml`. The release script
  mirrors it into `macos/Macomprendo.xcodeproj/project.pbxproj`. Never edit the pbxproj by hand
  — run `npm run gen` after changing `project.yml`.
- Git tags are `vX.Y.Z`; changelog headings are `## [X.Y.Z] - YYYY-MM-DD`; the release commit
  message is `chore(release): X.Y.Z`.
- Bundle id `com.dzamataev.macomprendo`, team `68QJJA7HK9`, notary profile `macomprendo-notary`.
- Ad-hoc (`--sign -`, the default) is fine locally. Notarization needs a **Developer ID
  Application** certificate; an *Apple Development* certificate cannot be notarized.
- The build copies every `*.bundle` SwiftPM emits into `Contents/Resources` (that is where the
  vendored Phosphor icons live) and every dynamic `*.framework` into `Contents/Frameworks`.
  whisper.cpp is a prebuilt xcframework, so there are no ggml Metal bundles to copy. A real
  build **errors** (not warns) with "swift build produced no SwiftPM resource bundle next to
  the executable" if none is found — that check only becomes a warning under `--dry-run`,
  where nothing has actually been built yet. Either way, stop and fix it before shipping.
- CI never notarizes: no Apple secrets are assumed to exist in the repository.
- **Pushing a `vX.Y.Z` tag publishes a GitHub release by itself** (`.github/workflows/release.yml`).
  The workflow re-verifies the tag against `MARKETING_VERSION`, runs both test suites, the
  unsigned xcodebuild and `npm run audit`, then builds a universal **ad-hoc signed** bundle and
  attaches `Macomprendo-<version>-macos-unsigned.zip` plus its `.sha256` sidecar, with notes from
  `CHANGELOG.md`. Re-running the same tag updates that release instead of failing. That artifact
  is *not notarized*: downloaders get a Gatekeeper warning. A notarized ZIP still comes only from
  `npm run release -- --notarize`, run locally, and is uploaded to the same release by hand.
  `scripts/ci-release-notes.mjs` is the CI-side notes writer; `scripts/release.mjs` remains the
  local release driver, and the two are deliberately separate.
- **No real notarization has ever been run against this toolchain.** No submission has ever
  reached Apple, nothing has ever been stapled, and no Gatekeeper acceptance check has ever
  passed for real. `--dry-run` and the test suite (against faked `codesign`/`notarytool`/
  `spctl`/`git`/`gh` binaries) prove the *steps* are the right ones; they do not prove Apple
  accepts what gets submitted. Treat the first `--notarize` release as the first real exercise
  of that path, and budget time in case it surfaces something only Apple's servers can tell you
  about.

## CI and the release workflow

`.github/workflows/ci.yml` runs on pushes to `main` and every PR; `release.yml` runs on a
`vX.Y.Z` tag and publishes the release. Facts learned the hard way, all now asserted by
`scripts/__tests__/workflows.test.mjs` against the committed workflow files:

- **Spell the test command `node --test scripts/__tests__/*.test.mjs`** (shell-expanded glob).
  A quoted `'…/**/*.test.mjs'` is taken literally before Node 21; a bare `scripts/__tests__`
  directory is resolved as a module on Node 22. Only the shell glob works on 20, 22 and 26.
- **Every job that runs npm must use `actions/setup-node`.** The ubuntu and macOS runner
  images preinstall different Node majors, so an unpinned job silently runs a different
  version from its sibling — that is how the same command passed in one job and failed in
  another on the same commit.
- **The audit job needs `fetch-depth: 0` and an explicit gitleaks install.** Runner images do
  not ship gitleaks, `audit-public-repo.mjs` fails rather than skipping its scan, and a
  shallow clone would make the history scan meaningless.
- **Publishing needs job-scoped `permissions: contents: write`**, and `gh` does not expand
  globs — pass the concrete asset paths through a shell variable.
- A timing-sensitive controller test must gate on `AsyncGate`, never on a `Task.sleep` racing
  a scripted delay: those pass locally forever and fail on loaded runners.
- Verify a published release for real: download the ZIP and `.sha256`, `shasum -a 256 -c`,
  expand it, then `lipo -archs` (expect `x86_64 arm64`) and `codesign -dv` (expect `adhoc`).

## When something fails

If a step after the confirmation prompt fails mid-release (files already rewritten, a commit
already made, a tag already pushed…), `release.mjs` prints a state block naming exactly which
of those irreversible steps already happened and the command that undoes each one. Read that
block before retrying or touching anything by hand.

| Symptom | Fix |
|---|---|
| `No "Developer ID Application" certificate…` | Follow DISTRIBUTING.md → prerequisites; check `security find-identity -v -p codesigning` |
| `Could not authenticate with notarytool` | Re-run `npm run configure-notary` |
| Notarization not `Accepted` | Read `dist/notary-log-<id>.json`; it names the offending binary and reason |
| `The working tree is not clean; commit or stash…` | Commit or stash, then retry the release |
| `Tag vX.Y.Z already exists on the remote` | Choose a higher version, or delete the tag if it was a mistake |
| `CHANGELOG.md has no entries under "## [Unreleased]"` | Write the release notes in `CHANGELOG.md` first |
| `…project.pbxproj declares MARKETING_VERSION … but … was expected` | Run `npm run gen` and commit the regenerated project |
| Audit flags a `/Users/<name>` path | Replace it with `~/`, `<repo>`, or `/Users/test` |
| `error: command …/swift-version-<hash>.txt not registered` during `npm run build -- --arch arm64,x86_64` | Stale/inconsistent state in `macos/.build` from alternating single-arch and multi-arch (`--triple`) builds. Run `rm -rf macos/.build`, then re-run the build. |
