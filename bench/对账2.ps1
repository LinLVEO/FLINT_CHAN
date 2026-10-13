# 对账2.ps1 —— 单核实测对账（逐个实现逐个核：结果对账 + 回边自证 + QPC 开销下界 + 倍数）
# 立卡：T-20260919-010437（周期0「尺子与账本」）
# 用法（cd E:\FLINT-lab\bench）：
#   & .\对账2.ps1 [-N 2097152] [-Iters 5] [-SkipBuild]
#   & .\对账2.ps1 -Gate           # 门模式：跑两轮自证 + 给退出码（供 test\verify-all.ps1 第 [9] 步调用）
#                                 # 判据见脚本末尾 [6] 节；gcc 折叠属 known-form（不判红）
#
# 📌 报告口径（2026-09-22 用户明确要求「下次拉-O2 一起比」）：**O1 与 O2 必须并列一起报**，
#    不许只报 O1、也不许因为「-O2 把 k3 的循环整段折叠掉（ticks=1）」就把 O2 拿掉 ——
#    折叠掉的格子要**标注 folded／不可比并写出证据**；倍数反常（例如 flint 比 -O2 还快，
#    2026-09-22 实测 k1 0.65 vs O2 0.9715 ns/轮）时照实报并给出解释或明确存疑。
#    自证手法：出表那一节必须同时出现 O1 与 O2 两行。
#
# 与 对账.ps1 的关系：那是"三核串跑"的第一版，时间上无法分辨每核各跑了多久；本脚本是**单核版**——
# 一次只量一个核 ⇒ 累计 ticks 与轮数一一对应，且每项都能独立回答三个问题：
#   ① 结果对不对（与独立第三实现 Node 逐位比）      → 错了就不能用它的时间
#   ② 循环真跑了没（对**该实现的 main** 反汇编找回边）→ 折掉了就不能用它的时间
#   ③ 时间够不够分辨（累计 ticks > QPC 调用下界）    → 太短说明量到的是调用开销
param(
  [long]$N = 2097152,
  [int]$Iters = 5,
  [switch]$SkipBuild,
  [switch]$Gate
)
$ErrorActionPreference = 'Continue'
$bench  = $PSScriptRoot
$flint  = 'E:\FLINT-lab\flint.exe'
$gcc    = 'E:\mingw64\bin\gcc.exe'
$objdump= 'E:\mingw64\bin\objdump.exe'
$node   = 'node'
$KERNELS = 1,2,3
$IMPLS = @(
  @{ name='flint'; exe='bench_one.exe' },
  @{ name='O1';    exe='bench_one_O1.exe' },
  @{ name='O2';    exe='bench_one_O2.exe' }
)
$log = @()
function Say($s) { Write-Host $s; $script:log += $s }
function Parse-Kv($lines) {
  $kv = @{}
  foreach ($l in $lines) {
    foreach ($m in [regex]::Matches($l, '([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)')) {
      $kv[$m.Groups[1].Value] = [long]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    }
  }
  return $kv
}
# 入口点：RVA（opt+16 那个）+ **文件偏移**（RVA 与文件偏移在 PE 里通常不等，必须查节表换算；
# 2026-09-19 踩过：直接拿 RVA 当文件偏移喂 objdump，反汇编出来的是 MZ 头，回边数恒为 0 的假红）
function PE-Entry([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  $peOff = [BitConverter]::ToInt32($b, 0x3C)
  $entRva  = [BitConverter]::ToUInt32($b, $peOff + 24 + 16)
  $nSec    = [BitConverter]::ToUInt16($b, $peOff + 6)
  $optSize = [BitConverter]::ToUInt16($b, $peOff + 20)
  $secOff  = $peOff + 24 + $optSize
  $sec0ptr = 0; $sec0raw = 0
  for ($i = 0; $i -lt $nSec; $i++) {
    $s = $secOff + $i * 40
    $va  = [BitConverter]::ToUInt32($b, $s + 12)
    $vsz = [BitConverter]::ToUInt32($b, $s + 8)
    $ptr = [BitConverter]::ToUInt32($b, $s + 20)
    if ($i -eq 0) { $sec0ptr = $ptr; $sec0raw = [BitConverter]::ToUInt32($b, $s + 16) }
    if ($entRva -ge $va -and $entRva -lt ($va + $vsz)) {
      return [pscustomobject]@{ rva = $entRva; fileoff = ($entRva - $va + $ptr); textPtr = $sec0ptr; textRaw = $sec0raw }
    }
  }
  return [pscustomobject]@{ rva = $entRva; fileoff = $entRva; textPtr = $entRva; textRaw = 8192 }
}
# 只看"入口点起 4096 字节"这一窗（够覆盖 main 的大循环；避免把库/节里无关回边算进来）
function Has-BackJump([string]$exe) {
  # ⚠️ 反汇编结果**落盘再读行**（2026-09-19 踩坑：把原生输出收进变量再解析，
  #    同样的正则匹配恒为 0 条 —— 落盘法一次就对了，别在这上面省事）
  # ⚠️ 窗口要开在**代码**上：00 字节解出来是 add %al,(%rax)（合法指令），会把边界搅乱；
  #    窗口起点取"入口文件偏移与 .text 文件偏移中较大者"，长度 = 到 .text 末尾。
  $pe = PE-Entry $exe
  $fo = [Math]::Max($pe.fileoff, $pe.textPtr)
  $len = [Math]::Max(4096, ($pe.textPtr + $pe.textRaw) - $fo)
  $tmp = Join-Path $env:TEMP ("dis-" + [IO.Path]::GetFileNameWithoutExtension($exe) + ".txt")
  # ⚠️ 参数先算成变量再拼："--stop-address=($fo + $len)" 这种写法在双引号里**不会求值**，
  #    objdump 直接报"参数非法"，而 2>$null 把错误吞掉 ⇒ 空文件 ⇒ 回边数恒 0 的假红（踩过）。
  $stop = $fo + $len
  & $objdump -D -b binary -m i386:x86-64 "--adjust-vma=$fo" "--start-address=$fo" "--stop-address=$stop" $exe 2>$null | Out-File -FilePath $tmp -Encoding ascii
  $lines = Get-Content $tmp
  $cur = 0; $edges = @()
  foreach ($l in $lines) {
    if ($l -match '^\s*([0-9a-f]+):') { $cur = [Convert]::ToInt64($matches[1], 16) }
    $m = [regex]::Match($l, '\bj[a-z]+\s+(0x[0-9a-f]+)')
    if ($m.Success) {
      $tgt = [Convert]::ToInt64($m.Groups[1].Value.Substring(2), 16)
      if ($tgt -lt $cur -and $tgt -ge $fo) { $edges += [pscustomobject]@{ at=$cur; to=$tgt } }
    }
  }
  return [pscustomobject]@{ entry=$pe.rva; fileoff=$pe.fileoff; textPtr=$pe.textPtr; textRaw=$pe.textRaw; edges=$edges.Count; first=($edges | Select-Object -First 1) }
}

Say ("===== 单核基准对账：N=$N iters=$Iters =====")
if ((($N -band ($N - 1)) -ne 0) -or $N -le 0) { Say "[!] N 必须是 2 的幂（口径 x & (n-1) 才等于 x % n）" }

# ---------- [0] 生成两侧共用的轮数常量 ----------
Say ""
Say "----- [0] 生成轮数常量 -----"
& (Join-Path $bench 'gen-counts.ps1') -N $N | ForEach-Object { Say $_ }

# ---------- [1] 编译 ----------
if (-not $SkipBuild) {
  Say ""
  Say "----- [1] 编译 -----"
  Push-Location $bench
  & $flint bench_one.fl -o bench_one.exe | Out-Null
  Say ("flint bench_one.exe   exit={0}" -f $LASTEXITCODE)
  foreach ($o in 'O1','O2') {
    & $gcc "-$o" -o "bench_one_$o.exe" bench_one.c 2>&1 | Out-Null
    Say ("gcc -$o bench_one_$o.exe exit={0}" -f $LASTEXITCODE)
  }
  Pop-Location
}

# ---------- [2] 第三方权威 ----------
Say ""
Say "----- [2] 独立第三实现（Node）裁定 -----"
$ref = Parse-Kv (& $node (Join-Path $bench 'bench_runner.js') $N)
Say ("node: k1={0} k2={1} k3={2}" -f $ref['k1'], $ref['k2'], $ref['k3'])

# ---------- [3] 逐个实现 × 逐个核：跑 + 判据 ----------
Say ""
Say "----- [3] 实跑与判据 -----"
$rows = @()
foreach ($k in $KERNELS) {
  foreach ($im in $IMPLS) {
    $exe = Join-Path $bench $im.exe
    if (-not (Test-Path $exe)) { Say ("{0,-6} k{1}: 缺产物" -f $im.name, $k); continue }
    $o = & $exe $k $Iters
    $code = $LASTEXITCODE
    $kv = Parse-Kv $o
    $bj = Has-BackJump $exe
    $resultOk = ($kv['result'] -eq $ref["k$k"])
    $t = $kv['ticks']
    $floorOk = ($t -gt 50)   # <50 刻度 = 100ns 级时基下的 5µs：三个核都远大于它
    $reliable = ($resultOk -and ($bj.edges -gt 0) -and $floorOk)
    $nsPerIter = $null
    if ($t -gt 0) { $nsPerIter = [Math]::Round(([double]$t / [double]$kv['iters'] / [double]$N * 1e9 / [double]$kv['qpf']), 4) }
    $rows += [pscustomobject]@{
      impl=$im.name; kernel="k$k"; result=$kv['result']; ref=$ref["k$k"]
      结果=if($resultOk){'OK'}else{'错'}; 回边=$bj.edges; qpcraw=$kv['qpcraw']; ticks=$t
      ns_per_iter=$nsPerIter; reliable=$reliable
      edges=$bj.edges; ok=$resultOk    # ASCII 别名：门判据只认这几个字段（中文列名留给表格输出）
    }
    Say ("{0,-6} k{1}: result={2} ({3})  回边={4}  entry=0x{5:X}  qpcraw={6} ticks={7}  ns/轮={8}  {9}" -f `
      $im.name, $k, $kv['result'], $(if($resultOk){'OK'}else{'错'}), $bj.edges, $bj.entry, $kv['qpcraw'], $t, $nsPerIter, $(if($reliable){'可用'}else{'不可用'}))
  }
}

# ---------- [3b] 第二轮（仅 -Gate）：同形状自证 ----------
# 判据 = **结果与回边数**两轮一致；**时间允许抖动**（真跑的时间本来就会抖，"两轮逐位相同"
# 反而是被常量折叠的指纹 —— 见 bench\README.md §四）。
$rows2 = @()
if ($Gate) {
  Say ""
  Say "----- [3b] 第二轮（同形状自证：结果/回边必须一致，时间允许抖动） -----"
  foreach ($k in $KERNELS) {
    foreach ($im in $IMPLS) {
      $exe = Join-Path $bench $im.exe
      if (-not (Test-Path $exe)) { continue }
      $o = & $exe $k $Iters
      $kv = Parse-Kv $o
      $bj = Has-BackJump $exe
      $rows2 += [pscustomobject]@{ impl=$im.name; kernel="k$k"; result=$kv['result']; edges=$bj.edges; ticks=$kv['ticks'] }
      Say ("{0,-6} k{1}: result={2} ({3})  回边={4}  ticks={5}" -f `
        $im.name, $k, $kv['result'], $(if($kv['result'] -eq $ref["k$k"]){'OK'}else{'错'}), $bj.edges, $kv['ticks'])
    }
  }
}

