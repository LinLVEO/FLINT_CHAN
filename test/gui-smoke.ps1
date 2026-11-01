# gui-smoke.ps1 -- GUI 冒烟门：一个窗口程序「起得来 / 有窗口 / 画出来 / 退得掉」的五连检。
#
# 为什么有这道门（2026-10-31，paintshop 崩了一整晚之后）：
#   那一天连着 6 个错误方向的 commit，最后才发现是 CreateWindowExA 的 WndProc 参数写成 int
#   截断了 64 位 lParam。根因不是难，而是「这个 exe 起得来吗、窗口出现了吗、画出来了吗」这个
#   问题当时只能靠人手工双击 + 看屏幕回答。这道门把它变成一条命令，并且是按进程/窗口/像素
#   三层独立取证，不读程序自己的任何输出（程序可能根本没输出、或者输出是假的）。
#
# 五项检查（顺序固定，逐项打印 PASS / FAIL / WARN / SKIP）：
#   A 起身   Start-Process -PassThru 起进程，等 -Seconds（默认 3 秒），顺带记录窗口首次出现的时刻。
#            判据：exe 存在且进程对象拿得到。
#   B 存活   等够时间后 HasExited 必须为 false。这是最关键的一条：建窗失败的程序往往「起来 -> 秒退」，
#            以前肉眼看屏幕只看到「没窗口」，其实是进程已经死了。FAIL 时打印真实 ExitCode（含 0x 形式）。
#   C 有窗口 EnumWindows 枚举该 pid 的所有顶层窗口，逐个 GetWindowRect 判尺寸 > 0，
#            要求至少一个「可见」窗口。打印每个窗口的 class / title / rect / iconic 状态。
#            （见文件末尾「已知局限」：不要求有标题栏，也不要求主窗口句柄可用。）
#   D 画出来 对最大的可见窗口截图（-Capture auto 时依次试 PrintWindow / 窗口 DC BitBlt / 屏幕抓取），
#            存 PNG 到 -Shot 路径，并统计像素颜色多样性：至少 -MinColors 个不同颜色值（默认 8）。
#            纯色 = 窗口在但没画东西，这是另一种失败，不能放过。截图存盘无论成败都做，留证。
#   E 干净退出 先 CloseMainWindow()，没退出就发 WM_CLOSE，再等 -ExitWaitSec（默认 2 秒）；
#            仍不退出则 Stop-Process 强杀，报告里标 WARN（默认不算 FAIL）——加 -WarnIsFail 则算 FAIL。
#            为什么默认不红：这是「能画但关不掉的窗口」，属于资源回收缺陷，不等于程序不能用；
#            但它是真缺陷，CI 里想收口就开 -WarnIsFail（实测 build\paintshop.exe 正是这一类）。
#
# 退出码：0 = 全部 PASS（WARN 不影响）；1 = 任一 FAIL；2 = 脚本自身异常（P/Invoke 编译失败等）。
#
# 用法：
#   pwsh -NoProfile -File test\gui-smoke.ps1 -Exe build\paintshop2.exe
#   pwsh -NoProfile -File test\gui-smoke.ps1 -Exe build\paintshop2.exe -Seconds 3 -Shot tmp\smoke.png
#   pwsh -NoProfile -File test\gui-smoke.ps1 -Exe build\paintshop.exe      # 反向验证：旧版应当红
#
# 注意：这道门会真的弹一个窗口，并抢走前台焦点，所以 test\verify-all.ps1 默认的 -Only 列表里
#       故意不含 gui；要单独跑就 -Only gui（见 verify-all.ps1 文件头）。
#
# 编码纪律：本文件有中文，必须 UTF-8 **带 BOM** 保存（PS 5.1 会把无 BOM 的 UTF-8 当 GBK 解码，
# 中文注释被截断后报的语法错会指向无辜的行）。改完请回读首 3 字节确认 EF BB BF。
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [ValidateRange(1, 120)][int]$Seconds = 3,
  [string]$Shot = "",
  [ValidateRange(2, 256)][int]$MinColors = 8,
  [ValidateSet('auto', 'print', 'dc', 'screen')][string]$Capture = 'auto',
  [ValidateRange(1, 60)][int]$ExitWaitSec = 2,
  [string]$WorkDir = "",
  [string]$WindowClass = "",
  [switch]$WarnIsFail
)

