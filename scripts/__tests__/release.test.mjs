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
