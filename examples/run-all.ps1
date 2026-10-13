# run-all.ps1 -- ONE command for all five examples: compile + run + assert each one.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\run-all.ps1
#
# Output ends with a single line:   examples: N/N passed
# Exit code 0 = all five passed, 1 = at least one failed.
# The full transcript is also written to tmp\examples\run-all.log (tmp\ is git-ignored).
#
# Each example is a separate child process (build.ps1), which keeps this script dumb: it does
# not know what any example asserts, it only reads exit codes. That is also why the examples
# are gated one at a time -- the rule is ONE compile per directory at any moment, and the five
# examples live in five different directories.
#
# ASCII-only on purpose: no BOM needed, nothing for PowerShell 5.1 to mis-decode.
param([string]$LogPath = "")

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
if ($LogPath -eq "") { $LogPath = Join-Path $root 'tmp\examples\run-all.log' }
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$names = @('hello', 'cn-print', 'exitcode', 'filecount', 'window')
$lines = @()
function Say([string]$m) {
  Write-Host $m
  $script:lines += $m
}

Say ("examples run-all : {0} examples, {1}" -f $names.Count, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$pass = 0
$t0 = Get-Date
foreach ($n in $names) {
  $b = Join-Path $here "$n\build.ps1"
  Say ""
  Say ("---- {0} ----" -f $n)
  if (-not (Test-Path $b)) { Say ("FAIL {0}: no build.ps1 at {1}" -f $n, $b); continue }
  $out  = & powershell -NoProfile -ExecutionPolicy Bypass -File $b 2>&1
  $code = $LASTEXITCODE
  foreach ($l in $out) { Say ("    " + $l) }
  if ($code -eq 0) {
    $pass = $pass + 1
    Say ("ok   {0} (exit 0)" -f $n)
  } else {
    Say ("FAIL {0} (exit {1})" -f $n, $code)
  }
}
$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

Say ""
Say ("examples: {0}/{1} passed   ({2}s)" -f $pass, $names.Count, $secs)
Say "hint: examples\window\build.ps1 -Window also smoke-tests the REAL window (needs a desktop)."
Set-Content -LiteralPath $LogPath -Value $lines -Encoding UTF8
Write-Host ("log: {0}" -f $LogPath)

if ($pass -ne $names.Count) { exit 1 }
exit 0
