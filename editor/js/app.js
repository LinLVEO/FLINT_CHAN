// app.js — FLINT Studio 前端（零依赖）
// v2（2026-09-09）：全语言高亮 / 文件打开保存 / stdin / stdout / 错误行定位 / 库速查 / 状态栏
// v3（2026-09-12）：① 撤销栈保护（编辑走 execCommand，不再 code.value= 抹掉 Ctrl+Z）
//                  ② Tab 多行缩进 / Shift+Tab 退格 / Ctrl+/ 行注释
//                  ③ 未保存标记 + 切文件确认 + 关页面拦截
//                  ④ 查找替换（Ctrl+F）
//                  ⑤ 侧栏可搜索文件树（原来 200+ 个 .fl 挤在下拉框）
//                  ⑥ 高亮跟上 v1.1.0：double 关键字 + 浮点字面量
//                  ⑦ 错误定位到「列」；退出码翻人话；反汇编页签；库速查改为扫 lib\*.fl
// v4（2026-09-12）：**工作区**——左栏顶部显示/切换工作区，可浏览并选任意文件夹；
//                  文件树随工作区变化，可选「全部文件（含非 .fl）」；选择器为服务端列目录
//                  （浏览器拿不到本地绝对路径，只能这么干）
"use strict";

const $ = (s) => document.querySelector(s);
const code = $("#code");
const hl = $("#hl");
const gutter = $("#gutter");
const stdinBox = $("#stdin");
const statEl = $("#stat");
const fileNameEl = $("#fileName");

// ============ 词法高亮（关键字对齐 parse.c is_keyword） ============
// v3：补上 v1.1.0 的 double（编译器 parse.c:101 已加，编辑器漏了同步）
const KEYWORDS = new Set([
  "int", "char", "void", "return", "if", "else", "while", "for",
  "new", "own", "share", "ptr", "struct", "api", "include", "print", "double",
]);
// 标准库函数名集合：v3 起由后端扫 lib\*.fl 生成（原先是这里手写的死表，加库不跟手）
const STDLIB_NAMES = new Set();

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const isIdStart = (c) => /[A-Za-z_]/.test(c);
const isIdChar = (c) => /[A-Za-z0-9_]/.test(c);
const isDigit = (c) => /[0-9]/.test(c);

function highlight(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === "\n") { out += "\n"; i++; continue; }
    if (c === " " || c === "\t") { out += c; i++; continue; }
    // 行注释
    if (c === "/" && src[i + 1] === "/") {
      let j = i; while (j < n && src[j] !== "\n") j++;
      out += `<span class="tk-com">${esc(src.slice(i, j))}</span>`; i = j; continue;
    }
    // 块注释
    if (c === "/" && src[i + 1] === "*") {
      let j = i + 2; while (j < n && !(src[j] === "*" && src[j + 1] === "/")) j++;
      j = Math.min(n, j + 2);
      out += `<span class="tk-com">${esc(src.slice(i, j))}</span>`; i = j; continue;
    }
    // 字符串
    if (c === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') { if (src[j] === "\\") j++; j++; }
      j = Math.min(n, j + 1);
      out += `<span class="tk-str">${esc(src.slice(i, j))}</span>`; i = j; continue;
    }
    // 字符
    if (c === "'") {
      let j = i + 1;
      while (j < n && src[j] !== "'") { if (src[j] === "\\") j++; j++; }
      j = Math.min(n, j + 1);
      out += `<span class="tk-chr">${esc(src.slice(i, j))}</span>`; i = j; continue;
    }
    // 数字（十进制 / 0x / 浮点）
    if (isDigit(c)) {
      let j = i;
      if (c === "0" && (src[i + 1] === "x" || src[i + 1] === "X")) {
        j = i + 2; while (j < n && /[0-9a-fA-F]/.test(src[j])) j++;
      } else {
        while (j < n && isDigit(src[j])) j++;
        // v3：浮点三种形态，对齐 tokenize.c v1.1.0——3.14 / 1e5 / 3.14e-2
        //     （点后必须是数字，否则是字段访问 a.b，不能吞）
        if (src[j] === "." && isDigit(src[j + 1])) { j++; while (j < n && isDigit(src[j])) j++; }
        if (src[j] === "e" || src[j] === "E") {
          let k = j + 1;
          if (src[k] === "+" || src[k] === "-") k++;
          if (isDigit(src[k])) { j = k; while (j < n && isDigit(src[j])) j++; }
        }
      }
      out += `<span class="tk-num">${esc(src.slice(i, j))}</span>`; i = j; continue;
    }
    // 标识符（含 :: 限定段，与编译器 tokenize 一致）
    if (isIdStart(c)) {
      let j = i;
      while (j < n && isIdChar(src[j])) j++;
      while (src[j] === ":" && src[j + 1] === ":" && j + 2 < n && isIdStart(src[j + 2])) {
        j += 2; while (j < n && isIdChar(src[j])) j++;
      }
      const word = src.slice(i, j);
      let cls = "";
      if (word.startsWith("std::")) {
        cls = STDLIB_NAMES.has(word.slice(5)) ? "tk-fn" : "tk-ns";
      } else if (KEYWORDS.has(word)) {
        cls = "tk-kw";
      } else if (/^[A-Z]/.test(word)) {
        cls = "tk-type";
      } else if (/^\s*\(/.test(src.slice(j))) {
        cls = "tk-call";
      }
      out += cls ? `<span class="${cls}">${esc(word)}</span>` : esc(word);
      i = j; continue;
    }
    if ("+-*/%=<>!&|^~?:;,.(){}[]".includes(c)) {
      out += `<span class="tk-op">${esc(c)}</span>`; i++; continue;
    }
    out += esc(c); i++;
  }
  return out;
}

