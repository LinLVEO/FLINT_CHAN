#!/usr/bin/env node
// test/docgate.mjs -- FLINT documentation gate (the [doc] step of test/verify-all.ps1).
//
// WHY IT EXISTS
//   Numbers used to live in prose with no truth source, so every reader (humans and agents
//   alike) read stale values: on 2026-10-15 one reading from 2026-10-13 ("imports 96/96 full,
//   boot table 512/512 full") was still quoted in 12+ documents, and the file that existed to
//   PREVENT drift (docs/索引.md) had drifted itself. This gate makes two things mechanical
//   instead of a matter of memory:
//     * every CURRENT number is a marker whose value must equal what tools/文档事实.ps1
//       computes right now -- so a number can only ever have ONE author (the meter);
//     * every document is CLASSIFIED: outward documents need a machine-readable meta block,
//       process artifacts need an explicit snapshot banner with an absolute date.
//   Therefore: RED MEANS THE DOCUMENT IS WRONG, NOT THE GATE.
//
//   Three further criteria were added on 2026-10-16 together with the route map (PROGRESS.md,
//   section "路线总图"), to make the new "avoid conflicts" discipline mechanical instead of a
//   matter of memory: (7) a number series (D/R/W) may not be cited ambiguously, (8) every route
//   row must be registered with a runnable criterion, (9) every path the route map cites must
//   exist. All three are deliberately NARROW, and each narrowing was MEASURED on this checkout
//   before it was written down (hit lists and reasons in the block comment above criterion (7)).
//
//   Written in Node, not PowerShell, on purpose: the document names themselves are CJK, and a
//   .ps1 with CJK literals needs a BOM -- which every editor/`edit` strips, after which PS 5.1
//   decodes the file as GBK and raises FAKE syntax errors. That trap already bit this project
//   (test/flgui-verify.ps1) and bit this very gate twice while it was a .ps1. Node reads and
//   writes UTF-8 unconditionally, so the class of bug simply does not exist here.
//
// SYNTAX (all three are greppable, so a wrong claim can be traced by hand too)
//   marker      <!--fact:key-->11318<!--/fact-->   single line; key = a key of tools/文档事实.ps1
//   snapshot    a line matching:  快照：2026-09-12   (absolute date; required in process artifacts)
//   meta block  three lines containing:  元信息（机检） / 真值源= / 最后复核=
//
// USAGE
//   node test/docgate.mjs                 check; exit 0 green / 1 issues found / 2 gate failed
//   node test/docgate.mjs --fix           rewrite drifted marker VALUES in place (the value
//                                         always comes from the meter; nothing else is touched,
//                                         and the file's BOM state is preserved). The verdict and
//                                         the exit code describe the state AFTER the rewrite: if
//                                         every finding was a repairable marker value, this exits
//                                         0 and prints "re-checked after fix: GREEN". Anything a
//                                         value rewrite cannot repair (unknown key, unclosed
//                                         marker, classification/index/BOM/tracking) still exits 1.
//   node test/docgate.mjs --trace version       truth source + ledger row + every quoting doc
//   node test/docgate.mjs --trace README.md:66  which fact keys live on that line
//   node test/docgate.mjs --root <dir>          run against another checkout (self-test)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
// Flags are matched case-insensitively (2026-10-16). Why: every document and skill that
// mentions this gate writes the fix flag as "-Fix", while the parser only accepted
// "--fix"/"-fix" -- so "-Fix" ran the CHECK and silently did nothing, exiting 1 with the
// drift still in place. A silent no-op is the worst failure shape: the operator believes
// the value was rewritten. Proven by a controlled experiment before the change
// (inject a wrong marker value -> "-Fix" leaves it at 999; "--fix" restores it).
const args = process.argv.slice(2).map((a) => (a.startsWith('-') ? a.toLowerCase() : a));
const hasFlag = (n) => args.includes('--' + n) || args.includes('-' + n);
const optVal = (n) => {
  const i = args.findIndex((a) => a === '--' + n || a === '-' + n);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
};
const FIX = hasFlag('fix');
const TRACE = optVal('trace');
const ROOT = path.resolve(optVal('root') || path.join(HERE, '..'));
const METER = path.join(ROOT, 'tools', '文档事实.ps1');
const LEDGER = path.join(ROOT, 'docs', '数字台账.md');

