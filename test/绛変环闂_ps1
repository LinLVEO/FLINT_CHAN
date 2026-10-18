# 等价门.ps1 —— 编译器**行为等价**门：同源两次独立编译 → 产物**逐字节相同**
# 立卡：T-20260919-010437（周期0「尺子与账本」）
#
# 为什么需要它：IR 小重构（把"变量访问"收敛成统一的 load/store 表示，为寄存器分配铺路）
#   这类重构的正确性判据不是"回归还能过"，而是更强的一条：**重构前后同一份源编译出的产物逐字节相同**
#   （行为不变的最硬形式；回归过了只能说明"测得的部分没变"，逐字节相同说明"发射的东西没变"）。
#   本门是那条判据的**工具化**：平时它是重构的护栏；**有意改发射形状的那一轮**（如 M4 寄存器分配），
#   它变成"变更清单"的生成器（`-UpdateFingerprint -Reason ...`，见 IR重构-设计与迁移计划.md §五）。
#
# 用法（任意目录）：
#   & .\等价门.ps1                 # 全样本两遍编译 + 逐字节对账
#   & .\等价门.ps1 -WriteBaseline  # 把"当前产物的逐样本 SHA256"存成指纹基线
#   & .\等价门.ps1 -UpdateFingerprint -Reason "M4 寄存器分配第一档"   # 有意改发射时更新指纹（必须写理由）
#   & .\等价门.ps1 -Only ctrl1,var1
#
# 判据（两层）：
#   ① **同一次运行的两次编译**（同一份源、两个不同输出目录）必须逐字节相同 ⇒ 编译器输出是**确定的**（无随机/无路径依赖）
#   ② 与**指纹基线**比：重构后指纹必须一致（除非该轮**有意**改变发射形状，那时更新基线并写明理由）
#
# ⚠️ 纪律：`-UpdateFingerprint` **必须**带 `-Reason`，且会把"哪些样本变了、旧→新指纹"写进基线文件头 ——
#   更新指纹 = 宣布"发射形状有意改变"，不写理由的更新一律**拒绝**（exit 2）；有不确定性样本时也拒绝更新（先修输出确定性）。
param(
  [switch]$WriteBaseline,
  [switch]$UpdateFingerprint,
  [string]$Reason = "",
  [string]$Only = "",
  [string]$Baseline = ""
)
$ErrorActionPreference = 'Continue'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PSScriptRoot) { throw '等价门: 拿不到脚本所在目录' }
$root    = Split-Path $PSScriptRoot -Parent
$samples = Join-Path $PSScriptRoot 'samples'
$flint   = Join-Path $root 'flint.exe'
$work    = Join-Path $PSScriptRoot 'tmp\eqgate'
if (-not $Baseline) { $Baseline = Join-Path $PSScriptRoot '等价门-指纹.txt' }

# 排除：开窗（编译能过、但本门只编译不运行，故其实无害；为一致性仍排除会挂住的样本）
$SKIP = @('demo1','m1_float','m2_float','ui_seg','ui_text','ui_widgets','stack1','stack2')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $work 'A') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $work 'B') -Force | Out-Null
# `../../lib/...` 这类 include 按字面路径拼（`..` 不规范化）⇒ 两个输出目录都要能解析到 lib
foreach ($d in 'A','B') {
  $link = Join-Path $work "$d\lib"
  cmd /c mklink /J "$link" "$root\lib" | Out-Null
}

$names = @()
if ($Only) { foreach ($x in ($Only -split ',')) { $t = $x.Trim(); if ($t) { $names += $t } } }
else { $names = @(Get-ChildItem $samples -Filter *.fl | Sort-Object Name | ForEach-Object { $_.BaseName }) }

