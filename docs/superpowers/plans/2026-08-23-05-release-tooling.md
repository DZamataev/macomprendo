# Macomprendo Release Tooling & Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the complete Node.js release toolchain (build, notarize, release, audit, install), the release/decision documentation, and the CI + tag-release workflows, so that `npm run release -- --dry-run patch` passes end to end.

**Architecture:** Every tool is a Node ≥ 20 ES module in `scripts/` that exports pure helper functions plus an injectable `main(argv, deps)`. Side effects reach the outside world only through injected `run` (process spawning), `fsOps` (filesystem mutation), and `io` (file read/write) objects, so `node:test` can drive whole flows with fakes and never touch the machine. Long command sequences are produced by pure `plan*()` functions returning step arrays, which `--dry-run` prints and `executePlan()` performs.

**Tech Stack:** Node ≥ 20 ESM (`.mjs`), `node:test`, `node:util.parseArgs`, `execa` (spawning), `picocolors` (terminal colour), `yaml` (project.yml validation), Xcode command-line tools (`swift`, `xcodebuild`, `codesign`, `xcrun notarytool`, `xcrun stapler`, `spctl`, `lipo`, `ditto`, `/usr/libexec/PlistBuddy`), `gh` CLI, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-23-macomprendo-design.md` (see §7 Build, CI, release and §9 Decisions)

**Shared file map:** `docs/superpowers/plans/2026-08-23-00-file-map-and-interfaces.md` (see "Node tooling contracts")

**Assumed done (Plans 1–4):** the app is feature-complete; `package.json` exists with scripts `gen`, `test:swift`, `test:scripts`, `sync-agents`; `scripts/lib/{run,log,version,fs}.mjs` exist per the map; `scripts/sync-agent-config.mjs` exists; `.github/workflows/ci.yml` runs the Swift and Node tests; `macos/AppBundle/{Info.plist,AppIcon.icns,Macomprendo.entitlements}` exist; `macos/project.yml` carries `MARKETING_VERSION: "0.1.0"`; `macos/Macomprendo.xcodeproj/` is committed.

---

## Global Constraints

- Node ≥ 20, ES modules only, file extension `.mjs`. **No shell scripts anywhere in the repo.**
- npm dependencies must be pinned to exact versions (`--save-exact`) with `package-lock.json` committed; CI uses `npm ci`.
- Node tests: `node --test scripts/__tests__/`. Swift tests: `swift test --package-path macos`.
- App name `Macomprendo`, bundle `Macomprendo.app`, executable `Macomprendo`.
- Bundle identifier `com.dzamataev.macomprendo`. Development team `68QJJA7HK9`.
- Copyright "© 2026 Denis Zamataev". Licence MIT.
- Deployment target macOS `14.0`. Universal binary: `arm64` + `x86_64`.
- Version source of truth: `MARKETING_VERSION` in `macos/project.yml`; mirrored into `macos/Macomprendo.xcodeproj/project.pbxproj`.
- Git tags are `vX.Y.Z`; CHANGELOG headings are `## [X.Y.Z] - YYYY-MM-DD` (Keep a Changelog style).
- Notary Keychain profile name: `macomprendo-notary`.
- Secrets never appear in `process.argv`, logs, or the repository.
- No machine-specific absolute paths (`/Users/<name>`) may be committed — use `~/`, `<repo>`, or `/Users/test`.
- GitHub Actions must be pinned by commit SHA.
- Commit after every task using conventional commits.

---

## File Structure

**New files created by this plan**

| File | Responsibility |
|---|---|
| `scripts/lib/paths.mjs` | Repo-root anchored path + identity constants shared by all tools |
| `scripts/lib/changelog.mjs` | Pure CHANGELOG.md transforms (release the Unreleased section, extract notes) |
| `scripts/build-app.mjs` | Per-arch `swift build` → `lipo` → assemble `.app` → PlistBuddy → codesign |
| `scripts/configure-notarization.mjs` | One-time `notarytool store-credentials` with a muted password prompt |
| `scripts/notarize-app.mjs` | Developer ID identity discovery, submit/staple/validate, final ZIP + SHA-256 |
| `scripts/release.mjs` | Preflight, version bump, changelog, tests, commit, tag, push, `gh release` |
| `scripts/audit-public-repo.mjs` | Refuse to publish sensitive filenames, machine paths, whitespace errors |
| `scripts/install-app.mjs` | Build + atomic install into `/Applications` with backup/restore |
| `scripts/__tests__/helpers/fake-run.mjs` | `node:test` doubles for `run`, `fsOps`, `io`, `log` |
| `scripts/__tests__/*.test.mjs` | One test file per tool |
| `DISTRIBUTING.md` | Full signing/notarization/release runbook |
| `docs/DECISIONS/ADR-0001..0006-*.md` | The six decisions from spec §9 |
| `.github/workflows/release.yml` | Tag-triggered (`v*`) test + unsigned artifact build |

**Modified files**

| File | Change |
|---|---|
| `package.json` / `package-lock.json` | New deps + `build`, `notarize`, `configure-notary`, `release`, `audit`, `install-app` scripts |
| `scripts/lib/fs.mjs` | Add filesystem-operation helpers + `realFsOps` / `realIO` bundles |
| `README.md` | Final content: features, install, hotkeys, privacy |
| `CHANGELOG.md` | 0.1.0 Unreleased entries |
| `docs/SMOKE_TEST.md` | Add the release checklist section |
| `.github/workflows/ci.yml` | Add audit + build dry-run + symlink check |
| `.agents/skills/macomprendo-release/SKILL.md` | Finalize with exact commands |

---

## Interface additions beyond the shared map

These are new and are used by later tasks in this plan. Nothing outside Plan 5 consumes them.

```js
// scripts/lib/paths.mjs  (NEW)
export const ROOT, MACOS_DIR, PROJECT_YML, PBXPROJ, XCODEPROJ, CHANGELOG_PATH,
             APP_BUNDLE_DIR, INFO_PLIST_SRC, ICON_SRC, ENTITLEMENTS_SRC, LICENSE_PATH,
             DIST_DIR, README_PATH
export const APP_NAME, EXECUTABLE_NAME, BUNDLE_ID, TEAM_ID, NOTARY_PROFILE,
             DEPLOYMENT_TARGET, SCHEME
export function appPath(distDir)

// scripts/lib/fs.mjs  (ADDITIONS to the Plan 1 file)
export async function mkdirp(dir)
export async function rmrf(target)
export async function copyPath(from, to)
export async function chmodExec(file)
export async function pathExists(p)
export async function listDirsWithSuffix(dir, suffix)
export const listBundles      // (dir) => *.bundle directory names, sorted
export const listFrameworks   // (dir) => *.framework directory names, sorted
export async function move(from, to)          // added in Task 10
export async function makeTempDir(prefix)     // added in Task 10
export const realFsOps   // the six/eight operations above, as one injectable object
export const realIO      // { readFile, writeFile, exists }

// scripts/lib/changelog.mjs  (NEW)
export function updateChangelog(text, version, isoDate)
export function extractSection(text, version)
```

Each `scripts/*.mjs` tool exports its own pure helpers plus `export async function main(argv, deps = {})`; the names are listed in each task's **Produces** block.

---

### Task 1: Tooling foundation — dependencies, paths, filesystem helpers

**Files:**
- Modify: `package.json`
- Create: `scripts/lib/paths.mjs`
- Modify: `scripts/lib/fs.mjs`
- Create: `scripts/__tests__/helpers/fake-run.mjs`
- Test: `scripts/__tests__/paths.test.mjs`

**Interfaces:**
- Consumes: `scripts/lib/{run,log,version,fs}.mjs` from Plan 1.
- Produces: everything in the "Interface additions" block above, plus the test doubles
  `makeFakeRun(script)`, `makeFakeFsOps(initial)`, `makeFakeIO(files)`, `makeFakeLog()`.

- [ ] **Step 1: Install the pinned npm dependencies**

Run:

```bash
cd /path/to/macomprendo
npm install --save-exact execa@9.5.2 picocolors@1.1.1 yaml@2.6.1
```

Expected: `package.json` `dependencies` now contains exactly `"execa": "9.5.2"`, `"picocolors": "1.1.1"`, `"yaml": "2.6.1"` (no `^`), and `package-lock.json` is updated. If Plan 1 already added `execa` or `picocolors`, the command is a no-op for those and only pins them.

- [ ] **Step 2: Write the failing test for `scripts/lib/paths.mjs`**

Create `scripts/__tests__/paths.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';

import {
  ROOT, MACOS_DIR, PROJECT_YML, PBXPROJ, DIST_DIR,
  APP_NAME, EXECUTABLE_NAME, BUNDLE_ID, TEAM_ID,
  NOTARY_PROFILE, DEPLOYMENT_TARGET, SCHEME, appPath,
} from '../lib/paths.mjs';

test('ROOT points at the repository checkout', () => {
  assert.equal(path.basename(PROJECT_YML), 'project.yml');
  assert.equal(MACOS_DIR, path.join(ROOT, 'macos'));
  assert.ok(existsSync(path.join(ROOT, 'package.json')));
});

test('identity constants match the spec', () => {
  assert.equal(APP_NAME, 'Macomprendo.app');
  assert.equal(EXECUTABLE_NAME, 'Macomprendo');
  assert.equal(BUNDLE_ID, 'com.dzamataev.macomprendo');
  assert.equal(TEAM_ID, '68QJJA7HK9');
  assert.equal(NOTARY_PROFILE, 'macomprendo-notary');
  assert.equal(DEPLOYMENT_TARGET, '14.0');
  assert.equal(SCHEME, 'Macomprendo');
});

test('pbxproj path targets the committed Xcode project', () => {
  assert.equal(PBXPROJ, path.join(ROOT, 'macos/Macomprendo.xcodeproj/project.pbxproj'));
});

test('appPath joins a dist directory with the bundle name', () => {
  assert.equal(appPath('/tmp/out'), '/tmp/out/Macomprendo.app');
  assert.equal(appPath(), path.join(DIST_DIR, 'Macomprendo.app'));
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `node --test scripts/__tests__/paths.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/lib/paths.mjs'`.

- [ ] **Step 4: Implement `scripts/lib/paths.mjs`**

```js
// Repo-anchored paths and release identity constants shared by every tool in scripts/.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url)); // <root>/scripts/lib

export const ROOT = path.resolve(here, '..', '..');
export const MACOS_DIR = path.join(ROOT, 'macos');
export const PROJECT_YML = path.join(MACOS_DIR, 'project.yml');
export const XCODEPROJ = path.join(MACOS_DIR, 'Macomprendo.xcodeproj');
export const PBXPROJ = path.join(XCODEPROJ, 'project.pbxproj');
export const CHANGELOG_PATH = path.join(ROOT, 'CHANGELOG.md');
export const README_PATH = path.join(ROOT, 'README.md');
export const LICENSE_PATH = path.join(ROOT, 'LICENSE');
export const APP_BUNDLE_DIR = path.join(MACOS_DIR, 'AppBundle');
export const INFO_PLIST_SRC = path.join(APP_BUNDLE_DIR, 'Info.plist');
export const ICON_SRC = path.join(APP_BUNDLE_DIR, 'AppIcon.icns');
export const ENTITLEMENTS_SRC = path.join(APP_BUNDLE_DIR, 'Macomprendo.entitlements');
export const DIST_DIR = path.join(ROOT, 'dist');

export const APP_NAME = 'Macomprendo.app';
export const EXECUTABLE_NAME = 'Macomprendo';
export const BUNDLE_ID = 'com.dzamataev.macomprendo';
export const TEAM_ID = '68QJJA7HK9';
export const NOTARY_PROFILE = 'macomprendo-notary';
export const DEPLOYMENT_TARGET = '14.0';
export const SCHEME = 'Macomprendo';

export function appPath(distDir = DIST_DIR) {
  return path.join(distDir, APP_NAME);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `node --test scripts/__tests__/paths.test.mjs`
Expected: PASS — `# pass 4`, `# fail 0`.

- [ ] **Step 6: Write the failing test for the `scripts/lib/fs.mjs` additions**

Create `scripts/__tests__/fs-ops.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, stat, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  mkdirp, rmrf, copyPath, chmodExec, pathExists, listBundles, listFrameworks, realFsOps, realIO,
} from '../lib/fs.mjs';

async function scratch() {
  return mkdtemp(path.join(tmpdir(), 'macomprendo-fs-'));
}

test('mkdirp creates nested directories and is idempotent', async () => {
  const dir = await scratch();
  const deep = path.join(dir, 'a/b/c');
  await mkdirp(deep);
  await mkdirp(deep);
  assert.equal(await pathExists(deep), true);
});

test('rmrf removes a tree and tolerates a missing path', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'x/y'));
  await rmrf(path.join(dir, 'x'));
  assert.equal(await pathExists(path.join(dir, 'x')), false);
  await rmrf(path.join(dir, 'never-existed'));
});

test('copyPath copies files and directories recursively', async () => {
  const dir = await scratch();
  await mkdir(path.join(dir, 'src/inner'), { recursive: true });
  await writeFile(path.join(dir, 'src/inner/note.txt'), 'hello');
  await copyPath(path.join(dir, 'src'), path.join(dir, 'dst'));
  assert.equal(await readFile(path.join(dir, 'dst/inner/note.txt'), 'utf8'), 'hello');
});

test('chmodExec makes a file executable', async () => {
  const dir = await scratch();
  const file = path.join(dir, 'bin');
  await writeFile(file, '#!/bin/sh\n', { mode: 0o644 });
  await chmodExec(file);
  assert.equal((await stat(file)).mode & 0o111, 0o111);
});

test('listBundles returns sorted *.bundle directory names only', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'Macomprendo_Macomprendo.bundle'));
  await mkdirp(path.join(dir, 'zeta_target.bundle'));
  await mkdirp(path.join(dir, 'Modules'));
  await mkdirp(path.join(dir, 'whisper.framework'));
  await writeFile(path.join(dir, 'not-a-dir.bundle'), '');
  assert.deepEqual(await listBundles(dir),
    ['Macomprendo_Macomprendo.bundle', 'zeta_target.bundle']);
});

test('listFrameworks returns sorted *.framework directory names only', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'whisper.framework'));
  await mkdirp(path.join(dir, 'Macomprendo_Macomprendo.bundle'));
  assert.deepEqual(await listFrameworks(dir), ['whisper.framework']);
});

test('listBundles and listFrameworks return an empty list for a missing directory', async () => {
  assert.deepEqual(await listBundles('/nope/does/not/exist'), []);
  assert.deepEqual(await listFrameworks('/nope/does/not/exist'), []);
});

test('realFsOps and realIO expose the operation bundles', async () => {
  for (const key of ['mkdirp', 'rmrf', 'copyPath', 'chmodExec', 'pathExists', 'listBundles', 'listFrameworks']) {
    assert.equal(typeof realFsOps[key], 'function', key);
  }
  for (const key of ['readFile', 'writeFile', 'exists']) {
    assert.equal(typeof realIO[key], 'function', key);
  }
  const dir = await scratch();
  await realIO.writeFile(path.join(dir, 'a.txt'), 'x');
  assert.equal(await realIO.readFile(path.join(dir, 'a.txt')), 'x');
  assert.equal(await realIO.exists(path.join(dir, 'a.txt')), true);
});
```

- [ ] **Step 7: Run the test to verify it fails**

Run: `node --test scripts/__tests__/fs-ops.test.mjs`
Expected: FAIL — `SyntaxError: The requested module '../lib/fs.mjs' does not provide an export named 'mkdirp'`.

- [ ] **Step 8: Append the helpers to `scripts/lib/fs.mjs`**

Keep the existing `ensureSymlink` and `sha256` exports untouched; append:

```js
import { mkdir, rm, cp, chmod, readdir, readFile as fsReadFile, writeFile as fsWriteFile, access }
  from 'node:fs/promises';
import path from 'node:path';

export async function mkdirp(dir) {
  await mkdir(dir, { recursive: true });
}

export async function rmrf(target) {
  await rm(target, { recursive: true, force: true });
}

export async function copyPath(from, to) {
  await mkdir(path.dirname(to), { recursive: true });
  await cp(from, to, { recursive: true, force: true, dereference: false });
}

export async function chmodExec(file) {
  await chmod(file, 0o755);
}

export async function pathExists(p) {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

export async function listDirsWithSuffix(dir, suffix) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(suffix))
    .map((entry) => entry.name)
    .sort();
}

// SwiftPM emits our own target's resources as <Package>_<Target>.bundle next to the
// executable, and binary xcframework slices as *.framework. Both must reach the app bundle.
export const listBundles = (dir) => listDirsWithSuffix(dir, '.bundle');
export const listFrameworks = (dir) => listDirsWithSuffix(dir, '.framework');

export const realFsOps = {
  mkdirp, rmrf, copyPath, chmodExec, pathExists, listBundles, listFrameworks,
};

export const realIO = {
  readFile: (p) => fsReadFile(p, 'utf8'),
  writeFile: (p, text) => fsWriteFile(p, text, 'utf8'),
  exists: pathExists,
};
```

If `scripts/lib/fs.mjs` already imports some of these from `node:fs/promises`, merge the import statements instead of adding a duplicate.

- [ ] **Step 9: Run the test to verify it passes**

Run: `node --test scripts/__tests__/fs-ops.test.mjs`
Expected: PASS — `# pass 8`, `# fail 0`.

- [ ] **Step 10: Create the shared test doubles**

Create `scripts/__tests__/helpers/fake-run.mjs`:

```js
// Test doubles for the injected side-effect boundaries used by scripts/*.mjs.
// This file is NOT a test file (node --test only collects *.test.mjs here).

/**
 * @param {Array<{ stdout?: string, stderr?: string, code?: number, throws?: string }>} script
 *        One entry per expected call, consumed in order. Missing entries behave as success.
 */
export function makeFakeRun(script = []) {
  let index = 0;
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    calls.push({ cmd, args, options, line: [cmd, ...args].join(' ') });
    const next = script[index] ?? {};
    index += 1;
    if (next.throws) {
      const error = new Error(next.throws);
      error.exitCode = next.code ?? 1;
      error.stdout = next.stdout ?? '';
      error.stderr = next.stderr ?? '';
      if (options.check === false) return { stdout: error.stdout, stderr: error.stderr, code: error.exitCode };
      throw error;
    }
    return { stdout: next.stdout ?? '', stderr: next.stderr ?? '', code: next.code ?? 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((call) => call.line);
  return run;
}

export function makeFakeFsOps(existing = []) {
  const present = new Set(existing);
  const events = [];
  return {
    events,
    present,
    async mkdirp(dir) { events.push(['mkdirp', dir]); present.add(dir); },
    async rmrf(target) { events.push(['rmrf', target]); present.delete(target); },
    async copyPath(from, to) { events.push(['copyPath', from, to]); present.add(to); },
    async chmodExec(file) { events.push(['chmodExec', file]); },
    async pathExists(p) { return present.has(p); },
    async listBundles(dir) { events.push(['listBundles', dir]); return this.bundles ?? []; },
    async listFrameworks(dir) { events.push(['listFrameworks', dir]); return this.frameworks ?? []; },
    bundles: [],
    frameworks: [],
  };
}

export function makeFakeIO(files = {}) {
  const store = new Map(Object.entries(files));
  const writes = [];
  return {
    store,
    writes,
    async readFile(p) {
      if (!store.has(p)) throw Object.assign(new Error(`ENOENT: ${p}`), { code: 'ENOENT' });
      return store.get(p);
    },
    async writeFile(p, text) { store.set(p, text); writes.push(p); },
    async exists(p) { return store.has(p); },
  };
}

export function makeFakeLog() {
  const lines = [];
  const push = (level) => (msg) => lines.push(`${level}: ${msg}`);
  return { lines, info: push('info'), warn: push('warn'), error: push('error'), step: push('step') };
}
```

- [ ] **Step 11: Run the whole Node suite**

Run: `node --test scripts/__tests__/`
Expected: PASS — all existing Plan 1 tests plus the new `paths` and `fs-ops` tests; `# fail 0`.

- [ ] **Step 12: Commit**

```bash
git add package.json package-lock.json scripts/lib/paths.mjs scripts/lib/fs.mjs \
        scripts/__tests__/paths.test.mjs scripts/__tests__/fs-ops.test.mjs \
        scripts/__tests__/helpers/fake-run.mjs
git commit -m "chore(scripts): add release tooling foundation (paths, fs ops, test doubles)"
```

---

### Task 2: CHANGELOG transforms

**Files:**
- Create: `scripts/lib/changelog.mjs`
- Test: `scripts/__tests__/changelog.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `updateChangelog(text, version, isoDate) -> string` — moves the entries under `## [Unreleased]` into a new `## [X.Y.Z] - YYYY-MM-DD` section, leaving an empty `## [Unreleased]` heading on top. Throws `Error` when the heading is missing or the section is empty.
  - `extractSection(text, version) -> string` — the body of the `## [X.Y.Z]` section, trimmed, for `gh release --notes-file`. Throws when the section is absent.

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/changelog.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { updateChangelog, extractSection } from '../lib/changelog.mjs';

const SAMPLE = `# Changelog

## [Unreleased]

### Added
- Dictation hotkey.

### Fixed
- Pasteboard restore race.

## [0.1.0] - 2026-08-01

- First release.
`;