// ============ 渲染：高亮 + 行号 + 错误行 ============
let errorLine = -1;
function render() {
  hl.innerHTML = highlight(code.value) + "\n";
  renderGutter();
  syncScroll();
  updateStat();
}
function renderGutter() {
  const lines = code.value.split("\n").length;
  let html = "";
  for (let i = 1; i <= lines; i++) html += `<div class="ln${i === errorLine ? " ln-err" : ""}">${i}</div>`;
  gutter.innerHTML = html;
}
function syncScroll() {
  hl.scrollTop = code.scrollTop;
  hl.scrollLeft = code.scrollLeft;
  gutter.scrollTop = code.scrollTop;
}
function updateStat() {
  const v = code.value;
  const pos = code.selectionStart;
  const line = v.slice(0, pos).split("\n").length;
  const col = pos - (v.lastIndexOf("\n", pos - 1) + 1) + 1;
  statEl.textContent = `行 ${line}, 列 ${col} · ${v.length} 字符${dirty ? " · 未保存" : ""}`;
}

code.addEventListener("input", () => { errorLine = -1; setDirty(true); render(); });
code.addEventListener("scroll", syncScroll);
code.addEventListener("click", updateStat);
code.addEventListener("keyup", updateStat);
code.addEventListener("select", updateStat);

// 滚轮：光标落在行号栏（或代码区任何非 textarea 处）时，把滚动转给 #code
// —— 行号栏 overflow:hidden 不可滚，事件冒泡到 body 就丢了，必须手动转发
$(".code-area").addEventListener("wheel", (e) => {
  if (e.target === code) return;                 // 在文本区上：用浏览器原生滚动
  e.preventDefault();
  const unit = e.deltaMode === 1 ? 17 : e.deltaMode === 2 ? code.clientHeight : 1; // 行/页/像素
  code.scrollTop += e.deltaY * unit;
  code.scrollLeft += e.deltaX * unit;
  syncScroll();
}, { passive: false });

// ============ v3：编辑原语（撤销栈安全） ============
// 关键：直接 `code.value = ...` 会让浏览器**清空撤销栈** → Ctrl+Z 失效。
// 走 document.execCommand 让浏览器把这次编辑记进它自己的撤销栈（textarea 上仍受支持）。
function editRange(start, end, text) {
  code.focus();
  code.selectionStart = start;
  code.selectionEnd = end;
  let ok = false;
  try {
    ok = text === "" ? document.execCommand("delete") : document.execCommand("insertText", false, text);
  } catch { ok = false; }
  if (!ok) {                                   // 兜底：execCommand 万一不可用，退回直接改写
    const v = code.value;
    code.value = v.slice(0, start) + text + v.slice(end);
    code.selectionStart = code.selectionEnd = start + text.length;
    setDirty(true);
    render();
  } else {
    code.selectionStart = code.selectionEnd = start + text.length;
  }
  return ok;
}
// 替换全文（打开文件/示例/新建用；这些是"换文档"不是"编辑"，清撤销栈是合理的）
function setDocument(text) {
  code.value = text;
  code.selectionStart = code.selectionEnd = 0;
  errorLine = -1;
  setDirty(false);
  render();
}

function lineStartAt(pos) {
  return code.value.lastIndexOf("\n", pos - 1) + 1;
}
function lineEndAt(pos) {
  const e = code.value.indexOf("\n", pos);
  return e === -1 ? code.value.length : e;
}
function currentIndent() {
  const v = code.value, s = code.selectionStart;
  const m = v.slice(lineStartAt(s), s).match(/^[ \t]*/);
  return m ? m[0].length : 0;
}
function nextNonSpaceIdx() {
  const v = code.value, s = code.selectionStart;
  let j = s;
  while (j < v.length && /\s/.test(v[j])) j++;
  return j < v.length ? j : -1;
}
function insertText(text, caretOffset) {
  const s = code.selectionStart, e = code.selectionEnd;
  const pos = s + (caretOffset === undefined ? text.length : caretOffset);
  editRange(s, e, text);
  code.selectionStart = code.selectionEnd = pos;
  updateStat();
}
const indentStr = (n) => " ".repeat(n);
const OPEN_CLOSE = { "(": ")", "[": "]", "{": "}" };