if (!fs.existsSync(METER)) {
  console.log('DOCGATE FAIL: tools/文档事实.ps1 not found -- the meter is the single source of numbers');
  process.exit(2);
}

// --------------------------------------------------------------- meter access
const cache = new Map();
function factValue(key) {
  if (cache.has(key)) return cache.get(key);
  let val = null;
  try {
    const out = execFileSync('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', METER, '-Key', key],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    val = String(out).split(/\r?\n/)[0].trim();
    if (val === '') val = null;
  } catch { val = null; }
  cache.set(key, val);
  return val;
}

const readDoc = (p) => fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
const hasBom = (p) => { const b = fs.readFileSync(p); return b.length >= 3 && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF; };
const writeDoc = (p, text) => fs.writeFileSync(p, (hasBom(p) ? '\uFEFF' : '') + text, 'utf8');
const lineOf = (text, index) => text.slice(0, index).split('\n').length;

// ------------------------------------------------------------- classification
// outward      : read by outsiders -> meta block + fact markers for every current number
// snapshot     : a dated process artifact -> must carry an explicit snapshot banner
// generated    : machine-written (docs/数字台账.md) -> exempt; it even documents the marker
//                syntax, so scanning it yields fake "unclosed marker" hits
// archive      : append-only history + a living handover block -> exempt from the banner rule
// unclassified : none of the above -> RED (forces a decision instead of silent rot)
const OUTWARD = [
  'README.md', 'SPEC.md', 'FLINT明细.md', '开源前-人类可用性缺口.md', '可用性路线图-人机两条线.md',
  '方向-对外一席之地（2026-10-13 用户口径变更）.md', 'lib/FLGUI.md',
  'docs/协作协议.md', 'docs/快速上手-真实项目.md', 'docs/真实项目.md', 'docs/索引.md',
  'docs/设计决策.md', 'docs/语言边界.md',
  // 2026-10-19 重写的对外技术文档（公开仓库只发这批 ＋ 根 README）
  'docs/README.md', 'docs/快速上手.md', 'docs/语言参考.md', 'docs/标准库.md', 'docs/FLGUI.md',
];
const SNAP_PATTERNS = [
  /^工单-/, /^待拍板-/, /^开工简报/, /^调研/, /^帧节拍-/, /^任务-/, /^人类试写-/,
  /^副本说明\.md$/, /^概念池\.md$/, /^学习笔记\.md$/, /^新路候选/, /^IRIS-/, /^IR重构-/,
  /^SPEC修订提案-/, /^需求勘定-/, /^FLGUI-计划\.md$/,
];
const GENERATED = ['docs/数字台账.md'];
const ARCHIVE = ['PROGRESS.md', 'PROGRESS-归档.md'];

function classify(rel) {
  if (GENERATED.includes(rel)) return 'generated';
  if (ARCHIVE.includes(rel)) return 'archive';
  if (OUTWARD.includes(rel)) return 'outward';
  const name = path.basename(rel);
  for (const rx of SNAP_PATTERNS) if (rx.test(name)) return 'snapshot';
  return 'unclassified';
}

const docs = [];
for (const f of fs.readdirSync(ROOT)) if (f.endsWith('.md')) docs.push(f);
const docsDir = path.join(ROOT, 'docs');
if (fs.existsSync(docsDir)) for (const f of fs.readdirSync(docsDir)) if (f.endsWith('.md')) docs.push('docs/' + f);
if (fs.existsSync(path.join(ROOT, 'lib', 'FLGUI.md'))) docs.push('lib/FLGUI.md');
const docList = [...new Set(docs)].sort();

