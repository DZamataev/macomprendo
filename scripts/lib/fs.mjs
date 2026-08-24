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
