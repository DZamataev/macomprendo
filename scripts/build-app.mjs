#!/usr/bin/env node
// Build Macomprendo.app with Xcode, then sign the finished bundle inner-to-outer.
//
// `swift build` emits resource accessors for executable targets that look beside
// `Bundle.main.bundleURL`. That location is outside Contents/ and cannot be signed as a valid
// macOS app. Xcode emits app-aware accessors and places package resources in Contents/Resources,
// so its product is the source bundle for local installs and releases.
// See DISTRIBUTING.md > "Xcode app layout".
import path from 'node:path';
import os from 'node:os';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';

import {
  ROOT, MACOS_DIR, PROJECT_YML, DIST_DIR, APP_NAME, EXECUTABLE_NAME, BUNDLE_ID,
  DEPLOYMENT_TARGET, ENTITLEMENTS_SRC, LICENSE_PATH,
} from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';

const SUPPORTED_ARCHS = ['arm64', 'x86_64'];
const EMBEDDED_FRAMEWORKS = ['SherpaOnnxC.framework', 'whisper.framework'];

export function parseBuildArgs(argv) {
  const { values } = parseArgs({
    args: argv,
    allowPositionals: false,
    options: {
      arch: { type: 'string' },
      sign: { type: 'string' },
      configuration: { type: 'string' },
      'deployment-target': { type: 'string' },
      entitlements: { type: 'string' },
      timestamp: { type: 'string' },
      'build-number': { type: 'string' },
      version: { type: 'string' },
      dist: { type: 'string' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });

  const archSource = values.arch ?? (os.arch() === 'arm64' ? 'arm64' : 'x86_64');
  const archs = archSource.split(',').map((a) => a.trim()).filter((a) => a !== '');
  if (archs.length === 0) throw new Error('--arch needs at least one architecture.');
  for (const arch of archs) {
    if (!SUPPORTED_ARCHS.includes(arch)) {
      throw new Error(`Unsupported architecture "${arch}". Use arm64 and/or x86_64.`);
    }
  }

  const configuration = values.configuration ?? 'release';
  if (configuration !== 'release' && configuration !== 'debug') {
    throw new Error('Configuration must be "release" or "debug".');
  }

  const timestamp = values.timestamp ?? 'auto';
  if (timestamp !== 'auto' && timestamp !== 'none') {
    throw new Error('Timestamp must be "auto" or "none".');
  }

  return {
    archs,
    sign: values.sign ?? '-',
    configuration,
    deploymentTarget: values['deployment-target'] ?? DEPLOYMENT_TARGET,
    entitlements: values.entitlements ?? ENTITLEMENTS_SRC,
    timestamp,
    buildNumber: values['build-number'] ?? null,
    version: values.version ?? null,
    dist: values.dist ?? DIST_DIR,
    dryRun: values['dry-run'],
    help: values.help,
  };
}

export function bundleLayout(distDir) {
  const app = path.join(distDir, APP_NAME);
  const contents = path.join(app, 'Contents');
  return {
    app,
    contents,
    macosDir: path.join(contents, 'MacOS'),
    resources: path.join(contents, 'Resources'),
    frameworks: path.join(contents, 'Frameworks'),
    executable: path.join(contents, 'MacOS', EXECUTABLE_NAME),
    infoPlist: path.join(contents, 'Info.plist'),
  };
}

export function planBuild(options, context) {
  const { version, buildNumber } = context;
  const layout = bundleLayout(options.dist);
  const derivedData = path.join(options.dist, '.derived-data');
  const xcodeConfiguration = options.configuration === 'release' ? 'Release' : 'Debug';
  const xcodeApp = path.join(derivedData, 'Build', 'Products', xcodeConfiguration, APP_NAME);
  const steps = [];

  steps.push({ type: 'rm', path: derivedData });
  steps.push({ type: 'rm', path: layout.app });
  steps.push({
    type: 'exec',
    cmd: 'xcodebuild',
    args: [
      '-project', path.join(MACOS_DIR, 'Macomprendo.xcodeproj'),
      '-scheme', 'Macomprendo',
      '-configuration', xcodeConfiguration,
      '-destination', 'generic/platform=macOS',
      '-derivedDataPath', derivedData,
      `ARCHS=${options.archs.join(' ')}`,
      `ONLY_ACTIVE_ARCH=${options.archs.length === 1 ? 'YES' : 'NO'}`,
      `MACOSX_DEPLOYMENT_TARGET=${options.deploymentTarget}`,
      `MARKETING_VERSION=${version}`,
      `CURRENT_PROJECT_VERSION=${buildNumber}`,
      `PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}`,
      'CODE_SIGNING_ALLOWED=NO',
      'CODE_SIGNING_REQUIRED=NO',
      'ENABLE_CODE_COVERAGE=NO',
      'CLANG_ENABLE_CODE_COVERAGE=NO',
      'CLANG_COVERAGE_MAPPING=NO',
      'CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO',
      'build',
    ],
  });
  steps.push({ type: 'copy', from: xcodeApp, to: layout.app });
  steps.push({ type: 'copy', from: LICENSE_PATH, to: path.join(layout.resources, 'LICENSE') });

  const plist = (command) => ({
    type: 'exec',
    cmd: '/usr/libexec/PlistBuddy',
    args: ['-c', command, layout.infoPlist],
  });
  steps.push(plist(`Set :CFBundleShortVersionString ${version}`));
  steps.push(plist(`Set :CFBundleVersion ${buildNumber}`));
  steps.push(plist(`Set :CFBundleIdentifier ${BUNDLE_ID}`));

  steps.push({ type: 'chmod', path: layout.executable });

  // Nested code is signed innermost-out, then the app. Xcode has already placed package
  // resources under Contents/Resources, where the app signature seals them. --deep is
  // intentionally never used for signing (only for the verification step below): it is
  // deprecated for signing and would hide ordering bugs.
  if (options.sign === '-') {
    for (const framework of EMBEDDED_FRAMEWORKS) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: ['--force', '--sign', '-', path.join(layout.frameworks, framework)],
      });
    }
    steps.push({ type: 'exec', cmd: 'codesign', args: ['--force', '--sign', '-', layout.app] });
  } else {
    const timestampArgs = options.timestamp === 'none' ? ['--timestamp=none'] : ['--timestamp'];
    for (const framework of EMBEDDED_FRAMEWORKS) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: [
          '--force', '--options', 'runtime', ...timestampArgs,
          '--sign', options.sign,
          path.join(layout.frameworks, framework),
        ],
      });
    }
    steps.push({
      type: 'exec',
      cmd: 'codesign',
      args: [
        '--force', '--options', 'runtime', ...timestampArgs,
        '--entitlements', options.entitlements,
        '--sign', options.sign,
        layout.app,
      ],
    });
  }

  steps.push({
    type: 'exec',
    cmd: 'codesign',
    args: ['--verify', '--deep', '--strict', '--verbose=2', layout.app],
  });
  steps.push({ type: 'exec', cmd: 'lipo', args: ['-archs', layout.executable], capture: true });

  return steps;
}

