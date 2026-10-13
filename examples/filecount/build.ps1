# build.ps1 -- the "filecount" example in ONE command: compile + run + assert.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\filecount\build.ps1
#
# What is asserted, all from raw bytes:
#   a) exit code == line count (mod 256);
#   b) stdout is byte-identical to "in=<path> bytes=<n> lines=<m> out=<path>" (the numbers are
#      recomputed HERE by walking the input file's bytes -- the program's own print is not used
#      as the expectation);
#   c) the produced copy is byte-identical to the input file.
#
# The input is copied into tmp\ first, so the example directory only ever holds source files.
# ASCII-only on purpose: no BOM needed, nothing for PowerShell 5.1 to mis-decode.
$ErrorActionPreference = 'Stop'

$name    = 'filecount'
$here    = $PSScriptRoot
$root    = Split-Path -Parent (Split-Path -Parent $here)
$flint   = Join-Path $root 'flint.exe'
$src     = Join-Path $here 'main.fl'
$exe     = Join-Path $here "$name.exe"
$inSrc   = Join-Path $here 'sample.txt'
$tmpDir  = Join-Path $root "tmp\examples\$name"
$inFile  = Join-Path $tmpDir 'sample.txt'
$copyFile = "$inFile.copy"
$stdout  = Join-Path ([System.IO.Path]::GetTempPath()) "${name}.stdout.bin"

if (-not (Test-Path $flint)) {
  Write-Host "FAIL: flint.exe not found at $flint"
  Write-Host "      build it first: cmd /c `"gcc -O2 src\*.c -o flint.exe`"   (run from the repo root)"
  exit 1
}

function Test-BytesEqual([byte[]]$a, [byte[]]$b) {
  if ($a.Length -ne $b.Length) { return $false }
  for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
  return $true
}

# ---- 1) compile --------------------------------------------------------------------------
& $flint $src -o $exe
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: flint.exe exit=$LASTEXITCODE"; exit 1 }
if (-not (Test-Path $exe)) { Write-Host "FAIL: no $exe produced"; exit 1 }
Write-Host ("[{0}] compiled: {1} bytes" -f $name, (Get-Item $exe).Length)

# ---- 2) the referee reads the input bytes itself ----------------------------------------
$inBytes = [System.IO.File]::ReadAllBytes($inSrc)
$wantBytes = $inBytes.Length
$wantLines = 0
foreach ($b in $inBytes) { if ($b -eq 10) { $wantLines++ } }
if ($wantBytes -gt 0 -and $inBytes[$wantBytes - 1] -ne 10) { $wantLines++ }
$wantCode = $wantLines % 256

# ---- 3) run it on a copy that lives in tmp\ ---------------------------------------------
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Copy-Item -LiteralPath $inSrc -Destination $inFile -Force
if (Test-Path $copyFile) { Remove-Item -LiteralPath $copyFile -Force }

$proc = Start-Process -FilePath $exe -ArgumentList @($inFile) -NoNewWindow -RedirectStandardOutput $stdout -Wait -PassThru
$code = $proc.ExitCode
$got  = [System.IO.File]::ReadAllBytes($stdout)

$wantOut = [System.Text.Encoding]::ASCII.GetBytes("in=$inFile bytes=$wantBytes lines=$wantLines out=$copyFile" + [char]10)
$sameOut = Test-BytesEqual $got $wantOut

Write-Host ("[{0}] referee   : bytes={1} lines={2} -> exit {3}" -f $name, $wantBytes, $wantLines, $wantCode)
Write-Host ("[{0}] exit code : {1} (want {2})" -f $name, $code, $wantCode)
Write-Host ("[{0}] stdout    : {1}" -f $name, ([System.Text.Encoding]::ASCII.GetString($got)).TrimEnd())
Write-Host ("[{0}] expected  : {1}" -f $name, ([System.Text.Encoding]::ASCII.GetString($wantOut)).TrimEnd())

if ($code -ne $wantCode) { Write-Host "FAIL: exit code $code != $wantCode"; exit 1 }
if (-not $sameOut)       { Write-Host "FAIL: stdout does not match the referee's line"; exit 1 }

# ---- 4) the copy must be byte-identical --------------------------------------------------
if (-not (Test-Path $copyFile)) { Write-Host "FAIL: no copy written at $copyFile"; exit 1 }
$copyBytes = [System.IO.File]::ReadAllBytes($copyFile)
$same = Test-BytesEqual $inBytes $copyBytes
$h1 = (Get-FileHash -LiteralPath $inFile -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $copyFile -Algorithm SHA256).Hash
Write-Host ("[{0}] copy      : {1} bytes, sha256 {2}" -f $name, $copyBytes.Length, $h2.Substring(0, 16))
Write-Host ("[{0}] input     : {1} bytes, sha256 {2}" -f $name, $inBytes.Length, $h1.Substring(0, 16))
if (-not $same) { Write-Host "FAIL: the copy is not byte-identical to the input"; exit 1 }

Write-Host "[$name] OK"
exit 0
