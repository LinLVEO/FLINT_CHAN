// api-test-native.mjs -- 原生服务端的契约子集测试（对应 editor\api-test.mjs 的前 5 组）
// 用法：node apps\studio_native\api-test-native.mjs
// 说明：只测已落地的端点；未实现的端点（file/save/edit/compile/run/search）在报告里单列。

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const EXE = path.join(HERE, 'studio_server.exe');
const PORT = 8899;   // 服务端固定监听 8899（与 capabilities.json 的 editorPort 一致）
const BASE = 'http://127.0.0.1:' + PORT;

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log('  OK   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? '   <-- ' + extra : '')); }
};
const jget = async (p) => (await fetch(BASE + p)).json();
// SSE 用裸 http 连接（agent:false）：undici 的 fetch 在流被中断后会把连接池搞脏，
// 后续同源请求全部 "other side closed"（实测：只有加了 SSE 订阅才复现）。
function sseCollect(ms, untilRe) {
  return new Promise((resolve) => {
    let text = '';
    let done = false;
    const fin = () => { if (!done) { done = true; try { req.destroy(); } catch {} resolve(text); } };
    const req = http.get(BASE + '/api/events', { agent: false }, (res) => {
      res.setEncoding('utf8');
      res.on('data', (d) => {
        text += d;
        if (untilRe && untilRe.test(text)) setTimeout(fin, 60);
      });
    });
    req.on('error', () => fin());
    setTimeout(fin, ms);
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (!fs.existsSync(EXE)) { console.error('missing ' + EXE); process.exit(1); }

const child = spawn(EXE, [], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
let log = '';
child.stdout.on('data', (d) => { log += d; });
child.stderr.on('data', (d) => { log += d; });

let up = false;
for (let i = 0; i < 60; i++) {
  try { const h = await fetch('http://127.0.0.1:8899/api/health'); if (h.ok) { up = true; break; } } catch {}
  await sleep(50);
}
ck('原生服务起来（/api/health 可 fetch）', up, log.slice(-200));

try {
  if (up) {
    const h = await (await fetch('http://127.0.0.1:8899/api/health')).json();
    ck('health: ok=true 且 mode=native', h.ok === true && h.mode === 'native', JSON.stringify(h));

    const cap = await (await fetch('http://127.0.0.1:8899/api/capabilities')).json();
    ck('capabilities: ok/version', cap.ok === true && cap.version === 1, JSON.stringify(cap).slice(0, 120));
    const impl = (cap.editor || []).filter((x) => x.status === 'implemented').length;
    const req = (cap.editor || []).filter((x) => x.status === 'required').length;
    ck('capabilities: editor 段可解析（' + impl + ' implemented / ' + req + ' required）', impl >= 17 && req === 0);
    ck('capabilities: debugger 段存在（≥16）', Array.isArray(cap.debugger) && cap.debugger.length >= 16);

    // 状态镜像：POST 后 revision 递增，GET 读回原文
    const b1 = await (await fetch('http://127.0.0.1:8899/api/editor/state')).json();
    const body = { tabs: [{ path: 'demo.fl', dirty: true, revision: 7 }], active: 'demo.fl', cursor: { line: 3, col: 5, offset: 42 }, selection: { start: 40, end: 42 } };
    const p1 = await (await fetch('http://127.0.0.1:8899/api/editor/state', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    })).json();
    ck('editor/state: POST 被接收且 revision 递增', p1.ok === true && p1.revision > b1.revision, JSON.stringify(p1));
    const st = await (await fetch('http://127.0.0.1:8899/api/editor/state')).json();
    const m = st.mirror || {};
    ck('editor/state: GET 读回 tab/光标/选区', m.active === 'demo.fl' && m.cursor?.line === 3 && m.selection?.end === 42, JSON.stringify(st).slice(0, 200));

    const sse = await sseCollect(1200, /event: ready/);
    ck('SSE: /api/events 推出 ready 事件', /event: ready/.test(sse), JSON.stringify(sse).slice(0, 160));

    const r404 = await fetch('http://127.0.0.1:8899/api/nope');
    const j404 = await r404.json();
    ck('未知路由: 404 + E-ROUTE', r404.status === 404 && j404.code === 'E-ROUTE', JSON.stringify(j404));

    // ---------- 文件类 ----------
    const ws = await (await fetch('http://127.0.0.1:8899/api/workspace')).json();
    ck('workspace: 返回绝对根目录', ws.ok === true && /FLINT-lab/i.test(ws.root), JSON.stringify(ws));

    const rd = await (await fetch('http://127.0.0.1:8899/api/file?path=README.md')).json();
    ck('file: 读到 README.md 且带 bytes', rd.ok === true && typeof rd.src === 'string' && rd.src.length > 100 && rd.bytes > 100, JSON.stringify({ ok: rd.ok, bytes: rd.bytes }));

    const target = 'tmp/studio-native-save.fl';
    const payload = { path: target, src: 'int main() { return 42; }\n' };
    const sv = await (await fetch('http://127.0.0.1:8899/api/save', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    })).json();
    ck('save: 写入成功并报字节数', sv.ok === true && sv.bytes === Buffer.byteLength(payload.src), JSON.stringify(sv));
    ck('save: 磁盘内容一致', fs.readFileSync(path.join(ROOT, target), 'utf8') === payload.src);

    const back = await (await fetch('http://127.0.0.1:8899/api/file?path=' + encodeURIComponent(target))).json();
    ck('file: 读回刚保存的内容', back.ok === true && back.src === payload.src, JSON.stringify(back).slice(0, 120));

    const esc = await (await fetch('http://127.0.0.1:8899/api/file?path=../escape.fl')).json();
    ck('file: 越工作区报 E-PATH', esc.ok === false && esc.code === 'E-PATH', JSON.stringify(esc));
    const nof = await (await fetch('http://127.0.0.1:8899/api/file?path=no_such_file.fl')).json();
    ck('file: 不存在报 E-NOFILE', nof.ok === false && nof.code === 'E-NOFILE', JSON.stringify(nof));

    // ---------- 编辑器改文件（字节偏移）----------
    const editRel = 'tmp/studio-native-edit.fl';
    const editAbs = path.join(ROOT, editRel);
    fs.mkdirSync(path.dirname(editAbs), { recursive: true });
    fs.writeFileSync(editAbs, 'line1\nline2\n', 'utf8');
    const post = (p, o) => fetch(BASE + p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(o) }).then((r) => r.json());

    const e1 = await post('/api/editor/edit', { path: editRel, start: 0, end: 0, text: 'TOP\n' });
    ck('edit: 插入返回新长度', e1.ok === true && e1.length === Buffer.byteLength('TOP\nline1\nline2\n'), JSON.stringify(e1));
    ck('edit: 磁盘内容正确', fs.readFileSync(editAbs, 'utf8') === 'TOP\nline1\nline2\n');

    const e2 = await post('/api/editor/edit', { path: editRel, start: 0, end: 4, text: '' });
    ck('edit: 删除返回新长度', e2.ok === true && e2.length === Buffer.byteLength('line1\nline2\n'), JSON.stringify(e2));

    const e3 = await post('/api/editor/edit', { path: editRel, start: 9999, end: 9999, text: 'x' });
    ck('edit: 越界报 E-RANGE（不静默截断）', e3.ok === false && e3.code === 'E-RANGE', JSON.stringify(e3));

    const e4 = await post('/api/editor/edit', { path: '../escape.fl', start: 0, end: 0, text: 'x' });
    ck('edit: 越工作区报 E-PATH', e4.ok === false && e4.code === 'E-PATH', JSON.stringify(e4));

    await post('/api/editor/state', { tabs: [{ path: editRel, dirty: true, revision: 1 }], active: editRel });
    const e5 = await post('/api/editor/edit', { path: editRel, start: 0, end: 0, text: 'X' });
    ck('edit: 文件脏时被拒（E-DIRTY，需 force）', e5.ok === false && e5.code === 'E-DIRTY', JSON.stringify(e5));

    // ---------- 目录 ----------
    const dirs = await (await fetch(BASE + '/api/dirs')).json();
    ck('dirs: 列出子目录且跳过 .git', dirs.ok === true && dirs.count >= 3 && !JSON.stringify(dirs).includes('".git"'), JSON.stringify({ count: dirs.count }));
    const files = await (await fetch(BASE + '/api/files')).json();
    ck('files: 递归列出 .fl 文件', files.ok === true && files.count >= 50 && /\.fl"/.test(JSON.stringify(files.files || [])), JSON.stringify({ count: files.count }).slice(0, 80));

    // ---------- 库 / 搜索 / 命令 ----------
    const libs = await (await fetch(BASE + '/api/libs')).json();
    ck('libs: 列出 lib/*.fl', libs.ok === true && libs.count >= 10 && /lib\/flgui/.test(JSON.stringify(libs.libs || [])), JSON.stringify({ count: libs.count }));

    const sr = await (await fetch(BASE + '/api/search?q=hlc.exe')).json();
    ck('search: 字面量有命中且带路径/行号', sr.ok === true && sr.count >= 1 && !!sr.matches[0].path && sr.matches[0].line >= 1, JSON.stringify(sr).slice(0, 120));
    const srRe = await (await fetch(BASE + '/api/search?q=' + encodeURIComponent('u?int_6[48]') + '&regex=1')).json();
    ck('search: 正则（可选字符 + 字符类）可用', srRe.ok === true && srRe.count >= 1, JSON.stringify(srRe).slice(0, 120));

    const cmd = await post('/api/editor/command', { cmd: 'goto', line: 3 });
    ck('command: goto 被接受并回显行号', cmd.ok === true && cmd.command.line === 3, JSON.stringify(cmd));
    const cmdBad = await post('/api/editor/command', { cmd: 'rm-rf' });
    ck('command: 未知命令报 E-CMD', cmdBad.ok === false && cmdBad.code === 'E-CMD', JSON.stringify(cmdBad));

    // ---------- 编译 ----------
    const badSrc = 'int main() {\n  int_64 big = 1;\n  int small = big;\n  return small;\n}\n';
    const bad = await post('/api/compile', { src: badSrc, path: '' });
    ck('compile: 坏程序 ok=false', bad.ok === false, (bad.error || '').slice(0, 80));
    ck('compile: 返回结构化 diagnostics', Array.isArray(bad.diagnostics) && bad.diagnostics.length >= 1, JSON.stringify(bad.diagnostics || null).slice(0, 160));
    const d0 = (bad.diagnostics || [])[0] || {};
    ck('compile: 诊断带行列（第 3 行）', d0.line === 3 && d0.col > 0, JSON.stringify({ line: d0.line, col: d0.col }));
    ck('compile: 诊断带可执行改法（fix 非空）', typeof d0.fix === 'string' && d0.fix.length > 0, JSON.stringify(d0.fix));

    // ---------- run / jobs ----------
    const run1 = await post('/api/run', { path: 'hlc.exe', args: [], timeoutMs: 5000 });
    ck('run: 返回 jobId', run1.ok === true && typeof run1.jobId === 'string', JSON.stringify(run1));
    let job = null;
    for (let i = 0; i < 40; i++) {
      job = await (await fetch(BASE + '/api/jobs/' + run1.jobId)).json();
      if (job.status !== 'running') break;
      await sleep(50);
    }
    ck('jobs: 跑完且状态 done', !!job && job.status === 'done', JSON.stringify(job).slice(0, 120));
    ck('jobs: 捕获输出（flint 用法文本）', /用法/.test((job.stdout || '')), JSON.stringify((job.stdout || '').slice(0, 60)));
    ck('jobs: 有退出码与耗时', job.exitCode !== null && job.ms >= 0, String(job.exitCode));
    const runBad = await post('/api/run', { path: 'README.md' });
    ck('run: 非 .exe 报 E-NOTEXE', runBad.ok === false && runBad.code === 'E-NOTEXE', JSON.stringify(runBad));
    const runEsc = await post('/api/run', { path: '../evil.exe' });
    ck('run: 越工作区报 E-PATH', runEsc.ok === false && runEsc.code === 'E-PATH', JSON.stringify(runEsc));


    const dg = await (await fetch(BASE + '/api/diagnostics')).json();
    ck('diagnostics: 能读到刚才那次', dg.ok === true && dg.diagnostics.length >= 1, JSON.stringify(dg).slice(0, 120));
    // ---------- 调试产物 ----------
    const cj = await post('/api/compile', { src: 'int main() { int a = 7; return a; }\n', debug: true, keep: true });
    ck('compile: {debug:true,keep:true} 成功', cj.ok === true, JSON.stringify(cj).slice(0, 100));
    const allThere = !!cj.exePath && fs.existsSync(cj.exePath) && !!cj.mapPath && fs.existsSync(cj.mapPath) && !!cj.tsvPath && fs.existsSync(cj.tsvPath);
    ck('compile: exePath/mapPath/tsvPath 都存在', allThere, JSON.stringify({ exe: cj.exePath, map: cj.mapPath }));
    let dbgmap = null;
    try { dbgmap = JSON.parse(fs.readFileSync(cj.mapPath, 'utf8')); } catch {}
    ck('compile: 调试旁文件可解析（version 1 + functions）', !!dbgmap && dbgmap.version === 1 && Array.isArray(dbgmap.functions) && dbgmap.functions.length >= 1);
    for (const f of [cj.exePath, cj.mapPath, cj.tsvPath]) { try { fs.unlinkSync(f); } catch {} }


    // SSE：订阅后再编译，应收到 compileFinished
    {
      const pending = sseCollect(2000, /compileFinished/);
      await sleep(150);
      // 订阅期间再发编译：显式 Connection: close，避开 undici 的连接池复用
      //   （手动 curl 验证过服务端没问题；失败的是测试客户端的 keep-alive 复用）
      // 用裸 http 发（agent:false），与 SSE 走同一条"不池化"的路
      let okC = false;
      try {
        const jj = await new Promise((resolve) => {
          const body = JSON.stringify({ src: 'int main() { return 0; }\n' });
          const rq = http.request(BASE + '/api/compile', { method: 'POST', agent: false, headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, (rs) => {
            let t = '';
            rs.setEncoding('utf8');
            rs.on('data', (d) => { t += d; });
            rs.on('end', () => { try { resolve(JSON.parse(t)); } catch { resolve({}); } });
          });
          rq.on('error', () => resolve({}));
          rq.write(body);
          rq.end();
        });
        okC = jj.ok === true;
      } catch (e) { okC = false; }
      ck('SSE: 订阅期间仍能编译', okC);
      const evText = await pending;
      ck('SSE: 推到 compileFinished', /compileFinished/.test(evText), JSON.stringify(evText.slice(0, 120)));
    }

    const good = await post('/api/compile', { src: 'int main() { print(["hi ", 2 + 3, "\\n"]); return 0; }\n', path: '' });
    ck('compile: 好程序 ok=true 且 exitCode=0', good.ok === true && good.exitCode === 0, JSON.stringify(good).slice(0, 100));
    ck('compile: 程序 stdout 被捕获（hi 5）', /hi 5/.test(good.stdout || ''), JSON.stringify(good.stdout));
    ck('compile: 失败诊断被清空', Array.isArray(good.diagnostics) && good.diagnostics.length === 0);
  }
} finally {
  try { child.kill(); } catch {}
}

// ---------- headless（主进程已退出，复用同一端口）----------
{
  const h = spawn(EXE, ['--headless'], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let hlog = '';
  h.stdout.on('data', (d) => { hlog += d; });
  try {
    let up = false;
    for (let i = 0; i < 60; i++) {
      try { const r = await fetch('http://127.0.0.1:8899/api/health'); if (r.ok) { up = true; break; } } catch {}
      await sleep(50);
    }
    ck('headless: 能起来', up, hlog.slice(-120));
    if (up) {
      const hh = await (await fetch('http://127.0.0.1:8899/api/health')).json();
      ck('headless: health.mode = headless', hh.mode === 'headless', JSON.stringify(hh));
      const ui = await fetch('http://127.0.0.1:8899/');
      const uib = await ui.json().catch(() => ({}));
      ck('headless: 不发前端（404 + E-HEADLESS）', ui.status === 404 && uib.code === 'E-HEADLESS', JSON.stringify(uib));
    }
  } finally {
    try { h.kill(); } catch {}
  }
}

console.log('----');
console.log('原生契约子集：通过 ' + pass + ' / 失败 ' + fail);
const missing = [];
console.log('未实现（下一轮）：' + missing.join(' '));
process.exit(fail > 0 ? 1 : 0);