export function describeStep(step) {
  switch (step.type) {
    case 'exec': {
      const quoted = step.args.map((a) => (/[\s"]/.test(a) ? JSON.stringify(a) : a));
      return [step.cmd, ...quoted].join(' ');
    }
    case 'rm': return `rm -rf ${step.path}`;
    case 'mkdir': return `mkdir -p ${step.path}`;
    case 'copy': return `cp -R ${step.from} ${step.to}`;
    case 'chmod': return `chmod 755 ${step.path}`;
    default: throw new Error(`Unknown step type: ${step.type}`);
  }
}

export function validateArchitectures(requested, output) {
  const expected = [...new Set(requested)].sort();
  const actual = [...new Set(output.trim().split(/\s+/).filter(Boolean))].sort();
  if (expected.length !== actual.length || expected.some((arch, index) => arch !== actual[index])) {
    throw new Error(
      `Architecture mismatch: requested ${expected.join(', ')}; built ${actual.join(', ') || 'none'}.`,
    );
  }
  return actual;
}

export async function executePlan(steps, { run, fsOps, log, dryRun }) {
  const outputs = [];
  for (const step of steps) {
    const description = describeStep(step);
    if (dryRun) {
      log.info(description);
      continue;
    }
    log.step(description);
    switch (step.type) {
      case 'rm': await fsOps.rmrf(step.path); break;
      case 'mkdir': await fsOps.mkdirp(step.path); break;
      case 'copy': await fsOps.copyPath(step.from, step.to); break;
      case 'chmod': await fsOps.chmodExec(step.path); break;
      case 'exec': {
        const result = await run(step.cmd, step.args, { cwd: ROOT, capture: step.capture === true });
        if (step.capture === true) outputs.push((result.stdout ?? '').trim());
        break;
      }
      default: throw new Error(`Unknown step type: ${step.type}`);
    }
  }
  return { outputs };
}

export async function resolveContext(options, { io }) {
  const version = options.version ?? readVersion(await io.readFile(PROJECT_YML));
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Could not read a valid X.Y.Z MARKETING_VERSION (got "${version}").`);
  }
  const buildNumber = options.buildNumber ?? version;

  return { version, buildNumber };
}

export async function main(argv, deps = {}) {
  const {
    run = realRun, log = realLog, fsOps = realFsOps, io = realIO,
  } = deps;

  let options;
  try {
    options = parseBuildArgs(argv);
  } catch (error) {
    log.error(error.message);
    return 2;
  }

  if (options.help) {
    log.info([
      'Usage: npm run build -- [options]',
      '',
      '  --arch <list>            arm64, x86_64, or "arm64,x86_64" (default: host arch)',
      '  --sign <identity>        codesign identity; "-" for ad-hoc (default: -)',
      '  --configuration <name>   release | debug (default: release)',
      '  --deployment-target <v>  macOS deployment target (default: 14.0)',
      '  --entitlements <path>    entitlements plist for hardened-runtime signing',
      '  --timestamp <mode>       auto | none (default: auto; none for local Developer ID installs)',
      '  --version <X.Y.Z>        override MARKETING_VERSION from macos/project.yml',
      '  --build-number <n>       CFBundleVersion (default: the version)',
      '  --dist <dir>             output directory (default: dist/)',
      '  --dry-run                print the plan without building',
    ].join('\n'));
    return 0;
  }

  try {
    const context = await resolveContext(options, { io });
    const steps = planBuild(options, context);
    const { outputs } = await executePlan(steps, { run, fsOps, log, dryRun: options.dryRun });
    if (options.dryRun) {
      log.info(`Dry run complete: ${steps.length} steps planned for ${bundleLayout(options.dist).app}`);
      return 0;
    }
    const architectures = validateArchitectures(options.archs, outputs.at(-1) ?? '');
    log.info(`Built ${bundleLayout(options.dist).app}`);
    log.info(`Version: ${context.version} (${context.buildNumber})`);
    log.info(`Bundle identifier: ${BUNDLE_ID}`);
    log.info(`Architectures: ${architectures.join(' ')}`);
    log.info(options.sign === '-' ? 'Signed ad hoc for local use.' : `Signed with ${options.sign}`);
    return 0;
  } catch (error) {
    log.error(error.message);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2));
}
