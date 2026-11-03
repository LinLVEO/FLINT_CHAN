// tools/make_bgm.mjs -- 合成《灰夜》的可循环 8-bit 战斗 BGM
//
// 输出: games/huiye/bgm.wav
//   A 小调 / 120 BPM / 6 小节 = 12.000 秒 / 22050 Hz / 16-bit PCM / 单声道
//   音轨: 主旋律(25% 方波) + 低音(50% 方波) + 琶音(12.5% 方波) + 底鼓(方波扫频)
//   所有音符都从 0 相位起、包络在音符尾部归零，最后一拍在循环点前收干净 -> 可无缝循环。
//
// 用法: node tools/make_bgm.mjs
// 只依赖 Node 内置模块，无第三方包。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(HERE, "..", "games", "huiye", "bgm.wav");

const SR = 22050;
const BPM = 120;
const BEATS_PER_BAR = 4;
const BARS = 6;
const BEAT = 60 / BPM;             // 0.5 s
const BAR = BEAT * BEATS_PER_BAR;  // 2.0 s
const STEP = BAR / 16;             // 16 分音符 = 0.125 s
const DUR = BAR * BARS;            // 12.0 s
const N = Math.round(SR * DUR);    // 264600 个采样

const midiHz = (m) => 440 * Math.pow(2, (m - 69) / 12);

// ---- 曲式 ----
// 和弦: Am | F | G | E | Am | E   （i - VI - VII - V - i - V，结尾属和弦回主和弦）
// 每个 lead 事件 = [16 分音符格, 长度(格), MIDI 音高]
const bars = [
  {
    name: "Am", root: 45, high: 57,
    arp: [57, 60, 64, 69, 72, 69, 64, 60],
    lead: [[0, 2, 69], [2, 2, 69], [4, 1, 72], [5, 1, 76], [6, 2, 81],
           [8, 2, 79], [10, 1, 76], [11, 1, 72], [12, 2, 76], [14, 2, 72]],
  },
  {
    name: "F", root: 41, high: 53,
    arp: [53, 57, 60, 65, 69, 65, 60, 57],
    lead: [[0, 2, 65], [2, 2, 69], [4, 1, 72], [5, 1, 77], [6, 2, 76],
           [8, 2, 72], [10, 1, 69], [11, 1, 72], [12, 2, 77], [14, 2, 76]],
  },
  {
    name: "G", root: 43, high: 55,
    arp: [55, 59, 62, 67, 71, 67, 62, 59],
    lead: [[0, 2, 67], [2, 2, 71], [4, 1, 74], [5, 1, 79], [6, 2, 77],
           [8, 2, 74], [10, 1, 71], [11, 1, 74], [12, 2, 79], [14, 2, 77]],
  },
  {
    name: "E", root: 40, high: 52,
    arp: [52, 56, 59, 64, 68, 64, 59, 56],
    lead: [[0, 2, 64], [2, 2, 68], [4, 1, 71], [5, 1, 76], [6, 2, 74],
           [8, 2, 71], [10, 1, 68], [11, 1, 71], [12, 2, 76], [14, 2, 74]],
  },
  {
    name: "Am", root: 45, high: 57,
    arp: [57, 60, 64, 69, 72, 69, 64, 60],
    lead: [[0, 2, 69], [2, 1, 72], [3, 1, 76], [4, 2, 81], [6, 1, 84],
           [7, 1, 83], [8, 2, 81], [10, 1, 79], [11, 1, 76],
           [12, 2, 81], [14, 2, 79]],
  },
  {
    name: "E", root: 40, high: 52,
    arp: [52, 56, 59, 64, 68, 64, 59, 56],
    lead: [[0, 2, 76], [2, 1, 74], [3, 1, 71], [4, 2, 68], [6, 1, 71],
           [7, 1, 74], [8, 2, 76], [10, 1, 79], [11, 1, 76],
           [12, 2, 74], [14, 2, 71]],
  },
];

// 事件: { t0, dur, midi/freq, gain, duty, env, sweep? }
const events = [];

function note(t0, dur, midi, gain, duty, env) {
  events.push({ t0, dur, freq: midiHz(midi), gain, duty, env });
}

