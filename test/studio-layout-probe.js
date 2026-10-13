// studio-layout-probe.js — 三栏布局回归（拖宽 / 收起 / 记忆 / 对照可用）
// 用法：node test\studio-layout-probe.js    （默认打 127.0.0.1:8900；STUDIO_URL 可换）
// 用户诉求（原话）：「反汇编难道不对照看吗？调整几个窗口的宽度占用，然后两边可以收起来」
//   → 验收点 = 能把右栏拉宽到**一边看代码一边看反汇编**，且左右两栏都能收起来腾地方。
"use strict";
const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const fs = require("fs");

const EDGE = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const STUDIO = process.env.STUDIO_URL || "http://127.0.0.1:8900/";
const ORIGIN = STUDIO.replace(/[?#].*$/, "").replace(/\/$/, "");
const PORT = Number(process.env.CDP_PORT || 9339);
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
const pending = new Map();
let ws = null;
function attachSocket(socket) {
  socket.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
    }
  });
}
// ⚠️ 每条命令必须带超时：页面 reload 期间发出的命令，响应会被导航吞掉 →
//    不带超时的 Promise 永远不 settle → 整个探针卡死到外部超时（实测踩过一次）。
function send(method, params) {
  return new Promise((resolve, reject) => {
    if (!ws || ws.readyState !== 1) { reject(new Error(`CDP 未连接(${method})`)); return; }
    const id = ++idSeq;
    const timer = setTimeout(() => {
      if (pending.has(id)) { pending.delete(id); reject(new Error(`CDP 超时(${method})`)); }
    }, 10000);
    pending.set(id, {
      resolve: (v) => { clearTimeout(timer); resolve(v); },
      reject: (e) => { clearTimeout(timer); reject(e); },
    });
    ws.send(JSON.stringify({ id, method, params: params || {} }));
  });
}
// 启动一个无头 Edge（同一 profile 可重复启动 → 用来测"重启后还记得布局"）
function launchEdge(udd) {
  return spawn(EDGE, ["--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${udd}`,
    "--no-first-run", "--no-default-browser-check", "--disable-gpu", "--window-size=1440,900",
    // ⚠️ 临时 profile 会冒出 edge://sync-confirmation-dialog/ 等"另一个 page 目标"，
    //    刷新时把调试会话抢走（实测 `/json/list` 第一条变成它）→ 命令全打到错的页面。
    //    下面四条把首次运行 / 同步 / 扩展交互全关掉，探针才是确定的。
    "--disable-sync", "--disable-extensions", "--disable-features=msEdgeSyncPromo", "--no-service-autorun",
    STUDIO], { stdio: "ignore" });
}
// 连上 Studio 页面（按 URL 认目标）+ Runtime/Page enable
async function connectStudio() {
  let page = null;
  for (let i = 0; i < 60; i++) {
    await sleep(300);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      // ⚠️ 必须按 URL 认目标：空白 Edge 可能自带别的 page 目标（实测见过
      //    edge://sync-confirmation-dialog/），/json/list 第一条不一定是 Studio
      //    → 认错目标 = 全套命令打到别的页面（假红甚至卡死）。
      page = list.find((t) => t.type === "page" && t.webSocketDebuggerUrl
        && (t.url || "").startsWith(ORIGIN));
      if (page) break;
    } catch { /* 等 */ }
  }
  if (!page) throw new Error("连不上 Edge CDP");
  const sock = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { sock.addEventListener("open", res); sock.addEventListener("error", rej); });
  attachSocket(sock);
  ws = sock;
  await send("Runtime.enable");
  await send("Page.enable");
}
// 重启浏览器（同一 profile → localStorage 保留）：比页面内 reload 更真、也好控制。
// ⚠️ 必须**优雅退出**：直接 kill 掉进程，LocalStorage 的写盘可能还没落盘 →
//    重启后读回 null（实测过：并行跑那一轮 "layout 四件套" 判红，单跑又绿）。
async function restartBrowser(child, udd) {
  try { ws.close(); } catch { /* 旧连接已废 */ }
  // Browser.close = 正常退出（会 flush 存储）；不行再 taskkill，最后才硬 kill
  try {
    await Promise.race([
      send("Browser.close"),
      new Promise((r) => setTimeout(r, 3000)),
    ]);
  } catch { /* 浏览器可能已经不理我们了 */ }
  for (let i = 0; i < 30; i++) {
    await sleep(200);
    if (child.exitCode !== null || child.killed) break;
  }
  if (child.exitCode === null) {
    try {
      await new Promise((res) => {
        const k = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
        k.on("exit", res);
        setTimeout(res, 3000);
      });
    } catch { /* 兜底再硬杀 */ }
    try { child.kill(); } catch { /* 可能已退 */ }
  }
  await sleep(2500);                      // 等 profile 锁释放 + 存储落盘
  const c2 = launchEdge(udd);
  await connectStudio();
  return c2;
}

