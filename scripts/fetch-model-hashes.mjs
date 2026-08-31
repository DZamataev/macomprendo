#!/usr/bin/env node
// Records authoritative sizes (and optionally SHA-256 digests) for the catalog's
// models into macos/Sources/Macomprendo/Services/ModelCatalog.swift.
//
//   npm run fetch-model-hashes                          # sizes only (HEAD requests, fast)
//   npm run fetch-model-hashes -- --download             # sizes + digests (whole catalog)
//   npm run fetch-model-hashes -- --download --only foo  # only files whose fileName contains "foo"
//   npm run fetch-model-hashes -- --dry-run              # print the records, write nothing
//
// The catalog literals are rewritten in place, so every ModelFile(...) entry must stay
// on one line with plain-digit sizeBytes. Records are parsed straight out of the
// catalog source (see scripts/lib/model-hashes.mjs) rather than rebuilt from a
// hardcoded id list: GigaAM's URLs are built from `\(someBase)` string interpolation,
// not a single fixed Hugging Face path the way whisper's is. Whisper's own
// `ModelFile` literal is a single template shared by nine models (`fileName:
// "ggml-\(id).bin"`) rather than nine distinct literals, so it has no resolvable
// downloadURL and is correctly skipped — its sha256 stays "" exactly as on main today.

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  rewriteModelFileLiteral, fileNameOf, existingSizeOf, existingHashOf, extractFileRecords,
} from './lib/model-hashes.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CATALOG_PATH = path.join(
  HERE, '..', 'macos', 'Sources', 'Macomprendo', 'Services', 'ModelCatalog.swift',
);

/**
 * Rewrites `sizeBytes` and `sha256` for each record in the Swift catalog source, keyed
 * by `fileName`. When incoming sha256 is empty, preserves the existing sha256 and only
 * updates sizeBytes. When incoming sizeBytes is 0 or null, preserves the existing size.
 * @param {string} source contents of ModelCatalog.swift
 * @param {{fileName: string, sizeBytes: number, sha256: string}[]} records
 * @returns {string} the updated source
 */
export function updateCatalogSource(source, records) {
  const byFileName = new Map(records.map((record) => [record.fileName, record]));
  const seen = new Set();

  const lines = source.split('\n').map((line) => {
    const fileName = fileNameOf(line);
    if (!fileName || !byFileName.has(fileName)) return line;

    const record = byFileName.get(fileName);
    seen.add(fileName);

    const sizeBytes = (record.sizeBytes && record.sizeBytes > 0) ? record.sizeBytes : existingSizeOf(line);
    const sha256 = record.sha256 ? record.sha256 : existingHashOf(line);
    return rewriteModelFileLiteral(line, { sizeBytes, sha256 });
  });

  for (const record of records) {
    if (!seen.has(record.fileName)) {
      throw new Error(`no catalog entry for file "${record.fileName}"`);
    }
  }

  return lines.join('\n');
}

/**
 * Reads a file's authoritative size (and digest when `download` is set).
 * @param {{fileName: string, downloadURL: string}} file
 * @param {{download?: boolean, fetchImpl?: typeof fetch}} options
 * @returns {Promise<{fileName: string, sizeBytes: number, sha256: string}>}
 */
export async function fetchModelMetadata({ fileName, downloadURL }, { download = false, fetchImpl = fetch } = {}) {
  const head = await fetchImpl(downloadURL, { method: 'HEAD', redirect: 'follow' });
  if (!head.ok) {
    throw new Error(`HEAD ${downloadURL} failed with ${head.status}`);
  }
  const sizeBytes = Number(head.headers.get('content-length') ?? 0);

  if (!download) {
    return { fileName, sizeBytes, sha256: '' };
  }

  const response = await fetchImpl(downloadURL, { method: 'GET', redirect: 'follow' });
  if (!response.ok) {
    throw new Error(`GET ${downloadURL} failed with ${response.status}`);
  }
  // Hash the body as it streams in rather than buffering the whole model (up to
  // ~600 MB) in memory: `response.body` is a web ReadableStream, which Node's fetch
  // implementation makes async-iterable.
  const hash = createHash('sha256');
  let bytesRead = 0;
  for await (const chunk of response.body) {
    hash.update(chunk);
    bytesRead += chunk.length;
  }
  return { fileName, sizeBytes: bytesRead || sizeBytes, sha256: hash.digest('hex') };
}

async function main() {
  const { values } = parseArgs({
    options: {
      download: { type: 'boolean', default: false },
      'dry-run': { type: 'boolean', default: false },
      only: { type: 'string' },
    },
  });

  const source = await readFile(CATALOG_PATH, 'utf8');
  let files = extractFileRecords(source);
  if (values.only) {
    files = files.filter((file) => file.fileName.includes(values.only));
  }

  const records = [];
  for (const file of files) {
    process.stdout.write(`fetching ${file.fileName}… `);
    const record = await fetchModelMetadata(file, { download: values.download });
    records.push(record);
    process.stdout.write(`${record.sizeBytes} bytes${record.sha256 ? ` sha256=${record.sha256}` : ''}\n`);
  }

  if (values['dry-run']) {
    console.log(JSON.stringify(records, null, 2));
    return;
  }

  await writeFile(CATALOG_PATH, updateCatalogSource(source, records), 'utf8');
  console.log(`updated ${path.relative(process.cwd(), CATALOG_PATH)}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
