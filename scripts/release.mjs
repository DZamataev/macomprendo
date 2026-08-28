#!/usr/bin/env node
// Bump the version, finalize the changelog, run the full test suite, tag, push,
// and publish a GitHub release.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import YAML from 'yaml';

import {
  ROOT, PROJECT_YML, PBXPROJ, CHANGELOG_PATH, DIST_DIR, SCHEME,
} from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion, bumpVersion } from './lib/version.mjs';
import { updateChangelog, extractSection } from './lib/changelog.mjs';
import { prompt } from './lib/prompt.mjs';
import { describeStep } from './build-app.mjs';

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
      notarize: { type: 'boolean', default: false },
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
    notarize: values.notarize,
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

export function planRelease({ version, notesPath, assets, notarize = false }) {
  const exec = (cmd, args) => ({ type: 'exec', cmd, args });
  const steps = [
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
  ];
  // Runs after prepareFiles has already rewritten macos/project.yml, so the ZIP
  // notarize-app.mjs names and builds is stamped with the *new* version — and before
  // the commit, so a failed notarization never leaves a bumped, committed tree with no
  // artifact to show for it.
  if (notarize) {
    steps.push(exec('node', ['scripts/notarize-app.mjs']));
  }
  steps.push(
    exec('git', ['add', 'macos/project.yml', 'macos/Macomprendo.xcodeproj/project.pbxproj', 'CHANGELOG.md']),
    exec('git', ['commit', '-m', `chore(release): ${version}`]),
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
  );
  return steps;
}

/**
 * Renders a concrete post-failure state block: exactly which irreversible steps of a
 * real release already happened before the plan failed, and the command that undoes
 * each one — so a failure never leaves the operator guessing what state the repo is in.
 */
export function describeReleaseState({
  version, filesRewritten, commitCreated, mainPushed, tagCreated, tagPushed, released,
}) {
  const line = (label, done, undo) => (done
    ? `  [x] ${label} — undo: ${undo}`
    : `  [ ] ${label}`);
  return [
    'Release state after the failure:',
    line('Version files rewritten (macos/project.yml, project.pbxproj, CHANGELOG.md)', filesRewritten,
      'git checkout -- macos/project.yml macos/Macomprendo.xcodeproj/project.pbxproj CHANGELOG.md'),
    line(`Commit created (chore(release): ${version})`, commitCreated, 'git reset --hard HEAD~1'),
    line('Commit pushed to origin/main', mainPushed, 'coordinate a revert with the team; origin/main is public'),
    line(`Tag created locally (v${version})`, tagCreated, `git tag -d v${version}`),
    line(`Tag pushed to origin (v${version})`, tagPushed, `git push origin :refs/tags/v${version}`),
    line(`GitHub release published (v${version})`, released, `gh release delete v${version} --yes`),
  ].join('\n');
}

export function confirm(question, io = { input: process.stdin, output: process.stdout }) {
  return prompt(question, io, { eofMessage: 'stdin is not interactive; re-run with --yes.' })
    .then((answer) => ['y', 'yes'].includes(answer.toLowerCase()));
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
      'Usage: npm run release -- [patch|minor|major|X.Y.Z] [--dry-run] [--yes] [--notarize]',
      '',
      '  --dry-run   resolve the version and print the plan without changing anything',
      '  --yes       publish without the interactive confirmation',
      '  --notarize  build, sign and notarize a fresh ZIP for the bumped version and',
      '              attach it to the GitHub release (slow; contacts Apple). Without',
      '              this flag the release publishes notes only.',
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
    // Computed once and reused for both the dry-run plan and the real one, so the
    // printed plan is always the plan that would actually execute. A pre-existing ZIP
    // from an earlier, differently-versioned notarize run is never attached: the
    // filename and its internal MARKETING_VERSION only line up with this release once
    // notarize-app.mjs runs (as the plan's own notarize step) after prepareFiles has
    // already bumped macos/project.yml.
    // notarize-app.mjs's plan always ends with a `sha256` step that writes `${final}.sha256`
    // right next to the ZIP it names (see planNotarize) — whenever notarize runs as part of
    // this release, that sidecar is guaranteed to exist by the time this gh release create
    // step runs. README.md tells downloaders to verify with it, so it must travel with the ZIP.
    const assets = options.notarize ? [assetPath, `${assetPath}.sha256`] : [];
    const attachmentNote = options.notarize
      ? `The notarized build will be built fresh and attached: ${path.basename(assetPath)}.`
      : 'This will publish release notes only; no build artifact will be attached '
        + '(pass --notarize to build, sign, notarize and attach one).';

    log.info(`Current version: ${current}`);
    log.info(`Release version: ${version}`);
    log.info(`Changelog heading: ## [${version}] - ${isoDate}`);
    log.info(`Release notes:\n${notes}`);
    log.info(attachmentNote);

    if (options.dryRun) {
      log.info('Planned commands:');
      for (const step of planRelease({ version, notesPath, assets, notarize: options.notarize })) {
        log.info(`  ${describeStep(step)}`);
      }
      log.info('Dry run complete; no files, tags or remote state changed.');
      return 0;
    }

    await preflight(version, { run, log, root });

    const question = options.notarize
      ? `Publish Macomprendo ${version} with the notarized build attached? [y/N] `
      : `Publish Macomprendo ${version} with release notes only (no build attached)? [y/N] `;
    if (!options.yes && !(await ask(question))) {
      log.info('Release cancelled.');
      return 1;
    }

    // From here on, failures are reported with a concrete state block instead of a
    // bare error: once prepareFiles has rewritten the tracked files, a mid-plan
    // failure leaves real, undoable state behind that the operator must be told about.
    let filesRewritten = false;
    let commitCreated = false;
    let mainPushed = false;
    let tagCreated = false;
    let tagPushed = false;
    let released = false;

    try {
      await prepareFiles({ current, version, isoDate, io });
      filesRewritten = true;
      await fsOps.mkdirp(dist);
      await io.writeFile(notesPath, `${notes}\n`);

      for (const step of planRelease({ version, notesPath, assets, notarize: options.notarize })) {
        log.step(describeStep(step));
        await run(step.cmd, step.args, { cwd: root });

        if (step.cmd === 'git' && step.args[0] === 'commit') commitCreated = true;
        if (step.cmd === 'git' && step.args[0] === 'push' && step.args[2] === 'main') mainPushed = true;
        if (step.cmd === 'git' && step.args[0] === 'tag') tagCreated = true;
        if (step.cmd === 'git' && step.args[0] === 'push' && step.args[2] === `v${version}`) tagPushed = true;
        if (step.cmd === 'gh') released = true;
      }
    } catch (error) {
      log.error(error.message);
      log.error(describeReleaseState({
        version, filesRewritten, commitCreated, mainPushed, tagCreated, tagPushed, released,
      }));
      return 1;
    }

    // The release already published successfully at this point (the loop above
    // completed without throwing) — a transient failure looking up its URL must not
    // report the release itself as failed and invite deleting a tag that is now public.
    try {
      const url = await run('gh', ['release', 'view', `v${version}`, '--json', 'url', '--jq', '.url'],
        { cwd: root, capture: true });
      log.info(`Published ${version}: ${(url.stdout ?? '').trim()}`);
    } catch (error) {
      log.warn(`Release v${version} was published, but looking up its URL failed: ${error.message} `
        + `Check with: gh release view v${version}`);
    }
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
