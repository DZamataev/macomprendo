import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { downloadURLs, renderPage, buildSite } from '../build-site.mjs';

const TEMPLATE = [
  '<!doctype html>',
  '<html lang="en"><head><title>{{title}} — Macomprendo</title>',
  '<meta name="description" content="{{description}}">',
  '<link rel="stylesheet" href="{{root}}assets/site.css"></head>',
  '<body><main>{{content}}</main><footer>{{year}}</footer></body></html>',
  '',
].join('\n');

async function fixture() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'macomprendo-site-'));
  await fs.mkdir(path.join(dir, 'site/content'), { recursive: true });
  await fs.mkdir(path.join(dir, 'site/templates'), { recursive: true });
  await fs.mkdir(path.join(dir, 'site/assets'), { recursive: true });
  await fs.mkdir(path.join(dir, 'macos'), { recursive: true });

  await fs.writeFile(path.join(dir, 'site/templates/page.html'), TEMPLATE);
  await fs.writeFile(path.join(dir, 'site/assets/site.css'), 'body{color:#111}\n');
  await fs.writeFile(path.join(dir, 'macos/project.yml'), 'settings:\n  base:\n    MARKETING_VERSION: "1.2.3"\n');
  await fs.writeFile(path.join(dir, 'PRIVACY.md'), '# Privacy\n\nIt never phones home.\n');
  await fs.writeFile(path.join(dir, 'site/content/index.md'),
    '---\ntitle: Home\ndescription: Dictation that stays on your Mac\noutput: index.html\n---\n\n# Macomprendo\n\nDownload: {{downloadURL}} ({{version}}), checksum {{checksumURL}}\n');
  await fs.writeFile(path.join(dir, 'site/content/terms.md'),
    '---\ntitle: Terms of Use\ndescription: Terms\noutput: terms/index.html\n---\n\n# Terms of Use\n\nMIT applies.\n');
  return dir;
}

test('downloadURLs pins the versioned asset name and its checksum sidecar', () => {
  const urls = downloadURLs('1.2.3');
  assert.equal(urls.downloadURL,
    'https://github.com/DZamataev/macomprendo/releases/download/v1.2.3/Macomprendo-1.2.3-macos.zip');
  assert.equal(urls.checksumURL,
    'https://github.com/DZamataev/macomprendo/releases/download/v1.2.3/Macomprendo-1.2.3-macos.zip.sha256');
  assert.equal(urls.releasesURL, 'https://github.com/DZamataev/macomprendo/releases');
});

test('renderPage substitutes metadata, content and the root prefix', () => {
  const html = renderPage(TEMPLATE, {
    title: 'Privacy',
    description: 'What leaves your Mac',
    content: '<h1>Privacy</h1>',
    root: '../',
    year: '2026',
  });
  assert.match(html, /<title>Privacy — Macomprendo<\/title>/);
  assert.match(html, /content="What leaves your Mac"/);
  assert.match(html, /href="\.\.\/assets\/site\.css"/);
  assert.match(html, /<main><h1>Privacy<\/h1><\/main>/);
});

test('renderPage refuses a placeholder the caller did not supply', () => {
  assert.throws(() => renderPage('<p>{{missing}}</p>', { title: 'x' }), /missing/);
});

test('buildSite writes every page, the privacy page from PRIVACY.md, and .nojekyll', async () => {
  const dir = await fixture();
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  const index = await fs.readFile(path.join(out, 'index.html'), 'utf8');
  assert.match(index, /<h1>Macomprendo<\/h1>/);
  assert.match(index, /releases\/download\/v1\.2\.3\/Macomprendo-1\.2\.3-macos\.zip/);
  assert.match(index, /1\.2\.3/);

  const terms = await fs.readFile(path.join(out, 'terms/index.html'), 'utf8');
  assert.match(terms, /<h1>Terms of Use<\/h1>/);

  const privacy = await fs.readFile(path.join(out, 'privacy/index.html'), 'utf8');
  assert.match(privacy, /It never phones home\./);
  assert.match(privacy, /<title>Privacy — Macomprendo<\/title>/);

  await fs.access(path.join(out, '.nojekyll'));
  await fs.access(path.join(out, 'assets/site.css'));
});

