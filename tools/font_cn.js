// font_cn.js -- 16x16 CJK bitmap generator for lib\hud_cn_font.fl
//
// Usage: node tools\font_cn.js [--art]
//
// Pipeline (matches the project rule "UTF-8 source -> GBK byte table -> generator -> self-check"):
//   1. CHARS below is the single source of truth for the glyph set.  It is a JS string,
//      so Chinese never has to appear in a .fl source literal.
//   2. A temporary PowerShell script renders each character from a Windows system font:
//      SimSun (Songti) 12pt at 96dpi = a 16px em, drawn with GDI TextRenderer at (0,0) on a
//      16x16 bitmap, NoPadding.  SimHei (Heiti) is the fallback if SimSun is unavailable.
//      The PowerShell script is pure ASCII: code points are passed as 0x.... numbers.
//   3. Each glyph becomes 16 rows x 16 bits (row 0 = top, bit 15 = leftmost column).
//      GBK bytes are produced by .NET Encoding 936, not guessed by hand.
//   4. lib\hud_cn_font.fl is emitted as pure-ASCII FLINT source, then the generator
//      asserts: 16 rows per glyph, every row in 0..65535, and 0 bytes > 127 in the file.
//
// The glyph set is deliberately small (one 16x16 glyph costs 16 ints of runtime table).
// Add a character to CHARS and rerun; lib\hud_cn.fl's global array size is checked too.

const fs = require("fs");
const path = require("path");
const os = require("os");
const child = require("child_process");

// Game title + UI words.  Duplicates are removed while preserving order.
const CHARS = "虚妄之塔血击杀重开按下始继续暂停胜利失败层关卡得分命";

// The task's minimum set must remain covered even if someone edits CHARS later.
const REQUIRED = "虚妄之塔血击杀重开按下开继续暂停胜利失败塔层";

const ROWS = 16;

function fail(msg) {
  throw new Error(msg);
}

const glyphs = [];
for (const ch of CHARS) {
  if (!glyphs.includes(ch)) glyphs.push(ch);
}
for (const ch of REQUIRED) {
  if (!glyphs.includes(ch)) fail(`required character missing from CHARS: U+${ch.codePointAt(0).toString(16).toUpperCase()}`);
}
for (const ch of glyphs) {
  const cp = ch.codePointAt(0);
  if (cp > 0xFFFF) fail(`non-BMP character is not supported: U+${cp.toString(16)}`);
}

const codepoints = glyphs.map((ch) => ch.codePointAt(0));
const hex4 = (v) => v.toString(16).toUpperCase().padStart(4, "0");

