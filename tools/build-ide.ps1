# build-ide.ps1 - rebuild FLINT Studio and swap the exe in place WITHOUT killing a running IDE.
# Why: hlc cannot overwrite studio_win.exe while the user has the window open. Windows allows
# *renaming* a running exe, so: build to .new -> rename running exe to .old -> rename .new into place.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$exe = Join-Path $root 'apps\studio_native\studio_win.exe'
$new = Join-Path $root 'apps\studio_native\studio_win.new.exe'
$old = Join-Path $root 'apps\studio_native\studio_win.old.exe'

Push-Location $root
try {
    & .\hlc.exe apps\studio_native\studio_win.fl -o apps\studio_native\studio_win.new.exe
    if ($LASTEXITCODE -ne 0) { throw "hlc failed (exit $LASTEXITCODE)" }
    if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    $swapped = $false
    if (Test-Path $exe) {
        try {
            Move-Item $exe $old -Force
            $swapped = $true
        } catch {
            # the running image may hold the name; try the New-Item rename path once
            [System.IO.File]::Move($exe, $old)
            $swapped = $true
        }
    }
    Move-Item $new $exe -Force
    if ($swapped) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
    Write-Output ("OK swapped={0} size={1}" -f $swapped, (Get-Item $exe).Length)
}
finally {
    Pop-Location
}
