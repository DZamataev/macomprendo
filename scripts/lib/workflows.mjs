// Pure checks over .github/workflows/*.yml. No filesystem access.
//
// CI is the one place where a mistake is invisible locally: the maintainer's machine runs a
// much newer Node and already has gitleaks installed, so a workflow can be broken for months
// while every local command stays green. These rules encode the failures that actually
// happened, so the script test suite catches them instead of a red run on main.
import YAML from 'yaml';

// `node --test` only expands glob patterns itself from Node 21 onwards. On the Node 20 the
// workflows pin (and the >=20 floor package.json declares) a pattern argument is taken
// literally and the run dies with "Could not find '<pattern>'". A directory argument works on
// every supported version, so a glob is always the wrong spelling here.
const NODE_TEST_GLOB = /node\s+(?:--[\w=-]+\s+)*--test\s+[^\n&|;]*\*/;

export function findNodeTestGlobs(commands) {
  const hits = [];
  for (const { source, command } of commands) {
    if (NODE_TEST_GLOB.test(command)) hits.push({ source, command: command.trim() });
  }
  return hits;
}

export function parseWorkflow(text, { name }) {
  let document;
  try {
    document = YAML.parse(text);
  } catch (error) {
    throw new Error(`${name} is not valid YAML: ${error.message}`);
  }
  if (document === null || typeof document !== 'object') {
    throw new Error(`${name} does not parse to a workflow object.`);
  }
  return document;
}

/** Every `run:` script in a workflow, tagged with `<workflow>:<job>` for error messages. */
export function runCommands(workflow, { name }) {
  const commands = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    for (const step of job?.steps ?? []) {
      if (typeof step?.run === 'string') {
        commands.push({ source: `${name}:${jobName}`, command: step.run });
      }
    }
  }
  return commands;
}

function stepUses(step) {
  return typeof step?.uses === 'string' ? step.uses : '';
}

/**
 * `npm run audit` shells out to gitleaks and *fails* when it is absent (deliberately: an
 * audit that silently skips its secret scan is worse than no audit). Runner images do not
 * ship gitleaks, and its history scan is meaningless on the shallow clone actions/checkout
 * makes by default — so both have to be arranged in the same job, before the audit step.
 */
export function findAuditSetupProblems(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    const steps = job?.steps ?? [];
    const auditIndex = steps.findIndex(
      (step) => typeof step?.run === 'string' && /npm run audit|audit-public-repo\.mjs/.test(step.run),
    );
    if (auditIndex === -1) continue;

    const before = steps.slice(0, auditIndex);
    const installsGitleaks = before.some(
      (step) => typeof step?.run === 'string' && /gitleaks/i.test(step.run),
    );
    if (!installsGitleaks) {
      problems.push(`${name}:${jobName} runs the audit without installing gitleaks first; `
        + 'the audit fails when gitleaks is missing.');
    }

    const checkout = before.find((step) => stepUses(step).startsWith('actions/checkout'));
    if (checkout === undefined) {
      problems.push(`${name}:${jobName} runs the audit without checking out the repository.`);
    } else if (Number(checkout.with?.['fetch-depth']) !== 0) {
      problems.push(`${name}:${jobName} runs the audit on a shallow clone; `
        + "set actions/checkout's fetch-depth: 0 so the gitleaks history scan sees every commit.");
    }
  }
  return problems;
}

export const RELEASE_ASSET_PATTERN = /Macomprendo-[^\s"']*\.zip|\$\{?ZIP\}?/;
export const RELEASE_CHECKSUM_PATTERN = /\.sha256/;

/**
 * A tag push is the only automated path to a published download, and README.md points users
 * straight at the Releases page. So the release workflow has to actually create the release,
 * with the ZIP *and* the checksum sidecar README tells them to verify against — and it needs
 * `contents: write` to do it, which is easy to leave at the repository-wide read default.
 *
 * The checks read the whole `run:` block that contains `gh release create`, not just that one
 * line: the assets are legitimately passed through a shell variable set earlier in the same
 * script, and `gh` itself never expands a glob.
 */
export function findReleasePublishProblems(workflow, { name }) {
  const problems = [];

  const tagPatterns = workflow.on?.push?.tags ?? [];
  if (tagPatterns.length === 0) {
    problems.push(`${name} does not trigger on a tag push.`);
  }

  const commands = runCommands(workflow, { name });
  const creates = commands.filter(({ command }) => /gh\s+release\s+create/.test(command));
  if (creates.length === 0) {
    problems.push(`${name} never runs "gh release create", so a tag publishes no release.`);
    return problems;
  }

  const jobsThatPublish = new Set(creates.map(({ source }) => source.split(':')[1]));
  for (const jobName of jobsThatPublish) {
    const permissions = workflow.jobs?.[jobName]?.permissions ?? workflow.permissions ?? {};
    if (permissions.contents !== 'write') {
      problems.push(`${name}:${jobName} publishes a release but does not grant `
        + 'contents: write; the GITHUB_TOKEN cannot create one.');
    }
  }

  const published = creates.map(({ command }) => command).join('\n');
  if (!RELEASE_ASSET_PATTERN.test(published)) {
    problems.push(`${name} publishes a release without attaching the app ZIP.`);
  }
  if (!RELEASE_CHECKSUM_PATTERN.test(published)) {
    problems.push(`${name} publishes a release without attaching the .sha256 sidecar; `
      + 'README.md tells downloaders to verify the ZIP against it.');
  }
  if (!/--notes-file|--notes\b|--generate-notes/.test(published)) {
    problems.push(`${name} publishes a release with no notes source.`);
  }

  return problems;
}
