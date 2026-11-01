# bytecmp.ps1 -- A/B compile the same .fl corpus with two hlc.exe builds and compare the
# produced PE bytes (SHA256). Pure dev instrument: a refactor that changes no behaviour must
# reproduce every product byte-for-byte.
#
# USAGE:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bytecmp.ps1 -A hlc.exe -B tmp\hlc-ref.exe
#   ... -Samples test\samples -Out <dir>
#
# EXIT: 0 = every product identical; 1 = at least one diff / compile failure; 2 = bad args.
param(
    [Parameter(Mandatory = $true)][string]$A,
    [Parameter(Mandatory = $true)][string]$B,
    [string]$Samples = 'test\samples',
    [string]$Out = ''
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$lab = Split-Path $PSScriptRoot -Parent
function Abs([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p } return (Join-Path $lab $p) }
$A = Abs $A; $B = Abs $B; $Samples = Abs $Samples
if (-not (Test-Path $A)) { Write-Host "A not found: $A"; exit 2 }
if (-not (Test-Path $B)) { Write-Host "B not found: $B"; exit 2 }
if (-not $Out) { $Out = Join-Path $env:TEMP ('bytecmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$files = @(Get-ChildItem -Path $Samples -Filter *.fl -Recurse | Sort-Object FullName)
if ($files.Count -eq 0) { Write-Host "no .fl under $Samples"; exit 2 }
Write-Host ("bytecmp: {0} samples, A={1}, B={2}, out={3}" -f $files.Count, $A, $B, $Out)

function Compile-One([string]$exe, [string]$src, [string]$tag) {
    $dst = Join-Path $Out $tag
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $o = Join-Path $dst ((Split-Path $src -Leaf) + '.exe')
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $r = & $exe -o $o $src 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { return @{ ok = $false; msg = ($r | Out-String).Trim() } }
    if (-not (Test-Path $o)) { return @{ ok = $false; msg = 'no exe' } }
    return @{ ok = $true; hash = (Get-FileHash $o -Algorithm SHA256).Hash }
}

$diff = 0; $bad = 0; $same = 0; $skip = 0
foreach ($f in $files) {
    $ra = Compile-One $A $f.FullName 'A'
    $rb = Compile-One $B $f.FullName 'B'
    if (-not $ra.ok -and -not $rb.ok) {
        $skip++
        continue
    }
    if (-not $ra.ok -or -not $rb.ok) {
        $bad++
        Write-Host ("COMPILE-FAIL-ONE-SIDE {0} :: A={1} B={2}" -f $f.Name, $ra.ok, $rb.ok)
        continue
    }
    if ($ra.hash -ne $rb.hash) {
        $diff++
        Write-Host ("DIFF {0}" -f $f.Name)
    } else { $same++ }
}
Write-Host ("---- same={0} diff={1} one-side-fail={2} skip(both-fail)={3}" -f $same, $diff, $bad, $skip)
if ($diff -ne 0 -or $bad -ne 0) { exit 1 }
exit 0
