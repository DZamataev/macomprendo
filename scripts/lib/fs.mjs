import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

/**
 * Makes `linkPath` a symlink pointing at `target` (interpreted relative to the
 * directory containing linkPath). Returns 'ok' when it already pointed there,
 * 'fixed' when it pointed elsewhere, 'created' when there was nothing there.
 */
export async function ensureSymlink(target, linkPath) {
  await fs.mkdir(path.dirname(linkPath), { recursive: true });
  let existing = null;
  try {
    existing = await fs.readlink(linkPath);
  } catch (error) {
    if (error.code === "EINVAL") {
      // A real file or directory is squatting on the path — remove it.
      await fs.rm(linkPath, { recursive: true, force: true });
    } else if (error.code !== "ENOENT") {
      throw error;
    }
  }
  if (existing === target) return "ok";
  if (existing !== null) {
    await fs.rm(linkPath, { force: true });
    await fs.symlink(target, linkPath);
    return "fixed";
  }
  await fs.symlink(target, linkPath);
  return "created";
}

export async function sha256(filePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) hash.update(chunk);
  return hash.digest("hex");
}

export async function mkdirp(dir) {
  await fs.mkdir(dir, { recursive: true });
}

export async function rmrf(target) {
  await fs.rm(target, { recursive: true, force: true });
}

export async function copyPath(from, to) {
  await fs.mkdir(path.dirname(to), { recursive: true });
  await fs.cp(from, to, { recursive: true, force: true, dereference: false });
}

export async function chmodExec(file) {
  await fs.chmod(file, 0o755);
}

export async function pathExists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

export async function listDirsWithSuffix(dir, suffix) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(suffix))
    .map((entry) => entry.name)
    .sort();
}

// SwiftPM emits our own target's resources as <Package>_<Target>.bundle next to the
// executable, and binary xcframework slices as *.framework. Both must reach the app bundle.
export const listBundles = (dir) => listDirsWithSuffix(dir, ".bundle");
export const listFrameworks = (dir) => listDirsWithSuffix(dir, ".framework");

export const realFsOps = {
  mkdirp, rmrf, copyPath, chmodExec, pathExists, listBundles, listFrameworks,
};

export const realIO = {
  readFile: (p) => fs.readFile(p, "utf8"),
  writeFile: (p, text) => fs.writeFile(p, text, "utf8"),
  exists: pathExists,
};
