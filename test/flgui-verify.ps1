# flgui-verify.ps1 — FLGUI 门（M1）：**无头内核样本** ＋ **真窗 app 的无头 dump 模式** 双端跑 + dump 逐字节对账 + 基线锁定
#
# 为什么单开一道门：FLGUI 的判据不是"退出码 42 就算过"——**布局/游标/命令表/状态池都要 dump 成文本对账**，
#   且要证明"同一份源码在两个编译器下产出行为逐字节一致"。总门（test\verify-all.ps1）里没有"stdout 快照基线"这种步骤，
#   所以 FLGUI 自建一道门（与 test\loop-verify.ps1 同级）；样本本身**同时**注册进总门的 regress / 差分门 / boot 门。
#
# 用法：
#   pwsh -File test\flgui-verify.ps1                 # 跑门（无头内核样本 flgui1~flgui5 ＋ 真窗 app 无头 dump）
#   pwsh -File test\flgui-verify.ps1 -WriteBaseline  # 重录基线（**只在你确认输出变化是有意的之后**）
#   pwsh -File test\flgui-verify.ps1 -Samples f1,f2  # 只跑指定样本（test\samples\<名>.fl，可多个）
#   pwsh -File test\flgui-verify.ps1 -SkipDemo       # 跳过真窗 app 那一半
#
# M4 新增的两条判据（此前只躺在 tmp\m3b\，靠人记得去跑）：
#   · 滚轮账本 / 命令表级布局 = 样本 `flgui5`（本门自动跑；合成输入走的就是平台层填进 GuiInput 的字段）
#   · **真输入**（真鼠标真的走通平台层那条路）= `apps\ui_gallery\wheel-probe.ps1`（真窗、真滚轮事件）
#     —— 脚本化输入看不见平台层缺口（2026-09-22 真滚轮 bug 的教训），所以这一条必须留在真窗口那边。
#
# M4d 新增（2026-09-26，动画地基①）：样本 `flgui7` = **时间注入通道 + 动画开关**的无头契约
#   （固定序列 0/16/32/48 钉"注入 → 搬运 → 可观测"；`anim_pct` 用"返回值 + 字段读回"两条硬判据量）。
#   真窗那半的对应判据在 `apps\flgui_demo\kb-probe.ps1`：CV 行里的 `ms=` 必须非 0、单调、且真推进。
# M4e 新增（2026-09-27，帧率档位）：样本 `flgui8` = **帧率档位**的无头契约
#   （默认 60 / 0 = 不限速 / 夹取 / `gui_frame_ms` 换算 / **不参与命令表** / 与 anim_pct 互不干扰）。
#   ⚠️ 真窗的帧率判据**不在这道门里**（dump 看不见"等多久"）：探针 = `tmp\frames\pace-probe.fl`
#   （真窗 + QPC 计时，量 period/work/CPU；2026-09-27 实测 60fps 档 ≈15.3ms、144 档 6.94ms）。
# M4f 新增（2026-09-27，真动画第一刀）：样本 `flgui9` = **缓动 / 插值 / 进度入口 / 池字段**的无头契约
#   （31 位全亮：ease-out 形状与端点、lerp 双向与夹取、池字段 k=0..3 与越界夹取、起始戳"只盖一次"、
#     不同 ID 不串位、**掉帧不跑偏**（两条帧史不同的 ID 同 elapsed 必须同进度）、慢动作 pct=200、
#     两个除零特判 `anim_pct=0` / `dur<=0`、到点饱和不越界）。
#   ⚠️ 真窗那半的判据**不在这道门里**：探针 = `tmp\animprobe\anim-probe.fl`（真窗 + QPC，
#     量动画跑着时的 period/work/CPU；2026-09-27 实测 60fps 档 ≈15.36ms、work ≈1.26ms/帧 ⇒ 单核 ≈8%）。
# M4g 新增（2026-09-27，滑入/缩放第二刀）：样本 `flgui10` = **位移/缩放**的无头契约
#   本刀**零新内核 API**（只用 M4f 的 gui_anim/gui_lerp ＋ 既有 gui_next_rect/gui_item_at）⇒ 判据钉的是
#   **那条接线**："动画值 → 布局矩形 → 命令表"（14 位：起步帧/中段/到位三组 rect ＋ 位移与缩放同源 ＋
#   `anim_pct=0` 时布局侧也立即到位 ＋ `gui_item_at` 不动布局游标 ＋ 有/无覆盖层时下一个控件矩形逐字段相同）。
#   ⚠️ 真窗那半的判据不在这道门里：`apps\flgui_demo\kb-probe.ps1`（真窗真按键）＋ 外部量 CPU/帧率。
# M4h 新增（2026-09-27，命令流形状第一刀）：样本 `flgui11` = **不透明度 / 状态栈**的无头契约
#   本刀给命令流加**状态命令** kind `20`（压不透明度）/ `21`（出栈）—— 与裁剪 `6`/`7` 同形；
#   但**生效值在 gui_push 那一刻解析进每条命令**（`gui_cmd_a`）⇒ 渲染端无状态、判据能逐条命令钉。
#   20 位全亮：默认 255 / 压后命令自带值 / kind 20 的载荷 / **每帧归零**（跨帧不残留）/ 嵌套与弹出返回值 /
#   夹取（-5→0、300→255）/ 空栈 pop 响亮报错（err=32）/ 8 层上限第 9 次只计数（err=48、栈顶不越写）/
#   压弹不动布局游标 / 20-21 条数配对。
#   ⚠️ **渲染层判据**（"画成什么样"）不在这道门里 —— 文字层对混合结果完全失明：
#   探针 = `tmp\blendprobe\blend-probe.fl`（真窗 + **离屏 DIB 直读** `s->bits`，绕开上屏）。
# M4m 新增（2026-09-28，输入灵敏度：窗口拖动 ＋ 滚轮步长 ＋ 滑块/滚动条倍率 ＋ 滚动条可抓区）：样本 `flgui13`
#   = **输入灵敏度**的无头契约（21 位全亮：默认 `wheel_step = 60` / `drag_scale = 100`；
#     `wheel_step` 三档 0/40/60 喂 ±1/±3 格 ⇒ 偏移变化 = 步长 × 格数（含累加与反向）；
#     滑块与滚动条各跑 `drag_scale` 100/50/200 ⇒ 位移 = Δ × scale / 100；滚动条可抓区放宽（tx − 6 也能抓）；
#     **拖动 on/off 两套状态下命令表逐字段相同** ＋ 顶栏 24px 之外按下不开拖 ＋ 双击分支返回 2）。
#   ⚠️ **真鼠标那半不在这道门里**：滚轮 = `apps\ui_gallery\wheel-probe.ps1`、
#     拖动（1:1 跟手 / 快拖出窗不自走 / 锁定 0,0 / 双击最大化）= `apps\ui_gallery\drag-probe.ps1`。
#   本门第 4 段是同一份口径的**外部裁判**：期望值用 PowerShell 现算，不信样本自己的结论。
# M4n 新增（2026-09-28，UI 美术第 2 批 · 卡 T-20260928-031004）：样本 `flgui14` = **勾 / 圆拇指 /
#   单选钮（新 API `gui_radio`）/ 焦点圈 / 进度条圆角端点 / 间距栅格**的无头契约（25 位全亮）：
#   ① 两个新字段（`theme_check` / `theme_focus`）的深色默认 0/0 与蓝白预设 255 / #2563EB（且等于 theme_box）；
#   ② **形状全在渲染端 ⇒ 命令流一个字节不动**：同一份控件代码在三个开关变化下命令表逐字段相同
#      （且表里真有 kind 8/9/12/15 —— 不是拿空表比空表）；
#   ③ `gui_radio` 的命令流形状（零新 kind：8 环 + 9 点 + 5 标签）与**组语义 + 状态池**；
#   ④ `gui_space_grid` 的归整算式与"**默认值一个字节没动**"。
#   ⚠️ **像素那半不在这道门里**（dump 对形状完全失明）：`tmp\artprobe\art-probe.fl`（24 位）＋
#     `tmp\artprobe\run-art-classic.ps1`（老库/新库整块表面逐像素比 —— "关就是真关"的机械证据）。
#   本门第 5 段是同一份口径的**外部裁判**：期望值用 PowerShell 现算，不信样本自己的结论。
param(
    [switch]$WriteBaseline,
    [string[]]$Samples = @('flgui1', 'flgui2', 'flgui3', 'flgui4', 'flgui5', 'flgui6', 'flgui7', 'flgui8', 'flgui9', 'flgui10', 'flgui11', 'flgui12', 'flgui13', 'flgui14', 'flgui15', 'flgui16', 'flgui17'),
    [switch]$SkipDemo
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot          # E:\FLINT-lab
$flint = Join-Path $root 'flint.exe'
$boot = Join-Path $root 'boot\b1_emit.exe'
$work = Join-Path $root 'tmp\flgui'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$pass = 0
$fail = 0
function Ok($m) { Write-Output "  OK   $m"; $script:pass++ }
function Bad($m) { Write-Output "  FAIL $m"; $script:fail++ }

# 外部裁判：用 GDI 按**同一字体参数**量真实字宽（供"光标条契约"判据用）。
# 为什么不用库里的值：那样就是自证。参数必须与 ui_lib.fl 的 ui_font_make 保持一致
# （px=14 / weight 400 / charset 1 / quality 5 / Consolas）。
function Get-FontAdvance {
  param([int]$Px = 14, [string]$Face = 'Consolas')
  if (-not ('FontGauge' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class FontGauge {
  [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
  [DllImport("gdi32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr CreateFontA(int h,int w,int e,int o,int wt,uint it,uint ul,uint st,uint cs,uint op,uint cp,uint q,uint pf,string face);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
  [DllImport("gdi32.dll", CharSet=CharSet.Ansi)] public static extern bool GetTextExtentPoint32A(IntPtr dc, string s, int n, out SIZE sz);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
  public static int Adv(int px, string face) {
    IntPtr scr = GetDC(IntPtr.Zero);
    IntPtr dc = CreateCompatibleDC(scr);
    IntPtr hf = CreateFontA(px,0,0,0,400,0,0,0,1,0,0,5,0,face);
    SelectObject(dc, hf);
    SIZE sz;
    GetTextExtentPoint32A(dc, "MMMMMMMMMM", 10, out sz);
    ReleaseDC(IntPtr.Zero, scr);
    return sz.cx / 10;
  }
  public static int Ext10(int px, string face) {
    IntPtr scr = GetDC(IntPtr.Zero);
    IntPtr dc = CreateCompatibleDC(scr);
    IntPtr hf = CreateFontA(px,0,0,0,400,0,0,0,1,0,0,5,0,face);
    SelectObject(dc, hf);
    SIZE sz;
    GetTextExtentPoint32A(dc, "MMMMMMMMMM", 10, out sz);
    ReleaseDC(IntPtr.Zero, scr);
    return sz.cx;
  }
  public static int CapH(int px, string face) {
    IntPtr scr = GetDC(IntPtr.Zero);
    IntPtr dc = CreateCompatibleDC(scr);
    IntPtr hf = CreateFontA(px,0,0,0,400,0,0,0,1,0,0,5,0,face);
    SelectObject(dc, hf);
    SIZE sz;
    GetTextExtentPoint32A(dc, "M", 1, out sz);
    ReleaseDC(IntPtr.Zero, scr);
    return sz.cy;
  }
}
'@
  }
  return [FontGauge]::Adv($Px, $Face)
}

# M4q（2026-09-28）：同一把外部尺子的**10 字符总宽**版本（多字体档"三档字号各对"对账用）。
#   与 Get-FontAdvance 共用同一个已加载的类型（上面那段 Add-Type 有幂等保护 ⇒ 这里只是确保类型就位）。
#   为什么不用 `Adv × 10`：那是同一个量的**换算**，不是第二次测量；这里要的是"另一条独立测量"。
function Get-FontExt10 {
  param([int]$Px = 14, [string]$Face = 'Consolas')
  $null = Get-FontAdvance $Px $Face
  return [FontGauge]::Ext10($Px, $Face)
}

# M4q：**字号**的锐尺子 —— `GetTextExtentPoint32A` 的文本高度 `cy`。
#   为什么必须补这一条：字宽在这套 GDI 映射下**按 2px 台阶量化**（实测 Consolas：px=16/17/18 的 10 字符宽
#   全是 80、px=12/13 全是 60）⇒ 光比宽度分辨不出"库用的是 17 还是 18"；而 **cy 与请求的 px 一一对应**
#   （实测 12→12 … 18→18）⇒ 三档字号"各对"这条判据靠它才钉得死（宽度只能证明"三档确实不同"）。
function Get-FontHeight {
  param([int]$Px = 14, [string]$Face = 'Consolas')
  $null = Get-FontAdvance $Px $Face
  return [FontGauge]::CapH($Px, $Face)
}

# 一个"双端跑 + dump 对账"的单元：$src = .fl 源文件；$name = 基线名
function Invoke-DualEnd([string]$name, [string]$src, [string]$expect) {
  Write-Output ""
  Write-Output "----- $name（$src）-----"
  if (-not (Test-Path $src)) { Bad "找不到源文件 $src"; return }
  $df = Join-Path $work "dump-$name-flint.txt"
  $db = Join-Path $work "dump-$name-boot.txt"

  # 真 flint 侧
  $exeF = Join-Path $work "$name-flint.exe"
  Remove-Item $exeF -ErrorAction SilentlyContinue
  & $flint $src -o $exeF | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "真 flint 编译失败（exit=$LASTEXITCODE）" }
  elseif (-not (Test-Path $exeF)) { Bad "真 flint 未产出 $exeF" }
  else {
    & $exeF > $df 2>&1
    $rf = $LASTEXITCODE
    if ($rf -eq $expect) { Ok "真 flint 产物退出码 $rf" } else { Bad "真 flint 产物退出码 $rf（期望 $expect）" }
  }

  # boot 侧（B2b 规则：产物写在源文件同目录）
  $srcDir = Split-Path -Parent $src
  $exeB = Join-Path $srcDir ((Split-Path -Leaf $src) -replace '\.fl$', '.exe')
  Remove-Item $exeB -ErrorAction SilentlyContinue
  Push-Location $srcDir
  & $boot $src | Out-Null
  $cb = $LASTEXITCODE
  Pop-Location
  if ($cb -ne 0) { Bad "boot 编译失败（exit=$cb）" }
  elseif (-not (Test-Path $exeB)) { Bad "boot 未产出 $exeB" }
  else {
    & $exeB > $db 2>&1
    $rb = $LASTEXITCODE
    if ($rb -eq $expect) { Ok "boot 产物退出码 $rb" } else { Bad "boot 产物退出码 $rb（期望 $expect）" }
    Remove-Item $exeB -ErrorAction SilentlyContinue     # 清掉源目录里的产物（别留脏）
  }

  if (-not ((Test-Path $df) -and (Test-Path $db))) { Bad "缺少 dump 文件（编译或运行没成功）"; return }

  # 双端 dump 逐字节一致
  $hf = (Get-FileHash $df -Algorithm SHA256).Hash
  $hb = (Get-FileHash $db -Algorithm SHA256).Hash
  $lines = (Get-Content $df).Count
  if ($hf -eq $hb) { Ok "双端 dump 逐字节一致（$lines 行，sha256=$($hf.Substring(0,16))）" }
  else {
    Bad "双端 dump 不一致：flint=$($hf.Substring(0,16)) boot=$($hb.Substring(0,16))"
    Compare-Object (Get-Content $df) (Get-Content $db) | Select-Object -First 6 |
      ForEach-Object { Write-Output "       $($_.SideIndicator) $($_.InputObject)" }
  }

  # 与基线对账（真值以真 flint 侧为准）
  $base = Join-Path $root "test\flgui-baseline-$name.txt"
  if ($WriteBaseline) {
    Copy-Item $df $base -Force
    Ok "基线已重录：$base（$lines 行）"
  } elseif (-not (Test-Path $base)) {
    Bad "基线不存在（$base）—— 确认输出无误后跑 -WriteBaseline"
  } else {
    $hb2 = (Get-FileHash $base -Algorithm SHA256).Hash
    if ($hf -eq $hb2) { Ok "与基线逐字节一致（$base）" }
    else {
      Bad "与基线不一致（基线 sha=$($hb2.Substring(0,16)) 现跑 sha=$($hf.Substring(0,16))）"
      Compare-Object (Get-Content $base) (Get-Content $df) | Select-Object -First 8 |
        ForEach-Object { Write-Output "       $($_.SideIndicator) $($_.InputObject)" }
    }
  }
}

Write-Output ""
Write-Output "============================================="
Write-Output "  FLGUI 门（M1）"
Write-Output "============================================="
foreach ($exe in @($flint, $boot)) { if (-not (Test-Path $exe)) { Write-Output "!! 找不到编译器 $exe"; exit 1 } }

# ---- 1. 无头内核样本（不建窗：合成输入喂 gui_begin）----
foreach ($s in $Samples) { Invoke-DualEnd $s (Join-Path $root "test\samples\$s.fl") 42 }

# ---- 2. 真窗 app 的无头 dump 模式（与真窗共用同一条代码路径；开关文件跑完恢复原状）----
if (-not $SkipDemo) {
  $demoSrc = Join-Path $root 'apps\flgui_demo\main.fl'
  $switch = Join-Path $work 'dump.on'
  $hadSwitch = Test-Path $switch
  try {
    New-Item -ItemType File -Force -Path $switch | Out-Null
    Invoke-DualEnd 'demo' $demoSrc 42
  } finally {
    if (-not $hadSwitch) { Remove-Item $switch -Force -ErrorAction SilentlyContinue }
  }
}

# ---- 3. 光标条契约（**语义判据**，不依赖基线里记住的数值）----
# 为什么单列一条：dump 基线只"记住当时的值" —— 当初那个"8px/字节估算"的错值就是被基线一并锁死的
#   （M4c 教训：**基线会把错值锁死**）。所以这里换成**外部裁判**：GDI 按同一字体参数量出真实字宽，
#   再断言 `光标 x = 文本 x + 真实字宽 × 文本长度`。字体一改、估算一改，这条都会说话。
Write-Output ""
Write-Output "----- 光标条契约（外部裁判：GDI 量真字宽）-----"
$adv = Get-FontAdvance 14 'Consolas'
Write-Output ("  GDI 实测字宽 = $adv px/字符（Consolas 14px，与 ui_lib.fl 的 ui_font_make 同参数）")
$dfDemo = Join-Path $work 'dump-demo-flint.txt'
if (-not $SkipDemo -and (Test-Path $dfDemo)) {
  $dl = Get-Content $dfDemo
  $pairs = 0
  for ($i = 0; $i -lt $dl.Count; $i++) {
    $m15 = [regex]::Match($dl[$i], '^\s*CMD \d+ kind=15 rect=(-?\d+),(-?\d+),(\d+),(\d+)')
    if (-not $m15.Success) { continue }
    $caretX = [int]$m15.Groups[1].Value
    $tx = $null; $tlen = $null
    for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 4; $j--) {
      $m5 = [regex]::Match($dl[$j], '^\s*CMD \d+ kind=5 rect=(-?\d+),(-?\d+),\d+,\d+ text=\d+,(\d+)')
      if ($m5.Success) { $tx = [int]$m5.Groups[1].Value; $tlen = [int]$m5.Groups[3].Value; break }
    }
    if ($null -eq $tx) { continue }
    $pairs++
    $want = $tx + $adv * $tlen
    if ($caretX -eq $want) { Ok ("光标 x={0} = 文本 x={1} + {2}px×{3} 字符（该帧文本字节数 {3}）" -f $caretX, $tx, $adv, $tlen) }
    else { Bad ("光标 x={0} ≠ 文本 x={1} + {2}×{3} = {4}（差 {5}px）" -f $caretX, $tx, $adv, $tlen, $want, ($caretX - $want)) }
  }
  if ($pairs -eq 0) { Bad '没找到任何「光标＋文本」配对 ⇒ 判据没在跑（先确认 dump 里有 kind=15）' }
  else { Ok ("光标契约共验了 $pairs 帧") }
} else {
  Write-Output "  （-SkipDemo 或没有 demo dump ⇒ 跳过光标契约判据）"
}

# ---- 4. M4m（2026-09-28）**输入灵敏度契约**（语义判据，**外部裁判：期望值在这里现算**）----
# 为什么单列一段：样本 `flgui13` 自己已经断言过一遍（内部位掩码 21 位），这里换**另一门语言、另一套算式**
#   再判一次 —— 与上面"光标条契约"同一条口径：**判据的期望值不许只活在样本里**（同族坑：基线会把旧值锁死）。
# 逐行读样本自己打出来的账（WSTEP / SLD / SCB / DRAG），期望值全部**在这儿现算**：
#   · WSTEP：`off1 − off0 == −n × step`（滚轮向下 n<0 ⇒ 偏移增加；步长 × 格数）
#   · SLD / SCB：位移 == `dx × scale / 100`（Δ=20 与 50/100/200 三档都不带余数 ⇒ 整数除法无歧义）
#   · DRAG：拖动 on/off 两帧命令表逐字段相同 = 1；顶栏外按下 begin=0 且 on=0；双击分支 begin2=2
Write-Output ""
Write-Output "----- M4m 输入灵敏度契约（外部裁判：PowerShell 现算）-----"
$df13 = Join-Path $work 'dump-flgui13-flint.txt'
if (Test-Path $df13) {
  $l13 = Get-Content $df13
  $n13 = 0
  # 默认值 + 三档滚轮步长 + 三档滑块 + 三档滚动条 + 三条拖动账
  $seen = @{ WSTEP = 0; SLD = 0; SCB = 0 }
  foreach ($l in $l13) {
    $m = [regex]::Match($l, '^M4M def wheel_step=(-?\d+) drag_scale=(-?\d+)')
    if ($m.Success) {
      $ws = [int]$m.Groups[1].Value; $ds = [int]$m.Groups[2].Value
      if ($ws -eq 60 -and $ds -eq 100) { Ok "默认：wheel_step=$ws（= 3 行/格）、drag_scale=$ds（= 1:1）" }
      else { Bad "默认值不对：wheel_step=$ws（期望 60）、drag_scale=$ds（期望 100）" }
      $n13++
      continue
    }
    $m = [regex]::Match($l, '^WSTEP step=(-?\d+) n=(-?\d+) off0=(-?\d+) off1=(-?\d+)')
    if ($m.Success) {
      $step = [int]$m.Groups[1].Value; $nn = [int]$m.Groups[2].Value
      $o0 = [int]$m.Groups[3].Value; $o1 = [int]$m.Groups[4].Value
      $want = $o0 - $nn * $step          # off = off − wheel × step
      if ($o1 -eq $want) { Ok ("滚轮 step={0} 格数={1}：偏移 {2} → {3} = {2} − ({1})×{0}（现算）" -f $step, $nn, $o0, $o1) }
      else { Bad ("滚轮 step={0} 格数={1}：偏移 {2} → {3}，该是 {4}" -f $step, $nn, $o0, $o1, $want) }
      $seen.WSTEP++; $n13++
      continue
    }
    $m = [regex]::Match($l, '^SLD sc=(-?\d+) press=(-?\d+) v0=(-?\d+) v1=(-?\d+) dx=(-?\d+)')
    if ($m.Success) {
      $sc = [int]$m.Groups[1].Value; $v0 = [int]$m.Groups[3].Value
      $v1 = [int]$m.Groups[4].Value; $dx = [int]$m.Groups[5].Value
      $want = $v0 + [int]($dx * $sc / 100)
      if ($v1 -eq $want) { Ok ("滑块 scale={0}：光标位移 {1}px ⇒ 值 {2} → {3}（现算 {1}×{0}/100）" -f $sc, $dx, $v0, $v1) }
      else { Bad ("滑块 scale={0}：值 {1} → {2}，该是 {3}（{4}×{0}/100）" -f $sc, $v0, $v1, $want, $dx) }
      $seen.SLD++; $n13++
      continue
    }
    $m = [regex]::Match($l, '^SCB sc=(-?\d+) y0=(-?\d+) y1=(-?\d+) dx=(-?\d+)')
    if ($m.Success) {
      $sc = [int]$m.Groups[1].Value; $y0 = [int]$m.Groups[2].Value
      $y1 = [int]$m.Groups[3].Value; $dx = [int]$m.Groups[4].Value
      $want = $y0 + [int]($dx * $sc / 100)
      if ($y1 -eq $want) { Ok ("滚动条 scale={0}：光标位移 {1}px ⇒ 滑块 {2} → {3}（现算 {1}×{0}/100；y0=视图顶 ⇒ 可抓区放宽也一并验到）" -f $sc, $dx, $y0, $y1) }
      else { Bad ("滚动条 scale={0}：滑块 {1} → {2}，该是 {3}（{4}×{0}/100）" -f $sc, $y0, $y1, $want, $dx) }
      $seen.SCB++; $n13++
      continue
    }
    $m = [regex]::Match($l, '^DRAG begin=(-?\d+) on=(-?\d+) off_after_end=(-?\d+) cmdnA=(-?\d+) cmdnB=(-?\d+) same=(-?\d+)')
    if ($m.Success) {
      $b = [int]$m.Groups[1].Value; $on = [int]$m.Groups[2].Value
      $off = [int]$m.Groups[3].Value; $na = [int]$m.Groups[4].Value
      $nb = [int]$m.Groups[5].Value; $same = [int]$m.Groups[6].Value
      if ($b -eq 1 -and $on -eq 1 -and $off -eq 0 -and $same -eq 1 -and $na -eq $nb) {
        Ok "拖动：顶栏按下开拖（begin=1/on=1）＋ 抬手收尾（on=0）＋ on/off 两帧命令表逐字段相同（$na 条，same=1）"
      } else { Bad "拖动账不对：begin=$b on=$on off=$off cmdnA=$na cmdnB=$nb same=$same" }
      $n13++
      continue
    }
    $m = [regex]::Match($l, '^DRAG locked_my=(\d+) begin=(-?\d+) on=(-?\d+)')
    if ($m.Success) {
      $lv = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $on = [int]$m.Groups[3].Value
      if ($b -eq 0 -and $on -eq 0) { Ok "拖动：顶栏之外（my=$lv ≥ 24）按下不开拖（begin=0、on 保持 0 ⇒ 窗口位移必为 0,0）" }
      else { Bad "顶栏之外按下竟然开了拖：begin=$b on=$on" }
      $n13++
      continue
    }
    $m = [regex]::Match($l, '^DRAG dbl begin2=(-?\d+)')
    if ($m.Success) {
      $b2 = [int]$m.Groups[1].Value
      if ($b2 -eq 2) { Ok "双击：400ms 内第二次顶栏按下走双击分支（返回 2，不重复开拖）" }
      else { Bad "双击分支没走到：begin2=$b2（期望 2）" }
      $n13++
      continue
    }
  }
  # 段数与样本自报的账要一致（防"正则没匹配上 ⇒ 判据静默没跑"）
  if ($seen.WSTEP -eq 5 -and $seen.SLD -eq 3 -and $seen.SCB -eq 3) {
    Ok ("账目齐：WSTEP {0} 条 ／ SLD {1} 条 ／ SCB {2} 条" -f $seen.WSTEP, $seen.SLD, $seen.SCB)
  } else {
    Bad ("账目不全：WSTEP {0}/5 ／ SLD {1}/3 ／ SCB {2}/3 ⇒ 有判据没在跑" -f $seen.WSTEP, $seen.SLD, $seen.SCB)
  }
} else {
  Bad "没有 flgui13 的 dump（$df13）—— 输入灵敏度契约没在跑"
}

# ---- 5. M4n（2026-09-28）**UI 美术第 2 批契约**（语义判据，**外部裁判：期望值在这里现算**）----
# 为什么单列一段：样本 `flgui14` 自己已经断言过一遍（内部位掩码 25 位），这里换**另一门语言、另一套算式**
#   再判一次 —— 同"光标条契约 / M4m 输入灵敏度契约"那条老口径：**判据的期望值不许只活在样本里**
#   （同族坑：基线会把旧值锁死）。逐行读样本自己打出来的账（ART14 / M4N），期望值全部在这儿现算：
#   · def/lb：两个新字段的默认值（0/0）与蓝白预设（255 / #2563EB 且**等于** theme_box）
#   · zoo/cmd：三个开关变化下命令表逐字段相同（形状全在渲染端）＋ **表非空**（k15 = 1 = 有光标条）
#   · radio un/sel/ring：kind 8/9/5 的条数与矩形（环 = box_w²、点 = box_w/2 居中、标签 x = box_w+spacing）
#   · radio clickA/clickB/reclickB/groups/samegroup/namespaces：组语义与状态池（跨帧存活 + 同组互斥）
#   · snap/grid：间距栅格的归整算式（四舍五入、正数至少一格）与"默认值未动（仍是 6 / 4）"
Write-Output ""
Write-Output "----- M4n UI 美术契约（外部裁判：PowerShell 现算）-----"
# 与库同口径的归整算式（**独立写一遍**：四舍五入、正数至少一格、n<=0/v<=0 原样）
function Snap-Space([int]$v, [int]$n) {
  if ($n -le 0) { return $v }
  if ($v -le 0) { return $v }
  $r = [int]([Math]::Floor(($v + [int]($n / 2)) / $n) * $n)
  if ($r -lt $n) { $r = $n }
  return $r
}
$df14 = Join-Path $work 'dump-flgui14-flint.txt'
if (Test-Path $df14) {
  $l14 = Get-Content $df14
  $n14 = 0
  $seen14 = @{ SNAP = 0; GRID = 0 }
  foreach ($l in $l14) {
    $m = [regex]::Match($l, '^ART14 def check=(-?\d+) focus=(-?\d+)')
    if ($m.Success) {
      $ck = [int]$m.Groups[1].Value; $fc = [int]$m.Groups[2].Value
      if ($ck -eq 0 -and $fc -eq 0) { Ok "深色默认：theme_check=$ck、theme_focus=$fc（两个新开关都关 = 老行为）" }
      else { Bad "深色默认不对：check=$ck（期望 0）、focus=$fc（期望 0）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 lb check=(-?\d+) focus=(-?\d+) box=(-?\d+)')
    if ($m.Success) {
      $ck = [int]$m.Groups[1].Value; $fc = [int]$m.Groups[2].Value; $bx = [int]$m.Groups[3].Value
      if ($ck -eq 255 -and $fc -eq 15426341 -and $fc -eq $bx) {
        Ok ("蓝白预设：theme_check={0}、theme_focus={1}（= #2563EB，且 == theme_box {2}）" -f $ck, $fc, $bx)
      } else { Bad ("蓝白预设不对：check={0}（期望 255）、focus={1}（期望 15426341）、box={2}" -f $ck, $fc, $bx) }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 zoo cmdn=(\d+) kinds=(\d+) k8=(\d+) k15=(\d+) poolsum=(-?\d+)')
    if ($m.Success) {
      $cn = [int]$m.Groups[1].Value; $kd = [int]$m.Groups[2].Value
      $k8 = [int]$m.Groups[3].Value; $k15 = [int]$m.Groups[4].Value
      # 表非空 + kind 15（光标条）在表里 ⇒ 后面那条"开关不改命令流"不是拿空表/缺 kind 的表比
      if ($cn -gt 0 -and $kd -ge 3 -and $k8 -ge 1 -and $k15 -eq 1) {
        Ok "比对用的命令表非空且有料（cmdn=$cn、kind9+12+15=$kd、kind8=$k8、kind15=$k15）"
      } else { Bad "比对用的命令表不合格（cmdn=$cn kinds=$kd k8=$k8 k15=$k15）—— 那条判据会是假绿" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 cmd same_check=(-?\d+) same_radius=(-?\d+) same_focus=(-?\d+) poolsum_same=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      $c = [int]$m.Groups[3].Value; $d = [int]$m.Groups[4].Value
      if ($a -eq 1 -and $b -eq 1 -and $c -eq 1 -and $d -eq 1) {
        Ok "形状全在渲染端：check 0/255、radius 0/4、focus 0/非0 三档下命令表逐字段相同 ＋ POOLSUM 不动"
      } else { Bad "命令流被形状改动碰到了：same_check=$a same_radius=$b same_focus=$c poolsum_same=$d" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio un kind8=(\d+) kind9=(\d+) kind5=(\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $c = [int]$m.Groups[3].Value
      if ($a -eq 1 -and $b -eq 0 -and $c -eq 1) { Ok "未选单选钮 = 1×kind8（圆环）+ 1×kind5（标签）、无 kind9" }
      else { Bad "未选单选钮命令形状不对：kind8=$a kind9=$b kind5=$c（期望 1/0/1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio sel on=(-?\d+) kind8=(\d+) kind9=(\d+) kind5=(\d+)')
    if ($m.Success) {
      $on = [int]$m.Groups[1].Value; $a = [int]$m.Groups[2].Value
      $b = [int]$m.Groups[3].Value; $c = [int]$m.Groups[4].Value
      if ($on -eq 1 -and $a -eq 1 -and $b -eq 1 -and $c -eq 1) { Ok "选中单选钮 = kind8 + kind9（内实心点）+ kind5，选中态 = 1" }
      else { Bad "选中单选钮命令形状不对：on=$on kind8=$a kind9=$b kind5=$c（期望 1/1/1/1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio ring=(-?\d+),(-?\d+),(\d+),(\d+) dot=(-?\d+),(-?\d+),(\d+),(\d+) lblx=(-?\d+) col8=(-?\d+) col9=(-?\d+) col5=(-?\d+) boxw=(\d+) sp=(\d+)')
    if ($m.Success) {
      $rx = [int]$m.Groups[1].Value; $ry = [int]$m.Groups[2].Value
      $rw = [int]$m.Groups[3].Value; $rh = [int]$m.Groups[4].Value
      $dx = [int]$m.Groups[5].Value; $dy = [int]$m.Groups[6].Value
      $dw = [int]$m.Groups[7].Value; $dh = [int]$m.Groups[8].Value
      $lx = [int]$m.Groups[9].Value
      $c8 = [int64]$m.Groups[10].Value; $c9 = [int64]$m.Groups[11].Value; $c5 = [int64]$m.Groups[12].Value
      $bw = [int]$m.Groups[13].Value; $sp = [int]$m.Groups[14].Value
      $dot = [int]($bw / 2); if ($dot -lt 2) { $dot = 2 }
      $ty = 10 + [int]((14 - $bw) / 2)
      $ok = ($rw -eq $bw) -and ($rh -eq $bw) -and ($rx -eq 10) -and ($ry -eq $ty)
      $ok = $ok -and ($dw -eq $dot) -and ($dh -eq $dot)
      $ok = $ok -and ($dx -eq (10 + [int](($bw - $dot) / 2))) -and ($dy -eq ($ty + [int](($bw - $dot) / 2)))
      $ok = $ok -and ($lx -eq (10 + $bw + $sp))
      $ok = $ok -and ($c8 -ne 0) -and ($c9 -ne 0) -and ($c8 -eq $c9) -and ($c5 -eq 0)
      if ($ok) {
        Ok ("圆环/圆点/标签矩形与形状通道（环 {0}×{0} @x=10、点 {1}×{1} 居中、标签 x={2}；col8=col9={3}≠0、col5=0）" -f $bw, $dot, $lx, $c8)
      } else {
        Bad ("单选钮矩形/通道不对：ring={0},{1},{2},{3} dot={4},{5},{6},{7} lblx={8} col8={9} col9={10} col5={11} boxw={12} sp={13}" -f $rx, $ry, $rw, $rh, $dx, $dy, $dw, $dh, $lx, $c8, $c9, $c5, $bw, $sp)
      }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio clickA a=(-?\d+) b=(-?\d+) pool_a=(-?\d+) pool_b=(-?\d+) again=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      $pa = [int]$m.Groups[3].Value; $pb = [int]$m.Groups[4].Value; $ag = [int]$m.Groups[5].Value
      if ($a -eq 1 -and $b -eq 0 -and $pa -eq 1 -and $pb -eq 0 -and $ag -eq 1) {
        Ok "点中 'ra'：返回值与状态池一致（a=1/b=0），且**下一帧无输入仍为 1**（跨帧存活）"
      } else { Bad "点中 'ra' 的账不对：a=$a b=$b pool_a=$pa pool_b=$pb again=$ag" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio clickB same_frame a=(-?\d+) b=(-?\d+) next_frame a=(-?\d+) b=(-?\d+) rb_ret=(-?\d+)')
    if ($m.Success) {
      $sa = [int]$m.Groups[1].Value; $na = [int]$m.Groups[3].Value
      $nb = [int]$m.Groups[4].Value; $rt = [int]$m.Groups[5].Value
      if ($na -eq 0 -and $nb -eq 1 -and $rt -eq 1) {
        Ok ("同组互斥：点 'rb' 后**下一帧** a={0}/b={1}（点击那一帧画在前面的 ra 还读旧组值 = a={2}，已写进诚实边界）" -f $na, $nb, $sa)
      } else { Bad "同组互斥不对：next_frame a=$na b=$nb rb_ret=$rt（期望 0/1/1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio reclickB b=(-?\d+)')
    if ($m.Success) {
      $b = [int]$m.Groups[1].Value
      if ($b -eq 1) { Ok "再点一次已选中的钮 ⇒ 保持选中（单选钮不是勾选框，不来回切）" }
      else { Bad "再点已选中的钮竟然取消了：b=$b（期望 1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio groups g1x=(-?\d+) g2y=(-?\d+) g1x_after=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $c = [int]$m.Groups[3].Value
      if ($a -eq 1 -and $b -eq 1 -and $c -eq 1) { Ok "不同组互不干扰：g1 的 x 与 g2 的 y 同时选中，再画仍是 1/1" }
      else { Bad "不同组互相顶掉了：g1x=$a g2y=$b g1x_after=$c（期望 1/1/1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio samegroup g1z=(-?\d+) g1x=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      if ($a -eq 1 -and $b -eq 0) { Ok "显式同名组互斥：同组两个标签只有后点的那个选中（g1z=1、g1x=0）" }
      else { Bad "同名组没互斥：g1z=$a g1x=$b（期望 1/0）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 radio namespaces defx=(-?\d+) grpx_y=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      if ($a -eq 1 -and $b -eq 1) { Ok "组名空间与控件名空间分开：默认组的标签 'x' 与组名 'x' 不互相顶掉" }
      else { Bad "组名/控件名撞了：defx=$a grpx_y=$b（期望 1/1）" }
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 snap n4_6=(-?\d+) n4_4=(-?\d+) n8_4=(-?\d+) n4_0=(-?\d+) n0_6=(-?\d+)')
    if ($m.Success) {
      $w = @((Snap-Space 6 4), (Snap-Space 4 4), (Snap-Space 4 8), (Snap-Space 0 4), (Snap-Space 6 0))
      $g = @(1..5 | ForEach-Object { [int]$m.Groups[$_].Value })
      if (($w[0] -eq $g[0]) -and ($w[1] -eq $g[1]) -and ($w[2] -eq $g[2]) -and ($w[3] -eq $g[3]) -and ($w[4] -eq $g[4])) {
        Ok ("gui_space_snap 现算：6→{0}(n4) 4→{1}(n4) 4→{2}(n8) 0→{3} 6→{4}(n0)" -f $w[0], $w[1], $w[2], $w[3], $w[4])
      } else { Bad ("gui_space_snap 与现算不符：样本 {0} vs 现算 {1}" -f ($g -join ','), ($w -join ',')) }
      $seen14.SNAP++
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 grid n=(\d+) pad=(-?\d+) spacing=(-?\d+)$')
    if ($m.Success) {
      $n = [int]$m.Groups[1].Value; $p = [int]$m.Groups[2].Value; $s = [int]$m.Groups[3].Value
      $wp = Snap-Space 6 $n; $ws = Snap-Space 4 $n
      if ($p -eq $wp -and $s -eq $ws) { Ok ("gui_space_grid(n={0})：pad 6→{1}、spacing 4→{2}（现算）" -f $n, $p, $s) }
      else { Bad ("gui_space_grid(n={0}) 不对：pad={1}（该 {2}）spacing={3}（该 {4}）" -f $n, $p, $wp, $s, $ws) }
      $seen14.GRID++
      $n14++
      continue
    }
    $m = [regex]::Match($l, '^ART14 grid n=0 pad=(-?\d+) spacing=(-?\d+) neg=(-?\d+),(-?\d+) fresh=(-?\d+),(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      $c = [int]$m.Groups[3].Value; $d = [int]$m.Groups[4].Value
      $e = [int]$m.Groups[5].Value; $f = [int]$m.Groups[6].Value
      if ($a -eq 6 -and $b -eq 4 -and $c -eq 6 -and $d -eq 4 -and $e -eq 6 -and $f -eq 4) {
        Ok "间距栅格的硬边界：n=0 / 负值一律不动 ＋ 新 ctx 仍是 pad 6 / spacing 4（**默认值一个字节没改**）"
      } else { Bad "间距默认值被动了：n0=$a,$b neg=$c,$d fresh=$e,$f（都要 6,4）" }
      $seen14.GRID++
      $n14++
      continue
    }
  }
  if ($seen14.SNAP -eq 1 -and $seen14.GRID -eq 3) {
    Ok ("账目齐：SNAP {0} 条 ／ GRID {1} 条（3 条 = n4/n8/n0）" -f $seen14.SNAP, $seen14.GRID)
  } else {
    Bad ("账目不全：SNAP {0}/1 ／ GRID {1}/3 ⇒ 有判据没在跑" -f $seen14.SNAP, $seen14.GRID)
  }
} else {
  Bad "没有 flgui14 的 dump（$df14）—— UI 美术契约没在跑"
}

# ---- 6. M4o（2026-09-28）**键盘焦点链契约**（语义判据，**外部裁判：期望值在这里现算**）----
# 为什么单列一段：样本 `flgui15` 自己已经断言过一遍（内部位掩码 25 位），这里换**另一门语言、另一套算式**
#   再判一次 —— 同"光标条契约 / M4m 输入灵敏度 / M4n UI 美术"三段的老口径：**判据的期望值不许只活在样本里**
#   （同族坑：基线会把旧值锁死）。
# 逐行读样本自己打出来的账（F15 / M4O），期望值全部在这儿现算：
#   · 场景的"可聚焦清单 + 顺序"在这里**独立写一遍**（$FOC* 三张表 = 样本里的坐标常量，**不是**从输出里抄的）；
#     画在两个可聚焦控件**中间**的不可聚焦控件（label "mid"、进度条 "P1"、只读文本域 "RO"）**不在表里**
#     ⇒ "不可聚焦被跳过"这条判据由表本身表达；
#   · 焦点序号一律**现算**（Tab ⇒ 序号 +1、Shift+Tab ⇒ -1、两端回绕），不问样本"它自己觉得对不对"。
Write-Output ""
Write-Output "----- M4o 键盘焦点链契约（外部裁判：PowerShell 现算）-----"
# 可聚焦控件的矩形（按库的**绘制顺序**：B1 → C1 → S1 → 可编辑文本域）
$FOCX = @(10, 10, 10, 10)
$FOCY = @(30, 80, 120, 160)
$FOCW = @(80, 100, 120, 140)
$FOCH = @(20, 14, 14, 14)
function Foc-RectOk([int]$i, [int]$x, [int]$y, [int]$w, [int]$h) {
  return (($x -eq $FOCX[$i]) -and ($y -eq $FOCY[$i]) -and ($w -eq $FOCW[$i]) -and ($h -eq $FOCH[$i]))
}
$df15 = Join-Path $work 'dump-flgui15-flint.txt'
if (Test-Path $df15) {
  $l15 = Get-Content $df15
  $n15 = 0
  $seen15 = @{ INIT = 0; TAB1 = 0; TAB2 = 0; TAB3 = 0; TAB4 = 0; WRF = 0; WRB = 0; BK1 = 0
               FF = 0; WB = 0; N1 = 0; N0 = 0; DANG = 0; CIN = 0; COUT = 0
               TF = 0; PF = 0; MOVE = 0; RAD = 0; RES = 0 }
  foreach ($l in $l15) {
    $m = [regex]::Match($l, '^F15 init idx=(-?\d+) cnt=(\d+) mark=(\d+) k15=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $cn = [int]$m.Groups[2].Value
      $mk = [int]$m.Groups[3].Value; $k15 = [int]$m.Groups[4].Value
      # 可聚焦清单 = 4（表里有 4 个）—— 与场景里"画了几个控件"无关，只数与可聚焦表对得上的那些
      if ($ix -eq -1 -and $cn -eq $FOCX.Count -and $mk -eq 0 -and $k15 -eq 0) {
        Ok ("初始：没有焦点（idx=-1）、可聚焦清单 = {0}、没有焦点 ⇒ kind16 = {1}（条）" -f $cn, $mk)
      } else { Bad ("初始状态不对：idx={0}（该 -1）cnt={1}（该 {2}）mark={3}（该 0）k15={4}（该 0）" -f $ix, $cn, $FOCX.Count, $mk, $k15) }
      $seen15.INIT++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 tab1 idx=(-?\d+) id_is_b1=(\d) mark=(\d+) rect=(-?\d+),(-?\d+),(-?\d+),(-?\d+) key=(-?\d+) len=(-?\d+) pend=(-?\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ib = [int]$m.Groups[2].Value; $mk = [int]$m.Groups[3].Value
      $rx = [int]$m.Groups[4].Value; $ry = [int]$m.Groups[5].Value
      $rw = [int]$m.Groups[6].Value; $rh = [int]$m.Groups[7].Value
      $ky = [int]$m.Groups[8].Value; $ln = [int]$m.Groups[9].Value; $pd = [int]$m.Groups[10].Value
      if ($ix -eq 0 -and $ib -eq 1 -and $mk -eq 1 -and (Foc-RectOk 0 $rx $ry $rw $rh) -and $ky -eq 0 -and $ln -eq 0 -and $pd -eq 0) {
        Ok "无焦点时第一下 Tab ⇒ 序号 0（B1）＋ 圈只有 1 条且 rect = 按钮整个矩形 ＋ Tab 被消费（key/文本/待打印都没动）"
      } else { Bad ("第一下 Tab 不对：idx={0} id_b1={1} mark={2} rect={3},{4},{5},{6}（该 {7},{8},{9},{10}）key={11} len={12} pend={13}" -f $ix, $ib, $mk, $rx, $ry, $rw, $rh, $FOCX[0], $FOCY[0], $FOCW[0], $FOCH[0], $ky, $ln, $pd) }
      $seen15.TAB1++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 tab2 idx=(-?\d+) id_is_c1=(\d) rect=(-?\d+),(-?\d+),(-?\d+),(-?\d+) mark=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ic = [int]$m.Groups[2].Value
      $rx = [int]$m.Groups[3].Value; $ry = [int]$m.Groups[4].Value
      $rw = [int]$m.Groups[5].Value; $rh = [int]$m.Groups[6].Value; $mk = [int]$m.Groups[7].Value
      if ($ix -eq 1 -and $ic -eq 1 -and $mk -eq 1 -and (Foc-RectOk 1 $rx $ry $rw $rh)) {
        Ok ("Tab 前进到序号 1（C1）＋ 圈换到它的矩形（{0},{1},{2},{3}）—— **跳过了夹在中间的 label**" -f $rx, $ry, $rw, $rh)
      } else { Bad ("Tab 第二格不对：idx={0}（该 1）id_c1={1} mark={2} rect={3},{4},{5},{6}（该 {7},{8},{9},{10}）" -f $ix, $ic, $mk, $rx, $ry, $rw, $rh, $FOCX[1], $FOCY[1], $FOCW[1], $FOCH[1]) }
      $seen15.TAB2++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 tab3 idx=(-?\d+) id_is_s1=(\d) rect=(-?\d+),(-?\d+),(-?\d+),(-?\d+) mark=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $is = [int]$m.Groups[2].Value
      $rx = [int]$m.Groups[3].Value; $ry = [int]$m.Groups[4].Value
      $rw = [int]$m.Groups[5].Value; $rh = [int]$m.Groups[6].Value; $mk = [int]$m.Groups[7].Value
      if ($ix -eq 2 -and $is -eq 1 -and $mk -eq 1 -and (Foc-RectOk 2 $rx $ry $rw $rh)) {
        Ok ("Tab 前进到序号 2（滑块 S1）＋ 圈换到它的矩形 —— **跳过了夹在中间的进度条**")
      } else { Bad ("Tab 第三格不对：idx={0}（该 2）id_s1={1} mark={2} rect={3},{4},{5},{6}（该 {7},{8},{9},{10}）" -f $ix, $is, $mk, $rx, $ry, $rw, $rh, $FOCX[2], $FOCY[2], $FOCW[2], $FOCH[2]) }
      $seen15.TAB3++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 tab4 idx=(-?\d+) id_is_edit=(\d) edit_slot=(-?\d+) k15=(\d+) mark=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ie = [int]$m.Groups[2].Value; $es = [int]$m.Groups[3].Value
      $k15 = [int]$m.Groups[4].Value; $mk = [int]$m.Groups[5].Value
      # 文本域那半仍是 M4n 的老路：编辑焦点（edit_slot=0）⇒ 光标条 kind 15 ⇒ 渲染端画圈（不是 kind 16）
      if ($ix -eq 3 -and $ie -eq 1 -and $es -eq 0 -and $k15 -eq 1 -and $mk -eq 0) {
        Ok "Tab 第 4 格 = 可编辑文本域：链焦点 3 ＋ edit_slot=0 ＋ 出现 kind15（**文本域仍走 M4n 那条圈**，不是 kind16）"
      } else { Bad ("Tab 第 4 格不对：idx={0}（该 3）id_edit={1} edit_slot={2}（该 0）k15={3}（该 1）mark={4}（该 0）" -f $ix, $ie, $es, $k15, $mk) }
      $seen15.TAB4++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 wrapfwd idx=(-?\d+) id_is_b1=(\d) edit_slot=(-?\d+) mark=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ib = [int]$m.Groups[2].Value
      $es = [int]$m.Groups[3].Value; $mk = [int]$m.Groups[4].Value
      # 现算回绕：(3 + 1) % 4 = 0
      $want = (3 + 1) % $FOCX.Count
      if ($ix -eq $want -and $ib -eq 1 -and $es -eq -1 -and $mk -eq 1) {
        Ok ("末尾回绕：序号 3 再 Tab ⇒ {0}（现算 (3+1)%{1}）＋ 编辑焦点收回 ＋ 圈跟着回第 0 项" -f $ix, $FOCX.Count)
      } else { Bad ("末尾回绕不对：idx={0}（该 {1}）id_b1={2} edit_slot={3}（该 -1）mark={4}" -f $ix, $want, $ib, $es, $mk) }
      $seen15.WRF++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 wrapback idx=(-?\d+) id_is_edit=(\d) edit_slot=(-?\d+) k15=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ie = [int]$m.Groups[2].Value
      $es = [int]$m.Groups[3].Value; $k15 = [int]$m.Groups[4].Value
      # 现算反向回绕：(0 - 1 + 4) % 4 = 3
      $want = ((0 - 1) + $FOCX.Count) % $FOCX.Count
      if ($ix -eq $want -and $ie -eq 1 -and $es -eq 0 -and $k15 -eq 1) {
        Ok ("开头反向回绕：序号 0 上 Shift+Tab ⇒ {0}（现算 (0-1+{1})%{1}）＋ 编辑焦点跟上" -f $ix, $FOCX.Count)
      } else { Bad ("反向回绕不对：idx={0}（该 {1}）id_edit={2} edit_slot={3}（该 0）k15={4}" -f $ix, $want, $ie, $es, $k15) }
      $seen15.WRB++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 back1 idx=(-?\d+) id_is_s1=(\d) edit_slot=(-?\d+) mark=(\d+) rect=(-?\d+),(-?\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $is = [int]$m.Groups[2].Value; $es = [int]$m.Groups[3].Value
      $mk = [int]$m.Groups[4].Value; $rx = [int]$m.Groups[5].Value; $ry = [int]$m.Groups[6].Value
      if ($ix -eq 2 -and $is -eq 1 -and $es -eq -1 -and $mk -eq 1 -and $rx -eq $FOCX[2] -and $ry -eq $FOCY[2]) {
        Ok "Shift+Tab 后退一格：序号 3 ⇒ 2（滑块）＋ 编辑焦点收回 ＋ 圈换到滑块矩形"
      } else { Bad ("反向后退不对：idx={0}（该 2）id_s1={1} edit_slot={2}（该 -1）mark={3} rect={4},{5}（该 {6},{7}）" -f $ix, $is, $es, $mk, $rx, $ry, $FOCX[2], $FOCY[2]) }
      $seen15.BK1++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 freshfwd idx=(-?\d+) id_is_b1=(\d) mark=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ib = [int]$m.Groups[2].Value; $mk = [int]$m.Groups[3].Value
      if ($ix -eq 0 -and $ib -eq 1 -and $mk -eq 1) {
        Ok "全新 ctx 的**第一帧**正向 Tab ⇒ 序号 0（不依赖上一帧的清单数）"
      } else { Bad ("首帧正向 Tab 不对：idx={0}（该 0）id_b1={1} mark={2}" -f $ix, $ib, $mk) }
      $seen15.FF++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 warmback idx=(-?\d+) id_is_edit=(\d) cnt=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $ie = [int]$m.Groups[2].Value; $cn = [int]$m.Groups[3].Value
      # 现算：无焦点 + 反向 ⇒ 最后一个 = 清单数 - 1
      $want = $FOCX.Count - 1
      if ($ix -eq $want -and $ie -eq 1 -and $cn -eq $FOCX.Count) {
        Ok ("无焦点时反向 Shift+Tab ⇒ 最后一个（现算 cnt-1 = {0}）＋ 清单数 = {1}" -f $want, $cn)
      } else { Bad ("反向首个不对：idx={0}（该 {1}）id_edit={2} cnt={3}（该 {4}）" -f $ix, $want, $ie, $cn, $FOCX.Count) }
      $seen15.WB++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 n1 cnt=(\d+) idx_a=(-?\d+) idx_b=(-?\d+) mark=(\d+)')
    if ($m.Success) {
      $cn = [int]$m.Groups[1].Value; $a = [int]$m.Groups[2].Value
      $b = [int]$m.Groups[3].Value; $mk = [int]$m.Groups[4].Value
      if ($cn -eq 1 -and $a -eq 0 -and $b -eq 0 -and $mk -eq 1) {
        Ok "退化档 n=1：Tab 恒为序号 0、再 Tab 仍是 0（回绕不越界）"
      } else { Bad ("n=1 不对：cnt={0} idx_a={1} idx_b={2} mark={3}（都要 0/0）" -f $cn, $a, $b, $mk) }
      $seen15.N1++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 n0 cnt=(\d+) idx=(-?\d+) mark=(\d+)')
    if ($m.Success) {
      $cn = [int]$m.Groups[1].Value; $ix = [int]$m.Groups[2].Value; $mk = [int]$m.Groups[3].Value
      if ($cn -eq 0 -and $ix -eq -1 -and $mk -eq 0) {
        Ok "退化档 n=0：一个可聚焦控件都没有 ⇒ Tab 之后序号仍是 -1（**不许乱动**）、圈一条都没有"
      } else { Bad ("n=0 不对：cnt={0} idx={1}（该 -1）mark={2}（该 0）" -f $cn, $ix, $mk) }
      $seen15.N0++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 dangling idx_a=(-?\d+) idx_b=(-?\d+) idx_after=(-?\d+) id_after=(-?\d+)')
    if ($m.Success) {
      $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
      $c = [int]$m.Groups[3].Value; $d = [int]$m.Groups[4].Value
      if ($a -eq 0 -and $b -eq 1 -and $c -eq -1 -and $d -eq 0) {
        Ok "序号越界（2 个可聚焦 ⇒ 只剩 1 个）⇒ 帧末**收回焦点**（idx=-1、id=0，不留悬空焦点）"
      } else { Bad ("越界收尾不对：idx_a={0} idx_b={1} idx_after={2}（该 -1）id_after={3}（该 0）" -f $a, $b, $c, $d) }
      $seen15.DANG++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 clickin idx=(-?\d+) edit_slot=(-?\d+) id_is_edit=(\d)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $es = [int]$m.Groups[2].Value; $ie = [int]$m.Groups[3].Value
      if ($ix -eq 3 -and $es -eq 0 -and $ie -eq 1) {
        Ok "鼠标点进文本域 ⇒ 链焦点 = 序号 3 ＋ edit_slot=0 ＋ gui_focus_get 报得出它的 id"
      } else { Bad ("点进文本域不对：idx={0}（该 3）edit_slot={1}（该 0）id_edit={2}" -f $ix, $es, $ie) }
      $seen15.CIN++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 clickout idx=(-?\d+) edit_slot=(-?\d+) mark=(\d+) k15=(\d+)')
    if ($m.Success) {
      $ix = [int]$m.Groups[1].Value; $es = [int]$m.Groups[2].Value
      $mk = [int]$m.Groups[3].Value; $k15 = [int]$m.Groups[4].Value
      if ($ix -eq -1 -and $es -eq -1 -and $mk -eq 0 -and $k15 -eq 0) {
        Ok "鼠标点盒子外 ⇒ 链焦点与编辑焦点**一起**收回（idx=-1、edit_slot=-1、圈一条不剩）"
      } else { Bad ("点外面不对：idx={0}（该 -1）edit_slot={1}（该 -1）mark={2} k15={3}" -f $ix, $es, $mk, $k15) }
      $seen15.COUT++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 themefocus same=(-?\d+) poolsum_a=(-?\d+) poolsum_b=(-?\d+) mark=(\d+) idx=(-?\d+)')
    if ($m.Success) {
      $sm = [int]$m.Groups[1].Value; $pa = [int]$m.Groups[2].Value
      $pb = [int]$m.Groups[3].Value; $mk = [int]$m.Groups[4].Value; $ix = [int]$m.Groups[5].Value
      # "相同"必须**不是空表比空表**（POOLSUM 非 0）＋ 焦点确实在 B1 上（圈真画着）
      if ($sm -eq 1 -and $pa -eq $pb -and $pa -ne 0 -and $mk -eq 1 -and $ix -eq 0) {
        Ok ("theme_focus 0/非0：命令表逐字段相同 ＋ POOLSUM 不动（且非 0 = {0}，不是空表比空表）" -f $pa)
      } else { Bad ("theme_focus 不改命令流不对：same={0} pool_a={1} pool_b={2}（都要非 0 且相等）mark={3} idx={4}" -f $sm, $pa, $pb, $mk, $ix) }
      $seen15.TF++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 poolfocus k0=(-?\d+) k1=(-?\d+) k2=(-?\d+) k3=(-?\d+) key=(-?\d+)')
    if ($m.Success) {
      $k0 = [int]$m.Groups[1].Value; $k1 = [int]$m.Groups[2].Value
      $k2 = [int]$m.Groups[3].Value; $k3 = [int]$m.Groups[4].Value
      if ($k0 -eq 0 -and $k1 -eq 1 -and $k2 -eq $FOCX.Count -and $k3 -ne 0) {
        Ok ("焦点态住池 k=1/k=2/k=3（序号+1 / 清单数 / 焦点 id），**k=0 恒 0** ⇒ POOLSUM 零扰动")
      } else { Bad ("焦点池字段不对：k0={0}（该 0）k1={1}（该 1）k2={2}（该 {3}）k3={4}（该非 0）" -f $k0, $k1, $k2, $FOCX.Count, $k3) }
      $seen15.PF++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 movealone mark_a=(\d+) y_a=(-?\d+) mark_b=(\d+) y_b=(-?\d+) y_c=(-?\d+) mark_c=(\d+)')
    if ($m.Success) {
      $ma = [int]$m.Groups[1].Value; $ya = [int]$m.Groups[2].Value
      $mb = [int]$m.Groups[3].Value; $yb = [int]$m.Groups[4].Value
      $yc = [int]$m.Groups[5].Value; $mc = [int]$m.Groups[6].Value
      # 停一帧圈不动（仍 1 条、仍在 B1）⇒ Tab 之后**旧控件不再发** kind16（同帧仍只有 1 条，y 换到 C1）
      if ($ma -eq 1 -and $ya -eq $FOCY[0] -and $mb -eq 1 -and $yb -eq $FOCY[0] -and $mc -eq 1 -and $yc -eq $FOCY[1]) {
        Ok "焦点圈只画在焦点那一项：停一帧不动，Tab 之后旧项不再发 kind16（同帧仍 1 条、rect 已换到 C1）"
      } else { Bad ("圈的独占性不对：mark_a={0} y_a={1} mark_b={2} y_b={3} y_c={4}（该 {5}）mark_c={6}" -f $ma, $ya, $mb, $yb, $yc, $FOCY[1], $mc) }
      $seen15.MOVE++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^F15 radio cnt=(\d+) first_is_ra=(\d) rect=(-?\d+),(-?\d+),(-?\d+),(-?\d+)')
    if ($m.Success) {
      $cn = [int]$m.Groups[1].Value; $fr = [int]$m.Groups[2].Value
      $rx = [int]$m.Groups[3].Value; $ry = [int]$m.Groups[4].Value
      $rw = [int]$m.Groups[5].Value; $rh = [int]$m.Groups[6].Value
      # radio 场景的可聚焦表 = RA(10,10,80,16) / RB(100,10,80,16) / B1(10,40,80,20) —— 这里**现写**出来
      if ($cn -eq 3 -and $fr -eq 1 -and $rx -eq 10 -and $ry -eq 10 -and $rw -eq 80 -and $rh -eq 16) {
        Ok "单选钮也在焦点链里：radio×2 + button ⇒ 清单 3、第一下落在**先画的**那个钮上（绘制顺序，不是 id 顺序）"
      } else { Bad ("单选钮焦点链不对：cnt={0}（该 3）first_is_ra={1} rect={2},{3},{4},{5}（该 10,10,80,16）" -f $cn, $fr, $rx, $ry, $rw, $rh) }
      $seen15.RAD++; $n15++
      continue
    }
    $m = [regex]::Match($l, '^M4O res=(-?\d+) want=(-?\d+)')
    if ($m.Success) {
      $r = [int]$m.Groups[1].Value; $w = [int]$m.Groups[2].Value
      # 现算：25 位全亮（样本内部位掩码的总账 —— 这一行只做"账目齐"的哨兵）
      $wantMask = [int]([Math]::Pow(2, 25) - 1)
      if ($r -eq $w -and $w -eq $wantMask) { Ok ("样本内部位掩码全亮：res={0}（= 2^25-1）" -f $r) }
      else { Bad ("样本位掩码不满：res={0} want={1}（该 {2}）" -f $r, $w, $wantMask) }
      $seen15.RES++; $n15++
      continue
    }
  }
  $need15 = @('INIT','TAB1','TAB2','TAB3','TAB4','WRF','WRB','BK1','FF','WB','N1','N0','DANG','CIN','COUT','TF','PF','MOVE','RAD','RES')
  $miss15 = @()
  foreach ($k in $need15) { if ($seen15[$k] -ne 1) { $miss15 += ("$k={0}" -f $seen15[$k]) } }
  if ($miss15.Count -eq 0) {
    Ok ("账目齐：{0} 组焦点链判据全部各出现 1 次（逐条都在跑）" -f $need15.Count)
  } else {
    Bad ("账目不全（有判据没在跑）：" + ($miss15 -join ' '))
  }
} else {
  Bad "没有 flgui15 的 dump（$df15）—— 键盘焦点链契约没在跑"
}

# ---- 7. M4p（2026-09-28）**焦点可见性契约**（语义判据，**外部裁判：期望值在这里现算**）----
# 为什么单列一段：样本 `flgui16` 自己已经断言过一遍（内部位掩码 15 位），这里换**另一门语言、另一套算式**
#   再判一次 —— 同"光标条 / M4m / M4n / M4o"四段的老口径：**判据的期望值不许只活在样本里**。
# ⚠️ 本刀第一版样本栽过的坑（必须记）：**只判"我自己按几何算出来的可见数"是自证** —— 拿改前的库跑
#   同一份样本照样 32767。所以这里把**库自己登记的个数**（报告行里的 `kbd`）与几何期望**对拉**：
#   `kbd` 才是被测对象（库到底登记了几个），几何期望是裁判（这个视口下**应该**有几个可见）。
#   "改前会红"的取证 = **隔离老库**实跑（`tmp\m4p\oldlab\`：老 lib ＋ 本样本）：`exit 4102`（`kbd=6`）。
# 几何期望**在这里独立重写一遍**（不抄样本里的常量）：视口 (6,6) 宽 120；6 个按钮 28x20、间距 4
#   ⇒ 第 i 个控件的 y = 6 + 24i（内容高 144）；"露够一半" = 相交高 x 2 >= 20。
Write-Output ""
Write-Output "----- M4p 焦点可见性契约（外部裁判：PowerShell 现算）-----"

# 一个场景的账：vh = 视口高、Off = 滚动偏移
function F16-Check {
  param([string]$Tag, [int]$Vh, [int]$Off, [string[]]$Lines)
  $vis = @()
  for ($i = 0; $i -lt 6; $i++) {
    $y0 = 6 + $i * 24 - $Off
    $y1 = $y0 + 20
    $t = $y0; if ($t -lt 6) { $t = 6 }
    $b = $y1; if ($b -gt (6 + $Vh)) { $b = 6 + $Vh }
    $hh = $b - $t
    if ($hh -gt 0) { if ($hh * 2 -ge 20) { $vis += ,@($i, $y0) } }
  }
  $cnt = $vis.Count
  $line = $Lines | Where-Object { $_ -like "F16 $Tag *" } | Select-Object -First 1
  if (-not $line) { Bad "M4p：样本没有打出 F16 $Tag 的账（判据没在跑）"; return }
  $m = [regex]::Match($line, '^F16 \S+ vx=(-?\d+) vy=(-?\d+) vw=(-?\d+) vh=(-?\d+) off=(-?\d+) idx=(-?\d+) cnt=(-?\d+) kbd=(-?\d+) nvis=(-?\d+) mark=(-?\d+) my=(-?\d+) mh=(-?\d+)')
  if (-not $m.Success) { Bad "M4p：F16 $Tag 这行解析不了：$line"; return }
  $gvx = [int]$m.Groups[1].Value; $gvy = [int]$m.Groups[2].Value
  $gvw = [int]$m.Groups[3].Value; $gvh = [int]$m.Groups[4].Value
  $goff = [int]$m.Groups[5].Value; $gidx = [int]$m.Groups[6].Value
  $gcnt = [int]$m.Groups[7].Value; $gkbd = [int]$m.Groups[8].Value
  $gnvis = [int]$m.Groups[9].Value; $gmark = [int]$m.Groups[10].Value
  $gmy = [int]$m.Groups[11].Value; $gmh = [int]$m.Groups[12].Value
  $ok = $true
  $why = @()
  if ($gvx -ne 6 -or $gvy -ne 6 -or $gvw -ne 120 -or $gvh -ne $Vh) { $ok = $false; $why += "视口读成 $gvx,$gvy,$gvw,$gvh（该 6,6,120,$Vh）" }
  if ($goff -ne $Off) { $ok = $false; $why += "偏移读成 $goff（该 $Off）" }
  # ① **库自己登记的个数** = 几何可见个数（本刀的核心判据）
  if ($gkbd -ne $cnt) { $ok = $false; $why += "库登记 kbd=$gkbd 不等于几何可见 $cnt" }
  if ($gnvis -ne $cnt) { $ok = $false; $why += "样本自算 nvis=$gnvis 不等于 $cnt" }
  # ② 上一帧清单数（池 k=2）也必须是可见数
  if ($gcnt -ne $cnt) { $ok = $false; $why += "池 k=2 清单 $gcnt 不等于 $cnt" }
  # ③ 焦点序号必须落在可见集合里（或 -1）
  if ($gidx -ge $cnt) { $ok = $false; $why += "焦点序号 $gidx 越出可见集合 0..$($cnt-1)" }
  # ④ 有焦点 ⇒ 必须恰好一条圈，且矩形 = 可见集合里第 idx 个控件
  if ($gidx -ge 0) {
    if ($gmark -ne 1) { $ok = $false; $why += "有焦点却发了 $gmark 条 kind16（该 1）" }
    else {
      $pi = $vis[$gidx][0]
      if ($gmy -ne $vis[$gidx][1]) { $ok = $false; $why += "圈 y=$gmy 不等于第 $($gidx) 个可见控件（控件#$pi，y=$($vis[$gidx][1])）" }
      if ($gmh -ne 20) { $ok = $false; $why += "圈高 $gmh（该 20）" }
    }
  } else {
    if ($gmark -ne 0) { $ok = $false; $why += "无焦点却发了 $gmark 条 kind16（该 0）" }
  }
  if ($ok) { Ok ("M4p {0}（vh={1} 偏移 {2}）：库登记 kbd={3} = 几何可见 {3}；池清单 {4}；焦点 idx={5}；圈 rect=(6,{6},28,20)" -f $Tag, $Vh, $Off, $cnt, $gcnt, $gidx, $gmy) }
  else { Bad ("M4p {0} 不成立：" -f $Tag) + ($why -join ' / ') | ForEach-Object { Bad $_ } }
}
# 可见集合大小单独钉一遍（免得上面那条只对了个数）
function F16-Set {
  param([string]$Tag, [int]$Want, [string[]]$Lines)
  $line = $Lines | Where-Object { $_ -like "F16 $Tag *" } | Select-Object -First 1
  if (-not $line) { Bad "M4p：样本没有打出 F16 $Tag 的账"; return }
  $m = [regex]::Match($line, 'nvis=(-?\d+)')
  $gnvis = [int]$m.Groups[1].Value
  if ($gnvis -eq $Want) { Ok ("M4p {0} 可见集合大小 = {1}（PowerShell 现算）" -f $Tag, $Want) }
  else { Bad ("M4p {0} 可见集合大小 = {1}（该 {2}）" -f $Tag, $gnvis, $Want) }
}
$df16 = Join-Path $work 'dump-flgui16-flint.txt'
if (Test-Path $df16) {
  $l16 = Get-Content $df16
  $seen16 = @{}
  foreach ($t in @('A0','A1','A2','A3','A5','A6','A7','B0','B1','B2','C0','C1','C2','D0','D1','D2','D3','E1','E2','P','RES')) { $seen16[$t] = 0 }
  # 场景 A：vh=44 偏移 0 ⇒ 可见 = {B0(y=6), B1(y=30)}
  F16-Set 'A0' 2 $l16; $seen16.A0++
  F16-Check 'A0' 44 0 $l16
  F16-Check 'A1' 44 0 $l16; $seen16.A1++
  F16-Check 'A2' 44 0 $l16; $seen16.A2++
  F16-Check 'A3' 44 0 $l16; $seen16.A3++
  F16-Check 'A7' 44 0 $l16; $seen16.A7++
  # 场景 B：vh=44 偏移 96 ⇒ 可见 = {B4(y=6), B5(y=30)}（B3 在 y=-18，全在外）
  F16-Set 'B0' 2 $l16; $seen16.B0++
  F16-Check 'B0' 44 96 $l16
  F16-Check 'B1' 44 96 $l16; $seen16.B1++
  F16-Check 'B2' 44 96 $l16; $seen16.B2++
  # 场景 C：vh=10 偏移 0 ⇒ 可见 = {B0}（只露 6..16 的 10px = 一半）
  F16-Set 'C0' 1 $l16; $seen16.C0++
  F16-Check 'C0' 10 0 $l16
  F16-Check 'C1' 10 0 $l16; $seen16.C1++
  F16-Check 'C2' 10 0 $l16; $seen16.C2++
  # 场景 D：vh=8 ⇒ **全在视口外**（B0 只露 8/20 < 一半）⇒ 可见 = 0、焦点收回 -1、无圈
  F16-Set 'D0' 0 $l16; $seen16.D0++
  F16-Check 'D0' 8 0 $l16
  F16-Check 'D1' 8 0 $l16; $seen16.D1++
  F16-Check 'D2' 8 0 $l16; $seen16.D2++
  F16-Check 'D3' 8 0 $l16; $seen16.D3++
  # 场景 A 恢复：vh=44 偏移 0（中间空等两帧）
  F16-Check 'E1' 44 0 $l16; $seen16.E1++
  F16-Check 'E2' 44 0 $l16; $seen16.E2++
  # 命令表只出现可见控件 ＋ 库登记数 = 可见数
  $m = [regex]::Match(($l16 | Where-Object { $_ -like 'F16 A5 *' } | Select-Object -First 1), '^F16 A5 only_visible_cmds=(-?\d+) ncmd=(-?\d+) kbd_ok=(-?\d+)')
  if ($m.Success) {
    if ([int]$m.Groups[1].Value -eq 1 -and [int]$m.Groups[3].Value -eq 1) {
      Ok ("M4p A5：命令表里只有可见按钮 ＋ 库登记数 = 可见数（ncmd={0}）" -f [int]$m.Groups[2].Value)
    } else { Bad ("M4p A5 不对：only_visible_cmds={0} kbd_ok={1}（都该 1）" -f $m.Groups[1].Value, $m.Groups[3].Value) }
  } else { Bad "M4p：没有 F16 A5 的行" }
  $seen16.A5++
  # 一圈只访问可见项：序号序列 0,1,0,1
  $m = [regex]::Match(($l16 | Where-Object { $_ -like 'F16 A6 *' } | Select-Object -First 1), '^F16 A6 seqok=(-?\d+) idx=(-?\d+) nvis=(-?\d+) kbd=(-?\d+)')
  if ($m.Success) {
    if ([int]$m.Groups[1].Value -eq 1 -and [int]$m.Groups[3].Value -eq 2 -and [int]$m.Groups[4].Value -eq 2) {
      Ok "M4p A6：连按 4 次 Tab 的序号序列 = 0,1,0,1（现算 k mod 2）＝只访问可见项"
    } else { Bad ("M4p A6 不对：seqok={0} nvis={1} kbd={2}" -f $m.Groups[1].Value, $m.Groups[3].Value, $m.Groups[4].Value) }
  } else { Bad "M4p：没有 F16 A6 的行" }
  $seen16.A6++
  # 池账：k=0 恒 0（POOLSUM 零扰动）
  $m = [regex]::Match(($l16 | Where-Object { $_ -like 'F16 P *' } | Select-Object -First 1), '^F16 P k0=(-?\d+) k1=(-?\d+) k2=(-?\d+) k3=(-?\d+) psum=(-?\d+) key=(-?\d+)')
  if ($m.Success) {
    if ([int]$m.Groups[1].Value -eq 0) { Ok "M4p P：焦点态只住池 k=1/k=2/k=3，**k=0 恒 0**（POOLSUM 零扰动）" }
    else { Bad ("M4p P：k=0 = {0}（该 0）" -f $m.Groups[1].Value) }
  } else { Bad "M4p：没有 F16 P 的行" }
  $seen16.P++
  # 样本内部位掩码：15 位全亮 = 32767
  $m = [regex]::Match(($l16 | Where-Object { $_ -like 'M4P res=*' } | Select-Object -First 1), '^M4P res=(-?\d+) want=(-?\d+)')
  if ($m.Success) {
    $wantMask = [int]([Math]::Pow(2, 15) - 1)
    if ([int]$m.Groups[1].Value -eq $wantMask -and [int]$m.Groups[2].Value -eq $wantMask) {
      Ok ("M4p：样本内部位掩码全亮：res={0}（= 2^15-1）" -f $wantMask)
    } else { Bad ("M4p：样本位掩码不满：res={0} want={1}（该 {2}）" -f $m.Groups[1].Value, $m.Groups[2].Value, $wantMask) }
  } else { Bad "M4p：没有 M4P res= 的行" }
  $seen16.RES++
  $miss16 = @()
  foreach ($k in $seen16.Keys) { if ($seen16[$k] -eq 0) { $miss16 += $k } }
  if ($miss16.Count -eq 0) { Ok ("账目齐：M4p 的 {0} 组判据逐帧都读到了（每帧各 1 次）" -f $seen16.Count) }
  else { Bad ("M4p 账目不全（有帧没读到）：" + ($miss16 -join ' ')) }
} else {
  Bad "没有 flgui16 的 dump（$df16）—— 焦点可见性契约没在跑"
}

# ---- 8. M4q（2026-09-28）**多字体档契约**（语义判据，**外部裁判：期望值在这里现算**）----
# 为什么单列一段：样本 `flgui17` 自己已经断言过一遍（内部位掩码 22 位），这里换**另一门语言、另一套算式**
#   再判一次 —— 与第 3 段（光标契约）／第 4~7 段同一条口径：**判据的期望值不许只活在样本里**。
# 两半（都必需）：
#   ① **无头那半**：逐行读 `flgui17` 的 dump（F17 …），按 `lib\FLGUI.md` 的契约**在 PowerShell 里重算**
#      栈深 / 载荷序列 / err 位 / 光标 = 文本 x ＋ n × 当前档尺子（三档尺子 9 / 8 / 5：9 与 5 是样本注入的
#      "实测宽"，8 是无头默认的基准 `gui_char_adv`）。
#   ② **真 GDI 那半**：跑 `tmp\m4q\font-tier-probe.fl`（离屏、**不建窗**），把它的 `CV … ext=… delta=…`
#      与**本脚本自己用 GDI 量的**三档字宽对拉；期望 px 由**政策**现算（基准 14 ⇒ 18 / 14 / 12，过 DPI），
#      不看库的任何自报值（同族坑：判据里出现被测对象自己算出来的量就是自证）。
Write-Output ""
Write-Output "----- M4q 多字体档契约（外部裁判：PowerShell 现算 ＋ GDI 现量）-----"

$m4qPass = 0
$m4qFail = 0
function Chk17($cond, $msg) {
  if ($cond) { Write-Output "  OK   $msg"; $script:pass++; $script:m4qPass++ }
  else { Write-Output "  FAIL $msg"; $script:fail++; $script:m4qFail++ }
}
function LineOf($lines, [string]$pat) {
  return (@($lines | Where-Object { [string]$_ -like $pat } | Select-Object -First 1))
}
function F17Num([string]$line, [string]$key) {
  $m = [regex]::Match([string]$line, [regex]::Escape($key) + '=(-?\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return -999999
}
function F17Seq([string]$line) {
  $s = @()
  foreach ($k in @('p0', 'p1', 'p2', 'p3', 'p4', 'p5')) { $s += (F17Num $line $k) }
  return $s
}

$df17 = Join-Path $work 'dump-flgui17-flint.txt'
if (-not (Test-Path $df17)) {
  Chk17 $false "没有 flgui17 的 dump（$df17）—— 多字体档契约没在跑"
} else {
  $l17 = @(Get-Content $df17)
  $A0 = LineOf $l17 'F17 A0 *'
  $A1 = LineOf $l17 'F17 A1 *'
  $B0 = LineOf $l17 'F17 B0 *'
  $B1 = LineOf $l17 'F17 B1 *'
  $C0 = LineOf $l17 'F17 C0 *'
  $C1 = LineOf $l17 'F17 C1 *'
  $D0 = LineOf $l17 'F17 D0 *'
  $E0 = LineOf $l17 'F17 E0 *'
  $E1 = LineOf $l17 'F17 E1 *'
  $E2 = LineOf $l17 'F17 E2 *'
  $F0 = LineOf $l17 'F17 F0 *'
  $G0 = LineOf $l17 'F17 G0 *'
  $H0 = LineOf $l17 'F17 H0 *'
  $I0 = LineOf $l17 'F17 I0 *'
  $J0 = LineOf $l17 'F17 J0 *'
  $l17 | ForEach-Object { Write-Output "       $_" }

  # ① 不压档：一条状态命令都不发 ＋ 基准尺子 = 8
  $tx = F17Num $A0 'tx'; $tn = F17Num $A0 'tn'; $cx = F17Num $A0 'cx'
  Chk17 (($tx -ge 0) -and ($tn -eq 3)) "A0 抓到「文本＋光标」配对：tx=$tx tn=$tn（样本文本恒 3 字节）"
  Chk17 (((F17Num $A0 'n22') -eq 0) -and ((F17Num $A0 'n23') -eq 0) -and ((F17Num $A0 'depth') -eq 0)) "A0 不压档：kind 22/23 各 0 条、栈深 0（不切档 ⇒ 一条状态命令都不发）"
  Chk17 ($cx -eq ($tx + $tn * 8)) "A0 基准尺子：光标 x=$cx = 文本 x=$tx ＋ $tn × 8（无头 gui_char_adv）"

  # ② 显式压基准档(1)＋弹：绘制类命令逐字段摘要与 ① 相同 ＋ POOLSUM 相同
  Chk17 (((F17Num $A1 'dig') -eq (F17Num $A0 'dig')) -and ((F17Num $A1 'n22') -eq 1) -and ((F17Num $A1 'n23') -eq 1) -and ((F17Num $A1 'p0') -eq 1) -and ((F17Num $A1 'p1') -eq 1)) "A1 压基准档＋弹：绘制摘要 = A0（$((F17Num $A0 'dig'))）＋ 两条状态命令、载荷 1/1"
  Chk17 ((F17Num $A1 'psum') -eq (F17Num $A0 'psum')) "A1 与 A0 的 POOLSUM 相同（$((F17Num $A0 'psum'))）：档态只住池 k=1/k=2/k=3，k=0 恒 0"

  # ③ 标题档尺子（池 k=2 = 9，样本注入）
  Chk17 ((F17Num $B0 'cx') -eq ((F17Num $B0 'tx') + (F17Num $B0 'tn') * 9)) "B0 标题档尺子：光标 = 文本 x ＋ $((F17Num $B0 'tn')) × 9（= 池 k=2 的实测宽，**不是** 8）"
  Chk17 (((F17Num $B1 'n22') -eq 1) -and ((F17Num $B1 'n23') -eq 0) -and ((F17Num $B1 'p0') -eq 0) -and ((F17Num $B1 'depth') -eq 1)) "B1 压了不弹：payload=0、栈深=1、没有出栈命令"

  # ④ 说明档尺子（池 k=3 = 5）＋ 栈顶换档
  Chk17 ((F17Num $C0 'cx') -eq ((F17Num $C0 'tx') + (F17Num $C0 'tn') * 5)) "C0 说明档尺子：光标 = 文本 x ＋ $((F17Num $C0 'tn')) × 5（= 池 k=3 的实测宽）"
  Chk17 (((F17Num $C1 'n22') -eq 1) -and ((F17Num $C1 'p0') -eq 2) -and ((F17Num $C1 'depth') -eq 1)) "C1 压说明档：payload=2、栈深=1"

  # ⑤ 嵌套三层 ＋ 逐个恢复（**载荷序列在 PowerShell 里按契约现算**）
  $want = @()
  $stk = New-Object System.Collections.ArrayList
  foreach ($t in @(0, 2, 1)) { [void]$stk.Add($t); $want += $t }
  while ($stk.Count -gt 0) {
    [void]$stk.RemoveAt($stk.Count - 1)
    if ($stk.Count -gt 0) { $want += [int]$stk[$stk.Count - 1] } else { $want += 1 }
  }
  $got = F17Seq $D0
  Chk17 (((($got -join ',') -eq ($want -join ','))) -and ((F17Num $D0 'n22') -eq 3) -and ((F17Num $D0 'n23') -eq 3) -and ((F17Num $D0 'depth') -eq 0)) "D0 嵌套三层：载荷序列 $($got -join ',') = 现算 $($want -join ',')（pop 恢复的是被压住的那一档，弹空回基准 1）"

  # ⑥ 错误记账（err 位：64 = 档号越界 ｜ 128 = 档栈越界）
  Chk17 (((F17Num $E0 'err') -eq 128) -and ((F17Num $E0 'n22') -eq 0)) "E0 空栈 pop：err=128 且**一条命令都不发**（返回基准 1）"
  Chk17 (((F17Num $E1 'err') -eq 64) -and ((F17Num $E1 'n22') -eq 1) -and ((F17Num $E1 'p0') -eq 1)) "E1 越界档 5：err=64、压进去的是基准档（payload=1）"
  Chk17 (((F17Num $E2 'err') -eq 64) -and ((F17Num $E2 'n22') -eq 1) -and ((F17Num $E2 'p0') -eq 1)) "E2 越界档 −1：err=64、payload=1（负档没漏成第 3 档）"
  Chk17 (((F17Num $F0 'err') -eq 128) -and ((F17Num $F0 'depth') -eq 8)) "F0 压满 8 级后第 9 次：err=128、栈深仍 = 8（只计数、不越写）"

  # ⑦ 每帧归零 ＋ 命令流形状 ＋ 没量到的档回落
  Chk17 (((F17Num $G0 'n22') -eq 0) -and ((F17Num $G0 'n23') -eq 0) -and ((F17Num $G0 'depth') -eq 0)) "G0 上一帧压了没弹 ⇒ 本帧 gui_begin 之后栈深 0（跨帧不串档）"
  Chk17 (((F17Num $H0 'n22') -eq 1) -and ((F17Num $H0 'n23') -eq 1) -and ((F17Num $H0 'p0') -eq 0) -and ((F17Num $H0 'p1') -eq 1)) "H0 命令流形状：压/弹各一条，载荷 = 该命令之后生效的档（0 然后回 1）"
  Chk17 ((F17Num $I0 'cx') -eq ((F17Num $I0 'tx') + (F17Num $I0 'tn') * 8)) "I0 该档没量到（池 k=2 = 0）⇒ 光标回落基准宽 8（不是 0、也不是别的档）"
  Chk17 (((F17Num $J0 'cx') -eq ((F17Num $J0 'tx') + (F17Num $J0 'tn') * 9)) -and ((F17Num $J0 'psum') -eq (F17Num $A0 'psum'))) "J0 池账：光标仍按标题档 9 ＋ POOLSUM 与不压档帧相同"

  # ⑧ 样本内部位掩码：22 位全亮 = 4194303
  $mres = [regex]::Match([string](LineOf $l17 'M4Q res=*'), 'M4Q res=(-?\d+) want=(-?\d+)')
  $wantMask = [int]([Math]::Pow(2, 22) - 1)
  if ($mres.Success) {
    Chk17 (([int]$mres.Groups[1].Value -eq $wantMask) -and ([int]$mres.Groups[2].Value -eq $wantMask)) "flgui17 内部位掩码全亮：res = $wantMask（= 2^22−1）"
  } else { Chk17 $false "flgui17 没有 M4Q res= 的行" }

  # ================= ② 真 GDI 那半：三档字号/字宽对账（外部裁判）=================
  $probeSrc = Join-Path $root 'tmp\m4q\font-tier-probe.fl'
  $probeExe = Join-Path $work 'font-tier-probe.exe'
  if (-not (Test-Path $probeSrc)) {
    Chk17 $false "找不到真 DC 量宽探针 $probeSrc"
  } else {
    Remove-Item $probeExe -ErrorAction SilentlyContinue
    & $flint $probeSrc -o $probeExe | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $probeExe)) {
      Chk17 $false "font-tier-probe.fl 编译失败（exit=$LASTEXITCODE）"
    } else {
      $pout = @(& $probeExe 2>&1)
      $pcode = $LASTEXITCODE
      $pout | ForEach-Object { Write-Output "       $_" }
      Chk17 ($pcode -eq 42) "font-tier-probe 退出码 $pcode（期望 42 = 探针自检全绿）"
      $basepx = 14
      $dl = @(4, 0, -2)
      $jext = @()
      $jadv = @()
      $jcy = @()
      $dpi = F17Num (LineOf $pout 'CV tier=1 *') 'dpi'
      for ($t = 0; $t -le 2; $t++) {
        $ln = LineOf $pout "CV tier=$t *"
        # 期望 px = **政策**现算（基准 ＋ 档偏移，过 DPI）；库用哪个 px 不看，只看它量出来的高度对不对
        $wantPx = [int][Math]::Floor((($basepx + $dl[$t]) * $dpi + 48) / 96)
        $ext = F17Num $ln 'ext'
        $adv = F17Num $ln 'adv'
        $reg = F17Num $ln 'reg'
        $dd = F17Num $ln 'delta'
        $cy = F17Num $ln 'cy'
        $ppx = F17Num $ln 'px'
        $jext += (Get-FontExt10 $wantPx 'Consolas')
        $jadv += (Get-FontAdvance $wantPx 'Consolas')
        $jcy += (Get-FontHeight $wantPx 'Consolas')
        Chk17 ($ppx -eq $wantPx) "tier=$t 政策算式两端一致：探针自算 px=$ppx = 本脚本现算 $wantPx（基准 $basepx ＋ $($dl[$t])，dpi=$dpi）"
        # **字号锐尺子**：GDI 文本高度 cy 与请求 px 一一对应（宽度按 2px 台阶量化，钉不死字号）
        Chk17 ($cy -eq $jcy[$t]) "tier=$t 字号：GDI 文本高度 cy=$cy = 本脚本按 px=$wantPx 现量 $($jcy[$t])"
        Chk17 ($ext -eq $jext[$t]) "tier=$t 字宽：GDI 的 10 字符宽 ext=$ext = 本脚本另一次 GDI 现量 $($jext[$t])"
        Chk17 (($adv -eq $jadv[$t]) -and ($reg -eq $adv) -and ($dd -eq 0)) "tier=$t 库登记字宽 reg=$reg = 单字符实测 adv=$adv（本脚本 $($jadv[$t])）＋ delta=$dd"
      }
      Chk17 (($jcy[0] -gt $jcy[1]) -and ($jcy[1] -gt $jcy[2])) "三档字号严格递减：外部现量文本高度 = $($jcy -join ' > ')（标题 > 正文 > 说明）"
      Chk17 (($jext[0] -gt $jext[1]) -and ($jext[1] -gt $jext[2])) "三档字宽严格递减：外部现量 10 字符宽 = $($jext -join ' > ')"

      $TB = LineOf $pout 'TPX tag=base *'; $T1 = LineOf $pout 'TPX tag=tier1 *'
      $T0 = LineOf $pout 'TPX tag=tier0 *'; $T2 = LineOf $pout 'TPX tag=tier2 *'; $TZ = LineOf $pout 'TPX tag=blank *'
      $TC = LineOf $pout 'TPX tag=clip *'
      $hB = F17Num $TB 'hash1'; $h1 = F17Num $T1 'hash1'; $h0 = F17Num $T0 'hash1'; $h2 = F17Num $T2 'hash1'
      Chk17 (($hB -eq $h1) -and ((F17Num $TB 'n22') -eq 0) -and ((F17Num $T1 'n22') -eq 1)) "压基准档(1)那一帧与完全不压那一帧**逐像素相同**（hash1=$hB），但那一帧确实发了 kind 22 ⇒ 压基准档是恒等变换"
      Chk17 (($h0 -ne $hB) -and ($h2 -ne $hB) -and ($h0 -ne $h2)) "三档渲染互不相同：标题 $h0 ≠ 基准 $hB ≠ 说明 $h2（字号真的画出来了，不是 dump 层面的数字）"
      $iw0 = F17Num $T0 'inkw'; $iw1 = F17Num $T1 'inkw'; $iw2 = F17Num $T2 'inkw'
      Chk17 (($iw0 -gt $iw1) -and ($iw1 -gt $iw2)) "文字墨迹宽严格递减：$iw0 > $iw1 > $iw2（像素级证据；dump 对字号完全失明）"
      Chk17 (([Math]::Abs($iw0 - $jext[0]) -le 2) -and ([Math]::Abs($iw1 - $jext[1]) -le 2) -and ([Math]::Abs($iw2 - $jext[2]) -le 2)) "墨迹宽 ≈ 外部量到的字串宽（各差 ≤ 2px）：$iw0/$iw1/$iw2 vs $($jext -join '/')"
      Chk17 ((F17Num $TZ 'inkw') -eq 0) "空场景墨迹 = 0（墨迹统计不是把底色/边框算进来的瞎数）"
      # **档 ＋ 裁剪出栈**：RestoreDC 会把 DC 的字体一起回滚 ⇒ 出栈之后必须重选当前档。
      #   裁剪区把整行字包住（裁剪本身不画东西、不动布局）⇒ 这一帧与 tier0 那一帧**应当逐像素相同**。
      Chk17 (((F17Num $TC 'hash1') -eq $h0) -and ((F17Num $TC 'inkw') -eq $iw0)) "压标题档 ＋ 裁剪压栈/出栈：出栈之后的文字仍是标题档（hash=$h0、墨迹宽 $iw0，与不裁剪那一帧逐像素相同）"
      Chk17 ((F17Num (LineOf $pout 'TPROBE *') 'ok') -eq 1) "探针自检 ok=1（$((LineOf $pout 'TPROBE *'))）"
      $gap = ($jadv[0] - $jadv[1]) * 3
      Write-Output ("  [改前口径必偏] 老库只有一个全局字宽槽：3 字符标题的光标 = (标题 adv {0} − 基准 adv {1}) × 3 = **{2}px** 偏 —— 单尺子量不到第二档" -f $jadv[0], $jadv[1], $gap)
    }
  }

  # ================= ③ "关就是真关"：老库（b610942）vs 新库整块表面逐像素比 =================
  $rcs = Join-Path $root 'tmp\m4q\run-font-classic.ps1'
  if (-not (Test-Path $rcs)) {
    Chk17 $false "找不到 $rcs（老库/新库逐像素取证脚本）"
  } else {
    $rout = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rcs 2>&1)
    $rtxt = ($rout -join "`n")
    $mrc = [regex]::Match($rtxt, 'font-classic pass (\d+) / fail (\d+)')
    if ($mrc.Success -and ([int]$mrc.Groups[2].Value -eq 0)) {
      Chk17 $true ("老库 git b610942 vs 新库：整块表面逐像素比 pass {0} / fail 0（三个场景 hash1＋hash2 全等）" -f $mrc.Groups[1].Value)
    } else {
      Chk17 $false "老库/新库逐像素比有失败 —— 见 tmp\m4q\run-font-classic.ps1 的输出"
      $rout | Select-Object -Last 8 | ForEach-Object { Write-Output "       $_" }
    }
  }

  Write-Output ("  M4q 契约小结：OK $m4qPass ｜ FAIL $m4qFail")
}

Write-Output ""
Write-Output "---------------------------------------------"
Write-Output ("  通过 {0} ｜ 失败 {1}" -f $pass, $fail)
Write-Output "  dump/产物留在 $work"
if ($fail -eq 0) { Write-Output "FLGUI 门：全绿"; exit 0 }
Write-Output "FLGUI 门：有失败"; exit 1
