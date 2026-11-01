# background-gate.ps1 -- run test\verify-all.ps1 on a PRIVATE DESKTOP so nothing it spawns can
# appear on the user's screen or steal focus.
#
# Why (2026-10-24, measured twice):
#   1. Console flashes: run-tests compiles 1000+ cases and docgate calls the fact meter once per
#      key; Node's child_process on Windows shows a console window unless `windowsHide: true`.
#      Fixed at the source (run-tests / docgate / editor / debugger all pass windowsHide).
#   2. REAL WINDOWS: half the sample corpus is Windows-API behaviour -- api1 pops a MessageBox
#      ("FLINT v0.8"), api3 shows a Static window, ui1/ui2 self-draw a window, align_probe,
#      rtptr5, wxb even an error dialog.  Those are *products*, not consoles: windowsHide does
#      nothing for them, and the gate runs them a few hundred times per pass.  A 30 ms EnumWindows
#      watcher on 2026-10-24 recorded them popping on the interactive desktop -- that is the
#      the pile of popups the user saw.  The only durable answer is to give the whole gate its own
#      desktop: tools\silent-gate.ps1 (CreateDesktop + CreateProcessW with lpDesktop + job object).
#
# So the DEFAULT is now the private desktop.  -NormalDesktop is the escape hatch for debugging a
# step that needs the interactive desktop (it will pop windows -- use it while watching, not in
# the background).
#
# The private desktop also required one codepage fix: a console created without a window keeps the
# system OEM codepage (936 on a Chinese box), so PowerShell decodes flint's UTF-8 stdout as GBK and
# the gates' keyword matches silently fail (measured: debug 115/6, diffgate 1/243, and the doc gate
# 8 fake drifts).  test\verify-all.ps1 now pins [Console]::OutputEncoding to UTF-8 before any child
# starts; that is process/console-wide, so every `& powershell ...` child inherits cp 65001.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\background-gate.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\background-gate.ps1 -Only doc
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\background-gate.ps1 -NormalDesktop
#
# Logs: tmp\verify-all\background-<stamp>.log ; exit code = verify-all's.
param(
  [string]$Only = '',
  [int]$TimeoutSec = 3600,
  [switch]$NormalDesktop
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'tmp\verify-all'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $logDir ('background-' + $stamp + '.log')
$err = Join-Path $logDir ('background-' + $stamp + '.log.err')

$argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'test\verify-all.ps1'))
if ($Only -ne '') { $argv = $argv + @('-Only', $Only) }

if ($NormalDesktop) {
  Write-Host 'background-gate: NORMAL desktop (windows WILL pop; for debugging only)'
  & powershell.exe @argv 2>&1 | Tee-Object -FilePath $log
  $code = $LASTEXITCODE
} else {
  $silent = Join-Path $PSScriptRoot 'silent-gate.ps1'
  & $silent -Exe 'powershell.exe' -Argv $argv -WorkDir $root -Stream -TimeoutSec $TimeoutSec -OutFile $log -ErrFile $err
  $code = $LASTEXITCODE
}
if ($null -eq $code) { $code = 1 }
Write-Host ''
Write-Host ('GATE_LOG=' + $log)
exit $code
