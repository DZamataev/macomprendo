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

// `.keychain-db` has been the actual default macOS keychain format since Sierra, and is the
// standard name CI scripts give a temporary signing keychain — the `.keychain$` anchor alone
// misses it entirely.
test('findUnsafePaths rejects both .keychain and .keychain-db spellings', () => {
  const flagged = findUnsafePaths(['login.keychain', 'build.keychain-db']).map((hit) => hit.path);
  assert.deepEqual(flagged, ['login.keychain', 'build.keychain-db']);
});

// The classifier must be at least as defensive as shouldScanContent, which already
// lowercases before comparing extensions.
test('findUnsafePaths rejects secret filenames regardless of case', () => {
  const flagged = findUnsafePaths([
    'secrets/cert.P12',
    'secrets/key.PEM',
    'profiles/dev.MOBILEPROVISION',
  ]).map((hit) => hit.path);
  assert.deepEqual(flagged, ['secrets/cert.P12', 'secrets/key.PEM', 'profiles/dev.MOBILEPROVISION']);
});

// ssh-keygen's default names carry no extension at all.
test('findUnsafePaths rejects extension-less SSH private keys', () => {
  const flagged = findUnsafePaths([
    'id_rsa',
    '.ssh/id_ed25519',
    'keys/id_dsa',
    'backup/id_ecdsa',
  ]).map((hit) => hit.path);
  assert.deepEqual(flagged, ['id_rsa', '.ssh/id_ed25519', 'keys/id_dsa', 'backup/id_ecdsa']);
  // A filename that merely starts with "id_" but isn't one of the four algorithms must
  // not be flagged.
  assert.deepEqual(findUnsafePaths(['id_rsa.pub', 'scripts/id_notes.md']), []);
});

test('findUnsafePaths allows the ordinary repository contents', () => {
  assert.deepEqual(findUnsafePaths([
    'README.md',
    '.env.example',
    'macos/Sources/Macomprendo/Resources/Icons/microphone.svg',
    'macos/Packages/WhisperBinary/Package.swift',
    'macos/project.yml',
    'macos/Macomprendo.xcodeproj/project.pbxproj',
    'macos/Sources/Macomprendo/Core/KeychainStore.swift',
    'scripts/lib/keychain-notes.md',
    'docs/DECISIONS/ADR-0003-not-sandboxed.md',
  ]), []);
});

test('shouldScanContent skips assets and the audit files themselves', () => {
  assert.equal(shouldScanContent('README.md'), true);
  assert.equal(shouldScanContent('macos/Sources/Macomprendo/App/AppModel.swift'), true);
  assert.equal(shouldScanContent('macos/AppBundle/AppIcon.icns'), false);
  assert.equal(shouldScanContent('docs/images/panel.png'), false);
  // Vendored Phosphor icons (ADR-0008) are third-party assets, not our source.
  assert.equal(shouldScanContent('macos/Sources/Macomprendo/Resources/Icons/microphone.svg'), false);
  assert.equal(shouldScanContent('scripts/audit-public-repo.mjs'), false);
  assert.equal(shouldScanContent('scripts/__tests__/audit-public-repo.test.mjs'), false);
});

