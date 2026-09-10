import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

import {
  parseBuildArgs, bundleLayout, planBuild, describeStep,
  executePlan, resolveContext, validateArchitectures, main,
} from '../build-app.mjs';
import { ROOT, DIST_DIR, BUNDLE_ID, PROJECT_YML } from '../lib/paths.mjs';
import { makeFakeRun, makeFakeFsOps, makeFakeIO, makeFakeLog } from './helpers/fake-run.mjs';

test('parseBuildArgs defaults to the host architecture and an ad-hoc signature', () => {
  const options = parseBuildArgs([]);
  assert.deepEqual(options.archs, [process.arch === 'arm64' ? 'arm64' : 'x86_64']);
  assert.equal(options.sign, '-');
  assert.equal(options.configuration, 'release');
  assert.equal(options.deploymentTarget, '14.0');
  assert.equal(options.dist, DIST_DIR);
  assert.equal(options.timestamp, 'auto');
  assert.equal(options.dryRun, false);
});

test('parseBuildArgs reads a comma separated arch list and a signing identity', () => {
  const options = parseBuildArgs([
    '--arch', 'arm64,x86_64',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '--configuration', 'release',
    '--dry-run',
  ]);
  assert.deepEqual(options.archs, ['arm64', 'x86_64']);
  assert.equal(options.sign, 'Developer ID Application: Denis Zamataev (68QJJA7HK9)');
  assert.equal(options.dryRun, true);
});

test('parseBuildArgs supports disabling timestamps for a local Developer ID build', () => {
  const options = parseBuildArgs([
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '--timestamp', 'none',
  ]);

  assert.equal(options.timestamp, 'none');
});
test('parseBuildArgs trims whitespace and rejects unknown architectures', () => {
  assert.deepEqual(parseBuildArgs(['--arch', ' arm64 , x86_64 ']).archs, ['arm64', 'x86_64']);
  assert.throws(() => parseBuildArgs(['--arch', 'ppc']), /Unsupported architecture "ppc"/);
  assert.throws(() => parseBuildArgs(['--arch', '']), /at least one architecture/);
});

test('parseBuildArgs rejects an unknown configuration', () => {
  assert.throws(() => parseBuildArgs(['--configuration', 'profile']),
    /Configuration must be "release" or "debug"/);
});

test('bundleLayout describes the app bundle', () => {
  const layout = bundleLayout('/out');
  assert.equal(layout.app, '/out/Macomprendo.app');
  assert.equal(layout.contents, '/out/Macomprendo.app/Contents');
  assert.equal(layout.macosDir, '/out/Macomprendo.app/Contents/MacOS');
  assert.equal(layout.resources, '/out/Macomprendo.app/Contents/Resources');
  assert.equal(layout.frameworks, '/out/Macomprendo.app/Contents/Frameworks');
  assert.equal(layout.executable, '/out/Macomprendo.app/Contents/MacOS/Macomprendo');
  assert.equal(layout.infoPlist, '/out/Macomprendo.app/Contents/Info.plist');
});

test('planBuild asks Xcode for the app bundle and copies that product into dist', () => {
  const steps = planFixture();
  const build = steps.find((step) => step.type === 'exec' && step.cmd === 'xcodebuild');
  assert.ok(build, 'expected an xcodebuild step');
  assert.ok(build.args.includes('-project'));
  assert.ok(build.args.includes(path.join(ROOT, 'macos/Macomprendo.xcodeproj')));
  assert.ok(build.args.includes('ARCHS=arm64 x86_64'));
  assert.ok(build.args.includes('CODE_SIGNING_ALLOWED=NO'));
  assert.ok(build.args.includes('ENABLE_CODE_COVERAGE=NO'));
  assert.ok(build.args.includes('CLANG_ENABLE_CODE_COVERAGE=NO'));
  assert.ok(build.args.includes('CLANG_COVERAGE_MAPPING=NO'));
  assert.ok(build.args.includes('CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO'));

  assert.ok(steps.some((step) => step.type === 'copy'
    && step.from === '/out/.derived-data/Build/Products/Release/Macomprendo.app'
    && step.to === '/out/Macomprendo.app'));
  assert.equal(
    steps.some((step) => step.type === 'copy' && step.to.endsWith('.app/Macomprendo_Macomprendo.bundle')),
    false,
  );
});

