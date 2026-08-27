import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';

import {
  PROJECT_YML_VERSION, PBXPROJ_VERSION,
  resolveVersion, replaceProjectYmlVersion, replacePbxprojVersions,
  assertProjectYmlParses, preflight,
  parseReleaseArgs, prepareFiles, planRelease, describeReleaseState, confirm, main,
} from '../release.mjs';
import { makeFakeRun, makeFakeLog, makeFakeIO, makeFakeFsOps } from './helpers/fake-run.mjs';
import { PROJECT_YML, PBXPROJ, CHANGELOG_PATH } from '../lib/paths.mjs';

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

test('parseReleaseArgs defaults to a patch release, notes-only, with confirmation', () => {
  assert.deepEqual(parseReleaseArgs([]),
    { requested: 'patch', dryRun: false, yes: false, help: false, notarize: false });
  assert.deepEqual(parseReleaseArgs(['minor', '--yes']),
    { requested: 'minor', dryRun: false, yes: true, help: false, notarize: false });
  assert.deepEqual(parseReleaseArgs(['--dry-run', '1.5.0']),
    { requested: '1.5.0', dryRun: true, yes: false, help: false, notarize: false });
  assert.deepEqual(parseReleaseArgs(['--notarize', '--yes']),
    { requested: 'patch', dryRun: false, yes: true, help: false, notarize: true });
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
    'git commit -m chore(release): 0.2.0',
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

test('planRelease omits the notarize step and any asset by default', () => {
  const lines = planRelease({ version: '0.2.0', notesPath: '/out/notes.md', assets: [] })
    .map((s) => [s.cmd, ...s.args].join(' '));
  assert.equal(lines.includes('node scripts/notarize-app.mjs'), false);
  assert.ok(lines.at(-1).endsWith('--latest'));
});

test('planRelease inserts the notarize step between the build gates and the commit', () => {
  const lines = planRelease({
    version: '0.2.0', notesPath: '/out/notes.md', assets: ['/out/Macomprendo-0.2.0-macos.zip'], notarize: true,
  }).map((s) => [s.cmd, ...s.args].join(' '));
  const notarizeIndex = lines.indexOf('node scripts/notarize-app.mjs');
  const diffCheckIndex = lines.indexOf('git diff --check');
  const commitIndex = lines.findIndex((l) => l.startsWith('git commit'));
  assert.ok(notarizeIndex !== -1);
  assert.ok(diffCheckIndex < notarizeIndex);
  assert.ok(notarizeIndex < commitIndex);
  assert.ok(lines.at(-1).endsWith('/out/Macomprendo-0.2.0-macos.zip'));
});

test('describeReleaseState marks nothing done and gives no undo command before anything happened', () => {
  const block = describeReleaseState({
    version: '0.2.0',
    filesRewritten: false, commitCreated: false, mainPushed: false,
    tagCreated: false, tagPushed: false, released: false,
  });
  assert.ok(block.startsWith('Release state after the failure:'));
  assert.ok(block.includes('[ ] Version files rewritten'));
  assert.ok(block.includes('[ ] Commit created'));
  assert.ok(block.includes('[ ] Commit pushed to origin/main'));
  assert.ok(block.includes('[ ] Tag created locally'));
  assert.ok(block.includes('[ ] Tag pushed to origin'));
  assert.ok(block.includes('[ ] GitHub release published'));
  assert.equal(block.includes('undo:'), false);
});

test('describeReleaseState prints the undo command for each step already completed', () => {
  const block = describeReleaseState({
    version: '0.2.0',
    filesRewritten: true, commitCreated: true, mainPushed: true,
    tagCreated: true, tagPushed: false, released: false,
  });
  assert.ok(block.includes('[x] Version files rewritten')
    && block.includes('undo: git checkout -- macos/project.yml macos/Macomprendo.xcodeproj/project.pbxproj CHANGELOG.md'));
  assert.ok(block.includes('[x] Commit created (chore(release): 0.2.0)') && block.includes('undo: git reset --hard HEAD~1'));
  assert.ok(block.includes('[x] Commit pushed to origin/main'));
  assert.ok(block.includes('[x] Tag created locally (v0.2.0)') && block.includes('undo: git tag -d v0.2.0'));
  assert.ok(block.includes('[ ] Tag pushed to origin (v0.2.0)'));
  assert.equal(block.includes('undo: git push origin :refs/tags/v0.2.0'), false);
  assert.ok(block.includes('[ ] GitHub release published (v0.2.0)'));
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
  assert.ok(printed.includes('publish release notes only'));
  assert.ok(!printed.includes('node scripts/notarize-app.mjs'));
  assert.ok(printed.includes('gh release create v0.1.1'));
});

test('main --dry-run --notarize prints the notarize step and states the ZIP will be attached', async () => {
  const io = releaseIO();
  const log = makeFakeLog();

  const code = await main(['--dry-run', '--notarize', 'patch'],
    { run: makeFakeRun(), log, io, now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  const printed = log.lines.join('\n');
  assert.ok(printed.includes('notarized build will be built fresh and attached'));
  assert.ok(printed.includes('node scripts/notarize-app.mjs'));
  assert.ok(printed.includes('Macomprendo-0.1.1-macos.zip'));
});

test('main --dry-run fails when the Unreleased section is empty', async () => {
  const io = releaseIO();
  await io.writeFile(CHANGELOG_PATH, '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n');
  const log = makeFakeLog();

  const code = await main(['--dry-run'], { run: makeFakeRun(), log, io, now: () => new Date('2026-08-23') });

  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => l.includes('no entries under "## [Unreleased]"')));
});

test('main --yes performs the whole release in order, notes-only, with no notarize step', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' } });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', fsOps: makeFakeFsOps(), now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  const lines = run.lines();
  assert.ok(lines.indexOf('git status --porcelain') < lines.indexOf('npm run test:scripts'));
  assert.ok(lines.indexOf('npm run test:scripts') < lines.indexOf('git commit -m chore(release): 0.1.1'));
  assert.ok(lines.indexOf('git tag -a v0.1.1 -m Macomprendo 0.1.1') < lines.indexOf('git push origin main'));
  assert.ok(lines.some((l) => l.startsWith('gh release create v0.1.1') && l.endsWith('--latest')));
  assert.equal(lines.includes('node scripts/notarize-app.mjs'), false);
  assert.deepEqual(io.writes.slice(0, 3), [PROJECT_YML, PBXPROJ, CHANGELOG_PATH]);
  assert.ok(log.lines.some((l) => l.includes('publish release notes only')));
  assert.ok(log.lines.some((l) => l.includes('Published 0.1.1:')));
});

test('main --yes --notarize runs notarize before the commit and attaches the ZIP to the release', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' } });
  const log = makeFakeLog();

  const code = await main(['--yes', '--notarize', 'patch'],
    { run, log, io, root: '/repo', fsOps: makeFakeFsOps(), now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  const lines = run.lines();
  assert.ok(lines.indexOf('node scripts/notarize-app.mjs') < lines.indexOf('git commit -m chore(release): 0.1.1'));
  assert.ok(lines.some((l) => l.startsWith('gh release create v0.1.1') && l.includes('Macomprendo-0.1.1-macos.zip')));
  assert.ok(log.lines.some((l) => l.includes('notarized build will be built fresh and attached')));
});

// Pins the "no half-released repo silently reported as success" requirement at the
// earliest possible failure index — a gate step (npm run test:scripts) fails right
// after prepareFiles has already rewritten the tracked files, so the repository is
// left with local modifications but no commit, tag, push or GitHub release. main()
// must surface that failure (non-zero exit, the failing command's own message, and a
// concrete state block) rather than continuing or reporting success.
test('main reports the failure and stops before any commit/push/publish when the first gate fails', async () => {
  const io = releaseIO();
  const run = preflightRun({
    'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' },
    'npm run test:scripts': { throws: 'npm run test:scripts exited with 1\nFAIL some.test.mjs' },
  });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', fsOps: makeFakeFsOps(), now: () => new Date('2026-08-23T10:00:00Z') });

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
  const state = log.lines.find((l) => l.includes('Release state after the failure:'));
  assert.ok(state, 'expected a state block to be logged');
  assert.ok(state.includes('[x] Version files rewritten'));
  assert.ok(state.includes('[ ] Commit created'));
  assert.ok(state.includes('[ ] Commit pushed to origin/main'));
  assert.ok(state.includes('[ ] Tag created locally'));
  assert.ok(state.includes('[ ] Tag pushed to origin'));
  assert.ok(state.includes('[ ] GitHub release published'));
});

// Same requirement, a much later failure index — the tag push is rejected after the
// commit, the tag, and the push of main have all already happened. The operator needs
// to see precisely that (main is now public; the tag is only local) and how to undo it.
test('main reports commit, tag and main-push as already done when the tag push fails', async () => {
  const io = releaseIO();
  const run = preflightRun({
    'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' },
    'git push origin v0.1.1': { throws: 'git push origin v0.1.1 exited with 1\n! [rejected]' },
  });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', fsOps: makeFakeFsOps(), now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 1);
  const lines = run.lines();
  assert.ok(lines.includes('git commit -m chore(release): 0.1.1'));
  assert.ok(lines.includes('git push origin main'));
  assert.ok(lines.includes('git tag -a v0.1.1 -m Macomprendo 0.1.1'));
  assert.ok(!lines.some((l) => l.startsWith('gh release create')));
  const state = log.lines.find((l) => l.includes('Release state after the failure:'));
  assert.ok(state, 'expected a state block to be logged');
  assert.ok(state.includes('[x] Version files rewritten'));
  assert.ok(state.includes('[x] Commit created (chore(release): 0.1.1)') && state.includes('git reset --hard HEAD~1'));
  assert.ok(state.includes('[x] Commit pushed to origin/main'));
  assert.ok(state.includes('[x] Tag created locally (v0.1.1)') && state.includes('git tag -d v0.1.1'));
  // The tag push itself failed, so it is reported as not done — and, consistent with
  // describeReleaseState's own contract, an incomplete step gets no undo command.
  assert.ok(state.includes('[ ] Tag pushed to origin (v0.1.1)'));
  assert.ok(state.includes('[ ] GitHub release published (v0.1.1)'));
});

