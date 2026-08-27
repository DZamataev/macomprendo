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

test('preflight refuses a signal-killed git status', async () => {
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (line === 'git status --porcelain') {
      throw new Error('git status --porcelain was killed with SIGKILL');
    }
    const table = {
      'git rev-parse --show-toplevel': { stdout: '/repo' },
      'git branch --show-current': { stdout: 'main' },
      'gh auth status': { stdout: 'Logged in' },
    };
    const hit = table[line];
    if (hit === undefined) return { stdout: '', stderr: '', code: 0 };
    return { stdout: hit.stdout ?? '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);
  await assert.rejects(preflight('1.2.4', { run, log: makeFakeLog(), root: '/repo' }),
    /was killed with SIGKILL/);
});

test('preflight distinguishes gh missing from gh auth failures', async () => {
  const runEnoent = preflightRun({ 'gh auth status': { throws: 'spawn ENOENT' } });
  await assert.rejects(preflight('1.2.4', { run: runEnoent, log: makeFakeLog(), root: '/repo' }),
    /gh is not installed/);

  const runAuthFail = preflightRun({ 'gh auth status': { throws: 'gh: not logged in' } });
  await assert.rejects(preflight('1.2.4', { run: runAuthFail, log: makeFakeLog(), root: '/repo' }),
    /gh is not authenticated; run: gh auth login/);

  const runOtherError = preflightRun({ 'gh auth status': { throws: 'network error' } });
  await assert.rejects(preflight('1.2.4', { run: runOtherError, log: makeFakeLog(), root: '/repo' }),
    /network error/);
});

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

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  const lines = run.lines();
  assert.ok(lines.indexOf('git status --porcelain') < lines.indexOf('npm run test:scripts'));
  assert.ok(lines.indexOf('npm run test:scripts') < lines.indexOf('git commit -m Release 0.1.1'));
  assert.ok(lines.indexOf('git tag -a v0.1.1 -m Macomprendo 0.1.1') < lines.indexOf('git push origin main'));
  assert.ok(lines.some((l) => l.startsWith('gh release create v0.1.1')));
  assert.deepEqual(io.writes.slice(0, 3), [PROJECT_YML, PBXPROJ, CHANGELOG_PATH]);
});

// Not from the brief: pins the "no half-released repo silently reported as success"
// requirement — a gate step (npm run test:scripts) fails after prepareFiles has already
// rewritten the tracked files, so the repository is left with local modifications but no
// commit, tag, push or GitHub release. main() must surface that failure (non-zero exit,
// the failing command's own message) rather than continuing or reporting success.
test('main reports the failure and stops before any commit/push/publish when a gate fails', async () => {
  const io = releaseIO();
  const run = preflightRun({
    'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' },
    'npm run test:scripts': { throws: 'npm run test:scripts exited with 1\nFAIL some.test.mjs' },
  });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 1);
  const lines = run.lines();
  assert.ok(lines.includes('npm run test:scripts'));
  assert.ok(!lines.some((l) => l.startsWith('git commit')));
  assert.ok(!lines.some((l) => l.startsWith('git push')));
  assert.ok(!lines.some((l) => l.startsWith('gh release create')));
  // The version-bearing files were already rewritten locally before the gate ran —
  // that is the state the operator must be told about.
  assert.deepEqual(io.writes.slice(0, 3), [PROJECT_YML, PBXPROJ, CHANGELOG_PATH]);
  assert.ok(log.lines.some((l) => l.includes('npm run test:scripts exited with 1')));
});

test('main aborts before writing anything when preflight fails', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git status --porcelain': { stdout: ' M README.md' } });
  const log = makeFakeLog();

  const code = await main(['--yes'], { run, log, io, root: '/repo', now: () => new Date('2026-08-23') });

  assert.equal(code, 1);
  assert.deepEqual(io.writes, []);
  assert.ok(log.lines.some((l) => l.includes('working tree is not clean')));
});