test('updateChangelog dates the Unreleased entries and keeps an empty Unreleased heading', () => {
  const updated = updateChangelog(SAMPLE, '0.2.0', '2026-08-23');
  assert.match(updated, /## \[Unreleased\]\n\n## \[0\.2\.0\] - 2026-08-23\n\n### Added\n- Dictation hotkey\./);
  assert.equal(updated.match(/- Dictation hotkey\./g).length, 1);
  assert.ok(updated.includes('## [0.1.0] - 2026-08-01'));
  assert.ok(updated.startsWith('# Changelog\n'));
});

test('updateChangelog works when there is no previous release section', () => {
  const text = '# Changelog\n\n## [Unreleased]\n\n- Only entry.\n';
  const updated = updateChangelog(text, '0.1.0', '2026-08-23');
  assert.equal(updated, '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-23\n\n- Only entry.\n');
});

test('updateChangelog refuses an empty Unreleased section', () => {
  const text = '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n';
  assert.throws(() => updateChangelog(text, '0.2.0', '2026-08-23'),
    /no entries under "## \[Unreleased\]"/);
});

test('updateChangelog refuses a missing Unreleased heading', () => {
  assert.throws(() => updateChangelog('# Changelog\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n', '0.2.0', '2026-08-23'),
    /missing an "## \[Unreleased\]" heading/);
});

test('extractSection returns the notes body for one version', () => {
  const released = updateChangelog(SAMPLE, '0.2.0', '2026-08-23');
  assert.equal(
    extractSection(released, '0.2.0'),
    '### Added\n- Dictation hotkey.\n\n### Fixed\n- Pasteboard restore race.',
  );
  assert.equal(extractSection(released, '0.1.0'), '- First release.');
});

test('extractSection throws for an unknown version', () => {
  assert.throws(() => extractSection(SAMPLE, '9.9.9'), /no "## \[9\.9\.9\]" section/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/changelog.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/lib/changelog.mjs'`.

- [ ] **Step 3: Implement `scripts/lib/changelog.mjs`**

```js
// Pure Keep-a-Changelog transforms. No filesystem access.

const UNRELEASED = /^## \[Unreleased\][^\n]*$/m;
const ANY_RELEASE = /^## \[\d+\.\d+\.\d+\][^\n]*$/m;

function escapeVersion(version) {
  return version.replace(/\./g, '\\.');
}

export function updateChangelog(text, version, isoDate) {
  const heading = UNRELEASED.exec(text);
  if (heading === null) {
    throw new Error('CHANGELOG.md is missing an "## [Unreleased]" heading.');
  }
  const bodyStart = heading.index + heading[0].length;
  const rest = text.slice(bodyStart);
  const nextHeading = ANY_RELEASE.exec(rest);
  const bodyEnd = nextHeading === null ? text.length : bodyStart + nextHeading.index;

  const entries = text.slice(bodyStart, bodyEnd).trim();
  if (entries === '') {
    throw new Error('CHANGELOG.md has no entries under "## [Unreleased]"; write release notes first.');
  }

  const remainder = text.slice(bodyEnd).replace(/^\n+/, '');
  const released = `## [Unreleased]\n\n## [${version}] - ${isoDate}\n\n${entries}\n${remainder === '' ? '' : '\n'}`;
  return text.slice(0, heading.index) + released + remainder;
}

export function extractSection(text, version) {
  const heading = new RegExp(`^## \\[${escapeVersion(version)}\\][^\\n]*$`, 'm').exec(text);
  if (heading === null) {
    throw new Error(`CHANGELOG.md has no "## [${version}]" section.`);
  }
  const bodyStart = heading.index + heading[0].length;
  const rest = text.slice(bodyStart);
  const nextHeading = /^## \[/m.exec(rest);
  const body = nextHeading === null ? rest : rest.slice(0, nextHeading.index);
  return body.trim();
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/changelog.test.mjs`
Expected: PASS — `# pass 6`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/changelog.mjs scripts/__tests__/changelog.test.mjs
git commit -m "feat(scripts): add CHANGELOG release and notes-extraction helpers"
```

---

### Task 3: `build-app.mjs` — argument parsing and the command plan

**Files:**
- Create: `scripts/build-app.mjs`
- Test: `scripts/__tests__/build-app.test.mjs`
- Modify: `package.json` (add the `build` script)

**Interfaces:**
- Consumes: `scripts/lib/paths.mjs` (Task 1), `scripts/lib/version.mjs` (`readVersion`, Plan 1),
  `scripts/lib/run.mjs` (`run`), `scripts/lib/log.mjs` (`log`), `scripts/lib/fs.mjs` (`realFsOps`, `realIO`).
- Produces:
  - `parseBuildArgs(argv) -> BuildOptions` where
    `BuildOptions = { archs: string[], sign: string, configuration: 'release'|'debug', deploymentTarget: string, entitlements: string, buildNumber: string|null, version: string|null, dist: string, dryRun: boolean, help: boolean }`
  - `tripleFor(arch, deploymentTarget) -> string`
  - `predictBinPath(root, triple, configuration) -> string`
  - `bundleLayout(distDir) -> { app, contents, macosDir, resources, frameworks, executable, infoPlist }`
  - `planBuild(options, context) -> Step[]` where
    `context = { version, buildNumber, binPaths: Record<arch,string>, resourceBundles: string[], frameworks?: string[] }` and
    `Step = { type: 'exec', cmd, args } | { type: 'rm'|'mkdir', path } | { type: 'copy', from, to } | { type: 'chmod', path }`
  - `describeStep(step) -> string`

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/build-app.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

import {
  parseBuildArgs, tripleFor, predictBinPath, bundleLayout, planBuild, describeStep,
} from '../build-app.mjs';
import { ROOT, DIST_DIR, BUNDLE_ID } from '../lib/paths.mjs';

test('parseBuildArgs defaults to the host architecture and an ad-hoc signature', () => {
  const options = parseBuildArgs([]);
  assert.deepEqual(options.archs, [process.arch === 'arm64' ? 'arm64' : 'x86_64']);
  assert.equal(options.sign, '-');
  assert.equal(options.configuration, 'release');
  assert.equal(options.deploymentTarget, '14.0');
  assert.equal(options.dist, DIST_DIR);
  assert.equal(options.dryRun, false);
});

test('parseBuildArgs reads a comma separated arch list and a signing identity', () => {
  const options = parseBuildArgs([
    '--arch', 'arm64,x86_64',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '--configuration', 'release',
    '--dry-run',
  ]);
  assert.deepEqual(options.archs, ['arm64', 'x86_64']);
  assert.equal(options.sign, 'Developer ID Application: Denis Zamataev (68QJJA7HK9)');
  assert.equal(options.dryRun, true);
});

test('parseBuildArgs trims whitespace and rejects unknown architectures', () => {
  assert.deepEqual(parseBuildArgs(['--arch', ' arm64 , x86_64 ']).archs, ['arm64', 'x86_64']);
  assert.throws(() => parseBuildArgs(['--arch', 'ppc']), /Unsupported architecture "ppc"/);
  assert.throws(() => parseBuildArgs(['--arch', '']), /at least one architecture/);
});

test('parseBuildArgs rejects an unknown configuration', () => {
  assert.throws(() => parseBuildArgs(['--configuration', 'profile']),
    /Configuration must be "release" or "debug"/);
});

test('tripleFor builds an SPM triple', () => {
  assert.equal(tripleFor('arm64', '14.0'), 'arm64-apple-macosx14.0');
  assert.equal(tripleFor('x86_64', '14.0'), 'x86_64-apple-macosx14.0');
});

test('predictBinPath mirrors the SwiftPM build layout', () => {
  assert.equal(
    predictBinPath('/repo', 'arm64-apple-macosx14.0', 'release'),
    '/repo/macos/.build/arm64-apple-macosx14.0/release',
  );
});

test('bundleLayout describes the app bundle', () => {
  const layout = bundleLayout('/out');
  assert.equal(layout.app, '/out/Macomprendo.app');
  assert.equal(layout.contents, '/out/Macomprendo.app/Contents');
  assert.equal(layout.macosDir, '/out/Macomprendo.app/Contents/MacOS');
  assert.equal(layout.resources, '/out/Macomprendo.app/Contents/Resources');
  assert.equal(layout.frameworks, '/out/Macomprendo.app/Contents/Frameworks');
  assert.equal(layout.executable, '/out/Macomprendo.app/Contents/MacOS/Macomprendo');
  assert.equal(layout.infoPlist, '/out/Macomprendo.app/Contents/Info.plist');
});

function planFixture(overrides = {}) {
  const options = parseBuildArgs(['--arch', 'arm64,x86_64', '--dist', '/out', ...(overrides.argv ?? [])]);
  return planBuild(options, {
    version: '1.2.3',
    buildNumber: '1.2.3',
    binPaths: { arm64: '/b/arm64', x86_64: '/b/x86_64' },
    resourceBundles: ['Macomprendo_Macomprendo.bundle'],
    frameworks: [],
    ...(overrides.context ?? {}),
  });
}

test('planBuild compiles every architecture before assembling', () => {
  const lines = planFixture().filter((s) => s.type === 'exec').map(describeStep);
  assert.ok(lines[0].startsWith('swift build --package-path'), lines[0]);
  assert.ok(lines[0].includes('--triple arm64-apple-macosx14.0'));
  assert.ok(lines[1].includes('--triple x86_64-apple-macosx14.0'));
  assert.ok(lines[0].includes('-c release'));
});

test('planBuild lipos two slices into one executable', () => {
  const lipo = planFixture().find((s) => s.type === 'exec' && s.cmd === 'lipo');
  assert.deepEqual(lipo.args, [
    '-create', '/b/arm64/Macomprendo', '/b/x86_64/Macomprendo',
    '-output', '/out/Macomprendo.app/Contents/MacOS/Macomprendo',
  ]);
});

test('planBuild copies a single slice instead of running lipo', () => {
  const steps = planBuild(parseBuildArgs(['--arch', 'arm64', '--dist', '/out']), {
    version: '1.2.3', buildNumber: '1.2.3',
    binPaths: { arm64: '/b/arm64' }, resourceBundles: [],
  });
  assert.equal(steps.some((s) => s.cmd === 'lipo' && s.args[0] === '-create'), false);
  assert.ok(steps.some((s) => s.type === 'copy'
    && s.from === '/b/arm64/Macomprendo'
    && s.to === '/out/Macomprendo.app/Contents/MacOS/Macomprendo'));
});

test('planBuild wipes the previous bundle and creates the skeleton', () => {
  const steps = planFixture();
  assert.deepEqual(steps[2], { type: 'rm', path: '/out/Macomprendo.app' });
  assert.deepEqual(steps[3], { type: 'mkdir', path: '/out/Macomprendo.app/Contents/MacOS' });
  assert.deepEqual(steps[4], { type: 'mkdir', path: '/out/Macomprendo.app/Contents/Resources' });
});

test('planBuild copies Info.plist, the icon, the licence and the SPM resource bundles', () => {
  const copies = planFixture().filter((s) => s.type === 'copy');
  const targets = copies.map((s) => s.to);
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Info.plist'));
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Resources/AppIcon.icns'));
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Resources/LICENSE'));
  assert.ok(copies.some((s) =>
    s.from === '/b/arm64/Macomprendo_Macomprendo.bundle'
    && s.to === '/out/Macomprendo.app/Contents/Resources/Macomprendo_Macomprendo.bundle'));
});

test('planBuild embeds discovered frameworks in Contents/Frameworks', () => {
  const steps = planFixture({ context: { frameworks: ['whisper.framework'] } });
  assert.ok(steps.some((s) =>
    s.type === 'mkdir' && s.path === '/out/Macomprendo.app/Contents/Frameworks'));
  assert.ok(steps.some((s) => s.type === 'copy'
    && s.from === '/b/arm64/whisper.framework'
    && s.to === '/out/Macomprendo.app/Contents/Frameworks/whisper.framework'));
  const install = steps.find((s) => s.cmd === 'install_name_tool');
  assert.deepEqual(install.args, [
    '-add_rpath', '@executable_path/../Frameworks',
    '/out/Macomprendo.app/Contents/MacOS/Macomprendo',
  ]);
});

test('planBuild omits the Frameworks directory when nothing needs embedding', () => {
  const steps = planFixture();
  assert.equal(steps.some((s) => s.type === 'mkdir' && s.path.endsWith('/Frameworks')), false);
  assert.equal(steps.some((s) => s.cmd === 'install_name_tool'), false);
});

test('planBuild stamps the version, build number and bundle identifier with PlistBuddy', () => {
  const plist = planFixture()
    .filter((s) => s.type === 'exec' && s.cmd === '/usr/libexec/PlistBuddy')
    .map((s) => s.args[1]);
  assert.deepEqual(plist, [
    'Set :CFBundleShortVersionString 1.2.3',
    'Set :CFBundleVersion 1.2.3',
    `Set :CFBundleIdentifier ${BUNDLE_ID}`,
  ]);
});

test('planBuild ad-hoc signs by default', () => {
  const signs = planFixture().filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, ['--force', '--sign', '-', '/out/Macomprendo.app']);
  assert.deepEqual(signs.at(-1).args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
});

test('planBuild signs nested code then the app with hardened runtime for a real identity', () => {
  const steps = planFixture({
    argv: ['--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)'],
    context: { frameworks: ['whisper.framework'] },
  });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app/Contents/Frameworks/whisper.framework',
  ]);
  assert.deepEqual(signs[1].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app/Contents/Resources/Macomprendo_Macomprendo.bundle',
  ]);
  assert.deepEqual(signs[2].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--entitlements', path.join(ROOT, 'macos/AppBundle/Macomprendo.entitlements'),
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app',
  ]);
  assert.deepEqual(signs[3].args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
});

test('planBuild ends by reporting the architectures actually produced', () => {
  const last = planFixture().at(-1);
  assert.deepEqual(last, {
    type: 'exec', cmd: 'lipo',
    args: ['-archs', '/out/Macomprendo.app/Contents/MacOS/Macomprendo'],
    capture: true,
  });
});

test('describeStep renders every step type as one readable line', () => {
  assert.equal(describeStep({ type: 'exec', cmd: 'lipo', args: ['-archs', '/a b'] }), 'lipo -archs "/a b"');
  assert.equal(describeStep({ type: 'rm', path: '/a' }), 'rm -rf /a');
  assert.equal(describeStep({ type: 'mkdir', path: '/a' }), 'mkdir -p /a');
  assert.equal(describeStep({ type: 'copy', from: '/a', to: '/b' }), 'cp -R /a /b');
  assert.equal(describeStep({ type: 'chmod', path: '/a' }), 'chmod 755 /a');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/build-app.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/build-app.mjs'`.

- [ ] **Step 3: Implement the pure half of `scripts/build-app.mjs`**

Create `scripts/build-app.mjs` with exactly this content for now (the executing half arrives in Task 4):

```js
#!/usr/bin/env node
// Build Macomprendo.app: swift build per architecture, lipo, assemble the bundle, codesign.
//
// SwiftPM emits two kinds of sidecar next to the executable, and both must reach the app:
//   *.bundle     our own target's resources (Macomprendo_Macomprendo.bundle: vendored
//                Phosphor SVGs and other assets). Copied into Contents/Resources, where
//                the generated `Bundle.module` accessor finds them via
//                Bundle.main.resourceURL.
//   *.framework  slices extracted from binary xcframework targets (whisper.cpp is consumed
//                as a prebuilt xcframework, see docs/DECISIONS/ADR-0007). Copied into
//                Contents/Frameworks, an @rpath is added, and each is signed before the
//                enclosing app. If the slices are static, `swift build` emits none and this
//                whole branch is skipped.
// See DISTRIBUTING.md > "What the build copies into the bundle".
import path from 'node:path';
import os from 'node:os';
import { parseArgs } from 'node:util';

import {
  ROOT, MACOS_DIR, DIST_DIR, APP_NAME, EXECUTABLE_NAME, BUNDLE_ID,
  DEPLOYMENT_TARGET, INFO_PLIST_SRC, ICON_SRC, ENTITLEMENTS_SRC, LICENSE_PATH,
} from './lib/paths.mjs';

const SUPPORTED_ARCHS = ['arm64', 'x86_64'];

export function parseBuildArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      arch: { type: 'string' },
      sign: { type: 'string' },
      configuration: { type: 'string' },
      'deployment-target': { type: 'string' },
      entitlements: { type: 'string' },
      'build-number': { type: 'string' },
      version: { type: 'string' },
      dist: { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });

  const archSource = values.arch ?? (os.arch() === 'arm64' ? 'arm64' : 'x86_64');
  const archs = archSource.split(',').map((a) => a.trim()).filter((a) => a !== '');
  if (archs.length === 0) throw new Error('--arch needs at least one architecture.');
  for (const arch of archs) {
    if (!SUPPORTED_ARCHS.includes(arch)) {
      throw new Error(`Unsupported architecture "${arch}". Use arm64 and/or x86_64.`);
    }
  }

  const configuration = values.configuration ?? 'release';
  if (configuration !== 'release' && configuration !== 'debug') {
    throw new Error('Configuration must be "release" or "debug".');
  }

  return {
    archs,
    sign: values.sign ?? '-',
    configuration,
    deploymentTarget: values['deployment-target'] ?? DEPLOYMENT_TARGET,
    entitlements: values.entitlements ?? ENTITLEMENTS_SRC,
    buildNumber: values['build-number'] ?? null,
    version: values.version ?? null,
    dist: values.dist ?? DIST_DIR,
    dryRun: values['dry-run'],
    help: values.help,
  };
}

export function tripleFor(arch, deploymentTarget) {
  return `${arch}-apple-macosx${deploymentTarget}`;
}

export function predictBinPath(root, triple, configuration) {
  return path.join(root, 'macos', '.build', triple, configuration);
}

export function bundleLayout(distDir) {
  const app = path.join(distDir, APP_NAME);
  const contents = path.join(app, 'Contents');
  return {
    app,
    contents,
    macosDir: path.join(contents, 'MacOS'),
    resources: path.join(contents, 'Resources'),
    frameworks: path.join(contents, 'Frameworks'),
    executable: path.join(contents, 'MacOS', EXECUTABLE_NAME),
    infoPlist: path.join(contents, 'Info.plist'),
  };
}

export function planBuild(options, context) {
  const { version, buildNumber, binPaths, resourceBundles, frameworks = [] } = context;
  const layout = bundleLayout(options.dist);
  const steps = [];

  for (const arch of options.archs) {
    steps.push({
      type: 'exec',
      cmd: 'swift',
      args: [
        'build', '--package-path', MACOS_DIR,
        '-c', options.configuration,
        '--triple', tripleFor(arch, options.deploymentTarget),
      ],
    });
  }

  steps.push({ type: 'rm', path: layout.app });
  steps.push({ type: 'mkdir', path: layout.macosDir });
  steps.push({ type: 'mkdir', path: layout.resources });
  if (frameworks.length > 0) steps.push({ type: 'mkdir', path: layout.frameworks });

  const slices = options.archs.map((arch) => path.join(binPaths[arch], EXECUTABLE_NAME));
  if (slices.length === 1) {
    steps.push({ type: 'copy', from: slices[0], to: layout.executable });
  } else {
    steps.push({
      type: 'exec',
      cmd: 'lipo',
      args: ['-create', ...slices, '-output', layout.executable],
    });
  }

  steps.push({ type: 'copy', from: INFO_PLIST_SRC, to: layout.infoPlist });
  steps.push({ type: 'copy', from: ICON_SRC, to: path.join(layout.resources, 'AppIcon.icns') });
  steps.push({ type: 'copy', from: LICENSE_PATH, to: path.join(layout.resources, 'LICENSE') });

  const primaryBin = binPaths[options.archs[0]];
  for (const bundle of resourceBundles) {
    steps.push({
      type: 'copy',
      from: path.join(primaryBin, bundle),
      to: path.join(layout.resources, bundle),
    });
  }
  for (const framework of frameworks) {
    steps.push({
      type: 'copy',
      from: path.join(primaryBin, framework),
      to: path.join(layout.frameworks, framework),
    });
  }
  if (frameworks.length > 0) {
    steps.push({
      type: 'exec',
      cmd: 'install_name_tool',
      args: ['-add_rpath', '@executable_path/../Frameworks', layout.executable],
    });
  }

  const plist = (command) => ({
    type: 'exec',
    cmd: '/usr/libexec/PlistBuddy',
    args: ['-c', command, layout.infoPlist],
  });
  steps.push(plist(`Set :CFBundleShortVersionString ${version}`));
  steps.push(plist(`Set :CFBundleVersion ${buildNumber}`));
  steps.push(plist(`Set :CFBundleIdentifier ${BUNDLE_ID}`));

  steps.push({ type: 'chmod', path: layout.executable });

  if (options.sign === '-') {
    steps.push({ type: 'exec', cmd: 'codesign', args: ['--force', '--sign', '-', layout.app] });
  } else {
    // Nested code must be signed before the enclosing bundle, innermost first.
    for (const framework of frameworks) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: [
          '--force', '--options', 'runtime', '--timestamp',
          '--sign', options.sign,
          path.join(layout.frameworks, framework),
        ],
      });
    }
    for (const bundle of resourceBundles) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: [
          '--force', '--options', 'runtime', '--timestamp',
          '--sign', options.sign,
          path.join(layout.resources, bundle),
        ],
      });
    }
    steps.push({
      type: 'exec',
      cmd: 'codesign',
      args: [
        '--force', '--options', 'runtime', '--timestamp',
        '--entitlements', options.entitlements,
        '--sign', options.sign,
        layout.app,
      ],
    });
  }

  steps.push({
    type: 'exec',
    cmd: 'codesign',
    args: ['--verify', '--deep', '--strict', '--verbose=2', layout.app],
  });
  steps.push({ type: 'exec', cmd: 'lipo', args: ['-archs', layout.executable], capture: true });

  return steps;
}

export function describeStep(step) {
  switch (step.type) {
    case 'exec': {
      const quoted = step.args.map((a) => (/[\s"]/.test(a) ? JSON.stringify(a) : a));
      return [step.cmd, ...quoted].join(' ');
    }
    case 'rm': return `rm -rf ${step.path}`;
    case 'mkdir': return `mkdir -p ${step.path}`;
    case 'copy': return `cp -R ${step.from} ${step.to}`;
    case 'chmod': return `chmod 755 ${step.path}`;
    default: throw new Error(`Unknown step type: ${step.type}`);
  }
}
```

Note: `ROOT` is imported now and used by `main()` in Task 4; leave the import in place.

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/build-app.test.mjs`
Expected: PASS — `# pass 19`, `# fail 0`.

- [ ] **Step 5: Add the `build` script to `package.json`**

In the `scripts` object add:

```json
"build": "node scripts/build-app.mjs"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/build-app.mjs scripts/__tests__/build-app.test.mjs package.json
git commit -m "feat(scripts): plan the macOS app build as an inspectable step list"
```

---

### Task 4: `build-app.mjs` — execution, resource-bundle discovery, real build

**Files:**
- Modify: `scripts/build-app.mjs`
- Modify: `scripts/__tests__/build-app.test.mjs`
- Modify: `.gitignore` (ensure `dist/` is ignored)

**Interfaces:**
- Consumes: everything from Task 3 plus `run`, `log`, `realFsOps`.
- Produces:
  - `executePlan(steps, { run, fsOps, log, dryRun }) -> Promise<{ outputs: string[] }>` — `outputs` collects the stdout of `capture: true` exec steps in order.
  - `resolveContext(options, { run, fsOps, io }) -> Promise<{ version, buildNumber, binPaths, resourceBundles, frameworks }>` — reads `MARKETING_VERSION` from `macos/project.yml`, resolves each arch's bin path (predicted in dry-run, `swift build --show-bin-path` otherwise), and lists the emitted `*.bundle` and `*.framework` directories.
  - `main(argv, deps = {}) -> Promise<number>` — exit code, `0` on success.

- [ ] **Step 1: Write the failing tests for execution and `main`**

Append to `scripts/__tests__/build-app.test.mjs`:

```js
import { executePlan, resolveContext, main } from '../build-app.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeIO, makeFakeLog } from './helpers/fake-run.mjs';
import { PROJECT_YML } from '../lib/paths.mjs';

const PROJECT_YML_TEXT = `name: Macomprendo
targets:
  Macomprendo:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        PRODUCT_BUNDLE_IDENTIFIER: com.dzamataev.macomprendo
`;

test('executePlan performs each step through the injected boundaries', async () => {
  const run = makeFakeRun([{}, { stdout: 'x86_64 arm64' }]);
  const fsOps = makeFakeFsOps();
  const result = await executePlan([
    { type: 'rm', path: '/out/app' },
    { type: 'mkdir', path: '/out/app/Contents' },
    { type: 'copy', from: '/a', to: '/b' },
    { type: 'chmod', path: '/b' },
    { type: 'exec', cmd: 'codesign', args: ['--force', '/out/app'] },
    { type: 'exec', cmd: 'lipo', args: ['-archs', '/b'], capture: true },
  ], { run, fsOps, log: makeFakeLog(), dryRun: false });

  assert.deepEqual(fsOps.events, [
    ['rmrf', '/out/app'],
    ['mkdirp', '/out/app/Contents'],
    ['copyPath', '/a', '/b'],
    ['chmodExec', '/b'],
  ]);
  assert.deepEqual(run.lines(), ['codesign --force /out/app', 'lipo -archs /b']);
  assert.deepEqual(result.outputs, ['x86_64 arm64']);
});

test('executePlan in dry-run mode touches nothing and logs every step', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  const log = makeFakeLog();
  await executePlan([
    { type: 'rm', path: '/out/app' },
    { type: 'exec', cmd: 'codesign', args: ['--force', '/out/app'] },
  ], { run, fsOps, log, dryRun: true });

  assert.deepEqual(fsOps.events, []);
  assert.deepEqual(run.calls, []);
  assert.deepEqual(log.lines, ['info: rm -rf /out/app', 'info: codesign --force /out/app']);
});

test('resolveContext predicts bin paths and skips swift in dry-run mode', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  fsOps.bundles = ['Macomprendo_Macomprendo.bundle'];
  fsOps.frameworks = ['whisper.framework'];
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64,x86_64', '--dry-run']);

  const context = await resolveContext(options, { run, fsOps, io });

  assert.equal(context.version, '1.2.3');
  assert.equal(context.buildNumber, '1.2.3');
  assert.deepEqual(run.calls, []);
  assert.ok(context.binPaths.arm64.endsWith('macos/.build/arm64-apple-macosx14.0/release'));
  assert.deepEqual(context.resourceBundles, ['Macomprendo_Macomprendo.bundle']);
  assert.deepEqual(context.frameworks, ['whisper.framework']);
});

test('resolveContext asks SwiftPM for the real bin path outside dry-run mode', async () => {
  const run = makeFakeRun([{ stdout: '/repo/macos/.build/arm64-apple-macosx14.0/release\n' }]);
  const fsOps = makeFakeFsOps();
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64']);

  const context = await resolveContext(options, { run, fsOps, io });

  assert.equal(context.binPaths.arm64, '/repo/macos/.build/arm64-apple-macosx14.0/release');
  assert.ok(run.lines()[0].includes('--show-bin-path'));
});

test('resolveContext honours explicit --version and --build-number', async () => {
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const context = await resolveContext(
    parseBuildArgs(['--arch', 'arm64', '--dry-run', '--version', '9.9.9', '--build-number', '42']),
    { run: makeFakeRun(), fsOps: makeFakeFsOps(), io },
  );
  assert.equal(context.version, '9.9.9');
  assert.equal(context.buildNumber, '42');
});

test('main --dry-run prints the plan and exits zero without running anything', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  const log = makeFakeLog();
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });

  const code = await main(['--arch', 'arm64,x86_64', '--dry-run'], { run, fsOps, log, io });

  assert.equal(code, 0);
  assert.deepEqual(run.calls, []);
  assert.deepEqual(
    fsOps.events.filter((e) => e[0] !== 'listBundles' && e[0] !== 'listFrameworks'), []);
  assert.ok(log.lines.some((l) => l.includes('--triple arm64-apple-macosx14.0')));
  assert.ok(log.lines.some((l) => l.includes('--triple x86_64-apple-macosx14.0')));
  assert.ok(log.lines.some((l) => l.includes('lipo -create')));
});

test('main reports a bad argument as exit code 2 without spawning anything', async () => {
  const run = makeFakeRun();
  const log = makeFakeLog();
  const code = await main(['--arch', 'ppc'], {
    run, fsOps: makeFakeFsOps(), log, io: makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT }),
  });
  assert.equal(code, 2);
  assert.deepEqual(run.calls, []);
  assert.ok(log.lines.some((l) => l.startsWith('error: Unsupported architecture "ppc"')));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/build-app.test.mjs`
Expected: FAIL — `The requested module '../build-app.mjs' does not provide an export named 'executePlan'`.

- [ ] **Step 3: Append the executing half to `scripts/build-app.mjs`**

Add these imports at the top of the file (merge with the existing import block):

```js
import { fileURLToPath, pathToFileURL } from 'node:url';

import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';
```

Append at the end of the file:

```js
export async function executePlan(steps, { run, fsOps, log, dryRun }) {
  const outputs = [];
  for (const step of steps) {
    const description = describeStep(step);
    if (dryRun) {
      log.info(description);
      continue;
    }
    log.step(description);
    switch (step.type) {
      case 'rm': await fsOps.rmrf(step.path); break;
      case 'mkdir': await fsOps.mkdirp(step.path); break;
      case 'copy': await fsOps.copyPath(step.from, step.to); break;
      case 'chmod': await fsOps.chmodExec(step.path); break;
      case 'exec': {
        const result = await run(step.cmd, step.args, { cwd: ROOT, capture: step.capture === true });
        if (step.capture === true) outputs.push((result.stdout ?? '').trim());
        break;
      }
      default: throw new Error(`Unknown step type: ${step.type}`);
    }
  }
  return { outputs };
}

export async function resolveContext(options, { run, fsOps, io }) {
  const version = options.version ?? readVersion(await io.readFile(PROJECT_YML));
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Could not read a valid X.Y.Z MARKETING_VERSION (got "${version}").`);
  }
  const buildNumber = options.buildNumber ?? version;

  const binPaths = {};
  for (const arch of options.archs) {
    const triple = tripleFor(arch, options.deploymentTarget);
    if (options.dryRun) {
      binPaths[arch] = predictBinPath(ROOT, triple, options.configuration);
    } else {
      const shown = await run('swift', [
        'build', '--package-path', MACOS_DIR,
        '-c', options.configuration, '--triple', triple, '--show-bin-path',
      ], { cwd: ROOT, capture: true });
      binPaths[arch] = shown.stdout.trim();
    }
  }

  const primaryBin = binPaths[options.archs[0]];
  const resourceBundles = await fsOps.listBundles(primaryBin);
  const frameworks = await fsOps.listFrameworks(primaryBin);
  return { version, buildNumber, binPaths, resourceBundles, frameworks };
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps, io = realIO,
  } = deps;

  let options;
  try {
    options = parseBuildArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run build -- [options]',
      '',
      '  --arch <list>            arm64, x86_64, or "arm64,x86_64" (default: host arch)',
      '  --sign <identity>        codesign identity; "-" for ad-hoc (default: -)',
      '  --configuration <name>   release | debug (default: release)',
      '  --deployment-target <v>  macOS deployment target (default: 14.0)',
      '  --entitlements <path>    entitlements plist for hardened-runtime signing',
      '  --version <X.Y.Z>        override MARKETING_VERSION from macos/project.yml',
      '  --build-number <n>       CFBundleVersion (default: the version)',
      '  --dist <dir>             output directory (default: dist/)',
      '  --dry-run                print the plan without building',
    ].join('\n'));
    return 0;
  }

  try {
    const context = await resolveContext(options, { run, fsOps, io });
    const steps = planBuild(options, context);
    if (context.resourceBundles.length === 0) {
      log.warn('No SwiftPM resource bundle found next to the executable. The app target '
        + 'declares resources (vendored Phosphor SVGs), so this usually means the build '
        + 'did not run or the resources were dropped from macos/Package.swift.');
    }
    const { outputs } = await executePlan(steps, { run, fsOps, log, dryRun: options.dryRun });
    if (options.dryRun) {
      log.info(`Dry run complete: ${steps.length} steps planned for ${bundleLayout(options.dist).app}`);
      return 0;
    }
    log.info(`Built ${bundleLayout(options.dist).app}`);
    log.info(`Version: ${context.version} (${context.buildNumber})`);
    log.info(`Bundle identifier: ${BUNDLE_ID}`);
    log.info(`Architectures: ${outputs.at(-1) ?? 'unknown'}`);
    log.info(options.sign === '-' ? 'Signed ad hoc for local use.' : `Signed with ${options.sign}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

Also add `PROJECT_YML` to the `./lib/paths.mjs` import list at the top of the file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test scripts/__tests__/build-app.test.mjs`
Expected: PASS — `# pass 26`, `# fail 0`.

- [ ] **Step 5: Verify `dist/` is git-ignored**

Run: `git check-ignore -v dist/Macomprendo.app`
Expected: a line naming `.gitignore` and the `dist/` rule. If the command exits 1 with no output, append `dist/` to `.gitignore` and re-run.

- [ ] **Step 6: Print the real plan**

Run: `npm run build -- --arch arm64,x86_64 --dry-run`
Expected: a numbered list of steps starting with two `swift build ... --triple ...` lines and ending with `codesign --verify --deep --strict --verbose=2 .../dist/Macomprendo.app` and `lipo -archs ...`; exit code 0.

- [ ] **Step 7: MANUAL VERIFICATION — discover what SwiftPM emits next to the executable**

whisper.cpp is **not** built from source here. Plan 1 consumes it as a prebuilt xcframework
through the local package `macos/Packages/WhisperBinary` (official
`whisper-v1.9.2-xcframework.zip`), so there are no ggml Metal *resource bundles* to copy. What
`swift build` does emit is our own target's resource bundle and, if the xcframework slices are
dynamic, one or more `.framework` directories. Find out exactly which, empirically:

```bash
swift build --package-path macos -c release --triple arm64-apple-macosx14.0
BIN=$(swift build --package-path macos -c release --triple arm64-apple-macosx14.0 --show-bin-path)
echo "$BIN"
ls -d "$BIN"/*.bundle 2>/dev/null || echo "(no .bundle)"
ls -d "$BIN"/*.framework 2>/dev/null || echo "(no .framework)"
ls "$BIN"/*.bundle/Contents/Resources 2>/dev/null | head -20
```

Expected:

- **At least one `.bundle`** — `Macomprendo_Macomprendo.bundle`, holding the vendored Phosphor
  SVG icons (SwiftPM names it `<PackageName>_<TargetName>.bundle`). An empty `.bundle` list is a
  failure: stop and check that `macos/Package.swift` still declares the icon resources.
- **`.framework` directories: possibly none.** Determine whether the whisper slices are static
  or dynamic — that decides whether anything needs embedding:

  ```bash
  otool -L "$BIN/Macomprendo" | grep -i whisper || echo "whisper is statically linked"
  ```

  If `otool -L` shows a `@rpath/whisper.framework/...` entry, the slice is dynamic and **must**
  be embedded — confirm the `.framework` appears in the `ls` above. If it prints
  "whisper is statically linked", there is nothing to embed and `planBuild` correctly emits no
  `Contents/Frameworks` steps.

**Write down both lists and the static/dynamic answer.** They are needed in Task 12
(DISTRIBUTING.md). Re-run this step after any whisper xcframework version bump.

- [ ] **Step 8: MANUAL VERIFICATION — build and launch the real ad-hoc signed app**

Run:

```bash
npm run build -- --arch arm64
ls dist/Macomprendo.app/Contents/Resources
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Macomprendo.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Macomprendo.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app
ls dist/Macomprendo.app/Contents/Frameworks 2>/dev/null || echo "(no embedded frameworks)"
open dist/Macomprendo.app
```

Expected:
- `Contents/Resources` lists `AppIcon.icns`, `LICENSE`, and every `.bundle` discovered in Step 7.
- `Contents/Frameworks` exists **only if** Step 7 found dynamic `.framework` slices, and then
  contains exactly those.
- The bundle identifier prints `com.dzamataev.macomprendo` and the version matches `macos/project.yml`.
- `codesign` prints `valid on disk` and `satisfies its Designated Requirement`.
- The menubar icon appears (this proves `Macomprendo_Macomprendo.bundle` with the Phosphor SVGs
  was found), and pressing the dictation hotkey once produces a transcript (this proves the
  whisper xcframework loaded). If either fails, watch
  `log stream --predicate 'subsystem == "com.dzamataev.macomprendo"'` in another terminal.

Then quit the app.

- [ ] **Step 9: Commit**

```bash
git add scripts/build-app.mjs scripts/__tests__/build-app.test.mjs .gitignore
git commit -m "feat(scripts): execute the app build plan with injected process and fs boundaries"
```

---

### Task 5: `configure-notarization.mjs`

**Files:**
- Create: `scripts/configure-notarization.mjs`
- Test: `scripts/__tests__/configure-notarization.test.mjs`
- Modify: `package.json` (add the `configure-notary` script)

**Background the implementer needs:** `xcrun notarytool store-credentials <profile>
--apple-id <email> --team-id <TEAMID>` saves an app-specific password into the login
Keychain under `<profile>`, so later `notarytool submit --keychain-profile <profile>` runs
need no secrets. `notarytool` prompts for the password on stdin when `--password` is
omitted, and it accepts a piped line. **Never pass the password as a CLI argument** — argv is
visible to every process on the machine via `ps`. The Team ID is exactly ten uppercase
alphanumeric characters; Macomprendo's is `68QJJA7HK9`. An app-specific password is created
at appleid.apple.com → Sign-In and Security → App-Specific Passwords; it is *not* the Apple
Account password.

**Interfaces:**
- Consumes: `scripts/lib/paths.mjs` (`NOTARY_PROFILE`, `TEAM_ID`), `run`, `log`.
- Produces:
  - `validateTeamID(id) -> string` — returns the id, throws for anything not `^[A-Z0-9]{10}$`.
  - `promptLine(query, io) -> Promise<string>` — echoing prompt.
  - `promptSecret(query, io) -> Promise<string>` — muted prompt; `io = { input, output }`.
  - `planStoreCredentials({ profile, appleID, teamID }) -> { cmd, args }`.
  - `main(argv, deps) -> Promise<number>`.

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/configure-notarization.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';

import {
  validateTeamID, promptLine, promptSecret, planStoreCredentials, main,
} from '../configure-notarization.mjs';
import { makeFakeRun, makeFakeLog } from './helpers/fake-run.mjs';

function fakeTTY() {
  const input = new PassThrough();
  const output = new PassThrough();
  output.isTTY = true;
  const seen = [];
  output.on('data', (chunk) => seen.push(chunk.toString()));
  return { input, output, seen, text: () => seen.join('') };
}

test('validateTeamID accepts a ten-character uppercase id', () => {
  assert.equal(validateTeamID('68QJJA7HK9'), '68QJJA7HK9');
  for (const bad of ['68qjja7hk9', '68QJJA7HK', '68QJJA7HK99', '', 'ABCDEFGHI-']) {
    assert.throws(() => validateTeamID(bad), /ten-character Apple Developer Team ID/, bad);
  }
});

test('promptLine reads one echoed line', async () => {
  const io = fakeTTY();
  const answer = promptLine('Apple Account email: ', io);
  io.input.write('dev@example.com\n');
  assert.equal(await answer, 'dev@example.com');
  assert.ok(io.text().includes('Apple Account email: '));
});

test('promptSecret never echoes the typed characters', async () => {
  const io = fakeTTY();
  const answer = promptSecret('App-specific password: ', io);
  io.input.write('abcd-efgh-ijkl-mnop\n');
  assert.equal(await answer, 'abcd-efgh-ijkl-mnop');
  assert.ok(io.text().includes('App-specific password: '));
  assert.equal(io.text().includes('abcd-efgh'), false);
});

test('planStoreCredentials keeps the password out of argv', () => {
  const planned = planStoreCredentials({
    profile: 'macomprendo-notary', appleID: 'dev@example.com', teamID: '68QJJA7HK9',
  });
  assert.equal(planned.cmd, 'xcrun');
  assert.deepEqual(planned.args, [
    'notarytool', 'store-credentials', 'macomprendo-notary',
    '--apple-id', 'dev@example.com',
    '--team-id', '68QJJA7HK9',
  ]);
  assert.equal(planned.args.some((a) => /password/i.test(a)), false);
});

test('main uses the environment, defaults the team, and pipes the password to stdin', async () => {
  const io = fakeTTY();
  const run = makeFakeRun([{}, { stdout: '  1) AAAA "Developer ID Application: Denis Zamataev (68QJJA7HK9)"\n' }]);
  const log = makeFakeLog();

  const done = main([], {
    run, log, io,
    env: { NOTARY_APPLE_ID: 'dev@example.com' },
  });
  io.input.write('abcd-efgh-ijkl-mnop\n');
  const code = await done;

  assert.equal(code, 0);
  const call = run.calls[0];
  assert.deepEqual(call.args.slice(0, 3), ['notarytool', 'store-credentials', 'macomprendo-notary']);
  assert.ok(call.args.includes('68QJJA7HK9'));
  assert.equal(call.options.input, 'abcd-efgh-ijkl-mnop\n');
  assert.ok(log.lines.some((l) => l.includes('macomprendo-notary')));
});

test('main warns when no Developer ID Application certificate is installed', async () => {
  const io = fakeTTY();
  const run = makeFakeRun([{}, { stdout: '  1) BBBB "Apple Development: dev@example.com (ABCDEFGHIJ)"\n' }]);
  const log = makeFakeLog();

  const done = main([], { run, log, io, env: { NOTARY_APPLE_ID: 'dev@example.com', APPLE_TEAM_ID: '68QJJA7HK9' } });
  io.input.write('pw\n');
  await done;

  assert.ok(log.lines.some((l) => l.startsWith('warn: ') && l.includes('Developer ID Application')));
});

test('main rejects a malformed APPLE_TEAM_ID before prompting for anything', async () => {
  const io = fakeTTY();
  const run = makeFakeRun();
  const log = makeFakeLog();

  const code = await main([], { run, log, io, env: { NOTARY_APPLE_ID: 'a@b.c', APPLE_TEAM_ID: 'nope' } });

  assert.equal(code, 1);
  assert.deepEqual(run.calls, []);
  assert.equal(io.text(), '');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/configure-notarization.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/configure-notarization.mjs'`.

- [ ] **Step 3: Implement `scripts/configure-notarization.mjs`**

```js
#!/usr/bin/env node
// One-time setup: store an Apple app-specific password in the login Keychain so that
// notarize-app.mjs can submit builds without any secret in the repository or in argv.
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

import { NOTARY_PROFILE, TEAM_ID } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';

const TEAM_ID_PATTERN = /^[A-Z0-9]{10}$/;

export function validateTeamID(id) {
  if (typeof id !== 'string' || !TEAM_ID_PATTERN.test(id)) {
    throw new Error(`"${id}" is not a ten-character Apple Developer Team ID (A-Z and 0-9).`);
  }
  return id;
}

function ask(query, { input, output }, muted) {
  return new Promise((resolve, reject) => {
    const rl = createInterface({ input, output, terminal: true });
    output.write(query);
    if (muted) rl._writeToOutput = () => {};
    rl.on('error', reject);
    rl.question('', (answer) => {
      rl.close();
      if (muted) output.write('\n');
      resolve(answer.trim());
    });
  });
}

export function promptLine(query, io) {
  return ask(query, io, false);
}

export function promptSecret(query, io) {
  return ask(query, io, true);
}

export function planStoreCredentials({ profile, appleID, teamID }) {
  return {
    cmd: 'xcrun',
    args: [
      'notarytool', 'store-credentials', profile,
      '--apple-id', appleID,
      '--team-id', teamID,
    ],
  };
}

export async function main(argv, deps = {}) {
  const {
    run = realRun,
    log = realLog,
    env = process.env,
    io = { input: process.stdin, output: process.stdout },
  } = deps;

  try {
    const profile = env.NOTARYTOOL_PROFILE ?? NOTARY_PROFILE;
    const teamID = validateTeamID(env.APPLE_TEAM_ID ?? TEAM_ID);
    const appleID = env.NOTARY_APPLE_ID ?? await promptLine('Apple Account email: ', io);
    if (appleID === '') throw new Error('An Apple Account email is required.');

    log.info(`Storing notarization credentials in the login Keychain under "${profile}".`);
    log.info('Use an app-specific password from appleid.apple.com, not your Apple Account password.');
    const password = await promptSecret('App-specific password: ', io);
    if (password === '') throw new Error('An app-specific password is required.');

    const planned = planStoreCredentials({ profile, appleID, teamID });
    await run(planned.cmd, planned.args, { input: `${password}\n` });

    log.info(`Notarization credentials are ready under profile "${profile}".`);

    const identities = await run('security', ['find-identity', '-v', '-p', 'codesigning'], {
      capture: true, check: false,
    });
    if (!(identities.stdout ?? '').includes('Developer ID Application:')) {
      log.warn('No "Developer ID Application" certificate is installed for this Mac. '
        + `Create one for team ${teamID} at developer.apple.com > Certificates, install it in `
        + 'Keychain Access with its private key, then run: npm run notarize');
    } else {
      log.info('Next: npm run notarize');
    }
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

**Note for the implementer:** `scripts/lib/run.mjs` must forward an `input` option to the
child process's stdin. If Plan 1's `run` does not yet accept `input`, add it — with `execa`
this is one line: pass `input` straight through in the options object, and leave `stdio`
alone so notarytool's own prompts stay visible.

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/configure-notarization.test.mjs`
Expected: PASS — `# pass 7`, `# fail 0`.

- [ ] **Step 5: Add the `configure-notary` script to `package.json`**

```json
"configure-notary": "node scripts/configure-notarization.mjs"
```

- [ ] **Step 6: MANUAL VERIFICATION (only when an Apple Account is available)**

Run: `NOTARY_APPLE_ID="you@example.com" npm run configure-notary`
Expected: the password prompt shows no characters as you type; the command finishes with
`Notarization credentials are ready under profile "macomprendo-notary".` Confirm the secret
is stored and readable back by notarytool:

```bash
xcrun notarytool history --keychain-profile macomprendo-notary --output-format json | head -5
```

Expected: JSON with a `history` array (possibly empty), not an authentication error.
If no Apple Account is available yet, skip this step and record it in the release checklist.

- [ ] **Step 7: Commit**

```bash
git add scripts/configure-notarization.mjs scripts/__tests__/configure-notarization.test.mjs \
        package.json scripts/lib/run.mjs
git commit -m "feat(scripts): store notarization credentials without exposing the password"
```

---

### Task 6: `notarize-app.mjs`

**Files:**
- Create: `scripts/notarize-app.mjs`
- Test: `scripts/__tests__/notarize-app.test.mjs`
- Modify: `package.json` (add the `notarize` script)

**Background the implementer needs:**
- `security find-identity -v -p codesigning` prints lines like
  `  1) A1B2C3D4… "Developer ID Application: Denis Zamataev (68QJJA7HK9)"` followed by
  `     2 valid identities found`. Only a `Developer ID Application:` identity can produce a
  notarizable build; an `Apple Development:` identity cannot.
- `ditto -c -k --sequesterRsrc --keepParent <app> <zip>` is the only archiver Apple supports
  for notarization submissions (it preserves the bundle's extended attributes).
- `xcrun notarytool submit <zip> --keychain-profile <p> --wait --timeout 60m --output-format json`
  prints a single JSON object: `{"id":"…","status":"Accepted","message":"…"}`. Statuses other
  than `Accepted` are `Invalid` or `Rejected`.
- `xcrun notarytool log <submission-id> --keychain-profile <p> <file>` fetches the failure
  report; always do this when the status is not `Accepted`.
- Stapling (`xcrun stapler staple`) must happen **before** the distributable ZIP is created,
  so downloaders get an offline ticket.

**Interfaces:**
- Consumes: `build-app.mjs` (`main` re-invoked through `run` as `node scripts/build-app.mjs`),
  `scripts/lib/paths.mjs`, `scripts/lib/version.mjs` (`readVersion`), `scripts/lib/fs.mjs` (`sha256`, `realIO`, `realFsOps`), `run`, `log`.
- Produces:
  - `parseNotarizeArgs(argv) -> { sign: string|null, profile: string, timeout: string, dist: string, dryRun: boolean, help: boolean }`
  - `parseIdentity(securityOutput) -> string | null`
  - `parseSubmission(jsonText) -> { id: string|null, status: string|null, message: string }`
  - `planNotarize({ identity, profile, timeout, dist, version }) -> Step[]` (same `Step` shape as `build-app.mjs`, plus `{ type: 'sha256', path, out }`)
  - `main(argv, deps) -> Promise<number>`

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/notarize-app.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

import {
  parseNotarizeArgs, parseIdentity, parseSubmission, planNotarize, main,
} from '../notarize-app.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeIO, makeFakeLog } from './helpers/fake-run.mjs';
import { PROJECT_YML } from '../lib/paths.mjs';

const SECURITY_OUTPUT = `  1) 1A2B3C "Apple Development: dev@example.com (ABCDEFGHIJ)"
  2) 4D5E6F "Developer ID Application: Denis Zamataev (68QJJA7HK9)"
     2 valid identities found
`;

const PROJECT_YML_TEXT = `targets:
  Macomprendo:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
`;

test('parseIdentity picks the Developer ID Application identity', () => {
  assert.equal(parseIdentity(SECURITY_OUTPUT), 'Developer ID Application: Denis Zamataev (68QJJA7HK9)');
});

test('parseIdentity returns null when only a development certificate exists', () => {
  assert.equal(parseIdentity('  1) 1A2B "Apple Development: dev@example.com (ABCDEFGHIJ)"\n'), null);
  assert.equal(parseIdentity('     0 valid identities found\n'), null);
  assert.equal(parseIdentity(''), null);
});

test('parseSubmission reads notarytool JSON', () => {
  assert.deepEqual(
    parseSubmission('{"id":"abc-123","status":"Accepted","message":"Successfully received submission info"}'),
    { id: 'abc-123', status: 'Accepted', message: 'Successfully received submission info' },
  );
  assert.deepEqual(
    parseSubmission('{"id":"def-456","status":"Invalid","message":"Processing complete"}'),
    { id: 'def-456', status: 'Invalid', message: 'Processing complete' },
  );
});

test('parseSubmission survives non-JSON output', () => {
  assert.deepEqual(parseSubmission('Error: could not reach Apple'),
    { id: null, status: null, message: 'Error: could not reach Apple' });
});

test('parseNotarizeArgs defaults to the shared profile and a one-hour timeout', () => {
  const options = parseNotarizeArgs([]);
  assert.equal(options.sign, null);
  assert.equal(options.profile, 'macomprendo-notary');
  assert.equal(options.timeout, '60m');
  assert.equal(options.dryRun, false);
});

const PLAN = () => planNotarize({
  identity: 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
  profile: 'macomprendo-notary',
  timeout: '60m',
  dist: '/out',
  version: '1.2.3',
});

test('planNotarize verifies the notary profile before doing any work', () => {
  const first = PLAN()[0];
  assert.equal(first.cmd, 'xcrun');
  assert.deepEqual(first.args,
    ['notarytool', 'history', '--keychain-profile', 'macomprendo-notary', '--output-format', 'json']);
});

test('planNotarize rebuilds a universal signed app through build-app.mjs', () => {
  const build = PLAN().find((s) => s.type === 'exec' && s.cmd === 'node');
  assert.deepEqual(build.args, [
    'scripts/build-app.mjs',
    '--arch', 'arm64,x86_64',
    '--configuration', 'release',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '--version', '1.2.3',
    '--dist', '/out',
  ]);
});

test('planNotarize zips with ditto and submits with --wait', () => {
  const steps = PLAN();
  const ditto = steps.find((s) => s.cmd === 'ditto');
  assert.deepEqual(ditto.args, [
    '-c', '-k', '--sequesterRsrc', '--keepParent',
    '/out/Macomprendo.app', '/out/Macomprendo-1.2.3-notarization.zip',
  ]);
  const submit = steps.find((s) => s.cmd === 'xcrun' && s.args[1] === 'submit');
  assert.deepEqual(submit.args, [
    'notarytool', 'submit', '/out/Macomprendo-1.2.3-notarization.zip',
    '--keychain-profile', 'macomprendo-notary',
    '--wait', '--timeout', '60m', '--output-format', 'json',
  ]);
  assert.equal(submit.capture, true);
});

test('planNotarize staples, validates, assesses, then produces the final zip and checksum', () => {
  const tail = PLAN().slice(PLAN().findIndex((s) => s.args?.[1] === 'submit') + 1);
  const lines = tail.map((s) => (s.type === 'exec' ? [s.cmd, ...s.args].join(' ') : `${s.type} ${s.path ?? ''}`));
  assert.deepEqual(lines, [
    'xcrun stapler staple /out/Macomprendo.app',
    'xcrun stapler validate /out/Macomprendo.app',
    'codesign --verify --deep --strict --verbose=2 /out/Macomprendo.app',
    'spctl --assess --type execute --verbose=4 /out/Macomprendo.app',
    'ditto -c -k --sequesterRsrc --keepParent /out/Macomprendo.app /out/Macomprendo-1.2.3-macos.zip',
    'rm /out/Macomprendo-1.2.3-notarization.zip',
    'sha256 /out/Macomprendo-1.2.3-macos.zip',
  ]);
});

function notarizeDeps({ submitJSON, identities = SECURITY_OUTPUT }) {
  const run = makeFakeRun();
  const scripted = new Map([
    ['security find-identity -v -p codesigning', { stdout: identities }],
    ['xcrun notarytool submit', { stdout: submitJSON }],
  ]);
  const calls = [];
  const wrapped = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    for (const [prefix, result] of scripted) {
      if (line.startsWith(prefix)) return { stdout: result.stdout, stderr: '', code: 0 };
    }
    return { stdout: '', stderr: '', code: 0 };
  };
  wrapped.calls = calls;
  wrapped.lines = () => calls.map((c) => c.line);
  return {
    run: wrapped,
    fsOps: makeFakeFsOps(),
    io: makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT }),
    log: makeFakeLog(),
    sha256: async () => 'a'.repeat(64),
  };
}

test('main completes the accepted path and writes the checksum file', async () => {
  const deps = notarizeDeps({ submitJSON: '{"id":"abc-123","status":"Accepted","message":"ok"}' });
  const code = await main(['--dist', '/out'], deps);

  assert.equal(code, 0);
  assert.ok(deps.run.lines().some((l) => l.startsWith('xcrun stapler staple')));
  assert.equal(await deps.io.readFile('/out/Macomprendo-1.2.3-macos.zip.sha256'),
    `${'a'.repeat(64)}  Macomprendo-1.2.3-macos.zip\n`);
  assert.ok(deps.log.lines.some((l) => l.includes('Macomprendo-1.2.3-macos.zip')));
});

test('main fetches the notary log and stops when the submission is rejected', async () => {
  const deps = notarizeDeps({ submitJSON: '{"id":"def-456","status":"Invalid","message":"Processing complete"}' });
  const code = await main(['--dist', '/out'], deps);

  assert.equal(code, 1);
  assert.ok(deps.run.lines().some((l) =>
    l === 'xcrun notarytool log def-456 --keychain-profile macomprendo-notary /out/notary-log-def-456.json'));
  assert.equal(deps.run.lines().some((l) => l.startsWith('xcrun stapler')), false);
  assert.ok(deps.log.lines.some((l) => l.startsWith('error: ') && l.includes('Invalid')));
});

test('main explains how to obtain a Developer ID certificate when none is installed', async () => {
  const deps = notarizeDeps({
    submitJSON: '{}',
    identities: '  1) 1A2B "Apple Development: dev@example.com (ABCDEFGHIJ)"\n',
  });
  const code = await main(['--dist', '/out'], deps);

  assert.equal(code, 1);
  const message = deps.log.lines.join('\n');
  assert.ok(message.includes('Developer ID Application'));
  assert.ok(message.includes('68QJJA7HK9'));
  assert.ok(message.includes('developer.apple.com'));
  assert.equal(deps.run.lines().some((l) => l.startsWith('xcrun notarytool submit')), false);
});

test('main --dry-run prints the plan and spawns nothing beyond identity discovery', async () => {
  const deps = notarizeDeps({ submitJSON: '{}' });
  const code = await main(['--dist', '/out', '--dry-run'], deps);

  assert.equal(code, 0);
  assert.deepEqual(deps.run.lines(), ['security find-identity -v -p codesigning']);
  assert.ok(deps.log.lines.some((l) => l.includes('notarytool submit')));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/notarize-app.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/notarize-app.mjs'`.

- [ ] **Step 3: Implement `scripts/notarize-app.mjs`**

```js
#!/usr/bin/env node
// Build a universal Developer ID release, notarize it with Apple, staple the ticket,
// and emit dist/Macomprendo-<version>-macos.zip plus its SHA-256 sidecar.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import { ROOT, DIST_DIR, APP_NAME, NOTARY_PROFILE, TEAM_ID, PROJECT_YML } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO, sha256 as realSha256 } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';
import { describeStep } from './build-app.mjs';

const IDENTITY_PATTERN = /"(Developer ID Application:[^"]+)"/;

export function parseNotarizeArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      sign: { type: 'string' },
      profile: { type: 'string' },
      timeout: { type: 'string' },
      dist: { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  return {
    sign: values.sign ?? null,
    profile: values.profile ?? process.env.NOTARYTOOL_PROFILE ?? NOTARY_PROFILE,
    timeout: values.timeout ?? '60m',
    dist: values.dist ?? DIST_DIR,
    dryRun: values['dry-run'],
    help: values.help,
  };
}

export function parseIdentity(securityOutput) {
  for (const line of String(securityOutput).split('\n')) {
    const match = IDENTITY_PATTERN.exec(line);
    if (match !== null) return match[1];
  }
  return null;
}

export function parseSubmission(jsonText) {
  try {
    const parsed = JSON.parse(jsonText);
    return {
      id: parsed.id ?? null,
      status: parsed.status ?? null,
      message: parsed.message ?? '',
    };
  } catch {
    return { id: null, status: null, message: String(jsonText).trim() };
  }
}

export function planNotarize({ identity, profile, timeout, dist, version }) {
  const app = path.join(dist, APP_NAME);
  const submission = path.join(dist, `Macomprendo-${version}-notarization.zip`);
  const final = path.join(dist, `Macomprendo-${version}-macos.zip`);
  return [
    {
      type: 'exec', cmd: 'xcrun',
      args: ['notarytool', 'history', '--keychain-profile', profile, '--output-format', 'json'],
    },
    {
      type: 'exec', cmd: 'node',
      args: [
        'scripts/build-app.mjs',
        '--arch', 'arm64,x86_64',
        '--configuration', 'release',
        '--sign', identity,
        '--version', version,
        '--dist', dist,
      ],
    },
    { type: 'rm', path: submission },
    { type: 'rm', path: final },
    {
      type: 'exec', cmd: 'ditto',
      args: ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submission],
    },
    {
      type: 'exec', cmd: 'xcrun', capture: true,
      args: [
        'notarytool', 'submit', submission,
        '--keychain-profile', profile,
        '--wait', '--timeout', timeout,
        '--output-format', 'json',
      ],
    },
    { type: 'exec', cmd: 'xcrun', args: ['stapler', 'staple', app] },
    { type: 'exec', cmd: 'xcrun', args: ['stapler', 'validate', app] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', '--verbose=2', app] },
    { type: 'exec', cmd: 'spctl', args: ['--assess', '--type', 'execute', '--verbose=4', app] },
    {
      type: 'exec', cmd: 'ditto',
      args: ['-c', '-k', '--sequesterRsrc', '--keepParent', app, final],
    },
    { type: 'rm', path: submission },
    { type: 'sha256', path: final, out: `${final}.sha256` },
  ];
}

const MISSING_IDENTITY_HELP = [
  'No "Developer ID Application" certificate with a private key is installed.',
  `Create one for team ${TEAM_ID}:`,
  '  1. Sign in at developer.apple.com > Certificates, Identifiers & Profiles > Certificates.',
  '  2. Add a certificate of type "Developer ID Application" and upload a CSR from Keychain Access',
  '     (Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority).',
  '  3. Download the .cer and double-click it so it lands in the login keychain next to its private key.',
  '  4. Re-check with: security find-identity -v -p codesigning',
  'An "Apple Development" certificate is enough for local builds but cannot be notarized.',
  'Meanwhile, build an ad-hoc signed app with: npm run build',
].join('\n');

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps, io = realIO, sha256 = realSha256,
  } = deps;

  let options;
  try {
    options = parseNotarizeArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run notarize -- [options]',
      '',
      '  --sign <identity>  Developer ID identity (default: the first one found)',
      '  --profile <name>   notarytool keychain profile (default: macomprendo-notary)',
      '  --timeout <dur>    notarytool --wait timeout (default: 60m)',
      '  --dist <dir>       output directory (default: dist/)',
      '  --dry-run          print the plan without contacting Apple',
    ].join('\n'));
    return 0;
  }

  try {
    let identity = options.sign;
    if (identity === null) {
      const found = await run('security', ['find-identity', '-v', '-p', 'codesigning'], {
        capture: true, check: false, cwd: ROOT,
      });
      identity = parseIdentity(found.stdout ?? '');
    }
    if (identity === null) {
      log.error(MISSING_IDENTITY_HELP);
      return 1;
    }
    log.info(`Signing identity: ${identity}`);

    const version = readVersion(await io.readFile(PROJECT_YML));
    const steps = planNotarize({
      identity, profile: options.profile, timeout: options.timeout,
      dist: options.dist, version,
    });

    if (options.dryRun) {
      for (const step of steps) {
        log.info(step.type === 'sha256' ? `sha256 ${step.path} > ${step.out}` : describeStep(step));
      }
      log.info(`Dry run complete: ${steps.length} steps planned.`);
      return 0;
    }

    for (const step of steps) {
      if (step.type === 'rm') {
        await fsOps.rmrf(step.path);
        continue;
      }
      if (step.type === 'sha256') {
        const digest = await sha256(step.path);
        await io.writeFile(step.out, `${digest}  ${path.basename(step.path)}\n`);
        log.info(`SHA-256: ${digest}`);
        continue;
      }
      log.step(describeStep(step));
      const result = await run(step.cmd, step.args, { cwd: ROOT, capture: step.capture === true });

      if (step.capture === true && step.args[1] === 'submit') {
        const submission = parseSubmission(result.stdout ?? '');
        log.info(`Submission ${submission.id ?? 'unknown'}: ${submission.status ?? 'unknown'}`);
        if (submission.status !== 'Accepted') {
          if (submission.id !== null) {
            const logPath = path.join(options.dist, `notary-log-${submission.id}.json`);
            await run('xcrun', [
              'notarytool', 'log', submission.id, '--keychain-profile', options.profile, logPath,
            ], { cwd: ROOT, check: false });
            log.error(`Notary log written to ${logPath}`);
          }
          log.error(`Notarization was not accepted (status: ${submission.status ?? 'unknown'}). `
            + `${submission.message}`);
          return 1;
        }
      }
    }

    const final = path.join(options.dist, `Macomprendo-${version}-macos.zip`);
    log.info(`Notarized release: ${final}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/notarize-app.test.mjs`
Expected: PASS — `# pass 13`, `# fail 0`.

- [ ] **Step 5: Add the `notarize` script to `package.json`**

```json
"notarize": "node scripts/notarize-app.mjs"
```

- [ ] **Step 6: Verify the real dry run and the missing-certificate path**

Run: `npm run notarize -- --dry-run`
Expected on this machine (only an Apple Development certificate exists): exit code 1 and the
`MISSING_IDENTITY_HELP` text, including the team id `68QJJA7HK9` and the developer.apple.com steps.

Then force the plan to print with a placeholder identity:

Run: `npm run notarize -- --dry-run --sign "Developer ID Application: Denis Zamataev (68QJJA7HK9)"`
Expected: exit code 0 and a 13-line plan ending with `sha256 .../Macomprendo-0.1.0-macos.zip > ….sha256`.

- [ ] **Step 7: Commit**

```bash
git add scripts/notarize-app.mjs scripts/__tests__/notarize-app.test.mjs package.json
git commit -m "feat(scripts): notarize, staple and package the signed app"
```

---

### Task 7: `release.mjs` — version resolution, file rewrites, preflight

**Files:**
- Create: `scripts/release.mjs`
- Test: `scripts/__tests__/release.test.mjs`

**Interfaces:**
- Consumes: `scripts/lib/version.mjs` (`readVersion`, `bumpVersion`), `scripts/lib/changelog.mjs`
  (`updateChangelog`, `extractSection`), `scripts/lib/paths.mjs`, `run`, `log`.
- Produces:
  - `PROJECT_YML_VERSION` and `PBXPROJ_VERSION` regular expressions.
  - `resolveVersion(current, requested) -> string` — `patch|minor|major|X.Y.Z`, must be strictly newer.
  - `replaceProjectYmlVersion(text, from, to) -> string` — exactly one declaration.
  - `replacePbxprojVersions(text, from, to) -> string` — every declaration, all currently `from`.
  - `assertProjectYmlParses(text, version) -> void` — `yaml.parse` sanity check.
  - `preflight(version, { run, log }) -> Promise<void>` — throws with a fix-it message on any failure.

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/release.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PROJECT_YML_VERSION, PBXPROJ_VERSION,
  resolveVersion, replaceProjectYmlVersion, replacePbxprojVersions,
  assertProjectYmlParses, preflight,
} from '../release.mjs';
import { makeFakeRun, makeFakeLog } from './helpers/fake-run.mjs';

const PROJECT_YML_TEXT = `name: Macomprendo
targets:
  Macomprendo:
    type: application
    platform: macOS
    settings:
      base:
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: 1
        PRODUCT_BUNDLE_IDENTIFIER: com.dzamataev.macomprendo
        DEVELOPMENT_TEAM: 68QJJA7HK9
`;

const PBXPROJ_TEXT = [
  '\t\t\t\tMARKETING_VERSION = 0.1.0;',
  '\t\t\t\tPRODUCT_NAME = Macomprendo;',
  '\t\t\t\tMARKETING_VERSION = 0.1.0;',
  '',
].join('\n');

test('resolveVersion supports the standard bumps and explicit versions', () => {
  assert.equal(resolveVersion('1.2.3', 'patch'), '1.2.4');
  assert.equal(resolveVersion('1.2.3', 'minor'), '1.3.0');
  assert.equal(resolveVersion('1.2.3', 'major'), '2.0.0');
  assert.equal(resolveVersion('1.2.3', '1.4.0'), '1.4.0');
  assert.equal(resolveVersion('0.9.9', 'minor'), '0.10.0');
});

test('resolveVersion rejects malformed and non-increasing versions', () => {
  for (const requested of ['banana', '1.2', '1.2.3-beta', 'v1.2.4']) {
    assert.throws(() => resolveVersion('1.2.3', requested),
      /patch, minor, major, or an explicit X\.Y\.Z/, requested);
  }
  for (const requested of ['1.2.3', '1.1.9', '0.9.0']) {
    assert.throws(() => resolveVersion('1.2.3', requested), /must be newer than 1\.2\.3/, requested);
  }
});

test('PROJECT_YML_VERSION matches the XcodeGen declaration', () => {
  assert.equal(PROJECT_YML_VERSION.exec(PROJECT_YML_TEXT)[1], '0.1.0');
});

test('replaceProjectYmlVersion rewrites exactly one declaration and keeps quoting', () => {
  const updated = replaceProjectYmlVersion(PROJECT_YML_TEXT, '0.1.0', '0.2.0');
  assert.ok(updated.includes('MARKETING_VERSION: "0.2.0"'));
  assert.equal(updated.includes('0.1.0'), false);
  assert.ok(updated.includes('DEVELOPMENT_TEAM: 68QJJA7HK9'));
});

test('replaceProjectYmlVersion refuses to rewrite an unexpected current version', () => {
  assert.throws(() => replaceProjectYmlVersion(PROJECT_YML_TEXT, '9.9.9', '0.2.0'),
    /macos\/project\.yml does not declare MARKETING_VERSION 9\.9\.9/);
});

test('PBXPROJ_VERSION finds every generated declaration', () => {
  assert.equal([...PBXPROJ_TEXT.matchAll(PBXPROJ_VERSION)].length, 2);
});

test('replacePbxprojVersions rewrites all declarations', () => {
  const updated = replacePbxprojVersions(PBXPROJ_TEXT, '0.1.0', '0.2.0');
  assert.equal(updated.match(/MARKETING_VERSION = 0\.2\.0;/g).length, 2);
  assert.equal(updated.includes('0.1.0'), false);
});

test('replacePbxprojVersions refuses a mixed or missing set', () => {
  assert.throws(() => replacePbxprojVersions(PBXPROJ_TEXT, '9.9.9', '0.2.0'),
    /project\.pbxproj declares MARKETING_VERSION 0\.1\.0/);
  assert.throws(() => replacePbxprojVersions('PRODUCT_NAME = Macomprendo;', '0.1.0', '0.2.0'),
    /no MARKETING_VERSION declarations/);
});

test('assertProjectYmlParses agrees with the regular expression', () => {
  assertProjectYmlParses(PROJECT_YML_TEXT, '0.1.0');
  assert.throws(() => assertProjectYmlParses(PROJECT_YML_TEXT, '0.2.0'),
    /parsed MARKETING_VERSION 0\.1\.0 does not match 0\.2\.0/);
  assert.throws(() => assertProjectYmlParses('targets: [\n', '0.1.0'), /macos\/project\.yml is not valid YAML/);
});

function preflightRun(overrides = {}) {
  const table = {
    'git rev-parse --show-toplevel': { stdout: '/repo' },
    'git status --porcelain': { stdout: '' },
    'git branch --show-current': { stdout: 'main' },
    'gh auth status': { stdout: 'Logged in' },
    'git fetch origin main --tags': { stdout: '' },
    'git rev-parse HEAD': { stdout: 'deadbeef' },
    'git rev-parse origin/main': { stdout: 'deadbeef' },
    'git ls-remote --tags origin refs/tags/v1.2.4': { stdout: '' },
    ...overrides,
  };
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    const hit = table[line];
    if (hit === undefined) return { stdout: '', stderr: '', code: 0 };
    if (hit.throws) throw new Error(hit.throws);
    return { stdout: hit.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  return run;
}

test('preflight passes on a clean, up-to-date main branch', async () => {
  const run = preflightRun();
  await preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' });
  assert.ok(run.lines().includes('git ls-remote --tags origin refs/tags/v1.2.4'));
});

test('preflight refuses a dirty working tree', async () => {
  const run = preflightRun({ 'git status --porcelain': { stdout: ' M README.md' } });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /working tree is not clean/);
});

test('preflight refuses a branch other than main', async () => {
  const run = preflightRun({ 'git branch --show-current': { stdout: 'feature/x' } });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /Releases must run from main, not "feature\/x"/);
});

test('preflight refuses when HEAD differs from origin/main', async () => {
  const run = preflightRun({ 'git rev-parse origin/main': { stdout: 'cafebabe' } });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /must exactly match origin\/main/);
});

test('preflight refuses an existing tag', async () => {
  const run = preflightRun({
    'git ls-remote --tags origin refs/tags/v1.2.4': { stdout: 'abc123\trefs/tags/v1.2.4' },
  });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /Tag v1\.2\.4 already exists on the remote/);
});

