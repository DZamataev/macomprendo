import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import path from 'node:path';

import {
  ROOT, MACOS_DIR, PROJECT_YML, PBXPROJ, DIST_DIR,
  APP_NAME, EXECUTABLE_NAME, BUNDLE_ID, TEAM_ID,
  NOTARY_PROFILE, DEPLOYMENT_TARGET, SCHEME, appPath,
} from '../lib/paths.mjs';

test('ROOT points at the repository checkout', () => {
  assert.equal(path.basename(PROJECT_YML), 'project.yml');
  assert.equal(MACOS_DIR, path.join(ROOT, 'macos'));
  assert.ok(existsSync(path.join(ROOT, 'package.json')));
});

test('identity constants match the spec', () => {
  assert.equal(APP_NAME, 'Macomprendo.app');
  assert.equal(EXECUTABLE_NAME, 'Macomprendo');
  assert.equal(BUNDLE_ID, 'com.dzamataev.macomprendo');
  assert.equal(TEAM_ID, '68QJJA7HK9');
  assert.equal(NOTARY_PROFILE, 'macomprendo-notary');
  assert.equal(DEPLOYMENT_TARGET, '14.0');
  assert.equal(SCHEME, 'Macomprendo');
});

test('pbxproj path targets the committed Xcode project', () => {
  assert.equal(PBXPROJ, path.join(ROOT, 'macos/Macomprendo.xcodeproj/project.pbxproj'));
});

test('appPath joins a dist directory with the bundle name', () => {
  assert.equal(appPath('/tmp/out'), '/tmp/out/Macomprendo.app');
  assert.equal(appPath(), path.join(DIST_DIR, 'Macomprendo.app'));
});
