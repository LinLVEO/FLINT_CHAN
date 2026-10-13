# loop-verify.ps1 -- end-to-end smoke gate: compile the REAL application with BOTH compilers and
# compare what the two products actually WRITE when they run.
#
# ASCII-only on purpose: Chinese text in a .ps1 needs a UTF-8 BOM and the edit tool keeps eating it
# (same rationale as test\verify-all.ps1 and test\debug-verify.ps1). Keep this file pure ASCII
# (no Chinese comments, no Chinese paths) -- a non-ASCII byte here means GBK decoding trouble.
#
# WHY this gate exists (2026-09-21, card T-20260921-194703):
#   Every other gate compiles *samples* (5-15 lines) or inspects bytes. Twice in one day the real
#   application shipped a product that COMPILED but never RAN:
#     (1) import-table DLL name reservation did not match the writer -> every Name RVA shifted by 4
#         -> loader reported STATUS_DLL_NOT_FOUND 0xC0000135 at process start;
#     (2) the array length lived in the low 3 decimal digits of the packed var spec -> char x[2048]
#         became 48 -> the frame was under-allocated -> 0xC0000005 writing past the frame.
#   Both passed "sample gate + 1009 regressions + differential gate" with zero noise. Only RUNNING
#   the real product shows them. So: "it compiles" is not progress.
#
# What this gate does:
#   1. compiles apps\m2_float\main.fl (2600+ lines, 41 globals, 47 structs, real Win32/LHM imports)
#      with flint.exe AND with the self-hosted boot\b1_emit.exe
#   2. clears the ASLR bits (DYNAMIC_BASE|HIGH_ENTROPY_VA) in both products. Reason is NOT codegen:
#      this host has an AMD GPU and atiadlxx.dll (the vendor library the app imports) faults with
#      0xC0000005 when the image is randomly based. Proven by a single-variable test -- flipping only
#      those 2 header bytes swaps pass/fail with no recompile (see the 2026-09-21 handover notes).
#   3. runs both products under the app's own self-check switches (dump.on + demo.on). demo.on feeds
#      sample data, which makes the row text deterministic, so the whole row pipeline is compared.
#   4. compares the dumps BYTE FOR BYTE after masking the genuine LIVE fields (everything else in the
#      dump comes from demo's fixed sample data, so it is compiler-determined and comparable):
#        tick=<N>          GetTickCount at dump time
#        dp=<S> v=<V> p=<P> live disk-busy reading -- note BOTH the state letter and the p= value
#                          are live, and the p= value can end with '/' (`p=00/`), so `p=\d+` was not
#                          enough (2026-09-22: the leftover slash made the mask self-check fail).
#                          `v=` stays visible on purpose. `sw=` in the cfg line is ALSO deliberately
#                          left visible -- it is a real codegen signal, and this gate is what caught
#                          A2's dropped statement (boot printed sw=12 where flint printed 8063).
#        DISK|<N>%|        the same live reading rendered into row L4
#        d=<N> u=<N>       raw network byte counters (live channel; found on the first run of this gate:
#                          two runs of the SAME flint product differed by exactly 2 bytes downloaded)
#      The mask is self-checked: the flint product is run twice and the two runs must also match,
#      otherwise the mask is incomplete and the gate says so instead of blaming the compiler.
#      The product keeps its message loop running after writing the dump, so the gate stops it once the
#      file is complete -- that is expected behaviour, not a failure.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\loop-verify.ps1
#   powershell ... -File test\loop-verify.ps1 -FlintRuns 1 -TimeoutSec 60
#   -KeepWork keeps tmp\loopcheck (default: also kept -- the dumps are the evidence).
#
# Exit code 0 only when every check passes. Scratch dir: tmp\loopcheck\*.txt (dumps + masked copies).
#
# 2026-09-22 (card T-20260922-201155) -- stability hardening, two changes, both about the OBSERVER:
#   (1) -TimeoutSec default 90 -> 120 s, and each product run gets -RunRetries (default 1) extra tries
#       when no *stable* dump was observed.  Why: the product writes its first dump 10 s after start
#       and rewrites it every 10 s (apps\m2_float\main.fl: "dump_mode == 1 && GetTickCount()-g_dump_t0
#       >= 10000"), while this gate decides "the dump is complete" by sampling the file size, sleeping
#       300 ms and re-sampling.  On a loaded machine that quiet 300 ms window can be missed even though
#       the dump IS on disk: measured 20/20 runs wrote a dump (516/517 bytes, at 10 s or ~15 s) and one
#       full-gate round still reported "no dump within 90 s" (product exit 90).  A retry cannot hide a
#       real hang (a hung product produces no dump on the retry either).
#   (2) The boot-vs-flint differential check now requires boot == flint (it used to hard-code 42),
#       because the new sarp1 sample legitimately returns 18337.  The 42-only samples are unchanged in
#       spirit: for them boot == flint == 42 still has to hold.

