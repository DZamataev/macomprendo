import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { parse as parseYaml } from "yaml";
import {
  ROLES,
  buildCardBody,
  createCard,
  createChain,
  loadConfig,
  renderTemplate,
  sessionKey,
  setupProfiles,
} from "../kanban.mjs";

const quietLog = { info() {}, warn() {}, error() {}, step() {} };
const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "..");

/**
 * A stand-in for the `hermes` CLI: records every call and answers the few queries the
 * tool makes (create --json, show --json, notify-list --json, profile create, config).
 */
function fakeHermes({ hermesHome, wrongParent = false, noId = false, failSubscribe = null } = {}) {
  const calls = [];
  const tasks = new Map();
  const subs = [];
  const configSets = new Map();
  let next = 1;
  const run = async (cmd, args, options = {}) => {
    calls.push({ cmd, args, input: options.input });
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (args[0] === "profile" && args[1] === "create") {
      const dir = path.join(hermesHome, "profiles", args[2]);
      await fs.mkdir(path.join(dir, "memories"), { recursive: true });
      await fs.writeFile(path.join(dir, "memories", "MEMORY.md"), "INHERITED from default\n");
      return ok();
    }
    if (args[0] === "config") {
      const home = options.env?.HERMES_HOME ?? "";
      const key = `${home}|${args[2]}`;
      if (args[1] === "set") configSets.set(key, args[3]);
      return ok(configSets.get(key) ?? "");
    }
    const kanban = args.indexOf("kanban");
    const verb = args[kanban + 3];
    const rest = args.slice(kanban + 4);
    if (verb === "create") {
      if (noId) return ok("{}");
      const id = `t_${next++}`;
      const parents = [];
      for (let i = 0; i < rest.length; i++) if (rest[i] === "--parent") parents.push(rest[i + 1]);
      tasks.set(id, { title: rest[0], body: options.input, parents: wrongParent ? [] : parents, args: rest });
      return ok(JSON.stringify({ id }));
    }
    if (verb === "show") return ok(JSON.stringify({ id: rest[0], parents: tasks.get(rest[0])?.parents ?? [] }));
    if (verb === "notify-subscribe") {
      const platform = rest[rest.indexOf("--platform") + 1];
      if (platform === failSubscribe) return { stdout: "", stderr: "refused", code: 1 };
      subs.push({ task: rest[0], platform, chat_id: rest[rest.indexOf("--chat-id") + 1], args: rest });
      return ok();
    }
    if (verb === "notify-list") return ok(JSON.stringify(subs.filter((s) => s.task === rest[0])));
    return ok();
  };
  return { run, calls, tasks, subs, configSets };
}

async function seedRepo({ notify = "" } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-kanban-"));
  await fs.mkdir(path.join(root, ".kanban"), { recursive: true });
  await fs.writeFile(
    path.join(root, ".kanban", "config.json"),
    JSON.stringify({
      board: "demo",
      profilePrefix: "demo",
      templates: "docs/agents/kanban",
      rules: "AGENTS.md",
      gate: "npm run test:swift",
      gateOk: "suites passed after",
      baseBranch: "main",
      retries: { impl: 2, research: 1, review: 1, fix: 2 },
      maxRuntime: "2h",
    }),
  );
  await fs.cp(path.join(repoRoot, "docs", "agents", "kanban"), path.join(root, "docs", "agents", "kanban"), {
    recursive: true,
  });
  if (notify) await fs.writeFile(path.join(root, ".env.local"), notify);
  await fs.writeFile(path.join(root, "task.md"), "Do the thing.\n");
  return root;
}

const noSession = {};
const orchestrator = { HERMES_SESSION_KEY: "sess-orch" };

// --- rendering ---------------------------------------------------------------------------

test("renderTemplate fills every placeholder", () => {
  assert.equal(renderTemplate("gate {{GATE}} in {{WORKDIR}}", { GATE: "npm t", WORKDIR: "/w" }), "gate npm t in /w");
});

test("renderTemplate refuses an unknown placeholder instead of shipping it to a worker", () => {
  assert.throws(() => renderTemplate("{{NOPE}} and {{GATE}}", { GATE: "x" }), /NOPE/);
});

