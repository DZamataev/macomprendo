// Pure checks over .github/workflows/*.yml. No filesystem access.
//
// CI is the one place where a mistake is invisible locally: the maintainer's machine runs a
// much newer Node and already has gitleaks installed, so a workflow can be broken for months
// while every local command stays green. These rules encode the failures that actually
// happened, so the script test suite catches them instead of a red run on main.
import YAML from 'yaml';

// Two spellings of this command are broken, on different Node versions, and each was found
// only after a red CI run:
//   `node --test 'scripts/__tests__/**/*.test.mjs'`  Node expands `**` itself only from 21
//       onwards; on Node 20 the pattern is taken literally ("Could not find '<pattern>'").
//   `node --test scripts/__tests__`                  a bare directory is resolved as a module
//       on Node 22 ("Cannot find module '…/__tests__'"), though it works on 20 and 26.
// A *shell*-expanded glob of concrete files works on every version, so that is the one
// spelling allowed here. `findUncoveredTestFiles` guards its one weakness: it does not
// recurse into subdirectories.
const NODE_TEST_NODE_GLOB = /node\s+(?:--[\w=-]+\s+)*--test\s+(['"])[^'"]*\*/;
const NODE_TEST_BARE_DIR = /node\s+(?:--[\w=-]+\s+)*--test\s+(?!-)([^\s'"&|;]+)(?=\s|$)/;

export function findNodeTestSpellingProblems(commands) {
  const hits = [];
  for (const { source, command } of commands) {
    if (NODE_TEST_NODE_GLOB.test(command)) {
      hits.push({
        source,
        command: command.trim(),
        reason: 'quoted glob: Node only expands patterns itself from v21, and CI pins v20',
      });
      continue;
    }
    const bare = NODE_TEST_BARE_DIR.exec(command);
    if (bare !== null && !bare[1].endsWith('.mjs') && !bare[1].includes('*')) {
      hits.push({
        source,
        command: command.trim(),
        reason: `bare directory "${bare[1]}": Node 22 resolves it as a module and fails`,
      });
    }
  }
  return hits;
}

/**
 * The shell glob `scripts/__tests__/*.test.mjs` does not recurse, so a test file added in a
 * subdirectory would simply never run — silently, with the suite still green. This names any
 * such file so the omission fails instead.
 */
export function findUncoveredTestFiles(command, testFiles) {
  const patterns = [...command.matchAll(/(\S*\*\S*)/g)].map((m) => m[1].replace(/^['"]|['"]$/g, ''));
  if (patterns.length === 0) return [];
  const matchers = patterns.map((pattern) => new RegExp(
    `^${pattern.split('*').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*')}$`,
  ));
  return testFiles.filter((file) => !matchers.some((matcher) => matcher.test(file)));
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

/**
 * A job that runs npm without `actions/setup-node` silently inherits whatever Node the
 * runner image preinstalls — which differs between the ubuntu and macOS images and moves
 * under us. That is how a `node --test` spelling passed on one job and failed on another in
 * the same commit.
 */
export function findUnpinnedNodeJobs(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    const steps = job?.steps ?? [];
    const usesNpm = steps.some(
      (step) => typeof step?.run === 'string' && /(^|\s)(npm|node)\s/.test(step.run),
    );
    if (!usesNpm) continue;
    const setsUpNode = steps.some((step) => stepUses(step).startsWith('actions/setup-node'));
    if (!setsUpNode) {
      problems.push(`${name}:${jobName} runs npm/node without actions/setup-node; `
        + 'it would inherit whatever version the runner image ships.');
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
