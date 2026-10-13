# drag-probe.ps1 -- real-mouse proof for M4m window dragging (card T-20260928-005959). ASCII only.
#
# What is proven here (all with REAL cursor movement + REAL left-button events; the window rect is
# read straight from user32 by THIS script, not from the app's own dump -- an external judge):
#   0. the window really sits at the round's start rect (moved there by MoveWindow before the round)
#   1. drag by the top bar (client y < 24) is 1:1: the window origin moves by exactly the cursor delta
#   2. a fast drag that leaves the window and releases there does NOT "stick" (no self-walk afterwards)
#   3. a press OUTSIDE the top bar does not move the window at all (locked tier => displacement 0,0)
#   4. double click on the top bar maximizes; another double click restores the old rect
#      (M4m also makes the surface follow the window size: ULW pins the window to cw x ch every frame,
#       so without that the maximize would be undone by the next frame -- see lib\flgui_win32.fl)
#
# WHY ROUNDS (added 2026-09-28 after an independent review caught a flaky restore):
#   a single run is NOT a judgement for this feature. A maximized 1920x1080 layered surface costs
#   ~2M pixels of alpha work per frame, so the app's frame period grows a lot; `gui_win_input` samples
#   the physical button only ONCE PER FRAME, so a fast down/up can fall entirely inside one slow frame
#   and that press/release edge is never seen. Two consequences used to be visible here:
#     (a) the restore ran but a STALE drag token (origin recorded on the maximized window = 0,0) then
#         dragged the restored window back to 0,0 -- size right, position wrong (library bug, fixed);
#     (b) the second press was only sampled LATE -- a fixed sleep after the clicks read the window
#         before the app got to the toggle at all (probe bug: this script now WAITS FOR THE STATE).
#   => every round RESTARTS the app (clean library state), moves the window to its own start rect
#      (different per round, so "it worked" cannot be a lucky legacy position) and re-runs all checks.
#      Acceptance = ALL rounds green, never "it passed once".
#
# ASCII ONLY on purpose: a .ps1 with non-ASCII needs a UTF-8 BOM, and PowerShell 5.1 decodes a BOM-less
# file as ANSI/GBK -- that mojibake ate a whole assignment line in the first version of this rewrite
# ($X0 came out $null => the window was reset to x=0 and three checks failed for the wrong reason).
# Same lesson as apps\flgui_demo\kb-probe.ps1 ("a probe that never ran was mistaken for a probe that
# failed"): run the repo's file-discipline checker with -FixBom on any probe that keeps non-ASCII text.
#
# The app is a borderless TOPMOST WS_POPUP window (class "FLINTGAL"), safe to click with the left button.
# Right button = quit, so this script never sends it.
param(
  [string]$Exe = "E:\FLINT-lab\apps\ui_gallery\ui_gallery.exe",
  [int]$Rounds = 5,
  [int]$TopBar = 12,          # client y used for top-bar presses (must be < 24)
  [int]$LockY  = 200,         # client y used for the "locked" press (must be >= 24)
  [int]$WaitMs = 4000,        # max wait for an expected state (the app can be slow while maximized)
  [string]$TraceDir = ""      # optional: capture the app's stdout per round (debug tracing)
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern IntPtr FindWindowA(string cls, string win);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, int e);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@ -Name Drag -Namespace Win32

function Get-Rect([IntPtr]$h) {
  $r = New-Object Win32.Drag+RECT
  if (-not [Win32.Drag]::GetWindowRect($h, [ref]$r)) { throw "GetWindowRect failed" }
  return @{ L = $r.Left; T = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top) }
}
function Move-To([int]$x, [int]$y) { [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y) }
function Btn([int]$f) { [Win32.Drag]::mouse_event([uint32]$f, 0, 0, 0, 0) }
$LDOWN = 0x0002; $LUP = 0x0004

