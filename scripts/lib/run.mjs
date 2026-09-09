import { spawn } from "node:child_process";
import { log as defaultLog } from "./log.mjs";

/**
 * Spawn a command and wait for it.
 * Returns { stdout, stderr, code }. Throws on a non-zero exit unless check === false.
 * `log` is injectable so tests stay quiet and callers can capture the transcript.
 *
 * `redact` lists values that must never reach the transcript or an error message. Every
 * command line here is logged verbatim, and a failure embeds the arguments in the thrown
 * Error, so a secret passed as an argument would otherwise land in CI logs — which are
 * public for this repository. Prefer stdin for secrets; use `redact` where a tool insists
 * on taking one as an argument.
 */
export async function run(cmd, args = [], options = {}) {
  const {
    cwd = process.cwd(),
    env = process.env,
    capture = false,
    dryRun = false,
    check = true,
    input,
    redact = [],
    log = defaultLog,
  } = options;

  const secrets = redact.filter((value) => typeof value === "string" && value !== "");
  const hide = (text) => secrets.reduce((acc, secret) => acc.split(secret).join("***"), text);
  const describe = () => hide(`${cmd} ${args.join(" ")}`);

  log.step(describe());
  if (dryRun) return { stdout: "", stderr: "", code: 0 };

  return await new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd,
      env,
      stdio: [input !== undefined ? "pipe" : "ignore", capture ? "pipe" : "inherit", capture ? "pipe" : "inherit"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (d) => { stdout += d.toString(); });
    child.stderr?.on("data", (d) => { stderr += d.toString(); });
    if (input !== undefined && child.stdin) {
      child.stdin.write(input);
      child.stdin.end();
    }
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (check && (code !== 0 || (code === null && signal))) {
        const reason = code === null && signal ? `was killed with ${signal}` : `exited with ${code}`;
        reject(new Error(hide(`${describe()} ${reason}${stderr ? `\n${stderr}` : ""}`)));
        return;
      }
      resolve({ stdout, stderr, code: code === null && signal ? null : code ?? 0, signal: signal ?? null });
    });
  });
}
