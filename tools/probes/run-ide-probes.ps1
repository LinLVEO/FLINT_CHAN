# run-ide-probes.ps1 - run the FLINT Studio probe suite sequentially, one PASS/FAIL line each.
# Why sequential: every probe injects keys/clicks into its own sandbox window and needs the
# foreground, so parallel runs steal each other's focus (false FAILs / SKIPs).
# Usage: pwsh -NoProfile -File tmp\run-ide-probes.ps1 [-Only a,b,c] [-Log path]
param(
    [string[]]$Only,
    [string]$Log = '',
    [int]$PerProbeTimeoutSec = 240
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot)
if ($Log -eq '') { $Log = Join-Path $root ("tmp\probe-suite-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

# order: fast/most-likely-broken first, then the rest
$all = @(
    'snapshot',
    'probe-ide-cjksize',
    'probe-ide-settings',
    'probe-ide-render',
    'probe-ide-scroll',
    'probe-ide-find',
    'probe-ide-replace',
    'probe-ide-diag',
    'probe-ide-wrap',
    'probe-ide-wrap-hl',
    'probe-ide-sel',
    'probe-ide-resize',
    'probe-win-ctl',        # NOTE: no "ide-" prefix (historical name)
    'probe-ide-tree',
    'probe-ide-ws',
    'probe-ide-menu',
    'probe-ide-edit2',
    'probe-ide-repeat',
    'probe-ide-ime',
    'probe-ide-cfg',
    'probe-ide-dlgdir',
    'probe-ide-term',
    'probe-shim'
)
if ($null -ne $Only -and $Only.Count -gt 0) {
    # `pwsh -File ... -Only a,b` hands over ONE string "a,b" (no comma parsing on argv)
    if ($Only.Count -eq 1 -and $Only[0] -like '*,*') { $Only = @($Only[0] -split ',') }
    $all = $Only
}

$rows = @()
"# suite {0} ({1} probes) log={2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $all.Count, $Log | Out-File -FilePath $Log -Encoding utf8
foreach ($name in $all) {
    $path = Join-Path $PSScriptRoot ("{0}.ps1" -f $name)
    if (-not (Test-Path $path)) { $rows += [pscustomobject]@{ Name = $name; Code = -1; Result = 'MISSING'; Sec = 0 }; continue }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()
    $res = ($out -split "`r?`n" | Where-Object { $_ -match '^RESULT\s' } | Select-Object -Last 1)
    if (-not $res) { $res = 'RESULT (none)' }
    $rows += [pscustomobject]@{ Name = $name; Code = $code; Result = $res.Trim(); Sec = [int]$sw.Elapsed.TotalSeconds }
    Add-Content -Path $Log -Value ("===== {0}  exit={1}  {2:N1}s" -f $name, $code, $sw.Elapsed.TotalSeconds)
    Add-Content -Path $Log -Value $out
}
$pass = ($rows | Where-Object { $_.Code -eq 0 }).Count
$skip = ($rows | Where-Object { $_.Code -eq 2 }).Count
$fail = ($rows | Where-Object { $_.Code -eq 1 -or $_.Code -eq -1 }).Count
Write-Host ''
Write-Host ("SUITE  pass={0} fail={1} skip={2} total={3}" -f $pass, $fail, $skip, $rows.Count)
foreach ($r in $rows) {
    Write-Host ("  {0,-5} {1,4}s  {2}" -f $(if ($r.Code -eq 0) { 'PASS' } elseif ($r.Code -eq 2) { 'SKIP' } else { 'FAIL' }), $r.Sec, $r.Name)
}
Write-Host ("LOG    {0}" -f $Log)
if ($fail -gt 0) { exit 1 } else { exit 0 }
