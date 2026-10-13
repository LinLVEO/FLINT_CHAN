// studio-tabs-probe.js — 右栏「机器码 / 反汇编 / 编译信息」三个页签的 UI 回归（CDP 驱动无头 Edge）
// 用法：node test\studio-tabs-probe.js   （默认打 127.0.0.1:8900；STUDIO_URL 可换）
// 背景（2026-09-12 用户反馈）：
//   「机械码太挤了」——实测 16 字节/行的 hex 串在 196px 的格子里被折成 2 行（行高 41px = 2×19.2）
//   「反汇编显示不完整」——服务端没截断（1393 行全给了），但右栏只有 365px 宽 / 429px 高：一次只见 23 行 + 要横滚
//   本探针钉住修复后的形态：8 字节/行不折行、不横滚、可折叠库速查、⤢ 放大、产物大小算式可见
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8900/";
const ORIGIN = STUDIO.replace(/[?#].*$/, "").replace(/\/$/, "");
const PORT = Number(process.env.CDP_PORT || 9338);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}  ${detail === undefined ? "" : JSON.stringify(detail)}`); }
};

const SRC = `include "num_lib.fl"
int main() {
  int i = 0;
  int s = 0;
  while (i < 10) {
    s = s + i * i;
    i = i + 1;
  }
  print(["s = ", s, "\\n"]);
  return s;
}
`;

let idSeq = 0;
function makeClient(ws) {
  const pending = new Map();
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
    }
  });
  return (method, params) => new Promise((resolve, reject) => {
    const id = ++idSeq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });
}

(async () => {
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "tabsprobe-"));
  const child = spawn(EDGE, ["--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${udd}`,
    "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--window-size=1440,900",
    // ⚠️ 临时 profile 会冒出 edge://sync-confirmation-dialog/ 等"另一个 page 目标"抢走调试会话，
    //    必须按 URL 认目标 + 关掉首次运行/同步/扩展，探针才确定。
    "--disable-sync", "--disable-extensions", "--disable-features=msEdgeSyncPromo", "--no-service-autorun",
    STUDIO], { stdio: "ignore" });
  let page = null;
  for (let i = 0; i < 60; i++) {
    await sleep(300);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      // ⚠️ 必须按 URL 认目标：/json/list 第一条不一定是 Studio（实测见过别的 page 目标）
      page = list.find((t) => t.type === "page" && t.webSocketDebuggerUrl
        && (t.url || "").startsWith(ORIGIN));
      if (page) break;
    } catch { /* 等 */ }
  }
  if (!page) { console.log("❌ 连不上 Edge CDP"); child.kill(); process.exit(1); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.addEventListener("open", res); ws.addEventListener("error", rej); });
  const send = makeClient(ws);
  await send("Runtime.enable");
  const ev = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("JS 异常: " + JSON.stringify(r.exceptionDetails.exception));
    return r.result.value;
  };
  const key = async (k, code, vk) => {
    const b = { key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk };
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyDown" }, b));
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyUp" }, b));
    await sleep(150);
  };
  const compile = async (src) => {
    await ev(`(() => { const c = document.querySelector("#code"); c.value = ${JSON.stringify(src)};
      c.dispatchEvent(new Event("input")); return 1; })()`);
    await ev(`document.querySelector("#compileBtn").click()`);
    for (let i = 0; i < 80; i++) {
      if (await ev(`document.querySelectorAll("#tabHex tr").length > 0`)) break;
      await sleep(250);
    }
    await sleep(400);
  };

  console.log("=== 右栏页签探针（机器码 / 反汇编 / 编译信息）===");
  for (let i = 0; i < 50; i++) {
    if (await ev(`document.readyState === "complete" && !!document.querySelector("#compileBtn")`)) break;
    await sleep(200);
  }
  await compile(SRC);

  // ---------- ① 机器码：8 字节/行、不折行、不横滚 ----------
  await ev(`document.querySelector('.tab[data-tab="hex"]').click()`);
  await sleep(250);
  const hex = await ev(`(() => {
    const cell = document.querySelector("table.hex .hx");
    const row = document.querySelector("table.hex tr");
    const body = document.querySelector("#tabHex");
    return { bytes: cell.textContent.trim().split(/\\s+/).length,
             单元格高: cell.clientHeight, lineHeight: parseFloat(getComputedStyle(cell).lineHeight),
             行高: row.offsetHeight, ws: getComputedStyle(cell).whiteSpace,
             内容宽: body.scrollWidth, 容器宽: body.clientWidth,
             行数: document.querySelectorAll("table.hex tr").length,
             有提示: !!document.querySelector("#tabHex .tab-note") };
  })()`);
  check("每行 8 字节", hex.bytes === 8, hex.bytes);
  check("单元格是一行（不再折成两行）", hex.单元格高 <= hex.lineHeight * 1.6, hex);
  check("white-space: nowrap", hex.ws === "nowrap", hex.ws);
  check("窄栏里不用横向滚", hex.内容宽 <= hex.容器宽 + 2, hex);
  check("机器码有顶部交代（共几行）", hex.有提示 === true);
  check("有机器码行", hex.行数 > 10, hex.行数);

  // ---------- ② 反汇编：内容完整、无横向滚、可折叠腾地方 ----------
  await ev(`document.querySelector('.tab[data-tab="dis"]').click()`);
  await sleep(250);
  const dis = await ev(`(() => {
    const body = document.querySelector("#tabDis"), pre = document.querySelector("pre.dis");
    const lines = pre.textContent.split("\\n");
    return { 总行: lines.length, 首行: lines[0], 末行: lines[lines.length - 1].slice(0, 20),
             有提示: !!document.querySelector("#tabDis .tab-note"),
             提示文字: document.querySelector("#tabDis .tab-note").textContent,
             可见行: Math.floor(body.clientHeight / parseFloat(getComputedStyle(pre).lineHeight)) };
  })()`);
  check("反汇编内容完整（上百行，不是被截断）", dis.总行 > 100, dis.总行);
  check("反汇编首行是 objdump 头", /file format/.test(dis.首行), dis.首行);
  check("反汇编有顶部交代（含放大提示）", dis.有提示 && /放大/.test(dis.提示文字), dis.提示文字);

  const wasCollapsed = await ev(`document.querySelector(".libs").classList.contains("collapsed")`);
  if (wasCollapsed) { await ev(`document.querySelector("#libsHead").click()`); await sleep(200); }  // 先展开（localStorage 可能记着）
  const vis1 = await ev(`(() => { const b = document.querySelector("#tabDis"), p = document.querySelector("pre.dis");
    return Math.floor(b.clientHeight / parseFloat(getComputedStyle(p).lineHeight)); })()`);
  await ev(`document.querySelector("#libsHead").click()`);
  await sleep(250);
  const vis2 = await ev(`(() => { const b = document.querySelector("#tabDis"), p = document.querySelector("pre.dis");
    return { collapsed: document.querySelector(".libs").classList.contains("collapsed"),
             可见行: Math.floor(b.clientHeight / parseFloat(getComputedStyle(p).lineHeight)) }; })()`);
  check("库速查能折叠", vis2.collapsed === true);
  check("折叠后反汇编一次能看更多行", vis2.可见行 > vis1, { 折叠前: vis1, 折叠后: vis2.可见行 });

  // ---------- ③ ⤢ 放大 ----------
  await ev(`document.querySelector("#zoomBtn").click()`);
  await sleep(300);
  const zoom = await ev(`(() => {
    const ov = document.querySelector("#zoomOverlay"), body = document.querySelector("#zoomBody");
    const pre = body.querySelector("pre.dis");
    return { 打开: !ov.classList.contains("hidden"), 标题: document.querySelector("#zoomTitle").textContent,
             可见行: Math.floor(body.clientHeight / parseFloat(getComputedStyle(pre).lineHeight)),
             需要横滚: pre.scrollWidth > body.clientWidth, 行数: pre.textContent.split("\\n").length };
  })()`);
  check("点 ⤢ 打开放大层", zoom.打开 === true && /放大/.test(zoom.标题), zoom.标题);
  check("放大后内容与右栏一致（行数相同）", zoom.行数 === dis.总行, { 放大: zoom.行数, 右栏: dis.总行 });
  check("放大后一次能看更多行（>30）", zoom.可见行 > 30, zoom.可见行);
  check("放大后不需要横向滚", zoom.需要横滚 === false, zoom);
  await key("Escape", "Escape", 27);
  check("Esc 关闭放大层", (await ev(`document.querySelector("#zoomOverlay").classList.contains("hidden")`)) === true);

  // ---------- ④ 编译信息：产物大小算式（回答"咋都是 1024 字节"）----------
  await compile(`int main() { return 42; }\n`);
  await ev(`document.querySelector('.tab[data-tab="log"]').click()`);
  await sleep(250);
  const logTxt = await ev(`document.querySelector("#tabLog").textContent`);
  check("编译信息给出产物大小算式", /产物\s*1024\s*字节\s*=\s*头\s*0x200\(512\)\s*\+\s*\.text\s*对齐后\s*512/.test(logTxt), logTxt.slice(0, 200));
  check("并解释「不是程序都一样大」", /不是"程序都一样大"|不是程序都一样大/.test(logTxt), logTxt.slice(0, 300));

  console.log("----");
  console.log(`通过 ${pass} / 失败 ${fail}`);
  try { ws.close(); } catch {}
  child.kill();
  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => { console.log("探针异常: " + e.message); process.exit(1); });