test('planBuild signs Xcode embedded frameworks before signing the app', () => {
  const signs = planFixture().filter((step) => step.type === 'exec' && step.cmd === 'codesign');
  assert.deepEqual(signs.slice(0, 3).map((step) => step.args.at(-1)), [
    '/out/Macomprendo.app/Contents/Frameworks/SherpaOnnxC.framework',
    '/out/Macomprendo.app/Contents/Frameworks/whisper.framework',
    '/out/Macomprendo.app',
  ]);
});

function planFixture(overrides = {}) {
  const options = parseBuildArgs(['--arch', 'arm64,x86_64', '--dist', '/out', ...(overrides.argv ?? [])]);
  return planBuild(options, {
    version: '1.2.3',
    buildNumber: '1.2.3',
    ...(overrides.context ?? {}),
  });
}

test('planBuild asks Xcode for one architecture when requested', () => {
  const steps = planBuild(parseBuildArgs(['--arch', 'arm64', '--dist', '/out']), {
    version: '1.2.3', buildNumber: '1.2.3',
  });
  const build = steps.find((step) => step.type === 'exec' && step.cmd === 'xcodebuild');
  assert.ok(build.args.includes('ARCHS=arm64'));
  assert.ok(build.args.includes('ONLY_ACTIVE_ARCH=YES'));
});

test('planBuild wipes stale DerivedData and the previous app before building', () => {
  const steps = planFixture();
  assert.deepEqual(steps[0], { type: 'rm', path: '/out/.derived-data' });
  assert.deepEqual(steps[1], { type: 'rm', path: '/out/Macomprendo.app' });
});

test('planBuild stamps the version, build number and bundle identifier with PlistBuddy', () => {
  const plist = planFixture()
    .filter((s) => s.type === 'exec' && s.cmd === '/usr/libexec/PlistBuddy')
    .map((s) => s.args[1]);
  assert.deepEqual(plist, [
    'Set :CFBundleShortVersionString 1.2.3',
    'Set :CFBundleVersion 1.2.3',
    `Set :CFBundleIdentifier ${BUNDLE_ID}`,
  ]);
});

test('planBuild ad-hoc signs both frameworks before the app', () => {
  const signs = planFixture().filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs.slice(0, 3).map((step) => step.args.at(-1)), [
    '/out/Macomprendo.app/Contents/Frameworks/SherpaOnnxC.framework',
    '/out/Macomprendo.app/Contents/Frameworks/whisper.framework',
    '/out/Macomprendo.app',
  ]);
  assert.deepEqual(signs.at(-1).args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 4);
});

test('planBuild signs nested frameworks then the app with hardened runtime for a real identity', () => {
  const steps = planFixture({
    argv: ['--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)'],
  });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app/Contents/Frameworks/SherpaOnnxC.framework',
  ]);
  assert.deepEqual(signs[1].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app/Contents/Frameworks/whisper.framework',
  ]);
  assert.deepEqual(signs[2].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--entitlements', path.join(ROOT, 'macos/AppBundle/Macomprendo.entitlements'),
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app',
  ]);
  assert.deepEqual(signs[3].args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 4);
});

test('planBuild explicitly disables timestamping for a local Developer ID build', () => {
  const steps = planFixture({
    argv: [
      '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
      '--timestamp', 'none',
    ],
  });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  const actualSigns = signs.filter((step) => step.args.includes('--sign'));

  assert.equal(actualSigns.every((step) => step.args.includes('--timestamp=none')), true);
  assert.equal(signs.some((step) => step.args.includes('--timestamp')), false);
  assert.ok(signs[0].args.includes('--options'));
  assert.ok(signs[2].args.includes('--entitlements'));
});
test('planBuild ends by reporting the architectures actually produced', () => {
  const last = planFixture().at(-1);
  assert.deepEqual(last, {
    type: 'exec', cmd: 'lipo',
    args: ['-archs', '/out/Macomprendo.app/Contents/MacOS/Macomprendo'],
    capture: true,
  });
});

test('validateArchitectures requires the exact requested architecture set', () => {
  assert.doesNotThrow(() => validateArchitectures(['arm64', 'x86_64'], 'x86_64 arm64'));
  assert.throws(
    () => validateArchitectures(['arm64', 'x86_64'], 'arm64'),
    /requested arm64, x86_64; built arm64/,
  );
  assert.throws(
    () => validateArchitectures(['arm64'], 'arm64 x86_64'),
    /requested arm64; built arm64, x86_64/,
  );
});

