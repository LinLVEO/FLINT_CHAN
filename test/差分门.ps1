# 差分门.ps1 —— 双编译器差分硬门（真 flint vs boot 自举编译器），**全样本**扫描
# 立卡：T-20260919-010437（周期0「尺子与账本」第 5 项）
#
# 为什么需要它（已具前科）：两台编译器各有一套语义，出过「真 flint 报错、boot 静默通过并产出
#   零扩展截断的指针」这类分岔（PROGRESS 2026-09-18 记录）。boot\verify.ps1 的 ⑥ 只覆盖 47 个
#   精选样本（$diff 列表），**全量样本没有对账**。本门把 test\samples 的 216 个样本全扫一遍，
#   对每个样本给出三态判定：一致 / 分岔 / boot 不支持，并**按原因聚类**。
#
# 用法（任意目录）：
#   & .\差分门.ps1                      # 跑一遍，与基线比：**新增分岔 = 红**
#   & .\差分门.ps1 -WriteBaseline       # 把当前结果写成基线（首次/确认收敛后再写）
#   & .\差分门.ps1 -Only ctrl1,comp1    # 只跑某几个样本（调试用）
#   & .\差分门.ps1 -TimeoutSec 20       # 单个产物运行超时（默认 15s，防开窗样本挂住整轮）
#   & .\差分门.ps1 -CompileTimeoutSec 20 # 单个**编译**超时（默认 20s；2026-09-20 新增——
#                                        #   编译期死循环原先会把整道门永久卡死，见 Invoke-Compile 注释）
#
# 判据（三条，缺一条这门就没意义）：
#   ① **同一份源**：样本原文件各拷一份到隔离目录，双方各自编译，谁也不改源、也不污染 test\samples
#   ② **比退出码 + stdout 逐字节**：退出码相同但输出不同也算分岔
#   ③ **超时即判"挂住"**：不自退的样本单列，既不算过也不算分岔
#
# ⚠️ boot 侧两个脾气（2026-09-19 实测，踩过）：
#   · **产物固定写在源文件旁边**（`a.fl` → `a.exe`），**不吃 -o** ⇒ 必须把源拷到隔离目录再编
#   · **没有目录分隔符的相对路径读不了**（`b1_emit.exe x.fl` 单独跑报 err=-2）⇒ **一律传绝对路径**
param(
  [switch]$WriteBaseline,
  [string]$Only = "",
  [int]$TimeoutSec = 15,
  [int]$CompileTimeoutSec = 20,
  [string]$Baseline = "",
  [int]$MaxShow = 40
)
$ErrorActionPreference = 'Continue'
# ⚠️ $PSScriptRoot 在 `powershell -Command "& script.ps1"` 这种调用下会是空串（实测 2026-09-19）
#    ⇒ 路径全部退化成"相对当前工作目录"，门会静默跑空/报假红。**必须兜底**。
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PSScriptRoot) { throw '差分门: 拿不到脚本所在目录（$PSScriptRoot 为空）' }
$root    = Split-Path $PSScriptRoot -Parent          # E:\FLINT-lab
$samples = Join-Path $PSScriptRoot 'samples'
$bootDir = Join-Path $root 'boot'
$flint   = Join-Path $root 'flint.exe'
$boot    = Join-Path $bootDir 'b1_emit.exe'
# ⚠️ 副本必须放在**与 test\samples 相同深度**的位置：样本里既有同目录 include，
#    也有 `include "../../lib/xxx.fl"` 这类**按相对深度**写的路径（2026-09-19 踩过：
#    放到 E:\FLINT-lab\tmp\ 下深度不够 ⇒ 23 个样本报"编译错误"的假红）。
#    test\tmp\diffgate\samples 与 test\samples 同深度 ⇒ 两种 include 都能解析。
$outDir  = Join-Path $PSScriptRoot 'tmp\diffgate'
if (-not $Baseline) { $Baseline = Join-Path $PSScriptRoot '差分门-baseline.txt' }