param(
  [int]$TimeoutSec = 120,
  [int]$FlintRuns = 2,
  [int]$RunRetries = 1,
  [switch]$KeepWork
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$flint   = Join-Path $root 'flint.exe'
$boot    = Join-Path $root 'boot\b1_emit.exe'
$appSrc  = Join-Path $root 'apps\m2_float\main.fl'
$appDir  = Split-Path $appSrc -Parent
$work    = Join-Path $root 'tmp\loopcheck'
$scDir   = Join-Path $root 'tmp\row-probe\selfcheck'
$dumpPath = Join-Path $root 'tmp\row-probe\rows-dump.txt'
$bootOut = Join-Path $appDir 'main.exe'   # boot names its product "source dir + .exe" (B2b rule)

$script:pass = 0
$script:total = 0
function Ok([string]$m)   { Write-Host "ok   $m"; $script:pass++; $script:total++ }
function Bad([string]$m)  { Write-Host "FAIL $m"; $script:total++ }
function Info([string]$m) { Write-Host "     $m" }

# ---------------------------------------------------------------- inputs
Write-Host '===== loop-verify: real application, both compilers, byte-compared dumps ====='
foreach ($p in @($flint, $boot, $appSrc)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL missing input: $p"; exit 2 }
}
Info ("flint.exe   " + (Get-Item -LiteralPath $flint).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') +
      "  sha256=" + (Get-FileHash -LiteralPath $flint -Algorithm SHA256).Hash.Substring(0, 16))
Info ("b1_emit.exe " + (Get-Item -LiteralPath $boot).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') +
      "  sha256=" + (Get-FileHash -LiteralPath $boot -Algorithm SHA256).Hash.Substring(0, 16))
Info ("app source  " + $appSrc + "  (" + (Get-Item -LiteralPath $appSrc).Length + " bytes)")
Info ("boot product goes to " + $bootOut + " (deleted again at the end)")

New-Item -ItemType Directory -Force -Path $work | Out-Null
Get-ChildItem -LiteralPath $work -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# the product needs its own directory to carry HwBridge.dll (import) + config.json (cfg line)
foreach ($f in @('HwBridge.dll', 'config.json')) {
  $src = Join-Path $appDir $f
  if (-not (Test-Path -LiteralPath $src)) { Write-Host "FAIL missing $f in $appDir"; exit 2 }
  Copy-Item -LiteralPath $src -Destination (Join-Path $work $f) -Force
}

# ---------------------------------------------------------------- self-check switches
$madeScDir = $false
if (-not (Test-Path -LiteralPath $scDir)) { New-Item -ItemType Directory -Force -Path $scDir | Out-Null; $madeScDir = $true }
$madeDumpOn = $false; $madeDemoOn = $false
if (-not (Test-Path -LiteralPath (Join-Path $scDir 'dump.on'))) {
  Set-Content -LiteralPath (Join-Path $scDir 'dump.on') -Value 'on' -Encoding ASCII; $madeDumpOn = $true
}
if (-not (Test-Path -LiteralPath (Join-Path $scDir 'demo.on'))) {
  Set-Content -LiteralPath (Join-Path $scDir 'demo.on') -Value 'on' -Encoding ASCII; $madeDemoOn = $true
}
Info ("self-check switches: dump.on=" + (-not $madeDumpOn) + " existed, demo.on=" + (-not $madeDemoOn) + " existed (created ones are removed again)")

$hadBootOut = Test-Path -LiteralPath $bootOut
if ($hadBootOut) { Copy-Item -LiteralPath $bootOut -Destination (Join-Path $work 'main.exe.preexisting') -Force }

# ---------------------------------------------------------------- helpers
function Clear-Aslr([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 0x100) { throw "file too small: $path" }
  $lf = [BitConverter]::ToInt32($b, 0x3C)          # e_lfanew
  $opt = $lf + 24                                  # PE sig + file header
  $dcOff = $opt + 0x46                             # DllCharacteristics (PE32+ optional header)
  $dcOld = [BitConverter]::ToUInt16($b, $dcOff)
  $dcNew = $dcOld -band (-bnot 0x60)               # clear DYNAMIC_BASE(0x40) | HIGH_ENTROPY_VA(0x20)
  $b[$dcOff] = [byte]($dcNew -band 0xFF)
  $b[$dcOff + 1] = [byte](($dcNew -shr 8) -band 0xFF)
  [IO.File]::WriteAllBytes($path, $b)
  return [pscustomobject]@{ Off = $dcOff; Old = $dcOld; New = $dcNew }
}

$gbk = [Text.Encoding]::GetEncoding(936)
function Get-MaskedBytes([string]$path) {
  $t = $gbk.GetString([IO.File]::ReadAllBytes($path))
  $t = [regex]::Replace($t, 'tick=\d+', 'tick=<T>')
  # 2026-09-22: the dp line carries TWO live fields, not one.  The old pattern only masked the
  # p=<N> part and required DIGITS after `p=`; the real reading can end with '/' (`p=00/`), so the
  # trailing slash survived masking, and the state LETTER after `dp=` was never masked at all
  # (it flips between C/O from run to run).  Both now masked; `v=` is deliberately KEPT visible.
  # NOTE: `sw=` in the cfg line is deliberately NOT masked -- it is a real signal (a codegen
  # regression made boot emit 12 instead of 8063 and this gate is what caught it).
  $t = [regex]::Replace($t, '(?m)^dp=(\S+)(\s+v=)(\S+)(\s+p=)\S+', 'dp=<S>${2}${3}${4}<P>')
  $t = [regex]::Replace($t, '(DISK\|)\d+(%\|)', '${1}<D>${2}')
  $t = [regex]::Replace($t, '(?m)^(\s*)d=(\d+)\s+u=(\d+)', '${1}d=<N> u=<N>')
  return ,$gbk.GetBytes($t)
}

function Compare-Masked([string]$pa, [string]$pb, [string]$label) {
  $a = Get-MaskedBytes $pa; $b = Get-MaskedBytes $pb
  if ($a.Length -ne $b.Length) {
    Bad ("$label : masked length differs (" + $a.Length + " vs " + $b.Length + ")")
    $la = $gbk.GetString($a).Split("`n"); $lb = $gbk.GetString($b).Split("`n")
    Compare-Object $la $lb | ForEach-Object { Info ("diff: " + $_.SideIndicator + " " + $_.InputObject) }
    return $false
  }
  for ($i = 0; $i -lt $a.Length; $i++) {
    if ($a[$i] -ne $b[$i]) {
      Bad ("$label : masked bytes differ at offset $i (" + $a[$i] + " vs " + $b[$i] + ")")
      $la = $gbk.GetString($a).Split("`n"); $lb = $gbk.GetString($b).Split("`n")
      Compare-Object $la $lb | ForEach-Object { Info ("diff: " + $_.SideIndicator + " " + $_.InputObject) }
      return $false
    }
  }
  Ok ("$label : " + $a.Length + " bytes byte-identical after masking")
  return $true
}

function Invoke-ProductOnce([string]$exe, [string]$tag) {
  Remove-Item -LiteralPath $dumpPath -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $seen = $false
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Milliseconds 200
    if (Test-Path -LiteralPath $dumpPath) {
      $l1 = (Get-Item -LiteralPath $dumpPath).Length
      Start-Sleep -Milliseconds 300
      $l2 = (Get-Item -LiteralPath $dumpPath).Length
      if ($l1 -gt 0 -and $l1 -eq $l2) { $seen = $true; break }
    }
  }
  $sw.Stop()
  $code = $null
  if ($p.HasExited) { $code = $p.ExitCode }
  else {
    # dump mode keeps the message loop alive: give it a moment to exit on its own, then stop it
    for ($w = 0; $w -lt 10; $w++) { if ($p.HasExited) { break }; Start-Sleep -Milliseconds 500 }
    if ($p.HasExited) { $code = $p.ExitCode }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $code = 'stopped-after-dump' }
  }
  $rc = if ($null -eq $code) { 'n/a' } else { "$code" }
  if (-not $seen) { return $null }
  $dst = Join-Path $work ("dump-$tag.txt")
  Copy-Item -LiteralPath $dumpPath -Destination $dst -Force
  return [pscustomobject]@{ Path = $dst; Sec = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Exit = $rc }
}

