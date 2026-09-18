import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startHeadline } from '../../site/assets/hero.mjs';

function fixture(reduced = false) {
  let tick;
  const listeners = {};
  const classes = new Set();
  const word = { textContent: 'code', dataset: {}, classList: { add: x => classes.add(x), remove: x => classes.delete(x) }, addEventListener: (event, fn) => { listeners[event] = fn; } };
  const button = { hidden: true, textContent: '', setAttribute() {}, addEventListener: (event, fn) => { listeners[event] = fn; } };
  const doc = { hidden: false, querySelector: selector => selector === '#rotating-action' ? word : button, addEventListener: (event, fn) => { listeners[event] = fn; } };
  const media = { matches: reduced, addEventListener: (event, fn) => { listeners.motion = fn; } };
  const env = { matchMedia: () => media, setInterval: fn => { tick = fn; return 1; }, clearInterval: () => { tick = undefined; } };
  startHeadline(doc, env);
  return { word, button, doc, media, listeners, tick: () => tick?.(), running: () => !!tick };
}

test('headline rotates, pauses and resumes without hiding its controls', () => {
  const f = fixture();
  assert.equal(f.button.hidden, false);
  f.tick();
  assert.equal(f.word.textContent, 'rephrase');
  f.listeners.click();
  assert.equal(f.running(), false);
  f.tick();
  assert.equal(f.word.textContent, 'rephrase');
  f.listeners.click();
  assert.equal(f.running(), true);
});

test('reduced motion and background tabs stop headline updates', () => {
  const f = fixture(true);
  assert.equal(f.running(), false);
  assert.equal(f.button.hidden, true);
  f.media.matches = false;
  f.listeners.motion();
  assert.equal(f.running(), true);
  f.doc.hidden = true;
  f.listeners.visibilitychange();
  assert.equal(f.running(), false);
  f.doc.hidden = false;
  f.listeners.visibilitychange();
  assert.equal(f.running(), true);
});
