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
#       carrying its stable code (E-T1-INTTOPTR / E-STRICT-UNINIT / E-STRICT-WIDTH / E-STRICT-BOUNDS).
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
$allow = @{ 'str5' = 'int function returns a string address (true positive: silent truncation)' }

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
  @{ f = 'neg-bounds-global.fl';code = 'E-STRICT-BOUNDS'; strictOnly = $true  }
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
foreach ($f in $posFiles) {
  $a = Join-Path $work "plain\$($f.BaseName).exe"
  $b = Join-Path $work "strict\$($f.BaseName).exe"
  Remove-Item $a, $b -ErrorAction SilentlyContinue
  $null = (& $Flint $f.FullName -o $a 2>&1 | Out-String); $ca = $LASTEXITCODE
  $txt = (& $Flint -strict $f.FullName -o $b 2>&1 | Out-String); $cb = $LASTEXITCODE
  if ($ca -ne 0) { No ("$($f.Name): does not compile even without -strict"); continue }
  if ($cb -ne 0) { No ("$($f.Name): FALSE POSITIVE under -strict -> $(FirstCode $txt)"); continue }
  $ha = (Get-FileHash $a -Algorithm SHA256).Hash
  $hb = (Get-FileHash $b -Algorithm SHA256).Hash
  if ($ha -ne $hb) { No ("$($f.Name): product DIFFERS with -strict (must be diagnostics-only)"); continue }
  Ok ("$($f.Name): clean under -strict, product identical")
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
