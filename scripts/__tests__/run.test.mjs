import assert from "node:assert/strict";
import { test } from "node:test";
import { run } from "../lib/run.mjs";

const silent = { info() {}, warn() {}, error() {}, step() {} };

test("run captures stdout and returns exit code 0", async () => {
  const result = await run("echo", ["hi"], { capture: true, log: silent });
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), "hi");
});

test("run throws on a non-zero exit", async () => {
  await assert.rejects(() => run("false", [], { capture: true, log: silent }), /exited with 1/);
});

test("run returns the code instead of throwing when check is false", async () => {
  const result = await run("false", [], { capture: true, check: false, log: silent });
  assert.equal(result.code, 1);
});

test("run reports a null code and the signal when the child is killed", async () => {
  const result = await run("node", ["-e", "process.kill(process.pid,'SIGTERM')"], {
    capture: true,
    check: false,
    log: silent,
  });
  assert.equal(result.signal, "SIGTERM");
  assert.equal(result.code, null);
});

test("dryRun does not spawn anything", async () => {
  const result = await run("definitely-not-a-command", [], { dryRun: true, log: silent });
  assert.deepEqual(result, { stdout: "", stderr: "", code: 0 });
});
