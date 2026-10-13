# build.ps1 -- the "cn-print" example in ONE command: regenerate the byte table, compile, run, assert.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\cn-print\build.ps1
#
# Two assertions, both of them raw bytes:
#   a) cn_gen.fl contains ZERO bytes > 127 (that IS the contract of the "Chinese via a byte
#      table" route -- if a real Chinese character ever leaks into the source, the compile step
#      would be the last place you find out);
#   b) the program's stdout is byte-identical to what .NET's GBK(936) encoder produces for the
#      same text. The expectation is built from text.txt (the source of truth) + the ASCII glue
#      that main.fl prints -- never from the program's own output.
#
# ASCII-only on purpose: this script has no BOM and no non-ASCII byte, so PowerShell 5.1 cannot
# mis-decode it. (The generator next to it DOES have Chinese comments and therefore DOES have a BOM.)
$ErrorActionPreference = 'Stop'

$name    = 'cn-print'
$here    = $PSScriptRoot
$root    = Split-Path -Parent (Split-Path -Parent $here)
$flint   = Join-Path $root 'flint.exe'
$gen     = Join-Path $here 'gen-gbk.ps1'
$txtSrc  = Join-Path $here 'text.txt'
$genFl   = Join-Path $here 'cn_gen.fl'
$src     = Join-Path $here 'main.fl'
$exe     = Join-Path $here "$name.exe"
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("${name}.stdout.bin")

if (-not (Test-Path $flint)) {
  Write-Host "FAIL: flint.exe not found at $flint"
  Write-Host "      build it first: cmd /c `"gcc -O2 src\*.c -o flint.exe`"   (run from the repo root)"
  exit 1
}

function Get-HighByteCount([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $hi = 0
  foreach ($b in $bytes) { if ($b -gt 127) { $hi++ } }
  return $hi
}

# ---- 1) regenerate cn_gen.fl from the UTF-8 text source ----------------------------------
# It runs as a CHILD process on purpose: a nested script's `exit` does not set $LASTEXITCODE,
# and running it as a process also lets its stdout be forwarded line by line below.
$genOut  = & powershell -NoProfile -ExecutionPolicy Bypass -File $gen 2>&1
$genCode = $LASTEXITCODE
foreach ($l in $genOut) { Write-Host ("[{0}] gen | {1}" -f $name, $l) }
if ($genCode -ne 0) { Write-Host "FAIL: gen-gbk.ps1 exit=$genCode"; exit 1 }

# ---- 2) the contract: generated file and hand-written source are both pure ASCII ----------
foreach ($f in @($genFl, $src)) {
  $hi = Get-HighByteCount $f
  Write-Host ("[{0}] {1,-11}: high(>127)={2} (want 0)" -f $name, (Split-Path -Leaf $f), $hi)
  if ($hi -ne 0) { Write-Host ("FAIL: {0} contains {1} non-ASCII byte(s)" -f (Split-Path -Leaf $f), $hi); exit 1 }
}

# ---- 3) compile + run --------------------------------------------------------------------
# -o gives the product the example's own name; without it flint names the exe after the source (main.exe).
& $flint $src -o $exe
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: flint.exe exit=$LASTEXITCODE"; exit 1 }
if (-not (Test-Path $exe)) { Write-Host "FAIL: no $exe produced"; exit 1 }

$proc = Start-Process -FilePath $exe -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
$code = $proc.ExitCode
$got  = [System.IO.File]::ReadAllBytes($outFile)

# ---- 4) independent expectation: text.txt -> GBK bytes, assembled by PowerShell -----------
$gbk = [System.Text.Encoding]::GetEncoding(936)
$label = ''
foreach ($ln in (Get-Content -LiteralPath $txtSrc -Encoding UTF8)) {
  if ([string]::IsNullOrWhiteSpace($ln)) { continue }
  $p = $ln -split "`t"
  if ($p.Count -ge 2 -and $p[0].Trim() -eq 'cn_temp_label') { $label = $p[1] }
}
if ($label -eq '') { Write-Host "FAIL: text.txt has no cn_temp_label entry"; exit 1 }
$expect = $gbk.GetBytes($label + ": 56 C" + [char]10)

$same = ($got.Length -eq $expect.Length)
if ($same) { for ($i = 0; $i -lt $expect.Length; $i++) { if ($got[$i] -ne $expect[$i]) { $same = $false } } }

Write-Host ("[{0}] exit code   : {1} (want 0)" -f $name, $code)
Write-Host ("[{0}] stdout hex  : {1}" -f $name, (($got | ForEach-Object { $_.ToString('X2') }) -join ' '))
Write-Host ("[{0}] expected hex: {1}" -f $name, (($expect | ForEach-Object { $_.ToString('X2') }) -join ' '))
Write-Host ("[{0}] bytes       : {1} (want {2})" -f $name, $got.Length, $expect.Length)

if ($code -ne 0) { Write-Host "FAIL: exit code $code != 0"; exit 1 }
if (-not $same)  { Write-Host "FAIL: stdout is not byte-identical to the GBK expectation"; exit 1 }
Write-Host "[$name] OK"
exit 0
