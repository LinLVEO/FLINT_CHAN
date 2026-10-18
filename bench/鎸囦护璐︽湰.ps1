# 指令账本.ps1 —— PE 只读指令账本（优化优先级只按账本定，不凭感觉）
# 立卡：T-20260919-010437（周期0「尺子与账本」）
#
# 用法（cd E:\FLINT-lab\bench）：
#   & .\指令账本.ps1 -Exe bench_one.exe                 # 全 .text 记账 + 按 4KB 窗分块
#   & .\指令账本.ps1 -Exe bench_one_O2.exe -Top 12      # 看主循环窗
#   & .\指令账本.ps1 -Exe bench_one.exe -Budget 800     # 只记前 800 字节（近似"主循环区"）
#
# 它回答的问题：**那 8~23 个周期/轮，具体花在哪几条指令上**——
#   ① 指令条数 / 指令字节数 / 平均指令长度
#   ② **访存指令占比**（AT&T 写法 `disp(%rbp)` / `(%rsp)`；FLINT 现状的病根）
#   ③ **纯寄存器操作占比**（add %rcx,%rax 这种，寄存器分配落地后该升上来）
#   ④ 栈流量（push/pop 条数）、回边（循环）条数
#   ⑤ 助记符直方图（按条数排序，直接指出"钱花在哪种指令上"）
#
# 判据/纪律：
#   · **只读**：不改任何产物、不碰编译器
#   · 反汇编结果**落盘再读行**（收进变量再解析踩过坑：同样正则恒不匹配）
#   · objdump 参数先算成变量再拼（`"($a + $b)"` 在双引号里不求值 ⇒ 参数非法被 2>$null 吞成空文件）
#   · 统计前先剔除**数据字节**被误当指令的区域：本脚本按"从入口文件偏移起、到 .text 末尾"取窗，
#     并对 `bad` 行计数（objdump 解不出来的字节数）报出来，避免把数据段算成代码
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [int]$Budget = 0,       # >0 时只统计前 Budget 字节（近似主循环区）
  [int]$Top = 10,         # 直方图显示前 N 项
  [int]$From = 0,         # >0 时窗口改从该文件偏移开始（只看单个函数/单个核）
  [string]$Symbol = ""    # 有符号表时按符号起止切窗（gcc 产物可用；FLINT 裸 PE 没有符号表）
)
$ErrorActionPreference = 'Stop'
$objdump = 'E:\mingw64\bin\objdump.exe'

