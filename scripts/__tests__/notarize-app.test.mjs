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
