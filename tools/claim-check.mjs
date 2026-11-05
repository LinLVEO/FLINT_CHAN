// claim-check.mjs -- 扫 A 类文档里的「裸写断言」（2026-11-05 立）
//
// 宗旨：文档里每一句"会过期的话"都要能核到真值源（见 docs\文档书写规则.md）。
// 本工具只做**体检**，不改文档；输出"违规清单"，人工/Agent 逐条修。
//
// 判定（保守，宁可少报）：
//   1. 行内含 没有/不支持/未实现/做不到/缺失 之一；
//   2. 该行不在代码块（``` 之间）里；
//   3. 该行没有 `<!--claim:`，也没有"截至/截至:"字样；
//   4. 跳过 诊断ID表.md（那些是错误文案，不是能力断言）与 文档书写规则.md（本身是规则）。
//
// 用法：node tools\claim-check.mjs [--json]

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const A_DIRS = ['docs'];
const A_FILES = ['SPEC.md', 'README.md', '开源前-人类可用性缺口.md', '可用性路线图-人机两条线.md'];
const SKIP = new Set(['诊断ID表.md', '文档书写规则.md']);
const PAT = /没有|不支持|未实现|做不到|缺失/;

function collect() {
  const out = [];
  for (const d of A_DIRS) {
    const dir = path.join(ROOT, d);
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.md')) continue;
      if (SKIP.has(f)) continue;
      out.push(path.join(dir, f));
    }
  }
  for (const f of A_FILES) {
    const p = path.join(ROOT, f);
    if (fs.existsSync(p)) out.push(p);
  }
  return out;
}

const violations = [];
for (const file of collect()) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*```/.test(line)) { inFence = !inFence; continue; }
    if (inFence) continue;
    if (!PAT.test(line)) continue;
    if (line.includes('<!--claim:')) continue;
    if (/截至/.test(line)) continue;
    violations.push({ file: rel, line: i + 1, text: line.trim().slice(0, 120) });
  }
}

if (process.argv.includes('--json')) {
  console.log(JSON.stringify(violations, null, 2));
} else {
  console.log(`裸写断言：${violations.length} 条（${collect().length} 个 A 类文档）`);
  for (const v of violations) {
    console.log(`${v.file}:${v.line}  ${v.text}`);
  }
}
process.exit(violations.length > 0 ? 1 : 0);
