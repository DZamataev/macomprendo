import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveIconFiles, WEIGHTS } from "../sync-icons.mjs";

test("regular icons are unsuffixed, other weights repeat the weight", () => {
  const resolved = resolveIconFiles(
    [{ name: "gear", weight: "regular" }, { name: "microphone", weight: "fill" }],
    "/assets"
  );
  assert.deepEqual(resolved, [
    { name: "gear", weight: "regular", fileName: "gear.svg", source: "/assets/regular/gear.svg" },
    { name: "microphone", weight: "fill", fileName: "microphone-fill.svg", source: "/assets/fill/microphone-fill.svg" },
  ]);
});

test("the result is sorted by file name so the folder listing is stable", () => {
  const resolved = resolveIconFiles(
    [{ name: "waveform", weight: "regular" }, { name: "cloud", weight: "regular" }],
    "/assets"
  );
  assert.deepEqual(resolved.map((i) => i.fileName), ["cloud.svg", "waveform.svg"]);
});

test("an unknown weight is rejected with the allowed list", () => {
  assert.throws(
    () => resolveIconFiles([{ name: "gear", weight: "chunky" }], "/assets"),
    /weight must be one of thin, light, regular, bold, fill, duotone, got "chunky"/
  );
});

test("a missing name is rejected with its index", () => {
  assert.throws(() => resolveIconFiles([{ weight: "regular" }], "/assets"), /icons\.json\[0\]: missing "name"/);
});

test("duplicates are rejected", () => {
  assert.throws(
    () => resolveIconFiles([{ name: "gear", weight: "regular" }, { name: "gear", weight: "regular" }], "/assets"),
    /lists gear\.svg twice/
  );
});

test("a non-array payload is rejected", () => {
  assert.throws(() => resolveIconFiles({ name: "gear" }, "/assets"), /must contain an array/);
});

test("every documented weight resolves", () => {
  const resolved = resolveIconFiles(WEIGHTS.map((weight) => ({ name: "gear", weight })), "/assets");
  assert.equal(resolved.length, WEIGHTS.length);
  assert.ok(resolved.some((i) => i.fileName === "gear.svg"));
  assert.ok(resolved.some((i) => i.fileName === "gear-duotone.svg"));
});