test("every role template in the repository renders with the config's values", async () => {
  const root = await seedRepo();
  const config = await loadConfig(root, { env: {} });
  for (const role of ROLES) {
    const body = await buildCardBody({ role, config, workdir: "/abs/wt", taskText: "TASK" });
    assert.doesNotMatch(body, /\{\{/, `${role} left a placeholder`);
    assert.ok(body.endsWith("TASK\n") || body.endsWith("TASK"), `${role} does not end with the task`);
  }
});

// --- config ------------------------------------------------------------------------------

test("loadConfig reads the tracked config and the notify target from the primary checkout", async () => {
  const primary = await seedRepo({ notify: "KANBAN_NOTIFY_CHAT_ID=-42\nKANBAN_NOTIFY_THREAD_ID=7\n" });
  const worktree = await seedRepo();
  const config = await loadConfig(worktree, { primaryRoot: primary, env: {} });
  assert.equal(config.board, "demo");
  assert.equal(config.repoRoot, worktree);
  assert.deepEqual(config.notify, { platform: "telegram", chatId: "-42", threadId: "7", userId: "-42" });
});

test("loadConfig without .env.local has no notify target", async () => {
  const root = await seedRepo();
  assert.equal((await loadConfig(root, { env: {} })).notify, null);
});

// --- the orchestrating session -------------------------------------------------------------

test("sessionKey is the calling desktop session and nothing else", () => {
  assert.equal(sessionKey(orchestrator), "sess-orch");
  assert.equal(sessionKey({ ...orchestrator, KANBAN_NOTIFY_SESSION: "0" }), "");
  assert.equal(sessionKey({ ...orchestrator, HERMES_SESSION_PLATFORM: "telegram" }), "");
  assert.equal(sessionKey({ ...orchestrator, HERMES_KANBAN_TASK: "t_9" }), "");
  assert.equal(sessionKey({ ...orchestrator, HERMES_CRON_SESSION: "1" }), "");
  assert.equal(sessionKey({}), "");
});

// --- one card ------------------------------------------------------------------------------

test("an implement card carries its preamble, profile, contract and runtime cap", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  const id = await createCard(
    { role: "impl", title: "Slice", taskFile: path.join(root, "task.md"), workdir: root },
    { repoRoot: root, run: hermes.run, env: noSession, log: quietLog },
  );
  assert.equal(id, "t_1");
  const card = hermes.tasks.get(id);
  assert.match(card.body, /Standing constraints/);
  assert.match(card.body, /npm run test:swift/);
  assert.ok(card.body.includes(root));
  assert.ok(card.body.trimEnd().endsWith("Do the thing."));
  const args = card.args.join(" ");
  assert.match(args, /--assignee demoimpl/);
  assert.match(args, /--completion-contract local-commit/);
  assert.match(args, /--max-runtime 2h/);
  assert.match(args, /--max-retries 2/);
  assert.ok(card.args.includes(`dir:${root}`));
  assert.ok(card.args.includes("--body-file") && card.args.includes("-"), "body must go through stdin");
});

test("only implement and fix cards must leave a commit", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  const ctx = { repoRoot: root, run: hermes.run, env: noSession, log: quietLog };
  for (const role of ["fix", "research", "review"]) {
    await createCard({ role, title: role, taskFile: path.join(root, "task.md"), workdir: root }, ctx);
  }
  const contract = (title) => [...hermes.tasks.values()].find((t) => t.title === title).args.includes("--completion-contract");
  assert.equal(contract("fix"), true);
  assert.equal(contract("research"), false);
  assert.equal(contract("review"), false);
});

test("a gate card is created blocked, unassigned and without a runtime cap", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  const id = await createCard(
    { role: "gate", title: "Gate", taskFile: path.join(root, "task.md"), workdir: root },
    { repoRoot: root, run: hermes.run, env: noSession, log: quietLog },
  );
  const args = hermes.tasks.get(id).args;
  assert.ok(args.includes("--initial-status") && args.includes("blocked"));
  assert.equal(args.includes("--assignee"), false);
  assert.equal(args.includes("--max-runtime"), false);
});

test("a card refuses an empty parent, a relative workdir and a create with no id", async () => {
  const root = await seedRepo();
  const ctx = { repoRoot: root, run: fakeHermes().run, env: noSession, log: quietLog };
  const task = path.join(root, "task.md");
  await assert.rejects(createCard({ role: "impl", title: "x", taskFile: task, workdir: root, parents: [""] }, ctx), /parent/);
  await assert.rejects(createCard({ role: "impl", title: "x", taskFile: task, workdir: "rel/path" }, ctx), /absolute/);
  await assert.rejects(
    createCard({ role: "impl", title: "x", taskFile: task, workdir: root }, { ...ctx, run: fakeHermes({ noId: true }).run }),
    /no id/,
  );
});

