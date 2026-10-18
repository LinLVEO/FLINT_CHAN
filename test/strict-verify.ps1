# strict-verify.ps1 -- gate for the `-strict` diagnostic tier (v1.4.25, card T-20260919-010437).
# ASCII-only on purpose: Chinese text in a .ps1 needs a UTF-8 BOM and the edit tool keeps eating it
# (same rationale as verify-all.ps1 / debug-verify.ps1).
#
# Why this gate exists: `-strict` is a diagnostics-only tier -- it must
#   (a) actually fire on the four classes of "silent" it claims to catch, and
#   (b) never change what the compiler emits.
# A check that never fires is not a check; a diagnostics tier that changes products is a new bug.
#
# Three layers:
#   [1] NEGATIVES (test\strict-samples\neg-*.fl): each must be rejected WITH -strict,
#       carrying its stable code (E-T1-INTTOPTR / E-STRICT-UNINIT / E-STRICT-WIDTH / E-STRICT-BOUNDS
#       / v1.6.4 adds E-STRICT-PTRSTEP = raw pointer +/- on a pointer whose element width is > 1B).
#       `strictOnly = $true`  -> must ALSO still compile WITHOUT -strict (that is exactly what
#                                 "silent by default" means) -- that is what -strict is FOR.
#       `strictOnly = $false` -> v1.4.27 (card T-20261012-210751) CLOSED the default-tier gap for
#                                 these two samples (int value -> int* param / pointer -> int param):
#                                 they must now be rejected WITHOUT -strict too. Asserting "still
#                                 compiles by default" here would contradict the change that closed it.
#                                 The exact default wording is pinned by the boundary-probe gate's
#                                 two wall cases (int_arg_to_ptr_param / ptr_arg_to_int_param).
#   [2] POSITIVES (test\strict-samples\pos-*.fl): must compile WITH -strict, and the product must be
#       BYTE-IDENTICAL to the same source compiled without it.
#   [3] CORPUS (test\samples\*.fl): compiled both ways at scale. Both succeed => identical bytes.
#       A strict-only reject must be on the allow-list below; ANY new one turns this gate red --
#       that is the false-positive net (a tier nobody can use is worse than no tier).
param(
  [string]$Flint = ''
)
$ErrorActionPreference = 'Continue'
$test = $PSScriptRoot
$root = Split-Path $test -Parent
if (-not $Flint) { $Flint = Join-Path $root 'flint.exe' }
if (-not (Test-Path $Flint)) { Write-Host "[!] flint.exe not found: $Flint"; exit 2 }
$sampleDir = Join-Path $test 'strict-samples'
$corpus    = Join-Path $test 'samples'
$work      = Join-Path $test 'tmp\strictgate'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $work 'plain'), (Join-Path $work 'strict') | Out-Null

# Corpus samples that -strict rejects **on purpose** (true positives; documented, not bugs).
#   str5.fl: `int foo() { return "N"; }` -- returns a 64-bit string address from an int function.
#            That IS the silent truncation the tier exists to catch; the sample knowingly relies on it.
#
# v1.6.4 (5th class E-STRICT-PTRSTEP: raw `p +/- n` on a pointer whose ELEMENT WIDTH > 1 byte).
#   FLINT's raw pointer +/- steps in BYTES (decision 40, SPEC.md:262/:486) -- only `p[i]` /
#   `&p[i]` scale by the element width (int/double/struct element = 8-byte slot, char = 1).
#   Every sample listed below deliberately writes the byte form (that is what they PIN), so the
#   5th class fires on them by design: they are TRUE POSITIVES of a deliberately literal
#   criterion, not gate noise.  `sh1/sh2/new3` are the strongest case: `*(a - 8)` /
#   `VirtualFree(p - 8)` read the **8-byte block header** of `new`/`share` -- the language's own
#   documented p-8 layout, i.e. not an element access at all (the subscript spelling would be
#   `a[-1]`, which is byte-identical).  Whether the 5th class SHOULD stay this literal is an
#   open question recorded in the v1.6.4 handover note -- if it is narrowed, delete these rows.
$allow = @{
  'str5'    = 'int function returns a string address (true positive: silent truncation)'
  'arr4'    = 'v1.6.4 #5: raw `p = p + 8` on int* (byte stepping by design -- pins decision 40)'
  'audit7'  = 'v1.6.4 #5: raw `p0 + 1` / `p0 + 8` on int* (the A7 byte-stepping regression)'
  'dblptr1' = 'v1.6.4 #5: raw `q + 16` on double* (16 bytes = two doubles, by design)'
  'new3'    = 'v1.6.4 #5: `VirtualFree(p - 8)` -- new() block header, byte stepping by design'
  'ptr64a'  = 'v1.6.4 #5: raw `*(p + 8)` = second 8-byte slot (64-bit address arithmetic pin)'
  'ptr64b'  = 'v1.6.4 #5: raw `a + 4` adjacency pin on int*'
  'rev1'    = 'v1.6.4 #5: raw `a + 8` = &a[1] (byte-stepping revision sample)'
  'rev2'    = 'v1.6.4 #5: raw `p + i` / `p - 1` address-chain comparison (byte stepping)'
  'sh1'     = 'v1.6.4 #5: share refcount header `*(a - 8)` (documented p-8 block layout)'
  'sh2'     = 'v1.6.4 #5: share refcount header `*(a - 8)` (documented p-8 block layout)'
}

