import assert from "node:assert/strict";
import { test } from "node:test";
import { bumpVersion, readVersion } from "../lib/version.mjs";

test("readVersion finds MARKETING_VERSION in project.yml text", () => {
  const yml = 'settings:\n  base:\n    MARKETING_VERSION: "0.1.0"\n';
  assert.equal(readVersion(yml), "0.1.0");
});

test("readVersion throws when the key is missing", () => {
  assert.throws(() => readVersion("name: Macomprendo\n"), /MARKETING_VERSION not found/);
});

test("bumpVersion bumps each part", () => {
  assert.equal(bumpVersion("1.2.3", "patch"), "1.2.4");
  assert.equal(bumpVersion("1.2.3", "minor"), "1.3.0");
  assert.equal(bumpVersion("1.2.3", "major"), "2.0.0");
  assert.equal(bumpVersion("1.2.3", "9.9.9"), "9.9.9");
});

test("bumpVersion rejects an unknown part", () => {
  assert.throws(() => bumpVersion("1.2.3", "sideways"), /Unknown version part/);
});