# ---------- [4] 出表 + 倍数 ----------
Say ""
Say "----- [4] 出表（只列「三项判据全过」的项） -----"
$rows | Where-Object { $_.reliable } | Select-Object impl,kernel,result,ns_per_iter | Format-Table -AutoSize | Out-String -Width 90 | ForEach-Object { Say $_ }

Say "----- [5] 跨编译器倍数（flint ÷ gcc，同一把尺子） -----"
foreach ($k in $KERNELS) {
  $f = $rows | Where-Object { $_.impl -eq 'flint' -and $_.kernel -eq "k$k" -and $_.reliable }
  if (-not $f) { Say ("k{0}: flint 侧不可用 → 不报" -f $k); continue }
  $line = "k{0}: flint={1} ns/轮" -f $k, $f.ns_per_iter
  foreach ($g in 'O1','O2') {
    $r = $rows | Where-Object { $_.impl -eq $g -and $_.kernel -eq "k$k" -and $_.reliable }
    if (-not $r) { $line += "  ${g}=不可用"; continue }
    $line += "  ${g}={0}（{1}×）" -f $r.ns_per_iter, [Math]::Round($f.ns_per_iter / $r.ns_per_iter, 2)
  }
  Say $line
}

$json = [pscustomobject]@{ n=$N; iters=$Iters; ref=$ref; rows=$rows }
$json | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $bench 'result-single.json') -Encoding UTF8
$log | Out-File -FilePath (Join-Path $bench 'result-single.log') -Encoding UTF8
Say ""
Say ("已落盘：{0}" -f (Join-Path $bench 'result-single.json'))

