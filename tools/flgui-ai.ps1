# flgui-ai.ps1 -- FLGUI AI observability kit (ASCII only, no BOM needed).
#
# Why: an agent cannot see the screen. This script is the "eyes" part of the toolkit; the
# in-app part lives in lib\flgui_ai.fl (ai.ev / ai.state / ai.fb).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\flgui-ai.ps1 -Shot  -Process chip8_win
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\flgui-ai.ps1 -Log   -Dir apps\chip8 -Tail 20
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\flgui-ai.ps1 -Clean -Dir apps\chip8
#
# -Shot captures the *visible window rect* from the screen (works for layered/ULW windows, where
# a DIB dump does not: measured 2026-10-25 -- the app draws through the render pipeline and the
# in-memory surface comes back all-zero). Output: <dir>\shot.png (or -Out).

param(
    [switch]$Shot,
    [switch]$Log,
    [switch]$Clean,
    [string]$Process = 'chip8_win',
    [string]$Dir = 'apps\chip8',
    [string]$Out = '',
    [int]$Tail = 15
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dirPath = if ([IO.Path]::IsPathRooted($Dir)) { $Dir } else { Join-Path $repo $Dir }

function Get-WinRect([IntPtr]$h) {
    Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public struct RECT{public int L,T,R,B;}public class WA{[DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}'
    $r = New-Object RECT
    [void][WA]::GetWindowRect($h, [ref]$r)
    return $r
}

if ($Shot) {
    $p = Get-Process $Process -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { Write-Output "no process '$Process'"; exit 1 }
    $h = [IntPtr]$p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { Write-Output "process '$Process' has no main window"; exit 1 }
    $r = Get-WinRect $h
    $w = $r.R - $r.L
    $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { Write-Output "bad window rect"; exit 1 }
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
    $g.Dispose()
    $outPath = if ($Out -ne '') { $Out } else { Join-Path $dirPath 'shot.png' }
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("shot: " + $outPath + " (" + $w + "x" + $ht + ", " + (Get-Item $outPath).Length + " bytes)")
    exit 0
}

if ($Log) {
    foreach ($name in 'ai.state', 'ai.ev') {
        $f = Join-Path $dirPath $name
        if (Test-Path $f) {
            Write-Output ("== " + $name + " (last " + $Tail + ") ==")
            Get-Content $f -Tail $Tail
        } else {
            Write-Output ("== " + $name + " (absent) ==")
        }
    }
    $fb = Join-Path $dirPath 'ai.fb'
    if (Test-Path $fb) {
        Write-Output '== ai.fb (last frame) =='
        $lines = Get-Content $fb
        $start = 0
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq 'FB') { $start = $i } }
        $lines[$start..([Math]::Min($start + 34, $lines.Count - 1))]
    }
    exit 0
}

if ($Clean) {
    foreach ($name in 'ai.state', 'ai.ev', 'ai.fb', 'ai.bmp', 'shot.png', 'ai.png') {
        $f = Join-Path $dirPath $name
        if (Test-Path $f) { Remove-Item $f -Force; Write-Output ("removed " + $name) }
    }
    exit 0
}

Write-Output 'flgui-ai: give one of -Shot / -Log / -Clean'
exit 2
