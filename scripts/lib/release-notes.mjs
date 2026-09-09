// Pure release-notes selection for a tag push. No filesystem access.
import { extractSection } from './changelog.mjs';

const TAG = /^v(\d+\.\d+\.\d+)$/;

export function tagVersion(tag) {
  const match = TAG.exec(tag ?? '');
  if (match === null) {
    throw new Error(`Tag "${tag}" is not a release tag; releases are tagged vX.Y.Z.`);
  }
  return match[1];
}

function sectionOrNull(text, heading) {
  try {
    const body = extractSection(text, heading);
    return body === '' ? null : body;
  } catch {
    return null;
  }
}

/**
 * `npm run release` moves the Unreleased entries into a `## [X.Y.Z]` section and commits
 * that *before* creating the tag, so a normal release always has a section of its own. A
 * hand-pushed tag does not, and both of the alternatives there are bad: failing the release
 * over prose, or publishing an empty release page. So the Unreleased entries — which are
 * precisely the changes that tag carries — are used instead and labelled as such, and the
 * caller is told which source it got.
 */
export function releaseNotesFor(changelog, version) {
  const versioned = sectionOrNull(changelog, version);
  if (versioned !== null) {
    return { source: 'version-section', body: versioned };
  }

  const unreleased = sectionOrNull(changelog, 'Unreleased');
  if (unreleased !== null) {
    return {
      source: 'unreleased-section',
      body: [
        `These notes come from the **Unreleased** section of \`CHANGELOG.md\`: this tag was`,
        `pushed without a \`## [${version}]\` section of its own.`,
        '',
        unreleased,
      ].join('\n'),
    };
  }

  return {
    source: 'none',
    body: `Macomprendo ${version}. See CHANGELOG.md for the changes in this release.`,
  };
}
