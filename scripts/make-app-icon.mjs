#!/usr/bin/env node
// Build all macOS icon representations from the approved transparent PNG master.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { run as realRun } from './lib/run.mjs';
import { log } from './lib/log.mjs';

export async function makeIcon(repoRoot, { run = realRun } = {}) {
  const bundle = path.join(repoRoot, 'macos/AppBundle');
  const master = path.join(bundle, 'AppIcon.png');
  await fs.access(master);
  const temporary = await fs.mkdtemp(path.join(bundle, '.icon-build-'));
  try {
    const iconset = path.join(temporary, 'AppIcon.iconset');
    await fs.mkdir(iconset);
    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const pixels = String(size * scale);
        const name = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`;
        await run('sips', ['-z', pixels, pixels, master, '--out', path.join(iconset, name)], { capture: true });
      }
    }
    const result = path.join(temporary, 'AppIcon.icns');
    await run('iconutil', ['-c', 'icns', iconset, '-o', result]);
    await fs.rename(result, path.join(bundle, 'AppIcon.icns'));
  } finally {
    await fs.rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    await makeIcon(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
    log.info('AppIcon.icns rebuilt from AppIcon.png.');
  } catch (error) {
    log.error(`${error.message}\nCheck AppIcon.png and ensure macOS sips and iconutil are available, then run npm run icon again.`);
    process.exitCode = 1;
  }
}