function PE-Info([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  $peOff = [BitConverter]::ToInt32($b, 0x3C)
  $entRva  = [BitConverter]::ToUInt32($b, $peOff + 24 + 16)
  $nSec    = [BitConverter]::ToUInt16($b, $peOff + 6)
  $optSize = [BitConverter]::ToUInt16($b, $peOff + 20)
  $secOff  = $peOff + 24 + $optSize
  $tPtr = 0; $tRaw = 0; $tVa = 0
  for ($i = 0; $i -lt $nSec; $i++) {
    $s = $secOff + $i * 40
    $ch = [BitConverter]::ToUInt32($b, $s + 36)
    if ($i -eq 0) { $tVa = [BitConverter]::ToUInt32($b, $s + 12); $tPtr = [BitConverter]::ToUInt32($b, $s + 20); $tRaw = [BitConverter]::ToUInt32($b, $s + 16) }
    if (($ch -band 0x20000000) -ne 0) {
      $va = [BitConverter]::ToUInt32($b, $s + 12); $vsz = [BitConverter]::ToUInt32($b, $s + 8); $ptr = [BitConverter]::ToUInt32($b, $s + 20)
      if ($entRva -ge $va -and $entRva -lt ($va + $vsz)) {
        $tVa = $va; $tPtr = $ptr; $tRaw = [BitConverter]::ToUInt32($b, $s + 16)
      }
    }
  }
  return [pscustomobject]@{ entry=$entRva; textVa=$tVa; textPtr=$tPtr; textRaw=$tRaw; entryPtr=($entRva - $tVa + $tPtr) }
}

$full = [IO.Path]::GetFullPath($Exe)
if (-not (Test-Path $full)) { throw "找不到 $full" }
$pe = PE-Info $full
$fo  = $pe.entryPtr
if ($From -gt 0) { $fo = $From }
$len = $pe.textRaw
if ($Budget -gt 0 -and $Budget -lt $len) { $len = $Budget }
if ($Symbol -ne "") {
  # 用符号表定界（gcc 产物可用；FLINT 裸 PE 没有符号表 → 走 -From 手给区间）
  $symOut = & $objdump -t $full 2>$null
  $symAddr = 0; $symSize = 0; $nextAddr = [long]::MaxValue
  foreach ($l in $symOut) {
    if ($l -match '^\s*([0-9a-f]+)\s+(\S+)\s+([0-9a-f]+)\s+(\S+)\s+([0-9a-f]+)\s+(\S+)\s*$') {
      $a = [Convert]::ToInt64($matches[1], 16)
      $sz = [Convert]::ToInt64($matches[3], 16)
      $nm = $matches[6]
      if ($nm -eq $Symbol) { $symAddr = $a; $symSize = $sz }
      elseif ($symAddr -gt 0 -and $a -gt $symAddr -and $a -lt $nextAddr) { $nextAddr = $a }
    }
  }
  if ($symAddr -gt 0) {
    if ($symSize -le 0) { $symSize = if ($nextAddr -lt [long]::MaxValue) { $nextAddr - $symAddr } else { 512 } }
    $fo  = $symAddr - $pe.textVa + $pe.textPtr
    $len = [int]$symSize
    Write-Host ("[符号窗口] {0} 0x{1:X}（RVA），长度 {2} 字节" -f $Symbol, $symAddr, $len)
  } else { Write-Host "[!] 符号 $Symbol 没找到（该产物可能没有符号表 → 用 -From 手给文件偏移）" }
}
$stop = $fo + $len

$tmp = Join-Path $env:TEMP ("ledger-" + [IO.Path]::GetFileNameWithoutExtension($full) + ".txt")
& $objdump -D -b binary -m i386:x86-64 "--adjust-vma=$fo" "--start-address=$fo" "--stop-address=$stop" $full 2>$null |
  Out-File -FilePath $tmp -Encoding ascii
$lines = Get-Content $tmp

$rows = @()
foreach ($l in $lines) {
  if ($l -match '^\s*([0-9a-f]+):\s*(([0-9a-f]{2} )+)\s+([a-z][a-z0-9.]*)\s*(.*)$') {
    $addr = [Convert]::ToInt64($matches[1], 16)
    $bytestr = $matches[3].Trim()
    $nb = ($bytestr -split '\s+').Count
    $mn = $matches[4]
    $ops = $matches[5]
    $rows += [pscustomobject]@{ addr=$addr; bytes=$nb; mn=$mn; ops=$ops }
  } elseif ($l -match '^\s*([0-9a-f]+):\s*\tbad') {
    $rows += [pscustomobject]@{ addr=[Convert]::ToInt64($matches[1],16); bytes=1; mn='(bad)'; ops='' }
  }
}
if ($rows.Count -eq 0) { throw "反汇编没出指令（检查 objdump 参数/窗口）；tmp=$tmp" }

$memRe   = '(%(rbp|rsp|rax|rbx|rcx|rdx|rsi|rdi|r8|r9|r10|r11|r12|r13|r14|r15|rip))'
$stackRe = '%(rbp|rsp)'
$memOps  = @($rows | Where-Object { $_.ops -match $memRe })
$stkOps  = @($rows | Where-Object { $_.ops -match $stackRe })
$pushpop = @($rows | Where-Object { $_.mn -match '^(push|pop)' })
$calls   = @($rows | Where-Object { $_.mn -match '^call' })
$jmps    = @($rows | Where-Object { $_.mn -match '^j' })
$badRows = @($rows | Where-Object { $_.mn -eq '(bad)' })
$regOnly = @($rows | Where-Object { ($_.ops -notmatch $memRe) -and ($_.mn -notmatch '^(j|call|ret|push|pop|leave|nop)') })
$bytes   = ($rows | Measure-Object -Property bytes -Sum).Sum

function Pct($a, $b) { if ($b -le 0) { return 'n/a' } else { return ('{0:N1}%' -f (100.0 * $a / $b)) } }

Write-Host ("===== 指令账本：{0} =====" -f [IO.Path]::GetFileName($full))
Write-Host ("窗口：入口文件偏移 0x{0:X}（RVA 0x{1:X}），长度 {2} 字节 (.text raw={3})" -f $fo, $pe.entry, $len, $pe.textRaw)
Write-Host ""
Write-Host ("  指令条数        {0}" -f $rows.Count)
Write-Host ("  指令字节数      {0}（平均 {1:N2} B/条）" -f $bytes, ($bytes / $rows.Count))
Write-Host ("  访存指令        {0}  ({1})   <-- 任何 (%reg) 形态（栈/内存）" -f $memOps.Count, (Pct $memOps.Count $rows.Count))
Write-Host ("  栈/帧访问       {0}  ({1})   <-- (%rbp) / (%rsp)" -f $stkOps.Count, (Pct $stkOps.Count $rows.Count))
Write-Host ("  push/pop        {0}  ({1})" -f $pushpop.Count, (Pct $pushpop.Count $rows.Count))
Write-Host ("  纯寄存器操作    {0}  ({1})   <-- 寄存器分配落地后该升上来" -f $regOnly.Count, (Pct $regOnly.Count $rows.Count))
Write-Host ("  call            {0}" -f $calls.Count)
Write-Host ("  跳转(含回边)    {0}" -f $jmps.Count)
Write-Host ("  objdump 解不出  {0} 字节（数据/对齐填充；>0 说明窗口里有非指令字节）" -f $badRows.Count)
Write-Host ""
Write-Host ("  Top {0} 助记符（按条数）：" -f $Top)
$rows | Group-Object mn | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object {
  Write-Host ("    {0,-10} {1,6}  ({2})" -f $_.Name, $_.Count, (Pct $_.Count $rows.Count))
}
Write-Host ""
Write-Host "  访存指令 Top（这几种就是「每步过内存」的钱）："
$memOps | Group-Object mn | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object {
  Write-Host ("    {0,-10} {1,6}" -f $_.Name, $_.Count)
}

$out = [pscustomobject]@{
  exe = $full; window_bytes = $len
  insns = $rows.Count; code_bytes = $bytes; bytes_per_insn = [Math]::Round($bytes / $rows.Count, 3)
  mem = $memOps.Count; stack = $stkOps.Count; pushpop = $pushpop.Count
  reg_only = $regOnly.Count; calls = $calls.Count; jumps = $jmps.Count; bad_bytes = $badRows.Count
  hist = ($rows | Group-Object mn | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{ mn=$_.Name; n=$_.Count } })
}
$json = Join-Path (Split-Path $full -Parent) ("ledger-" + [IO.Path]::GetFileNameWithoutExtension($full) + ".json")
$out | ConvertTo-Json -Depth 5 | Out-File -FilePath $json -Encoding UTF8
Write-Host ""
Write-Host ("已落盘：{0}" -f $json)
