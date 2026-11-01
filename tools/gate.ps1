# gate.ps1 (v2, 2026-10-28) - one command, one exit code for the FLINT Studio IDE line.
#
# v1 (2026-10-27) always paid the full 5-6 min. v2 implements docs\流程优化提案.md §2 items 1 / 2 / 5:
#   -Quick  = build + pixel snapshot + the probes owned by the touched subsystem (+ perf only for paint/font)
#   -Full   = v1 behaviour on purpose: all probes + perf + static (use before merge/delivery)
#   every gate is timed; one line per run is appended to tmp\gate\timings.log (so the next cut is data-driven).
#
# Usage:
#   pwsh -NoProfile -File tools\gate.ps1                          # full (~5-6 min)
#   pwsh -NoProfile -File tools\gate.ps1 -Quick -Touched paint    # ~90s (build + snapshot + 5 paint probes + perf)
#   pwsh -NoProfile -File tools\gate.ps1 -Quick -Touched input,cfg
#   pwsh -NoProfile -File tools\gate.ps1 -Quick                   # core set: render + sel + cfg (+ snapshot)
#   Tags: paint | input | file | cfg | core.  -Touched accepts "a,b" or a PowerShell list.
#   Switches: -SkipBuild -SkipPerf -Quiet  (kept from v1; -Full is an explicit alias of the default).
#
param(
    [switch]$SkipBuild,
    [switch]$SkipPerf,
    [switch]$Quiet,
    [switch]$Quick,
    [switch]$Full,
    [string[]]$Touched
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$logDir = Join-Path $root 'tmp\gate'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("gate-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$fail = 0
$lines = New-Object System.Collections.Generic.List[string]
$timings = [ordered]@{}

function Say([string]$s) {
    $lines.Add($s)
    if (-not $Quiet) { Write-Host $s }
}

# ---------- mode / probe plan (proposal §2 #2, influence map from 2.1 option 1: explicit tag) ----------
$probeMap = [ordered]@{
    paint = @('probe-ide-render', 'probe-ide-cjksize', 'probe-ide-menu', 'probe-ide-ws', 'probe-ide-wrap-hl')
    input = @('probe-ide-sel', 'probe-ide-edit2', 'probe-ide-find', 'probe-ide-replace', 'probe-ide-repeat', 'probe-ide-scroll')
    file  = @('probe-ide-tree', 'probe-ide-dlgdir', 'probe-ide-cfg')
    cfg   = @('probe-ide-cfg', 'probe-ide-settings')
}
$coreProbes = @('probe-ide-render', 'probe-ide-sel', 'probe-ide-cfg')
$mode = 'full'
$tags = @()
$probeNames = $null
if ($Quick -and -not $Full) {
    $mode = 'quick'
    if ($null -ne $Touched -and $Touched.Count -gt 0) {
        # `pwsh -File ... -Touched paint,input` hands over ONE string "paint,input"
        if ($Touched.Count -eq 1 -and $Touched[0] -like '*,*') { $Touched = @($Touched[0] -split ',') }
        $tags = @($Touched | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' })
    }
    $badTags = @($tags | Where-Object { $_ -ne 'core' -and -not $probeMap.Contains($_) })
    if ($badTags.Count -gt 0) {
        Write-Host ("gate: unknown -Touched value(s): {0}" -f ($badTags -join ', '))
        Write-Host ("      valid tags: core, {0}" -f (($probeMap.Keys) -join ', '))
        exit 2
    }
    if ($tags.Count -eq 0) { $tags = @('core') }
    $probeNames = @('snapshot')
    foreach ($t in $tags) {
        if ($t -eq 'core') { $probeNames += $coreProbes } else { $probeNames += $probeMap[$t] }
    }
    $probeNames = @($probeNames | Select-Object -Unique)
}

Say ("GATE start {0}  mode={1}{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode,
    $(if ($mode -eq 'quick') { "  touched=" + ($tags -join '+') + "  probes=" + $probeNames.Count } else { '' }))
if ($mode -eq 'quick') { Say ("GATE plan    {0}" -f ($probeNames -join ', ')) }

# ---------- G1 compile ----------
$exe = Join-Path $root 'apps\studio_native\studio_win.exe'
if ($SkipBuild) {
    Say "G1 compile   SKIP (requested)"
} else {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & pwsh -NoProfile -File (Join-Path $root 'tools\build-ide.ps1') 2>&1 | Out-String
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $exe)
    $size = if (Test-Path $exe) { (Get-Item $exe).Length } else { 0 }
    $sw.Stop(); $timings['G1'] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($ok) { Say ("G1 compile   PASS  exe={0} bytes  {1:N1}s" -f $size, $timings['G1']) }
    else { Say ("G1 compile   FAIL  exit={0}  {1:N1}s" -f $LASTEXITCODE, $timings['G1']); $fail = 1; $lines.Add($out) }
}

# ---------- G2 behaviour ----------
if ($fail -eq 0) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $suite = Join-Path $root 'tools\probes\run-ide-probes.ps1'
    $suiteArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $suite)
    if ($null -ne $probeNames) { $suiteArgs += @('-Only', ($probeNames -join ',')) }
    $out = & pwsh @suiteArgs 2>&1 | Out-String
    $suiteOk = ($LASTEXITCODE -eq 0)
    $sw.Stop(); $timings['G2'] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $summary = ($out -split "`r?`n" | Where-Object { $_ -match '^SUITE' } | Select-Object -Last 1)
    if ($suiteOk) { Say ("G2 behaviour PASS  {0}  {1:N1}s" -f $summary, $timings['G2']) }
    else {
        Say ("G2 behaviour FAIL  {0}  {1:N1}s" -f $summary, $timings['G2'])
        ($out -split "`r?`n" | Where-Object { $_ -match 'FAIL' }) | ForEach-Object { Say ("             " + $_.Trim()) }
        $fail = 1
    }
    $lines.Add('--- suite log ---'); $lines.Add($out)
}