# 2026-09-22 (card T-20260922-201155): "no stable dump observed" is an OBSERVATION race, not a product
#   defect, so give one retry.  Measured with test\loop-flake-probe.ps1 (20/20 runs DID write a dump,
#   516/517 bytes, at 10 s or ~15 s): the failing round had the dump on disk, the gate just never saw a
#   quiet 300 ms window while the machine was loaded.  A retry does not weaken the criterion (a truly
#   hung product still shows no dump on the retry) -- it only removes the jitter.
function Invoke-Product([string]$exe, [string]$tag) {
  $attempt = 0
  $secs = @()
  while ($attempt -le $RunRetries) {
    $attempt = $attempt + 1
    $r = Invoke-ProductOnce $exe $tag
    if ($r) {
      if ($attempt -gt 1) { Info ("$tag : got a stable dump on attempt $attempt (earlier attempts used " + ($secs -join '+') + " s)") }
      Ok ("$tag : dump written in " + $r.Sec + " s, " + (Get-Item -LiteralPath $r.Path).Length + " bytes, exit=" + $r.Exit)
      return $r.Path
    }
    $secs += $TimeoutSec
    Info ("$tag : attempt $attempt saw no stable dump within " + $TimeoutSec + " s -- retrying ($dumpPath)")
    Remove-Item -LiteralPath $dumpPath -Force -ErrorAction SilentlyContinue
  }
  Bad ("$tag : " + ($attempt) + " attempts (" + $TimeoutSec + " s each) saw no stable dump -- the product really never wrote it, or it hangs")
  return $null
}

