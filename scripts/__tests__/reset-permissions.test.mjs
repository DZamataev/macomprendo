import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TCC_SERVICES, parseResetArgs, planReset, main } from '../reset-permissions.mjs';
import { makeFakeRun, makeFakeLog } from './helpers/fake-run.mjs';

test('parseResetArgs defaults to a real, guarded run', () => {
  assert.deepEqual(parseResetArgs([]), { dryRun: false, force: false, help: false });
});

test('parseResetArgs honours --dry-run, --force and --help', () => {
  assert.equal(parseResetArgs(['--dry-run']).dryRun, true);
  assert.equal(parseResetArgs(['--force']).force, true);
  assert.equal(parseResetArgs(['--help']).help, true);
});

test('planReset resets every TCC service this app asks for, by bundle id', () => {
  const lines = planReset('com.example.app').map((step) => [step.cmd, ...step.args].join(' '));
  assert.deepEqual(lines, [
    'tccutil reset Accessibility com.example.app',
    'tccutil reset Microphone com.example.app',
  ]);
  assert.deepEqual(TCC_SERVICES, ['Accessibility', 'Microphone']);
});

test('main prints the plan and changes nothing in dry-run mode', async () => {
  const run = makeFakeRun();
  const log = makeFakeLog();

  const code = await main(['--dry-run'], { run, log });

  assert.equal(code, 0);
  assert.deepEqual(run.lines(), []);
  assert.ok(log.lines.some((line) => line.includes('tccutil reset Accessibility com.dzamataev.macomprendo')));
  assert.ok(log.lines.some((line) => line.includes('tccutil reset Microphone com.dzamataev.macomprendo')));
});

test('main resets both services when the app is not running', async () => {
  const run = makeFakeRun([{ stdout: '', code: 1 }]);   // pgrep: no match
  const log = makeFakeLog();

  const code = await main([], { run, log });

  assert.equal(code, 0);
  assert.deepEqual(run.lines(), [
    'pgrep -x Macomprendo',
    'tccutil reset Accessibility com.dzamataev.macomprendo',
    'tccutil reset Microphone com.dzamataev.macomprendo',
  ]);
});

test('main refuses while Macomprendo is running, and resets nothing', async () => {
  const run = makeFakeRun([{ stdout: '4242\n', code: 0 }]);
  const log = makeFakeLog();

  const code = await main([], { run, log });

  assert.equal(code, 1);
  assert.deepEqual(run.lines(), ['pgrep -x Macomprendo']);
  assert.ok(log.lines.some((line) => line.startsWith('error: ') && line.includes('quit Macomprendo')),
    `expected an actionable refusal, got ${JSON.stringify(log.lines)}`);
});

test('main refuses when the running-app probe is killed by a signal', async () => {
  const run = makeFakeRun([{ signal: 'SIGKILL' }]);
  const log = makeFakeLog();

  const code = await main([], { run, log });

  assert.equal(code, 1);
  assert.deepEqual(run.lines(), ['pgrep -x Macomprendo']);
  const errors = log.lines.filter((line) => line.startsWith('error: '));
  assert.ok(errors.some((line) => line.includes('SIGKILL')),
    `expected the signal to be named, got ${JSON.stringify(errors)}`);
  assert.ok(!errors.some((line) => line.includes('quit Macomprendo')),
    'a killed probe must not be reported as "the app is running"');
});

test('main --force skips the running check and resets anyway', async () => {
  const run = makeFakeRun();
  const log = makeFakeLog();

  const code = await main(['--force'], { run, log });

  assert.equal(code, 0);
  assert.deepEqual(run.lines(), [
    'tccutil reset Accessibility com.dzamataev.macomprendo',
    'tccutil reset Microphone com.dzamataev.macomprendo',
  ]);
});

test('main surfaces a tccutil failure and stops', async () => {
  const run = makeFakeRun([
    { stdout: '', code: 1 },                                   // pgrep: no match
    { throws: 'tccutil reset Accessibility ... exited with 1' },
  ]);
  const log = makeFakeLog();

  const code = await main([], { run, log });

  assert.equal(code, 1);
  assert.deepEqual(run.lines(), ['pgrep -x Macomprendo', 'tccutil reset Accessibility com.dzamataev.macomprendo']);
  assert.ok(log.lines.some((line) => line.startsWith('error: ')));
});