# 排除清单：开窗 / 依赖窗口环境 / 长跑 / stdout 口径特殊的样本（GUI 由 wx 门与浮窗自检覆盖）
$SKIP = @('demo1','m1_float','m2_float','ui_seg','ui_text','ui_widgets','stack1','stack2','console1','print1')
# 2026-10-18：**非确定样本** —— 退出码由时间/系统状态决定，双端先后跑必然不同（不是编译器分岔）。
#   sys_probe = Sleep(1000) 采两次 GetSystemTimes，退出码 = cpu%*100 + mem%（实测同一编译器两次跑
#   给 -655 / -355 等不同值）。对这类样本只比 stdout、不判退出码；**样本本身仍在门里跑**（编译+运行
#   仍要成功 ⇒ 产物能跑这件事照样被验）。
$NONDET = @('sys_probe')

# ⚠️ **整目录副本**：样本里有大量 `include "xxx_lib.fl"`（同目录相对路径）—— 只拷单个 .fl 到孤立目录
#    会让 include 全部失效 ⇒ 23 个样本报"编译错误"的**假红**（2026-09-19 踩过）。
#    正解 = 把 test\samples 整个拷一份，双方都在副本里编译/运行，收工再把副本删掉（原件一字不动）。
Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
$work = Join-Path $outDir 'samples'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item (Join-Path $samples '*') $work -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $outDir 'f') -Force | Out-Null
# ⚠️ 样本里有 `include "../../lib/xxx.fl"`（`..` 不做规范化，FLINT 按字面路径拼）
#    ⇒ 副本的**深度必须与原位置一致**，否则 include 必失败（实测报"include 文件不存在 …/samples/../../lib/…"）。
#    副本在 <test>\tmp\diffgate\samples ⇒ `..\..\lib` 落在 **<test>\tmp\lib** ⇒ junction 就建在那儿指回 <root>\lib。
$libLink = Join-Path $root 'test\tmp\lib'
if (-not (Test-Path $libLink)) {
  New-Item -ItemType Directory -Path (Split-Path $libLink -Parent) -Force | Out-Null
  cmd /c mklink /J "$libLink" "$root\lib" | Out-Null
}

