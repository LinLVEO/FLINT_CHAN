// 边界覆盖.mjs —— FLINT「必须记住的边界」↔「机器能验的探针」对账器（只读）
//
// 目的（2026-10-12，用户「让语言更好用，对于人也对于机器」）：
//   把「凡是必须靠人记住的规则」逐条找出来，量一量其中多少已经变成**机器能替你检查**的探针。
//   本工具只回答三个问题，不做结论、不改任何文件：
//     ① 探针侧本身健不健壮（每条是否有实质断言 / 有没有重名）——防「假检验」
//     ② 文档侧的边界条目有多少、其中多少**自带"作废/订正"标记**（陈旧信号）
//     ③ 哪些文档条目**疑似没有探针覆盖**（关键词近似匹配，标注"需人核"，不自动下结论）
//
// 用法：
//   node tools\边界覆盖.mjs
//   node tools\边界覆盖.mjs --json          机器可读
//   node tools\边界覆盖.mjs --memory <记忆.md 路径> --archive <FLINT编译器.md 路径>
//
// 真值来源（都在磁盘上，路径会打印出来）：
//   E:\FLINT-lab\test\边界探针.ps1                     ← 探针（机器能验的部分）
//   C:\Users\20838\Desktop\.dsh-tools\记忆归档\FLINT编译器.md  ← 边界节的权威正文
//   C:\Users\20838\Desktop\记忆.md                     ← 速查表（FLINT 相关行）

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const argv = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : dflt;
};
const asJson = argv.includes('--json');

const here = path.dirname(fileURLToPath(import.meta.url));
const labRoot = path.resolve(here, '..');
const PROBE = path.join(labRoot, 'test', '边界探针.ps1');
const ARCHIVE = opt('--archive', 'C:\\Users\\20838\\Desktop\\.dsh-tools\\记忆归档\\FLINT编译器.md');
const MEMORY = opt('--memory', 'C:\\Users\\20838\\Desktop\\记忆.md');

const read = (p) => {
  try { return readFileSync(p, 'utf8').replace(/^\uFEFF/, ''); }
  catch (e) { return null; }
};

// ---------- 一、探针侧 ----------
const probeText = read(PROBE);
if (probeText === null) { console.error(`找不到探针文件：${PROBE}`); process.exit(2); }

// 用例块：@{ n='...'; kind='...'; ... }（跨行）
const caseBlocks = probeText.split(/@\{/).slice(1).map((s) => s.split(/\n\s*\}/)[0]);
const pick = (block, re) => { const m = block.match(re); return m ? m[1] : null; };

const cases = caseBlocks.map((b) => ({
  name: pick(b, /n='([^']*)'/),
  kind: pick(b, /kind='([^']*)'/),
  code: pick(b, /code=(\d+)/),
  err: pick(b, /err="([^"]*)"/) ?? pick(b, /err='([^']*)'/),
  note: pick(b, /note='([^']*)'/) ?? pick(b, /note="([^"]*)"/),
})).filter((c) => c.name && c.kind);

const byKind = cases.reduce((m, c) => ((m[c.kind] = (m[c.kind] || 0) + 1), m), {});
const noAssertion = cases.filter((c) => (c.kind === 'ok' && !c.code) || (c.kind === 'wall' && !c.err));
const dupNames = Object.entries(cases.reduce((m, c) => ((m[c.name] = (m[c.name] || 0) + 1), m), {}))
  .filter(([, n]) => n > 1).map(([name]) => name);

const probeHay = cases.map((c) => `${c.name} ${c.note || ''} ${c.err || ''}`).join(' ');

