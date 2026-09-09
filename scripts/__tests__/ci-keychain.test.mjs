import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  parseKeychainArgs, planImportCertificate, planStoreNotaryCredentials, planTeardown,
  parseKeychainList, readEnvironment, main,
} from '../ci-keychain.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeIO, makeFakeLog } from './helpers/fake-run.mjs';

const ENV = {
  MACOS_CERTIFICATE_P12_BASE64: 'YmFzZTY0',
  MACOS_CERTIFICATE_PASSWORD: 'p12-pass',
  NOTARY_APPLE_ID: 'dev@example.com',
  NOTARY_APP_SPECIFIC_PASSWORD: 'abcd-efgh-ijkl-mnop',
  NOTARY_TEAM_ID: '68QJJA7HK9',
};

test('parseKeychainArgs requires a known subcommand', () => {
  assert.equal(parseKeychainArgs(['setup']).command, 'setup');
  assert.equal(parseKeychainArgs(['teardown']).command, 'teardown');
  assert.throws(() => parseKeychainArgs([]), /setup|teardown/);
  assert.throws(() => parseKeychainArgs(['destroy']), /setup|teardown/);
});

test('readEnvironment reports every missing secret at once', () => {
  const { missing } = readEnvironment({ NOTARY_TEAM_ID: '68QJJA7HK9' });
  assert.deepEqual(missing, [
    'MACOS_CERTIFICATE_P12_BASE64',
    'MACOS_CERTIFICATE_PASSWORD',
    'NOTARY_APPLE_ID',
    'NOTARY_APP_SPECIFIC_PASSWORD',
  ]);
});

test('readEnvironment treats a blank secret as missing', () => {
  const { missing } = readEnvironment({ ...ENV, MACOS_CERTIFICATE_PASSWORD: '   ' });
  assert.deepEqual(missing, ['MACOS_CERTIFICATE_PASSWORD']);
});

test('readEnvironment validates the team id', () => {
  assert.throws(
    () => readEnvironment({ ...ENV, NOTARY_TEAM_ID: 'nope' }),
    /ten-character/,
  );
});

test('readEnvironment falls back to the project team id', () => {
  const { secrets } = readEnvironment({ ...ENV, NOTARY_TEAM_ID: undefined });
  assert.equal(secrets.teamID, '68QJJA7HK9');
});

const IMPORT = () => planImportCertificate({
  keychain: '/tmp/build.keychain-db',
  keychainPassword: 'ephemeral',
  certificatePath: '/tmp/cert.p12',
  certificatePassword: 'p12-pass',
  originalKeychains: ['/Users/test/Library/Keychains/login.keychain-db', '/tmp/extra.keychain-db'],
});

test('planImportCertificate creates, unlocks and defaults a dedicated keychain', () => {
  const lines = IMPORT().map((s) => [s.cmd, ...s.args].join(' '));
  assert.deepEqual(lines.slice(0, 3), [
    'security create-keychain -p ephemeral /tmp/build.keychain-db',
    'security set-keychain-settings -lut 21600 /tmp/build.keychain-db',
    'security unlock-keychain -p ephemeral /tmp/build.keychain-db',
  ]);
});

test('planImportCertificate imports the p12 for codesign only and allows non-interactive use', () => {
  const steps = IMPORT();
  const importStep = steps.find((s) => s.args.includes('import'));
  assert.deepEqual(importStep.args, [
    'import', '/tmp/cert.p12',
    '-k', '/tmp/build.keychain-db',
    '-P', 'p12-pass',
    '-T', '/usr/bin/codesign',
    '-f', 'pkcs12',
  ]);
  // Without this, codesign blocks on a GUI "allow access" prompt no runner can answer.
  const partition = steps.find((s) => s.args.includes('set-key-partition-list'));
  assert.deepEqual(partition.args, [
    'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
    '-s', '-k', 'ephemeral', '/tmp/build.keychain-db',
  ]);
});

test('planImportCertificate never leaks a password into a logged command line', () => {
  for (const step of IMPORT()) {
    assert.deepEqual(step.redact?.slice().sort(), ['ephemeral', 'p12-pass'],
      `${step.cmd} ${step.args.join(' ')} does not redact its passwords`);
  }
});

