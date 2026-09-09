---
name: macomprendo-scripts
description: Use when writing or changing anything under scripts/ in Macomprendo — the Node ≥ 20 ESM conventions, the shared helpers, and how to keep a script unit-testable.
---

# Node script conventions

All tooling is Node ≥ 20 ES modules with the `.mjs` extension. There are no shell
scripts in this repository, and there will not be.

## Rules

1. Prefer `node:` built-ins — `child_process`, `fs/promises`, `path`, `crypto`,
   `util.parseArgs`. Add an npm dependency only when it clearly simplifies the code, pin
   it exactly in `package.json`, and commit `package-lock.json`.
2. **Export the logic, guard the CLI.** A script is a module first and an entry point
   second:

   ```js
   export async function doTheThing(repoRoot, options = {}) { /* … */ }

   if (process.argv[1] === fileURLToPath(import.meta.url)) {
     const { values } = parseArgs({ options: { check: { type: "boolean", default: false } } });
     await doTheThing(repoRoot, values);
   }
   ```

   The exported function is what the test calls; the guard is what `npm run` calls.
3. **Never spawn from the exported function's happy path without injection.** Take
   `run` (or a `log`) as an option so tests can pass a stub, or keep the pure logic in a
   separate exported function and let only the CLI wrapper spawn.
4. Use the shared helpers instead of re-implementing them:

   | Helper | Use for |
   |---|---|
   | `lib/run.mjs` → `run(cmd, args, opts)` | Spawning; supports `capture`, `dryRun`, `check`, `log` |
   | `lib/log.mjs` → `log.{info,warn,error,step}` | All console output |
   | `lib/version.mjs` | Reading and rewriting `MARKETING_VERSION` |
   | `lib/fs.mjs` | `ensureSymlink`, `sha256` |

5. Resolve paths from the script's own location, never from `process.cwd()`:

   ```js
   const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
   ```

6. Exit non-zero on failure and print a recovery hint. `--check` modes must be read-only.
7. Add the script to `package.json` `scripts` so it has a stable name.

## Tests

One `scripts/__tests__/<name>.test.mjs` per module, using `node:test` and
`node:assert/strict`. Create temporary directories with
`fs.mkdtemp(path.join(os.tmpdir(), "macomprendo-…"))` — never write inside the repo.

Run them with `npm run test:scripts`, which passes a **shell-expanded glob of files**
(`node --test scripts/__tests__/*.test.mjs`). The other two spellings are each broken on
some Node this project supports: a quoted `'…/**/*.test.mjs'` is taken literally before
Node 21 (CI pins 20), and a bare `scripts/__tests__` directory is resolved as a module on
Node 22. Because a shell glob does not recurse, a test file in a subdirectory would silently
never run — `scripts/__tests__/workflows.test.mjs` asserts both properties.
