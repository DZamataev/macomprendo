// Catalog-source-aware helpers for scripts/fetch-model-hashes.mjs.
//
// A `ModelFile(...)` literal is now keyed by its `fileName`, not by model id: one
// `LocalModel` can own up to four files (a sherpa-onnx transducer has an encoder,
// decoder, joiner and tokens file), and Task 1's
// `localFileNamesAreUniqueAcrossTheWholeCatalog` test guarantees `fileName` is unique
// catalog-wide, which is exactly what a rewrite key needs to be.
//
// GigaAM's download URLs are built from `\(v3CTCBase)`-style string interpolation
// rather than a single hardcoded Hugging Face path, so records are parsed directly out
// of ModelCatalog.swift's source (see `extractFileRecords`) instead of being rebuilt
// from a hardcoded id list.

/**
 * Matches one `ModelFile(...)` literal, exactly as ModelCatalog.swift writes it — one
 * line, `role: .xxx`, plain-digit `sizeBytes`, and a `downloadURL: URL(string: "...")!`.
 * Capture groups: 1 fileName, 2 sizeBytes digits, 3 sha256 value, 4 downloadURL string.
 */
const MODEL_FILE_LITERAL =
  /ModelFile\(role: \.\w+, fileName: "([^"]+)", sizeBytes: (\d+), sha256: "([^"]*)", downloadURL: URL\(string: "([^"]*)"\)!\)/;

/** Matches a `private static let name = "value"` string constant declaration. */
const STRING_CONSTANT = /private static let (\w+)\s*=\s*"([^"]*)"/g;

/**
 * Matches a *templated* `ModelFile(...)` literal, where `sizeBytes`/`sha256` are helper
 * parameters rather than literals. `MODEL_FILE_LITERAL` deliberately requires plain-digit
 * sizeBytes so rewriting cannot corrupt a template, so template detection needs its own
 * pattern. Capture groups: 1 fileName, 2 downloadURL string.
 */
const MODEL_FILE_TEMPLATE =
  /ModelFile\(role: \.\w+, fileName: "([^"]+)", sizeBytes: \w+, sha256: \w+, downloadURL: URL\(string: "([^"]*)"\)!\)/;

/**
 * Rewrites the `sizeBytes` and `sha256` fields of a single `ModelFile(...)` literal
 * line, leaving the rest of the line — including a `downloadURL` built from string
 * interpolation — untouched. A line that isn't a recognisable `ModelFile` literal is
 * returned unchanged.
 */
export function rewriteModelFileLiteral(line, { sizeBytes, sha256 }) {
  if (!MODEL_FILE_LITERAL.test(line)) return line;
  return line.replace(
    /sizeBytes: \d+, sha256: "[^"]*"/,
    `sizeBytes: ${sizeBytes}, sha256: "${sha256}"`,
  );
}

/** The `fileName` out of a `ModelFile(...)` literal line, or `null` if it doesn't match. */
export function fileNameOf(line) {
  const match = MODEL_FILE_LITERAL.exec(line);
  return match ? match[1] : null;
}

/** The existing `sizeBytes` out of a `ModelFile(...)` literal line, or `null`. */
export function existingSizeOf(line) {
  const match = MODEL_FILE_LITERAL.exec(line);
  return match ? Number(match[2]) : null;
}

/** The existing `sha256` out of a `ModelFile(...)` literal line, or `null`. */
export function existingHashOf(line) {
  const match = MODEL_FILE_LITERAL.exec(line);
  return match ? match[3] : null;
}

/**
 * Reads the `downloadURL` string out of a `ModelFile(...)` literal line. Returns
 * `null` for a non-matching line, and also for a URL that isn't a plain string
 * literal — e.g. one built with `\(someConstant)` interpolation, which cannot be
 * resolved from a single line in isolation. Resolve the file's `private static let`
 * constants first (see `extractFileRecords`) if that's needed.
 */
