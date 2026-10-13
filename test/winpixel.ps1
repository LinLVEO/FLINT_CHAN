# winpixel.ps1 -- capture a window's CLIENT AREA pixels into a diffable text snapshot.
#
# Why this exists (FLGUI M3 dogfood, 2026-09-22): the existing M3 criterion (rows-dump.txt) is text the
# program writes itself and never goes through the renderer, so "is it still the same on screen after
# swapping the draw layer?" had NO criterion.  This tool produces one.
#
# Two capture paths, and the choice matters:
#   -PrintWindow (default): asks the window to render itself (WM_PRINT).  Deterministic for
#     layered/ULW (UpdateLayeredWindow) windows and independent of what other windows sit on top.
#     Measured 2026-09-22: screen-grab mode (CopyFromScreen) differs by 5~15% between two runs of the
#     SAME product because the desktop shows through the composited layered window; PrintWindow mode
#     is the one to use as a baseline.
#   -ScreenGrab: CopyFromScreen of the window rect (kept for "what the user actually sees" checks).
#
# Usage:
#   powershell -File winpixel.ps1 -Exe <path> [-Arg <args>] [-WaitSec 6] [-Out <file>] [-ScreenGrab]
# Snapshot format: first line "W=<w> H=<h>", then one line per pixel "y x R G B".
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [string]$Arg = "",
  [int]$WaitSec = 6,
  [string]$Out = "",
  [switch]$ScreenGrab
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Exe)) { Write-Output "missing exe: $Exe"; exit 2 }
if (-not $Out) { $Out = Join-Path (Split-Path -Parent $Exe) 'winpixel.txt' }

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32c {
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
}
"@

if ($Arg) { $p = Start-Process -FilePath $Exe -ArgumentList $Arg -PassThru }
else { $p = Start-Process -FilePath $Exe -PassThru }
Start-Sleep -Seconds $WaitSec

$found = [IntPtr]::Zero
$h = [W32c]::GetTopWindow([IntPtr]::Zero)
for ($i = 0; $i -lt 500 -and $h -ne [IntPtr]::Zero; $i++) {
  $pid2 = 0
  [void][W32c]::GetWindowThreadProcessId($h, [ref]$pid2)
  if ($pid2 -eq $p.Id -and [W32c]::IsWindowVisible($h)) {
    $cr = New-Object W32c+RECT
    [void][W32c]::GetClientRect($h, [ref]$cr)
    if (($cr.r - $cr.l) -gt 8 -and ($cr.b - $cr.t) -gt 8) { $found = $h; break }
  }
  $h = [W32c]::GetWindow($h, 2)   # GW_HWNDNEXT
}
if ($found -eq [IntPtr]::Zero) {
  Write-Output "no visible window for pid $($p.Id)"
  if (-not $p.HasExited) { $p.Kill() }
  exit 3
}
$wr = New-Object W32c+RECT
[void][W32c]::GetWindowRect($found, [ref]$wr)
$cr2 = New-Object W32c+RECT
[void][W32c]::GetClientRect($found, [ref]$cr2)
$w = $cr2.r - $cr2.l; $ht = $cr2.b - $cr2.t
$mode = 'printwindow'
if ($ScreenGrab) { $mode = 'screen' }
Write-Output ("window pid={0} hwnd={1} windowRect={2},{3} {4}x{5} client={6}x{7} mode={8}" -f $p.Id, $found, $wr.l, $wr.t, ($wr.r - $wr.l), ($wr.b - $wr.t), $w, $ht, $mode)

$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
if ($ScreenGrab) {
  $g.CopyFromScreen($wr.l, $wr.t, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
} else {
  $hdc = $g.GetHdc()
  # PW_CLIENTONLY (1) | PW_RENDERFULLCONTENT (2) -- the latter is what makes composited content paint
  [void][W32c]::PrintWindow($found, $hdc, 3)
  $g.ReleaseHdc($hdc)
}
$g.Dispose()

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("W=$w H=$ht")
for ($y = 0; $y -lt $ht; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    $c = $bmp.GetPixel($x, $y)
    [void]$sb.AppendLine("$y $x $($c.R) $($c.G) $($c.B)")
  }
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Output ("snapshot -> $Out (" + (Get-Item $Out).Length + " bytes)")
if (-not $p.HasExited) { $p.Kill() }
Write-Output ("killed pid " + $p.Id)
