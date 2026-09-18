import { test } from 'node:test';
import assert from 'node:assert/strict';
import { demoFrame } from '../../site/assets/demo.mjs';

test('demo tells the failed and corrected stories in order and loops after its ending', () => {
  assert.equal(demoFrame(0).phase, 'dictating');
  assert.ok(demoFrame(1500).text.length < demoFrame(2900).text.length);
  assert.equal(demoFrame(6000).phase, 'dead');
  assert.equal(demoFrame(8500).phase, 'crossed');
  assert.equal(demoFrame(11000).phase, 'retry');
  assert.equal(demoFrame(14500).phase, 'correcting');
  assert.equal(demoFrame(17500).phase, 'understood');
  assert.equal(demoFrame(22000).phase, 'heart');
  assert.equal(demoFrame(22000).caption, '');
  assert.deepEqual(demoFrame(24000), demoFrame(0));
  assert.deepEqual(demoFrame(49500), demoFrame(1500));
  assert.match(demoFrame(17500).text, /SQLite/);
  assert.doesNotMatch(demoFrame(17500).text, /sequel light/);
});

import { startDemo } from '../../site/assets/demo.mjs';

test('demo pauses when hidden, supports replay, and respects reduced motion', () => {
  const nodes = new Map();
  const node = key => {
    if (!nodes.has(key)) nodes.set(key, { textContent: '', hidden: true, style: {}, events: {}, setAttribute() {}, addEventListener(event, fn) { this.events[event] = fn; } });
    return nodes.get(key);
  };
  const root = { dataset: {}, querySelector: node };
  const events = {};
  const doc = { hidden: false, querySelector: () => root, addEventListener: (name, fn) => { events[name] = fn; } };
  let scheduled;
  let observe;
  let motionChange;
  const motion = { matches: false, addEventListener: (_, fn) => { motionChange = fn; } };
  const env = {
    matchMedia: () => motion,
    requestAnimationFrame: fn => { scheduled = fn; return 1; },
    cancelAnimationFrame: () => { scheduled = null; },
    IntersectionObserver: class { constructor(fn) { observe = fn; } observe() {} },
  };
  startDemo(doc, env);
  assert.equal(scheduled, null);
  observe([{ isIntersecting: true }]);
  assert.equal(typeof scheduled, 'function');
  scheduled(0);
  scheduled(100);
  for (let time = 200; time <= 24100; time += 100) scheduled(time);
  assert.equal(root.dataset.phase, 'dictating');
  assert.equal(node('.demo-toggle').hidden, false);
  node('.demo-toggle').events.click();
  assert.equal(scheduled, null);
  assert.equal(node('.demo-toggle').textContent, 'Play');
  node('.demo-replay').events.click();
  assert.equal(node('.demo-transcript').textContent, '…');
  doc.hidden = true;
  events.visibilitychange();
  assert.equal(scheduled, null);
  doc.hidden = false;
  events.visibilitychange();
  assert.equal(typeof scheduled, 'function');
  motion.matches = true;
  motionChange();
  assert.equal(scheduled, null);
  assert.equal(root.dataset.phase, 'understood');
  assert.equal(node('.demo-transcript').hidden, true);
  assert.equal(node('.demo-correction').hidden, false);
  assert.equal(node('.correction-word').textContent, 'SQLite');
  assert.equal(node('.demo-toggle').hidden, true);
  assert.equal(node('.demo-replay').hidden, true);
});

test('correction strikes the original before typing its replacement', () => {
  assert.equal(demoFrame(12999).replacement, undefined);
  assert.equal(demoFrame(13000).replacement, '');
  assert.equal(demoFrame(13500).replacement, 'S');
  assert.equal(demoFrame(14000).replacement, 'SQL');
  assert.equal(demoFrame(14700).replacement, 'SQLite');
  assert.equal(demoFrame(15999).replacement, 'SQLite');
  assert.equal(demoFrame(16000).replacement, 'SQLite');
  assert.equal(demoFrame(18999).replacement, 'SQLite');
});