# 2026-10-18（卡：**退出码盲区**）——本函数原先 `return @{ code = $p.ExitCode }`，而 PS 5.1 下
#   `Start-Process -PassThru` 的 `.ExitCode` 在这里**恒为空**（同下方 Invoke-Compile 注释记的坑；基线里
#   每行 `OK exit=` 那个空值就是它）。后果：`$rb.code -eq $rf.code` 变成 `$null -eq $null` **恒真** ⇒
#   纯退出码样本（str1/str2/str3/str6 这类 stdout 为空、分歧只在退出码的）分岔被整片吞掉，门照报 0/236。
#   （2026-10-18 标量槽 4 字节实验就是这个盲区被手动复跑抓到的：flint 乱值 vs boot=3/52/4/12。）
#   修法 = 与 Invoke-Compile **同一套哨兵行**：写临时 .bat，子进程跑完把 `%errorlevel%` 落到 `<stdout>.rc`，
#   再从那行取码；**不用 .ExitCode**。哨兵落在**独立文件**里 ⇒ stdout 口径一字不变（还是逐字节比原文件）。
#   ⚠️ 保留的语义：① 超时仍按 $sec 计时（WaitForExit 毫秒超时）；② 超时**杀整棵进程树** —— 现在子进程是
#   cmd 的孙子，只 Kill cmd 会漏下真挂住的产物继续吃 CPU、占着 stdout 文件（所以用 taskkill /T）；③ 拿不到
#   哨兵 = 当作挂住（与 Invoke-Compile 同口径），交给调用方的"重试 4 倍预算"再判一次。
function Run-WithTimeout([string]$exe, [string]$workdir, [int]$sec, [string]$stdoutPath) {
  $rcPath = $stdoutPath + '.rc'
  Remove-Item $rcPath -Force -ErrorAction SilentlyContinue
  $tag = [IO.Path]::GetFileNameWithoutExtension($stdoutPath)
  # ⚠️ 与 Invoke-Compile 同因：不把长命令塞进 `cmd /c`（Start-Process 的 ArgumentList 会被嵌套引号解析坏），
  #    改成写 .bat 再跑，引号原样进文件，行为确定。
  $line = ('"' + $exe + '" > "' + $stdoutPath + '" 2> "' + (Join-Path $workdir 'stderr.txt') + '"') +
          "`r`necho __RC=%errorlevel% > `"$rcPath`""
  $bat = Join-Path $work ("_run-$tag.bat")
  Set-Content -Path $bat -Value ("@echo off`r`n" + $line) -Encoding Ascii
  $p = Start-Process -FilePath $bat -WorkingDirectory $workdir -NoNewWindow -PassThru
  if (-not $p.WaitForExit($sec * 1000)) {
    try { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null } catch { }
    try { $p.Kill() } catch { }
    return @{ hang = $true; code = $null }
  }
  $ec = Get-SentinelRc $rcPath
  if ($null -eq $ec) { return @{ hang = $true; code = $null } }   # 无哨兵 = 没跑到终点，按挂住处理
  return @{ hang = $false; code = $ec }
}

# 2026-09-20（卡 T-20260920-001345 本轮实测暴露的真缺口）：
#   **编译步原先没有超时** —— 一条「编译期死循环」会把整道门永久卡死（实测 boot 在 arr2.fl 上
#   100% CPU 空转 14+ 分钟、无输出无产物，门外完全看不出发生了什么，同族于已入档的
#   「等进程必须带超时」）。这里给两个编译方向都加超时，并把「编译挂住」单列 verdict=HANG_COMPILE，
#   不再让它伪装成"门没跑完"。
# ⚠️⚠️ 取退出码的坑（本轮实测，别再踩）：`Start-Process -PassThru` 的 `$p.ExitCode` 在这里**恒为空**
#   （`WaitForExit` 返回 True、`HasExited` True、`Refresh()` 也没用；实测四种写法都一样）。
#   正解 = 用 cmd 把子进程退出码写成哨兵行 `__RC=<码>` 到输出文件里，再从那行取 —— 与超时保护
#   不冲突（还是 Start-Process + WaitForExit(超时)）。命令行里没有引号/空格问题，源路径已在副本目录里。
function Get-SentinelRc([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $m = Select-String -Path $path -Pattern '__RC=(-?\d+)' -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 1
  if (-not $m) { return $null }
  return [int]$m.Matches[0].Groups[1].Value
}
function Invoke-Compile([string]$exe, [string]$src, [string[]]$extra, [string]$tag, [int]$sec, [string]$outPath) {
  $parts = @('"' + $exe + '"', '"' + $src + '"')
  foreach ($x in $extra) { $parts += ('"' + $x + '"') }
  $line = ($parts -join ' ') + ' > "' + $outPath + '" 2>&1' + "`r`necho __RC=%errorlevel% >> `"$outPath`""
  # ⚠️ 用「写一个临时 .bat 再跑」而不是 `cmd /c <长命令>`：Start-Process -ArgumentList 对嵌套引号
  #   的处理不可靠（实测那条长命令被解析坏、cmd 挂住 20s 不动 → 全样本假 HANG_COMPILE）。
  #   写文件则引号原样进 bat，行为确定。
  $bat = Join-Path $work ("_compile-$tag.bat")
  Set-Content -Path $bat -Value ("@echo off`r`n" + $line) -Encoding Ascii
  $p = Start-Process -FilePath $bat -WorkingDirectory $work -NoNewWindow -PassThru
  if (-not $p.WaitForExit($sec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ hang = $true; code = $null; text = "[$tag 编译超时 ${sec}s]" }
  }
  $ec = Get-SentinelRc $outPath
  if ($null -eq $ec) { return @{ hang = $true; code = $null; text = "[$tag 编译超时/无退出码] " + ((Get-Content $outPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)) } }
  $txt = ''
  # ⚠️ `Start-Process -RedirectStandardOutput` **不做解码**，落盘就是子进程原样吐的字节；
  #   实测 flint.exe 吐的是 **UTF-8**（首字节 E2 9C 85 = "✅"）⇒ 必须按 UTF8 读。
  #   不写 -Encoding 时 PS5.1 按 ANSI(GBK) 解 ⇒ 中文全变乱码，门外看着像失败（本轮实测踩过）。
  if (Test-Path $outPath) { $txt = (Get-Content $outPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) }
  if (Test-Path "$outPath.err") { $txt = $txt + (Get-Content "$outPath.err" -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) }
  $txt = $txt -replace '__RC=-?\d+', ''            # 哨兵行不进报错文案
  return @{ hang = $false; code = $ec; text = ($txt -replace '\s+', ' ').Trim() }
}

