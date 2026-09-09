import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

import {
  findNodeTestSpellingProblems, findUncoveredTestFiles, parseWorkflow, runCommands,
  findAuditSetupProblems, findReleasePublishProblems, findUnpinnedNodeJobs,
} from '../lib/workflows.mjs';
import { WORKFLOWS_DIR, PACKAGE_JSON } from '../lib/paths.mjs';

const read = (file) => fs.readFile(file, 'utf8');

async function workflow(name) {
  const text = await read(path.join(WORKFLOWS_DIR, name));
  return { text, document: parseWorkflow(text, { name }) };
}

// --- pure unit coverage -----------------------------------------------------

test('findNodeTestSpellingProblems flags a Node-expanded glob', () => {
  const hits = findNodeTestSpellingProblems([
    { source: 'ci:tooling', command: "node --test 'scripts/__tests__/**/*.test.mjs'" },
  ]);
  assert.equal(hits.length, 1);
  assert.match(hits[0].reason, /v21/);
});

test('findNodeTestSpellingProblems flags a bare directory argument', () => {
  const hits = findNodeTestSpellingProblems([
    { source: 'ci:tooling', command: 'node --test scripts/__tests__' },
  ]);
  assert.equal(hits.length, 1);
  assert.match(hits[0].reason, /Node 22/);
});

test('findNodeTestSpellingProblems accepts a shell-expanded glob of files', () => {
  assert.deepEqual(findNodeTestSpellingProblems([
    { source: 'ci:tooling', command: 'node --test scripts/__tests__/*.test.mjs' },
  ]), []);
});

test('findNodeTestSpellingProblems ignores commands that are not node --test', () => {
  assert.deepEqual(findNodeTestSpellingProblems([
    { source: 'ci:tooling', command: 'ls dist/Macomprendo-*-macos-unsigned.zip' },
    { source: 'ci:tooling', command: 'swift test --package-path macos' },
  ]), []);
});

test('findUncoveredTestFiles names test files a non-recursive glob would miss', () => {
  const command = 'node --test scripts/__tests__/*.test.mjs';
  assert.deepEqual(
    findUncoveredTestFiles(command, ['scripts/__tests__/a.test.mjs']),
    [],
  );
  assert.deepEqual(
    findUncoveredTestFiles(command, ['scripts/__tests__/nested/b.test.mjs']),
    ['scripts/__tests__/nested/b.test.mjs'],
  );
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

test('findUnpinnedNodeJobs flags a job that runs npm without setup-node', () => {
  const unpinned = parseWorkflow([
    'jobs:',
    '  macos:',
    '    steps:',
    '      - uses: actions/checkout@abc',
    '      - run: npm ci',
  ].join('\n'), { name: 'ci.yml' });
  const problems = findUnpinnedNodeJobs(unpinned, { name: 'ci' });
  assert.equal(problems.length, 1);
  assert.match(problems[0], /setup-node/);
});

test('findUnpinnedNodeJobs passes a pinned job and ignores npm-free jobs', () => {
  const good = parseWorkflow([
    'jobs:',
    '  macos:',
    '    steps:',
    '      - uses: actions/setup-node@abc',
    '      - run: npm ci',
    '  swift:',
    '    steps:',
    '      - run: swift test --package-path macos',
  ].join('\n'), { name: 'ci.yml' });
  assert.deepEqual(findUnpinnedNodeJobs(good, { name: 'ci' }), []);
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

test('no workflow spells node --test in a way some supported Node rejects', async () => {
  const names = (await fs.readdir(WORKFLOWS_DIR)).filter((f) => f.endsWith('.yml'));
  assert.ok(names.length > 0, 'expected workflows in .github/workflows');
  const commands = [];
  for (const name of names) {
    const { document } = await workflow(name);
    commands.push(...runCommands(document, { name: path.basename(name, '.yml') }));
  }
  assert.deepEqual(findNodeTestSpellingProblems(commands), []);
});

test('package.json test:scripts runs on every supported Node and covers every test file', async () => {
  const pkg = JSON.parse(await read(PACKAGE_JSON));
  const command = pkg.scripts['test:scripts'];
  assert.deepEqual(findNodeTestSpellingProblems([
    { source: 'package.json:test:scripts', command },
  ]), []);

  const testsDir = path.dirname(new URL(import.meta.url).pathname);
  const found = [];
  const walk = async (dir) => {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.name.endsWith('.test.mjs')) {
        found.push(path.join('scripts/__tests__', path.relative(testsDir, full)));
      }
    }
  };
  await walk(testsDir);
  assert.ok(found.length > 0);
  assert.deepEqual(findUncoveredTestFiles(command, found), []);
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

test('every job that runs npm pins its Node version', async () => {
  const names = (await fs.readdir(WORKFLOWS_DIR)).filter((f) => f.endsWith('.yml'));
  const problems = [];
  for (const name of names) {
    const { document } = await workflow(name);
    problems.push(...findUnpinnedNodeJobs(document, { name: path.basename(name, '.yml') }));
  }
  assert.deepEqual(problems, []);
});
