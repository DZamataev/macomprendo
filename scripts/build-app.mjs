#!/usr/bin/env node
// Build Macomprendo.app: swift build per architecture, lipo, assemble the bundle, codesign.
//
// SwiftPM emits two kinds of sidecar next to the executable, and both must reach the app:
//   *.bundle     our own target's resources (Macomprendo_Macomprendo.bundle: vendored
//                Phosphor SVGs and other assets). Copied into Contents/Resources, where
//                the generated `Bundle.module` accessor finds them via
//                Bundle.main.resourceURL.
//   *.framework  slices extracted from binary xcframework targets (whisper.cpp is consumed
//                as a prebuilt xcframework, see docs/DECISIONS/ADR-0007). Copied into
//                Contents/Frameworks, an @rpath is added, and each is signed before the
//                enclosing app. If the slices are static, `swift build` emits none and this
//                whole branch is skipped.
// See DISTRIBUTING.md > "What the build copies into the bundle".
import path from 'node:path';
import os from 'node:os';
import { parseArgs } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';

import {
  ROOT, MACOS_DIR, PROJECT_YML, DIST_DIR, APP_NAME, EXECUTABLE_NAME, BUNDLE_ID,
  DEPLOYMENT_TARGET, INFO_PLIST_SRC, ICON_SRC, ENTITLEMENTS_SRC, LICENSE_PATH,
} from './lib/paths.mjs';
import { run as realRun } from './lib/run.mjs';
import { log as realLog } from './lib/log.mjs';
import { realFsOps, realIO } from './lib/fs.mjs';
import { readVersion } from './lib/version.mjs';

const SUPPORTED_ARCHS = ['arm64', 'x86_64'];

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

  return {
    archs,
    sign: values.sign ?? '-',
    configuration,
    deploymentTarget: values['deployment-target'] ?? DEPLOYMENT_TARGET,
    entitlements: values.entitlements ?? ENTITLEMENTS_SRC,
    buildNumber: values['build-number'] ?? null,
    version: values.version ?? null,
    dist: values.dist ?? DIST_DIR,
    dryRun: values['dry-run'],
    help: values.help,
  };
}

export function tripleFor(arch, deploymentTarget) {
  return `${arch}-apple-macosx${deploymentTarget}`;
}

