# boot-bench.ps1 -- the ruler for the FLINT-side optimization route (card T-20260921-215305).
#
# ASCII-only on purpose: Chinese text in a .ps1 needs a UTF-8 BOM and the edit tool keeps eating it
# (same rationale as test\verify-all.ps1 / test\loop-verify.ps1). Keep this file pure ASCII.
#
# WHY: the bootstrap already closes (boot builds itself, fixed point, 4-5x FASTER compile throughput
# than real flint), but the products BOOT emits run 5-10x slower than the ones real flint emits:
#   k1 10.1x / k2 5.1x / k3 7.4x   (2026-09-21, bench\bench_one.fl, same source, same iters)
# Root cause: the whole M1..M8 optimization set lives in the C backend (src\*.c); boot's emitter
# (boot\b1_emit.fl) is a straight translation with no register allocation / no in-place ops.
# The route decided by the user: port those optimizations into the FLINT-side emitter.
# Project discipline for that route: BUILD THE RULER FIRST, THEN COUNT INSTRUCTIONS, ONLY THEN CUT.
#
# What this script does:
#   1. compiles bench\bench_one.fl with BOTH compilers (boot's product goes to bench_one_boot.exe,
#      the tracked bench_one.exe is never touched)
#   2. runs kernel 1|2|3 for N rounds each, takes the MIN per kernel (min is the stable statistic;
#      the loop is identical work every round), prints ticks -> ns/round and the flint/boot ratio
#   3. -Loops: disassembles both products (objdump -d -Mintel) and counts, per product, the total
#      instruction count, the total memory-operand count, and the biggest backward-branch loops
#      (instruction count + memory operands per body). That is the "count the instructions before
#      you touch anything" step -- it tells where the money goes and gives the upper bound.
#   4. -Record writes bench\boot-bench-baseline.txt; without -Record an existing baseline is compared
#      and any boot kernel that got >5% slower is reported as a REGRESSION (exit 1).
#
# Usage (any cwd; the script fixes locations itself):
#   powershell -NoProfile -ExecutionPolicy Bypass -File bench\boot-bench.ps1
#   powershell ... -File bench\boot-bench.ps1 -Loops
#   powershell ... -File bench\boot-bench.ps1 -Rounds 5 -Iters 7 -Record
#
# Exit code 0 only when every kernel produced a tick count and no baseline regression was found.

param(
  [int]$Iters = 7,
  [int]$Rounds = 3,
  [int[]]$Kernels = @(1, 2, 3),
  [switch]$Loops,
  [switch]$Record,
  [double]$RegressTol = 5.0
)

$ErrorActionPreference = 'Continue'
$bench = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $bench
$flint = Join-Path $root 'flint.exe'
$boot = Join-Path $root 'boot\b1_emit.exe'
$src = Join-Path $bench 'bench_one.fl'
$bootSrc = Join-Path $bench 'bench_one_boot.fl'
$bootExe = Join-Path $bench 'bench_one_boot.exe'
$flintExe = Join-Path $bench 'bench_one_flint.exe'
$baseFile = Join-Path $bench 'boot-bench-baseline.txt'
$tmp = Join-Path $root 'tmp\boot-bench'

$script:fail = 0
function Ok([string]$m)   { Write-Host "ok   $m" }
function Bad([string]$m)  { Write-Host "FAIL $m"; $script:fail = $script:fail + 1 }
function Info([string]$m) { Write-Host "     $m" }

foreach ($p in @($flint, $boot, $src)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL missing input: $p"; exit 2 }
}
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host '===== boot-bench: boot product vs real-flint product (same source, same session) ====='
Info ("flint.exe  " + (Get-Item -LiteralPath $flint).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + "  sha256=" + (Get-FileHash -LiteralPath $flint -Algorithm SHA256).Hash.Substring(0, 16))
Info ("b1_emit.exe " + (Get-Item -LiteralPath $boot).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + "  sha256=" + (Get-FileHash -LiteralPath $boot -Algorithm SHA256).Hash.Substring(0, 16))

# ---------------------------------------------------------------- build both products
Copy-Item -LiteralPath $src -Destination $bootSrc -Force
& $flint $src '-o' $flintExe 2>&1 | Out-Null
$cF = $LASTEXITCODE
& $boot $bootSrc 2>&1 | Out-Null
$cB = $LASTEXITCODE
if ($cF -eq 0 -and (Test-Path -LiteralPath $flintExe)) { Ok ("flint built the kernel host (exit=0, " + (Get-Item -LiteralPath $flintExe).Length + " bytes)") }
else { Bad "flint could not build bench_one (exit=$cF)" }
if ($cB -eq 0 -and (Test-Path -LiteralPath $bootExe)) { Ok ("boot  built the kernel host (exit=0, " + (Get-Item -LiteralPath $bootExe).Length + " bytes)") }
else { Bad "boot could not build bench_one (exit=$cB)" }