test('preflight refuses a checkout that is not this repository', async () => {
  const run = preflightRun({ 'git rev-parse --show-toplevel': { stdout: '/somewhere/else' } });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /Run this from the \/repo checkout/);
});

test('preflight surfaces a failed gh auth check', async () => {
  const run = preflightRun({ 'gh auth status': { throws: 'gh: not logged in' } });
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /gh is not authenticated; run: gh auth login/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/release.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/release.mjs'`.

- [ ] **Step 3: Implement the pure half of `scripts/release.mjs`**

Create `scripts/release.mjs`:

```js
#!/usr/bin/env node
// Bump the version, finalize the changelog, run the full test suite, tag, push,
// and publish a GitHub release.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';

import YAML from 'yaml';

import {
  ROOT, MACOS_DIR, PROJECT_YML, PBXPROJ, XCODEPROJ, CHANGELOG_PATH, DIST_DIR, SCHEME,
} from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realIO } from './lib/fs.mjs';
import { readVersion, bumpVersion } from './lib/version.mjs';
import { updateChangelog, extractSection } from './lib/changelog.mjs';

export const PROJECT_YML_VERSION = /^[ \t]*MARKETING_VERSION:[ \t]*"?(\d+\.\d+\.\d+)"?[ \t]*$/m;
export const PBXPROJ_VERSION = /^([ \t]*)MARKETING_VERSION = (\d+\.\d+\.\d+);$/gm;

const SEMVER = /^\d+\.\d+\.\d+$/;

function parts(version) {
  return version.split('.').map((n) => Number.parseInt(n, 10));
}

function isNewer(target, current) {
  const a = parts(target);
  const b = parts(current);
  for (let i = 0; i < 3; i += 1) {
    if (a[i] > b[i]) return true;
    if (a[i] < b[i]) return false;
  }
  return false;
}

export function resolveVersion(current, requested) {
  if (!['patch', 'minor', 'major'].includes(requested) && !SEMVER.test(requested)) {
    throw new Error('Version must be patch, minor, major, or an explicit X.Y.Z version.');
  }
  const target = bumpVersion(current, requested);
  if (!isNewer(target, current)) {
    throw new Error(`Requested version ${target} must be newer than ${current}.`);
  }
  return target;
}

export function replaceProjectYmlVersion(text, from, to) {
  const match = PROJECT_YML_VERSION.exec(text);
  if (match === null || match[1] !== from) {
    throw new Error(`macos/project.yml does not declare MARKETING_VERSION ${from} `
      + `(found ${match === null ? 'none' : match[1]}).`);
  }
  return text.replace(PROJECT_YML_VERSION, (line) => line.replace(from, to));
}

export function replacePbxprojVersions(text, from, to) {
  const matches = [...text.matchAll(PBXPROJ_VERSION)];
  if (matches.length === 0) {
    throw new Error('macos/Macomprendo.xcodeproj/project.pbxproj has no MARKETING_VERSION declarations.');
  }
  const found = [...new Set(matches.map((m) => m[2]))];
  if (found.length !== 1 || found[0] !== from) {
    throw new Error(`macos/Macomprendo.xcodeproj/project.pbxproj declares MARKETING_VERSION `
      + `${found.join(', ')} but ${from} was expected. Run: npm run gen`);
  }
  return text.replace(PBXPROJ_VERSION, (_line, indent) => `${indent}MARKETING_VERSION = ${to};`);
}

export function assertProjectYmlParses(text, version) {
  let document;
  try {
    document = YAML.parse(text);
  } catch (error) {
    throw new Error(`macos/project.yml is not valid YAML: ${error.message}`);
  }
  const settings = document?.targets?.Macomprendo?.settings?.base ?? {};
  const parsed = String(settings.MARKETING_VERSION ?? '');
  if (parsed !== version) {
    throw new Error(`macos/project.yml parsed MARKETING_VERSION ${parsed || 'none'} `
      + `does not match ${version}.`);
  }
}

export async function preflight(version, { run, log, root = ROOT }) {
  const capture = async (cmd, args) => (await run(cmd, args, { cwd: root, capture: true })).stdout.trim();

  log.step('Checking the repository state');

  const toplevel = await capture('git', ['rev-parse', '--show-toplevel']);
  if (path.resolve(toplevel) !== path.resolve(root)) {
    throw new Error(`Run this from the ${root} checkout (git reports ${toplevel}).`);
  }

  const status = await capture('git', ['status', '--porcelain']);
  if (status !== '') {
    throw new Error('The working tree is not clean; commit or stash your changes first.');
  }

  const branch = await capture('git', ['branch', '--show-current']);
  if (branch !== 'main') {
    throw new Error(`Releases must run from main, not "${branch || 'detached HEAD'}".`);
  }

  try {
    await run('gh', ['auth', 'status'], { cwd: root });
  } catch {
    throw new Error('gh is not authenticated; run: gh auth login');
  }

  await run('git', ['fetch', 'origin', 'main', '--tags'], { cwd: root });

  const head = await capture('git', ['rev-parse', 'HEAD']);
  const remote = await capture('git', ['rev-parse', 'origin/main']);
  if (head !== remote) {
    throw new Error('Local main must exactly match origin/main before releasing; push or pull first.');
  }

  const tag = await capture('git', ['ls-remote', '--tags', 'origin', `refs/tags/v${version}`]);
  if (tag !== '') {
    throw new Error(`Tag v${version} already exists on the remote.`);
  }

  log.info('Preflight checks passed.');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/release.test.mjs`
Expected: PASS — `# pass 16`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.mjs scripts/__tests__/release.test.mjs
git commit -m "feat(scripts): add release version resolution, file rewrites and preflight"
```

---

### Task 8: `release.mjs` — the release flow

**Files:**
- Modify: `scripts/release.mjs`
- Modify: `scripts/__tests__/release.test.mjs`
- Modify: `package.json` (add the `release` script)

**Interfaces:**
- Consumes: everything from Task 7.
- Produces:
  - `parseReleaseArgs(argv) -> { requested: string, dryRun: boolean, yes: boolean, help: boolean }`
  - `prepareFiles({ current, version, isoDate, io }) -> Promise<string[]>` — writes `macos/project.yml`,
    `macos/Macomprendo.xcodeproj/project.pbxproj` and `CHANGELOG.md`; returns the paths written.
  - `planRelease({ version, notesPath, assets }) -> Step[]` — the verification/commit/publish commands.
  - `confirm(question, io) -> Promise<boolean>`
  - `main(argv, deps) -> Promise<number>`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/__tests__/release.test.mjs`:

```js
import { parseReleaseArgs, prepareFiles, planRelease, main } from '../release.mjs';
import { makeFakeIO } from './helpers/fake-run.mjs';
import { PROJECT_YML, PBXPROJ, CHANGELOG_PATH } from '../lib/paths.mjs';

const CHANGELOG_TEXT = `# Changelog

## [Unreleased]

### Added
- Dictation hotkey.
`;

function releaseIO() {
  return makeFakeIO({
    [PROJECT_YML]: PROJECT_YML_TEXT,
    [PBXPROJ]: PBXPROJ_TEXT,
    [CHANGELOG_PATH]: CHANGELOG_TEXT,
  });
}

test('parseReleaseArgs defaults to a patch release', () => {
  assert.deepEqual(parseReleaseArgs([]), { requested: 'patch', dryRun: false, yes: false, help: false });
  assert.deepEqual(parseReleaseArgs(['minor', '--yes']),
    { requested: 'minor', dryRun: false, yes: true, help: false });
  assert.deepEqual(parseReleaseArgs(['--dry-run', '1.5.0']),
    { requested: '1.5.0', dryRun: true, yes: false, help: false });
});

test('parseReleaseArgs rejects more than one version argument', () => {
  assert.throws(() => parseReleaseArgs(['patch', 'minor']), /exactly one version argument/);
});

test('prepareFiles rewrites the three version-bearing files', async () => {
  const io = releaseIO();
  const written = await prepareFiles({ current: '0.1.0', version: '0.2.0', isoDate: '2026-08-23', io });

  assert.deepEqual(written, [PROJECT_YML, PBXPROJ, CHANGELOG_PATH]);
  assert.ok((await io.readFile(PROJECT_YML)).includes('MARKETING_VERSION: "0.2.0"'));
  assert.equal((await io.readFile(PBXPROJ)).match(/MARKETING_VERSION = 0\.2\.0;/g).length, 2);
  assert.ok((await io.readFile(CHANGELOG_PATH)).includes('## [0.2.0] - 2026-08-23'));
  assert.ok((await io.readFile(CHANGELOG_PATH)).includes('## [Unreleased]'));
});

test('prepareFiles leaves every file untouched when one rewrite fails', async () => {
  const io = releaseIO();
  await assert.rejects(
    prepareFiles({ current: '9.9.9', version: '10.0.0', isoDate: '2026-08-23', io }),
    /does not declare MARKETING_VERSION 9\.9\.9/,
  );
  assert.deepEqual(io.writes, []);
});

test('planRelease runs every gate before touching the remote', () => {
  const lines = planRelease({ version: '0.2.0', notesPath: '/out/notes.md', assets: [] })
    .map((s) => [s.cmd, ...s.args].join(' '));
  assert.deepEqual(lines, [
    'npm run test:scripts',
    'swift test --package-path macos',
    'xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo -configuration Release '
      + '-destination generic/platform=macOS CODE_SIGNING_ALLOWED=NO build',
    'git diff --check',
    'git add macos/project.yml macos/Macomprendo.xcodeproj/project.pbxproj CHANGELOG.md',
    'git commit -m Release 0.2.0',
    'git tag -a v0.2.0 -m Macomprendo 0.2.0',
    'git push origin main',
    'git push origin v0.2.0',
    'gh release create v0.2.0 --target main --title Macomprendo 0.2.0 --notes-file /out/notes.md --latest',
  ]);
});

test('planRelease attaches an existing artifact to the GitHub release', () => {
  const create = planRelease({
    version: '0.2.0', notesPath: '/out/notes.md', assets: ['/out/Macomprendo-0.2.0-macos.zip'],
  }).at(-1);
  assert.equal(create.args.at(-1), '/out/Macomprendo-0.2.0-macos.zip');
});

test('main --dry-run resolves the version, validates the changelog and changes nothing', async () => {
  const io = releaseIO();
  const run = makeFakeRun();
  const log = makeFakeLog();

  const code = await main(['--dry-run', 'patch'], { run, log, io, now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  assert.deepEqual(run.calls, []);
  assert.deepEqual(io.writes, []);
  const printed = log.lines.join('\n');
  assert.ok(printed.includes('Current version: 0.1.0'));
  assert.ok(printed.includes('Release version: 0.1.1'));
  assert.ok(printed.includes('## [0.1.1] - 2026-08-23'));
  assert.ok(printed.includes('gh release create v0.1.1'));
});

test('main --dry-run fails when the Unreleased section is empty', async () => {
  const io = releaseIO();
  await io.writeFile(CHANGELOG_PATH, '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n');
  const log = makeFakeLog();

  const code = await main(['--dry-run'], { run: makeFakeRun(), log, io, now: () => new Date('2026-08-23') });

  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => l.includes('no entries under "## [Unreleased]"')));
});

test('main --yes performs the whole release in order', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' } });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'], { run, log, io, now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  const lines = run.lines();
  assert.ok(lines.indexOf('git status --porcelain') < lines.indexOf('npm run test:scripts'));
  assert.ok(lines.indexOf('npm run test:scripts') < lines.indexOf('git commit -m Release 0.1.1'));
  assert.ok(lines.indexOf('git tag -a v0.1.1 -m Macomprendo 0.1.1') < lines.indexOf('git push origin main'));
  assert.ok(lines.some((l) => l.startsWith('gh release create v0.1.1')));
  assert.deepEqual(io.writes.slice(0, 3), [PROJECT_YML, PBXPROJ, CHANGELOG_PATH]);
});

test('main aborts before writing anything when preflight fails', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git status --porcelain': { stdout: ' M README.md' } });
  const log = makeFakeLog();

  const code = await main(['--yes'], { run, log, io, now: () => new Date('2026-08-23') });

  assert.equal(code, 1);
  assert.deepEqual(io.writes, []);
  assert.ok(log.lines.some((l) => l.includes('working tree is not clean')));
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test scripts/__tests__/release.test.mjs`
Expected: FAIL — `does not provide an export named 'parseReleaseArgs'`.

- [ ] **Step 3: Append the flow half to `scripts/release.mjs`**

```js
export function parseReleaseArgs(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      'dry-run': { type: 'boolean', default: false },
      yes: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  if (positionals.length > 1) {
    throw new Error('Pass exactly one version argument: patch, minor, major, or X.Y.Z.');
  }
  return {
    requested: positionals[0] ?? 'patch',
    dryRun: values['dry-run'],
    yes: values.yes,
    help: values.help,
  };
}

export async function prepareFiles({ current, version, isoDate, io }) {
  const projectYml = replaceProjectYmlVersion(await io.readFile(PROJECT_YML), current, version);
  const pbxproj = replacePbxprojVersions(await io.readFile(PBXPROJ), current, version);
  const changelog = updateChangelog(await io.readFile(CHANGELOG_PATH), version, isoDate);
  assertProjectYmlParses(projectYml, version);

  await io.writeFile(PROJECT_YML, projectYml);
  await io.writeFile(PBXPROJ, pbxproj);
  await io.writeFile(CHANGELOG_PATH, changelog);
  return [PROJECT_YML, PBXPROJ, CHANGELOG_PATH];
}

export function planRelease({ version, notesPath, assets }) {
  const exec = (cmd, args) => ({ type: 'exec', cmd, args });
  return [
    exec('npm', ['run', 'test:scripts']),
    exec('swift', ['test', '--package-path', 'macos']),
    exec('xcodebuild', [
      '-project', 'macos/Macomprendo.xcodeproj',
      '-scheme', SCHEME,
      '-configuration', 'Release',
      '-destination', 'generic/platform=macOS',
      'CODE_SIGNING_ALLOWED=NO',
      'build',
    ]),
    exec('git', ['diff', '--check']),
    exec('git', ['add', 'macos/project.yml', 'macos/Macomprendo.xcodeproj/project.pbxproj', 'CHANGELOG.md']),
    exec('git', ['commit', '-m', `Release ${version}`]),
    exec('git', ['tag', '-a', `v${version}`, '-m', `Macomprendo ${version}`]),
    exec('git', ['push', 'origin', 'main']),
    exec('git', ['push', 'origin', `v${version}`]),
    exec('gh', [
      'release', 'create', `v${version}`,
      '--target', 'main',
      '--title', `Macomprendo ${version}`,
      '--notes-file', notesPath,
      '--latest',
      ...assets,
    ]),
  ];
}

export function confirm(question, io = { input: process.stdin, output: process.stdout }) {
  return new Promise((resolve, reject) => {
    const rl = createInterface({ input: io.input, output: io.output, terminal: true });
    rl.on('error', reject);
    rl.question(question, (answer) => {
      rl.close();
      resolve(['y', 'yes'].includes(answer.trim().toLowerCase()));
    });
  });
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, io = realIO, fsOps = realFsOps,
    now = () => new Date(), root = ROOT, dist = DIST_DIR, ask = confirm,
  } = deps;

  let options;
  try {
    options = parseReleaseArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run release -- [patch|minor|major|X.Y.Z] [--dry-run] [--yes]',
      '',
      '  --dry-run  resolve the version and print the plan without changing anything',
      '  --yes      publish without the interactive confirmation',
    ].join('\n'));
    return 0;
  }

  try {
    const current = readVersion(await io.readFile(PROJECT_YML));
    const version = resolveVersion(current, options.requested);
    const isoDate = now().toISOString().slice(0, 10);

    // Validate the changelog before any network or repository work.
    const releasedChangelog = updateChangelog(await io.readFile(CHANGELOG_PATH), version, isoDate);
    const notes = extractSection(releasedChangelog, version);
    const notesPath = path.join(dist, `release-notes-${version}.md`);
    const assetPath = path.join(dist, `Macomprendo-${version}-macos.zip`);

    log.info(`Current version: ${current}`);
    log.info(`Release version: ${version}`);
    log.info(`Changelog heading: ## [${version}] - ${isoDate}`);
    log.info(`Release notes:\n${notes}`);

    if (options.dryRun) {
      log.info('Planned commands:');
      for (const step of planRelease({ version, notesPath, assets: [] })) {
        log.info(`  ${[step.cmd, ...step.args].join(' ')}`);
      }
      log.info('Dry run complete; no files, tags or remote state changed.');
      return 0;
    }

    await preflight(version, { run, log, root });

    if (!options.yes && !(await ask(`Publish Macomprendo ${version}? [y/N] `))) {
      log.info('Release cancelled.');
      return 1;
    }

    await prepareFiles({ current, version, isoDate, io });
    await fsOps.mkdirp(dist);
    await io.writeFile(notesPath, `${notes}\n`);

    const assets = (await io.exists(assetPath)) ? [assetPath] : [];
    if (assets.length === 0) {
      log.warn(`No notarized artifact at ${assetPath}; publishing release notes only. `
        + 'Run "npm run notarize" first if you want to attach the ZIP.');
    }

    for (const step of planRelease({ version, notesPath, assets })) {
      log.step([step.cmd, ...step.args].join(' '));
      await run(step.cmd, step.args, { cwd: root });
    }

    const url = await run('gh', ['release', 'view', `v${version}`, '--json', 'url', '--jq', '.url'],
      { cwd: root, capture: true });
    log.info(`Published ${version}: ${(url.stdout ?? '').trim()}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

**Two details that matter:**

1. Change the Task 7 import line `import { realIO } from './lib/fs.mjs';` to
   `import { realFsOps, realIO } from './lib/fs.mjs';` — the flow needs `mkdirp` to create
   `dist/` before writing the release-notes file.
2. `prepareFiles` writes only after all three transforms succeed, which is why every `replace*`
   call happens before the first `io.writeFile`. The `main` tests rely on that: a failed rewrite
   must leave `io.writes` empty.

The release-notes file lands in `dist/`, which is git-ignored, so it never enters the release
commit. In the `main` tests `fsOps` defaults to `realFsOps`, so `mkdirp(DIST_DIR)` performs a
harmless real `mkdir -p dist`; pass `fsOps: makeFakeFsOps()` in a test if you want it fully hermetic.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test scripts/__tests__/release.test.mjs`
Expected: PASS — `# pass 26`, `# fail 0`.

- [ ] **Step 5: Add the `release` script to `package.json`**

```json
"release": "node scripts/release.mjs"
```

- [ ] **Step 6: Confirm the remote actually is GitHub**

Run: `git remote get-url origin`

Expected: a `github.com` URL. The spec mandates `gh release create`, which only works against
GitHub.

**If the remote is GitLab or anything else, stop and ask the maintainer before continuing.**
At the time this plan was written `origin` pointed at `gitlab.com/dzamataev/macomprendo`, so
this is a live question, not a hypothetical. The three possible resolutions are: (a) add a
GitHub remote and publish there, (b) keep GitLab and swap the last step of `planRelease` for
`glab release create v<version> --notes-file <path>` plus `--assets-links`, or (c) drop the
hosted-release step and publish tags only. Do **not** guess — the choice also decides the
`README.md` Releases URL and the `gh auth status` preflight check.

- [ ] **Step 7: Verify the real dry run**

Run: `npm run release -- --dry-run patch`
Expected: exit 0, printing `Current version: 0.1.0`, `Release version: 0.1.1`, the release notes
extracted from the Unreleased section, and the ten planned commands ending with
`gh release create v0.1.1 …`. Nothing in `git status` changes.

If it reports `no entries under "## [Unreleased]"`, Task 12 has not run yet — that is expected at
this point in the plan; re-run this step at the end of Task 12.

- [ ] **Step 8: Commit**

```bash
git add scripts/release.mjs scripts/__tests__/release.test.mjs package.json
git commit -m "feat(scripts): add the end-to-end release flow with dry-run and confirmation"
```

---

### Task 9: `audit-public-repo.mjs`

**Files:**
- Create: `scripts/audit-public-repo.mjs`
- Test: `scripts/__tests__/audit-public-repo.test.mjs`
- Modify: `package.json` (add the `audit` script)

**What this guards:** the repository is public. The audit refuses to let a commit go out that
carries Xcode user state, private keys, provisioning profiles, notary logs, `.env` files, or any
machine-specific `/Users/<name>` path. It also runs `git diff --check` (trailing whitespace and
conflict markers) and, when `gitleaks` happens to be installed, a secret scan of both the working
tree and the git history.

**Interfaces:**
- Consumes: `scripts/lib/paths.mjs`, `run`, `log`, `realIO`.
- Produces:
  - `UNSAFE_PATH_RULES: Array<{ name: string, test: (p: string) => boolean }>`
  - `findUnsafePaths(paths) -> Array<{ path: string, rule: string }>`
  - `BINARY_EXTENSIONS: Set<string>` and `CONTENT_SCAN_EXCLUDES: Set<string>`
  - `shouldScanContent(relativePath) -> boolean`
  - `findHomePaths(text, { file, allow }) -> Array<{ file, line, column, match }>`
  - `main(argv, deps) -> Promise<number>`

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/audit-public-repo.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  findUnsafePaths, shouldScanContent, findHomePaths, main,
} from '../audit-public-repo.mjs';
import { makeFakeRun, makeFakeIO, makeFakeLog } from './helpers/fake-run.mjs';

test('findUnsafePaths rejects Xcode user state, keys, profiles and notary logs', () => {
  const flagged = findUnsafePaths([
    'macos/Macomprendo.xcodeproj/xcuserdata/dev.xcuserdatad/xcschemes/x.xcscheme',
    'macos/.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata',
    'macos/Macomprendo.xcodeproj/project.xcworkspace/UserInterfaceState.xcuserstate',
    'build/Macomprendo.xcarchive/Info.plist',
    'build/Macomprendo.xcresult/Info.plist',
    'dist/Macomprendo.app.dSYM/Contents/Info.plist',
    'dist/notary-log-abc-123.json',
    'secrets/AuthKey_ABC123.p8',
    'secrets/cert.p12',
    'secrets/cert.pem',
    'secrets/cert.cer',
    'secrets/private.key',
    'profiles/dev.mobileprovision',
    'profiles/dev.provisionprofile',
    'login.keychain',
    '.env',
    '.env.local',
  ]).map((hit) => hit.path);
  assert.equal(flagged.length, 17);
});

test('findUnsafePaths allows the ordinary repository contents', () => {
  assert.deepEqual(findUnsafePaths([
    'README.md',
    '.env.example',
    'macos/project.yml',
    'macos/Macomprendo.xcodeproj/project.pbxproj',
    'macos/Sources/Macomprendo/Core/KeychainStore.swift',
    'scripts/lib/keychain-notes.md',
    'docs/DECISIONS/ADR-0003-not-sandboxed.md',
  ]), []);
});

test('shouldScanContent skips binaries and the audit files themselves', () => {
  assert.equal(shouldScanContent('README.md'), true);
  assert.equal(shouldScanContent('macos/Sources/Macomprendo/App/AppModel.swift'), true);
  assert.equal(shouldScanContent('macos/AppBundle/AppIcon.icns'), false);
  assert.equal(shouldScanContent('docs/images/panel.png'), false);
  assert.equal(shouldScanContent('scripts/audit-public-repo.mjs'), false);
  assert.equal(shouldScanContent('scripts/__tests__/audit-public-repo.test.mjs'), false);
});

test('findHomePaths reports machine-specific home directories with line and column', () => {
  const text = 'ok line\nopen /Users/alice/dev/macomprendo\nfine\n';
  assert.deepEqual(findHomePaths(text, { file: 'docs/x.md' }), [
    { file: 'docs/x.md', line: 2, column: 6, match: '/Users/alice' },
  ]);
});

test('findHomePaths allows the sanctioned placeholder homes', () => {
  const text = [
    '/Users/test/Library/Application Support/Macomprendo',
    '/Users/test',
    '~/Library/Application Support/Macomprendo',
    '/Users/<local-user>/dev',
  ].join('\n');
  assert.deepEqual(findHomePaths(text, { file: 'docs/x.md' }), []);
  assert.equal(findHomePaths('/Users/testuser/x', { file: 'a' }).length, 1);
});

function auditDeps({ files, contents = {}, gitleaks = false }) {
  const table = {
    'git ls-files --cached --others --exclude-standard': { stdout: files.join('\n') },
    'git diff --check': { stdout: '' },
  };
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (line === 'command -v gitleaks' || (cmd === 'which' && args[0] === 'gitleaks')) {
      return { stdout: gitleaks ? '/usr/local/bin/gitleaks' : '', stderr: '', code: gitleaks ? 0 : 1 };
    }
    const hit = table[line];
    if (hit?.throws) throw new Error(hit.throws);
    return { stdout: hit?.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  // root: '' makes the implementation's path.join(root, file) return the bare relative
  // path, which is exactly how makeFakeIO is keyed.
  return { run, io: makeFakeIO(contents), log: makeFakeLog(), root: '' };
}

test('main passes on a clean tree', async () => {
  const deps = auditDeps({
    files: ['README.md', 'macos/project.yml'],
    contents: { 'README.md': '# Macomprendo\n', 'macos/project.yml': 'name: Macomprendo\n' },
  });
  const code = await main([], deps);
  assert.equal(code, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Public repository audit passed')));
  assert.ok(deps.run.lines().includes('git diff --check'));
});

test('main refuses a tracked private key', async () => {
  const deps = auditDeps({ files: ['README.md', 'secrets/AuthKey_ABC.p8'], contents: { 'README.md': 'x' } });
  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('secrets/AuthKey_ABC.p8')));
  assert.equal(deps.run.lines().includes('git diff --check'), false);
});

test('main refuses a machine-specific home path in a tracked file', async () => {
  const deps = auditDeps({
    files: ['docs/SMOKE_TEST.md'],
    contents: { 'docs/SMOKE_TEST.md': 'Open /Users/alice/dev/macomprendo and run.\n' },
  });
  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('docs/SMOKE_TEST.md:1:6')));
});

