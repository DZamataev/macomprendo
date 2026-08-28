// Pure Keep-a-Changelog transforms. No filesystem access.

const UNRELEASED = /^## \[Unreleased\][^\n]*$/m;
const ANY_RELEASE = /^## \[\d+\.\d+\.\d+\][^\n]*$/m;

function escapeVersion(version) {
  return version.replace(/\./g, '\\.');
}

export function updateChangelog(text, version, isoDate) {
  const heading = UNRELEASED.exec(text);
  if (heading === null) {
    throw new Error('CHANGELOG.md is missing an "## [Unreleased]" heading.');
  }
  const bodyStart = heading.index + heading[0].length;
  const rest = text.slice(bodyStart);
  const nextHeading = ANY_RELEASE.exec(rest);
  const bodyEnd = nextHeading === null ? text.length : bodyStart + nextHeading.index;

  const entries = text.slice(bodyStart, bodyEnd).trim();
  if (entries === '') {
    throw new Error('CHANGELOG.md has no entries under "## [Unreleased]"; write release notes first.');
  }

  const remainder = text.slice(bodyEnd).replace(/^\n+/, '');
  const released = `## [Unreleased]\n\n## [${version}] - ${isoDate}\n\n${entries}\n${remainder === '' ? '' : '\n'}`;
  return text.slice(0, heading.index) + released + remainder;
}

export function extractSection(text, version) {
  const heading = new RegExp(`^## \\[${escapeVersion(version)}\\][^\\n]*$`, 'm').exec(text);
  if (heading === null) {
    throw new Error(`CHANGELOG.md has no "## [${version}]" section.`);
  }
  const bodyStart = heading.index + heading[0].length;
  const rest = text.slice(bodyStart);
  const nextHeading = /^## \[/m.exec(rest);
  const body = nextHeading === null ? rest : rest.slice(0, nextHeading.index);
  return body.trim();
}
