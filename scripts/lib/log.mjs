import pc from "picocolors";

/** Every script writes progress through this object so output stays uniform. */
export const log = {
  info(msg) { console.log(msg); },
  warn(msg) { console.warn(pc.yellow(`! ${msg}`)); },
  error(msg) { console.error(pc.red(`✗ ${msg}`)); },
  step(msg) { console.log(pc.cyan(`▸ ${msg}`)); },
};
