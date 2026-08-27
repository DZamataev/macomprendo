#!/usr/bin/env node
// Build the app from this checkout and install it atomically, keeping a restorable backup.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

import { ROOT, DIST_DIR, APP_NAME, EXECUTABLE_NAME, appPath } from './lib/paths.mjs';
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

async function runningPIDs(run, pattern) {
  const result = await run('pgrep', ['-f', pattern], { capture: true, check: false });
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

  const destination = path.join(options.installDir, APP_NAME);
  const pattern = executablePattern(destination);
  let workDir = null;
  let backup = null;
  let installed = false;

  try {
    workDir = await fsOps.mkdtemp(path.join(options.installDir, '.macomprendo-update.'));
    const staged = path.join(workDir, APP_NAME);
    backup = path.join(workDir, `previous-${APP_NAME}`);

    for (const step of planInstall({ installDir: options.installDir, workDir, source })) {
      log.step([step.cmd, ...step.args].join(' '));
      await run(step.cmd, step.args, { cwd: root });
    }

    let pids = await runningPIDs(run, pattern);
    if (pids.length > 0) {
      log.info('Closing the installed app before updating it…');
      for (const pid of pids) await run('kill', ['-TERM', pid], { check: false });
      for (let attempt = 0; attempt < 20; attempt += 1) {
        pids = await runningPIDs(run, pattern);
        if (pids.length === 0) break;
        await sleep(250);
      }
      if (pids.length > 0) {
        throw new Error('Macomprendo is still running. Quit it and run the installer again.');
      }
    }

    if (await fsOps.pathExists(destination)) {
      await fsOps.move(destination, backup);
    } else {
      backup = null;
    }
    await fsOps.move(staged, destination);
    installed = true;

    await run('codesign', ['--verify', '--deep', '--strict', destination], { cwd: root });
    const version = await run('/usr/libexec/PlistBuddy',
      ['-c', 'Print :CFBundleShortVersionString', path.join(destination, 'Contents', 'Info.plist')],
      { capture: true });
    log.info(`Installed Macomprendo ${(version.stdout ?? '').trim()} at ${destination}`);

    if (options.open) {
      await run('open', [destination]);
      log.info('Launched the updated app.');
    }
    return 0;
  } catch (error) {
    log.error(error.message);
    if (!installed && backup !== null && (await fsOps.pathExists(backup))) {
      try {
        await fsOps.move(backup, destination);
        log.info('Restored the previously installed app.');
      } catch (restoreError) {
        log.error(`Automatic restore failed; the previous app remains at ${backup}: ${restoreError.message}`);
        return 1;
      }
    }
    return 1;
  } finally {
    // Remove the staging directory whenever the destination is in place — either the new
    // app was installed, or the backup was successfully restored. If the destination is
    // missing, the backup is the only copy left and must survive for manual recovery.
    if (workDir !== null && (await fsOps.pathExists(destination))) {
      await fsOps.rmrf(workDir);
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