test('planImportCertificate prepends the new keychain without dropping existing keychains', () => {
  const listStep = IMPORT().find((s) => s.args.includes('list-keychains'));
  assert.deepEqual(listStep.args, [
    'list-keychains', '-d', 'user', '-s',
    '/tmp/build.keychain-db',
    '/Users/test/Library/Keychains/login.keychain-db',
    '/tmp/extra.keychain-db',
  ]);
});

test('parseKeychainList reads every quoted keychain path in order', () => {
  assert.deepEqual(parseKeychainList([
    '    "/Users/test/Library/Keychains/login.keychain-db"',
    '    "/tmp/extra keychain.keychain-db"',
  ].join('\n')), [
    '/Users/test/Library/Keychains/login.keychain-db',
    '/tmp/extra keychain.keychain-db',
  ]);
});

test('planStoreNotaryCredentials passes the app-specific password on stdin, not argv', () => {
  const step = planStoreNotaryCredentials({
    keychain: '/tmp/build.keychain-db',
    profile: 'macomprendo-notary',
    appleID: 'dev@example.com',
    teamID: '68QJJA7HK9',
    password: 'abcd-efgh-ijkl-mnop',
  });
  assert.equal(step.args.includes('--password'), false);
  assert.equal([step.cmd, ...step.args].join(' ').includes('abcd-efgh'), false);
  assert.equal(step.input, 'abcd-efgh-ijkl-mnop\n');
  assert.deepEqual(step.redact, ['abcd-efgh-ijkl-mnop']);
  assert.ok(step.args.includes('--keychain'));
  assert.ok(step.args.includes('/tmp/build.keychain-db'));
});

test('planTeardown restores the original search list and deletes all temporary files', () => {
  const steps = planTeardown({
    keychain: '/tmp/build.keychain-db',
    certificatePath: '/tmp/cert.p12',
    statePath: '/tmp/build-search-list.json',
    originalKeychains: ['/tmp/original.keychain-db'],
  });
  const lines = steps.map((s) => (s.type === 'rm' ? `rm ${s.path}` : [s.cmd, ...s.args].join(' ')));
  assert.deepEqual(lines, [
    'security list-keychains -d user -s /tmp/original.keychain-db',
    'security delete-keychain /tmp/build.keychain-db',
    'rm /tmp/cert.p12',
    'rm /tmp/build-search-list.json',
  ]);
});

function deps(env = ENV, script = []) {
  return {
    run: makeFakeRun(script),
    log: makeFakeLog(),
    fsOps: makeFakeFsOps(),
    io: makeFakeIO(),
    env,
    keychain: '/tmp/build.keychain-db',
    certificatePath: '/tmp/cert.p12',
    statePath: '/tmp/build-search-list.json',
    randomPassword: () => 'ephemeral',
  };
}

test('setup writes the decoded certificate as raw bytes, and runs the whole plan', async () => {
  const d = deps();
  const code = await main(['setup'], d);
  assert.equal(code, 0);
  const lines = d.run.lines();
  assert.ok(lines.some((l) => l.startsWith('security create-keychain')));
  assert.ok(lines.some((l) => l.includes('set-key-partition-list')));
  assert.ok(lines.some((l) => l.includes('notarytool store-credentials')));
  assert.deepEqual(d.io.writes, ['/tmp/build-search-list.json', '/tmp/cert.p12']);
  // A .p12 is binary; writing it through the text path would corrupt it.
  const written = d.io.store.get('/tmp/cert.p12');
  assert.ok(Buffer.isBuffer(written), 'the certificate must be written as bytes, not text');
  assert.ok(written.equals(Buffer.from('YmFzZTY0', 'base64')));
  assert.ok(d.fsOps.events.some((event) => event[0] === 'rmrf' && event[1] === '/tmp/cert.p12'),
    'the decoded certificate should be deleted immediately after import');
});

test('setup captures every existing keychain before prepending the temporary one', async () => {
  const existing = [
    '/Users/test/Library/Keychains/login.keychain-db',
    '/tmp/extra.keychain-db',
  ];
  const d = deps(ENV, [{ stdout: existing.map((item) => `    "${item}"`).join('\n') }]);
  assert.equal(await main(['setup'], d), 0);
  assert.deepEqual(JSON.parse(d.io.store.get('/tmp/build-search-list.json')), existing);
  assert.ok(d.run.calls.some((call) => call.args.join('\0') === [
    'list-keychains', '-d', 'user', '-s', '/tmp/build.keychain-db', ...existing,
  ].join('\0')));
});