# ---------------------------------------------------------------- compile both products
Push-Location $root
$flintExe = Join-Path $work 'app_flint.exe'
& $flint $appSrc -o $flintExe 2>&1 | Out-Null
$cFlint = $LASTEXITCODE
if ($cFlint -eq 0 -and (Test-Path -LiteralPath $flintExe)) { Ok "flint compiled the app (exit=0)" }
else { Bad "flint could not compile the app (exit=$cFlint)" }

& $boot $appSrc 2>&1 | Out-Null
$cBoot = $LASTEXITCODE
Pop-Location
$bootExe = Join-Path $work 'app_boot.exe'
if ($cBoot -eq 0 -and (Test-Path -LiteralPath $bootOut)) {
  Copy-Item -LiteralPath $bootOut -Destination $bootExe -Force
  Ok ("boot compiled the app (exit=0), product " + (Get-Item -LiteralPath $bootExe).Length + " bytes")
} else {
  Bad "boot could not compile the app (exit=$cBoot, product present: $(Test-Path -LiteralPath $bootOut))"
}

try {
  # ------------------------------------------------------------ ASLR bits
  $anyRan = $true
  if (Test-Path -LiteralPath $flintExe) {
    $r = Clear-Aslr $flintExe
    Info ("flint product DllCharacteristics 0x{0:X4} -> 0x{1:X4} (offset 0x{2:X})" -f $r.Old, $r.New, $r.Off)
    $script:total++
    if (($r.Old -band 0x60) -eq 0x60) { $script:pass++; Write-Host 'ok   flint product declared the ASLR form before the patch' }
    else { Write-Host ("FAIL flint product did not declare DYNAMIC_BASE|HIGH_ENTROPY_VA (0x{0:X4}) -- wrong product?" -f $r.Old) }
  } else { $anyRan = $false }
  if (Test-Path -LiteralPath $bootExe) {
    $r = Clear-Aslr $bootExe
    Info ("boot  product DllCharacteristics 0x{0:X4} -> 0x{1:X4} (offset 0x{2:X})" -f $r.Old, $r.New, $r.Off)
    $script:total++
    if (($r.Old -band 0x60) -eq 0x60) { $script:pass++; Write-Host 'ok   boot product declared the ASLR form before the patch' }
    else { Write-Host ("FAIL boot product did not declare DYNAMIC_BASE|HIGH_ENTROPY_VA (0x{0:X4}) -- wrong product?" -f $r.Old) }
  } else { $anyRan = $false }

  # ------------------------------------------------------------ run
  if ($anyRan) {
    $flintDumps = @()
    for ($i = 1; $i -le $FlintRuns; $i++) {
      $d = Invoke-Product $flintExe ("flint" + $i)
      if ($d) { $flintDumps += $d }
    }
    $bootDump = Invoke-Product $bootExe 'boot1'

    if ($flintDumps.Count -ge 2) {
      # self-check: two runs of the SAME binary must agree after masking, otherwise the mask is
      # incomplete (live values leaking through) and any flint-vs-boot difference proves nothing.
      Compare-Masked $flintDumps[0] $flintDumps[1] 'mask self-check (flint run1 vs run2)' | Out-Null
    } else {
      Info 'mask self-check skipped (only one flint run)'
    }
    if ($flintDumps.Count -ge 1 -and $bootDump) {
      Compare-Masked $flintDumps[0] $bootDump 'CRITERION boot vs flint' | Out-Null
    }
  } else {
    Bad 'nothing to run (a product is missing)'
  }
}
finally {
  # ------------------------------------------------------------ cleanup: put the tree back
  if ($madeDumpOn) { Remove-Item -LiteralPath (Join-Path $scDir 'dump.on') -Force -ErrorAction SilentlyContinue }
  if ($madeDemoOn) { Remove-Item -LiteralPath (Join-Path $scDir 'demo.on') -Force -ErrorAction SilentlyContinue }
  if ($madeScDir -and (Test-Path -LiteralPath $scDir)) {
    if (@(Get-ChildItem -LiteralPath $scDir -Force).Count -eq 0) { Remove-Item -LiteralPath $scDir -Force -ErrorAction SilentlyContinue }
  }
  Remove-Item -LiteralPath $bootOut -Force -ErrorAction SilentlyContinue
  if ($hadBootOut -and (Test-Path -LiteralPath (Join-Path $work 'main.exe.preexisting'))) {
    Copy-Item -LiteralPath (Join-Path $work 'main.exe.preexisting') -Destination $bootOut -Force
    Info 'restored the pre-existing apps\m2_float\main.exe'
  }
  if (-not $KeepWork) {
    # keep the dumps (evidence) but drop the big copied DLL to keep tmp\ small
    Remove-Item -LiteralPath (Join-Path $work 'HwBridge.dll') -Force -ErrorAction SilentlyContinue
  }
  Info ("scratch: $work")
}

Write-Host ''
Write-Host '================ loop-verify summary ================'
Write-Host ("real-app smoke + dump byte compare: passed " + $script:pass + " / " + $script:total + " checks")
if ($script:pass -eq $script:total -and $script:total -gt 0) { exit 0 } else { exit 1 }
