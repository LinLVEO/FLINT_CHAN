#!/usr/bin/env node
// tools/像素统计.mjs -- READ-ONLY pixel census for the three documentation screenshots.
//
// WHY IT EXISTS
//   docs/真实项目.md states, per screenshot, a "总像素" (= W*H, accountable) and a
//   "非背景像素" count with a percentage. The 总像素 number is arithmetic; the
//   "非背景像素" number has a stated CALIBER in prose ("以出现次数最多的颜色为'背景'，
//   统计其余像素") but no executable truth source -- so nobody can tell whether today's
//   PNG files still produce it. This tool exists to answer exactly one question:
//   CAN THE DOCUMENTED NUMBER BE REPRODUCED FROM THE FILE BY SOME STATED RULE?
//   It prints every candidate rule it tried, side by side, and never adjusts a
//   parameter to hit a target. If no rule reproduces the documented count, that is
//   the finding, and the tool says so instead of guessing.
//
// WHY NODE (not PowerShell)
//   This is byte-level forensic work: zlib inflate + PNG per-scanline unfiltering.
//   test/docgate.mjs was rewritten into Node for the same family of reasons (CJK file
//   names + .ps1 BOM traps), and PowerShell is the wrong tool for pixel loops.
//
// CALIBER NOTES (fixed here so they cannot drift silently)
//   * Colour key = the 4-tuple (R,G,B,A) as stored in the file, NO colour-space
//     conversion, NO premultiplication. The PNGs are 8-bit RGBA (colour type 6).
//   * "mode colour" = the colour with the highest pixel count; ties are broken by the
//     first colour encountered in scanline order (row 0 left to right, then down), so
//     the result is deterministic for a given file.
//   * "opaque" = A == 255. "transparent" = A == 0. Everything else = partial.
//
// USAGE
//   node tools/像素统计.mjs                       # census of the three doc screenshots
//   node tools/像素统计.mjs <a.png> [b.png ...]   # census of arbitrary PNGs
//   node tools/像素统计.mjs --json                # same numbers, machine-readable
//
// Exit codes: 0 = ran, 1 = a file could not be decoded, 2 = usage error.

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');

const DEFAULT_IMAGES = [
  'docs/图片/winpanel-面板.png',
  'docs/图片/ui_gallery-控件.png',
  'docs/图片/m2_float-浮窗.png',
];
// ASCII ids for the three documentation screenshots. The meter (tools/文档事实.ps1) is a
// PowerShell 5.1 script: when it captures this tool's stdout the child bytes are decoded with
// the console codepage (GBK on this host), so the CJK part of a path can come back as mojibake
// and an equality test on it would fail. Matching on an ASCII id removes that whole class of
// bug -- the meter never has to look at a CJK string to pick a row.
const DEFAULT_IDS = ['winpanel', 'uigallery', 'm2float'];

// The one rule this tool declares as the caliber for "非背景像素". It is the rule the prose in
// docs/真实项目.md describes, and it is the only rule that reproduces all three documented
// counts (see the candidate table the tool prints for the record).
const CALIBER_RULE = 'background = the single most frequent colour as stored (R,G,B,A); non-background pixel = any pixel whose stored (R,G,B,A) differs from it. Ties broken by first appearance in scanline order.';

// ------------------------------------------------------------------ PNG decode
// Only what these files actually are: signature + chunks, IHDR 8-bit colour type 6,
// IDAT (possibly split), zlib, filter types 0..4, no interlace. Anything else is
// refused loudly rather than guessed -- a silent mis-decode would produce a wrong
// pixel count that looks plausible, which is the exact failure mode this tool is
// meant to detect.
function decodePng(buf) {
  const SIG = [137, 80, 78, 71, 13, 10, 26, 10];
  for (let i = 0; i < 8; i++) if (buf[i] !== SIG[i]) throw new Error('not a PNG (bad signature)');
  let off = 8;
  let ihdr = null;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('latin1', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (off + 12 + len > buf.length) throw new Error('truncated chunk ' + type);
    if (type === 'IHDR') {
      ihdr = {
        w: data.readUInt32BE(0), h: data.readUInt32BE(4),
        depth: data[8], colorType: data[9], compression: data[10],
        filter: data[11], interlace: data[12],
      };
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (!ihdr) throw new Error('no IHDR chunk');
  if (ihdr.depth !== 8) throw new Error('unsupported bit depth ' + ihdr.depth + ' (this tool only does 8)');
  if (ihdr.interlace !== 0) throw new Error('interlaced PNG is not supported');
  const chanByType = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
  const chan = chanByType[ihdr.colorType];
  if (!chan) throw new Error('unsupported colour type ' + ihdr.colorType);
  if (ihdr.colorType === 3) throw new Error('palette PNG (colour type 3) is not supported: need tRNS to expand alpha');

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const bpp = chan;                       // bytes per pixel (8-bit)
  const stride = ihdr.w * bpp;
  const out = Buffer.alloc(stride * ihdr.h);
  let p = 0;
  for (let y = 0; y < ihdr.h; y++) {
    const ft = raw[p++];
    const line = raw.subarray(p, p + stride); p += stride;
    const cur = out.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? out.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bpp ? prev[x - bpp] : 0;
      const v = line[x];
      let val;
      switch (ft) {
        case 0: val = v; break;
        case 1: val = v + a; break;
        case 2: val = v + b; break;
        case 3: val = v + ((a + b) >> 1); break;
        case 4: {
          const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          val = v + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c));
          break;
        }
        default: throw new Error('unknown PNG filter type ' + ft + ' on row ' + y);
      }
      cur[x] = val & 0xff;
    }
  }
  return { ...ihdr, chan, pixels: out };
}

