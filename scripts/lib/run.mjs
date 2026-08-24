import { spawn } from "node:child_process";
import { log as defaultLog } from "./log.mjs";

/**
 * Spawn a command and wait for it.
 * Returns { stdout, stderr, code }. Throws on a non-zero exit unless check === false.
 * `log` is injectable so tests stay quiet and callers can capture the transcript.
 */
export async function run(cmd, args = [], options = {}) {
  const {
    cwd = process.cwd(),
    env = process.env,
    capture = false,
    dryRun = false,
    check = true,
    log = defaultLog,
  } = options;

  log.step(`${cmd} ${args.join(" ")}`);
  if (dryRun) return { stdout: "", stderr: "", code: 0 };

  return await new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd,
      env,
      stdio: capture ? ["ignore", "pipe", "pipe"] : ["ignore", "inherit", "inherit"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (d) => { stdout += d.toString(); });
    child.stderr?.on("data", (d) => { stderr += d.toString(); });
    child.on("error", reject);
    child.on("close", (code) => {
      if (check && code !== 0) {
        reject(new Error(`${cmd} ${args.join(" ")} exited with ${code}${stderr ? `\n${stderr}` : ""}`));
        return;
      }
      resolve({ stdout, stderr, code: code ?? 0 });
    });
  });
}
