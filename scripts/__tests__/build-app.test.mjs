import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

import {
  parseBuildArgs, tripleFor, predictBinPath, bundleLayout, planBuild, describeStep,
  executePlan, resolveContext, main,
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

test('parseBuildArgs trims whitespace and rejects unknown architectures', () => {
  assert.deepEqual(parseBuildArgs(['--arch', ' arm64 , x86_64 ']).archs, ['arm64', 'x86_64']);
  assert.throws(() => parseBuildArgs(['--arch', 'ppc']), /Unsupported architecture "ppc"/);
  assert.throws(() => parseBuildArgs(['--arch', '']), /at least one architecture/);
});

test('parseBuildArgs rejects an unknown configuration', () => {
  assert.throws(() => parseBuildArgs(['--configuration', 'profile']),
    /Configuration must be "release" or "debug"/);
});

test('tripleFor builds an SPM triple', () => {
  assert.equal(tripleFor('arm64', '14.0'), 'arm64-apple-macosx14.0');
  assert.equal(tripleFor('x86_64', '14.0'), 'x86_64-apple-macosx14.0');
});

test('predictBinPath mirrors the SwiftPM build layout', () => {
  assert.equal(
    predictBinPath('/repo', 'arm64-apple-macosx14.0', 'release'),
    '/repo/macos/.build/arm64-apple-macosx/release',
  );
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

function planFixture(overrides = {}) {
  const options = parseBuildArgs(['--arch', 'arm64,x86_64', '--dist', '/out', ...(overrides.argv ?? [])]);
  return planBuild(options, {
    version: '1.2.3',
    buildNumber: '1.2.3',
    binPaths: { arm64: '/b/arm64', x86_64: '/b/x86_64' },
    resourceBundles: ['Macomprendo_Macomprendo.bundle'],
    frameworks: [],
    ...(overrides.context ?? {}),
  });
}

test('planBuild compiles every architecture before assembling', () => {
  const lines = planFixture().filter((s) => s.type === 'exec').map(describeStep);
  assert.ok(lines[0].startsWith('swift build --package-path'), lines[0]);
  assert.ok(lines[0].includes('--triple arm64-apple-macosx14.0'));
  assert.ok(lines[1].includes('--triple x86_64-apple-macosx14.0'));
  assert.ok(lines[0].includes('-c release'));
});

test('planBuild lipos two slices into one executable', () => {
  const lipo = planFixture().find((s) => s.type === 'exec' && s.cmd === 'lipo');
  assert.deepEqual(lipo.args, [
    '-create', '/b/arm64/Macomprendo', '/b/x86_64/Macomprendo',
    '-output', '/out/Macomprendo.app/Contents/MacOS/Macomprendo',
  ]);
});

test('planBuild copies a single slice instead of running lipo', () => {
  const steps = planBuild(parseBuildArgs(['--arch', 'arm64', '--dist', '/out']), {
    version: '1.2.3', buildNumber: '1.2.3',
    binPaths: { arm64: '/b/arm64' }, resourceBundles: [],
  });
  assert.equal(steps.some((s) => s.cmd === 'lipo' && s.args[0] === '-create'), false);
  assert.ok(steps.some((s) => s.type === 'copy'
    && s.from === '/b/arm64/Macomprendo'
    && s.to === '/out/Macomprendo.app/Contents/MacOS/Macomprendo'));
});

test('planBuild wipes the previous bundle and creates the skeleton', () => {
  const steps = planFixture();
  assert.deepEqual(steps[2], { type: 'rm', path: '/out/Macomprendo.app' });
  assert.deepEqual(steps[3], { type: 'mkdir', path: '/out/Macomprendo.app/Contents/MacOS' });
  assert.deepEqual(steps[4], { type: 'mkdir', path: '/out/Macomprendo.app/Contents/Resources' });
});

test('planBuild copies Info.plist, the icon, the licence and the SwiftPM resource bundle', () => {
  const copies = planFixture().filter((s) => s.type === 'copy');
  const targets = copies.map((s) => s.to);
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Info.plist'));
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Resources/AppIcon.icns'));
  assert.ok(targets.includes('/out/Macomprendo.app/Contents/Resources/LICENSE'));
  assert.ok(copies.some((s) =>
    s.from === '/b/arm64/Macomprendo_Macomprendo.bundle'
    && s.to === '/out/Macomprendo.app/Contents/Resources/Macomprendo_Macomprendo.bundle'));
});

test('planBuild embeds discovered frameworks in Contents/Frameworks', () => {
  const steps = planFixture({ context: { frameworks: ['whisper.framework'] } });
  assert.ok(steps.some((s) =>
    s.type === 'mkdir' && s.path === '/out/Macomprendo.app/Contents/Frameworks'));
  assert.ok(steps.some((s) => s.type === 'copy'
    && s.from === '/b/arm64/whisper.framework'
    && s.to === '/out/Macomprendo.app/Contents/Frameworks/whisper.framework'));
  const install = steps.find((s) => s.cmd === 'install_name_tool');
  assert.deepEqual(install.args, [
    '-add_rpath', '@executable_path/../Frameworks',
    '/out/Macomprendo.app/Contents/MacOS/Macomprendo',
  ]);
});

test('planBuild omits the Frameworks directory when nothing needs embedding', () => {
  const steps = planFixture();
  assert.equal(steps.some((s) => s.type === 'mkdir' && s.path.endsWith('/Frameworks')), false);
  assert.equal(steps.some((s) => s.cmd === 'install_name_tool'), false);
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

test('planBuild ad-hoc signs by default when there is nothing to embed', () => {
  const signs = planFixture().filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, ['--force', '--sign', '-', '/out/Macomprendo.app']);
  assert.deepEqual(signs.at(-1).args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 2);
  // No resource bundle ever gets its own signature, ad-hoc or otherwise.
  assert.equal(signs.some((s) => s.args.some((a) => a.includes('.bundle'))), false);
});

test('planBuild ad-hoc signs nested frameworks before the app', () => {
  const steps = planFixture({ context: { frameworks: ['whisper.framework'] } });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args,
    ['--force', '--sign', '-', '/out/Macomprendo.app/Contents/Frameworks/whisper.framework']);
  assert.deepEqual(signs[1].args, ['--force', '--sign', '-', '/out/Macomprendo.app']);
  assert.deepEqual(signs[2].args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 3);
});

test('planBuild signs only the app for a real identity when there is nothing to embed', () => {
  const steps = planFixture({
    argv: ['--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)'],
  });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--entitlements', path.join(ROOT, 'macos/AppBundle/Macomprendo.entitlements'),
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app',
  ]);
  assert.deepEqual(signs[1].args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 2);
  // No resource bundle ever gets its own signature, real identity or otherwise.
  assert.equal(signs.some((s) => s.args.some((a) => a.includes('.bundle'))), false);
});

test('planBuild signs nested frameworks then the app with hardened runtime for a real identity', () => {
  const steps = planFixture({
    argv: ['--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)'],
    context: { frameworks: ['whisper.framework'] },
  });
  const signs = steps.filter((s) => s.type === 'exec' && s.cmd === 'codesign');
  assert.deepEqual(signs[0].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app/Contents/Frameworks/whisper.framework',
  ]);
  assert.deepEqual(signs[1].args, [
    '--force', '--options', 'runtime', '--timestamp',
    '--entitlements', path.join(ROOT, 'macos/AppBundle/Macomprendo.entitlements'),
    '--sign', 'Developer ID Application: Denis Zamataev (68QJJA7HK9)',
    '/out/Macomprendo.app',
  ]);
  assert.deepEqual(signs[2].args,
    ['--verify', '--deep', '--strict', '--verbose=2', '/out/Macomprendo.app']);
  assert.equal(signs.length, 3);
  // The bundle SwiftPM emits for our own resources has no Info.plist and cannot be
  // signed as its own target — it must never get a codesign step of its own.
  assert.equal(signs.some((s) => s.args.some((a) => a.includes('Macomprendo_Macomprendo.bundle'))), false);
});

