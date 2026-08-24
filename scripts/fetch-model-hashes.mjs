#!/usr/bin/env node
// Records authoritative sizes (and optionally SHA-256 digests) for the whisper
// models into macos/Sources/Macomprendo/Services/ModelCatalog.swift.
//
//   npm run fetch-model-hashes              # sizes only (HEAD requests, fast)
//   npm run fetch-model-hashes -- --download # sizes + digests (~6 GB of traffic)
//   npm run fetch-model-hashes -- --dry-run  # print the records, write nothing
//
// The catalog literals are rewritten in place, so every WhisperModel(...) entry
// must stay on one line with plain-digit sizeBytes.

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CATALOG_PATH = path.join(
  HERE, '..', 'macos', 'Sources', 'Macomprendo', 'Services', 'ModelCatalog.swift',
);

const MODEL_IDS = [
  'tiny', 'tiny.en', 'base', 'base.en',
  'small', 'small.en', 'medium', 'medium.en',
  'large-v3-turbo',
];

export function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Rewrites `sizeBytes` and `sha256` for each record in the Swift catalog source.
 * @param {string} source contents of ModelCatalog.swift
 * @param {{id: string, sizeBytes: number, sha256: string}[]} records
 * @returns {string} the updated source
 */
export function updateCatalogSource(source, records) {
  let out = source;
  for (const { id, sizeBytes, sha256 } of records) {
    const pattern = new RegExp(
      `(WhisperModel\\(id: "${escapeRegExp(id)}",[^\\n]*?sizeBytes: )\\d+(, sha256: ")[^"]*(")`,
    );
    if (!pattern.test(out)) {
      throw new Error(`no catalog entry for model id "${id}"`);
    }
    out = out.replace(pattern, `$1${sizeBytes}$2${sha256}$3`);
  }
  return out;
}

/**
 * Reads a model's authoritative size (and digest when `download` is set).
 * @param {{id: string, downloadURL: string}} model
 * @param {{download?: boolean, fetchImpl?: typeof fetch}} options
 * @returns {Promise<{id: string, sizeBytes: number, sha256: string}>}
 */
export async function fetchModelMetadata(model, { download = false, fetchImpl = fetch } = {}) {
  const head = await fetchImpl(model.downloadURL, { method: 'HEAD', redirect: 'follow' });
  if (!head.ok) {
    throw new Error(`HEAD ${model.downloadURL} failed with ${head.status}`);
  }
  const sizeBytes = Number(head.headers.get('content-length') ?? 0);

  if (!download) {
    return { id: model.id, sizeBytes, sha256: '' };
  }

  const response = await fetchImpl(model.downloadURL, { method: 'GET', redirect: 'follow' });
  if (!response.ok) {
    throw new Error(`GET ${model.downloadURL} failed with ${response.status}`);
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  return { id: model.id, sizeBytes: bytes.length || sizeBytes, sha256 };
}

function downloadURLFor(id) {
  return `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${id}.bin`;
}

async function main() {
  const { values } = parseArgs({
    options: {
      download: { type: 'boolean', default: false },
      'dry-run': { type: 'boolean', default: false },
    },
  });

  const records = [];
  for (const id of MODEL_IDS) {
    process.stdout.write(`fetching ${id}… `);
    const record = await fetchModelMetadata(
      { id, downloadURL: downloadURLFor(id) },
      { download: values.download },
    );
    records.push(record);
    process.stdout.write(`${record.sizeBytes} bytes${record.sha256 ? ` sha256=${record.sha256}` : ''}\n`);
  }

  if (values['dry-run']) {
    console.log(JSON.stringify(records, null, 2));
    return;
  }

  const source = await readFile(CATALOG_PATH, 'utf8');
  await writeFile(CATALOG_PATH, updateCatalogSource(source, records), 'utf8');
  console.log(`updated ${path.relative(process.cwd(), CATALOG_PATH)}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
