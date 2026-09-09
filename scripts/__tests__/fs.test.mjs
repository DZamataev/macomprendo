import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { ensureSymlink, sha256, realIO } from "../lib/fs.mjs";

async function tmpdir() {
  return await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-test-"));
}

test("ensureSymlink creates, keeps and repairs a link", async () => {
  const dir = await tmpdir();
  await fs.writeFile(path.join(dir, "AGENTS.md"), "hello");
  await fs.writeFile(path.join(dir, "OTHER.md"), "other");
  const link = path.join(dir, "CLAUDE.md");

  assert.equal(await ensureSymlink("AGENTS.md", link), "created");
  assert.equal(await ensureSymlink("AGENTS.md", link), "ok");

  await fs.rm(link);
  await fs.symlink("OTHER.md", link);
  assert.equal(await ensureSymlink("AGENTS.md", link), "fixed");
  assert.equal(await fs.readlink(link), "AGENTS.md");
});

test("ensureSymlink replaces a real file sitting at the link path", async () => {
  const dir = await tmpdir();
  await fs.writeFile(path.join(dir, "AGENTS.md"), "hello");
  const link = path.join(dir, "CLAUDE.md");
  await fs.writeFile(link, "stale copy");

  assert.equal(await ensureSymlink("AGENTS.md", link), "created");
  assert.equal(await fs.readlink(link), "AGENTS.md");
});

test("sha256 hashes file contents", async () => {
  const dir = await tmpdir();
  const file = path.join(dir, "a.txt");
  await fs.writeFile(file, "abc");
  assert.equal(await sha256(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("realIO.writeBinaryFile round-trips bytes a utf8 write would corrupt", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-binary-"));
  const file = path.join(dir, "cert.p12");
  // Real .p12 bytes are not valid UTF-8; writing them as text re-encodes and grows the file.
  const bytes = Buffer.from([0x30, 0x82, 0x0a, 0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28]);
  await realIO.writeBinaryFile(file, bytes.toString("base64"));
  assert.ok(bytes.equals(await fs.readFile(file)));
  assert.equal((await fs.stat(file)).size, bytes.length);
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  await fs.rm(dir, { recursive: true, force: true });
});
