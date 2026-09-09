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

test("run writes input to stdin and closes it", async () => {
  const result = await run("cat", [], { capture: true, input: "hello\nworld\n", log: silent });
  assert.equal(result.code, 0);
  assert.equal(result.stdout, "hello\nworld\n");
});

test("run redacts listed values from the logged command line", async () => {
  const lines = [];
  const log = { info() {}, warn() {}, error() {}, step: (m) => lines.push(m) };
  await run("echo", ["--password", "hunter2", "--user", "me"], {
    capture: true, log, redact: ["hunter2"],
  });
  assert.equal(lines.length, 1);
  assert.equal(lines[0].includes("hunter2"), false);
  assert.match(lines[0], /--password \*\*\*/);
  assert.match(lines[0], /--user me/);
});

test("run redacts the same value everywhere it appears, and ignores empty entries", async () => {
  const lines = [];
  const log = { info() {}, warn() {}, error() {}, step: (m) => lines.push(m) };
  await run("echo", ["s3cret", "keep", "s3cret"], {
    capture: true, log, redact: ["s3cret", "", undefined, null],
  });
  assert.equal(lines[0], "echo *** keep ***");
});

test("run keeps a redacted value out of the error it throws", async () => {
  const silentLog = { info() {}, warn() {}, error() {}, step() {} };
  await assert.rejects(
    () => run("sh", ["-c", "exit 3", "hunter2"], { capture: true, log: silentLog, redact: ["hunter2"] }),
    (error) => {
      assert.equal(error.message.includes("hunter2"), false);
      assert.match(error.message, /exited with 3/);
      return true;
    },
  );
});