export function predictBinPath(root, triple, configuration) {
  // SwiftPM's --show-bin-path drops the deployment-target version suffix from the
  // triple when naming .build's per-triple directory (arm64-apple-macosx14.0 builds
  // land in .build/arm64-apple-macosx/release, not .build/arm64-apple-macosx14.0/...).
  // tripleFor's version-qualified triple is still what --triple itself needs; only the
  // directory name it predicts here has to match what SwiftPM actually emits on disk.
  const buildDir = triple.replace(/^(.*-apple-macosx)[0-9][0-9.]*$/, '$1');
  return path.join(root, 'macos', '.build', buildDir, configuration);
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
  const { version, buildNumber, binPaths, resourceBundles, frameworks = [] } = context;
  const layout = bundleLayout(options.dist);
  const steps = [];

  for (const arch of options.archs) {
    steps.push({
      type: 'exec',
      cmd: 'swift',
      args: [
        'build', '--package-path', MACOS_DIR,
        '-c', options.configuration,
        '--triple', tripleFor(arch, options.deploymentTarget),
      ],
    });
  }

  steps.push({ type: 'rm', path: layout.app });
  steps.push({ type: 'mkdir', path: layout.macosDir });
  steps.push({ type: 'mkdir', path: layout.resources });
  if (frameworks.length > 0) steps.push({ type: 'mkdir', path: layout.frameworks });

  const slices = options.archs.map((arch) => path.join(binPaths[arch], EXECUTABLE_NAME));
  if (slices.length === 1) {
    steps.push({ type: 'copy', from: slices[0], to: layout.executable });
  } else {
    steps.push({
      type: 'exec',
      cmd: 'lipo',
      args: ['-create', ...slices, '-output', layout.executable],
    });
  }

  steps.push({ type: 'copy', from: INFO_PLIST_SRC, to: layout.infoPlist });
  steps.push({ type: 'copy', from: ICON_SRC, to: path.join(layout.resources, 'AppIcon.icns') });
  steps.push({ type: 'copy', from: LICENSE_PATH, to: path.join(layout.resources, 'LICENSE') });

  const primaryBin = binPaths[options.archs[0]];
  for (const bundle of resourceBundles) {
    steps.push({
      type: 'copy',
      from: path.join(primaryBin, bundle),
      to: path.join(layout.resources, bundle),
    });
  }
  for (const framework of frameworks) {
    steps.push({
      type: 'copy',
      from: path.join(primaryBin, framework),
      to: path.join(layout.frameworks, framework),
    });
  }
  if (frameworks.length > 0) {
    steps.push({
      type: 'exec',
      cmd: 'install_name_tool',
      args: ['-add_rpath', '@executable_path/../Frameworks', layout.executable],
    });
  }

  const plist = (command) => ({
    type: 'exec',
    cmd: '/usr/libexec/PlistBuddy',
    args: ['-c', command, layout.infoPlist],
  });
  steps.push(plist(`Set :CFBundleShortVersionString ${version}`));
  steps.push(plist(`Set :CFBundleVersion ${buildNumber}`));
  steps.push(plist(`Set :CFBundleIdentifier ${BUNDLE_ID}`));

  steps.push({ type: 'chmod', path: layout.executable });

  if (options.sign === '-') {
    steps.push({ type: 'exec', cmd: 'codesign', args: ['--force', '--sign', '-', layout.app] });
  } else {
    // Nested code must be signed before the enclosing bundle, innermost first.
    for (const framework of frameworks) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: [
          '--force', '--options', 'runtime', '--timestamp',
          '--sign', options.sign,
          path.join(layout.frameworks, framework),
        ],
      });
    }
    for (const bundle of resourceBundles) {
      steps.push({
        type: 'exec',
        cmd: 'codesign',
        args: [
          '--force', '--options', 'runtime', '--timestamp',
          '--sign', options.sign,
          path.join(layout.resources, bundle),
        ],
      });
    }
    steps.push({
      type: 'exec',
      cmd: 'codesign',
      args: [
        '--force', '--options', 'runtime', '--timestamp',
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

export async function resolveContext(options, { run, fsOps, io }) {
  const version = options.version ?? readVersion(await io.readFile(PROJECT_YML));
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Could not read a valid X.Y.Z MARKETING_VERSION (got "${version}").`);
  }
  const buildNumber = options.buildNumber ?? version;

  const binPaths = {};
  for (const arch of options.archs) {
    const triple = tripleFor(arch, options.deploymentTarget);
    if (options.dryRun) {
      binPaths[arch] = predictBinPath(ROOT, triple, options.configuration);
    } else {
      const shown = await run('swift', [
        'build', '--package-path', MACOS_DIR,
        '-c', options.configuration, '--triple', triple, '--show-bin-path',
      ], { cwd: ROOT, capture: true });
      binPaths[arch] = shown.stdout.trim();
    }
  }

  const primaryBin = binPaths[options.archs[0]];
  const resourceBundles = await fsOps.listBundles(primaryBin);
  const frameworks = await fsOps.listFrameworks(primaryBin);
  return { version, buildNumber, binPaths, resourceBundles, frameworks };
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
      '  --version <X.Y.Z>        override MARKETING_VERSION from macos/project.yml',
      '  --build-number <n>       CFBundleVersion (default: the version)',
      '  --dist <dir>             output directory (default: dist/)',
      '  --dry-run                print the plan without building',
    ].join('\n'));
    return 0;
  }

  try {
    const context = await resolveContext(options, { run, fsOps, io });
    const steps = planBuild(options, context);
    if (context.resourceBundles.length === 0) {
      log.warn('No SwiftPM resource bundle found next to the executable. The app target '
        + 'declares resources (vendored Phosphor SVGs), so this usually means the build '
        + 'did not run or the resources were dropped from macos/Package.swift.');
    }
    const { outputs } = await executePlan(steps, { run, fsOps, log, dryRun: options.dryRun });
    if (options.dryRun) {
      log.info(`Dry run complete: ${steps.length} steps planned for ${bundleLayout(options.dist).app}`);
      return 0;
    }
    log.info(`Built ${bundleLayout(options.dist).app}`);
    log.info(`Version: ${context.version} (${context.buildNumber})`);
    log.info(`Bundle identifier: ${BUNDLE_ID}`);
    log.info(`Architectures: ${outputs.at(-1) ?? 'unknown'}`);
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
