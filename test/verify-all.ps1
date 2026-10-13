# verify-all.ps1 -- ONE command for the whole re-run set (v1.4.16, task card T-20260918-012105).
# ASCII-only on purpose: Chinese text in a .ps1 needs a UTF-8 BOM and the edit tool keeps eating it
# (same rationale as test\debug-verify.ps1).
#
# Steps, in this order (order matters -- step 0 rebuilds the compiler every gate uses, and no two
# gates may overlap: a product rebuild while a regression runs has burned this project before):
#   [0] build     gcc -O2 src\*.c -o flint.exe            (skip with -SkipBuild)
#   [1] warn      gcc -O2 -Wall -Wextra -> warning count  (baseline 7, must not grow)
#   [2] wx        test\wx-verify.ps1                      W^X / .idata / ASLR + header layout pin
#   [3] debug     test\debug-verify.ps1 -BaselineExe ...   -debug audit layer
#   [4] regress   node test\run-tests.js                  behaviour regression
#   [5] boot      boot\verify.ps1                         self-hosting boot compiler + fixed point
#   [6] diffgate  test\差分门.ps1 -TimeoutSec 5            full-sample two-compiler differential gate
#                 (compares exit code + stdout of both compilers over every test sample,
#                  red only on NEW divergences vs the recorded baseline)
#   [7] audit     test\映射层审计.ps1                       mapping-layer discipline (IR refactor M1/M2):
#                 frame-slot offset encoding must live ONLY in src\slotmap.c, and the generation layer
#                 must reach slots through slot_* (this is the net that keeps M4's invalidation rules
#                 from leaking: one direct access left behind = compiles, silently wrong value)
#   [8] eqgate    test\等价门.ps1                          emission-shape pin (T-20260919-010437):
#                 every sample compiled twice into two output dirs must be BYTE-IDENTICAL to each other
#                 AND to the recorded fingerprint baseline; only an intentional emission change may
#                 re-record it (.\等价门.ps1 -UpdateFingerprint -Reason "<why>"). This is the gate that
#                 makes the IR refactor safe and turns M4-style changes into an explicit change list.
#   [9] bench     bench\对账2.ps1 -Gate                     performance-ruler guard (same card):
#                 the ruler itself must stay trustworthy before anyone quotes a number from it --
#                 results of all three implementations must match the Node third implementation, the
#                 flint side must really run the loop (back edge) and stay above the QPC floor, and a
#                 second identical round must reproduce result + back-edge count. gcc -O2 folding a
#                 kernel is a KNOWN form (reported, not red). This step is a GUARD, not a perf target:
#                 it never fails because flint got slower.
#   [10] strict   test\strict-verify.ps1                    `-strict` diagnostics tier (v1.4.25):
#                 layer 1 -- each of the four checks must really fire on its negative sample
#                 (E-T1-INTTOPTR / E-STRICT-UNINIT / E-STRICT-WIDTH / E-STRICT-BOUNDS), and each of
#                 those samples must still compile WITHOUT -strict (that is what "silent" means);
#                 layer 2 -- positive samples compile clean with -strict and produce byte-identical
#                 products; layer 3 -- the whole test corpus compiled both ways: identical bytes, and
#                 any strict-only reject must be on the documented allow-list (currently str5.fl only,
#                 a true positive). It fails in BOTH directions on purpose: a check that never fires,
#                 and a false positive (a tier nobody can use is worse than no tier).
#
#   [11] loop     test\loop-verify.ps1                       real-application smoke gate (2026-09-21):
#                 compiles apps\m2_float (2600+ lines, real imports) with BOTH compilers, clears the
#                 ASLR bits in both products, runs each under the app's own dump.on/demo.on self-check
#                 switches and compares the resulting dumps byte for byte after masking the four live
#                 fields (tick= / dp p= / DISK NN% / net raw counters d= u=). Runs the flint product
#                 twice to prove the mask is
#                 complete. Rationale: twice in one day a product COMPILED but never RAN (truncated
#                 import DLL name -> 0xC0000135; array length in the low 3 digits -> 0xC0000005) and
#                 every sample-level gate stayed green. See test\loop-verify.ps1 header.
#
#   [12] budget   tools\ "budget gate" (CJK file name; the step body builds the path from code
#                 points -- this file is an ASCII contract). Budget REGRESSION gate (2026-10-13):
#                 runs the two read-only budget meters -- (a) the import table of every FLINT-family
#                 product (apps\**\*.exe) against MAX_IMPORTS/MAX_GROUPS read from src\pe.c, and
#                 (b) boot's single function table (api declarations + top-level function
#                 definitions) for the heaviest chain boot compiles (apps\m2_float\main.fl) against
#                 the capacity constant read from boot\lib_parse.fl, including the lib_print.fl
#                 source boot itself injects before parsing.
#                 Verdict = comparison against the recorded baseline test\ "budget baseline".json:
#                 ANY change of a recorded number is RED in BOTH directions (spending one more
#                 import or table slot is a regression; spending one LESS is a counting-rule change
#                 that must be re-recorded, or a later regression back to the old level would slip
#                 under the gate). A missing baseline and a meter failure are RED as well, and the
#                 re-record command is printed. The ABSOLUTE status quo (a product at 96/96 imports
#                 and 8/8 modules; boot's table at 512/512 with headroom 0) is printed as a loud
#                 WARN but is not a red by itself -- it is pre-existing and pending budget
#                 re-layout, and a gate that is red for the status quo trains people to ignore it.
#
# Full output per step -> tmp\verify-all\<step>.log; the console shows the tail plus the parsed
# "N / M" summary line. Exit code 0 only when every requested step is green.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\verify-all.ps1
#   powershell ... -File test\verify-all.ps1 -SkipBuild
#   powershell ... -File test\verify-all.ps1 -Only wx,debug
param(
  [switch]$SkipBuild,
  [string[]]$Only = @('build', 'warn', 'wx', 'debug', 'regress', 'boot', 'diffgate', 'audit', 'eqgate', 'bench', 'strict', 'loop', 'budget'),
  [string]$BaselineExe = '.\flint_before_aslr.exe',
  [int]$TailLines = 6
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$flint = Join-Path $root 'flint.exe'
$logDir = Join-Path $root 'tmp\verify-all'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$results = @()

function Want([string]$k) { return ($Only -contains $k) }

function Add-Result([string]$key, [string]$title, [int]$code, $out, [double]$secs) {
  $log = Join-Path $logDir "$key.log"
  $out | Out-File -FilePath $log -Encoding UTF8
  $n = [Math]::Min($TailLines, @($out).Count)
  if ($n -gt 0) { @($out) | Select-Object -Last $n | ForEach-Object { Write-Host "    $_" } }
  # the gates print "<word> N / <word> M" (English or Chinese wording) -- pull the two numbers out
  $nums = ''
  foreach ($l in (@($out) | Select-Object -Last 4)) {
    $m = [regex]::Match([string]$l, '(\d+)\D+(\d+)\s*$')
    if ($m.Success) { $nums = "$($m.Groups[1].Value) / $($m.Groups[2].Value)" }
  }
  $script:results += [pscustomobject]@{
    step = $key; what = $title; exit = $code
    summary = $(if ($nums) { $nums } else { '-' })
    secs = $secs; log = (Split-Path $log -Leaf)
  }
  Write-Host ("    -> exit=$code  summary=$nums  ($secs s, log: $log)")
}

function Run-Gate([string]$key, [string]$title, [string]$exe, [string[]]$argv) {
  if (-not (Want $key)) { return }
  Write-Host ""
  Write-Host "=== [$key] $title ==="
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = & $exe @argv 2>&1
  $code = $LASTEXITCODE; $sw.Stop()
  if ($null -eq $code) { $code = 1 }
  Add-Result $key $title $code $out ([Math]::Round($sw.Elapsed.TotalSeconds, 1))
}

Push-Location $root

# --- [0] rebuild the compiler ---
if (Want 'build') {
  if ($SkipBuild) {
    Write-Host ""
    Write-Host "=== [build] skipped (-SkipBuild) ==="
  } else {
    Write-Host ""
    Write-Host "=== [build] rebuild flint.exe (gcc -O2) ==="
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $src = (Get-ChildItem (Join-Path $root 'src\*.c')).FullName
    $out = & gcc -O2 @src -o $flint 2>&1
    $code = $LASTEXITCODE; $sw.Stop()
    Add-Result 'build' 'rebuild flint.exe (gcc -O2)' $code $out ([Math]::Round($sw.Elapsed.TotalSeconds, 1))
    if ($code -ne 0) { Write-Host 'BUILD FAILED -- later steps would test a stale compiler, stopping.'; Pop-Location; exit 1 }
  }
}

# --- [1] warning count ---
if (Want 'warn') {
  Write-Host ""
  Write-Host "=== [warn] gcc -O2 -Wall -Wextra (baseline: 7 warnings, 0 errors) ==="
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $src = (Get-ChildItem (Join-Path $root 'src\*.c')).FullName
  $out = & gcc -O2 -Wall -Wextra @src -o (Join-Path $logDir 'warnchk.exe') 2>&1
  $sw.Stop()
  $w = @($out | Select-String 'warning:').Count
  $e = @($out | Select-String 'error:').Count
  $code = 0
  if ($e -gt 0 -or $w -gt 7) { $code = 1 }   # baseline is 7: fewer is fine, more is a regression
  Add-Result 'warn' "warnings (baseline 7)" $code @($out + "warnings=$w errors=$e (baseline 7 / 0)") ([Math]::Round($sw.Elapsed.TotalSeconds, 1))
}

$ps = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
Run-Gate 'wx'      'gate: product invariants (W^X / .idata / ASLR) + header layout pin' 'powershell' ($ps + @((Join-Path $root 'test\wx-verify.ps1')))
Run-Gate 'debug'   'gate: -debug audit layer' 'powershell' ($ps + @((Join-Path $root 'test\debug-verify.ps1'), '-BaselineExe', $BaselineExe))
Run-Gate 'regress' 'behaviour regression' 'node' @((Join-Path $root 'test\run-tests.js'))
Run-Gate 'boot'    'boot compiler self-hosting verify' 'powershell' ($ps + @((Join-Path $root 'boot\verify.ps1')))
# [6] full-sample two-compiler differential gate (T-20260919-010437). TimeoutSec 5 keeps it ~80s:
#     only genuine hangs are affected (they are already recorded as HANG in the baseline).
Run-Gate 'diffgate' 'gate: two-compiler differential (flint vs boot, all samples)' 'powershell' ($ps + @((Join-Path $root 'test\差分门.ps1'), '-TimeoutSec', '5'))
# [7] mapping-layer discipline (T-20260919-010437 M1/M2) -- see header
Run-Gate 'audit'   'gate: mapping layer discipline (single slot exit)' 'powershell' ($ps + @((Join-Path $root 'test\映射层审计.ps1')))
# [8] emission-shape pin: same source twice -> byte-identical, and identical to the fingerprint baseline
#     (T-20260919-010437). An intentional emission change must re-record the baseline WITH a reason.
Run-Gate 'eqgate'  'gate: emission shape pin (byte-identical + fingerprint baseline)' 'powershell' ($ps + @((Join-Path $root 'test\等价门.ps1')))
# [9] performance-ruler guard: the ruler must stay trustworthy (results match the Node third
#     implementation, loops really run, second identical round reproduces result + back edges).
#     It is NOT a perf target -- flint getting slower does not turn this red.
Run-Gate 'bench'   'gate: bench ruler guard (3 impls vs node, back edge, round-2 self-check)' 'powershell' ($ps + @((Join-Path $root 'bench\对账2.ps1'), '-Gate'))
# [10] `-strict` diagnostics tier: must fire on all four silent classes, must never change a product
#      byte, and must not reject anything outside the documented allow-list (see header)
Run-Gate 'strict'  'gate: -strict diagnostics tier (fires + byte-identical + no false positives)' 'powershell' ($ps + @((Join-Path $root 'test\strict-verify.ps1')))
# [11] end-to-end smoke gate on the REAL application (2026-09-21, card T-20260921-194703): the other
#      steps compile samples or inspect bytes -- twice in one day the real app shipped a product that
#      compiled but never ran (truncated import-table DLL name -> 0xC0000135; array length packed into
#      the low 3 decimal digits -> frame under-allocated -> 0xC0000005) and every sample gate stayed
#      green. This step compiles apps\m2_float with BOTH compilers, runs both products under the app's
#      dump.on/demo.on self-check switches (ASLR bits cleared in the products -- an AMD ADL library on
#      this host faults on randomly based images, proven by a 2-byte single-variable test) and compares
#      the two dumps byte for byte after masking the four live fields (tick= / dp p= / DISK NN% /
#      net raw counters d= u=). It
#      also re-runs the flint product to prove the mask is complete. "It compiles" is not progress.
Run-Gate 'loop'    'gate: real-app smoke (both compilers, run + dump byte compare)' 'powershell' ($ps + @((Join-Path $root 'test\loop-verify.ps1')))

# [12] budget gate (2026-10-13, usability roadmap P1 item 3). Run AFTER loop; nothing here is
#      rebuilt, so this step compiles nothing.
#      ONE entry point: tools\<CJK "budget gate">.ps1. It runs both read-only budget meters --
#      the import-table meter (per FLINT product, caps read from src\pe.c) and the boot
#      function-table meter (apps\m2_float\main.fl, cap read from boot\lib_parse.fl, including the
#      lib_print.fl source boot injects) -- and compares their numbers against the recorded
#      baseline test\<CJK "budget baseline">.json.
#      It reds on ANY change of a recorded number, in BOTH directions: one more import or one more
#      table slot is a real regression, and one LESS is a counting-rule change that must be
#      re-recorded explicitly, otherwise a later "back to the old level" regression would slip
#      under the gate (the same rule that makes the equivalence gate safe). A missing baseline and
#      a meter failure are red too, with the re-record command printed.
#      The ABSOLUTE status quo is printed as a loud WARN but is not a red by itself: the real app
#      currently sits at 96/96 imports, 8/8 modules and boot's table at 512/512 (headroom 0). That
#      is a pre-existing fact awaiting the planned budget re-layout, and a gate that is red for the
#      status quo is a gate people learn to read as noise.
#      The tool and baseline file names contain CJK characters and this file is an ASCII contract,
#      so those paths are assembled from code points here (and echoed so the log says what ran).
if (Want 'budget') {
  Write-Host ""
  Write-Host "=== [budget] gate: budget regression vs recorded baseline (imports + boot table) ==="
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $budgetGate = Join-Path $root ('tools\' + [char]0x9884 + [char]0x7B97 + [char]0x95E8 + '.ps1')
  $bout = @()
  $code = 0
  if (-not (Test-Path -LiteralPath $budgetGate)) {
    $bout += @("!! missing instrument: $budgetGate")
    $code = 1
  } else {
    $to = & powershell @ps @($budgetGate) 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 1 }
    $bout += @("--- $budgetGate  exit=$code ---") + @($to)
  }
  $sw.Stop()
  $verdict = 'GREEN'
  if ($code -ne 0) { $verdict = 'RED' }
  $bout += @("budget gate: $verdict (see the exit= line above; the baseline lives in test\)")
  Add-Result 'budget' 'gate: budget regression vs recorded baseline (imports + boot table)' $code $bout ([Math]::Round($sw.Elapsed.TotalSeconds, 1))
}

Pop-Location

Write-Host ""
Write-Host '================ verify-all summary ================'
$results | Format-Table -AutoSize
$bad = @($results | Where-Object { $_.exit -ne 0 })
if ($results.Count -eq 0) { Write-Host 'nothing was run (-Only matched no step)'; exit 1 }
if ($bad.Count -eq 0) {
  Write-Host ("ALL GREEN ({0}/{0} steps)" -f $results.Count)
  exit 0
} else {
  Write-Host ("FAILED: {0} of {1} steps -- {2}" -f $bad.Count, $results.Count, (($bad | ForEach-Object { $_.step }) -join ','))
  exit 1
}
