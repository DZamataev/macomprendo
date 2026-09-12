#!/usr/bin/env node
// Refuse to publish sensitive filenames, machine-specific paths, or whitespace errors.
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

import { ROOT } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realIO } from './lib/fs.mjs';

// `.keychain-db` has been the actual default macOS keychain format since Sierra, and it's
// the standard name CI scripts give a temporary signing keychain — must be caught alongside
// the legacy `.keychain` extension, not just the bare one. Case-insensitive: `cert.P12` or
// `profile.MOBILEPROVISION` are just as unsafe as their lowercase spellings, and
// shouldScanContent already lowercases before comparing asset extensions, so this
// classifier should be no less careful.
const SECRET_EXTENSIONS = /\.(p8|p12|pem|cer|key|keychain(-db)?|mobileprovision|provisionprofile)$/i;

export const UNSAFE_PATH_RULES = [
  { name: 'Xcode user state', test: (p) => /(^|\/)xcuserdata(\/|$)/.test(p) || /\.xcuserstate$/.test(p) },
  { name: 'SwiftPM local state', test: (p) => /(^|\/)\.swiftpm(\/|$)/.test(p) },
  { name: 'build output', test: (p) => /\.(xcarchive|xcresult|dSYM)(\/|$)/.test(p) },
  { name: 'notary log', test: (p) => /(^|\/)notary-log-[^/]*\.json$/.test(p) },
  { name: 'credential file', test: (p) => SECRET_EXTENSIONS.test(p) },
  // Extension-less SSH private keys: ssh-keygen's default names, never given a suffix.
  { name: 'SSH private key', test: (p) => /(^|\/)id_(rsa|dsa|ecdsa|ed25519)$/i.test(p) },
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

// Vendored icons (see ADR-0008) are third-party assets copied verbatim by
// scripts/sync-icons.mjs — they are not ours to edit, and any path-like string inside them
// is upstream data, not a leak from this machine. That exemption is scoped to the exact
// vendored directory below, not to `.svg` as a format: a design-tool SVG export anywhere
// else in the repo routinely embeds an absolute path in its generator metadata and must
// still be scanned.
const VENDORED_ICON_DIR = 'macos/Sources/Macomprendo/Resources/Icons/';

export const ASSET_EXTENSIONS = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.icns', '.ico', '.pdf', '.zip', '.gz',
  '.ttf', '.otf', '.woff', '.woff2', '.mp3', '.wav', '.aiff', '.bin',
  '.metallib', '.dylib', '.a', '.o', '.xcframework', '.xcuserstate',
]);

// Both files below genuinely contain non-allowlisted `/Users/<name>` fixtures (this file's
// own home-path regex, and that test's illustrative hits) — excluding them from the content
// scan is what lets the audit pass at all. Do not paste a real home path into either file
// believing it will be caught: it will not be scanned.
export const CONTENT_SCAN_EXCLUDES = new Set([
  'scripts/audit-public-repo.mjs',
  'scripts/__tests__/audit-public-repo.test.mjs',
]);

export function shouldScanContent(relativePath) {
  if (CONTENT_SCAN_EXCLUDES.has(relativePath)) return false;
  if (relativePath.startsWith(VENDORED_ICON_DIR) && relativePath.toLowerCase().endsWith('.svg')) return false;
  return !ASSET_EXTENSIONS.has(path.extname(relativePath).toLowerCase());
}

const HOME_PATH = /\/Users\/([A-Za-z0-9._-]+)/g;
const DEFAULT_ALLOWED_HOMES = ['test', 'example', 'shared'];

// Telegram chat and thread ids identify a private group the operator owns. They are not
// credentials, so Gitleaks ignores them, but publishing one invites strangers into that
// group — and unlike a key it cannot be rotated without moving everyone. They belong in
// .env.local; this catches the copy-paste that would otherwise put one in a runbook.
// Telegram supergroup ids are -100 followed by ten or more digits.
const TELEGRAM_CHAT_ID = /-100\d{10,}/g;

export function findTelegramChatIds(text, { file }) {
  const hits = [];
  for (const [index, line] of text.split('\n').entries()) {
    TELEGRAM_CHAT_ID.lastIndex = 0;
    let match;
    while ((match = TELEGRAM_CHAT_ID.exec(line)) !== null) {
      hits.push({ file, line: index + 1, column: match.index + 1, match: match[0] });
    }
  }
  return hits;
}

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
  // A signal-killed `which` resolves under check:false with code: null and empty stdout —
  // indistinguishable from "not installed" unless checked explicitly. Reporting that as a
  // confirmed negative would let the audit pass having never actually asked the question.
  if (result.code === null) {
    throw new Error(`which gitleaks was killed (signal ${result.signal}); `
      + 'cannot tell whether Gitleaks is installed.');
  }
  return (result.stdout ?? '').trim() !== '';
}

