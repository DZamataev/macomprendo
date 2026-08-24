import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { SYMLINKS, syncAgentConfig } from "../sync-agent-config.mjs";

async function repo() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-sync-"));
  await fs.writeFile(path.join(dir, "AGENTS.md"), "# AGENTS");
  await fs.mkdir(path.join(dir, ".agents/skills"), { recursive: true });
  return dir;
}

test("sync creates every symlink, then reports no drift", async () => {
  const dir = await repo();
  const created = await syncAgentConfig(dir);
  assert.equal(created.length, SYMLINKS.length);
  assert.deepEqual(await syncAgentConfig(dir, { check: true }), []);
});

test("check reports a missing symlink without creating it", async () => {
  const dir = await repo();
  const drifted = await syncAgentConfig(dir, { check: true });
  assert.equal(drifted.length, SYMLINKS.length);
  await assert.rejects(() => fs.readlink(path.join(dir, "CLAUDE.md")));
});

test("check reports a symlink pointing somewhere else", async () => {
  const dir = await repo();
  await syncAgentConfig(dir);
  await fs.rm(path.join(dir, "CLAUDE.md"));
  await fs.symlink("README.md", path.join(dir, "CLAUDE.md"));

  const drifted = await syncAgentConfig(dir, { check: true });
  assert.deepEqual(drifted, [{ link: "CLAUDE.md", target: "AGENTS.md", actual: "README.md" }]);
});
