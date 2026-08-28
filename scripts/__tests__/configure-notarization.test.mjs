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

test('main fails fast instead of hanging when stdin is not interactive', async () => {
  const io = fakeTTY();
  const run = makeFakeRun();
  const log = makeFakeLog();

  const done = main([], { run, log, io, env: {} });
  io.input.end();
  const code = await done;

  assert.equal(code, 1);
  assert.deepEqual(run.calls, []);
  assert.ok(log.lines.some((l) => l.includes('stdin closed before an answer was given')));
});

test('promptSecret restores terminal echo and closes the interface on input error', async () => {
  const io = fakeTTY();
  const answer = promptSecret('App-specific password: ', io);
  const inputError = new Error('Input stream error');
  io.input.destroy(inputError);
  await assert.rejects(answer, inputError);
  // Verify the newline was written to restore echo visibility
  assert.ok(io.text().includes('\n'), 'newline should be written to restore echo on error');
});

test('main returns 0 and warns when identity check throws after store-credentials succeeds', async () => {
  const io = fakeTTY();

  // Custom fake run: succeeds on store-credentials, throws on find-identity
  let callCount = 0;
  const customRun = async (cmd, args, options = {}) => {
    callCount += 1;
    if (callCount === 1) {
      // First call: store-credentials succeeds
      return { stdout: '', stderr: '', code: 0 };
    }
    if (callCount === 2) {
      // Second call: find-identity throws (simulating spawn/other error)
      throw new Error('security command failed');
    }
  };
  customRun.calls = [];

  const log = makeFakeLog();

  const done = main([], {
    run: customRun,
    log,
    io,
    env: { NOTARY_APPLE_ID: 'dev@example.com' },
  });
  io.input.write('password\n');
  const code = await done;

  assert.equal(code, 0, 'should return 0 when store-credentials succeeds, even if identity check throws');
  assert.ok(log.lines.some((l) => l.includes('credentials are ready')), 'should log that credentials were stored');
  assert.ok(log.lines.some((l) => l.startsWith('warn: ') && l.includes('Could not check')), 'should warn about identity check failure');
});

// `security find-identity` runs with `check: false`, so a signal-killed probe resolves
// (code: null, signal set) rather than throwing — it must not be read as "no certificate
// found" (identities.stdout is empty either way and would satisfy that same `!includes`
// check). This is the sixth `{ check: false }` call site in the toolchain; the other five
// already distinguish a signal kill from a clean result, and so must this one.
test('main warns naming the signal, not a missing certificate, when find-identity is signal-killed', async () => {
  const io = fakeTTY();
  const run = makeFakeRun([{}, { signal: 'SIGKILL' }]);
  const log = makeFakeLog();

  const done = main([], { run, log, io, env: { NOTARY_APPLE_ID: 'dev@example.com' } });
  io.input.write('password\n');
  const code = await done;

  assert.equal(code, 0);
  assert.ok(log.lines.some((l) => l.startsWith('warn: ') && l.includes('SIGKILL')),
    'the warning must name the signal that killed the probe');
  assert.equal(
    log.lines.some((l) => l.includes('No "Developer ID Application" certificate is installed')),
    false,
    'a signal-killed probe must never be reported as a confirmed "certificate missing"',
  );
});
