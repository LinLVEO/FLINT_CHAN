// studio-ui-probe.js — FLINT Studio 编辑器「UI 行为」回归探针（CDP 驱动 Edge 无头，零依赖）
// 用法：node test\studio-ui-probe.js   （需先启动 editor\启动FLINT Studio.bat，:8899）
// 覆盖 v3 新增/修复的行为：
//   ① 高亮跟上 v1.1.0：double 是关键字；浮点字面量 3.14 / 1.5e-2 各算一个 token
//   ② Tab 多行缩进 / Shift+Tab 退格——选中内容**不许被删掉**（v2 的 Tab 会拿两空格换掉选区）
//   ③ 撤销栈：编辑走 execCommand → Ctrl+Z 必须能退回（v2 用 code.value= 会抹掉撤销栈）
//   ④ Ctrl+/ 行注释开关
//   ⑤ 未保存标记：干净=暗点，改动=橙点 + 标题带 ●
//   ⑥ Ctrl+F 查找条 + 匹配计数
//   ⑦ 侧栏文件树 + 过滤
//   ⑧ 编译错误定位到「行」：行号栏标红
//   ⑨ 退出码翻人话 + 反汇编页签
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8899/";
const ORIGIN = STUDIO.replace(/[?#].*$/, "").replace(/\/$/, "");
const PORT = Number(process.env.CDP_PORT || 9334);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}  ${detail === undefined ? "" : detail}`); }
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
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "uiprobe-"));
  const child = spawn(EDGE, [
    "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${udd}`,
    "--no-first-run", "--no-default-browser-check", "--disable-gpu",
    "--window-size=1440,900", STUDIO,
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
  for (let i = 0; i < 60; i++) {
    if (await evalJs(`document.readyState === "complete" && !!document.querySelector("#code")`)) break;
    await sleep(200);
  }
  // 等异步加载（文件树 / 库速查）落地
  for (let i = 0; i < 40; i++) {
    const ready = await evalJs(`document.querySelectorAll("#fileTree .file-item").length > 0
      && document.querySelectorAll("#libsBody .lib-fn").length > 0`);
    if (ready) break;
    await sleep(200);
  }

  // 按键（真键盘事件，Ctrl+Z 这种必须走真实路径）
  const key = async (k, code, vk, modifiers) => {
    const base = { key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: modifiers || 0 };
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyDown" }, base));
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyUp" }, base));
    await sleep(120);
  };
  const CTRL = 2, SHIFT = 8;
  const setSrc = async (src) => {
    await evalJs(`(() => { const c = document.querySelector("#code"); c.value = ${JSON.stringify(src)};
      c.selectionStart = c.selectionEnd = 0; window.dispatchEvent(new Event("x")); c.dispatchEvent(new Event("input"));
      return c.value.length; })()`);
    await sleep(80);
  };
  const flush = () => evalJs(`(function () { if (typeof render === "function") render(); return document.querySelector("#code").value; })()`);

  console.log("=== FLINT Studio UI 行为探针（v3）===");

  // 任何改动之前先记下「初始干净状态」
  const initDot = await evalJs(`document.querySelector("#dirtyDot").className`);
  const initTitle = await evalJs(`document.title`);

  // ---------- ① 高亮 ----------
  await setSrc(`int main() {
  double d = 3.14;
  double e = 1.5e-2;
  return 0;
}`);
  await flush();
  const hlInfo = await evalJs(`(() => {
    const spans = [...document.querySelectorAll("#hl span")];
    return {
      kw: spans.filter((s) => s.className === "tk-kw").map((s) => s.textContent),
      num: spans.filter((s) => s.className === "tk-num").map((s) => s.textContent),
    };
  })()`);
  check("double 被识别为关键字", hlInfo.kw.includes("double"), JSON.stringify(hlInfo.kw));
  check("浮点字面量 3.14 是一个整体 token", hlInfo.num.includes("3.14"), JSON.stringify(hlInfo.num));
  check("科学计数 1.5e-2 是一个整体 token", hlInfo.num.includes("1.5e-2"), JSON.stringify(hlInfo.num));

  // ---------- ② Tab 多行缩进 / 退格（不许吃内容）----------
  await setSrc("int a = 1;\nint b = 2;\n");
  await evalJs(`(() => { const c = document.querySelector("#code"); c.focus(); c.selectionStart = 0; c.selectionEnd = c.value.length; return 1; })()`);
  await key("Tab", "Tab", 9, 0);
  const indented = await evalJs(`document.querySelector("#code").value`);
  check("Tab 只加缩进、不删选中内容", indented === "  int a = 1;\n  int b = 2;\n", JSON.stringify(indented));
  await key("Tab", "Tab", 9, SHIFT);
  const outdented = await evalJs(`document.querySelector("#code").value`);
  check("Shift+Tab 退掉缩进", outdented === "int a = 1;\nint b = 2;\n", JSON.stringify(outdented));

  // ---------- ③ 撤销栈：Ctrl+Z 必须能退回 ----------
  await setSrc("int a = 1;\n");
  await evalJs(`(() => { const c = document.querySelector("#code"); c.focus(); c.selectionStart = 0; c.selectionEnd = 0; return 1; })()`);
  await key("Tab", "Tab", 9, 0);                       // 走 execCommand 的一次缩进
  const afterIndent = await evalJs(`document.querySelector("#code").value`);
  await key("z", "KeyZ", 90, CTRL);
  const afterUndo = await evalJs(`document.querySelector("#code").value`);
  check("缩进生效", afterIndent === "  int a = 1;\n", JSON.stringify(afterIndent));
  check("Ctrl+Z 能撤销这次缩进（撤销栈没被抹掉）", afterUndo === "int a = 1;\n", JSON.stringify(afterUndo));

  // ---------- ④ Ctrl+/ 行注释 ----------
  await setSrc("int a = 1;\nint b = 2;\n");
  await evalJs(`(() => { const c = document.querySelector("#code"); c.focus(); c.selectionStart = 0; c.selectionEnd = c.value.length; return 1; })()`);
  await key("/", "Slash", 191, CTRL);
  const commented = await evalJs(`document.querySelector("#code").value`);
  await key("/", "Slash", 191, CTRL);
  const uncommented = await evalJs(`document.querySelector("#code").value`);
  check("Ctrl+/ 加上行注释", commented === "// int a = 1;\n// int b = 2;\n", JSON.stringify(commented));
  check("Ctrl+/ 再按一次取消注释", uncommented === "int a = 1;\nint b = 2;\n", JSON.stringify(uncommented));

  // ---------- ⑤ 未保存标记 ----------
  await evalJs(`(() => { const c = document.querySelector("#code"); c.value = "int x = 1;"; c.dispatchEvent(new Event("input")); return 1; })()`);
  const dirtyDot = await evalJs(`document.querySelector("#dirtyDot").className`);
  const dirtyTitle = await evalJs(`document.title`);
  check("初始是干净状态（暗点）", /clean/.test(initDot), initDot);
  check("初始标题没有 ●", initTitle.indexOf("●") === -1, initTitle);
  check("改动后变脏（橙点）", dirtyDot === "dot", dirtyDot);
  check("标题带 ● 提示", dirtyTitle.indexOf("●") === 0, dirtyTitle);

  // ---------- ⑥ Ctrl+F 查找 ----------
  await setSrc("int main() {\n  int sum = 0;\n  sum = sum + 1;\n  return sum;\n}\n");
  await flush();
  await key("f", "KeyF", 70, CTRL);
  const barOpen = await evalJs(`!document.querySelector("#findbar").classList.contains("hidden")`);
  await evalJs(`(() => { const i = document.querySelector("#findInput"); i.value = "sum"; i.dispatchEvent(new Event("input")); return 1; })()`);
  await sleep(120);
  const findCount = await evalJs(`document.querySelector("#findCount").textContent`);
  await evalJs(`document.querySelector("#findNext").click()`);
  await sleep(120);
  const selText = await evalJs(`(() => { const c = document.querySelector("#code"); return c.value.slice(c.selectionStart, c.selectionEnd); })()`);
  check("Ctrl+F 打开查找条", barOpen === true);
  check("匹配计数正确（sum 出现 4 次）", findCount === "—/4", findCount);
  check("「下一个」选中了匹配词", selText === "sum", JSON.stringify(selText));
  await key("Escape", "Escape", 27, 0);
  const barClosed = await evalJs(`document.querySelector("#findbar").classList.contains("hidden")`);
  check("Esc 关闭查找条", barClosed === true);

  // ---------- ⑦ 侧栏文件树 + 过滤 ----------
  const treeAll = await evalJs(`document.querySelectorAll("#fileTree .file-item").length`);
  await evalJs(`(() => { const i = document.querySelector("#fileFilter"); i.value = "num_lib"; i.dispatchEvent(new Event("input")); return 1; })()`);
  await sleep(120);
  const treeFiltered = await evalJs(`[...document.querySelectorAll("#fileTree .file-item")].map((e) => e.dataset.rel)`);
  check("文件树列出了 .fl 文件", treeAll > 50, String(treeAll));
  check("过滤能收窄到 num_lib", treeFiltered.length >= 1 && treeFiltered.every((r) => r.indexOf("num_lib") >= 0), JSON.stringify(treeFiltered));
  await evalJs(`(() => { const i = document.querySelector("#fileFilter"); i.value = ""; i.dispatchEvent(new Event("input")); return 1; })()`);

  // ---------- ⑧ 编译错误定位（行号栏标红）----------
  await setSrc("int main() {\n  return (1 + 2;\n}\n");
  await evalJs(`(() => { document.querySelector("#compileBtn").click(); return 1; })()`);
  for (let i = 0; i < 60; i++) {
    const done = await evalJs(`document.querySelector("#compileBtn").disabled === false && !document.querySelector("#tabLog").classList.contains("hidden")`);
    if (done) break;
    await sleep(300);
  }
  const errInfo = await evalJs(`(() => {
    const ln = document.querySelector("#gutter .ln-err");
    return { has: !!ln, line: ln ? ln.textContent : null,
             log: (document.querySelector("#tabLog").textContent || "").slice(0, 120) };
  })()`);
  check("语法错误 → 行号栏对应行标红", errInfo.has === true && errInfo.line === "2", JSON.stringify(errInfo));
  check("编译信息里给出「行 + 列」", /第\s*2\s*行/.test(errInfo.log), errInfo.log);

  // ---------- ⑨ 退出码人话 + 反汇编 ----------
  await setSrc("int main() { int *p = 0; *p = 1; return 0; }\n");
  await evalJs(`(() => { document.querySelector("#compileBtn").click(); return 1; })()`);
  for (let i = 0; i < 60; i++) {
    const done = await evalJs(`document.querySelector("#compileBtn").disabled === false && !document.querySelector("#tabOut").classList.contains("hidden")`);
    if (done) break;
    await sleep(300);
  }
  const crashInfo = await evalJs(`document.querySelector("#tabOut").textContent`);
  const disInfo = await evalJs(`(() => { document.querySelector('[data-tab="dis"]').click();
    return (document.querySelector("#tabDis").textContent || "").slice(0, 200); })()`);
  check("野指针退出码翻成人话「访问冲突」", /访问冲突/.test(crashInfo), crashInfo.slice(0, 120));
  check("反汇编页签有 objdump 输出", /pei-x86-64|<\.text>|ret/.test(disInfo), disInfo.slice(0, 120));

  console.log("----");
  console.log(`通过 ${pass} / 失败 ${fail}`);
  ws.close();
  child.kill();
  process.exit(fail ? 1 : 0);
}

main().catch((e) => { console.log("探针自身出错: " + e.message); process.exit(2); });
