import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  findNodeTestGlobs, parseWorkflow, runCommands,
  findAuditSetupProblems, findReleasePublishProblems,
} from '../lib/workflows.mjs';
import { WORKFLOWS_DIR, PACKAGE_JSON } from '../lib/paths.mjs';

const read = (file) => fs.readFile(file, 'utf8');

async function workflow(name) {
  const text = await read(path.join(WORKFLOWS_DIR, name));
  return { text, document: parseWorkflow(text, { name }) };
}

// --- pure unit coverage -----------------------------------------------------

test('findNodeTestGlobs flags a glob argument to node --test', () => {
  const hits = findNodeTestGlobs([
    { source: 'ci:tooling', command: "node --test 'scripts/__tests__/**/*.test.mjs'" },
  ]);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].source, 'ci:tooling');
});

test('findNodeTestGlobs accepts a directory argument', () => {
  assert.deepEqual(findNodeTestGlobs([
    { source: 'ci:tooling', command: 'node --test scripts/__tests__' },
  ]), []);
});

test('findNodeTestGlobs ignores globs that are not node --test arguments', () => {
  assert.deepEqual(findNodeTestGlobs([
    { source: 'ci:tooling', command: 'ls dist/Macomprendo-*-macos-unsigned.zip' },
    { source: 'ci:tooling', command: 'node --test scripts/__tests__\nls dist/*.zip' },
  ]), []);
});

test('parseWorkflow rejects text that is not a workflow object', () => {
  assert.throws(() => parseWorkflow('just a string', { name: 'x.yml' }), /workflow object/);
  assert.throws(() => parseWorkflow('a: [', { name: 'x.yml' }), /not valid YAML/);
});

test('runCommands tags every run step with its workflow and job', () => {
  const document = parseWorkflow([
    'jobs:',
    '  build:',
    '    steps:',
    '      - uses: actions/checkout@abc',
    '      - run: make',
  ].join('\n'), { name: 'ci.yml' });
  assert.deepEqual(runCommands(document, { name: 'ci' }), [
    { source: 'ci:build', command: 'make' },
  ]);
});

test('findAuditSetupProblems wants gitleaks installed and full history before the audit', () => {
  const shallow = parseWorkflow([
    'jobs:',
    '  tooling:',
    '    steps:',
    '      - uses: actions/checkout@abc',
    '      - run: npm run audit',
  ].join('\n'), { name: 'ci.yml' });
  const problems = findAuditSetupProblems(shallow, { name: 'ci' });
  assert.equal(problems.length, 2);
  assert.ok(problems.some((p) => /installing gitleaks/.test(p)));
  assert.ok(problems.some((p) => /shallow clone/.test(p)));
});

test('findAuditSetupProblems passes a job that installs gitleaks on a full clone', () => {
  const good = parseWorkflow([
    'jobs:',
    '  tooling:',
    '    steps:',
    '      - uses: actions/checkout@abc',
    '        with:',
    '          fetch-depth: 0',
    '      - run: install gitleaks',
    '      - run: npm run audit',
  ].join('\n'), { name: 'ci.yml' });
  assert.deepEqual(findAuditSetupProblems(good, { name: 'ci' }), []);
});

test('findAuditSetupProblems ignores jobs that never audit', () => {
  const none = parseWorkflow([
    'jobs:',
    '  macos:',
    '    steps:',
    '      - run: swift test',
  ].join('\n'), { name: 'ci.yml' });
  assert.deepEqual(findAuditSetupProblems(none, { name: 'ci' }), []);
});

test('findReleasePublishProblems reports a workflow that only uploads an artifact', () => {
  const artifactOnly = parseWorkflow([
    'on:',
    '  push:',
    '    tags:',
    "      - 'v[0-9]*'",
    'jobs:',
    '  build:',
    '    steps:',
    '      - uses: actions/upload-artifact@abc',
  ].join('\n'), { name: 'release.yml' });
  const problems = findReleasePublishProblems(artifactOnly, { name: 'release' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /never runs "gh release create"/);
});

test('findReleasePublishProblems requires contents: write, both assets and notes', () => {
  const missing = parseWorkflow([
    'on:',
    '  push:',
    '    tags:',
    "      - 'v[0-9]*'",
    'permissions:',
    '  contents: read',
    'jobs:',
    '  publish:',
    '    steps:',
    '      - run: gh release create "v1.0.0" "dist/Macomprendo-1.0.0-macos-unsigned.zip"',
  ].join('\n'), { name: 'release.yml' });
  const problems = findReleasePublishProblems(missing, { name: 'release' });
  assert.ok(problems.some((p) => /contents: write/.test(p)));
  assert.ok(problems.some((p) => /\.sha256/.test(p)));
  assert.ok(problems.some((p) => /no notes source/.test(p)));
});

test('findReleasePublishProblems accepts a job-scoped contents: write grant', () => {
  const good = parseWorkflow([
    'on:',
    '  push:',
    '    tags:',
    "      - 'v[0-9]*'",
    'permissions:',
    '  contents: read',
    'jobs:',
    '  publish:',
    '    permissions:',
    '      contents: write',
    '    steps:',
    '      - run: |',
    '          ZIP="dist/Macomprendo-1.0.0-macos-unsigned.zip"',
    '          gh release create "$TAG" --notes-file notes.md "$ZIP" "${ZIP}.sha256"',
  ].join('\n'), { name: 'release.yml' });
  assert.deepEqual(findReleasePublishProblems(good, { name: 'release' }), []);
});

test('findReleasePublishProblems reports a workflow with no tag trigger', () => {
  const noTag = parseWorkflow([
    'on:',
    '  workflow_dispatch:',
    'jobs:',
    '  publish:',
    '    permissions:',
    '      contents: write',
    '    steps:',
    '      - run: |',
    '          ZIP="dist/Macomprendo-1.0.0-macos-unsigned.zip"',
    '          gh release create v1 --notes-file n.md "$ZIP" "${ZIP}.sha256"',
  ].join('\n'), { name: 'release.yml' });
  const problems = findReleasePublishProblems(noTag, { name: 'release' });
  assert.deepEqual(problems, ['release does not trigger on a tag push.']);
});

// --- the workflows actually committed to this repository --------------------

test('no workflow passes a glob to node --test', async () => {
  const names = (await fs.readdir(WORKFLOWS_DIR)).filter((f) => f.endsWith('.yml'));
  assert.ok(names.length > 0, 'expected workflows in .github/workflows');
  const commands = [];
  for (const name of names) {
    const { document } = await workflow(name);
    commands.push(...runCommands(document, { name: path.basename(name, '.yml') }));
  }
  assert.deepEqual(findNodeTestGlobs(commands), []);
});

test('package.json test:scripts uses a directory, not a glob', async () => {
  const pkg = JSON.parse(await read(PACKAGE_JSON));
  assert.deepEqual(findNodeTestGlobs([
    { source: 'package.json:test:scripts', command: pkg.scripts['test:scripts'] },
  ]), []);
});

test('every committed workflow audits on a full clone with gitleaks available', async () => {
  const names = (await fs.readdir(WORKFLOWS_DIR)).filter((f) => f.endsWith('.yml'));
  const problems = [];
  for (const name of names) {
    const { document } = await workflow(name);
    problems.push(...findAuditSetupProblems(document, { name: path.basename(name, '.yml') }));
  }
  assert.deepEqual(problems, []);
});

test('the release workflow publishes the ZIP and its checksum on a tag', async () => {
  const { document } = await workflow('release.yml');
  assert.deepEqual(findReleasePublishProblems(document, { name: 'release' }), []);
});
