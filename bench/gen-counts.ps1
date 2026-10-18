# gen-counts.ps1 —— 为每个基准核生成"单核轮数 = N"的常量（供两侧共用）
# 立卡：T-20260919-010437（周期0）
# 用法：& .\gen-counts.ps1 -N 2097152
# 为什么需要它：先前把三个核串在一次运行里量（每核被跑 3 遍），时间上无法分辨"每核各跑了多久"；
# 改成"一次只量一个核"后，累计 ticks 与轮数一一对应 —— 下面这张表就是那个对应关系的单一来源。
param([long]$N = 2097152)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

# FLINT 侧：N 沿用同一个文件（bench_flint.dat，4 字节小端）
[IO.File]::WriteAllBytes((Join-Path $dir 'bench_flint.dat'), [BitConverter]::GetBytes([int]$N))

# 核轮数：三份实现共用一张表（C 侧 #include，FLINT/Node 侧同值）
$content = @(
  '/* bench_counts.h - 由 gen-counts.ps1 生成，请勿手改（N = 每核轮数） */',
  "#define BC_N $N",
  ''
) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $dir 'bench_counts.h'), $content, (New-Object Text.UTF8Encoding($false)))

# FLINT / Node 侧的核轮数写进一个 .fl（避免两份手抄）
$fl = @(
  '// bench_counts.fl - 由 gen-counts.ps1 生成，请勿手改（与 bench_counts.h 同值）',
  "int BC_N = $N;",
  ''
) -join "`n"
[IO.File]::WriteAllText((Join-Path $dir 'bench_counts.fl'), $fl, (New-Object Text.UTF8Encoding($false)))

Write-Output ("[gen-counts] N=$N -> bench_flint.dat / bench_counts.h / bench_counts.fl")
