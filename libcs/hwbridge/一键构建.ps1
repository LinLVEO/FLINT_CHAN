# 一键构建.ps1 -- rebuild HwBridge.dll (LibreHardwareMonitor C# -> native DLL for FLINT) from a clean tree.
#
# ASCII-ONLY on purpose: PS 5.1 reads a .ps1 as ANSI(GBK) when it has no UTF-8 BOM, so CJK in a
# non-BOM script gets mangled into fake parse errors. Keep this file ASCII (same rule as tools\gen-altnames.ps1).
#
# Recipe source: FLINT明细.md §4.1 / §4.7 / §4.8  (zero Microsoft tools: NuGet ILCompiler + self-made CRT shim
#   + lld-link + /ENTRY:_DllMainCRTStartup + TLS alignment with the 0x1000 front block LEFT ALONE).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File 一键构建.ps1                 # full clean build + deploy
#   powershell -NoProfile -ExecutionPolicy Bypass -File 一键构建.ps1 -NoDeploy       # build only (e.g. while the window is running)
#   powershell -NoProfile -ExecutionPolicy Bypass -File 一键构建.ps1 -Verify          # also run the launch checks (positive + missing-DLL negative)
param(
  [switch]$NoDeploy,
  [switch]$Verify,
  [switch]$KeepObj,          # skip the "delete obj native" step (ONLY if you know MSBuild will relink)
  [string]$Dotnet = '',                    # empty = auto: prefer E:\dotnet (the SDK lives there), else PATH
  [string]$Lab    = 'E:\FLINT-lab',
  [string]$Proj   = 'E:\FLINT-lab\libcs\hwbridge',
  [string]$Shim   = 'E:\FLINT-lab\tmp\cs-aot-probe\shim',
  [string]$AppDir = 'E:\FLINT-lab\apps\m2_float'
)
$ErrorActionPreference = 'Stop'
$script:fail = 0

function Step([string]$msg) { Write-Host ('[step] ' + $msg) -ForegroundColor Cyan }
function Ok([string]$msg)   { Write-Host ('  OK   ' + $msg) -ForegroundColor Green }
function Bad([string]$msg)  { Write-Host ('  FAIL ' + $msg) -ForegroundColor Red; $script:fail++ }
function Info([string]$msg) { Write-Host ('       ' + $msg) -ForegroundColor Gray }

