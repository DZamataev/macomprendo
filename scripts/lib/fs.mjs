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

// Node's fs.cp({ dereference: false }) does not copy symlinks verbatim: for a
// relative symlink target (e.g. a macOS .framework's `Versions/Current -> A` or
// `Headers -> Versions/Current/Headers`), it resolves the target against the
// source tree and writes an *absolute* symlink in the destination that points
// back at the original source location, instead of preserving the original
// (possibly relative) target string. That corrupts anything with the standard
// versioned-framework symlink layout — the copy no longer stands on its own,
// and `codesign` refuses to seal it ("unsealed contents present in the root
// directory of an embedded framework"). So directories and symlinks are walked
// and recreated by hand here; only plain files go through fs.cp.
async function copyEntry(from, to) {
  const st = await fs.lstat(from);
  if (st.isSymbolicLink()) {
    const target = await fs.readlink(from);
    await fs.rm(to, { recursive: true, force: true });
    await fs.symlink(target, to);
    return;
  }
  if (st.isDirectory()) {
    await fs.mkdir(to, { recursive: true });
    // fs.mkdir applies the process umask, not the source directory's mode — fs.cp used
    // to preserve it, so match that here rather than silently loosening permissions.
    await fs.chmod(to, st.mode & 0o777);
    const entries = await fs.readdir(from, { withFileTypes: true });
    for (const entry of entries) {
      await copyEntry(path.join(from, entry.name), path.join(to, entry.name));
    }
    return;
  }
  await fs.cp(from, to, { force: true });
}

export async function copyPath(from, to) {
  await fs.mkdir(path.dirname(to), { recursive: true });
  await copyEntry(from, to);
}

export async function chmodExec(file) {
  await fs.chmod(file, 0o755);
}

export async function move(from, to) {
  await fs.rename(from, to);
}

export async function makeTempDir(prefix) {
  return fs.mkdtemp(prefix);
}

export async function pathExists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

export async function isDirectory(p) {
  try {
    const stats = await fs.stat(p);
    return stats.isDirectory();
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
  mkdirp, rmrf, copyPath, chmodExec, pathExists, isDirectory,
  listBundles, listFrameworks, move, mkdtemp: makeTempDir,
};

export const realIO = {
  readFile: (p) => fs.readFile(p, "utf8"),
  writeFile: (p, text) => fs.writeFile(p, text, "utf8"),
  // Base64 in, raw bytes out. A .p12 certificate is not valid UTF-8, so decoding it to a
  // string and writing that re-encodes every byte above 0x7f and produces a larger, corrupt
  // file that `security import` rejects.
  writeBinaryFile: (p, base64) => fs.writeFile(p, Buffer.from(base64, "base64")),
  exists: pathExists,
};
