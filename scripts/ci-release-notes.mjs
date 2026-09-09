#!/usr/bin/env node
// Write the GitHub release notes for a pushed tag, and verify the tag agrees with the
// version the repository actually declares.
//
// The release workflow cannot reuse scripts/release.mjs: that script *drives* a release
// from a clean local checkout (bumping files, committing, tagging, pushing). By the time
// CI runs, the tag already exists and the only jobs left are validating it and producing
// the notes text for `gh release create --notes-file`.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import { ROOT } from './lib/paths.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';
import { tagVersion, releaseNotesFor } from './lib/release-notes.mjs';

export function parseNotesArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      tag: { type: 'string' },
      out: { type: 'string' },
    },
  });
  if (!values.tag) throw new Error('Pass the pushed tag with --tag vX.Y.Z.');
  if (!values.out) throw new Error('Pass the notes output path with --out <file>.');
  return { tag: values.tag, out: values.out };
}

export async function main(argv, deps = {}) {
  const {
    log = realLog, io = realIO, fsOps = realFsOps, root = ROOT,
  } = deps;

  let options;
  try {
    options = parseNotesArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  try {
    const version = tagVersion(options.tag);

    const declared = readVersion(await io.readFile(path.join(root, 'macos', 'project.yml')));
    if (declared !== version) {
      throw new Error(`Tag ${options.tag} does not match MARKETING_VERSION ${declared} in `
        + `macos/project.yml (expected v${declared}). Tag the release commit that `
        + 'npm run release created, or bump the version first.');
    }
    log.info(`Tag ${options.tag} matches MARKETING_VERSION ${declared}.`);

    const notes = releaseNotesFor(await io.readFile(path.join(root, 'CHANGELOG.md')), version);
    if (notes.source === 'unreleased-section') {
      log.warn(`CHANGELOG.md has no "## [${version}]" section; publishing the Unreleased `
        + 'entries as the release notes instead.');
    } else if (notes.source === 'none') {
      log.warn(`CHANGELOG.md has neither a "## [${version}]" section nor Unreleased entries; `
        + 'publishing a placeholder note.');
    }

    await fsOps.mkdirp(path.dirname(options.out));
    await io.writeFile(options.out, `${notes.body}\n`);
    log.info(`Wrote release notes to ${options.out} (source: ${notes.source}).`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