// The `.svg` skip is scoped to the vendored icons directory, not the format: a design-tool
// SVG export elsewhere in the repo routinely embeds an absolute path in generator metadata
// and must still be scanned.
test('shouldScanContent scans SVGs outside the vendored icons directory', () => {
  assert.equal(shouldScanContent('docs/images/exported-icon.svg'), true);
  assert.equal(shouldScanContent('macos/Sources/Macomprendo/Resources/Icons/microphone.svg'), false);
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

// `failLines` lets a test make one specific command fail the way scripts/lib/run.mjs's
// real `check: true` (the default) fails a non-zero exit: it rejects with a plain
// `Error(message)` — no custom properties — which is exactly what `main`'s outer
// try/catch is written to handle for `git diff --check` and the Gitleaks calls.
function auditDeps({ files, contents = {}, gitleaks = true, failLines = {} }) {
  const table = {
    'git ls-files --cached --others --exclude-standard': { stdout: files.join('\n') },
    'git diff --check': { stdout: '' },
  };
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (failLines[line] !== undefined) throw new Error(failLines[line]);
    if (line === 'command -v gitleaks' || (cmd === 'which' && args[0] === 'gitleaks')) {
      return { stdout: gitleaks ? '/usr/local/bin/gitleaks' : '', stderr: '', code: gitleaks ? 0 : 1 };
    }
    const hit = table[line];
    if (hit?.throws) throw new Error(hit.throws);
    return { stdout: hit?.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  const stageCalls = [];
  let cleaned = false;
  const stageCandidateFiles = async (candidateFiles) => {
    stageCalls.push([...candidateFiles]);
    return {
      root: '/tmp/macomprendo-gitleaks-candidates',
      cleanup: async () => { cleaned = true; },
    };
  };
  stageCandidateFiles.calls = stageCalls;
  stageCandidateFiles.wasCleaned = () => cleaned;
  // root: '' makes the implementation's path.join(root, file) return the bare relative
  // path, which is exactly how makeFakeIO is keyed.
  return {
    run,
    io: makeFakeIO(contents),
    log: makeFakeLog(),
    root: '',
    stageCandidateFiles,
  };
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

test('main scans only the candidate-file snapshot and cleans it up', async () => {
  const deps = auditDeps({
    files: ['README.md', 'Sources/App.swift'],
    contents: { 'README.md': 'x', 'Sources/App.swift': 'print("x")' },
    gitleaks: true,
  });

  const code = await main([], deps);

  assert.equal(code, 0);
  assert.deepEqual(deps.stageCandidateFiles.calls, [['README.md', 'Sources/App.swift']]);
  const workingTreeScan = deps.run.calls.find(
    ({ line }) => line === 'gitleaks detect --source . --no-git --redact --no-banner',
  );
  assert.equal(workingTreeScan.options.cwd, '/tmp/macomprendo-gitleaks-candidates');
  assert.equal(deps.stageCandidateFiles.wasCleaned(), true);
});

test('main refuses publication when gitleaks is unavailable', async () => {
  const deps = auditDeps({
    files: ['README.md'],
    contents: { 'README.md': 'x' },
    gitleaks: false,
  });
  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('Gitleaks is required')));
  assert.ok(!deps.log.lines.some((l) => l.includes('Public repository audit passed')));
});

test('main fails when git diff --check finds trailing whitespace or a conflict marker', async () => {
  const deps = auditDeps({
    files: ['README.md'],
    contents: { 'README.md': 'x' },
    failLines: { 'git diff --check': 'git diff --check exited with 2\nREADME.md:1: trailing whitespace.' },
  });
  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('trailing whitespace')));
  // Gitleaks must never run once the whitespace check has already failed the audit.
  assert.equal(deps.run.lines().some((l) => l.startsWith('gitleaks')), false);
});

test('main fails when Gitleaks finds a secret in the working tree', async () => {
  const deps = auditDeps({
    files: ['README.md'],
    contents: { 'README.md': 'x' },
    gitleaks: true,
    failLines: {
      'gitleaks detect --source . --no-git --redact --no-banner':
        'gitleaks detect --source . --no-git --redact --no-banner exited with 1',
    },
  });
  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('gitleaks detect --source . --no-git')));
  // The history scan must never run once the working-tree scan has already failed.
  assert.equal(
    deps.run.lines().some((l) => l === 'gitleaks detect --source . --redact --no-banner'),
    false,
  );
  assert.equal(deps.stageCandidateFiles.wasCleaned(), true);
});

// Distinguishing ENOENT (fine to skip — the file vanished mid-run) from every other read
// failure (permission denied, I/O error, ...) is the fail-closed property that matters
// most for this specific loop: silently skipping any other failure would let an unreadable
// file sail through the audit undetected.
test('main refuses publication when a tracked file cannot be read for a reason other than ENOENT', async () => {
  const files = ['README.md', 'docs/locked.md'];
  const table = {
    'git ls-files --cached --others --exclude-standard': { stdout: files.join('\n') },
    'git diff --check': { stdout: '' },
  };
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (cmd === 'which' && args[0] === 'gitleaks') return { stdout: '', stderr: '', code: 1 };
    const hit = table[line];
    return { stdout: hit?.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  const io = {
    async readFile(p) {
      if (p.endsWith('docs/locked.md')) {
        throw Object.assign(new Error('EACCES: permission denied, open \'docs/locked.md\''), { code: 'EACCES' });
      }
      return 'x';
    },
  };
  const log = makeFakeLog();

  const code = await main([], { run, io, log, root: '' });
  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => l.includes('docs/locked.md') && l.includes('EACCES')));
  assert.ok(!log.lines.some((l) => l.includes('Public repository audit passed')));
});

