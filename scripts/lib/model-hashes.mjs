// Catalog-source-aware helpers for scripts/fetch-model-hashes.mjs.
//
// A `ModelFile(...)` literal is now keyed by its `fileName`, not by model id: one
// `LocalASRModel` can own up to four files (a sherpa-onnx transducer has an encoder,
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
 * Parses `{ fileName, downloadURL }` records out of the catalog source: one per
 * `ModelFile(...)` literal whose `downloadURL` can be resolved to a plain string,
 * after substituting the source's own `private static let` string constants into any
 * `\(...)` interpolation. A literal whose URL still can't be resolved (whisper's
 * `\(id)`-templated line, which is a single template shared by nine models rather
 * than nine distinct literals) is skipped rather than guessed at.
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
  return records;
}