$ErrorActionPreference = 'Stop'
# 与 verify-all.ps1 一致：本进程输出 UTF-8，子门/父门互相解码才不会出现「关键字读不到」的假红。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:passN = 0
$script:failN = 0
$script:warnN = 0
$script:skipN = 0
$script:proc = $null
$script:scriptErr = $false

function Check([string]$id, [string]$name, [string]$verdict, [string]$detail) {
  switch ($verdict) {
    'PASS' { $script:passN++ }
    'FAIL' { $script:failN++ }
    'WARN' { $script:warnN++ }
    default { $script:skipN++ }
  }
  Write-Output ("[{0}] {1} {2}: {3}" -f $id, $verdict, $name, $detail)
}
function Note([string]$s) { Write-Output ("     " + $s) }

# ---- P/Invoke（与 test\winpixel.ps1、test\cfg-probe.ps1 同一套做法，换成 C# 辅助方法，
#      避免 PowerShell 对 out/ref struct 参数不写回的老坑）----
Add-Type -AssemblyName System.Drawing
if (-not ('GuiSmoke32' -as [type])) {
  Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class GuiSmoke32 {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  [DllImport("user32.dll", SetLastError = true)] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, int rop);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

  public static IntPtr[] WindowsOf(uint pid) {
    List<IntPtr> list = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list.ToArray();
  }
  public static int[] RectOf(IntPtr h) {
    RECT r; if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
    return new int[] { r.L, r.T, r.R, r.B };
  }
  public static int[] ClientOf(IntPtr h) {
    RECT r; if (!GetClientRect(h, out r)) return new int[] { 0, 0, 0, 0 };
    return new int[] { r.L, r.T, r.R, r.B };
  }
  public static int[] ClientScreenOrigin(IntPtr h) {
    POINT p; p.X = 0; p.Y = 0;
    if (!ClientToScreen(h, ref p)) return new int[] { 0, 0 };
    return new int[] { p.X, p.Y };
  }
  public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
  public static string TitleOf(IntPtr h) { StringBuilder sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
}
'@
}

# ---- 参数规整 ----
$exePath = $Exe
if (-not [System.IO.Path]::IsPathRooted($exePath)) { $exePath = Join-Path (Get-Location).Path $exePath }
$exePath = [System.IO.Path]::GetFullPath($exePath)
$wd = $WorkDir
if (-not $wd) { $wd = (Get-Location).Path }
if (-not [System.IO.Path]::IsPathRooted($wd)) { $wd = Join-Path (Get-Location).Path $wd }
if (-not (Test-Path -LiteralPath $wd -PathType Container)) { $wd = (Get-Location).Path }

if (-not $Shot) {
  $Shot = Join-Path $root ('tmp\gui-smoke\' + [System.IO.Path]::GetFileNameWithoutExtension($exePath) + '.png')
} elseif (-not [System.IO.Path]::IsPathRooted($Shot)) {
  $Shot = Join-Path (Get-Location).Path $Shot
}
$Shot = [System.IO.Path]::GetFullPath($Shot)
$shotDir = Split-Path -Parent $Shot
if ($shotDir -and -not (Test-Path -LiteralPath $shotDir)) { New-Item -ItemType Directory -Force -Path $shotDir | Out-Null }

Write-Output ("=== gui-smoke: {0} ===" -f $exePath)
Note ("workdir={0}  wait={1}s  minColors={2}  capture={3}  shot={4}" -f $wd, $Seconds, $MinColors, $Capture, $Shot)

# ---- 像素统计：LockBits 一次拷出来数颜色，不用 GetPixel（逐像素 30 万次会慢到不可用）----
function Get-ImgStats([System.Drawing.Bitmap]$bmp, [int]$maxSamples) {
  $rect = New-Object System.Drawing.Rectangle -ArgumentList @(0, 0, $bmp.Width, $bmp.Height)
  $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  try {
    $stride = [Math]::Abs($d.Stride)
    $n = $stride * $bmp.Height
    $buf = New-Object byte[] $n
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $n)
  } finally {
    $bmp.UnlockBits($d)
  }
  $px = $bmp.Width * $bmp.Height
  $step = 1
  if ($px -gt $maxSamples) { $step = [int][Math]::Ceiling([Math]::Sqrt($px / [double]$maxSamples)) }
  $set = New-Object 'System.Collections.Generic.HashSet[int]'
  $sampled = 0
  $y = 0
  while ($y -lt $bmp.Height) {
    $row = $y * $stride
    $x = 0
    while ($x -lt $bmp.Width) {
      $i = $row + $x * 4
      $key = ([int]$buf[$i] -shl 16) -bor ([int]$buf[$i + 1] -shl 8) -bor [int]$buf[$i + 2]
      [void]$set.Add([int]$key)
      $sampled++
      $x = $x + $step
    }
    $y = $y + $step
  }
  return @{ colors = $set.Count; sampled = $sampled; w = $bmp.Width; h = $bmp.Height }
}

