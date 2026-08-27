import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdtemp, writeFile, mkdir, stat, readFile, symlink, readlink, lstat,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  mkdirp, rmrf, copyPath, chmodExec, pathExists, listBundles, listFrameworks, realFsOps, realIO,
} from '../lib/fs.mjs';

async function scratch() {
  return mkdtemp(path.join(tmpdir(), 'macomprendo-fs-'));
}

test('mkdirp creates nested directories and is idempotent', async () => {
  const dir = await scratch();
  const deep = path.join(dir, 'a/b/c');
  await mkdirp(deep);
  await mkdirp(deep);
  assert.equal(await pathExists(deep), true);
});

test('rmrf removes a tree and tolerates a missing path', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'x/y'));
  await rmrf(path.join(dir, 'x'));
  assert.equal(await pathExists(path.join(dir, 'x')), false);
  await rmrf(path.join(dir, 'never-existed'));
});

test('copyPath copies files and directories recursively', async () => {
  const dir = await scratch();
  await mkdir(path.join(dir, 'src/inner'), { recursive: true });
  await writeFile(path.join(dir, 'src/inner/note.txt'), 'hello');
  await copyPath(path.join(dir, 'src'), path.join(dir, 'dst'));
  assert.equal(await readFile(path.join(dir, 'dst/inner/note.txt'), 'utf8'), 'hello');
});

test('copyPath preserves a relative symlink target instead of resolving it absolute', async () => {
  const dir = await scratch();
  // Mirror a macOS .framework's versioned-symlink layout:
  //   src/Versions/A/Headers/foo.h
  //   src/Versions/Current -> A                       (relative)
  //   src/Headers          -> Versions/Current/Headers (relative)
  await mkdir(path.join(dir, 'src/Versions/A/Headers'), { recursive: true });
  await writeFile(path.join(dir, 'src/Versions/A/Headers/foo.h'), 'int foo;');
  await symlink('A', path.join(dir, 'src/Versions/Current'));
  await symlink('Versions/Current/Headers', path.join(dir, 'src/Headers'));

  await copyPath(path.join(dir, 'src'), path.join(dir, 'dst'));

  const currentLink = await lstat(path.join(dir, 'dst/Versions/Current'));
  assert.equal(currentLink.isSymbolicLink(), true);
  assert.equal(await readlink(path.join(dir, 'dst/Versions/Current')), 'A');

  const headersLink = await lstat(path.join(dir, 'dst/Headers'));
  assert.equal(headersLink.isSymbolicLink(), true);
  assert.equal(await readlink(path.join(dir, 'dst/Headers')), 'Versions/Current/Headers');

  // The relative targets must still resolve inside the copy, standing on their own.
  assert.equal(await readFile(path.join(dir, 'dst/Headers/foo.h'), 'utf8'), 'int foo;');
});

test('chmodExec makes a file executable', async () => {
  const dir = await scratch();
  const file = path.join(dir, 'bin');
  await writeFile(file, '#!/bin/sh\n', { mode: 0o644 });
  await chmodExec(file);
  assert.equal((await stat(file)).mode & 0o111, 0o111);
});

test('listBundles returns sorted *.bundle directory names only', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'Macomprendo_Macomprendo.bundle'));
  await mkdirp(path.join(dir, 'zeta_target.bundle'));
  await mkdirp(path.join(dir, 'Modules'));
  await mkdirp(path.join(dir, 'whisper.framework'));
  await writeFile(path.join(dir, 'not-a-dir.bundle'), '');
  assert.deepEqual(await listBundles(dir),
    ['Macomprendo_Macomprendo.bundle', 'zeta_target.bundle']);
});

test('listFrameworks returns sorted *.framework directory names only', async () => {
  const dir = await scratch();
  await mkdirp(path.join(dir, 'whisper.framework'));
  await mkdirp(path.join(dir, 'Macomprendo_Macomprendo.bundle'));
  assert.deepEqual(await listFrameworks(dir), ['whisper.framework']);
});

test('listBundles and listFrameworks return an empty list for a missing directory', async () => {
  assert.deepEqual(await listBundles('/nope/does/not/exist'), []);
  assert.deepEqual(await listFrameworks('/nope/does/not/exist'), []);
});

test('realFsOps and realIO expose the operation bundles', async () => {
  for (const key of ['mkdirp', 'rmrf', 'copyPath', 'chmodExec', 'pathExists', 'listBundles', 'listFrameworks']) {
    assert.equal(typeof realFsOps[key], 'function', key);
  }
  for (const key of ['readFile', 'writeFile', 'exists']) {
    assert.equal(typeof realIO[key], 'function', key);
  }
  const dir = await scratch();
  await realIO.writeFile(path.join(dir, 'a.txt'), 'x');
  assert.equal(await realIO.readFile(path.join(dir, 'a.txt')), 'x');
  assert.equal(await realIO.exists(path.join(dir, 'a.txt')), true);
});
