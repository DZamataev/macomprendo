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
import { realIO } from './lib/fs.mjs';
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
  } catch {
    throw new Error('gh is not authenticated; run: gh auth login');
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
