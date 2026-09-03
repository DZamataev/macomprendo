import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  updateCatalogSource,
  fetchModelMetadata,
} from '../fetch-model-hashes.mjs';

// Shaped like the real ModelCatalog.swift: fileName is the rewrite key now, not model id
// — one model can own several files, and two GigaAM entries share the fileName prefix
// "gigaam-v3-e2e-", the way "tiny" and "tiny.en" used to collide on model id.
const SOURCE = `enum ModelCatalog {
    static let all: [LocalModel] = whisper + gigaAM
    private static let gigaAM: [LocalModel] = [
        LocalModel(
            id: "gigaam-v3-e2e-ctc",
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-v3-e2e-ctc-model.onnx", sizeBytes: 224900000, sha256: "", downloadURL: URL(string: "https://example.com/ctc/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-ctc-tokens.txt", sizeBytes: 4000, sha256: "abc", downloadURL: URL(string: "https://example.com/ctc/tokens.txt")!)
            ]
        ),
        LocalModel(
            id: "gigaam-v3-e2e-rnnt",
            files: [
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-rnnt-tokens.txt", sizeBytes: 13000, sha256: "", downloadURL: URL(string: "https://example.com/rnnt/tokens.txt")!)
            ]
        )
    ]
}
`;

test('updateCatalogSource rewrites size and hash for one file', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-ctc-model.onnx', sizeBytes: 100, sha256: 'deadbeef' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-model\.onnx", sizeBytes: 100, sha256: "deadbeef"/);
  // Other entries untouched.
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-tokens\.txt", sizeBytes: 4000, sha256: "abc"/);
  assert.match(out, /fileName: "gigaam-v3-e2e-rnnt-tokens\.txt", sizeBytes: 13000, sha256: ""/);
});

test('updateCatalogSource does not confuse fileNames that share a prefix', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-rnnt-tokens.txt', sizeBytes: 200, sha256: 'feed' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-tokens\.txt", sizeBytes: 4000, sha256: "abc"/);
  assert.match(out, /fileName: "gigaam-v3-e2e-rnnt-tokens\.txt", sizeBytes: 200, sha256: "feed"/);
});

test('updateCatalogSource replaces an existing non-empty hash', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-ctc-tokens.txt', sizeBytes: 4000, sha256: 'newhash' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-tokens\.txt".*sha256: "newhash"/);
  assert.doesNotMatch(out, /sha256: "abc"/);
});

test('updateCatalogSource applies several records at once', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-ctc-model.onnx', sizeBytes: 1, sha256: 'a' },
    { fileName: 'gigaam-v3-e2e-rnnt-tokens.txt', sizeBytes: 3, sha256: 'c' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-model\.onnx", sizeBytes: 1, sha256: "a"/);
  assert.match(out, /fileName: "gigaam-v3-e2e-rnnt-tokens\.txt", sizeBytes: 3, sha256: "c"/);
});

test('updateCatalogSource throws for a fileName that is not in the catalog', () => {
  assert.throws(
    () => updateCatalogSource(SOURCE, [{ fileName: 'ghost.onnx', sizeBytes: 1, sha256: 'a' }]),
    /no catalog entry for file "ghost\.onnx"/,
  );
});

test('updateCatalogSource preserves existing hash when incoming sha256 is empty', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-ctc-tokens.txt', sizeBytes: 999, sha256: '' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-tokens\.txt", sizeBytes: 999, sha256: "abc"/);
});

test('updateCatalogSource preserves existing sizeBytes when incoming is 0', () => {
  const out = updateCatalogSource(SOURCE, [
    { fileName: 'gigaam-v3-e2e-ctc-tokens.txt', sizeBytes: 0, sha256: 'newhash' },
  ]);
  assert.match(out, /fileName: "gigaam-v3-e2e-ctc-tokens\.txt", sizeBytes: 4000, sha256: "newhash"/);
});

test('fetchModelMetadata reads the size from a HEAD Content-Length', async () => {
  const calls = [];
  const fakeFetch = async (url, options) => {
    calls.push({ url, method: options.method });
    return { ok: true, status: 200, headers: new Headers({ 'content-length': '4242' }) };
  };

  const record = await fetchModelMetadata(
    { fileName: 'gigaam-v3-e2e-ctc-model.onnx', downloadURL: 'https://example.com/model.int8.onnx' },
    { fetchImpl: fakeFetch },
  );

  assert.deepEqual(record, { fileName: 'gigaam-v3-e2e-ctc-model.onnx', sizeBytes: 4242, sha256: '' });
  assert.deepEqual(calls, [{ url: 'https://example.com/model.int8.onnx', method: 'HEAD' }]);
});

test('fetchModelMetadata throws when the HEAD request fails', async () => {
  const fakeFetch = async () => ({ ok: false, status: 404, headers: new Headers() });
  await assert.rejects(
    () => fetchModelMetadata(
      { fileName: 'gigaam-v3-e2e-ctc-model.onnx', downloadURL: 'https://example.com/model.int8.onnx' },
      { fetchImpl: fakeFetch },
    ),
    /HEAD https:\/\/example\.com\/model\.int8\.onnx failed with 404/,
  );
});

/** An async-iterable of chunks, standing in for a web ReadableStream body. */
function fakeBody(chunks) {
  return {
    async *[Symbol.asyncIterator]() {
      for (const chunk of chunks) yield chunk;
    },
  };
}

test('fetchModelMetadata hashes the body when download is requested', async () => {
  const fakeFetch = async (url, options) => {
    if (options.method === 'HEAD') {
      return { ok: true, status: 200, headers: new Headers({ 'content-length': '5' }) };
    }
    return {
      ok: true,
      status: 200,
      headers: new Headers({ 'content-length': '5' }),
      body: fakeBody([new TextEncoder().encode('hello')]),
    };
  };

  const record = await fetchModelMetadata(
    { fileName: 'gigaam-v3-e2e-ctc-model.onnx', downloadURL: 'https://example.com/model.int8.onnx' },
    { download: true, fetchImpl: fakeFetch },
  );

  // sha256("hello")
  assert.equal(
    record.sha256,
    '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
  );
  assert.equal(record.sizeBytes, 5);
});

test('fetchModelMetadata hashes a body delivered across several chunks', async () => {
  const fakeFetch = async (url, options) => {
    if (options.method === 'HEAD') {
      return { ok: true, status: 200, headers: new Headers({ 'content-length': '5' }) };
    }
    return {
      ok: true,
      status: 200,
      headers: new Headers({ 'content-length': '5' }),
      // Split "hello" across three chunks, so streamed hashing must
      // accumulate across `for await` iterations rather than assuming one
      // chunk holds the whole body.
      body: fakeBody([
        new TextEncoder().encode('he'),
        new TextEncoder().encode('l'),
        new TextEncoder().encode('lo'),
      ]),
    };
  };

  const record = await fetchModelMetadata(
    { fileName: 'gigaam-v3-e2e-ctc-model.onnx', downloadURL: 'https://example.com/model.int8.onnx' },
    { download: true, fetchImpl: fakeFetch },
  );

  assert.equal(
    record.sha256,
    '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
  );
  assert.equal(record.sizeBytes, 5);
});
