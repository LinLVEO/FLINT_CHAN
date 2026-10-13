# cfg-probe.ps1 — 浮窗第 6 步（6a）config.json 读写回归探针（Agent 维护）
# 用法：
#   powershell -ExecutionPolicy Bypass -File test\cfg-probe.ps1 -Mode dump
#   powershell -ExecutionPolicy Bypass -File test\cfg-probe.ps1 -Mode window -X 300 -Y 220
# 两种模式都会**先备份真配置、跑完还原**（用户数据铁律：改数据先备份，测完还原）。
#
# Mode dump  ：改 config（ShowDisk/ShowFan/OpacityPercent/FontSize/CpuTempOffset）→ 开 dump.on 跑一次
#              → 读 rows-dump.txt 里的 `cfg …` / `sw=` / `rows=` 几行，核对「配置 → 位掩码/合成常量/行数」链路。
# Mode window：写 config 的 X/Y → 正常起窗口 → GetWindowRect 核对落点 → 发 WM_CLOSE 正常退出
#              → 核对 config.json 里 X/Y 是否被回写（C# 同款：退出即存）。
param(
  [ValidateSet('dump','window','locked')][string]$Mode = 'dump',
  [int]$X = 300,
  [int]$Y = 220,
  [string]$Exe = "E:\FLINT-lab\apps\m2_float\m2_float.exe",
  [string]$Cfg = "E:\FLINT-lab\apps\m2_float\config.json"
)
$ErrorActionPreference = 'Stop'
$root = "E:\FLINT-lab"
$probe = Join-Path $root "tmp\row-probe"
# 2026-09-16：自检开关挪进 selfcheck\ 子目录（与运行开关 http.on/stitch.on 物理分开）→ 探针路径同步
$selfcheck = Join-Path $probe "selfcheck"
$dumpOn = Join-Path $selfcheck "dump.on"
$dumpOut = Join-Path $probe "rows-dump.txt"
$bak = Join-Path $root "tmp\cfg-probe-backup.json"

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CP {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l; public int t; public int r; public int b; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
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

function Set-Cfg([hashtable]$kv) {
  $t = Get-Content $Cfg -Raw -Encoding UTF8
  foreach ($k in $kv.Keys) {
    $v = $kv[$k]
    $t = [regex]::Replace($t, ('"{0}"\s*:\s*[^,\r\n]+' -f [regex]::Escape($k)), ('"{0}": {1}' -f $k, $v))
  }
  [System.IO.File]::WriteAllText($Cfg, $t, (New-Object System.Text.UTF8Encoding($false)))
}

Copy-Item $Cfg $bak -Force
try {
  if ($Mode -eq 'dump') {
    Set-Cfg @{ ShowDisk = 'true'; ShowFan = 'false'; OpacityPercent = '80'; FontSize = '13'; CpuTempOffset = '-20' }
    "写测试配置: ShowDisk=true ShowFan=false OpacityPercent=80 FontSize=13 CpuTempOffset=-20"
    New-Item -ItemType Directory -Force -Path $selfcheck | Out-Null
    New-Item $dumpOn -ItemType File -Force | Out-Null
    if (Test-Path $dumpOut) { Remove-Item $dumpOut -Force }
    $p = Start-Process $Exe -PassThru
    $p.WaitForExit(20000) | Out-Null
    if (Test-Path $dumpOut) {
      "---- rows-dump.txt（cfg / sw / rows 相关行）----"
      Select-String -Path $dumpOut -Pattern '^(rows=|sw=|cfg |L\d)' | ForEach-Object { "  " + $_.Line }
    } else { "❌ 没生成 rows-dump.txt" }
  }
  elseif ($Mode -eq 'window') {
    Set-Cfg @{ X = "$X"; Y = "$Y" }
    "写测试配置: X=$X Y=$Y"
    $p = Start-Process $Exe -PassThru
    Start-Sleep -Milliseconds 2500
    $h = [CP]::FindClass([uint32]$p.Id, "FLINTM2")
    if ($h -eq [IntPtr]::Zero) { "❌ 没找到窗口（class=FLINTM2, pid=$($p.Id)）" }
    else {
      $r = New-Object CP+RECT
      [void][CP]::GetWindowRect($h, [ref]$r)
      "窗口落点: ($($r.l),$($r.t))  尺寸 $($r.r - $r.l)x$($r.b - $r.t)   期望落点 ($X,$Y)"
      if ($r.l -eq $X -and $r.t -eq $Y) { "✅ 位置恢复一致" } else { "❌ 位置不一致" }
      [void][CP]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE → 触发退出存位置
      $p.WaitForExit(8000) | Out-Null
      if (-not $p.HasExited) { $p.Kill(); "（进程未自行退出，已强制结束）" }
      Start-Sleep -Milliseconds 300
      $after = Get-Content $Cfg -Raw -Encoding UTF8
      $mx = [regex]::Match($after, '"X"\s*:\s*(-?\d+)').Groups[1].Value
      $my = [regex]::Match($after, '"Y"\s*:\s*(-?\d+)').Groups[1].Value
      "退出后 config 里的 X/Y = $mx / $my（应等于窗口实际落点）"
      if ([int]$mx -eq $r.l -and [int]$my -eq $r.t) { "✅ 退出存位置生效" } else { "❌ 退出存位置没对上" }
      "---- 退出后 config.json 全文（核对键名/顺序与 C# 一致）----"
      (Get-Content $Cfg -Encoding UTF8) | ForEach-Object { "  $_" }
    }
  }
  else {
    # 6b：锁定 → 拖动无效；未锁定 → 拖动有效。
    # ⚠️ 对照组必须跑：否则"没动"可能只是探针没生效（判据要能区分两种情形）。
    $LEFTDOWN = 0x0002; $LEFTUP = 0x0004
    $orig = New-Object CP+POINT
    [void][CP]::GetCursorPos([ref]$orig)
    foreach ($locked in @('true','false')) {
      Set-Cfg @{ Locked = $locked; X = '300'; Y = '220' }
      "`n=== Locked=$locked ==="
      $p = Start-Process $Exe -PassThru
      Start-Sleep -Milliseconds 3000          # 等第一轮置顶钉回（≥2s）跑过
      $h = [CP]::FindClass([uint32]$p.Id, "FLINTM2")
      if ($h -eq [IntPtr]::Zero) { "❌ 没找到窗口（class=FLINTM2, pid=$($p.Id)）"; continue }
      $ex = [CP]::GetWindowLong($h, -20)
      $topmost = if (($ex -band 0x8) -ne 0) { '是' } else { '否' }
      $r0 = New-Object CP+RECT
      [void][CP]::GetWindowRect($h, [ref]$r0)
      # 模拟拖动：光标按到窗口内 → 按住 → 分步移动 → 松开
      [void][CP]::SetCursorPos($r0.l + 20, $r0.t + 10)
      Start-Sleep -Milliseconds 150
      [CP]::mouse_event($LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
      for ($i = 1; $i -le 6; $i++) {
        [void][CP]::SetCursorPos($r0.l + 20 + $i * 10, $r0.t + 10 + $i * 7)
        Start-Sleep -Milliseconds 60
      }
      [CP]::mouse_event($LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 400
      $r1 = New-Object CP+RECT
      [void][CP]::GetWindowRect($h, [ref]$r1)
      $moved = ($r1.l -ne $r0.l) -or ($r1.t -ne $r0.t)
      "置顶钉回：WS_EX_TOPMOST 置位 = $topmost（C# 同款：每 ≥2s 钉一次）"
      "拖动检查：$($r0.l),$($r0.t) → $($r1.l),$($r1.t)  位移 = $($r1.l - $r0.l),$($r1.t - $r0.t)"
      if ($locked -eq 'true') {
        if ($moved) { "❌ Locked=true 时窗口仍被拖走了" } else { "✅ Locked=true 拖动无效（符合 C# :1021）" }
      } else {
        if ($moved) { "✅ Locked=false 拖动有效（对照组成立）" } else { "❌ 对照组：未锁定也拖不动 → 探针没生效" }
      }
      [void][CP]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
      $p.WaitForExit(8000) | Out-Null
      if (-not $p.HasExited) { $p.Kill() }
      Start-Sleep -Milliseconds 300
    }
    [void][CP]::SetCursorPos($orig.x, $orig.y)
  }
}
finally {
  Remove-Item $dumpOn -Force -ErrorAction SilentlyContinue
  Copy-Item $bak $Cfg -Force
  "`n（已还原原 config.json，并删掉 dump.on 开关）"
}
