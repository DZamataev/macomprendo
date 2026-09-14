#!/usr/bin/env node
// Carries the graphify knowledge graph from the operator's checkout into a worktree.
//
// graphify-out/ is git-ignored (it is generated, machine-local and ~17 MB), so a fresh
// `git worktree add` starts blind: an agent working there cannot run `graphify query`
// and would have to rebuild the whole graph, which costs over a million tokens. Copying
// the artifacts and running the free, AST-only `graphify update` re-extracts just the
// files that differ on that branch.
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { copyPath, pathExists, rmrf } from "./lib/fs.mjs";
import { log as defaultLog } from "./lib/log.mjs";
import { run as defaultRun } from "./lib/run.mjs";

export const GRAPH_DIR = "graphify-out";

/**
 * Everything a worktree needs to query and incrementally refresh the graph.
 * README.md is deliberately absent: it is the one committed file in graphify-out/,
 * so the worktree already has its own copy from git and must not be clobbered.
 */
export const GRAPH_ENTRIES = [
  "graph.json",
  "GRAPH_REPORT.md",
  "graph.html",
  "manifest.json",
  "cost.json",
  "cache",
  ".graphify_labels.json",
  ".graphify_root",
];

/** The artifacts without which `graphify query` cannot answer anything. */
const REQUIRED_ENTRIES = ["graph.json", "manifest.json"];

/**
 * The same rule as .gitignore, installed into the shared `.git/info/exclude`.
 * A worktree on a branch that predates the .gitignore rule would otherwise see
 * graphify-out/ as untracked and could commit 17 MB of generated graph; info/exclude
 * is shared by every worktree of the repository and is not itself versioned, so it
 * protects old branches without touching their history.
 */
const EXCLUDE_RULES = ["graphify-out/*", "!graphify-out/README.md"];
const EXCLUDE_HEADER = "# graphify — generated graph, never committed (see .gitignore)";

async function ensureGitExclude(gitCommonDir, log) {
  const excludePath = path.join(gitCommonDir, "info", "exclude");
  let current = "";
  try {
    current = await fs.readFile(excludePath, "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const lines = current.split("\n").map((line) => line.trim());
  const missing = EXCLUDE_RULES.filter((rule) => !lines.includes(rule));
  if (missing.length === 0) return false;

  await fs.mkdir(path.dirname(excludePath), { recursive: true });
  const prefix = current === "" || current.endsWith("\n") ? current : `${current}\n`;
  await fs.writeFile(excludePath, `${prefix}${EXCLUDE_HEADER}\n${missing.join("\n")}\n`, "utf8");
  log.info(`Added the graphify rule to ${excludePath} (shared by every worktree)`);
  return true;
}

/**
 * Copies the graph from `sourceRoot` into `targetRoot`, rewrites the recorded scan
 * root, and re-extracts the branch's own code with `graphify update`.
 *
 * With { check: true } nothing is written; `missing` lists the entries the target
 * lacks. `run` and `log` are injectable so tests stay offline and quiet.
 */
export async function syncGraph(targetRoot, options = {}) {
  const {
    sourceRoot,
    check = false,
    update = true,
    gitCommonDir = null,
    run = defaultRun,
    log = defaultLog,
  } = options;

  const source = path.resolve(sourceRoot);
  const target = path.resolve(targetRoot);
  const sourceDir = path.join(source, GRAPH_DIR);
  const targetDir = path.join(target, GRAPH_DIR);
  const sameTree = source === target;

  if (!sameTree) {
    for (const entry of REQUIRED_ENTRIES) {
      if (!(await pathExists(path.join(sourceDir, entry)))) {
        throw new Error(
          `${path.join(sourceDir, entry)} is missing — build the graph in ${source} first ` +
            `(run the graphify skill on it), then re-run this tool.`,
        );
      }
    }
  }

  if (check) {
    const missing = [];
    for (const entry of GRAPH_ENTRIES) {
      if (!(await pathExists(path.join(targetDir, entry)))) missing.push(entry);
    }
    return { copied: [], missing, updated: false };
  }

  const copied = [];
  if (gitCommonDir) await ensureGitExclude(gitCommonDir, log);
  if (!sameTree) {
    await fs.mkdir(targetDir, { recursive: true });
    for (const entry of GRAPH_ENTRIES) {
      const from = path.join(sourceDir, entry);
      if (!(await pathExists(from))) continue;
      const to = path.join(targetDir, entry);
      // A stale cache directory would otherwise keep entries the source no longer has.
      await rmrf(to);
      await copyPath(from, to);
      copied.push(entry);
    }
    // The scan root is absolute and points at the source checkout; leaving it would make
    // `graphify update` re-extract the operator's tree instead of this branch.
    await fs.writeFile(path.join(targetDir, ".graphify_root"), `${target}\n`, "utf8");
    log.info(`Copied ${copied.length} graph artifact(s) into ${targetDir}`);
  }

  let updated = false;
  if (update) {
    // AST-only re-extraction: deterministic, free, no LLM and no API key.
    await run("graphify", ["update", target], { cwd: target, log });
    updated = true;
  }

  return { copied, missing: [], updated };
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  const { values } = parseArgs({
    options: {
      check: { type: "boolean", default: false },
      "no-update": { type: "boolean", default: false },
      source: { type: "string" },
      target: { type: "string" },
    },
  });
  const scriptRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  // The common dir is the `.git` of the checkout that owns the repository: from a
  // worktree it points back at the main checkout, so both the default source and the
  // shared info/exclude are resolved from one query.
  const { stdout } = await defaultRun("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], {
    cwd: scriptRoot,
    capture: true,
    log: { info() {}, warn() {}, error() {}, step() {} },
  });
  const gitCommonDir = stdout.trim();
  const source = values.source ?? path.dirname(gitCommonDir);
  const target = path.resolve(values.target ?? scriptRoot);

  try {
    const result = await syncGraph(target, {
      sourceRoot: source,
      check: values.check,
      update: !values["no-update"],
      gitCommonDir,
    });
    if (values.check) {
      if (result.missing.length > 0) {
        for (const entry of result.missing) defaultLog.error(`${path.join(GRAPH_DIR, entry)} is missing`);
        defaultLog.error("Run `npm run sync-graph` to copy the graph into this worktree.");
        process.exit(1);
      }
      defaultLog.info("The graphify graph is present in this worktree.");
    } else {
      defaultLog.info(`Graph ready in ${path.join(target, GRAPH_DIR)} — query it with \`graphify query "<question>"\`.`);
    }
  } catch (error) {
    defaultLog.error(error.message);
    process.exit(1);
  }
}
