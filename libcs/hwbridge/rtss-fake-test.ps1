# rtss-fake-test.ps1 -- prove HwBridge's RTSS FPS channel on a CONTROLLED fake shared memory.
#
# Why: RTSS currently has no hooked application, so the real map carries no frame times. Without a
# controlled sample we could only say "the offsets look right". This builds a map with the exact
# RTSS v2 layout, points the bridge at it via HWBRIDGE_RTSS_MAP, and checks the exported values.
#
# ASCII ONLY on purpose: PS 5.1 decodes BOM-less non-ASCII scripts as GBK -> mojibake (known trap).
param(
    [string]$Dll = 'E:\FLINT-lab\libcs\hwbridge\out\HwBridge.dll',
    [string]$CheckExe = 'E:\FLINT-lab\libcs\hwbridge\hwcheck.exe',
    [string]$Log = 'E:\FLINT-lab\libcs\hwbridge\rtss_fake.log',
    [int]$FrameTimeUs = 8333,        # 8333 us -> 1000000/8333 = 120.0 fps
    [string]$MapName = 'HwBridgeTestRtss'
)
$ErrorActionPreference = 'Stop'

$entrySize = 512
$arrOffset = 128
$arrSize = 4
$size = $arrOffset + $entrySize * $arrSize

$mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($MapName, $size)
$v = $mmf.CreateViewAccessor(0, $size)
$v.Write(0, [uint32]0x52545353)      # 'RTSS'
$v.Write(8, [uint32]$entrySize)
$v.Write(12, [uint32]$arrOffset)
$v.Write(16, [uint32]$arrSize)
$v.Write(64, [uint32]0)              # dwLastForegroundApp = 0 -> entry 0 is the target

$b = $arrOffset
$v.Write($b + 0, [uint32]4242)           # dwProcessID (fake)
$v.Write($b + 264, [uint32]0x0001000B)   # dwFlags: low16 = API type (nonzero) / high16 = arch
$v.Write($b + 268, [uint32]1000)         # dwTime0
$v.Write($b + 272, [uint32]6000)         # dwTime1
$v.Write($b + 276, [uint32]600)          # dwFrames
$v.Write($b + 280, [uint32]$FrameTimeUs) # dwFrameTime (us)
$v.Flush()

$env:HWBRIDGE_RTSS_MAP = $MapName
Remove-Item $Log -ErrorAction SilentlyContinue
& $CheckExe $Dll $Log | Out-Null
"hwcheck exit = $LASTEXITCODE   (42 = CPU temp valid, 41 = call ok but no CPU temp)"
Get-Content $Log -Encoding UTF8 | Select-String -Pattern 'hw_init|fps|FLAGS|Attached' | ForEach-Object { $_.Line }

$v.Dispose()
$mmf.Dispose()
Remove-Item Env:\HWBRIDGE_RTSS_MAP -ErrorAction SilentlyContinue
"expected: hw_init bit3 (RTSS) set, fps = 120000, fps_low invalid (fewer than 20 samples)"
