# 导入预算.ps1 — FLINT 产物的「导入表预算」体检（只读；加 API 之前先数账）
#
# 为什么有它（2026-10-12 · 可用性路线图 P1）：
#   项目纪律写着「每加一批 API 前先 objdump -p <产物> 数条目」，但那是手工活；
#   而 pe.c 的 MAX_IMPORTS=96 / MAX_GROUPS=8 是**硬上限** —— 顶爆时"最重的那个 app 先炸"。
#   本脚本把这条纪律变成**可跑的仪器**，并把上限**从真值源读出来**（不写死）。
#
# 真值源 = src\pe.c 的 MAX_IMPORTS / MAX_GROUPS（同族纪律：守卫阈值必须与真值源同源）。
#
# ⚠️ 两条诚实边界（2026-10-12 首次实跑发现）：
#   ① **不是所有 .exe 都是 FLINT 产物**（例：PresentMon.exe 是 Intel 的、flint.exe 是 gcc 编的）
#      ⇒ 判据 = objdump 报的「There is an import table in <.节>」：**.text = FLINT 家族**，
#        其余（.idata / .rdata）算外来，**只列不计限**。
#   ② **boot 产物可能超过 96**（boot 侧上限与真 flint 不同；历史上实测 boot 产物 97 条 —— "boot 更宽"是纪律允许的方向）
#      ⇒ 对 FLINT 家族里 ≥96 的，本脚本报 `AT/OVER-LIMIT?`（**带问号 = 需人归因**，不当场判违规）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\导入预算.ps1
#   powershell ... -File tools\导入预算.ps1 -Exe apps\winpanel\winpanel.exe
#   powershell ... -File tools\导入预算.ps1 -Json
# 退出码：FLINT 家族全部在上限内侧 = 0；有触顶/超限（需归因）= 1；仪器自身出问题 = 2。

param(
  [string[]]$Exe = @(),
  [int]$WarnPercent = 90,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$tools = $PSScriptRoot
$root  = Split-Path $tools -Parent
$objdump = 'E:\mingw64\bin\objdump.exe'
if (-not (Test-Path -LiteralPath $objdump)) { Write-Host "!! 找不到 objdump: $objdump"; exit 2 }

# ---- 真值源：从 src\pe.c 读上限 ----
$peSrc = Join-Path $root 'src\pe.c'
if (-not (Test-Path -LiteralPath $peSrc)) { Write-Host "!! 找不到编译器源: $peSrc"; exit 2 }
$peText = Get-Content -LiteralPath $peSrc -Raw
$mImp = [regex]::Match($peText, 'MAX_IMPORTS\s+(\d+)')
$mGrp = [regex]::Match($peText, 'MAX_GROUPS\s+(\d+)')
if (-not $mImp.Success -or -not $mGrp.Success) { Write-Host '!! 没能从 pe.c 读出 MAX_IMPORTS / MAX_GROUPS'; exit 2 }
$maxImports = [int]$mImp.Groups[1].Value
$maxGroups  = [int]$mGrp.Groups[1].Value

# ---- 目标产物：显式给就用给的，否则扫 apps\*\*.exe ----
if ($Exe.Count -gt 0) {
  $targets = @()
  foreach ($p in $Exe) {
    $full = $p
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $root $p }
    if (Test-Path -LiteralPath $full) { $targets += (Get-Item -LiteralPath $full) }
    else { Write-Host "!! 跳过（不存在）: $p" }
  }
} else {
  $targets = @(Get-ChildItem -LiteralPath (Join-Path $root 'apps') -Recurse -Filter *.exe -File -ErrorAction SilentlyContinue)
}
if ($targets.Count -eq 0) { Write-Host '!! 没找到任何产物（apps 下没有 .exe？先编一个再来）'; exit 2 }

# ---- 逐件数账 ----
$rows = @()
$over = 0
foreach ($f in $targets) {
  $dump = & $objdump -p $f.FullName 2>&1

  $locLine = ($dump | Select-String -Pattern 'There is an import table in (\S+)' | Select-Object -First 1)
  $locSec  = ''
  if ($locLine) { $locSec = $locLine.Matches[0].Groups[1].Value }
  $isFlint = ($locSec -eq '.text')

  $dlls    = @($dump | Select-String -Pattern '^\s*DLL Name:\s*(.+?)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
  $imports = @($dump | Select-String -Pattern '^\s+[0-9a-fA-F]{8}\s+<none>\s+[0-9a-fA-F]{4}\s+\S+\s*$')

  $nImp = $imports.Count
  $nGrp = $dlls.Count
  $pct  = 0
  if ($maxImports -gt 0) { $pct = [int](100.0 * $nImp / $maxImports) }

  $state = 'OK'
  if (-not $isFlint) { $state = '外来' }
  elseif ($nImp -ge $maxImports -or $nGrp -ge $maxGroups) { $state = 'AT/OVER-LIMIT?'; $over++ }
  elseif ($pct -ge $WarnPercent) { $state = 'WARN' }

  $rows += [pscustomobject]@{
    Artifact = $f.FullName.Substring($root.Length + 1)
    Built    = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    Kind     = $(if ($isFlint) { 'FLINT' } else { '外来(' + $locSec + ')' })
    Groups   = "$nGrp/$maxGroups"
    Imports  = "$nImp/$maxImports"
    UsedPct  = $pct
    Headroom = ($maxImports - $nImp)
    State    = $state
    Modules  = ($dlls -join ' ')
  }
}

if ($Json) {
  [pscustomobject]@{
    MaxImports = $maxImports
    MaxGroups  = $maxGroups
    Objdump    = $objdump
    Source     = $peSrc
    NeedAttribution = $over
    Rows       = $rows
  } | ConvertTo-Json -Depth 5
} else {
  Write-Host ''
  Write-Host '===== FLINT 导入预算体检（上限真值源 = src\pe.c）====='
  Write-Host ("上限: 导入条目 {0} ｜ 导入模块 {1} ｜ 警示线 {2}%" -f $maxImports, $maxGroups, $WarnPercent)
  Write-Host ''
  foreach ($r in $rows) {
    Write-Host ("{0,-40} {1}  {2,-9} 模块 {3,-5} 条目 {4,-8} 用 {5,3}% 余 {6,3}  [{7}]" -f $r.Artifact, $r.Built, $r.Kind, $r.Groups, $r.Imports, $r.UsedPct, $r.Headroom, $r.State)
    Write-Host ("     {0}" -f $r.Modules)
  }
  Write-Host ''
  if ($over -gt 0) {
    Write-Host "导入预算：$over 件触顶/超限 ⇒ exit 1。**先归因再动手**：boot 产物比真 flint 宽是纪律允许的；真 flint 产物触顶则加 API 会当场编不过。"
  } else {
    Write-Host '导入预算：FLINT 家族全部在上限内侧。'
  }
}

if ($over -gt 0) { exit 1 }
exit 0