test('buildSite gives a nested page a relative root so a project subpath works', async () => {
  const dir = await fixture();
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  const index = await fs.readFile(path.join(out, 'index.html'), 'utf8');
  const terms = await fs.readFile(path.join(out, 'terms/index.html'), 'utf8');
  assert.match(index, /href="assets\/site\.css"/);
  assert.match(terms, /href="\.\.\/assets\/site\.css"/);
  assert.doesNotMatch(index, /href="\/assets/);
  assert.doesNotMatch(terms, /href="\/assets/);
});

test('buildSite emits no root-relative href or src anywhere', async () => {
  const dir = await fixture();
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  for (const relative of ['index.html', 'terms/index.html', 'privacy/index.html']) {
    const html = await fs.readFile(path.join(out, relative), 'utf8');
    assert.doesNotMatch(html, /(href|src)="\/[^/]/, `${relative} has a root-relative reference`);
  }
});

test('buildSite replaces a previous build rather than merging into it', async () => {
  const dir = await fixture();
  const out = path.join(dir, 'build/site');
  await fs.mkdir(out, { recursive: true });
  await fs.writeFile(path.join(out, 'stale.html'), 'old');
  await buildSite(dir, { outputDir: out, log: () => {} });
  await assert.rejects(() => fs.access(path.join(out, 'stale.html')));
});

test('buildSite passes an optional layout through, defaulting to "page"', async () => {
  const dir = await fixture();
  await fs.writeFile(path.join(dir, 'site/templates/page.html'),
    TEMPLATE.replace('<main>', '<main class="{{layout}}">'));
  await fs.writeFile(path.join(dir, 'site/content/index.md'),
    '---\ntitle: Home\ndescription: d\noutput: index.html\nlayout: home\n---\n\n# Macomprendo\n');
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  assert.match(await fs.readFile(path.join(out, 'index.html'), 'utf8'), /<main class="home">/);
  assert.match(await fs.readFile(path.join(out, 'terms/index.html'), 'utf8'), /<main class="page">/);
  assert.match(await fs.readFile(path.join(out, 'privacy/index.html'), 'utf8'), /<main class="page">/);
});

test('buildSite groups h2 sections when the page front matter asks for it', async () => {
  const dir = await fixture();
  await fs.writeFile(path.join(dir, 'site/content/index.md'),
    '---\ntitle: Home\ndescription: d\noutput: index.html\ngroupSections: true\n---\n\n# Macomprendo\n\nLead.\n\n## Offline\n\nRuns locally.\n');
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  const index = await fs.readFile(path.join(out, 'index.html'), 'utf8');
  assert.match(index, /<section>\n<h2>Offline<\/h2>\n<p>Runs locally\.<\/p>\n<\/section>/);
  assert.doesNotMatch(index, /<section>[\s\S]*<h1>/);

  // Text pages stay a flat single column.
  const terms = await fs.readFile(path.join(out, 'terms/index.html'), 'utf8');
  assert.doesNotMatch(terms, /<section>/);
});

test('buildSite marks the current page in the navigation', async () => {
  const dir = await fixture();
  await fs.writeFile(path.join(dir, 'site/templates/page.html'),
    TEMPLATE.replace('<main>', '<nav><a href="{{root}}terms/"{{navTerms}}>Terms</a></nav><main>'));
  const out = path.join(dir, 'build/site');
  await buildSite(dir, { outputDir: out, log: () => {} });

  assert.match(await fs.readFile(path.join(out, 'terms/index.html'), 'utf8'),
    /<a href="\.\.\/terms\/" aria-current="page">Terms<\/a>/);
  assert.match(await fs.readFile(path.join(out, 'index.html'), 'utf8'),
    /<a href="terms\/">Terms<\/a>/);
});

test('buildSite refuses a page whose front matter lacks required keys', async () => {
  const dir = await fixture();
  await fs.writeFile(path.join(dir, 'site/content/broken.md'),
    '---\ntitle: No output\ndescription: Has everything but an output path\n---\n\n# X\n');
  await assert.rejects(
    () => buildSite(dir, { outputDir: path.join(dir, 'build/site'), log: () => {} }),
    /broken\.md.*"output"/s);
});
