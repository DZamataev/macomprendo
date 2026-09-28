#!/usr/bin/env node
// Creates Hermes Kanban cards and role profiles for this repository.
//
//   npm run kanban -- card <impl|research|review|fix|gate> "<title>" <task.md|-> <abs workdir> [parent…]
//   npm run kanban -- chain --title "<slice>" --task <task.md> --workdir <abs worktree>
//                           [--after <id>]… [--gate-task <gate.md>] [--hold]
//   npm run kanban -- profiles [--model-impl <provider>:<model>] [--model-review …] [--model-fix …]
//                              [--fallback-impl <provider>:<model>] […] [--clone-from <profile>]
//                              [--force-memory]
//
// Settings: .kanban/config.json (tracked). Notification target: KANBAN_NOTIFY_* in the
// primary checkout's .env.local (gitignored — a chat id names a private group).
// Role preambles: docs/agents/kanban/*.md. The method: docs/hermes_kanban_development.md.
//
// Every card is prepended with its role's standing constraints, so none can be created
// without its prohibitions and gate, and every card is subscribed to the chat and to the
// calling desktop session, so the orchestrator hears about each block and completion.
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { parse as parseYaml, stringify as stringifyYaml } from "yaml";
import { log as defaultLog } from "./lib/log.mjs";
import { run as defaultRun } from "./lib/run.mjs";

export const ROLES = ["impl", "research", "review", "fix", "gate"];

/** Role → template file, profile suffix (null = the operator's), default retries. */
const ROLE_SPEC = {
  impl: { template: "common.md", profile: "impl", retries: 2, commits: true },
  research: { template: "research.md", profile: "impl", retries: 1, commits: false },
  review: { template: "review.md", profile: "review", retries: 1, commits: false },
  fix: { template: "fix.md", profile: "fix", retries: 2, commits: true },
  gate: { template: "gate.md", profile: null, retries: 1, commits: false },
};

const REVIEW_TASK = "Review the implementation chained before you (parent card).\n";
const FIX_TASK = "Apply or reject the findings of the review chained before you (parent card).\n";

const hermesBinary = (env) => env.KANBAN_HERMES || "hermes";

/** Board writes are refused when this leaks in from a parent session. */
function childEnv(env) {
  const next = { ...env };
  delete next.HERMES_DELEGATED_CHILD_CONTEXT;
  return next;
}

// --- config ----------------------------------------------------------------------------------