for (let b = 0; b < BARS; b++) {
  const bar = bars[b];
  const base = b * BAR;

  // 主旋律: 25% 方波，8/16 分音符混合
  for (const [s, len, m] of bar.lead) {
    note(base + s * STEP, len * STEP * 0.94, m, 0.32, 0.25, "lead");
  }

  // 低音: 每 8 分音符一下，根音与高八度交替（战斗推进感）
  const bassPat = [0, 0, 1, 0, 0, 1, 0, 1];
  for (let i = 0; i < 8; i++) {
    const m = bassPat[i] ? bar.high : bar.root;
    note(base + i * 2 * STEP, 2 * STEP * 0.88, m, 0.20, 0.5, "bass");
  }

  // 琶音: 16 分音符和弦分解，低音量铺底
  for (let i = 0; i < 16; i++) {
    const m = bar.arp[i % 8];
    const g = i % 4 === 0 ? 0.060 : 0.045;
    note(base + i * STEP, STEP * 0.78, m, g, 0.125, "arp");
  }

  // 底鼓: 每拍一下，方波从 150Hz 扫到 50Hz
  for (let beat = 0; beat < 4; beat++) {
    const t = base + beat * BEAT;
    events.push({
      t0: t, dur: 0.085, freq: 150, endFreq: 50,
      gain: 0.16, duty: 0.5, env: "kick", sweep: true,
    });
  }
}

// ---- 包络 ----
function envelope(t, dur, kind) {
  if (t < 0 || t >= dur) return 0;
  const attack = kind === "kick" ? 0.001 : 0.004;
  const release = Math.min(0.025, dur * 0.25);
  let v = 1;

  if (t < attack) {
    v = t / attack;
  } else if (kind === "lead") {
    v = 0.62 + 0.38 * Math.exp(-(t - attack) * 12);
  } else if (kind === "bass") {
    v = 0.72 + 0.28 * Math.exp(-(t - attack) * 20);
  } else if (kind === "arp") {
    v = 0.35 + 0.65 * Math.exp(-(t - attack) * 40);
  } else if (kind === "kick") {
    v = Math.exp(-t * 30);
  }

  if (kind === "kick") {
    v *= Math.exp(-t * 26);
  }
  if (t > dur - release) {
    v *= (dur - t) / release;
  }
  if (v < 0) v = 0;
  return v;
}

// ---- 渲染 ----
const mix = new Float64Array(N);

for (const e of events) {
  const i0 = Math.max(0, Math.round(e.t0 * SR));
  const i1 = Math.min(N, Math.round((e.t0 + e.dur) * SR));
  let phase = 0;

  for (let i = i0; i < i1; i++) {
    const t = (i - i0) / SR;
    let f = e.freq;
    if (e.sweep) {
      const k = t / e.dur;
      f = e.freq * Math.pow(e.endFreq / e.freq, k);
    }
    phase += f / SR;
    if (phase >= 1) phase -= Math.floor(phase);
    const sq = phase < e.duty ? 1 : -1;
    mix[i] += sq * e.gain * envelope(t, e.dur, e.env);
  }
}

// ---- 归一化 + 统计 ----
let peak = 0;
let sumSq = 0;
for (let i = 0; i < N; i++) {
  const a = Math.abs(mix[i]);
  if (a > peak) peak = a;
  sumSq += mix[i] * mix[i];
}
const target = 0.89; // 约 -1 dBFS，留余量
const scale = peak > 0 ? target / peak : 1;
const rms = Math.sqrt(sumSq / N) * scale;
for (let i = 0; i < N; i++) mix[i] *= scale;

const seam = Math.max(Math.abs(mix[0]), Math.abs(mix[N - 1]));

// ---- 写 16-bit PCM 单声道 WAV ----
const dataBytes = N * 2;
const buf = Buffer.alloc(44 + dataBytes);
buf.write("RIFF", 0, "ascii");
buf.writeUInt32LE(36 + dataBytes, 4);
buf.write("WAVE", 8, "ascii");
buf.write("fmt ", 12, "ascii");
buf.writeUInt32LE(16, 16);          // fmt chunk size
buf.writeUInt16LE(1, 20);           // PCM
buf.writeUInt16LE(1, 22);           // mono
buf.writeUInt32LE(SR, 24);
buf.writeUInt32LE(SR * 2, 28);      // byte rate
buf.writeUInt16LE(2, 32);           // block align
buf.writeUInt16LE(16, 34);          // bits per sample
buf.write("data", 36, "ascii");
buf.writeUInt32LE(dataBytes, 40);

for (let i = 0; i < N; i++) {
  let s = Math.round(mix[i] * 32767);
  if (s > 32767) s = 32767;
  if (s < -32768) s = -32768;
  buf.writeInt16LE(s, 44 + i * 2);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, buf);

const db = (x) => (x > 0 ? (20 * Math.log10(x)).toFixed(2) : "-inf");
console.log(`make_bgm: ${BPM} BPM, ${BARS} bars, ${DUR.toFixed(3)} s, ${SR} Hz, mono 16-bit`);
console.log(`make_bgm: samples=${N} bytes=${buf.length} (${(buf.length / 1024).toFixed(1)} KiB)`);
console.log(`make_bgm: peak=${peak.toFixed(3)} (${db(target)} dBFS) rms=${rms.toFixed(4)} (${db(rms)} dBFS) seam=${seam.toFixed(5)}`);
console.log(`make_bgm: wrote ${OUT}`);