test("a card is subscribed to the chat and to the orchestrating session", async () => {
  const root = await seedRepo({ notify: "KANBAN_NOTIFY_CHAT_ID=-42\nKANBAN_NOTIFY_THREAD_ID=7\n" });
  const hermes = fakeHermes();
  const id = await createCard(
    { role: "impl", title: "S", taskFile: path.join(root, "task.md"), workdir: root },
    { repoRoot: root, run: hermes.run, env: orchestrator, log: quietLog },
  );
  const subs = hermes.subs.filter((s) => s.task === id);
  assert.deepEqual(subs.map((s) => `${s.platform}:${s.chat_id}`).sort(), ["telegram:-42", "tui:sess-orch"]);
  const chat = subs.find((s) => s.platform === "telegram").args.join(" ");
  assert.match(chat, /--thread-id 7 --chat-type thread/);
});

test("a card made outside a desktop session subscribes no session", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  await createCard(
    { role: "impl", title: "S", taskFile: path.join(root, "task.md"), workdir: root },
    { repoRoot: root, run: hermes.run, env: noSession, log: quietLog },
  );
  assert.equal(hermes.subs.length, 0);
});

// --- a chain -------------------------------------------------------------------------------

test("a chain is created blocked, checked, then only its head is released", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  const ids = await createChain(
    { title: "List", taskFile: path.join(root, "task.md"), workdir: root, after: ["t_0"], gateTaskFile: path.join(root, "task.md") },
    { repoRoot: root, run: hermes.run, env: orchestrator, log: quietLog },
  );
  assert.deepEqual(Object.keys(ids), ["impl", "review", "fix", "gate", "session"]);
  assert.deepEqual(hermes.tasks.get(ids.impl).parents, ["t_0"]);
  assert.deepEqual(hermes.tasks.get(ids.review).parents, [ids.impl]);
  assert.deepEqual(hermes.tasks.get(ids.fix).parents, [ids.review]);
  assert.deepEqual(hermes.tasks.get(ids.gate).parents, [ids.fix]);
  for (const id of [ids.impl, ids.review, ids.fix, ids.gate]) {
    assert.ok(hermes.tasks.get(id).args.includes("blocked"), `${id} was not created blocked`);
  }
  const verbs = hermes.calls.map((c) => c.args[c.args.indexOf("kanban") + 3]);
  assert.ok(verbs.lastIndexOf("show") < verbs.indexOf("unblock"), "released before the edges were checked");
  const unblock = hermes.calls.find((c) => c.args.includes("unblock")).args;
  assert.equal(unblock.includes(ids.gate), false, "the operator gate must stay blocked");
  assert.equal(verbs.filter((v) => v === "dispatch").length, 1);
  assert.equal(hermes.subs.filter((s) => s.platform === "tui").length, 4);
});

test("a chain whose edge did not land releases nothing", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes({ wrongParent: true });
  await assert.rejects(
    createChain({ title: "Bad", taskFile: path.join(root, "task.md"), workdir: root, after: ["t_0"] },
      { repoRoot: root, run: hermes.run, env: noSession, log: quietLog }),
    /parents/,
  );
  assert.equal(hermes.calls.some((c) => c.args.includes("unblock")), false);
});

test("a chain the orchestrating session would not hear about releases nothing", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes({ failSubscribe: "tui" });
  await assert.rejects(
    createChain({ title: "Deaf", taskFile: path.join(root, "task.md"), workdir: root },
      { repoRoot: root, run: hermes.run, env: orchestrator, log: quietLog }),
    /not subscribed/,
  );
  assert.equal(hermes.calls.some((c) => c.args.includes("unblock")), false);
});

test("a held chain is created but not released", async () => {
  const root = await seedRepo();
  const hermes = fakeHermes();
  await createChain({ title: "Held", taskFile: path.join(root, "task.md"), workdir: root, hold: true },
    { repoRoot: root, run: hermes.run, env: noSession, log: quietLog });
  assert.equal(hermes.calls.some((c) => c.args.includes("unblock") || c.args.includes("dispatch")), false);
});

// --- profiles ------------------------------------------------------------------------------

