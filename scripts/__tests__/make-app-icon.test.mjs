import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

test('failed conversion preserves the installed icon source and cleans temporary files', async () => {
  const { makeIcon } = await import('../make-app-icon.mjs');
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'macomprendo-icon-'));
  const bundle = path.join(root, 'macos/AppBundle');
  await fs.mkdir(bundle, { recursive: true });
  await fs.writeFile(path.join(bundle, 'AppIcon.png'), 'master');
  await fs.writeFile(path.join(bundle, 'AppIcon.icns'), 'previous');
  try {
    await assert.rejects(makeIcon(root, { run: async () => { throw new Error('conversion failed'); } }), /conversion failed/);
    assert.equal(await fs.readFile(path.join(bundle, 'AppIcon.icns'), 'utf8'), 'previous');
    assert.deepEqual((await fs.readdir(bundle)).sort(), ['AppIcon.icns', 'AppIcon.png']);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
