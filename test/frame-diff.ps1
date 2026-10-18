# frame-diff.ps1 — frame size diff probe: compile the same sample with real flint and boot,
# then read main's `sub rsp,N` from the entry point via objdump.
# Usage: pwsh -File frame-diff.ps1 -Src <path.fl> [-Quiet]
param(
  [Parameter(Mandatory=$true)][string]$Src,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# 练习副本改动：原先写死 E:\FLINT\... → 会去跑原件的编译器。改成按本脚本位置推导，副本自包含。
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent $here
$flint   = Join-Path $root 'flint.exe'
$boot    = Join-Path $root 'boot\b1_emit.exe'
$objdump = 'E:\mingw64\bin\objdump.exe'
$work    = Join-Path $env:TEMP 'flint-framediff'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$probe = Join-Path $work 'probe.fl'
Copy-Item -LiteralPath $Src -Destination $probe -Force

$outFlint = Join-Path $work 'out_flint.exe'
$outBoot  = Join-Path $work 'probe.exe'
foreach ($f in @($outFlint, $outBoot)) { if (Test-Path $f) { Remove-Item $f -Force } }

$logF = & $flint $probe -o $outFlint 2>&1 | Out-String
$rcF = $LASTEXITCODE
$logB = & $boot $probe 2>&1 | Out-String
$rcB = $LASTEXITCODE

function Get-FrameSize([string]$exe) {
  if (-not (Test-Path $exe)) { return $null }
  $b = [IO.File]::ReadAllBytes($exe)
  $pe = [BitConverter]::ToInt32($b, 0x3C)
  $magic = [BitConverter]::ToUInt16($b, $pe + 0x18)
  $ep = [BitConverter]::ToInt32($b, $pe + 0x28)
  if ($magic -eq 0x20b) { $ib = [BitConverter]::ToInt64($b, $pe + 0x30) }
  else { $ib = [BitConverter]::ToInt32($b, $pe + 0x34) }
  $va = $ib + $ep
  $a = '0x{0:x}' -f $va
  $z = '0x{0:x}' -f ($va + 64)
  $txt = & $objdump -d --start-address=$a --stop-address=$z -M intel $exe 2>$null | Out-String
  $m = [regex]::Match($txt, 'sub\s+rsp,0x([0-9a-f]+)')
  if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
  return $null
}

$fF = Get-FrameSize $outFlint
$fB = Get-FrameSize $outBoot

$name = [IO.Path]::GetFileName($Src)
if ($rcF -ne 0) { Write-Host "[$name] flint compile failed rc=$rcF`n$logF" -ForegroundColor Red }
if ($rcB -ne 0) { Write-Host "[$name] boot compile failed rc=$rcB`n$logB" -ForegroundColor Red }
$sf = if ($null -eq $fF) { '?' } else { '0x{0:x} ({1} slots)' -f $fF, ($fF / 8) }
$sb = if ($null -eq $fB) { '?' } else { '0x{0:x} ({1} slots)' -f $fB, ($fB / 8) }
$diff = if ($null -ne $fF -and $null -ne $fB) { ($fB - $fF) / 8 } else { $null }
$tag = if ($diff -eq 0) { 'SAME' } elseif ($null -ne $diff) { "DIFF boot-flint = $diff slots" } else { 'n/a' }
$color = if ($diff -eq 0) { 'Green' } elseif ($null -ne $diff) { 'Yellow' } else { 'Red' }
if (-not $Quiet) {
  Write-Host ("{0,-14} flint={1,-20} boot={2,-20} {3}" -f $name, $sf, $sb, $tag) -ForegroundColor $color
}
[pscustomobject]@{ Name = $name; FlintFrame = $fF; BootFrame = $fB; DiffSlots = $diff; RcFlint = $rcF; RcBoot = $rcB }
