# tab-probe.ps1 -- REAL-keyboard gate for the FLGUI M4o focus chain (Tab / Shift+Tab).
#
# WHY: the headless sample (test\samples\flgui15.fl) drives in.key directly. It can never prove that
#   (a) a real WM_KEYDOWN with VK_TAB physically reaches the library through gui_win_pump, nor that
#   (b) VK_SHIFT is decoded there into the REVERSE direction (gui_key_tab_shift). That is exactly the
#   class of gap this project has been burned by before ("scripted input cannot see platform-layer
#   gaps" -- the real mouse wheel never worked while every sample gate stayed green).
# WHAT: launches the keyboard-tier demo app, clicks the editable field (that click also gives the
#   window real keyboard focus AND moves the focus chain onto the field), then sends REAL Tab and
#   Shift+Tab keystrokes via keybd_event and reads the app's own ledger lines:
#     FOC idx=<n> cnt=<m> id=<id> edit=<slot>   (printed once per focus change, real-window branch only)
#     KB  ... F=<edit focus> ...                (M4c ledger, same stdout stream)
#   Expectations are RECOMPUTED here from the app's own cnt (never copied from a recorded run):
#     Tab        -> idx = (idx + 1) % cnt
#     Shift+Tab  -> idx = (idx - 1 + cnt) % cnt
#   Because the click lands on the LAST focusable control (the editable field is drawn last), the two
#   keystrokes also exercise both wrap directions. If Shift were ignored, both would step forward and
#   the Shift+Tab checks would fail -- that is this probe's "red before the fix" evidence.
# ASCII only on purpose (a .ps1 with non-ASCII needs a UTF-8 BOM, and probes are the last place to
# gamble on encoding). Usage: powershell -NoProfile -File apps\flgui_demo\tab-probe.ps1
param(
  [string]$Exe = "E:\FLINT-lab\apps\flgui_demo\flgui_demo.exe",
  [string]$Out = "E:\FLINT-lab\tmp\flgui\tab-stdout.txt"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr FindWindowA(string cls, string win);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, int e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyA(uint code, uint mapType);
public struct RECT { public int L; public int T; public int R; public int B; }
'@ -Name Kb -Namespace W32

function Get-Lines {
  if (-not (Test-Path $Out)) { return @() }
  return @(Get-Content -LiteralPath $Out -Encoding UTF8 -ErrorAction SilentlyContinue)
}
function Get-Last([string]$kind) {
  $ls = Get-Lines
  for ($i = $ls.Count - 1; $i -ge 0; $i--) { if ($ls[$i].StartsWith($kind)) { return $ls[$i] } }
  return ""
}
# Read BY FIELD NAME, never by position: the ledger keeps gaining columns and a positional parser
# breaks every time one is added (kb-probe.ps1 records that lesson).
# A record is accepted ONLY when all four fields are present AND non-empty: stdout is block-buffered,
# so the tail of the file can hold a HALF-FLUSHED line (measured: "FOC idx=0 cnt=" -- the empty
# fields then parse as 0 and would have silently faked "edit=0"). A partial line must be ignored,
# not interpreted (same family as the kb-probe TIMEOUT race).
function Parse-Foc([string]$l) {
  if (-not $l.StartsWith("FOC ")) { return $null }
  $h = @{}
  foreach ($m in [regex]::Matches($l, '([A-Za-z]+)=(\S*)')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  foreach ($k in @('idx', 'cnt', 'id', 'edit')) {
    if (-not $h.ContainsKey($k)) { return $null }
    if ([string]::IsNullOrEmpty($h[$k])) { return $null }
  }
  return [pscustomobject]@{
    Raw = $l; Idx = [int]$h['idx']; Cnt = [int]$h['cnt']
    Id = [int]$h['id']; Edit = [int]$h['edit']
  }
}
function Parse-KbF([string]$l) {
  if (-not $l.StartsWith("KB ")) { return $null }
  $h = @{}
  foreach ($m in [regex]::Matches($l, '([A-Z])=(\S*)')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  # 'L'/'F'/'D' are all non-empty in every KB record (T can legitimately be empty: an empty edit box)
  foreach ($k in @('L', 'F', 'D')) {
    if (-not $h.ContainsKey($k)) { return $null }
    if ([string]::IsNullOrEmpty($h[$k])) { return $null }
  }
  return [int]$h['F']
}
# WAIT for a NEW FOC record satisfying $ok instead of sampling once (kb-probe.ps1's TIMEOUT race fix).
# $notRaw = the raw line that was already on disk before the keystroke: the ledger appends one line per
#   focus CHANGE, so "the newest complete line is still the old one" means the keystroke has not landed
#   yet -- waiting on that (instead of accepting it) is what makes a stale read impossible.
function Wait-Foc([int]$ms, [string]$notRaw, [scriptblock]$ok) {
  $deadline = (Get-Date).AddMilliseconds($ms)
  $last = $null
  while ((Get-Date) -lt $deadline) {
    $r = Parse-Foc (Get-Last "FOC ")
    if ($null -ne $r -and $r.Raw -ne $notRaw) { $last = $r; if (& $ok $r) { return $r } }
    Start-Sleep -Milliseconds 40
  }
  return $last
}
function Send-Key([int]$vk, [bool]$shift) {
  # scan code via MapVirtualKey(vk, MAPVK_VK_TO_VSC=0): the platform layer reverse-looks-up the scan
  # code (MapVirtualKeyA(sc, 1)), so a correct scan byte is what makes this a REAL keystroke.
  # The SHIFT key gets its real scan code too (0x2A): injecting it with scan 0 is legal and the library
  # falls back to wParam for that case, but a realistic code keeps this probe honest about both paths.
  $sc = [W32.Kb]::MapVirtualKeyA([uint32]$vk, 0)
  $scShift = [W32.Kb]::MapVirtualKeyA([uint32]16, 0)
  if ($shift) { [W32.Kb]::keybd_event([byte]16, [byte]$scShift, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
  [W32.Kb]::keybd_event([byte]$vk, [byte]$sc, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [W32.Kb]::keybd_event([byte]$vk, [byte]$sc, 2, [UIntPtr]::Zero)
  if ($shift) { Start-Sleep -Milliseconds 40; [W32.Kb]::keybd_event([byte]16, [byte]$scShift, 2, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds 220
}

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
  if ($ok) { Write-Output ("  OK   {0} ({1})" -f $n, $d); $script:pass++ }
  else { Write-Output ("  FAIL {0} ({1})" -f $n, $d); $script:fail++ }
}

Get-Process flgui_demo -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
Remove-Item $Out -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru -RedirectStandardOutput $Out
Start-Sleep -Milliseconds 900
if ($p.HasExited) { Write-Output ("FAIL: app exited early (code {0})" -f $p.ExitCode); exit 1 }

$h = [IntPtr]::Zero
$find = (Get-Date).AddSeconds(6)
while ((Get-Date) -lt $find) {
  $h = [W32.Kb]::FindWindowA("FLGUIM2DEMO", $null)
  if ($h -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 150
}
if ($h -eq [IntPtr]::Zero) {
  Write-Output "FAIL: window class FLGUIM2DEMO not found"
  Stop-Process -Id $p.Id -Force; exit 1
}

# click point from the app's own geometry (never a hard-coded coordinate)
$boxDeadline = (Get-Date).AddSeconds(6)
$box = $null
while ((Get-Date) -lt $boxDeadline -and $null -eq $box) {
  $l = Get-Last "BOX "
  if ($l -ne "") {
    $m = [regex]::Match($l, 'BOX (-?\d+) (-?\d+) (-?\d+) (-?\d+)')
    if ($m.Success) { $box = @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value) }
  }
  if ($null -eq $box) { Start-Sleep -Milliseconds 100 }
}
if ($null -eq $box) { Write-Output "FAIL: no BOX line on stdout"; Stop-Process -Id $p.Id -Force; exit 1 }
$r = New-Object W32.Kb+RECT
[void][W32.Kb]::GetWindowRect($h, [ref]$r)
$cx = $r.L + $box[0] + [int]($box[2] / 2)
$cy = $r.T + $box[1] + [int]($box[3] / 2)
Write-Output ("window hwnd={0} rect={1},{2}-{3},{4} box={5} click={6},{7}" -f $h, $r.L, $r.T, $r.R, $r.B, ($box -join ","), $cx, $cy)

# STEP 0: real click into the editable box -> edit focus AND the focus chain both land on it
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($cx, $cy)
Start-Sleep -Milliseconds 250
[W32.Kb]::mouse_event(0x0002, 0, 0, 0, 0)
Start-Sleep -Milliseconds 90
[W32.Kb]::mouse_event(0x0004, 0, 0, 0, 0)
$afterClick = Wait-Foc 4000 "" { param($x) $x.Edit -ge 0 }
if ($null -eq $afterClick) { Write-Output "FAIL: no FOC ledger line at all"; Stop-Process -Id $p.Id -Force; exit 1 }
Write-Output ("after click     : {0}" -f $afterClick.Raw)
$cnt = $afterClick.Cnt
Check "click into the editable field puts the focus chain on it (edit slot >= 0)" ($afterClick.Edit -ge 0) ("edit=" + $afterClick.Edit)
Check "focusable list is non-trivial (cnt >= 2)" ($cnt -ge 2) ("cnt=$cnt")
Check "the clicked field is the LAST focusable control (so forward Tab must wrap)" ($afterClick.Idx -eq ($cnt - 1)) ("idx=$($afterClick.Idx) cnt=$cnt")

# STEP 1: one REAL Tab -> forward by one, with wrap; edit focus must be released
$prevRaw = (Get-Last "FOC ")
Send-Key 9 $false
$wantF = ($afterClick.Idx + 1) % $cnt
$afterTab = Wait-Foc 4000 $prevRaw { param($x) $x.Idx -eq $wantF }
if ($null -eq $afterTab) { Write-Output "FAIL: Tab never produced the expected FOC line"; Stop-Process -Id $p.Id -Force; exit 1 }
Write-Output ("after Tab       : {0}" -f $afterTab.Raw)
Check "real VK_TAB steps the focus chain forward with wrap (recomputed)" ($afterTab.Idx -eq $wantF) ("idx=$($afterTab.Idx) want=$wantF")
Check "Tab moved the focus AWAY from the editable field -> edit slot released" ($afterTab.Edit -eq -1) ("edit=" + $afterTab.Edit)
$kbF = Parse-KbF (Get-Last "KB ")
Check "KB ledger agrees that the edit focus is gone (F=-1)" ($null -ne $kbF -and $kbF -eq -1) ("F=" + $kbF)

# STEP 2: one REAL Shift+Tab -> backward by one, with wrap (this is the direction decode check)
$prevRaw = (Get-Last "FOC ")
Send-Key 9 $true
$wantB = (($afterTab.Idx - 1) + $cnt) % $cnt
$afterShift = Wait-Foc 4000 $prevRaw { param($x) $x.Idx -eq $wantB }
if ($null -eq $afterShift) { Write-Output "FAIL: Shift+Tab never produced the expected FOC line"; Stop-Process -Id $p.Id -Force; exit 1 }
Write-Output ("after Shift+Tab : {0}" -f $afterShift.Raw)
Check "real Shift+Tab steps BACKWARD with wrap (recomputed; forward would have failed)" ($afterShift.Idx -eq $wantB) ("idx=$($afterShift.Idx) want=$wantB")
Check "Shift+Tab landed on a different control than Tab did" ($afterShift.Idx -ne $afterTab.Idx) ("shift=$($afterShift.Idx) tab=$($afterTab.Idx)")

# STEP 3: a full forward cycle of cnt real Tabs must return to where we started (wrap is a bijection)
$seen = @{}
$okSeq = $true
$cur = $afterShift.Idx
for ($i = 0; $i -lt $cnt; $i++) {
  $prevRaw = (Get-Last "FOC ")
  Send-Key 9 $false
  $want = ($cur + 1) % $cnt
  $rec = Wait-Foc 4000 $prevRaw { param($x) $x.Idx -eq $want }
  if ($null -eq $rec -or $rec.Idx -ne $want) { $okSeq = $false; break }
  if ($seen.ContainsKey($rec.Idx)) { $okSeq = $false; break }
  $seen[$rec.Idx] = 1
  $cur = $rec.Idx
}
Check ("{0} real Tabs visit every focusable exactly once and wrap back to the start" -f $cnt) ($okSeq -and $cur -eq $afterShift.Idx) ("end=$cur start=$($afterShift.Idx) visited=" + $seen.Count)

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output ("tab-probe: {0}/{1} checks passed" -f $pass, ($pass + $fail))
if ($fail -eq 0) { Write-Output "M4o focus chain (real keyboard): GREEN"; exit 0 }
Write-Output "M4o focus chain (real keyboard): FAILED"; exit 1
