# wheel-probe.ps1 -- does the gallery's list scroll with a REAL mouse wheel? (one-off probe)
# Why: mouse-test.ps1 only covers the scrollbar DRAG (M3(b) added it). The wheel path comes from
#   the platform layer (WM_MOUSEWHEEL in gui_win_pump) + gui_scroll_begin's hover test -- never
#   proven on this app with real hardware input. This probe sends real wheel events and reads the
#   app's own dump (scr= field) before/after. ASCII only.
#
# M4m (2026-09-28, card T-20260928-005959): the per-notch step is no longer hard-coded 20px --
#   it is `GuiCtx.wheel_step`, whose default is now **60 = 3 rows/notch** (the old "one notch = 20px"
#   expectation is what this probe used to assert). The numbers below are derived from that new
#   default, NOT from the recorded value of a previous run (same-family trap: "a baseline locks in
#   the old value"). `-Step` lets you re-run the probe against any other step (e.g. 20 for the
#   legacy unit) without editing the script.
param(
  [string]$Exe  = "E:\FLINT-lab\apps\ui_gallery\ui_gallery.exe",
  [string]$Dump = "E:\FLINT-lab\tmp\row-probe\ui-gallery-dump.txt",
  [int]$WinX = 300,
  [int]$WinY = 180,
  [int]$Step = 60
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, int dwExtraInfo);' -Name Wheel -Namespace Win32

function Get-Scr {
  if (-not (Test-Path $Dump)) { return -1 }
  $t = (Get-Content $Dump -Raw).Trim()
  $m = [regex]::Match($t, 'scr=(\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}
function Wheel([int]$delta) {
  [Win32.Wheel]::mouse_event(0x0800, 0, 0, $delta, 0)
  Start-Sleep -Milliseconds 260
}

$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Start-Sleep -Milliseconds 900
if ($p.HasExited) { Write-Output ("FAIL: app exited early (code {0})" -f $p.ExitCode); exit 1 }

# cursor into the scroll view (client 280,120 -> inside view rect 188,40,215,194)
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($WinX + 280), ($WinY + 120))
Start-Sleep -Milliseconds 200
$s0 = Get-Scr
Wheel -120
$s1 = Get-Scr
Wheel -120
$s2 = Get-Scr
Wheel 120
$s3 = Get-Scr
Wheel 120
$s4 = Get-Scr

# wheel OUTSIDE the view (client 60,150 -> over the button/left column): must NOT move
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($WinX + 60), ($WinY + 150))
Start-Sleep -Milliseconds 200
Wheel -120
$s5 = Get-Scr

# wheel with cursor back inside but scrolled to a middle offset, then bottom clamp
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($WinX + 280), ($WinY + 120))
Start-Sleep -Milliseconds 200
# 40 ticks x 60px = 2400px worth of scroll => must clamp at the bottom (content is 40 rows ~ 536px)
for ($i = 0; $i -lt 40; $i++) { Wheel -120 }
$s6 = Get-Scr
# 5 more ticks at the bottom: a real clamp means "no further movement at all"
for ($i = 0; $i -lt 5; $i++) { Wheel -120 }
$s7 = Get-Scr

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Start-Sleep -Milliseconds 200

Write-Output ("step (px/notch) = {0}" -f $Step)
Write-Output ("scr: start={0}  wheelDown={1}  wheelDown={2}  wheelUp={3}  wheelUp={4}" -f $s0, $s1, $s2, $s3, $s4)
Write-Output ("scr: outsideView(wheelDown)={0}   then 40x wheelDown -> {1}   then 5x more -> {2}" -f $s5, $s6, $s7)
$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) { if ($ok) { Write-Output ("  OK   {0} ({1})" -f $n, $d); $script:pass++ } else { Write-Output ("  FAIL {0} ({1})" -f $n, $d); $script:fail++ } }
Check 'one notch down = exactly one step' ($s1 -eq ($s0 + $Step))          ("scr {0} -> {1}, expect +{2}" -f $s0, $s1, $Step)
Check 'a second notch adds another step'  ($s2 -eq ($s1 + $Step))          ("scr {0} -> {1}, expect +{2}" -f $s1, $s2, $Step)
Check 'one notch up = exactly one step'   ($s3 -eq ($s2 - $Step))          ("scr {0} -> {1}, expect -{2}" -f $s2, $s3, $Step)
Check 'wheel up returns to start'         ($s4 -eq $s0)                    ("scr {0} (start {1})" -f $s4, $s0)
Check 'wheel outside view is ignored'     ($s5 -eq $s4)                    ("scr {0} (was {1})" -f $s5, $s4)
Check 'bottom clamp reached'              ($s6 -gt 0)                      ("scr {0} after 40 ticks" -f $s6)
Check 'bottom clamp holds (no creep)'     ($s7 -eq $s6)                    ("scr {0} -> {1} after 5 more ticks" -f $s6, $s7)
Write-Output "----"
Write-Output ("pass {0} / fail {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
