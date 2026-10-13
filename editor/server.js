// server.js — FLINT Studio 后端（零 npm 依赖）
// v2（2026-09-09）：① 编译运行支持 stdin 输入 + 捕获程序 stdout（v1 只取退出码，print 看不到）
//                  ② 文件管理：列出 / 打开 / 保存 E:\FLINT 下的 .fl（限制在项目根内，防路径穿越）
//                  ③ 编译时把缓冲写到「被打开文件同目录」的临时 .fl —— 相对 include 才能解析
//                  ④ 仍返回 .text 机器码字节（自产 PE 反向验证）
//
// v4（2026-09-12）：**工作区** —— 文件不再锁死在项目根，可以切到任意文件夹：
//   ① 工作区状态：默认 = 项目根，切过之后落盘在 editor\tmp\workspace.json，重启记得住
//   ② 目录浏览接口 /api/dirs（**只列子目录名，不读任何文件内容**）+ /api/workspace 读写
//   ③ 文件树 / 打开 / 保存 / 编译全部相对「当前工作区」；**路径穿越防护不变**（只是根从常量变成动态的）
//   ④ /api/files?all=1 连非 .fl 一起列；打开非 .fl 也允许（工作区内 + ≤1MB + 非二进制）
//
// 启动：node server.js  →  http://127.0.0.1:8899   （或双击 启动FLINT Studio.bat）

"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const crypto = require("crypto");

const ROOT = __dirname;
const PROJ = path.resolve(ROOT, "..");                 // 默认工作区 = 项目根（E:\FLINT / E:\FLINT-lab）
const FLINT_EXE = path.join(PROJ, "flint.exe");
const TMP_DIR = path.join(ROOT, "tmp");
const PORT = process.env.PORT || 8899;
const RUN_TIMEOUT = 10000;                             // 程序运行上限（毫秒）
const MAX_OPEN_BYTES = 1024 * 1024;                    // 单文件打开上限（1MB；编辑器只开文本）

// ===== v4：工作区（可切到任意文件夹）=====
const WS_FILE = process.env.STUDIO_STATE || path.join(TMP_DIR, "workspace.json");
let WORKSPACE = PROJ;                                  // 当前工作区：所有相对路径的根
let RECENT = [];                                       // 最近用过的文件夹（去重，最多 8 个）

function isDir(p) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }

function loadWorkspace() {
  try {
    const j = JSON.parse(fs.readFileSync(WS_FILE, "utf8"));
    if (j.workspace && isDir(j.workspace)) WORKSPACE = path.resolve(j.workspace);
    if (Array.isArray(j.recent))
      RECENT = j.recent.filter((x) => typeof x === "string" && isDir(x)).slice(0, 8);
  } catch { /* 首次运行 / 文件损坏：就用默认项目根，不报错 */ }
}
function saveWorkspace() {
  try {
    fs.mkdirSync(path.dirname(WS_FILE), { recursive: true });
    fs.writeFileSync(WS_FILE, JSON.stringify({ workspace: WORKSPACE, recent: RECENT }, null, 2), "utf8");
  } catch { /* 落盘失败不影响本次会话，下次启动退回默认 */ }
}
function setWorkspace(abs) {
  WORKSPACE = path.resolve(abs);
  RECENT = [WORKSPACE, ...RECENT.filter((x) => x.toLowerCase() !== WORKSPACE.toLowerCase())].slice(0, 8);
  saveWorkspace();
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".ico": "image/x-icon",
};

function sendJson(res, code, obj) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

// 相对路径 → 绝对路径（必须落在「当前工作区」内；穿越防护不变，只是根是动态的）
function safePath(rel) {
  if (typeof rel !== "string" || !rel) return null;
  const p = path.resolve(WORKSPACE, rel);
  if (p !== WORKSPACE && !p.startsWith(WORKSPACE + path.sep)) return null;
  return p;
}
// .fl 专用（编译要按「被打开文件同目录」落临时文件，非 .fl 没意义）
function safeFlPath(rel) {
  const p = safePath(rel);
  if (!p || path.extname(p).toLowerCase() !== ".fl") return null;
  return p;
}

// —— 找一个可写的临时目录（优先「被打开文件同目录」，相对 include 才解析得对；
//     工作区只读时退回 editor\tmp —— 否则 writeFileSync 抛异常会把整个服务带崩）——
function pickTmpDir(prefer) {
  const cands = prefer && path.resolve(prefer) !== path.resolve(TMP_DIR) ? [prefer, TMP_DIR] : [TMP_DIR];
  for (const d of cands) {
    try { fs.mkdirSync(d, { recursive: true }); fs.accessSync(d, fs.constants.W_OK); return d; } catch { /* 试下一个 */ }
  }
  return null;
}