test('setup refuses to run with a missing secret, and names every one', async () => {
  const d = deps({ NOTARY_TEAM_ID: '68QJJA7HK9' });
  assert.equal(await main(['setup'], d), 1);
  const text = d.log.lines.join('\n');
  assert.match(text, /MACOS_CERTIFICATE_P12_BASE64/);
  assert.match(text, /NOTARY_APP_SPECIFIC_PASSWORD/);
  assert.equal(d.run.calls.length, 0, 'nothing should be spawned without the secrets');
});

test('setup never prints a secret, even when a step fails', async () => {
  const d = deps(ENV, [{}, {}, {}, {}, { throws: 'security import failed' }]);
  await main(['setup'], d);
  const text = d.log.lines.join('\n');
  for (const secret of ['p12-pass', 'abcd-efgh-ijkl-mnop', 'ephemeral']) {
    assert.equal(text.includes(secret), false, `log leaked ${secret}`);
  }
});

test('a failed setup tears the keychain down instead of leaving it behind', async () => {
  const d = deps(ENV, [{}, {}, {}, {}, { throws: 'security import failed' }]);
  assert.equal(await main(['setup'], d), 1);
  assert.ok(d.run.lines().some((l) => l.startsWith('security delete-keychain')));
});

test('teardown tolerates an already-missing keychain', async () => {
  const d = deps(ENV, [{ throws: 'no such keychain' }]);
  assert.equal(await main(['teardown'], d), 0);
  assert.ok(d.run.lines().some((l) => l.startsWith('security delete-keychain')));
});

test('teardown restores the captured keychain list before deleting the temporary keychain', async () => {
  const d = deps();
  d.io.store.set('/tmp/build-search-list.json', JSON.stringify([
    '/Users/test/Library/Keychains/login.keychain-db',
    '/tmp/extra.keychain-db',
  ]));
  assert.equal(await main(['teardown'], d), 0);
  assert.deepEqual(d.run.calls[0].args, [
    'list-keychains', '-d', 'user', '-s',
    '/Users/test/Library/Keychains/login.keychain-db',
    '/tmp/extra.keychain-db',
  ]);
  assert.deepEqual(d.run.calls[1].args, ['delete-keychain', '/tmp/build.keychain-db']);
});

test('teardown fails instead of claiming removal when the keychain still exists', async () => {
  const d = deps(ENV, [{ code: 1, stderr: 'permission denied' }]);
  d.io.store.set('/tmp/build.keychain-db', Buffer.alloc(0));
  assert.equal(await main(['teardown'], d), 1);
  assert.ok(d.log.lines.some((line) => /still exists|permission denied/i.test(line)));
  assert.equal(d.log.lines.some((line) => /removed/.test(line)), false);
});

test('a failed search-list restore keeps its state file so teardown can be retried', async () => {
  const d = deps(ENV, [{ code: 1, stderr: 'search list locked' }, {}]);
  d.io.store.set('/tmp/build-search-list.json', JSON.stringify(['/Users/test/login.keychain-db']));
  assert.equal(await main(['teardown'], d), 1);
  assert.equal(
    d.fsOps.events.some((event) => event[0] === 'rmrf' && event[1] === '/tmp/build-search-list.json'),
    false,
  );
  assert.ok(d.log.lines.some((line) => /restore the original keychain search list/i.test(line)));
});

test('keychainPath honours the environment so CI and the script agree on one location', async () => {
  // The workflow passes runner.temp to notarytool; if this script defaulted to os.tmpdir()
  // instead, setup would build the keychain somewhere notarytool never looks.
  const { keychainPath } = await import('../ci-keychain.mjs');
  assert.equal(
    keychainPath({ MACOMPRENDO_SIGNING_KEYCHAIN: '/runner/temp/signing.keychain-db' }),
    '/runner/temp/signing.keychain-db',
  );
  assert.match(keychainPath({}), /macomprendo-signing\.keychain-db$/);
});

test('setup uses the environment-provided keychain path end to end', async () => {
  const d = deps({ ...ENV, MACOMPRENDO_SIGNING_KEYCHAIN: '/runner/temp/signing.keychain-db' });
  delete d.keychain;
  delete d.statePath;
  assert.equal(await main(['setup'], d), 0);
  assert.ok(d.run.lines().every((l) => !l.includes('/tmp/build.keychain-db')));
  assert.ok(d.run.lines().some((l) => l.includes('/runner/temp/signing.keychain-db')));
});
