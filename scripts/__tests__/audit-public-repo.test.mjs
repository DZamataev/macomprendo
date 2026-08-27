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

// --- Carried-forward requirement: every `{ check: false }` call site must distinguish a
// signal-killed child from a clean non-zero exit. `hasGitleaks` is the only such site here
// (`which gitleaks` with `check: false`). Per scripts/lib/run.mjs, a signal-killed child
// under check:false does NOT throw — it resolves with `code: null, signal: 'SIGKILL'` and
// (normally) empty stdout. This reproduces that exact shape, not a friendlier fake.
test('main treats a signal-killed "which gitleaks" as not-installed rather than crashing', async () => {
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
  assert.equal(code, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Gitleaks is not installed')));
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
