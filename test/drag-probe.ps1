# drag-probe.ps1 — 无边框浮窗「拖动粘手」回归探针（Agent 维护）
# 用法：powershell -ExecutionPolicy Bypass -File test\drag-probe.ps1 [-Exe <exe 路径>]
#       默认测 apps\m2_float\m2_float.exe
# 原理：模拟鼠标 按下/移动/抬起，用 GetWindowRect 判断松手后窗口是否还跟着光标走。
#       场景 C 是「粘手」bug 的复现点：快拖时光标冲出窗口、窗口没跟上就松手
#       → 旧实现丢掉 WM_LBUTTONUP → drag.on 清不掉 → 窗口一直跟着光标。
# 修复（apps\m2_float\flint_ui.fl v1.0.9）：拖动期 SetCapture / 抬起 ReleaseCapture。
# 注意：本脚本会真的移动鼠标光标，跑完会恢复原位置；被测程序跑完会被结束。
param([string]$Exe = "")
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DP {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l; public int t; public int r; public int b; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  public static IntPtr FindClass(uint pid, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp == pid) {
        var cn = new StringBuilder(64); GetClassName(h, cn, 64);
        if (cn.ToString() == cls) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
$LEFTDOWN = 0x0002; $LEFTUP = 0x0004
if (-not $Exe) { $Exe = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\m2_float\m2_float.exe' }
if (-not (Test-Path $Exe)) { Write-Output "找不到 $Exe"; exit 1 }
Write-Output ("被测程序: " + $Exe)

$p = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 2
$hwnd = [DP]::FindClass([uint32]$p.Id, "FLINTM2")
if ($hwnd -eq [IntPtr]::Zero) { Write-Output "没找到 FLINTM2 窗口（建窗失败？）"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; exit 1 }
$orig = New-Object DP+POINT; [DP]::GetCursorPos([ref]$orig) | Out-Null
function Get-Rect([IntPtr]$hw) { $x = New-Object DP+RECT; [DP]::GetWindowRect($hw, [ref]$x) | Out-Null; return "$($x.l),$($x.t)" }
function Center([IntPtr]$hw) { $x = New-Object DP+RECT; [DP]::GetWindowRect($hw, [ref]$x) | Out-Null; return @([int](($x.l + $x.r) / 2), [int](($x.t + $x.b) / 2)) }
$fail = 0

# 场景 A：按下 → 原地抬起 → 移动光标（不该跟）
$c = Center $hwnd; [DP]::SetCursorPos($c[0], $c[1]) | Out-Null; Start-Sleep -Milliseconds 250
[DP]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero) | Out-Null; Start-Sleep -Milliseconds 250
[DP]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero) | Out-Null; Start-Sleep -Milliseconds 400
$a0 = Get-Rect $hwnd; [DP]::SetCursorPos($c[0]+30, $c[1]+20) | Out-Null; Start-Sleep -Milliseconds 500
$a1 = Get-Rect $hwnd
if ($a0 -eq $a1) { Write-Output "场景A 原地点击后移光标: OK（$a0 未动）" } else { Write-Output "场景A: 粘手！$a0 -> $a1"; $fail++ }

# 场景 B：正常拖动（分段移动，窗口跟得上）→ 抬起 → 移动光标
$c = Center $hwnd; [DP]::SetCursorPos($c[0], $c[1]) | Out-Null; Start-Sleep -Milliseconds 250
[DP]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero) | Out-Null; Start-Sleep -Milliseconds 150
foreach ($d in @(@(80,60),@(160,120),@(220,155))) { [DP]::SetCursorPos($c[0]+$d[0], $c[1]+$d[1]) | Out-Null; Start-Sleep -Milliseconds 150 }
[DP]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero) | Out-Null; Start-Sleep -Milliseconds 400
$b0 = Get-Rect $hwnd; [DP]::SetCursorPos($c[0]+300, $c[1]+220) | Out-Null; Start-Sleep -Milliseconds 500
$b1 = Get-Rect $hwnd
$moved = ($b0 -ne $a1)
if ($moved -and $b0 -eq $b1) { Write-Output "场景B 正常拖动后移光标: OK（拖动生效 $a1 -> $b0，抬起后未再跟）" }
elseif (-not $moved) { Write-Output "场景B: 拖动没生效（窗口没动）——回归！"; $fail++ }
else { Write-Output "场景B: 粘手！$b0 -> $b1"; $fail++ }

# 场景 C：快拖（光标冲出窗口）瞬间松手 → 移动光标（原 bug 复现点）
$c = Center $hwnd; [DP]::SetCursorPos($c[0], $c[1]) | Out-Null; Start-Sleep -Milliseconds 250
[DP]::mouse_event($LEFTDOWN,0,0,0,[UIntPtr]::Zero) | Out-Null; Start-Sleep -Milliseconds 120
[DP]::SetCursorPos($c[0]+400, $c[1]+300) | Out-Null
[DP]::mouse_event($LEFTUP,0,0,0,[UIntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 800
$c0 = Get-Rect $hwnd; [DP]::SetCursorPos($c[0]+60, $c[1]+40) | Out-Null; Start-Sleep -Milliseconds 600
$c1 = Get-Rect $hwnd
if ($c0 -eq $c1) { Write-Output "场景C 快拖后瞬间松手: OK（$c0 未再跟）" } else { Write-Output "场景C: 粘手！$c0 -> $c1"; $fail++ }

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
[DP]::SetCursorPos($orig.x, $orig.y) | Out-Null
Write-Output ("----")
if ($fail -eq 0) { Write-Output "拖动探针通过 3 / 失败 0"; exit 0 }
Write-Output "拖动探针失败 $fail 项"; exit 1