test('planBuild ends by reporting the architectures actually produced', () => {
  const last = planFixture().at(-1);
  assert.deepEqual(last, {
    type: 'exec', cmd: 'lipo',
    args: ['-archs', '/out/Macomprendo.app/Contents/MacOS/Macomprendo'],
    capture: true,
  });
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

test('resolveContext predicts bin paths and skips swift in dry-run mode', async () => {
  const run = makeFakeRun();
  const fsOps = makeFakeFsOps();
  fsOps.bundles = ['Macomprendo_Macomprendo.bundle'];
  fsOps.frameworks = ['whisper.framework'];
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64,x86_64', '--dry-run']);

  const context = await resolveContext(options, { run, fsOps, io });

  assert.equal(context.version, '1.2.3');
  assert.equal(context.buildNumber, '1.2.3');
  assert.deepEqual(run.calls, []);
  assert.ok(context.binPaths.arm64.endsWith('macos/.build/arm64-apple-macosx/release'));
  assert.deepEqual(context.resourceBundles, ['Macomprendo_Macomprendo.bundle']);
  assert.deepEqual(context.frameworks, ['whisper.framework']);
});

test('resolveContext builds for real before asking SwiftPM for the bin path outside dry-run mode', async () => {
  const run = makeFakeRun([{}, { stdout: '/repo/macos/.build/arm64-apple-macosx14.0/release\n' }]);
  const fsOps = makeFakeFsOps();
  fsOps.bundles = ['Macomprendo_Macomprendo.bundle'];
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64']);

  const context = await resolveContext(options, { run, fsOps, io });

  assert.equal(context.binPaths.arm64, '/repo/macos/.build/arm64-apple-macosx14.0/release');
  // --show-bin-path only prints a path, it never builds — the real build must run
  // first, or a fresh .build directory would leave listBundles/listFrameworks with
  // nothing to find.
  assert.equal(run.lines().length, 2);
  assert.ok(!run.lines()[0].includes('--show-bin-path'), run.lines()[0]);
  assert.ok(run.lines()[1].includes('--show-bin-path'), run.lines()[1]);
});

test('resolveContext fails when a real build finds no resource bundle', async () => {
  const run = makeFakeRun([{}, { stdout: '/repo/macos/.build/arm64-apple-macosx14.0/release\n' }]);
  const fsOps = makeFakeFsOps(); // fsOps.bundles stays [] — nothing found next to the executable
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const options = parseBuildArgs(['--arch', 'arm64']);

  await assert.rejects(
    () => resolveContext(options, { run, fsOps, io }),
    /Macomprendo_Macomprendo\.bundle/,
  );
});

test('resolveContext does not fail on an empty resource-bundle list in dry-run mode', async () => {
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });
  const context = await resolveContext(
    parseBuildArgs(['--arch', 'arm64', '--dry-run']),
    { run: makeFakeRun(), fsOps: makeFakeFsOps(), io },
  );
  assert.deepEqual(context.resourceBundles, []);
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
  assert.deepEqual(
    fsOps.events.filter((e) => e[0] !== 'listBundles' && e[0] !== 'listFrameworks'), []);
  assert.ok(log.lines.some((l) => l.includes('--triple arm64-apple-macosx14.0')));
  assert.ok(log.lines.some((l) => l.includes('--triple x86_64-apple-macosx14.0')));
  assert.ok(log.lines.some((l) => l.includes('lipo -create')));
});

test('main returns a non-zero exit when a real build finds no resource bundle', async () => {
  const run = makeFakeRun([{}, { stdout: '/repo/macos/.build/arm64-apple-macosx14.0/release\n' }]);
  const fsOps = makeFakeFsOps(); // bundles stays [] — a broken/empty .build directory
  const log = makeFakeLog();
  const io = makeFakeIO({ [PROJECT_YML]: PROJECT_YML_TEXT });

  const code = await main(['--arch', 'arm64'], { run, fsOps, log, io });

  assert.equal(code, 1);
  assert.ok(log.lines.some((l) => l.startsWith('error:') && l.includes('Macomprendo_Macomprendo.bundle')));
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
