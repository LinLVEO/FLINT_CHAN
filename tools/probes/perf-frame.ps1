# perf-frame.ps1 - how much CPU does one repaint cost? Two phases:
#   IDLE  : 2s with no input (the app should skip painting entirely -> ~0 CPU)
#   BURST : N discrete Down presses (each one moves the caret => 1 repaint)
# Usage: pwsh -File tmp\perf-frame.ps1 -Tag before
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [string]$Tag = 'current',
    [int]$Presses = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$Sand = Join-Path $Root 'tmp\ide-perf'
$SrcDir = Join-Path $Sand 'apps\studio_native'
New-Item -ItemType Directory -Force $SrcDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
$body = New-Object System.Text.StringBuilder
for ($i = 1; $i -le 200; $i++) {
    [void]$body.AppendLine(("int v{0} = {1};  // 注释 comment {2}" -f $i, $i, $i))
}
[System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), $body.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$cfg = @('font=Consolas', 'size=15', 'weight=400', 'cjk=Noto Sans SC Medium', 'cjksize=0', 'wrap=0', 'ui=20',
    'winx=120', 'winy=90', 'winw=1000', 'winh=700', 'winmax=0', 'tree=0', 'file=apps/studio_native/main.fl') -join "`n"
[System.IO.File]::WriteAllText((Join-Path $Sand 'studio.cfg'), $cfg + "`n", [System.Text.Encoding]::ASCII)

$app = $null
try {
    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc) { throw 'did not start' }
    Position-Window $app.Hwnd
    [void](Wait-Stable $app.Hwnd 1500 40)
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'focus stolen' }
    Start-Sleep -Milliseconds 1000
    $p = Get-Process -Id $app.Proc.Id
    $p.Refresh()
    $cpu0 = $p.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Milliseconds 2000
    $p.Refresh()
    $idleMs = $p.TotalProcessorTime.TotalMilliseconds - $cpu0

    Start-Sleep -Milliseconds 300
    $p.Refresh()
    $cpu2 = $p.TotalProcessorTime.TotalMilliseconds
    for ($i = 0; $i -lt $Presses; $i++) {
        [Ide]::Key(0x28, $false, $false)     # Down
        Start-Sleep -Milliseconds 12
    }
    Start-Sleep -Milliseconds 400
    $p.Refresh()
    $burstMs = $p.TotalProcessorTime.TotalMilliseconds - $cpu2
    Write-Host ("PERF {0,-8} idle={1,6:N0}ms/2s  burst={2,6:N0}ms for {3} repaints => {4:N2} ms/frame CPU" -f `
            $Tag, $idleMs, $burstMs, $Presses, ($burstMs / $Presses))
}
finally {
    Stop-Studio $app $Root
}
