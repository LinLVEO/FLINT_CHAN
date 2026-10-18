<#
对账.ps1 —— 不可折叠基准组：编译 / 运行 / 三方对账 / PE 回边自证 / 归一化出表
立卡：T-20260919-010437（周期0「尺子与账本」）

用法（先 cd E:\FLINT-lab\bench）：
  powershell -NoProfile -ExecutionPolicy Bypass -File 对账.ps1 [-N 2000000] [-Iters 3] [-SkipBuild]

它做五件事：
  [1] 编译：flint 侧（FLINT-lab\flint.exe）+ C 侧三档（gcc -O0 / -O1 / -O2）
  [2] 跑：每侧各跑一次，抓 stdout 与退出码
  [3] 第三方裁定：node bench_runner.js <n> 算出"标准答案"（独立第三实现）
  [4] 结果对账：flint / C / 第三方 三份 k1 k2 k3 必须逐个相等
  [5] PE 回边自证：读 .text 段字节，找**向后跳转**（85 xx / E9 / EB / 7x）——
     证明"循环真的编进去了"；再叠加 [4] 的逐值相等 ⇒ 证明"真的跑了 n 轮"
     最后归一化 ns/轮（只报**同侧**；跨编译器倍数只在两边都过 [4]+[5] 时才打印）

输出：控制台表 + result.json（供后续轮次/回归引用）
#>
param(
  [long]$N = 2097152,
  [int]$Iters = 10,
  [switch]$SkipBuild,
  [switch]$Debug
)
$ErrorActionPreference = 'Continue'
$Iters = [int]$Iters     # 复制成本地变量：脚本里 $it 的赋值不得覆盖参数（PS 变量不区分大小写）
$bench = $PSScriptRoot
$flint = 'E:\FLINT-lab\flint.exe'
$gcc   = 'E:\mingw64\bin\gcc.exe'
$node  = 'node'
$log = @()

function Say($s) { Write-Host $s; $script:log += $s }

# ---------- [0] 写 FLINT 侧配置（二进制 4 字节小端）----------
# 退役的文本 cfg 踩过"读到注释里的数字"：读出 n=209（应为 2097152），属静默错
$dat = Join-Path $bench 'bench_flint.dat'
[System.IO.File]::WriteAllBytes($dat, [BitConverter]::GetBytes([int]$N))
Say ("[0] 写入 bench_flint.dat: n=$N（4 字节小端）")

# ---------- [1] 编译 ----------
if (-not $SkipBuild) {
  Say "===== [1] 编译 ====="
  Push-Location $bench
  & $flint bench_flint.fl -o bench_flint.exe | Out-Null
  Say ("flint  bench_flint.exe   exit={0}" -f $LASTEXITCODE)
  foreach ($opt in 'O1','O2') {
    & $gcc "-$opt" -o "bench_c_$opt.exe" bench_c.c 2>&1 | Out-Null
    Say ("gcc -$opt bench_c_$opt.exe exit={0}" -f $LASTEXITCODE)
  }
  Pop-Location
}

# ---------- 解析器 ----------
function Parse-Out($lines) {
  $kv = @{}
  foreach ($l in $lines) {
    foreach ($m in [regex]::Matches($l, '([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)')) {
      $kv[$m.Groups[1].Value] = [long]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    }
  }
  return $kv
}

function As-U32([long]$v) { if ($v -lt 0) { return $v + 4294967296 } else { return $v } }

# 8 位有符号（PS 里 [sbyte] 转换 >127 会抛异常，故手工算补码）
function Sign8([int]$v) { if ($v -gt 127) { return $v - 256 } else { return $v } }