// A transient failure looking up the release URL happens strictly after `gh release
// create` has already succeeded — it must degrade to a warning, not report the release
// (which is now public) as a failure.
test('main reports success even when the post-publish URL lookup fails', async () => {
  const io = releaseIO();
  const run = preflightRun({
    'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' },
    'gh release view v0.1.1 --json url --jq .url': { throws: 'gh: rate limited' },
  });
  const log = makeFakeLog();

  const code = await main(['--yes', 'patch'],
    { run, log, io, root: '/repo', fsOps: makeFakeFsOps(), now: () => new Date('2026-08-23T10:00:00Z') });

  assert.equal(code, 0);
  assert.ok(log.lines.some((l) => l.startsWith('warn:') && l.includes('was published') && l.includes('rate limited')));
  assert.ok(!log.lines.some((l) => l.startsWith('error:')));
});

// The confirmation gate is the single guard between a preflight-passing repo and an
// irreversible publish; it had no test coverage at all before this one.
test('main respects a declined confirmation and touches nothing', async () => {
  const io = releaseIO();
  const run = preflightRun({ 'git ls-remote --tags origin refs/tags/v0.1.1': { stdout: '' } });
  const log = makeFakeLog();

  const code = await main(['patch'], {
    run, log, io, root: '/repo', fsOps: makeFakeFsOps(),
    ask: async () => false,
    now: () => new Date('2026-08-23T10:00:00Z'),
  });

  assert.equal(code, 1);
  assert.deepEqual(io.writes, []);
  // Preflight legitimately runs read-only "gh auth status" and "git status/fetch/..."
  // checks before the confirmation; what must never happen is anything irreversible.
  assert.ok(!run.lines().some((l) => l.startsWith('git commit') || l.startsWith('git push')
    || l.startsWith('git tag') || l.startsWith('gh release')));
  assert.ok(log.lines.some((l) => l.includes('Release cancelled.')));
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

// Finding 1: confirm() must never hang against a non-interactive stdin (</dev/null, CI,
// any wrapper that closes stdin) — it rejects with an actionable message instead.
test('confirm resolves true only for y/yes and rejects on EOF instead of hanging', async () => {
  const output = new PassThrough();
  output.isTTY = true;
  output.resume();

  const inputYes = new PassThrough();
  const yes = confirm('Publish? [y/N] ', { input: inputYes, output });
  inputYes.write('yes\n');
  assert.equal(await yes, true);

  const inputNo = new PassThrough();
  const no = confirm('Publish? [y/N] ', { input: inputNo, output });
  inputNo.write('n\n');
  assert.equal(await no, false);

  const inputEmpty = new PassThrough();
  const empty = confirm('Publish? [y/N] ', { input: inputEmpty, output });
  inputEmpty.write('\n');
  assert.equal(await empty, false);

  const inputEOF = new PassThrough();
  const eof = confirm('Publish? [y/N] ', { input: inputEOF, output });
  inputEOF.end();
  await assert.rejects(eof, /stdin is not interactive; re-run with --yes\./);
});
