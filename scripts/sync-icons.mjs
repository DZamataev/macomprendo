#!/usr/bin/env node
// Copies the Phosphor SVGs listed in macos/Sources/Macomprendo/Resources/Icons/icons.json
// out of the @phosphor-icons/core npm package and into the Swift resource folder.
// The SVGs are committed, so a Swift build never needs Node.
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { log } from "./lib/log.mjs";

export const WEIGHTS = ["thin", "light", "regular", "bold", "fill", "duotone"];
export const ICONS_DIR = "macos/Sources/Macomprendo/Resources/Icons";
export const ASSETS_DIR = "node_modules/@phosphor-icons/core/assets";
export const LICENSE_SOURCE = "node_modules/@phosphor-icons/core/LICENSE";
export const LICENSE_TARGET = "LICENSE-phosphor.txt";

/**
 * Turns the icons.json list into concrete file paths.
 * In @phosphor-icons/core the regular weight is unsuffixed (`assets/regular/gear.svg`)
 * and every other weight repeats itself (`assets/fill/gear-fill.svg`).
 * Returns [{ name, weight, fileName, source }] sorted by fileName.
 */
export function resolveIconFiles(list, assetsDir) {
  if (!Array.isArray(list)) throw new Error("icons.json must contain an array");
  const seen = new Set();
  const resolved = list.map((entry, index) => {
    const { name, weight } = entry ?? {};
    if (typeof name !== "string" || name.length === 0) {
      throw new Error(`icons.json[${index}]: missing "name"`);
    }
    if (!WEIGHTS.includes(weight)) {
      throw new Error(`icons.json[${index}] ("${name}"): weight must be one of ${WEIGHTS.join(", ")}, got "${weight}"`);
    }
    const fileName = weight === "regular" ? `${name}.svg` : `${name}-${weight}.svg`;
    if (seen.has(fileName)) throw new Error(`icons.json lists ${fileName} twice`);
    seen.add(fileName);
    return { name, weight, fileName, source: path.join(assetsDir, weight, fileName) };
  });
  return resolved.sort((a, b) => a.fileName.localeCompare(b.fileName));
}

export async function syncIcons(repoRoot, { check = false } = {}) {
  const iconsDir = path.join(repoRoot, ICONS_DIR);
  const list = JSON.parse(await fs.readFile(path.join(iconsDir, "icons.json"), "utf8"));
  const wanted = resolveIconFiles(list, path.join(repoRoot, ASSETS_DIR));

  const missingSources = [];
  for (const icon of wanted) {
    try {
      await fs.access(icon.source);
    } catch {
      missingSources.push(icon.source);
    }
  }
  if (missingSources.length > 0) {
    throw new Error(`@phosphor-icons/core is missing:\n  ${missingSources.join("\n  ")}\nRun \`npm ci\` first.`);
  }

  const present = (await fs.readdir(iconsDir)).filter((f) => f.endsWith(".svg"));
  const wantedNames = new Set(wanted.map((i) => i.fileName));
  const stale = present.filter((f) => !wantedNames.has(f));
  const changed = [];

  for (const icon of wanted) {
    const target = path.join(iconsDir, icon.fileName);
    const source = await fs.readFile(icon.source, "utf8");
    let current = null;
    try {
      current = await fs.readFile(target, "utf8");
    } catch {
      current = null;
    }
    if (current === source) continue;
    changed.push(icon.fileName);
    if (!check) await fs.writeFile(target, source);
  }

  const licenseTarget = path.join(iconsDir, LICENSE_TARGET);
  const licenseSource = await fs.readFile(path.join(repoRoot, LICENSE_SOURCE), "utf8");
  let licenseCurrent = null;
  try {
    licenseCurrent = await fs.readFile(licenseTarget, "utf8");
  } catch {
    licenseCurrent = null;
  }
  if (licenseCurrent !== licenseSource) {
    changed.push(LICENSE_TARGET);
    if (!check) await fs.writeFile(licenseTarget, licenseSource);
  }

  if (!check) {
    for (const file of stale) await fs.rm(path.join(iconsDir, file));
  }

  return { changed, stale, total: wanted.length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: { check: { type: "boolean", default: false } } });
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const { changed, stale, total } = await syncIcons(repoRoot, { check: values.check });
  if (values.check) {
    if (changed.length > 0 || stale.length > 0) {
      for (const f of changed) log.error(`${f} differs from @phosphor-icons/core`);
      for (const f of stale) log.error(`${f} is not listed in icons.json`);
      log.error("Run `npm run sync-icons` and commit the result.");
      process.exit(1);
    }
    log.info(`All ${total} vendored icons match @phosphor-icons/core.`);
  } else {
    for (const f of changed) log.info(`updated ${f}`);
    for (const f of stale) log.info(`removed ${f}`);
    log.info(`${total} icons in ${ICONS_DIR}`);
  }
}