function New-ClientBitmap([int]$w, [int]$h) {
  $fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  return New-Object System.Drawing.Bitmap -ArgumentList @($w, $h, $fmt)
}

# 三条抓图路径，都只取「客户区」（程序画东西的地方；标题栏/边框不属于内容）
function Shot-Print([IntPtr]$hwnd, [int]$w, [int]$h) {
  $bmp = New-ClientBitmap $w $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  try { [void][GuiSmoke32]::PrintWindow($hwnd, $hdc, 3) }   # PW_CLIENTONLY | PW_RENDERFULLCONTENT
  finally { $g.ReleaseHdc($hdc); $g.Dispose() }
  return $bmp
}
function Shot-Dc([IntPtr]$hwnd, [int]$w, [int]$h) {
  $bmp = New-ClientBitmap $w $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $src = [GuiSmoke32]::GetDC($hwnd)
  try {
    if ($src -ne [IntPtr]::Zero) { [void][GuiSmoke32]::BitBlt($hdc, 0, 0, $w, $h, $src, 0, 0, 0x00CC0020) }
  } finally {
    if ($src -ne [IntPtr]::Zero) { [void][GuiSmoke32]::ReleaseDC($hwnd, $src) }
    $g.ReleaseHdc($hdc); $g.Dispose()
  }
  return $bmp
}
function Shot-Screen([IntPtr]$hwnd, [int]$w, [int]$h) {
  $org = [GuiSmoke32]::ClientScreenOrigin($hwnd)
  $ox = [int]$org[0]
  $oy = [int]$org[1]
  $bmp = New-ClientBitmap $w $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $sz = New-Object System.Drawing.Size -ArgumentList @($w, $h)
    $g.CopyFromScreen($ox, $oy, 0, 0, $sz)
  } finally { $g.Dispose() }
  return $bmp
}

