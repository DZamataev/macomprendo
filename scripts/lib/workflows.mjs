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

/**
 * `secrets` is not an allowed context in `jobs.<id>.if` — GitHub rejects the whole workflow
 * with "Unrecognized named-value: 'secrets'", so this mistake takes CI down entirely rather
 * than merely skipping a job. Presence must be probed in a step and passed on as an output.
 */
export function findSecretsInJobConditions(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    // Must not match a job named `check-signing-secrets` referenced through `needs.…`:
    // only the bare `secrets` context, i.e. not preceded by a word character, hyphen or dot.
    if (typeof job?.if === 'string' && /(^|[^\w.-])secrets\./.test(job.if)) {
      problems.push(`${name}:${jobName} uses the secrets context in a job-level if; `
        + 'GitHub rejects the workflow. Probe it in a step and expose a boolean output.');
    }
  }
  return problems;
}

/**
 * A job that imports a signing certificate must remove it again unconditionally. Without an
 * `if: always()` teardown, a failure between import and cleanup leaves the private key on
 * the runner.
 */
export function findSigningTeardownProblems(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    const steps = job?.steps ?? [];
    const setsUp = steps.some(
      (step) => typeof step?.run === 'string' && /ci-keychain\.mjs\s+setup/.test(step.run),
    );
    if (!setsUp) continue;
    const teardown = steps.find(
      (step) => typeof step?.run === 'string' && /ci-keychain\.mjs\s+teardown/.test(step.run),
    );
    if (teardown === undefined) {
      problems.push(`${name}:${jobName} sets up a signing keychain but never tears it down.`);
    } else if (String(teardown.if ?? '').replace(/\s|\$\{\{|\}\}/g, '') !== 'always()') {
      problems.push(`${name}:${jobName} tears the signing keychain down without if: always(); `
        + 'a failed run would leave the private key on the runner.');
    }
  }
  return problems;
}

/**
 * `runner` is not available in `jobs.<id>.env` — only in step-level env, `with:` and `run:`.
 * actionlint catches it, but a workflow that reaches GitHub with it simply expands to an
 * empty string, silently pointing tools at a bogus path instead of failing.
 */
export function findJobEnvContextProblems(workflow, { name }) {
  const problems = [];
  const disallowedContext = /\$\{\{\s*(runner|steps|job|env)\./;
  // GitHub does not shell-expand env values, so `${RUNNER_TEMP}/…` is passed through as
  // that literal string — a silent wrong path rather than an error.
  const shellExpansion = /\$\{?[A-Z_][A-Z0-9_]*\}?/;
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    for (const [key, value] of Object.entries(job?.env ?? {})) {
      if (typeof value !== 'string') continue;
      if (disallowedContext.test(value)) {
        problems.push(`${name}:${jobName} job-level env ${key} uses a context that is not `
          + 'available there (runner/steps/job/env); move it to the step that needs it.');
      } else if (!value.includes('${{') && shellExpansion.test(value)) {
        problems.push(`${name}:${jobName} job-level env ${key} looks like a shell variable; `
          + 'GitHub passes env values through literally and never expands them.');
      }
    }
  }
  return problems;
}

/**
 * Every step that consumes a signing secret must be gated, so a fork or an unconfigured
 * repository publishes the ad-hoc build instead of failing.
 */
export function findUngatedSigningSteps(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    // The probe job's whole purpose is to read the secrets and publish a boolean; it is the
    // thing that produces SIGNING_AVAILABLE, so it cannot itself be gated on it. It is safe
    // because it only ever emits true/false, never a secret value.
    const producesTheGate = Object.values(job?.outputs ?? {}).some(
      (value) => typeof value === 'string' && /available/i.test(value),
    );
    if (producesTheGate) continue;

    for (const step of job?.steps ?? []) {
      const usesSigningSecret = Object.values(step?.env ?? {}).some(
        (value) => typeof value === 'string' && /secrets\.(MACOS_CERTIFICATE|NOTARY_)/.test(value),
      );
      if (!usesSigningSecret) continue;
      if (!String(step.if ?? '').includes('SIGNING_AVAILABLE')) {
        problems.push(`${name}:${jobName} step "${step.name ?? step.id ?? 'unnamed'}" reads a `
          + 'signing secret without gating on SIGNING_AVAILABLE.');
      }
    }
  }
  return problems;
}

