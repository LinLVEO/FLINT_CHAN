// 错误记录.mjs -- 实际运行出错时，把现场（命令 / 输出 / 退出码 / 源码片段）落到 errors\
//
// 为什么要有它：编译器报错、产物跑挂的时候，最有价值的现场是"当时到底跑了什么、原样输出是什么"，
//   而这三样几乎总是过一会儿就记不清。这个工具只做一件事：**失败才记录**，成功零噪音。
//
// 用法：
//   node tools\错误记录.mjs build <源文件.fl> [flint 的其它参数...]
//   node tools\错误记录.mjs run   <可执行文件> [它自己的参数...]
//
// 行为：
//   · 子进程退出码 = 0  ⇒ 原样透传输出，不落盘；
//   · 退出码 ≠ 0 / 启动失败 ⇒ 写 errors\<时间戳>-<模式>.log（含命令、cwd、退出码、stdout、stderr、
//     以及源文件哈希与最多 60 行摘录），并在 errors\索引.md 追加一行；退出码原样透传。
//   · 输出编码：先按 UTF-8，出现替换字符再按 GBK 解（Windows 控制台中文）。
//
// 环境变量 ERR_REC_NO_LOG=1 可强制不落盘（只想跑不想记的时候）。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const ERR_DIR = path.join(ROOT, 'errors');

function decode(buf) {
  if (!buf || buf.length === 0) return '';
  const utf8 = buf.toString('utf8');
  if (!utf8.includes('\uFFFD')) return utf8;
  try { return new TextDecoder('gbk').decode(buf); } catch { return utf8; }
}

function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function sha16(file) {
  try { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').slice(0, 16); } catch { return '(读不到)'; }
}

function writeLog({ mode, cmdline, cwd, code, signal, stdout, stderr, srcFile }) {
  fs.mkdirSync(ERR_DIR, { recursive: true });
  const ts = stamp();
  const logPath = path.join(ERR_DIR, `${ts}-${mode}.log`);
  const out = [];
  out.push('# 错误记录（机器生成）');
  out.push('');
  out.push(`- 时间: ${new Date().toLocaleString('zh-CN', { hour12: false })}`);
  out.push(`- 模式: ${mode}`);
  out.push(`- 命令行: \`${cmdline}\``);
  out.push(`- 工作目录: ${cwd}`);
  out.push(`- 退出码: ${code === null ? '(启动失败)' : code}${signal ? '  signal=' + signal : ''}`);
  if (srcFile && fs.existsSync(srcFile)) {
    const st = fs.statSync(srcFile);
    const lines = fs.readFileSync(srcFile, 'utf8').split(/\r?\n/).slice(0, 60);
    out.push(`- 源文件: ${path.relative(ROOT, srcFile)}  ${st.size} B  sha256:${sha16(srcFile)}`);
    out.push('');
    out.push('## 源码摘录（前 60 行）');
    out.push('```');
    out.push(...lines);
    out.push('```');
  }
  out.push('');
  out.push('## stdout');
  out.push('```');
  out.push(stdout.trimEnd());
  out.push('```');
  out.push('');
  out.push('## stderr');
  out.push('```');
  out.push(stderr.trimEnd());
  out.push('```');
  out.push('');
  fs.writeFileSync(logPath, out.join('\n'), 'utf8');

  const idx = path.join(ERR_DIR, '索引.md');
  if (!fs.existsSync(idx)) fs.writeFileSync(idx, '# 错误记录索引（机器生成）\n\n| 时间 | 模式 | 退出码 | 涉及文件 | 日志 |\n|---|---|---|---|---|\n', 'utf8');
  const rel = path.relative(ERR_DIR, logPath).replace(/\\/g, '/');
  fs.appendFileSync(idx, `| ${ts} | ${mode} | ${code === null ? 'SPAWN' : code} | ${srcFile ? path.basename(srcFile) : '-'} | [${rel}](${rel}) |\n`, 'utf8');
  return logPath;
}

const argv = process.argv.slice(2);
const mode = argv[0];
if (mode !== 'build' && mode !== 'run') {
  console.error('用法:\n  node tools\\错误记录.mjs build <源文件.fl> [flint 参数...]\n  node tools\\错误记录.mjs run <可执行文件> [参数...]');
  process.exit(2);
}
const rest = argv.slice(1);
if (rest.length === 0) { console.error('缺目标：build 需要 .fl 源文件，run 需要可执行文件'); process.exit(2); }

let exe, args, srcFile = null, display;
if (mode === 'build') {
  srcFile = path.resolve(ROOT, rest[0]);
  exe = path.join(ROOT, 'flint.exe');
  args = [srcFile, ...rest.slice(1)];
  display = `flint.exe ${rest.join(' ')}`;
} else {
  const cand = path.resolve(ROOT, rest[0]);
  exe = fs.existsSync(cand) ? cand : rest[0];   // 允许直接写 PATH 里的程序名（如 cmd）
  args = rest.slice(1);
  display = `${rest[0]} ${args.join(' ')}`.trim();
}

const r = spawnSync(exe, args, { cwd: ROOT, encoding: 'buffer', windowsHide: true });
const stdout = decode(r.stdout);
const stderr = decode(r.stderr);
const code = r.error ? null : r.status;

process.stdout.write(stdout);
process.stderr.write(stderr);

if (r.error) {
  console.error(`\n[错误记录] 启动失败: ${r.error.message}`);
  if (!process.env.ERR_REC_NO_LOG) {
    const p = writeLog({ mode, cmdline: display, cwd: ROOT, code: null, signal: null, stdout, stderr: stderr + '\n' + r.error.message, srcFile });
    console.error(`[错误记录] 已落盘: ${path.relative(ROOT, p)}`);
  }
  process.exit(127);
}

if (code !== 0 && !process.env.ERR_REC_NO_LOG) {
  const p = writeLog({ mode, cmdline: display, cwd: ROOT, code, signal: r.signal, stdout, stderr, srcFile });
  console.error(`\n[错误记录] 退出码 ${code}，现场已落盘: ${path.relative(ROOT, p)}`);
}
process.exit(code);
