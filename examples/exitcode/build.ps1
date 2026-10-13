# build.ps1 -- the "exitcode" example in ONE command: compile + run + assert.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\exitcode\build.ps1
#
# The point of this example is that the RESULT IS THE EXIT CODE, so no output parsing is needed
# to assert it. The expected code is recomputed here, in PowerShell, from the same words --
# byte sum mod 256 -- and compared with the child process's real exit code AND with its stdout.
#
# ASCII-only on purpose: no BOM needed, nothing for PowerShell 5.1 to mis-decode.
$ErrorActionPreference = 'Stop'

$name    = 'exitcode'
$here    = $PSScriptRoot
$root    = Split-Path -Parent (Split-Path -Parent $here)
$flint   = Join-Path $root 'flint.exe'
$src     = Join-Path $here 'main.fl'
$exe     = Join-Path $here "$name.exe"
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("${name}.stdout.bin")

if (-not (Test-Path $flint)) {
  Write-Host "FAIL: flint.exe not found at $flint"
  Write-Host "      build it first: cmd /c `"gcc -O2 src\*.c -o flint.exe`"   (run from the repo root)"
  exit 1
}

function Invoke-Capture([string]$exePath, [string[]]$argv) {
  if ($argv.Count -gt 0) {
    $p = Start-Process -FilePath $exePath -ArgumentList $argv -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
  } else {
    $p = Start-Process -FilePath $exePath -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
  }
  return @{ Code = $p.ExitCode; Bytes = [System.IO.File]::ReadAllBytes($outFile) }
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

# ---- 2) run it with several words; the referee recomputes the expected exit code ----------
$bad = 0
$cases = @(
  'flint',
  'FLINT-lab',
  'Zz9',
  'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
)
foreach ($w in $cases) {
  $sum = 0
  foreach ($b in [System.Text.Encoding]::ASCII.GetBytes($w)) { $sum = $sum + $b }
  $wantCode = $sum % 256
  $r = Invoke-Capture $exe @($w)
  $wantBytes = [System.Text.Encoding]::ASCII.GetBytes("word=$w len=$($w.Length) sum=$sum exit=$wantCode" + [char]10)
  $same = Test-BytesEqual $r.Bytes $wantBytes
  if ($same) { $flag = 'match' } else { $flag = 'DIFFER' }
  Write-Host ("[{0}] arg={1,-64} exit={2,3} (want {3,3})  stdout={4}  bytes={5}/{6}" -f `
      $name, "'$w'", $r.Code, $wantCode, $flag, $r.Bytes.Length, $wantBytes.Length)
  if ($r.Code -ne $wantCode) { Write-Host "      FAIL: exit code $($r.Code) != $wantCode"; $bad++ }
  if (-not $same)            { Write-Host "      FAIL: stdout != '$($w)' line"; $bad++ }
}

# ---- 3) no argument at all: usage line + exit 1 (a tool has to be usable wrongly, too) ----
$r0 = Invoke-Capture $exe @()
$t0 = [System.Text.Encoding]::ASCII.GetString($r0.Bytes)
Write-Host ("[{0}] no arg -> exit={1} (want 1), stdout='{2}'" -f $name, $r0.Code, $t0.TrimEnd())
if ($r0.Code -ne 1) { Write-Host "      FAIL: exit code $($r0.Code) != 1"; $bad++ }
if ($t0 -notlike '*usage*') { Write-Host "      FAIL: no usage line"; $bad++ }

if ($bad -ne 0) { Write-Host "FAIL: $bad assertion(s) failed"; exit 1 }
Write-Host "[$name] OK"
exit 0