$names = @()
if ($Only) { foreach ($x in ($Only -split ',')) { $t = $x.Trim(); if ($t) { $names += $t } } }
else { $names = @(Get-ChildItem $samples -Filter *.fl | Sort-Object Name | ForEach-Object { $_.BaseName }) }

$results = @()
$i = 0
foreach ($n in $names) {
  $i++
  Write-Progress -Activity '差分门' -Status "$n ($i/$($names.Count))" -PercentComplete (100 * $i / [Math]::Max(1, $names.Count))
  $src = Join-Path $samples "$n.fl"
  if (-not (Test-Path $src)) { continue }
  if ($SKIP -contains $n) { $results += [pscustomobject]@{ name=$n; verdict='SKIP'; detail='排除清单' }; continue }

  # 双方都用**副本目录里的同一份源**（boot 会把产物写在源旁边；flint 用 -o 指到别处）
  $csrc = Join-Path $work "$n.fl"
  $bexe = Join-Path $work "$n.exe"
  $fexe = Join-Path $outDir "f\$n.exe"

  Remove-Item $bexe -ErrorAction SilentlyContinue
  $br = Invoke-Compile $boot $csrc @() 'boot' $CompileTimeoutSec (Join-Path $outDir "boot-$n.compile.txt")
  $bc = $br.code
  $bo = $br.text
  $fr = Invoke-Compile $flint $csrc @('-o', $fexe) 'flint' $CompileTimeoutSec (Join-Path $outDir "flint-$n.compile.txt")
  $fc = $fr.code
  $fo = $fr.text

  if ($br.hang -or $fr.hang) {
    $who = @(); if ($br.hang) { $who += 'boot' }; if ($fr.hang) { $who += 'flint' }
    $results += [pscustomobject]@{ name=$n; verdict='HANG_COMPILE'; detail=(($who -join '+') + " 编译超时 ${CompileTimeoutSec}s") }
    continue
  }

  $bOk = ($bc -eq 0) -and (Test-Path $bexe)
  $fOk = ($fc -eq 0) -and (Test-Path $fexe)
  if (-not $fOk) { $results += [pscustomobject]@{ name=$n; verdict='FLINT_FAIL'; detail=("exit=$fc " + ($fo -replace '\s+',' ').Trim()) }; continue }
  if (-not $bOk) { $results += [pscustomobject]@{ name=$n; verdict='BOOT_FAIL'; detail=($bo -replace '\s+',' ').Trim() }; continue }

  $rb = Run-WithTimeout $bexe $work $TimeoutSec (Join-Path $outDir "b-$n.stdout.txt")
  $rf = Run-WithTimeout $fexe (Join-Path $outDir 'f') $TimeoutSec (Join-Path $outDir "f-$n.stdout.txt")
  # 2026-09-22（FLGUI M1 实测，卡 T-20260922-042229）：**超时判定给一次重试**。
  #   证据：整轮负载下（总门 verify-all 用 -TimeoutSec 5 调本门）新建产物的首次启动会被杀成 HANG ——
  #   flgui1 产物空载只跑 18ms、单跑本门「新增分歧 0/220」全绿，同一份产物在总门里却报「超过 5s」；既有样本 audit7 同病。
  #   真挂死的样本重试仍会挂 ⇒ 重试不削弱判据，只去掉负载抖动；**重试给 4 倍预算**（首次仍按 $TimeoutSec 快速筛，
  #   只有"疑似慢"才付这笔钱）—— 2026-09-22 实测：flgui1 在总门里连 5s 都过不去、单跑却 18ms，
  #   说明这类样本的首次启动在整轮负载下能超出 5s 一个量级，重试必须给足余量才拦得住假红。
  #   ⚠️ 改本文件必须**保住 UTF-8 BOM**：PS 5.1 把「无 BOM 的 UTF-8」按 GBK 解码，中文注释的字节会吞掉引号 → 解析炸（2026-09-22 踩过）。
  if ($rb.hang) { $rb = Run-WithTimeout $bexe $work ($TimeoutSec * 4) (Join-Path $outDir "b-$n.stdout.txt") }
  if ($rf.hang) { $rf = Run-WithTimeout $fexe (Join-Path $outDir 'f') ($TimeoutSec * 4) (Join-Path $outDir "f-$n.stdout.txt") }
  if ($rb.hang -or $rf.hang) {
    $who = @(); if ($rb.hang) { $who += 'boot产物' }; if ($rf.hang) { $who += 'flint产物' }
    $results += [pscustomobject]@{ name=$n; verdict='HANG'; detail=(($who -join '+') + " 超过 ${TimeoutSec}s") }
    continue
  }
  $ob = (Get-Content (Join-Path $outDir "b-$n.stdout.txt") -Raw -ErrorAction SilentlyContinue)
  $of = (Get-Content (Join-Path $outDir "f-$n.stdout.txt") -Raw -ErrorAction SilentlyContinue)
  if ($null -eq $ob) { $ob = '' }
  if ($null -eq $of) { $of = '' }
  $exitCompared = -not ($NONDET -contains $n)
  if ((-not $exitCompared -or $rb.code -eq $rf.code) -and $ob -eq $of) {
    $detail = if ($exitCompared) { "exit=$($rf.code)" } else { "exit 不判（非确定样本）" }
    $results += [pscustomobject]@{ name=$n; verdict='OK'; detail=$detail }
  } else {
    $d = "exit boot=$($rb.code) flint=$($rf.code)"
    if ($ob -ne $of) { $d += (" | stdout 不同 boot='" + ($ob -replace '\s+',' ').Trim() + "' flint='" + ($of -replace '\s+',' ').Trim() + "'") }
    $results += [pscustomobject]@{ name=$n; verdict='DIFF'; detail=$d }
  }
}
Write-Progress -Activity '差分门' -Completed

