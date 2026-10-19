// 错误台账.mjs -- 把编译器源码里全部报错点（error_at 家族）扫成一张机器生成的台账
//
// 为什么要有它：src\*.c 里有近三百处报错，文案散在代码里，加一条/删一条/改一个字，
//   人和文档都记不住；探针（test\边界探针.ps1 的 wall 用例）只钉其中一部分关键词。
//   把「源码里的报错点」变成一份可 diff 的基线：新增/删除/改文案会红，必须显式重录。
//
// 用法：
//   node tools\错误台账.mjs --update    重生成 tools\错误台账.md + tools\错误台账基线.json
//   node tools\错误台账.mjs --check     对比基线（exit 1 = 有漂移），不写文件
//   node tools\错误台账.mjs --json      把当前扫描结果打到 stdout（机器读）
//
// 口径：
//   · 只扫 src\*.c（不含 .h、不含 *.bak-*）；
//   · 报错点 = error_at( / error_at_node( / error_at_nodef( 的调用（不是定义）；
//   · 文案 = 第 2 个实参里的字符串字面量（相邻字面量按 C 规则拼接）；不是字面量时记「(动态)」；
//   · 错误码 = 文案里的 [E-XXX] 标记（没有就留空）；
//   · 基线的身份键 = 文件 + 错误码 + 文案 —— **不含行号**（行号会随无关编辑漂移）。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'src');
const MD = path.join(HERE, '错误台账.md');
const BASE = path.join(HERE, '错误台账基线.json');

const RX_CALL = /\berror_at(?:_nodef|_node)?\s*\(/g;

function decodeLiteral(body) {
  // 只做最小反转义，够读：\" \\ \n \t 等
  return body.replace(/\\(["\\])/g, '$1').replace(/\\n/g, '⏎').replace(/\\t/g, '→');
}

function splitArgs(text, start, close) {
  // start = '(' 之后的下标；close = 配对的 ')' 下标；按顶层逗号切
  const args = [];
  let depth = 0, inStr = false, esc = false, from = start;
  for (let i = start; i < close; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    else if (c === ',' && depth === 0) { args.push(text.slice(from, i)); from = i + 1; }
  }
  args.push(text.slice(from, close));
  return args.map((s) => s.trim());
}

function findClose(text, start) {
  let depth = 1, inStr = false, esc = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) return i; }
  }
  return -1;
}

function scanFile(file, text) {
  const out = [];
  const base = path.relative(ROOT, file).replace(/\\/g, '/');
  let m;
  RX_CALL.lastIndex = 0;
  while ((m = RX_CALL.exec(text))) {
    // 跳过函数**定义**（`static void error_at_node(...)` 这种），只记调用点
    const lineStart = text.lastIndexOf('\n', m.index) + 1;
    const prefix = text.slice(lineStart, m.index);
    if (/(^|\s)(static\s+)?(void|int)\s+$/.test(prefix)) continue;
    const after = m.index + m[0].length; // 指向 '(' 之后
    const close = findClose(text, after);
    if (close < 0) continue;
    const args = splitArgs(text, after, close);
    const line = text.slice(0, m.index).split('\n').length;
    let msg = '(动态)';
    if (args.length >= 2) {
      const lits = [...args[1].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((x) => decodeLiteral(x[1]));
      const rest = args[1].replace(/"((?:[^"\\]|\\.)*)"/g, '').trim();
      if (lits.length > 0) msg = lits.join('');
      if (rest.length > 0 && lits.length > 0) msg += ' ⚠拼接';
    }
    const code = (msg.match(/\[(E-[A-Z0-9_-]+)\]/) || [])[1] || '';
    out.push({ file: base, line, code, msg });
  }
  return out;
}

