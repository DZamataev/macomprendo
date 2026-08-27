// A single, correctly-behaved readline prompt shared by every script that needs to ask
// the operator a question on stdin/stdout (release.mjs's yes/no confirmation,
// configure-notarization.mjs's Apple ID and app-specific-password prompts).
import { createInterface } from 'node:readline';

/**
 * Prompts once on `io.input`/`io.output` and resolves with the trimmed answer.
 *
 * Cleans up the readline interface on every path — an answer, an input-stream error,
 * or the input stream ending (EOF) before an answer was given, which happens whenever
 * stdin is not a TTY: piped from `/dev/null`, a CI runner, or any wrapper that closes
 * stdin. Without an explicit 'close' handler a prompt against an already-ended stream
 * never settles: `rl.question`'s callback simply never fires, so the caller hangs
 * forever instead of failing.
 *
 * `muted` suppresses local echo (for a password) and writes a trailing newline on
 * cleanup so the terminal's next line isn't glued to the prompt.
 * `eofMessage` customizes the error thrown when stdin closes with no answer given —
 * callers should make it actionable for their own situation.
 */
export function prompt(query, { input, output }, { muted = false, eofMessage } = {}) {
  return new Promise((resolve, reject) => {
    const rl = createInterface({ input, output, terminal: true });
    output.write(query);
    if (muted) rl._writeToOutput = () => {};

    let settled = false;
    const cleanup = () => {
      rl.close();
      if (muted) output.write('\n');
    };
    const succeed = (value) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value);
    };
    const fail = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };

    rl.on('error', fail);
    rl.on('close', () => fail(new Error(eofMessage ?? 'stdin closed before an answer was given.')));
    rl.question('', (answer) => succeed(answer.trim()));
  });
}