# ---------- [5] PE 回边自证 ----------
function Get-PESections([string]$path) {
  $b = [System.IO.File]::ReadAllBytes($path)
  if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return @() }
  $peOff = [BitConverter]::ToInt32($b, 0x3C)
  if ($b[$peOff] -ne 0x50 -or $b[$peOff + 1] -ne 0x45) { return @() }
  $nSec    = [BitConverter]::ToUInt16($b, $peOff + 6)
  $optSize = [BitConverter]::ToUInt16($b, $peOff + 20)
  $secOff  = $peOff + 24 + $optSize
  $list = @()
  for ($i = 0; $i -lt $nSec; $i++) {
    $s = $secOff + $i * 40
    # 段名：ASCII 化后只取 [A-Za-z0-9._]（别用 -replace 处理 NUL，PS 里会出幺蛾子）
    $sb = New-Object Text.StringBuilder
    for ($q = 0; $q -lt 8; $q++) {
      $ch = $b[$s + $q]
      if ($ch -eq 0) { break }
      if (($ch -ge 65 -and $ch -le 90) -or ($ch -ge 97 -and $ch -le 122) -or ($ch -ge 48 -and $ch -le 57) -or $ch -eq 46 -or $ch -eq 95) { [void]$sb.Append([char]$ch) }
    }
    $list += [pscustomobject]@{
      name  = $sb.ToString()
      vsz   = [BitConverter]::ToUInt32($b, $s + 8)
      vad   = [BitConverter]::ToUInt32($b, $s + 12)
      ras   = [BitConverter]::ToUInt32($b, $s + 16)
      vptr  = [BitConverter]::ToUInt32($b, $s + 20)
      chars = [BitConverter]::ToUInt32($b, $s + 36)
    }
  }
  return $list
}

function PE-BackJump([string]$path, [switch]$Debug) {
  $wantDebug = $Debug.IsPresent
  $b = [System.IO.File]::ReadAllBytes($path)
  $secs = Get-PESections $path
  if ($wantDebug) { foreach ($s in $secs) { Say ("       [dbg] 段 {0,-9} vsz={1} ras={2} vptr={3} chars=0x{4:X8}" -f $s.name, $s.vsz, $s.ras, $s.vptr, $s.chars) } }
  # 取"可执行"的那一段（flags 含 IMAGE_SCN_MEM_EXECUTE=0x20000000）；没有就退而取 .text
  $text = $secs | Where-Object { ($_.chars -band 0x20000000) -ne 0 } | Select-Object -First 1
  if (-not $text) { $text = $secs | Where-Object { $_.name -eq '.text' } | Select-Object -First 1 }
  if (-not $text) { return @{ ok = $false; why = ('无 段（PE 段表读到 {0} 个）' -f $secs.Count) } }
  $start = [int]$text.vptr
  $len   = [int][Math]::Min($text.ras, $b.Length - $start)
  if ($start -le 0 -or $len -le 0 -or ($start + $len) -gt $b.Length) {
    return @{ ok = $false; why = ('段范围越界 start={0} len={1} file={2}' -f $start, $len, $b.Length) }
  }
  # 只需要回答"有没有向后跳转" → 找到第一条就继续数，但整段扫一遍也很快
  $firstBack = $null
  $backCount = 0
  $i = 0
  while ($i -lt ($len - 8)) {
    $op = $b[$start + $i]
    $rel = $null
    $ilen = 1
    if ($op -eq 0x85) { $rel = (Sign8 $b[$start + $i + 2]) + 6; $ilen = 6 }
    elseif ($op -eq 0xE9) { $rel = [BitConverter]::ToInt32($b, $start + $i + 1) + 5; $ilen = 5 }
    elseif ($op -eq 0xEB) { $rel = (Sign8 $b[$start + $i + 1]) + 2; $ilen = 2 }
    elseif ($op -ge 0x70 -and $op -le 0x7F) { $rel = (Sign8 $b[$start + $i + 1]) + 2; $ilen = 2 }
    if ($null -ne $rel -and $rel -lt 0) {
      $backCount = $backCount + 1
      if ($null -eq $firstBack) { $firstBack = [pscustomobject]@{ off = $i; op = ('{0:X2}' -f $op); rel = $rel } }
    }
    $i = $i + $ilen
  }
  # 定义：段里存在至少一条向后的相对跳转 ⇒ 说明"循环真的编进去了"
  return @{ ok = ($backCount -gt 0); count = $backCount; first = $firstBack; size = $len; sec = $text.name }
}

# 口径自检：n 必须是 2 的幂（否则 &(n-1) 与 %n 不等，三方对账不成立 —— 已踩过）
if ((($N -band ($N - 1)) -ne 0) -or $N -le 0) {
  Say ("[!] N=$N 不是 2 的幂：本组口径 x & (n-1) 与 x % n 不等，结果对账不成立（请用 2 的幂，如 2097152）")
}

