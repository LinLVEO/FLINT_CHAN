#!/usr/bin/env node
// skill状态.mjs —— FLC skill 的「入口事实」，一条命令现取，永不抄数。
//
// 存在理由：skill 是静态文件，写进去的数字必然过期（v1 的「633 项 / 27/27 / 512 项 / int 8 字节槽」全死了）。
//   ⇒ skill 正文不许存值，只许存「取值的命令」。本脚本就是那条命令。
//
// 用法：
//   node tools/skill状态.mjs            # 打印此刻的状态摘要
//   node tools/skill状态.mjs --json     # 同上，机器可读
//   node tools/skill状态.mjs --check    # 自检 SKILL.md 有没有腐坏（路径失效 / 裸数字残留）
//
// 退出码：0 = 正常；1 = --check 发现腐坏（可当门用）。

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SKILL = path.join(process.env.USERPROFILE || '', '.dsh', 'skills', 'flint-dev', 'SKILL.md');
const argv = process.argv.slice(2);
const asJson = argv.includes('--json');
const doCheck = argv.includes('--check');

function git(args) {
  try {
    return execFileSync('git', ['-c', 'core.quotepath=false', ...args], {
      cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch { return ''; }
}

function countLines(dir, filter) {
  let files = 0, lines = 0;
  const walk = (d) => {
    if (!fs.existsSync(d)) return;
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (filter(e.name)) {
        files++;
        lines += fs.readFileSync(p, 'utf8').split('\n').length;
      }
    }
  };
  walk(dir);
  return { files, lines };
}

function countMd(dir) {
  if (!fs.existsSync(dir)) return 0;
  return fs.readdirSync(dir).filter(f => f.endsWith('.md')).length;
}

const now = new Date();
const local = (d) => new Date(d).toLocaleString('sv-SE').slice(0, 16); // YYYY-MM-DD HH:mm，本地时区
const head = git(['log', '-1', '--format=%h|%ad|%s', '--date=format:%Y-%m-%d %H:%M']);
const [headHash, headDate, headSubj] = head ? head.split('|') : ['?', '?', '?'];
const branch = git(['rev-parse', '--abbrev-ref', 'HEAD']);
const dirty = git(['status', '--porcelain']).split('\n').filter(Boolean).length;

const src = countLines(path.join(ROOT, 'src'), n => !n.includes('.bak') && /\.(c|h)$/.test(n));
const lib = countLines(path.join(ROOT, 'lib'), n => n.endsWith('.fl'));
const boot = countLines(path.join(ROOT, 'boot'), n => n.endsWith('.fl'));

const hlcPath = path.join(ROOT, 'hlc.exe');
const hlc = fs.existsSync(hlcPath)
  ? { bytes: fs.statSync(hlcPath).size, mtime: local(fs.statSync(hlcPath).mtime) }
  : null;

const docs = {
  root: countMd(ROOT),
  docs: countMd(path.join(ROOT, 'docs')),
  notes: countMd(path.join(ROOT, 'notes')),
  archive: countMd(path.join(ROOT, 'archive')),
};

const skill = fs.existsSync(SKILL)
  ? { path: SKILL, mtime: local(fs.statSync(SKILL).mtime) }
  : null;

if (doCheck) {
  const problems = [];
  if (!skill) {
    console.log('SKILL-CHECK  FAIL 找不到 SKILL.md：' + SKILL);
    process.exit(1);
  }
  const text = fs.readFileSync(SKILL, 'utf8');

  // 1) 反引号里的路径必须存在（相对仓库根解析）
  //    反引号里常是整条命令（`node tools/x.mjs --check`），所以先切 token，
  //    再挑"看起来是仓库路径"的那个；纯扩展名（`.ps1`）与模板占位（NN）跳过。
  const raw = [...text.matchAll(/`([^`\n]+)`/g)].map(m => m[1]);
  const paths = [];
  for (const s of raw) {
    for (const tok of s.split(/[\s，、（）()]+/)) {
      if (!tok || tok.includes('<') || tok.includes('*')) continue;
      if (/^\.\w+$/.test(tok)) continue;                 // 纯扩展名
      if (/NN/.test(tok)) continue;                      // 模板占位
      const isRepoPath = /^(src|lib|boot|apps|test|tools|docs|notes|archive)[\\/]/.test(tok);
      const isRootDoc = /^[^\\/\s]+\.md$/.test(tok);
      if (isRepoPath || isRootDoc) paths.push(tok);
    }
  }
  for (const p of [...new Set(paths)]) {
    const abs = path.join(ROOT, p.replace(/[\\/]/g, path.sep));
    if (!fs.existsSync(abs)) problems.push('路径失效  ' + p);
  }

  // 2) 裸数字残留（v1 的死法）：`27/27`、`512 项`、`8 字节槽`、`633 项`
  const banned = [
    [/\b\d+\s*\/\s*\d+\b/g, '比例式数字（如 27/27）'],
    [/\b\d+\s*(项|格|条|字节槽)\b/g, '带单位的裸数字（如 512 项）'],
  ];
  const lines = text.split('\n');
  for (const [rx, why] of banned) {
    lines.forEach((ln, i) => {
      if (/^\s*>/.test(ln)) return;            // 引用块里允许（讲历史教训）
      for (const m of ln.matchAll(rx)) problems.push(`裸数字 ${why}：「${m[0]}」 @SKILL.md:${i + 1}`);
    });
  }

  if (problems.length) {
    console.log('SKILL-CHECK  RED  ' + problems.length + ' 个问题');
    [...new Set(problems)].forEach(p => console.log('  ' + p));
    console.log('\n修法：值要么删掉换成命令，要么放进引用块说明是历史。');
    process.exit(1);
  }
  console.log(`SKILL-CHECK  GREEN  路径 ${paths.length} 处全部存在，无裸数字残留`);
  console.log(`  与仓库同步：SKILL.md ${skill.mtime} ／ HEAD ${headDate}`);
  process.exit(0);
}

const out = {
  at: local(now),
  head: { hash: headHash, date: headDate, subject: headSubj, branch, dirty },
  src, lib, boot, hlc, docs, skill,
};

if (asJson) {
  console.log(JSON.stringify(out, null, 2));
} else {
  console.log(`FLINT 状态（${out.at}）`);
  console.log(`  HEAD        ${headHash}  ${branch}  ${headDate}`);
  console.log(`  最近提交    ${headSubj}`);
  console.log(`  工作区       ${dirty === 0 ? '干净' : dirty + ' 个未提交改动'}`);
  console.log(`  源码        src ${src.files} 文件 / ${src.lines} 行 ｜ lib ${lib.files} / ${lib.lines} ｜ boot ${boot.files} / ${boot.lines}`);
  console.log(`  hlc.exe     ${hlc ? hlc.bytes + ' 字节 @ ' + hlc.mtime : '不存在（先构建）'}`);
  console.log(`  文档        根 ${docs.root} ｜ docs ${docs.docs} ｜ notes ${docs.notes} ｜ archive ${docs.archive}`);
  console.log(`  skill       ${skill ? skill.mtime : '找不到 SKILL.md'}`);
  console.log('');
  console.log('下一步（慢门不预跑，要时再跑）：');
  console.log('  node test/docgate.mjs               文档门');
  console.log('  powershell -File test/边界探针.ps1   语言边界（ok 必编过 / wall 必硬错 / gap 必须 0）');
  console.log('  powershell -File test/verify-all.ps1  总门');
  console.log('  node tools/skill状态.mjs --check     skill 自身有没有腐坏');
}