// —— v3：多行缩进 / 退格（原来 Tab 会把选中的内容整段删掉换成两个空格）——
function selectedLineRange() {
  const s = code.selectionStart, e = code.selectionEnd;
  return { start: lineStartAt(s), end: lineEndAt(e === s ? s : e) };
}
function indentSelection() {
  const { start, end } = selectedLineRange();
  const block = code.value.slice(start, end);
  const lines = block.split("\n");
  const next = lines.map((l) => (l.length ? "  " + l : l)).join("\n");
  const delta = next.length - block.length;
  const s0 = code.selectionStart, e0 = code.selectionEnd;
  editRange(start, end, next);
  code.selectionStart = s0 + (lines[0].length ? 2 : 0);
  code.selectionEnd = e0 + delta;
  return lines.length;
}
function outdentSelection() {
  const { start, end } = selectedLineRange();
  const block = code.value.slice(start, end);
  const lines = block.split("\n");
  let removed = 0, firstRemoved = 0;
  const next = lines.map((l, idx) => {
    const m = l.match(/^ {1,2}|^\t/);
    if (!m) return l;
    removed += m[0].length;
    if (idx === 0) firstRemoved = m[0].length;
    return l.slice(m[0].length);
  }).join("\n");
  if (!removed) return 0;
  const s0 = code.selectionStart, e0 = code.selectionEnd;
  editRange(start, end, next);
  code.selectionStart = Math.max(start, s0 - firstRemoved);
  code.selectionEnd = Math.max(code.selectionStart, e0 - removed);
  return 1;
}
// —— v3：Ctrl+/ 行注释开关 ——
function toggleComment() {
  const { start, end } = selectedLineRange();
  const block = code.value.slice(start, end);
  const lines = block.split("\n");
  const allCommented = lines.every((l) => l.trim() === "" || /^\s*\/\//.test(l));
  const next = lines.map((l) => {
    if (l.trim() === "") return l;
    return allCommented ? l.replace(/^(\s*)\/\/ ?/, "$1") : l.replace(/^(\s*)/, "$1// ");
  }).join("\n");
  const s0 = code.selectionStart, e0 = code.selectionEnd;
  editRange(start, end, next);
  code.selectionEnd = e0 + (next.length - block.length);
  code.selectionStart = Math.min(s0, code.selectionEnd);
}

code.addEventListener("keydown", (e) => {
  if (e.key === "Tab") {
    e.preventDefault();                                  // v3：选中多行 → 整块缩进 / 退格
    if (e.shiftKey) outdentSelection(); else indentSelection();
    updateStat();
    return;
  }
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); compile(); return; }
  if ((e.key === "s" || e.key === "S") && (e.ctrlKey || e.metaKey)) { e.preventDefault(); saveFile(); return; }
  if ((e.key === "/" && (e.ctrlKey || e.metaKey))) { e.preventDefault(); toggleComment(); return; }
  if (e.ctrlKey || e.altKey || e.metaKey) return;

  if (e.key === "Enter") {
    e.preventDefault();
    const base = currentIndent();
    const prefix = code.value.slice(lineStartAt(code.selectionStart), code.selectionStart).replace(/\s+$/, "");
    let next = base;
    if (prefix.endsWith("{")) next = base + 2;
    else if (prefix.endsWith("}") || prefix.endsWith(")")) next = Math.max(0, base - 2);
    insertText("\n" + indentStr(next));
    return;
  }

  if ([")", "]", "}"].includes(e.key)) {
    const j = nextNonSpaceIdx();
    if (j !== -1 && code.value[j] === e.key) {
      e.preventDefault();
      const prefix = code.value.slice(lineStartAt(code.selectionStart), code.selectionStart);
      if (prefix.trim() === "" && e.key === "}") {
        // 该行只有自动补的 '}'：把缩进收掉（原来靠重写全文，现在走 editRange 保撤销栈）
        const ls = lineStartAt(code.selectionStart);
        editRange(ls, j, "");
        code.selectionStart = code.selectionEnd = ls;
      } else {
        code.selectionStart = code.selectionEnd = j + 1;
        code.selectionEnd = j + 1;
        updateStat();
      }
      return;
    }
  }
  if (OPEN_CLOSE[e.key]) {
    e.preventDefault();
    const close = OPEN_CLOSE[e.key];
    if (e.key === "{") {
      const base = currentIndent();
      insertText("{\n" + indentStr(base + 2) + "\n" + indentStr(base) + "}", 1 + base + 2);
    } else {
      insertText(e.key + close, 1);
    }
  }
});

// ============ v3：未保存状态 ============
let dirty = false;
function setDirty(v) {
  dirty = v;
  $("#dirtyDot").className = "dot" + (v ? "" : " clean");
  $("#dirtyDot").title = v ? "有未保存的改动" : "已保存";
  document.title = (v ? "● " : "") + "FLINT Studio v4 · 专用编辑器";
}
// 关页面/刷新时拦一下（有未保存改动才拦）
window.addEventListener("beforeunload", (e) => {
  if (!dirty) return;
  e.preventDefault();
  e.returnValue = "";
});
// 切文件/新建/换示例前确认
function confirmDiscard() {
  if (!dirty) return true;
  return window.confirm("当前文件有未保存的改动，确定丢弃吗？");
}

// ============ 编译运行 ============
let currentPath = "";

async function compile() {
  const btn = $("#compileBtn");
  btn.disabled = true;
  btn.textContent = "⏳ 编译中";
  try {
    const res = await fetch("/api/compile", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ src: code.value, stdin: stdinBox.value, path: currentPath }),
    });
    showResult(await res.json());
  } catch (err) {
    showResult({ ok: false, error: "请求失败: " + err.message });
  } finally {
    btn.disabled = false;
    btn.textContent = "▶ 编译运行";
  }
}

