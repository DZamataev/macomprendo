#!/usr/bin/env node
// Build the app from this checkout and install it atomically, keeping a restorable backup.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

import { ROOT, DIST_DIR, APP_NAME, EXECUTABLE_NAME, BUNDLE_ID, appPath } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps } from './lib/fs.mjs';

export function parseInstallArgs(argv, env = process.env) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      'install-dir': { type: 'string' },
      'no-open': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  const raw = values['install-dir'] ?? env.MACOS_INSTALL_DIR ?? '/Applications';
  const installDir = raw.length > 1 && raw.endsWith('/') ? raw.slice(0, -1) : raw;
  return { installDir, open: !values['no-open'], help: values.help };
}

export function executablePattern(destination) {
  const executable = path.join(destination, 'Contents', 'MacOS', EXECUTABLE_NAME);
  const escaped = executable.replace(/[[\]().^$*+?|\\{}]/g, '\\$&');
  return `^${escaped}([[:space:]]|$)`;
}

export function planInstall({ installDir, workDir, source }) {
  const staged = path.join(workDir, APP_NAME);
  return [
    { type: 'exec', cmd: 'node', args: ['scripts/build-app.mjs'] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', source] },
    { type: 'exec', cmd: 'ditto', args: [source, staged] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', staged] },
  ];
}

// `run(..., { check: false })` still throws on a spawn error, but resolves rather than
// rejects when the child exits non-zero OR is killed by a signal — see scripts/lib/run.mjs.
// A signal kill reports `code: null` with `signal` set, and looks exactly like a clean
// "no output" result unless callers check for it explicitly. Treating a killed probe as a
// confirmed negative answer is the bug this guards against.
function isSignalKill(result) {
  return result.code === null && Boolean(result.signal);
}

async function runningPIDs(run, pattern, log) {
  const result = await run('pgrep', ['-f', pattern], { capture: true, check: false, log });
  if (isSignalKill(result)) {
    throw new Error(
      'Could not determine whether Macomprendo is running: pgrep was killed with '
      + `${result.signal}. Run the installer again.`,
    );
  }
  return (result.stdout ?? '').split('\n').map((p) => p.trim()).filter((p) => p !== '');
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps,
    env = process.env, root = ROOT, source = appPath(DIST_DIR),
  } = deps;

  let options;
  try {
    options = parseInstallArgs(argv, env);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run install-app -- [--no-open] [--install-dir <dir>]',
      '',
      'Builds Macomprendo.app from this checkout and replaces the installed copy.',
      'Environment: MACOS_INSTALL_DIR (default /Applications).',
    ].join('\n'));
    return 0;
  }

  if (!(await fsOps.pathExists(options.installDir))) {
    log.error(`Install directory does not exist: ${options.installDir}`);
    return 1;
  }
  if (!(await fsOps.isDirectory(options.installDir))) {
    log.error(`Install directory is not a directory: ${options.installDir}`);
    return 1;
  }

  const destination = path.join(options.installDir, APP_NAME);
  const pattern = executablePattern(destination);
  let workDir = null;
  let backup = null;
  let backedUp = false;
  let swapped = false;
  let installed = false;

  try {
    workDir = await fsOps.mkdtemp(path.join(options.installDir, '.macomprendo-update.'));
    const staged = path.join(workDir, APP_NAME);
    backup = path.join(workDir, `previous-${APP_NAME}`);

    for (const step of planInstall({ installDir: options.installDir, workDir, source })) {
      await run(step.cmd, step.args, { cwd: root, log });
    }

    let pids = await runningPIDs(run, pattern, log);
    if (pids.length > 0) {
      log.info('Closing the installed app before updating it…');
      for (const pid of pids) await run('kill', ['-TERM', pid], { check: false, log });
      for (let attempt = 0; attempt < 20; attempt += 1) {
        pids = await runningPIDs(run, pattern, log);
        if (pids.length === 0) break;
        await sleep(250);
      }
      if (pids.length > 0) {
        throw new Error('Macomprendo is still running. Quit it and run the installer again.');
      }
    }

    if (await fsOps.pathExists(destination)) {
      // Something is already at the destination — confirm it is actually Macomprendo
      // before treating it as disposable. A differently-signed app sharing the name, a
      // half-written remnant, or an unrelated folder must be refused, not backed up and
      // silently replaced.
      const identity = await run(
        '/usr/libexec/PlistBuddy',
        ['-c', 'Print :CFBundleIdentifier', path.join(destination, 'Contents', 'Info.plist')],
        { capture: true, check: false, log },
      );
      if (isSignalKill(identity)) {
        throw new Error(
          `Could not verify the app already at ${destination}: PlistBuddy was killed with `
          + `${identity.signal}. Run the installer again.`,
        );
      }
      const identifier = (identity.stdout ?? '').trim();
      if (identifier !== BUNDLE_ID) {
        throw new Error(
          `Refusing to replace ${destination}: it is not Macomprendo `
          + `(found bundle identifier "${identifier || 'none'}"). Remove it manually, or `
          + 'install to a different --install-dir.',
        );
      }
      await fsOps.move(destination, backup);
      backedUp = true;
    } else {
      backup = null;
    }

    await fsOps.move(staged, destination);
    swapped = true;

    await run('codesign', ['--verify', '--deep', '--strict', destination], { cwd: root, log });
    installed = true;

    const version = await run('/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleShortVersionString', path.join(destination, 'Contents', 'Info.plist')],
      { capture: true, log });
    log.info(`Installed Macomprendo ${(version.stdout ?? '').trim()} at ${destination}`);

    if (options.open) {
      await run('open', [destination], { log });
      log.info('Launched the updated app.');
    }
    return 0;
  } catch (error) {
    log.error(error.message);
    if (!installed && (swapped || backedUp)) {
      try {
        if (await fsOps.pathExists(destination)) {
          // The swap already put a copy at the destination before something about it
          // failed to verify — it is disposable (the build output in dist/ is still
          // there), so clear it before restoring, rather than leaving it live.
          await fsOps.rmrf(destination);
        }
        if (backedUp) {
          await fsOps.move(backup, destination);
          log.info('Restored the previously installed app.');
        } else {
          log.info('Removed the unverified update; there was no previous app to restore.');
        }
      } catch (restoreError) {
        const remaining = backedUp ? ` The previous app remains at ${backup}.` : '';
        log.error(`Automatic restore failed.${remaining} ${restoreError.message}`);
        return 1;
      }
    }
    return 1;
  } finally {
    // Clean up the staging directory once it is safe to: the new app was installed and
    // verified, or the swap never happened (a pre-swap failure — whether or not there was
    // a previous app at the destination — leaves nothing precious in the staging
    // directory). A post-swap failure — the staged app was already moved into place before
    // something about it failed to verify — leaves the staging directory (and anything left
    // in it, such as an unrestored backup) for manual inspection instead of erasing the
    // evidence. `pathExists(destination)` used to stand in for "the swap never happened",
    // but on a first-time install the destination never existed either way, so a pre-swap
    // failure there was wrongly kept forever.
    const safeToCleanUp = installed || !swapped;
    if (workDir !== null && safeToCleanUp) {
      await fsOps.rmrf(workDir);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
