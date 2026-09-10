import { test } from 'node:test';
import assert from 'node:assert/strict';
import { splitFrontMatter, renderMarkdown } from '../lib/markdown.mjs';

test('splitFrontMatter separates a leading YAML block from the body', () => {
  const text = '---\ntitle: Privacy\ndescription: What leaves your Mac\n---\n\n# Privacy\n\nBody.\n';
  const { frontMatter, body } = splitFrontMatter(text);
  assert.equal(frontMatter, 'title: Privacy\ndescription: What leaves your Mac');
  assert.equal(body, '# Privacy\n\nBody.\n');
});

test('splitFrontMatter tolerates a document without front matter', () => {
  const { frontMatter, body } = splitFrontMatter('# Privacy\n\nBody.\n');
  assert.equal(frontMatter, '');
  assert.equal(body, '# Privacy\n\nBody.\n');
});

test('splitFrontMatter refuses an unterminated front matter block', () => {
  assert.throws(() => splitFrontMatter('---\ntitle: Oops\n\n# Heading\n'),
    /unterminated front matter/i);
});

test('renderMarkdown renders headings by level', () => {
  assert.equal(renderMarkdown('# One\n'), '<h1>One</h1>');
  assert.equal(renderMarkdown('## Two\n'), '<h2>Two</h2>');
  assert.equal(renderMarkdown('### Three\n'), '<h3>Three</h3>');
});

test('renderMarkdown joins wrapped lines into one paragraph', () => {
  assert.equal(renderMarkdown('Macomprendo has no analytics,\nno crash reporting.\n'),
    '<p>Macomprendo has no analytics, no crash reporting.</p>');
});

test('renderMarkdown separates paragraphs on a blank line', () => {
  assert.equal(renderMarkdown('First.\n\nSecond.\n'), '<p>First.</p>\n<p>Second.</p>');
});

test('renderMarkdown renders bullet lists, including wrapped items', () => {
  const html = renderMarkdown('- One\n- Two spans\n  two lines\n');
  assert.equal(html, '<ul>\n<li>One</li>\n<li>Two spans two lines</li>\n</ul>');
});

test('renderMarkdown renders bold, code and links inline', () => {
  assert.equal(renderMarkdown('**What is stored.** Settings live in `UserDefaults`.\n'),
    '<p><strong>What is stored.</strong> Settings live in <code>UserDefaults</code>.</p>');
  assert.equal(renderMarkdown('See [the licence](LICENSE) for terms.\n'),
    '<p>See <a href="LICENSE">the licence</a> for terms.</p>');
});

test('renderMarkdown escapes HTML so Markdown cannot inject markup', () => {
  assert.equal(renderMarkdown('A <script>alert(1)</script> & an ampersand.\n'),
    '<p>A &lt;script&gt;alert(1)&lt;/script&gt; &amp; an ampersand.</p>');
});

test('renderMarkdown escapes inside code spans and link text', () => {
  assert.equal(renderMarkdown('`a < b`\n'), '<p><code>a &lt; b</code></p>');
  assert.equal(renderMarkdown('[a & b](https://example.com/?x=1&y=2)\n'),
    '<p><a href="https://example.com/?x=1&amp;y=2">a &amp; b</a></p>');
});

test('renderMarkdown does not linkify a bare URL, leaving it as text', () => {
  assert.equal(renderMarkdown('Ollama runs on http://localhost:11434 by default.\n'),
    '<p>Ollama runs on http://localhost:11434 by default.</p>');
});

test('renderMarkdown refuses a construct it does not support rather than dropping it', () => {
  assert.throws(() => renderMarkdown('> A blockquote.\n'), /unsupported markdown/i);
  assert.throws(() => renderMarkdown('```\ncode block\n```\n'), /unsupported markdown/i);
  assert.throws(() => renderMarkdown('1. Numbered.\n'), /unsupported markdown/i);
  assert.throws(() => renderMarkdown('| a | b |\n|---|---|\n'), /unsupported markdown/i);
});

test('renderMarkdown reports the line number of an unsupported construct', () => {
  assert.throws(() => renderMarkdown('# Fine\n\nAlso fine.\n\n> Not fine.\n'),
    /line 5/);
});

test('renderMarkdown groups h2 sections into elements when asked, leaving the lead alone', () => {
  const source = '# Title\n\nLead paragraph.\n\n## First\n\nOne.\n\n- a\n\n## Second\n\nTwo.\n';
  assert.equal(renderMarkdown(source, { groupSections: true }), [
    '<h1>Title</h1>',
    '<p>Lead paragraph.</p>',
    '<section>',
    '<h2>First</h2>',
    '<p>One.</p>',
    '<ul>',
    '<li>a</li>',
    '</ul>',
    '</section>',
    '<section>',
    '<h2>Second</h2>',
    '<p>Two.</p>',
    '</section>',
  ].join('\n'));
});

test('renderMarkdown leaves output ungrouped by default', () => {
  const html = renderMarkdown('## First\n\nOne.\n');
  assert.equal(html, '<h2>First</h2>\n<p>One.</p>');
});

test('renderMarkdown grouping is a no-op on a document with no h2', () => {
  const html = renderMarkdown('# Only\n\nText.\n', { groupSections: true });
  assert.equal(html, '<h1>Only</h1>\n<p>Text.</p>');
});

test('renderMarkdown renders the real PRIVACY.md shape end to end', () => {
  const source = [
    '# Privacy',
    '',
    'Macomprendo has no analytics, no crash reporting and no update checks. It never',
    'phones home.',
    '',
    '**What leaves your Mac.** Only requests you configure yourself:',
    '',
    '- If transcription is set to a local whisper model, audio never leaves the Mac.',
    '- API keys live in the login Keychain under the service',
    '  `com.dzamataev.macomprendo` — never in settings, logs, or exported files.',
    '',
  ].join('\n');
  assert.equal(renderMarkdown(source), [
    '<h1>Privacy</h1>',
    '<p>Macomprendo has no analytics, no crash reporting and no update checks. It never phones home.</p>',
    '<p><strong>What leaves your Mac.</strong> Only requests you configure yourself:</p>',
    '<ul>',
    '<li>If transcription is set to a local whisper model, audio never leaves the Mac.</li>',
    '<li>API keys live in the login Keychain under the service <code>com.dzamataev.macomprendo</code> — never in settings, logs, or exported files.</li>',
    '</ul>',
  ].join('\n'));
});