// —— 文件树：列出工作区下的 .fl（all=1 时所有文件），跳过噪音目录 ——
// v4.1（2026-09-12 用户反馈「tmp 咋读不到」）：噪音清单只留**真·机器生成**的目录。
// 原来把 tmp / backups 也当噪音藏了 —— 但工作区是用户自己选的，"你选哪儿就该看得见哪儿"；
// 藏起来还让人没法从选择器点进去（只能手打绝对路径），得不偿失。
// （entry 上限 2000 / 深度 8 仍在，node_modules 那种上万文件的仍跳过）
const SKIP_DIRS = new Set(["node_modules", "__pycache__"]);
function listFiles(dir, out, depth, all, root) {
  if (depth > 8 || out.length > 2000) return;
  let entries = [];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    if (e.name.startsWith(".")) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      listFiles(full, out, depth + 1, all, root);
    } else if (e.isFile()) {
      if (!all && !e.name.toLowerCase().endsWith(".fl")) continue;
      let st;
      try { st = fs.statSync(full); } catch { continue; }
      out.push({ rel: path.relative(root, full).replace(/\\/g, "/"), size: st.size, mtime: st.mtimeMs });
    }
  }
}

// —— v4：目录浏览（供工作区选择器用；**只列子目录名**，不读任何文件内容）——
function listDirs(dir) {
  const abs = path.resolve(dir);
  let entries = [];
  try { entries = fs.readdirSync(abs, { withFileTypes: true }); } catch { return null; }
  return entries
    .filter((e) => e.isDirectory() && !e.name.startsWith(".") && !SKIP_DIRS.has(e.name))
    .map((e) => ({ name: e.name, path: path.join(abs, e.name) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}
// 快捷入口：驱动器 + 主目录 + 项目根 + 最近用过
function quickRoots() {
  const out = [];
  for (let c = 65; c <= 90; c++) {
    const d = String.fromCharCode(c) + ":\\";
    if (isDir(d)) out.push({ name: d, path: d });
  }
  if (process.env.USERPROFILE && isDir(process.env.USERPROFILE))
    out.push({ name: "主目录", path: process.env.USERPROFILE });
  out.push({ name: "项目根", path: PROJ });
  for (const r of RECENT) out.push({ name: "最近", path: r });
  return out;
}

// —— PE：取 .text 原始字节 ——
function extractTextSection(exePath) {
  const b = fs.readFileSync(exePath);
  if (b.length < 0x40 || b[0] !== 0x4d || b[1] !== 0x5a) return { ok: false, err: "不是 MZ 头" };
  const peOff = b.readUInt32LE(0x3c);
  const nsec = b.readUInt16LE(peOff + 6);
  const optSize = b.readUInt16LE(peOff + 20);
  let secOff = peOff + 24 + optSize;
  for (let i = 0; i < nsec; i++) {
    const name = b.toString("ascii", secOff, secOff + 8).replace(/\0/g, "");
    if (name === ".text") {
      const virtSize = b.readUInt32LE(secOff + 8);        // VirtualSize（有效字节，对齐前）
      const rawSize = b.readUInt32LE(secOff + 16);
      const rawPtr = b.readUInt32LE(secOff + 20);
      const codeLen = Math.min(rawSize, b.length - rawPtr);
      return { ok: true, bytes: b.slice(rawPtr, rawPtr + codeLen), rawPtr, rawSize, virtSize };
    }
    secOff += 40;
  }
  return { ok: false, err: "未找到 .text 节" };
}

function bytesToHexRows(bytes) {
  // v4.2：16 字节/行 → 8 字节/行。右栏只有 365px，16 字节的 hex 串（47 字符）在里头要么折成两行
  // （原来就是，实测行高 41px = 2×19.2，"又挤又乱"），要么逼人横向滚；8 字节刚好一屏排下。
  // 总高度几乎不变（同样多的字节，只是行数翻倍）。
  const rows = [];
  for (let i = 0; i < bytes.length; i += 8) {
    const chunk = bytes.slice(i, i + 8);
    const hex = Array.from(chunk).map((x) => x.toString(16).padStart(2, "0")).join(" ");
    const ascii = Array.from(chunk).map((x) => (x >= 0x20 && x < 0x7f ? String.fromCharCode(x) : ".")).join("");
    rows.push({ off: i, hex, ascii });
  }
  return rows;
}

// node 在 Windows 报无符号退出码，负数要转回有符号
function signedCode(c) {
  if (typeof c !== "number") return null;
  return c > 0x7fffffff ? c - 0x100000000 : c;
}

// —— v3 ① 崩溃码翻译 —— 程序炸了只会看到 -1073741819 这种数，等于没信息
const CRASH_NAMES = {
  0xc0000005: "访问冲突（野指针 / 越界读写）",
  0xc00000fd: "栈溢出（递归太深 / 栈帧太大）",
  0xc0000094: "整数除零",
  0xc0000095: "整数溢出",
  0xc000001d: "非法指令",
  0xc0000374: "堆损坏",
  0xc0000409: "栈缓冲区溢出（/GS 检查失败）",
  0xc0000135: "找不到依赖 DLL",
  0xc0000139: "找不到入口点",
  0x80000003: "断点异常",
};
function exitName(code) {
  if (code === null || code === undefined) return null;
  if (code === 0) return "正常退出";
  const u = code >>> 0;
  if (code > 0 && code < 256) return "程序返回 " + code;
  const hit = CRASH_NAMES[u];
  return hit ? hit + "（0x" + u.toString(16).toUpperCase().padStart(8, "0") + "）" : null;
}

// —— v3 ② 报错定位：编译器文案是「第 N 行第 M 列」（tokenize.c verror_at）——
function parseLoc(text) {
  if (!text) return null;
  const m = String(text).match(/第\s*(\d+)\s*行(?:\s*第\s*(\d+)\s*列)?/);
  if (!m) return null;
  return { line: parseInt(m[1], 10), col: m[2] ? parseInt(m[2], 10) : null };
}

// —— v3 ③ 标准库速查：扫 lib\*.fl 的真实定义（原先前端是手写死表，加库不跟手）——
// v4：工作区里自带 lib\ 就用它（在别处的 FLINT 项目里也能查库），否则用项目根的 lib\
function libDir() {
  const w = path.join(WORKSPACE, "lib");
  return isDir(w) ? w : path.join(PROJ, "lib");
}
// 形如 `int std::itoa(int n, char *buf) {` / `struct Seg *std::foo(...)`
const LIB_FN_RE = /^\s*(?:int|char|void|double|struct\s+[A-Za-z_]\w*)\s*\*?\s*(std::[A-Za-z_]\w*)\s*\(/;
function scanLibs(dir) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return out; }
  names.filter((f) => f.toLowerCase().endsWith(".fl")).sort().forEach((f) => {
    const full = path.join(dir, f);
    let text = "";
    try { text = fs.readFileSync(full, "utf8"); } catch { return; }
    const fns = [];
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(LIB_FN_RE);
      if (m) fns.push({ name: m[1], sig: line.trim().replace(/\s*\{\s*$/, "").replace(/\s*:\s*$/, "") });
    }
    if (fns.length) out.push({ lib: f, count: fns.length, fns });
  });
  return out;
}

// —— v3 ④ 反汇编（objdump；缺了就不给，不报错）——
const OBJDUMP = process.env.OBJDUMP || "E:\\mingw64\\bin\\objdump.exe";
function disassemble(exePath) {
  if (!fs.existsSync(OBJDUMP)) return null;
  try {
    const out = execFileSync(OBJDUMP, ["-d", "-M", "intel", exePath], {
      encoding: "utf8", timeout: 10000, maxBuffer: 4 * 1024 * 1024,
    });
    return (out || "").trim() || null;
  } catch { return null; }
}

// —— /api/compile ——
function handleCompile(res, body) {
  let src = "", stdin = "", openPath = "";
  try {
    const j = JSON.parse(body);
    src = j.src || "";
    stdin = j.stdin || "";
    openPath = j.path || "";
  } catch { /* 忽略 */ }

  if (!src.trim()) return sendJson(res, 400, { ok: false, error: "源码为空" });
  if (!fs.existsSync(FLINT_EXE)) return sendJson(res, 500, { ok: false, error: "找不到 flint.exe（期望 " + FLINT_EXE + "）" });

  // 临时源码放在「被打开文件同目录」（相对 include 才能解析）；未打开文件则用 editor/tmp
  // v4：工作区只读时自动退回 editor\tmp（退一步只影响相对 include，不能让服务崩）
  const opened = safeFlPath(openPath);
  const tmpDir = pickTmpDir(opened ? path.dirname(opened) : TMP_DIR);
  if (!tmpDir) return sendJson(res, 500, { ok: false, error: "找不到可写的临时目录（editor\\tmp 也不可写？）" });
  const id = crypto.randomBytes(4).toString("hex");
  const flPath = path.join(tmpDir, `.studio_${id}.fl`);
  const exePath = path.join(tmpDir, `.studio_${id}.exe`);
  fs.writeFileSync(flPath, src, "utf8");

  const t0 = Date.now();
  const result = {
    ok: false, compileLog: "", error: null, stdout: "", stderr: "",
    exitCode: null, exitName: null, exeSize: null, codeRows: [], textInfo: null,
    disasm: null, loc: null, ms: 0,
  };

  // ① 编译
  let compileOk = false;
  try {
    const out = execFileSync(FLINT_EXE, [flPath, "-o", exePath], { encoding: "utf8", timeout: 20000 });
    result.compileLog = (out || "").trim();
    compileOk = fs.existsSync(exePath);
  } catch (e) {
    result.compileLog = ((e.stderr || "") + (e.stdout || "") || e.message || "").toString().trim();
    compileOk = false;
  }

  if (!compileOk) {
    result.error = result.compileLog || "编译失败";
    result.loc = parseLoc(result.error);          // v3：行 + 列都给前端，标红定位才准
    result.ms = Date.now() - t0;
    try { fs.unlinkSync(flPath); } catch {}
    try { fs.unlinkSync(exePath); } catch {}
    return sendJson(res, 200, result);
  }

  // ② 运行（带 stdin；捕获 stdout/stderr；cwd = 临时目录，程序写的文件不污染项目）
  result.ok = true;
  try {
    const out = execFileSync(exePath, [], { input: stdin, timeout: RUN_TIMEOUT, encoding: "utf8", maxBuffer: 8 * 1024 * 1024, cwd: tmpDir });
    result.stdout = out || "";
    result.exitCode = 0;
  } catch (e) {
    result.stdout = (e.stdout || "").toString();
    result.stderr = (e.stderr || "").toString();
    if (e.status !== undefined && e.status !== null) result.exitCode = signedCode(e.status);
    else if (e.signal) result.error = "运行超时或被杀（" + e.signal + "）";
    else result.error = (e.message || "").toString();
  }

  // ③ 产物信息 + .text + 反汇编
  result.exitName = exitName(result.exitCode);            // v3：把 -1073741819 翻成人话
  try {
    result.exeSize = fs.statSync(exePath).size;
    result.disasm = disassemble(exePath);                 // v3：objdump（必须在删 exe 之前）
    const sec = extractTextSection(exePath);
    if (sec.ok) {
      result.textInfo = { rawPtr: sec.rawPtr, rawSize: sec.rawSize, virtualSize: sec.virtSize, codeLen: sec.bytes.length };
      result.codeRows = bytesToHexRows(sec.bytes);
    } else {
      result.error = (result.error ? result.error + " | " : "") + "PE 解析: " + sec.err;
    }
  } catch (e) {
    result.error = (result.error ? result.error + " | " : "") + "读产物失败: " + e.message;
  }

  result.ms = Date.now() - t0;
  try { fs.unlinkSync(flPath); } catch {}
  try { fs.unlinkSync(exePath); } catch {}
  sendJson(res, 200, result);
}

// —— HTTP ——
const server = http.createServer((req, res) => {
  const urlPath = (req.url || "/").split("?")[0];
  const q = new URL(req.url || "/", "http://127.0.0.1");
  let body = "";

  const collect = (cb) => {
    req.on("data", (c) => { body += c; if (body.length > 4e6) req.destroy(); });
    req.on("end", () => cb());
  };

  if (urlPath === "/api/health") {
    return sendJson(res, 200, {
      ok: true, flint: fs.existsSync(FLINT_EXE), proj: PROJ,
      workspace: WORKSPACE, libDir: libDir(), v: 4,
    });
  }

  if (urlPath === "/api/libs") {
    const d = libDir();
    return sendJson(res, 200, { ok: true, dir: d, libs: scanLibs(d) });
  }

  // ===== v4：工作区读写 =====
  if (urlPath === "/api/workspace" && req.method === "GET") {
    return sendJson(res, 200, { ok: true, workspace: WORKSPACE, default: PROJ, recent: RECENT });
  }
  if (urlPath === "/api/workspace" && req.method === "POST") {
    return collect(() => {
      let want = "";
      try { want = String(JSON.parse(body).path || "").trim(); } catch { /* 空 */ }
      if (!want) return sendJson(res, 200, { ok: false, error: "路径为空" });
      const abs = path.resolve(WORKSPACE, want);          // 相对路径按当前工作区解析
      if (!fs.existsSync(abs)) return sendJson(res, 200, { ok: false, error: "这个路径不存在：" + abs });
      if (!isDir(abs)) return sendJson(res, 200, { ok: false, error: "这不是文件夹：" + abs });
      setWorkspace(abs);
      const out = [];
      listFiles(WORKSPACE, out, 0, false, WORKSPACE);
      return sendJson(res, 200, { ok: true, workspace: WORKSPACE, recent: RECENT, flCount: out.length });
    });
  }
  // 目录浏览（选择器用）：只列子目录名
  if (urlPath === "/api/dirs") {
    const abs = path.resolve(WORKSPACE, q.searchParams.get("path") || WORKSPACE);
    const dirs = listDirs(abs);
    if (!dirs)
      return sendJson(res, 200, { ok: false, error: "读不到这个文件夹：" + abs, path: abs, dirs: [], roots: quickRoots() });
    const parent = path.dirname(abs);
    return sendJson(res, 200, {
      ok: true, path: abs, parent: parent === abs ? null : parent, dirs, roots: quickRoots(),
    });
  }

  if (urlPath === "/api/files") {
    const all = q.searchParams.get("all") === "1";
    const out = [];
    listFiles(WORKSPACE, out, 0, all, WORKSPACE);
    out.sort((a, b) => a.rel.localeCompare(b.rel));
    return sendJson(res, 200, { ok: true, root: WORKSPACE, all, files: out });
  }

  if (urlPath === "/api/file" && req.method === "GET") {
    const p = safePath(q.searchParams.get("path"));
    if (!p) return sendJson(res, 400, { ok: false, error: "非法路径（必须落在当前工作区内）" });
    try {
      const st = fs.statSync(p);
      if (st.isDirectory()) return sendJson(res, 200, { ok: false, error: "这是个文件夹，不是文件" });
      if (st.size > MAX_OPEN_BYTES)
        return sendJson(res, 200, { ok: false, error: "文件太大（" + Math.round(st.size / 1024) + "KB > 1024KB）——编辑器只开文本文件" });
      const buf = fs.readFileSync(p);
      if (buf.includes(0)) return sendJson(res, 200, { ok: false, error: "看着是二进制文件（含 NUL 字节），不打开" });
      return sendJson(res, 200, {
        ok: true, src: buf.toString("utf8"), size: st.size,
        rel: path.relative(WORKSPACE, p).replace(/\\/g, "/"),
      });
    } catch (e) {
      return sendJson(res, 200, { ok: false, error: "读不到: " + e.message });
    }
  }

  if (urlPath === "/api/save" && req.method === "POST") {
    return collect(() => {
      let rel = "", src = "";
      try { const j = JSON.parse(body); rel = j.path || ""; src = j.src || ""; } catch {}
      const p = safePath(rel);
      if (!p) return sendJson(res, 400, { ok: false, error: "非法路径（必须落在当前工作区内）" });
      try {
        fs.mkdirSync(path.dirname(p), { recursive: true });
        fs.writeFileSync(p, src, "utf8");
        return sendJson(res, 200, { ok: true, saved: path.relative(WORKSPACE, p).replace(/\\/g, "/"), size: Buffer.byteLength(src, "utf8") });
      } catch (e) {
        return sendJson(res, 200, { ok: false, error: "写入失败: " + e.message });
      }
    });
  }

  if (urlPath === "/api/compile" && req.method === "POST") {
    return collect(() => handleCompile(res, body));
  }

  // 静态文件
  const rel = urlPath === "/" ? "index.html" : urlPath.replace(/^\/+/, "");
  const filePath = path.resolve(ROOT, rel);
  if (!filePath.startsWith(ROOT)) { res.writeHead(403); return res.end("403"); }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); return res.end("404"); }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(filePath).toLowerCase()] || "application/octet-stream",
      // v4.3：不缓存前端文件 —— 改完一刷新就是新的（省得"我改了但你看的还是旧的"这种扯皮）
      "Cache-Control": "no-store, must-revalidate",
    });
    res.end(data);
  });
});

loadWorkspace();

server.listen(PORT, "127.0.0.1", () => {
  console.log("==============================================");
  console.log("  FLINT Studio v4 · 专用编辑器");
  console.log("  http://127.0.0.1:" + PORT);
  console.log("  项目根: " + PROJ);
  console.log("  工作区: " + WORKSPACE + (WORKSPACE === PROJ ? "（默认=项目根）" : ""));
  console.log("  flint.exe: " + (fs.existsSync(FLINT_EXE) ? "✅ 就绪" : "❌ 缺失"));
  console.log("  Ctrl+C 退出");
  console.log("==============================================");
});