# v1.6.4: the positives layer has no allow-list by design, but ONE existing positive sample is a
#   documented true positive of the 5th class: pos-share.fl reads the share refcount header
#   `*(a - 8)` (decision 40's p-8 layout).  Allowed for E-STRICT-PTRSTEP **only** -- every other
#   code still makes it a hard FAIL (that is what keeps this from becoming a blanket exemption).
$posAllow = @{
  'pos-share.fl' = 'share refcount header *(a - 8) = decision 40 byte stepping, not an element'
}

$pass = 0; $fail = 0
function Ok($m) { $script:pass++; Write-Host ("  OK   " + $m) }
function No($m) { $script:fail++; Write-Host ("  FAIL " + $m) }
function FirstCode($text) {
  $m = [regex]::Matches([string]$text, '\[(E-[A-Z0-9\-]+)\]')
  if ($m.Count -gt 0) { return $m[0].Groups[1].Value }
  return ''
}

Write-Host ""
Write-Host "---- [1] negatives: every check must really fire ----"
$neg = @(
  @{ f = 'neg-inttoptr.fl';     code = 'E-T1-INTTOPTR';   strictOnly = $false },
  @{ f = 'neg-uninit.fl';       code = 'E-STRICT-UNINIT'; strictOnly = $true  },
  @{ f = 'neg-width-arg.fl';    code = 'E-STRICT-WIDTH';  strictOnly = $false },
  @{ f = 'neg-width-ret.fl';    code = 'E-STRICT-WIDTH';  strictOnly = $true  },
  @{ f = 'neg-bounds-local.fl'; code = 'E-STRICT-BOUNDS'; strictOnly = $true  },
  @{ f = 'neg-bounds-global.fl';code = 'E-STRICT-BOUNDS'; strictOnly = $true  },
  # v1.6.4 5th class: raw `p +/- n` on int* (element width 8 > 1 byte) -- silent byte stepping
  #   by default (decision 40), rejected under -strict.  Exactly what "silent by default" means.
  @{ f = 'neg-ptrstep.fl';      code = 'E-STRICT-PTRSTEP'; strictOnly = $true  }
)
foreach ($c in $neg) {
  $src = Join-Path $sampleDir $c.f
  if (-not (Test-Path $src)) { No ("$($c.f): sample missing"); continue }
  $txt = (& $Flint -strict $src -o (Join-Path $work 'strict\n.exe') 2>&1 | Out-String)
  $x = $LASTEXITCODE
  if ($x -eq 0) { No ("$($c.f): -strict compiled it -- expected $($c.code)"); continue }
  if ($txt -notmatch [regex]::Escape($c.code)) {
    No ("$($c.f): rejected but the code is '$((FirstCode $txt))' -- expected $($c.code)"); continue
  }
  $null = (& $Flint $src -o (Join-Path $work 'plain\n.exe') 2>&1 | Out-String)
  $pc = $LASTEXITCODE
  if ($c.strictOnly) {
    if ($pc -ne 0) { No ("$($c.f): also fails WITHOUT -strict -- not a strict-only catch"); continue }
    Ok ("$($c.f) -> $($c.code)  (silent without -strict)")
  } else {
    if ($pc -eq 0) { No ("$($c.f): compiles WITHOUT -strict -- the default-tier gap is OPEN again"); continue }
    Ok ("$($c.f) -> $($c.code) with -strict; ALSO rejected without it (default-tier hard error)")
  }
}

Write-Host ""
Write-Host "---- [2] positives: compile clean WITH -strict, product byte-identical ----"
$posFiles = @(Get-ChildItem $sampleDir -Filter 'pos-*.fl' | Sort-Object Name)
if ($posFiles.Count -eq 0) { No 'no positive samples found (test\strict-samples\pos-*.fl)' }
$posStrict = @()
foreach ($f in $posFiles) {
  $a = Join-Path $work "plain\$($f.BaseName).exe"
  $b = Join-Path $work "strict\$($f.BaseName).exe"
  Remove-Item $a, $b -ErrorAction SilentlyContinue
  $null = (& $Flint $f.FullName -o $a 2>&1 | Out-String); $ca = $LASTEXITCODE
  $txt = (& $Flint -strict $f.FullName -o $b 2>&1 | Out-String); $cb = $LASTEXITCODE
  if ($ca -ne 0) { No ("$($f.Name): does not compile even without -strict"); continue }
  if ($cb -ne 0) {
    if ($posAllow.ContainsKey($f.Name) -and $txt -match 'E-STRICT-PTRSTEP') {
      $posStrict += $f.Name
      Ok ("$($f.Name): -strict rejects it with E-STRICT-PTRSTEP (allowed -- $($posAllow[$f.Name]))")
    } else {
      No ("$($f.Name): FALSE POSITIVE under -strict -> $(FirstCode $txt)")
    }
    continue
  }
  $ha = (Get-FileHash $a -Algorithm SHA256).Hash
  $hb = (Get-FileHash $b -Algorithm SHA256).Hash
  if ($ha -ne $hb) { No ("$($f.Name): product DIFFERS with -strict (must be diagnostics-only)"); continue }
  Ok ("$($f.Name): clean under -strict, product identical")
}
foreach ($k in @($posAllow.Keys)) {
  if ($posStrict -notcontains $k) { No ("positives allow-list entry '$k' is no longer rejected -- stale, update it") }
}

