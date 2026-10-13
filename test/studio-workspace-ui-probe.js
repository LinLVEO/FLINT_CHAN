// studio-workspace-ui-probe.js — FLINT Studio v4「工作区」**界面**回归探针（CDP 驱动无头 Edge，零依赖）
// 用法：node test\studio-workspace-ui-probe.js
//   先起服务（默认打 127.0.0.1:8900 的实例；换目标：$env:STUDIO_URL="http://127.0.0.1:8899/"）
//   注意：本探针会**真的切工作区**（服务端会落盘记住），跑完会切回项目根
// 覆盖：
//   ① 工作区条显示当前工作区（短路径 + 完整路径在 title）
//   ② 点「更换」开选择器；列子目录、给快捷入口
//   ③ 粘绝对路径「前往」能定位；点进子目录能下钻
//   ④ 「用这个文件夹」→ 弹窗关、工作区条变、**文件树换成新工作区的 .fl**
//   ⑤ 刷新页面后工作区还记得（服务端落盘）
//   ⑥ 从快捷入口切回项目根，文件树恢复
//   ⑦ 「全部文件」开关：树里出现非 .fl（PROGRESS.md）
//   ⑧ Esc 关选择器
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8900/";
const ORIGIN = STUDIO.replace(/[?#].*$/, "").replace(/\/$/, "");
const PORT = Number(process.env.CDP_PORT || 9335);
const LAB = path.resolve(__dirname, "..");
const APPS = path.join(LAB, "apps");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0, fail = 0;
const check = (name, ok, detail) => {
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name}  ${detail === undefined ? "" : JSON.stringify(detail)}`); }
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
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "wsprobe-"));
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
  await send("Page.enable");

  const evalJs = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("JS 异常: " + JSON.stringify(r.exceptionDetails.exception));
    return r.result.value;
  };
  // 等首屏：DOM 就绪 + 文件树落地（工作区条也要在）
  const waitReady = async () => {
    for (let i = 0; i < 50; i++) {
      const ok = await evalJs(`document.readyState === "complete" && !!document.querySelector("#wsBar")
        && document.querySelectorAll("#fileTree .file-item").length > 0
        && document.querySelector("#wsPath").title.length > 0`);
      if (ok) return true;
      await sleep(200);
    }
    return false;
  };
  const treeRels = () => evalJs(`[...document.querySelectorAll("#fileTree .file-item")].map((e) => e.dataset.rel)`);
  const wsTitle = () => evalJs(`document.querySelector("#wsPath").title`);
  const modalOpen = () => evalJs(`!document.querySelector("#wsModal").classList.contains("hidden")`);
  const dirNames = () => evalJs(`[...document.querySelectorAll("#wsDirs .dir-item")].map((e) => e.textContent.trim())`);

  console.log("=== FLINT Studio v4 工作区 UI 探针 ===");
  console.log("目标: " + STUDIO);

  const ready = await waitReady();
  check("首屏就绪（工作区条 + 文件树都在）", ready);

  // ---------- ① 工作区条 ----------
  let t = await wsTitle();
  check("工作区条显示项目根（完整路径在 title）", String(t).toLowerCase() === LAB.toLowerCase(), t);
  const shortTxt = await evalJs(`document.querySelector("#wsPath").textContent`);
  check("工作区条显示短路径（不挤爆左栏）", shortTxt.length <= 24 && /FLINT-lab/.test(shortTxt), shortTxt);

  // ---------- ② 选择器：目录 + 快捷入口 ----------
  await evalJs(`document.querySelector("#wsChangeBtn").click()`);
  await sleep(500);
  check("点「更换」打开选择器", (await modalOpen()) === true);
  let names = await dirNames();
  check("列出当前文件夹的子目录", names.length >= 5 && names.some((n) => n.includes("apps")), names);
  const rootChips = await evalJs(`[...document.querySelectorAll("#wsRoots .ws-chip")].map((e) => e.title)`);
  check("快捷入口里有项目根", rootChips.some((p) => String(p).toLowerCase() === LAB.toLowerCase()), rootChips);
  check("快捷入口里有驱动器", rootChips.some((p) => /^[A-Za-z]:\\\\?$/.test(String(p)) || /^[A-Za-z]:\\$/.test(String(p))), rootChips);

  // ---------- ③ 粘绝对路径 → 前往 ----------
  await evalJs(`(() => { const i = document.querySelector("#wsPathInput"); i.value = ${JSON.stringify(APPS)};
    document.querySelector("#wsGo").click(); return 1; })()`);
  await sleep(500);
  const cur = await evalJs(`document.querySelector("#wsPathInput").value`);
  check("「前往」定位到 apps", String(cur).toLowerCase() === APPS.toLowerCase(), cur);
  names = await dirNames();
  check("apps 下能看到 student", names.some((n) => n.includes("student")), names);

  // 下钻：点 student 进下一层，再点「上一级」回来
  await evalJs(`[...document.querySelectorAll("#wsDirs .dir-item")].find((e) => e.textContent.includes("student")).click()`);
  await sleep(500);
  const cur2 = await evalJs(`document.querySelector("#wsPathInput").value`);
  check("点子目录能下钻", String(cur2).toLowerCase() === path.join(APPS, "student").toLowerCase(), cur2);
  await evalJs(`document.querySelector("#wsUp").click()`);
  await sleep(500);
  const cur3 = await evalJs(`document.querySelector("#wsPathInput").value`);
  check("「上一级」能回来", String(cur3).toLowerCase() === APPS.toLowerCase(), cur3);

  // ---------- ④ 用这个文件夹 ----------
  await evalJs(`document.querySelector("#wsUse").click()`);
  await sleep(800);
  check("切换后弹窗自动关闭", (await modalOpen()) === false);
  t = await wsTitle();
  check("工作区条变成 apps", String(t).toLowerCase() === APPS.toLowerCase(), t);
  let rels = await treeRels();
  check("文件树换成 apps 下的 .fl", rels.length > 0 && rels.every((r) => r.toLowerCase().endsWith(".fl")) && rels.some((r) => r.startsWith("student/")), rels.slice(0, 5));
  check("旧工作区的文件不在树里（src/parse.c 之类的 .fl 没了）", !rels.some((r) => r.includes("samples/")), rels.slice(0, 5));

  // ---------- ⑤ 刷新后还记得 ----------
  await send("Page.reload");
  await sleep(1200);
  const ready2 = await waitReady();
  check("刷新后首屏仍就绪", ready2);
  t = await wsTitle();
  check("刷新后工作区还是 apps（服务端落盘生效）", String(t).toLowerCase() === APPS.toLowerCase(), t);

  // ---------- ⑥ 切回项目根 ----------
  await evalJs(`document.querySelector("#wsChangeBtn").click()`);
  await sleep(500);
  await evalJs(`(() => { const c = [...document.querySelectorAll("#wsRoots .ws-chip")]
    .find((e) => String(e.title).toLowerCase() === ${JSON.stringify(LAB.toLowerCase())});
    if (c) c.click(); return !!c; })()`);
  await sleep(500);
  await evalJs(`document.querySelector("#wsUse").click()`);
  await sleep(800);
  t = await wsTitle();
  check("从快捷入口切回项目根", String(t).toLowerCase() === LAB.toLowerCase(), t);
  rels = await treeRels();
  check("文件树恢复成项目的大列表", rels.length > 50 && rels.some((r) => r === "apps/student/student.fl"), rels.length);

  // ---------- ⑦ 全部文件开关 ----------
  await evalJs(`(() => { const c = document.querySelector("#showAllFiles"); c.checked = true; c.dispatchEvent(new Event("change")); return 1; })()`);
  await sleep(700);
  rels = await treeRels();
  check("「全部文件」后树里出现 .fl 之外的文件", rels.some((r) => !r.toLowerCase().endsWith(".fl")), rels.filter((r) => !r.toLowerCase().endsWith(".fl")).slice(0, 4));
  check("「全部文件」里能看到 PROGRESS.md", rels.includes("PROGRESS.md"), null);
  const headLabel = await evalJs(`document.querySelector("#filesHeadLabel").textContent`);
  check("左栏标题跟着说明范围", /全部/.test(headLabel), headLabel);
  await evalJs(`(() => { const c = document.querySelector("#showAllFiles"); c.checked = false; c.dispatchEvent(new Event("change")); return 1; })()`);
  await sleep(500);
  rels = await treeRels();
  check("取消「全部文件」后只剩 .fl", rels.length > 0 && rels.every((r) => r.toLowerCase().endsWith(".fl")), rels.length);

  // ---------- ⑧ Esc 关选择器 ----------
  await evalJs(`document.querySelector("#wsChangeBtn").click()`);
  await sleep(400);
  const opened = await modalOpen();
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 });
  await sleep(300);
  check("Esc 关闭选择器", opened === true && (await modalOpen()) === false);

  // ---------- ⑨ 没把编辑器搞坏 ----------
  const stillOk = await evalJs(`(!!document.querySelector("#code") && document.querySelector("#code").value.length > 10
    && !!document.querySelector("#compileBtn") && document.querySelector("#fileFilter") !== null)`);
  check("编辑器主体仍正常（代码区/编译钮/过滤器都在）", stillOk === true);

  console.log("----");
  console.log(`通过 ${pass} / 失败 ${fail}`);
  try { ws.close(); } catch {}
  child.kill();
  process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => { console.log("探针异常: " + e.message); process.exit(1); });
