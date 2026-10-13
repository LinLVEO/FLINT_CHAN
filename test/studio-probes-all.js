// studio-probes-all.js — 一次跑完 Studio 六套探针（并行，各自独立 CDP 端口）
// 用法：node test\studio-probes-all.js
// 前提：Studio 服务在跑（默认 http://127.0.0.1:8900 ；用 STUDIO_URL 换）
// 规矩：所有探针都指 8900（别误测用户自己的 8899 实例），每套都有硬超时，绝不空等。
"use strict";
const { spawn } = require("child_process");
const path = require("path");

const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8900/";
const TIMEOUT_MS = Number(process.env.PROBE_TIMEOUT_MS || 180000);
const PROBES = [
  "test/studio-layout-probe.js",
  "test/studio-tabs-probe.js",
  "test/studio-ui-probe.js",
  "test/studio-wheel-probe.js",
  "test/studio-workspace-ui-probe.js",
  "test/studio-workspace-probe.js",     // HTTP 层
  "editor/tmp/api-test.js",             // HTTP 层
  "editor/tmp/samples-test-local.js",   // 内置示例逐个编译（示例错了等于教错）
];

const runOne = (rel) => new Promise((resolve) => {
  const started = Date.now();
  const file = path.basename(rel);
  const child = spawn(process.execPath, [path.join(__dirname, "..", rel)], {
    cwd: path.join(__dirname, ".."),
    env: Object.assign({}, process.env, { STUDIO_URL: STUDIO, STUDIO_BASE: STUDIO.replace(/\/$/, "") }),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "", err = "";
  let killed = false;
  const timer = setTimeout(() => { killed = true; child.kill(); }, TIMEOUT_MS);
  child.stdout.on("data", (d) => { out += d.toString("utf8"); });
  child.stderr.on("data", (d) => { err += d.toString("utf8"); });
  child.on("exit", (code) => {
    clearTimeout(timer);
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    // 判成败只认输出里的成绩行；三种口径都收：
    //   「通过 N / 失败 M」（多数探针）、「N 通过 / M 失败」（wheel 探针）、「失败 M / 总数」（示例体检）
    let m = out.match(/通过\s+(\d+)\s*\/\s*失败\s+(\d+)/) || out.match(/(\d+)\s*通过\s*\/\s*(\d+)\s*失败/);
    if (!m) {
      const f = out.match(/失败\s+(\d+)\s*\/\s*(\d+)/);      // 只有"失败数/总数"
      if (f) m = [null, String(Number(f[2]) - Number(f[1])), f[1]];
    }
    resolve({
      file, code: killed ? "超时被杀" : code, secs,
      pass: m ? Number(m[1]) : null, fail: m ? Number(m[2]) : null,
      tail: out.split("\n").filter((l) => l.trim()).slice(-6).join("\n"),
      err: err.trim().slice(0, 400),
    });
  });
});

(async () => {
  console.log("=== Studio 探针总跑（默认串行：各套都要开自己的无头 Edge + 独占 Studio 的 tmp，并行会互相干扰）===");
  console.log("目标: " + STUDIO + "　文件数: " + PROBES.length);
  const results = [];
  for (const f of PROBES) results.push(await runOne(f));
  let totalPass = 0, totalFail = 0, bad = 0;
  console.log("");
  for (const r of results) {
    const ok = r.fail === 0 && r.pass !== null;
    if (ok) { totalPass += r.pass; totalFail += r.fail; }
    else { bad++; if (r.pass !== null) { totalPass += r.pass; totalFail += r.fail; } }
    console.log(`${ok ? "✅" : "❌"} ${r.file.padEnd(32)} 通过 ${r.pass} / 失败 ${r.fail}　(${r.secs}s, 退出码 ${r.code})`);
    if (!ok) {
      console.log("   ---- 尾部输出 ----");
      console.log("   " + r.tail.split("\n").join("\n   "));
      if (r.err) console.log("   ---- stderr ----\n   " + r.err.split("\n").join("\n   "));
    }
  }
  console.log("");
  console.log(`合计：通过 ${totalPass} / 失败 ${totalFail}　异常套数 ${bad}/${PROBES.length}`);
  process.exit(totalFail > 0 || bad > 0 ? 1 : 0);
})();
