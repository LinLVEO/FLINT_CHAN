# run-font-classic.ps1 -- M4q (2026-09-28): the OLD-LIB vs NEW-LIB whole-surface pixel-identity witness
# for the multi-font-tier batch ("off is really off").
#
# Why this exists: this batch touches the RENDER hot path (gwb_render_range gained a "pick the font for
# the current tier" branch). Every command-stream dump is blind to "which font got selected", so the
# only honest proof that a program which never pushes a tier still draws byte-identical pixels is:
# compile ONE common-subset source against BOTH libraries (M4p's lib from git b610942, and this batch's
# lib), hash the whole surface, and compare here.
#
#   oldlib/              = lib/flgui{,_widgets,_win32,_edit}.fl + ui_lib.fl + num_lib.fl taken verbatim
#                          from git b610942 with `git show ... > file` (raw bytes, no BOM).
#   font-classic-body.fl = the scenes. It may use ONLY APIs present in both libraries (no gui_font_push,
#                          no gui_win_font_tier, no Surf.ft0/ft1/ft2) -- mechanically guaranteed, because
#                          a new name would not compile against the old library.
#   font-classic-{old,new}.fl = thin wrappers with different include paths.
#
# Scenes (all three are "no tier switched" shapes):
#   base  = dark default theme + 14px font
#   light = light-blue preset (M4j) + 14px font
#   small = dark default theme + 12px font (the OLD way to change the font size: hand in another handle)
#
# Checks (the probe's own self-report is not trusted for the verdict):
#   A. both builds compile and exit 42
#   B. base / light / small: hash1 AND hash2 EQUAL old vs new -> pixel for pixel identical
#   C. inside one run base != small AND base != light -> the digest can see a font-size change and a
#      theme change (so the identity above is not a vacuous pass over a blind hash)
#   D. command counts identical per scene in both runs -> this batch moved zero bytes of command stream
# ASCII only on purpose (a .ps1 with non-ASCII needs a UTF-8 BOM; see the memory rule).
param(
  [string]$Root = "",
  [switch]$RebuildOldLib
)
$ErrorActionPreference = 'Stop'
# Self-relative: this script lives next to the sources it drives (test\m4q-assets\).
# $Root defaults to the repo root two levels up, so a clean clone works from anywhere.
$here = $PSScriptRoot
if (-not $Root) { $Root = Split-Path (Split-Path $here -Parent) -Parent }
$old = Join-Path $here 'oldlib'
$flint = Join-Path $Root 'flint.exe'
# All build products go to a throwaway dir under %TEMP% (never into the repo).
$work = Join-Path ([IO.Path]::GetTempPath()) ('flint-font-classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$pass = 0
$fail = 0
function Ok($m) { Write-Output "  OK   $m"; $script:pass++ }
function Bad($m) { Write-Output "  FAIL $m"; $script:fail++ }

# ---- 0. OPTIONAL: re-derive oldlib from git (raw bytes; cmd redirection keeps LF, adds no BOM) ----
# The oldlib sources are committed next to this script, so a clean clone needs no git history.
# Pass -RebuildOldLib only if you deliberately want to refresh them from b610942.
if ($RebuildOldLib) {
  New-Item -ItemType Directory -Force -Path $old | Out-Null
  Push-Location $Root
  foreach ($f in @('flgui.fl', 'flgui_widgets.fl', 'flgui_win32.fl', 'flgui_edit.fl')) {
    cmd /c "git show b610942:lib/$f > `"$old\$f`""
  }
  Copy-Item (Join-Path $Root 'lib\ui_lib.fl') (Join-Path $old 'ui_lib.fl') -Force
  Copy-Item (Join-Path $Root 'lib\num_lib.fl') (Join-Path $old 'num_lib.fl') -Force
  Pop-Location
  $bad = 0
  foreach ($f in @('flgui.fl', 'flgui_widgets.fl', 'flgui_win32.fl', 'flgui_edit.fl')) {
    $b = [IO.File]::ReadAllBytes((Join-Path $old $f))
    if ($b.Length -lt 2 -or ($b[0] -eq 239 -and $b[1] -eq 187)) { $bad++ }
  }
  if ($bad -eq 0) { Ok "oldlib rebuilt from b610942 (raw bytes, LF, no BOM)" }
  else { Bad "$bad oldlib file(s) have a BOM or are empty" }
}

# ---- 1. compile the two wrappers ----
foreach ($tag in @('old', 'new')) {
  $src = Join-Path $here "font-classic-$tag.fl"
  $exe = Join-Path $work "font-classic-$tag.exe"
  Remove-Item $exe -ErrorAction SilentlyContinue
  & $flint $src -o $exe | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Bad "compile failed: font-classic-$tag.fl"; return }
}
Ok "both wrappers compiled (old lib b610942 + new lib)"

# ---- 2. run both, parse the FONTCLASSIC lines ----
function Run-Probe([string]$tag) {
  $exe = Join-Path $work "font-classic-$tag.exe"
  $out = & $exe 2>&1
  $code = $LASTEXITCODE
  $t = @{}
  foreach ($l in $out) {
    $m = [regex]::Match([string]$l, 'FONTCLASSIC case=(\w+) h1=(-?\d+) h2=(-?\d+) cmdn=(\d+) px=(\d+)')
    if ($m.Success) {
      $t[$m.Groups[1].Value] = @{
        h1 = [int64]$m.Groups[2].Value; h2 = [int64]$m.Groups[3].Value
        cmdn = [int]$m.Groups[4].Value; px = [int]$m.Groups[5].Value
      }
    }
  }
  return @{ code = $code; cases = $t; out = $out }
}
$o = Run-Probe 'old'
$n = Run-Probe 'new'
Write-Output ""
Write-Output "old exit=$($o.code):"
$o.out | ForEach-Object { Write-Output "    $_" }
Write-Output "new exit=$($n.code):"
$n.out | ForEach-Object { Write-Output "    $_" }
Write-Output ""

# A. exit codes
if ($o.code -eq 42 -and $n.code -eq 42) { Ok "both products exit 42 (internal state checks green)" }
else { Bad "exit codes: old=$($o.code) new=$($n.code) (want 42/42)" }

$keys = @('base', 'light', 'small')
$missing = @($keys | Where-Object { -not $o.cases.ContainsKey($_) -or -not $n.cases.ContainsKey($_) })
if ($missing.Count -gt 0) { Bad "missing FONTCLASSIC lines: $($missing -join ',') -- cannot judge"; return }
Ok "both runs printed all three scene lines"

# B. identity where it is required (no tier is ever pushed)
foreach ($k in $keys) {
  $a = $o.cases[$k]; $b = $n.cases[$k]
  if (($a.h1 -eq $b.h1) -and ($a.h2 -eq $b.h2)) {
    Ok ("{0}: surface byte-identical old vs new (h1={1} h2={2})" -f $k, $a.h1, $a.h2)
  } else {
    Bad ("{0}: PIXELS DIFFER old(h1={1} h2={2}) new(h1={3} h2={4})" -f $k, $a.h1, $a.h2, $b.h1, $b.h2)
  }
}

# C. the digest must be able to see a font-size / theme change (otherwise B proves nothing)
foreach ($r in @(@{ n = 'old'; t = $o.cases }, @{ n = 'new'; t = $n.cases })) {
  $ds = ($r.t['base'].h1 -ne $r.t['small'].h1) -and ($r.t['base'].h2 -ne $r.t['small'].h2)
  $dl = ($r.t['base'].h1 -ne $r.t['light'].h1) -and ($r.t['base'].h2 -ne $r.t['light'].h2)
  if ($ds -and $dl) { Ok "$($r.n): base != small and base != light -> the digest is sensitive" }
  else { Bad "$($r.n): digest blind somewhere (small=$ds light=$dl) -> identity checks prove nothing" }
}

# D. command count per scene (a renderer-only change must move zero bytes of command stream)
foreach ($s in $keys) {
  $counts = @($o.cases[$s].cmdn, $n.cases[$s].cmdn)
  if (($counts | Select-Object -Unique).Count -eq 1) {
    Ok ("scene {0}: command count identical old vs new ({1} commands)" -f $s, $counts[0])
  } else { Bad ("scene {0}: command counts differ: {1}" -f $s, ($counts -join ',')) }
}

Write-Output ""
Write-Output "----"
Write-Output ("font-classic pass {0} / fail {1}" -f $pass, $fail)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
exit 0
