// wheel-probe.js — FLINT Studio 编辑器「滚动」回归探针（CDP 驱动 Edge 无头，零依赖）
// 用法：node wheel-probe.js   （需先启动 editor\启动FLINT Studio.bat，:8899）
// 覆盖：① 长内容时 textarea 必须溢出（曾因 flex min-height:auto 被行号栏撑高 → 永不溢出 → 滚轮失效）
//       ② 滚轮在文本区/行号栏都能滚，且高亮层 + 行号栏同步 ③ 键盘 PageDown ④ 横向滚动同步
//       ⑤ 右侧结果面板滚轮
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8899/";
const ORIGIN = STUDIO.replace(/[?#].*$/, "").replace(/\/$/, "");
const PORT = Number(process.env.CDP_PORT || 9333);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}  ${detail || ""}`); }
};

let idSeq = 0;
function makeClient(ws) {
  const pending = new Map();
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
  });
  return (method, params) => new Promise((resolve, reject) => {
    const id = ++idSeq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });
}

async function main() {
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "wheelprobe-"));
  const child = spawn(EDGE, [
    "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${udd}`,
    "--no-first-run", "--no-default-browser-check", "--disable-gpu",
    "--window-size=1280,800", STUDIO,
  ], { stdio: "ignore" });

  let page = null;
  for (let i = 0; i < 60; i++) {
    await sleep(300);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      // ⚠️ 必须按 URL 认目标：/json/list 第一条不一定是 Studio（实测见过别的 page 目标）
      page = list.find((t) => t.type === "page" && t.webSocketDebuggerUrl
        && (t.url || "").startsWith(ORIGIN));
      if (page) break;
    } catch { /* 还没起来 */ }
  }
  if (!page) { console.log("❌ 连不上 Edge CDP"); child.kill(); process.exit(1); }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.addEventListener("open", res); ws.addEventListener("error", rej); });
  const send = makeClient(ws);
  await send("Runtime.enable");

  const evalJs = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("JS 异常: " + JSON.stringify(r.exceptionDetails.exception));
    return r.result.value;
  };
  for (let i = 0; i < 40; i++) {
    if (await evalJs(`document.readyState === "complete" && !!document.querySelector("#code")`)) break;
    await sleep(200);
  }

  const scroll = () => evalJs(`(() => {
    const c = document.querySelector("#code");
    return { code: c.scrollTop, codeX: c.scrollLeft,
             hl: document.querySelector("#hl").scrollTop, hlX: document.querySelector("#hl").scrollLeft,
             gutter: document.querySelector("#gutter").scrollTop };
  })()`);
  const wheel = async (x, y, dy, dx) => {
    await send("Input.dispatchMouseEvent", { type: "mouseWheel", x, y, deltaX: dx || 0, deltaY: dy });
    await sleep(350);
  };

  console.log("=== FLINT Studio 滚动回归探针 ===");
  const g = await evalJs(`(() => {
    const c = document.querySelector("#code").getBoundingClientRect();
    const gt = document.querySelector("#gutter").getBoundingClientRect();
    return { cx: Math.round(c.x + c.width / 2), cy: Math.round(c.y + c.height / 2),
             gx: Math.round(gt.x + gt.width / 2), gy: Math.round(gt.y + gt.height / 2) };
  })()`);

  // —— 长内容（300 行） ——
  await evalJs(`(() => {
    const c = document.querySelector("#code");
    let s = "";
    for (let i = 0; i < 300; i++) s += "int v" + i + " = " + i + ";  // 行 " + i + "\\n";
    c.value = s; c.dispatchEvent(new Event("input")); c.focus(); return 1;
  })()`);
  await sleep(300);

  const geo = await evalJs(`(() => {
    const c = document.querySelector("#code");
    return { sh: c.scrollHeight, ch: c.clientHeight, pane: Math.round(document.querySelector(".editor-pane").getBoundingClientRect().height),
             vp: innerHeight };
  })()`);
  console.log(`几何: textarea clientH=${geo.ch} scrollH=${geo.sh} 面板高=${geo.pane} 视口=${geo.vp}`);
  check("长内容下 textarea 可溢出（可滚）", geo.sh > geo.ch + 100, `scrollH=${geo.sh} clientH=${geo.ch}`);
  check("编辑面板不再被内容撑破视口", geo.pane <= geo.vp + 1, `pane=${geo.pane} vp=${geo.vp}`);

  // —— 滚轮：文本区 ——
  await wheel(g.cx, g.cy, 240);
  let s = await scroll();
  check("滚轮在文本区可滚动", s.code > 100, JSON.stringify(s));
  check("高亮层跟随（hl==code）", s.hl === s.code, JSON.stringify(s));
  check("行号栏跟随（gutter==code）", s.gutter === s.code, JSON.stringify(s));

  const resetScroll = async () => {
    await evalJs(`(() => { const c = document.querySelector("#code"); c.scrollTop = 0; c.scrollLeft = 0;
      const h = document.querySelector("#hl"); h.scrollTop = 0; h.scrollLeft = 0;
      document.querySelector("#gutter").scrollTop = 0; return 1; })()`);
    await sleep(120);
  };

  // —— 滚轮：行号栏 ——
  await resetScroll();
  const before = (await scroll()).code;
  await wheel(g.gx, g.gy, 240);
  s = await scroll();
  check("滚轮在行号栏上也能滚", s.code > before, `before=${before} now=${s.code}`);
  check("行号栏滚动后三层仍同步", s.hl === s.code && s.gutter === s.code, JSON.stringify(s));

  // —— 键盘 PageDown（需焦点） ——
  await resetScroll();
  await evalJs(`document.querySelector("#code").focus()`);
  const beforeKey = (await scroll()).code;
  await send("Input.dispatchKeyEvent", { type: "rawKeyDown", windowsVirtualKeyCode: 34, code: "PageDown", key: "PageDown" });
  await send("Input.dispatchKeyEvent", { type: "keyUp", windowsVirtualKeyCode: 34, code: "PageDown", key: "PageDown" });
  await sleep(350);
  s = await scroll();
  check("PageDown 可翻页", s.code > beforeKey, `before=${beforeKey} now=${s.code}`);

  // —— 横向：超长单行 ——
  await evalJs(`(() => {
    const c = document.querySelector("#code");
    c.value = "int " + "x".repeat(400) + " = 1;\\nint y = 2;\\n";
    c.dispatchEvent(new Event("input")); c.scrollTop = 0; c.scrollLeft = 0;
    document.querySelector("#hl").scrollLeft = 0; return 1;
  })()`);
  await sleep(250);
  const wide = await evalJs(`(() => { const c = document.querySelector("#code"); return { sw: c.scrollWidth, cw: c.clientWidth }; })()`);
  check("超长行可横向溢出", wide.sw > wide.cw + 100, JSON.stringify(wide));
  await wheel(g.cx, g.cy, 0, 200);
  s = await scroll();
  check("横向滚动高亮层同步", s.codeX > 50 && s.hlX === s.codeX, JSON.stringify(s));

  // —— 右侧结果面板滚轮 ——
  const ro = await evalJs(`(() => {
    const b = document.querySelector("#tabOut");
    b.innerHTML = Array.from({ length: 200 }, (_, i) => "<div>line " + i + "</div>").join("");
    const r = b.getBoundingClientRect();
    return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), sh: b.scrollHeight, ch: b.clientHeight };
  })()`);
  await wheel(ro.x, ro.y, 240);
  const outScroll = await evalJs(`document.querySelector("#tabOut").scrollTop`);
  check("结果面板可滚轮滚动", outScroll > 100, `scrollTop=${outScroll} sh=${ro.sh} ch=${ro.ch}`);

  // —— 注释可读性：对比度 ≥ 7:1（WCAG AAA）且不用斜体；等宽对齐不能被样式改动破坏 ——
  const com = await evalJs(`(() => {
    const c = document.querySelector("#code");
    c.value = "// abcdefghijklmnop int x = 1;\\nint main() { return 0; }\\n";
    c.dispatchEvent(new Event("input"));
    const s = document.querySelector("#hl .tk-com");
    if (!s) return null;
    const cs = getComputedStyle(s);
    const bg = getComputedStyle(document.body).backgroundColor;
    // 参考宽度：同字体、非注释样式量同一串文字（等宽字体宽度应完全一致 → 高亮层与 textarea 对齐没被破坏）
    const ref = document.createElement("span");
    ref.style.cssText = "position:absolute;visibility:hidden;white-space:pre;font:13px/1.7 var(--mono);";
    ref.textContent = s.textContent;
    document.body.appendChild(ref);
    const w = ref.getBoundingClientRect().width; ref.remove();
    return { color: cs.color, fontStyle: cs.fontStyle, bg,
             spanW: Math.round(s.getBoundingClientRect().width * 100) / 100, refW: Math.round(w * 100) / 100 };
  })()`);
  const rgb = (str) => str.match(/[\d.]+/g).slice(0, 3).map(Number);
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const L1 = lum(rgb(com.color)), L2 = lum(rgb(com.bg));
  const ratio = (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
  console.log(`注释: color=${com.color} bg=${com.bg} 对比度=${ratio.toFixed(2)}:1 italic=${com.fontStyle} 宽度 ${com.spanW} vs 参考 ${com.refW}`);
  check("注释对比度 ≥ 7:1（WCAG AAA）", ratio >= 7, `实际 ${ratio.toFixed(2)}:1`);
  check("注释不用斜体（13px 等宽下斜体发糊）", com.fontStyle === "normal", `实际 ${com.fontStyle}`);
  check("高亮层宽度与等宽参考一致（对齐未破坏）", Math.abs(com.spanW - com.refW) < 0.6, `${com.spanW} vs ${com.refW}`);

  console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
  ws.close();
  child.kill();
  try { fs.rmSync(udd, { recursive: true, force: true }); } catch {}
  process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.error("探针失败:", e.message); process.exit(1); });
