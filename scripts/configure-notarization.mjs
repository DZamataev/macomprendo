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
    const cleanup = () => {
      rl.close();
      if (muted) output.write('\n');
    };
    rl.on('error', (err) => {
      cleanup();
      reject(err);
    });
    rl.question('', (answer) => {
      cleanup();
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

    try {
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
    } catch (identityCheckError) {
      log.warn('Could not check for Developer ID Application certificate (continuing anyway). '
        + `Create one for team ${teamID} at developer.apple.com > Certificates if needed, then run: npm run notarize`);
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