test('describeStep renders every step type as one readable line', () => {
  assert.equal(describeStep({ type: 'exec', cmd: 'lipo', args: ['-archs', '/a b'] }), 'lipo -archs "/a b"');
  assert.equal(describeStep({ type: 'rm', path: '/a' }), 'rm -rf /a');
  assert.equal(describeStep({ type: 'mkdir', path: '/a' }), 'mkdir -p /a');
  assert.equal(describeStep({ type: 'copy', from: '/a', to: '/b' }), 'cp -R /a /b');
  assert.equal(describeStep({ type: 'chmod', path: '/a' }), 'chmod 755 /a');
});

const PROJECT_YML_TEXT = `name: Macomprendo
targets:
  Macomprendo:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        PRODUCT_BUNDLE_IDENTIFIER: com.dzamataev.macomprendo
`;

test('executePlan performs each step through the injected boundaries', async () => {
  const run = makeFakeRun([{}, { stdout: 'x86_64 arm64' }]);
  const fsOps = makeFakeFsOps();
  const result = await executePlan([
    { type: 'rm', path: '/out/app' },
    { type: 'mkdir', path: '/out/app/Contents' },
    { type: 'copy', from: '/a', to: '/b' },
    { type: 'chmod', path: '/b' },
    { type: 'exec', cmd: 'codesign', args: ['--force', '/out/app'] },
    { type: 'exec', cmd: 'lipo', args: ['-archs', '/b'], capture: true },
  ], { run, fsOps, log: makeFakeLog(), dryRun: false });

  assert.deepEqual(fsOps.events, [
    ['rmrf', '/out/app'],
    ['mkdirp', '/out/app/Contents'],
    ['copyPath', '/a', '/b'],
    ['chmodExec', '/b'],
  ]);
  assert.deepEqual(run.lines(), ['codesign --force /out/app', 'lipo -archs /b']);
  assert.deepEqual(result.outputs, ['x86_64 arm64']);
});

test('executePlan in dry-run mode touches nothing and logs every step', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  const log = makeFakeLog();
  await executePlan([
    { type: 'rm', path: '/out/app' },
    { type: 'exec', cmd: 'codesign', args: ['--force', '/out/app'] },
  ], { run, fsOps, log, dryRun: true });

  assert.deepEqual(fsOps.events, []);
  assert.deepEqual(run.calls, []);
  assert.deepEqual(log.lines, ['info: rm -rf /out/app', 'info: codesign --force /out/app']);
});

test('resolveContext reads version metadata without starting a build', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64,x86_64']);

  const context = await resolveContext(options, { run, fsOps, io });

  assert.deepEqual(context, { version: '1.2.3', buildNumber: '1.2.3' });
  assert.deepEqual(run.calls, []);
  assert.deepEqual(fsOps.events, []);
});

test('resolveContext honours explicit --version and --build-number', async () => {
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const context = await resolveContext(
    parseBuildArgs(['--arch', 'arm64', '--dry-run', '--version', '9.9.9', '--build-number', '42']),
    { run: makeFakeRun(), fsOps: makeFakeFsOps(), io },
  );
  assert.equal(context.version, '9.9.9');
  assert.equal(context.buildNumber, '42');
});

test('main --dry-run prints the plan and exits zero without running anything', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  const log = makeFakeLog();
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });

  const code = await main(['--arch', 'arm64,x86_64', '--dry-run'], { run, fsOps, log, io });

  assert.equal(code, 0);
  assert.deepEqual(run.calls, []);
  assert.deepEqual(fsOps.events, []);
  assert.ok(log.lines.some((line) => line.includes('xcodebuild')));
  assert.ok(log.lines.some((line) => line.includes('ARCHS=arm64 x86_64')));
  assert.ok(log.lines.some((line) => line.includes('lipo -archs')));
});

test('main fails when Xcode omits a requested architecture', async () => {
  const run = makeFakeRun([
    {}, {}, {}, {}, {}, {}, {}, {}, { stdout: 'arm64' },
  ]);
  const log = makeFakeLog();
  const code = await main(['--arch', 'arm64,x86_64'], {
    run,
    fsOps: makeFakeFsOps(),
    log,
    io: makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT }),
  });

  assert.equal(code, 1);
  assert.ok(log.lines.includes(
    'error: Architecture mismatch: requested arm64, x86_64; built arm64.',
  ));
});

test('main reports a bad argument as exit code 2 without spawning anything', async () => {
  const run = makeFakeRun();
  const log = makeFakeLog();
  const code = await main(['--arch', 'ppc'], {
    run, fsOps: makeFakeFsOps(), log, io: makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT }),
  });
  assert.equal(code, 2);
  assert.deepEqual(run.calls, []);
  assert.ok(log.lines.some((l) => l.startsWith('error: Unsupported architecture "ppc"')));
});