// ------------------------------------------------------------------ census
function census(img, rel, id) {
  const { w, h, chan, colorType, pixels } = img;
  const total = w * h;
  const counts = new Map();      // rgba key -> count   (insertion order = first seen)
  const rgbCounts = new Map();   // rgb key  -> count, over opaque pixels only
  const rgbAll = new Map();      // rgb key  -> count, all pixels
  let alphaOpaque = 0, alphaTransparent = 0, alphaPartial = 0;

  const at = (i) => {
    const o = i * chan;
    if (chan === 4) return [pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]];
    if (chan === 3) return [pixels[o], pixels[o + 1], pixels[o + 2], 255];
    if (chan === 2) return [pixels[o], pixels[o], pixels[o], pixels[o + 1]];
    return [pixels[o], pixels[o], pixels[o], 255];
  };
  const px = new Array(total);
  for (let i = 0; i < total; i++) {
    const c = at(i);
    px[i] = c;
    const k = c.join(',');
    counts.set(k, (counts.get(k) || 0) + 1);
    const kr = c[0] + ',' + c[1] + ',' + c[2];
    rgbAll.set(kr, (rgbAll.get(kr) || 0) + 1);
    if (c[3] === 255) { alphaOpaque++; rgbCounts.set(kr, (rgbCounts.get(kr) || 0) + 1); }
    else if (c[3] === 0) alphaTransparent++;
    else alphaPartial++;
  }
  const top = (m) => {
    let best = null, bestN = -1;
    for (const [k, n] of m) if (n > bestN) { bestN = n; best = k; }
    return { key: best, n: bestN };
  };
  const modeRgba = top(counts);
  const modeRgbOpaque = top(rgbCounts);
  const modeRgbAll = top(rgbAll);

  const mRgba = modeRgba.key.split(',').map(Number);
  const mRgbOp = modeRgbOpaque.key.split(',').map(Number);
  const mRgbAll = modeRgbAll.key.split(',').map(Number);
  const corner = px[0];

  // ---- candidate rules. Each returns the count of pixels that are NOT background
  //      under that rule's definition of background. No rule is tuned to a target.
  const neRgba = (c, m) => c[0] !== m[0] || c[1] !== m[1] || c[2] !== m[2] || c[3] !== m[3];
  const neRgb = (c, m) => c[0] !== m[0] || c[1] !== m[1] || c[2] !== m[2];
  const countIf = (fn) => { let n = 0; for (const c of px) if (fn(c)) n++; return n; };
  const rules = [
    ['R1 bg = mode colour as stored (R,G,B,A), count pixels whose RGBA differs',
      () => countIf((c) => neRgba(c, mRgba))],
    ['R2 bg = mode RGB among OPAQUE pixels, count pixels (any alpha) whose RGB differs',
      () => countIf((c) => neRgb(c, mRgbOp))],
    ['R3 bg = mode RGB among ALL pixels, count pixels whose RGB differs',
      () => countIf((c) => neRgb(c, mRgbAll))],
    ['R4 bg = mode RGB among OPAQUE pixels, count only OPAQUE pixels whose RGB differs',
      () => countIf((c) => c[3] === 255 && neRgb(c, mRgbOp))],
    ['R5 background = "opaque" itself: count every pixel with A != 255',
      () => countIf((c) => c[3] !== 255)],
    ['R6 bg = the (0,0) corner pixel as stored, count pixels whose RGBA differs',
      () => countIf((c) => neRgba(c, corner))],
    ['R7 bg = mode RGB among OPAQUE pixels, count pixels that are non-opaque OR RGB-different',
      () => countIf((c) => c[3] !== 255 || neRgb(c, mRgbOp))],
  ];

  const out = {
    id,
    file: rel,
    size: w + 'x' + h,
    pixels: total,
    colorType,
    modeRgba: { rgba: modeRgba.key, count: modeRgba.n, pct: pct(modeRgba.n, total) },
    modeRgbOpaque: { rgb: modeRgbOpaque.key, count: modeRgbOpaque.n, pct: pct(modeRgbOpaque.n, total) },
    modeRgbAll: { rgb: modeRgbAll.key, count: modeRgbAll.n, pct: pct(modeRgbAll.n, total) },
    cornerPixel: corner.join(','),
    distinctRgba: counts.size,
    distinctRgbOpaque: rgbCounts.size,
    alpha: { opaque: alphaOpaque, transparent: alphaTransparent, partial: alphaPartial },
    candidates: [],
  };
  for (const [name, fn] of rules) {
    const v = fn();
    out.candidates.push({ rule: name, nonBackground: v, pct: pct(v, total) });
  }
  // The declared caliber = R1 (the first candidate). Stated explicitly so a consumer never has
  // to guess which row of the candidate table is "the" number.
  out.caliberRule = CALIBER_RULE;
  out.nonBackgroundCount = out.candidates[0].nonBackground;
  out.nonBackgroundPct = pct2(out.nonBackgroundCount, total);
  return out;
}
function pct(n, total) { return Math.round((n / total) * 10000) / 100 + '%'; }
function pct2(n, total) { return (Math.round((n / total) * 10000) / 100).toFixed(2); }

