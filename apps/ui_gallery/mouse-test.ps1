# mouse-test.ps1 -- drive apps\ui_gallery with REAL mouse input and check the app's text report.
# Why: the regression sample proves the widget logic with scripted input; this proves the real
# wiring (cursor -> window messages -> component). It moves the real cursor, so run it only
# when nobody is using the PC.
# ASCII only on purpose: a .ps1 containing non-ASCII needs a UTF-8 BOM (see memory rule).
param(
  [string]$Exe  = "E:\FLINT-lab\apps\ui_gallery\ui_gallery.exe",
  [string]$Dump = "E:\FLINT-lab\tmp\row-probe\ui-gallery-dump.txt",
  [int]$WinX = 300,
  [int]$WinY = 180
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, int dwExtraInfo);' -Name Mouse -Namespace Win32

function Move-2([int]$x, [int]$y) {
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
  Start-Sleep -Milliseconds 140
}
function Click-2([int]$x, [int]$y) {
  Move-2 $x $y
  [Win32.Mouse]::mouse_event(2, 0, 0, 0, 0)   # LEFTDOWN
  Start-Sleep -Milliseconds 70
  [Win32.Mouse]::mouse_event(4, 0, 0, 0, 0)   # LEFTUP
  Start-Sleep -Milliseconds 220
}
function Read-Report {
  if (Test-Path $Dump) { return (Get-Content $Dump -Raw).Trim() } else { return "<no dump>" }
}
function Get-Field([string]$text, [string]$key) {
  $m = [regex]::Match($text, "$key=(\d+)")
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}

if (Test-Path $Dump) { Remove-Item $Dump -Force }
$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Start-Sleep -Milliseconds 900
if ($p.HasExited) { Write-Output ("FAIL: app exited early (code {0})" -f $p.ExitCode); exit 1 }

# button center = client (92,56); checkbox center = client (22,100)
Click-2 ($WinX + 92) ($WinY + 56)
Click-2 ($WinX + 92) ($WinY + 56)
Click-2 ($WinX + 22) ($WinY + 100)

# scrollbar drag: grab the thumb (track top 40, thumb ~38px) then pull down 74 px
Move-2 ($WinX + 401) ($WinY + 46)
[Win32.Mouse]::mouse_event(2, 0, 0, 0, 0)
Start-Sleep -Milliseconds 90
Move-2 ($WinX + 401) ($WinY + 120)
[Win32.Mouse]::mouse_event(4, 0, 0, 0, 0)
Start-Sleep -Milliseconds 350

$report = Read-Report
$btn = Get-Field $report 'btn'
$chk = Get-Field $report 'chk'
$scr = Get-Field $report 'scr'
$fr  = Get-Field $report 'frames'
Write-Output ("report: {0}" -f $report)

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Start-Sleep -Milliseconds 200

$pass = 0
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { Write-Output ("  OK   {0} ({1})" -f $name, $detail); $script:pass++ }
  else { Write-Output ("  FAIL {0} ({1})" -f $name, $detail); $script:fail++ }
}
Check 'button got 2 real clicks' ($btn -eq 2) ("btn={0}" -f $btn)
Check 'checkbox toggled to 1'    ($chk -eq 1) ("chk={0}" -f $chk)
Check 'scrollbar moved by drag'  ($scr -gt 0) ("scr={0}" -f $scr)
Check 'app kept running'         ($fr -gt 0)  ("frames={0}" -f $fr)
Write-Output "----"
Write-Output ("pass {0} / fail {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
