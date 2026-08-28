import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import {
  ASSETS_DIR,
  ICONS_DIR,
  LICENSE_SOURCE,
  LICENSE_TARGET,
  resolveIconFiles,
  syncIcons,
  WEIGHTS,
} from "../sync-icons.mjs";

const LICENSE_TEXT = "MIT License\n\nCopyright (c) Phosphor Icons\n";

/**
 * Builds a throwaway repo root under the OS tmpdir with the same layout syncIcons
 * expects: icons.json + vendored SVGs under ICONS_DIR, and the npm package's assets
 * + LICENSE under ASSETS_DIR's parent. Nothing here touches the real repo tree.
 */
async function fakeRepo({
  icons = [{ name: "gear", weight: "regular" }],
  vendoredLicense,
  omitSource,
} = {}) {
  const repoRoot = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-sync-icons-"));
  const iconsDir = path.join(repoRoot, ICONS_DIR);
  await fs.mkdir(iconsDir, { recursive: true });
  await fs.writeFile(path.join(iconsDir, "icons.json"), JSON.stringify(icons));

  const assetsDir = path.join(repoRoot, ASSETS_DIR);
  for (const { name, weight } of icons) {
    const fileName = weight === "regular" ? `${name}.svg` : `${name}-${weight}.svg`;
    if (fileName === omitSource) continue;
    const dir = path.join(assetsDir, weight);
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(path.join(dir, fileName), `<svg>${fileName}</svg>`);
  }

  await fs.mkdir(path.dirname(path.join(repoRoot, LICENSE_SOURCE)), { recursive: true });
  await fs.writeFile(path.join(repoRoot, LICENSE_SOURCE), LICENSE_TEXT);

  if (vendoredLicense !== undefined) {
    await fs.writeFile(path.join(iconsDir, LICENSE_TARGET), vendoredLicense);
  }

  return { repoRoot, iconsDir };
}

test("regular icons are unsuffixed, other weights repeat the weight", () => {
  const resolved = resolveIconFiles(
    [{ name: "gear", weight: "regular" }, { name: "microphone", weight: "fill" }],
    "/assets"
  );
  assert.deepEqual(resolved, [
    { name: "gear", weight: "regular", fileName: "gear.svg", source: "/assets/regular/gear.svg" },
    { name: "microphone", weight: "fill", fileName: "microphone-fill.svg", source: "/assets/fill/microphone-fill.svg" },
  ]);
});

test("the result is sorted by file name so the folder listing is stable", () => {
  const resolved = resolveIconFiles(
    [{ name: "waveform", weight: "regular" }, { name: "cloud", weight: "regular" }],
    "/assets"
  );
  assert.deepEqual(resolved.map((i) => i.fileName), ["cloud.svg", "waveform.svg"]);
});

test("an unknown weight is rejected with the allowed list", () => {
  assert.throws(
    () => resolveIconFiles([{ name: "gear", weight: "chunky" }], "/assets"),
    /weight must be one of thin, light, regular, bold, fill, duotone, got "chunky"/
  );
});

test("a missing name is rejected with its index", () => {
  assert.throws(() => resolveIconFiles([{ weight: "regular" }], "/assets"), /icons\.json\[0\]: missing "name"/);
});

test("duplicates are rejected", () => {
  assert.throws(
    () => resolveIconFiles([{ name: "gear", weight: "regular" }, { name: "gear", weight: "regular" }], "/assets"),
    /lists gear\.svg twice/
  );
});

test("a non-array payload is rejected", () => {
  assert.throws(() => resolveIconFiles({ name: "gear" }, "/assets"), /must contain an array/);
});

test("every documented weight resolves", () => {
  const resolved = resolveIconFiles(WEIGHTS.map((weight) => ({ name: "gear", weight })), "/assets");
  assert.equal(resolved.length, WEIGHTS.length);
  assert.ok(resolved.some((i) => i.fileName === "gear.svg"));
  assert.ok(resolved.some((i) => i.fileName === "gear-duotone.svg"));
});

test("a requested icon whose source SVG is missing from the npm package fails with npm ci guidance", async () => {
  const { repoRoot } = await fakeRepo({ omitSource: "gear.svg" });

  await assert.rejects(
    () => syncIcons(repoRoot, {}),
    /@phosphor-icons\/core is missing:\n {2}.*regular[\\/]gear\.svg\nRun `npm ci` first\./
  );
});

test("a vendored SVG no longer listed in icons.json is removed", async () => {
  const { repoRoot, iconsDir } = await fakeRepo();
  await fs.writeFile(path.join(iconsDir, "old-icon.svg"), "<svg>stale</svg>");

  const result = await syncIcons(repoRoot, {});

  assert.deepEqual(result.stale, ["old-icon.svg"]);
  await assert.rejects(() => fs.access(path.join(iconsDir, "old-icon.svg")));
});

test("the phosphor licence is copied alongside the icons", async () => {
  const { repoRoot, iconsDir } = await fakeRepo();

  await syncIcons(repoRoot, {});

  assert.equal(await fs.readFile(path.join(iconsDir, LICENSE_TARGET), "utf8"), LICENSE_TEXT);
});

test("--check fails when LICENSE-phosphor.txt is missing", async () => {
  const { repoRoot, iconsDir } = await fakeRepo();

  const result = await syncIcons(repoRoot, { check: true });

  assert.ok(result.changed.includes(LICENSE_TARGET));
  await assert.rejects(() => fs.access(path.join(iconsDir, LICENSE_TARGET)));
});

test("--check fails when LICENSE-phosphor.txt differs from upstream", async () => {
  const { repoRoot, iconsDir } = await fakeRepo({ vendoredLicense: "STALE LICENSE TEXT\n" });

  const result = await syncIcons(repoRoot, { check: true });

  assert.ok(result.changed.includes(LICENSE_TARGET));
  assert.equal(await fs.readFile(path.join(iconsDir, LICENSE_TARGET), "utf8"), "STALE LICENSE TEXT\n");
});

test("--check passes once the licence matches upstream, and doesn't rewrite it", async () => {
  const { repoRoot, iconsDir } = await fakeRepo({ vendoredLicense: LICENSE_TEXT });
  await syncIcons(repoRoot, {}); // vendor the icon itself so only the licence is under test

  const result = await syncIcons(repoRoot, { check: true });

  assert.deepEqual(result.changed, []);
  assert.deepEqual(result.stale, []);
  assert.equal(await fs.readFile(path.join(iconsDir, LICENSE_TARGET), "utf8"), LICENSE_TEXT);
});
