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

import {
  ROOT, MACOS_DIR, DIST_DIR, APP_NAME, EXECUTABLE_NAME, BUNDLE_ID,
  DEPLOYMENT_TARGET, INFO_PLIST_SRC, ICON_SRC, ENTITLEMENTS_SRC, LICENSE_PATH,
} from './lib/paths.mjs';

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
  return path.join(root, 'macos', '.build', triple, configuration);
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
