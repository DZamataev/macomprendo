#!/usr/bin/env node
// Reset this app's TCC grants so the next launch asks for them from scratch.
//
// Why this exists: an ad-hoc signed build has no stable code identity, so macOS records
// the grant against the build's code hash. Every rebuild changes that hash, and the grant
// silently stops applying while System Settings still shows the toggle switched on — the
// app then reports "no accessibility access" for a permission that looks granted. Signing
// with a Developer ID identity fixes that for good; this script clears the stale state in
// the meantime. See DISTRIBUTING.md.
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import { ROOT, BUNDLE_ID, EXECUTABLE_NAME } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';

// The two permissions the app asks for: Accessibility drives reading the selection and
// pasting the result, Microphone drives dictation.
export const TCC_SERVICES = ['Accessibility', 'Microphone'];

const HELP = `Usage: npm run reset-permissions -- [--dry-run] [--force]

Resets the macOS privacy grants for ${BUNDLE_ID}:
${TCC_SERVICES.map((service) => `  - ${service}`).join('\n')}

The next launch asks for them again. Quit Macomprendo first — a running process keeps the
permissions it started with, which is exactly the confusion this script exists to clear.

  --dry-run   print the commands without running them
  --force     reset even while Macomprendo is running
  --help      show this message
`;

export function parseResetArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      'dry-run': { type: 'boolean', default: false },
      force: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  return { dryRun: values['dry-run'], force: values.force, help: values.help };
}

export function planReset(bundleId) {
  return TCC_SERVICES.map((service) => ({
    type: 'exec',
    cmd: 'tccutil',
    args: ['reset', service, bundleId],
  }));
}

// `run(..., { check: false })` resolves rather than rejects when the child exits non-zero
// OR is killed by a signal — a kill reports `code: null` with `signal` set, and looks
// exactly like pgrep's "no match" result unless callers check for it. Reading a killed
// probe as "not running" would reset permissions out from under a live app.
function isSignalKill(result) {
  return result.code === null && Boolean(result.signal);
}

async function isRunning(run, log) {
  const result = await run('pgrep', ['-x', EXECUTABLE_NAME], { capture: true, check: false, log });
  if (isSignalKill(result)) {
    throw new Error(
      `Could not determine whether ${EXECUTABLE_NAME} is running: pgrep was killed with `
      + `${result.signal}. Nothing was reset; run the command again.`,
    );
  }
  return (result.stdout ?? '').trim() !== '';
}

export async function main(argv, deps = {}) {
  const { run = realRun, log = realLog, root = ROOT, bundleId = BUNDLE_ID } = deps;

  let options;
  try {
    options = parseResetArgs(argv);
  } catch (error) {
    log.error(error.message);
    log.info(HELP);
    return 2;
  }

  if (options.help) {
    log.info(HELP);
    return 0;
  }

  const steps = planReset(bundleId);

  if (options.dryRun) {
    log.info(`Would reset ${TCC_SERVICES.join(' and ')} for ${bundleId}:`);
    for (const step of steps) log.step([step.cmd, ...step.args].join(' '));
    return 0;
  }

  try {
    if (!options.force && await isRunning(run, log)) {
      log.error(
        `${EXECUTABLE_NAME} is running. Resetting now would leave it holding permissions the `
        + 'system has already revoked — quit Macomprendo and run this again, or pass --force.',
      );
      return 1;
    }

    for (const step of steps) {
      log.step([step.cmd, ...step.args].join(' '));
      await run(step.cmd, step.args, { cwd: root, log });
    }
  } catch (error) {
    log.error(error.message);
    return 1;
  }

  log.info(`Reset ${TCC_SERVICES.join(' and ')} for ${bundleId}. The next launch will ask again.`);
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