test("profiles creates three roles and rewrites each cloned memory to its role", async () => {
  const hermesHome = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-hermes-"));
  const hermes = fakeHermes({ hermesHome });
  await setupProfiles({ prefix: "demo", repoName: "macomprendo" }, { hermesHome, run: hermes.run, log: quietLog });
  for (const role of ["impl", "review", "fix"]) {
    const memory = await fs.readFile(path.join(hermesHome, "profiles", `demo${role}`, "memories", "MEMORY.md"), "utf8");
    assert.doesNotMatch(memory, /INHERITED/, `demo${role} kept the cloned memory`);
  }
  const review = await fs.readFile(path.join(hermesHome, "profiles", "demoreview", "memories", "MEMORY.md"), "utf8");
  assert.match(review, /blind adversarial reviewer/);
});

test("profiles keeps an existing profile's memory unless forced", async () => {
  const hermesHome = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-hermes-"));
  const hermes = fakeHermes({ hermesHome });
  const ctx = { hermesHome, run: hermes.run, log: quietLog };
  await setupProfiles({ prefix: "demo", repoName: "macomprendo" }, ctx);
  const memory = path.join(hermesHome, "profiles", "demoimpl", "memories", "MEMORY.md");
  await fs.writeFile(memory, "KEEP\n");
  await setupProfiles({ prefix: "demo", repoName: "macomprendo" }, ctx);
  assert.equal(await fs.readFile(memory, "utf8"), "KEEP\n");
  await setupProfiles({ prefix: "demo", repoName: "macomprendo", forceMemory: true }, ctx);
  assert.notEqual(await fs.readFile(memory, "utf8"), "KEEP\n");
});

test("profiles makes authors wait out a quota wall and leaves the reviewer on fallback", async () => {
  const hermesHome = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-hermes-"));
  const hermes = fakeHermes({ hermesHome });
  await setupProfiles({ prefix: "demo", repoName: "macomprendo" }, { hermesHome, run: hermes.run, log: quietLog });
  const homes = [...hermes.configSets.entries()]
    .filter(([key, value]) => key.endsWith("|kanban.worker_fallback") && value === "wait")
    .map(([key]) => path.basename(key.split("|")[0]));
  assert.deepEqual(homes.sort(), ["demofix", "demoimpl"]);
});

test("profiles pins a model and writes a fallback list without touching other keys", async () => {
  const hermesHome = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-hermes-"));
  const hermes = fakeHermes({ hermesHome });
  const ctx = { hermesHome, run: hermes.run, log: quietLog };
  await setupProfiles({ prefix: "demo", repoName: "macomprendo" }, ctx);
  const configPath = path.join(hermesHome, "profiles", "demoreview", "config.yaml");
  await fs.writeFile(configPath, "model:\n  default: x\nfallback_providers:\n- provider: old\n  model: y\n");
  await setupProfiles(
    { prefix: "demo", repoName: "macomprendo", models: { review: "codex:gpt-x" }, fallbacks: { review: "other:gpt-y" } },
    ctx,
  );
  const reviewHome = path.join(hermesHome, "profiles", "demoreview");
  assert.equal(hermes.configSets.get(`${reviewHome}|model.provider`), "codex");
  assert.equal(hermes.configSets.get(`${reviewHome}|model.default`), "gpt-x");
  const config = parseYaml(await fs.readFile(configPath, "utf8"));
  assert.deepEqual(config.fallback_providers, [{ provider: "other", model: "gpt-y" }]);
  assert.deepEqual(config.model, { default: "x" });
});

test("profiles refuses a model without a provider", async () => {
  const hermesHome = await fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-hermes-"));
  await assert.rejects(
    setupProfiles({ prefix: "demo", repoName: "m", models: { impl: "just-a-model" } },
      { hermesHome, run: fakeHermes({ hermesHome }).run, log: quietLog }),
    /provider/,
  );
});

// --- the repository's own setup ------------------------------------------------------------

test("the repository's kanban config names this repo's gate and a board", async () => {
  const config = await loadConfig(repoRoot, { env: {} });
  assert.equal(config.gate, "npm run test:swift");
  assert.ok(config.board && config.profilePrefix);
});

test("the kanban setup refers to nothing outside this repository", async () => {
  const files = [
    "docs/hermes_kanban_development.md",
    "scripts/kanban.mjs",
    ...ROLES.map((role) => `docs/agents/kanban/${role === "impl" ? "common" : role}.md`),
  ];
  for (const file of files) {
    const text = await fs.readFile(path.join(repoRoot, file), "utf8");
    assert.doesNotMatch(text, /HERMES_SKILL_DIR|skills\/software-development|hermes-tools|~\/dev\//, `${file} reaches outside the repo`);
  }
});