test('main runs gitleaks when it is installed', async () => {
  const deps = auditDeps({ files: ['README.md'], contents: { 'README.md': 'x' }, gitleaks: true });
  await main([], deps);
  assert.ok(deps.run.lines().some((l) => l.startsWith('gitleaks detect --source . --no-git')));
  assert.ok(deps.run.lines().some((l) => l === 'gitleaks detect --source . --redact --no-banner'));
});

test('main notes when gitleaks is unavailable but still passes', async () => {
  const deps = auditDeps({ files: ['README.md'], contents: { 'README.md': 'x' } });
  const code = await main([], deps);
  assert.equal(code, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Gitleaks is not installed')));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/audit-public-repo.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/audit-public-repo.mjs'`.

- [ ] **Step 3: Implement `scripts/audit-public-repo.mjs`**

```js
#!/usr/bin/env node
// Refuse to publish sensitive filenames, machine-specific paths, or whitespace errors.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { ROOT } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realIO } from './lib/fs.mjs';

const SECRET_EXTENSIONS = /\.(p8|p12|pem|cer|key|keychain|mobileprovision|provisionprofile)$/;

export const UNSAFE_PATH_RULES = [
  { name: 'Xcode user state', test: (p) => /(^|\/)xcuserdata(\/|$)/.test(p) || /\.xcuserstate$/.test(p) },
  { name: 'SwiftPM local state', test: (p) => /(^|\/)\.swiftpm(\/|$)/.test(p) },
  { name: 'build output', test: (p) => /\.(xcarchive|xcresult|dSYM)(\/|$)/.test(p) },
  { name: 'notary log', test: (p) => /(^|\/)notary-log-[^/]*\.json$/.test(p) },
  { name: 'credential file', test: (p) => SECRET_EXTENSIONS.test(p) },
  {
    name: 'environment file',
    test: (p) => /(^|\/)\.env($|\.)/.test(p) && !/(^|\/)\.env\.example$/.test(p),
  },
];

export function findUnsafePaths(paths) {
  const hits = [];
  for (const candidate of paths) {
    const relative = candidate.trim();
    if (relative === '') continue;
    for (const rule of UNSAFE_PATH_RULES) {
      if (rule.test(relative)) {
        hits.push({ path: relative, rule: rule.name });
        break;
      }
    }
  }
  return hits;
}

export const BINARY_EXTENSIONS = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.icns', '.ico', '.pdf', '.zip', '.gz',
  '.ttf', '.otf', '.woff', '.woff2', '.mp3', '.wav', '.aiff', '.bin',
  '.metallib', '.dylib', '.a', '.o', '.xcuserstate',
]);

export const CONTENT_SCAN_EXCLUDES = new Set([
  'scripts/audit-public-repo.mjs',
  'scripts/__tests__/audit-public-repo.test.mjs',
]);

export function shouldScanContent(relativePath) {
  if (CONTENT_SCAN_EXCLUDES.has(relativePath)) return false;
  return !BINARY_EXTENSIONS.has(path.extname(relativePath).toLowerCase());
}

const HOME_PATH = /\/Users\/([A-Za-z0-9._-]+)/g;
const DEFAULT_ALLOWED_HOMES = ['test', 'example', 'shared'];

export function findHomePaths(text, { file, allow = DEFAULT_ALLOWED_HOMES }) {
  const allowed = new Set(allow);
  const hits = [];
  const lines = text.split('\n');
  for (const [index, line] of lines.entries()) {
    HOME_PATH.lastIndex = 0;
    let match;
    while ((match = HOME_PATH.exec(line)) !== null) {
      if (allowed.has(match[1])) continue;
      hits.push({
        file,
        line: index + 1,
        column: match.index + 1,
        match: `/Users/${match[1]}`,
      });
    }
  }
  return hits;
}

async function hasGitleaks(run) {
  const result = await run('which', ['gitleaks'], { capture: true, check: false, cwd: ROOT });
  return (result.stdout ?? '').trim() !== '';
}

export async function main(argv, deps = {}) {
  const { run = realRun, log = realLog, io = realIO, root = ROOT } = deps;

  try {
    log.step('Listing candidate files');
    const listed = await run('git', ['ls-files', '--cached', '--others', '--exclude-standard'], {
      cwd: root, capture: true,
    });
    const files = (listed.stdout ?? '').split('\n').map((f) => f.trim()).filter((f) => f !== '');

    log.step('Checking filenames');
    const unsafe = findUnsafePaths(files);
    if (unsafe.length > 0) {
      log.error('Refusing publication because sensitive or generated files are visible:');
      for (const hit of unsafe) log.error(`  ${hit.path}  (${hit.rule})`);
      log.error('Remove them, add them to .gitignore, and rewrite history if they were ever committed.');
      return 1;
    }

    log.step('Checking for machine-specific home paths');
    const homeHits = [];
    for (const file of files) {
      if (!shouldScanContent(file)) continue;
      let text;
      try {
        text = await io.readFile(path.isAbsolute(file) ? file : path.join(root, file));
      } catch {
        continue; // unreadable or binary; the extension filter already covers the usual cases
      }
      homeHits.push(...findHomePaths(text, { file }));
    }
    if (homeHits.length > 0) {
      log.error('Replace or redact these machine-specific paths before publishing:');
      for (const hit of homeHits) log.error(`  ${hit.file}:${hit.line}:${hit.column}  ${hit.match}`);
      log.error('Use ~/, <repo>, or /Users/test instead.');
      return 1;
    }

    log.step('Checking whitespace and conflict markers');
    await run('git', ['diff', '--check'], { cwd: root });

    if (await hasGitleaks(run)) {
      log.step('Scanning candidate files with Gitleaks');
      await run('gitleaks', ['detect', '--source', '.', '--no-git', '--redact', '--no-banner'], { cwd: root });
      log.step('Scanning Git history with Gitleaks');
      await run('gitleaks', ['detect', '--source', '.', '--redact', '--no-banner'], { cwd: root });
    } else {
      log.info('Gitleaks is not installed; filename, path, and diff checks passed. '
        + 'Install it with: brew install gitleaks');
    }

    log.info('Public repository audit passed.');
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/__tests__/audit-public-repo.test.mjs`
Expected: PASS — `# pass 10`, `# fail 0`.

- [ ] **Step 5: Add the `audit` script to `package.json`**

```json
"audit": "node scripts/audit-public-repo.mjs"
```

- [ ] **Step 6: Run the real audit**

Run: `npm run audit`
Expected: `Public repository audit passed.` and exit 0.

If it flags `/Users/<name>` inside `docs/superpowers/plans/*.md`, edit those plan files to use
`~/` or `<repo>` instead of the absolute path — machine paths must not be published.

- [ ] **Step 7: Commit**

```bash
git add scripts/audit-public-repo.mjs scripts/__tests__/audit-public-repo.test.mjs package.json
git commit -m "feat(scripts): audit the public repository for secrets and machine paths"
```

---

### Task 10: `install-app.mjs`

**Files:**
- Create: `scripts/install-app.mjs`
- Test: `scripts/__tests__/install-app.test.mjs`
- Modify: `package.json` (add the `install-app` script)

**What it does:** builds the app from the current checkout, stages it in a temporary directory
*inside* the install directory (so the final move is an atomic same-volume rename), quits any
running copy, moves the old app aside as a backup, moves the new one into place, verifies the
signature, and restores the backup if anything fails.

**Interfaces:**
- Consumes: `scripts/lib/paths.mjs`, `run`, `log`, `realFsOps`.
- Produces:
  - `parseInstallArgs(argv) -> { installDir: string, open: boolean, help: boolean }`
  - `executablePattern(destination) -> string` — an anchored regex for `pgrep -f`.
  - `planInstall({ installDir, workDir, source }) -> Step[]`
  - `main(argv, deps) -> Promise<number>`

- [ ] **Step 1: Write the failing test**

Create `scripts/__tests__/install-app.test.mjs`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseInstallArgs, executablePattern, planInstall, main } from '../install-app.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeLog } from './helpers/fake-run.mjs';

test('parseInstallArgs defaults to /Applications and opening the app', () => {
  assert.deepEqual(parseInstallArgs([], {}), { installDir: '/Applications', open: true, help: false });
});

test('parseInstallArgs honours --no-open, --install-dir and MACOS_INSTALL_DIR', () => {
  assert.equal(parseInstallArgs(['--no-open'], {}).open, false);
  assert.equal(parseInstallArgs(['--install-dir', '~/Apps/'], {}).installDir, '~/Apps');
  assert.equal(parseInstallArgs([], { MACOS_INSTALL_DIR: '/Volumes/Dev/Apps' }).installDir,
    '/Volumes/Dev/Apps');
  assert.equal(parseInstallArgs(['--install-dir', '/Custom'], { MACOS_INSTALL_DIR: '/Ignored' }).installDir,
    '/Custom');
});

test('executablePattern anchors on the installed executable and escapes regex characters', () => {
  assert.equal(
    executablePattern('/Applications/Macomprendo.app'),
    '^/Applications/Macomprendo\\.app/Contents/MacOS/Macomprendo([[:space:]]|$)',
  );
});

test('planInstall builds, stages, swaps and verifies', () => {
  const lines = planInstall({
    installDir: '/Applications',
    workDir: '/Applications/.macomprendo-update.AB12',
    source: '/repo/dist/Macomprendo.app',
  }).map((s) => (s.type === 'exec' ? [s.cmd, ...s.args].join(' ') : `${s.type} ${s.from ?? s.path} ${s.to ?? ''}`.trim()));

  assert.deepEqual(lines, [
    'node scripts/build-app.mjs',
    'codesign --verify --deep --strict /repo/dist/Macomprendo.app',
    'ditto /repo/dist/Macomprendo.app /Applications/.macomprendo-update.AB12/Macomprendo.app',
    'codesign --verify --deep --strict /Applications/.macomprendo-update.AB12/Macomprendo.app',
  ]);
});

function installDeps({ running = false, existing = true } = {}) {
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (cmd === 'pgrep') {
      return running && calls.filter((c) => c.cmd === 'pgrep').length <= 1
        ? { stdout: '4242\n', stderr: '', code: 0 }
        : { stdout: '', stderr: '', code: 1 };
    }
    if (cmd === '/usr/libexec/PlistBuddy') return { stdout: '0.1.0\n', stderr: '', code: 0 };
    return { stdout: '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);

  const fsOps = makeFakeFsOps([
    '/Applications',
    ...(existing ? ['/Applications/Macomprendo.app'] : []),
    '/repo/dist/Macomprendo.app',
  ]);
  fsOps.moves = [];
  fsOps.move = async (from, to) => { fsOps.moves.push([from, to]); fsOps.present.delete(from); fsOps.present.add(to); };
  fsOps.mkdtemp = async (prefix) => `${prefix}AB12`;
  // env: {} keeps MACOS_INSTALL_DIR from the developer's shell out of the test.
  return { run, fsOps, log: makeFakeLog(), env: {}, source: '/repo/dist/Macomprendo.app' };
}

test('main installs over an existing copy and opens it', async () => {
  const deps = installDeps();
  const code = await main([], deps);

  assert.equal(code, 0);
  assert.deepEqual(deps.fsOps.moves, [
    ['/Applications/Macomprendo.app', '/Applications/.macomprendo-update.AB12/previous-Macomprendo.app'],
    ['/Applications/.macomprendo-update.AB12/Macomprendo.app', '/Applications/Macomprendo.app'],
  ]);
  assert.ok(deps.run.lines().includes('open /Applications/Macomprendo.app'));
  assert.ok(deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/.macomprendo-update.AB12'));
});

test('main --no-open leaves the app closed', async () => {
  const deps = installDeps();
  await main(['--no-open'], deps);
  assert.equal(deps.run.lines().some((l) => l.startsWith('open ')), false);
});

test('main terminates a running copy before swapping', async () => {
  const deps = installDeps({ running: true });
  const code = await main([], deps);
  assert.equal(code, 0);
  assert.ok(deps.run.lines().includes('kill -TERM 4242'));
});

test('main restores the backup when the swap fails', async () => {
  const deps = installDeps();
  let swaps = 0;
  const originalMove = deps.fsOps.move;
  deps.fsOps.move = async (from, to) => {
    swaps += 1;
    if (swaps === 2) throw new Error('Resource busy');
    return originalMove(from, to);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.deepEqual(deps.fsOps.moves.at(-1), [
    '/Applications/.macomprendo-update.AB12/previous-Macomprendo.app',
    '/Applications/Macomprendo.app',
  ]);
  assert.ok(deps.log.lines.some((l) => l.includes('Restored the previously installed app')));
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/__tests__/install-app.test.mjs`
Expected: FAIL — `Cannot find module '.../scripts/install-app.mjs'`.

- [ ] **Step 3: Add `move` and `mkdtemp` to `scripts/lib/fs.mjs`**

Append to `scripts/lib/fs.mjs` and add both to the `realFsOps` object:

```js
import { rename, mkdtemp } from 'node:fs/promises';

export async function move(from, to) {
  await rename(from, to);
}

export async function makeTempDir(prefix) {
  return mkdtemp(prefix);
}
```

Update: `export const realFsOps = { mkdirp, rmrf, copyPath, chmodExec, pathExists, listBundles, move, mkdtemp: makeTempDir };`

- [ ] **Step 4: Implement `scripts/install-app.mjs`**

```js
#!/usr/bin/env node
// Build the app from this checkout and install it atomically, keeping a restorable backup.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

import { ROOT, DIST_DIR, APP_NAME, EXECUTABLE_NAME, appPath } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps } from './lib/fs.mjs';

export function parseInstallArgs(argv, env = process.env) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      'install-dir': { type: 'string' },
      'no-open': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  const raw = values['install-dir'] ?? env.MACOS_INSTALL_DIR ?? '/Applications';
  const installDir = raw.length > 1 && raw.endsWith('/') ? raw.slice(0, -1) : raw;
  return { installDir, open: !values['no-open'], help: values.help };
}

export function executablePattern(destination) {
  const executable = path.join(destination, 'Contents', 'MacOS', EXECUTABLE_NAME);
  const escaped = executable.replace(/[[\]().^$*+?|\\{}]/g, '\\$&');
  return `^${escaped}([[:space:]]|$)`;
}

export function planInstall({ installDir, workDir, source }) {
  const staged = path.join(workDir, APP_NAME);
  return [
    { type: 'exec', cmd: 'node', args: ['scripts/build-app.mjs'] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', source] },
    { type: 'exec', cmd: 'ditto', args: [source, staged] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', staged] },
  ];
}

async function runningPIDs(run, pattern) {
  const result = await run('pgrep', ['-f', pattern], { capture: true, check: false });
  return (result.stdout ?? '').split('\n').map((p) => p.trim()).filter((p) => p !== '');
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps,
    env = process.env, root = ROOT, source = appPath(DIST_DIR),
  } = deps;

  let options;
  try {
    options = parseInstallArgs(argv, env);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run install-app -- [--no-open] [--install-dir <dir>]',
      '',
      'Builds Macomprendo.app from this checkout and replaces the installed copy.',
      'Environment: MACOS_INSTALL_DIR (default /Applications).',
    ].join('\n'));
    return 0;
  }

  if (!(await fsOps.pathExists(options.installDir))) {
    log.error(`Install directory does not exist: ${options.installDir}`);
    return 1;
  }

  const destination = path.join(options.installDir, APP_NAME);
  const pattern = executablePattern(destination);
  let workDir = null;
  let backup = null;
  let installed = false;

  try {
    workDir = await fsOps.mkdtemp(path.join(options.installDir, '.macomprendo-update.'));
    const staged = path.join(workDir, APP_NAME);
    backup = path.join(workDir, `previous-${APP_NAME}`);

    for (const step of planInstall({ installDir: options.installDir, workDir, source })) {
      log.step([step.cmd, ...step.args].join(' '));
      await run(step.cmd, step.args, { cwd: root });
    }

    let pids = await runningPIDs(run, pattern);
    if (pids.length > 0) {
      log.info('Closing the installed app before updating it…');
      for (const pid of pids) await run('kill', ['-TERM', pid], { check: false });
      for (let attempt = 0; attempt < 20; attempt += 1) {
        pids = await runningPIDs(run, pattern);
        if (pids.length === 0) break;
        await sleep(250);
      }
      if (pids.length > 0) {
        throw new Error('Macomprendo is still running. Quit it and run the installer again.');
      }
    }

    if (await fsOps.pathExists(destination)) {
      await fsOps.move(destination, backup);
    } else {
      backup = null;
    }
    await fsOps.move(staged, destination);
    installed = true;

    await run('codesign', ['--verify', '--deep', '--strict', destination], { cwd: root });
    const version = await run('/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleShortVersionString', path.join(destination, 'Contents', 'Info.plist')],
      { capture: true });
    log.info(`Installed Macomprendo ${(version.stdout ?? '').trim()} at ${destination}`);

    if (options.open) {
      await run('open', [destination]);
      log.info('Launched the updated app.');
    }
    return 0;
  } catch (error) {
    log.error(error.message);
    if (!installed && backup !== null && (await fsOps.pathExists(backup))) {
      try {
        await fsOps.move(backup, destination);
        log.info('Restored the previously installed app.');
      } catch (restoreError) {
        log.error(`Automatic restore failed; the previous app remains at ${backup}: ${restoreError.message}`);
        return 1;
      }
    }
    return 1;
  } finally {
    // Remove the staging directory whenever the destination is in place — either the new
    // app was installed, or the backup was successfully restored. If the destination is
    // missing, the backup is the only copy left and must survive for manual recovery.
    if (workDir !== null && (await fsOps.pathExists(destination))) {
      await fsOps.rmrf(workDir);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `node --test scripts/__tests__/install-app.test.mjs`
Expected: PASS — `# pass 8`, `# fail 0`.

- [ ] **Step 6: Add the `install-app` script to `package.json`**

```json
"install-app": "node scripts/install-app.mjs"
```

- [ ] **Step 7: MANUAL VERIFICATION — install into a scratch directory, then into /Applications**

Run:

```bash
mkdir -p ~/Applications
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app -- --no-open
ls -d ~/Applications/Macomprendo.app
codesign --verify --deep --strict ~/Applications/Macomprendo.app
```

Expected: the bundle exists, `codesign` is silent (success), and no `.macomprendo-update.*`
directory is left behind (`ls -a ~/Applications | grep macomprendo-update` finds nothing).

Then run it a second time with the app already installed and running:

```bash
open ~/Applications/Macomprendo.app
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app
```

Expected: `Closing the installed app before updating it…`, then
`Installed Macomprendo 0.1.0 at /Users/<you>/Applications/Macomprendo.app`, then
`Launched the updated app.` and the menubar icon returns.

- [ ] **Step 8: Commit**

```bash
git add scripts/install-app.mjs scripts/__tests__/install-app.test.mjs scripts/lib/fs.mjs package.json
git commit -m "feat(scripts): install the built app atomically with backup and restore"
```

---

### Task 11: Architecture Decision Records

**Files:**
- Create: `docs/DECISIONS/ADR-0001-llm-through-endpoints.md`
- Create: `docs/DECISIONS/ADR-0002-whisper-cpp-in-process.md`
- Create: `docs/DECISIONS/ADR-0003-not-sandboxed.md`
- Create: `docs/DECISIONS/ADR-0004-keyboardshortcuts-library.md`
- Create: `docs/DECISIONS/ADR-0005-phosphor-icons.md`
- Create: `docs/DECISIONS/ADR-0006-fixed-quick-panel-position.md`

**Interfaces:**
- Consumes: spec §9. Produces: documentation only; no code depends on these files.

Each ADR uses the same four-heading shape: `Status`, `Context`, `Decision`, `Consequences`.

- [ ] **Step 1: Write ADR-0001**

Create `docs/DECISIONS/ADR-0001-llm-through-endpoints.md`:

```markdown
# ADR-0001: LLM features run through configurable endpoints, not a bundled engine

## Status

Accepted — 2026-08-23

## Context

Refine and Summarize need a chat model. Bundling llama.cpp plus weights would add hundreds of
megabytes to the download, force us to ship and update GGUF files, and make us responsible for
inference performance on every Mac. Meanwhile Ollama is already installed on most developer Macs
and exposes both a native API (`/api/tags`, `/api/chat`, `/api/pull`) and an OpenAI-compatible
surface, and every hosted provider worth supporting speaks `/v1/chat/completions`.

## Decision

Macomprendo ships no LLM engine. It talks to user-configured `Endpoint` values of kind `.ollama`
or `.openAICompatible`. `ProviderFactory` picks `OllamaProvider` for `.ollama` (needed for model
listing and one-click `pull`) and `OpenAICompatibleLLMProvider` otherwise. A seeded
"Ollama (local)" endpoint at `http://localhost:11434` is the default. API keys are stored in the
Keychain; `Settings` holds only the account reference.

## Consequences

- The app download stays small and the LLM can be swapped without a new release.
- Refine and Summarize are unavailable until the user has a reachable endpoint; the UI must
  surface `providerUnreachable` with "Start Ollama or choose another endpoint".
- Two streaming formats must be supported: Ollama's NDJSON and OpenAI's SSE with a `[DONE]`
  terminator. Both are parsed by dedicated, unit-tested parsers.
- Users bear the cost and privacy characteristics of whichever endpoint they choose; the app makes
  no network call the user has not configured.
```

- [ ] **Step 2: Write ADR-0002**

Create `docs/DECISIONS/ADR-0002-whisper-cpp-in-process.md`:

```markdown
# ADR-0002: Transcription uses whisper.cpp in-process, with a remote fallback

## Status

Accepted — 2026-08-23

## Context

Dictation must work offline, start instantly, and never send audio anywhere by default. Ollama has
no speech-to-text API, so the "just reuse the LLM endpoint" approach is not available. whisper.cpp
builds as a SwiftPM package with Metal acceleration and runs comfortably in-process on Apple
silicon.

## Decision

`WhisperCppTranscriber` is an actor wrapping `whisper_full`, loading the selected ggml model lazily
and keeping it resident. It is the default `TranscriptionProvider`. Models are downloaded on demand
from `ggerganov/whisper.cpp` into `~/Library/Application Support/Macomprendo/models/` and verified
by SHA-256. Users who prefer a server can instead select an `Endpoint` and
`OpenAICompatibleTranscriber` posts a WAV multipart body to `{baseURL}/v1/audio/transcriptions`.

## Consequences

- The app bundle must carry whisper.cpp's SwiftPM resource bundles (Metal shaders) inside
  `Contents/Resources`; `scripts/build-app.mjs` copies every `*.bundle` emitted next to the
  executable, and DISTRIBUTING.md records which ones those are.
- First-run requires a model download (default `large-v3-turbo`, lightweight alternative `base`).
- The C interop is hardware-bound and therefore thin, isolated behind `TranscriptionProvider`, and
  covered by `docs/SMOKE_TEST.md` rather than unit tests.
- If Ollama ever adds `/v1/audio/transcriptions`, it works through the existing endpoint path with
  no code change.
```

- [ ] **Step 3: Write ADR-0003**

Create `docs/DECISIONS/ADR-0003-not-sandboxed.md`:

```markdown
# ADR-0003: The app is not sandboxed and ships outside the Mac App Store

## Status

Accepted — 2026-08-23

## Context

The four core features need capabilities the App Sandbox does not grant: system-wide hotkeys that
fire while another app is frontmost, reading the focused element's selected text through the
Accessibility API, synthesising ⌘C/⌘V with `CGEvent`, and re-activating an arbitrary application to
paste into it. Apple provides no sandbox entitlement combination that covers AX reading of other
processes plus global event synthesis.

## Decision

Macomprendo is built without App Sandbox, with the hardened runtime enabled, signed with a
Developer ID Application certificate, notarized, stapled, and distributed as a ZIP from GitHub
Releases. It requests Microphone and Accessibility permission explicitly during onboarding and
checks both before each action.

## Consequences

- Mac App Store distribution is off the table for as long as these features exist.
- Release engineering owns signing and notarization; `scripts/notarize-app.mjs` performs the whole
  chain and `spctl --assess` gates the artifact.
- Users must grant Accessibility in System Settings; the app deep-links to the right pane and
  degrades to copy-only with a toast when permission is missing.
- The absence of a sandbox raises the bar on the privacy promises: no telemetry, secrets only in the
  Keychain, and no network call the user has not configured.
```

- [ ] **Step 4: Write ADR-0004**

Create `docs/DECISIONS/ADR-0004-keyboardshortcuts-library.md`:

```markdown
# ADR-0004: Global hotkeys use the KeyboardShortcuts package

## Status

Accepted — 2026-08-23

## Context

Five user-rebindable global hotkeys are needed, one of which (`dictate`) must distinguish key-down
from key-up so hold-to-talk works. Hand-rolling this means Carbon `RegisterEventHotKey`, manual
modifier bookkeeping, a bespoke recorder control, conflict detection against system shortcuts, and
persistence — several hundred lines of fragile, untestable code.

## Decision

Use `sindresorhus/KeyboardShortcuts` (from 2.0.0). `KeyboardShortcutsHotkeyService` adapts it to the
app's `HotkeyServicing` protocol, publishing `HotkeyEvent.keyDown`/`.keyUp` on an `AsyncStream`.
`KeyboardShortcuts.Recorder` is used directly in the Hotkeys settings tab. Defaults: ⌥Space,
⌥⇧Space, ⌥S, ⌥M, and no default for `refineSelection`.

## Consequences

- Recorder UI, conflict handling and `UserDefaults` persistence come for free and stay consistent
  with other Mac apps.
- Hotkey storage lives in the library's own defaults keys, outside `Settings`; `Settings` therefore
  does not model key combinations.
- Controllers depend on `HotkeyServicing`, not the library, so their state machines are unit-tested
  with a fake that pushes synthetic events.
- One more third-party dependency to track; it is MIT-licensed and widely used.
```

- [ ] **Step 5: Write ADR-0005**

Create `docs/DECISIONS/ADR-0005-phosphor-icons.md`:

```markdown
# ADR-0005: Phosphor Icons in-app, SF Symbols for the menubar item

## Status

Accepted — 2026-08-23

## Context

The UI needs a consistent icon set with multiple weights across the Quick Panel, HUD, settings tabs
and onboarding. SF Symbols is the platform default but its licence restricts use to Apple platform
UI and its coverage of the specific glyphs this app wants (waveform states, preset kinds, endpoint
kinds) is uneven. Separately, a menubar status item must supply a *template* image so macOS can tint
it for light, dark and menu-bar-highlight states.

## Decision

Use `phosphor-icons/swift` (MIT, six weights) through a single `UI/Components/Icon.swift` wrapper for
all in-app iconography. Use an SF Symbol template image for the `MenuBarExtra` status item only.

## Consequences

- Icon usage funnels through one wrapper, so weight and size conventions stay consistent and the set
  can be swapped in one place.
- Two icon sources coexist; the rule "SF Symbol only for the status item" must be stated in
  `AGENTS.md` so it is not eroded.
- Phosphor adds a small binary size cost; it is MIT-licensed, so redistribution inside the app is
  unencumbered.
```

- [ ] **Step 6: Write ADR-0006**

Create `docs/DECISIONS/ADR-0006-fixed-quick-panel-position.md`:

```markdown
# ADR-0006: The Quick Panel appears at a fixed top-centre position

## Status

Accepted — 2026-08-23

## Context

The Quick Panel shows dictated/refined text and summaries. It could follow the text caret, follow
the mouse, or sit in a fixed place. Caret-following requires AX bounds that many apps report badly
or not at all; mouse-following makes the panel land somewhere different every time and fights the
user's reading position.

## Decision

The Quick Panel is a non-activating floating `NSPanel`, 680×420, pinned to the top-centre of the
screen that currently contains the mouse. Its frame is remembered per screen in
`Settings.quickPanelFrames`, keyed by screen identifier, so a user who drags it keeps that position.
Esc closes it; it stays open while streaming. The Recording HUD follows the same top-centre rule.

## Consequences

- The panel is where the user already looks, in the same place every time — the behaviour users know
  from MacWhisper and ChatGPT's quick chat.
- No dependence on per-app AX caret geometry, so behaviour is uniform across every application.
- Multi-display users get per-screen memory; the screen identifier must be stable across
  disconnect/reconnect, so `quickPanelFrames` keys are treated as best-effort with a top-centre
  fallback.
- The panel can overlap content the user is reading; Esc and the explicit close button are therefore
  always available and the panel never steals keyboard focus until clicked.
```

- [ ] **Step 7: Verify the ADRs are complete and audit-clean**

Run:

```bash
ls docs/DECISIONS/
grep -L '^## Consequences' docs/DECISIONS/ADR-*.md; echo "exit=$?"
npm run audit
```

Expected: six `ADR-000N-*.md` files; the `grep -L` prints nothing (every file has all four
headings); the audit passes.

- [ ] **Step 8: Commit**

```bash
git add docs/DECISIONS
git commit -m "docs: record ADR-0001..0006 from the design spec"
```

---

### Task 12: Release documentation — DISTRIBUTING, README, CHANGELOG, smoke-test checklist

**Files:**
- Create: `DISTRIBUTING.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/SMOKE_TEST.md`

**Interfaces:**
- Consumes: the exact command names added in Tasks 3–10 and the resource-bundle names discovered in
  Task 4 Step 7. Produces: documentation; `scripts/release.mjs` reads `CHANGELOG.md`, so the
  `## [Unreleased]` section written here is load-bearing.

- [ ] **Step 1: Write `DISTRIBUTING.md`**

Replace `<resource bundle names from Task 4 Step 7>` with the actual `ls` output you recorded.

````markdown
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
- Optional: `gitleaks` (`brew install gitleaks`) so `npm run audit` also scans for secrets.

### A "Developer ID Application" certificate for team 68QJJA7HK9

**This is the one prerequisite that cannot be scripted.** At the time of writing, only an
*Apple Development* certificate is installed on the build Mac; that is enough for local
ad-hoc and development builds but **cannot be notarized**.

To obtain the right certificate:

1. Sign in to <https://developer.apple.com/account> with an account that has the Account
   Holder or Admin role for team `68QJJA7HK9`.
2. Open **Certificates, Identifiers & Profiles → Certificates → +**.
3. Choose **Developer ID Application** (software distributed outside the Mac App Store).
4. When asked for a Certificate Signing Request, create one locally: **Keychain Access →
   Certificate Assistant → Request a Certificate From a Certificate Authority**, enter the
   team email, choose *Saved to disk*, and upload the resulting `.certSigningRequest`.
5. Download the issued `.cer` and double-click it. It must land in the **login** keychain,
   paired with the private key created in step 4.
6. Confirm:

   ```sh
   security find-identity -v -p codesigning
   ```

   The output must contain a line like
   `"Developer ID Application: Denis Zamataev (68QJJA7HK9)"`.

Never commit the `.cer`, the `.p12` export, or the private key. `npm run audit` refuses any
commit that contains them.

## 1. Store notarization credentials

Create an app-specific password at <https://appleid.apple.com> → Sign-In and Security →
App-Specific Passwords. Then:

```sh
NOTARY_APPLE_ID="you@example.com" npm run configure-notary
```

The prompt for the password is echo-muted and the value is piped to `notarytool` on stdin —
it never appears in `ps` output, shell history, or this repository. The credential is stored
in the login Keychain under the profile `macomprendo-notary`.

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

### SPM resource bundles

whisper.cpp ships its Metal shaders as SwiftPM resources. `swift build` emits them as
`*.bundle` directories next to the executable, and the build script copies **every** one of
them into `Contents/Resources`, where SwiftPM's generated `Bundle.module` accessor finds them
via `Bundle.main.resourceURL`.

On this project the emitted bundles are:

```text
<resource bundle names from Task 4 Step 7>
```

Re-check after any whisper.cpp version bump:

```sh
BIN=$(swift build --package-path macos -c release --triple arm64-apple-macosx14.0 --show-bin-path)
ls -d "$BIN"/*.bundle
```

If the list is empty the build warns; a shipped app without these bundles falls back to CPU
inference or fails to load the model.

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

The ZIP is created *after* stapling, so a downloader gets an offline notarization ticket.

Useful flags: `--dry-run` (print the plan), `--sign "<identity>"` (when several Developer ID
identities are installed), `--profile <name>`, `--timeout 30m`.

## 4. Release

```sh
npm run release -- --dry-run patch     # resolve version, validate changelog, print the plan
npm run release -- patch               # the real thing, with a confirmation prompt
npm run release -- 1.0.0 --yes         # explicit version, no prompt
```

The release script:

1. Reads `MARKETING_VERSION` from `macos/project.yml` and resolves the next version.
2. Validates that `CHANGELOG.md` has entries under `## [Unreleased]`.
3. Preflight: clean working tree, branch `main`, `gh` authenticated, `HEAD == origin/main`,
   tag `vX.Y.Z` absent on the remote.
4. Writes the new version into `macos/project.yml`, `macos/Macomprendo.xcodeproj/project.pbxproj`
   and `CHANGELOG.md` (`## [Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD`).
5. Runs `npm run test:scripts`, `swift test --package-path macos`, an unsigned
   `xcodebuild … CODE_SIGNING_ALLOWED=NO build`, and `git diff --check`.
6. Commits `Release X.Y.Z`, tags `vX.Y.Z`, pushes both.
7. Creates the GitHub release with the changelog section as the notes and attaches
   `dist/Macomprendo-X.Y.Z-macos.zip` when it exists.

Run `npm run notarize` **before** `npm run release` if you want the notarized ZIP attached.

## 5. Install locally

```sh
npm run install-app                                   # build + install into /Applications
npm run install-app -- --no-open
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app
```

The installer stages the new bundle inside the destination directory, quits any running copy,
moves the old app to a backup, swaps in the new one, verifies the signature, and restores the
backup if anything fails.

## Before publishing anything

```sh
npm run audit
```

Refuses any tree containing Xcode user state, `.swiftpm`, `.xcuserstate`, archives, dSYMs,
notary logs, `.p8`/`.p12`/`.pem`/`.cer`/`.key`/`.mobileprovision` files, non-example `.env`
files, or a machine-specific `/Users/<name>` path. It also runs `git diff --check` and, when
installed, `gitleaks` over both the working tree and the git history.

## Verification the tooling performs

- Developer ID signing with hardened runtime and a secure timestamp
- Nested SPM resource bundles signed before the enclosing app
- Universal architecture report (`lipo -archs`) after assembly
- Synchronous `notarytool` submission with an explicit `Accepted` check
- Ticket stapling plus `stapler validate`
- `codesign --verify --deep --strict`
- Gatekeeper assessment with `spctl`
- SHA-256 sidecar for the published ZIP

Apple's reference: [Customizing the notarization
workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
````

- [ ] **Step 2: Write the final `README.md`**

Before pasting: run `git remote get-url origin` and use that host/owner/repo in both URLs
below (the draft assumes `github.com/DZamataev/macomprendo`, matching the decision made in
Task 8 Step 7).

````markdown
# Macomprendo

A menubar-only macOS app that turns global hotkeys into dictation, speech, and LLM text
actions. Transcription runs locally with whisper.cpp; refinement and summarization run through
Ollama or any OpenAI-compatible endpoint you configure. No telemetry, no account, no network
call you did not ask for.

Requires macOS 14 or newer. Universal (Apple silicon and Intel). MIT licensed.

## Features

| Action | Default hotkey | What happens |
|---|---|---|
| **Dictate** | ⌥Space | Records while held (or toggles), transcribes locally, pastes into the frontmost app |
| **Dictate & Refine** | ⌥⇧Space | Same capture, then a Quick Panel with the original and an LLM-refined version side by side |
| **Speak selection** | ⌥S | Reads the selected text aloud with a voice you choose; press again to stop |
| **Summarize selection** | ⌥M | Quick Panel with a streamed summary; Copy or Replace the selection |
| **Refine selection** | unassigned | The refine Quick Panel, applied to the current selection |

Other things it does:

- **Local transcription** with whisper.cpp and Metal. Models (`tiny` … `large-v3-turbo`) are
  downloaded on demand, SHA-256 verified, and stored in
  `~/Library/Application Support/Macomprendo/models/`.
- **Remote transcription** through any `/v1/audio/transcriptions` endpoint, if you prefer.
- **Editable prompt presets** for both refine and summarize — Clean up, Formal, Casual,
  Shorten, Expand, Fix grammar, Translate, Brief, Bullets, TL;DR, Key actions — all of which
  you can rename, rewrite, reorder, delete, or add to.
- **Multiple endpoints**: add as many Ollama or OpenAI-compatible providers as you like, test
  the connection from Settings, and pick a different model per feature.

## Install

Download `Macomprendo-<version>-macos.zip` from the
[Releases page](https://github.com/DZamataev/macomprendo/releases), expand it, and drag
`Macomprendo.app` to `/Applications`. The build is signed with a Developer ID certificate and
notarized by Apple, so it opens without a Gatekeeper warning.

Verify the download if you like:

```sh
shasum -a 256 -c Macomprendo-<version>-macos.zip.sha256
```

### Build from source

```sh
git clone https://github.com/DZamataev/macomprendo.git
cd macomprendo
npm ci
npm run install-app
```

`npm run install-app` builds an ad-hoc signed universal app and installs it into
`/Applications`. See [DISTRIBUTING.md](DISTRIBUTING.md) for signed and notarized builds.

## First run

Onboarding asks for what it needs, and nothing else:

1. **Microphone** — required for dictation.
2. **Accessibility** — required to read the selected text and to paste into other apps. macOS
   grants this in System Settings → Privacy & Security → Accessibility; the app deep-links you
   there.
3. **A whisper model** — `large-v3-turbo` is offered by default, `base` if you want something
   small and fast.
4. **Ollama** (optional) — if it is running on `http://localhost:11434` the app finds it and
   offers to pull `qwen2.5:1.5b` for refine and summarize.

All hotkeys are rebindable in Settings → Hotkeys.

## Privacy

- **No telemetry.** The app contains no analytics, crash reporting, or update pinging.
- **Audio never leaves your Mac** unless you explicitly select a remote transcription endpoint.
- **Text never leaves your Mac** unless you use Refine or Summarize, which send it to the
  endpoint you configured — your local Ollama by default.
- **API keys live in the Keychain only.** They are never written to settings, logs, or exports.
- **Transcripts and LLM output are never logged** at the default log level.
- **The clipboard is restored.** Copy/paste simulation snapshots the pasteboard and puts it
  back 300 ms later, guarded by a change-count check so anything you copied meanwhile survives.

See [PRIVACY.md](PRIVACY.md) for the full statement.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — layers, protocols, and how they fit together
- [DISTRIBUTING.md](DISTRIBUTING.md) — signing, notarization, releasing
- [docs/SMOKE_TEST.md](docs/SMOKE_TEST.md) — the manual checklist run before every release
- [docs/DECISIONS/](docs/DECISIONS/) — architecture decision records
- [CHANGELOG.md](CHANGELOG.md)

## License

MIT — see [LICENSE](LICENSE). © 2026 Denis Zamataev.
````

- [ ] **Step 3: Write the `CHANGELOG.md` Unreleased section for 0.1.0**

````markdown
# Changelog

All notable changes to Macomprendo are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menubar-only macOS app (`LSUIElement`) with a `MenuBarExtra` status menu, Settings scene, and
  first-run onboarding.
- Dictate (⌥Space): hold-to-talk or toggle recording, local transcription, automatic paste into
  the frontmost application.
- Dictate & Refine (⌥⇧Space): capture, then a Quick Panel showing the original and a streamed
  LLM-refined version with per-side Copy and Insert.
- Speak selection (⌥S): reads the selected text with a configurable `AVSpeechSynthesisVoice`,
  rate, pitch and volume; press again to stop.
- Summarize selection (⌥M): Quick Panel with a streamed summary, Copy and Replace selection.
- Refine selection (unassigned by default): the refine Quick Panel applied to the selection.
- Local transcription with whisper.cpp and Metal, plus an on-demand model manager for the ggml
  catalog (`tiny` … `large-v3-turbo`) with resumable downloads and SHA-256 verification.
- Remote transcription through any OpenAI-compatible `/v1/audio/transcriptions` endpoint.
- LLM providers: Ollama (`/api/tags`, `/api/chat` NDJSON streaming, `/api/pull`) and any
  OpenAI-compatible endpoint (`/v1/models`, `/v1/chat/completions` SSE streaming).
- Editable prompt presets for refine and summarize, seeded with factory presets and restorable.
- Endpoint management with API keys stored in the Keychain, never in settings or logs.
- Recording HUD with a live level meter, elapsed time, and transient toasts.
- Node release toolchain: `npm run build`, `notarize`, `configure-notary`, `release`, `audit` and
  `install-app`, all unit-tested with `node:test`.
- Documentation: README, DISTRIBUTING, ARCHITECTURE, SMOKE_TEST, PRIVACY, and ADR-0001…0008.

### Security

- Not sandboxed by necessity, but hardened runtime, Developer ID signed, notarized and stapled.
- Pasteboard contents are snapshotted and restored after every simulated ⌘C/⌘V, guarded by a
  change-count check.
- `npm run audit` blocks publication of credentials, Xcode user state, notary logs, and
  machine-specific paths.
````

- [ ] **Step 4: Add the release checklist to `docs/SMOKE_TEST.md`**

Append this section to the existing `docs/SMOKE_TEST.md` (create the file with an
`# Macomprendo Smoke Test` heading first if Plans 3–4 did not):

````markdown
## Release checklist

Run this list on a Mac that has *not* been used to develop the current change, if possible.
Every box must be ticked before `npm run release`.

### Automated gates

- [ ] `npm ci` succeeds from a clean `node_modules`.
- [ ] `npm run test:scripts` — all Node tests pass.
- [ ] `swift test --package-path macos` — all Swift tests pass.
- [ ] `npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj` — the committed Xcode
      project matches `macos/project.yml`.
- [ ] `npm run sync-agents -- --check` — the agent-config symlinks are intact.
- [ ] `npm run audit` — the public repository audit passes.
- [ ] `npm run build -- --dry-run` — the build plan prints without error.
- [ ] `npm run release -- --dry-run patch` — the version resolves and the changelog validates.

### Build artifact

- [ ] `npm run build -- --arch arm64,x86_64` succeeds.
- [ ] `lipo -archs dist/Macomprendo.app/Contents/MacOS/Macomprendo` prints `x86_64 arm64`.
- [ ] `ls dist/Macomprendo.app/Contents/Resources` contains `AppIcon.icns`, `LICENSE`, and every
      whisper SwiftPM resource bundle listed in DISTRIBUTING.md.
- [ ] `codesign --verify --deep --strict --verbose=2 dist/Macomprendo.app` reports the bundle as
      valid on disk and satisfying its designated requirement.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/Macomprendo.app/Contents/Info.plist`
      prints `com.dzamataev.macomprendo`.
- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' …` matches
      `MARKETING_VERSION` in `macos/project.yml`.

### Notarized artifact (requires the Developer ID certificate)

- [ ] `npm run notarize` finishes with `Notarized release: dist/Macomprendo-<version>-macos.zip`.
- [ ] `xcrun stapler validate dist/Macomprendo.app` reports the ticket is valid.
- [ ] `spctl --assess --type execute --verbose=4 dist/Macomprendo.app` prints `accepted` and
      `source=Notarized Developer ID`.
- [ ] `shasum -a 256 -c dist/Macomprendo-<version>-macos.zip.sha256` passes.
- [ ] Expanding the ZIP on a Mac that has never seen the app opens it with no Gatekeeper warning.

> If no Developer ID Application certificate is installed yet, record this whole block as
> **blocked** and ship an ad-hoc build for internal use only. See DISTRIBUTING.md → "A
> Developer ID Application certificate for team 68QJJA7HK9".

### Install and first run

- [ ] `npm run install-app` installs into `/Applications` and relaunches the app.
- [ ] Running it a second time while the app is open quits the running copy and relaunches it.
- [ ] No `.macomprendo-update.*` directory is left behind in the install directory.
- [ ] On a fresh user account, onboarding asks for Microphone, then Accessibility, and the
      System Settings deep links open the correct panes.

### Documentation

- [ ] `CHANGELOG.md` has entries under `## [Unreleased]` describing everything in this release.
- [ ] `README.md` install instructions match the artifact names actually produced.
- [ ] `DISTRIBUTING.md` lists the resource bundle names currently emitted by `swift build`.
````

- [ ] **Step 5: Verify the docs against the tooling**

Run:

```bash
npm run audit
npm run release -- --dry-run patch
```

Expected: the audit passes, and the release dry run now prints
`Release version: 0.1.1` followed by the release notes extracted from the Unreleased section
and the ten planned commands. This is the step that proves Task 8 Step 7 fully.

- [ ] **Step 6: Commit**

```bash
git add DISTRIBUTING.md README.md CHANGELOG.md docs/SMOKE_TEST.md
git commit -m "docs: add the distribution runbook, final README, changelog and release checklist"
```

---

### Task 13: CI gates and the tag-triggered release workflow

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the `audit`, `build`, `test:scripts`, `test:swift`, `gen`, `sync-agents` npm scripts.
- Produces: CI enforcement; no code depends on these files.

**Constraint reminder:** every GitHub Action must be pinned by commit SHA. This plan uses only
`actions/checkout`; Node 20+, `swift`, `xcodebuild` and `gh` are all preinstalled on
`macos-latest` runners, so no `setup-node` or `setup-swift` action is needed.

- [ ] **Step 1: Recover the pinned `actions/checkout` SHA**

Run:

```bash
grep -n 'actions/checkout@' .github/workflows/ci.yml
```

Expected: a line like `uses: actions/checkout@<40-hex> # v4`. Copy that whole `uses:` value —
you will paste it verbatim into `release.yml` in Step 3.

If `ci.yml` has no pinned checkout (Plan 1 deviated), obtain one now:

```bash
gh api repos/actions/checkout/git/ref/tags/v4 --jq .object.sha
```

and write it as `uses: actions/checkout@<sha> # v4` in both workflow files.

- [ ] **Step 2: Add the new gates to `.github/workflows/ci.yml`**

The file already checks out the repo, runs `swift test --package-path macos`, an unsigned
`xcodebuild`, and `npm run test:scripts`. Add the four steps below to the job that has Node
available (the same job that runs `npm run test:scripts`), immediately after the Node test step:

```yaml
      - name: Verify the generated Xcode project is up to date
        run: |
          brew install xcodegen
          npm run gen
          git diff --exit-code macos/Macomprendo.xcodeproj

      - name: Verify agent-config symlinks
        run: npm run sync-agents -- --check

      - name: Audit public repository files
        run: npm run audit

      - name: Verify the app build plan
        run: npm run build -- --arch arm64,x86_64 --dry-run
```

Make sure the job installs dependencies with `npm ci` (not `npm install`) before these steps;
add the step if Plan 1 did not:

```yaml
      - name: Install Node dependencies
        run: npm ci
```

- [ ] **Step 3: Create `.github/workflows/release.yml`**

Replace `<checkout-sha>` with the SHA recovered in Step 1.

```yaml
name: Release

permissions:
  contents: read

on:
  push:
    tags:
      - 'v*'

jobs:
  verify-and-build:
    runs-on: macos-latest

    steps:
      - name: Check out repository
        uses: actions/checkout@<checkout-sha> # v4

      - name: Report toolchain versions
        run: |
          node --version
          npm --version
          swift --version
          xcodebuild -version

      - name: Install Node dependencies
        run: npm ci

      - name: Run Node script tests
        run: npm run test:scripts

      - name: Run Swift package tests
        run: swift test --package-path macos

      - name: Build the app without signing
        run: >-
          xcodebuild
          -project macos/Macomprendo.xcodeproj
          -scheme Macomprendo
          -configuration Release
          -destination 'generic/platform=macOS'
          CODE_SIGNING_ALLOWED=NO
          build

      - name: Audit public repository files
        run: npm run audit

      - name: Build an unsigned universal app bundle
        run: npm run build -- --arch arm64,x86_64

      - name: Report the built artifact
        run: |
          lipo -archs dist/Macomprendo.app/Contents/MacOS/Macomprendo
          /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            dist/Macomprendo.app/Contents/Info.plist
          ls dist/Macomprendo.app/Contents/Resources

      - name: Archive the unsigned build
        run: |
          VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            dist/Macomprendo.app/Contents/Info.plist)
          ditto -c -k --sequesterRsrc --keepParent \
            dist/Macomprendo.app "dist/Macomprendo-${VERSION}-macos-unsigned.zip"
          shasum -a 256 "dist/Macomprendo-${VERSION}-macos-unsigned.zip"

      - name: Upload the unsigned build
        uses: actions/upload-artifact@<upload-artifact-sha> # v4
        with:
          name: macomprendo-unsigned
          path: dist/Macomprendo-*-macos-unsigned.zip
          if-no-files-found: error
          retention-days: 14
```

Get the upload-artifact SHA the same way:

```bash
gh api repos/actions/upload-artifact/git/ref/tags/v4 --jq .object.sha
```

and paste it in place of `<upload-artifact-sha>`.

**This workflow deliberately does not notarize.** Notarization needs an Apple app-specific
password and a Developer ID private key; neither is assumed to exist as a repository secret.
Signed, notarized artifacts are produced locally with `npm run notarize` and attached to the
GitHub release by `npm run release`.

- [ ] **Step 4: Validate the workflow files parse**

Run:

```bash
node -e "import('yaml').then(async ({default: YAML}) => { const fs = await import('node:fs/promises'); for (const f of ['.github/workflows/ci.yml', '.github/workflows/release.yml']) { YAML.parse(await fs.readFile(f, 'utf8')); console.log('ok', f); } })"
grep -n 'uses:' .github/workflows/*.yml
```

Expected: `ok .github/workflows/ci.yml`, `ok .github/workflows/release.yml`, and every `uses:`
line carrying a 40-character hex SHA (no `@v4` floating tags).

- [ ] **Step 5: Confirm the new CI gates pass locally**

Run:

```bash
npm ci
npm run test:scripts
npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj
npm run sync-agents -- --check
npm run audit
npm run build -- --arch arm64,x86_64 --dry-run
```

Expected: every command exits 0. These are exactly the commands CI will run.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit -m "ci: gate on the audit and build plan, add a tag-triggered release build"
```

---

### Task 14: Finalize the release skill and verify end to end

**Files:**
- Modify: `.agents/skills/macomprendo-release/SKILL.md`
- Modify: `package.json` (final review of the `scripts` block)

**Interfaces:**
- Consumes: every npm script and document produced by Tasks 1–13.
- Produces: the operator-facing skill; nothing depends on it programmatically.

- [ ] **Step 1: Confirm the full `scripts` block in `package.json`**

It must contain exactly these entries (order does not matter):

```json
  "scripts": {
    "gen": "xcodegen generate --spec macos/project.yml",
    "test:swift": "swift test --package-path macos",
    "test:scripts": "node --test scripts/__tests__/",
    "sync-agents": "node scripts/sync-agent-config.mjs",
    "build": "node scripts/build-app.mjs",
    "notarize": "node scripts/notarize-app.mjs",
    "configure-notary": "node scripts/configure-notarization.mjs",
    "release": "node scripts/release.mjs",
    "audit": "node scripts/audit-public-repo.mjs",
    "install-app": "node scripts/install-app.mjs",
    "sync-icons": "node scripts/sync-icons.mjs",
    "fetch-model-hashes": "node scripts/fetch-model-hashes.mjs"
  }
```

Run: `node -e "console.log(Object.keys(require('./package.json').scripts).sort().join(' '))"`
Expected: `audit build configure-notary fetch-model-hashes gen install-app notarize release sync-agents sync-icons test:scripts test:swift`

`fetch-model-hashes` comes from Plan 2 and `sync-icons` from Plan 1; this plan only adds
`build`, `notarize`, `configure-notary`, `release`, `audit` and `install-app`.

- [ ] **Step 2: Write the final `.agents/skills/macomprendo-release/SKILL.md`**

Remember that `.claude/skills` is a symlink to `.agents/skills`, so this single file serves both
agents. Replace the file's contents with:

````markdown
---
name: macomprendo-release
description: Use when building, signing, notarizing, installing, or publishing a Macomprendo release, or when a release command fails
---

# Macomprendo Release

Every release action is an npm script backed by a Node ES module in `scripts/`. There are no
shell scripts. Full prose runbook: `DISTRIBUTING.md`. Manual checklist: `docs/SMOKE_TEST.md`.

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

npm run install-app                                # build + atomic install into /Applications
npm run install-app -- --no-open
MACOS_INSTALL_DIR="$HOME/Applications" npm run install-app

npm run audit                                      # refuse to publish secrets / machine paths
npm run release -- --dry-run patch                 # resolve version, validate changelog, print plan
npm run release -- patch                           # real release, with confirmation
npm run release -- 1.0.0 --yes                     # explicit version, no prompt

npm run fetch-model-hashes                         # (from Plan 2) refresh whisper model SHA-256 digests
```

## Order of operations for a real release

1. Write the entries under `## [Unreleased]` in `CHANGELOG.md`. The release refuses to run
   without them.
2. `npm run audit`
3. `npm run release -- --dry-run patch` — check the version and the notes.
4. `npm run notarize` — produces `dist/Macomprendo-<version>-macos.zip`. Skip only if you
   accept a release with no attached binary.
5. Work through the release checklist in `docs/SMOKE_TEST.md`.
6. `npm run release -- patch` — bumps, tests, commits `Release X.Y.Z`, tags `vX.Y.Z`, pushes,
   and creates the GitHub release with the changelog section as notes plus the ZIP.

## Facts that trip people up

- Version source of truth is `MARKETING_VERSION` in `macos/project.yml`. The release script
  mirrors it into `macos/Macomprendo.xcodeproj/project.pbxproj`. Never edit the pbxproj by hand
  — run `npm run gen` after changing `project.yml`.
- Git tags are `vX.Y.Z`; changelog headings are `## [X.Y.Z] - YYYY-MM-DD`.
- Bundle id `com.dzamataev.macomprendo`, team `68QJJA7HK9`, notary profile `macomprendo-notary`.
- Ad-hoc (`--sign -`) is the default and is fine locally. Notarization needs a **Developer ID
  Application** certificate; an *Apple Development* certificate cannot be notarized.
- The build copies every `*.bundle` SwiftPM emits next to the executable into
  `Contents/Resources` — that is where whisper's Metal shaders live. If the build warns "No
  SwiftPM resource bundles found", stop and fix it before shipping.
- CI never notarizes: no Apple secrets are assumed to exist in the repository.

## When something fails

| Symptom | Fix |
|---|---|
| `No "Developer ID Application" certificate…` | Follow DISTRIBUTING.md → prerequisites; check `security find-identity -v -p codesigning` |
| `Could not authenticate with notarytool` | Re-run `npm run configure-notary` |
| Notarization not `Accepted` | Read `dist/notary-log-<id>.json`; it names the offending binary and reason |
| `The working tree is not clean` | Commit or stash, then retry the release |
| `Tag vX.Y.Z already exists on the remote` | Choose a higher version, or delete the tag if it was a mistake |
| `no entries under "## [Unreleased]"` | Write the release notes in `CHANGELOG.md` first |
| `macos/…/project.pbxproj declares MARKETING_VERSION …` | Run `npm run gen` and commit the regenerated project |
| Audit flags a `/Users/<name>` path | Replace it with `~/`, `<repo>`, or `/Users/test` |
````

- [ ] **Step 3: Verify the skill symlink still resolves**

Run:

```bash
npm run sync-agents -- --check
ls -l .claude/skills
cat .claude/skills/macomprendo-release/SKILL.md | head -5
```

Expected: the check passes, `.claude/skills` is a symlink to `../.agents/skills`, and the
front matter prints.

- [ ] **Step 4: Run the whole verification suite**

Run each command and confirm the expected result:

```bash
npm ci                                      # clean install succeeds
npm run test:scripts                        # all Node tests pass, # fail 0
npm run test:swift                          # all Swift tests pass
npm run audit                               # "Public repository audit passed."
npm run build -- --dry-run                  # prints the plan, exit 0
npm run build -- --arch arm64,x86_64        # builds dist/Macomprendo.app
lipo -archs dist/Macomprendo.app/Contents/MacOS/Macomprendo   # "x86_64 arm64"
npm run notarize -- --dry-run --sign "Developer ID Application: Denis Zamataev (68QJJA7HK9)"
npm run release -- --dry-run patch          # THE FINAL DELIVERABLE
git status --porcelain                      # empty: nothing was mutated
```

Expected for the final deliverable, `npm run release -- --dry-run patch`:

```text
Current version: 0.1.0
Release version: 0.1.1
Changelog heading: ## [0.1.1] - <today>
Release notes:
### Added
- Menubar-only macOS app …
…
Planned commands:
  npm run test:scripts
  swift test --package-path macos
  xcodebuild -project macos/Macomprendo.xcodeproj -scheme Macomprendo -configuration Release …
  git diff --check
  git add macos/project.yml macos/Macomprendo.xcodeproj/project.pbxproj CHANGELOG.md
  git commit -m Release 0.1.1
  git tag -a v0.1.1 -m Macomprendo 0.1.1
  git push origin main
  git push origin v0.1.1
  gh release create v0.1.1 --target main --title Macomprendo 0.1.1 --notes-file …/dist/release-notes-0.1.1.md --latest
Dry run complete; no files, tags or remote state changed.
```

and `git status --porcelain` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add .agents/skills/macomprendo-release/SKILL.md package.json
git commit -m "docs(skills): finalize the release skill with the exact commands"
```

---

## Verification summary

After Task 14 every one of these must hold:

| Check | Command | Expected |
|---|---|---|
| Node tests | `npm run test:scripts` | `# fail 0` |
| Swift tests | `npm run test:swift` | all pass |
| Public audit | `npm run audit` | `Public repository audit passed.` |
| Build plan | `npm run build -- --dry-run` | exit 0, plan printed |
| Universal build | `npm run build -- --arch arm64,x86_64` | `dist/Macomprendo.app`, `lipo -archs` = `x86_64 arm64` |
| Notarize plan | `npm run notarize -- --dry-run --sign "<Developer ID>"` | exit 0, 13-step plan |
| **Release dry run** | `npm run release -- --dry-run patch` | exit 0, plan printed, working tree untouched |
| Xcode project fresh | `npm run gen && git diff --exit-code macos/Macomprendo.xcodeproj` | no diff |
| Agent symlinks | `npm run sync-agents -- --check` | passes |

Manual (documented in `docs/SMOKE_TEST.md`, not automatable here): the SPM resource-bundle
discovery in Task 4 Step 7, the real app launch in Task 4 Step 8, the notarization credential
setup in Task 5 Step 6, and the `/Applications` install in Task 10 Step 7.
