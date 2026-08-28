#!/usr/bin/env node
// One-time setup: store an Apple app-specific password in the login Keychain so that
// notarize-app.mjs can submit builds without any secret in the repository or in argv.
import { pathToFileURL } from 'node:url';

import { NOTARY_PROFILE, TEAM_ID } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { prompt } from './lib/prompt.mjs';

const TEAM_ID_PATTERN = /^[A-Z0-9]{10}$/;
const NOT_INTERACTIVE = 'stdin closed before an answer was given; '
  + 'set NOTARY_APPLE_ID (and pipe the password) or run this in an interactive terminal.';

export function validateTeamID(id) {
  if (typeof id !== 'string' || !TEAM_ID_PATTERN.test(id)) {
    throw new Error(`"${id}" is not a ten-character Apple Developer Team ID (A-Z and 0-9).`);
  }
  return id;
}

export function promptLine(query, io) {
  return prompt(query, io, { eofMessage: NOT_INTERACTIVE });
}

export function promptSecret(query, io) {
  return prompt(query, io, { muted: true, eofMessage: NOT_INTERACTIVE });
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
      // A signal-killed probe resolves under check:false with code: null and empty stdout —
      // the same shape as "no certificate found" unless checked explicitly. This is advisory
      // (the operator can always re-check with `security find-identity`), so a warning naming
      // the signal is enough here; it must not claim the certificate is actually missing.
      if (identities.code === null) {
        log.warn(`Could not check for a Developer ID Application certificate: security `
          + `find-identity was killed (signal ${identities.signal}). Create one for team `
          + `${teamID} at developer.apple.com > Certificates if needed, then run: npm run notarize`);
      } else if (!(identities.stdout ?? '').includes('Developer ID Application:')) {
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
