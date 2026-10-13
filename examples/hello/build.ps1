# build.ps1 -- the "hello" example in ONE command: compile + run + assert.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\hello\build.ps1
#
# Exit code 0 = everything held; 1 = something failed (the failing line says what).
#
# Why the expected stdout is computed HERE and not copied from the program's own output:
# an assert that reads the program's output as its own expectation only proves the program
# agrees with itself. `2 + 3` below is added by PowerShell -- that is the independent referee.
#
# ASCII-only on purpose: PowerShell 5.1 decodes a BOM-less file as GBK, so a Chinese comment
# here could be torn in half and produce a bogus parse error. Zero non-ASCII bytes = nothing to get wrong.
$ErrorActionPreference = 'Stop'

$name    = 'hello'
$here    = $PSScriptRoot                                    # examples\hello
$root    = Split-Path -Parent (Split-Path -Parent $here)     # repo root
$flint   = Join-Path $root 'flint.exe'
$src     = Join-Path $here 'hello.fl'
$exe     = Join-Path $here 'hello.exe'
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("${name}.stdout.bin")

if (-not (Test-Path $flint)) {
  Write-Host "FAIL: flint.exe not found at $flint"
  Write-Host "      build it first: cmd /c `"gcc -O2 src\*.c -o flint.exe`"   (run from the repo root)"
  exit 1
}

# ---- 1) compile -------------------------------------------------------------------------
& $flint $src
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: flint.exe exit=$LASTEXITCODE"; exit 1 }
if (-not (Test-Path $exe)) { Write-Host "FAIL: no $exe produced"; exit 1 }
$exeSize = (Get-Item $exe).Length

# ---- 2) run, keeping stdout as RAW BYTES -------------------------------------------------
# Start-Process writes the child's stdout straight into the file (no text decoding), so the
# comparison below is byte-for-byte -- "looks about right" is not an assert.
$proc = Start-Process -FilePath $exe -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
$code = $proc.ExitCode
$got  = [System.IO.File]::ReadAllBytes($outFile)

# ---- 3) independent expectation ----------------------------------------------------------
$expect = [System.Text.Encoding]::ASCII.GetBytes("hello, flint" + [char]10 + "2 + 3 = " + (2 + 3) + [char]10)
$same = ($got.Length -eq $expect.Length)
if ($same) { for ($i = 0; $i -lt $expect.Length; $i++) { if ($got[$i] -ne $expect[$i]) { $same = $false } } }

Write-Host ("[{0}] compiled      : exit=0, {1} bytes ({2})" -f $name, $exeSize, (Split-Path -Leaf $exe))
Write-Host ("[{0}] exit code     : {1} (want 0)" -f $name, $code)
Write-Host ("[{0}] stdout bytes  : {1} (want {2})" -f $name, $got.Length, $expect.Length)
Write-Host ("[{0}] stdout hex    : {1}" -f $name, (($got | ForEach-Object { $_.ToString('X2') }) -join ' '))
Write-Host ("[{0}] expected hex  : {1}" -f $name, (($expect | ForEach-Object { $_.ToString('X2') }) -join ' '))

if ($code -ne 0)  { Write-Host "FAIL: exit code $code != 0"; exit 1 }
if (-not $same)   { Write-Host "FAIL: stdout is not byte-identical to the expected bytes"; exit 1 }
Write-Host "[$name] OK"
exit 0