export function downloadURLOf(line) {
  const match = MODEL_FILE_LITERAL.exec(line);
  if (!match) return null;
  const url = match[4];
  if (url.includes('\\(')) return null;
  return url;
}

/** Collects every `private static let name = "value"` string constant in the source. */
export function resolveConstants(source) {
  const constants = {};
  for (const match of source.matchAll(STRING_CONSTANT)) {
    constants[match[1]] = match[2];
  }
  return constants;
}

/**
 * Substitutes `\(name)` interpolations for known string constants. An interpolation
 * this doesn't recognise (e.g. whisper's `\(id)`, a function parameter rather than a
 * `private static let`) is left as-is, so `downloadURLOf` still reports it unresolved.
 */
function substituteConstants(source, constants) {
  let out = source;
  for (const [name, value] of Object.entries(constants)) {
    out = out.split(`\\(${name})`).join(value);
  }
  return out;
}

/**
 * Expands a templated `ModelFile(...)` literal into one record per call site.
 *
 * Whisper's nine models share a single literal inside a `whisperModel(id, …)` helper,
 * so its `fileName` and `downloadURL` both interpolate `\(id)` — a function parameter,
 * not a resolvable constant. `extractFileRecords` alone therefore reports zero whisper
 * records, which silently left all nine digests empty. Rather than guess, this reads the
 * helper's call sites (`whisperModel("tiny", …)`) and substitutes each literal id.
 *
 * Only `\(id)` is handled, because that is the one templated parameter the catalog uses.
 * A template interpolating anything else is skipped, not approximated.
 */
export function expandTemplateRecords(source) {
  const records = [];
  const lines = source.split('\n');
  for (const [index, line] of lines.entries()) {
    const match = MODEL_FILE_TEMPLATE.exec(line);
    if (!match) continue;
    const [, fileName, url] = match;
    if (!fileName.includes('\\(id)') || !url.includes('\\(id)')) continue;

    // The helper owning this literal is the nearest `private static func` above it.
    let helperName = null;
    for (let i = index; i >= 0; i--) {
      const helper = /private static func (\w+)\(/.exec(lines[i]);
      if (helper) { [, helperName] = helper; break; }
    }
    if (helperName === null) continue;

    const callSite = new RegExp(`${helperName}\\("([^"]+)"`, 'g');
    for (const call of source.matchAll(callSite)) {
      const id = call[1];
      records.push({
        fileName: fileName.split('\\(id)').join(id),
        downloadURL: url.split('\\(id)').join(id),
      });
    }
  }
  // A malformed catalog could produce the same file twice; keep the first.
  const seen = new Set();
  return records.filter(({ fileName }) => {
    if (seen.has(fileName)) return false;
    seen.add(fileName);
    return true;
  });
}

/**
 * Parses `{ fileName, downloadURL }` records out of the catalog source: one per
 * `ModelFile(...)` literal whose `downloadURL` can be resolved to a plain string,
 * after substituting the source's own `private static let` string constants into any
 * `\(...)` interpolation. Templated literals whose URL interpolates a function
 * parameter are expanded from their call sites by `expandTemplateRecords`, so whisper's
 * nine models are covered rather than skipped.
 */
export function extractFileRecords(source) {
  const constants = resolveConstants(source);
  const rawLines = source.split('\n');
  const resolvedLines = substituteConstants(source, constants).split('\n');
  const records = [];
  for (let i = 0; i < rawLines.length; i++) {
    const fileName = fileNameOf(rawLines[i]);
    if (!fileName) continue;
    const downloadURL = downloadURLOf(resolvedLines[i]);
    if (!downloadURL) continue;
    records.push({ fileName, downloadURL });
  }
  const known = new Set(records.map((record) => record.fileName));
  for (const record of expandTemplateRecords(source)) {
    if (!known.has(record.fileName)) records.push(record);
  }
  return records;
}
