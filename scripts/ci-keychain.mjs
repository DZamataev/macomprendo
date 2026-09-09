#!/usr/bin/env node
// Build (and tear down) a temporary keychain holding the Developer ID certificate and the
// notarization credentials, so a CI runner can sign and notarize without any secret ever
// touching the repository or the log.
//
// Why a *dedicated* keychain and not the login one:
//   - It is created with a random password this process invents and never persists, so the
//     certificate cannot outlive the job in a usable state.
//   - `security delete-keychain` at the end removes both the container and its private key,
//     which "just importing into login.keychain" would leave behind on a self-hosted runner.
//   - `set-key-partition-list` is what stops codesign from blocking on the GUI "allow access"
//     prompt that no runner can answer; it applies to a keychain, so we need our own.
//
// Apple's `security` CLI only accepts the keychain and PKCS#12 passwords as arguments. Every
// such step declares them in `redact`; the notary password does support stdin and uses it.
// GitHub-hosted runners are ephemeral and single-tenant, and job logs for this repo are public.
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

import { ROOT, NOTARY_PROFILE, TEAM_ID } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';

const COMMANDS = new Set(['setup', 'teardown']);
const TEAM_ID_PATTERN = /^[A-Z0-9]{10}$/;

export const REQUIRED_SECRETS = [
  'MACOS_CERTIFICATE_P12_BASE64',
  'MACOS_CERTIFICATE_PASSWORD',
  'NOTARY_APPLE_ID',
  'NOTARY_APP_SPECIFIC_PASSWORD',
];

export function parseKeychainArgs(argv) {
  const command = argv[0];
  if (!COMMANDS.has(command)) {
    throw new Error(`Usage: node scripts/ci-keychain.mjs <${[...COMMANDS].join('|')}>`);
  }
  return { command };
}

/**
 * Reads the five secrets from the environment. Every missing one is reported together: a CI
 * operator setting this up for the first time should learn about all of them in one run
 * rather than one failed run per secret.
 */
export function readEnvironment(env) {
  const value = (name) => {
    const raw = env[name];
    return typeof raw === 'string' && raw.trim() !== '' ? raw.trim() : null;
  };

  const missing = REQUIRED_SECRETS.filter((name) => value(name) === null);

  const teamID = value('NOTARY_TEAM_ID') ?? TEAM_ID;
  if (!TEAM_ID_PATTERN.test(teamID)) {
    throw new Error(`NOTARY_TEAM_ID "${teamID}" is not a ten-character Apple Developer Team ID.`);
  }

  return {
    missing,
    secrets: {
      certificateBase64: value('MACOS_CERTIFICATE_P12_BASE64'),
      certificatePassword: value('MACOS_CERTIFICATE_PASSWORD'),
      appleID: value('NOTARY_APPLE_ID'),
      notaryPassword: value('NOTARY_APP_SPECIFIC_PASSWORD'),
      teamID,
      profile: value('NOTARYTOOL_PROFILE') ?? NOTARY_PROFILE,
    },
  };
}

/**
 * Where the temporary keychain lives. CI passes an explicit path (the runner's own temp
 * directory, which it also hands to notarytool) — those two must agree, or setup builds a
 * keychain in one place while notarytool looks in another.
 */
export function keychainPath(env = process.env) {
  const explicit = env.MACOMPRENDO_SIGNING_KEYCHAIN;
  if (typeof explicit === 'string' && explicit.trim() !== '') return explicit.trim();
  return path.join(os.tmpdir(), 'macomprendo-signing.keychain-db');
}

export function certificatePathFor(env = process.env) {
  return `${keychainPath(env).replace(/\.keychain-db$/, '')}-certificate.p12`;
}

export function statePathFor(env = process.env) {
  return `${keychainPath(env).replace(/\.keychain-db$/, '')}-search-list.json`;
}

export function parseKeychainList(output) {
  return String(output).split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
    try { return JSON.parse(line); } catch { return line.replace(/^"|"$/g, ''); }
  });
}

export function planImportCertificate({
  keychain, keychainPassword, certificatePath, certificatePassword, originalKeychains = [],
}) {
  const redact = [keychainPassword, certificatePassword];
  const step = (args) => ({ cmd: 'security', args, redact });
  return [
    step(['create-keychain', '-p', keychainPassword, keychain]),
    // -lut 21600: lock after six hours of idling, an upper bound on how long the key can be
    // usable if a job hangs. Without it the keychain never auto-locks.
    step(['set-keychain-settings', '-lut', '21600', keychain]),
    step(['unlock-keychain', '-p', keychainPassword, keychain]),
    step([
      'import', certificatePath,
      '-k', keychain,
      '-P', certificatePassword,
      '-T', '/usr/bin/codesign',
      '-f', 'pkcs12',
    ]),
    // Grants codesign non-interactive access to the imported key. Skipping this is the classic
    // "CI hangs forever at the codesign step" bug: the GUI prompt has nobody to answer it.
    step([
      'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
      '-s', '-k', keychainPassword, keychain,
    ]),
    // Prepend, never replace: a runner can have keychains besides login, and teardown restores
    // this exact captured list rather than guessing what existed before the job.
    step(['list-keychains', '-d', 'user', '-s', keychain,
      ...originalKeychains.filter((item) => item !== keychain)]),
  ];
}