$shotBmp = $null
$exitCode = 0
try {
  # ================= A 起身 =================
  if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Check 'A' '起身' 'FAIL' ("找不到 exe: " + $exePath)
    Check 'B' '存活' 'SKIP' '没有进程可查'
    Check 'C' '有窗口' 'SKIP' '没有进程可查'
    Check 'D' '画出来了' 'SKIP' '没有进程可查'
    Check 'E' '干净退出' 'SKIP' '没有进程可查'
    Write-Output '----'
    Write-Output ("shot: {0}" -f $Shot)
    Write-Output ("warn {0} / skip {1}" -f $script:warnN, $script:skipN)
    Write-Output ("gui smoke pass {0} / fail {1}" -f $script:passN, $script:failN)
    exit 1
  }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $script:proc = Start-Process -FilePath $exePath -WorkingDirectory $wd -PassThru
  } catch {
    Check 'A' '起身' 'FAIL' ("Start-Process 抛异常: " + $_.Exception.Message)
    Write-Output '----'
    Write-Output ("gui smoke pass {0} / fail {1}" -f $script:passN, $script:failN)
    exit 1
  }
  $proc = $script:proc
  $startMs = [int]$sw.Elapsed.TotalMilliseconds
  Check 'A' '起身' 'PASS' ("进程已创建 pid={0}，Start-Process 返回耗时 {1}ms" -f $proc.Id, $startMs)

  # 等 -Seconds，同时每 100ms 探一次窗口：首次出现/首次可见的时刻比"睡够再看"更有诊断价值
  $firstWinMs = -1
  $firstVisMs = -1
  $probeErr = ''
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    if ($proc.HasExited) { break }
    try {
      $ws0 = @([GuiSmoke32]::WindowsOf([uint32]$proc.Id))
      if ($ws0.Count -gt 0 -and $firstWinMs -lt 0) { $firstWinMs = [int]$sw.Elapsed.TotalMilliseconds }
      if ($ws0.Count -gt 0 -and $firstVisMs -lt 0) {
        foreach ($w0 in $ws0) { if ([GuiSmoke32]::IsWindowVisible($w0)) { $firstVisMs = [int]$sw.Elapsed.TotalMilliseconds; break } }
      }
    } catch { $probeErr = $_.Exception.Message }
    Start-Sleep -Milliseconds 100
  }
  $waitMs = [int]$sw.Elapsed.TotalMilliseconds
  if ($probeErr) { Note ("窗口轮询异常: " + $probeErr) }

  # ================= B 存活 =================
  $proc.Refresh()
  $alive = -not $proc.HasExited
  if ($alive) {
    Check 'B' '存活' 'PASS' ("等待 {0}ms 后 HasExited=False（窗口首次出现 {1}ms，首次可见 {2}ms）" -f $waitMs, $firstWinMs, $firstVisMs)
  } else {
    $ec = $proc.ExitCode
    Check 'B' '存活' 'FAIL' ("进程已退出！exit={0} (0x{1:X8})，启动后约 {2}ms —— 典型的「建窗失败后秒退」" -f $ec, ($ec -band 0xFFFFFFFF), $waitMs)
  }

  # ================= C 有窗口 =================
  # 候选规则（2026-10-31 实测才补上，不是想当然）：hlc -o 编出来的 exe 是 console 子系统，
  # 除了程序自己的窗口还会带一个 ConsoleWindowClass 控制台窗口，它往往比程序窗口更大。第一版
  # 按「面积最大」取截图目标，结果截到控制台黑底 -> D 假红。所以按 rank 分层：
  #   指定 -WindowClass 时：该类 rank=3，其余 rank=0（显式指定就是硬约束）；
  #   未指定时：非控制台 rank=2，控制台 rank=1。同档内面积最大者胜。
  # C 的判据只认 rank>=2 的窗口 ——「只有控制台窗口」不叫「GUI 起来了」。
  $cOk = $false
  $target = [IntPtr]::Zero
  $wins = @()
  $visWins = @()
  if ($alive) {
    $wins = @([GuiSmoke32]::WindowsOf([uint32]$proc.Id))
    foreach ($h in $wins) { if ([GuiSmoke32]::IsWindowVisible($h)) { $visWins += $h } }
  }
  $tgtRect = @(0, 0, 0, 0)
  $tgtClient = @(0, 0, 0, 0)
  $tgtCls = ''
  $tgtTitle = ''
  $tgtIconic = $false
  $cands = @()
  $tgtW = 0
  $tgtH = 0
  Note ("该 pid 顶层窗口 {0} 个，其中 IsWindowVisible=true {1} 个" -f $wins.Count, $visWins.Count)
  foreach ($h in $wins) {
    $r = [GuiSmoke32]::RectOf($h)
    $rw = $r[2] - $r[0]; $rh = $r[3] - $r[1]
    $cls = [GuiSmoke32]::ClassOf($h)
    $ttl = [GuiSmoke32]::TitleOf($h)
    $vis = [GuiSmoke32]::IsWindowVisible($h)
    $ic = [GuiSmoke32]::IsIconic($h)
    $cr = [GuiSmoke32]::ClientOf($h)
    $cw = $cr[2] - $cr[0]; $ch = $cr[3] - $cr[1]
    Note ("hwnd=0x{0:X} visible={1} iconic={2} class={3} title={4} rect={5},{6} {7}x{8} client={9}x{10}" -f
      $h.ToInt64(), $vis, $ic, $cls, $ttl, $r[0], $r[1], $rw, $rh, $cw, $ch)
    if ($vis -and $rw -gt 0 -and $rh -gt 0) {
      $rank = 2
      if (($cls -eq 'ConsoleWindowClass') -or ($cls -eq 'PseudoConsoleWindow') -or ($cls -eq 'CASCADIA_HOSTING_WINDOW_CLASS')) { $rank = 1 }
      if ($WindowClass) {
        if ($cls -eq $WindowClass) { $rank = 3 } else { $rank = 0 }
      }
      $cands += [pscustomobject]@{
        rank = $rank; area = ($rw * $rh); hwnd = $h
        r = @($r[0], $r[1], $rw, $rh); c = @($cr[0], $cr[1], $cw, $ch)
        cls = $cls; title = $ttl; iconic = $ic
      }
    }
  }
  $guiCands = @($cands | Where-Object { $_.rank -ge 2 -and (-not $_.iconic) })
  $pick = $null
  if ($guiCands.Count -gt 0) {
    $pick = $guiCands | Sort-Object -Property @{ Expression = 'rank'; Descending = $true }, @{ Expression = 'area'; Descending = $true } | Select-Object -First 1
  } elseif ($cands.Count -gt 0) {
    $pick = $cands | Sort-Object -Property @{ Expression = 'rank'; Descending = $true }, @{ Expression = 'area'; Descending = $true } | Select-Object -First 1
    Note '没有程序自己的可见窗口，只有控制台/系统窗口：截图退回到它（D 大概率红，这正是想要的判定）'
  }
  if ($null -ne $pick) {
    $target = [IntPtr]$pick.hwnd
    $tgtRect = $pick.r
    $tgtClient = $pick.c
    $tgtCls = $pick.cls
    $tgtTitle = $pick.title
    $tgtIconic = $pick.iconic
    $tgtW = $tgtRect[2]
    $tgtH = $tgtRect[3]
  }
  if ($guiCands.Count -gt 0) {
    $cOk = $true
    Check 'C' '有窗口' 'PASS' ("程序自己的可见窗口 {0} 个（非控制台、非最小化、rect>0）；截图目标 hwnd=0x{1:X} class={2} rect={3}x{4}" -f $guiCands.Count, $target.ToInt64(), $tgtCls, $tgtW, $tgtH)
  } else {
    $why = '进程不在（见 B）'
    if ($alive) {
      if ($cands.Count -eq 0) { $why = '没有任何 visible=true 且 rect>0 的顶层窗口' }
      else { $why = ("只有控制台/系统窗口（{0} 个），没有程序自己的可见窗口" -f $cands.Count) }
    }
    Check 'C' '有窗口' 'FAIL' $why
  }

  # ================= D 画出来了 =================
  if ($target -eq [IntPtr]::Zero) {
    Check 'D' '画出来了' 'FAIL' '没有可截图的可见窗口（见 C）'
  } else {
    $cw = $tgtClient[2]; $chh = $tgtClient[3]
    if ($cw -le 0 -or $chh -le 0) { $cw = $tgtRect[2]; $chh = $tgtRect[3]; Note '客户区尺寸为 0，退回窗口矩形尺寸' }
    if (($tgtCls -eq 'ConsoleWindowClass') -or ($tgtCls -eq 'PseudoConsoleWindow')) { Note '目标是控制台窗口，不是程序自己的 GUI 窗口' }
    $methods = @($Capture)
    if ($Capture -eq 'auto') { $methods = @('print', 'dc', 'screen') }
    $fg = [GuiSmoke32]::GetForegroundWindow()
    $best = $null
    foreach ($m in $methods) {
      if ($m -eq 'screen' -and $fg -ne $target) {
        Note '跳过 screen 抓取：目标窗口不是前台窗口（抓到的可能是桌面而不是程序，容易假通过）'
        continue
      }
      $bmp = $null
      try {
        switch ($m) {
          'print' { $bmp = Shot-Print $target $cw $chh }
          'dc' { $bmp = Shot-Dc $target $cw $chh }
          'screen' { $bmp = Shot-Screen $target $cw $chh }
        }
        $st = Get-ImgStats $bmp 60000
        Note ("方式 {0}: {1}x{2}，不同颜色 {3} 个，采样 {4} 点" -f $m, $st.w, $st.h, $st.colors, $st.sampled)
        if ($null -eq $best -or $st.colors -gt $best.stats.colors) {
          if ($null -ne $best) { $best.bmp.Dispose() }
          $best = @{ m = $m; bmp = $bmp; stats = $st }
        } else {
          $bmp.Dispose()
        }
      } catch {
        if ($null -ne $bmp) { $bmp.Dispose() }
        Note ("方式 {0} 抛异常: {1}" -f $m, $_.Exception.Message)
      }
    }
    if ($null -eq $best) {
      Check 'D' '画出来了' 'FAIL' '三条抓图路径全部失败（详见上面的异常行）'
    } else {
      $shotBmp = $best.bmp
      $st = $best.stats
      $saved = $true
      try { $shotBmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png) }
      catch { $saved = $false; Note ("PNG 保存失败: " + $_.Exception.Message) }
      $ok = ($st.colors -ge $MinColors) -and $saved
      $detail = ("方式={0}，不同颜色 {1} 个（要求 >= {2}），{3}x{4}，采样 {5} 点，图 -> {6}" -f
        $best.m, $st.colors, $MinColors, $st.w, $st.h, $st.sampled, $Shot)
      if (-not $saved) { $detail = $detail + '（PNG 保存失败）' }
      if ($st.colors -lt $MinColors) { $detail = $detail + ' —— 纯色/接近纯色，窗口在但没画东西' }
      Check 'D' '画出来了' $(if ($ok) { 'PASS' } else { 'FAIL' }) $detail
      if ($best.m -eq 'screen') { Note '仅屏幕抓取成功：依据较弱（可能抓到桌面背景），建议实现窗口自身重绘或 GetDC 路径' }
    }
  }

  # ================= E 干净退出 =================
  if (-not $proc.HasExited) {
    $mode = 'CloseMainWindow'
    $closed = $false
    try { $closed = $proc.CloseMainWindow() } catch { $closed = $false }
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $exited = $proc.WaitForExit($ExitWaitSec * 1000)
    if (-not $exited -and $target -ne [IntPtr]::Zero) {
      [void][GuiSmoke32]::PostMessage($target, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
      $mode = 'CloseMainWindow + WM_CLOSE'
      $exited = $proc.WaitForExit($ExitWaitSec * 1000)
    }
    $em = [int]$t0.Elapsed.TotalMilliseconds
    if ($exited) {
      $proc.Refresh()
      $ec = $proc.ExitCode
      Check 'E' '干净退出' 'PASS' ("{0} -> {1}ms 内自行退出，exit={2} (0x{3:X8})" -f $mode, $em, $ec, ($ec -band 0xFFFFFFFF))
      if ($ec -ne 0) { Note ("注意：退出码非 0（" + $ec + "），关窗路径可能有问题") }
    } else {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 200
      $verdict = $(if ($WarnIsFail) { 'FAIL' } else { 'WARN' })
      $tail = $(if ($WarnIsFail) { '按 -WarnIsFail：关不掉的窗口算失败' } else { '按约定这是 WARN，不是 FAIL；加 -WarnIsFail 可改为失败' })
      Check 'E' '干净退出' $verdict ("{0} 后 {1}ms 仍未退出，已 Stop-Process 强杀（{2}）" -f $mode, $em, $tail)
    }
  } else {
    Check 'E' '干净退出' 'SKIP' '进程在 B 已退出，没有「干净退出」可测'
  }
} catch {
  $script:scriptErr = $true
  Write-Output ("SCRIPT ERROR: " + $_.Exception.Message)
  Write-Output ($_.ScriptStackTrace)
} finally {
  if ($null -ne $script:proc) {
    try {
      if (-not $script:proc.HasExited) {
        Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
        Write-Output ("     (finally) 清理残留进程 pid=" + $script:proc.Id)
      }
    } catch { }
  }
  if ($null -ne $shotBmp) { try { $shotBmp.Dispose() } catch { } }
}

Write-Output '----'
Write-Output ("shot: {0}" -f $Shot)
Write-Output ("warn {0} / skip {1}" -f $script:warnN, $script:skipN)
Write-Output ("gui smoke pass {0} / fail {1}" -f $script:passN, $script:failN)

if ($script:scriptErr) { exit 2 }
if ($script:failN -gt 0) { exit 1 }
exit 0