export async function stageCandidateFiles(files, { root }) {
  const stagedRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'macomprendo-gitleaks-'));
  try {
    for (const file of files) {
      if (path.isAbsolute(file) || file.split(path.sep).includes('..')) {
        throw new Error(`Refusing to stage an unsafe candidate path: ${file}`);
      }
      const source = path.join(root, file);
      const destination = path.join(stagedRoot, file);
      let stats;
      try {
        stats = await fs.lstat(source);
      } catch (error) {
        if (error?.code === 'ENOENT') continue;
        throw error;
      }
      await fs.mkdir(path.dirname(destination), { recursive: true });
      if (stats.isSymbolicLink()) {
        await fs.symlink(await fs.readlink(source), destination);
      } else if (stats.isFile()) {
        try {
          await fs.link(source, destination);
        } catch (error) {
          if (error?.code !== 'EXDEV') throw error;
          await fs.copyFile(source, destination);
        }
      }
    }
  } catch (error) {
    await fs.rm(stagedRoot, { recursive: true, force: true });
    throw error;
  }
  return {
    root: stagedRoot,
    cleanup: () => fs.rm(stagedRoot, { recursive: true, force: true }),
  };
}

export async function main(argv, deps = {}) {
  const {
    run = realRun,
    log = realLog,
    io = realIO,
    root = ROOT,
    stageCandidateFiles: stageFiles = stageCandidateFiles,
  } = deps;

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

    log.step('Checking for machine-specific home paths and private chat ids');
    const homeHits = [];
    const chatIdHits = [];
    const unreadableHits = [];
    for (const file of files) {
      if (!shouldScanContent(file)) continue;
      let text;
      try {
        text = await io.readFile(path.isAbsolute(file) ? file : path.join(root, file));
      } catch (error) {
        // Two read failures are fine to skip, because in both cases there is nothing of
        // this file's own to scan:
        //   ENOENT  the file vanished between listing and reading (e.g. a concurrent
        //           `git rm`) — nothing left to read.
        //   EISDIR  `git ls-files` listed a symlink whose target is a directory (e.g.
        //           `.claude/skills -> ../.agents/skills`, see AGENTS.md); reading it
        //           follows the symlink into a directory. The files inside that target
        //           are themselves separately tracked at their own real paths and get
        //           scanned there — skipping the symlink entry itself scans nothing
        //           twice and misses nothing.
        // Every OTHER failure (permission denied, I/O error, ...) must NOT be treated as
        // "no finding": that would let an unreadable file sail through silently, which is
        // exactly the failure mode this audit exists to prevent.
        if (error?.code === 'ENOENT' || error?.code === 'EISDIR') continue;
        unreadableHits.push({ file, message: error?.message ?? String(error) });
        continue;
      }
      homeHits.push(...findHomePaths(text, { file }));
      chatIdHits.push(...findTelegramChatIds(text, { file }));
    }
    if (unreadableHits.length > 0) {
      log.error('Refusing publication because these tracked files could not be read and scanned:');
      for (const hit of unreadableHits) log.error(`  ${hit.file}  (${hit.message})`);
      log.error('Fix the file permissions, or remove it from tracking, then re-run the audit.');
      return 1;
    }
    if (homeHits.length > 0) {
      log.error('Replace or redact these machine-specific paths before publishing:');
      for (const hit of homeHits) log.error(`  ${hit.file}:${hit.line}:${hit.column}  ${hit.match}`);
      log.error('Use ~/, <repo>, or /Users/test instead.');
      return 1;
    }
    if (chatIdHits.length > 0) {
      log.error('Refusing publication because these private chat ids are in tracked files:');
      for (const hit of chatIdHits) log.error(`  ${hit.file}:${hit.line}:${hit.column}  ${hit.match}`);
      log.error('Move the value to .env.local and read it from there; document the shape in .env.example.');
      return 1;
    }

    log.step('Checking whitespace and conflict markers');
    await run('git', ['diff', '--check'], { cwd: root });

    if (await hasGitleaks(run)) {
      log.step('Scanning candidate files with Gitleaks');
      const staged = await stageFiles(files, { root });
      try {
        await run('gitleaks', ['detect', '--source', '.', '--no-git', '--redact', '--no-banner'], {
          cwd: staged.root,
        });
      } finally {
        await staged.cleanup();
      }
      log.step('Scanning Git history with Gitleaks');
      await run('gitleaks', ['detect', '--source', '.', '--redact', '--no-banner'], { cwd: root });
    } else {
      log.error('Gitleaks is required for the public repository audit. '
        + 'Install it with: brew install gitleaks');
      return 1;
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