(async () => {
  const udd = fs.mkdtempSync(path.join(os.tmpdir(), "layoutprobe-"));
  let child = launchEdge(udd);
  try {
    await connectStudio();
  } catch (e) {
    console.log("❌ " + e.message);
    child.kill();
    process.exit(1);
  }
  const ev = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("JS 异常: " + JSON.stringify(r.exceptionDetails.exception));
    return r.result.value;
  };
  const key = async (k, code, vk, modifiers) => {
    const b = { key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: modifiers || 0 };
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyDown" }, b));
    await send("Input.dispatchKeyEvent", Object.assign({ type: "keyUp" }, b));
    await sleep(150);
  };
  // 真鼠标拖分隔条（CDP 输入 → Chrome 会同时派发 pointer 事件）
  // ⚠️ 步进必须算比例（别用 `x += 25` 配 `x !== toX` 的循环：取整一错就永远不相等 = 死循环）
  const dragSplitter = async (sel, toX) => {
    const box = await ev(`(() => { const r = document.querySelector("${sel}").getBoundingClientRect();
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }; })()`);
    await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: box.x, y: box.y, button: "none" });
    await send("Input.dispatchMouseEvent", { type: "mousePressed", x: box.x, y: box.y, button: "left", clickCount: 1 });
    const steps = 10;
    for (let i = 1; i <= steps; i++) {
      const x = Math.round(box.x + (toX - box.x) * (i / steps));
      await send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y: box.y, button: "left" });
      await sleep(20);
    }
    await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: toX, y: box.y, button: "left", clickCount: 1 });
    await sleep(250);
  };
  const widths = () => ev(`(() => {
    const l = document.querySelector(".files-pane"), e = document.querySelector(".editor-pane"), r = document.querySelector(".result-pane");
    const vis = (el) => el.offsetParent !== null && el.getBoundingClientRect().width > 0;
    return { 左: Math.round(l.getBoundingClientRect().width), 中: Math.round(e.getBoundingClientRect().width),
             右: Math.round(r.getBoundingClientRect().width), 中可见: vis(e) };
  })()`);
  const disLines = () => ev(`(() => {
    const body = document.querySelector("#tabDis"), pre = document.querySelector("pre.dis");
    if (!pre) return null;
    const lh = parseFloat(getComputedStyle(pre).lineHeight);
    return { 可见行: Math.floor(body.clientHeight / lh), 内容宽: pre.scrollWidth, 容器宽: body.clientWidth,
             需横滚: pre.scrollWidth > body.clientWidth };
  })()`);

  console.log("=== 三栏布局探针（拖宽 / 收起 / 对照）===");
  console.log("目标: " + STUDIO);
  for (let i = 0; i < 50; i++) {
    if (await ev(`document.readyState === "complete" && !!document.querySelector("#splitR")`)) break;
    await sleep(200);
  }
  await ev(`(() => { const c = document.querySelector("#code"); c.value = ${JSON.stringify(SRC)};
    c.dispatchEvent(new Event("input")); return 1; })()`);
  await ev(`document.querySelector("#compileBtn").click()`);
  for (let i = 0; i < 80; i++) {
    if (await ev(`document.querySelectorAll("#tabHex tr").length > 0`)) break;
    await sleep(250);
  }
  await sleep(400);

  // ---------- ① 默认三栏 ----------
  const w0 = await widths();
  check("三栏都在（左 240 / 右 380 默认）", w0.左 > 200 && w0.右 > 300 && w0.中 > 400, w0);

  // ---------- ② 拖宽右栏 → 反汇编能对照看 ----------
  await ev(`document.querySelector('.tab[data-tab="dis"]').click()`);
  await sleep(250);
  const dBefore = await disLines();
  await dragSplitter("#splitR", 480);                   // 把分隔条往左拖 → 右栏变宽
  const w1 = await widths();
  check("拖动分隔条能把右栏拉宽", w1.右 > w0.右 + 150, { 前: w0.右, 后: w1.右 });
  check("拉宽时编辑器还在（能对照看代码）", w1.中 > 300 && w1.中可见 === true, w1);
  const dAfter = await disLines();
  // 注意：可见**行数**只跟高度有关（拉宽不改高度）——拉宽治的是"一行放不下要横滚"
  check("右栏变宽后容器也变宽（一行能放下的内容更多）", dAfter.容器宽 > dBefore.容器宽, { 前: dBefore.容器宽, 后: dAfter.容器宽 });
  check("右栏变宽后反汇编不用横向滚", dAfter.需横滚 === false, dAfter);
  check("对照场景：右栏宽 + 编辑器宽同时成立", dAfter.容器宽 > 500 && w1.中 > 300, { 右栏: dAfter.容器宽, 编辑器: w1.中 });

  // ---------- ③ 拖到极限：编辑器有下限 ----------
  await dragSplitter("#splitR", 20);
  const w2 = await widths();
  check("拖到头也不会把编辑器挤没（≥300px）", w2.中 >= 300, w2);
  check("右栏有上限（≤ 视口 - 编辑器下限）", w2.右 <= 1416 - 300, w2);
  await dragSplitter("#splitR", 900 - 380);             // 拉回一个舒服的宽度

  // ---------- ④ 左右两栏收起 ----------
  await ev(`document.querySelector("#toggleRight").click()`);
  await sleep(250);
  const w3 = await widths();
  check("点 ◨ 能收起结果栏", (await ev(`document.body.classList.contains("hide-right")`)) === true && w3.右 === 0, w3);
  check("收起右栏后编辑器变宽", w3.中 > w1.中, { 收前: w1.中, 收后: w3.中 });
  await ev(`document.querySelector("#toggleRight").click()`);
  await sleep(250);
  check("再点一次展开结果栏", (await widths()).右 > 300);

  await ev(`document.querySelector("#toggleLeft").click()`);
  await sleep(250);
  const w4 = await widths();
  check("点 ◧ 能收起文件栏", (await ev(`document.body.classList.contains("hide-left")`)) === true && w4.左 === 0, w4);
  await ev(`document.querySelector("#toggleLeft").click()`);
  await sleep(250);
  check("再点一次展开文件栏", (await widths()).左 > 200);

  // ---------- ⑤ 快捷键 ----------
  const before = (await widths()).右;
  await key("b", "KeyB", 66, 2 | 1);                    // Ctrl+Alt+B → 右栏
  const afterHot = (await widths()).右;
  check("Ctrl+Alt+B 收起结果栏", afterHot === 0 && before > 0, { 前: before, 后: afterHot });
  await key("b", "KeyB", 66, 2 | 1);
  await key("b", "KeyB", 66, 2);                        // Ctrl+B → 左栏
  check("Ctrl+B 收起文件栏", (await ev(`document.body.classList.contains("hide-left")`)) === true);
  await key("b", "KeyB", 66, 2);

  // ---------- ⑥ 宽度记住（刷新后还在）----------
  await dragSplitter("#splitR", 700 - 380);
  const wBeforeReload = await widths();
  const saved = await ev(`localStorage.getItem("studio.layout")`);
  check("宽度已写进 localStorage", !!saved && /wRight/.test(saved), saved);
  // ⚠️ 别用「页面内 reload」验持久化：导航会把在飞的 CDP 命令响应吞掉，还容易被
  //    Edge 自己的页面（sync/扩展）抢走调试目标（实测踩过两次卡死）。
  //    改成**重启无头 Edge（同一 profile）**：更接近"下次打开还是这样"，且全程可控。
  child = await restartBrowser(child, udd);
  let backOk = false;
  for (let i = 0; i < 40; i++) {
    try { if (await ev(`document.readyState === "complete" && !!document.querySelector("#splitR")`)) { backOk = true; break; } }
    catch { /* 还在加载，下一轮再试 */ }
    await sleep(250);
  }
  check("重启后页面确实起来了（有上限，不空等）", backOk);
  const wAfterReload = await widths();
  const savedAfter = await ev(`localStorage.getItem("studio.layout")`);
  let lay = null;
  try { lay = JSON.parse(savedAfter); } catch { /* 解析失败就在下面判红 */ }
  check("重启后宽度还是拉宽后的样子", backOk && Math.abs(wAfterReload.右 - wBeforeReload.右) <= 6, { 前: wBeforeReload.右, 后: wAfterReload.右 });
  check("layout 四件套齐全（没有只存一半）", !!lay && lay.wLeft !== undefined && lay.wRight !== undefined
    && lay.hideLeft !== undefined && lay.hideRight !== undefined, lay);
  check("两栏都没被上次的收起状态卡住", wAfterReload.左 > 200 && wAfterReload.右 > 200, wAfterReload);

  // ---------- ⑦ 双击分隔条 = 收起 ----------
  await ev(`document.querySelector("#splitL").dispatchEvent(new MouseEvent("dblclick", { bubbles: true }))`);
  await sleep(250);
  check("双击分隔条也能收起", (await ev(`document.body.classList.contains("hide-left")`)) === true);
  await ev(`document.querySelector("#toggleLeft").click()`);
  await sleep(200);

  console.log("----");
  console.log(`通过 ${pass} / 失败 ${fail}`);
  try { ws.close(); } catch {}
  child.kill();
  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => { console.log("探针异常: " + e.message); process.exit(1); });