/** `KEY=value` lines; quotes stripped, comments and blanks ignored. */
export function parseEnvFile(text) {
  const values = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const value = line.slice(eq + 1).trim().replace(/^(['"])(.*)\1$/, "$2");
    values[line.slice(0, eq).trim()] = value;
  }
  return values;
}

async function readIfExists(file) {
  try {
    return await fs.readFile(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

/**
 * The tracked settings of `repoRoot` plus the notify target from `primaryRoot`'s
 * `.env.local`. A worktree has no copy of the gitignored file, so it is always read from
 * the checkout that owns `.git`.
 */
export async function loadConfig(repoRoot, { primaryRoot = repoRoot, env = process.env } = {}) {
  const file = path.join(repoRoot, ".kanban", "config.json");
  const text = await readIfExists(file);
  if (text === null) throw new Error(`${file} is missing — the Kanban setup is not on this branch.`);
  const config = JSON.parse(text);
  for (const key of ["board", "profilePrefix", "gate", "gateOk"]) {
    if (!config[key]) throw new Error(`${file}: "${key}" is empty.`);
  }
  const local = parseEnvFile((await readIfExists(path.join(primaryRoot, ".env.local"))) ?? "");
  const pick = (key) => env[key] || local[key] || "";
  const chatId = pick("KANBAN_NOTIFY_CHAT_ID");
  return {
    templates: "docs/agents/kanban",
    rules: "AGENTS.md",
    baseBranch: "main",
    retries: {},
    maxRuntime: "",
    ...config,
    repoRoot,
    primaryRoot,
    notify: chatId
      ? {
          platform: pick("KANBAN_NOTIFY_PLATFORM") || "telegram",
          chatId,
          threadId: pick("KANBAN_NOTIFY_THREAD_ID"),
          userId: pick("KANBAN_NOTIFY_USER_ID") || chatId,
        }
      : null,
  };
}

/**
 * The desktop/TUI session running this tool, to be subscribed to every card it creates;
 * empty when nobody would read that session: a gateway session (the chat target covers
 * it), a board worker, a cron run, or KANBAN_NOTIFY_SESSION=0.
 */
export function sessionKey(env) {
  if (env.KANBAN_NOTIFY_SESSION === "0") return "";
  if (env.HERMES_SESSION_PLATFORM) return "";
  if (env.HERMES_KANBAN_TASK) return "";
  if (["1", "true", "yes", "on"].includes(env.HERMES_CRON_SESSION ?? "")) return "";
  return env.HERMES_SESSION_KEY ?? "";
}

// --- card bodies -----------------------------------------------------------------------------

/** Replaces `{{NAME}}`; an unknown name is an error, never a literal left for a worker. */
export function renderTemplate(text, values) {
  const missing = new Set();
  const out = text.replace(/\{\{([A-Z_]+)\}\}/g, (whole, key) => {
    if (values[key] === undefined) {
      missing.add(key);
      return whole;
    }
    return values[key];
  });
  if (missing.size > 0) throw new Error(`no value for ${[...missing].sort().join(", ")}`);
  return out;
}

export async function buildCardBody({ role, config, workdir, taskText }) {
  const templateFile = path.join(config.repoRoot, config.templates, ROLE_SPEC[role].template);
  const template = await readIfExists(templateFile);
  if (template === null) throw new Error(`role template missing: ${templateFile}`);
  let body;
  try {
    body = renderTemplate(template, {
      BOARD: config.board,
      GATE: config.gate,
      GATE_OK: config.gateOk,
      BASE: config.baseBranch,
      RULES: config.rules,
      TEMPLATES: config.templates,
      WORKDIR: workdir,
    });
  } catch (error) {
    throw new Error(`${templateFile}: ${error.message}`);
  }
  return taskText ? `${body.trimEnd()}\n\n${taskText}` : body;
}

// --- the board -------------------------------------------------------------------------------

async function kanban(ctx, args, options = {}) {
  const env = childEnv(ctx.env);
  const result = await ctx.run(hermesBinary(env), ["kanban", "--board", ctx.config.board, ...args], {
    capture: true,
    check: false,
    env,
    log: ctx.quiet,
    ...options,
  });
  return result;
}

function parseJson(text, fallback) {
  try {
    return JSON.parse(text || "");
  } catch {
    return fallback;
  }
}

async function subscribe(ctx, id) {
  const { notify } = ctx.config;
  if (notify) {
    const target = ["--platform", notify.platform, "--chat-id", notify.chatId, "--user-id", notify.userId,
      "--delivery-mode", "notify"];
    target.push(...(notify.threadId ? ["--thread-id", notify.threadId, "--chat-type", "thread"] : ["--chat-type", "dm"]));
    const result = await kanban(ctx, ["notify-subscribe", id, ...target]);
    if (result.code !== 0) ctx.log.warn(`${id} was created but the chat subscription failed`);
  }
  const session = sessionKey(ctx.env);
  if (session) {
    const result = await kanban(ctx, ["notify-subscribe", id, "--platform", "tui", "--chat-id", session,
      "--delivery-mode", "notify"]);
    if (result.code !== 0) ctx.log.warn(`${id} was created but the session subscription failed`);
  }
}

async function context(options) {
  const repoRoot = options.repoRoot;
  const env = options.env ?? process.env;
  const config = options.config ?? (await loadConfig(repoRoot, { primaryRoot: options.primaryRoot ?? repoRoot, env }));
  const log = options.log ?? defaultLog;
  const quiet = { info() {}, warn: log.warn, error: log.error, step() {} };
  return { config, env, log, quiet, run: options.run ?? defaultRun };
}

/** Creates one card and returns its id. */
export async function createCard({ role, title, taskFile, workdir, parents = [], blocked = false }, options) {
  const ctx = await context(options);
  const spec = ROLE_SPEC[role];
  if (!spec) throw new Error(`role must be one of ${ROLES.join(", ")}: ${role}`);
  if (!path.isAbsolute(workdir)) throw new Error(`workdir must be absolute: ${workdir}`);
  if (parents.some((parent) => !parent)) {
    throw new Error("empty parent id — a card whose parent did not resolve is dispatched at once");
  }
  const taskText = taskFile && taskFile !== "-" ? await fs.readFile(taskFile, "utf8") : "";
  if (role === "gate" && !taskText) throw new Error("a gate card needs a task file with its questions");
  const body = await buildCardBody({ role, config: ctx.config, workdir, taskText });

  const args = ["create", title, "--body-file", "-", "--json", "--workspace", `dir:${workdir}`,
    "--max-retries", String(ctx.config.retries[role] ?? spec.retries)];
  if (spec.profile) args.push("--assignee", `${ctx.config.profilePrefix}${spec.profile}`);
  // Implement and fix must leave a commit and a clean tree; the board refuses `done` otherwise.
  if (spec.commits) args.push("--completion-contract", "local-commit");
  if (ctx.config.maxRuntime && role !== "gate") args.push("--max-runtime", ctx.config.maxRuntime);
  for (const skill of ctx.config.skills ?? []) args.push("--skill", skill);
  for (const parent of parents) args.push("--parent", parent);
  if (blocked || role === "gate") args.push("--initial-status", "blocked");

  const result = await kanban(ctx, args, { input: body });
  if (result.code !== 0) throw new Error(`hermes kanban create failed for "${title}": ${result.stderr.trim()}`);
  // The id is under `id`, not `task_id`; a missing one means nothing usable was created.
  const id = parseJson(result.stdout, {}).id;
  if (!id) throw new Error(`create returned no id for "${title}": ${result.stdout.trim()}`);
  // --json skips auto-subscribe.
  await subscribe(ctx, id);
  return id;
}

async function parentsOf(ctx, id) {
  const result = await kanban(ctx, ["show", id, "--json"]);
  return parseJson(result.stdout, {}).parents ?? [];
}

async function follows(ctx, id, session) {
  const result = await kanban(ctx, ["notify-list", id, "--json"]);
  const subs = parseJson(result.stdout, []);
  return Array.isArray(subs) && subs.some((s) => (s.platform ?? "").toLowerCase() === "tui" && s.chat_id === session);
}

/**
 * One slice as implement → review → fix (→ operator gate), race-free: every card is
 * created blocked, the edges and the session subscriptions are read back, and only then
 * are the three worker cards released and the dispatcher nudged. The gate stays blocked.
 */
export async function createChain({ title, taskFile, workdir, after = [], gateTaskFile = null, hold = false }, options) {
  const ctx = await context(options);
  const shared = { ...options, config: ctx.config };
  const card = (role, suffix, file, parents) =>
    createCard({ role, title: `${title}: ${suffix}`, taskFile: file, workdir, parents, blocked: true }, shared);

  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-kanban-chain-"));
  try {
    const reviewTask = path.join(scratch, "review.md");
    const fixTask = path.join(scratch, "fix.md");
    await fs.writeFile(reviewTask, REVIEW_TASK);
    await fs.writeFile(fixTask, FIX_TASK);

    const ids = {};
    ids.impl = await card("impl", "implement", taskFile, after);
    ids.review = await card("review", "review", reviewTask, [ids.impl]);
    ids.fix = await card("fix", "fix", fixTask, [ids.review]);
    if (gateTaskFile) ids.gate = await card("gate", "operator gate", gateTaskFile, [ids.fix]);

    const expected = { impl: after, review: [ids.impl], fix: [ids.review], gate: [ids.fix] };
    for (const role of Object.keys(ids)) {
      const got = await parentsOf(ctx, ids[role]);
      if ([...got].sort().join(",") !== [...expected[role]].sort().join(",")) {
        throw new Error(`${role} ${ids[role]} has parents [${got}], expected [${expected[role]}] — board left blocked`);
      }
    }
    const session = sessionKey(ctx.env);
    if (session) {
      const deaf = [];
      for (const role of Object.keys(ids)) if (!(await follows(ctx, ids[role], session))) deaf.push(`${role} ${ids[role]}`);
      if (deaf.length > 0) throw new Error(`session ${session} is not subscribed to ${deaf.join(", ")} — board left blocked`);
      ids.session = session;
    }
    if (!hold) {
      const released = await kanban(ctx, ["unblock", ids.impl, ids.review, ids.fix]);
      if (released.code !== 0) throw new Error(`unblock failed: ${released.stderr.trim()}`);
      await kanban(ctx, ["dispatch"]);
    }
    return ids;
  } finally {
    await fs.rm(scratch, { recursive: true, force: true });
  }
}

// --- profiles --------------------------------------------------------------------------------

function roleMemory(role, repoName) {
  const lines = {
    impl: [
      `Role: implementer for Kanban cards in ${repoName}. Work only in the card's workspace; local commits allowed, never push/merge/rebase/reset/amend/force.`,
      "Read AGENTS.md and the task before editing. AGENTS.md / CLAUDE.md are write-protected: return the exact edit in the summary.",
      "TDD with the RED run quoted; a manual mutation check for every new guarantee (break the line, see the failure, restore). No mutation helper scripts.",
      "Obstacle → kanban_block, reason opening with the action and the path. Summary first line: START_HEAD..END_HEAD, N files, gate: green — nothing about intent.",
    ],
    review: [
      `Role: blind adversarial reviewer for ${repoName}. Read the diff and the repo's rules only; never tasks, plans, the implementer's card or other cards' comments. Reconstruct intent from the diff.`,
      "Run the gate yourself; a summary is a self-report.",
      "Hunt: tests that survive breaking their line; tests asserting something other than their name; Swift 6 races; missed cancellation; layer violations; leaked secrets or transcript text in logs.",
      "State the commit range actually reviewed. Findings F1… with path:line, consequence, concrete fix, severity. Change nothing in the tree.",
    ],
    fix: [
      `Role: remediation for review findings in ${repoName}. Apply each finding with a test and a mutation check, or reject it with proof (output or the refuting line).`,
      "A finding that argues with a written decision (ADR, spec) is not applied: report it as \"needs decision\".",
      "A symptom-shaped finding is fixed on every path that produces it. Two failed attempts on one finding: stop, record, move on.",
      "Local commits only; never push/merge/rebase/reset/amend/force. Summary first line: START_HEAD..END_HEAD, N files, gate: green.",
    ],
  };
  return `${lines[role].join("\n§\n")}\n`;
}

const DESCRIPTIONS = {
  impl: (repo) => `Implements and researches Kanban cards for ${repo}: TDD, mutation checks, neutral summaries`,
  review: (repo) => `Blind adversarial reviewer for ${repo} cards: diff and repo rules only`,
  fix: (repo) => `Applies or rejects review findings with proof for ${repo} cards`,
};

function providerModel(spec, flag) {
  const colon = spec.indexOf(":");
  if (colon <= 0 || colon === spec.length - 1) throw new Error(`${flag} wants <provider>:<model>, got ${spec}`);
  return { provider: spec.slice(0, colon), model: spec.slice(colon + 1) };
}

async function pathExists(file) {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

/**
 * Creates `<prefix>impl`, `<prefix>review` and `<prefix>fix` (existing ones are kept),
 * rewrites every NEW profile's memory to its role — `--clone-from` copies the source
 * profile's MEMORY.md wholesale, and a reviewer that inherits the implementer's notes is
 * not blind — pins models, writes fallback lists, and makes the authors wait out a quota
 * wall instead of finishing on a weaker fallback model.
 */
export async function setupProfiles(
  { prefix, repoName, cloneFrom = "default", models = {}, fallbacks = {}, forceMemory = false },
  { hermesHome = path.join(os.homedir(), ".hermes"), run = defaultRun, env = process.env, log = defaultLog } = {},
) {
  if (!/^[a-z0-9]+$/.test(prefix)) throw new Error(`profile prefix must be lowercase alphanumeric: ${prefix}`);
  for (const [role, spec] of Object.entries(models)) providerModel(spec, `--model-${role}`);
  for (const [role, spec] of Object.entries(fallbacks)) providerModel(spec, `--fallback-${role}`);
  const binary = hermesBinary(env);
  const hermes = (args, home) =>
    run(binary, args, { capture: true, check: true, env: childEnv(home ? { ...env, HERMES_HOME: home } : env), log: { ...log, step() {} } });

  const report = [];
  for (const role of ["impl", "review", "fix"]) {
    const name = `${prefix}${role}`;
    const dir = path.join(hermesHome, "profiles", name);
    let created = false;
    if (await pathExists(dir)) {
      report.push(`${name}: exists`);
    } else {
      await hermes(["profile", "create", name, "--clone-from", cloneFrom, "--no-alias", "--description", DESCRIPTIONS[role](repoName)]);
      if (!(await pathExists(dir))) throw new Error(`profile create reported success but ${dir} is missing`);
      created = true;
      report.push(`${name}: created from ${cloneFrom}`);
    }
    if (created || forceMemory) {
      await fs.mkdir(path.join(dir, "memories"), { recursive: true });
      await fs.writeFile(path.join(dir, "memories", "MEMORY.md"), roleMemory(role, repoName));
      report.push(`${name}: MEMORY.md rewritten to the role`);
    }
    if (models[role]) {
      const { provider, model } = providerModel(models[role], `--model-${role}`);
      await hermes(["config", "set", "model.provider", provider], dir);
      await hermes(["config", "set", "model.default", model], dir);
    }
    if (role !== "review") await hermes(["config", "set", "kanban.worker_fallback", "wait"], dir);
    if (fallbacks[role]) {
      const { provider, model } = providerModel(fallbacks[role], `--fallback-${role}`);
      const configPath = path.join(dir, "config.yaml");
      const current = parseYaml((await readIfExists(configPath)) ?? "") ?? {};
      current.fallback_providers = [{ provider, model }];
      await fs.writeFile(configPath, stringifyYaml(current));
    }
    const configured = (await hermes(["config", "get", "model.default"], dir)).stdout.trim().split("\n").pop();
    report.push(`${name}: model ${configured || "(inherited)"}`);
  }
  for (const line of report) log.info(line);
  log.info(`Check routing after the first real card: grep "OpenAI client created" ${hermesHome}/profiles/${prefix}<role>/logs/agent.log`);
  return report;
}

// --- CLI -------------------------------------------------------------------------------------

async function primaryCheckout(repoRoot) {
  const { stdout } = await defaultRun("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], {
    cwd: repoRoot,
    capture: true,
    log: { ...defaultLog, step() {} },
  });
  return path.dirname(stdout.trim());
}

async function main(argv) {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const primaryRoot = await primaryCheckout(repoRoot);
  const options = { repoRoot, primaryRoot };
  const [command, ...rest] = argv;

  if (command === "card") {
    const [role, title, taskFile, workdir, ...parents] = rest;
    if (!workdir) throw new Error('usage: npm run kanban -- card <role> "<title>" <task.md|-> <abs workdir> [parent…]');
    const blocked = process.env.KANBAN_BLOCKED === "1";
    const taskPath = taskFile === "-" ? "-" : path.resolve(taskFile);
    console.log(await createCard({ role, title, taskFile: taskPath, workdir, parents, blocked }, options));
    return;
  }
  if (command === "chain") {
    const { values } = parseArgs({
      args: rest,
      options: {
        title: { type: "string" },
        task: { type: "string" },
        workdir: { type: "string" },
        after: { type: "string", multiple: true, default: [] },
        "gate-task": { type: "string" },
        hold: { type: "boolean", default: false },
      },
    });
    if (!values.title || !values.task || !values.workdir) {
      throw new Error('usage: npm run kanban -- chain --title "<slice>" --task <task.md> --workdir <abs worktree> [--after <id>]… [--gate-task <gate.md>] [--hold]');
    }
    const ids = await createChain({
      title: values.title,
      taskFile: path.resolve(values.task),
      workdir: values.workdir,
      after: values.after,
      gateTaskFile: values["gate-task"] ? path.resolve(values["gate-task"]) : null,
      hold: values.hold,
    }, options);
    console.log(Object.entries(ids).map(([k, v]) => `${k}=${v}`).join(" "));
    return;
  }
  if (command === "profiles") {
    const spec = { type: "string" };
    const { values } = parseArgs({
      args: rest,
      options: {
        "clone-from": { type: "string", default: "default" },
        "model-impl": spec, "model-review": spec, "model-fix": spec,
        "fallback-impl": spec, "fallback-review": spec, "fallback-fix": spec,
        "force-memory": { type: "boolean", default: false },
      },
    });
    const config = await loadConfig(repoRoot, { primaryRoot });
    const collect = (kind) => Object.fromEntries(
      ["impl", "review", "fix"].filter((role) => values[`${kind}-${role}`]).map((role) => [role, values[`${kind}-${role}`]]),
    );
    await setupProfiles({
      prefix: config.profilePrefix,
      repoName: path.basename(primaryRoot),
      cloneFrom: values["clone-from"],
      models: collect("model"),
      fallbacks: collect("fallback"),
      forceMemory: values["force-memory"],
    }, { hermesHome: process.env.HERMES_HOME || path.join(os.homedir(), ".hermes") });
    return;
  }
  throw new Error("usage: npm run kanban -- <card|chain|profiles> … (see the header of scripts/kanban.mjs)");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    defaultLog.error(error.message);
    process.exit(1);
  });
}