// Key names are NOT restricted to ASCII: the meter has at least one key containing CJK
// (app-winpanel-验收-loc). An ASCII-only key pattern would silently IGNORE such a marker --
// the worst kind of failure, because the document would look checked while never being
// checked. Any non-space, non-'>' run is accepted here; unknown keys are still caught,
// because the meter refuses to produce a value for them (=> drift).
const RX_MARKER = /<!--fact:([^>\s]+?)-->([^<]*)<!--\/fact-->/g;
const RX_OPEN = /<!--fact:/g;
const RX_SNAP = /快照[:：]\s*20\d\d-\d\d-\d\d/;
const RX_LINK = /\]\(([^)]+)\)/g;
const RX_TICK = /`([^`\r\n]+\.md)`/g;

// --------------------------------------------------------------------- trace
if (TRACE) {
  const m = /^(.+):(\d+)$/.exec(TRACE);
  if (m) {
    const relName = m[1];
    // ROOT-relative resolution FIRST: this gate is normally invoked from some other working
    // directory, and a bare "README.md" would otherwise resolve against the caller's cwd and
    // silently read a different file (observed: "line 93 out of range (file has 46)").
    let p = path.join(ROOT, relName);
    if (!fs.existsSync(p)) p = relName;
    if (!fs.existsSync(p)) { console.log('TRACE FAIL: no such file: ' + relName); process.exit(2); }
    const lines = readDoc(p).split(/\r?\n/);
    const want = Number(m[2]);
    if (want < 1 || want > lines.length) { console.log('TRACE FAIL: line ' + want + ' out of range (file has ' + lines.length + ')'); process.exit(2); }
    console.log('LINE  ' + relName + ':' + want);
    console.log('TEXT  ' + lines[want - 1].trim());
    const found = [...lines[want - 1].matchAll(/<!--fact:([^>\s]+?)-->([^<]*)<!--\/fact-->/g)];
    if (found.length === 0) console.log('FACT  (none on this line)');
    for (const f of found) console.log('FACT  ' + f[1] + ' = ' + f[2].trim() + '   (meter now: ' + factValue(f[1]) + ')');
    process.exit(0);
  }
  const key = TRACE;
  console.log('KEY   ' + key);
  const now = factValue(key);
  console.log(now === null ? 'VALUE <unknown key, or the meter refused to produce a number (NOT_COLLECTED)>' : 'VALUE ' + now);
  let row = null;
  if (fs.existsSync(LEDGER)) {
    row = readDoc(LEDGER).split(/\r?\n/).find((l) => l.startsWith('| ' + key + ' |')) || null;
  }
  console.log(row ? 'LEDGER ' + row.trim() : 'LEDGER (no row for this key / ledger missing)');
  console.log('QUOTED BY');
  let any = false;
  for (const rel of docList) {
    const p = path.join(ROOT, rel);
    if (!fs.existsSync(p)) continue;
    const text = readDoc(p);
    for (const mm of text.matchAll(new RegExp(RX_MARKER.source, 'g'))) {
      if (mm[1] === key) { any = true; console.log('  ' + rel + ':' + lineOf(text, mm.index) + '  value=' + mm[2].trim()); }
    }
  }
  if (!any) console.log('  (nobody quotes this key yet)');
  process.exit(0);
}

// -------------------------------------------------------------------- checks
// The marker face (how many markers exist / which drifted / which are unclosed) lives in one
// function so it can be measured a second time AFTER --fix has rewritten values. This costs no
// extra measurement: factValue() memoises the meter per key, so the re-check reads the same
// already-computed numbers instead of running the meter again.
function scanMarkerFace(rel, text, wrong) {
  const out = { count: 0, drift: [], unclosed: [] };
  const matches = [...text.matchAll(new RegExp(RX_MARKER.source, 'g'))];
  const opens = [...text.matchAll(new RegExp(RX_OPEN.source, 'g'))];
  if (opens.length !== matches.length) {
    for (const o of opens) {
      if (!text.slice(o.index).includes('<!--/fact-->')) {
        out.unclosed.push(rel + ':' + lineOf(text, o.index) + '  marker not closed (need <!--fact:key-->value<!--/fact--> on one line)');
      }
    }
  }
  out.count = matches.length;
  for (const mm of matches) {
    const key = mm[1], now = mm[2].trim(), want = factValue(key);
    // An unknown key (or a key the meter refuses to compute) is NOT value drift: it can never be
    // repaired by rewriting a value, so it is never handed to the fixer and stays RED below.
    if (want === null) { out.drift.push(rel + ':' + lineOf(text, mm.index) + '  key=' + key + '  now=' + now + '  want=<UNKNOWN KEY or NOT_COLLECTED>'); continue; }
    if (now !== want) {
      out.drift.push(rel + ':' + lineOf(text, mm.index) + '  key=' + key + '  now=' + now + '  want=' + want);
      if (wrong) wrong.push([key, want]);
    }
  }
  return out;
}

const drift = [], unclosed = [], snapMissing = [], metaMissing = [], unclassified = [], linkIssues = [];
let markerCount = 0, fixedCount = 0, scanned = 0;

for (const rel of docList) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) continue;
  if (classify(rel) === 'generated') continue;
  scanned++;
  let text = readDoc(p);
  const wrong = [];
  const face = scanMarkerFace(rel, text, FIX ? wrong : null);
  unclosed.push(...face.unclosed);
  markerCount += face.count;
  drift.push(...face.drift);
  if (FIX && wrong.length > 0) {
    const wantByKey = new Map(wrong);
    text = text.replace(new RegExp(RX_MARKER.source, 'g'), (all, k, v) =>
      wantByKey.has(k) && v.trim() !== wantByKey.get(k) ? '<!--fact:' + k + '-->' + wantByKey.get(k) + '<!--/fact-->' : all);
    writeDoc(p, text);
    fixedCount += wrong.length;
  }
}

// --fix USED to print "FIXED n" and then exit 1 on the very drift it had just repaired: the check
// ran before the rewrite and the drift array was never re-derived, so the caller was told the
// document is WRONG about a file that is now correct -- which sends the operator hunting for a bug
// that no longer exists (both agents of the 2026-10-16 session wasted a round on exactly this).
// The verdict must describe the state the operator is LEFT WITH, so when the rewrite touched
// anything, re-measure the marker face from disk and let THAT feed the summary and the exit code.
// Nothing real is laundered by this: only value drift the meter itself resolved can disappear,
// while unknown keys, unclosed markers, classification, index links, BOM and untracked-outward-doc
// findings are all re-measured/computed outside this pass and still turn the gate RED.
let recheckedAfterFix = false;
if (FIX && fixedCount > 0) {
  recheckedAfterFix = true;
  drift.length = 0; unclosed.length = 0; markerCount = 0;
  for (const rel of docList) {
    const p = path.join(ROOT, rel);
    if (!fs.existsSync(p) || classify(rel) === 'generated') continue;
    const face = scanMarkerFace(rel, readDoc(p), null);
    drift.push(...face.drift); unclosed.push(...face.unclosed); markerCount += face.count;
  }
}

for (const rel of docList) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) continue;
  const cls = classify(rel);
  if (cls === 'generated' || cls === 'archive') continue;
  if (cls === 'unclassified') { unclassified.push(rel); continue; }
  const text = readDoc(p);
  if (cls === 'snapshot') {
    if (!RX_SNAP.test(text)) snapMissing.push(rel);
  } else {
    const missing = [];
    if (!text.includes('元信息（机检）')) missing.push('meta-block-marker');
    if (!text.includes('真值源=')) missing.push('truth-source-line');
    if (!text.includes('最后复核=')) missing.push('last-reviewed-line');
    if (missing.length) metaMissing.push(rel + '  (missing: ' + missing.join(', ') + ')');
  }
}

const INDEX = 'docs/索引.md';
const indexPath = path.join(ROOT, INDEX);
if (fs.existsSync(indexPath)) {
  const idx = readDoc(indexPath);
  const targets = new Set();
  for (const mm of idx.matchAll(new RegExp(RX_LINK.source, 'g'))) targets.add(mm[1]);
  for (const mm of idx.matchAll(new RegExp(RX_TICK.source, 'g'))) targets.add(mm[1]);
  for (const t of [...targets].sort()) {
    if (/^(https?:|mailto:|#)/.test(t)) continue;
    const clean = t.split('#')[0].trim();
    if (!clean) continue;
    if (clean.includes('*')) continue; // prose globs such as SPEC修订提案-*.md are not paths
    const cands = clean.startsWith('docs/') || clean.startsWith('docs\\')
      ? [path.join(ROOT, clean)]
      : [path.join(docsDir, clean), path.join(ROOT, clean)];
    if (!cands.some((c) => fs.existsSync(c))) linkIssues.push(INDEX + '  dead target: ' + clean);
  }
  for (const rel of OUTWARD) {
    const base = path.basename(rel, '.md');
    if (!idx.includes(base)) linkIssues.push(INDEX + '  does not mention outward doc: ' + rel);
  }
  // An outward document that is not tracked by git is invisible to anyone who clones:
  // the index would point at a file that does not exist for the reader, so the very first
  // step of "go get the right answer" breaks. Observed 2026-10-15: the D5 origin document
  // 方向-对外一席之地（2026-10-13 用户口径变更）.md was untracked while being listed in the index.
  for (const rel of OUTWARD) {
    try {
      execFileSync('git', ['-C', ROOT, 'ls-files', '--error-unmatch', rel], { stdio: ['ignore', 'ignore', 'ignore'] });
    } catch {
      linkIssues.push(rel + '  outward doc is NOT tracked by git -- a clone will not have it, so the index link dangles for the reader (run: git add)');
    }
  }
} else {
  linkIssues.push('docs/索引.md is missing (it is the single link hub)');
}

// (4) encoding hygiene: a PowerShell script containing non-ASCII bytes MUST carry a UTF-8 BOM.
//     PowerShell 5.1 cannot tell a BOM-less .ps1 is UTF-8, so it falls back to the system ANSI
//     codepage (GBK on this host) and CJK inside PATHS and literals turns into mojibake. This is
//     not theoretical: on 2026-10-15 an edit stripped the BOM from test/verify-all.ps1 and four of
//     its own steps (diffgate/audit/eqgate/bench -- exactly the ones whose script names are CJK)
//     died instantly with a "-File parameter" error, while steps whose CJK appears only in printed
//     text kept passing and hid the cause. Seven files were in this state that night.
const ps1Issues = [];
for (const dir of ['', 'test', 'tools', 'bench', 'boot', 'apps', 'examples', 'libcs']) {
  const abs = dir ? path.join(ROOT, dir) : ROOT;
  if (!fs.existsSync(abs)) continue;
  for (const f of fs.readdirSync(abs)) {
    if (!f.toLowerCase().endsWith('.ps1')) continue;
    const p = path.join(abs, f);
    let st; try { st = fs.statSync(p); } catch { continue; }
    if (!st.isFile()) continue;
    const b = fs.readFileSync(p);
    const hasBom = b.length >= 3 && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF;
    let nonAscii = 0;
    for (const byte of b) if (byte > 127) nonAscii++;
    if (nonAscii > 0 && !hasBom) {
      ps1Issues.push((dir ? dir + '/' : '') + f + '  has ' + nonAscii +
        ' non-ASCII byte(s) but NO UTF-8 BOM -- PowerShell 5.1 will decode it as the ANSI codepage (GBK) and CJK in paths/literals becomes mojibake (fix: prepend EF BB BF)');
    }
  }
}

// --------------------------------------------- (7)(8)(9) conflict hygiene
// WHY: the route map (PROGRESS.md, section "路线总图", 2026-10-16) is the single authority for
// "what next", and it introduced a new way to be wrong that no earlier criterion could see:
// a path is claimed but not written, a route is listed with no runnable criterion, or a number
// is cited so that the reader cannot tell which of the three series it belongs to. Each of the
// three checks below is a JUDGED finding (it enters `bad`, it can exit 1) -- printing a number
// in the summary without wiring it into the verdict has bitten this repo before.
//
// (7) NUMBER-SERIES MIXING. Three series are in force and must not be mixed up:
//       D = engineering decisions (docs/设计决策.md), R = direction (可用性路线图-人机两条线.md),
//       W = routes (the route map in PROGRESS.md). A bare "D7"/"R5"/"W1.1" is only useful if the
//       reader can tell which series it belongs to.
//     SCOPE -- measured on this checkout BEFORE the rule was fixed (2026-10-16), not guessed:
//       * WIDE form ("every bare series number in an OUTWARD doc must carry its file name on the
//         same line", owner file excluded) hits 4 lines: SPEC.md:430 and SPEC.md:490 are x86
//         opcode bytes ("FF D0 call rax") => FALSE positives, and SPEC.md:312 / 开源前-人类可用性
//         缺口.md:186 are real single-mention attribution gaps in files this cut may not touch.
//       * NARROW form (kept here): only a line that carries TWO OR MORE different series at once
//         is judged, because that is the case that is PROVABLY mixed -- the reader has no way to
//         split them apart. 4 hits wide / 0 after narrowing. The two real single-mention gaps are
//         NOT dropped silently: they are listed in the PROGRESS.md handover as the next cut's job,
//         together with the reason this cut cannot repair them (SPEC.md is out of scope here).
//       * skipped on purpose: the owner file of a series (docs/设计决策.md owns D, the roadmap
//         owns R, PROGRESS.md owns W -- a file may of course use its own numbers bare); the
//         "FF D0" opcode shape (two hex digits before); the "D6-6D" pixel-hash shape (hex + '-').
//     Only OUTWARD documents are scanned, as before.
const OWNER_FILE = { D: 'docs/设计决策.md', R: '可用性路线图-人机两条线.md', W: 'PROGRESS.md' };
const OWNER_NAME = { D: ['设计决策'], R: ['可用性路线图'], W: ['路线总图', 'PROGRESS.md'] };
const numMix = [];
for (const rel of OUTWARD) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) continue;
  const text = readDoc(p);
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    const toks = [...ln.matchAll(/(?<![0-9A-Za-z_])([DRW])(\d{1,2})(?![0-9A-Za-z_])/g)].filter((m) => {
      if (rel === OWNER_FILE[m[1]]) return false;
      const after = ln.slice(m.index + m[0].length, m.index + m[0].length + 4);
      const before = ln.slice(Math.max(0, m.index - 5), m.index);
      if (/^\s+[0-9A-Fa-f]{2}\b/.test(after)) return false;          // "D3 E0" opcode: byte after the token
      if (/(?:^|[^0-9A-Za-z_])[0-9A-Fa-f]{2}\s+$/.test(before)) return false; // "FF D0" opcode: byte before it
      if (/[0-9A-Fa-f]-$/.test(before)) return false;                // "D6-6D" pixel-hash form
      return true;
    });
    const series = [...new Set(toks.map((m) => m[1]))];
    if (series.length < 2) continue; // single-series mention: not "mixing" (see SCOPE above)
    for (const s of series) {
      if (OWNER_NAME[s].some((t) => ln.includes(t))) continue;
      const sample = toks.filter((m) => m[1] === s).map((m) => m[0]).join('/');
      numMix.push(rel + ':' + (i + 1) + '  line cites series ' + series.join('+') + ' (' +
        toks.map((m) => m[0]).join(', ') + ') but names none of ' + OWNER_NAME[s].join(' / ') +
        ' -- the bare "' + sample + '" cannot be told apart from the other series; add the file name  [裸 ' + sample + ' 无法判断是哪一套，请补文件名]');
    }
  }
}

// (8)(9) THE ROUTE MAP. Read from PROGRESS.md directly: that file is classified `archive` (it is
//     exempt from the snapshot-banner rule), but its route-map SECTION is the single authority for
//     paths, so its two tables are judged here explicitly.
//     (8) REGISTRATION. Every main-table row "| **W<n>.<m>** | ..." must have exactly 6 columns and
//         a non-empty "能跑的判据" column. A route whose criterion cannot be written down may only
//         be registered as an explicit text such as "无（未拍板 ⇒ 立项前必须先写判据）" -- never
//         left blank. Shape: the main table is the only place with a dotted W number ("W1.1"); the
//         overview table above it uses bare "W1".."W6" and is therefore not a main-table row.
//     (9) EXISTENCE. Backticked paths in those tables must exist under the repo root.
//         SCOPE -- measured before the rule was fixed (2026-10-16): judging BARE file names against
//         the repo root gives 7 hits, of which 5 are FALSE positives: row W1.1 writes `f013_fwdsugar.fl`
//         and four siblings without the directory although they live in test\facts\ (verified on
//         disk). The other 2 are real dead links and are reported in the handover, not silently
//         absorbed: `工单-T1双端缺口收口.md` (the file on disk is 工单-T1双向缺口收口.md -- 向/端 typo)
//         and `记忆.md` (lives on the owner's Desktop, outside the repo). Because a bare name does
//         not say which directory it is relative to, and guessing a search root produces the 5 false
//         positives above, this criterion only judges what carries its own directory -- an explicit
//         "this is where it lives" claim.
//         Skipped classes, explicitly: tokens without a "\" or "/" (bare names, see above); globs and
//         placeholders (* < > | =); anything containing a space (commands/prose such as
//         "node test\docgate.mjs --fix"); absolute paths and drive letters (E:\FLINT_CHAN -- outside
//         the repo, not ours to judge); "#anchor" tails and ":<line>" tails (test\verify-all.ps1:79
//         is a file+line reference, the file is what must exist).
const ROUTE_MAP = 'PROGRESS.md';
const routeIncomplete = [], routePathsMissing = [];
{
  const rp = path.join(ROOT, ROUTE_MAP);
  const rlines = fs.existsSync(rp) ? readDoc(rp).split(/\r?\n/) : null;
  if (!rlines) {
    routeIncomplete.push(ROUTE_MAP + '  is missing -- the route map is the single authority for "what next" (W6.1)');
  } else {
    let s = -1, e = rlines.length;
    for (let i = 0; i < rlines.length; i++) {
      if (s < 0 && /^##\s*路线总图/.test(rlines[i])) { s = i; continue; }
      if (s >= 0 && i > s && /^##\s/.test(rlines[i])) { e = i; break; }
    }
    if (s < 0) {
      routeIncomplete.push(ROUTE_MAP + '  has no "## 路线总图" section -- the route map must exist (W6.1)');
    } else {
      let rows = 0;
      for (let i = s; i < e; i++) {
        const ln = rlines[i];
        if (!/^\|/.test(ln)) continue; // prose/blockquote lines in the section are not table rows
        const label = (ln.match(/^\|\s*\*\*([^|*]+?)\*\*/) || [])[1] || '(row)';
        const mw = /^\|\s*\*\*W(\d+)\.(\d+)\*\*\s*\|/.exec(ln);
        if (mw) {
          rows++;
          const id = 'W' + mw[1] + '.' + mw[2];
          const cells = ln.split('|');
          const ncol = cells.length - 2;
          if (ncol !== 6) {
            routeIncomplete.push(ROUTE_MAP + ':' + (i + 1) + '  ' + id + ' has ' + ncol +
              ' column(s); the main table needs exactly 6 (编号/目标/能跑的判据/状态/权威出处/与谁冲突)');
          } else if (!cells[3].trim()) {
            routeIncomplete.push(ROUTE_MAP + ':' + (i + 1) + '  ' + id +
              ' has an EMPTY "能跑的判据" column -- a route with no runnable criterion may only be registered as an explicit "无（未拍板…）", never left blank');
          }
        }
        for (const tm of ln.matchAll(/`([^`]+)`/g)) {
          let tok = tm[1].trim();
          if (!/[\\/]/.test(tok)) continue;
          if (/[*<>|=]/.test(tok)) continue;
          if (/\s/.test(tok)) continue;
          if (/^[A-Za-z]:/.test(tok)) continue;
          if (/^[\\/]/.test(tok)) continue;
          tok = tok.split('#')[0].replace(/:\d+$/, '');
          if (!tok) continue;
          if (!fs.existsSync(path.join(ROOT, tok))) {
            routePathsMissing.push(ROUTE_MAP + ':' + (i + 1) + '  ' + label +
              ' references `' + tm[1].trim() + '` -- no such path under the repo root (dead link for anyone who clones)');
          }
        }
      }
      if (rows === 0) {
        routeIncomplete.push(ROUTE_MAP + '  route map has no "| **W<n>.<m>** |" main-table row -- the registration table is empty or its shape changed');
      }
    }
  }
}

