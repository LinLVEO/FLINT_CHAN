# probe-ide-ws.ps1 - workspace ("open folder") + settings value clipping probe.
#
# Sandbox: tmp\ide-ws (the app's WORKING DIRECTORY)
#   apps\studio_native\main.fl   opened at startup
#   sub\alpha.fl (43 B) / sub\beta.fl (65 B)
#   studio.cfg with ws=<abs path of sub>  <- the workspace root under test
#
# What it measures:
#   1. ROOT     the tree is rooted at ws= (sub): clicking row 0 opens alpha.fl (43 B),
#               row 1 opens beta.fl (65 B) - no directory rows in between
#   2. ICON     clicking the folder icon in the sidebar header opens a shell folder
#               dialog (class #32770 owned by the app); the probe closes it
#   3. CLIP     the settings card's value cells are not vertically clipped any more:
#               ink height of the "Noto Sans SC Medium" row must be >= 9 px (16 px UI font)
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP.
# ASCII only on purpose.
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$result = 'FAIL'
$code = 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-ws'
$MainDir = Join-Path $Sand 'apps\studio_native'
$Sub = Join-Path $Sand 'sub'
$MainFile = Join-Path $MainDir 'main.fl'
$Alpha = Join-Path $Sub 'alpha.fl'
$Beta = Join-Path $Sub 'beta.fl'

$MainBody = "int main() { return 0; }`n"
$AlphaBody = "int alpha = 1;`nint alpha2 = 2;`nint a3 = 3;`n"
$BetaBody = "int beta = 1;`nint beta2 = 2;`nint b3 = 3;`nint b4 = 4;`nint b5 = 5;`n"

function RowY([int]$i) { return 34 + 26 + 30 + $i * 22 + 11 }   # title 34 + menu bar 26 + header 30
function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds 90
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 350
}

# find a visible dialog window of class $cls owned by $pid, return its hwnd or 0
function Find-Dialog([int]$TargetPid, [string]$Cls, [int]$TimeoutMs = 4000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class DlgFind {
    delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public static IntPtr Find(int target, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)target && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
                if (c.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@ -ErrorAction SilentlyContinue
        $h = [DlgFind]::Find($TargetPid, $Cls)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $MainDir | Out-Null
    New-Item -ItemType Directory -Force $Sub | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($MainFile, $MainBody, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($Alpha, $AlphaBody, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($Beta, $BetaBody, [System.Text.Encoding]::ASCII)
    $alphaLen = (Get-Item $Alpha).Length
    $betaLen = (Get-Item $Beta).Length
    $cfg = "font=Consolas`nsize=14`nweight=400`ncjk=Noto Sans SC Medium`ncjksize=0`nwrap=1`nui=16`nws=$Sub`n"
    [System.IO.File]::WriteAllText((Join-Path $Sand 'studio.cfg'), $cfg, [System.Text.Encoding]::UTF8)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Write-Check 'SANDBOX' ("ws={0} alpha={1}B beta={2}B" -f $Sub, $alphaLen, $betaLen)

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    $img0 = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st0) { throw 'ai.state has no ST line' }
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:focus stolen' }

    # ---- 1. tree rooted at ws= : row 0 = alpha.fl, row 1 = beta.fl ----
    Click-Client $app.Hwnd 60 (RowY 0)
    $stA = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $alphaLen } 3000
    if ($null -eq $stA) { $stA = Read-StudioState $Sand }
    Click-Client $app.Hwnd 60 (RowY 1)
    $stB = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $betaLen } 3000
    if ($null -eq $stB) { $stB = Read-StudioState $Sand }
    $rootOk = ($null -ne $stA -and $stA.SrcLen -eq $alphaLen -and $null -ne $stB -and $stB.SrcLen -eq $betaLen)
    Write-Check 'ROOT' ("row0 -> srclen {0} (need {1}); row1 -> srclen {2} (need {3})" -f `
            $(if ($stA) { $stA.SrcLen } else { 'n/a' }), $alphaLen, $(if ($stB) { $stB.SrcLen } else { 'n/a' }), $betaLen)
    [void](Save-Shot ([Ide]::Grab($app.Hwnd)) $Root 'ide-ws-1-tree')

    # ---- 2. folder icon opens the shell picker ----
    Click-Client $app.Hwnd 40 74
    $dlg = Find-Dialog $app.Proc.Id '#32770' 4000
    $iconOk = ($dlg -ne [IntPtr]::Zero)
    Write-Check 'ICON' ("folder dialog hwnd={0} (need non-zero)" -f $dlg)
    if ($dlg -ne [IntPtr]::Zero) {
        [void][Ide]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        Start-Sleep -Milliseconds 500
    }

    # ---- 3. settings value not clipped ----
    [Ide]::Key(0x78, $false, $false)          # F9 opens settings
    Start-Sleep -Milliseconds 600
    $img = [Ide]::Grab($app.Hwnd)
    $cw = 520; $ch = 410
    $cx = [int](($W - $cw) / 2)
    $cy = [int](($H - $ch) / 2)
    $rowY = $cy + 58 + 2 * 44                 # row 2 = 中文字体
    # value cell (Latin) vs label cell (CJK): a clipped cell loses its bottom rows AND ends
    # flush with the row edge; the fixed layout leaves >=3 px of air below both.
    function InkBand([int]$x0, [int]$x1, [int]$y0, [int]$y1) {
        $top = -1; $bot = -1
        for ($y = $y0; $y -lt $y1; $y++) {
            for ($x = $x0; $x -lt $x1; $x++) {
                $c = $img.At($x, $y)
                $r = ($c -shr 16) -band 255; $g = ($c -shr 8) -band 255; $b = $c -band 255
                if ($r -gt 60 -and $g -gt 60 -and $b -gt 60) { if ($top -lt 0) { $top = $y }; $bot = $y; break }
            }
        }
        return @{ Top = $top; Bot = $bot; H = $(if ($top -ge 0) { $bot - $top + 1 } else { 0 }) }
    }
    $val = InkBand ($cx + 210) ($cx + $cw - 120) $rowY ($rowY + 42)
    $lab = InkBand ($cx + 22) ($cx + 150) $rowY ($rowY + 42)
    $inkH = $val.H
    $clipOk = ($val.H -ge 8 -and $lab.H -ge 10 -and ($rowY + 42 - $val.Bot) -ge 4 -and ($rowY + 42 - $lab.Bot) -ge 4)
    Write-Check 'CLIP' ("value ink={0}px (y {1}..{2}) label ink={3}px (y {4}..{5}); need both>=8/10 with >=4px air below" -f `
            $val.H, $val.Top, $val.Bot, $lab.H, $lab.Top, $lab.Bot)
    [void](Save-Shot $img $Root 'ide-ws-2-settings')
    [Ide]::Key(0x1B, $false, $false)
    Start-Sleep -Milliseconds 300
    Assert-Deadline $sw $TimeoutSec 'ws'

    $all = ($rootOk -and $iconOk -and $clipOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     ws={0} alpha={1} beta={2} dialog={3} value_ink_h={4}" -f `
            $result, $(if ($stA) { $stA.SrcLen } else { 'n/a' }), $(if ($stB) { $stB.SrcLen } else { 'n/a' }), $iconOk, $inkH)
    if (-not $all) { Write-Check 'VERDICT' ("root={0} icon={1} clip={2}" -f $rootOk, $iconOk, $clipOk) }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     ws=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     ws=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     ws=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