Write-Host '===== HwBridge.dll one-click build =====' -ForegroundColor Cyan
Write-Host ('time   : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ('project: ' + $Proj)

# ---------- 1. preconditions ----------
Step 'preconditions'
# NOTE: on this box `dotnet` on PATH is C:\Program Files\dotnet (runtime host, NO SDK).
#       The SDK lives in E:\dotnet (8.0.4xx). Pick the first candidate that actually reports an SDK.
if (-not $Dotnet) {
  foreach ($cand in @('E:\dotnet\dotnet.exe', (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'), 'dotnet.exe')) {
    try {
      $sdks = @(& $cand --list-sdks 2>$null)
      if ($sdks.Count -gt 0) { $Dotnet = $cand; break }
    } catch {}
  }
}
if (-not $Dotnet) { Bad 'no .NET SDK found (tried E:\dotnet, Program Files, PATH)'; Write-Host 'ABORT' -ForegroundColor Red; exit 2 }
$sdkList = @(& $Dotnet --list-sdks 2>$null)
Ok ('dotnet SDK -> ' + $Dotnet + '   [' + ($sdkList -join ' / ') + ']')
# the AOT runtime pack resolves its own runtime; point DOTNET_ROOT at the SDK root so apphost/ilc agree
$env:DOTNET_ROOT = Split-Path $Dotnet
Info ('DOTNET_ROOT=' + $env:DOTNET_ROOT)

$need = @{
  'gcc'      = 'gcc.exe'
  'objdump'  = 'objdump.exe'
}
foreach ($k in $need.Keys) {
  $c = Get-Command $need[$k] -ErrorAction SilentlyContinue
  if ($null -eq $c) { Bad ("$k not found in PATH ($($need[$k]))") } else { Ok ("$k -> " + $c.Source) }
}
$must = @(
  (Join-Path $Shim 'crtshim.c'),
  (Join-Path $Shim 'link.exe'),
  (Join-Path $Shim 'altnames.rsp'),
  (Join-Path $Proj 'HwBridge.csproj'),
  (Join-Path $Proj 'HwBridge.cs'),
  'E:\FLINT-lab\tmp\cs-aot-probe\sdk\microsoft.windows.sdk.cpp.x64\c\ucrt\x64\ucrt.lib',
  'E:\FLINT-lab\tmp\cs-aot-probe\sdk\microsoft.windows.sdk.cpp.x64\c\um\x64\kernel32.lib'
)
foreach ($m in $must) { if (Test-Path -LiteralPath $m) { Ok ('present: ' + $m) } else { Bad ('MISSING: ' + $m) } }
if ($script:fail -gt 0) { Write-Host 'ABORT: preconditions failed' -ForegroundColor Red; exit 2 }

# ---------- 2. CRT shim (source of the TLS directory + MSVC symbol stubs) ----------
Step 'rebuild CRT shim (crtshim.obj)'
Push-Location $Shim
try {
  $gccArgs = @('-O2', '-DSHIM_INIT_MODE=4', '-c', 'crtshim.c', '-o', 'crtshim.obj')
  Info ('gcc ' + ($gccArgs -join ' '))
  & gcc @gccArgs 2>&1 | ForEach-Object { Info $_ }
  if ($LASTEXITCODE -ne 0) { Bad ('gcc exit=' + $LASTEXITCODE) } else { Ok ('crtshim.obj rebuilt (' + (Get-Item crtshim.obj).Length + ' bytes)') }
  # regeneration is idempotent: the decorated-name table lives in tools\gen-altnames.ps1 (single source of truth)
  $gen = Join-Path $Proj '..\..\tmp\cs-aot-probe\tools\gen-altnames.ps1'
  if (Test-Path -LiteralPath $gen) {
    Info 'regenerating altnames.rsp ...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $gen 2>&1 | ForEach-Object { Info $_ }
    if ($LASTEXITCODE -ne 0) { Bad ('gen-altnames exit=' + $LASTEXITCODE) } else { Ok 'altnames.rsp regenerated' }
  } else { Info ('gen-altnames.ps1 not found, keeping existing altnames.rsp') }
} finally { Pop-Location }

# ---------- 3. clean (MSBuild increment does NOT relink on linker-input changes) ----------
Step 'clean build outputs'
if (-not $KeepObj) {
  $victims = @(
    (Join-Path $Proj 'obj\Release\net8.0-windows\win-x64\native'),
    (Join-Path $Proj 'out'),
    (Join-Path $Proj 'bin')
  )
  foreach ($v in $victims) {
    if (Test-Path -LiteralPath $v) { Remove-Item -LiteralPath $v -Recurse -Force; Ok ('removed ' + $v) }
  }
  Info 'why: changing crtshim.obj / LinkerArg does not trigger a relink, MSBuild only watches C# sources'
} else { Info 'KeepObj: skipping clean (relink not guaranteed)' }

# ---------- 4. publish ----------
Step 'dotnet publish (NativeAOT Shared + lld-link)'
$outDir = Join-Path $Proj 'out'
Push-Location $Proj
try {
  $pubArgs = @('publish', 'HwBridge.csproj', '-c', 'Release', '-r', 'win-x64', '-o', $outDir,
               '-p:IlcUseEnvironmentalTools=true',
               ('-p:CppLinker=' + (Join-Path $Shim 'link.exe')))
  Info ($Dotnet + ' ' + ($pubArgs -join ' '))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # redirect INSIDE the call (not through a pipeline: piping truncates and forges exit codes)
  $pubLog = Join-Path $env:TEMP 'hwbridge-publish.log'
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'   # native stderr + EAP=Stop would throw a bogus NativeCommandError
  & $Dotnet @pubArgs *> $pubLog
  $code = $LASTEXITCODE
  $ErrorActionPreference = $eap
  $sw.Stop()
  if ($code -ne 0) {
    Bad ('dotnet exit=' + $code)
    Info ('full log: ' + $pubLog + '  (tail below)')
    Get-Content -LiteralPath $pubLog -Tail 25 | ForEach-Object { Info $_ }
  } else { Ok ('publish ok in ' + [int]$sw.Elapsed.TotalSeconds + 's') }
} finally { Pop-Location }

$dll = Join-Path $outDir 'HwBridge.dll'
if (-not (Test-Path -LiteralPath $dll)) { Bad 'HwBridge.dll was not produced'; Write-Host 'ABORT' -ForegroundColor Red; exit 3 }
$fi = Get-Item -LiteralPath $dll
Ok ('artifact: ' + $dll + '  ' + $fi.Length + ' bytes  ' + $fi.LastWriteTime)

# a fresh artifact must be newer than its inputs, otherwise we are looking at a stale binary
$objShim = Get-Item -LiteralPath (Join-Path $Shim 'crtshim.obj')
if ($fi.LastWriteTime -lt $objShim.LastWriteTime) {
  Bad ('STALE: dll mtime ' + $fi.LastWriteTime + ' < crtshim.obj mtime ' + $objShim.LastWriteTime)
} else { Ok 'artifact is newer than crtshim.obj (real relink happened)' }

# ---------- 5. artifact assertions ----------
Step 'artifact assertions'
$dump = & objdump -p $dll 2>&1
# v1.4.7 (2026-09-17): the PresentMon channel added hw_pm_* exports -> name the REQUIRED ones explicitly so a
# rename/removal fails loudly instead of just lowering a count. (Old check was a count >= 4 via one regex.)
$needExports = @('hw_init', 'hw_snap', 'hw_snap64', 'hw_ready', 'hw_status', 'hw_rtss_mode', 'hw_rtss_flags',
                 'hw_pm_want', 'hw_pm_src', 'hw_pm_status', 'hw_pm_lines', 'hw_pm_stop')
$expNames = @()
foreach ($e in $dump) {
  $m = [regex]::Match($e, '\]\s+[0-9a-f]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*$')
  if ($m.Success) { $expNames += $m.Groups[1].Value }
}
$missing = @($needExports | Where-Object { $expNames -notcontains $_ })
if ($missing.Count -eq 0) { Ok ('exports ok: all ' + $needExports.Count + ' required hw_* entries present (named exports total ' + $expNames.Count + ')') }
else { Bad ('MISSING exports: ' + ($missing -join ', ')) }
Info ('named exports = ' + ($expNames -join ' '))
# TLS directory MUST be present: without it the AOT runtime borrows the host's TLS slot -> intermittent AV (FLINT明细 §4.7)
$tls = ($dump | Select-String -Pattern 'Thread Storage').Count
if ($tls -ge 1) { Ok 'TLS data directory present (required for NativeAOT stability)' } else { Bad 'TLS data directory MISSING -> do not ship this dll' }
Info (($dump | Select-String -Pattern 'DLL name|API|Thread Storage' | Select-Object -First 8) -join ' ; ')

# ---------- 5b. PresentMon.exe (the v1.4.7 FPS channel ships it next to the app) ----------
Step 'PresentMon.exe staging'
$pmSrc = 'E:\HardwareMonitor\PresentMon\PresentMon.exe'   # reference build's copy (see FLINT明细 borrow ledger)
$pmDst = Join-Path $AppDir 'PresentMon.exe'
if (Test-Path -LiteralPath $pmSrc) {
  $spm = Get-Item -LiteralPath $pmSrc
  Ok ('source: ' + $pmSrc + '  ' + $spm.Length + ' bytes')
  if (-not (Test-Path -LiteralPath $pmDst) -or (Get-FileHash -LiteralPath $pmSrc).Hash -ne (Get-FileHash -LiteralPath $pmDst).Hash) {
    if ($NoDeploy) { Info 'NoDeploy: PresentMon.exe differs but will not be copied' }
    else {
      try {
        Copy-Item -LiteralPath $pmSrc -Destination $pmDst -Force
        Ok ('copied PresentMon.exe -> ' + $pmDst)
      } catch { Bad ('copy PresentMon.exe failed: ' + $_.Exception.Message) }
    }
  } else { Ok 'PresentMon.exe in place (hash identical)' }
} else { Bad ('PresentMon.exe source missing: ' + $pmSrc + ' -> the FPS channel will degrade to RTSS/--') }

# ---------- 6. deploy ----------
$target = Join-Path $AppDir 'HwBridge.dll'
if ($NoDeploy) {
  Info ('NoDeploy: skipping copy to ' + $target)
} else {
  Step 'deploy to the app directory'
  $locked = $false
  try { Copy-Item -LiteralPath $dll -Destination $target -Force } catch { $locked = $true }
  if ($locked) {
    Bad ('copy failed - is m2_float.exe running with the old DLL loaded? (' + $_.Exception.Message + ')')
    Info 'close the floating window and rerun, or rerun with -NoDeploy while it is up'
  } else {
    $h1 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($h1 -eq $h2) { Ok ('deployed ' + $target + ' (sha256 match)') } else { Bad 'deployed copy hash mismatch' }
  }
}

# ---------- 7. optional launch checks ----------
if ($Verify) {
  Step 'launch checks (positive: runs with the DLL / negative: refuses without it)'
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class VB {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string win);
}
'@
  $exe = Join-Path $AppDir 'm2_float.exe'
  # NOTE: the app carries a requireAdministrator manifest -> it must be started via -Verb RunAs
  #       (`& exe` / plain Start-Process fails with "The requested operation requires elevation").
  #       Run this script from an ELEVATED shell, otherwise the child windows cannot be stopped again.
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Info 'WARNING: not elevated - starting the app works (UAC is silent here) but stopping it will fail (access denied). Prefer an elevated shell for -Verify.' }
  function Stop-App2 {
    foreach ($p in @(Get-Process -Name 'm2_float' -ErrorAction SilentlyContinue)) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Info ('could not stop pid ' + $p.Id + ': ' + $_.Exception.Message) }
    }
    Start-Sleep -Seconds 1
  }
  # negative: hide the DLL, the import table must fail to resolve -> window must NOT appear
  $hidden = Join-Path $AppDir 'HwBridge.dll.hidden'
  Stop-App2
  Move-Item -LiteralPath $target -Destination $hidden -Force
  $pn = Start-Process -FilePath $exe -WorkingDirectory $AppDir -Verb RunAs -PassThru
  Start-Sleep -Seconds 5
  $hn = [VB]::FindWindow('FLINTM2', $null)
  $aliveNeg = -not $pn.HasExited
  if ($hn -eq [IntPtr]::Zero) {
    if ($aliveNeg) {
      Ok 'negative criterion holds: NO window; process is stuck on the missing-DLL error dialog (expected Windows behaviour)'
      Stop-App2
    } else { Ok ('negative criterion holds: NO window, process exited (exit=' + $pn.ExitCode + ')') }
  } else {
    Bad ('negative criterion FAILED: a window came up even without HwBridge.dll (hwnd=' + $hn + ')')
    Stop-App2
  }
  Move-Item -LiteralPath $hidden -Destination $target -Force
  # positive: window must come up within a few seconds
  Start-Sleep -Seconds 2
  $pp = Start-Process -FilePath $exe -WorkingDirectory $AppDir -Verb RunAs -PassThru
  $hp = [IntPtr]::Zero
  for ($i = 0; $i -lt 40 -and $hp -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 300; $hp = [VB]::FindWindow('FLINTM2', $null) }
  if ($hp -ne [IntPtr]::Zero) { Ok ('positive criterion holds: FLINTM2 window up (hwnd=' + $hp + ')') } else { Bad 'positive criterion FAILED: window never appeared' }
  Stop-App2
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'DONE - all checks passed' -ForegroundColor Green; exit 0 }
else { Write-Host ($script:fail.ToString() + ' check(s) FAILED') -ForegroundColor Red; exit 1 }
