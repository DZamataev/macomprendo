// The published privacy statement, the README bullet, the changelog and the settings caption
// must agree about saved recordings. These read the real repository files rather than
// fixtures: a fixture cannot catch a stale claim shipping to users.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

import { ROOT, CHANGELOG_PATH } from '../lib/paths.mjs';

const PRIVACY_PATH = path.join(ROOT, 'PRIVACY.md');
const README_PATH = path.join(ROOT, 'README.md');
const SMOKE_TEST_PATH = path.join(ROOT, 'docs', 'SMOKE_TEST.md');
const GENERAL_TAB_PATH = path.join(
  ROOT, 'macos', 'Sources', 'Macomprendo', 'UI', 'Settings', 'GeneralTab.swift');

const read = (file) => fs.readFile(file, 'utf8');

// These documents wrap at 100 columns, so a sentence the reader sees as one phrase is several
// lines in the file. Compare against the squashed text or a wrapped claim looks absent.
const squash = (text) => text.replace(/\s+/g, ' ');

function unreleasedSection(changelog) {
  const start = changelog.indexOf('## [Unreleased]');
  assert.notEqual(start, -1, 'CHANGELOG.md has no [Unreleased] section');
  const next = changelog.indexOf('\n## ', start + 1);
  return next === -1 ? changelog.slice(start) : changelog.slice(start, next);
}

test('no user-facing document still claims the audio is never saved', async () => {
  for (const file of [PRIVACY_PATH, README_PATH, SMOKE_TEST_PATH, GENERAL_TAB_PATH]) {
    const text = await read(file);
    const stale = text
      .split('\n')
      .map((line, index) => ({ line, number: index + 1 }))
      .filter(({ line }) => /audio is never saved|never records audio|no audio is present/i.test(line));
    assert.deepEqual(stale, [], `${path.relative(ROOT, file)} still claims audio is never saved`);
  }
  // The changelog is a record of past releases, so only the section describing the upcoming
  // one may not carry the claim; released entries stay as they were published.
  const unreleased = unreleasedSection(await read(CHANGELOG_PATH));
  assert.doesNotMatch(unreleased, /audio is never saved/i);
});

test('PRIVACY.md states where saved recordings live, in what format, and for how long', async () => {
  const privacy = await read(PRIVACY_PATH);
  for (const claim of [
    'Save the original recording',
    'dictation-audio',
    '.m4a',
    'AAC',
    '90 days',
    'Clear History',
    'Delete saved audio',
    'FileVault',
  ]) {
    assert.ok(privacy.includes(claim), `PRIVACY.md does not mention ${claim}`);
  }
  // The app is deliberately unsandboxed (ADR-0003), so the privacy page must not imply
  // protection it does not provide.
  assert.match(privacy, /not sandboxed|unsandboxed/i);
  assert.match(squash(privacy), /any (program|process) running under your macOS account can read them/i);
});

test('README.md describes the optional recording instead of denying it', async () => {
  const readme = await read(README_PATH);
  assert.match(readme, /Save the original recording/);
});

test('CHANGELOG.md records the feature and the retention default under Unreleased', async () => {
  const unreleased = squash(unreleasedSection(await read(CHANGELOG_PATH)));
  assert.match(unreleased, /90 days/);
  assert.match(unreleased, /Keep history for/);
  assert.match(unreleased, /Save the original recording/);
});

test('the General tab caption agrees with PRIVACY.md about when recordings are stored', async () => {
  const general = squash(await read(GENERAL_TAB_PATH));
  assert.match(general, /Recordings are stored only/);
  assert.match(general, /Save the original recording/);
});

test('SMOKE_TEST.md covers the manual saved-audio checks unit tests cannot reach', async () => {
  const smoke = await read(SMOKE_TEST_PATH);
  for (const step of [
    'Save the original recording',
    'Show in Finder',
    'Delete saved audio',
    'Maximum recording length',
  ]) {
    assert.ok(smoke.includes(step), `docs/SMOKE_TEST.md does not cover ${step}`);
  }
});