$results = @()
$i = 0
foreach ($n in $names) {
  $i++
  Write-Progress -Activity '等价门' -Status "$n ($i/$($names.Count))" -PercentComplete (100 * $i / [Math]::Max(1, $names.Count))
  $src = Join-Path $samples "$n.fl"
  if (-not (Test-Path $src)) { continue }
  if ($SKIP -contains $n) { $results += [pscustomobject]@{ name=$n; verdict='SKIP'; sha='' }; continue }
  $a = Join-Path $work "A\$n.exe"
  $b = Join-Path $work "B\$n.exe"
  Remove-Item $a, $b -ErrorAction SilentlyContinue
  $o1 = (& $flint $src -o $a 2>&1 | Out-String)
  $c1 = $LASTEXITCODE
  $o2 = (& $flint $src -o $b 2>&1 | Out-String)
  $c2 = $LASTEXITCODE
  if ($c1 -ne 0 -or $c2 -ne 0 -or -not (Test-Path $a) -or -not (Test-Path $b)) {
    # 编译不过的样本（含故意报错的负例）不参与"逐字节"判据
    $results += [pscustomobject]@{ name=$n; verdict='COMPILE_FAIL'; sha='' }
    continue
  }
  $ha = (Get-FileHash $a -Algorithm SHA256).Hash
  $hb = (Get-FileHash $b -Algorithm SHA256).Hash
  $results += [pscustomobject]@{ name=$n; verdict=$(if ($ha -eq $hb) { 'DET' } else { 'NONDET' }); sha=$ha.Substring(0,16) }
}
Write-Progress -Activity '等价门' -Completed
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

$det = @($results | Where-Object { $_.verdict -eq 'DET' })
$non = @($results | Where-Object { $_.verdict -eq 'NONDET' })
$cf  = @($results | Where-Object { $_.verdict -eq 'COMPILE_FAIL' })
$sk  = @($results | Where-Object { $_.verdict -eq 'SKIP' })
Write-Host ("样本 {0}：确定性 {1} ｜ 不确定 {2} ｜ 编译不过 {3} ｜ 跳过 {4}" -f $results.Count, $det.Count, $non.Count, $cf.Count, $sk.Count)
if ($non.Count -gt 0) {
  Write-Host "  [!] 不确定性样本（同一份源两次编译产物不同 —— 这是真问题，编译器输出必须确定）："
  $non | ForEach-Object { Write-Host ("      " + $_.name) }
}

# ---- 读现有指纹基线（更新与比对两种用途共用）----
$base = @{}
$baseExists = Test-Path $Baseline
if ($baseExists) {
  foreach ($l in (Get-Content $Baseline -Encoding UTF8)) {
    if ($l -match '^([^\t#]+)\t([0-9A-Fa-f]+)$') { $base[$matches[1]] = $matches[2] }
  }
}

# ---- 有意改发射形状时更新指纹（§五 第 1 条：必须写理由，变更清单写进文件头）----
if ($UpdateFingerprint) {
  if (-not $Reason) {
    Write-Host '[!] -UpdateFingerprint 必须同时给 -Reason "<理由>" —— 更新指纹 = 宣布"发射形状有意改变"，不写理由一律拒绝'
    exit 2
  }
  if ($non.Count -gt 0) {
    Write-Host '[!] 有不确定性样本，拒绝更新指纹（输出必须确定 —— 先修它，再来更新基线）'
    exit 1
  }
  $changed = @(); $added = @()
  foreach ($r in ($det | Sort-Object name)) {
    if (-not $base.ContainsKey($r.name)) { $added += $r.name }
    elseif ($base[$r.name] -ne $r.sha) { $changed += ("{0}`t{1} -> {2}" -f $r.name, $base[$r.name], $r.sha) }
  }
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
  $hdr = @(
    "# 等价门指纹基线 —— 由 等价门.ps1 -WriteBaseline / -UpdateFingerprint 生成",
    "# 含义：每个样本「当前实现」编译出的产物 SHA256 前 16 位。**重构期本文件必须逐行不变**（否则说明发射形状变了）",
    ("# 生成时间：" + $stamp + " ｜ 确定性样本 " + $det.Count + " 个"),
    "#",
    "# ===== 变更记录（最近一次 -UpdateFingerprint）=====",
    ("# 时间：" + $stamp),
    ("# 理由：" + $Reason),
    ("# 变更样本 " + $changed.Count + " 个 ｜ 新增样本 " + $added.Count + " 个")
  )
  if ($changed.Count -gt 0) {
    $hdr += "# 变更清单（样本：旧前16 -> 新前16）"
    $hdr += @($changed | ForEach-Object { "#   " + $_ })
  }
  if ($added.Count -gt 0) { $hdr += ("# 新增：" + ($added -join ', ')) }
  $sig = @($det | Sort-Object name | ForEach-Object { "$($_.name)`t$($_.sha)" })
  ($hdr + $sig) | Out-File -FilePath $Baseline -Encoding UTF8
  Write-Host ""
  Write-Host ("指纹基线已更新：{0}（{1} 条；变更 {2} ／ 新增 {3}）" -f $Baseline, $sig.Count, $changed.Count, $added.Count)
  if ($changed.Count -gt 0) { $changed | Select-Object -First 20 | ForEach-Object { Write-Host ("        变更 " + $_) } }
  exit 0
}

