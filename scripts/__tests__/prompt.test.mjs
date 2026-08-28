import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';

import { prompt } from '../lib/prompt.mjs';

function fakeTTY() {
  const input = new PassThrough();
  const output = new PassThrough();
  output.isTTY = true;
  const seen = [];
  output.on('data', (chunk) => seen.push(chunk.toString()));
  return { input, output, seen, text: () => seen.join('') };
}

test('prompt resolves "y" as typed', async () => {
  const io = fakeTTY();
  const answer = prompt('Publish? [y/N] ', io);
  io.input.write('y\n');
  assert.equal(await answer, 'y');
  assert.ok(io.text().includes('Publish? [y/N] '));
});

test('prompt resolves "n" as typed', async () => {
  const io = fakeTTY();
  const answer = prompt('Publish? [y/N] ', io);
  io.input.write('n\n');
  assert.equal(await answer, 'n');
});

test('prompt trims and resolves an empty line', async () => {
  const io = fakeTTY();
  const answer = prompt('Publish? [y/N] ', io);
  io.input.write('\n');
  assert.equal(await answer, '');
});

test('prompt rejects with an actionable message when stdin ends before an answer', async () => {
  const io = fakeTTY();
  const answer = prompt('Publish? [y/N] ', io, { eofMessage: 'stdin is not interactive; re-run with --yes.' });
  io.input.end();
  await assert.rejects(answer, /stdin is not interactive; re-run with --yes\./);
});

test('prompt rejects with a generic message when no eofMessage is supplied', async () => {
  const io = fakeTTY();
  const answer = prompt('Password: ', io);
  io.input.end();
  await assert.rejects(answer, /stdin closed before an answer was given\./);
});

test('prompt never echoes typed characters when muted, and restores echo on cleanup', async () => {
  const io = fakeTTY();
  const answer = prompt('App-specific password: ', io, { muted: true });
  io.input.write('abcd-efgh-ijkl-mnop\n');
  assert.equal(await answer, 'abcd-efgh-ijkl-mnop');
  assert.ok(io.text().includes('App-specific password: '));
  assert.equal(io.text().includes('abcd-efgh'), false);
});

test('prompt cleans up and rejects on an input-stream error', async () => {
  const io = fakeTTY();
  const answer = prompt('App-specific password: ', io, { muted: true });
  const inputError = new Error('Input stream error');
  io.input.destroy(inputError);
  await assert.rejects(answer, inputError);
  assert.ok(io.text().includes('\n'), 'newline should be written to restore echo on error');
});

test('prompt only settles once when close follows an answer', async () => {
  const io = fakeTTY();
  const answer = prompt('Publish? [y/N] ', io);
  io.input.write('y\n');
  const resolved = await answer;
  // Ending the stream after the interface already closed must not reject the
  // already-settled promise or throw an unhandled rejection.
  io.input.end();
  assert.equal(resolved, 'y');
});
