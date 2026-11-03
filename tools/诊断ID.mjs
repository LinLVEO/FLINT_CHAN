// 诊断ID.mjs -- 给「用户源码诊断」分配稳定错误码 [E-<类>-<哈希>]，并生成 C 端查表头
//
// 为什么要有它：src\*.c 里三百多处报错文案散在代码里，人看报错只能看中文，机器/AI 查表只能靠
//   关键词模糊匹配；改一个字就换一个"身份"。clang/gcc/rustc 的做法是每条诊断一个**稳定 ID**，
//   报错带 ID ⇒ 文档、issue、AI 都能按 ID 定位。
//
// 稳定性从哪来：ID 的哈希位 = **文案字符串** 的 SHA1 前 4 位（大写十六进制）⇒ ID 只跟文案走。
//   新增/删除别的报错，已有 ID 一位都不变（这正是本方案的核心要求，见 --gen 的"保留旧 ID"）。
//   类前缀（SEM/SYN/LIM/GEN）由文案关键词推断；类变了 ID 才会变（所以关键词表是口径，改动要显式）。
//
// 用法：
//   node tools\诊断ID.mjs --gen       扫源码 → 重生成 tools\诊断ID基线.json + docs\诊断ID表.md + src\diag_ids.h
//   node tools\诊断ID.mjs --check     校验（源码每条文案都在表里 / 表里没有孤儿 / 三个产物与表一致），失配 exit 1
//   node tools\诊断ID.mjs --json      把当前扫描结果打到 stdout（机器读）
//
// 口径：
//   · 只扫 src\*.c（不含 .h、不含 *.bak-*）；注释与字符串内部不参与"调用点"识别；
//   · 报错点 = error_at( / error( / error_at_node( / error_at_nodef( 的**调用**（不是定义）；
//   · 文案 = fmt 实参里相邻字符串字面量按 C 规则拼接（保留源码转义原样，反转义只影响显示）；
//   · **已经有手工码的文案**（正文以 [E-...] 开头，如 -strict 那 9 处）不进自动表、运行时也不加 ID
//     —— 手工码优先，绝不覆盖（判据：这些错误的 ID 与原来一字不差）；
//   · 纯变量传进来的 fmt（提取不到文案）记进 dynamic 列表，显式报出来，不静默漏；
//   · 基线的身份键 = **文案字符串**（不含文件、不含行号、不含出现次数）⇒ 无关编辑不漂移。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'src');
const BASE = path.join(HERE, '诊断ID基线.json');
const MD = path.join(ROOT, 'docs', '诊断ID表.md');
const HDR = path.join(SRC, 'diag_ids.h');

// ===== 一、C 源码扫描器（注释/字符串感知）=====
//
// 只靠正则扫 "error_at(" 会把注释里提过的同名文本也算进去；只靠正则切实参会在
// `"..."` 里的逗号/括号上切错。所以先逐字符做一遍状态机，得到两张等长标记表。

function markSource(text) {
  const n = text.length;
  const inStr = new Uint8Array(n); // 1 = 位于字符串/字符字面量内部（含定界引号）
  const inCmt = new Uint8Array(n); // 1 = 位于注释内部
  let i = 0;
  let st = 0; // 0 代码 / 1 行注释 / 2 块注释 / 3 字符串 / 4 字符字面量
  while (i < n) {
    const c = text[i];
    const d = i + 1 < n ? text[i + 1] : '';
    if (st === 0) {
      if (c === '/' && d === '/') { inCmt[i] = inCmt[i + 1] = 1; st = 1; i += 2; continue; }
      if (c === '/' && d === '*') { inCmt[i] = inCmt[i + 1] = 1; st = 2; i += 2; continue; }
      if (c === '"') { inStr[i] = 1; st = 3; i += 1; continue; }
      if (c === "'") { inStr[i] = 1; st = 4; i += 1; continue; }
      i += 1; continue;
    }
    if (st === 1) { // 行注释：到行尾（\r 也吞掉，免得漏行）
      if (c === '\n') { st = 0; i += 1; continue; }
      inCmt[i] = 1; i += 1; continue;
    }
    if (st === 2) { // 块注释
      if (c === '*' && d === '/') { inCmt[i] = inCmt[i + 1] = 1; st = 0; i += 2; continue; }
      inCmt[i] = 1; i += 1; continue;
    }
    // 字符串 / 字符字面量内部：只关心转义与收尾
    if (c === '\\') { inStr[i] = 1; if (i + 1 < n) inStr[i + 1] = 1; i += 2; continue; }
    if ((st === 3 && c === '"') || (st === 4 && c === "'")) { inStr[i] = 1; st = 0; i += 1; continue; }
    inStr[i] = 1; i += 1; continue;
  }
  return { inStr, inCmt };
}