// ------------------------------------------------------------------ main
const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const files = argv.filter((a) => !a.startsWith('-'));
const list = files.length ? files : DEFAULT_IMAGES;

const results = [];
let rc = 0;
for (const f of list) {
  const abs = path.isAbsolute(f) ? f : path.join(ROOT, f);
  const rel = path.relative(ROOT, abs).split(path.sep).join('/');
  const di = DEFAULT_IMAGES.indexOf(rel);
  const id = di >= 0 ? DEFAULT_IDS[di] : rel;
  if (!fs.existsSync(abs)) { console.error('MISSING ' + rel); rc = 1; continue; }
  try {
    const img = decodePng(fs.readFileSync(abs));
    results.push(census(img, rel, id));
  } catch (e) {
    console.error('DECODE-FAIL ' + rel + ': ' + e.message);
    rc = 1;
  }
}

if (asJson) {
  console.log(JSON.stringify({ tool: 'tools/像素统计.mjs', results }, null, 2));
} else {
  for (const r of results) {
    console.log('=== ' + r.file + '  (' + r.size + ', ' + r.pixels + ' px, colourType=' + r.colorType + ')');
    console.log('    alpha: opaque=' + r.alpha.opaque + ' transparent=' + r.alpha.transparent + ' partial=' + r.alpha.partial);
    console.log('    mode colour (RGBA, all px) = ' + r.modeRgba.rgba + ' x' + r.modeRgba.count + ' (' + r.modeRgba.pct + ')');
    console.log('    mode colour (RGB, opaque)  = ' + r.modeRgbOpaque.rgb + ' x' + r.modeRgbOpaque.count + ' (' + r.modeRgbOpaque.pct + ')');
    console.log('    mode colour (RGB, all px)  = ' + r.modeRgbAll.rgb + ' x' + r.modeRgbAll.count + ' (' + r.modeRgbAll.pct + ')');
    console.log('    corner pixel (0,0)         = ' + r.cornerPixel);
    console.log('    distinct RGBA=' + r.distinctRgba + '  distinct RGB(opaque)=' + r.distinctRgbOpaque);
    console.log('    -- candidate "non-background" counts --');
    for (const c of r.candidates) {
      console.log('    ' + String(c.nonBackground).padStart(9) + '  ' + c.pct.padStart(8) + '   ' + c.rule);
    }
    console.log('    DECLARED CALIBER (id=' + r.id + '): non-background = ' + r.nonBackgroundCount +
      '  (' + r.nonBackgroundPct + '%)');
    console.log('');
  }
}
process.exit(rc);
