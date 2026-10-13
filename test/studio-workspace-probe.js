// studio-workspace-probe.js — FLINT Studio v4「工作区」回归探针（HTTP 层，零依赖）
// 用法：
//   1) 起一个服务实例（建议独立端口；想连状态文件也隔离就再加 STUDIO_STATE）：
//        默认实例：            $env:PORT=8900; node editor\server.js
//        完全隔离的测试实例：  $env:PORT=8900; $env:STUDIO_STATE="...\ws-test-state.json"; node editor\server.js
//   2) node test\studio-workspace-probe.js
//        （默认打 127.0.0.1:8900；换目标：$env:STUDIO_BASE="http://127.0.0.1:8899"）
//      ⚠️ 探针要读「工作区状态文件」核对落盘，**默认按服务端的默认路径 workspace.json**；
//         如果你给服务端设了 STUDIO_STATE=别的文件，跑探针时也要设同一个值，否则 3 项落盘检查会红。
// 覆盖：工作区读写 / 目录浏览 / 相对路径解析 / 文件树随工作区变化 / ?all=1 /
//       路径穿越与只读守卫仍在 / 二进制与超大文件拒收 / 切工作区后编译仍可用 / 状态落盘
"use strict";
const fs = require("fs");
const path = require("path");

const BASE = process.env.STUDIO_BASE || "http://127.0.0.1:8900";
const LAB = path.resolve(__dirname, "..");            // E:\FLINT-lab
const STATE = process.env.STUDIO_STATE || path.join(LAB, "editor", "tmp", "workspace.json");

let pass = 0, fail = 0;
function ck(name, cond, extra) {
  if (cond) { pass++; console.log("  OK   " + name); }
  else { fail++; console.log("  FAIL " + name + (extra !== undefined ? "  → " + JSON.stringify(extra) : "")); }
}
async function jget(p) { const r = await fetch(BASE + p); return r.json(); }
async function jpost(p, obj) {
  const r = await fetch(BASE + p, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(obj),
  });
  return r.json();
}