# ---------------------------------------------------------------- run the kernels
function Run-Kernel([string]$exe, [int]$k) {
  Push-Location $bench
  $o = (& $exe $k $Iters 2>&1) -join ' '
  Pop-Location
  $t = [regex]::Match($o, 'ticks=(\d+)')
  $q = [regex]::Match($o, 'qpf=(\d+)')
  $n = [regex]::Match($o, 'n=(\d+)')
  $r = [regex]::Match($o, 'result=(-?\d+)')
  if (-not ($t.Success -and $q.Success -and $n.Success)) { return $null }
  return [pscustomobject]@{
    Ticks = [int64]$t.Groups[1].Value
    Qpf   = [int64]$q.Groups[1].Value
    N     = [int]$n.Groups[1].Value
    Result = $(if ($r.Success) { [int]$r.Groups[1].Value } else { 0 })
    Raw   = $o
  }
}

$rows = @()
foreach ($k in $Kernels) {
  $tf = @(); $tb = @(); $res = $null
  for ($i = 1; $i -le $Rounds; $i++) {
    $a = Run-Kernel $flintExe $k
    if ($a) { $tf += $a.Ticks; $res = $a }
    $b = Run-Kernel $bootExe $k
    if ($b) { $tb += $b.Ticks }
  }
  if ($tf.Count -eq 0 -or $tb.Count -eq 0) { Bad "kernel k$k : no usable tick reading (flint=$($tf.Count) boot=$($tb.Count))"; continue }
  $mf = ($tf | Measure-Object -Minimum).Minimum
  $mb = ($tb | Measure-Object -Minimum).Minimum
  $nsf = [Math]::Round($mf / $res.Qpf * 1e9 / $res.N, 4)
  $nsb = [Math]::Round($mb / $res.Qpf * 1e9 / $res.N, 4)
  $rows += [pscustomobject]@{
    kernel = "k$k"
    flint_ticks_min = $mf
    boot_ticks_min = $mb
    flint_ns_per_round = $nsf
    boot_ns_per_round = $nsb
    ratio = [Math]::Round($mb / $mf, 2)
    result = $res.Result
    rounds = $Rounds
  }
  Info ("k$k ticks: flint " + ($tf -join '/') + "   boot " + ($tb -join '/'))
}
$rows | Format-Table -AutoSize

