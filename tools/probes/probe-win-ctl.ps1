# probe-win-ctl.ps1 - end-to-end check of studio_win window controls (drag / minimize / close)
# ASCII only on purpose (avoid BOM / codepage traps).
$ErrorActionPreference = 'Stop'

Add-Type -Namespace W -Name Api -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
[StructLayout(LayoutKind.Sequential)] public struct P { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct MI { public int dx; public int dy; public uint data; public uint flags; public uint time; public System.IntPtr extra; }
[StructLayout(LayoutKind.Sequential)] public struct IN { public uint type; public MI mi; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref P p);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern uint SendInput(uint n, IN[] a, int sz);
public static void Btn(uint fl) {
  IN[] a = new IN[1];
  a[0].type = 0;
  a[0].mi.flags = fl;
  SendInput(1, a, Marshal.SizeOf(typeof(IN)));
}
'@

function Get-Rect([IntPtr]$h) {
    $r = New-Object W.Api+RECT
    [void][W.Api]::GetWindowRect($h, [ref]$r)
    return @{ L = $r.L; T = $r.T; R = $r.R; B = $r.B; W = ($r.R - $r.L); H = ($r.B - $r.T) }
}
function Move-To([IntPtr]$h, [int]$cx, [int]$cy) {
    $p = New-Object W.Api+P
    $p.X = $cx; $p.Y = $cy
    [void][W.Api]::ClientToScreen($h, [ref]$p)
    [void][W.Api]::SetCursorPos($p.X, $p.Y)
    Start-Sleep -Milliseconds 30
}
function Client-Screen([IntPtr]$h, [int]$cx, [int]$cy) {
    $p = New-Object W.Api+P
    $p.X = $cx; $p.Y = $cy
    [void][W.Api]::ClientToScreen($h, [ref]$p)
    return @{ X = $p.X; Y = $p.Y }
}
$DOWN = 0x0002; $UP = 0x0004

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinFind {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static IntPtr ByClass(int target, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)target && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(256);
                GetClassName(h, c, 256);
                if (c.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@ -Language CSharp

# ---- 1) start（隐藏它自带的控制台窗：否则它会盖在编辑器上面，点击全落到控制台） ----
# NOTE (2026-10-27): the app now persists session state in studio.cfg on a NORMAL close (this
# probe clicks [X]). Running from the repo root would leave a stray E:\FLINT-lab\studio.cfg,
# so remember whether it existed and delete it in that case (probes must not dirty the tree).
$repoRoot = Split-Path (Split-Path $PSScriptRoot)
$hadRootCfg = Test-Path (Join-Path $repoRoot 'studio.cfg')
$exe = Join-Path $repoRoot 'apps\studio_native\studio_win.exe'
$p = Start-Process -FilePath $exe -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 100
    $p.Refresh()
    if ($p.HasExited) { break }
    $hwnd = [WinFind]::ByClass($p.Id, 'FLINTSTUDIO')
    if ($hwnd -ne [IntPtr]::Zero) { break }
}
if ($hwnd -eq [IntPtr]::Zero) { throw "window did not appear" }
Start-Sleep -Milliseconds 800
[void][W.Api]::SetForegroundWindow($hwnd)
$r0 = Get-Rect $hwnd
"WINDOW  pid=$($p.Id)  hwnd=$hwnd  rect=$($r0.L),$($r0.T) $($r0.W)x$($r0.H)"

# ---- 2) drag from title bar (500,12) by (+120,+80) ----
$sp = Client-Screen $hwnd 500 12
[void][W.Api]::SetCursorPos($sp.X, $sp.Y)
Start-Sleep -Milliseconds 60
[W.Api]::Btn($DOWN)
Start-Sleep -Milliseconds 60
for ($s = 1; $s -le 8; $s++) {
    [void][W.Api]::SetCursorPos(($sp.X + 15 * $s), ($sp.Y + 10 * $s))
    Start-Sleep -Milliseconds 30
}
Start-Sleep -Milliseconds 80
[W.Api]::Btn($UP)
Start-Sleep -Milliseconds 250
$r1 = Get-Rect $hwnd
$dx = $r1.L - $r0.L; $dy = $r1.T - $r0.T
"DRAG    from=$($r0.L),$($r0.T) to=$($r1.L),$($r1.T)  delta=$dx,$dy  size=$($r1.W)x$($r1.H)"
$dragOk = ([Math]::Abs($dx - 120) -le 12) -and ([Math]::Abs($dy - 80) -le 12) -and ($r1.W -eq $r0.W) -and ($r1.H -eq $r0.H)
"DRAG    OK=$dragOk"

# ---- 3) minimize via [ - ] button (client 934..960 x 4..30) ----
Move-To $hwnd 947 17
[W.Api]::Btn($DOWN); Start-Sleep -Milliseconds 70; [W.Api]::Btn($UP)
Start-Sleep -Milliseconds 600
$mini = [W.Api]::IsIconic($hwnd)
"MINI    IsIconic=$mini"

# ---- 4) restore, window must come back at the dragged rect (not off-screen) ----
[void][W.Api]::ShowWindow($hwnd, 9)
Start-Sleep -Milliseconds 700
[void][W.Api]::SetForegroundWindow($hwnd)
$r2 = Get-Rect $hwnd
$restoreOk = ([Math]::Abs($r2.L - $r1.L) -le 6) -and ([Math]::Abs($r2.T - $r1.T) -le 6) -and ($r2.L -gt -100) -and ($r2.T -gt -100)
"RESTORE rect=$($r2.L),$($r2.T) $($r2.W)x$($r2.H)  OK=$restoreOk"

# ---- 5) close via [ X ] button (client 966..992 x 4..30) ----
Move-To $hwnd 979 17
[W.Api]::Btn($DOWN); Start-Sleep -Milliseconds 70; [W.Api]::Btn($UP)
$gone = $false
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 100; $p.Refresh(); if ($p.HasExited) { $gone = $true; break } }
"CLOSE   exited=$gone"
$srv = @(Get-Process -Name studio_server -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
"CLOSE   left_over_server_pids=$(($srv -join ','))"

if ($p.HasExited -eq $false) { Stop-Process -Id $p.Id -Force }
if (-not $hadRootCfg) { Remove-Item (Join-Path $repoRoot 'studio.cfg') -ErrorAction SilentlyContinue }
$all = $dragOk -and ($mini -eq $true) -and ($restoreOk -eq $true) -and $gone -and ($srv.Count -eq 0)
"RESULT  drag=$dragOk mini=$mini restore=$restoreOk close=$gone server_leak=$($srv.Count) => ALL=$all"
if ($all) { exit 0 } else { exit 1 }
