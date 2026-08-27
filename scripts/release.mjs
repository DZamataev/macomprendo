#!/usr/bin/env node
// Bump the version, finalize the changelog, run the full test suite, tag, push,
// and publish a GitHub release.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';

import YAML from 'yaml';

import {
  ROOT, MACOS_DIR, PROJECT_YML, PBXPROJ, XCODEPROJ, CHANGELOG_PATH, DIST_DIR, SCHEME,
} from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion, bumpVersion } from './lib/version.mjs';
import { updateChangelog, extractSection } from './lib/changelog.mjs';

export const PROJECT_YML_VERSION = /^[ \t]*MARKETING_VERSION:[ \t]*"?(\d+\.\d+\.\d+)"?[ \t]*$/m;
export const PBXPROJ_VERSION = /^([ \t]*)MARKETING_VERSION = (\d+\.\d+\.\d+);$/gm;

const SEMVER = /^\d+\.\d+\.\d+$/;

function parts(version) {
  return version.split('.').map((n) => Number.parseInt(n, 10));
}

function isNewer(target, current) {
  const a = parts(target);
  const b = parts(current);
  for (let i = 0; i < 3; i += 1) {
    if (a[i] > b[i]) return true;
    if (a[i] < b[i]) return false;
  }
  return false;
}

export function resolveVersion(current, requested) {
  if (!['patch', 'minor', 'major'].includes(requested) && !SEMVER.test(requested)) {
    throw new Error('Version must be patch, minor, major, or an explicit X.Y.Z version.');
  }
  const target = bumpVersion(current, requested);
  if (!isNewer(target, current)) {
    throw new Error(`Requested version ${target} must be newer than ${current}.`);
  }
  return target;
}

export function replaceProjectYmlVersion(text, from, to) {
  const match = PROJECT_YML_VERSION.exec(text);
  if (match === null || match[1] !== from) {
    throw new Error(`macos/project.yml does not declare MARKETING_VERSION ${from} `
      + `(found ${match === null ? 'none' : match[1]}).`);
  }
  return text.replace(PROJECT_YML_VERSION, (line) => line.replace(from, to));
}

export function replacePbxprojVersions(text, from, to) {
  const matches = [...text.matchAll(PBXPROJ_VERSION)];
  if (matches.length === 0) {
    throw new Error('macos/Macomprendo.xcodeproj/project.pbxproj has no MARKETING_VERSION declarations.');
  }
  const found = [...new Set(matches.map((m) => m[2]))];
  if (found.length !== 1 || found[0] !== from) {
    throw new Error(`macos/Macomprendo.xcodeproj/project.pbxproj declares MARKETING_VERSION `
      + `${found.join(', ')} but ${from} was expected. Run: npm run gen`);
  }
  return text.replace(PBXPROJ_VERSION, (_line, indent) => `${indent}MARKETING_VERSION = ${to};`);
}

export function assertProjectYmlParses(text, version) {
  let document;
  try {
    document = YAML.parse(text);
  } catch (error) {
    throw new Error(`macos/project.yml is not valid YAML: ${error.message}`);
  }
  const settings = document?.targets?.Macomprendo?.settings?.base ?? {};
  const parsed = String(settings.MARKETING_VERSION ?? '');
  if (parsed !== version) {
    throw new Error(`macos/project.yml parsed MARKETING_VERSION ${parsed || 'none'} `
      + `does not match ${version}.`);
  }
}

export async function preflight(version, { run, log, root = ROOT }) {
  const capture = async (cmd, args) => (await run(cmd, args, { cwd: root, capture: true })).stdout.trim();

  log.step('Checking the repository state');

  const toplevel = await capture('git', ['rev-parse', '--show-toplevel']);
  if (path.resolve(toplevel) !== path.resolve(root)) {
    throw new Error(`Run this from the ${root} checkout (git reports ${toplevel}).`);
  }

  const status = await capture('git', ['status', '--porcelain']);
  if (status !== '') {
    throw new Error('The working tree is not clean; commit or stash your changes first.');
  }

  const branch = await capture('git', ['branch', '--show-current']);
  if (branch !== 'main') {
    throw new Error(`Releases must run from main, not "${branch || 'detached HEAD'}".`);
  }

  try {
    await run('gh', ['auth', 'status'], { cwd: root });
  } catch (error) {
    if (error.message.includes('ENOENT') || error.message.includes('spawn')) {
      throw new Error('gh is not installed; run: brew install gh');
    }
    if (error.message.includes('not logged in') || error.message.includes('not authenticated')) {
      throw new Error('gh is not authenticated; run: gh auth login');
    }
    throw error;
  }

  await run('git', ['fetch', 'origin', 'main', '--tags'], { cwd: root });

  const head = await capture('git', ['rev-parse', 'HEAD']);
  const remote = await capture('git', ['rev-parse', 'origin/main']);
  if (head !== remote) {
    throw new Error('Local main must exactly match origin/main before releasing; push or pull first.');
  }

  const tag = await capture('git', ['ls-remote', '--tags', 'origin', `refs/tags/v${version}`]);
  if (tag !== '') {
    throw new Error(`Tag v${version} already exists on the remote.`);
  }

  log.info('Preflight checks passed.');
}