# ---------- [6] 门判据（仅 -Gate；接入 test\verify-all.ps1 第 [9] 步） ----------
# 为什么这样定：本门是"**尺子的护栏**"，不是"性能指标门" ——
#   ① 三份实现的结果都必须等于 Node 第三实现（**含 gcc 侧**：C 源写错了同样要红）
#   ② flint 侧必须真的在跑循环（回边 > 0）且时间够分辨（ticks > 50，否则量到的是 QPC 调用开销）
#   ③ 同形状两轮自证：结果 / 回边数逐项一致（口径悄悄变了要当场发现）
#   ④ gcc -O2 整体折叠某核是**已知形态**（k3 实测 ticks=1~2、回边仍在但一圈没跑）⇒ 只打印
#      "known-form"、不判红 —— 长期挂红的门等于没有门（同「任务卡别长期挂进行中」的病因）
if ($Gate) {
  Say ""
  Say "----- [6] 门判据 -----"
  $fails = @(); $known = @()
  foreach ($k in $KERNELS) {
    foreach ($im in $IMPLS) {
      $r = $rows | Where-Object { $_.impl -eq $im.name -and $_.kernel -eq "k$k" }
      if (-not $r) { $fails += ("k{0}/{1}: product missing" -f $k, $im.name); continue }
      if ($r.result -ne $r.ref) { $fails += ("k{0}/{1}: result {2} != ref {3}" -f $k, $im.name, $r.result, $r.ref) }
      if ($im.name -eq 'flint') {
        if ($r.edges -le 0) { $fails += ("k{0}/flint: no back edge (loop did not really run)" -f $k) }
        if ($r.ticks -le 50) { $fails += ("k{0}/flint: ticks={1} below QPC floor" -f $k, $r.ticks) }
      } elseif (-not $r.reliable) {
        $known += ("k{0}/{1}: excluded by the three criteria (edges={2} ticks={3})" -f $k, $im.name, $r.edges, $r.ticks)
      }
      $r2 = $rows2 | Where-Object { $_.impl -eq $im.name -and $_.kernel -eq "k$k" }
      if (-not $r2) { $fails += ("k{0}/{1}: round-2 data missing" -f $k, $im.name); continue }
      if ($r2.result -ne $r.result) { $fails += ("k{0}/{1}: round2 result {2} != round1 {3}" -f $k, $im.name, $r2.result, $r.result) }
      if ($r2.edges -ne $r.edges) { $fails += ("k{0}/{1}: round2 edges {2} != round1 {3}" -f $k, $im.name, $r2.edges, $r.edges) }
    }
  }
  foreach ($x in $known) { Say ("  known-form " + $x) }
  foreach ($x in $fails) { Say ("  FAIL       " + $x) }
  $total = $KERNELS.Count * $IMPLS.Count
  Say ("bench pass {0} / {1}" -f ($total - $fails.Count), $total)
  $log | Out-File -FilePath (Join-Path $bench 'result-single.log') -Encoding UTF8
  if ($fails.Count -gt 0) { exit 1 }
  exit 0
}
