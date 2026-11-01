# probe-ide-menu.ps1 - top menu bar + new file + built-in terminal + external CMD.
#
# Sandbox: tmp\ide-menu (the app's WORKING DIRECTORY).
#   1. MENUBAR click 文件 -> the dropdown paints (menu item labels + #252526 panel)
#   2. NEW     Ctrl+N empties the buffer (ai.state srclen=0, nlines=1)
#   3. SAVEAS  Ctrl+S on an untitled buffer must open the shell Save dialog (#32770),
#              which the probe closes (a file written to "untitled.fl" would be the old bug)
#   4. TERM    Ctrl+` opens the built-in terminal; typing `echo hi` + Enter appends output
#              (`hi` visible as ink) and leaves the editor buffer untouched
#   5. CMD     menu 运行 -> 外部 CMD 窗口 spawns a real console window (class ConsoleWindowClass)
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP. ASCII only.
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$code = 1
$result = 'FAIL'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-menu'
$MainDir = Join-Path $Sand 'apps\studio_native'
$MainFile = Join-Path $MainDir 'main.fl'

function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds 90
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 350
}

function Find-Window([int]$TargetPid, [string]$Cls, [int]$TimeoutMs = 4000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinFind {
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
        $h = [WinFind]::Find($TargetPid, $Cls)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $MainDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($MainFile, "int main() { return 0; }`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'untitled.fl') -ErrorAction SilentlyContinue

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear' }
        throw "PROBE_SKIP:$why"
    }
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    $img0 = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st0) { throw 'ai.state has no ST line' }
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:focus stolen' }
    Write-Check 'STATE0' $st0.Raw

    # ---- 1. menu bar dropdown ----
    $bandInk = (Get-InkStats $img0 8 34 200 60 70).Count
    Click-Client $app.Hwnd 24 47                       # 文件
    $img1 = [Ide]::Grab($app.Hwnd)
    # dropdown panel colour #252526 must cover a decent block under the band
    $dropPx = $img1.CountNear(10, 62, 260, 62 + 6 * 24 + 6, 0x252526, 4)
    $menuOk = ($dropPx -gt 3000)
    Write-Check 'MENUBAR' ("band_ink={0} dropdown_px={1} (need>3000)" -f $bandInk, $dropPx)
    [void](Save-Shot $img1 $Root 'ide-menu-1-open')
    Click-Client $app.Hwnd 600 400                     # click elsewhere closes it
    Start-Sleep -Milliseconds 250

    # ---- 1b. F5 = 运行：编译当前缓冲并开一个 cmd 窗口跑产物（此时打开的是启动文件 main.fl）
    $cmdRun0 = @(Get-Process cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    [Ide]::Key(0x74, $false, $false)          # F5
    Start-Sleep -Milliseconds 4000
    $cmdRun1 = @(Get-Process cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $newRun = @($cmdRun1 | Where-Object { $cmdRun0 -notcontains $_ })
    $runOk = ($newRun.Count -ge 1)
    Write-Check 'RUN' ("F5 -> new cmd pids=[{0}] (need >=1)" -f ($newRun -join ','))
    foreach ($rp in $newRun) { Stop-Process -Id $rp -Force -ErrorAction SilentlyContinue }
    [void](Save-Shot ([Ide]::Grab($app.Hwnd)) $Root 'ide-menu-3-run')
    Start-Sleep -Milliseconds 400
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:focus lost after F5' }

    # ---- 2. Ctrl+N ----
    [Ide]::Key(0x4E, $true, $false)
    Start-Sleep -Milliseconds 600
    $st1 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq 0 } 3000
    $newOk = ($null -ne $st1 -and $st1.LineCount -eq 1)
    Write-Check 'NEW' ("srclen={0} nlines={1} (need 0 / 1)" -f $(if ($st1) { $st1.SrcLen } else { 'n/a' }), $(if ($st1) { $st1.LineCount } else { 'n/a' }))

    # ---- 3. Ctrl+S on untitled -> Save As dialog ----
    [Ide]::Key(0x53, $true, $false)
    $dlg = Find-Window $app.Proc.Id '#32770' 4000
    $saveOk = ($dlg -ne [IntPtr]::Zero)
    Write-Check 'SAVEAS' ("save dialog hwnd={0} (need non-zero)" -f $dlg)
    if ($dlg -ne [IntPtr]::Zero) {
        [void][Ide]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 600
    }
    $untitledWritten = Test-Path (Join-Path $Sand 'untitled.fl')
    if ($untitledWritten) { Write-Check 'WARN' 'untitled.fl was written (old behaviour)' }

    # ---- 4. built-in terminal ----
    [Ide]::Key(0xC0, $true, $false)
    Start-Sleep -Milliseconds 600
    $img2 = [Ide]::Grab($app.Hwnd)
    $termPx = $img2.CountNear(220, ($H - 26 - 200), $W, ($H - 26), 0x181818, 6)
    $termOk = ($termPx -gt 20000)
    Write-Check 'TERMPANEL' ("terminal_bg_px={0} (need>20000)" -f $termPx)
    foreach ($ch in 'echo hi'.ToCharArray()) {
        $vk = [int][char]([string]$ch).ToUpperInvariant()
        if ($ch -eq ' ') { $vk = 0x20 }
        [Ide]::KeyDownSc($app.Hwnd, $vk, [Ide]::Scan($vk))
        Start-Sleep -Milliseconds 90
    }
    [Ide]::Key(0x0D, $false, $false)
    Start-Sleep -Milliseconds 1500
    $img3 = [Ide]::Grab($app.Hwnd)
    $ink0 = (Get-InkStats $img2 232 ($H - 26 - 200) ($W - 20) ($H - 26 - 24) 70).Count
    $ink1 = (Get-InkStats $img3 232 ($H - 26 - 200) ($W - 20) ($H - 26 - 24) 70).Count
    $st4 = Read-StudioState $Sand
    $termInkOk = ($ink1 -gt $ink0 + 40)
    $noEdit = ($null -ne $st4 -and $st4.SrcLen -eq 0)
    Write-Check 'TERMRUN' ("terminal_ink {0} -> {1} (need +40); editor srclen={2} (need 0)" -f $ink0, $ink1, $(if ($st4) { $st4.SrcLen } else { 'n/a' }))
    [void](Save-Shot $img3 $Root 'ide-menu-2-term')

    # ---- 5. external CMD from 运行 menu ----
    $cmdBefore = @(Get-Process cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Click-Client $app.Hwnd 120 47                      # 运行 (third title: x = 10 + 2*44 .. = 98..142 at ui=16)
    Start-Sleep -Milliseconds 250
    Click-Client $app.Hwnd 150 (34 + 26 + 3 + 4 * 24 + 12)   # 5th item = 外部 CMD 窗口（工作区）
    Start-Sleep -Milliseconds 1500
    $cmdAfter = @(Get-Process cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $newCmd = @($cmdAfter | Where-Object { $cmdBefore -notcontains $_ })
    $cmdOk = ($newCmd.Count -ge 1)
    Write-Check 'EXTCMD' ("new cmd pids=[{0}] (need >=1)" -f ($newCmd -join ','))
    foreach ($p2 in $newCmd) { Stop-Process -Id $p2 -Force -ErrorAction SilentlyContinue }
    Assert-Deadline $sw $TimeoutSec 'menu'

    $all = ($menuOk -and $newOk -and $saveOk -and $termOk -and $termInkOk -and $noEdit -and $runOk -and $cmdOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     menu={0} drop_px={1} new={2} saveas={3} term_px={4} term_ink={5}->{6} srclen={7} f5run={8} extcmd={9}" -f `
            $result, $dropPx, $newOk, $saveOk, $termPx, $ink0, $ink1, $(if ($st4) { $st4.SrcLen } else { 'n/a' }), $runOk, $cmdOk)
    if (-not $all) { Write-Check 'VERDICT' ("menu={0} new={1} saveas={2} term={3} termink={4} noedit={5} f5={6} cmd={7}" -f `
            $menuOk, $newOk, $saveOk, $termOk, $termInkOk, $noEdit, $runOk, $cmdOk) }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      " + $_.Exception.Message.Substring(11))
        Write-Host "RESULT     menu=SKIP"
        $code = 2
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     menu=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
