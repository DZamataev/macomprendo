import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  escapeRegExp,
  updateCatalogSource,
  fetchModelMetadata,
} from '../fetch-model-hashes.mjs';

const SOURCE = `enum ModelCatalog {
    static let all: [WhisperModel] = [
        WhisperModel(id: "tiny", displayName: "Tiny (multilingual)", fileName: "ggml-tiny.bin", sizeBytes: 77691713, sha256: "", downloadURL: downloadURL(for: "tiny")),
        WhisperModel(id: "tiny.en", displayName: "Tiny (English)", fileName: "ggml-tiny.en.bin", sizeBytes: 77704715, sha256: "", downloadURL: downloadURL(for: "tiny.en")),
        WhisperModel(id: "base", displayName: "Base (multilingual)", fileName: "ggml-base.bin", sizeBytes: 147951465, sha256: "abc", downloadURL: downloadURL(for: "base"))
    ]
}
`;

test('escapeRegExp escapes regex metacharacters', () => {
  assert.equal(escapeRegExp('tiny.en'), 'tiny\\.en');
  assert.equal(escapeRegExp('large-v3-turbo'), 'large-v3-turbo');
});

test('updateCatalogSource rewrites size and hash for one model', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'tiny', sizeBytes: 100, sha256: 'deadbeef' },
  ]);
  assert.match(out, /id: "tiny",.*sizeBytes: 100, sha256: "deadbeef"/);
  // Other entries untouched.
  assert.match(out, /id: "tiny\.en",.*sizeBytes: 77704715, sha256: ""/);
  assert.match(out, /id: "base",.*sizeBytes: 147951465, sha256: "abc"/);
});

test('updateCatalogSource does not confuse "tiny" with "tiny.en"', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'tiny.en', sizeBytes: 200, sha256: 'feed' },
  ]);
  assert.match(out, /id: "tiny",.*sizeBytes: 77691713, sha256: ""/);
  assert.match(out, /id: "tiny\.en",.*sizeBytes: 200, sha256: "feed"/);
});

test('updateCatalogSource replaces an existing non-empty hash', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'base', sizeBytes: 147951465, sha256: 'newhash' },
  ]);
  assert.match(out, /id: "base",.*sha256: "newhash"/);
  assert.doesNotMatch(out, /sha256: "abc"/);
});

test('updateCatalogSource applies several records at once', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'tiny', sizeBytes: 1, sha256: 'a' },
    { id: 'base', sizeBytes: 3, sha256: 'c' },
  ]);
  assert.match(out, /id: "tiny",.*sizeBytes: 1, sha256: "a"/);
  assert.match(out, /id: "base",.*sizeBytes: 3, sha256: "c"/);
});

test('updateCatalogSource throws for an id that is not in the catalog', () => {
  assert.throws(
    () => updateCatalogSource(SOURCE, [{ id: 'ghost', sizeBytes: 1, sha256: 'a' }]),
    /no catalog entry for model id "ghost"/,
  );
});

test('updateCatalogSource preserves existing hash when incoming sha256 is empty', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'base', sizeBytes: 999, sha256: '' },
  ]);
  // Hash should remain "abc", size should change to 999
  assert.match(out, /id: "base",.*sizeBytes: 999, sha256: "abc"/);
});

test('updateCatalogSource preserves existing sizeBytes when incoming is 0', () => {
  const out = updateCatalogSource(SOURCE, [
    { id: 'base', sizeBytes: 0, sha256: 'newhash' },
  ]);
  // Size should remain 147951465, hash should change to newhash
  assert.match(out, /id: "base",.*sizeBytes: 147951465, sha256: "newhash"/);
});

test('fetchModelMetadata reads the size from a HEAD Content-Length', async () => {
  const calls = [];
  const fakeFetch = async (url, options) => {
    calls.push({ url, method: options.method });
    return { ok: true, status: 200, headers: new Headers({ 'content-length': '4242' }) };
  };

  const record = await fetchModelMetadata(
    { id: 'tiny', downloadURL: 'https://example.com/ggml-tiny.bin' },
    { fetchImpl: fakeFetch },
  );

  assert.deepEqual(record, { id: 'tiny', sizeBytes: 4242, sha256: '' });
  assert.deepEqual(calls, [{ url: 'https://example.com/ggml-tiny.bin', method: 'HEAD' }]);
});

test('fetchModelMetadata throws when the HEAD request fails', async () => {
  const fakeFetch = async () => ({ ok: false, status: 404, headers: new Headers() });
  await assert.rejects(
    () => fetchModelMetadata(
      { id: 'tiny', downloadURL: 'https://example.com/ggml-tiny.bin' },
      { fetchImpl: fakeFetch },
    ),
    /HEAD https:\/\/example\.com\/ggml-tiny\.bin failed with 404/,
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
    { id: 'tiny', downloadURL: 'https://example.com/ggml-tiny.bin' },
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
    { id: 'tiny', downloadURL: 'https://example.com/ggml-tiny.bin' },
    { download: true, fetchImpl: fakeFetch },
  );

  assert.equal(
    record.sha256,
    '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
  );
  assert.equal(record.sizeBytes, 5);
});