function showResult(data) {
  const outBody = $("#tabOut");
  const logBody = $("#tabLog");
  const hexBody = $("#tabHex");
  const disBody = $("#tabDis");

  if (data.ok) {
    const parts = [];
    // v3：退出码 + 人话（原来只看得到 -1073741819 这种数字）
    let exitTxt = `<b class="${data.exitCode === 0 ? "good" : "bad"}">${data.exitCode}</b>`;
    if (data.exitName) {
      const isCrash = /0x[0-9A-F]{8}/.test(data.exitName);
      exitTxt += ` <span class="exit-name${isCrash ? " crash" : ""}">— ${esc(data.exitName)}</span>`;
    }
    parts.push(`<div class="meta">退出码 ${exitTxt}` +
      ` · exe ${data.exeSize} 字节 · 编译+运行 ${data.ms}ms</div>`);
    if (data.stdout) parts.push(`<pre class="out">${esc(data.stdout)}</pre>`);
    else parts.push(`<div class="placeholder">（程序没有输出；print 的内容会显示在这里）</div>`);
    if (data.stderr) parts.push(`<div class="meta bad">stderr</div><pre class="out">${esc(data.stderr)}</pre>`);
    if (data.error) parts.push(`<div class="meta bad">${esc(data.error)}</div>`);
    outBody.innerHTML = parts.join("");
  } else {
    outBody.innerHTML = `<div class="meta bad">编译失败</div><pre class="out">${esc(data.error || "未知错误")}</pre>`;
  }

  const logLines = [];
  if (data.compileLog) logLines.push(esc(data.compileLog));
  if (data.loc) logLines.push(`定位：第 ${data.loc.line} 行${data.loc.col ? " 第 " + data.loc.col + " 列" : ""}`);
  if (data.textInfo) {
    const ti = data.textInfo;
    logLines.push(`.text: rawPtr=${ti.rawPtr} rawSize=${ti.rawSize} 有效 ${ti.codeLen} 字节`);
    // v4.2：把「产物为啥老是 1024 字节」当场算给用户看（PE 文件对齐，不是程序都一样大）
    if (data.exeSize) {
      const virt = ti.virtualSize != null ? ti.virtualSize : ti.codeLen;
      const aligned = Math.max(0x200, Math.ceil(virt / 0x200) * 0x200);
      logLines.push(`产物 ${data.exeSize} 字节 = 头 0x200(512) + .text 对齐后 ${aligned}`
        + `（.text 有效 ${virt} 字节 → 按 FileAlignment 0x200 向上取整）`);
      if (data.exeSize === 1024)
        logLines.push(`→ 代码 ≤ 512 字节时，对齐后恒为 512 → 产物恒为 1024 字节（不是"程序都一样大"）`);
    }
  }
  logBody.innerHTML = logLines.length ? `<pre class="out">${logLines.join("\n")}</pre>` : `<div class="placeholder">无编译日志</div>`;

  if (data.codeRows && data.codeRows.length) {
    hexBody.innerHTML = `<div class="tab-note">共 ${data.codeRows.length} 行 × 8 字节（.text 原始字节，未反汇编）`
      + ` · 点右上角 ⤢ 放大看</div>`
      + `<table class="hex"><tbody>` + data.codeRows.map((r) =>
        `<tr><td class="ad">${r.off.toString(16).padStart(6, "0")}</td><td class="hx">${r.hex}</td><td class="as">${esc(r.ascii)}</td></tr>`
      ).join("") + `</tbody></table>`;
  } else {
    hexBody.innerHTML = `<div class="placeholder">没有机器码（编译失败或未取到 .text）</div>`;
  }

  // v4.3：反汇编页签（objdump -d -M intel）——右栏窄，先给行数交代，再让人 ⤢ 放大看
  if (data.disasm) {
    const nLines = data.disasm.split("\n").length;
    disBody.innerHTML = `<div class="tab-note">共 ${nLines} 行（objdump -d）· 前面是你的程序代码，`
      + `尾段是数据区被顺带解出来的（FLINT 把导入表字符串放在 .text 里）· 点 ⤢ 放大看</div>`
      + `<pre class="dis">${esc(data.disasm)}</pre>`;
  } else {
    disBody.innerHTML = `<div class="placeholder">没有反汇编（编译失败，或找不到 objdump）</div>`;
  }

  // v3：定位优先用后端给的「行 + 列」
  if (!data.ok && data.loc) {
    errorLine = data.loc.line;
    renderGutter();
    jumpToLine(data.loc.line, data.loc.col);
    switchTab("log");
  } else if (!data.ok) {
    errorLine = -1;
    renderGutter();
    switchTab("log");
  } else {
    errorLine = -1;
    renderGutter();
    switchTab("out");
  }
}

// 跳到「行 + 列」（列号让光标真的落在出错的字符上，不再只跳到行首）
function jumpToLine(line, col) {
  const lines = code.value.split("\n");
  if (line < 1 || line > lines.length) return;
  let pos = 0;
  for (let i = 0; i < line - 1; i++) pos += lines[i].length + 1;
  pos += Math.max(0, (col || 1) - 1);
  pos = Math.min(pos, code.value.length);
  code.focus();
  code.selectionStart = code.selectionEnd = pos;
  const lineHeight = parseFloat(getComputedStyle(code).lineHeight) || 20;
  code.scrollTop = Math.max(0, (line - 3) * lineHeight);
  syncScroll();
  updateStat();
}

// ============ 标签页 ============
const TAB_IDS = { out: "#tabOut", log: "#tabLog", hex: "#tabHex", dis: "#tabDis" };
let curTab = "out";                       // v4.2：全屏查看要知道"当前在看哪个页签"
function switchTab(name) {
  curTab = name;
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === name));
  for (const [k, sel] of Object.entries(TAB_IDS)) $(sel).classList.toggle("hidden", k !== name);
}
document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => switchTab(t.dataset.tab)));

// ============ v3：查找 / 替换（Ctrl+F） ============
let findIdx = 0;
const findbar = $("#findbar");
const findInput = $("#findInput");
const replaceInput = $("#replaceInput");

function findMatches() {
  const q = findInput.value;
  if (!q) return [];
  const v = code.value;
  const hits = [];
  let at = v.indexOf(q);
  while (at !== -1 && hits.length < 5000) { hits.push(at); at = v.indexOf(q, at + q.length); }
  return hits;
}
function updateFindCount() {
  const hits = findMatches();
  const el = $("#findCount");
  if (!hits.length) { el.textContent = findInput.value ? "无匹配" : "0/0"; return; }
  const cur = hits.findIndex((p) => p === code.selectionStart);
  el.textContent = (cur >= 0 ? cur + 1 : "—") + "/" + hits.length;
}
function findNext(dir) {
  const q = findInput.value;
  if (!q) return;
  const hits = findMatches();
  if (!hits.length) { updateFindCount(); return; }
  const from = code.selectionStart;
  let target;
  if (dir > 0) target = hits.find((p) => p > from);
  else target = [...hits].reverse().find((p) => p < from);
  if (target === undefined) target = dir > 0 ? hits[0] : hits[hits.length - 1];
  const line = code.value.slice(0, target).split("\n").length;
  jumpToLine(line, target - lineStartAt(target) + 1);
  code.selectionStart = target;
  code.selectionEnd = target + q.length;
  updateFindCount();
}
function replaceOne() {
  const q = findInput.value;
  if (!q) return;
  const s = code.selectionStart, e = code.selectionEnd;
  if (code.value.slice(s, e) !== q) { findNext(1); return; }
  const rep = replaceInput.value;
  editRange(s, e, rep);
  code.selectionStart = code.selectionEnd = s + rep.length;
  findNext(1);
  updateFindCount();
}
function replaceAll() {
  const q = findInput.value;
  if (!q) return;
  const hits = findMatches();
  if (!hits.length) return;
  const v = code.value;
  let out = "", last = 0;
  for (const p of hits) { out += v.slice(last, p) + replaceInput.value; last = p + q.length; }
  out += v.slice(last);
  editRange(0, v.length, out);           // 一次编辑 = 一次撤销
  updateFindCount();
}
function openFind() {
  findbar.classList.remove("hidden");
  findInput.focus();
  findInput.select();
  updateFindCount();
}
function closeFind() {
  findbar.classList.add("hidden");
  code.focus();
}
$("#findNext").addEventListener("click", () => findNext(1));
$("#findPrev").addEventListener("click", () => findNext(-1));
$("#findClose").addEventListener("click", closeFind);
$("#replaceOneBtn").addEventListener("click", replaceOne);
$("#replaceAllBtn").addEventListener("click", replaceAll);
findInput.addEventListener("input", () => { findIdx = 0; updateFindCount(); });
findInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); findNext(e.shiftKey ? -1 : 1); }
  if (e.key === "Escape") { e.preventDefault(); closeFind(); }
});
replaceInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); replaceOne(); }
  if (e.key === "Escape") { e.preventDefault(); closeFind(); }
});
document.addEventListener("keydown", (e) => {
  if ((e.key === "f" || e.key === "F") && (e.ctrlKey || e.metaKey)) { e.preventDefault(); openFind(); }
  else if (e.key === "Escape" && !findbar.classList.contains("hidden")) { closeFind(); }
});