$counts = $results | Group-Object verdict | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("样本 {0} 个：{1}" -f $results.Count, ($counts -join '  '))
$sig = @($results | Sort-Object name | ForEach-Object { "$($_.name)`t$($_.verdict)`t$($_.detail)" })
# 收工清场：副本目录整个删掉（样本原件一字未动；回归门只认"摘要"这一份产物）
Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue

if ($WriteBaseline) {
  $hdr = @(
    "# 差分门基线（真 flint vs boot）—— 由 差分门.ps1 -WriteBaseline 生成",
    "# 格式：样本名 <TAB> 判定 <TAB> 说明；判定取值 OK / DIFF / BOOT_FAIL / FLINT_FAIL / HANG / SKIP",
    ("# 生成时间：" + (Get-Date -Format 'yyyy-MM-dd HH:mm') + " ｜ 样本数 " + $results.Count),
    "# 纪律：新增分岔（OK → DIFF/HANG）= 红；已列在此的 = 已知（boot 缺口，随开发逐条收敛）"
  )
  ($hdr + $sig) | Out-File -FilePath $Baseline -Encoding UTF8
  Write-Host ("基线已写入：{0}" -f $Baseline)
  return
}

if (-not (Test-Path $Baseline)) {
  Write-Host ("[!] 还没有基线：先跑一次 -WriteBaseline 建立基准（{0}）" -f $Baseline)
  exit 2
}
$base = @{}
foreach ($l in (Get-Content $Baseline -Encoding UTF8)) {
  if ($l -match '^([^\t#]+)\t([A-Z_]+)\t(.*)$') { $base[$matches[1]] = $matches[2] }
}
$newDiff = @(); $fixed = @(); $changed = @()
foreach ($r in $results) {
  if (-not $base.ContainsKey($r.name)) { $newDiff += $r; continue }
  $b = $base[$r.name]
  if ($b -ne $r.verdict) {
    if ($r.verdict -eq 'OK') { $fixed += "$($r.name) : $b -> OK" }
    # 2026-09-20（复核补洞）：**新出现的「编译挂住」一律判红** —— 原先只把 OK -> DIFF/HANG 算新增分岔，
    #   OK -> HANG_COMPILE 会掉进下面的 $changed（只打印"状态变化"、不改退出码、不判红）⇒
    #   「某样本从能编变成编译挂死」这种最该被门拦住的情况反而不红（本门加 HANG_COMPILE 的初衷就是拦它）。
    #   判据放宽方向 = 只要不是本来就是 HANG_COMPILE，转成 HANG_COMPILE 就是新增问题。
    elseif ($r.verdict -eq 'HANG_COMPILE') { $newDiff += $r }
    elseif ($r.verdict -in @('DIFF','HANG') -and $b -eq 'OK') { $newDiff += $r }
    else { $changed += "$($r.name) : $b -> $($r.verdict) ($($r.detail))" }
  }
}
Write-Host ""
Write-Host "---- 与基线比 ----"
if ($newDiff.Count -eq 0) { Write-Host "  OK  没有新增分岔/新增挂住" }
else { Write-Host ("  FAIL 新增 {0} 项：" -f $newDiff.Count); $newDiff | ForEach-Object { Write-Host ("        {0} : {1} : {2}" -f $_.name, $_.verdict, $_.detail) } }
if ($fixed.Count -gt 0) { Write-Host ("  已收敛 {0} 项：" -f $fixed.Count); $fixed | Select-Object -First 15 | ForEach-Object { Write-Host ("        $_") } }
if ($changed.Count -gt 0) { Write-Host ("  状态变化 {0} 项（多为 boot 缺口分类变化）：" -f $changed.Count); $changed | Select-Object -First 15 | ForEach-Object { Write-Host ("        $_") } }