Write-Host ""
Write-Host "---- [2b] positives also RUN with the right numbers (expectations computed HERE) ----"
# v1.6.4: "compiles clean under -strict" is not enough for the 5th class -- the positives exist to
#   prove the ALTERNATIVES stay correct: `p[i]` / `&p[i]` take the i-th element, and raw +/- on a
#   1-byte-element pointer (char* / char[]) is the documented byte stepping (decision 40).
#   Expected values are recomputed HERE from the rule (never copied from the product's output).
$elemVals = 0..7 | ForEach-Object { 100 + 3 * $_ }        # a[i] = 100 + 3*i
$elemS    = ($elemVals | Measure-Object -Sum).Sum         # sum over all 8 elements
$elemQ    = $elemVals[5]                                  # &p[5]
$elemD    = 4                                             # (&a[1]) - a = int element = 4-byte (v1.6.5 int4 ABI)
$doc      = '0123456789'                                  # the very literal the sample uses
$charW    = 9 - 4                                         # c9 - c4 = byte distance
$charBuf  = 0..7 | ForEach-Object { [char](65 + $_) }      # buf[i] = 65 + i
$runs = @(
  @{ f = 'pos-ptrstep-elem.fl'; want = ("ptrstep_elem s={0} q={1} d={2}" -f $elemS, $elemQ, $elemD) },
  @{ f = 'pos-ptrstep-char.fl'; want = ("ptrstep_char c4={0} c9={1} d={2} cb={3} e={4}" -f $doc[4], $doc[9], $charW, $charBuf[3], 3) }
)
foreach ($rc in $runs) {
  $src = Join-Path $sampleDir $rc.f
  if (-not (Test-Path $src)) { No ("$($rc.f): sample missing"); continue }
  $exe = Join-Path $work "strict\run-$($rc.f).exe"
  Remove-Item $exe -ErrorAction SilentlyContinue
  $etxt = (& $Flint -strict $src -o $exe 2>&1 | Out-String); $cb = $LASTEXITCODE
  if ($cb -ne 0) { No ("$($rc.f): rejected under -strict -> $(FirstCode $etxt)"); continue }
  $got = (& $exe 2>&1 | Out-String).Trim()
  if ($got -notmatch [regex]::Escape($rc.want)) {
    No ("$($rc.f): -strict clean but stdout '$got' lacks the expected '$($rc.want)'"); continue
  }
  Ok ("$($rc.f): -strict clean AND runs correctly ('$($rc.want)')")
}

Write-Host ""
Write-Host "---- [3] corpus: every sample both ways (false-positive net at scale) ----"
$strictOnly = @(); $diffBytes = @(); $both = 0
foreach ($f in (Get-ChildItem $corpus -Filter '*.fl' | Sort-Object Name)) {
  $a = Join-Path $work 'plain\c.exe'
  $b = Join-Path $work 'strict\c.exe'
  Remove-Item $a, $b -ErrorAction SilentlyContinue
  $null = (& $Flint $f.FullName -o $a 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { continue }            # 编译不过的样本（负例）不参与本层判据
  $null = (& $Flint -strict $f.FullName -o $b 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { $strictOnly += $f.BaseName; continue }
  $both++
  if ((Get-FileHash $a -Algorithm SHA256).Hash -ne (Get-FileHash $b -Algorithm SHA256).Hash) { $diffBytes += $f.BaseName }
}
foreach ($n in $strictOnly) {
  if ($allow.ContainsKey($n)) { Ok ("corpus ${n}: strict-only reject (allowed -- $($allow[$n]))") }
  else { No ("corpus ${n}: NEW strict-only reject -- likely FALSE POSITIVE (fix the check, not the gate)") }
}
foreach ($k in @($allow.Keys)) {
  if ($strictOnly -notcontains $k) { No ("allow-list entry '$k' is no longer rejected -- the list is stale, update it") }
}
if ($diffBytes.Count -gt 0) {
  No ("corpus: $($diffBytes.Count) sample(s) produced DIFFERENT bytes with -strict: $((($diffBytes | Select-Object -First 5) -join ', '))")
} else {
  Ok ("corpus: $both samples compiled under -strict -- all products byte-identical to the plain build")
}

Write-Host ""
Write-Host ("strict gate pass {0} / {1}" -f $pass, ($pass + $fail))
if ($fail -gt 0) { exit 1 }
exit 0
