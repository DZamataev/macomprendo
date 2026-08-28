// Repo-anchored paths and release identity constants shared by every tool in scripts/.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url)); // <root>/scripts/lib

export const ROOT = path.resolve(here, '..', '..');
export const MACOS_DIR = path.join(ROOT, 'macos');
export const PROJECT_YML = path.join(MACOS_DIR, 'project.yml');
export const XCODEPROJ = path.join(MACOS_DIR, 'Macomprendo.xcodeproj');
export const PBXPROJ = path.join(XCODEPROJ, 'project.pbxproj');
export const CHANGELOG_PATH = path.join(ROOT, 'CHANGELOG.md');
export const LICENSE_PATH = path.join(ROOT, 'LICENSE');
export const APP_BUNDLE_DIR = path.join(MACOS_DIR, 'AppBundle');
export const INFO_PLIST_SRC = path.join(APP_BUNDLE_DIR, 'Info.plist');
export const ICON_SRC = path.join(APP_BUNDLE_DIR, 'AppIcon.icns');
export const ENTITLEMENTS_SRC = path.join(APP_BUNDLE_DIR, 'Macomprendo.entitlements');
export const DIST_DIR = path.join(ROOT, 'dist');

export const APP_NAME = 'Macomprendo.app';
export const EXECUTABLE_NAME = 'Macomprendo';
export const BUNDLE_ID = 'com.dzamataev.macomprendo';
export const TEAM_ID = '68QJJA7HK9';
export const NOTARY_PROFILE = 'macomprendo-notary';
export const DEPLOYMENT_TARGET = '14.0';
export const SCHEME = 'Macomprendo';

export function appPath(distDir = DIST_DIR) {
  return path.join(distDir, APP_NAME);
}