export function parseReleaseArgs(argv) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      'dry-run': { type: 'boolean', default: false },
      yes: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  if (positionals.length > 1) {
    throw new Error('Pass exactly one version argument: patch, minor, major, or X.Y.Z.');
  }
  return {
    requested: positionals[0] ?? 'patch',
    dryRun: values['dry-run'],
    yes: values.yes,
    help: values.help,
  };
}

export async function prepareFiles({ current, version, isoDate, io }) {
  const projectYml = replaceProjectYmlVersion(await io.readFile(PROJECT_YML), current, version);
  const pbxproj = replacePbxprojVersions(await io.readFile(PBXPROJ), current, version);
  const changelog = updateChangelog(await io.readFile(CHANGELOG_PATH), version, isoDate);
  assertProjectYmlParses(projectYml, version);

  await io.writeFile(PROJECT_YML, projectYml);
  await io.writeFile(PBXPROJ, pbxproj);
  await io.writeFile(CHANGELOG_PATH, changelog);
  return [PROJECT_YML, PBXPROJ, CHANGELOG_PATH];
}

export function planRelease({ version, notesPath, assets }) {
  const exec = (cmd, args) => ({ type: 'exec', cmd, args });
  return [
    exec('npm', ['run', 'test:scripts']),
    exec('swift', ['test', '--package-path', 'macos']),
    exec('xcodebuild', [
      '-project', 'macos/Macomprendo.xcodeproj',
      '-scheme', SCHEME,
      '-configuration', 'Release',
      '-destination', 'generic/platform=macOS',
      'CODE_SIGNING_ALLOWED=NO',
      'build',
    ]),
    exec('git', ['diff', '--check']),
    exec('git', ['add', 'macos/project.yml', 'macos/Macomprendo.xcodeproj/project.pbxproj', 'CHANGELOG.md']),
    exec('git', ['commit', '-m', `Release ${version}`]),
    exec('git', ['tag', '-a', `v${version}`, '-m', `Macomprendo ${version}`]),
    exec('git', ['push', 'origin', 'main']),
    exec('git', ['push', 'origin', `v${version}`]),
    exec('gh', [
      'release', 'create', `v${version}`,
      '--target', 'main',
      '--title', `Macomprendo ${version}`,
      '--notes-file', notesPath,
      '--latest',
      ...assets,
    ]),
  ];
}

export function confirm(question, io = { input: process.stdin, output: process.stdout }) {
  return new Promise((resolve, reject) => {
    const rl = createInterface({ input: io.input, output: io.output, terminal: true });
    rl.on('error', reject);
    rl.question(question, (answer) => {
      rl.close();
      resolve(['y', 'yes'].includes(answer.trim().toLowerCase()));
    });
  });
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, io = realIO, fsOps = realFsOps,
    now = () => new Date(), root = ROOT, dist = DIST_DIR, ask = confirm,
  } = deps;

  let options;
  try {
    options = parseReleaseArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run release -- [patch|minor|major|X.Y.Z] [--dry-run] [--yes]',
      '',
      '  --dry-run  resolve the version and print the plan without changing anything',
      '  --yes      publish without the interactive confirmation',
    ].join('\n'));
    return 0;
  }

  try {
    const current = readVersion(await io.readFile(PROJECT_YML));
    const version = resolveVersion(current, options.requested);
    const isoDate = now().toISOString().slice(0, 10);

    // Validate the changelog before any network or repository work.
    const releasedChangelog = updateChangelog(await io.readFile(CHANGELOG_PATH), version, isoDate);
    const notes = extractSection(releasedChangelog, version);
    const notesPath = path.join(dist, `release-notes-${version}.md`);
    const assetPath = path.join(dist, `Macomprendo-${version}-macos.zip`);

    log.info(`Current version: ${current}`);
    log.info(`Release version: ${version}`);
    log.info(`Changelog heading: ## [${version}] - ${isoDate}`);
    log.info(`Release notes:\n${notes}`);

    if (options.dryRun) {
      log.info('Planned commands:');
      for (const step of planRelease({ version, notesPath, assets: [] })) {
        log.info(`  ${[step.cmd, ...step.args].join(' ')}`);
      }
      log.info('Dry run complete; no files, tags or remote state changed.');
      return 0;
    }

    await preflight(version, { run, log, root });

    if (!options.yes && !(await ask(`Publish Macomprendo ${version}? [y/N] `))) {
      log.info('Release cancelled.');
      return 1;
    }

    await prepareFiles({ current, version, isoDate, io });
    await fsOps.mkdirp(dist);
    await io.writeFile(notesPath, `${notes}\n`);

    const assets = (await io.exists(assetPath)) ? [assetPath] : [];
    if (assets.length === 0) {
      log.warn(`No notarized artifact at ${assetPath}; publishing release notes only. `
        + 'Run "npm run notarize" first if you want to attach the ZIP.');
    }

    for (const step of planRelease({ version, notesPath, assets })) {
      log.step([step.cmd, ...step.args].join(' '));
      await run(step.cmd, step.args, { cwd: root });
    }

    const url = await run('gh', ['release', 'view', `v${version}`, '--json', 'url', '--jq', '.url'],
      { cwd: root, capture: true });
    log.info(`Published ${version}: ${(url.stdout ?? '').trim()}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