// ---- 错误台账：源码里的报错点 vs 基线（tools\错误台账.mjs）----
// 为什么放在文档门：这份台账是「文档/探针说的错误文案」与「源码里实际报什么」之间的对账，
// 产物 tools\错误台账.md 本身也是机器生成的文档。新增/删除/改文案都必须显式重录基线。
const ledgerIssues = [];
{
  const tool = path.join(ROOT, 'tools', '错误台账.mjs');
  if (!fs.existsSync(tool)) {
    ledgerIssues.push('tools/错误台账.mjs 不存在（错误台账无法对账）');
  } else {
    try {
      execFileSync(process.execPath, [tool, '--check'], { cwd: ROOT, encoding: 'utf8', stdio: 'pipe' });
    } catch (e) {
      const txt = String((e && e.stdout) || '').trim().split('\n').slice(0, 6).join(' ｜ ');
      ledgerIssues.push('错误台账漂移（重录：node tools\\错误台账.mjs --update 后复查）: ' + (txt || (e && e.message)));
    }
  }
}

const bad = drift.length + unclosed.length + snapMissing.length + metaMissing.length + unclassified.length + linkIssues.length + ps1Issues.length + numMix.length + routeIncomplete.length + routePathsMissing.length + ledgerIssues.length;
for (const s of drift) console.log('DRIFT   ' + s);
for (const s of ps1Issues) console.log('PS1-BOM ' + s);
for (const s of unclosed) console.log('MARKER  ' + s);
for (const s of snapMissing) console.log('SNAPSHOT-MISSING  ' + s);
for (const s of metaMissing) console.log('META-MISSING      ' + s);
for (const s of unclassified) console.log('UNCLASSIFIED      ' + s);
for (const s of linkIssues) console.log('LINK    ' + s);
for (const s of numMix) console.log('NUM-MIX      ' + s);
for (const s of routeIncomplete) console.log('ROUTE-MAP    ' + s);
for (const s of routePathsMissing) console.log('ROUTE-PATH   ' + s);
for (const s of ledgerIssues) console.log('LEDGER  ' + s);
if (FIX) {
  // Report the repaired and the un-repairable separately: "1 value fixed" and "2 issues remain"
  // are different facts, and lumping them together is what made the old exit code unreadable.
  const remaining = [];
  if (drift.length) remaining.push(drift.length + ' drift');
  if (unclosed.length) remaining.push(unclosed.length + ' unclosed marker');
  if (snapMissing.length) remaining.push(snapMissing.length + ' snapshot-missing');
  if (metaMissing.length) remaining.push(metaMissing.length + ' meta-missing');
  if (unclassified.length) remaining.push(unclassified.length + ' unclassified');
  if (linkIssues.length) remaining.push(linkIssues.length + ' link');
  if (ps1Issues.length) remaining.push(ps1Issues.length + ' ps1-bom');
  if (numMix.length) remaining.push(numMix.length + ' num-mix');
  if (routeIncomplete.length) remaining.push(routeIncomplete.length + ' route-map-incomplete');
  if (routePathsMissing.length) remaining.push(routePathsMissing.length + ' route-path-missing');
  if (ledgerIssues.length) remaining.push(ledgerIssues.length + ' error-ledger');
  console.log('FIXED   ' + fixedCount + ' marker value(s) rewritten from the meter' +
    (recheckedAfterFix ? '; re-checked after fix: ' + (remaining.length === 0 ? 'GREEN' : 'still RED -- ' + remaining.join(', ')) : ''));
  if (recheckedAfterFix && fixedCount > 0) console.log('FIXED   REPAIRED: ' + fixedCount + ' marker value(s) (those DRIFT lines are absent from the list above)');
  if (remaining.length > 0) console.log('FIXED   NOT REPAIRED (not a marker value drift; --fix cannot touch these): ' + remaining.join(', '));
}
console.log('DOCGATE files=' + scanned + ' markers=' + markerCount + ' drift=' + drift.length + ' unclosed=' + unclosed.length +
  ' snapshot-missing=' + snapMissing.length + ' meta-missing=' + metaMissing.length +
  ' unclassified=' + unclassified.length + ' link-issues=' + linkIssues.length + ' ps1-bom=' + ps1Issues.length +
  ' num-mix=' + numMix.length + ' routes-incomplete=' + routeIncomplete.length + ' route-paths-missing=' + routePathsMissing.length +
  ' error-ledger=' + ledgerIssues.length);
if (bad === 0) {
  console.log('DOCGATE GREEN');
  console.log('DOCGATE documents ' + scanned + ' / issues ' + bad);
  process.exit(0);
}
console.log('DOCGATE RED -- the documents are wrong, not this gate (run with --trace <key> to see the truth source)');
console.log('DOCGATE documents ' + scanned + ' / issues ' + bad);
process.exit(1);
