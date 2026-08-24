#!/usr/bin/env node
// Generates macos/AppBundle/AppIcon.icns: a flat placeholder until real art exists.
// Pure Node — draws the bitmap, encodes PNGs with zlib, then shells out to iconutil.
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";
import { log } from "./lib/log.mjs";
import { run } from "./lib/run.mjs";

const SIZES = [16, 32, 128, 256, 512];
const BACKGROUND = [0x2f, 0x6f, 0xed, 0xff]; // Macomprendo accent blue
const FOREGROUND = [0xff, 0xff, 0xff, 0xff];

function crc32(buffer) {
  let crc = ~0;
  for (const byte of buffer) {
    crc ^= byte;
    for (let i = 0; i < 8; i += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return ~crc >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typeAndData = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typeAndData));
  return Buffer.concat([length, typeAndData, crc]);
}

/** pixels: a Buffer of size * size * 4 RGBA bytes. */
export function encodePNG(size, pixels) {
  const stride = size * 4 + 1;
  const raw = Buffer.alloc(size * stride);
  for (let y = 0; y < size; y += 1) {
    raw[y * stride] = 0; // filter type: none
    pixels.copy(raw, y * stride + 1, y * size * 4, (y + 1) * size * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/** A rounded blue square with three white waveform bars. */
export function drawIcon(size) {
  const pixels = Buffer.alloc(size * size * 4);
  const radius = size * 0.22;
  const inset = size * 0.06;
  const bars = [
    { x: 0.34, height: 0.26 },
    { x: 0.47, height: 0.44 },
    { x: 0.60, height: 0.30 },
  ];
  const barWidth = Math.max(1, Math.round(size * 0.06));

  const insideRoundedRect = (x, y) => {
    const min = inset;
    const max = size - inset;
    if (x < min || y < min || x > max || y > max) return false;
    if (x >= min + radius && x <= max - radius) return true;
    if (y >= min + radius && y <= max - radius) return true;
    const cx = Math.min(Math.max(x, min + radius), max - radius);
    const cy = Math.min(Math.max(y, min + radius), max - radius);
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2;
  };

  for (let y = 0; y < size; y += 1) {
    for (let x = 0; x < size; x += 1) {
      let colour = [0, 0, 0, 0];
      if (insideRoundedRect(x + 0.5, y + 0.5)) colour = BACKGROUND;
      for (const bar of bars) {
        const left = bar.x * size;
        const halfHeight = (bar.height * size) / 2;
        if (x >= left && x < left + barWidth && Math.abs(y + 0.5 - size / 2) <= halfHeight) {
          colour = FOREGROUND;
        }
      }
      const offset = (y * size + x) * 4;
      pixels[offset] = colour[0];
      pixels[offset + 1] = colour[1];
      pixels[offset + 2] = colour[2];
      pixels[offset + 3] = colour[3];
    }
  }
  return pixels;
}

export async function makeIcon(repoRoot) {
  const iconset = path.join(repoRoot, "macos/AppBundle/AppIcon.iconset");
  const icnsPath = path.join(repoRoot, "macos/AppBundle/AppIcon.icns");
  await fs.rm(iconset, { recursive: true, force: true });
  await fs.mkdir(iconset, { recursive: true });
  for (const size of SIZES) {
    await fs.writeFile(path.join(iconset, `icon_${size}x${size}.png`), encodePNG(size, drawIcon(size)));
    await fs.writeFile(path.join(iconset, `icon_${size}x${size}@2x.png`), encodePNG(size * 2, drawIcon(size * 2)));
  }
  await run("iconutil", ["-c", "icns", iconset, "-o", icnsPath]);
  await fs.rm(iconset, { recursive: true, force: true });
  const icns = await fs.readFile(icnsPath);
  log.info(`AppIcon.icns written (${icns.length} bytes, sha256 ${createHash("sha256").update(icns).digest("hex").slice(0, 12)}…)`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await makeIcon(path.resolve(path.dirname(fileURLToPath(import.meta.url)), ".."));
}