// A file that vanished mid-run (ENOENT) is not a finding — there is nothing left to scan —
// and must not fail the audit on its own.
test('main tolerates a tracked file that vanished (ENOENT) between listing and reading', async () => {
  const deps = auditDeps({
    files: ['README.md', 'docs/deleted-mid-run.md'],
    contents: { 'README.md': 'x' },
  });
  const code = await main([], deps);
  assert.equal(code, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Public repository audit passed')));
});

// A git-tracked symlink to a directory (e.g. `.claude/skills -> ../.agents/skills`, see
// AGENTS.md) makes `fs.readFile` follow the link and hit EISDIR. That must not fail the
// audit: the real files under the target are tracked and scanned at their own paths.
test('main tolerates EISDIR from a tracked symlink whose target is a directory', async () => {
  const files = ['README.md', '.claude/skills'];
  const table = {
    'git ls-files --cached --others --exclude-standard': { stdout: files.join('\n') },
    'git diff --check': { stdout: '' },
  };
  const run = async (cmd, args = []) => {
    const line = [cmd, ...args].join(' ');
    if (cmd === 'which' && args[0] === 'gitleaks') {
      return { stdout: '/usr/local/bin/gitleaks', stderr: '', code: 0 };
    }
    const hit = table[line];
    return { stdout: hit?.stdout ?? '', stderr: '', code: 0 };
  };
  const io = {
    async readFile(p) {
      if (p.endsWith('.claude/skills')) {
        throw Object.assign(new Error('EISDIR: illegal operation on a directory, read'), { code: 'EISDIR' });
      }
      return 'x';
    },
  };
  const log = makeFakeLog();
  const stageCandidateFiles = async () => ({ root: '/tmp/gitleaks', cleanup: async () => {} });

  const code = await main([], {
    run, io, log, root: '', stageCandidateFiles,
  });
  assert.equal(code, 0);
  assert.ok(log.lines.some((l) => l.includes('Public repository audit passed')));
});

// --- Carried-forward requirement: every `{ check: false }` call site must distinguish a
// signal-killed child from a clean non-zero exit. `hasGitleaks` is the only such site here
// (`which gitleaks` with `check: false`). Per scripts/lib/run.mjs, a signal-killed child
// under check:false does NOT throw — it resolves with `code: null, signal: 'SIGKILL'` and
// (normally) empty stdout — indistinguishable from "gitleaks is not installed" unless the
// caller checks explicitly. Treating it as a confirmed negative would report a passing
// audit despite never having actually asked whether Gitleaks is installed. This reproduces
// that exact shape, not a friendlier fake, and asserts the audit fails closed instead.
test('main fails closed when "which gitleaks" is signal-killed, rather than reporting a clean audit', async () => {
  const files = ['README.md'];
  const contents = { 'README.md': 'x' };
  const table = {
    'git ls-files --cached --others --exclude-standard': { stdout: files.join('\n') },
    'git diff --check': { stdout: '' },
  };
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (cmd === 'which' && args[0] === 'gitleaks') {
      assert.equal(options.check, false, 'the which-gitleaks probe must pass check: false');
      // Real run.mjs behavior for a signal-killed child under check:false: resolves,
      // does not throw, code is null and signal is set, stdout/stderr are whatever the
      // child managed to flush before it died (here: nothing).
      return { stdout: '', stderr: '', code: null, signal: 'SIGKILL' };
    }
    const hit = table[line];
    return { stdout: hit?.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  const deps = { run, io: makeFakeIO(contents), log: makeFakeLog(), root: '' };

  const code = await main([], deps);
  assert.equal(code, 1);
  assert.ok(deps.log.lines.some((l) => l.includes('SIGKILL')),
    'the failure must name the signal that killed the probe');
  assert.equal(deps.log.lines.some((l) => l.includes('Gitleaks is not installed')), false,
    'a signal-killed probe must never be reported as a confirmed "not installed"');
  assert.equal(deps.log.lines.some((l) => l.includes('Public repository audit passed')), false);
  assert.equal(deps.run.lines().some((l) => l.startsWith('gitleaks detect')), false);
});

// The git ls-files call itself keeps the default check:true, precisely so a signal-killed
// listing cannot be mistaken for "the repository has no files" (which would report a clean
// audit). This test uses makeFakeRun's real throw-on-check-true semantics to prove it.
test('main fails closed when "git ls-files" is signal-killed rather than reporting a clean repo', async () => {
  const run = makeFakeRun([
    { throws: 'git ls-files --cached --others --exclude-standard was killed with SIGTERM' },
  ]);
  const log = makeFakeLog();
  const code = await main([], { run, io: makeFakeIO({}), log, root: '' });
  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => l.includes('was killed with SIGTERM')));
  assert.ok(!log.lines.some((l) => l.includes('Public repository audit passed')));
});
