#!/usr/bin/env node
// Refuse to publish sensitive filenames, machine-specific paths, or whitespace errors.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

import { ROOT } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realIO } from './lib/fs.mjs';

const SECRET_EXTENSIONS = /\.(p8|p12|pem|cer|key|keychain|mobileprovision|provisionprofile)$/;

export const UNSAFE_PATH_RULES = [
  { name: 'Xcode user state', test: (p) => /(^|\/)xcuserdata(\/|$)/.test(p) || /\.xcuserstate$/.test(p) },
  { name: 'SwiftPM local state', test: (p) => /(^|\/)\.swiftpm(\/|$)/.test(p) },
  { name: 'build output', test: (p) => /\.(xcarchive|xcresult|dSYM)(\/|$)/.test(p) },
  { name: 'notary log', test: (p) => /(^|\/)notary-log-[^/]*\.json$/.test(p) },
  { name: 'credential file', test: (p) => SECRET_EXTENSIONS.test(p) },
  {
    name: 'environment file',
    test: (p) => /(^|\/)\.env($|\.)/.test(p) && !/(^|\/)\.env\.example$/.test(p),
  },
];

export function findUnsafePaths(paths) {
  const hits = [];
  for (const candidate of paths) {
    const relative = candidate.trim();
    if (relative === '') continue;
    for (const rule of UNSAFE_PATH_RULES) {
      if (rule.test(relative)) {
        hits.push({ path: relative, rule: rule.name });
        break;
      }
    }
  }
  return hits;
}

// Asset formats. `.svg` is text, but the vendored Phosphor icons (see ADR-0008) are
// third-party assets copied verbatim by scripts/sync-icons.mjs — they are not ours to edit,
// and any path-like string inside them is upstream data, not a leak from this machine.
export const ASSET_EXTENSIONS = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.svg', '.icns', '.ico', '.pdf', '.zip', '.gz',
  '.ttf', '.otf', '.woff', '.woff2', '.mp3', '.wav', '.aiff', '.bin',
  '.metallib', '.dylib', '.a', '.o', '.xcframework', '.xcuserstate',
]);

export const CONTENT_SCAN_EXCLUDES = new Set([
  'scripts/audit-public-repo.mjs',
  'scripts/__tests__/audit-public-repo.test.mjs',
]);

export function shouldScanContent(relativePath) {
  if (CONTENT_SCAN_EXCLUDES.has(relativePath)) return false;
  return !ASSET_EXTENSIONS.has(path.extname(relativePath).toLowerCase());
}

const HOME_PATH = /\/Users\/([A-Za-z0-9._-]+)/g;
const DEFAULT_ALLOWED_HOMES = ['test', 'example', 'shared'];

export function findHomePaths(text, { file, allow = DEFAULT_ALLOWED_HOMES }) {
  const allowed = new Set(allow);
  const hits = [];
  const lines = text.split('\n');
  for (const [index, line] of lines.entries()) {
    HOME_PATH.lastIndex = 0;
    let match;
    while ((match = HOME_PATH.exec(line)) !== null) {
      if (allowed.has(match[1])) continue;
      hits.push({
        file,
        line: index + 1,
        column: match.index + 1,
        match: `/Users/${match[1]}`,
      });
    }
  }
  return hits;
}

async function hasGitleaks(run) {
  const result = await run('which', ['gitleaks'], { capture: true, check: false, cwd: ROOT });
  return (result.stdout ?? '').trim() !== '';
}

export async function main(argv, deps = {}) {
  const { run = realRun, log = realLog, io = realIO, root = ROOT } = deps;

  try {
    log.step('Listing candidate files');
    const listed = await run('git', ['ls-files', '--cached', '--others', '--exclude-standard'], {
      cwd: root, capture: true,
    });
    const files = (listed.stdout ?? '').split('\n').map((f) => f.trim()).filter((f) => f !== '');

    log.step('Checking filenames');
    const unsafe = findUnsafePaths(files);
    if (unsafe.length > 0) {
      log.error('Refusing publication because sensitive or generated files are visible:');
      for (const hit of unsafe) log.error(`  ${hit.path}  (${hit.rule})`);
      log.error('Remove them, add them to .gitignore, and rewrite history if they were ever committed.');
      return 1;
    }

    log.step('Checking for machine-specific home paths');
    const homeHits = [];
    for (const file of files) {
      if (!shouldScanContent(file)) continue;
      let text;
      try {
        text = await io.readFile(path.isAbsolute(file) ? file : path.join(root, file));
      } catch {
        continue; // unreadable or binary; the extension filter already covers the usual cases
      }
      homeHits.push(...findHomePaths(text, { file }));
    }
    if (homeHits.length > 0) {
      log.error('Replace or redact these machine-specific paths before publishing:');
      for (const hit of homeHits) log.error(`  ${hit.file}:${hit.line}:${hit.column}  ${hit.match}`);
      log.error('Use ~/, <repo>, or /Users/test instead.');
      return 1;
    }

    log.step('Checking whitespace and conflict markers');
    await run('git', ['diff', '--check'], { cwd: root });

    if (await hasGitleaks(run)) {
      log.step('Scanning candidate files with Gitleaks');
      await run('gitleaks', ['detect', '--source', '.', '--no-git', '--redact', '--no-banner'], { cwd: root });
      log.step('Scanning Git history with Gitleaks');
      await run('gitleaks', ['detect', '--source', '.', '--redact', '--no-banner'], { cwd: root });
    } else {
      log.info('Gitleaks is not installed; filename, path, and diff checks passed. '
        + 'Install it with: brew install gitleaks');
    }

    log.info('Public repository audit passed.');
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