(async () => {
  console.log("目标: " + BASE);

  // ① health 带工作区字段
  const h = await jget("/api/health");
  ck("health 含 workspace/v", h.ok === true && typeof h.workspace === "string" && h.v === 4, h);

  // ② 工作区可读（先归零到项目根：这样探针能反复跑，不受上次残留影响）
  const reset = await jpost("/api/workspace", { path: LAB });
  ck("开工归零：切到项目根", reset.ok === true, reset);
  let ws = await jget("/api/workspace");
  ck("工作区 = 项目根", ws.ok === true && ws.workspace.toLowerCase() === LAB.toLowerCase(), ws);
  ck("返回 recent 数组", Array.isArray(ws.recent), ws.recent);

  // ③ 目录浏览：默认列工作区子目录
  let d = await jget("/api/dirs");
  ck("列目录 ok", d.ok === true && d.path.toLowerCase() === LAB.toLowerCase(), d.error);
  const names = (d.dirs || []).map((x) => x.name);
  ck("列出 apps/boot/editor/lib/src/test", ["apps", "boot", "editor", "lib", "src", "test"].every((n) => names.includes(n)), names);
  ck("tmp 可见（用户反馈：能读的东西不许藏）", names.includes("tmp"), names);
  ck("仍跳过点名目录（无 .git/node_modules）", !names.includes(".git") && !names.includes("node_modules"), names);
  ck("给快捷入口（驱动器/项目根）", (d.roots || []).some((r) => r.path === LAB) && (d.roots || []).length >= 3, d.roots);
  ck("给上一级", d.parent && d.parent.toUpperCase().startsWith("E:"), d.parent);

  // ④ 目录浏览：绝对路径 + 不存在路径
  d = await jget("/api/dirs?path=" + encodeURIComponent(LAB + "\\src"));
  ck("按绝对路径浏览 src", d.ok === true && d.path.toLowerCase() === (LAB + "\\src").toLowerCase(), d.error);
  d = await jget("/api/dirs?path=" + encodeURIComponent(LAB + "\\__nope__"));
  ck("不存在的目录：报错不抛异常", d.ok === false && !!d.error, d.error);

  // ⑤ 文件树：.fl 默认 + all=1 含非 .fl
  const fl = await jget("/api/files");
  ck("文件树 root = 工作区", fl.root && fl.root.toLowerCase() === LAB.toLowerCase(), fl.root);
  ck("默认只列 .fl", (fl.files || []).length > 100 && (fl.files || []).every((f) => f.rel.toLowerCase().endsWith(".fl")), (fl.files || []).length);
  const all = await jget("/api/files?all=1");
  ck("all=1 数量更多", all.all === true && (all.files || []).length > (fl.files || []).length, [ (fl.files || []).length, (all.files || []).length ]);
  ck("all=1 含 PROGRESS.md", (all.files || []).some((f) => f.rel === "PROGRESS.md"), null);
  // v4.1：tmp 不再被当噪音藏起来（用户反馈「tmp 咋读不到」——bug1-*.fl 这类样本就在那儿）
  ck("文件树里能看到 tmp 下的 .fl", (fl.files || []).some((f) => f.rel.startsWith("tmp/") && f.rel.toLowerCase().endsWith(".fl")),
     (fl.files || []).filter((f) => f.rel.startsWith("tmp/")).slice(0, 3));

  // ⑥ 二进制 / 超大文件守卫（工作区内 tmp\*.png 是现成的二进制样本）
  const bin = await jget("/api/file?path=" + encodeURIComponent("tmp/cpu_bar.png"));
  ck("二进制文件被拒（提示清楚）", bin.ok === false && /二进制/.test(bin.error || ""), bin.error);
  const dir = await jget("/api/file?path=" + encodeURIComponent("src"));
  ck("传目录被拒", dir.ok === false && /文件夹/.test(dir.error || ""), dir.error);

  // ⑦ 路径穿越防护仍在（相对根换了，规则不变）
  const bad = await jget("/api/file?path=" + encodeURIComponent("../../PROGRESS.md"));
  ck("仍拒绝路径穿越", bad.ok === false, bad);
  const badSave = await jpost("/api/save", { path: "../escape.fl", src: "int main(){return 0;}\n" });
  ck("保存也拒绝穿越", badSave.ok === false, badSave);

  // ⑧ 切换工作区（相对路径按当前工作区解析）
  let set = await jpost("/api/workspace", { path: "test" });
  ck("切到 test（相对路径）", set.ok === true && set.workspace.toLowerCase() === (LAB + "\\test").toLowerCase(), set);
  const fl2 = await jget("/api/files");
  ck("文件树 rel 相对新工作区", (fl2.files || []).some((f) => f.rel === "samples/iolib1.fl"), (fl2.files || []).slice(0, 3));
  ck("旧工作区的文件不再出现", !(fl2.files || []).some((f) => f.rel === "apps/student/student.fl"), null);

  // ⑨ 切换后：打开 / 保存 / 编译 都相对新工作区
  const open2 = await jget("/api/file?path=" + encodeURIComponent("samples/iolib1.fl"));
  ck("能打开新工作区里的文件", open2.ok === true && (open2.src || "").length > 20, open2.error);
  const rel = "tmp/ws_probe.fl";
  const saved = await jpost("/api/save", { path: rel, src: "int main() { return 42; }\n" });
  ck("能在新工作区里保存", saved.ok === true && saved.saved === rel, saved);
  const back = await jget("/api/file?path=" + encodeURIComponent(rel));
  ck("读回一致", back.ok === true && back.src === "int main() { return 42; }\n", back.error);
  const comp = await jpost("/api/compile", { src: back.src, path: rel });
  ck("切工作区后编译仍可用（退出码 42）", comp.ok === true && comp.exitCode === 42, comp.error || comp.exitCode);
  try { fs.unlinkSync(path.join(LAB, "test", "tmp", "ws_probe.fl")); } catch {}

  // ⑩ 非法工作区：不存在 / 不是文件夹
  let badWs = await jpost("/api/workspace", { path: LAB + "\\__nope__" });
  ck("不存在的文件夹被拒", badWs.ok === false && /不存在/.test(badWs.error || ""), badWs.error);
  badWs = await jpost("/api/workspace", { path: LAB + "\\PROGRESS.md" });   // 绝对路径指到一个文件
  ck("指到文件被拒", badWs.ok === false && /不是文件夹/.test(badWs.error || ""), badWs.error);
  badWs = await jpost("/api/workspace", { path: "PROGRESS.md" });           // 相对路径 = 相对「当前工作区」
  ck("相对路径按当前工作区解析（test 里没它 → 不存在）", badWs.ok === false && /不存在/.test(badWs.error || ""), badWs.error);
  badWs = await jpost("/api/workspace", { path: "   " });
  ck("空路径被拒", badWs.ok === false, badWs.error);

  // ⑪ 状态落盘 + 库速查跟着工作区
  // ⚠️ 默认工作区**不会**被塞进 recent（它另有「项目根」快捷入口）——recent 只记你手动切过的
  let state = null;
  try { state = JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { /* 无 */ }
  ck("工作区已落盘", state && state.workspace && state.workspace.toLowerCase() === (LAB + "\\test").toLowerCase(), state);
  ck("recent 记下手动切过的目录", state && (state.recent || []).some((r) => r.toLowerCase() === (LAB + "\\test").toLowerCase()), state && state.recent);
  const libs = await jget("/api/libs");
  ck("库速查回退到项目 lib（test 里没有 lib\\）", libs.ok === true && libs.dir.toLowerCase() === (LAB + "\\lib").toLowerCase(), libs.dir);

  // ⑫ 切回项目根，别把练习场留在 test 里
  set = await jpost("/api/workspace", { path: LAB });
  ck("切回项目根", set.ok === true && set.workspace.toLowerCase() === LAB.toLowerCase(), set);
  state = null;
  try { state = JSON.parse(fs.readFileSync(STATE, "utf8")); } catch { /* 无 */ }
  ck("切回后 recent 首位 = 项目根", state && (state.recent || [])[0] && state.recent[0].toLowerCase() === LAB.toLowerCase(), state && state.recent);

  console.log("----");
  console.log(`通过 ${pass} / 失败 ${fail}`);
  process.exit(fail > 0 ? 1 : 0);
})();
