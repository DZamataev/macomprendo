import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseInstallArgs, executablePattern, planInstall, main } from '../install-app.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeLog } from './helpers/fake-run.mjs';

test('parseInstallArgs defaults to /Applications and opening the app', () => {
  assert.deepEqual(parseInstallArgs([], {}), { installDir: '/Applications', open: true, help: false });
});

test('parseInstallArgs honours --no-open, --install-dir and MACOS_INSTALL_DIR', () => {
  assert.equal(parseInstallArgs(['--no-open'], {}).open, false);
  assert.equal(parseInstallArgs(['--install-dir', '~/Apps/'], {}).installDir, '~/Apps');
  assert.equal(parseInstallArgs([], { MACOS_INSTALL_DIR: '/Volumes/Dev/Apps' }).installDir,
    '/Volumes/Dev/Apps');
  assert.equal(parseInstallArgs(['--install-dir', '/Custom'], { MACOS_INSTALL_DIR: '/Ignored' }).installDir,
    '/Custom');
});

test('executablePattern anchors on the installed executable and escapes regex characters', () => {
  assert.equal(
    executablePattern('/Applications/Macomprendo.app'),
    '^/Applications/Macomprendo\\.app/Contents/MacOS/Macomprendo([[:space:]]|$)',
  );
});

test('planInstall builds, stages, swaps and verifies', () => {
  const lines = planInstall({
    installDir: '/Applications',
    workDir: '/Applications/.macomprendo-update.AB12',
    source: '/repo/dist/Macomprendo.app',
  }).map((s) => (s.type === 'exec' ? [s.cmd, ...s.args].join(' ') : `${s.type} ${s.from ?? s.path} ${s.to ?? ''}`.trim()));

  assert.deepEqual(lines, [
    'node scripts/build-app.mjs',
    'codesign --verify --deep --strict /repo/dist/Macomprendo.app',
    'ditto /repo/dist/Macomprendo.app /Applications/.macomprendo-update.AB12/Macomprendo.app',
    'codesign --verify --deep --strict /Applications/.macomprendo-update.AB12/Macomprendo.app',
  ]);
});

