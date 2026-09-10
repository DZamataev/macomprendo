// Markdown → HTML for this repository's own prose. Pure transforms, no filesystem access.
//
// Deliberately not a CommonMark implementation. The site renders four documents whose
// source we write ourselves, so the supported syntax is exactly what those documents use:
// ATX headings, paragraphs, bullet lists, and inline bold/code/links. Anything else throws
// with a line number rather than being silently dropped — a privacy statement that loses a
// paragraph because it used an unsupported construct is worse than a build failure.

const FRONT_MATTER = /^---\r?\n/;

/**
 * Splits a leading `---`-delimited YAML block off a document.
 * Returns `{ frontMatter, body }`; `frontMatter` is `''` when there is none.
 */
export function splitFrontMatter(text) {
  if (!FRONT_MATTER.test(text)) return { frontMatter: '', body: text };
  const lines = text.split('\n');
  const end = lines.indexOf('---', 1);
  if (end === -1) {
    throw new Error('Unterminated front matter: the opening "---" has no closing "---".');
  }
  return {
    frontMatter: lines.slice(1, end).join('\n').trim(),
    body: lines.slice(end + 1).join('\n').replace(/^\n+/, ''),
  };
}

function escapeHTML(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Inline spans are resolved in one pass so that escaping happens exactly once: the
// placeholder round-trip below would otherwise let `&` in a URL be escaped twice.
function renderInline(text) {
  const placeholders = [];
  const keep = (html) => {
    placeholders.push(html);
    return `\u0000${placeholders.length - 1}\u0000`;
  };

  const withSpans = text
    .replace(/`([^`]+)`/g, (_, code) => keep(`<code>${escapeHTML(code)}</code>`))
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
      (_, label, href) => keep(`<a href="${escapeHTML(href)}">${escapeHTML(label)}</a>`))
    .replace(/\*\*([^*]+)\*\*/g, (_, bold) => keep(`<strong>${escapeHTML(bold)}</strong>`));

  return escapeHTML(withSpans).replace(/\u0000(\d+)\u0000/g, (_, index) => placeholders[Number(index)]);
}

const UNSUPPORTED = [
  { test: /^\s*>/, what: 'blockquote' },
  { test: /^\s*(```|~~~)/, what: 'code block' },
  { test: /^\s*\d+\.\s/, what: 'ordered list' },
  { test: /^\s*\|/, what: 'table' },
  { test: /^\s*(\*|_){3,}\s*$/, what: 'thematic break' },
  { test: /^#{7,}\s/, what: 'heading deeper than h6' },
];

function rejectUnsupported(line, lineNumber) {
  for (const { test, what } of UNSUPPORTED) {
    if (test.test(line)) {
      throw new Error(`Unsupported markdown (${what}) on line ${lineNumber}: ${line.trim()}`);
    }
  }
}

/**
 * Renders the supported subset to HTML. Throws on anything outside it.
 *
 * With `groupSections`, each `h2` and the blocks following it are wrapped in a `<section>`,
 * and blocks before the first `h2` are left as-is. CSS grid places every *child* of the
 * container in the next cell, so without this a heading lands in one column and its own
 * paragraph in the next — the sections have to be single elements to be laid out as cards.
 */
export function renderMarkdown(markdown, options = {}) {
  const lines = markdown.split('\n');
  const blocks = [];
  let paragraph = [];
  let list = null;

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    blocks.push(`<p>${renderInline(paragraph.join(' '))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (list === null) return;
    const items = list.map((item) => `<li>${renderInline(item.join(' '))}</li>`);
    blocks.push(`<ul>\n${items.join('\n')}\n</ul>`);
    list = null;
  };
  const flushAll = () => {
    flushParagraph();
    flushList();
  };

  for (const [index, raw] of lines.entries()) {
    const lineNumber = index + 1;
    const line = raw.replace(/\r$/, '');

    if (line.trim() === '') {
      flushAll();
      continue;
    }
    rejectUnsupported(line, lineNumber);

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading !== null) {
      flushAll();
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2].trim())}</h${level}>`);
      continue;
    }

    const bullet = /^[-*]\s+(.*)$/.exec(line);
    if (bullet !== null) {
      flushParagraph();
      if (list === null) list = [];
      list.push([bullet[1].trim()]);
      continue;
    }

    // An indented line continues whichever block is open: a list item or a paragraph.
    if (list !== null) {
      list[list.length - 1].push(line.trim());
      continue;
    }
    paragraph.push(line.trim());
  }

  flushAll();
  if (options.groupSections !== true) return blocks.join('\n');

  // Blocks are already rendered top-level HTML strings, so grouping is a regroup of that
  // list: each <h2> opens a section that runs until the next <h2>.
  const grouped = [];
  let section = null;
  const closeSection = () => {
    if (section === null) return;
    grouped.push(`<section>\n${section.join('\n')}\n</section>`);
    section = null;
  };
  for (const block of blocks) {
    if (block.startsWith('<h2>')) {
      closeSection();
      section = [block];
      continue;
    }
    if (section === null) grouped.push(block);
    else section.push(block);
  }
  closeSection();
  return grouped.join('\n');
}