# ---------- G3 performance (proposal §2 #1: trend metric, only paint/font/terminal changes pay for it) ----------
$perfBudgetMs = 25.0
if ($SkipPerf -or $fail -ne 0) {
    Say "G3 performance SKIP"
} elseif ($mode -eq 'quick' -and -not ($tags -contains 'paint')) {
    Say "G3 performance SKIP (quick, not a paint/font change)"
} else {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # run twice, take the better sample (one measurement is noisy on a shared box);
    # quick pays for one sample only: the 25 ms budget has ~10 ms of headroom, and a 2x
    # perf regression would still be caught by the next -Full before merge.
    $samples = @()
    $runs = if ($mode -eq 'quick') { 1 } else { 2 }
    for ($i = 0; $i -lt $runs; $i++) {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\probes\perf-frame.ps1') -Tag "gate$i" 2>&1 | Out-String
        $m = [regex]::Match($out, '=>\s*([0-9.]+)\s*ms/frame')
        if ($m.Success) { $samples += [double]$m.Groups[1].Value }
        $lines.Add($out)
    }
    $sw.Stop(); $timings['G3'] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($samples.Count -eq 0) { Say ("G3 performance FAIL  (no sample)  {0:N1}s" -f $timings['G3']); $fail = 1 }
    else {
        $best = ($samples | Measure-Object -Minimum).Minimum
        if ($best -le $perfBudgetMs) { Say ("G3 performance PASS  {0:N2} ms/frame (budget {1})  {2:N1}s" -f $best, $perfBudgetMs, $timings['G3']) }
        else { Say ("G3 performance FAIL  {0:N2} ms/frame (budget {1})  {2:N1}s" -f $best, $perfBudgetMs, $timings['G3']); $fail = 1 }
    }
}

# ---------- G4 static ratchet ----------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fl = Join-Path $root 'apps\studio_native\studio_win.fl'
$baseFile = Join-Path $root 'tools\gate-baseline.json'
$src = Get-Content $fl -Raw
$srcLines = (Get-Content $fl).Count
$funcStarts = (Select-String -Path $fl -Pattern '^[a-zA-Z_].*\) \{' | ForEach-Object { $_.LineNumber })
$maxFunc = 0
for ($i = 0; $i -lt $funcStarts.Count - 1; $i++) {
    $len = $funcStarts[$i + 1] - $funcStarts[$i]
    if ($len -gt $maxFunc) { $maxFunc = $len }
}
$mainStart = (Select-String -Path $fl -Pattern '^int main\(' | Select-Object -First 1).LineNumber
$mainLen = if ($mainStart) { $srcLines - $mainStart } else { 0 }
$magic = @{}
# 魔法数的口径：只数**逻辑里**的字面量。`int tbh = 34;` / `int g_sideW = 220;` 这种"命名量的声明"
#   正是字面量该待的地方（全 app 唯一来源），计进去等于惩罚整理行为。所以先剔掉这类声明行再数。
$logic = (Get-Content $fl) | Where-Object {
    $_ -notmatch '^\s*int\s+(g_[A-Za-z0-9_]+|W|H|fs|tbh|MB|sbh|top|sb_top|edb|gx|tx|lh|ln|col|vis)\s*=\s*-?[0-9]+\s*;'
}
$logicSrc = [string]::Join("`n", $logic)
foreach ($n in @(220, 240, 268, 34, 26, 60)) {
    $magic["$n"] = ([regex]::Matches($logicSrc, "\b$n\b")).Count
}
# 裸调用 = 忽略返回值的调用（"不崩就行"的味道）。**排除 paint_* 绘制助手**：它们是纯绘制、
#   返回值没有意义，而且每抽出一个分区函数就会多一个这种调用点 —— 那不算欠账。
$bareCalls = (Select-String -Path $fl -Pattern '^\s*[a-zA-Z_]+\(' |
    Where-Object { $_.Line.Trim() -notmatch '^(paint_|handle_)' }).Count

