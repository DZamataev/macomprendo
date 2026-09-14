import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { GRAPH_ENTRIES, syncGraph } from "../sync-graph.mjs";

const quietLog = { info() {}, warn() {}, error() {}, step() {} };

async function seedSource() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-graph-src-"));
  const out = path.join(root, "graphify-out");
  await fs.mkdir(path.join(out, "cache", "ast"), { recursive: true });
  await fs.writeFile(path.join(out, "graph.json"), '{"nodes":[]}');
  await fs.writeFile(path.join(out, "GRAPH_REPORT.md"), "# report");
  await fs.writeFile(path.join(out, "graph.html"), "<html></html>");
  await fs.writeFile(path.join(out, "manifest.json"), "{}");
  await fs.writeFile(path.join(out, "cost.json"), '{"runs":[]}');
  await fs.writeFile(path.join(out, ".graphify_labels.json"), "{}");
  await fs.writeFile(path.join(out, ".graphify_root"), root);
  await fs.writeFile(path.join(out, "cache", "ast", "entry.json"), "{}");
  await fs.writeFile(path.join(out, "README.md"), "# committed wiring");
  return root;
}

async function emptyWorktree() {
  return fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-graph-wt-"));
}

test("copies every graph artifact into the worktree and rewrites the scan root", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  const calls = [];
  const run = async (cmd, args, opts) => { calls.push({ cmd, args, cwd: opts?.cwd }); return { stdout: "", stderr: "", code: 0 }; };

  const result = await syncGraph(worktree, { sourceRoot: source, run, log: quietLog });

  for (const entry of GRAPH_ENTRIES) {
    await fs.access(path.join(worktree, "graphify-out", entry));
  }
  assert.equal(await fs.readFile(path.join(worktree, "graphify-out", "cache", "ast", "entry.json"), "utf8"), "{}");
  assert.equal((await fs.readFile(path.join(worktree, "graphify-out", ".graphify_root"), "utf8")).trim(), worktree);
  assert.equal(result.copied.length, GRAPH_ENTRIES.length);
  assert.equal(result.updated, true);
  assert.deepEqual(calls.map((c) => [c.cmd, c.args[0], c.cwd]), [["graphify", "update", worktree]]);
});

test("the committed README is never overwritten by the copy", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  await fs.mkdir(path.join(worktree, "graphify-out"), { recursive: true });
  await fs.writeFile(path.join(worktree, "graphify-out", "README.md"), "# worktree wiring");

  await syncGraph(worktree, { sourceRoot: source, update: false, run: async () => ({ code: 0 }), log: quietLog });

  assert.equal(await fs.readFile(path.join(worktree, "graphify-out", "README.md"), "utf8"), "# worktree wiring");
});

test("check reports the missing artifacts without writing or updating", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  let ran = false;

  const result = await syncGraph(worktree, {
    sourceRoot: source, check: true, run: async () => { ran = true; return { code: 0 }; }, log: quietLog,
  });

  assert.equal(result.missing.length, GRAPH_ENTRIES.length);
  assert.equal(result.updated, false);
  assert.equal(ran, false);
  await assert.rejects(() => fs.access(path.join(worktree, "graphify-out", "graph.json")));
});

test("check is silent once the worktree already carries the graph", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  await syncGraph(worktree, { sourceRoot: source, update: false, run: async () => ({ code: 0 }), log: quietLog });

  const result = await syncGraph(worktree, { sourceRoot: source, check: true, run: async () => ({ code: 0 }), log: quietLog });

  assert.deepEqual(result.missing, []);
});

test("a second sync refreshes a stale copy instead of keeping it", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  await syncGraph(worktree, { sourceRoot: source, update: false, run: async () => ({ code: 0 }), log: quietLog });
  await fs.writeFile(path.join(source, "graphify-out", "graph.json"), '{"nodes":[{"id":"a"}]}');

  await syncGraph(worktree, { sourceRoot: source, update: false, run: async () => ({ code: 0 }), log: quietLog });

  assert.equal(
    await fs.readFile(path.join(worktree, "graphify-out", "graph.json"), "utf8"),
    '{"nodes":[{"id":"a"}]}',
  );
});

test("syncing the source onto itself updates in place and copies nothing", async () => {
  const source = await seedSource();
  const calls = [];
  const run = async (cmd, args, opts) => { calls.push({ cmd, args, cwd: opts?.cwd }); return { code: 0 }; };

  const result = await syncGraph(source, { sourceRoot: source, run, log: quietLog });

  assert.deepEqual(result.copied, []);
  assert.equal(result.updated, true);
  assert.equal(calls.length, 1);
  assert.equal(await fs.readFile(path.join(source, "graphify-out", "graph.json"), "utf8"), '{"nodes":[]}');
});

test("a source without a built graph fails with a rebuild hint", async () => {
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-graph-bare-"));
  const worktree = await emptyWorktree();

  await assert.rejects(
    () => syncGraph(worktree, { sourceRoot: source, run: async () => ({ code: 0 }), log: quietLog }),
    /graph\.json.*graphify/s,
  );
});

test("the graph is excluded even on a branch whose .gitignore predates the rule", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  const gitDir = path.join(source, ".git");
  await fs.mkdir(path.join(gitDir, "info"), { recursive: true });
  await fs.writeFile(path.join(gitDir, "info", "exclude"), "# git ls-files --others\n");

  await syncGraph(worktree, { sourceRoot: source, gitCommonDir: gitDir, update: false, run: async () => ({ code: 0 }), log: quietLog });

  const exclude = await fs.readFile(path.join(gitDir, "info", "exclude"), "utf8");
  assert.match(exclude, /^graphify-out\/\*$/m);
  assert.match(exclude, /^!graphify-out\/README\.md$/m);
});

test("the shared exclude gains the rule once, not on every sync", async () => {
  const source = await seedSource();
  const worktree = await emptyWorktree();
  const gitDir = path.join(source, ".git");
  await fs.mkdir(path.join(gitDir, "info"), { recursive: true });
  await fs.writeFile(path.join(gitDir, "info", "exclude"), "");
  const opts = { sourceRoot: source, gitCommonDir: gitDir, update: false, run: async () => ({ code: 0 }), log: quietLog };

  await syncGraph(worktree, opts);
  const afterFirst = await fs.readFile(path.join(gitDir, "info", "exclude"), "utf8");
  await syncGraph(worktree, opts);

  // Byte-identical, so neither the rules nor the explanatory header pile up.
  assert.equal(await fs.readFile(path.join(gitDir, "info", "exclude"), "utf8"), afterFirst);
  assert.equal(afterFirst.match(/^graphify-out\/\*$/gm).length, 1);
});