function installDeps({ running = false, existing = true } = {}) {
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    const line = [cmd, ...args].join(' ');
    calls.push({ cmd, args, options, line });
    if (cmd === 'pgrep') {
      return running && calls.filter((c) => c.cmd === 'pgrep').length <= 1
        ? { stdout: '4242\n', stderr: '', code: 0 }
        : { stdout: '', stderr: '', code: 1 };
    }
    if (cmd === '/usr/libexec/PlistBuddy') {
      if (args.includes('Print :CFBundleIdentifier')) {
        return { stdout: 'com.dzamataev.macomprendo\n', stderr: '', code: 0 };
      }
      return { stdout: '0.1.0\n', stderr: '', code: 0 };
    }
    return { stdout: '', stderr: '', code: 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((c) => c.line);

  const fsOps = makeFakeFsOps([
    '/Applications',
    ...(existing ? ['/Applications/Macomprendo.app'] : []),
    '/repo/dist/Macomprendo.app',
  ]);
  fsOps.moves = [];
  fsOps.move = async (from, to) => { fsOps.moves.push([from, to]); fsOps.present.delete(from); fsOps.present.add(to); };
  fsOps.mkdtemp = async (prefix) => `${prefix}AB12`;
  // env: {} keeps MACOS_INSTALL_DIR from the developer's shell out of the test.
  return { run, fsOps, log: makeFakeLog(), env: {}, source: '/repo/dist/Macomprendo.app' };
}

test('main installs over an existing copy and opens it', async () => {
  const deps = installDeps();
  const code = await main([], deps);

  assert.equal(code, 0);
  assert.deepEqual(deps.fsOps.moves, [
    ['/Applications/Macomprendo.app', '/Applications/.macomprendo-update.AB12/previous-Macomprendo.app'],
    ['/Applications/.macomprendo-update.AB12/Macomprendo.app', '/Applications/Macomprendo.app'],
  ]);
  assert.ok(deps.run.lines().includes('open /Applications/Macomprendo.app'));
  assert.ok(deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/.macomprendo-update.AB12'));
});

test('main --no-open leaves the app closed', async () => {
  const deps = installDeps();
  await main(['--no-open'], deps);
  assert.equal(deps.run.lines().some((l) => l.startsWith('open ')), false);
});

test('main terminates a running copy before swapping', async () => {
  const deps = installDeps({ running: true });
  const code = await main([], deps);
  assert.equal(code, 0);
  assert.ok(deps.run.lines().includes('kill -TERM 4242'));
});

test('main restores the backup when the swap fails', async () => {
  const deps = installDeps();
  let swaps = 0;
  const originalMove = deps.fsOps.move;
  deps.fsOps.move = async (from, to) => {
    swaps += 1;
    if (swaps === 2) throw new Error('Resource busy');
    return originalMove(from, to);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.deepEqual(deps.fsOps.moves.at(-1), [
    '/Applications/.macomprendo-update.AB12/previous-Macomprendo.app',
    '/Applications/Macomprendo.app',
  ]);
  assert.ok(deps.log.lines.some((l) => l.includes('Restored the previously installed app')));
});

test('main installs fresh when no previous app exists', async () => {
  const deps = installDeps({ existing: false });
  const code = await main([], deps);

  assert.equal(code, 0);
  assert.deepEqual(deps.fsOps.moves, [
    ['/Applications/.macomprendo-update.AB12/Macomprendo.app', '/Applications/Macomprendo.app'],
  ]);
  assert.ok(deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/.macomprendo-update.AB12'));
});

// The `finally` guard used to read `installed || (!swapped && pathExists(destination))`,
// which conflates "the destination is untouched" with "the destination exists". On a
// first-time install (no previous app, so `destination` never existed) that fails before
// the swap, both halves are false, so the staging directory was kept forever — even though
// nothing precious is in it: the swap never happened, so there is no surviving copy to
// protect. It must be cleaned up exactly like the "existing app, pre-swap failure" case.
test('main cleans up the staging directory when a pre-swap step fails on a fresh install', async () => {
  const deps = installDeps({ existing: false });
  const originalRun = deps.run;
  let codesignCalls = 0;
  deps.run = async (cmd, args = [], options = {}) => {
    if (cmd === 'codesign') {
      codesignCalls += 1;
      if (codesignCalls === 2) {
        throw new Error(
          'codesign --verify --deep --strict /Applications/.macomprendo-update.AB12/Macomprendo.app exited with 1',
        );
      }
    }
    return originalRun(cmd, args, options);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.equal(deps.fsOps.moves.length, 0);
  assert.ok(
    deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/.macomprendo-update.AB12'),
    'a pre-swap failure on a fresh install must not leak the staging directory',
  );
});

test('main refuses when the install directory is not a directory', async () => {
  const deps = installDeps();
  deps.fsOps.isDirectory = async (p) => p !== '/Applications';

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.equal(deps.fsOps.moves.length, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('not a directory')));
});

test('main refuses to proceed when pgrep cannot be trusted (signal-killed)', async () => {
  const deps = installDeps();
  const originalRun = deps.run;
  deps.run = async (cmd, args = [], options = {}) => {
    if (cmd === 'pgrep') return { stdout: '', stderr: '', code: null, signal: 'SIGKILL' };
    return originalRun(cmd, args, options);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.equal(deps.fsOps.moves.length, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Could not determine whether Macomprendo is running')));
});

test('main refuses when it cannot verify the existing destination (PlistBuddy signal-killed)', async () => {
  const deps = installDeps();
  const originalRun = deps.run;
  deps.run = async (cmd, args = [], options = {}) => {
    if (cmd === '/usr/libexec/PlistBuddy' && args.includes('Print :CFBundleIdentifier')) {
      return { stdout: '', stderr: '', code: null, signal: 'SIGKILL' };
    }
    return originalRun(cmd, args, options);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.equal(deps.fsOps.moves.length, 0);
  assert.ok(deps.log.lines.some((l) => l.includes('Could not verify the app already at')));
});

test('main refuses to replace a destination that is not Macomprendo', async () => {
  const deps = installDeps();
  const originalRun = deps.run;
  deps.run = async (cmd, args = [], options = {}) => {
    if (cmd === '/usr/libexec/PlistBuddy' && args.includes('Print :CFBundleIdentifier')) {
      return { stdout: 'com.example.other\n', stderr: '', code: 0 };
    }
    return originalRun(cmd, args, options);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.equal(deps.fsOps.moves.length, 0);
  assert.ok(deps.fsOps.present.has('/Applications/Macomprendo.app'));
  assert.ok(deps.log.lines.some((l) => l.includes('Refusing to replace')));
});

test('main restores the backup and preserves the staging dir when the post-swap verify fails', async () => {
  const deps = installDeps();
  const originalRun = deps.run;
  let codesignCalls = 0;
  deps.run = async (cmd, args = [], options = {}) => {
    if (cmd === 'codesign') {
      codesignCalls += 1;
      if (codesignCalls === 3) {
        throw new Error('codesign --verify --deep --strict /Applications/Macomprendo.app exited with 1');
      }
    }
    return originalRun(cmd, args, options);
  };

  const code = await main([], deps);

  assert.equal(code, 1);
  assert.deepEqual(deps.fsOps.moves.at(-1), [
    '/Applications/.macomprendo-update.AB12/previous-Macomprendo.app',
    '/Applications/Macomprendo.app',
  ]);
  assert.ok(deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/Macomprendo.app'));
  assert.ok(!deps.fsOps.events.some((e) => e[0] === 'rmrf' && e[1] === '/Applications/.macomprendo-update.AB12'));
  assert.ok(deps.log.lines.some((l) => l.includes('Restored the previously installed app')));
});