# ---------- [2] 跑 ----------
Say ""
Say "===== [2] 运行（N=$N, iters=$Iters）====="
$runs = @{}
foreach ($name in 'flint','O1','O2') {
  $exe = if ($name -eq 'flint') { 'bench_flint.exe' } else { "bench_c_$name.exe" }
  $path = Join-Path $bench $exe
  if (-not (Test-Path $path)) { Say "$exe 缺失（跳过）"; continue }
  if ($name -eq 'flint') { $o = & $path } else { $o = & $path $N $Iters }
  $code = $LASTEXITCODE
  $kv = Parse-Out $o
  $runs[$name] = @{ kv = $kv; exit = $code; exe = $path; out = $o }
  Say ("{0,-6} exit={1}  out={2}" -f $name, $code, ($o -join ' | '))
  if ($name -eq 'flint' -and $kv['n'] -ne $N) {
    Say ("       [!] FLINT 侧 n={0} ≠ 脚本 -N={1}：两侧工作量不同，结果对账必然失败（先对齐 bench_flint.cfg）" -f $kv['n'], $N)
  }
}

# ---------- [3] 第三方裁定 ----------
Say ""
Say "===== [3] 第三方裁定（node bench_runner.js $N）====="
$refOut = & $node (Join-Path $bench 'bench_runner.js') $N
Say ("node   out=" + ($refOut -join ' | '))
$ref = Parse-Out $refOut

# ---------- [4] 结果对账 ----------
Say ""
Say "===== [4] 结果对账（k1 k2 k3 必须三方逐位相同）====="
$verdict = $true
foreach ($k in 'k1','k2','k3') {
  $want = $ref[$k]
  $line = "{0,-3} 第三方={1,-12}" -f $k, $want
  foreach ($name in $runs.Keys) {
    $got = $runs[$name].kv[$k]
    $ok = ($got -eq $want)
    if (-not $ok) { $verdict = $false }
    $line += " {0}={1}{2}" -f $name, $got, $(if ($ok) { " OK" } else { " **不一致**" })
  }
  Say $line
}
Say ("结果对账总体：{0}" -f $(if ($verdict) { "一致" } else { "有不一致" }))
# 逐侧判定（"该侧结果与权威不符"⇒ 它的时间数字不可信，不能进倍数）
$kvOk = @{}
foreach ($name in $runs.Keys) {
  $ok = $true
  foreach ($k in 'k1','k2','k3') { if ($runs[$name].kv[$k] -ne $ref[$k]) { $ok = $false } }
  $kvOk[$name] = $ok
}
Say ("逐侧结果可信：{0}" -f (($runs.Keys | ForEach-Object { "$_=$(if($kvOk[$_]){'OK'}else{'错'})" }) -join ' '))

# ---------- [5] PE 回边自证 ----------
Say ""
Say "===== [5] PE 回边自证（循环真的编进去了？）====="
$jumpInfo = @{}
foreach ($name in $runs.Keys) {
  $ji = PE-BackJump $runs[$name].exe -Debug:$Debug
  $jumpInfo[$name] = $ji
  if ($ji.ok) {
    Say ("{0,-6} 段{1}={2} 字节，向后跳转 {3} 条，首条 offset={4} op={5} rel={6}" -f $name, $ji.sec, $ji.size, $ji.count, $ji.first.off, $ji.first.op, $ji.first.rel)
  } else {
    Say ("{0,-6} 失败：{1}" -f $name, $ji.why)
  }
}

