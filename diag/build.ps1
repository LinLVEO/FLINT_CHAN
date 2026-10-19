# diag/build.ps1 -- build fltdiag.dll + fltdiag.exe + the two self-test programs
# ASCII only on purpose: a .ps1 with CJK literals needs a BOM, and every editor/`edit`
# strips it, after which PS 5.1 decodes GBK and raises fake syntax errors (known trap).
param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host '[1/3] build fltdiag.dll'
gcc -O2 -shared -o diag\fltdiag.dll diag\diag.c -lpsapi -static-libgcc
if ($LASTEXITCODE -ne 0) { throw 'gcc failed building fltdiag.dll' }

Write-Host '[2/3] build fltdiag.exe'
gcc -O2 -o diag\fltdiag.exe diag\fltdiag.c -lpsapi -static-libgcc
if ($LASTEXITCODE -ne 0) { throw 'gcc failed building fltdiag.exe' }

Write-Host '[3/3] build self-tests'
Copy-Item diag\fltdiag.dll diag\test\fltdiag.dll -Force
gcc -O2 -o diag\test\crash_c.exe diag\test\crash_c.c diag\fltdiag.dll -static-libgcc
if ($LASTEXITCODE -ne 0) { throw 'gcc failed building crash_c.exe' }
gcc -O2 -o diag\test\exit3.exe diag\test\exit3.c -static-libgcc
if ($LASTEXITCODE -ne 0) { throw 'gcc failed building exit3.exe' }

if (-not $SkipTests) {
    Write-Host '--- smoke test: in-process crash (DLL) ---'
    Remove-Item diag\test\fltdiag\crash-* -Force -ErrorAction SilentlyContinue
    & .\diag\test\crash_c.exe | Out-Null
    Start-Sleep -Milliseconds 400
    $n = (Get-ChildItem diag\test\fltdiag -Filter 'crash-*.txt' -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($n -lt 1) { throw 'in-process crash report was NOT written' }

    Write-Host '--- smoke test: external tool on nonzero exit ---'
    $out = & .\diag\fltdiag.exe run diag\test\exit3.exe 2>&1
    if (-not ($out -match 'EXIT 3')) { throw 'external tool did not report exit code 3' }
    Write-Host 'all smoke tests passed'
}