// ============ v3：侧栏文件树（可搜索） ============
let allFiles = [];
function renderFileTree() {
  const box = $("#fileTree");
  const q = $("#fileFilter").value.trim().toLowerCase();
  const list = q ? allFiles.filter((f) => f.rel.toLowerCase().includes(q)) : allFiles;
  $("#filesCount").textContent = q ? `${list.length}/${allFiles.length}` : String(allFiles.length);
  if (!list.length) { box.innerHTML = `<div class="file-empty">没有匹配的文件</div>`; return; }
  box.innerHTML = list.map((f) => {
    const i = f.rel.lastIndexOf("/");
    const dir = i === -1 ? "" : f.rel.slice(0, i + 1);
    const base = i === -1 ? f.rel : f.rel.slice(i + 1);
    const cls = "file-item" + (f.rel === currentPath ? " active" : "");
    return `<div class="${cls}" data-rel="${esc(f.rel)}" title="${esc(f.rel)} · ${f.size}B">` +
           `<span class="fp-dir">${esc(dir)}</span><span class="fp-name">${esc(base)}</span></div>`;
  }).join("");
}
$("#fileFilter").addEventListener("input", renderFileTree);
$("#fileTree").addEventListener("click", (e) => {
  const item = e.target.closest(".file-item");
  if (!item) return;
  openFile(item.dataset.rel);
});

async function loadFileTree() {
  try {
    const res = await fetch("/api/files" + (showAll ? "?all=1" : ""));
    const data = await res.json();
    allFiles = data.files || [];
    if (data.root) { WS = data.root; renderWsBar(); }
  } catch { allFiles = []; }
  const label = $("#filesHeadLabel");
  if (label) label.textContent = showAll ? "工作区文件（全部）" : "工作区 .fl 文件";
  renderFileTree();
}

async function openFile(rel) {
  if (!rel) return;
  if (!confirmDiscard()) { renderFileTree(); return; }
  try {
    const res = await fetch("/api/file?path=" + encodeURIComponent(rel));
    const data = await res.json();
    if (!data.ok) { alert(data.error || "打开失败"); return; }
    currentPath = rel;
    fileNameEl.textContent = rel;
    $("#pathInput").value = rel;
    setDocument(data.src);
    renderFileTree();
  } catch (err) { alert("打开失败: " + err.message); }
}

async function saveFile() {
  const rel = $("#pathInput").value.trim() || currentPath;
  if (!rel) { alert("请先在「另存为」输入相对路径，例如 apps/student/student.fl"); return; }
  try {
    const res = await fetch("/api/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: rel, src: code.value }),
    });
    const data = await res.json();
    if (!data.ok) { alert(data.error || "保存失败"); return; }
    currentPath = data.saved;
    fileNameEl.textContent = data.saved;
    $("#pathInput").value = data.saved;
    setDirty(false);
    renderFileTree();
    const btn = $("#saveBtn");
    const old = btn.textContent;
    btn.textContent = "✅ 已保存";
    setTimeout(() => { btn.textContent = old; }, 1200);
  } catch (err) { alert("保存失败: " + err.message); }
}
$("#saveBtn").addEventListener("click", saveFile);
$("#compileBtn").addEventListener("click", compile);
$("#newBtn").addEventListener("click", () => {
  if (!confirmDiscard()) return;
  currentPath = "";
  fileNameEl.textContent = "untitled.fl";
  $("#pathInput").value = "";
  setDocument("");
  renderFileTree();
  code.focus();
});

// ============ v4：工作区（可切到任意文件夹） ============
let WS = "";              // 当前工作区绝对路径（服务器说了算）
let wsCursor = "";        // 选择器里正在浏览的那个目录
let showAll = false;      // 是否连非 .fl 一起列

// 长路径只显示末尾两段（完整路径放 title，鼠标悬停能看到）
function shortPath(p) {
  const parts = String(p).split(/[\\/]/).filter(Boolean);
  return parts.length <= 2 ? String(p) : "…\\" + parts.slice(-2).join("\\");
}
function renderWsBar() {
  const el = $("#wsPath");
  if (!el) return;
  el.textContent = WS ? shortPath(WS) : "…";
  el.title = WS;
  $("#wsBar").title = "当前工作区：" + WS + "\n文件树 / 打开 / 保存 / 编译都相对它 —— 点这里换文件夹";
}
async function loadWorkspace() {
  try {
    const res = await fetch("/api/workspace");
    const data = await res.json();
    if (data.ok) WS = data.workspace;
  } catch { /* 忽略：拿不到就等 /api/files 回填 */ }
  renderWsBar();
}

