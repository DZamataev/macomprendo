import assert from "node:assert/strict";
import { test } from "node:test";
import { drawIcon, encodePNG } from "../make-placeholder-icon.mjs";

test("drawIcon returns RGBA bytes for the requested size", () => {
  const pixels = drawIcon(32);
  assert.equal(pixels.length, 32 * 32 * 4);
});

test("the corners are transparent and the centre is opaque", () => {
  const size = 64;
  const pixels = drawIcon(size);
  const alphaAt = (x, y) => pixels[(y * size + x) * 4 + 3];
  assert.equal(alphaAt(0, 0), 0);
  assert.equal(alphaAt(size - 1, size - 1), 0);
  assert.equal(alphaAt(size / 2, size / 2), 255);
});

test("encodePNG produces a valid PNG signature and an IEND chunk", () => {
  const png = encodePNG(16, drawIcon(16));
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal(png.subarray(png.length - 8, png.length - 4).toString("ascii"), "IEND");
  assert.equal(png.readUInt32BE(16), 16); // IHDR width
  assert.equal(png.readUInt32BE(20), 16); // IHDR height
});
