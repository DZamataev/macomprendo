import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { tagVersion, releaseNotesFor } from '../lib/release-notes.mjs';
import { main } from '../ci-release-notes.mjs';

const CHANGELOG = [
  '# Changelog',
  '',
  '## [Unreleased]',
  '',
  '### Added',
  '- something not yet released',
  '',
  '## [0.2.0] - 2026-09-09',
  '',
  '### Added',
  '- the released feature',
  '',
  '## [0.1.0] - 2026-01-01',
  '',
  '### Added',
  '- the first release',
  '',
].join('\n');

test('tagVersion accepts a vX.Y.Z tag', () => {
  assert.equal(tagVersion('v1.2.3'), '1.2.3');
});

test('tagVersion rejects anything else', () => {
  for (const tag of ['1.2.3', 'v1.2', 'v1.2.3-rc1', 'release-1.2.3', '']) {
    assert.throws(() => tagVersion(tag), /vX\.Y\.Z/, `expected ${tag} to be rejected`);
  }
});

test('releaseNotesFor uses the version section when the changelog has one', () => {
  const notes = releaseNotesFor(CHANGELOG, '0.2.0');
  assert.equal(notes.source, 'version-section');
  assert.match(notes.body, /the released feature/);
  assert.doesNotMatch(notes.body, /not yet released/);
});

// A tag pushed by hand (rather than by `npm run release`, which writes the section first)
// has no section of its own. Failing the release there would be unhelpful, and generating
// nothing would ship an empty release page — so the Unreleased entries, which are exactly
// what that tag contains, are used and clearly labelled as such.
test('releaseNotesFor falls back to the Unreleased section, labelled', () => {
  const notes = releaseNotesFor(CHANGELOG, '0.3.0');
  assert.equal(notes.source, 'unreleased-section');
  assert.match(notes.body, /not yet released/);
  assert.match(notes.body, /Unreleased/);
});

test('releaseNotesFor reports when neither section has content', () => {
  const notes = releaseNotesFor('# Changelog\n\n## [Unreleased]\n', '0.3.0');
  assert.equal(notes.source, 'none');
  assert.match(notes.body, /CHANGELOG\.md/);
});

test('releaseNotesFor prefers the exact version over a prefix match', () => {
  const notes = releaseNotesFor(CHANGELOG, '0.1.0');
  assert.equal(notes.source, 'version-section');
  assert.match(notes.body, /the first release/);
  assert.doesNotMatch(notes.body, /the released feature/);
});

async function tempRepo() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'macomprendo-ci-notes-'));
  await fs.mkdir(path.join(root, 'macos'), { recursive: true });
  await fs.writeFile(path.join(root, 'CHANGELOG.md'), CHANGELOG);
  await fs.writeFile(
    path.join(root, 'macos', 'project.yml'),
    ['targets:', '  Macomprendo:', '    settings:', '      base:',
      '        MARKETING_VERSION: "0.2.0"', ''].join('\n'),
  );
  return root;
}

function fakeLog() {
  const lines = [];
  return {
    lines,
    step: (m) => lines.push(`step ${m}`),
    info: (m) => lines.push(`info ${m}`),
    warn: (m) => lines.push(`warn ${m}`),
    error: (m) => lines.push(`error ${m}`),
  };
}

test('the CLI writes notes and accepts a tag matching MARKETING_VERSION', async () => {
  const root = await tempRepo();
  const out = path.join(root, 'dist', 'notes.md');
  const log = fakeLog();
  const code = await main(['--tag', 'v0.2.0', '--out', out], { root, log });
  assert.equal(code, 0);
  assert.match(await fs.readFile(out, 'utf8'), /the released feature/);
  await fs.rm(root, { recursive: true, force: true });
});

test('the CLI refuses a tag that disagrees with MARKETING_VERSION', async () => {
  const root = await tempRepo();
  const log = fakeLog();
  const code = await main(['--tag', 'v9.9.9', '--out', path.join(root, 'n.md')], { root, log });
  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => /MARKETING_VERSION/.test(l)));
  await fs.rm(root, { recursive: true, force: true });
});

test('the CLI rejects a malformed tag', async () => {
  const root = await tempRepo();
  const log = fakeLog();
  const code = await main(['--tag', 'release-0.2.0', '--out', path.join(root, 'n.md')], { root, log });
  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => /vX\.Y\.Z/.test(l)));
  await fs.rm(root, { recursive: true, force: true });
});

test('the CLI warns, but succeeds, when it falls back to Unreleased', async () => {
  const root = await tempRepo();
  await fs.writeFile(
    path.join(root, 'macos', 'project.yml'),
    ['targets:', '  Macomprendo:', '    settings:', '      base:',
      '        MARKETING_VERSION: "0.3.0"', ''].join('\n'),
  );
  const out = path.join(root, 'notes.md');
  const log = fakeLog();
  const code = await main(['--tag', 'v0.3.0', '--out', out], { root, log });
  assert.equal(code, 0);
  assert.ok(log.lines.some((l) => /warn/.test(l) && /Unreleased/.test(l)));
  assert.match(await fs.readFile(out, 'utf8'), /not yet released/);
  await fs.rm(root, { recursive: true, force: true });
});

test('the CLI requires both --tag and --out', async () => {
  const log = fakeLog();
  assert.equal(await main(['--tag', 'v0.2.0'], { root: '/tmp', log }), 2);
  assert.equal(await main(['--out', '/tmp/n.md'], { root: '/tmp', log }), 2);
});