// 切工作区：先问未保存改动 → 告诉服务端 → 刷新文件树/库速查 → 文件不在新工作区就清空编辑器
async function useWorkspace(p) {
  if (!p) return false;
  if (!confirmDiscard()) return false;
  try {
    const res = await fetch("/api/workspace", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: p }),
    });
    const data = await res.json();
    if (!data.ok) { alert(data.error || "切换失败"); $("#wsHint").textContent = data.error || "切换失败"; return false; }
    WS = data.workspace;
    renderWsBar();
    closeWsModal();
    await loadFileTree();
    await renderLibs();                       // 新工作区可能自带 lib\
    if (currentPath && allFiles.some((f) => f.rel === currentPath)) {
      renderFileTree();                       // 文件还在新工作区里：保持打开
    } else if (currentPath) {
      currentPath = "";                       // 文件不在新工作区了：退回未命名（否则保存会被拒）
      fileNameEl.textContent = "untitled.fl";
      $("#pathInput").value = "";
      setDocument("");
      setDirty(false);
    }
    return true;
  } catch (err) { alert("切换失败: " + err.message); return false; }
}

// —— 选择器：服务端列目录（浏览器不给本地绝对路径）——
function openWsModal() { $("#wsModal").classList.remove("hidden"); browseDirs(WS); code.blur(); }
function closeWsModal() { $("#wsModal").classList.add("hidden"); }
async function browseDirs(p) {
  try {
    const res = await fetch("/api/dirs?path=" + encodeURIComponent(p || ""));
    const data = await res.json();
    wsCursor = data.path || "";
    $("#wsPathInput").value = wsCursor;
    $("#wsUp").disabled = !data.parent;
    $("#wsUp").dataset.parent = data.parent || "";
    $("#wsRoots").innerHTML = (data.roots || []).map((r) =>
      `<span class="ws-chip" data-path="${esc(r.path)}" title="${esc(r.path)}">${esc(r.name)}</span>`).join("");
    const box = $("#wsDirs");
    if (!data.ok) {
      box.innerHTML = `<div class="file-empty">${esc(data.error || "读不到")}</div>`;
      $("#wsHint").textContent = data.error || "读不到";
    } else if (!data.dirs.length) {
      box.innerHTML = `<div class="file-empty">（没有子文件夹；可以直接点「用这个文件夹」）</div>`;
      $("#wsHint").textContent = "这个文件夹里没有子文件夹";
    } else {
      box.innerHTML = data.dirs.map((d) =>
        `<div class="dir-item" data-path="${esc(d.path)}"><span class="di-ico">📁</span><span>${esc(d.name)}</span></div>`).join("");
      $("#wsHint").textContent = data.dirs.length + " 个子文件夹 · 双击/单击进入，或直接「用这个文件夹」";
    }
  } catch (err) {
    $("#wsHint").textContent = "读不到: " + err.message;
    $("#wsDirs").innerHTML = `<div class="file-empty">读不到: ${esc(err.message)}</div>`;
  }
}
$("#wsBar").addEventListener("click", (e) => { if (e.target.id !== "wsChangeBtn") openWsModal(); });
$("#wsChangeBtn").addEventListener("click", (e) => { e.stopPropagation(); openWsModal(); });
$("#wsClose").addEventListener("click", closeWsModal);
$("#wsModal").addEventListener("click", (e) => { if (e.target.id === "wsModal") closeWsModal(); });
$("#wsDirs").addEventListener("click", (e) => {
  const it = e.target.closest(".dir-item");
  if (it) browseDirs(it.dataset.path);
});
$("#wsRoots").addEventListener("click", (e) => {
  const c = e.target.closest(".ws-chip");
  if (c) browseDirs(c.dataset.path);
});
$("#wsUp").addEventListener("click", (e) => { const p = e.currentTarget.dataset.parent; if (p) browseDirs(p); });
$("#wsGo").addEventListener("click", () => browseDirs($("#wsPathInput").value.trim()));
$("#wsPathInput").addEventListener("keydown", (e) => { if (e.key === "Enter") browseDirs(e.target.value.trim()); });
$("#wsUse").addEventListener("click", () => useWorkspace(wsCursor || WS));
$("#showAllFiles").addEventListener("change", (e) => {
  showAll = e.target.checked;
  try { localStorage.setItem("studio.showAll", showAll ? "1" : "0"); } catch { /* 无痕模式等 */ }
  loadFileTree();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#wsModal").classList.contains("hidden")) closeWsModal();
});

// ============ v4.2：页签全屏查看（右栏只有 380px，反汇编/机器码在里头看不全）============
function openZoom() {
  const body = $(TAB_IDS[curTab]);
  if (!body) return;
  $("#zoomBody").innerHTML = body.innerHTML;
  const tabEl = document.querySelector(`.tab[data-tab="${curTab}"]`);
  $("#zoomTitle").textContent = (tabEl ? tabEl.textContent.trim() : "查看") + " · 放大";
  $("#zoomOverlay").classList.remove("hidden");
}
function closeZoom() { $("#zoomOverlay").classList.add("hidden"); }
$("#zoomBtn").addEventListener("click", openZoom);
$("#zoomClose").addEventListener("click", closeZoom);
$("#zoomOverlay").addEventListener("click", (e) => { if (e.target.id === "zoomOverlay") closeZoom(); });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("#zoomOverlay").classList.contains("hidden")) closeZoom();
});

// ============ v4.2：标准库速查可折叠（它占着右栏 38% 高度，看反汇编时纯浪费）============
let libsCollapsed = false;
function applyLibsCollapse() {
  document.querySelector(".libs").classList.toggle("collapsed", libsCollapsed);
  $("#libsToggle").textContent = libsCollapsed ? "▸" : "▾";
}
$("#libsHead").addEventListener("click", () => {
  libsCollapsed = !libsCollapsed;
  try { localStorage.setItem("studio.libsCollapsed", libsCollapsed ? "1" : "0"); } catch { /* 忽略 */ }
  applyLibsCollapse();
});

