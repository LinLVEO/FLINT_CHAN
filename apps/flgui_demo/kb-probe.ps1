# kb-probe.ps1 -- real-keyboard gate for the FLGUI editable text field (M4c rework).
#
# WHY THIS FILE WAS REWRITTEN (2026-09-23, card T-20260923-010300 item 5):
#   The M4b version read a 34-byte record that the app rewrote with CREATE_ALWAYS on EVERY frame.
#   Two consequences, both measured:
#     * the probe kept reading half-written records (reported focus=?) or empty files (TIMEOUT);
#     * its focus check could never pass at all: the app encoded focus as (focus+10) so focus=0 came out
#       as ':' while the probe matched F=(\d+) -- a judgement that was structurally unable to pass.
#   So the app now appends ONE LINE PER STATE CHANGE to stdout, and this probe:
#     * captures stdout (append-only, no truncation race) and reads the LAST complete record;
#     * WAITS for the expected state instead of sampling once;
#     * derives the click point from the app's own `BOX x y w h` line plus the real window rect;
#     * separates the four questions the diagnosis needed: D (keydown arrived) / N (thread message?)
#       / S,Z,Q (scan code + lParam sane?) / C,X (characters: WM_CHAR vs platform-layer ToAscii).
#   ASCII only on purpose: a .ps1 with non-ASCII needs a UTF-8 BOM, and probes are the last place to
#   gamble on encoding (m4c lesson: a probe that never ran was mistaken for a probe that failed).
# Usage: pwsh -File apps\flgui_demo\kb-probe.ps1        (opens a real window, moves the cursor)
param(
  [string]$Exe = "E:\FLINT-lab\apps\flgui_demo\flgui_demo.exe",
  [string]$Out = "E:\FLINT-lab\tmp\flgui\kb-stdout.txt"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr FindWindowA(string cls, string win);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern IntPtr GetFocus();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, int e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern uint MapVirtualKeyA(uint code, uint mapType);
public struct RECT { public int L; public int T; public int R; public int B; }
'@ -Name Kb -Namespace W32

function Get-Lines {
  if (-not (Test-Path $Out)) { return @() }
  # redirected output is raw bytes; PS 5.1 would decode it as ANSI unless told otherwise
  return @(Get-Content -LiteralPath $Out -Encoding UTF8 -ErrorAction SilentlyContinue)
}
function Get-Last([string]$kind) {
  $ls = Get-Lines
  for ($i = $ls.Count - 1; $i -ge 0; $i--) { if ($ls[$i].StartsWith($kind)) { return $ls[$i] } }
  return ""
}
function Parse-Kb([string]$l) {
  # Read BY FIELD NAME, never by position: the app's ledger keeps gaining diagnostic columns
  #   (L/F/P/D/C/X/Y/W/U/E/K/V/N/S/Z/Q/T), and a positional parser breaks every time one is added.
  if (-not $l.StartsWith("KB ")) { return $null }
  $h = @{}
  foreach ($m in [regex]::Matches($l, '([A-Z])=(\S*)')) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
  if (-not $h.ContainsKey('L')) { return $null }
  function N([string]$k) { if ($h.ContainsKey($k)) { return [int]$h[$k] } else { return 0 } }
  return [pscustomobject]@{
    Raw = $l
    Len = N 'L'; Focus = N 'F'; Pend = N 'P'; Down = N 'D'; Char = N 'C'; Tr = N 'X'
    Fb = N 'B'; M = N 'M'; Null = N 'N'; Scan = N 'S'; Scan0 = N 'Z'; Lp0 = N 'Q'
    Text = $h['T']
  }
}
# Poll until the last complete record satisfies $ok. Waiting (not sampling) is the fix for the old race.
function Wait-Kb([int]$ms, [scriptblock]$ok) {
  $deadline = (Get-Date).AddMilliseconds($ms)
  $last = $null
  while ((Get-Date) -lt $deadline) {
    $r = Parse-Kb (Get-Last "KB ")
    if ($null -ne $r) { $last = $r; if (& $ok $r) { return $r } }
    Start-Sleep -Milliseconds 50
  }
  return $last
}
function Type-Key([int]$vk) {
  # scan code via MapVirtualKey(vk, MAPVK_VK_TO_VSC=0): TranslateMessage/ToUnicode index the layout
  #   table by SCAN CODE, so injecting with scan=0 is not guaranteed to produce a WM_CHAR.
  $sc = [W32.Kb]::MapVirtualKeyA([uint32]$vk, 0)
  [W32.Kb]::keybd_event([byte]$vk, [byte]$sc, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [W32.Kb]::keybd_event([byte]$vk, [byte]$sc, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
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

# click point from the app's own geometry: window rect + client rect of the editable box
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
# WS_POPUP window: client origin == window origin
$cx = $r.L + $box[0] + [int]($box[2] / 2)
$cy = $r.T + $box[1] + [int]($box[3] / 2)
Write-Output ("window hwnd={0} rect={1},{2}-{3},{4} box={5} click={6},{7}" -f $h, $r.L, $r.T, $r.R, $r.B, ($box -join ","), $cx, $cy)

$before = Wait-Kb 3000 { param($x) $true }
Write-Output ("record before   : {0}" -f $before.Raw)

# STEP 1: real click on the editable box -> the field must take focus (F=0)
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($cx, $cy)
Start-Sleep -Milliseconds 250
[W32.Kb]::mouse_event(0x0002, 0, 0, 0, 0)
Start-Sleep -Milliseconds 120
[W32.Kb]::mouse_event(0x0004, 0, 0, 0, 0)
$clicked = Wait-Kb 2500 { param($x) $x.Focus -eq 0 }
$fg = [W32.Kb]::GetForegroundWindow()
$tMe = [W32.Kb]::GetCurrentThreadId(); $pid2 = 0
$tTarget = [W32.Kb]::GetWindowThreadProcessId($h, [ref]$pid2)
[void][W32.Kb]::AttachThreadInput($tMe, $tTarget, $true)
$focusWin = [W32.Kb]::GetFocus()
[void][W32.Kb]::AttachThreadInput($tMe, $tTarget, $false)
Write-Output ("record clicked  : {0}" -f $clicked.Raw)
Write-Output ("  foreground={0} (is window={1})  target thread focus window={2} (is window={3})" -f $fg, ($fg -eq $h), $focusWin, ($focusWin -eq $h))
Check 'real click focused the field' ($clicked.Focus -eq 0) ("F=" + $clicked.Focus)

# STEP 2: real typing 'O' 'K' -> text must reach the field
Type-Key 0x4F
Type-Key 0x4B
$typed = Wait-Kb 3000 { param($x) $x.Len -ge 2 }
Write-Output ("record typed    : {0}" -f $typed.Raw)
Write-Output ("  message split : D={0} keydown; N={1} of them hwnd=0 THREAD messages; last wParam M={2} (229 = VK_PROCESSKEY, i.e. the IME took the key); scan byte S={3} (0x{3:X2}); Z={4} keydowns with scan=0; Q={5} with lParam=0" -f $typed.Down, $typed.Null, $typed.M, $typed.Scan, $typed.Scan0, $typed.Lp0)
Write-Output ("  character path: C={0} WM_CHAR (system TranslateMessage, default tier) / X={1} characters produced by the platform layer's own scan-code table (B={2} of them in this frame)" -f $typed.Char, $typed.Tr, $typed.Fb)
Check 'real typing reached the field' ($typed.Len -eq 2 -and $typed.Text -eq "OK") ("L=" + $typed.Len + " T=" + $typed.Text)
Check 'WM_KEYDOWN messages arrived' ($typed.Down -ge 2) ("D=" + $typed.Down)
Check 'characters were produced' (($typed.Char + $typed.Tr) -ge 2) ("C=" + $typed.Char + " X=" + $typed.Tr)

# STEP 3: real backspace -> one char gone
Type-Key 0x08
$backed = Wait-Kb 3000 { param($x) $x.Len -eq 1 }
Write-Output ("record backspace: {0}" -f $backed.Raw)
Check 'real backspace deleted a char' ($backed.Len -eq 1 -and $backed.Text -eq "O") ("L=" + $backed.Len + " T=" + $backed.Text)

# STEP 4: real Enter -> commit (focus lost) and text kept
Type-Key 0x0D
$entered = Wait-Kb 3000 { param($x) $x.Focus -eq -1 }
Write-Output ("record enter    : {0}" -f $entered.Raw)
Check 'Enter committed (unfocused)' ($entered.Focus -eq -1) ("F=" + $entered.Focus)
Check 'Enter kept the text' ($entered.Len -eq 1) ("L=" + $entered.Len)

# STEP 5: platform-layer time channel. Since M4d the app's CV diagnostic line ends with "ms=<tick>",
#   where the value comes from the platform layer (gui_win_input -> GetTickCount), NOT from the kernel
#   (the kernel must never take time itself: byte-exact dump baselines would stop being deterministic).
#   So: every CV line must carry ms > 0, the sequence must never go backwards, and it must really advance
#   during the run -- a hard-coded or never-injected timestamp fails all three.
$cvlines = @(Get-Lines | Where-Object { $_.StartsWith("CV ") })
$msList = @()
foreach ($l in $cvlines) {
  $m = [regex]::Match($l, 'ms=(-?\d+)')
  if ($m.Success) { $msList += [int]$m.Groups[1].Value }
}
$allPos = ($msList.Count -gt 0 -and @($msList | Where-Object { $_ -le 0 }).Count -eq 0)
$mono = $true
for ($i = 1; $i -lt $msList.Count; $i++) { if ($msList[$i] -lt $msList[$i - 1]) { $mono = $false } }
$span = 0
if ($msList.Count -gt 1) { $span = $msList[$msList.Count - 1] - $msList[0] }
Write-Output ("CV lines carrying ms: {0} -> {1}" -f $msList.Count, ($msList -join ","))
Check 'platform layer injected a real timestamp (ms > 0 on every CV line)' $allPos ("lines=" + $msList.Count)
Check 'timestamp is a monotonic clock (never goes backwards)' $mono ("span=" + $span + "ms")
Check 'clock really advanced during the run (span >= 200ms)' ($span -ge 200) ("span=" + $span + "ms")

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Start-Sleep -Milliseconds 200
Write-Output "----"
Write-Output ("pass {0} / fail {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