if ($WriteBaseline) {
  $hdr = @(
    "# 等价门指纹基线 —— 由 等价门.ps1 -WriteBaseline 生成",
    "# 含义：每个样本「当前实现」编译出的产物 SHA256 前 16 位。**IR 重构后本文件必须逐行不变**（否则说明发射形状变了）",
    ("# 生成时间：" + (Get-Date -Format 'yyyy-MM-dd HH:mm') + " ｜ 确定性样本 " + $det.Count + " 个")
  )
  $sig = @($det | Sort-Object name | ForEach-Object { "$($_.name)`t$($_.sha)" })
  ($hdr + $sig) | Out-File -FilePath $Baseline -Encoding UTF8
  Write-Host ("指纹基线已写入：{0}（{1} 条）" -f $Baseline, $sig.Count)
  if ($non.Count -gt 0) { exit 1 } else { exit 0 }
}

if (-not $baseExists) { Write-Host ("[!] 没有指纹基线：先跑 -WriteBaseline（{0}）" -f $Baseline); exit 2 }
$mismatch = @(); $missing = @()
foreach ($r in $det) {
  if (-not $base.ContainsKey($r.name)) { $missing += $r.name; continue }
  if ($base[$r.name] -ne $r.sha) { $mismatch += ("{0} : 基线 {1} → 现在 {2}" -f $r.name, $base[$r.name], $r.sha) }
}
$gone = @($base.Keys | Where-Object { $_ -notin @($det.name) })
Write-Host ""
Write-Host "---- 与指纹基线比 ----"
if ($mismatch.Count -eq 0 -and $non.Count -eq 0) { Write-Host "  OK  产物逐字节与基线一致（发射形状未变）" }
if ($mismatch.Count -gt 0) {
  Write-Host ("  FAIL 产物形状变了 {0} 项：" -f $mismatch.Count)
  $mismatch | Select-Object -First 20 | ForEach-Object { Write-Host ("        " + $_) }
}
if ($missing.Count -gt 0) { Write-Host ("  新增样本 {0} 项（不在基线里）：{1}" -f $missing.Count, (($missing | Select-Object -First 8) -join ',')) }
if ($gone.Count -gt 0) { Write-Host ("  基线里有、本次没有 {0} 项（样本被删/改名？）" -f $gone.Count) }
if ($non.Count -gt 0) { Write-Host ("  FAIL 确定性破裂 {0} 项（同源两次编译产物不同）" -f $non.Count) }

# summary line for test\verify-all.ps1 (its parser reads the last line's trailing two numbers)
Write-Host ("等价门 确定性 {0} / 样本 {1}" -f $det.Count, $results.Count)
if ($mismatch.Count -gt 0 -or $non.Count -gt 0) { exit 1 }
exit 0