// ============ v4.3：三栏可拖宽 + 左右可收起 ============
// 起因（用户）：反汇编要和代码**对照**看 —— 右栏 380px 太窄、⤢ 全屏又把代码盖住了，两头不讨好。
// 做法：拖动分隔条改宽（宽度记住），左右两栏可一键收起（Ctrl+B / Ctrl+Alt+B，双击分隔条也行）。
const EDITOR_MIN = 320;
const W_MIN = { left: 140, right: 240 };
let wLeft = 240, wRight = 380, hideLeft = false, hideRight = false;

function applyLayout() {
  document.documentElement.style.setProperty("--w-left", wLeft + "px");
  document.documentElement.style.setProperty("--w-right", wRight + "px");
  document.body.classList.toggle("hide-left", hideLeft);
  document.body.classList.toggle("hide-right", hideRight);
  const tl = $("#toggleLeft"), tr = $("#toggleRight");
  if (tl) tl.classList.toggle("active", hideLeft);
  if (tr) tr.classList.toggle("active", hideRight);
}
function persistLayout() {
  try {
    localStorage.setItem("studio.layout", JSON.stringify({ wLeft, wRight, hideLeft, hideRight }));
  } catch { /* 忽略 */ }
}
function loadLayout() {
  try {
    const j = JSON.parse(localStorage.getItem("studio.layout") || "{}");
    if (j.wLeft) wLeft = j.wLeft;
    if (j.wRight) wRight = j.wRight;
    hideLeft = !!j.hideLeft;
    hideRight = !!j.hideRight;
  } catch { /* 忽略 */ }
  applyLayout();
}
function setPaneWidth(which, raw) {
  const other = which === "left" ? (hideRight ? 0 : wRight) : (hideLeft ? 0 : wLeft);
  const max = Math.max(W_MIN[which], window.innerWidth - other - EDITOR_MIN - 10);
  const v = Math.max(W_MIN[which], Math.min(Math.round(raw), max));
  if (which === "left") wLeft = v; else wRight = v;
  applyLayout();
}
function dragSplit(el, which) {
  el.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    el.classList.add("dragging");
    const move = (ev) => setPaneWidth(which, which === "left" ? ev.clientX : window.innerWidth - ev.clientX);
    const up = () => {
      el.classList.remove("dragging");
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      persistLayout();
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  });
  el.addEventListener("dblclick", () => {
    if (which === "left") hideLeft = !hideLeft; else hideRight = !hideRight;
    applyLayout(); persistLayout();
  });
}
$("#toggleLeft").addEventListener("click", () => { hideLeft = !hideLeft; applyLayout(); persistLayout(); });
$("#toggleRight").addEventListener("click", () => { hideRight = !hideRight; applyLayout(); persistLayout(); });
dragSplit($("#splitL"), "left");
dragSplit($("#splitR"), "right");
document.addEventListener("keydown", (e) => {
  if (!e.ctrlKey) return;
  const k = (e.key || "").toLowerCase();
  if (k !== "b") return;
  if (e.altKey) { e.preventDefault(); hideRight = !hideRight; }
  else { e.preventDefault(); hideLeft = !hideLeft; }
  applyLayout(); persistLayout();
});