function psQuote(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function renderGlyphs() {
  if (process.platform !== "win32") {
    fail("this generator needs Windows (System.Drawing / GDI)");
  }
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "flint-font-cn-"));
  const psPath = path.join(tmpDir, "render.ps1");
  const outPath = path.join(tmpDir, "glyphs.txt");
  const cpList = codepoints.map((cp) => "0x" + hex4(cp)).join(",");

  const ps = [
    "$ErrorActionPreference = 'Stop'",
    "Add-Type -AssemblyName System.Drawing",
    "Add-Type -AssemblyName System.Windows.Forms",
    `$codes = @(${cpList})`,
    `$outPath = ${psQuote(outPath)}`,
    // Songti = U+5B8B U+4F53, Heiti = U+9ED1 U+4F53.  Keep this script ASCII-only.
    "$sun = [string]([char]0x5B8B) + [string]([char]0x4F53)",
    "$hei = [string]([char]0x9ED1) + [string]([char]0x4F53)",
    "$font = $null",
    "$fontLabel = ''",
    "$cands = @(@{ Req = 'SimSun'; Name = $sun }, @{ Req = 'SimHei'; Name = $hei })",
    "foreach ($cand in $cands) {",
    "  $f = New-Object System.Drawing.Font($cand.Req, 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)",
    // Windows PowerShell 5.1 reports the English family name; .NET Core reports the
    // localized one.  Accept either, but never accept a silent fallback font.
    "  $want = @($cand.Req, $cand.Name)",
    "  if ($want -contains $f.Name) { $font = $f; $fontLabel = $cand.Req; break }",
    "  $f.Dispose()",
    "}",
    "if ($font -eq $null) { throw 'no usable CJK font (SimSun/SimHei)' }",
    "$lines = New-Object 'System.Collections.Generic.List[string]'",
    "$lines.Add('FONT ' + $fontLabel)",
    "$gbkEnc = [System.Text.Encoding]::GetEncoding(936)",
    "foreach ($cp in $codes) {",
    "  $bmp = New-Object System.Drawing.Bitmap 16,16",
    "  $g = [System.Drawing.Graphics]::FromImage($bmp)",
    "  $g.Clear([System.Drawing.Color]::White)",
    "  $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding",
    "  [System.Windows.Forms.TextRenderer]::DrawText($g, [string][char]$cp, $font, (New-Object System.Drawing.Point(0,0)), [System.Drawing.Color]::Black, $flags)",
    "  $g.Dispose()",
    "  $gbk = $gbkEnc.GetBytes([string][char]$cp)",
    "  if ($gbk.Length -ne 2) { throw ('character U+' + $cp.ToString('X4') + ' has no 2-byte GBK mapping') }",
    "  $rows = New-Object 'System.Collections.Generic.List[int]'",
    "  for ($y = 0; $y -lt 16; $y++) {",
    "    $v = 0",
    "    for ($x = 0; $x -lt 16; $x++) {",
    "      if ($bmp.GetPixel($x, $y).R -lt 128) { $v = $v -bor (1 -shl (15 - $x)) }",
    "    }",
    "    $rows.Add($v)",
    "  }",
    "  $bmp.Dispose()",
    "  $lines.Add(('{0:X4} {1:X2} {2:X2} {3}' -f $cp, $gbk[0], $gbk[1], ($rows -join ' ')))",
    "}",
    "[System.IO.File]::WriteAllLines($outPath, $lines, (New-Object System.Text.ASCIIEncoding))",
    "Write-Output ('FONT ' + $fontLabel + ' 12pt 16px')",
  ].join("\r\n");

  try {
    fs.writeFileSync(psPath, ps, "ascii");
    const r = child.spawnSync(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", psPath],
      { stdio: "inherit", windowsHide: true }
    );
    if (r.error) fail(`failed to start powershell.exe: ${r.error.message}`);
    if (r.status !== 0) fail(`powershell render failed (exit ${r.status})`);
    const text = fs.readFileSync(outPath, "ascii");
    const lines = text.split(/\r?\n/).filter((s) => s.trim().length > 0);
    if (lines.length < 1 + glyphs.length) fail(`render output too short: ${lines.length} lines`);
    const fontLine = lines[0].split(/\s+/);
    if (fontLine[0] !== "FONT") fail(`bad render header: ${lines[0]}`);
    const fontName = fontLine[1];
    if (fontName !== "SimSun" && fontName !== "SimHei") fail(`unexpected font label: ${fontName}`);
    const out = [];
    for (let i = 0; i < glyphs.length; i++) {
      const parts = lines[1 + i].trim().split(/\s+/);
      if (parts.length !== 3 + ROWS) fail(`bad glyph line ${i}: ${parts.length} fields`);
      const cp = parseInt(parts[0], 16);
      const hi = parseInt(parts[1], 16);
      const lo = parseInt(parts[2], 16);
      if (cp !== codepoints[i]) fail(`glyph order mismatch at ${i}: ${parts[0]} vs ${hex4(codepoints[i])}`);
      if (!(hi >= 0x81 && hi <= 0xFE) || !(lo >= 0x40 && lo <= 0xFE)) {
        fail(`bad GBK bytes for U+${hex4(cp)}: ${parts[1]} ${parts[2]}`);
      }
      const rows = parts.slice(3).map((s) => parseInt(s, 10));
      for (let r = 0; r < ROWS; r++) {
        if (!Number.isInteger(rows[r]) || rows[r] < 0 || rows[r] > 0xFFFF) {
          fail(`bad row ${r} for U+${hex4(cp)}: ${parts[3 + r]}`);
        }
      }
      let ink = 0;
      for (const v of rows) for (let b = 0; b < 16; b++) if ((v & (1 << b)) !== 0) ink++;
      if (ink === 0) fail(`glyph U+${hex4(cp)} is empty (font fallback?)`);
      out.push({ ch: glyphs[i], cp, hi, lo, rows });
    }
    return { fontName, glyphs: out };
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { /* ignore */ }
  }
}

