#!/usr/bin/env node
// Build a universal Developer ID release, notarize it with Apple, staple the ticket,
// and emit dist/Macomprendo-<version>-macos.zip plus its SHA-256 sidecar.
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import { ROOT, DIST_DIR, APP_NAME, NOTARY_PROFILE, TEAM_ID, PROJECT_YML } from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO, sha256 as realSha256 } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';
import { describeStep } from './build-app.mjs';

const IDENTITY_PATTERN = /"(Developer ID Application:[^"]+)"/;

export function parseNotarizeArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      sign: { type: 'string' },
      profile: { type: 'string' },
      timeout: { type: 'string' },
      dist: { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  return {
    sign: values.sign ?? null,
    profile: values.profile ?? process.env.NOTARYTOOL_PROFILE ?? NOTARY_PROFILE,
    timeout: values.timeout ?? '60m',
    dist: values.dist ?? DIST_DIR,
    dryRun: values['dry-run'],
    help: values.help,
  };
}

export function parseIdentity(securityOutput) {
  for (const line of String(securityOutput).split('\n')) {
    const match = IDENTITY_PATTERN.exec(line);
    if (match !== null) return match[1];
  }
  return null;
}

export function parseSubmission(jsonText) {
  try {
    const parsed = JSON.parse(jsonText);
    return {
      id: parsed.id ?? null,
      status: parsed.status ?? null,
      message: parsed.message ?? '',
    };
  } catch {
    return { id: null, status: null, message: String(jsonText).trim() };
  }
}

export function planNotarize({ identity, profile, timeout, dist, version }) {
  const app = path.join(dist, APP_NAME);
  const submission = path.join(dist, `Macomprendo-${version}-notarization.zip`);
  const final = path.join(dist, `Macomprendo-${version}-macos.zip`);
  return [
    {
      type: 'exec', cmd: 'xcrun',
      args: ['notarytool', 'history', '--keychain-profile', profile, '--output-format', 'json'],
    },
    {
      type: 'exec', cmd: 'node',
      args: [
        'scripts/build-app.mjs',
        '--arch', 'arm64,x86_64',
        '--configuration', 'release',
        '--sign', identity,
        '--version', version,
        '--dist', dist,
      ],
    },
    { type: 'rm', path: submission },
    { type: 'rm', path: final },
    {
      type: 'exec', cmd: 'ditto',
      args: ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submission],
    },
    {
      type: 'exec', cmd: 'xcrun', capture: true,
      args: [
        'notarytool', 'submit', submission,
        '--keychain-profile', profile,
        '--wait', '--timeout', timeout,
        '--output-format', 'json',
      ],
    },
    { type: 'exec', cmd: 'xcrun', args: ['stapler', 'staple', app] },
    { type: 'exec', cmd: 'xcrun', args: ['stapler', 'validate', app] },
    { type: 'exec', cmd: 'codesign', args: ['--verify', '--deep', '--strict', '--verbose=2', app] },
    { type: 'exec', cmd: 'spctl', args: ['--assess', '--type', 'execute', '--verbose=4', app] },
    {
      type: 'exec', cmd: 'ditto',
      args: ['-c', '-k', '--sequesterRsrc', '--keepParent', app, final],
    },
    { type: 'rm', path: submission },
    { type: 'sha256', path: final, out: `${final}.sha256` },
  ];
}

const MISSING_IDENTITY_HELP = [
  'No "Developer ID Application" certificate with a private key is installed.',
  `Create one for team ${TEAM_ID}:`,
  '  1. Sign in at developer.apple.com > Certificates, Identifiers & Profiles > Certificates.',
  '  2. Add a certificate of type "Developer ID Application" and upload a CSR from Keychain Access',
  '     (Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority).',
  '  3. Download the .cer and double-click it so it lands in the login keychain next to its private key.',
  '  4. Re-check with: security find-identity -v -p codesigning',
  'An "Apple Development" certificate is enough for local builds but cannot be notarized.',
  'Meanwhile, build an ad-hoc signed app with: npm run build',
].join('\n');

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps, io = realIO, sha256 = realSha256,
  } = deps;

  let options;
  try {
    options = parseNotarizeArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run notarize -- [options]',
      '',
      '  --sign <identity>  Developer ID identity (default: the first one found)',
      '  --profile <name>   notarytool keychain profile (default: macomprendo-notary)',
      '  --timeout <dur>    notarytool --wait timeout (default: 60m)',
      '  --dist <dir>       output directory (default: dist/)',
      '  --dry-run          print the plan without contacting Apple',
    ].join('\n'));
    return 0;
  }

  try {
    let identity = options.sign;
    if (identity === null) {
      const found = await run('security', ['find-identity', '-v', '-p', 'codesigning'], {
        capture: true, check: false, cwd: ROOT,
      });
      if (found.code === null) {
        throw new Error(`security find-identity was killed (signal ${found.signal}).`);
      }
      identity = parseIdentity(found.stdout ?? '');
    }
    if (identity === null) {
      log.error(MISSING_IDENTITY_HELP);
      return 1;
    }
    log.info(`Signing identity: ${identity}`);

    const version = readVersion(await io.readFile(PROJECT_YML));
    const steps = planNotarize({
      identity, profile: options.profile, timeout: options.timeout,
      dist: options.dist, version,
    });

    if (options.dryRun) {
      for (const step of steps) {
        log.info(step.type === 'sha256' ? `sha256 ${step.path} > ${step.out}` : describeStep(step));
      }
      log.info(`Dry run complete: ${steps.length} steps planned.`);
      return 0;
    }

    for (const step of steps) {
      if (step.type === 'rm') {
        await fsOps.rmrf(step.path);
        continue;
      }
      if (step.type === 'sha256') {
        const digest = await sha256(step.path);
        await io.writeFile(step.out, `${digest}  ${path.basename(step.path)}\n`);
        log.info(`SHA-256: ${digest}`);
        continue;
      }
      log.step(describeStep(step));
      const result = await run(step.cmd, step.args, { cwd: ROOT, capture: step.capture === true });

      if (step.capture === true && step.args[1] === 'submit') {
        const submission = parseSubmission(result.stdout ?? '');
        log.info(`Submission ${submission.id ?? 'unknown'}: ${submission.status ?? 'unknown'}`);
        if (submission.status !== 'Accepted') {
          if (submission.id !== null) {
            const logPath = path.join(options.dist, `notary-log-${submission.id}.json`);
            const logResult = await run('xcrun', [
              'notarytool', 'log', submission.id, '--keychain-profile', options.profile, logPath,
            ], { cwd: ROOT, check: false });
            if (logResult.code === null) {
              log.error(`Fetching the notary log was killed (signal ${logResult.signal}); `
                + `no log written to ${logPath}.`);
            } else if (logResult.code !== 0) {
              log.error(`Fetching the notary log failed (exit ${logResult.code}); `
                + `no log written to ${logPath}.`);
            } else {
              log.error(`Notary log written to ${logPath}`);
            }
          }
          log.error(`Notarization was not accepted (status: ${submission.status ?? 'unknown'}). `
            + `${submission.message}`);
          return 1;
        }
      }
    }

    const final = path.join(options.dist, `Macomprendo-${version}-macos.zip`);
    log.info(`Notarized release: ${final}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
