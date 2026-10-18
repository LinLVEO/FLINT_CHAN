#!/usr/bin/env node
// tools/行号扫描.mjs -- READ-ONLY inventory of bare "file:line" references inside the OUTWARD
// documents, printing the CURRENT content of every referenced line so a human can judge whether
// the reference still holds.
//
// WHY IT EXISTS
//   A line number is a number, and it drifts silently: docs/索引.md claimed SPEC.md §设计原则
//   started at :96 and that principle 11 was at :142, while the real lines were :100 and :146
//   (four lines off, and nobody noticed for two work-units -- because line numbers were never
//   checked by any gate). The current numbers are now meter keys (spec-principles-sec/-first/-last),
//   but a document can also cite a line of a FILE, and those citations are still unguarded.
//   This tool answers, mechanically: "which bare citations do the outward documents make, what
//   does each cited line say TODAY, and is that the thing the document claims?"
//
// WHAT IT DELIBERATELY DOES NOT DO
//   It does not decide "correct" for you. "in range" is NOT "correct": the cited line can be a
//   perfectly valid line that now says something else entirely. Judgement is by CONTENT, and the
//   tool prints the content so the judgement is auditable rather than a memory claim. Line-only
//   citations (e.g. a bare ":486" whose filename lives earlier in the sentence) need context, so
//   they are NOT matched here -- the tool only reports what it can resolve mechanically.
//
// USAGE
//   node tools/行号扫描.mjs            # scan the outward documents at this checkout
//   node tools/行号扫描.mjs --json     # same rows, machine-readable
// Exit codes: 0 = scanned, 1 = an input file could not be read, 2 = usage error.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// The same list test/docgate.mjs classifies as "outward" (a document an outsider is meant to read).
const OUTWARD = [
  'README.md', 'SPEC.md', 'FLINT明细.md', '开源前-人类可用性缺口.md', '可用性路线图-人机两条线.md',
  '方向-对外一席之地（2026-10-13 用户口径变更）.md', 'lib/FLGUI.md',
  'docs/协作协议.md', 'docs/快速上手-真实项目.md', 'docs/真实项目.md', 'docs/索引.md',
  'docs/设计决策.md', 'docs/语言边界.md',
];
// a bare reference looks like  some\path.ext:NN  or  some\path.ext:NN-MM  (also :NN,MM)
const RX = /([A-Za-z0-9_][A-Za-z0-9_\\\/\.\-]*\.(?:md|fl|c|h|ps1|mjs|js|txt|json|gitattributes)):(\d+(?:\s*[-,]\s*\d+)*)/g;

const asJson = process.argv.includes('--json');
const rows = [];
let rc = 0;
for (const rel of OUTWARD) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) { rows.push({ doc: rel, note: 'MISSING DOC' }); rc = 1; continue; }
  const text = fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
  text.split(/\r?\n/).forEach((ln, i) => {
    for (const m of ln.matchAll(RX)) {
      const ref = m[1], nums = m[2];
      // 1) resolve as written (root-relative), with either slash flavour
      let target = null;
      for (const c of [ref, ref.replace(/\\/g, '/')]) {
        const q = path.join(ROOT, c);
        if (fs.existsSync(q)) { target = q; break; }
      }
      // 2) documents often abbreviate a path; fall back to a basename search, but only when it is
      //    UNAMBIGUOUS -- picking one of several same-named files would silently invent an answer.
      let ambiguous = false;
      if (!target) {
        const base = path.basename(ref.replace(/\\/g, '/'));
        const hits = [];
        const walk = (d, depth) => {
          if (depth > 3) return;
          let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
          for (const e of ents) {
            if (e.name === 'node_modules' || e.name === '.git' || e.name === 'tmp') continue;
            const q = path.join(d, e.name);
            if (e.isDirectory()) walk(q, depth + 1);
            else if (e.name === base) hits.push(q);
          }
        };
        walk(ROOT, 0);
        if (hits.length === 1) target = hits[0];
        else if (hits.length > 1) ambiguous = true;
      }
      const rec = {
        doc: rel + ':' + (i + 1), ref, nums,
        resolved: target ? path.relative(ROOT, target).split(path.sep).join('/') : (ambiguous ? 'AMBIGUOUS' : 'NOT-FOUND'),
      };
      if (target) {
        const t = fs.readFileSync(target, 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/);
        const first = parseInt(nums.split(/[-,]/)[0], 10);
        rec.maxLine = t.length;
        rec.inRange = first >= 1 && first <= t.length;
        rec.content = rec.inRange ? t[first - 1].trim().slice(0, 110) : '(line out of range)';
      }
      rows.push(rec);
    }
  });
}
if (asJson) {
  console.log(JSON.stringify({ tool: 'tools/行号扫描.mjs', total: rows.length, rows }, null, 2));
} else {
  for (const r of rows) {
    console.log([r.doc, r.ref + ':' + r.nums, r.resolved,
      r.inRange === false ? 'OUT-OF-RANGE' : (r.inRange ? 'in-range' : ''),
      '| ' + (r.content || '')].join('  '));
  }
  console.log('\nTOTAL refs=' + rows.length +
    '  unresolved=' + rows.filter((r) => r.resolved === 'NOT-FOUND' || r.resolved === 'AMBIGUOUS').length +
    '  out-of-range=' + rows.filter((r) => r.inRange === false).length +
    '\nNOTE: "in-range" only means the line EXISTS -- whether the citation is still CORRECT must be judged from the printed content.');
}
process.exit(rc);