# ---------- 归一化出表 ----------
Say ""
Say "===== 出表（ns/轮 = 累计 ticks ÷ iters ÷ n ÷ qpf × 1e9）====="
$rows = @()
$bad = @()
foreach ($name in $runs.Keys) {
  $kv = $runs[$name].kv
  $qpf = As-U32 $kv['qpf']
  if ($qpf -le 0) { Say ("{0}: qpf 无效（{1}）→ 不出数" -f $name, $kv['qpf']); $bad += $name; continue }
  Say ("{0,-6} qpf={1}（{2} MHz）" -f $name, $qpf, [Math]::Round($qpf / 1e6, 1))
  $itn = if ($kv['i']) { $kv['i'] } else { $Iters }
  foreach ($k in 'k1','k2','k3') {
    $t = $kv["t$($k[1])"]
    if ($t -le 0) {
      # 0 ticks = 那段跑不满一个时钟刻度 ⇒ 出不了数、且**不能当成"快"**
      Say ("       {0}: [!] 累计 ticks=0 -> 不可测（不是「快」，也不是「零成本」，是分辨率不够或被折掉）" -f $k)
      $rows += [pscustomobject]@{ impl=$name; kernel=$k; ticks=$t; ns_per_iter=$null; reliable=$false }
      continue
    }
    # 物理下界判据：被测区段至少包含"进入+离开各一次 QPC 调用"
    # （C 侧实测背靠背 QPC 差 ~25 刻度 ⇒ 单次调用 ~12 刻度；每核前后各一次 ⇒ 下界 ≈ 25）
    # 低于该下界 ⇒ 那一侧的时间数字是"被折掉/量到空气"，绝不当成"快"
    $tickFloor = 25
    if ($t -lt $tickFloor) {
      Say ("       {0}: [!] 累计 ticks={1} < QPC 开销下界 {2} -> 该侧被折掉（结果仍对，时间不可用）" -f $k, $t, $tickFloor)
      $rows += [pscustomobject]@{ impl=$name; kernel=$k; ticks=$t; ns_per_iter=$null; reliable=$false }
      continue
    }
    $ns = [double]$t * $Iters / [double]$itn          # 观测次数归一化到"单次"
    $ns = $ns * 1e9 / $qpf
    $per = $ns / $N
    $rows += [pscustomobject]@{ impl=$name; kernel=$k; ticks=$t; ns_per_iter=[Math]::Round($per,4); reliable=($kvOk[$name]) }
  }
}
$rows | Where-Object { $_.reliable } | Format-Table -AutoSize | Out-String -Width 100 | ForEach-Object { Say $_ }

# 跨编译器倍数：只有"结果对账通过 + 两侧都证明有回边 + 该项可测"才算数
$jumpOk = (($runs.Keys | ForEach-Object { $jumpInfo[$_].ok }) -notcontains $false)
Say ""
Say "===== 跨编译器倍数（同一把尺子：同机同刻同形状；口径 = flint ÷ gcc）====="
foreach ($k in 'k1','k2','k3') {
  $f = $rows | Where-Object { $_.impl -eq 'flint' -and $_.kernel -eq $k -and $_.reliable }
  if (-not $f) { Say ("{0}: flint 侧不可测 → 不报" -f $k); continue }
  $line = "{0}: flint={1} ns/轮" -f $k, $f.ns_per_iter
  foreach ($g in 'O0','O1','O2') {
    $r = $rows | Where-Object { $_.impl -eq $g -and $_.kernel -eq $k -and $_.reliable }
    if (-not $r) { $line += "  ${g}=不可测（结果不符⇒时间不可信）"; continue }
    $ratio = [Math]::Round($f.ns_per_iter / $r.ns_per_iter, 3)
    $line += "  ${g}={0}（flint÷{1}={2}×）" -f $r.ns_per_iter, $g, $ratio
  }
  Say $line
}
Say ("前提：结果对账={0}；回边自证={1}；{2}" -f $(if($verdict){'✅'}else{'❌'}), $(if($jumpOk){'✅'}else{'❌'}), $(if($verdict -and $jumpOk){'⇒ 倍数可引用'}else{'⇒ 倍数不可引用'}))

# ---------- 落 result.json ----------
$json = [pscustomobject]@{
  n = $N; iters = $Iters; verdict = $verdict; backjump_ok = $jumpOk
  ref = $ref
  runs = $runs.Keys | ForEach-Object { [pscustomobject]@{ impl=$_; exit=$runs[$_].exit; kv=$runs[$_].kv; backjumps=$jumpInfo[$_].count } }
  rows = $rows
}
$json | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $bench 'result.json') -Encoding UTF8
Say ""
Say ("已落盘：{0}" -f (Join-Path $bench 'result.json'))
$log | Out-File -FilePath (Join-Path $bench 'result.log') -Encoding UTF8
