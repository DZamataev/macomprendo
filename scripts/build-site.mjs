#!/usr/bin/env node
// Builds the public site from Markdown sources into a static tree GitHub Pages can serve.
//
// Two properties drive the design:
//
// 1. The site is served from a *project* subpath, `dzamataev.github.io/macomprendo/`, so a
//    root-relative `/assets/site.css` would resolve against the user site and 404. Every
//    template gets a `{{root}}` prefix computed from the page's own depth, and the tests
//    assert that no root-relative href or src survives.
// 2. The download asset name carries the version (`Macomprendo-<version>-macos.zip`), so a
//    hardcoded link rots on the next release. The URL is generated from MARKETING_VERSION,
//    and the Pages workflow re-runs on `release: published`.
import path from 'node:path';
import fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { parse as parseYAML } from 'yaml';

import { ROOT } from './lib/paths.mjs';
import { log as realLog } from './lib/log.mjs';
import { readVersion } from './lib/version.mjs';
import { splitFrontMatter, renderMarkdown } from './lib/markdown.mjs';

const REPO_URL = 'https://github.com/DZamataev/macomprendo';

// The nav marks the page you are on. Keyed by output path so a page cannot link to itself
// without being flagged; the template spells the attribute, this only decides where it goes.
const NAV_PLACEHOLDERS = {
  'index.html': 'navHome',
  'privacy/index.html': 'navPrivacy',
  'terms/index.html': 'navTerms',
  'support/index.html': 'navSupport',
};

function navMarkers(currentOutput) {
  return Object.fromEntries(Object.entries(NAV_PLACEHOLDERS)
    .map(([output, key]) => [key, output === currentOutput ? ' aria-current="page"' : '']));
}

/** The release URLs for a version, with the version baked into the asset filename. */
export function downloadURLs(version) {
  const asset = `Macomprendo-${version}-macos.zip`;
  const base = `${REPO_URL}/releases/download/v${version}/${asset}`;
  return { downloadURL: base, checksumURL: `${base}.sha256`, releasesURL: `${REPO_URL}/releases` };
}

/** Substitutes `{{key}}` placeholders; throws rather than leaving one unresolved. */
export function renderPage(template, values) {
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) => {
    if (!(key in values)) {
      throw new Error(`Template placeholder {{${key}}} has no value; supplied: ${Object.keys(values).join(', ')}`);
    }
    return values[key];
  });
}

// A page at `terms/index.html` needs `../` to reach the site root; `index.html` needs ''.
function rootPrefix(outputPath) {
  const depth = outputPath.split('/').length - 1;
  return '../'.repeat(depth);
}

async function readPageSources(contentDir) {
  const entries = (await fs.readdir(contentDir)).filter((name) => name.endsWith('.md')).sort();
  const pages = [];
  for (const name of entries) {
    const text = await fs.readFile(path.join(contentDir, name), 'utf8');
    const { frontMatter, body } = splitFrontMatter(text);
    const meta = frontMatter === '' ? {} : parseYAML(frontMatter);
    for (const key of ['title', 'description', 'output']) {
      if (typeof meta?.[key] !== 'string' || meta[key].trim() === '') {
        throw new Error(`site/content/${name}: front matter is missing a "${key}" string.`);
      }
    }
    pages.push({ source: `site/content/${name}`, meta, body });
  }
  return pages;
}

async function copyDirectory(from, to) {
  await fs.cp(from, to, { recursive: true });
}

/**
 * Renders every page under `repoRoot/site/content`, plus the repository-root PRIVACY.md,
 * into `options.outputDir`. Replaces the output directory so a removed page cannot linger.
 */
export async function buildSite(repoRoot, options = {}) {
  const log = options.log ?? realLog.info.bind(realLog);
  const outputDir = options.outputDir ?? path.join(repoRoot, 'build', 'site');
  const siteDir = path.join(repoRoot, 'site');
  const template = await fs.readFile(path.join(siteDir, 'templates', 'page.html'), 'utf8');
  const version = readVersion(await fs.readFile(path.join(repoRoot, 'macos', 'project.yml'), 'utf8'));
  const urls = downloadURLs(version);
  const year = String(new Date().getUTCFullYear());

  const pages = await readPageSources(path.join(siteDir, 'content'));

  // PRIVACY.md is the single source of truth for the privacy statement (see issue #6), so
  // the privacy page is rendered from it rather than from a copy under site/content.
  const privacyMarkdown = await fs.readFile(path.join(repoRoot, 'PRIVACY.md'), 'utf8');
  pages.push({
    source: 'PRIVACY.md',
    meta: {
      title: 'Privacy',
      description: 'What Macomprendo stores, logs and sends, and what never leaves your Mac.',
      output: 'privacy/index.html',
    },
    body: splitFrontMatter(privacyMarkdown).body,
  });

  await fs.rm(outputDir, { recursive: true, force: true });
  await fs.mkdir(outputDir, { recursive: true });

  for (const page of pages) {
    const root = rootPrefix(page.meta.output);
    // Markdown may itself reference the download URLs, so substitute before rendering.
    const substituted = renderPage(page.body, { ...urls, version, root, year });
    const html = renderPage(template, {
      title: page.meta.title,
      description: page.meta.description,
      // Layout only selects a CSS shape (the home page lays its value props out as a card
      // grid; text pages read as a single column), so it defaults rather than being required.
      layout: typeof page.meta.layout === 'string' && page.meta.layout.trim() !== ''
        ? page.meta.layout.trim()
        : 'page',
      content: renderMarkdown(substituted, { groupSections: page.meta.groupSections === true }),
      root,
      year,
      ...urls,
      ...navMarkers(page.meta.output),
      version,
    });
    const destination = path.join(outputDir, page.meta.output);
    await fs.mkdir(path.dirname(destination), { recursive: true });
    await fs.writeFile(destination, html);
    log(`wrote ${page.meta.output} from ${page.source}`);
  }

  await copyDirectory(path.join(siteDir, 'assets'), path.join(outputDir, 'assets'));
  // Without this, Jekyll processes the output and silently drops underscore-prefixed files.
  await fs.writeFile(path.join(outputDir, '.nojekyll'), '');
  log(`built ${pages.length} pages for ${version} into ${outputDir}`);
  return { outputDir, version, pages: pages.length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: { out: { type: 'string' } } });
  await buildSite(ROOT, { outputDir: values.out ? path.resolve(values.out) : undefined });
}