// ---------- 二、文档侧：边界节的 dated 记录 ----------
const archText = read(ARCHIVE);
let docRecords = [];
if (archText) {
  const lines = archText.split(/\r?\n/);
  const start = lines.findIndex((l) => /^##\s*⛔\s*FLINT 语言边界/.test(l));
  if (start >= 0) {
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) if (/^##\s/.test(lines[i])) { end = i; break; }
    docRecords = lines.slice(start + 1, end)
      .filter((l) => /^- \[20\d\d-\d\d-\d\d/.test(l))
      .map((l) => l.replace(/^- /, '').trim());
  }
}
const staleMark = /作废|订正|已修|旧写|过期|不再是|已被/;
const stale = docRecords.filter((r) => staleMark.test(r));

// ---------- 三、记忆侧：FLINT 相关速查行 ----------
const memText = read(MEMORY);
let memRows = [];
if (memText) {
  memRows = memText.split(/\r?\n/)
    .filter((l) => /^\|/.test(l))
    .filter((l) => /FLINT|指针|struct|全局|api|boot|char|边界/.test(l));
}

// ---------- 四、疑似未覆盖（关键词近似，需人核）----------
const VOCAB = ['sizeof', '转型', 'ptr', 'long long', 'int64', '无符号', '整体初始化', '相邻字符串',
  '转义', '全局', 'struct', '字段', '参数', '栈参', '回调', '函数指针', 'api', '导入', '模块名',
  '指针', '引用', 'new', 'own', 'share', '异常', '泛型', '闭包', '枚举', 'const', '并发', '线程',
  'switch', '三元', '浮点', 'double', '取模', '除法', '位运算', '容量', '上限', '数组', 'char'];
const uncovered = [];
for (const r of docRecords) {
  if (staleMark.test(r)) continue;                    // 自带"作废/订正"的不算欠覆盖
  const hits = VOCAB.filter((v) => r.includes(v) && !probeHay.includes(v));
  if (hits.length) uncovered.push({ terms: hits, rec: r.slice(0, 110) });
}

// ---------- 输出 ----------
const summary = {
  探针: { 文件: PROBE, 用例数: cases.length, 按类型: byKind, 缺实质断言: noAssertion.map((c) => c.name), 重名: dupNames },
  文档: { 文件: ARCHIVE, 边界记录数: docRecords.length, 自带作废订正标记: stale.length },
  记忆: { 文件: MEMORY, FLINT相关速查行: memRows.length },
  疑似未覆盖: uncovered.length,
};

if (asJson) {
  console.log(JSON.stringify({ summary, 疑似未覆盖明细: uncovered, 探针清单: cases }, null, 2));
} else {
  const L = (s = '') => console.log(s);
  L('===== FLINT 边界覆盖对账（只读）=====');
  L(`探针 : ${PROBE}`);
  L(`文档 : ${ARCHIVE}`);
  L(`记忆 : ${MEMORY}`);
  L('');
  L(`[1] 探针用例 ${cases.length} 条 —— ${Object.entries(byKind).map(([k, v]) => `${k} ${v}`).join(' ／ ')}`);
  L(`    缺实质断言的用例（假检验风险）: ${noAssertion.length ? noAssertion.map((c) => c.name).join(', ') : '无'}`);
  L(`    重名用例: ${dupNames.length ? dupNames.join(', ') : '无'}`);
  L('');
  L(`[2] 边界节 dated 记录 ${docRecords.length} 条，其中**自带"作废/订正"标记** ${stale.length} 条（陈旧信号，需人核是否已回填）`);
  L(`[3] 记忆.md 里 FLINT 相关速查行 ${memRows.length} 行（这些是"人必须记住"的口径，不是全部可探针化）`);
  L('');
  L(`[4] 疑似**没有探针覆盖**的文档记录 ${uncovered.length} 条（关键词近似匹配 ⇒ **需人核**，不是结论）：`);
  for (const u of uncovered.slice(0, 20)) L(`    · [${u.terms.join('/')}] ${u.rec}`);
  if (uncovered.length > 20) L(`    …另有 ${uncovered.length - 20} 条（--json 看全量）`);
  L('');
  L('说明：本工具只做对账与体检，不判"该不该做探针"——那要人来定。');
}
process.exit(0);
