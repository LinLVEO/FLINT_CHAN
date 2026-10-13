# menu-probe.ps1 — 浮窗第 6 步（6c）右键中文菜单回归探针（Agent 维护）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File test\menu-probe.ps1 -Mode dump
#       powershell -NoProfile -ExecutionPolicy Bypass -File test\menu-probe.ps1 -Mode act
# 原理：给浮窗 PostMessage(WM_RBUTTONDOWN) → 菜单是标准 Win32 弹出菜单（窗口类 #32768）
#       → 拿它的菜单句柄 GetMenuItemCount/GetMenuStringA **逐个读出条目**（GBK 解码，
#         这样验的是"系统里真实存在的菜单文本"，而不是我生成器自己的输出）。
#       act 模式再用键盘 Down+Enter 选中第一项（锁定位置），核对 config.json 的 Locked 是否翻转
#       —— 这是"菜单 → 命令号 → 动作 → 落盘"整链的端到端验证。
# 注意：会真的动鼠标/键盘（跑完还原光标位置），被测程序跑完会被结束；真配置先备份后还原。
param(
  [ValidateSet('dump','act','mini')][string]$Mode = 'dump',
  [string]$Exe = "E:\FLINT-lab\apps\m2_float\m2_float.exe",
  [string]$Cfg = "E:\FLINT-lab\apps\m2_float\config.json"
)
$ErrorActionPreference = 'Stop'
$bak = "E:\FLINT-lab\tmp\menu-probe-backup.json"
Copy-Item $Cfg $bak -Force

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class MP {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int l; public int t; public int r; public int b; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr h, int pos);
  [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr h, int item, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern int GetMenuStringA(IntPtr h, int item, byte[] s, int max, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
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

function Read-Menu([IntPtr]$hMenu, [string]$indent, [int]$depth) {
  $gbk = [System.Text.Encoding]::GetEncoding(936)
  $n = [MP]::GetMenuItemCount($hMenu)
  for ($i = 0; $i -lt $n; $i++) {
    $buf = New-Object byte[] 512
    $len = [MP]::GetMenuStringA($hMenu, $i, $buf, 512, 0x400)   # MF_BYPOSITION
    if ($len -le 0) { "$indent[$i] ----(分隔线)----"; continue }
    $txt = $gbk.GetString($buf, 0, $len)
    $st = [MP]::GetMenuState($hMenu, $i, 0x400)                  # MF_BYPOSITION
    $mark = if (($st -band 0x8) -ne 0) { ' [✓勾选]' } else { '' }
    "$indent[$i] $txt$mark"
    $sub = [MP]::GetSubMenu($hMenu, $i)
    if ($sub -ne [IntPtr]::Zero -and $depth -lt 2) { Read-Menu $sub "$indent    " ($depth + 1) }
  }
}

function key([int]$vk) {
  [MP]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [MP]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
}

$cur = New-Object MP+POINT
[void][MP]::GetCursorPos([ref]$cur)
try {
  $p = Start-Process $Exe -PassThru
  Start-Sleep -Milliseconds 2500
  $h = [MP]::FindClass([uint32]$p.Id, "FLINTM2")
  if ($h -eq [IntPtr]::Zero) { throw "没找到窗口（class=FLINTM2）" }
  $r = New-Object MP+RECT
  [void][MP]::GetWindowRect($h, [ref]$r)
  # 右键点在窗口中间
  [void][MP]::SetCursorPos($r.l + 40, $r.t + 20)
  Start-Sleep -Milliseconds 200
  [void][MP]::PostMessage($h, 0x204, [IntPtr]1, [IntPtr]0)     # WM_RBUTTONDOWN
  Start-Sleep -Milliseconds 900                                 # 等 TrackPopupMenu 起来

  $pop = [MP]::FindClass([uint32]$p.Id, "#32768")
  if ($pop -eq [IntPtr]::Zero) { "❌ 没找到弹出菜单窗口（#32768）——菜单没弹出来" }
  else {
    "✅ 弹出菜单窗口已出现（class=#32768）"
    # 弹出菜单的 HMENU 要用 MN_GETHMENU(0x1E1) 问那个 #32768 窗口要（GetMenu 拿不到 —— 实测返回 0）
    $hMenu = [MP]::SendMessage($pop, 0x1E1, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($hMenu -eq [IntPtr]::Zero) { $hMenu = [MP]::GetMenu($pop) }
    if ($hMenu -eq [IntPtr]::Zero) { "❌ 菜单句柄为空" }
    else {
      "---- 菜单结构（系统视角逐个读出，GBK 解码）----"
      Read-Menu $hMenu "  " 0
    }
  }

  if ($Mode -eq 'act') {
    # 走一条**子菜单**命令（比顶级项多一层）：显示项 ▸ 磁盘占用
    # 诊断口径：不预设"哪一项变了"，而是把 config 前后差异全打出来 —— 免得把"选错项"误判成"没生效"
    $beforeTxt = Get-Content -LiteralPath $Cfg -Raw -Encoding UTF8
    "---- act：显示项 ▸ 磁盘占用（子菜单命令路径）----"
    for ($k = 0; $k -lt 6; $k++) { key 0x28 }    # Down×6 → 高亮到 [5] 显示项
    key 0x0D                                     # Enter → 展开子菜单（比 Right 稳）
    Start-Sleep -Milliseconds 250
    for ($k = 0; $k -lt 8; $k++) { key 0x28 }    # Down×8 → 子项 [8] 磁盘占用
    # 注：展开子菜单后 **item0 已处于选中态**，所以到 [n] 要按 n 次（此处 n=8）；实测按 9 次会落到 [9] 网速
    #     —— 那次"选错项"曾被 `ShowDisk 没变` 误判成"子菜单命令没生效"，靠 Compare-Object 全量差异才看清。
    key 0x0D                                     # Enter
    Start-Sleep -Milliseconds 700
    $afterTxt = Get-Content -LiteralPath $Cfg -Raw -Encoding UTF8
    "---- config 实际变化（Compare-Object，只看变动行）----"
    $d = Compare-Object ($beforeTxt -split "`n") ($afterTxt -split "`n")
    if ($d) {
      $d | ForEach-Object { "  {0} {1}" -f $_.SideIndicator, $_.InputObject.Trim() }
      $disk = (Select-String -Path $Cfg -Pattern '"ShowDisk"\s*:\s*(\w+)').Matches[0].Groups[1].Value
      if ($disk -eq 'true') { "✅ 子菜单命令整链生效且**选中的就是磁盘占用**（ShowDisk = true）" }
      else { "❌ 有变化但不是 ShowDisk（变化项见上）→ 选择落点不对" }
    }
    else { "  （没有任何行变化 → 子菜单命令没走到动作）" }
  }
  elseif ($Mode -eq 'mini') {
    # 6d：小窗模式 34×34 —— ① 菜单切进去 ② 单击小方框恢复完整浮窗
    # ⚠️ 先把我们的窗口挪到空位：C# 参考版停在同一坐标且同为 TOPMOST，
    #    实测真鼠标点击会落到 C# 窗口上（WindowFromPoint 证明）——那是测试环境干扰，不是被测行为的锅。
    [void][MP]::MoveWindow($h, 600, 400, 187, 111, $true)
    Start-Sleep -Milliseconds 600
    $r0 = New-Object MP+RECT
    [void][MP]::GetWindowRect($h, [ref]$r0)
    $w0 = $r0.r - $r0.l; $h0 = $r0.b - $r0.t
    "起始尺寸: ${w0}x${h0}（完整浮窗应 > 60 宽；若已是 34 说明 config 停在 MiniMode=true）"
    # ① 右键 → Down×7 → 高亮 [7] 最小化模式（键盘导航会跳过 [6] 分隔线）→ Enter
    [void][MP]::SetCursorPos($r0.l + 40, $r0.t + 20)
    Start-Sleep -Milliseconds 200
    [void][MP]::PostMessage($h, 0x204, [IntPtr]1, [IntPtr]0)
    Start-Sleep -Milliseconds 900
    for ($k = 0; $k -lt 7; $k++) { key 0x28 }
    key 0x0D
    Start-Sleep -Milliseconds 1000
    $r1 = New-Object MP+RECT
    [void][MP]::GetWindowRect($h, [ref]$r1)
    $w1 = $r1.r - $r1.l; $h1 = $r1.b - $r1.t
    $m1 = (Select-String -Path $Cfg -Pattern '"MiniMode"\s*:\s*(\w+)').Matches[0].Groups[1].Value
    "菜单切换后: ${w1}x${h1}   config MiniMode = $m1"
    if ($w1 -eq 34 -and $h1 -eq 34 -and $m1 -eq 'true') { "✅ 小窗模式生效（34×34 ＋ config 落盘）" }
    else {
      "❌ 小窗模式没生效（可能选错项/被最小尺寸钳制）"
      $dlg = [MP]::FindClass([uint32]$p.Id, "#32770")     # 选错到「使用说明」会弹 MessageBox → 兜底关掉，别把探针卡死
      if ($dlg -ne [IntPtr]::Zero) { key 0x0D; "（检测到 MessageBox，已按 Enter 关掉）" }
    }
    # ② 单击小方框（按下+抬起、不移动）→ 恢复完整浮窗（C# :1055-1064）
    [void][MP]::SetCursorPos($r1.l + 17, $r1.t + 17)
    Start-Sleep -Milliseconds 250
    # 先看光标下到底是哪个窗口：C# 参考版也停在同一坐标且同样 TOPMOST，真鼠标点击可能打到它身上
    $ptc = New-Object MP+POINT
    [void][MP]::GetCursorPos([ref]$ptc)
    $under = [MP]::WindowFromPoint($ptc)
    $clsName = New-Object System.Text.StringBuilder 64
    [void][MP]::GetClassName($under, $clsName, 64)
    "光标下窗口 = 0x{0:X}（类 {1}）／我们的窗口 = 0x{2:X}" -f [int64]$under, $clsName.ToString(), [int64]$h
    [MP]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    [MP]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 1000
    $r2 = New-Object MP+RECT
    [void][MP]::GetWindowRect($h, [ref]$r2)
    $w2 = $r2.r - $r2.l; $h2 = $r2.b - $r2.t
    $m2 = (Select-String -Path $Cfg -Pattern '"MiniMode"\s*:\s*(\w+)').Matches[0].Groups[1].Value
    "单击小方框后: ${w2}x${h2}   config MiniMode = $m2"
    if ($w2 -gt 60 -and $m2 -eq 'false') { "✅ 单击小方框恢复完整浮窗" } else { "❌ 单击没能恢复（尺寸/配置没变回去）" }
  }
  else {
    [MP]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)   # VK_ESCAPE 关掉菜单
    Start-Sleep -Milliseconds 100
    [MP]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 300
  if (-not $p.HasExited) { [void][MP]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero); $p.WaitForExit(5000) | Out-Null }
  if (-not $p.HasExited) { $p.Kill() }
}
finally {
  [void][MP]::SetCursorPos($cur.x, $cur.y)
  Copy-Item $bak $Cfg -Force
  "（已还原原 config.json 与光标位置）"
}