function buildSource(fontName, glyphs) {
  const n = glyphs.length;
  const total = n * ROWS;   // one int per 16-pixel row
  const L = [];
  L.push("// hud_cn_font.fl -- AUTO-GENERATED by tools\\font_cn.js, do not edit by hand.");
  L.push("// Source: Windows system font " + fontName + (fontName === "SimSun" ? " (fallback SimHei)" : " (SimSun unavailable)") + ", 12pt => 16x16 cell.");
  L.push("// Renderer: GDI TextRenderer.DrawText, NoPadding, black on white, threshold R<128.");
  L.push("// Layout: " + n + " chars x 16 rows x 16 bits; row 0 = top; bit 15 = leftmost column.");
  L.push("// GBK: .NET Encoding 936.  This file is pure ASCII; the generator asserts 0 bytes > 127.");
  L.push("//");
  L.push("// API:");
  L.push("//   int hud_cn_count()");
  L.push("//   int hud_cn_gbk_hi(int idx) / hud_cn_gbk_lo(int idx)   (0 when idx out of range)");
  L.push("//   int hud_cn_load(int *buf)                             (fills " + total + " ints)");
  L.push("");
  L.push("int hud_cn_count() { return " + n + "; }");
  L.push("");
  L.push("int hud_cn_gbk_hi(int idx) {");
  for (let i = 0; i < n; i++) L.push("  if (idx == " + i + ") { return " + glyphs[i].hi + "; }");
  L.push("  return 0;");
  L.push("}");
  L.push("");
  L.push("int hud_cn_gbk_lo(int idx) {");
  for (let i = 0; i < n; i++) L.push("  if (idx == " + i + ") { return " + glyphs[i].lo + "; }");
  L.push("  return 0;");
  L.push("}");
  L.push("");
  L.push("// Fill buf[0 .. " + (total - 1) + "] element by element.");
  L.push("// One nested block per glyph keeps each block's direct child count small (boot-friendly).");
  L.push("int hud_cn_load(int *buf) {");
  L.push("  if (buf == 0) { return 0; }");
  for (let i = 0; i < n; i++) {
    const g = glyphs[i];
    L.push("  if (1) {");
    L.push("    // idx " + i + ": U+" + hex4(g.cp) + " GBK " + g.hi.toString(16).toUpperCase() + g.lo.toString(16).toUpperCase());
    for (let r = 0; r < ROWS; r++) {
      L.push("    buf[" + (i * ROWS + r) + "] = " + g.rows[r] + ";");
    }
    L.push("  }");
  }
  L.push("  return 0;");
  L.push("}");
  return { text: L.join("\n") + "\n", total };
}

function checkAscii(filePath) {
  const bytes = fs.readFileSync(filePath);
  let bad = 0;
  for (const b of bytes) if (b > 127) bad++;
  return { size: bytes.length, bad };
}

function printArt(glyphs) {
  for (const g of glyphs) {
    console.log(`--- U+${hex4(g.cp)} ${g.ch} GBK ${g.hi.toString(16).toUpperCase()}${g.lo.toString(16).toUpperCase()} ---`);
    for (const v of g.rows) {
      let line = "";
      for (let c = 0; c < 16; c++) line += (v & (0x8000 >> c)) !== 0 ? "#" : ".";
      console.log(line);
    }
  }
}

function main() {
  const { fontName, glyphs: rendered } = renderGlyphs();
  const { text, total } = buildSource(fontName, rendered);
  const outPath = path.join(__dirname, "..", "lib", "hud_cn_font.fl");

  // The library declares a fixed-size global int array; keep it in sync with this set.
  const libPath = path.join(__dirname, "..", "lib", "hud_cn.fl");
  if (fs.existsSync(libPath)) {
    const libText = fs.readFileSync(libPath, "utf8");
    const m = libText.match(/int\s+hud_cn_buf\s*\[\s*(\d+)\s*\]/);
    if (!m) fail("lib\\hud_cn.fl: cannot find 'int hud_cn_buf[N]' declaration");
    if (parseInt(m[1], 10) !== total) {
      fail(`lib\\hud_cn.fl declares hud_cn_buf[${m[1]}], generator needs [${total}] (${rendered.length} chars x 16 rows)`);
    }
  }

  // Write as UTF-8 so the byte check below is meaningful: an accidental non-ASCII
  // character in the generated source must show up as a >127 byte, not be masked away.
  fs.writeFileSync(outPath, text, "utf8");
  const check = checkAscii(outPath);
  if (check.bad !== 0) fail(`${outPath}: ${check.bad} byte(s) > 127`);
  if (fs.readFileSync(outPath, "utf8") !== text) fail(`${outPath}: ASCII round-trip mismatch`);

  for (const g of rendered) {
    if (g.rows.length !== ROWS) fail(`U+${hex4(g.cp)}: ${g.rows.length} rows`);
    for (const v of g.rows) if (!(v >= 0 && v <= 0xFFFF)) fail(`U+${hex4(g.cp)}: row out of range`);
  }
  if (rendered.length * ROWS !== total) fail("internal total mismatch");

  console.log(`wrote ${outPath}`);
  console.log(`font=${fontName} 12pt/16px  chars=${rendered.length}  ints=${total}  bytes=${check.size}  high_bytes=${check.bad}`);
  if (process.argv.includes("--art")) printArt(rendered);
}

try {
  main();
} catch (e) {
  console.error("font_cn: " + e.message);
  process.exit(1);
}
