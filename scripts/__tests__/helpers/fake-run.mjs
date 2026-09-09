// Test doubles for the injected side-effect boundaries used by scripts/*.mjs.
// This file is NOT a test file (node --test only collects *.test.mjs here).

/**
 * @param {Array<{ stdout?: string, stderr?: string, code?: number, throws?: string, signal?: string }>} script
 *        One entry per expected call, consumed in order. Missing entries behave as success.
 *        `signal` reproduces a signal-killed child exactly as scripts/lib/run.mjs resolves
 *        one: under `check: false` it resolves with `code: null, signal`; under the default
 *        `check: true` it rejects, the same as any other non-zero exit.
 */
export function makeFakeRun(script = []) {
  let index = 0;
  const calls = [];
  const run = async (cmd, args = [], options = {}) => {
    calls.push({ cmd, args, options, line: [cmd, ...args].join(' ') });
    const next = script[index] ?? {};
    index += 1;
    if (next.signal) {
      const stdout = next.stdout ?? '';
      const stderr = next.stderr ?? '';
      if (options.check === false) return { stdout, stderr, code: null, signal: next.signal };
      const error = new Error(
        `${cmd} ${args.join(' ')} was killed with ${next.signal}${stderr ? `\n${stderr}` : ''}`,
      );
      error.stdout = stdout;
      error.stderr = stderr;
      throw error;
    }
    if (next.throws) {
      const error = new Error(next.throws);
      error.exitCode = next.code ?? 1;
      error.stdout = next.stdout ?? '';
      error.stderr = next.stderr ?? '';
      if (options.check === false) return { stdout: error.stdout, stderr: error.stderr, code: error.exitCode };
      throw error;
    }
    return { stdout: next.stdout ?? '', stderr: next.stderr ?? '', code: next.code ?? 0 };
  };
  run.calls = calls;
  run.lines = () => calls.map((call) => call.line);
  return run;
}

export function makeFakeFsOps(existing = []) {
  const present = new Set(existing);
  const events = [];
  return {
    events,
    present,
    async mkdirp(dir) { events.push(['mkdirp', dir]); present.add(dir); },
    async rmrf(target) { events.push(['rmrf', target]); present.delete(target); },
    async copyPath(from, to) { events.push(['copyPath', from, to]); present.add(to); },
    async chmodExec(file) { events.push(['chmodExec', file]); },
    async pathExists(p) { return present.has(p); },
    async isDirectory(p) { return present.has(p); },
    async listBundles(dir) { events.push(['listBundles', dir]); return this.bundles ?? []; },
    async listFrameworks(dir) { events.push(['listFrameworks', dir]); return this.frameworks ?? []; },
    async move(from, to) { events.push(['move', from, to]); present.delete(from); present.add(to); },
    async mkdtemp(prefix) {
      const dir = `${prefix}${Math.random().toString(36).slice(2, 8)}`;
      events.push(['mkdtemp', prefix]);
      present.add(dir);
      return dir;
    },
    bundles: [],
    frameworks: [],
  };
}

export function makeFakeIO(files = {}) {
  const store = new Map(Object.entries(files));
  const writes = [];
  return {
    store,
    writes,
    async readFile(p) {
      if (!store.has(p)) throw Object.assign(new Error(`ENOENT: ${p}`), { code: 'ENOENT' });
      return store.get(p);
    },
    async writeFile(p, text) { store.set(p, text); writes.push(p); },
    async writeBinaryFile(p, base64) { store.set(p, Buffer.from(base64, 'base64')); writes.push(p); },
    async exists(p) { return store.has(p); },
  };
}

export function makeFakeLog() {
  const lines = [];
  const push = (level) => (msg) => lines.push(`${level}: ${msg}`);
  return { lines, info: push('info'), warn: push('warn'), error: push('error'), step: push('step') };
}