// 从 '(' 的下标 open 起找配对的 ')'（跳过字符串/注释内部）
function findClose(text, mark, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (mark.inStr[i] || mark.inCmt[i]) continue;
    const c = text[i];
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

// 按顶层逗号切实参（同样跳过字符串/注释内部）
function splitArgs(text, mark, open, close) {
  const args = [];
  let depth = 0;
  let from = open + 1;
  for (let i = open + 1; i < close; i++) {
    if (mark.inStr[i] || mark.inCmt[i]) continue;
    const c = text[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === ',' && depth === 0) { args.push(text.slice(from, i)); from = i + 1; }
  }
  args.push(text.slice(from, close));
  return args.map((s) => s.trim());
}

// 把一个实参切成 [字面量...] + 残余 token；返回值：
//   kind='literal'  纯相邻字面量（C 会拼接）→ text 是拼接后的源码正文（未反转义）
//   kind='dynamic'  提取不到（变量/表达式/含运算符的三目等）
function extractFmt(argText, startOffset, mark) {
  const lits = [];
  let rest = '';
  let i = 0;
  while (i < argText.length) {
    // 跳过注释
    if (argText[i] === '/' && argText[i + 1] === '/') { while (i < argText.length && argText[i] !== '\n') i++; continue; }
    if (argText[i] === '/' && argText[i + 1] === '*') {
      const e = argText.indexOf('*/', i + 2);
      i = e < 0 ? argText.length : e + 2;
      continue;
    }
    if (argText[i] === '"') {
      let j = i + 1;
      while (j < argText.length && argText[j] !== '"') { if (argText[j] === '\\') j++; j++; }
      lits.push(argText.slice(i + 1, j)); // 保留 \n \" 等源码转义原样（哈希输入口径）
      i = j + 1;
      continue;
    }
    rest += argText[i];
    i++;
  }
  if (!rest.trim()) return { kind: 'literal', text: lits.join('') };
  if (lits.length === 0) return { kind: 'dynamic', text: argText.trim() };
  // 三目/字符串选择：`cond ? "A" : "B"` —— 运行时 fmt 指向其中**某一个**字面量，
  //   所以逐分支收录（每个分支各自一条 ID），而不是把 A、B 拼成一条假文案。
  return { kind: 'branch', lits, text: argText.trim(), rest: rest.trim() };
}

// ===== 二、扫 src\*.c =====

const RX_CALL = /(?<![A-Za-z0-9_])(error_at_nodef|error_at_node|error_at|error)\s*\(/g;

// 每个入口的 fmt 实参下标（0 = 第 1 个实参）
const FMT_ARG = { error_at: 1, error_at_node: 1, error_at_nodef: 1, error: 0 };

function scanFile(file, text) {
  const mark = markSource(text);
  const out = [];
  const base = path.relative(ROOT, file).replace(/\\/g, '/');
  let m;
  RX_CALL.lastIndex = 0;
  while ((m = RX_CALL.exec(text))) {
    if (mark.inStr[m.index] || mark.inCmt[m.index]) continue; // 注释/字符串里的同名文本
    // 跳过函数**定义**：`void error_at(...)` / `static void error_at_node(...)`
    const lineStart = text.lastIndexOf('\n', m.index) + 1;
    const prefix = text.slice(lineStart, m.index);
    if (/(^|\s)(static\s+)?(void|int|const\s+char\s*\*)\s*$/.test(prefix)) continue;
    const open = m.index + m[0].length - 1;
    const close = findClose(text, mark, open);
    if (close < 0) continue;
    const args = splitArgs(text, mark, open, close);
    const line = text.slice(0, m.index).split('\n').length;
    const fn = m[1];
    const fi = FMT_ARG[fn];
    const point = { file: base, line, fn, kind: 'dynamic', msg: '', expr: '' };
    if (args.length > fi) {
      const ex = extractFmt(args[fi], 0, mark);
      if (ex.kind === 'literal') { point.kind = 'literal'; point.msg = ex.text; }
      else if (ex.kind === 'branch') {
        // 三目选择：每个分支都可能是运行时的 fmt ⇒ 逐条收录；另记一条 branch 供报告
        for (const lit of ex.lits) out.push({ file: base, line, fn, kind: 'literal', msg: lit, fromExpr: true });
        point.kind = 'branch';
        point.expr = ex.text.replace(/\s+/g, ' ');
      } else { point.kind = 'dynamic'; point.expr = ex.text; }
    }
    out.push(point);
  }
  return out;
}

export function collect() {
  const files = fs.readdirSync(SRC).filter((f) => f.endsWith('.c') && !f.includes('.bak-')).sort();
  const points = [];
  for (const f of files) points.push(...scanFile(path.join(SRC, f), fs.readFileSync(path.join(SRC, f), 'utf8')));
  return points;
}

// ===== 三、类判定 + 哈希 =====

// 类前缀规则（顺序即优先级，先命中先得）：
//   语义：未声明/未定义/重定义/类型/不能/须要
//   语法：期望/缺少/语法/必须写成/写法
//   限制：暂不支持/不支持/边界；上限/超出/溢出/太大
//   其余：GEN
const CLASS_RULES = [
  ['SEM', /未声明|未定义|重定义|类型|不能|须要/],
  ['SYN', /期望|缺少|语法|必须写成|写法/],
  ['LIM', /暂不支持|不支持|边界/],
  ['LIM', /上限|超出|溢出|太大/],
];

function classify(msg) {
  for (const [cls, rx] of CLASS_RULES) if (rx.test(msg)) return cls;
  return 'GEN';
}

function sha1_4(msg) {
  return crypto.createHash('sha1').update(msg, 'utf8').digest('hex').slice(0, 4).toUpperCase();
}

// 手工码 = 文案正文以 [E-...] 开头（-strict 那 9 处）；这类不分配自动 ID
const MANUAL_RX = /^\[(E-[A-Z0-9_-]+)\]/;

// 反转义（只用于人读的 md / 显示，不参与哈希）
function unescapeLit(s) {
  return s.replace(/\\(["\\])/g, '$1').replace(/\\n/g, '⏎').replace(/\\t/g, '→').replace(/\\0/g, '∅');
}

// ===== 四、ID 分配（稳定性 = 保留旧 ID）=====

function assignIds(points, oldBase) {
  const old = new Map();
  if (oldBase && Array.isArray(oldBase.diagnostics)) {
    for (const d of oldBase.diagnostics) old.set(d.msg, d.id);
  }
  const byMsg = new Map(); // msg -> { msg, cls, id, files:Set, count }
  const dynamic = [];
  const branch = [];
  for (const p of points) {
    if (p.kind === 'branch') { branch.push(p); continue; }
    if (p.kind !== 'literal') { dynamic.push(p); continue; }
    if (MANUAL_RX.test(p.msg)) continue; // 手工码走自己的路
    let e = byMsg.get(p.msg);
    if (!e) { e = { msg: p.msg, cls: classify(p.msg), files: new Set(), count: 0 }; byMsg.set(p.msg, e); }
    e.files.add(p.file);
    e.count++;
  }
  // ID 碰撞：SHA1 前 4 位只有 65536 格，几百条文案撞一次是正常概率。
  //   撞了就**延长哈希位**（5、6…）直到唯一 —— 仍然只由文案决定 ⇒ 依旧稳定。
  const used = new Map(); // id -> msg
  const list = [...byMsg.values()];
  // 先给"旧表里已有"的文案占位，保证老 ID 一位不动
  const hashOf = new Map();
  for (const e of list) hashOf.set(e.msg, sha1_4(e.msg));
  const idOf = new Map();
  for (const e of list) {
    const kept = old.get(e.msg);
    if (kept && !used.has(kept)) { used.set(kept, e.msg); idOf.set(e.msg, kept); }
  }
  for (const e of list) {
    if (idOf.has(e.msg)) continue;
    let width = 4;
    let id;
    for (;;) {
      const h = crypto.createHash('sha1').update(e.msg, 'utf8').digest('hex').toUpperCase().slice(0, width);
      id = `[E-${e.cls}-${h}]`;
      if (!used.has(id) || used.get(id) === e.msg) break;
      width += 1;
      if (width > 40) throw new Error('哈希位延长到 40 位仍冲突：' + e.msg);
    }
    used.set(id, e.msg);
    idOf.set(e.msg, id);
  }
  const diags = list
    .map((e) => ({ id: idOf.get(e.msg), cls: e.cls, msg: e.msg, files: [...e.files].sort(), count: e.count, hash: hashOf.get(e.msg) }))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const manual = [];
  for (const p of points) {
    if (p.kind !== 'literal') continue;
    const mm = p.msg.match(MANUAL_RX);
    if (mm) manual.push({ code: mm[1], msg: p.msg, file: p.file, line: p.line });
  }
  return { diags, dynamic, branch, manual };
}

// ===== 五、渲染 =====

function jsonText(res) {
  const payload = {
    note: '由 tools\\诊断ID.mjs --gen 生成；身份键 = 文案字符串（不含文件/行号/次数）。ID = [E-<类>-<SHA1 前4位大写>]。',
    diagnostics: res.diags.map((d) => ({ id: d.id, cls: d.cls, msg: d.msg, files: d.files, count: d.count })),
  };
  return JSON.stringify(payload, null, 2) + '\n';
}

function mdText(res) {
  const cell = (s) => unescapeLit(s).replace(/\|/g, '\\|').replace(/\n/g, ' ');
  const byCls = new Map();
  for (const d of res.diags) byCls.set(d.cls, (byCls.get(d.cls) || 0) + 1);
  const clsLine = ['SEM', 'SYN', 'LIM', 'GEN'].map((c) => `${c} ${byCls.get(c) || 0}`).join(' ｜ ');
  const lines = [
    '# 诊断 ID 表（机器生成 · 勿手改）',
    '',
    '> 生成器：`tools\\诊断ID.mjs` ｜ 重生成：`node tools\\诊断ID.mjs --gen` ｜ 校验：`node tools\\诊断ID.mjs --check`',
    `> 自动 ID **${res.diags.length}** 条（${clsLine}）｜ 手工码 **${res.manual.length}** 处（保持原样，不进本表）｜ 动态文案 **${res.dynamic.length}** 处｜ 三目分支 **${res.branch.length}** 处（已逐分支收录）。`,
    '',
    'ID 的哈希位 = 该条文案字符串的 SHA1 前 4 位（大写十六进制）⇒ **只跟文案走**：新增/删除别的错误，已有 ID 不变。',
    '类别：`SEM` 语义 ｜ `SYN` 语法 ｜ `LIM` 限制 ｜ `GEN` 其他。',
    '',
    '| ID | 类 | 文案 | 出现文件 |',
    '|---|---|---|---|',
  ];
  for (const d of res.diags) lines.push(`| \`${d.id}\` | ${d.cls} | ${cell(d.msg)} | ${d.files.map((f) => '`' + f + '`').join(' ')} |`);
  lines.push('');
  // 提取不到 / 特殊形态的，显式列出来（不静默漏）
  if (res.dynamic.length) {
    lines.push('## 提取不到的文案（fmt 经变量传入 —— 运行时按变量里的字符串查表，命中不到就不追加 ID）', '');
    lines.push('| 位置 | 入口 | 表达式 |', '|---|---|---|');
    for (const p of res.dynamic) lines.push(`| \`${p.file}:${p.line}\` | \`${p.fn}\` | ${cell(p.expr).slice(0, 120)} |`);
    lines.push('');
  }
  if (res.branch.length) {
    lines.push('## 三目/字符串选择的 fmt（已把每个分支逐条收录进上表）', '');
    lines.push('| 位置 | 入口 | 选择表达式 |', '|---|---|---|');
    for (const p of res.branch) lines.push(`| \`${p.file}:${p.line}\` | \`${p.fn}\` | ${cell(p.expr).slice(0, 120)} |`);
    lines.push('');
  }
  return lines.join('\n');
}

function headerText(res) {
  const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const rows = res.diags.map((d) => `  { "${esc(d.msg)}", "${d.id}" },`).join('\n');
  return [
    '// diag_ids.h -- 机器生成（勿手改）；重生成：node tools\\诊断ID.mjs --gen',
    '//',
    '// 「文案 → 稳定错误码」查表。key 是**源码里的字面量正文**（未反转义，保留 \\n \\" 等），',
    '// 与 error_at/error 运行时拿到的 fmt 指针逐字节相同 ⇒ strcmp 即可命中。',
    '// 手工码（正文已带 [E-...]、如 -strict 那 9 处）**不收录**：查不到 ⇒ 运行时不追加，一字不动。',
    `// 条目数：${res.diags.length}（另有手工码 ${res.manual.length} 处、动态文案 ${res.dynamic.length} 处、三目分支 ${res.branch.length} 处）`,
    '',
    '#ifndef DIAG_IDS_H',
    '#define DIAG_IDS_H',
    '',
    'typedef struct { const char *msg; const char *id; } DiagIdEntry;',
    '',
    'static const DiagIdEntry DIAG_ID_TABLE[] = {',
    rows,
    '};',
    '',
    `#define DIAG_ID_COUNT ((int)(sizeof(DIAG_ID_TABLE) / sizeof(DIAG_ID_TABLE[0])))`,
    '',
    '#endif // DIAG_IDS_H',
    '',
  ].join('\n');
}

// ===== 六、命令 =====

function readBase() {
  if (!fs.existsSync(BASE)) return null;
  return JSON.parse(fs.readFileSync(BASE, 'utf8'));
}

function gen(points) {
  const old = readBase();
  const res = assignIds(points, old);
  fs.writeFileSync(BASE, jsonText(res), 'utf8');
  fs.mkdirSync(path.dirname(MD), { recursive: true });
  fs.writeFileSync(MD, mdText(res), 'utf8');
  fs.writeFileSync(HDR, headerText(res), 'utf8');
  console.log(`已生成：${path.relative(ROOT, BASE)} / ${path.relative(ROOT, MD)} / ${path.relative(ROOT, HDR)}`);
  console.log(`自动 ID ${res.diags.length} 条 ｜ 手工码 ${res.manual.length} 处 ｜ 动态文案 ${res.dynamic.length} 处 ｜ 三目分支 ${res.branch.length} 处 ｜ 报错点 ${points.length} 处`);
  if (res.dynamic.length) {
    console.log('动态文案（fmt 经变量传入，提取不到；运行时按变量里的字符串查表，命中不到就不追加 ID）：');
    for (const p of res.dynamic) console.log(`  ${p.file}:${p.line}  ${p.fn}  ←  ${p.expr.replace(/\s+/g, ' ').slice(0, 90)}`);
  }
  if (res.branch.length) {
    console.log('三目/字符串选择（已逐分支收录）：');
    for (const p of res.branch) console.log(`  ${p.file}:${p.line}  ${p.fn}  ←  ${p.expr.replace(/\s+/g, ' ').slice(0, 90)}`);
  }
  // 哈希位被延长的（4 位撞车）显式提示（正常 ID 长度 = 12：`[E-XXX-1234]`）
  for (const d of res.diags) {
    if (d.id.length > 12) console.log(`  注意：${d.id} 的哈希位延长到 ${d.id.length - 8} 位（前 4 位与别的文案撞车）—— ${d.msg.slice(0, 60)}`);
  }
  return 0;
}

function check(points) {
  const old = readBase();
  if (!old) { console.log('诊断ID：没有基线 ' + BASE + '（先跑 --gen）'); return 1; }
  let rc = 0;
  const res = assignIds(points, old);
  const o = new Map();
  for (const d of old.diagnostics) o.set(d.msg, d);
  const n = new Map();
  for (const d of res.diags) n.set(d.msg, d);
  const added = [...n.keys()].filter((m) => !o.has(m));
  const removed = [...o.keys()].filter((m) => !n.has(m));
  const changed = [...n.keys()].filter((m) => o.has(m) && o.get(m).id !== n.get(m).id);
  if (added.length) { rc = 1; console.log(`源码新增文案 ${added.length} 条（未登记，跑 --gen）：`); for (const m of added) console.log(`  + ${n.get(m).id}  ${unescapeLit(m).slice(0, 90)}`); }
  if (removed.length) { rc = 1; console.log(`表里孤儿 ${removed.length} 条（源码里已不存在，跑 --gen）：`); for (const m of removed) console.log(`  - ${o.get(m).id}  ${unescapeLit(m).slice(0, 90)}`); }
  if (changed.length) { rc = 1; console.log(`ID 变了 ${changed.length} 条（哈希/类规则被改过？）：`); for (const m of changed) console.log(`  ~ ${o.get(m).id} → ${n.get(m).id}  ${unescapeLit(m).slice(0, 80)}`); }
  // ID 唯一性（不同文案同 ID）
  const seen = new Map();
  const dup = [];
  for (const d of res.diags) { if (seen.has(d.id)) dup.push(`${d.id}: ${seen.get(d.id)} ／ ${d.msg}`); else seen.set(d.id, d.msg); }
  if (dup.length) { rc = 1; console.log('ID 冲突：'); for (const x of dup) console.log('  ! ' + x); }
  // 三个产物与表同步
  for (const [file, text] of [[MD, mdText(res)], [HDR, headerText(res)]]) {
    if (!fs.existsSync(file)) { rc = 1; console.log(`缺文件：${path.relative(ROOT, file)}（跑 --gen）`); continue; }
    if (fs.readFileSync(file, 'utf8') !== text) { rc = 1; console.log(`${path.relative(ROOT, file)} 与当前扫描不一致（跑 --gen 重生成）`); }
  }
  if (fs.existsSync(BASE) && fs.readFileSync(BASE, 'utf8') !== jsonText(res)) { rc = 1; console.log(`${path.relative(ROOT, BASE)} 与当前扫描不一致（跑 --gen 重生成）`); }
  if (rc === 0) console.log(`诊断ID OK：${res.diags.length} 条自动 ID / ${res.manual.length} 处手工码 / ${res.dynamic.length} 处动态文案，三产物同步。`);
  return rc;
}

const argv = process.argv.slice(2);
const points = collect();
if (argv.includes('--json')) {
  const res = assignIds(points, readBase());
  process.stdout.write(JSON.stringify({ points, ...res }, null, 2));
  process.exit(0);
}
if (argv.includes('--check')) process.exit(check(points));
if (argv.includes('--gen')) process.exit(gen(points));
console.log('用法: node tools\\诊断ID.mjs --gen | --check | --json');
process.exit(2);
