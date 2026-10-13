# loop-flake-probe.ps1 -- measure the boot product's run-to-run behaviour on the real app
# (card T-20260922-201155). Writes NOTHING into the repo tree except tmp\loopflake evidence.
$ErrorActionPreference = 'Continue'
$root = 'E:\FLINT-lab'
$appDir = Join-Path $root 'apps\m2_float'
$work = Join-Path $root 'tmp\loopflake'
$scDir = Join-Path $root 'tmp\row-probe\selfcheck'
$dump = Join-Path $root 'tmp\row-probe\rows-dump.txt'
$bootOut = Join-Path $appDir 'main.exe'

New-Item -ItemType Directory -Force -Path $work | Out-Null
Get-ChildItem $work -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
# make the switches definitely on
New-Item -ItemType Directory -Force -Path $scDir | Out-Null
Set-Content -LiteralPath (Join-Path $scDir 'dump.on') -Value 'on' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $scDir 'demo.on') -Value 'on' -Encoding ASCII
foreach ($f in @('HwBridge.dll', 'config.json')) { Copy-Item (Join-Path $appDir $f) (Join-Path $work $f) -Force }

Push-Location $root
& (Join-Path $root 'flint.exe') (Join-Path $appDir 'main.fl') -o (Join-Path $work 'app_flint.exe') 2>&1 | Out-Null
Write-Output ("flint compile exit=" + $LASTEXITCODE)
& (Join-Path $root 'boot\b1_emit.exe') (Join-Path $appDir 'main.fl') 2>&1 | Out-Null
Write-Output ("boot compile exit=" + $LASTEXITCODE)
Pop-Location
if (Test-Path $bootOut) { Copy-Item $bootOut (Join-Path $work 'app_boot.exe') -Force; Remove-Item $bootOut -Force }

function Probe([string]$exe, [string]$tag, [int]$runs) {
  for ($i = 1; $i -le $runs; $i++) {
    Remove-Item $dump -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $got = $false
    while ($sw.Elapsed.TotalSeconds -lt 30) {
      Start-Sleep -Milliseconds 150
      if (Test-Path $dump) {
        $l1 = (Get-Item $dump).Length; Start-Sleep -Milliseconds 250
        if ($l1 -gt 0 -and $l1 -eq (Get-Item $dump).Length) { $got = $true; break }
      }
    }
    $sw.Stop()
    $code = 'n/a'
    if ($p.HasExited) { $code = "$($p.ExitCode)" }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $code = 'stopped' }
    $h = 'none'; $len = 0
    if ($got) {
      $copy = Join-Path $work ("dump-$tag-run$i.txt")
      Copy-Item $dump $copy -Force
      $len = (Get-Item $copy).Length
      $h = (Get-FileHash $copy -Algorithm SHA256).Hash.Substring(0, 12)
    }
    Write-Output ("{0} run{1}: dump={2} bytes={3} sha={4} exit={5} sec={6}" -f $tag, $i, $got, $len, $h, $code, [Math]::Round($sw.Elapsed.TotalSeconds, 1))
  }
}
Probe (Join-Path $work 'app_boot.exe') 'boot' 10
Probe (Join-Path $work 'app_flint.exe') 'flint' 10
Write-Output ("scratch: " + $work)