// ============ 示例 ============
const SAMPLES = {
  "hello · print 与库": `include "num_lib.fl"
int main() {
  print(["hello FLINT!\\n"]);
  print(["1+2*3 = ", 1 + 2 * 3, "\\n"]);
  char b[16];
  std::itoa(2026, b);
  print(["itoa -> ", b, "\\n"]);
  return 0;
}`,
  "结构体 + 指针字段": `struct Stu { int id; int score; int *tags; }
int main() {
  struct Stu s;
  s.id = 1001;
  s.score = 92;
  int tags[3];
  s.tags = tags;
  s.tags[0] = 7;
  s.tags[1] = 8;
  s.tags[2] = 9;
  print(["id=", s.id, " score=", s.score, " tags[1]=", s.tags[1], "\\n"]);
  return 0;
}`,
  "位掩码测试（退出码即成绩单）": `// 每项断言 r |= 2^i，退出码就是二进制成绩单
int main() {
  int r = 0;
  if (1 + 2 * 3 == 7) r |= 1;
  if (-10 / 3 == -3) r |= 2;
  if (-10 % 3 == -1) r |= 4;
  if ((1 + 2) * 3 == 9) r |= 8;
  if (0x10 == 16) r |= 16;
  if (r != 31) return 1;
  return 42;
}`,
  "浮点 double（含数组/复合赋值）": `// v1.1.0 起：字面量 / 算术 / 比较 / to_int
// v1.2.1~v1.2.4：函数返回 double、函数形参 double、print 直接打 double、
//   double 数组、复合赋值 += -= *= /=（结构体 double 字段也可）
// ⚠️ double → int 必须写 to_int(值)：int n = 3.5 是**编译期报错**（不静默截断小数）
// ⚠️ double 的 ++/-- 暂未支持（会走整数路径）——请写 d += 1.0
double half(double x) { return x / 2.0; }
struct Box { double w; double h; }
int main() {
  int r = 0;
  double a = 3.5;
  double b = 1.5e1;
  if (a + b == 18.5) r |= 1;
  if (a * 2.0 == 7.0) r |= 2;
  if (b / 3.0 == 5.0) r |= 4;
  if (a < b) r |= 8;
  if (a != b) r |= 16;                 // v1.2.3 修的真 bug：double 的 != 曾与 == 同义
  if (to_int(a * 4.0) == 14) r |= 32;
  if (half(a + 0.5) == 2.0) r |= 64;   // double 形参 + 返回值：half(4.0) = 2.0
  double s[2];                         // v1.2.4：double 数组
  s[0] = 1.25;
  s[1] = s[0] * 2.0;                   // 2.5
  if (s[1] == 2.5) r |= 128;
  struct Box box;                      // v1.2.4：结构体 double 字段
  box.w = 2.0;
  box.h = 3.0;
  box.w += 0.5;                        // 2.5（字段复合赋值）
  if (box.w * box.h == 7.5) r |= 256;
  print(["a=", a, " half=", half(a + 0.5), " s=", s[1], " box=", box.w, "x", box.h, " r=", r, "\\n"]);
  return r;   // 511
}`,
  "io 库 · 写读文件": `include "io_lib.fl"
int main() {
  char w[8];
  char r[8];
  w[0] = 'F'; w[1] = 'L'; w[2] = 'I'; w[3] = 'N'; w[4] = 'T';
  if (std::file_write("studio_test.txt", w, 5) != 1) return 1;
  int n = std::file_read("studio_test.txt", r, 8);
  if (n != 5) return 2;
  if (r[0] != 'F') return 3;
  print(["写读 OK, 文件大小=", std::file_size("studio_test.txt"), "\\n"]);
  return 0;
}`,
  "交互程序（用右侧 stdin 输入）": `include "num_lib.fl"
include "io_lib.fl"
api kernel32 ptr GetStdHandle(int);

// ⚠️ 管道输入时 ReadFile 一次可能给多行 → 自己缓冲逐行取（别直接当一行用）
struct In { int *buf; int len; int pos; int cap; }

int in_line(struct In *in, char *out, int cap) {
  int *h = GetStdHandle(-10);
  if (h == 0) return -1;
  char *ib = in->buf;
  int o = 0;
  while (1) {
    while (in->pos < in->len) {
      char c = ib[in->pos];
      in->pos = in->pos + 1;
      if (c == 10) { out[o] = 0; return o; }
      if (c != 13) { if (o < cap - 1) { out[o] = c; o = o + 1; } }
    }
    in->len = 0;
    in->pos = 0;
    int got = 0;
    if (ReadFile(h, ib, in->cap, &got, 0) == 0) { out[o] = 0; if (o > 0) return o; return -1; }
    if (got == 0) { out[o] = 0; if (o > 0) return o; return -1; }
    in->len = got;
  }
}

int main() {
  char line[64];
  char ibuf[256];
  struct In in;
  in.buf = ibuf;
  in.len = 0;
  in.pos = 0;
  in.cap = 256;
  int sum = 0;
  int run = 1;
  print(["输入若干整数（stdin 面板），累加求和：\\n"]);
  while (run) {
    int n = in_line(&in, line, 64);
    if (n < 0) { run = 0; }
    else {
      int v = std::atoi(line);
      if (v == 0) { run = 0; }
      else { sum = sum + v; print(["  + ", v, " => ", sum, "\\n"]); }
    }
  }
  print(["sum = ", sum, "\\n"]);
  return 0;
}`,
  "学生管理骨架（完整版 apps/student）": `// 完整交互版：打开 apps/student/student.fl → 编译运行 → stdin 面板喂菜单
int main() {
  int ids[8];
  int scores[8];
  int n = 0;
  ids[n] = 1001; scores[n] = 92; n = n + 1;
  ids[n] = 1002; scores[n] = 78; n = n + 1;
  print(["学号\\t成绩\\n"]);
  int i = 0;
  while (i < n) {
    print([ids[i], "\\t", scores[i], "\\n"]);
    i = i + 1;
  }
  return 0;
}`,
};

function loadSamples() {
  const sel = $("#sampleSel");
  for (const name of Object.keys(SAMPLES)) {
    const o = document.createElement("option");
    o.value = name; o.textContent = name;
    sel.appendChild(o);
  }
  sel.addEventListener("change", () => {
    const src = SAMPLES[sel.value];
    if (!src) return;
    if (!confirmDiscard()) { sel.value = ""; return; }
    currentPath = "";
    fileNameEl.textContent = "untitled.fl";
    $("#pathInput").value = "";
    setDocument(src);
    renderFileTree();
  });
}

// ============ 标准库速查（v3：后端扫 lib\*.fl 自动生成） ============
async function renderLibs() {
  const box = $("#libsBody");
  let libs = [];
  try {
    const res = await fetch("/api/libs");
    const data = await res.json();
    libs = data.libs || [];
  } catch { /* 忽略 */ }
  if (!libs.length) { box.innerHTML = `<div class="file-empty">读不到 lib 目录</div>`; return; }
  STDLIB_NAMES.clear();
  const parts = [];
  for (const l of libs) {
    parts.push(`<div class="lib-name">${esc(l.lib)}（${l.count}）</div>`);
    parts.push(`<div class="lib-fns">` + l.fns.map((f) =>
      `<span class="lib-fn" data-fn="${esc(f.name)}" title="${esc(f.sig)}">${esc(f.name)}</span>`).join("") + `</div>`);
    for (const f of l.fns) STDLIB_NAMES.add(f.name.split("::")[1]);
  }
  box.innerHTML = parts.join("");
  render();                                   // 库名集合变了，重画高亮
}
$("#libsBody").addEventListener("click", (e) => {
  const fn = e.target.dataset && e.target.dataset.fn;
  if (!fn) return;
  insertText(fn);
  code.focus();
});

// ============ 初始化 ============
const DEFAULT_SRC = `// FLINT Studio v3 — 写点东西，Ctrl+Enter 编译运行
// 语言：int/char/double/void/struct/指针/数组/if/while/for/new+own·share/api/include/print
// 快捷键：Ctrl+Enter 编译 · Ctrl+S 保存 · Ctrl+F 查找 · Ctrl+/ 注释 · Tab 缩进
include "num_lib.fl"

int main() {
  print(["hello FLINT!\\n"]);
  char b[16];
  std::itoa(42, b);
  print(["std::itoa(42) = ", b, "\\n"]);
  return 0;
}
`;
code.value = DEFAULT_SRC;
setDirty(false);
render();
loadSamples();
renderLibs();
try { showAll = localStorage.getItem("studio.showAll") === "1"; } catch { /* 忽略 */ }
$("#showAllFiles").checked = showAll;
try { libsCollapsed = localStorage.getItem("studio.libsCollapsed") === "1"; } catch { /* 忽略 */ }
applyLibsCollapse();
loadLayout();
loadWorkspace().then(() => loadFileTree());
