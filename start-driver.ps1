# start-driver.ps1 — 启动 WinRing0 驱动（FLINT 硬件通道的前置，需管理员 UAC）
# 用途：WinRing0_1_2_0 服务已注册（LHM 遗留 DEMAND_START），但 .sys 在 Temp 易被清
# 本脚本：① 从 LibreHardwareMonitorLib.dll 内嵌资源提取 WinRing0x64.sys（FF 前缀 gzip）
#         ② 放到服务 ImagePath 指向的路径 ③ UAC 提权启动服务 ④ 验证 RUNNING
# 用法：powershell -ExecutionPolicy Bypass -File E:\FLINT\start-driver.ps1
# 依赖：E:\HardwareMonitor\bin\Debug\net8.0-windows\LibreHardwareMonitorLib.dll（LHM 库，内嵌驱动）
$ErrorActionPreference = "Stop"
$dll = "E:\HardwareMonitor\bin\Debug\net8.0-windows\LibreHardwareMonitorLib.dll"
if (-not (Test-Path $dll)) { Write-Output "LHM dll not found: $dll"; exit 1 }
# 1. 提取 .sys 到服务 ImagePath 路径
$img = (sc.exe qc WinRing0_1_2_0 | Select-String "BINARY_PATH_NAME" | ForEach-Object { ($_ -split ":", 2)[1].Trim() })
$sys = $img -replace '^\\\\\?\?\\', ''   # 去掉 \??\ 前缀
if (-not $sys) { Write-Output "cannot read service ImagePath"; exit 1 }
$dir = Split-Path $sys
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$asm = [System.Reflection.Assembly]::LoadFrom($dll)
$s = $asm.GetManifestResourceStream("LibreHardwareMonitor.Resources.WinRing0x64.gz")
$len = [int]$s.Length
$raw = [byte[]]::new($len)
[void]$s.Read($raw, 0, $len)
$s.Dispose()
$ms = [System.IO.MemoryStream]::new($raw, 1, $len - 1)   # 跳过 FF 前缀
$gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
$fs = [System.IO.File]::Create($sys)
$gz.CopyTo($fs)
$fs.Dispose(); $gz.Dispose(); $ms.Dispose()
Write-Output ("driver extracted: " + (Get-Item $sys).Length + " bytes -> " + $sys)
# 2. 启动（UAC 弹窗请点"是"）
Start-Process -FilePath "sc.exe" -ArgumentList "start", "WinRing0_1_2_0" -Verb RunAs -Wait
Start-Sleep -Milliseconds 800
$st = (sc.exe query WinRing0_1_2_0 | Select-String "STATE").ToString()
Write-Output ("service state: " + $st)
if ($st -match "RUNNING") { Write-Output "OK: driver running, FLINT hardware reads ready" } else { Write-Output "NOT RUNNING - check UAC / signature" }