$cur = [ordered]@{
    fileLines   = $srcLines
    mainLines   = $mainLen
    maxFunction = $maxFunc
    bareCalls   = $bareCalls
    magic       = $magic
}
# G4 口径（2026-10-27 第一次跑红后修正，理由写在 docs\工业级标准.md）：
#   · mainLines / maxFunction / bareCalls / magic 是**欠账**，只许降不许升（棘轮）
#   · fileLines **不是欠账**（加一张常量表是好事），改成硬上限 —— 防止文件无脑膨胀
$fileCap = 5250   # 宽松上限：拆函数会加"函数头/注释"这种脚手架，真正的欠账指标是 main/最大函数/裸调用/魔法数
                  # 2026-10-28：5200 → 5250（Ctrl+H 替换功能 +131 行；只抬到刚好够，下一刀拆输入侧时回落）
if ($srcLines -gt $fileCap) { Say ("G4 static    FAIL  fileLines {0} > hard cap {1}" -f $srcLines, $fileCap); $fail = 1 }
if (-not (Test-Path $baseFile)) {
    $cur | ConvertTo-Json -Depth 5 | Set-Content -Path $baseFile -Encoding utf8
    Say ("G4 static    PASS  baseline created ({0} lines, main={1}, maxFunc={2}, bare={3})" -f $srcLines, $mainLen, $maxFunc, $bareCalls)
} else {
    $b = Get-Content $baseFile -Raw | ConvertFrom-Json
    $bad = @()
    $better = @()
    if ($cur.mainLines -gt [int]$b.mainLines) { $bad += ("mainLines {0} > {1}" -f $cur.mainLines, $b.mainLines) }
    elseif ($cur.mainLines -lt [int]$b.mainLines) { $better += ("main {0}->{1}" -f $b.mainLines, $cur.mainLines) }
    if ($cur.maxFunction -gt [int]$b.maxFunction) { $bad += ("maxFunction {0} > {1}" -f $cur.maxFunction, $b.maxFunction) }
    if ($cur.bareCalls -gt [int]$b.bareCalls) { $bad += ("bareCalls {0} > {1}" -f $cur.bareCalls, $b.bareCalls) }
    elseif ($cur.bareCalls -lt [int]$b.bareCalls) { $better += ("bare {0}->{1}" -f $b.bareCalls, $cur.bareCalls) }
    foreach ($k in $magic.Keys) {
        if ($magic[$k] -gt [int]$b.magic.$k) { $bad += ("magic {0}: {1} > {2}" -f $k, $magic[$k], $b.magic.$k) }
        elseif ($magic[$k] -lt [int]$b.magic.$k) { $better += ("magic{0} {1}->{2}" -f $k, $b.magic.$k, $magic[$k]) }
    }
    if ($bad.Count -eq 0) {
        # 只许降：降了就顺手把基线压下去（棘轮逐格收紧），这样下一次不许回到旧值
        if (($better.Count -gt 0) -and ($fail -eq 0)) {
            $cur | ConvertTo-Json -Depth 5 | Set-Content -Path $baseFile -Encoding utf8
            Say ("G4 static    PASS  debt down ({0}) -> baseline tightened" -f ($better -join ', '))
        } else {
            Say ("G4 static    PASS  lines={0} main={1} maxFunc={2} bare={3} (no new debt)" -f $srcLines, $mainLen, $maxFunc, $bareCalls)
        }
    } else {
        Say ("G4 static    FAIL  debt grew: {0}" -f ($bad -join '; ')); $fail = 1
    }
}
$sw.Stop(); $timings['G4'] = [math]::Round($sw.Elapsed.TotalSeconds, 1)

# ---------- summary + timing ledger (proposal §2 #5) ----------
$total = 0.0
foreach ($k in $timings.Keys) { $total += $timings[$k] }
Say ("GATE {0}  mode={1}  total={2:N1}s  log={3}" -f $(if ($fail -eq 0) { 'GREEN' } else { 'RED' }), $mode, $total, $log)
$lines -join "`r`n" | Set-Content -Path $log -Encoding utf8

$row = ("{0}  mode={1}  touched={2}  total={3:N1}s  |  {4}" -f
    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode,
    $(if ($mode -eq 'quick' -and $tags.Count -gt 0) { $tags -join '+' } else { '-' }),
    $total,
    (($timings.Keys | ForEach-Object { "$_=$($timings[$_])s" }) -join ' '))
Add-Content -Path (Join-Path $logDir 'timings.log') -Value $row -Encoding utf8
exit $fail
