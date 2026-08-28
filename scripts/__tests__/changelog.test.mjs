import { test } from 'node:test';
import assert from 'node:assert/strict';
import { updateChangelog, extractSection } from '../lib/changelog.mjs';

const SAMPLE = `# Changelog

## [Unreleased]

### Added
- Dictation hotkey.

### Fixed
- Pasteboard restore race.

## [0.1.0] - 2026-08-01

- First release.
`;

test('updateChangelog dates the Unreleased entries and keeps an empty Unreleased heading', () => {
  const updated = updateChangelog(SAMPLE, '0.2.0', '2026-08-23');
  assert.match(updated, /## \[Unreleased\]\n\n## \[0\.2\.0\] - 2026-08-23\n\n### Added\n- Dictation hotkey\./);
  assert.equal(updated.match(/- Dictation hotkey\./g).length, 1);
  assert.ok(updated.includes('## [0.1.0] - 2026-08-01'));
  assert.ok(updated.startsWith('# Changelog\n'));
});

test('updateChangelog works when there is no previous release section', () => {
  const text = '# Changelog\n\n## [Unreleased]\n\n- Only entry.\n';
  const updated = updateChangelog(text, '0.1.0', '2026-08-23');
  assert.equal(updated, '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-23\n\n- Only entry.\n');
});

test('updateChangelog refuses an empty Unreleased section', () => {
  const text = '# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n';
  assert.throws(() => updateChangelog(text, '0.2.0', '2026-08-23'),
    /no entries under "## \[Unreleased\]"/);
});

test('updateChangelog refuses a missing Unreleased heading', () => {
  assert.throws(() => updateChangelog('# Changelog\n\n## [0.1.0] - 2026-08-01\n\n- Old.\n', '0.2.0', '2026-08-23'),
    /missing an "## \[Unreleased\]" heading/);
});

test('extractSection returns the notes body for one version', () => {
  const released = updateChangelog(SAMPLE, '0.2.0', '2026-08-23');
  assert.equal(
    extractSection(released, '0.2.0'),
    '### Added\n- Dictation hotkey.\n\n### Fixed\n- Pasteboard restore race.',
  );
  assert.equal(extractSection(released, '0.1.0'), '- First release.');
});

test('extractSection throws for an unknown version', () => {
  assert.throws(() => extractSection(SAMPLE, '9.9.9'), /no "## \[9\.9\.9\]" section/);
});
