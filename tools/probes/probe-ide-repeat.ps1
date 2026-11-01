# probe-ide-repeat.ps1 - FLINT Studio: holding an arrow key must keep moving (auto-repeat).
#
# Why: the editor polls GetAsyncKeyState and the old code only reacted to the 0->1 edge, so a
# HELD arrow key moved the caret exactly once ("连续方向键没反应"). The fix synthesises repeats
# (first press + one step every 45ms while held). This probe proves both directions:
#   TAP    one tap of Right moves exactly ONE codepoint (no over-fire)
#   HOLD-R holding Right ~700ms moves >= 5 codepoints
#   HOLD-D holding Down ~700ms moves >= 5 display rows
#   STOP   after the key is released it stops moving (delta stays put for 500ms)
#
# Hold is simulated with keybd_event down/up: the OS does NOT auto-repeat virtual keys pressed
# this way, so every extra step can only come from the app's own repeat logic.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP.
# ASCII only on purpose (BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 180,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Kb {
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr extra);
  public static void Down(byte vk) { keybd_event(vk, 0, 0, UIntPtr.Zero); }
  public static void Up(byte vk) { keybd_event(vk, 0, 2, UIntPtr.Zero); }
  public static void Hold(byte vk, int ms) { Down(vk); System.Threading.Thread.Sleep(ms); Up(vk); }
}
'@

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-repeat'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$State = Join-Path $Sand 'ai.state'

$script:Ok = $true
$script:Fails = @()

function Check([string]$Tag, [bool]$Cond, [string]$Detail) {
    $mark = if ($Cond) { 'ok  ' } else { 'FAIL' }
    Write-Check $Tag ("{0} {1}" -f $mark, $Detail)
    if (-not $Cond) { $script:Ok = $false; $script:Fails += $Tag }
}

$app = $null
$code = 1
try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    $lines = @()
    for ($i = 0; $i -lt 60; $i++) { $lines += ("int value{0} = {0};" -f $i) }
    [System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), (($lines -join "`n") + "`n"), (New-Object System.Text.ASCIIEncoding))
    Remove-Item $State -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw "PROBE_SKIP:window did not appear ($($app.Error))" }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'start'
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen' }
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 100 } 6000
    if ($null -eq $st0) { throw 'ai.state has no ST line' }
    $cur0 = $st0.Cur; $line0 = $st0.Line

    # ---- TAP: exactly one step ----
    [Kb]::Down(0x27); Start-Sleep -Milliseconds 60; [Kb]::Up(0x27)
    Start-Sleep -Milliseconds 500
    $stT = Read-StudioState $Sand
    $tapD = $stT.Cur - $cur0
    Check 'TAP' ($tapD -eq 1) ("one tap -> cur {0} -> {1} (delta {2}, want 1)" -f $cur0, $stT.Cur, $tapD)
    $cur1 = $stT.Cur

    # ---- HOLD-R: continuous ----
    [Kb]::Hold(0x27, 700)
    Start-Sleep -Milliseconds 500
    $stR = Read-StudioState $Sand
    $holdR = $stR.Cur - $cur1
    Check 'HOLD-R' ($holdR -ge 5) ("hold Right 700ms -> cur {0} -> {1} (delta {2}, want >=5)" -f $cur1, $stR.Cur, $holdR)

    # ---- HOLD-D: continuous rows ----
    $lineBefore = $stR.Line
    [Kb]::Hold(0x28, 700)
    Start-Sleep -Milliseconds 500
    $stD = Read-StudioState $Sand
    $holdD = $stD.Line - $lineBefore
    Check 'HOLD-D' ($holdD -ge 5) ("hold Down 700ms -> line {0} -> {1} (delta {2}, want >=5)" -f $lineBefore, $stD.Line, $holdD)

    # ---- STOP: released key must not keep moving ----
    $cur2 = $stD.Cur
    Start-Sleep -Milliseconds 600
    $stS = Read-StudioState $Sand
    Check 'STOP' ($stS.Cur -eq $cur2) ("released: cur stays {0} (got {1})" -f $cur2, $stS.Cur)

    $code = if ($script:Ok) { 0 } else { 1 }
    Write-Host ("RESULT     repeat={0} fails={1}" -f $(if ($script:Ok) { 'PASS' } else { 'FAIL' }), $(if ($script:Fails.Count -gt 0) { $script:Fails -join ',' } else { 'none' }))
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      {0}" -f $_.Exception.Message.Substring(11))
        Write-Host "RESULT     repeat=SKIP(env-contention)"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     repeat=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     repeat=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
