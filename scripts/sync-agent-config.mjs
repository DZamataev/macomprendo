#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { ensureSymlink } from "./lib/fs.mjs";
import { log } from "./lib/log.mjs";

/** `target` is relative to the directory containing `link`. */
export const SYMLINKS = [
  { link: "CLAUDE.md", target: "AGENTS.md" },
  { link: ".claude/skills", target: "../.agents/skills" },
];

/**
 * With { check: true } nothing is written; the returned array lists the links
 * that are wrong. Without it the links are created or repaired and the returned
 * array lists what changed.
 */
export async function syncAgentConfig(repoRoot, { check = false } = {}) {
  const drifted = [];
  for (const { link, target } of SYMLINKS) {
    const linkPath = path.join(repoRoot, link);
    if (check) {
      let actual = null;
      try {
        actual = await fs.readlink(linkPath);
      } catch {
        actual = null;
      }
      if (actual !== target) drifted.push({ link, target, actual });
      continue;
    }
    const result = await ensureSymlink(target, linkPath);
    if (result !== "ok") drifted.push({ link, target, actual: result });
  }
  return drifted;
}

const isMain = process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  const { values } = parseArgs({ options: { check: { type: "boolean", default: false } } });
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const drifted = await syncAgentConfig(repoRoot, { check: values.check });
  if (values.check) {
    if (drifted.length > 0) {
      for (const d of drifted) {
        log.error(`${d.link} should be a symlink to ${d.target} (found: ${d.actual ?? "nothing"})`);
      }
      log.error("Run `npm run sync-agents` to fix.");
      process.exit(1);
    }
    log.info("Agent config symlinks are in sync.");
  } else {
    for (const d of drifted) log.info(`${d.link} -> ${d.target} (${d.actual})`);
    log.info("Agent config symlinks are in sync.");
  }
}