# ---------------------------------------------------------------- optional: count instructions
if ($Loops) {
  Write-Host ''
  Write-Host '--- instruction account (objdump -d -Mintel): total + biggest backward-branch loops ---'
  $objdump = Get-Command objdump -ErrorAction SilentlyContinue
  if (-not $objdump) { Bad 'objdump not found -- -Loops skipped' }
  else {
    foreach ($pair in @(@($flintExe, 'flint'), @($bootExe, 'boot'))) {
      $dis = Join-Path $tmp ("$($pair[1]).dis")
      cmd /c "objdump -d -Mintel `"$($pair[0])`" > `"$dis`" 2>&1" | Out-Null
      if (-not (Test-Path -LiteralPath $dis)) { Bad "disassembly missing for $($pair[1])"; continue }
      $ins = New-Object System.Collections.ArrayList
      foreach ($l in [IO.File]::ReadAllLines($dis)) {
        $m = [regex]::Match($l, '^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2}\s+)+\s*([a-z][a-z0-9]*)\s*(.*)$')
        if ($m.Success) {
          [void]$ins.Add([pscustomobject]@{
            Addr = [Convert]::ToInt64($m.Groups[1].Value, 16)
            Mn = $m.Groups[2].Value
            Op = $m.Groups[3].Value.Trim()
          })
        }
      }
      if ($ins.Count -eq 0) { Bad "no instructions parsed for $($pair[1])"; continue }
      $memAll = @($ins | Where-Object { $_.Op -match '\[(rbp|rsp|r[0-9]+)' }).Count
      Info ("$($pair[1]) product : " + $ins.Count + " instructions, " + $memAll + " with a memory operand")
      # NOTE (trap hit for real on 2026-09-21): do NOT name this $loops -- PowerShell variable names
      # are case-insensitive, so $loops IS the [switch]$Loops parameter and .Add() fails at runtime
      # ("SwitchParameter does not contain a method named Add") while the timing half stays green.
      # Same family as the archived "$Args cannot be a parameter name" trap.
      $loopList = New-Object System.Collections.ArrayList
      for ($i = 0; $i -lt $ins.Count; $i++) {
        if ($ins[$i].Mn -notmatch '^j') { continue }
        # objdump prints branch targets as 0x140001055 -- the 0x prefix MUST be optional-but-matched,
        # otherwise "^([0-9a-f]+)" grabs the lone "0" of "0x..." and every branch looks like a jump to 0
        # (first run of this tool: 200 fake "loops" each covering the whole .text).
        $mm = [regex]::Match($ins[$i].Op, '^(?:0x)?([0-9a-f]+)')
        if (-not $mm.Success) { continue }
        $target = [Convert]::ToInt64($mm.Groups[1].Value, 16)
        if ($target -ge $ins[$i].Addr) { continue }        # forward branch -- not a loop back edge
        $s = 0
        for ($k2 = $i; $k2 -ge 0; $k2--) { if ($ins[$k2].Addr -ge $target) { $s = $k2 } else { break } }
        $body = $ins[$s..$i]
        $mem = @($body | Where-Object { $_.Op -match '\[(rbp|rsp|r[0-9]+)' }).Count
        # mnemonic histogram of the loop body -- this is the "where does the money go" line
        $h = @{}
        foreach ($x in $body) { if ($h.ContainsKey($x.Mn)) { $h[$x.Mn] = $h[$x.Mn] + 1 } else { $h[$x.Mn] = 1 } }
        $hist = (($h.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 8 |
                  ForEach-Object { $_.Key + 'x' + $_.Value }) -join ' ')
        [void]$loopList.Add([pscustomobject]@{
          start = ('0x{0:X}' -f $ins[$s].Addr); ins = $body.Count; mem = $mem; hist = $hist
        })
      }
      # print EVERY loop (there are only ~8-10 per product) sorted by address: the kernels' own hot
      # loops are the SMALL ones, so "top N by size" hides exactly what we came for.
      $top = $loopList | Sort-Object -Property start
      Info ("$($pair[1]) loops found: " + $loopList.Count + " (all, sorted by address)")
      $top | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
  }
}

# ---------------------------------------------------------------- baseline / regression
if ($rows.Count -gt 0) {
  if ($Record) {
    $lines = @("# boot-bench baseline -- boot-side ticks (min of N rounds). Recorded by bench\boot-bench.ps1 -Record")
    $lines += ("# " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  iters=$Iters rounds=$Rounds  b1_emit sha256=" + (Get-FileHash -LiteralPath $boot -Algorithm SHA256).Hash.Substring(0, 16))
    foreach ($r in $rows) { $lines += ("$($r.kernel) boot_ticks_min=$($r.boot_ticks_min) flint_ticks_min=$($r.flint_ticks_min) ratio=$($r.ratio)") }
    [IO.File]::WriteAllLines($baseFile, $lines)
    Ok "baseline recorded -> $baseFile"
  } elseif (Test-Path -LiteralPath $baseFile) {
    $bl = @{}
    foreach ($l in [IO.File]::ReadAllLines($baseFile)) {
      $m = [regex]::Match($l, '^(k\d) boot_ticks_min=(\d+)')
      if ($m.Success) { $bl[$m.Groups[1].Value] = [int64]$m.Groups[2].Value }
    }
    foreach ($r in $rows) {
      if (-not $bl.ContainsKey($r.kernel)) { Info ("$($r.kernel): no baseline entry"); continue }
      $old = $bl[$r.kernel]
      $delta = [Math]::Round((($r.boot_ticks_min - $old) / $old) * 100, 1)
      if ($delta -gt $RegressTol) { Bad ("$($r.kernel): boot product REGRESSED " + $delta + "% vs baseline (" + $old + " -> " + $r.boot_ticks_min + ")") }
      else { Ok ("$($r.kernel): vs baseline " + $delta + "% (tol +$RegressTol%)") }
    }
  } else { Info 'no baseline file yet -- run with -Record to create one' }
}

# ---------------------------------------------------------------- cleanup build artifacts
Remove-Item -LiteralPath $bootSrc, $bootExe, $flintExe -Force -ErrorAction SilentlyContinue
if (-not $Loops) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '================ boot-bench summary ================'
$med = if ($rows.Count -gt 0) { [Math]::Round((($rows | Measure-Object -Property ratio -Average).Average), 2) } else { 'n/a' }
Write-Host ("kernels measured: " + $rows.Count + "/" + $Kernels.Count + "   mean boot/flint ratio: " + $med + "   failures: " + $script:fail)
if ($script:fail -eq 0 -and $rows.Count -eq $Kernels.Count) { exit 0 } else { exit 1 }