export function planStoreNotaryCredentials({ keychain, profile, appleID, teamID, password }) {
  return {
    cmd: 'xcrun',
    args: [
      'notarytool', 'store-credentials', profile,
      '--apple-id', appleID,
      '--team-id', teamID,
      '--keychain', keychain,
    ],
    input: `${password}\n`,
    redact: [password],
  };
}

export function planTeardown({ keychain, certificatePath, statePath, originalKeychains }) {
  const steps = [];
  if (Array.isArray(originalKeychains)) {
    steps.push({
      cmd: 'security', args: ['list-keychains', '-d', 'user', '-s', ...originalKeychains],
      kind: 'restore-search-list',
    });
  }
  steps.push(
    { cmd: 'security', args: ['delete-keychain', keychain], kind: 'delete-keychain' },
    { type: 'rm', path: certificatePath },
  );
  if (statePath) steps.push({ type: 'rm', path: statePath, kind: 'search-list-state' });
  return steps;
}

async function teardown(steps, { run, fsOps, io, root, keychain }) {
  const failures = [];
  let restoreFailed = false;
  for (const step of steps) {
    if (step.type === 'rm') {
      if (step.kind === 'search-list-state' && restoreFailed) continue;
      await fsOps.rmrf(step.path);
      continue;
    }
    const result = await run(step.cmd, step.args, {
      cwd: root, check: false, redact: step.redact ?? [],
    });
    if (result.code !== 0 && step.kind === 'restore-search-list') {
      restoreFailed = true;
      failures.push(`Could not restore the original keychain search list: ${result.stderr}`);
    }
    if (result.code !== 0 && step.kind === 'delete-keychain' && await io.exists(keychain)) {
      failures.push(`Could not delete the signing keychain: ${result.stderr}`);
    }
  }
  if (await io.exists(keychain)) failures.push(`Signing keychain still exists at ${keychain}.`);
  if (failures.length > 0) throw new Error(failures.join('\n'));
}

async function readOriginalKeychains(io, statePath) {
  try {
    const value = JSON.parse(await io.readFile(statePath));
    if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
      throw new Error('invalid keychain search-list state');
    }
    return value;
  } catch (error) {
    if (error.code === 'ENOENT') return undefined;
    throw error;
  }
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps, io = realIO,
    env = process.env, root = ROOT,
    keychain = keychainPath(env),
    certificatePath = certificatePathFor(env),
    statePath = statePathFor(env),
    randomPassword = () => crypto.randomBytes(24).toString('base64url'),
  } = deps;

  let command;
  try {
    ({ command } = parseKeychainArgs(argv));
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (command === 'teardown') {
    try {
      const originalKeychains = await readOriginalKeychains(io, statePath);
      await teardown(planTeardown({ keychain, certificatePath, statePath, originalKeychains }),
        { run, fsOps, io, root, keychain });
      log.info('Signing keychain and certificate removed.');
      return 0;
    } catch (error) {
      log.error(error.message);
      return 1;
    }
  }

  let secrets;
  try {
    const environment = readEnvironment(env);
    if (environment.missing.length > 0) {
      log.error('Cannot set up code signing; these repository secrets are not set:');
      for (const name of environment.missing) log.error(`  ${name}`);
      log.error('See DISTRIBUTING.md > "Signing and notarizing from CI" for how to create them.');
      return 1;
    }
    secrets = environment.secrets;
  } catch (error) {
    log.error(error.message);
    return 1;
  }

  const keychainPassword = randomPassword();
  try {
    const listed = await run('security', ['list-keychains', '-d', 'user'], {
      cwd: root, capture: true,
    });
    const originalKeychains = parseKeychainList(listed.stdout);
    await io.writeFile(statePath, JSON.stringify(originalKeychains));
    await io.writeBinaryFile(certificatePath, secrets.certificateBase64);

    const steps = planImportCertificate({
      keychain,
      keychainPassword,
      certificatePath,
      certificatePassword: secrets.certificatePassword,
      originalKeychains,
    });
    for (const step of steps) {
      await run(step.cmd, step.args, { cwd: root, redact: step.redact });
      if (step.args.includes('import')) await fsOps.rmrf(certificatePath);
    }

    const credentials = planStoreNotaryCredentials({
      keychain,
      profile: secrets.profile,
      appleID: secrets.appleID,
      teamID: secrets.teamID,
      password: secrets.notaryPassword,
    });
    await run(credentials.cmd, credentials.args, {
      cwd: root, input: credentials.input, redact: credentials.redact,
    });

    log.info(`Signing keychain ready at ${keychain} (profile "${secrets.profile}").`);
    return 0;
  } catch (error) {
    log.error(error.message);
    // A half-built keychain is worse than none: it can hold the private key without the
    // partition list that makes codesign non-interactive, so a later step would hang.
    try {
      const originalKeychains = await readOriginalKeychains(io, statePath);
      await teardown(planTeardown({ keychain, certificatePath, statePath, originalKeychains }),
        { run, fsOps, io, root, keychain });
    } catch (cleanupError) {
      log.error(`Cleanup also failed: ${cleanupError.message}`);
    }
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