function executableShell(command) {
  return String(command).split('\n')
    .filter((line) => !line.trimStart().startsWith('#'))
    // A guard token after an inline shell comment is inert and must not satisfy an invariant.
    .map((line) => line.replace(/\s+#.*$/, ''))
    .join('\n');
}

function commandLines(shell) {
  return executableShell(shell).split('\n').map((line) => line.trim()).filter(Boolean);
}

function normalizedExpression(value) {
  return String(value ?? '').replace(/\$\{\{|\}\}|\s/g, '');
}

/** The signed and fallback paths must be exact complements, not merely mention the gate. */
export function findSigningGateProblems(workflow, { name }) {
  const problems = [];
  for (const [jobName, job] of Object.entries(workflow.jobs ?? {})) {
    const signingJob = (job?.steps ?? []).some((step) =>
      /ci-keychain\.mjs\s+setup|npm\s+run\s+notarize/.test(executableShell(step?.run)));
    if (!signingJob) continue;
    for (const step of job?.steps ?? []) {
      const run = executableShell(step?.run);
      const label = `${name}:${jobName} step "${step.name ?? step.id ?? 'unnamed'}"`;
      let expected;
      if (/ci-keychain\.mjs\s+setup|npm\s+run\s+notarize/.test(run)) {
        expected = "env.SIGNING_AVAILABLE=='true'";
      } else if (/unsigned/i.test(step?.name ?? '') && /npm\s+run\s+build/.test(run)) {
        expected = "env.SIGNING_AVAILABLE!='true'";
      }
      if (expected && normalizedExpression(step.if) !== expected) {
        problems.push(`${label} must use exactly "${expected}".`);
      }
      if (/Archive/i.test(step?.name ?? '') && /SIGNING_AVAILABLE/.test(run)
          && !/if\s+\[\s+"\$\{SIGNING_AVAILABLE\}"\s+=\s+"true"\s+\]/.test(run)) {
        problems.push(`${label} must select the signed artifact only when SIGNING_AVAILABLE = true.`);
      }
    }
  }
  return problems;
}

/** A rerun that changes signing mode must remove assets belonging to the previous mode. */
export function findReleaseAssetReconciliationProblems(workflow, { name }) {
  const problems = [];
  for (const { source, command } of runCommands(workflow, { name })) {
    const lines = commandLines(command);
    if (!lines.some((line) => /^gh\s+release\s+upload\b/.test(line))) continue;
    const staleLoop = lines.some((line) => /^for\s+STALE_ASSET\s+in\b/.test(line)
      && line.includes('$(basename "$STALE_ZIP")')
      && line.includes('$(basename "${STALE_ZIP}.sha256")'));
    const deletesLoopAsset = lines.some((line) =>
      /^gh\s+release\s+delete-asset\s+"\$TAG"\s+"\$STALE_ASSET"\s+--yes$/.test(line));
    const identifiesBothModes = lines.some((line) =>
      /^STALE_ZIP=.*-macos\.zip"?$/.test(line))
      && lines.some((line) => /^STALE_ZIP=.*-macos-unsigned\.zip"?$/.test(line));
    if (!staleLoop || !deletesLoopAsset || !identifiesBothModes) {
      problems.push(`${source} uploads release assets without removing the opposite signing mode.`);
    }
  }
  return problems;
}

/**
 * Re-publishing an existing release must also clear the draft flag. Deleting a tag turns its
 * published release into a draft, and `gh release edit --latest` on a draft fails with
 * "Latest release cannot be draft or prerelease" — so a re-run would upload the assets and
 * then die, leaving the release invisible to everyone.
 */
export function findDraftClearingProblems(workflow, { name }) {
  const problems = [];
  for (const { source, command } of runCommands(workflow, { name })) {
    const edits = commandLines(command).filter((line) => /^gh\s+release\s+edit\b/.test(line));
    if (edits.length === 0) continue;
    if (!commandLines(command).some((line) => /^--draft=false(?:\s|$|\\)/.test(line)
      || (/^gh\s+release\s+edit\b/.test(line) && /\s--draft=false(?:\s|$|\\)/.test(line)))) {
      problems.push(`${source} edits a release without --draft=false; a release orphaned into `
        + 'a draft (by deleting its tag) cannot be marked --latest.');
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