$diffNow = @($results | Where-Object { $_.verdict -eq 'DIFF' })
Write-Host ""
Write-Host ("当前分岔清单（{0} 项，最多显示 {1}）：" -f $diffNow.Count, $MaxShow)
$diffNow | Select-Object -First $MaxShow | ForEach-Object { Write-Host ("    {0,-14} {1}" -f $_.name, $_.detail) }
$bf = @($results | Where-Object { $_.verdict -eq 'BOOT_FAIL' })
Write-Host ("boot 编译失败 {0} 项，按报错聚类：" -f $bf.Count)
$bf | Group-Object { if ($_.detail -match 'err=(-?\d+)') { "err=$($matches[1])" } elseif ($_.detail -match '^([\w:]+)') { $matches[1] } else { 'other' } } |
  Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object { Write-Host ("    {0,4} 项  {1}" -f $_.Count, $_.Name) }

# summary line for test\verify-all.ps1 (its parser reads the last line's trailing two numbers)
Write-Host ("差分门 新增分歧 {0} / 样本 {1}" -f $newDiff.Count, $results.Count)
$sig | Out-File -FilePath (Join-Path $PSScriptRoot '差分门-最近一次.txt') -Encoding UTF8
if ($newDiff.Count -gt 0) { exit 1 }
exit 0