export function collect() {
  const files = fs.readdirSync(SRC).filter((f) => f.endsWith('.c') && !f.includes('.bak-')).sort();
  const points = [];
  for (const f of files) points.push(...scanFile(path.join(SRC, f), fs.readFileSync(path.join(SRC, f), 'utf8')));
  points.sort((a, b) => (a.file + '\u0000' + a.msg).localeCompare(b.file + '\u0000' + b.msg));
  return points;
}

const key = (p) => p.file + '\u0000' + p.code + '\u0000' + p.msg;

export function renderMd(points) {
  const coded = points.filter((p) => p.code).length;
  const dyn = points.filter((p) => p.msg.startsWith('(动态)')).length;
  const cell = (s) => s.replace(/\|/g, '\\|');
  const lines = [
    '# 错误台账（机器生成 · 勿手改）',
    '',
    '> 生成器：`tools\\错误台账.mjs` ｜ 重生成：`node tools\\错误台账.mjs --update` ｜ 校验：`node tools\\错误台账.mjs --check`',
    `> 报错点 **${points.length}** 处（带 \`[E-*]\` 码 **${coded}** 处；动态文案 **${dyn}** 处）。`,
    '',
    '| 文件 | 错误码 | 文案 |',
    '|---|---|---|',
  ];
  for (const p of points) lines.push(`| \`${p.file}\` | ${p.code ? '`' + p.code + '`' : ''} | ${cell(p.msg)} |`);
  lines.push('');
  return lines.join('\n');
}

function readBase() {
  if (!fs.existsSync(BASE)) return null;
  return JSON.parse(fs.readFileSync(BASE, 'utf8'));
}

function check(points) {
  const base = readBase();
  if (!base) { console.log('错误台账：没有基线 ' + BASE + '（先跑 --update）'); return 1; }
  const now = new Map();
  for (const p of points) now.set(key(p), (now.get(key(p)) || 0) + 1);
  const old = new Map();
  for (const p of base.points) old.set(key(p), (old.get(key(p)) || 0) + 1);
  const added = [], removed = [];
  for (const [k, n] of now) { const d = n - (old.get(k) || 0); if (d > 0) added.push(k + (d > 1 ? ` ×${d}` : '')); }
  for (const [k, n] of old) { const d = n - (now.get(k) || 0); if (d > 0) removed.push(k + (d > 1 ? ` ×${d}` : '')); }
  let rc = 0;
  if (added.length) { rc = 1; console.log('新增报错点 ' + added.length + ' 条（必须显式重录基线）：'); for (const a of added) console.log('  + ' + a.replace(/\u0000/g, ' ｜ ')); }
  if (removed.length) { rc = 1; console.log('删除/改文案 ' + removed.length + ' 条（必须显式重录基线）：'); for (const r of removed) console.log('  - ' + r.replace(/\u0000/g, ' ｜ ')); }
  const mdNow = renderMd(points);
  if (fs.existsSync(MD) && fs.readFileSync(MD, 'utf8') !== mdNow) { rc = 1; console.log('tools\\错误台账.md 与当前扫描不一致（跑 --update 重生成）'); }
  if (rc === 0) console.log(`错误台账 OK：${points.length} 处报错点与基线一致，md 同步。`);
  return rc;
}

function update(points) {
  fs.writeFileSync(MD, renderMd(points), 'utf8');
  fs.writeFileSync(BASE, JSON.stringify({ note: '由 tools\\错误台账.mjs --update 生成；身份键不含行号', points }, null, 2) + '\n', 'utf8');
  console.log(`已重生成：${path.relative(ROOT, MD)}（${points.length} 处）＋ ${path.relative(ROOT, BASE)}`);
}

const argv = process.argv.slice(2);
const points = collect();
if (argv.includes('--json')) { process.stdout.write(JSON.stringify(points, null, 2)); process.exit(0); }
if (argv.includes('--check')) process.exit(check(points));
if (argv.includes('--update')) { update(points); process.exit(0); }
console.log('用法: node tools\\错误台账.mjs --update | --check | --json');
process.exit(2);
