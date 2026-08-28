const MARKETING_VERSION = /MARKETING_VERSION:\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?/;

/** Reads MARKETING_VERSION out of macos/project.yml text. */
export function readVersion(projectYmlText) {
  const match = projectYmlText.match(MARKETING_VERSION);
  if (!match) throw new Error("MARKETING_VERSION not found in project.yml");
  return match[1];
}

/** part is 'patch' | 'minor' | 'major' | an explicit 'X.Y.Z'. */
export function bumpVersion(version, part) {
  if (/^[0-9]+\.[0-9]+\.[0-9]+$/.test(part)) return part;
  const [major, minor, patch] = version.split(".").map(Number);
  if (part === "major") return `${major + 1}.0.0`;
  if (part === "minor") return `${major}.${minor + 1}.0`;
  if (part === "patch") return `${major}.${minor}.${patch + 1}`;
  throw new Error(`Unknown version part: ${part}`);
}
