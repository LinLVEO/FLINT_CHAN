# build.ps1 -- the "window" example in ONE command: compile + run + assert.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\window\build.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File examples\window\build.ps1 -Window
#
# Default = the HEADLESS mode: no window is created, no desktop is needed, and the run is
# deterministic. What is asserted:
#   a) exit code 42 (the program's four self-check bits are all lit);
#   b) exactly one FRAME line, exactly one CMD line, exactly one POOLSUM line;
#   c) cmdn=1, over=0, err=0 on the FRAME line (nothing overflowed, nothing was dropped);
#   d) the text command carries the WHOLE label -- and the label length is read out of main.fl
#      by THIS script (an independent judge), not taken from the program's own output.
#
# -Window = the REAL window path: it is created, rendered at 60fps for 90 frames, then closes
# itself (mode word "autoclose"). Needs an interactive desktop, so it is NOT the default.
# ASCII-only on purpose: no BOM needed, nothing for PowerShell 5.1 to mis-decode.
param([switch]$Window)

$ErrorActionPreference = 'Stop'

$name    = 'window'
$here    = $PSScriptRoot
$root    = Split-Path -Parent (Split-Path -Parent $here)
$flint   = Join-Path $root 'flint.exe'
$src     = Join-Path $here 'main.fl'
$exe     = Join-Path $here "$name.exe"
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) "${name}.stdout.bin"

if (-not (Test-Path $flint)) {
  Write-Host "FAIL: flint.exe not found at $flint"
  Write-Host "      build it first: cmd /c `"gcc -O2 src\*.c -o flint.exe`"   (run from the repo root)"
  exit 1
}

# ---- 1) compile --------------------------------------------------------------------------
& $flint $src -o $exe
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: flint.exe exit=$LASTEXITCODE"; exit 1 }
if (-not (Test-Path $exe)) { Write-Host "FAIL: no $exe produced"; exit 1 }
Write-Host ("[{0}] compiled: {1} bytes (the whole FLGUI platform layer is in there)" -f $name, (Get-Item $exe).Length)

# ---- 2) the independent judge: pull the label literal out of the source -------------------
$srcText = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
$m = [regex]::Match($srcText, 'char \*w_title = "([^"]*)"')
if (-not $m.Success) { Write-Host "FAIL: main.fl has no 'char *w_title = ""..."";' line to judge against"; exit 1 }
$label = $m.Groups[1].Value
$labelLen = $label.Length

# ---- 3) headless run ---------------------------------------------------------------------
$proc = Start-Process -FilePath $exe -ArgumentList @('headless') -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
$code = $proc.ExitCode
$got  = [System.IO.File]::ReadAllBytes($outFile)
$text = [System.Text.Encoding]::ASCII.GetString($got)

$bad  = 0
$all  = @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
$frameLines = @($all | Where-Object { $_ -match '^FRAME ' })
$cmdLines   = @($all | Where-Object { $_ -match '^\s*CMD ' })
$poolLines  = @($all | Where-Object { $_ -match 'POOLSUM' })

Write-Host ("[{0}] headless exit : {1} (want 42 = all four self-check bits lit)" -f $name, $code)
foreach ($l in $all) { Write-Host ("[{0}]   dump | {1}" -f $name, $l) }
Write-Host ("[{0}] judge        : label from main.fl = ""{1}"" ({2} bytes)" -f $name, $label, $labelLen)

if ($code -ne 42)      { Write-Host "      FAIL: exit code $code != 42"; $bad++ }
if ($frameLines.Count -ne 1) { Write-Host "      FAIL: expected exactly one FRAME line, got $($frameLines.Count)"; $bad++ }
if ($cmdLines.Count -ne 1)   { Write-Host "      FAIL: expected exactly one CMD line, got $($cmdLines.Count)"; $bad++ }
if ($poolLines.Count -ne 1)  { Write-Host "      FAIL: expected exactly one POOLSUM line, got $($poolLines.Count)"; $bad++ }

if ($frameLines.Count -eq 1) {
  $f = $frameLines[0]
  if ($f -notmatch 'cmdn=1\b') { Write-Host "      FAIL: frame did not report exactly one command"; $bad++ }
  if ($f -notmatch 'over=0\b') { Write-Host "      FAIL: command table overflowed (over != 0)"; $bad++ }
  if ($f -notmatch 'err=0\b')  { Write-Host "      FAIL: context error bits are set (err != 0)"; $bad++ }
}
if ($cmdLines.Count -eq 1) {
  $c = $cmdLines[0]
  $cm = [regex]::Match($c, 'kind=(\d+) rect=(-?\d+),(-?\d+),(\d+),(\d+) text=(\d+),(\d+)\s*$')
  if (-not $cm.Success) { Write-Host "      FAIL: CMD line does not parse: $c"; $bad++ }
  else {
    $kind = [int]$cm.Groups[1].Value
    $toff = [int]$cm.Groups[6].Value
    $tlen = [int]$cm.Groups[7].Value
    if ($kind -ne 5)         { Write-Host "      FAIL: kind=$kind, want 5 (text)"; $bad++ }
    if ($tlen -ne $labelLen) { Write-Host "      FAIL: tlen=$tlen, want $labelLen (the whole label)"; $bad++ }
    if ($toff + $tlen -gt 4096) { Write-Host "      FAIL: text=$toff,$tlen runs past the 4096-byte arena"; $bad++ }
    Write-Host ("[{0}] text command : kind={1} toff={2} tlen={3}" -f $name, $kind, $toff, $tlen)
  }
}

# ---- 4) optional: the real window --------------------------------------------------------
if ($Window) {
  Write-Host ("[{0}] real window  : running 'autoclose' (90 frames at the 60fps target)..." -f $name)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $wp = Start-Process -FilePath $exe -ArgumentList @('autoclose') -NoNewWindow -RedirectStandardOutput $outFile -Wait -PassThru
  $sw.Stop()
  $secs = $sw.Elapsed.TotalSeconds
  Write-Host ("[{0}] real window  : exit={1} elapsed={2:N2}s" -f $name, $wp.ExitCode, $secs)
  if ($wp.ExitCode -ne 0) { Write-Host "      FAIL: the real window path exited $($wp.ExitCode) (90 = no window, 91 = no surface)"; $bad++ }
  if ($secs -lt 0.5)      { Write-Host "      FAIL: it returned in $secs s -- 90 paced frames cannot be that fast"; $bad++ }
}

if ($bad -ne 0) { Write-Host "FAIL: $bad assertion(s) failed"; exit 1 }
Write-Host "[$name] OK"
exit 0