$script:pass = 0
$script:fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
  if ($ok) { Write-Output ("  OK   {0} ({1})" -f $n, $d); $script:pass++ }
  else { Write-Output ("  FAIL {0} ({1})" -f $n, $d); $script:fail++ }
}
# wait until the window rect satisfies $Test, or give up after $WaitMs (NEVER a single fixed sleep:
# the app's frame period while maximized can be several hundred ms, and the judgement must not race it)
function Wait-Rect([IntPtr]$h, [scriptblock]$Test, [string]$Tag) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalMilliseconds -lt $WaitMs) {
    $r = Get-Rect $h
    if (& $Test $r) { return @{ rect = $r; ms = [int]$sw.Elapsed.TotalMilliseconds } }
    Start-Sleep -Milliseconds 50
  }
  return @{ rect = (Get-Rect $h); ms = -1 }
}
# one click: settle, press, hold long enough that a SLOW (maximized) frame still samples the edge, release
function Click([IntPtr]$h, [int]$x, [int]$y) {
  Move-To $x $y
  Start-Sleep -Milliseconds 60
  Btn $LDOWN
  Start-Sleep -Milliseconds 120
  Btn $LUP
  Start-Sleep -Milliseconds 90
}

for ($rd = 1; $rd -le $Rounds; $rd++) {
  Write-Output ""
  Write-Output ("===== round {0}/{1} =====" -f $rd, $Rounds)
  $StartX = 400 + 40 * $rd
  $StartY = 220 + 20 * $rd
  $failBefore = $fail
  if ($TraceDir) {
    New-Item -ItemType Directory -Force -Path $TraceDir | Out-Null
    $so = Join-Path $TraceDir ("drag-trace-r{0}.log" -f $rd)
    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru -RedirectStandardOutput $so
  } else {
    $p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
  }
  Start-Sleep -Milliseconds 900
  if ($p.HasExited) { Write-Output ("  FAIL app exited early (code {0})" -f $p.ExitCode); $fail++; continue }
  $h = [Win32.Drag]::FindWindowA("FLINTGAL", $null)
  if ($h -eq [IntPtr]::Zero) { Stop-Process -Id $p.Id -Force; Write-Output "  FAIL window class FLINTGAL not found"; $fail++; continue }

  # ---- 0. reset to this round's start rect (kills "lucky legacy position") ----
  [void][Win32.Drag]::MoveWindow($h, $StartX, $StartY, 420, 260, $true)
  $w = Wait-Rect $h { param($r) $r.L -eq $StartX -and $r.T -eq $StartY -and $r.W -eq 420 -and $r.H -eq 260 } 'reset'
  $r0 = $w.rect
  Check 'start rect reset by the probe' ($w.ms -ge 0) ("got {0},{1} {2}x{3} ; want {4},{5} 420x260 ({6})" -f $r0.L, $r0.T, $r0.W, $r0.H, $StartX, $StartY, $(if ($w.ms -ge 0) { "$($w.ms)ms" } else { "TIMEOUT>${WaitMs}ms" }))

  # ---- 1. 1:1 drag by the top bar ----
  Move-To ($r0.L + 100) ($r0.T + $TopBar)
  Start-Sleep -Milliseconds 150
  Btn $LDOWN
  Start-Sleep -Milliseconds 150
  $dx = 50; $dy = 35
  Move-To ($r0.L + 100 + $dx) ($r0.T + $TopBar + $dy)
  $w = Wait-Rect $h { param($r) $r.L -eq ($r0.L + $dx) -and $r.T -eq ($r0.T + $dy) } 'drag'
  $r1 = $w.rect
  Btn $LUP
  Start-Sleep -Milliseconds 300
  $r2 = Get-Rect $h
  Write-Output ("drag: {0},{1} {2}x{3} -> {4},{5} (cursor {6},{7})" -f $r0.L, $r0.T, $r0.W, $r0.H, $r1.L, $r1.T, $dx, $dy)
  Check 'top bar drag moves the window 1:1' (($r1.L - $r0.L) -eq $dx -and ($r1.T - $r0.T) -eq $dy) ("moved {0},{1} ; expect {2},{3}" -f ($r1.L - $r0.L), ($r1.T - $r0.T), $dx, $dy)
  Check 'release does not move it further'  ($r2.L -eq $r1.L -and $r2.T -eq $r1.T)                ("after release {0},{1}" -f $r2.L, $r2.T)

  # ---- 2. fast drag out of the window, release outside => no self-walk ----
  $rA = Get-Rect $h
  Move-To ($rA.L + 100) ($rA.T + $TopBar)
  Start-Sleep -Milliseconds 150
  Btn $LDOWN
  Start-Sleep -Milliseconds 150
  Move-To ($rA.L + 100 + 400) ($rA.T + $TopBar + 300)
  Start-Sleep -Milliseconds 30
  Btn $LUP
  Start-Sleep -Milliseconds 500
  $rB = Get-Rect $h
  Start-Sleep -Milliseconds 800
  $rC = Get-Rect $h
  Write-Output ("fast-drag-out: {0},{1} -> +500ms {2},{3} -> +1300ms {4},{5}" -f $rA.L, $rA.T, $rB.L, $rB.T, $rC.L, $rC.T)
  Check 'fast drag out + release does not self-walk' ($rB.L -eq $rC.L -and $rB.T -eq $rC.T) ("{0},{1} then {2},{3}" -f $rB.L, $rB.T, $rC.L, $rC.T)

  # ---- 3. press OUTSIDE the top bar => locked (0,0) ----
  $rL0 = Get-Rect $h
  Move-To ($rL0.L + 60) ($rL0.T + $LockY)
  Start-Sleep -Milliseconds 150
  Btn $LDOWN
  Start-Sleep -Milliseconds 150
  Move-To ($rL0.L + 60 + 50) ($rL0.T + $LockY + 35)
  Start-Sleep -Milliseconds 400
  $rL1 = Get-Rect $h
  Btn $LUP
  Start-Sleep -Milliseconds 300
  Write-Output ("locked press (client y={0}): {1},{2} -> {3},{4}" -f $LockY, $rL0.L, $rL0.T, $rL1.L, $rL1.T)
  Check 'press outside the top bar does not move the window' ($rL1.L -eq $rL0.L -and $rL1.T -eq $rL0.T) ("moved {0},{1} ; expect 0,0" -f ($rL1.L - $rL0.L), ($rL1.T - $rL0.T))

  # ---- 4. double click the top bar => maximize ; again => restore ----
  $rD0 = Get-Rect $h
  Click $h ($rD0.L + 100) ($rD0.T + $TopBar)
  Click $h ($rD0.L + 100) ($rD0.T + $TopBar)
  $w = Wait-Rect $h { param($r) $r.W -gt 800 -and $r.H -gt 600 } 'maximize'
  $rD1 = $w.rect
  Write-Output ("double click 1: {0},{1} {2}x{3}  ->  {4},{5} {6}x{7} ({8})" -f $rD0.L, $rD0.T, $rD0.W, $rD0.H, $rD1.L, $rD1.T, $rD1.W, $rD1.H, $(if ($w.ms -ge 0) { "$($w.ms)ms" } else { "TIMEOUT>${WaitMs}ms" }))
  Check 'double click on the top bar maximizes' ($w.ms -ge 0) ("size {0}x{1}" -f $rD1.W, $rD1.H)

  Click $h ($rD1.L + 100) ($rD1.T + $TopBar)
  Click $h ($rD1.L + 100) ($rD1.T + $TopBar)
  $w = Wait-Rect $h { param($r) $r.L -eq $rD0.L -and $r.T -eq $rD0.T -and $r.W -eq $rD0.W -and $r.H -eq $rD0.H } 'restore'
  $rD2 = $w.rect
  Write-Output ("double click 2: -> {0},{1} {2}x{3}  (want {4},{5} {6}x{7}) ({8})" -f $rD2.L, $rD2.T, $rD2.W, $rD2.H, $rD0.L, $rD0.T, $rD0.W, $rD0.H, $(if ($w.ms -ge 0) { "$($w.ms)ms" } else { "TIMEOUT>${WaitMs}ms" }))
  Check 'double click again restores the old rect' ($w.ms -ge 0) ("{0},{1} {2}x{3}" -f $rD2.L, $rD2.T, $rD2.W, $rD2.H)

  # after the restore the window must STAY there (this is the stale-drag regression: the token left
  # over from a press on the maximized window used to pull it straight back to 0,0)
  Start-Sleep -Milliseconds 700
  $rD3 = Get-Rect $h
  Check 'restored rect is stable (no stale drag pulls it back)' ($rD3.L -eq $rD2.L -and $rD3.T -eq $rD2.T -and $rD3.W -eq $rD2.W -and $rD3.H -eq $rD2.H) ("{0},{1} {2}x{3} after +700ms" -f $rD3.L, $rD3.T, $rD3.W, $rD3.H)

  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Start-Sleep -Milliseconds 250
  Write-Output ("-- round {0} done: this round fail={1} / total fail={2}" -f $rd, ($fail - $failBefore), $fail)
}

Write-Output ""
Write-Output "----"
Write-Output ("rounds {0}  | checks pass {1} / fail {2}" -f $Rounds, $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
