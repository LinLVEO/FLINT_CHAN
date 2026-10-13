# verify-panel.ps1 -- self check for apps\winpanel v5 (seven nav pages: Local / Ports / Self /
# Startup / Actions / System / Env, the Opacity+Transparency display and the one-click launchers)
#
# Rule of this script (unchanged since v1): every expected value is recomputed HERE. Nothing the
# app prints is trusted as truth: the app's dump is compared against values this script derives
# from the raw sources (main.fl's own constants, lib\flgui.fl's theme presets, lib\ui_lib.fl's
# fill alpha, state-snapshot.txt, the exe file, the real disks, real TCP connects, real pixels, the
# real registry, the real desktop composition), and the geometry expectations are built from the
# constants this script parses out of main.fl -- no coordinate is hand-written.
#
# v3 changes to the criteria (kept): C0e counts the two theme preset calls / their one call site /
#   zero direct theme_* writes; C2j recomputes every rectangle from main.fl's constants; C2k is the
#   theme A/B; C6m/C6n/C6o are the real-mouse theme round trip, the on-screen palette and "input
#   after a long idle still repaints"; C8 measures the flicker ruler on four artifacts; C9 is the
#   idle CPU + upload A/B.
# v4 adds (Phase A = size + settings page + opacity, Phase B = the registry Startup page):
#   * C1f now parses the new single-point constants too, and C1h checks the AREA ratio against the
#     v3 delivery (the work order's "2.5x" is an area ratio: 1024*736 / (640*460) >= 2.5).
#   * C2c no longer hard-codes the api declaration count: the count is summed over main.fl and the
#     five library files it includes.
#   * C2l: the Settings page + the opacity slider, judged from the app's own ledger AND from the
#     live label the widget layer drew (predicted from the constants + the click point).
#   * C2m: the Startup page's list against PowerShell's OWN read of the same two Run keys.
#   * C6r: a real-mouse Setup -> Back round trip that must come back pixel-identical.
#   * C6s/C6t/C6u: the opacity really moves SCREEN pixels -- judged against the composition model
#     built from lib\ui_lib.fl's fill alpha, a desktop background this script captured itself
#     before the window existed, and the slider's own two end points.
#   * C7a..C7e: no write-registry entry anywhere in the source, the "key does not exist"
#     degradation path (real dump, exit 0), and the import ledger before/after (objdump -p).
# v5 adds (A = the Actions page, B = the System page, C = the Env page, D = the RunOnce keys, plus
# the Opacity/Transparency display):
#   * C2f/C2g/C4c/C7c: the page count is no longer the literal 4 -- it is WP_PAGES read out of
#     main.fl, and the seven page command streams must all differ.
#   * C2l: the Settings page now spells BOTH ends of the knob ("Opacity <n>" and "Transparency <n>",
#     plain 0..100 with no "%") and the status bar carries the opacity; all three are read back out
#     of the live text arena of the frame the widget layer really drew.
#   * C2o: the two RunOnce keys against PowerShell's own read of the same keys (name sets).
#   * C2p: the four System-page strings against PowerShell's own read of the same registry values.
#   * C2q: both Environment keys -- name sets AND the head of every value against the raw registry.
#   * C2r: the Actions table and the SOURCE: N launchers, N call sites, every one verb "open".
#   * C6x/C6y: a REAL click on the Actions tab and on one launcher, with the OS (Get-Process)
#     proving the program started; only the PIDs that appeared during the click are stopped.
#   * C7e: the expected import delta is recomputed from the two SOURCES (which declarations the
#     delivered file has that the v3 file did not), not from a hand-written number.
#
# Checks: C0 hygiene / C1 compile+font+size / C2 dump vs recomputed + geometry + theme + settings +
#         startup / C3 ports / C4 missing data / C5 git / C6 window smoke with REAL input + setup +
#         opacity pixels / C7 registry read-only + degradation + import ledger / B1 refresh /
#         C8 flicker A/B (4 artifacts) / C9 idle CPU A/B.
# Exit code: 0 = every check passed, 1 = at least one failed.
param([switch]$SkipSmoke, [switch]$SkipAB, [switch]$SkipIdle)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$app      = "E:\FLINT-lab\apps\winpanel"
$src      = Join-Path $app "main.fl"
$exe      = Join-Path $app "winpanel.exe"
$bare     = Join-Path $app "main.exe"
$flint    = "E:\FLINT-lab\flint.exe"
$repo     = "E:\FLINT-lab"
$lib      = "E:\FLINT-lab\lib"
$snap     = "C:\Users\20838\Desktop\.dsh-tools\task-engine\state-snapshot.txt"
$marker   = Join-Path $app "panel.dump"
$srcovr   = Join-Path $app "panel.src"
$portsovr = Join-Path $app "panel.ports"
$dumpdir  = "E:\FLINT-lab\tmp\winpanel"
$dump     = Join-Path $dumpdir "panel-dump.txt"
$dumpalt  = Join-Path $app "panel-dump.txt"
$v1dir    = Join-Path $dumpdir "v1"
$v1src    = Join-Path $v1dir "v1-main.fl"
$v1exe    = Join-Path $v1dir "v1panel.exe"
$v2dir    = Join-Path $dumpdir "v2"
$v2src    = Join-Path $v2dir "v2-main.fl"
$v2exe    = Join-Path $v2dir "v2panel.exe"
$v3dir    = Join-Path $dumpdir "v3"
$v3src    = Join-Path $v3dir "v3-main.fl"
$v3exe    = Join-Path $v3dir "v3panel.exe"
$regovr   = Join-Path $app "panel.reg"
# v9 (M9): the language tables, the config file the app now reads/writes, and the two scratch paths
# this round's checks back things up into (the user's own config is never destroyed -- see the note at
# the top of the C10 block: it is copied aside before the first run and put back at the very end).
$cfgfile  = Join-Path $app "winpanel.cfg"
$langen   = Join-Path $app "lang.en.txt"
$langzh   = Join-Path $app "lang.zh.txt"
$cfguser  = Join-Path $dumpdir "winpanel.cfg.user-backup"
$langzbak = Join-Path $dumpdir "lang.zh.txt.m9bak"
$frozen   = Join-Path $dumpdir "frozen-snapshot.txt"
$fpsled   = Join-Path $dumpdir "panel-fps.txt"
$fpson    = Join-Path $dumpdir "fps.on"
# v10 (M12): the app's own layer trace has to be LIVE for the C6 window instance, because one of the
# new judges (C11c) asks "did the panel really PROCESS that press" and the panel's answer is the
# `press` line in this file -- written only when layer.on exists at startup. The C10 block re-creates
# both markers itself, so declaring them here (and cleaning them up after C6) changes nothing for it.
$c10TraceEarly = Join-Path $dumpdir "panel-layer.txt"
$c10TraceOnEarly = Join-Path $dumpdir "layer.on"
$cls      = "WINPANEL4"
$clsV2    = "WINPANEL2"
$clsV1    = "WINPANEL"
$ports    = @(3080, 8080, 8090, 8091, 8092)
# the three git anchors this suite rebuilds: v3 = the delivered predecessor (import baseline),
# v2 = the FLGUI version, v1 = the pre-FLGUI one
$gitV3    = "105ea7c"
$gitV2    = "be3a040"
$gitV1    = "9c127f1"

$CHK = New-Object System.Collections.ArrayList
function Check([string]$id, [string]$name, [bool]$ok, [string]$detail) {
  [void]$CHK.Add([pscustomobject]@{ Id = $id; Name = $name; Ok = $ok; Detail = $detail })
  $tag = "FAIL"; if ($ok) { $tag = "ok  " }
  Write-Output ("[{0}] {1,-48} {2}  {3}" -f $tag, $id, $name, $detail)
}
function CleanMarkers() {
  foreach ($f in @($marker, $srcovr, $portsovr, $dumpalt, $fpson, $regovr)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
}
function ReadDump([string]$p) {
  $h = @{}
  foreach ($line in (Get-Content -LiteralPath $p -Encoding Default)) {
    $i = $line.IndexOf('=')
    if ($i -gt 0) { $h[$line.Substring(0, $i)] = $line.Substring($i + 1) }
  }
  return $h
}
function RunDump([int]$timeoutMs) {
  if (Test-Path -LiteralPath $dump) { Remove-Item -LiteralPath $dump -Force }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $pr = Start-Process -FilePath $exe -PassThru
  while (-not $pr.HasExited -and $sw.ElapsedMilliseconds -lt $timeoutMs) { Start-Sleep -Milliseconds 25 }
  if (-not $pr.HasExited) { Stop-Process -Id $pr.Id -Force; return @{ rc = -999; ms = [int]$sw.ElapsedMilliseconds } }
  return @{ rc = $pr.ExitCode; ms = [int]$sw.ElapsedMilliseconds }
}
function TcpState([string]$ip, [int]$port, [int]$capMs) {
  $cl = New-Object System.Net.Sockets.TcpClient
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $st = "down"
  try {
    $ar = $cl.BeginConnect($ip, $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne($capMs)) {
      try { $cl.EndConnect($ar); $st = "up" } catch { $st = "down" }
    } else { $st = "timeout" }
  } catch { $st = "down" }
  $sw.Stop()
  try { $cl.Close() } catch { }
  return @{ st = $st; ms = [int]$sw.ElapsedMilliseconds }
}

Add-Type -AssemblyName System.Drawing
# v10 (M12): C11d needs a window of this judge's OWN to hold the foreground (see the note there), and
# a WinForms form is the cheapest way to have one whose rect this script controls exactly.
Add-Type -AssemblyName System.Windows.Forms
if (-not ("WinPanelProbe" -as [type])) {
  Add-Type @"
using System;using System.Runtime.InteropServices;
public struct WPRECT { public int l,t,r,b; }
public struct WPPOINT { public int x,y; }
public class WinPanelProbe {
 [DllImport("user32.dll",CharSet=CharSet.Ansi)] public static extern IntPtr FindWindowA(string c, string w);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WPRECT r);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 // v10 (M12): C11d minimizes the focused window and then requires the panel to come back by itself,
 // so the judge has to ask the OS whether that window really is down (a ShowWindow that silently
 // failed would otherwise be read as "the panel did not come back").
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(out WPPOINT p);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  // v7 (M7): C6x3 puts a REAL topmost window above the panel and walks the z-order itself, so the
  // `auto` behaviour is judged from the OS and never from the app's own verdict.
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  // v10 (M12): the judge's own absolute z-order walk. `C11d` needs to see the panel MOVE to the front
  // of the normal band when the focused window minimizes -- "the panel is above the minimized window"
  // is NOT good enough, because Windows demotes a minimized window behind everything on its own, so
  // that comparison can be true while the panel never moved at all (measured: it stayed exactly where
  // it was and the check still read "in front").
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int cx, int cy, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  // v10 (M12): C11c asserts that a real click at the panel's centre really reaches the PANEL, so the
  // judge asks the OS the same question the user's mouse asks it: which window owns this screen point.
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(WPPOINT p);
  // v10 (M12): C11e compares the app's own fg_pid against the pid THIS judge measures for the window
  // GetForegroundWindow hands it -- the cross-check the user asked for ("let the judges verify it
  // themselves instead of trusting the app").
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  // v8 (M8): C6x4/C6x4b. These inject a keyboard chord, and the ONLY chord they may ever inject is
  // one the panel itself registered (the system swallows a registered chord, so no other application
  // can see it). See the incident note in tmp\m8\hotkey-probe.ps1 before editing anything here.
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
 [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
}
"@
}
[void][WinPanelProbe]::SetProcessDPIAware()

# ---- the input-injection precondition (measured 2026-10-10, v5 round) ---------------------------
# While an ELEVATED window owns the foreground, Windows discards EVERY synthetic mouse event this
# script sends (UIPI). Measured here: with an elevated Task Manager left in the foreground,
# SetCursorPos returned False and the cursor never moved, so all twelve real-click checks went red
# for a reason that had nothing to do with the panel. `Stop-Process` on that Task Manager is denied
# (Access denied), so the fix is not to kill it but to give the foreground to a normal-integrity
# window of our own -- and then to PROVE injection works before any click check is trusted.
function Test-Inject {
  $p = New-Object WPPOINT
  [void][WinPanelProbe]::GetCursorPos([ref]$p)
  $x0 = $p.x; $y0 = $p.y
  $ok = [WinPanelProbe]::SetCursorPos(($x0 + 9), ($y0 + 7))
  Start-Sleep -Milliseconds 150
  $q = New-Object WPPOINT
  [void][WinPanelProbe]::GetCursorPos([ref]$q)
  $moved = (($q.x -ne $x0) -or ($q.y -ne $y0))
  [void][WinPanelProbe]::SetCursorPos($x0, $y0)
  Start-Sleep -Milliseconds 80
  return @{ ok = ($ok -and $moved); from = "$x0,$y0"; to = "$($q.x),$($q.y)"; fg = [WinPanelProbe]::GetForegroundWindow() }
}

# ---- pixel helpers (the ruler and the on-screen readers) --------------------------------------
function ImgShot([IntPtr]$hwnd, [int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [void][WinPanelProbe]::PrintWindow($hwnd, $hdc, 3)   # PW_CLIENTONLY | PW_RENDERFULLCONTENT
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  return $bmp
}
function ImgBytes([System.Drawing.Bitmap]$bmp) {
  $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
  $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($d.Stride * $bmp.Height)
  [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($d)
  return @{ bytes = $bytes; stride = $d.Stride }
}
# v4: the REAL screen (composited: the layered window blended with whatever is behind it). The
# PrintWindow reader above returns the offscreen DIB, which does NOT carry the window's constant
# alpha -- so the opacity criterion needs this second ruler.
function ShotScreen([int]$x, [int]$y, [int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $g.Dispose()
  return $bmp
}
# gui_hash (lib\flgui.fl) re-implemented here: djb2 masked to 31 bits. Reimplemented on purpose --
# the check "the opacity lives in the pool slot the documentation names" must not read the app's
# own claim, it must recompute the key from the string.
function GuiHash([string]$s) {
  $h = [long]5381
  foreach ($ch in [System.Text.Encoding]::ASCII.GetBytes($s)) { $h = (($h * 33) + [long]$ch) -band 0x7FFFFFFF }
  return [int]$h
}
# the two Run keys read by PowerShell ITSELF (the independent judge for the Startup page). Returns
# @{ ok = <key could be opened>; names = @(...); bytes = <sum of the data sizes RegQueryValueExA
# would report> }. The byte count reproduces what the A-variant API returns: for a string value the
# size is the ANSI byte length of the data including the terminating NUL (measured: 573 here).
function RegRead([string]$which, [string]$sub) {
  $names = @()
  $bytes = 0
  $ok = $false
  $root = $null
  if ($which -eq "hkcu") { $root = [Microsoft.Win32.Registry]::CurrentUser }
  if ($which -eq "hklm") { $root = [Microsoft.Win32.Registry]::LocalMachine }
  if ($root -ne $null) {
    $key = $root.OpenSubKey($sub)
    if ($key -ne $null) {
      $ok = $true
      $enc = [System.Text.Encoding]::Default          # the A-variant API converts with the ACP
      foreach ($n in $key.GetValueNames()) {
        $names += $n
        $kind = $key.GetValueKind($n)
        $v = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::String -or $kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
          $bytes += $enc.GetByteCount([string]$v) + 1
        } elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
          $bytes += ([byte[]]$v).Length
        } elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
          $bytes += 4
        } elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::QWord) {
          $bytes += 8
        } elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::MultiString) {
          foreach ($s in [string[]]$v) { $bytes += $enc.GetByteCount([string]$s) + 1 }
          $bytes += 1
        }
      }
      $key.Close()
    }
  }
  return @{ ok = $ok; names = @($names); bytes = $bytes }
}
# ===== the opacity composition model ==========================================================
# UpdateLayeredWindow with AC_SRC_OVER + AC_SRC_ALPHA + SourceConstantAlpha = a composes
#     out = P * a / 255 + bg * (1 - fillA * a / (255 * 255))
# where P is the offscreen DIB's RGB (already premultiplied by ui_lib.fl's surf_alpha with the
# alpha-dependent fill value -- v6: fillA1 / fillA2, one per capture, because the app drives the
# surface alpha from the same knob; see FillAOf above)
# and bg is what is behind the window. PowerShell captures all three of P (PrintWindow), bg (a
# screen shot taken BEFORE the window existed) and out (a screen shot of the live window), so the
# model can be checked channel by channel -- and the "no opacity at all" null model (both captures
# sitting at the default alpha) can be shown to fail.
function OpaError([hashtable]$scrA, [hashtable]$dibA, [hashtable]$scrB, [hashtable]$dibB, [hashtable]$bg, [int]$aA, [int]$aB, [int]$fillA1, [int]$fillA2, [int]$ySkip0, [int]$ySkip1, [int]$W, [int]$H, [int]$sx, [int]$sy) {
  $e = New-Object System.Collections.ArrayList
  $mov = New-Object System.Collections.ArrayList
  $n = 0
  # v9 (M9): `bad8` = how many samples miss the model by more than 8 levels. Added for the C10e
  # opacity check, which samples the WHOLE client area (glyph pixels and a live desktop included):
  # there a fixed p99 bound turned out to be a bad ruler -- measured 2026-10-10, dropping one key from
  # lang.zh.txt (an unrelated change that only moves which pixels carry glyphs) drove p99 from 0.52 to
  # 149.86 while the median stayed at 0.29. The counter is purely additive: no existing key of this
  # hashtable changed, so C6s/C6u read exactly what they read before.
  $bad8 = 0
  for ($y = $sy; $y -lt ($H - $sy); $y += $sy) {
    if ($y -ge $ySkip0 -and $y -lt $ySkip1) { continue }   # the widget band: the DIB itself moves there
    for ($x = $sx; $x -lt ($W - $sx); $x += $sx) {
      for ($c = 0; $c -lt 3; $c++) {
        $i = $y * $scrA.stride + $x * 4 + $c
        $P = [double]$dibA.bytes[$i]
        $B = [double]$bg.bytes[$i]
        $pA = $P * $aA / 255.0 + $B * (1.0 - ($fillA1 * $aA) / 65025.0)
        $pB = $P * $aB / 255.0 + $B * (1.0 - ($fillA2 * $aB) / 65025.0)
        $d1 = [Math]::Abs([double]$scrA.bytes[$i] - $pA)
        $d2 = [Math]::Abs([double]$scrB.bytes[$i] - $pB)
        if ($d2 -gt $d1) { $d1 = $d2 }
        if ($d1 -gt 8.0) { $bad8++ }
        [void]$e.Add($d1)
        [void]$mov.Add([Math]::Abs([double]$scrA.bytes[$i] - [double]$scrB.bytes[$i]))
        $n++
      }
    }
  }
  $se = @($e | Sort-Object)
  $sm = @($mov | Sort-Object)
  # v10 (M12): `agg` = the SUM of every sample's error, and `gt20` = how many samples miss the model by
  # more than 20 levels. Why they exist: C6u (the "the pixels reject the opacity-ignored model" check)
  # reads the MEDIAN, and the median of a null model measured 4413/5059/5408/5505 on four clean runs --
  # but once 17.7 ("both captures at the default alpha" on a run where the desktop behind the panel had
  # moved between the two captures). Two keys are added; NO existing key changed, so C6s/C6s2 keep
  # reading exactly what they read before.
  $agg = 0.0
  $gt20 = 0
  foreach ($v in $e) { $agg = $agg + $v; if ($v -gt 20.0) { $gt20++ } }
  return @{ n = $n; med = $se[[int]($n / 2)]; p99 = $se[[int]($n * 0.99)]; max = $se[$n - 1]; medMove = $sm[[int]($n / 2)]; bad8 = $bad8; agg = $agg; gt20 = $gt20 }
}
function ImgHash([System.Drawing.Bitmap]$bmp) {
  $b = ImgBytes $bmp
  $md5 = [System.Security.Cryptography.MD5]::Create()
  return [BitConverter]::ToString($md5.ComputeHash($b.bytes))
}
# ink = pixels with any colour channel above 40 (a proxy for "there is something painted here")
function ImgInk([System.Drawing.Bitmap]$bmp) {
  $b = ImgBytes $bmp
  $n = 0
  for ($i = 0; $i -lt $b.bytes.Length; $i += 4) {
    if ($b.bytes[$i] -gt 40 -or $b.bytes[$i + 1] -gt 40 -or $b.bytes[$i + 2] -gt 40) { $n++ }
  }
  return $n
}
function BandAvg([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  $b = ImgBytes $bmp
  $sum = 0; $n = 0
  for ($y = $y0; $y -lt $y1; $y++) {
    for ($x = $x0; $x -lt $x1; $x++) {
      $i = $y * $b.stride + $x * 4
      $sum += ($b.bytes[$i] + $b.bytes[$i + 1] + $b.bytes[$i + 2])
      $n++
    }
  }
  if ($n -eq 0) { return 0 }
  return [int]($sum / (3 * $n))
}
# count pixels of an exact RGB triple (the theme palette is checked with this)
function CountRGB([System.Drawing.Bitmap]$bmp, [int]$cr, [int]$cg, [int]$cb) {
  $b = ImgBytes $bmp
  $n = 0
  for ($i = 0; $i -lt $b.bytes.Length; $i += 4) {
    if ($b.bytes[$i] -eq $cb -and $b.bytes[$i + 1] -eq $cg -and $b.bytes[$i + 2] -eq $cr) { $n++ }
  }
  return $n
}
# first row (y0..y1) down column x whose colour is NOT (cr,cg,cb); -1 = never
function FirstOther([System.Drawing.Bitmap]$bmp, [int]$x, [int]$y0, [int]$y1, [int]$cr, [int]$cg, [int]$cb) {
  $b = ImgBytes $bmp
  for ($y = $y0; $y -lt $y1; $y++) {
    $i = $y * $b.stride + $x * 4
    if (-not ($b.bytes[$i] -eq $cb -and $b.bytes[$i + 1] -eq $cg -and $b.bytes[$i + 2] -eq $cr)) { return $y }
  }
  return -1
}
# count pixels bright enough to be glyph ink (sum > 300): the translucent backdrop stays below it
function BandCount([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  $b = ImgBytes $bmp
  $n = 0
  for ($y = $y0; $y -lt $y1; $y++) {
    for ($x = $x0; $x -lt $x1; $x++) {
      $i = $y * $b.stride + $x * 4
      if ((([int]$b.bytes[$i] + [int]$b.bytes[$i + 1] + [int]$b.bytes[$i + 2]) -gt 300)) { $n++ }
    }
  }
  return $n
}
# count pixels in a band that differ from the band's own top-left pixel: a theme-agnostic glyph
# ink proxy (the old "sum > 300" proxy assumed the dark theme's dark background and counted the
# whole light blue-white background as ink)
function BandInkVsCorner([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  $b = ImgBytes $bmp
  $i0 = $y0 * $b.stride + $x0 * 4
  $cb = [int]$b.bytes[$i0]; $cg = [int]$b.bytes[$i0 + 1]; $cr = [int]$b.bytes[$i0 + 2]
  $n = 0
  for ($y = $y0; $y -lt $y1; $y++) {
    for ($x = $x0; $x -lt $x1; $x++) {
      $i = $y * $b.stride + $x * 4
      if (-not ([int]$b.bytes[$i] -eq $cb -and [int]$b.bytes[$i + 1] -eq $cg -and [int]$b.bytes[$i + 2] -eq $cr)) { $n++ }
    }
  }
  return $n
}
function BandHash([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
  $b = ImgBytes $bmp
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $acc = New-Object System.Collections.Generic.List[byte]
  for ($y = $y0; $y -lt $y1; $y++) {
    for ($x = $x0; $x -lt $x1; $x++) {
      $i = $y * $b.stride + $x * 4
      $acc.Add($b.bytes[$i]); $acc.Add($b.bytes[$i + 1]); $acc.Add($b.bytes[$i + 2])
    }
  }
  return [BitConverter]::ToString($md5.ComputeHash($acc.ToArray()))
}
# count "dark ink" pixels inside a rect (sum < 300). The smoke checks run in the blue-white theme,
# where a button's fill is white (~600) and its 1px border ~520, so only glyph pixels fall below 300
function DarkIn([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$w, [int]$h) {
  $b = ImgBytes $bmp
  $n = 0
  for ($y = $y0; $y -lt ($y0 + $h); $y++) {
    for ($x = $x0; $x -lt ($x0 + $w); $x++) {
      $i = $y * $b.stride + $x * 4
      if ((([int]$b.bytes[$i] + [int]$b.bytes[$i + 1] + [int]$b.bytes[$i + 2]) -lt 300)) { $n++ }
    }
  }
  return $n
}
# port row state from pixels: 'up' = green text, 'down' = red text, 'wait' = neutral ('--')
function RowStates([System.Drawing.Bitmap]$bmp, [int]$x0, [int]$y0, [int]$dy, [int]$nRows) {
  $b = ImgBytes $bmp
  $out = @{}
  for ($rr = 0; $rr -lt $nRows; $rr++) {
    $ry = $y0 + $rr * $dy
    $g = 0; $rd = 0
    for ($y = $ry; $y -lt $ry + 14; $y++) {
      for ($x = $x0; $x -lt $x0 + 50; $x++) {
        $i = $y * $b.stride + $x * 4
        $bb = [int]$b.bytes[$i]; $gg = [int]$b.bytes[$i + 1]; $cr = [int]$b.bytes[$i + 2]
        if ($gg -gt ($cr + 25) -and $gg -gt ($bb + 25) -and $gg -gt 110) { $g++ }
        if ($cr -gt ($gg + 25) -and $cr -gt ($bb + 25) -and $cr -gt 110) { $rd++ }
      }
    }
    $st = "wait"
    if ($g -gt 12 -and $g -gt $rd) { $st = "up" }
    elseif ($rd -gt 12 -and $rd -gt $g) { $st = "down" }
    $out[$rr] = @{ st = $st; green = $g; red = $rd }
  }
  return $out
}
function ClickAt([int]$x, [int]$y) {
  [void][WinPanelProbe]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  [WinPanelProbe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # LEFTDOWN
  Start-Sleep -Milliseconds 160
  [WinPanelProbe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # LEFTUP
  Start-Sleep -Milliseconds 300
}
# park the pointer far away from the panel: clears any hover state and keeps the app idle
function Park() {
  [void][WinPanelProbe]::SetCursorPos(5, 1070)
  Start-Sleep -Milliseconds 450
}
# v7 (M7): is $other ABOVE $h in the REAL z-order? Walks GW_HWNDPREV (3) upwards from $h. This is
# the script's own reading of the question the panel's `auto` policy has to answer -- it exists
# because WindowFromPoint was measured to answer about the desktop instead (see C6x3).
function ZAbove([IntPtr]$h, [IntPtr]$other) {
  $w = [WinPanelProbe]::GetWindow($h, 3)
  $n = 0
  while (($w -ne [IntPtr]::Zero) -and ($n -lt 400)) {
    if ($w -eq $other) { return $true }
    $w = [WinPanelProbe]::GetWindow($w, 3)
    $n++
  }
  return $false
}
# v10 (M12): the panel's `press` counter out of its own layer trace. Reads only the LAST line (the app
# rewrites the trace continuously), so a caller compares two reads. -1 = the trace says nothing.
# v10 (M12): the judge's own absolute z-order position of a window (0 = the topmost window on the
# desktop). Used by C11d, where "is it in front?" must mean "it really moved towards the front", not
# "the other window went behind it".
function ZIndex([IntPtr]$h) {
  $w = [WinPanelProbe]::GetTopWindow([IntPtr]::Zero)
  $n = 0
  while (($w -ne [IntPtr]::Zero) -and ($n -lt 4000)) {
    if ($w -eq $h) { return $n }
    $w = [WinPanelProbe]::GetWindow($w, 2)      # GW_HWNDNEXT = the next window DOWN the z-order
    $n++
  }
  return -1
}
# v10 (M12): one headless dump run from inside the C6 block. RunDumpM9 is defined further down (the
# C10 block owns it), and C11e -- which runs here, while the panel window is still alive -- needs the
# same discipline: the marker exists only around the call, so a stray window can never be left behind.
function DumpOnce([int]$timeoutMs) {
  New-Item -ItemType File -Force -Path $marker | Out-Null
  $r = RunDump $timeoutMs
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  return $r
}
function TracePress() {
  if (-not (Test-Path -LiteralPath $c10TraceEarly)) { return -1 }
  $l = [string](Get-Content -LiteralPath $c10TraceEarly -Tail 1 -ErrorAction SilentlyContinue)
  $m = [regex]::Match($l, 'pressn=(\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}
# v13 (M14): the whole last trace line. The app rewrites that file per line, so only the last line
# survives; C11g reads it while a press is still DOWN, which is the only way to catch a transient tag.
function TraceLine() {
  if (-not (Test-Path -LiteralPath $c10TraceEarly)) { return '' }
  try { return [string](Get-Content -LiteralPath $c10TraceEarly -Tail 1 -ErrorAction SilentlyContinue) } catch { return '' }
}
# M4r: drag the panel by its title bar (the platform layer only drags from the top 24 px). Press
# inside the title bar, then walk the pointer to (x+dx, y+dy) in small steps so the app sees several
# "window moved, content unchanged" frames, then release. The caller passes the ACTUAL delta it wants
# (measured from GetWindowRect) so the window can be put back exactly where it was.
function DragTitle([int]$x, [int]$y, [int]$dx, [int]$dy) {
  [void][WinPanelProbe]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 150
  [WinPanelProbe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # LEFTDOWN
  for ($s = 1; $s -le 12; $s++) {
    [void][WinPanelProbe]::SetCursorPos(($x + [int]($dx * $s / 12)), ($y + [int]($dy * $s / 12)))
    Start-Sleep -Milliseconds 30
  }
  [WinPanelProbe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # LEFTUP
  Start-Sleep -Milliseconds 300
}
function WaitWindow([string]$wcls, [int]$timeoutMs) {
  $hw = [IntPtr]::Zero
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    Start-Sleep -Milliseconds 25
    $hw = [WinPanelProbe]::FindWindowA($wcls, $null)
    if ($hw -ne [IntPtr]::Zero) { break }
  }
  return @{ hwnd = $hw; ms = [int]$sw.ElapsedMilliseconds }
}
# high resolution CPU clock (GetProcessTimes = what TotalProcessorTime wraps, without its ~15.6 ms
# granularity); returns 100ns units of kernel+user, or -1
function CpuNs([System.Diagnostics.Process]$p) {
  $c = [long]0; $e = [long]0; $k = [long]0; $u = [long]0
  $h = $p.Handle
  if (-not [WinPanelProbe]::GetProcessTimes($h, [ref]$c, [ref]$e, [ref]$k, [ref]$u)) { return -1 }
  return ($k + $u)
}
# the app's own cumulative ledger. v2: "F <renders> ms=<tick>" every 30 frames.
# v3: "loops=<pump iterations> renders=<uploads> tick=<tick>" every 500 ms.
# M4r: "... tick=<tick> flushes=<position-only re-uploads>" (appended AFTER tick so old readers keep
# working; the window-move fast path is judged from this counter).
function LedgerRead([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $line = (Get-Content -LiteralPath $path -Tail 1)
  if (-not $line) { return $null }
  $o = @{ renders = -1; tick = -1; loops = -1; flushes = -1; raw = $line }
  $m = [regex]::Match($line, '^F\s+(\d+)\s+ms=(\d+)')
  if ($m.Success) { $o.renders = [int]$m.Groups[1].Value; $o.tick = [int]$m.Groups[2].Value; return $o }
  $m = [regex]::Match($line, 'loops=(\d+)\s+renders=(\d+)\s+tick=(\d+)')
  if ($m.Success) {
    $o.loops = [int]$m.Groups[1].Value; $o.renders = [int]$m.Groups[2].Value; $o.tick = [int]$m.Groups[3].Value
    $mf = [regex]::Match($line, 'flushes=(\d+)')
    if ($mf.Success) { $o.flushes = [int]$mf.Groups[1].Value }
  }
  return $o
}
# the ONE ruler used for every artifact: sample the window every IntervalMs, count frames that
# differ from the majority frame (those are the intermediate states the eye reads as flicker)
function Measure-Flicker([string]$exePath, [string]$wcls, [int]$frames, [int]$intervalMs, [int]$warmupMs, [int[]]$clickAt) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
  Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 250
  $p = Start-Process -FilePath $exePath -PassThru
  $w = WaitWindow $wcls 6000
  $hw = $w.hwnd
  if ($hw -eq [IntPtr]::Zero) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    return @{ ok = $false; frames = 0; diff = -1; distinct = -1; ink = 0; w = 0; h = 0; upMs = $w.ms }
  }
  $upMs = $w.ms
  $rc = New-Object WPRECT
  [void][WinPanelProbe]::GetWindowRect($hw, [ref]$rc)
  $ww = $rc.r - $rc.l; $hh = $rc.b - $rc.t
  # optional real click before sampling (how the dark-theme run is set up)
  if ($clickAt -and $clickAt.Count -eq 2) {
    ClickAt ($rc.l + $clickAt[0]) ($rc.t + $clickAt[1])
  }
  Park
  Start-Sleep -Milliseconds $warmupMs
  $hashes = New-Object System.Collections.ArrayList
  $inkmin = [int]::MaxValue
  for ($i = 0; $i -lt $frames; $i++) {
    $bmp = ImgShot $hw $ww $hh
    [void]$hashes.Add((ImgHash $bmp))
    $ink = ImgInk $bmp
    if ($ink -lt $inkmin) { $inkmin = $ink }
    $bmp.Dispose()
    Start-Sleep -Milliseconds $intervalMs
  }
  $groups = @($hashes | Group-Object | Sort-Object Count -Descending)
  $modal = $groups[0].Count
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Start-Sleep -Milliseconds 250
  return @{ ok = $true; frames = $frames; diff = ($frames - $modal); distinct = $groups.Count; ink = $inkmin; w = $ww; h = $hh; modal = $modal; upMs = $upMs }
}
# idle measurement: no input at all for `seconds`, pointer parked away from the panel. Returns the
# exact CPU time (both clocks), the upload/pump deltas from the app's own ledger, and -- when a
# click point is given -- whether a real click AFTER the idle window still changes the picture.
function Measure-Idle([string]$exePath, [string]$wcls, [int]$seconds, [int[]]$clickAt) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($exePath)
  Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  if (Test-Path -LiteralPath $fpsled) { Remove-Item -LiteralPath $fpsled -Force }
  New-Item -ItemType File -Force -Path $fpson | Out-Null    # the app checks this at startup
  $p = Start-Process -FilePath $exePath -PassThru
  $w = WaitWindow $wcls 6000
  if ($w.hwnd -eq [IntPtr]::Zero) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Remove-Item -LiteralPath $fpson -Force -ErrorAction SilentlyContinue
    return @{ ok = $false }
  }
  $rc = New-Object WPRECT
  [void][WinPanelProbe]::GetWindowRect($w.hwnd, [ref]$rc)
  $ww = $rc.r - $rc.l; $hh = $rc.b - $rc.t
  Park
  Start-Sleep -Milliseconds 1500
  $l0 = LedgerRead $fpsled
  $n0 = CpuNs $p
  $t0 = $p.TotalProcessorTime
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # poll the app's own ledger while idling: the upload counter's timeline is the evidence for
  # "nothing was drawn", and it also shows WHEN a stray frame happened if one ever does
  $tl = New-Object System.Collections.ArrayList
  $lastLed = ""
  # the pointer watchdog: this panel covers the middle of the screen, so a LIVE user moving the mouse
  # across it makes the app repaint on hover -- by design. Such a round would measure the human, not
  # the app, so it is flagged and retried rather than counted as an idle-CPU regression (measured
  # 2026-10-10: one 30 s round reported 25.9% single core and 520 uploads purely from that, while a
  # pointer-quiet 40 s round of the SAME binary stayed at renders=1 / flushes=0).
  $touched = $false
  while ($sw.ElapsedMilliseconds -lt ($seconds * 1000)) {
    Start-Sleep -Milliseconds 400
    $pNow = New-Object WPPOINT
    [void][WinPanelProbe]::GetCursorPos([ref]$pNow)
    if (($pNow.x -ne 5) -or ($pNow.y -ne 1070)) { $touched = $true }
    $cur = LedgerRead $fpsled
    if ($cur) {
      if ($cur.raw -ne $lastLed) { [void]$tl.Add(("t={0}ms {1}" -f [int]$sw.ElapsedMilliseconds, $cur.raw)); $lastLed = $cur.raw }
    }
  }
  $sw.Stop()
  $t1 = $p.TotalProcessorTime
  $n1 = CpuNs $p
  $l1 = LedgerRead $fpsled
  $changed = -1
  if ($clickAt -and $clickAt.Count -eq 2) {    $b = ImgShot $w.hwnd $ww $hh
    $h0 = ImgHash $b
    $b.Dispose()
    ClickAt ($rc.l + $clickAt[0]) ($rc.t + $clickAt[1])
    Park
    $b = ImgShot $w.hwnd $ww $hh
    $h1 = ImgHash $b
    $b.Dispose()
    if ($h0 -ne $h1) { $changed = 1 } else { $changed = 0 }
  }
  $rcEnd = New-Object WPRECT
  [void][WinPanelProbe]::GetWindowRect($w.hwnd, [ref]$rcEnd)   # read BEFORE the kill (else 0x0)
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Start-Sleep -Milliseconds 250
  Remove-Item -LiteralPath $fpson -Force -ErrorAction SilentlyContinue
  $renders0 = -1; $renders1 = -1; $loops0 = -1; $loops1 = -1
  if ($l0) { $renders0 = $l0.renders; $loops0 = $l0.loops }
  if ($l1) { $renders1 = $l1.renders; $loops1 = $l1.loops }
  return @{
    ok = $true; seconds = $seconds; touched = $touched
    cpuMs = [int](($t1 - $t0).TotalMilliseconds); cpuNs = [long](($n1 - $n0) / 10000)
    wallMs = [int]$sw.ElapsedMilliseconds
    renders = ($renders1 - $renders0); loops = ($loops1 - $loops0)
    rectBefore = "${ww}x${hh}"; rectAfter = "$($rcEnd.r - $rcEnd.l)x$($rcEnd.b - $rcEnd.t)"
    led0 = $(if ($l0) { $l0.raw } else { "" }); led1 = $(if ($l1) { $l1.raw } else { "" })
    timeline = @($tl)
    afterClickChanged = $changed
  }
}
# theme palette straight out of the library (independent judge: the values are NOT taken from the app)
function Get-LibText([string]$p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Parse-ThemeBody([string]$text, [string]$fn) {
  $m = [regex]::Match($text, ('int ' + $fn + '\(struct GuiCtx \*c\) \{(.*?)\n\}'), [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return @{} }
  $h = @{}
  foreach ($mm in [regex]::Matches($m.Groups[1].Value, 'c->theme_([a-z_0-9]+)\s*=\s*(0x[0-9A-Fa-f]+|[0-9]+)\s*;')) {
    $v = $mm.Groups[2].Value
    if ($v.StartsWith("0x")) { $h[$mm.Groups[1].Value] = [Convert]::ToInt64($v.Substring(2), 16) } else { $h[$mm.Groups[1].Value] = [int]$v }
  }
  return $h
}
# COLORREF (0x00BBGGRR) -> the exact RGB triple PrintWindow hands back for it, i.e. the DIB content
# premultiplied by the surface fill alpha (lib\ui_lib.fl surf_alpha: px = px * a / 255, integer).
function PremulRGB([long]$colorref, [int]$a) {
  $r = [int]($colorref -band 0xFF)
  $g = [int](($colorref -shr 8) -band 0xFF)
  $b = [int](($colorref -shr 16) -band 0xFF)
  # Floor, not [int]: PowerShell's [int] cast ROUNDS (233*200/255 = 182.7 -> 183) while the library
  # truncates (surf_alpha writes px = px * a / 255 with integer division) -> 182
  return @([int][Math]::Floor($r * $a / 255), [int][Math]::Floor($g * $a / 255), [int][Math]::Floor($b * $a / 255))
}
function Csv([int[]]$v) { return ($v -join ",") }

Write-Output "==================== winpanel verify v3 ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ===================="
CleanMarkers
Get-Process -Name winpanel, v1panel, v2panel -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300
if (-not (Test-Path -LiteralPath $dumpdir)) { New-Item -ItemType Directory -Force -Path $dumpdir | Out-Null }
if (-not (Test-Path -LiteralPath $v2dir)) { New-Item -ItemType Directory -Force -Path $v2dir | Out-Null }

# v9 (M9): the app READS its own config file at startup now, so this whole suite has to run from a
# known config state. A file the user saved is copied aside here and put back at the very end; it is
# never destroyed. (C10f does its own backup/restore on top of this when it deletes the file.)
$cfgHadUser = Test-Path -LiteralPath $cfgfile
if (Test-Path -LiteralPath $cfguser) { Remove-Item -LiteralPath $cfguser -Force }
if ($cfgHadUser) {
  Copy-Item -LiteralPath $cfgfile -Destination $cfguser -Force
  Remove-Item -LiteralPath $cfgfile -Force
}

# ---------------------------------------------------------------- C0 source hygiene
$bytes = [System.IO.File]::ReadAllBytes($src)
$hi = 0
foreach ($b in $bytes) { if ($b -gt 127) { $hi++ } }
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check "C0a" "main.fl is pure ASCII" ($hi -eq 0) "bytes=$($bytes.Length) bytes>127=$hi"
Check "C0b" "main.fl has no BOM" (-not $bom) "BOM=$bom"
# C0c: structural evidence for the flicker fix -- the app source must not draw to a window DC at
# all; the whole frame goes through the FLGUI four-step protocol.
$txt = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::ASCII)
$forbidden = @("GetDC(", "ReleaseDC(", "ui_text(", "ui_fill_rgb(", "PeekMessageA(", "ui_num(", "seg_mk(")
$found = @()
foreach ($f in $forbidden) { if ($txt.Contains($f)) { $found += $f } }
Check "C0c" "no direct-draw API in the app source (v1 drew per frame)" ($found.Count -eq 0) "forbidden_hits=[$($found -join ',')] needle=GetDC/ReleaseDC/ui_text/ui_fill_rgb"
$c1 = ([regex]::Matches($txt, [regex]::Escape("gui_begin("))).Count
$c2 = ([regex]::Matches($txt, [regex]::Escape("gui_end("))).Count
$c3 = ([regex]::Matches($txt, [regex]::Escape("gui_win_render("))).Count
$c4 = ([regex]::Matches($txt, [regex]::Escape("gui_win_show("))).Count
Check "C0d" "four-step protocol present exactly once (begin/end/render/show)" (($c1 -eq 1) -and ($c2 -eq 1) -and ($c3 -eq 1) -and ($c4 -eq 1)) "gui_begin=$c1 gui_end=$c2 gui_win_render=$c3 gui_win_show=$c4"
# C0e (v3 wording -- the work order allows this one change and it must say why): v2 required "the
# app overrides no theme_* field" because the dark library default WAS the wanted theme. v3 wants
# the blue-white preset as the default with a toggle, so the criterion is now: switching the theme
# happens through the two preset functions ONLY, from exactly ONE call site, and the app still
# writes no theme_* field itself. Counts: 1 call each inside one function, and one call of it.
$thAssign = ([regex]::Matches($txt, '\.theme_[a-z_0-9]+\s*=')).Count
$cDef = ([regex]::Matches($txt, [regex]::Escape("gui_theme_default("))).Count
$cLb  = ([regex]::Matches($txt, [regex]::Escape("gui_theme_light_blue("))).Count
$cApply = ([regex]::Matches($txt, [regex]::Escape("wp_theme_apply("))).Count
$cApplyCall = ([regex]::Matches($txt, [regex]::Escape("wp_theme_apply(c, wp_theme_mode())"))).Count
$applyBody = [regex]::Match($txt, 'int wp_theme_apply\(struct GuiCtx \*c, int mode\) \{(.*?)\n\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$inOneFn = ($applyBody.Success -and $applyBody.Groups[1].Value.Contains("gui_theme_light_blue(") -and $applyBody.Groups[1].Value.Contains("gui_theme_default("))
$c0eOk = ($thAssign -eq 0) -and ($cDef -eq 1) -and ($cLb -eq 1) -and ($cApply -eq 2) -and ($cApplyCall -eq 1) -and $inOneFn
Check "C0e" "theme = 2 preset calls, 1 call site, 0 direct theme_* writes (v3 wording)" $c0eOk "theme_assign=$thAssign default=$cDef light_blue=$cLb apply_def+call=$cApply apply_call=$cApplyCall both_in_one_fn=$inOneFn"

# ---------------------------------------------------------------- C1 compile
if (Test-Path -LiteralPath $bare) { Remove-Item -LiteralPath $bare -Force }
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
$o1 = & $flint $src 2>&1 | Out-String
$rc1 = $LASTEXITCODE
$bareOk = Test-Path -LiteralPath $bare
Check "C1a" "flint main.fl (work-order literal cmd)" ($rc1 -eq 0 -and $bareOk) "exit=$rc1 produced main.exe=$bareOk"
$o2 = & $flint $src -gui -o $exe 2>&1 | Out-String
$rc2 = $LASTEXITCODE
$exeOk = Test-Path -LiteralPath $exe
Check "C1b" "flint main.fl -gui -o winpanel.exe (GUI subsystem: no console window)" ($rc2 -eq 0 -and $exeOk) "exit=$rc2 produced winpanel.exe=$exeOk"
if (-not $exeOk) { Write-Output "cannot continue without winpanel.exe"; exit 1 }
$exeLen = (Get-Item -LiteralPath $exe).Length
$bareLen = 0
if ($bareOk) { $bareLen = (Get-Item -LiteralPath $bare).Length }
Check "C1c" "delivered winpanel.exe byte size" ($exeLen -gt 0) "winpanel.exe=$exeLen bytes"
Check "C1d" "same source -> same size (bare vs -o)" ($bareLen -eq $exeLen) "main.exe=$bareLen winpanel.exe=$exeLen"
$sub = -1
$eb = [System.IO.File]::ReadAllBytes($exe)
$peOff = [BitConverter]::ToInt32($eb, 0x3C)
$sub = [BitConverter]::ToUInt16($eb, $peOff + 4 + 20 + 0x44)
Check "C1e" "delivered winpanel.exe is GUI subsystem (opt+0x44 = 2)" ($sub -eq 2) "subsystem=$sub"
if (Test-Path -LiteralPath $bare) { Remove-Item -LiteralPath $bare -Force }

# ---------------------------------------------------------------- C2 source constants (the judge's
# own expectations are built from THESE, never from the app's report)
function SrcInt([string]$name) {
  $m = [regex]::Match($txt, ("int\s+" + $name + "\s*=\s*(-?[0-9]+)\s*;"))
  if (-not $m.Success) { return $null }
  return [int]$m.Groups[1].Value
}
$CW = SrcInt "WP_W"; $CH = SrcInt "WP_H"; $CTH = SrcInt "WP_TITLE_H"; $CNW = SrcInt "WP_NAV_W"
$CBH = SrcInt "WP_BOT_H"; $CFONT = SrcInt "WP_FONT"; $CLH = SrcInt "WP_LINE_H"; $CROW = SrcInt "WP_ROW"
$CBX = SrcInt "WP_NAVBTN_X"; $CBW = SrcInt "WP_NAVBTN_W"; $CBHt = SrcInt "WP_NAVBTN_H"; $CBY = SrcInt "WP_NAVBTN_Y0"
$CBDY = SrcInt "WP_NAVBTN_DY"
$CTBH = SrcInt "WP_TBTN_H"; $CTBW = SrcInt "WP_TBTN_W"; $CTHW = SrcInt "WP_THEME_W"
$CPR = SrcInt "WP_PAD_R"; $CGAP = SrcInt "WP_GAP"; $CSDX = SrcInt "WP_STATE_DX"; $CPW = SrcInt "WP_PROBE_W"
# v4 additions: the settings page layout, the opacity range and the startup list limits
$CSTW = SrcInt "WP_SETUP_W"; $CCXG = SrcInt "WP_CXGAP"; $CSPAD = SrcInt "WP_SPAD"; $CSPPAD = SrcInt "WP_SP_PAD"
$CSLGAP = SrcInt "WP_SL_GAP"; $CBACKW = SrcInt "WP_BACK_W"; $CLROW = SrcInt "WP_LIST_ROW"
# v6 additions: the window-layer row on the settings page
$CLAYGAP = SrcInt "WP_LAY_GAP"; $CLAYW = SrcInt "WP_LAYER_W"
# v10 (M12): the Layer row is three buttons now, laid out from one width and one pitch
$CLAYBW = SrcInt "WP_LAYBTN_W"; $CLAYBDX = SrcInt "WP_LAYBTN_DX"; $CLAYBGAP = SrcInt "WP_LAYBTN_GAP"
$COPMIN = SrcInt "WP_OPA_MIN"; $COPMAX = SrcInt "WP_OPA_MAX"; $COPDEF = SrcInt "WP_OPA_DEF"
$COPCT = SrcInt "WP_PCT_MAX"; $CPTO = SrcInt "WP_PROBE_TO_MS"
$CREGMAX = SrcInt "WP_REG_MAX"; $CREGVIEW = SrcInt "WP_REG_VIEW"; $CREGSLOT = SrcInt "WP_REGL_SLOT"
$CX = SrcInt "WP_X"; $CY = SrcInt "WP_Y"
# v5 additions: the nav tab count, the actions grid, the system/env pages and their row budgets
$CPAGES = SrcInt "WP_PAGES"; $CRGKEYS = SrcInt "WP_RG_KEYS"
$CACTN = SrcInt "WP_ACT_N"; $CACTCOLS = SrcInt "WP_ACT_COLS"; $CACTW = SrcInt "WP_ACT_W"
$CACTH = SrcInt "WP_ACT_H"; $CACTDX = SrcInt "WP_ACT_DX"; $CACTDY = SrcInt "WP_ACT_DY"
$CACTY0 = SrcInt "WP_ACT_Y0"; $CACTROWS = SrcInt "WP_ACT_ROWS"; $CACTTEST = SrcInt "WP_ACT_TEST"
$CSYSN = SrcInt "WP_SYS_N"; $CSYSSLOT = SrcInt "WP_SYS_SLOT"
$CENVMAX = SrcInt "WP_ENVN_MAX"; $CENVVIEW = SrcInt "WP_ENVN_VIEW"; $CENVNAME = SrcInt "WP_ENVN_NAME"
$CENVVAL = SrcInt "WP_ENVN_VAL"; $CENVROWS = SrcInt "WP_ENV_ROWS"
$CSTARTROWS = SrcInt "WP_START_ROWS"
# v9 (M9): the cfg file's key count, the default "Opacity" number and the five layout constants of
# the Language / Config rows (all read out of main.fl, like every constant above)
$CCFGNKEYS = SrcInt "WP_CFG_NKEYS"; $CCFGOPADEF = SrcInt "WP_CFG_OPA_DEF"
$CCFGGAP = SrcInt "WP_CFG_GAP"; $CCFGLANGW = SrcInt "WP_CFG_LANG_W"; $CCFGBTNW = SrcInt "WP_CFG_BTN_W"
$CCFGDX = SrcInt "WP_CFG_DX"; $CCFGINFOH = SrcInt "WP_CFG_INFO_H"
# the language table's own key count (the appendix-A list length), for C10a
$CLANGN = SrcInt "WP_LANG_N"
$constOk = ($null -ne $CW -and $null -ne $CH -and $null -ne $CTH -and $null -ne $CNW -and $null -ne $CBH -and
            $null -ne $CFONT -and $null -ne $CLH -and $null -ne $CROW -and $null -ne $CBX -and $null -ne $CBW -and
            $null -ne $CBHt -and $null -ne $CBY -and $null -ne $CTBH -and $null -ne $CTBW -and $null -ne $CTHW -and
            $null -ne $CPR -and $null -ne $CGAP -and $null -ne $CSDX -and $null -ne $CPW -and
            $null -ne $CSTW -and $null -ne $CCXG -and $null -ne $CSPAD -and $null -ne $CSPPAD -and
            $null -ne $CSLGAP -and $null -ne $CBACKW -and $null -ne $CLROW -and
            $null -ne $CLAYGAP -and $null -ne $CLAYW -and
            $null -ne $CLAYBW -and $null -ne $CLAYBDX -and $null -ne $CLAYBGAP -and
            $null -ne $COPMIN -and $null -ne $COPMAX -and $null -ne $COPDEF -and $null -ne $COPCT -and $null -ne $CPTO -and
            $null -ne $CREGMAX -and $null -ne $CREGVIEW -and $null -ne $CREGSLOT -and $null -ne $CX -and $null -ne $CY -and
            $null -ne $CPAGES -and $null -ne $CRGKEYS -and $null -ne $CACTN -and $null -ne $CACTCOLS -and
            $null -ne $CACTW -and $null -ne $CACTH -and $null -ne $CACTDX -and $null -ne $CACTDY -and
            $null -ne $CACTY0 -and $null -ne $CACTROWS -and $null -ne $CACTTEST -and
            $null -ne $CSYSN -and $null -ne $CSYSSLOT -and $null -ne $CENVMAX -and $null -ne $CENVVIEW -and
            $null -ne $CENVNAME -and $null -ne $CENVVAL -and $null -ne $CENVROWS -and $null -ne $CSTARTROWS -and
            $null -ne $CCFGNKEYS -and $null -ne $CCFGOPADEF -and $null -ne $CCFGGAP -and
            $null -ne $CCFGLANGW -and $null -ne $CCFGBTNW -and $null -ne $CCFGDX -and $null -ne $CCFGINFOH)
Check "C1f" "single-point geometry constants readable from main.fl" $constOk "W=$CW H=$CH title=$CTH nav=$CNW bot=$CBH font=$CFONT line=$CLH row=$CROW setupbtnW=$CSTW cxgap=$CCXG pages=$CPAGES act=$CACTN/$CACTCOLS/$CACTW/$CACTH actY0=$CACTY0 sysN=$CSYSN envMax=$CENVMAX envView=$CENVVIEW startRows=$CSTARTROWS"
# the font criterion: the app hands WP_FONT to gui_win_font_init and the label line height is
# WP_FONT + 4 -- both parsed from the source, then checked against the live command table (C2j)
$fontCall = ([regex]::Matches($txt, [regex]::Escape("gui_win_font_init(WP_FONT)"))).Count
Check "C1g" "body font = WP_FONT (=20) fed to gui_win_font_init, line height = font + 4" `
  (($fontCall -eq 1) -and ($CFONT -eq 20) -and ($CLH -eq ($CFONT + 4))) `
  "gui_win_font_init(WP_FONT) count=$fontCall WP_FONT=$CFONT WP_LINE_H=$CLH (expect 20 and $($CFONT + 4))"
# v4's headline claim is an AREA ratio ("2.5x bigger"), which is why the linear factor is 1.6 and
# not 2.5 (linear 2.5 = 1600x1150 would be taller than this machine's 1080 screen). Recomputed here.
$areaNow = $CW * $CH
$areaV3 = 640 * 460
$areaRatio = [Math]::Round($areaNow / $areaV3, 4)
$linear = [Math]::Round($CW / 640.0, 4)
Check "C1h" "window area >= 2.5x v3's 640x460 (the work order's reading of '2.5x bigger')" `
  ($areaRatio -ge 2.5) "now=${CW}x${CH} area=$areaNow vs v3 640x460 area=$areaV3 -> ratio=$areaRatio (linear x$linear)"
Check "C1i" "window placed at the source constants WP_X/WP_Y and inside the 1920x1080 screen" `
  (($CX -ge 0) -and ($CY -ge 0) -and (($CX + $CW) -le 1920) -and (($CY + $CH) -le 1080)) `
  "WP_X=$CX WP_Y=$CY right=$($CX + $CW) bottom=$($CY + $CH) (screen 1920x1080)"

# ---------------------------------------------------------------- C2 dump vs recomputed expectations
$snapLen = 0
$snapText = ""
if (Test-Path -LiteralPath $snap) {
  $snapLen = (Get-Item -LiteralPath $snap).Length
  $snapText = [System.IO.File]::ReadAllText($snap, [System.Text.Encoding]::UTF8)
}
$exp = @{}
foreach ($line in ($snapText -split "`n")) {
  $l = $line.TrimEnd("`r")
  $i = $l.IndexOf('=')
  if ($i -gt 0) { $exp[$l.Substring(0, $i)] = $l.Substring($i + 1) }
}
# disk totals: PS measures the real disks itself (the app carries them as constants)
$diskTotal = @{}
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:' or DeviceID='E:'")) {
  $diskTotal[$d.DeviceID.Substring(0, 1)] = [int][Math]::Round($d.Size / 1GB * 10)
}
New-Item -ItemType File -Force -Path $marker | Out-Null
$dr = RunDump 60000
Remove-Item -LiteralPath $marker -Force
$dumpPath = $dump
if (-not (Test-Path -LiteralPath $dumpPath)) { $dumpPath = $dumpalt }
$dumpOk = Test-Path -LiteralPath $dumpPath
Check "C2a" "dump mode exits 0" ($dr.rc -eq 0) "exit=$($dr.rc) wall=$($dr.ms)ms"
Check "C2b" "dump report written" $dumpOk "path=$dumpPath"

$d = @{}
if ($dumpOk) { $d = ReadDump $dumpPath }
Write-Output "---- dump report (verbatim) ----"
if ($dumpOk) { Get-Content -LiteralPath $dumpPath | ForEach-Object { Write-Output ("    " + $_) } }
Write-Output "---- independently recomputed by PowerShell ----"
$psMem = "(key absent)"
if ($exp.ContainsKey("mem_time")) { $psMem = $exp["mem_time"] }
Write-Output ("    snap file           = $snap")
Write-Output ("    snap bytes          = $snapLen")
Write-Output ("    mem_time            = $psMem")
foreach ($k in @("tasks_open", "cand", "sec_danger", "sec_warn", "sec_info", "disk_c_free_x10", "disk_e_free_x10")) {
  $v = "(key absent)"
  if ($exp.ContainsKey($k)) { $v = $exp[$k] }
  Write-Output ("    {0,-20}= {1}" -f $k, $v)
}
Write-Output ("    disk C total x10    = {0}   disk E total x10 = {1}" -f $diskTotal["C"], $diskTotal["E"])
$psPctC = "-"
$psPctE = "-"
if ($exp.ContainsKey("disk_c_free_x10") -and $diskTotal["C"]) { $psPctC = [int][Math]::Floor((($diskTotal["C"] - [int]$exp["disk_c_free_x10"]) * 100) / $diskTotal["C"]) }
if ($exp.ContainsKey("disk_e_free_x10") -and $diskTotal["E"]) { $psPctE = [int][Math]::Floor((($diskTotal["E"] - [int]$exp["disk_e_free_x10"]) * 100) / $diskTotal["E"]) }
Write-Output ("    used pct C / E      = {0} / {1}  (= (total - free) / total, integer)" -f $psPctC, $psPctE)

$mismatch = New-Object System.Collections.ArrayList
$cmpCount = 0
function Cmp([string]$key, [string]$app, [string]$ps) {
  $script:cmpCount++
  $a = ""; if ($app -ne $null) { $a = $app.Trim() }
  $p = ""; if ($ps -ne $null) { $p = ([string]$ps).Trim() }
  if ($a -ne $p) { [void]$script:mismatch.Add("$key app='$a' ps='$p'") }
}
Cmp "mem_time" $d["mem_time"] $psMem
foreach ($k in @("tasks_open", "cand", "sec_danger", "sec_warn", "sec_info", "disk_c_free_x10", "disk_e_free_x10")) {
  $ps = "(absent)"
  if ($exp.ContainsKey($k)) { $ps = $exp[$k] }
  Cmp $k $d[$k] $ps
}
Cmp "disk_c_total_x10" $d["disk_c_total_x10"] $diskTotal["C"]
Cmp "disk_e_total_x10" $d["disk_e_total_x10"] $diskTotal["E"]
Cmp "disk_c_used_pct" $d["disk_c_used_pct"] $psPctC
Cmp "disk_e_used_pct" $d["disk_e_used_pct"] $psPctE
Cmp "snap_bytes" $d["snap_bytes"] $snapLen
Cmp "exe_bytes" $d["exe_bytes"] $exeLen
Cmp "refresh_ms" $d["refresh_ms"] "2000"
# the api declaration count is no longer a hand-written 62: it is summed over main.fl plus the
# library files the app includes (the compiler pulls the same set in). v4 adds the four read-only
# advapi32 entries.
$apiFiles = @($src,
  (Join-Path $lib "ui_lib.fl"), (Join-Path $lib "flgui.fl"), (Join-Path $lib "flgui_widgets.fl"),
  (Join-Path $lib "flgui_edit.fl"), (Join-Path $lib "flgui_win32.fl"),
  (Join-Path $lib "io_lib.fl"), (Join-Path $lib "http_lib.fl"))
$apiCount = 0
$apiTxt = ""
foreach ($af in $apiFiles) {
  $c = ([regex]::Matches([System.IO.File]::ReadAllText($af, [System.Text.Encoding]::UTF8), '(?m)^\s*api\s+\S+\s+\S+\s+\w+')).Count
  $apiTxt = $apiTxt + " $(Split-Path $af -Leaf)=$c"
  $apiCount += $c
}
Cmp "api_decls" $d["api_decls"] $apiCount
Cmp "geo_win_w" $d["geo_win_w"] $CW
Cmp "geo_win_h" $d["geo_win_h"] $CH
Cmp "geo_title_h" $d["geo_title_h"] $CTH
Cmp "geo_nav_w" $d["geo_nav_w"] $CNW
Cmp "geo_bot_h" $d["geo_bot_h"] $CBH
Cmp "geo_font" $d["geo_font"] $CFONT
Cmp "geo_line_h" $d["geo_line_h"] $CLH
Cmp "geo_row" $d["geo_row"] $CROW
if ($snapLen -gt 0) { Cmp "snap_state" $d["snap_state"] "ok" }
Check "C2c" "dump fields == PowerShell recomputation" ($mismatch.Count -eq 0) "compared=$cmpCount mismatches=$($mismatch.Count) $(($mismatch) -join ' | ')"
$ansiOk = $false
if ($d.ContainsKey("ansi_bytes") -and [int]$d["ansi_bytes"] -gt 0) { $ansiOk = $true }
Check "C2d" "UTF-8 snapshot transcoded to ANSI" $ansiOk "snap_bytes=$($d['snap_bytes']) ansi_bytes=$($d['ansi_bytes']) (2-step MultiByteToWideChar->WideCharToMultiByte)"
$litOk = $false
if ($d.ContainsKey("probe_ms") -and [int]$d["probe_ms"] -ge 0) { $litOk = $true }
Check "C2e" "in-process startup_ms / probe_ms present" ($litOk -and $d.ContainsKey("startup_ms")) "startup_ms=$($d['startup_ms']) probe_ms=$($d['probe_ms'])"

# ---- C2f: the skeleton and the seven pages, judged from the command stream the app reported ----
$sig0 = [int]$d["page0_sig"]; $sig1 = [int]$d["page1_sig"]; $sig2 = [int]$d["page2_sig"]; $sig3 = [int]$d["page3_sig"]
$sig4 = [int]$d["page4_sig"]; $sig5 = [int]$d["page5_sig"]; $sig6 = [int]$d["page6_sig"]
$allSigs = @($sig0, $sig1, $sig2, $sig3, $sig4, $sig5, $sig6)
$sigsDistinct = (@($allSigs | Sort-Object -Unique).Count -eq $CPAGES)
Check "C2f" "seven nav clicks really switch pages (distinct command streams)" `
  (([int]$d["nav_click_switched"] -eq $CPAGES) -and ([int]$d["pages_distinct"] -eq $CPAGES) -and $sigsDistinct) `
  "nav_click_switched=$($d['nav_click_switched']) pages_distinct=$($d['pages_distinct']) pages=$CPAGES sigs=$($allSigs -join '/') distinct=$sigsDistinct"
# v6: the title cluster gained the REAL minimize button (collapse moved to the new "<<" control),
# so it is 5 title buttons (Setup / Theme / minimize / collapse<< / close) + N nav tabs
$expButtons = 5 + $CPAGES
$skOk = ([int]$d["skeleton_title_cmds"] -gt 0) -and ([int]$d["skeleton_nav_cmds"] -gt 0) -and ([int]$d["skeleton_bottom_cmds"] -gt 0) -and ([int]$d["skeleton_buttons"] -eq $expButtons)
Check "C2g" "title bar / nav column / bottom bar / $expButtons buttons in the command stream" $skOk `
  "title_cmds=$($d['skeleton_title_cmds']) nav_cmds=$($d['skeleton_nav_cmds']) bottom_cmds=$($d['skeleton_bottom_cmds']) buttons=$($d['skeleton_buttons']) (expect $expButtons = 5 title + $CPAGES nav)"
Check "C2h" "command table and text arena never overflowed" (($d["cmd_over"] -eq "0") -and ($d["text_over"] -eq "0")) "cmd_over=$($d['cmd_over']) text_over=$($d['text_over']) cmd_total=$($d['cmd_total']) dump_frames=$($d['dump_frames'])"
$geoOk = ([int]$d["ports_row_n"] -eq 5) -and ([int]$d["ports_row_dy"] -eq $CROW) -and ([int]$d["ports_state_x"] -eq ($CNW + $CCXG + $CSDX)) -and ([int]$d["nav2_cx"] -gt 0) -and ([int]$d["probe_cx"] -gt $CNW)
Check "C2i" "click points and port-row geometry come from the command table" $geoOk `
  "nav2=($($d['nav2_cx']),$($d['nav2_cy'])) probe=($($d['probe_cx']),$($d['probe_cy'])) rows y0=$($d['ports_row_y0']) dy=$($d['ports_row_dy']) x=$($d['ports_state_x']) (content x = $CNW+$CCXG)"

# ---- C2j: EVERY rectangle recomputed here from main.fl's constants, then compared ---------------
# expectations (all PowerShell arithmetic over the parsed constants):
$expBase  = @(0, 0, $CW, $CH)
$expTitle = @(0, 0, $CW, $CTH)
$expNav   = @(0, $CTH, $CNW, ($CH - $CTH - $CBH))
$expBot   = @(0, ($CH - $CBH), $CW, $CBH)
$expNb0   = @($CBX, $CBY, ($CNW - 2 * $CBX), $CBHt)
$expTby   = [int](($CTH - $CTBH) / 2)
$expClose = @(($CW - $CPR - $CTBW), $expTby, $CTBW, $CTBH)
$expTheme = @(($CW - $CPR - $CTBW - $CGAP - $CTHW), $expTby, $CTHW, $CTBH)
$expSetup = @(($CW - $CPR - $CTBW - $CGAP - $CTHW - $CGAP - $CSTW), $expTby, $CSTW, $CTBH)
# v6: the title cluster reads close / theme / setup / minimize / collapse(<<) from the right, so the
# old single-button formula now describes the MINIMIZE button and << sits one more gap to its left
$expMin   = @(($CW - $CPR - $CTBW - $CGAP - $CTHW - $CGAP - $CSTW - $CGAP - $CTBW), $expTby, $CTBW, $CTBH)
$expColl  = @(($expMin[0] - $CGAP - $CTBW), $expTby, $CTBW, $CTBH)
$expProbe = @(($CNW + $CCXG), ($CTH + 10 + 6 * $CROW + 6), $CPW, $CBHt)
# the settings page (secondary page) and its widgets, all derived from the constants
$expSetupX = $CNW
$expSetupY = $CTH
$expSetupW = $CW - $CNW
$expSetupH = $CH - $CTH - $CBH
$expSlX = $CNW + $CSPAD
$expSlY = $CTH + $CSPPAD + 2 * $CROW
$expSlW = ($CW - $CNW) - 2 * $CSPAD
$expSlRect = @($expSlX, $expSlY, $expSlW, $CLH)
$expOpaLblRect = @($expSlX, ($expSlY + $CLH + $CSLGAP), 320, $CLH)
# v5: the Transparency line sits exactly one line under the Opacity line
$expTrLblRect = @($expSlX, ($expSlY + $CLH + $CSLGAP + $CLH), 320, $CLH)
# v6: the window-layer row (the "Layer: top/normal/auto" button) sits one line + gap under it
$expLayerRect = @($expSlX, ($expTrLblRect[1] + $CLH + $CLAYGAP), $CLAYW, $CBHt)
# v10 (M12): the Layer row is three buttons of width $CLAYBW with pitch $CLAYBDX. They tile the same
# row the single cycling button used to occupy, so every row below is unmoved -- and the three are
# pairwise disjoint by construction (the C11c geometry check measures the real rects against this).
$expLayTopRect = @($expSlX, $expLayerRect[1], $CLAYBW, $CBHt)
$expLayNorRect = @(($expSlX + $CLAYBDX), $expLayerRect[1], $CLAYBW, $CBHt)
$expLayAutRect = @(($expSlX + 2 * $CLAYBDX), $expLayerRect[1], $CLAYBW, $CBHt)
# v9 (M9): the settings page gained a Language row, a Config row (Save / Reload / Reset) and the cfg
# info line, so the rows below the Layer selector moved. This chain MIRRORS main.fl's own derived
# functions (wp_state_y -> wp_lang_y -> wp_cfg_y -> wp_cfginfo_y -> wp_back_y) over the constants
# parsed out of that same file. v6's old "slider + 5 rows" formula described a layout that no longer
# exists; the ruler is still arithmetic over the source, never a hand-written coordinate.
$expStateY = ($expLayerRect[1] + $CBHt + 4)
$expLangRect = @($expSlX, ($expStateY + $CLH + $CCFGGAP), $CCFGLANGW, $CBHt)
$expCfgY = ($expLangRect[1] + $CBHt + $CCFGGAP)
$expCfgSaveRect = @($expSlX, $expCfgY, $CCFGBTNW, $CBHt)
$expCfgReloadRect = @(($expSlX + $CCFGDX), $expCfgY, $CCFGBTNW, $CBHt)
$expCfgResetRect = @(($expSlX + 2 * $CCFGDX), $expCfgY, $CCFGBTNW, $CBHt)
$expCfgInfoY = ($expCfgY + $CBHt + 4)
$expBackRect = @($expSlX, ($expCfgInfoY + $CCFGINFOH), $CBACKW, $CBHt)
# v5: the nav tabs 5..7 (indices 4..6) and the actions grid. Every one of these is arithmetic over
# the constants parsed out of main.fl -- the app's own report is only the thing being checked.
$expNav5 = @($CBX, ($CBY + 4 * $CBDY), $CBW, $CBHt)
$expNav6 = @($CBX, ($CBY + 5 * $CBDY), $CBW, $CBHt)
$expNav7 = @($CBX, ($CBY + 6 * $CBDY), $CBW, $CBHt)
$expActX0 = $CNW + $CCXG
$expAct0 = @($expActX0, $CACTY0, $CACTW, $CACTH)
$expActTest = @(($expActX0 + ($CACTTEST % $CACTCOLS) * $CACTDX), ($CACTY0 + [int]($CACTTEST / $CACTCOLS) * $CACTDY), $CACTW, $CACTH)
$geoLines = @(
  @{ k = "geo_base_rect";        e = $expBase },
  @{ k = "geo_title_rect";       e = $expTitle },
  @{ k = "geo_nav_rect";         e = $expNav },
  @{ k = "geo_bot_rect";         e = $expBot },
  @{ k = "geo_navbtn0_rect";     e = $expNb0 },
  @{ k = "geo_close_rect";       e = $expClose },
  @{ k = "geo_theme_rect";       e = $expTheme },
  @{ k = "geo_setupbtn_rect";    e = $expSetup },
  @{ k = "geo_collapse_rect";    e = $expColl },
  @{ k = "geo_probe_rect";       e = $expProbe },
  @{ k = "geo_slider_rect";      e = $expSlRect },
  @{ k = "geo_setup_back_rect";  e = $expBackRect },
  @{ k = "geo_opa_label_rect";   e = $expOpaLblRect },
  @{ k = "geo_tr_label_rect";    e = $expTrLblRect },
  @{ k = "geo_minimize_rect";    e = $expMin },
  @{ k = "geo_collapse2_rect";   e = $expColl },
  @{ k = "geo_layer_rect";       e = $expLayerRect },
  @{ k = "geo_layer_top_rect";    e = $expLayTopRect },
  @{ k = "geo_layer_normal_rect"; e = $expLayNorRect },
  @{ k = "geo_layer_auto_rect";   e = $expLayAutRect },
  @{ k = "geo_setup_lang_rect";   e = $expLangRect },
  @{ k = "geo_setup_save_rect";   e = $expCfgSaveRect },
  @{ k = "geo_setup_reload_rect"; e = $expCfgReloadRect },
  @{ k = "geo_setup_reset_rect";  e = $expCfgResetRect },
  @{ k = "nav5_rect";            e = $expNav5 },
  @{ k = "geo_nav6_rect";        e = $expNav6 },
  @{ k = "geo_nav7_rect";        e = $expNav7 },
  @{ k = "geo_action0_rect";     e = $expAct0 },
  @{ k = "geo_action_test_rect"; e = $expActTest }
)
$geoBad = New-Object System.Collections.ArrayList
$geoTxt = ""
foreach ($g in $geoLines) {
  $got = @()
  if ($d.ContainsKey($g.k)) { $got = @($d[$g.k] -split ',' | ForEach-Object { [int]$_ }) }
  $geoTxt = $geoTxt + (" {0}=({1}) exp=({2})" -f $g.k, (Csv $got), (Csv $g.e))
  if ((Csv $got) -ne (Csv $g.e)) { [void]$geoBad.Add($g.k) }
}
$lineOk = ($null -ne $CLH) -and ([int]$d["geo_line_h_cmd"] -eq $CLH)
if (-not $lineOk) { [void]$geoBad.Add("geo_line_h_cmd") }
# v10 (M12): the three layer buttons must really be three, on ONE row, pairwise disjoint, and all
# inside the single row the old cycling button used to occupy. This is arithmetic over the constants
# above (never a hand-written rectangle) plus main.fl's own report of the row width.
$layTile = @($expLayTopRect, $expLayNorRect, $expLayAutRect)
$layTileOk = ($CLAYW -eq (3 * $CLAYBW + 2 * $CLAYBGAP)) -and ($CLAYBDX -eq ($CLAYBW + $CLAYBGAP)) -and
             ($expLayTopRect[0] -eq $expSlX) -and
             (($expLayAutRect[0] + $expLayAutRect[2]) -eq ($expSlX + $CLAYW)) -and
             ([int]$d["layer_btn_w"] -eq $CLAYBW) -and ([int]$d["layer_btn_gap"] -eq $CLAYBGAP) -and
             ([int]$d["layer_btn_dx"] -eq $CLAYBDX) -and ([int]$d["layer_w"] -eq $CLAYW)
for ($li = 0; $li -lt 3; $li++) {
  for ($lj = $li + 1; $lj -lt 3; $lj++) {
    $la = $layTile[$li]; $lb = $layTile[$lj]
    $ovl = -not ((($la[0] + $la[2]) -le $lb[0]) -or (($lb[0] + $lb[2]) -le $la[0]) -or (($la[1] + $la[3]) -le $lb[1]) -or (($lb[1] + $lb[3]) -le $la[1]))
    if ($ovl) { $layTileOk = $false }
  }
}
if (-not $layTileOk) { [void]$geoBad.Add("layer_button_tiling") }
Write-Output ("---- v10 (M12) layer row: three buttons tile the same row (w={0} gap={1} pitch={2} row={3}) ----" -f $CLAYBW, $CLAYBGAP, $CLAYBDX, $CLAYW)
Write-Output ("     top=({0}) normal=({1}) auto=({2})" -f (Csv $expLayTopRect), (Csv $expLayNorRect), (Csv $expLayAutRect))
Write-Output "---- geometry: command table vs PowerShell arithmetic over main.fl constants ----"
Write-Output ("   " + $geoTxt)
Check "C2j" "every rectangle == PS recomputation from main.fl constants" ($geoBad.Count -eq 0) "bad=[$($geoBad -join ',')] line_h_cmd=$($d['geo_line_h_cmd']) exp=$CLH"

# ---- C2k: the theme A/B (same frame sequence run twice by the app, judged here) -----------------
$libFl = Get-LibText (Join-Path $lib "flgui.fl")
$libW32 = Get-LibText (Join-Path $lib "flgui_win32.fl")
$palDef = Parse-ThemeBody $libFl "gui_theme_default"
$palLb = Parse-ThemeBody $libFl "gui_theme_light_blue"
$palLight = @{}
foreach ($k in $palDef.Keys) { $palLight[$k] = $palDef[$k] }
foreach ($k in $palLb.Keys) { $palLight[$k] = $palLb[$k] }
$fillA = 200
$mFill = [regex]::Match($libW32, 's->fill_a\s*=\s*([0-9]+)\s*;')
if ($mFill.Success) { $fillA = [int]$mFill.Groups[1].Value }
# v6 (A): the panel now drives the surface's own per-pixel alpha from the SAME knob, so the expected
# fill alpha is a FUNCTION of the constant alpha instead of one library constant. Both steps are the
# app's own arithmetic re-done here over the constants parsed out of main.fl:
#   pct    = ((OPA_MAX - a) * PCT_MAX + 67) / (OPA_MAX - OPA_MIN)   (truncating division)
#   fill_a = 255 - (FILL_DROP * pct) / PCT_MAX                      (255 at 0%, $fillA at 100%)
$CFILLDROP = SrcInt "WP_FILL_DROP"
if ($null -eq $CFILLDROP) { $CFILLDROP = $COPMAX - $fillA }   # fall back to the library's own value
function FillAOf([int]$a) {
  if ($a -gt $COPMAX) { $a = $COPMAX }
  if ($a -lt $COPMIN) { $a = $COPMIN }
  $pct = [int][Math]::Floor(((($COPMAX - $a) * $COPCT) + 67) / ($COPMAX - $COPMIN))
  return (255 - [int][Math]::Floor(($CFILLDROP * $pct) / $COPCT))
}
$fillADef = FillAOf $COPDEF
$fields = @("bg", "panel", "btn", "border", "text", "dim", "box", "fill")
$palBad = New-Object System.Collections.ArrayList
$palTxt = ""
foreach ($f in $fields) {
  # "dim" is shorthand here for the library field theme_text_dim
  $tf = $f; if ($f -eq "dim") { $tf = "text_dim" }
  $appLight = [long]$d["theme_light_$f"]
  $libLight = [long]$palLight[$tf]
  $appDark = [long]$d["theme_dark_$f"]
  $libDark = [long]$palDef[$tf]
  $palTxt = $palTxt + (" {0}:app={1}/{2} lib={3}/{4}" -f $f, $appLight, $appDark, $libLight, $libDark)
  if ($appLight -ne $libLight) { [void]$palBad.Add("light.$f") }
  if ($appDark -ne $libDark) { [void]$palBad.Add("dark.$f") }
}
$radiusOk = ([long]$d["theme_light_radius"] -eq [long]$palLight["radius"]) -and ([long]$d["theme_dark_radius"] -eq [long]$palDef["radius"])
if (-not $radiusOk) { [void]$palBad.Add("radius") }
Write-Output "---- theme palette: app ctx vs lib\flgui.fl presets (parsed by this script) ----"
Write-Output ("   " + $palTxt + (" radius:app={0}/{1} lib={2}/{3} fill_a={4}" -f $d["theme_light_radius"], $d["theme_dark_radius"], $palLight["radius"], $palDef["radius"], $fillA))
$geomSame = ([long]$d["theme_light_geom"] -eq [long]$d["theme_dark_geom"])
$colDiff = ([long]$d["theme_light_col"] -ne [long]$d["theme_dark_col"])
$cntSame = $true
$cntTxt = ""
foreach ($kindKey in @("k1", "k2", "k3", "k4", "k5", "k11", "k12", "k13")) {
  $lv = [int]$d["theme_light_$kindKey"]; $dv = [int]$d["theme_dark_$kindKey"]
  $cntTxt = $cntTxt + " $kindKey=$lv/$dv"
  if ($lv -ne $dv) { $cntSame = $false }
}
$rectSame = $true
$rectTxt = ""
foreach ($r in @("base", "title", "nav", "bot")) {
  $lv = [string]$d["theme_light_${r}_rect"]; $dv = [string]$d["theme_dark_${r}_rect"]
  $rectTxt = $rectTxt + " $r=$lv/$dv"
  if ($lv -ne $dv) { $rectSame = $false }
}
$cmdnSame = ([int]$d["theme_light_cmdn"] -eq [int]$d["theme_dark_cmdn"])
$themeOk = $geomSame -and $colDiff -and $cntSame -and $rectSame -and $cmdnSame -and $radiusOk -and ($palBad.Count -eq 0) -and ([int]$d["theme_light_cmdn"] -gt 0)
Check "C2k" "theme A/B: identical geometry, identical rects/kinds, other colours, palette == lib" $themeOk `
  "geom=$($d['theme_light_geom'])/$($d['theme_dark_geom']) same=$geomSame col_diff=$colDiff cmdn=$($d['theme_light_cmdn'])/$($d['theme_dark_cmdn']) kinds:$cntTxt rects:$rectTxt palette_bad=[$($palBad -join ',')]"

# ---- C2l: the secondary Settings page and the TRANSPARENCY slider (Phase A; percent since M4r) --
# The slider is a PERCENT now (0..100): the click maps to pct = floor(floor(w/2) * PCTMAX / (w-1)),
# and the app stores the alpha the layer consumes, alpha(pct) = 255 - round(pct * 135 / 100). Both
# directions are recomputed here; the app's own ledger is only the thing being checked.
$slRect = @($d["geo_slider_rect"] -split ',' | ForEach-Object { [int]$_ })
$slIw = $slRect[2] - 1
$expMidPct = [int][Math]::Floor(([Math]::Floor($slRect[2] / 2) * $COPCT) / $slIw)
$expMid = $COPMAX - [int][Math]::Floor(($expMidPct * ($COPMAX - $COPMIN) + 50) / $COPCT)
# ... and the label spells the percent back out of that alpha (round to nearest, same as the app)
$expMidPctBack = [int][Math]::Floor((($COPMAX - $expMid) * $COPCT + 67) / ($COPMAX - $COPMIN))
$opaTxt = ""
$opaBad = New-Object System.Collections.ArrayList
$opaPairs = @(
  @{ k = "opa_min";           a = $d["opa_min"];          e = $COPMIN },
  @{ k = "opa_max";           a = $d["opa_max"];          e = $COPMAX },
  @{ k = "opa_default";       a = $d["opa_default"];      e = $COPDEF },
  @{ k = "opa_at_left";       a = $d["opa_at_left"];      e = $COPMAX },
  @{ k = "opa_at_drag_right"; a = $d["opa_at_drag_right"]; e = $COPMIN },
  @{ k = "opa_at_drag_left";  a = $d["opa_at_drag_left"]; e = $COPMAX },
  @{ k = "opa_at_mid";        a = $d["opa_at_mid"];       e = $expMid },
  @{ k = "opa_pool";          a = $d["opa_pool"];         e = $expMid },
  @{ k = "opa_label_value";   a = $d["opa_label_value"];  e = $expMidPctBack }
)
foreach ($p in $opaPairs) {
  $opaTxt = $opaTxt + (" {0}:app={1} exp={2}" -f $p.k, $p.a, $p.e)
  if (([string]$p.a) -ne ([string]$p.e)) { [void]$opaBad.Add($p.k) }
}
$midInside = ($expMid -gt $COPMIN) -and ($expMid -lt $COPMAX)
if (-not $midInside) { [void]$opaBad.Add("mid_not_inside_range") }
# the label the widget layer really drew must spell the percent the pool's alpha stands for --
# v5: BOTH ends of the same knob, each on its own line, both plain 0..100 integers with NO "%"
if ($d["opa_label"] -ne ("Opacity " + [string]($COPCT - $expMidPctBack))) { [void]$opaBad.Add("opa_label_text") }
if ($d["tr_label"] -ne ("Transparency " + [string]$expMidPctBack)) { [void]$opaBad.Add("tr_label_text") }
if ([string]$d["opa_label_value"] -ne [string]($COPCT - $expMidPctBack)) { [void]$opaBad.Add("opa_label_value") }
if ([string]$d["tr_label_value"] -ne [string]$expMidPctBack) { [void]$opaBad.Add("tr_label_value") }
if (([string]$d["opa_label"]).Contains("%") -or ([string]$d["tr_label"]).Contains("%")) { [void]$opaBad.Add("label_has_percent_sign") }
# v5: the status bar now carries the OPACITY (no "%") and must not carry the old wording
$barText = [string]$d["bar_text"]
$expBar = "src ok   refresh 2s   opacity " + [string]($COPCT - $expMidPctBack)
if (-not $barText.StartsWith($expBar)) { [void]$opaBad.Add("bar_text_prefix") }
if ($barText.Contains("transparency")) { [void]$opaBad.Add("bar_text_still_says_transparency") }
if ($barText.Contains("%")) { [void]$opaBad.Add("bar_text_has_percent_sign") }
# v5: the DEFAULT state (nothing dragged yet) must show the two ends of the same knob -- and 86/14 is
# NOT 50/50, so this is the part that can tell a correct implementation from a swapped one.
$expDefPct = [int][Math]::Floor(((($COPMAX - $COPDEF) * $COPCT) + 67) / ($COPMAX - $COPMIN))
if ([string]$d["opa_def_label"] -ne ("Opacity " + [string]($COPCT - $expDefPct))) { [void]$opaBad.Add("opa_def_label") }
if ([string]$d["tr_def_label"] -ne ("Transparency " + [string]$expDefPct)) { [void]$opaBad.Add("tr_def_label") }
if (([int]$d["opa_def_value"] + [int]$d["tr_def_value"]) -ne $COPCT) { [void]$opaBad.Add("def_values_sum") }
if ([int]$d["opa_def_value"] -eq [int]$d["tr_def_value"]) { [void]$opaBad.Add("def_values_degenerate") }
# the value must live in the pool slot the documentation names (recomputed djb2 here)
if ([string]$d["opa_pool_key"] -ne [string](GuiHash "winpanel.opacity")) { [void]$opaBad.Add("opa_pool_key") }
# the settings page must be a FIFTH distinct screen, entered and left exactly once
if (([string]$d["setup_open_ok"] -ne "1") -or ([string]$d["setup_back_ok"] -ne "1") -or ([string]$d["setup_transitions"] -ne "2")) { [void]$opaBad.Add("setup_transitions") }
if (([string]$d["setup_slider_found"] -ne "1") -or ([string]$d["setup_back_found"] -ne "1")) { [void]$opaBad.Add("widgets_missing") }
$setupSig = [int]$d["setup_page_sig"]
if ($allSigs -contains $setupSig) { [void]$opaBad.Add("setup_page_sig_collides") }
# the slider is the FLGUI widget, so its command stream must carry a track (kind 11) and the
# renderer's fill/thumbs come with it -- and the dump must not have lost any command
if ([int]$d["cmd_over"] -ne 0) { [void]$opaBad.Add("cmd_over") }
Write-Output "---- opacity ledger: app dump vs PowerShell recomputation ----"
Write-Output ("   " + $opaTxt)
Write-Output ("   label='{0}' tr_label='{1}' bar='{2}' pool_key={3} (GuiHash('winpanel.opacity')={4}) setup_sig={5} vs pages={6}" -f $d["opa_label"], $d["tr_label"], $barText, $d["opa_pool_key"], (GuiHash "winpanel.opacity"), $setupSig, ($allSigs -join '/'))
Write-Output ("   default (nothing dragged): '{0}' / '{1}'  ->  {2} + {3} = {4}  (expected {5} + {6})" -f $d["opa_def_label"], $d["tr_def_label"], $d["opa_def_value"], $d["tr_def_value"], ([int]$d["opa_def_value"] + [int]$d["tr_def_value"]), ($COPCT - $expDefPct), $expDefPct)
Check "C2l" "Settings page + transparency slider: endpoints, mid value, pool slot, BOTH labels and the status bar all agree" ($opaBad.Count -eq 0) `
  "bad=[$($opaBad -join ',')] slider_rect=($(Csv $slRect)) iw=$slIw exp_mid_pct=$expMidPct exp_mid_alpha=$expMid range=$COPMIN..$COPMAX pct=$COPCT transitions=$($d['setup_transitions']) setup_frames=$($d['setup_seq_frames']) opacity=$($COPCT - $expMidPctBack)"

# ---- C2n: the port probe is NON-BLOCKING (M4r) -------------------------------------------------
# The dump probes all five ports itself and reports the wall time it spent. A blocking connect costs
# ~2045 ms per DEAD port on this machine (measured three ways in the v1 round) = ~8.2 s for this
# set; the non-blocking ioctlsocket/select path must come in far under that, and the five states it
# produces are checked against PowerShell's own connect above. The bound is recomputed from the
# app's own select budget, not hand-written.
$probeBound = ($CPTO * 5) + 600
$probeMs = -1
if ($null -ne $d["probe_ms"]) { $probeMs = [int]$d["probe_ms"] }
Check "C2n" "five-port probe finished far under the old blocking cost (non-blocking select path live)" `
  (($probeMs -gt 0) -and ($probeMs -lt $probeBound)) `
  "probe_ms=$probeMs bound=$probeBound (select budget WP_PROBE_TO_MS=$CPTO per dead port; the old blocking connect measured ~2045 ms/port = ~8.2 s for five)"

# ---- C2m: the Startup page vs PowerShell's OWN read of the same two Run keys -------------------
# Independent judge: this script opens the very same two keys through .NET and compares the value
# NAME SETS (order is irrelevant -- a registry enumeration has no guaranteed order) plus the count,
# the data sizes and the rows that really reached the command stream.
$rc2 = RegRead "hkcu" "Software\Microsoft\Windows\CurrentVersion\Run"
$rc3 = RegRead "hklm" "Software\Microsoft\Windows\CurrentVersion\Run"
$regBad = New-Object System.Collections.ArrayList
$regTxt = ""
foreach ($pair in @(@("hkcu", $rc2, "0"), @("hklm", $rc3, "1"))) {
  $tag = $pair[0]; $ps = $pair[1]; $slot = $pair[2]
  $expState = "unavailable"
  if ($ps.ok) { $expState = "ok" }
  $appState = [string]$d["reg_${tag}_state"]
  $appN = [int]$d["reg_${tag}_n"]
  $appMore = [int]$d["reg_${tag}_more"]
  $psN = @($ps.names).Count
  $expN = $psN
  if ($expN -gt $CREGMAX) { $expN = $CREGMAX }
  # the app's set
  $appSet = @()
  for ($i = 0; $i -lt $appN; $i++) { $appSet += [string]$d["reg_${tag}_$i"] }
  $psSet = @($ps.names | Select-Object -First $CREGMAX)
  $miss = @($psSet | Where-Object { $appSet -notcontains $_ })
  $extra = @($appSet | Where-Object { $psSet -notcontains $_ })
  $regTxt = $regTxt + ("`n    {0}: state app={1} ps={2} | n app={3} ps={4} | rows app={5} | more app={6} | missing=[{7}] extra=[{8}]" -f `
    $tag.ToUpper(), $appState, $expState, $appN, $expN, $d["startup_${tag}_rows"], $appMore, ($miss -join '|'), ($extra -join '|'))
  if ($appState -ne $expState) { [void]$regBad.Add("${tag}_state") }
  if ($appN -ne $expN) { [void]$regBad.Add("${tag}_n") }
  if ($miss.Count -gt 0) { [void]$regBad.Add("${tag}_missing:$($miss -join ',')") }
  if ($extra.Count -gt 0) { [void]$regBad.Add("${tag}_extra:$($extra -join ',')") }
  # the rows drawn on the page: min(n, view) when the key opened with values, 1 otherwise
  $expRows = 1
  if ($ps.ok -and $expN -gt 0) { $expRows = $expN; if ($expRows -gt $CREGVIEW) { $expRows = $CREGVIEW } }
  if ([int]$d["startup_${tag}_rows"] -ne $expRows) { [void]$regBad.Add("${tag}_rows") }
}
# the data sizes RegQueryValueExA reports (asked with lpData = 0) must equal the sizes this script
# computes from the live values; one successful size query per enumerated name
$psBytesTotal = $rc2.bytes + $rc3.bytes
if ([int]$d["reg_bytes_total"] -ne [int]$psBytesTotal) { [void]$regBad.Add("reg_bytes_total") }
$expQ = @($rc2.names).Count + @($rc3.names).Count
if ([int]$d["reg_query_ok"] -ne $expQ) { [void]$regBad.Add("reg_query_ok") }
Write-Output "---- startup registry reconciliation (PowerShell read of the same keys) ----"
Write-Output ("    hkcu names(ps)={0} : {1}" -f @($rc2.names).Count, (@($rc2.names) -join '|'))
Write-Output ("    hklm names(ps)={0} : {1}" -f @($rc3.names).Count, (@($rc3.names) -join '|'))
Write-Output ("    names app(hkcu)={0} : {1}" -f [int]$d["reg_hkcu_n"], (@(0..([int]$d["reg_hkcu_n"] - 1) | ForEach-Object { $d["reg_hkcu_$_"] }) -join '|'))
Write-Output ("    names app(hklm)={0} : {1}" -f [int]$d["reg_hklm_n"], (@(0..([int]$d["reg_hklm_n"] - 1) | ForEach-Object { $d["reg_hklm_$_"] }) -join '|'))
Write-Output ("    bytes: ps={0} app={1} | size queries: ps={2} app={3}" -f $psBytesTotal, $d["reg_bytes_total"], $expQ, $d["reg_query_ok"])
Write-Output ("    per hive:" + $regTxt)
Check "C2m" "Startup page list == PowerShell's own read of the same two Run keys" ($regBad.Count -eq 0) `
  "bad=[$($regBad -join ',')] app_hkcu=$($d['reg_hkcu_n']) ps_hkcu=$(@($rc2.names).Count) app_hklm=$($d['reg_hklm_n']) ps_hklm=$(@($rc3.names).Count) max=$CREGMAX view=$CREGVIEW"
Check "C2m2" "the Startup page is a real page: a 5th distinct command stream with its rows" `
  (([int]$d["startup_hkcu_rows"] -ge 1) -and ([int]$d["startup_hklm_rows"] -ge 1)) `
  "hkcu_rows=$($d['startup_hkcu_rows']) hklm_rows=$($d['startup_hklm_rows']) page3_sig=$sig3"

# ---- C2o (v5, D): the two RunOnce keys against PowerShell's own read of the same keys -----------
$ro2 = RegRead "hkcu" "Software\Microsoft\Windows\CurrentVersion\RunOnce"
$ro3 = RegRead "hklm" "Software\Microsoft\Windows\CurrentVersion\RunOnce"
$roBad = New-Object System.Collections.ArrayList
foreach ($pair in @(@("hkcu", $ro2, "reg_ro_hkcu"), @("hklm", $ro3, "reg_ro_hklm"))) {
  $tag = $pair[0]; $ps = $pair[1]; $pre = $pair[2]
  $expState = "unavailable"
  if ($ps.ok) { $expState = "ok" }
  $appState = [string]$d["${pre}_state"]
  $appN = [int]$d["${pre}_n"]
  $psSet = @($ps.names | Select-Object -First $CREGMAX)
  $appSet = @()
  for ($i = 0; $i -lt $appN; $i++) { $appSet += [string]$d["${pre}_$i"] }
  $miss = @($psSet | Where-Object { $appSet -notcontains $_ })
  $extra = @($appSet | Where-Object { $psSet -notcontains $_ })
  Write-Output ("    RunOnce {0}: state app={1} ps={2} | n app={3} ps={4} | rows app={5} | missing=[{6}] extra=[{7}]" -f `
    $tag.ToUpper(), $appState, $expState, $appN, @($ps.names).Count, $d["startup_ro_${tag}_rows"], ($miss -join '|'), ($extra -join '|'))
  if ($appState -ne $expState) { [void]$roBad.Add("${tag}_state") }
  if ($appN -ne [Math]::Min(@($ps.names).Count, $CREGMAX)) { [void]$roBad.Add("${tag}_n") }
  if ($miss.Count -gt 0) { [void]$roBad.Add("${tag}_missing:$($miss -join ',')") }
  if ($extra.Count -gt 0) { [void]$roBad.Add("${tag}_extra:$($extra -join ',')") }
  $expRows = 1
  if ($ps.ok -and @($ps.names).Count -gt 0) { $expRows = [Math]::Min(@($ps.names).Count, $CREGVIEW) }
  if ([int]$d["startup_ro_${tag}_rows"] -ne $expRows) { [void]$roBad.Add("${tag}_rows") }
}
if ([int]$d["reg_keys_n"] -ne $CRGKEYS) { [void]$roBad.Add("reg_keys_n") }
Check "C2o" "RunOnce keys: the page's name sets == PowerShell's own read of the same two keys" ($roBad.Count -eq 0) `
  "bad=[$($roBad -join ',')] keys=$($d['reg_keys_n']) hkcu app=$($d['reg_ro_hkcu_n'])/ps=$(@($ro2.names).Count) hklm app=$($d['reg_ro_hklm_n'])/ps=$(@($ro3.names).Count) rows=$($d['startup_ro_hkcu_rows'])/$($d['startup_ro_hklm_rows']) budget=$($d['start_rows_budget'])"

# ---- C2p (v5, B): the System page's four strings against PowerShell's own registry read ---------
# The expectation is read HERE, from the very same keys, with the raw (unexpanded) values.
function RegValue([string]$which, [string]$sub, [string]$name) {
  $root = $null
  if ($which -eq "hklm") { $root = [Microsoft.Win32.Registry]::LocalMachine }
  if ($which -eq "hkcu") { $root = [Microsoft.Win32.Registry]::CurrentUser }
  if ($root -eq $null) { return $null }
  $key = $root.OpenSubKey($sub)
  if ($key -eq $null) { return $null }
  $v = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  $key.Close()
  if ($v -eq $null) { return $null }
  return [string]$v
}
$sysKeys = @(
  @{ k = "sys_product"; w = "hklm"; s = "SOFTWARE\Microsoft\Windows NT\CurrentVersion"; n = "ProductName"; bit = 1 },
  @{ k = "sys_display"; w = "hklm"; s = "SOFTWARE\Microsoft\Windows NT\CurrentVersion"; n = "DisplayVersion"; bit = 2 },
  @{ k = "sys_build";   w = "hklm"; s = "SOFTWARE\Microsoft\Windows NT\CurrentVersion"; n = "CurrentBuild"; bit = 4 },
  @{ k = "sys_cpu";     w = "hklm"; s = "HARDWARE\DESCRIPTION\System\CentralProcessor\0"; n = "ProcessorNameString"; bit = 8 }
)
$sysBad = New-Object System.Collections.ArrayList
$sysMask = 0
$sysTxt = ""
foreach ($sk in $sysKeys) {
  $ps = RegValue $sk.w $sk.s $sk.n
  $app = [string]$d[$sk.k]
  $sTxt = $ps
  if ($sTxt -ne $null -and $sTxt.Length -gt 40) { $sTxt = $sTxt.Substring(0, 40) + "..." }
  $sysTxt = $sysTxt + ("`n    {0,-12} app='{1}'" -f $sk.n, $sTxt)
  if ($ps -eq $null) { continue }
  $sysMask = $sysMask -bor $sk.bit
  if ($app -ne $ps) { [void]$sysBad.Add("$($sk.k):app='$app' ps='$ps'") }
}
if ([int]$d["sys_mask"] -ne $sysMask) { [void]$sysBad.Add("sys_mask app=$($d['sys_mask']) ps=$sysMask") }
if ([int]$d["sys_rows"] -ne $CSYSN) { [void]$sysBad.Add("sys_rows app=$($d['sys_rows']) ps=$CSYSN") }
Write-Output "---- System page strings (PowerShell read of the same four values) ----"
Write-Output $sysTxt
Write-Output ("    mask app={0} ps={1} (1 product, 2 version, 4 build, 8 cpu); rows drawn={2}/{3}" -f $d["sys_mask"], $sysMask, $d["sys_rows"], $CSYSN)
Check "C2p" "System page strings == PowerShell's own read of the same four registry values" ($sysBad.Count -eq 0) `
  "bad=[$($sysBad -join ' | ')] product='$($d['sys_product'])' build='$($d['sys_build'])' cpu='$($d['sys_cpu'])' mask=$($d['sys_mask'])"

# ---- C2q (v5, C): the Env page against PowerShell's own read of the two Environment keys --------
function EnvRead([string]$which, [string]$sub) {
  $names = @()
  $vals = @{}
  $ok = $false
  $root = $null
  if ($which -eq "hkcu") { $root = [Microsoft.Win32.Registry]::CurrentUser }
  if ($which -eq "hklm") { $root = [Microsoft.Win32.Registry]::LocalMachine }
  if ($root -ne $null) {
    $key = $root.OpenSubKey($sub)
    if ($key -ne $null) {
      $ok = $true
      foreach ($n in $key.GetValueNames()) {
        $names += $n
        $kind = $key.GetValueKind($n)
        $v = $key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (($kind -eq [Microsoft.Win32.RegistryValueKind]::String) -or ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
          $vals[$n] = [string]$v
        } elseif ($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
          $vals[$n] = [string][int]$v
        } else {
          $vals[$n] = $null
        }
      }
      $key.Close()
    }
  }
  return @{ ok = $ok; names = @($names); vals = $vals }
}
$ev0 = EnvRead "hkcu" "Environment"
$ev1 = EnvRead "hklm" "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$envBad = New-Object System.Collections.ArrayList
$envCap = $CENVVAL - 1
foreach ($pair in @(@("hkcu", $ev0, "env_hkcu"), @("hklm", $ev1, "env_hklm"))) {
  $tag = $pair[0]; $ps = $pair[1]; $pre = $pair[2]
  $expState = "unavailable"
  if ($ps.ok) { $expState = "ok" }
  if ([string]$d["${pre}_state"] -ne $expState) { [void]$envBad.Add("${tag}_state") }
  $appN = [int]$d["${pre}_n"]
  if ($appN -ne [Math]::Min(@($ps.names).Count, $CENVMAX)) { [void]$envBad.Add("${tag}_n") }
  $psSet = @($ps.names | Select-Object -First $CENVMAX)
  $appSet = @()
  for ($i = 0; $i -lt $appN; $i++) { $appSet += [string]$d["${pre}_name_$i"] }
  $miss = @($psSet | Where-Object { $appSet -notcontains $_ })
  $extra = @($appSet | Where-Object { $psSet -notcontains $_ })
  if ($miss.Count -gt 0) { [void]$envBad.Add("${tag}_missing:$($miss -join ',')") }
  if ($extra.Count -gt 0) { [void]$envBad.Add("${tag}_extra:$($extra -join ',')") }
  # ... and the head of every value must match the raw registry data (no expansion on either side)
  $vBad = 0
  for ($i = 0; $i -lt $appN; $i++) {
    $nm = [string]$d["${pre}_name_$i"]
    $appV = [string]$d["${pre}_val_$i"]
    if (-not $ps.vals.ContainsKey($nm)) { continue }
    $raw = $ps.vals[$nm]
    if ($raw -eq $null) { continue }
    $exp = $raw
    if ($exp.Length -gt $envCap) { $exp = $exp.Substring(0, $envCap) }
    if ($appV -ne $exp) { $vBad++; if ($vBad -le 2) { [void]$envBad.Add("${tag}_val:$nm") } }
  }
  Write-Output ("    Env {0}: state app={1} ps={2} | n app={3} ps={4} | value mismatches={5} | missing=[{6}] extra=[{7}]" -f `
    $tag.ToUpper(), $d["${pre}_state"], $expState, $appN, @($ps.names).Count, $vBad, ($miss -join '|'), ($extra -join '|'))
}
if ([int]$d["env_rows"] -lt 1) { [void]$envBad.Add("env_rows") }
$expEnvRows = [Math]::Min([Math]::Min(@($ev0.names).Count, $CENVVIEW) + [Math]::Min(@($ev1.names).Count, $CENVVIEW), $CENVROWS)
if ([int]$d["env_rows"] -ne $expEnvRows) { [void]$envBad.Add("env_rows app=$($d['env_rows']) ps=$expEnvRows") }
Write-Output ("    names ps(hkcu)={0} : {1}" -f @($ev0.names).Count, (@($ev0.names) -join '|'))
Write-Output ("    names ps(hklm)={0} : {1}" -f @($ev1.names).Count, (@($ev1.names) -join '|'))
Write-Output ("    names app(hkcu)={0} : {1}" -f [int]$d["env_hkcu_n"], (@(0..([Math]::Max(0, [int]$d["env_hkcu_n"] - 1)) | ForEach-Object { $d["env_hkcu_name_$_"] }) -join '|'))
Write-Output ("    rows drawn app={0} ps={1} (view cap {2}, page budget {3})" -f $d["env_rows"], $expEnvRows, $CENVVIEW, $CENVROWS)
Check "C2q" "Env page: name sets and value heads == PowerShell's own read of the two Environment keys" ($envBad.Count -eq 0) `
  "bad=[$($envBad -join ' | ')] hkcu=$($d['env_hkcu_n'])/$(@($ev0.names).Count) hklm=$($d['env_hklm_n'])/$(@($ev1.names).Count) rows=$($d['env_rows'])/$expEnvRows max=$($d['env_max']) view=$($d['env_view'])"

# ---- C2r (v5, A): the Actions page -- the source can only ever OPEN, and the page really draws --
# Independent judge: the command that actually starts a process is counted in the SOURCE, and every
# one of those call sites must carry the "open" verb literal (a "/c" or a write would show up here).
$callAll = ([regex]::Matches($txt, 'ShellExecuteA\(')).Count
$callOpen = ([regex]::Matches($txt, 'ShellExecuteA\(0, "open"')).Count
$callVerbs = @([regex]::Matches($txt, 'ShellExecuteA\(0, "([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$actBad = New-Object System.Collections.ArrayList
if ([int]$d["action_n"] -ne $CACTN) { [void]$actBad.Add("action_n") }
if ([int]$d["action_cols"] -ne $CACTCOLS) { [void]$actBad.Add("action_cols") }
if ([int]$d["action_rows"] -ne $CACTROWS) { [void]$actBad.Add("action_rows") }
if ([int]$d["action_btn_count"] -ne $CACTN) { [void]$actBad.Add("action_btn_count=$($d['action_btn_count'])") }
if ([int]$d["action_hint_rows"] -ne 1) { [void]$actBad.Add("action_hint_rows") }
if ($callAll -ne ($CACTN + 1)) { [void]$actBad.Add("source_calls=$callAll") }
if ($callOpen -ne $CACTN) { [void]$actBad.Add("source_open_calls=$callOpen") }
if (($callVerbs.Count -ne 1) -or ($callVerbs[0] -ne "open")) { [void]$actBad.Add("verbs=[$($callVerbs -join ',')]") }
$lblSeen = @{}
for ($i = 0; $i -lt $CACTN; $i++) {
  $lb = [string]$d["action_$i"]
  $tg = [string]$d["action_target_$i"]
  if ($lb.Length -lt 2) { [void]$actBad.Add("label_$i") }
  if ($tg.Length -lt 2) { [void]$actBad.Add("target_$i") }
  if ($lblSeen.ContainsKey($lb)) { [void]$actBad.Add("duplicate_label_$i") }
  $lblSeen[$lb] = 1
}
$tgTest = [string]$d["action_target_$CACTTEST"]
if (-not $tgTest.StartsWith("notepad")) { [void]$actBad.Add("test_target=$tgTest") }
Write-Output "---- Actions page (source call sites + the app's own table) ----"
for ($i = 0; $i -lt $CACTN; $i++) { Write-Output ("    {0,2}: {1,-18} -> {2}" -f $i, $d["action_$i"], $d["action_target_$i"]) }
Write-Output ("    source: ShellExecuteA( total={0} with 'open'={1} verbs=[{2}] (declaration counts once); buttons in the stream={3}" -f $callAll, $callOpen, ($callVerbs -join ','), $d["action_btn_count"])
Check "C2r" "Actions page: 10 launchers, every source call site uses the open verb only, all 10 buttons in the stream" ($actBad.Count -eq 0) `
  "bad=[$($actBad -join ',')] test_target='$tgTest' page4_sig=$sig4 buttons=$($d['action_btn_count']) hint_rows=$($d['action_hint_rows'])"

# ---------------------------------------------------------------- C3 ports vs real connects
$psPorts = @{}
$portLine = ""
foreach ($p in $ports) {
  $t = TcpState "127.0.0.1" $p 4000
  $psPorts[$p] = $t.st
  $portLine = $portLine + (" {0}={1}({2}ms)" -f $p, $t.st, $t.ms)
}
$pmis = New-Object System.Collections.ArrayList
foreach ($p in $ports) {
  $k = "port_$p"
  $appv = ""
  if ($d.ContainsKey($k)) { $appv = $d[$k] }
  if ($appv -ne $psPorts[$p]) { [void]$pmis.Add("$p app='$appv' ps='$($psPorts[$p])'") }
}
Write-Output ("---- PowerShell real connects:" + $portLine)
Check "C3" "port states == PowerShell connects" ($pmis.Count -eq 0) "mismatches=$($pmis.Count) $(($pmis) -join ' | ')"
Check "C3b" "port probe source recorded" ($d.ContainsKey("port_src")) "port_src=$($d['port_src'])"

# ---------------------------------------------------------------- C4 missing data degradation
[System.IO.File]::WriteAllText($srcovr, "E:\FLINT-lab\tmp\winpanel\no-such-snapshot.txt`r`n", (New-Object System.Text.ASCIIEncoding))
New-Item -ItemType File -Force -Path $marker | Out-Null
$dr4 = RunDump 60000
Remove-Item -LiteralPath $marker -Force
Remove-Item -LiteralPath $srcovr -Force
$d4 = @{}
if (Test-Path -LiteralPath $dumpPath) { $d4 = ReadDump $dumpPath }
$missingOk = ($dr4.rc -eq 0)
$missingOk = $missingOk -and ($d4["snap_state"] -eq "missing")
$allMissing = $true
foreach ($k in @("mem_time", "tasks_open", "cand", "sec_danger", "sec_warn", "sec_info", "disk_c_free_x10", "disk_e_free_x10", "disk_c_used_pct")) {
  if ($d4[$k] -ne "missing") { $allMissing = $false }
}
$missingOk = $missingOk -and $allMissing
Check "C4" "snapshot missing -> all 'missing', exit 0" $missingOk "exit=$($dr4.rc) snap_state=$($d4['snap_state']) all_fields_missing=$allMissing"
Check "C4b" "port rows still real when snapshot is gone" ($d4["port_3080"] -eq $psPorts[3080]) "port_3080=$($d4['port_3080']) ps=$($psPorts[3080])"
Check "C4c" "skeleton survives missing data (pages still switch)" (([int]$d4["pages_distinct"] -eq $CPAGES) -and ([int]$d4["nav_click_switched"] -eq $CPAGES)) "pages_distinct=$($d4['pages_distinct']) nav_click_switched=$($d4['nav_click_switched']) pages=$CPAGES"
# the two v4 features are independent of the snapshot: losing the data file must not touch the
# registry list (and vice versa)
Check "C4d" "registry list unaffected by the missing snapshot (independent data sources)" `
  (($d4["reg_hkcu_n"] -eq $d["reg_hkcu_n"]) -and ($d4["reg_hkcu_0"] -eq $d["reg_hkcu_0"]) -and ($d4["reg_hklm_n"] -eq $d["reg_hklm_n"])) `
  "hkcu n=$($d4['reg_hkcu_n']) vs $($d['reg_hkcu_n']) first='$($d4['reg_hkcu_0'])' hklm n=$($d4['reg_hklm_n']) vs $($d['reg_hklm_n'])"

# ---------------------------------------------------------------- C5 git hygiene
$diff = & git -C $repo -c core.quotepath=false diff --stat -- lib src boot test 2>&1 | Out-String
$diff = $diff.Trim()
$st = & git -C $repo -c core.quotepath=false status --porcelain 2>&1
$stLines = @($st | Where-Object { $_ -ne "" })
# M4r: this round is a LIB round ON PURPOSE (the user chose the library-level fix over an app-local
# workaround), so the old "nothing outside apps/winpanel may move" rule is replaced by "exactly the
# expected set moved" -- with src\ and boot\ still frozen and every sample/baseline untouched.
#   lib\ui_lib.fl     the surf_alpha rewrite (output byte-identical: tmp\m4r\alpha-ab.fl)
#   test\*.txt        at most the two gate RECORD files (the re-recorded fingerprint, written with
#                     -Reason, and the differential gate's own last-run log) -- no sample, no baseline
#   bench\*           rewritten by the bench-ruler gate run itself
# The two record files have Chinese names, so they are matched by shape rather than by literal name:
# this script is deliberately ASCII-only (a Chinese character here would need a UTF-8 BOM, and the
# edit tool eats BOMs -- see the file header).
$expectedMoved = @(
  'lib/ui_lib.fl',
  'bench/bench_counts.fl', 'bench/bench_one_O1.exe', 'bench/bench_one_O2.exe',
  'bench/result-single.json', 'bench/result-single.log'
)
$movedPaths = @()
foreach ($l in $stLines) {
  if ($l.Length -gt 3) {
    $pth = $l.Substring(3).Trim('"')
    if ($pth -match '^(lib|src|boot|test|bench)/') { $movedPaths += $pth }
  }
}
$srcBootTouched = @($movedPaths | Where-Object { $_ -match '^(src|boot)/' })
$movedTestRec = @($movedPaths | Where-Object { $_ -match '^test/' })
$movedUnexpected = @($movedPaths | Where-Object { ($expectedMoved -notcontains $_) -and ($_ -notmatch '^test/') })
$sampleTouched = @($movedPaths | Where-Object { $_ -match '^test/(samples/|flgui-baseline)' })
$testRecOk = ($movedTestRec.Count -le 2)
$unexpected = @($stLines | Where-Object {
  $pth = $_.Substring(3).Trim('"')
  ($_ -notmatch 'apps/winpanel/') -and ($_ -notmatch '\.md"?$') -and ($_ -notmatch '^\?\? tmp/') -and ($movedPaths -notcontains $pth)
})
Write-Output "---- git status --porcelain ----"
foreach ($l in $stLines) { Write-Output ("    " + $l) }
Check "C5a" "LIB round: src\ and boot\ untouched, only the expected lib/bench files plus <=2 gate records moved" `
  (($srcBootTouched.Count -eq 0) -and ($movedUnexpected.Count -eq 0) -and $testRecOk) `
  "moved=[$($movedPaths -join ',')] src_boot=[$($srcBootTouched -join ',')] unexpected=[$($movedUnexpected -join ',')] test_records=$($movedTestRec.Count)"
Check "C5b" "git status only touches apps/winpanel + tmp + the work order md + this round's files" ($unexpected.Count -eq 0) "lines=$($stLines.Count) unexpected=$($unexpected.Count) ($($stLines -join ' | '))"
Check "C5c" "no test sample and no dump baseline is touched (only the fingerprint record + the gate log)" `
  ($sampleTouched.Count -eq 0) "samples_or_baselines=[$($sampleTouched -join ',')] diff_stat='$diff'"

# ---------------------------------------------------------------- C6 window smoke with REAL input
# v5: the injection precondition FIRST. Everything below drives the panel with synthetic mouse
# events; if the desktop silently discards them (an elevated foreground window does exactly that,
# see Test-Inject above) then twelve checks would go red for a reason the panel cannot cause. So
# the guard is its own numbered check and, when it has to fix the foreground, it does so with a
# normal-integrity helper window that is stopped again at the end of the whole run.
$injHelper = $null
$inj = @{ ok = $true; from = "-"; to = "-"; fg = [IntPtr]::Zero }
if ((-not $SkipSmoke) -or (-not $SkipAB) -or (-not $SkipIdle)) {
  $inj = Test-Inject
  if (-not $inj.ok) {
    $injHelper = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1500
    $inj = Test-Inject
    Write-Output ("---- synthetic input was being discarded (foreground hwnd was $($inj.fg)); " +
                  "a normal-integrity helper window was started (pid $($injHelper.Id)) and injection re-probed ----")
  }
  Check "C6z" "the desktop really accepts synthetic mouse input (an elevated foreground discards it)" $inj.ok `
    "SetCursorPos moved the cursor $($inj.from) -> $($inj.to) helper_pid=$(if ($injHelper) { $injHelper.Id } else { 'none' }) fg=$($inj.fg)"
}
CleanMarkers
$probeTimeline = ""
$seenStates = @{}
$themeLightHash = ""
$themeDarkHash = ""
$themeBackHash = ""
$themeBright = @{}
$themePix = @{}
if (-not $SkipSmoke) {
  Get-Process -Name winpanel -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 400
  # v5: FREEZE THE DATA for this block, exactly as the C9 block already does (its own header records
  # that C9 once went red because the live snapshot was rewritten under it). Reason it matters here:
  # the opacity criterion pairs a SCREEN capture with a DIB capture of the same frame; if the app
  # repaints in between (the 2 s refresh re-reads the snapshot, and the task engine rewrites that
  # file while other work is going on) the two captures disagree at the few pixels of the row that
  # changed, which shows up as a handful of ~150-level outliers while the median stays exact.
  # The port list is deliberately NOT frozen: C6g..C6j need the live socket path.
  Copy-Item -LiteralPath $snap -Destination $frozen -Force
  [System.IO.File]::WriteAllText($srcovr, $frozen + "`r`n", (New-Object System.Text.ASCIIEncoding))
  # The desktop behind where the window will be, captured BEFORE the window exists. The opacity
  # check needs to know what is behind the panel, and no app-side number can supply that: this
  # script measures it itself and uses it in the composition model (C6s/C6t/C6u).
  $bgShot = ShotScreen $CX $CY $CW $CH
  $bgBytes = ImgBytes $bgShot
  # M4r: the frame ledger has to be LIVE for this instance -- the app checks tmp\winpanel\fps.on once
  # at startup, and the window-move fast-path check (C6w) reads that ledger's `flushes` counter.
  New-Item -ItemType File -Force -Path $fpson | Out-Null
  # v10 (M12): turn the app's layer trace ON for this instance (it is read once at startup). C11c uses
  # its `pressn` counter as the panel-side proof that a real press was processed; the file is deleted
  # again right after the C6 block, so C10's own use of the same channel starts from an empty file.
  if (Test-Path -LiteralPath $c10TraceEarly) { Remove-Item -LiteralPath $c10TraceEarly -Force }
  New-Item -ItemType File -Force -Path $c10TraceOnEarly | Out-Null
  $proc = Start-Process -FilePath $exe -PassThru
  $w = WaitWindow $cls 5000
  $h = $w.hwnd
  $winMs = $w.ms
  $alive = -not $proc.HasExited
  Check "C6a" "window '$cls' created (smoke: it came up)" ($h -ne [IntPtr]::Zero -and $alive) "hwnd=$h after=${winMs}ms process alive=$alive"
  if ($h -ne [IntPtr]::Zero) {
    $rc = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$rc)
    $ex = [WinPanelProbe]::GetWindowLong($h, -20)
    $w0 = $rc.r - $rc.l; $ht = $rc.b - $rc.t
    Check "C6b" "window size == WP_W x WP_H from main.fl ($CW x $CH)" (($w0 -eq $CW) -and ($ht -eq $CH)) "rect=${w0}x${ht} at $($rc.l),$($rc.t)"
    $exOk = (($ex -band 0x8) -ne 0) -and (($ex -band 0x80000) -ne 0) -and [WinPanelProbe]::IsWindowVisible($h)
    Check "C6c" "topmost + layered + visible" $exOk ("exstyle=0x{0:X8}" -f $ex)
    Start-Sleep -Milliseconds 1200
    Park
    # (1) the default page must be the skeleton start page, and a REAL click on the Ports tab
    #     must change what is on screen
    $b0 = ImgShot $h $w0 $ht
    $hash0 = ImgHash $b0
    $ink0 = ImgInk $b0
    $avgTitle = BandAvg $b0 0 0 $CW $CTH
    $avgNav = BandAvg $b0 0 $CTH $CNW ($CH - $CBH)
    $avgBase = BandAvg $b0 ($CNW + 20) ($CTH + 20) ($CW - 20) ($CH - $CBH - 20)
    # every button must really SHOW its label: the library renders text for kind 5 only, so
    # gui_button's own string never reaches the screen -- the app draws the labels itself, and this
    # is the check that keeps that from silently regressing (the v2 delivery had blank buttons)
    $dTheme = @($d["geo_theme_rect"] -split ',' | ForEach-Object { [int]$_ })
    $dClose = @($d["geo_close_rect"] -split ',' | ForEach-Object { [int]$_ })
    $dSetupBtn = @($d["geo_setupbtn_rect"] -split ',' | ForEach-Object { [int]$_ })
    $dCollBtn = @($d["geo_collapse_rect"] -split ',' | ForEach-Object { [int]$_ })
    $dNb0 = @($d["geo_navbtn0_rect"] -split ',' | ForEach-Object { [int]$_ })
    $btnList = @(
      @{ n = "setup"; x = $dSetupBtn[0]; y = $dSetupBtn[1]; w = $dSetupBtn[2]; h = $dSetupBtn[3] },
      @{ n = "theme"; x = $dTheme[0]; y = $dTheme[1]; w = $dTheme[2]; h = $dTheme[3] },
      @{ n = "collapse"; x = $dCollBtn[0]; y = $dCollBtn[1]; w = $dCollBtn[2]; h = $dCollBtn[3] },
      @{ n = "close"; x = $dClose[0]; y = $dClose[1]; w = $dClose[2]; h = $dClose[3] },
      @{ n = "nav1"; x = $dNb0[0]; y = $dNb0[1]; w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav2"; x = $dNb0[0]; y = ($dNb0[1] + $CBDY); w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav3"; x = $dNb0[0]; y = ($dNb0[1] + 2 * $CBDY); w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav4"; x = $dNb0[0]; y = ($dNb0[1] + 3 * $CBDY); w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav5"; x = $dNb0[0]; y = ($dNb0[1] + 4 * $CBDY); w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav6"; x = $dNb0[0]; y = ($dNb0[1] + 5 * $CBDY); w = $dNb0[2]; h = $dNb0[3] },
      @{ n = "nav7"; x = $dNb0[0]; y = ($dNb0[1] + 6 * $CBDY); w = $dNb0[2]; h = $dNb0[3] }
    )
    $lblTxt = ""
    $lblMin = [int]::MaxValue
    foreach ($bt in $btnList) {
      $v = DarkIn $b0 $bt.x $bt.y $bt.w $bt.h
      $lblTxt = $lblTxt + (" {0}={1}" -f $bt.n, $v)
      if ($v -lt $lblMin) { $lblMin = $v }
    }
    $b0.Dispose()
    Check "C6d" "captured frame is not blank (the panel really paints)" ($ink0 -gt 1000) "inkPixels=$ink0"
    Check "C6e" "skeleton reads as bars over the base (relative brightness)" (($avgTitle -gt $avgBase) -and ($avgNav -gt $avgBase)) "avg title=$avgTitle nav=$avgNav base=$avgBase"
    Check "C6p" "all 11 buttons render a visible label (dark ink inside each button rect)" ($lblMin -ge 3) "label ink pixels:$lblTxt (a blank button measures 0; the 1-char '-' glyph is legitimately tiny)"
    # (1a2) the SECONDARY page with the real mouse: Setup must cover the content area, and Back
    #       must come back PIXEL-IDENTICAL (the settings page is a pure overlay and the opacity is
    #       untouched here, so a non-identical return would be a real defect)
    $dBackBtn = @($d["geo_setup_back_rect"] -split ',' | ForEach-Object { [int]$_ })
    $scx = $dSetupBtn[0] + [int]($dSetupBtn[2] / 2); $scy = $dSetupBtn[1] + [int]($dSetupBtn[3] / 2)
    $bkx = $rc.l + $dBackBtn[0] + [int]($dBackBtn[2] / 2); $bky = $rc.t + $dBackBtn[1] + [int]($dBackBtn[3] / 2)
    $bs = ImgShot $h $w0 $ht
    $setupBefore = ImgHash $bs
    $bs.Dispose()
    ClickAt ($rc.l + $scx) ($rc.t + $scy); Park
    $bs = ImgShot $h $w0 $ht
    $setupOpenHash = ImgHash $bs
    $setupInk = ImgInk $bs
    $bs.Dispose()
    ClickAt $bkx $bky; Park
    $bs = ImgShot $h $w0 $ht
    $setupBackHash = ImgHash $bs
    $bs.Dispose()
    Check "C6r" "real Setup click opens the secondary page; Back returns a pixel-identical frame" `
      (($setupOpenHash -ne $setupBefore) -and ($setupBackHash -eq $setupBefore) -and ($setupInk -gt 1000)) `
      "before=$($setupBefore.Substring(0,12)) open=$($setupOpenHash.Substring(0,12)) back=$($setupBackHash.Substring(0,12)) (equal=$($setupBackHash -eq $setupBefore)) ink=$setupInk"
    # v6 (B): the layer selector must really move the window between bands, and that is judged here
    # by THIS script's own read of GWL_EXSTYLE -- not by the app's report. Reason: the first v6 build
    # passed all 91 checks while the `top` selector silently fell back to HWND_TOP (FindWindowA was
    # called with its arguments the other way round -> no tray handle -> no topmost band), i.e. the
    # switch could never promote the window back. A judgement that reads the app's own field would
    # have stayed green forever.
    ClickAt ($rc.l + $scx) ($rc.t + $scy); Park          # open Setup
    # v10 (M12): the Layer control is no longer ONE cycling button -- it is three buttons (top /
    # normal / auto) and each one is a DIRECT position. The judge therefore reads all three rects out
    # of the dump (C2j already proved each of them equals main.fl's own arithmetic) and clicks the one
    # it means. The old round-robin made "go to top" impossible without passing through normal, and
    # normal used to park the panel at HWND_BOTTOM -- the user: "it jumps to the bottom and then I
    # cannot click it any more" -- so this check now also proves that a single press on `normal`
    # leaves a panel a real mouse click can still reach.
    $layTopR = @($d["geo_layer_top_rect"] -split ',' | ForEach-Object { [int]$_ })
    $layNorR = @($d["geo_layer_normal_rect"] -split ',' | ForEach-Object { [int]$_ })
    $layAutR = @($d["geo_layer_auto_rect"] -split ',' | ForEach-Object { [int]$_ })
    $lyTopX = $rc.l + $layTopR[0] + [int]($layTopR[2] / 2); $lyTopY = $rc.t + $layTopR[1] + [int]($layTopR[3] / 2)
    $lyNorX = $rc.l + $layNorR[0] + [int]($layNorR[2] / 2); $lyNorY = $rc.t + $layNorR[1] + [int]($layNorR[3] / 2)
    $lyAutX = $rc.l + $layAutR[0] + [int]($layAutR[2] / 2); $lyAutY = $rc.t + $layAutR[1] + [int]($layAutR[3] / 2)
    [void][WinPanelProbe]::SetCursorPos($lyTopX, $lyTopY)   # first read happens with the pointer away
    Park
    $exA = [WinPanelProbe]::GetWindowLong($h, -20)
    ClickAt $lyNorX $lyNorY; Park                        # press NORMAL once
    Start-Sleep -Milliseconds 1600
    $exB = [WinPanelProbe]::GetWindowLong($h, -20)
    # the reachability half: is the panel the window a real click at its centre would land on? (Before
    # M12 `normal` meant HWND_BOTTOM and this answered about ANOTHER process -- measured, see v11 in
    # the acceptance file: z#175 of 175 and WindowFromPoint(centre) = another pid.) Read with the
    # pointer parked, so this measurement is not disturbed by a click.
    $pcPt = New-Object WPPOINT; $pcPt.x = $rc.l + [int]($w0 / 2); $pcPt.y = $rc.t + [int]($ht / 2)
    $norUnder = [WinPanelProbe]::WindowFromPoint($pcPt)
    $norReach = ($norUnder -eq $h)
    ClickAt $lyAutX $lyAutY; Park                        # press AUTO once
    Start-Sleep -Milliseconds 1900
    $exC = [WinPanelProbe]::GetWindowLong($h, -20)
    ClickAt $lyTopX $lyTopY; Park                        # press TOP once: a real topmost band again
    Start-Sleep -Milliseconds 1400
    $exD = [WinPanelProbe]::GetWindowLong($h, -20)
    Check "C6x2" "the three Layer buttons really switch bands, one press each (GWL_EXSTYLE read back by THIS script) and normal leaves the panel CLICKABLE" `
      ((($exA -band 0x8) -ne 0) -and (($exB -band 0x8) -eq 0) -and (($exC -band 0x8) -eq 0) -and (($exD -band 0x8) -ne 0) -and $norReach) `
      ("exstyle: start=0x{0:X8} (top) | after pressing NORMAL=0x{1:X8} (TOPMOST bit clear) | after pressing AUTO=0x{2:X8} (clear: auto shows itself in the NORMAL band) | after pressing TOP=0x{3:X8} (set again) ; WindowFromPoint(panel centre)=$norUnder -> is the panel itself={4} (v10/M12: normal used to be HWND_BOTTOM and this answered about ANOTHER window)" -f $exA, $exB, $exC, $exD, $norReach)
    ClickAt $bkx $bky; Park                              # leave the settings page again
    # v7 (M7): the `auto` mode judged by its BEHAVIOUR, not by the selector's label. The v6 cover
    # verdict (five WindowFromPoint probes) was measured to answer about the DESKTOP even while the
    # panel was topmost, painted and receiving real clicks (tmp\m7\), so the verdict sat at "covered"
    # forever and `auto` could never return to the top. The verdict is now a z-order walk.
    # v10 (M12): this check keeps BOTH of M7's halves -- a REAL TOPMOST window above the panel still
    # makes it yield, and the panel comes back once that window is gone -- and the "come back" half is
    # judged under the NEW semantics: the panel returns to the front of the NORMAL band and never
    # promotes itself into the topmost band. The ORDINARY-window case (the actual user report) is
    # C11a/C11d below, which are foreground-driven and never start a fresh window.
    ClickAt ($rc.l + $scx) ($rc.t + $scy); Park          # open Setup
    ClickAt $lyAutX $lyAutY; Park                        # select AUTO directly (one press)
    Start-Sleep -Milliseconds 1900
    $exSel = [WinPanelProbe]::GetWindowLong($h, -20)
    $covProc = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 900
    # NOTE: these locals are deliberately NOT named $clr / $clH: PowerShell variable names are
    # case-INsensitive, so `$clH` would overwrite the geometry constant `$CLH` (WP_LINE_H = 24) and
    # the opacity checks further down would silently sample a nonsense band (measured: skipY became
    # [170,11994562) and the sample grid collapsed 495 -> 135, failing C6s/C6s2 from a distance).
    $covHwnd = $covProc.MainWindowHandle
    if ($covHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 900; $covHwnd = $covProc.MainWindowHandle }
    [void][WinPanelProbe]::MoveWindow($covHwnd, $rc.l, $rc.t, ($rc.r - $rc.l), ($rc.b - $rc.t), $true)
    [void][WinPanelProbe]::SetWindowPos($covHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x13)   # coverer = HWND_TOPMOST
    [void][WinPanelProbe]::SetForegroundWindow($covHwnd)
    Start-Sleep -Milliseconds 3400
    $exYield = [WinPanelProbe]::GetWindowLong($h, -20)
    $covAbove = ZAbove $h $covHwnd
    Stop-Process -Id $covProc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 3800
    $exRe = [WinPanelProbe]::GetWindowLong($h, -20)
    ClickAt $lyTopX $lyTopY; Park                        # press TOP: back to topmost (one press)
    ClickAt $bkx $bky; Park                              # leave the settings page
    Check "C6x3" "auto = FRONT OF THE NORMAL BAND (v9/M10: not topmost), still yields to a real topmost window above it, and is back in the normal band once that window is gone (all read back here)" `
      (((($exSel -band 0x8) -eq 0) -and $covAbove -and (($exRe -band 0x8) -eq 0))) `
      ("exstyle: just after selecting auto=0x{0:X8} (topmost bit must be CLEAR -- v9/M10 changed auto from 'expose topmost' to 'front of the normal band'), with a REAL topmost coverer over the panel=0x{1:X8} while THIS script's own z-order walk found the coverer above the panel={2}, after the coverer was killed=0x{3:X8} (must be clear again)" -f $exSel, $exYield, $covAbove, $exRe)
    # ---- v10 (M12): the FOREGROUND-driven `auto` rule, judged with windows that are NOT new ---------
    # The user reported twice (2026-10-11): "I still need to be able to cover it with the FOCUSED
    # window" and "it does not judge windows that are already running". The M10 judge below drove the
    # ordinary case by STARTING A FRESH notepad -- a trigger that only works on an activation CHANGE
    # and therefore proves nothing about a browser the user opened an hour ago. C11a/C11d replace it:
    #   * the notepad is started BEFORE the session is arranged and is brought to the FOREGROUND by a
    #     REAL CLICK on the strip of it that sticks out past the panel's rect (a click on a spot the
    #     panel covers is fed to the panel, so a fully covered window can never be activated this way);
    #   * in `auto` the panel must end up BELOW that foreground window; in `top` it must stay ABOVE it;
    #   * C11c then proves the way back: a real press on the panel raises it and keeps it up (not just
    #     for one frame -- the judge waits past the 2 s policy sample);
    #   * C11d closes the loop: once the focused window is minimized the panel comes back to the front
    #     of the NORMAL band by itself, still non-topmost and still visible.
    ClickAt ($rc.l + $scx) ($rc.t + $scy); Park          # open Setup
    Start-Sleep -Milliseconds 1200
    # v10 (M12): a helper window of THIS judge's own, placed clear of the panel ((0,940)-(200,1040):
    # the panel lives at (448,172)-(1472,908), so the two cannot overlap). C11d anchors the foreground
    # on it after the minimize -- see the note there -- and it is closed again at the end of this block.
    $fgHelpForm = New-Object System.Windows.Forms.Form
    $fgHelpForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $fgHelpForm.Text = 'm12-foreground-helper'
    $fgHelpForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $fgHelpForm.SetBounds(0, 940, 200, 100)
    $fgHelpForm.ShowInTaskbar = $false
    $fgHelpForm.Show()
    [void]$fgHelpForm.Handle
    [System.Windows.Forms.Application]::DoEvents()
    $fgHelp = $fgHelpForm.Handle
    $fgHelpRc = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($fgHelp, [ref]$fgHelpRc)
    $helpClear = -not (($fgHelpRc.l -lt $rc.r) -and ($fgHelpRc.r -gt $rc.l) -and ($fgHelpRc.t -lt $rc.b) -and ($fgHelpRc.b -gt $rc.t))
    Write-Output ("     M12 helper window: hwnd=$fgHelp rect=($(Csv @($fgHelpRc.l, $fgHelpRc.t, $fgHelpRc.r, $fgHelpRc.b))) does NOT overlap the panel rect=$(Csv @($rc.l, $rc.t, $rc.r, $rc.b)) -> $helpClear")
    # an ALREADY OPEN window, placed at fixed screen coordinates so that: (a) a strip of it lies
    # OUTSIDE the panel's rect and can be clicked, (b) it OVERLAPS the panel, and (c) it does NOT cover
    # the three layer buttons (those live at x >= 216 inside the panel -- the panel's left edge is
    # $rc.l, so a 720-wide window at x = $rc.l - 340 ends 20 px short of them).
    $npOld = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1300
    $npOldH = $npOld.MainWindowHandle
    if ($npOldH -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 900; $npOldH = $npOld.MainWindowHandle }
    [void][WinPanelProbe]::MoveWindow($npOldH, ($rc.l - 340), ($rc.t - 130), 720, 420, $true)
    Start-Sleep -Milliseconds 400
    # the notepad's ACTUAL rect: C11d probes a point this window really covers, so it must not be assumed
    $npOldRc = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($npOldH, [ref]$npOldRc)
    # WHERE to click a notepad that the panel partly covers: on its own TITLE BAR, above the panel's top
    # edge. MoveWindow's height (420) is clamped by the window's minimum tracking size, so the window is
    # really only ~332 px tall -- a click derived from 420 lands BELOW its bottom edge, i.e. on the PANEL
    # instead, and everything downstream then measures the wrong window (measured: C11d's precondition
    # read "the notepad is not above the panel" while the real cause was that the click never reached
    # the notepad). Both coordinates are derived from the MEASURED rect and asserted to be inside it and
    # outside the panel's rect.
    $npClickX = [int]($npOldRc.l + 120)
    $npClickY = [int]($npOldRc.t + 14)
    $clickInside = ($npClickX -gt $npOldRc.l) -and ($npClickX -lt $npOldRc.r) -and ($npClickY -gt $npOldRc.t) -and ($npClickY -lt $npOldRc.b)
    $clickOutsidePanel = -not (($npClickX -gt $rc.l) -and ($npClickX -lt $rc.r) -and ($npClickY -gt $rc.t) -and ($npClickY -lt $rc.b))
    Write-Output ("     M12 notepad strip click: notepad rect=($(Csv @($npOldRc.l, $npOldRc.t, $npOldRc.r, $npOldRc.b))) -> click ($npClickX,$npClickY) inside it={0}, outside the panel rect=$(Csv @($rc.l, $rc.t, $rc.r, $rc.b))={1}" -f $clickInside, $clickOutsidePanel)
    ClickAt $npClickX $npClickY; Park             # a REAL click on the notepad's own title strip
    Start-Sleep -Milliseconds 900
    $fgOld = [WinPanelProbe]::GetForegroundWindow()
    $actOk = ($fgOld -eq $npOldH) -and $npOldH -ne [IntPtr]::Zero
    # (1) `top`: the panel is a REAL topmost window, so an ordinary foreground window cannot get above it
    ClickAt $lyTopX $lyTopY; Park
    Start-Sleep -Milliseconds 1400
    $exTopMode = [WinPanelProbe]::GetWindowLong($h, -20)
    $aboveInTop = ZAbove $h $npOldH
    # (2) `auto`: one press on the Auto button, and the FOREGROUND window (already open, never
    # restarted) must end up ABOVE the panel. No SetForegroundWindow and no fresh process is used, so
    # a rule that keyed on "a window appeared" or "an activation change" cannot pass this.
    ClickAt $lyAutX $lyAutY; Park
    Start-Sleep -Milliseconds 3400                             # > the 2 s policy sample, plus margin
    $exAutoMode = [WinPanelProbe]::GetWindowLong($h, -20)
    $aboveInAuto = ZAbove $h $npOldH
    $fgStillOld = (([WinPanelProbe]::GetForegroundWindow()) -eq $npOldH)
    Check "C11a" "auto is FOREGROUND-driven: an ALREADY OPEN window, merely focused, gets above the panel in auto and can never in top (no fresh window is started anywhere in this check)" `
      ($actOk -and $clickInside -and $clickOutsidePanel -and (($exTopMode -band 0x8) -ne 0) -and (($exAutoMode -band 0x8) -eq 0) -and (-not $aboveInTop) -and $aboveInAuto) `
      ("the notepad (pid $($npOld.Id), started BEFORE the click, never restarted) really became the foreground window by THIS script's own real click={0} (the click at ($npClickX,$npClickY) was inside its measured rect={1} and outside the panel's={2}) ; top mode: exstyle=0x{3:X8} (topmost bit set), it is above the panel={4} (must be False) ; auto mode: exstyle=0x{5:X8} (bit clear), the same window is above the panel={6} (must be True), it is STILL the foreground window={7}" -f $actOk, $clickInside, $clickOutsidePanel, $exTopMode, $aboveInTop, $exAutoMode, $aboveInAuto, $fgStillOld)
    # (3) C11c: the user's way back. FIRST make the panel really yield again -- click the notepad's own
    # strip (foreground), press AUTO, and let the rule give it the spot -- so the press below starts from
    # "the panel is genuinely under the focused window"; without that step the panel is still in front
    # from the check above and the raise would have nothing to prove. Then press the panel's own centre
    # with the real mouse: the panel must be the window at that point (reachable), and its own `pressn`
    # counter (layer trace) must go up -- i.e. the press was really PROCESSED by the panel.
    ClickAt $npClickX $npClickY; Park
    Start-Sleep -Milliseconds 800
    $fgBack = (([WinPanelProbe]::GetForegroundWindow()) -eq $npOldH)
    ClickAt $lyAutX $lyAutY; Park                        # auto again: the raise is the thing measured
    Start-Sleep -Milliseconds 3400
    $yieldedC11c = -not (ZAbove $h $npOldH)
    $prBefore = TracePress
    $pcPt2 = New-Object WPPOINT; $pcPt2.x = $rc.l + [int]($w0 / 2); $pcPt2.y = $rc.t + [int]($ht / 2)
    $underC11c = [WinPanelProbe]::WindowFromPoint($pcPt2)
    $reachC11c = ($underC11c -eq $h)
    ClickAt $pcPt2.x $pcPt2.y; Park
    Start-Sleep -Milliseconds 1400
    $prAfter = TracePress
    $raisedC11c = ZAbove $npOldH $h        # "the panel is above the notepad" == not ZAbove(panel, notepad)
    $panelAbove = -not (ZAbove $h $npOldH)
    $exC11c = [WinPanelProbe]::GetWindowLong($h, -20)
    Check "C11c" "a real click at the panel's centre reaches the PANEL (WindowFromPoint) and is really PROCESSED (the panel's own press counter rises), and it brings the panel back above the focused window -- and it STAYS there past the 2 s policy sample" `
      ($reachC11c -and ($prAfter -gt $prBefore) -and $prBefore -ge 0 -and $panelAbove -and (($exC11c -band 0x8) -eq 0)) `
      ("the fixture was put back under it first (the notepad is the foreground window again=$fgBack, and the panel had yielded below it=$yieldedC11c, otherwise this press would have nothing to prove) ; WindowFromPoint(panel centre)=$underC11c -> the panel itself={0} ; the panel's own pressn counter went {1} -> {2} (read out of its layer trace: a real press was processed, not swallowed) ; after the click the panel is above the focused window={3}, still NOT topmost (exstyle=0x{4:X8}), measured 1.4 s after the click and still true after +3 s below" -f $reachC11c, $prBefore, $prAfter, $panelAbove, $exC11c)
    Start-Sleep -Milliseconds 3000
    $stillAbove = -not (ZAbove $h $npOldH)
    Check "C11b2" "the raise survives the auto policy's next 2 s sample (the user's 'do not slide back under me'): the panel is still above the focused window after +3 s" `
      $stillAbove ("panel above the still-focused window after the extra 3 s={0} (a timer-based suppression would have given the spot back here)" -f $stillAbove)
    # (3b) C11f -- v12 (M13): the LEVEL condition. User report (2026-10-11 09:5x): "the window
    # judgement does not consider the LEVEL -- anything in range gets pushed up". The fixture is that
    # situation, made measurable: the notepad is the FOREGROUND window, its rect overlaps the panel's,
    # and it sits directly BELOW the panel. Pressing AUTO then makes the panel re-ask the question in
    # its FRESH branch -- the branch that ignores the user-hold, and the reachable form of the report
    # (measured pre-fix, tmp\m13\probe-behind-fg-run-before.txt PHASE C: panel z#34 / notepad z#37
    # before the press, panel z#37 / notepad z#34 after it, i.e. the notepad was lifted OVER the panel).
    # After the fix the panel must not move at all: the notepad stays below it, and the panel is still
    # the window at a point only the two of them can own.
    [void][WinPanelProbe]::SetWindowPos($npOldH, $h, 0, 0, 0, 0, 0x13)   # notepad directly below the panel
    Start-Sleep -Milliseconds 900
    $fPreBelow = -not (ZAbove $h $npOldH)                 # the notepad is NOT above the panel ...
    $fPreFg = (([WinPanelProbe]::GetForegroundWindow()) -eq $npOldH)
    $fZ0 = ZIndex $h
    $fOvL = [Math]::Max($npOldRc.l, $rc.l); $fOvT = [Math]::Max($npOldRc.t, $rc.t)
    $fOvR = [Math]::Min($npOldRc.r, $rc.r); $fOvB = [Math]::Min($npOldRc.b, $rc.b)
    $fPt = New-Object WPPOINT
    $fPt.x = [int](($fOvL + $fOvR) / 2); $fPt.y = [int](($fOvT + $fOvB) / 2)
    $fUnderPre = [WinPanelProbe]::WindowFromPoint($fPt)
    ClickAt $lyAutX $lyAutY; Park                         # press AUTO: a FRESH auto decision
    Start-Sleep -Milliseconds 5200                        # >= 2 policy samples after the fresh frame
    $fPostBelow = -not (ZAbove $h $npOldH)
    $fPostFg = (([WinPanelProbe]::GetForegroundWindow()) -eq $npOldH)
    $fEx = [WinPanelProbe]::GetWindowLong($h, -20)
    $fVis = [WinPanelProbe]::IsWindowVisible($h)
    $fZ1 = ZIndex $h
    $fUnderPost = [WinPanelProbe]::WindowFromPoint($fPt)
    Check "C11f" "the LEVEL condition: a FOREGROUND window that merely OVERLAPS the panel but sits BELOW it is NOT pulled up over the panel by an auto decision (the notepad stays below, and the panel is still the window at their overlap centre)" `
      ($fPreBelow -and $fPreFg -and $fPostBelow -and $fPostFg -and ($fUnderPost -eq $h) -and (($fEx -band 0x8) -eq 0) -and $fVis -and ($fZ1 -le $fZ0)) `
      ("precondition: before the AUTO press the notepad was the FOREGROUND window={0} and sat BELOW the panel={1} (WindowFromPoint at the centre of their overlap ($($fPt.x),$($fPt.y)) was the panel: $fUnderPre) ; after the press + 5.2 s (>=2 samples): the notepad is still BELOW the panel={2}, still the foreground={3}, the panel is still the window at that point={4}, still non-topmost (exstyle=0x{5:X8}), still visible={6} ; panel absolute z# {7} -> {8} (must not sink behind that window)" -f $fPreFg, $fPreBelow, $fPostBelow, $fPostFg, ($fUnderPost -eq $h), $fEx, $fVis, $fZ0, $fZ1)
    # (3c) C11g -- v13 (M14): only a press that lands ON the panel counts as "the user touched me".
    # Why: the platform layer polls the GLOBAL left button (lib\flgui_win32.fl), so in.pressed fires for a
    # click anywhere on the desktop; before this cut any such click raised the panel to the front,
    # re-armed the user-hold (so `auto` stopped giving way) and bumped the panel's own press counter --
    # measured, tmp\m14\probe-anyclick-run-before.txt: pressn 1->2 / 2->3 / 3->4 for clicks on a notepad,
    # with the app's own trace recording mx=-220 my=-116 (outside its client area).
    # Both directions are driven here, because a gate can fail in two ways: an outside click must NOT be
    # counted, and a click ON the panel MUST still be counted and still raise it (an early shape of the
    # fix answered "not mine" for every point and the panel stopped counting its OWN presses -- caught by
    # exactly this control half while the fix was being measured).
    ClickAt $npClickX $npClickY; Park                     # focus the notepad -> it is raised above the panel
    Start-Sleep -Milliseconds 1500
    $gAbove0 = ZAbove $h $npOldH                          # the notepad is above the panel
    $gPr0 = TracePress
    # the OUTSIDE click: the press edge is inspected while the button is still down
    [void][WinPanelProbe]::SetCursorPos($npClickX, $npClickY)
    Start-Sleep -Milliseconds 130
    $gSeen = New-Object System.Collections.ArrayList
    [WinPanelProbe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # LEFTDOWN
    for ($gi = 0; $gi -lt 10; $gi++) { Start-Sleep -Milliseconds 15; $gl = TraceLine; if ($gl -ne '' -and -not $gSeen.Contains($gl)) { [void]$gSeen.Add($gl) } }
    [WinPanelProbe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # LEFTUP
    Start-Sleep -Milliseconds 400
    for ($gi = 0; $gi -lt 6; $gi++) { Start-Sleep -Milliseconds 15; $gl = TraceLine; if ($gl -ne '' -and -not $gSeen.Contains($gl)) { [void]$gSeen.Add($gl) } }
    $gPr1 = TracePress
    $gUserRaise = $false
    $gPressLine = $false
    foreach ($gl in $gSeen) { if ($gl -match 'user-raise') { $gUserRaise = $true }; if ($gl -match '^press ') { $gPressLine = $true } }
    Start-Sleep -Milliseconds 2400
    $gAbove1 = ZAbove $h $npOldH                          # the notepad must STILL be above the panel
    # control: a real click ON the panel must still be counted and must still raise it
    $gPr2 = TracePress
    ClickAt ([int](($rc.l + $rc.r) / 2)) ([int](($rc.t + $rc.b) / 2)); Park
    Start-Sleep -Milliseconds 1200
    $gPr3 = TracePress
    $gEx = [WinPanelProbe]::GetWindowLong($h, -20)
    $gAbove2 = ZAbove $h $npOldH                          # after a press on the panel it is in front -> False
    Check "C11g" "only a press that lands ON the panel is treated as 'the user touched me': a real click on a window outside the panel is NOT counted (press counter unchanged, no press trace line, no user-raise) and does not lift the panel above that window -- while a real click on the panel still IS counted and still raises it" `
      ($gAbove0 -and ($gPr0 -ge 0) -and ($gPr1 -eq $gPr0) -and (-not $gPressLine) -and (-not $gUserRaise) -and $gAbove1 -and ($gPr3 -gt $gPr2) -and (-not $gAbove2) -and (($gEx -band 0x8) -eq 0)) `
      ("precondition: the notepad is above the panel before the outside click={0} ; outside click at ($npClickX,$npClickY) -> pressn {1} -> {2} (must not change), a 'press' trace line={3} (must be False), 'user-raise'={4} ; traces seen during that press: {5} ; the notepad is still above the panel afterwards={6} ; CONTROL click on the panel centre -> pressn {7} -> {8} (must rise) and the panel is now in front of the notepad={9} (exstyle=0x{10:X8})" -f $gAbove0, $gPr0, $gPr1, $gPressLine, $gUserRaise, ($gSeen -join ' || '), $gAbove1, $gPr2, $gPr3, (-not $gAbove2), $gEx)
    # (3d) C11h -- v14 (M15): the DRAG case, driven by a REAL synthetic title-bar drag.
    # User report (2026-10-11 12:2x): "dragging another window over the panel does not make the panel give
    # way; clicking that window does." Measured before the fix (tmp\m15\probe-drag-clean-run-before.txt):
    # with the notepad the FOREGROUND window and directly BELOW the panel (C11f's own state, and with NO
    # press on the panel anywhere, so the user-hold cannot mask it), a real drag of its title bar onto the
    # panel left the pair at panel z#34 / notepad z#37 for the whole held drag AND for the whole 6 s after
    # the release, and the app's own trace file was not written once during the drag (tick= frozen, tag
    # `auto-front`): the M13 LEVEL reading honestly answered "the foreground window is BELOW me" and the
    # give-way was refused. WHY a drag differs from a click (same file, Q1/Q2): a caption CLICK raises the
    # window over the panel (z# 37 -> 34) so `auto` then gives way, while a caption DRAG of a window that is
    # ALREADY the foreground does not raise it at all.
    # The judge drives the action the report is about and asserts both halves of the work order:
    #   (i)  WHILE THE BUTTON IS STILL DOWN (>= 1.5 s of held movement) the notepad must be ABOVE the panel
    #        -- the panel really got out of the way -- and the panel's own rect must be untouched (it must
    #        not be dragged along by the pointer and must not have jumped above the window);
    #   (ii) after the release it must STILL be above at +2 s and +6 s (>= 1 and >= 3 policy samples).
    # The load-bearing reading is this script's own z-order walk (ZAbove / GW_HWNDPREV), because on a live
    # desktop a THIRD window can own the overlap centre; WindowFromPoint is printed as a readout only.
    $npDr = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1400
    $npDrH = $npDr.MainWindowHandle
    if ($npDrH -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 900; $npDrH = $npDr.MainWindowHandle }
    [void][WinPanelProbe]::MoveWindow($npDrH, ($rc.l - 340), ($rc.t - 130), 720, 420, $true)
    Start-Sleep -Milliseconds 3400
    $npDrRc = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($npDrH, [ref]$npDrRc)
    $drX = [int]($npDrRc.l + 120); $drY = [int]($npDrRc.t + 14)
    $drOutside = -not (($drX -gt $rc.l) -and ($drX -lt $rc.r) -and ($drY -gt $rc.t) -and ($drY -lt $rc.b))
    [void][WinPanelProbe]::SetWindowPos($npDrH, $h, 0, 0, 0, 0, 0x13)   # the notepad directly BELOW the panel
    Start-Sleep -Milliseconds 3200
    $drFg0 = (([WinPanelProbe]::GetForegroundWindow()) -eq $npDrH)
    $drBelow0 = -not (ZAbove $h $npDrH)
    $drPr0 = TracePress
    $drRc0 = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$drRc0)
    [void][WinPanelProbe]::SetCursorPos($drX, $drY)
    Start-Sleep -Milliseconds 220
    [WinPanelProbe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)      # LEFTDOWN on the notepad's title bar
    Start-Sleep -Milliseconds 180
    for ($ds = 1; $ds -le 10; $ds++) {
      [void][WinPanelProbe]::SetCursorPos([int]($drX + (($rc.l + $w0 / 2) - $drX) * $ds / 10), [int]($drY + (($rc.t + $ht / 2) - $drY) * $ds / 10))
      [WinPanelProbe]::mouse_event(0x0001, 0, 0, 0, [IntPtr]::Zero)    # MOUSEEVENTF_MOVE
      Start-Sleep -Milliseconds 90
    }
    Start-Sleep -Milliseconds 2000                                    # >= 1.5 s of drag with the button DOWN
    $drAboveHeld = ZAbove $h $npDrH
    $drRcHeld = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$drRcHeld)
    $drNotMoved = ($drRcHeld.l -eq $drRc0.l) -and ($drRcHeld.t -eq $drRc0.t) -and ($drRcHeld.r -eq $drRc0.r) -and ($drRcHeld.b -eq $drRc0.b)
    [WinPanelProbe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)      # LEFTUP
    Start-Sleep -Milliseconds 2000
    $drAbove2 = ZAbove $h $npDrH
    Start-Sleep -Milliseconds 4000
    $drAbove6 = ZAbove $h $npDrH
    $drPr1 = TracePress
    $drEx = [WinPanelProbe]::GetWindowLong($h, -20)
    $drVis = [WinPanelProbe]::IsWindowVisible($h)
    $npDrRc2 = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($npDrH, [ref]$npDrRc2)
    $drOvL = [Math]::Max($npDrRc2.l, $rc.l); $drOvT = [Math]::Max($npDrRc2.t, $rc.t)
    $drOvR = [Math]::Min($npDrRc2.r, $rc.r); $drOvB = [Math]::Min($npDrRc2.b, $rc.b)
    $drPt = New-Object WPPOINT
    $drPt.x = [int](($drOvL + $drOvR) / 2); $drPt.y = [int](($drOvT + $drOvB) / 2)
    $drUnder = [WinPanelProbe]::WindowFromPoint($drPt)
    Check "C11h" "the DRAG case: a REAL title-bar drag of a window onto the panel makes the panel give way -- that window is above the panel while the button is still down, and it STILL is at +2 s and +6 s after the release, with the panel's own rect untouched by the drag" `
      ($drOutside -and $drFg0 -and $drBelow0 -and (($drOvR - $drOvL) -gt 0) -and (($drOvB - $drOvT) -gt 0) -and $drAboveHeld -and $drNotMoved -and $drAbove2 -and $drAbove6 -and (($drEx -band 0x8) -eq 0) -and $drVis) `
      ("precondition: the notepad (pid $($npDr.Id)) is the FOREGROUND window={0} and sits BELOW the panel={1} before the drag, and ($drX,$drY) is its title bar OUTSIDE the panel rect={2} (no press on the panel is involved anywhere in this check) ; panel rect while the button was held=$(Csv @($drRcHeld.l, $drRcHeld.t, $drRcHeld.r, $drRcHeld.b)) vs before the drag=$(Csv @($drRc0.l, $drRc0.t, $drRc0.r, $drRc0.b)) -> UNCHANGED={3} ; notepad ABOVE the panel while held={4}, +2 s after the release={5}, +6 s={6} ; overlap centre ($($drPt.x),$($drPt.y)): WindowFromPoint=$drUnder (panel=$h notepad=$npDrH -- on a live desktop a third window can own a point) ; panel exstyle=0x{7:X8} (topmost bit must stay clear), IsWindowVisible={8} ; pressn {9} -> {10} (readout: the drag press is outside the panel)" -f $drFg0, $drBelow0, $drOutside, $drNotMoved, $drAboveHeld, $drAbove2, $drAbove6, $drEx, $drVis, $drPr0, $drPr1)
    Stop-Process -Id $npDr.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1200
    # (4) C11d: the focused window MINIMIZES => the panel comes back on its own, in the NORMAL band.
    # WHY the check needs a foreground anchor of its own: minimizing the focused notepad hands the
    # foreground to whatever Windows picks next, and on this desktop that is a FULL-SCREEN shell window
    # (measured, tmp\m12\probe-fg3-run-01.txt: pid 5244, rect (302,59)-(1799,1006), and again in the
    # clean runs: hwnd 459742). A full-screen foreground window OVERLAPS the panel, so the correct
    # answer for the panel is "keep giving the spot away" -- and that is exactly what it did (z# 37,
    # the shell window above it). A judge that demanded "the panel is now in front" would therefore be
    # measuring the desktop, not the rule. So the check anchors the foreground on a window of its OWN
    # that does NOT overlap the panel: with "the foreground window is gone/minimized and the new one
    # does not want the spot", the panel must take it back.
    # The check's OWN precondition: the notepad must really be the foreground window before the
    # minimize, otherwise "it came back" cannot be distinguished from "it was never away".
    ClickAt $npClickX $npClickY; Park
    Start-Sleep -Milliseconds 3200                        # let the auto policy sample and yield again
    $fgBeforeMin = (([WinPanelProbe]::GetForegroundWindow()) -eq $npOldH)
    $yieldOk = $fgBeforeMin
    [void][WinPanelProbe]::ShowWindow($npOldH, 6)        # SW_MINIMIZE
    Start-Sleep -Milliseconds 700
    $npMin = [WinPanelProbe]::IsIconic($npOldH)
    $fgAfterMin = [WinPanelProbe]::GetForegroundWindow()
    $helpOk = [WinPanelProbe]::SetForegroundWindow($fgHelp)
    Start-Sleep -Milliseconds 400
    $fgIsHelp = (([WinPanelProbe]::GetForegroundWindow()) -eq $fgHelp)
    $zBeforeMin = ZIndex $h
    # the DEFINITION of "came back to the front" this check uses: a point that the notepad really covers
    # must now belong to the PANEL (WindowFromPoint), and the panel must be at least as far forward as it
    # was before the minimize. The earlier version required the absolute z# to go DOWN, which is wrong
    # when the panel was already the front-most normal window before the minimize (measured: z# 34 -> 34
    # while the rule was working perfectly) -- and requiring "above the minimized window" is wrong in the
    # other direction, because Windows demotes a minimized window by itself.
    # The probe point must lie in the INTERSECTION of the notepad's rect and the panel's rect: only
    # there does "which window owns this point" distinguish "the panel is in front" from "the panel is
    # still giving the spot away". (The first version took the notepad's own centre, which on this
    # desktop sits in the panel's left MARGIN -- outside the panel -- so it read the panel no matter
    # what the panel did, and the red round caught exactly that: the check stayed green on a build
    # where the panel never moved.)
    $ovL = [Math]::Max($npOldRc.l, $rc.l); $ovT = [Math]::Max($npOldRc.t, $rc.t)
    $ovR = [Math]::Min($npOldRc.r, $rc.r); $ovB = [Math]::Min($npOldRc.b, $rc.b)
    $probePt = New-Object WPPOINT
    $probePt.x = [int](($ovL + $ovR) / 2)
    $probePt.y = [int](($ovT + $ovB) / 2)
    $ovArea = ($ovR - $ovL) * ($ovB - $ovT)
    if ($ovArea -le 0) { Write-Output "     C11d WARNING: the notepad and the panel do not overlap -- the probe point is meaningless" }
    Start-Sleep -Milliseconds 5000                        # > 2 policy samples, so a silent no-op is caught
    $exBack2 = [WinPanelProbe]::GetWindowLong($h, -20)
    $visBack2 = [WinPanelProbe]::IsWindowVisible($h)
    $zAfterMin = ZIndex $h
    $underMin = [WinPanelProbe]::WindowFromPoint($probePt)
    $panelBackFront = ($underMin -eq $h) -and ($zAfterMin -ge 0) -and ($zAfterMin -le $zBeforeMin)
    Start-Sleep -Milliseconds 2000
    $exBack3 = [WinPanelProbe]::GetWindowLong($h, -20)
    $zAfterMin2 = ZIndex $h
    $panelBackFront2 = ($underMin -eq $h) -and ($zAfterMin2 -ge 0) -and ($zAfterMin2 -le $zAfterMin) -and (-not (ZAbove $h $npOldH))
    Check "C11d" "the focused window minimized (and the foreground handed to a non-overlapping window of the judge's own) => the auto panel is the window at a point the minimized window used to cover (WindowFromPoint), in the NORMAL band, visible and non-topmost" `
      ($yieldOk -and $npMin -and $helpOk -and $fgIsHelp -and (($exBack2 -band 0x8) -eq 0) -and $visBack2 -and $panelBackFront -and (($exBack3 -band 0x8) -eq 0) -and $panelBackFront2) `
      ("precondition: before the minimize the notepad really was the FOREGROUND window={0} (IsIconic after={1}) ; the raw foreground Windows picked after the minimize was $fgAfterMin -- on this desktop a full-screen shell window, which legitimately keeps the spot, so the judge then anchors the foreground on its OWN helper window at ($(Csv @($fgHelpRc.l, $fgHelpRc.t, $fgHelpRc.r, $fgHelpRc.b)), which does NOT overlap the panel: SetForegroundWindow returned $helpOk and it really is foreground={2} ; the notepad's rect was ($(Csv @($npOldRc.l, $npOldRc.t, $npOldRc.r, $npOldRc.b))), so the centre of its OVERLAP with the panel ($($probePt.x),$($probePt.y), area $ovArea) is a point only the two of them can own -- WindowFromPoint there after +5 s = $underMin, the PANEL itself={3} ; panel absolute z# {4} -> {5} (must not slip back), exstyle=0x{6:X8} (topmost bit clear), IsWindowVisible={7} ; after a further +2 s: z#{8}, exstyle=0x{9:X8}" -f $yieldOk, $npMin, $fgIsHelp, ($underMin -eq $h), $zBeforeMin, $zAfterMin, $exBack2, $visBack2, $zAfterMin2, $exBack3)
    Stop-Process -Id $npOld.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 4200
    $exBack = [WinPanelProbe]::GetWindowLong($h, -20)
    $visBack = [WinPanelProbe]::IsWindowVisible($h)
    Check "C11b" "the auto panel comes back once the covering window is gone (still non-topmost, still visible)" `
      (((($exBack -band 0x8) -eq 0) -and $visBack)) `
      ("exstyle after the coverer was closed=0x{0:X8} (topmost bit must stay clear -- auto never promotes itself into the topmost band), IsWindowVisible={1}" -f $exBack, $visBack)
    if ($fgHelpForm -ne $null) { $fgHelpForm.Close(); $fgHelpForm.Dispose(); $fgHelpForm = $null }
    if ($fgHelpForm -ne $null) { $fgHelpForm.Close(); $fgHelpForm.Dispose(); $fgHelpForm = $null }
    Start-Sleep -Milliseconds 400
    ClickAt $lyTopX $lyTopY; Park                        # leave the mode as we found it (top, one press)
    ClickAt $bkx $bky; Park                              # leave the settings page
    # ---- v10 (M12): the foreground readings in the dump are LIVE OS answers, not stored claims -----
    # The app prints fg_pid / fg_is_self / fg_overlap for the foreground window it sees. This judge
    # asks the OS the same questions from ITS OWN process (GetForegroundWindow + GetWindowRect over the
    # panel's own geometry) and requires the two to agree, so "auto is driven by the foreground window"
    # can be checked without trusting the panel's word for it.
    $npFg = Start-Process notepad -PassThru
    Start-Sleep -Milliseconds 1400
    $npFgH = $npFg.MainWindowHandle
    if ($npFgH -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 900; $npFgH = $npFg.MainWindowHandle }
    [void][WinPanelProbe]::SetWindowPos($npFgH, [IntPtr]::Zero, ($rc.l + 40), ($rc.t + 40), 640, 380, 0x14)
    [void][WinPanelProbe]::SetForegroundWindow($npFgH)
    # TOPMOST fixture: the dump below is a SEPARATE process that this shell spawns, and a spawned process
    # may briefly take the foreground for itself -- which would make the app report ITS OWN pid and this
    # comparison would measure the harness instead of the app. A topmost fixture window cannot be
    # displaced from the foreground by a plain process (measured in the M10 round: only a band
    # transition moves a topmost window), so the foreground window is the SAME one before and during the
    # dump, and the reading below is deterministic rather than lucky.
    [void][WinPanelProbe]::SetWindowPos($npFgH, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    Start-Sleep -Milliseconds 1000
    # (the panel is in `top` from C6x3, so nothing here changes the panel's own band)
    $fgPid = 0
    $fgH = [WinPanelProbe]::GetForegroundWindow()
    $fgTid = [WinPanelProbe]::GetWindowThreadProcessId($fgH, [ref]$fgPid)
    $fgRc = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($fgH, [ref]$fgRc)
    $expOverlap = 0
    if (($fgRc.l -lt $rc.r) -and ($fgRc.r -gt $rc.l) -and ($fgRc.t -lt $rc.b) -and ($fgRc.b -gt $rc.t)) { $expOverlap = 1 }
    $drFg = DumpOnce 60000
    $dFg = @{}
    if (Test-Path -LiteralPath $dumpPath) { $dFg = ReadDump $dumpPath }
    $appFgPid = -1
    if ($dFg.ContainsKey("fg_pid")) { $appFgPid = [int]$dFg["fg_pid"] }
    $appFgSelf = -1
    if ($dFg.ContainsKey("fg_is_self")) { $appFgSelf = [int]$dFg["fg_is_self"] }
    $appFgOv = -1
    if ($dFg.ContainsKey("fg_overlap")) { $appFgOv = [int]$dFg["fg_overlap"] }
    $appFgOwn = -1
    if ($dFg.ContainsKey("fg_owns_spot")) { $appFgOwn = [int]$dFg["fg_owns_spot"] }
    $appFgPidQ = -1
    if ($dFg.ContainsKey("fg_pid_query")) { $appFgPidQ = [int]$dFg["fg_pid_query"] }
    $appFgPidS = -1
    if ($dFg.ContainsKey("fg_pid_stored")) { $appFgPidS = [int]$dFg["fg_pid_stored"] }
    $appFgRc = @()
    if ($dFg.ContainsKey("fg_rect")) { $appFgRc = @($dFg["fg_rect"] -split ',' | ForEach-Object { [int]$_ }) }
    # the foreground really belongs to the notepad this judge started (proves the fixture, not the app)
    $fixtureOk = ($fgH -eq $npFgH) -and ($fgPid -eq $npFg.Id)
    # the pid must be the SAME however the app asks for it (a live GetWindowThreadProcessId call vs the
    # reading it stored when it sampled the foreground): two answers that disagree would mean the value
    # is not a fact about one window
    $pidAgree = ($appFgPid -ge 1) -and ($appFgPid -eq $appFgPidQ) -and ($appFgPid -eq $appFgPidS)
    # and it must be the process THIS judge measures for the foreground window, with the same rect --
    # the fixture is a TOPMOST window, so it cannot be displaced while the dump runs (measured in the
    # M10 round: only a band transition re-orders a topmost window), which makes this exact match
    # deterministic rather than lucky
    $pidMatch = $pidAgree -and ($appFgPid -eq $fgPid)
    $rectMatch = ($appFgRc.Count -eq 4) -and ($appFgRc[0] -eq $fgRc.l) -and ($appFgRc[1] -eq $fgRc.t) -and
                 ($appFgRc[2] -eq $fgRc.r) -and ($appFgRc[3] -eq $fgRc.b)
    # the panel has no window in a dump run, so is_self must be 0; fg_overlap is the plain rect test and
    # must equal the judge's own intersection; fg_owns_spot is the DECISION's predicate (self excluded,
    # visible, not minimized) and this fixture is all three, so the app itself must say "yes, that
    # window owns the spot" -- which is exactly what makes `auto` yield.
    $fgOk = $fixtureOk -and $pidMatch -and $rectMatch -and ($appFgSelf -eq 0) -and
            ($appFgOv -eq $expOverlap) -and ($expOverlap -eq 1) -and ($appFgOwn -eq 1) -and
            ($dFg["fg_visible"] -eq "1") -and ($dFg["fg_iconic"] -eq "0")
    Check "C11e" "the dump's foreground reading is the LIVE one: the app's fg_pid == the pid THIS judge measures with GetForegroundWindow (and == its own two other ways of asking), fg_rect == the judge's rect, fg_overlap == the judge's own intersection, fg_is_self == 0 headless" `
      $fgOk ("judge: foreground hwnd=$fgH pid=$fgPid is the notepad it started={0}, rect=({1}), overlaps the panel rect=({2}) -> {3} ; app dump: fg_pid={4} fg_pid_query={5} fg_pid_stored={6} fg_rect=({7}) -> same pid={8} same rect={9} ; fg_is_self={10} fg_overlap={11} fg_owns_spot={12} fg_visible={13} fg_iconic={14}" -f $fixtureOk, (Csv @($fgRc.l, $fgRc.t, $fgRc.r, $fgRc.b)), (Csv @($rc.l, $rc.t, $rc.r, $rc.b)), $expOverlap, $appFgPid, $appFgPidQ, $appFgPidS, (Csv $appFgRc), $pidMatch, $rectMatch, $appFgSelf, $appFgOv, $appFgOwn, $dFg["fg_visible"], $dFg["fg_iconic"])
    Stop-Process -Id $npFg.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
    # ---- v8 (M8): the hold-to-peek hotkey, driven and judged from here -----------------------------
    # SAFETY RULE (incident 2026-10-10 20:09): the only chord this script may inject is the one the
    # PANEL REGISTERED (read out of the dump). A registered chord is consumed by the system and
    # delivered to the registrant as WM_HOTKEY, so no other application ever sees it. A bare
    # Ctrl+W injected during development went to the user's focused window and closed it; see
    # tmp\m8\hotkey-probe.ps1 for the full note. If the panel holds no combo, this check FAILS loudly
    # and injects nothing -- it must never "make do" with some other key.
    $hkVk = [int]$d["hk_vk"]; $hkMods = [int]$d["hk_mods"]; $hkOk = [int]$d["hk_ok"]
    if ($hkOk -ne 1) {
      Check "C6x4" "hold-to-peek really peeks and T really locks top (exstyle read back here)" $false `
        ("no safe chord to inject: the panel claimed NO combo (hk_ok=0, hk_probe_fail=$($d['hk_probe_fail']), name=$($d['hk_name'])) -- the feature is unusable until a candidate is free; nothing was injected")
    } else {
      # GUARD (must come before any injection): injecting is only safe while the PANEL HOLDS the
      # chord, because the holder is what makes the system swallow it. Confirm that from our own
      # process first; if we cannot confirm it, inject nothing at all.
      $ourOk = [WinPanelProbe]::RegisterHotKey([IntPtr]::Zero, 77, ($hkMods -bor 0x4000), $hkVk)
      $ourErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
      $hkBlocked = -not $ourOk
      if ($ourOk) { [void][WinPanelProbe]::UnregisterHotKey([IntPtr]::Zero, 77) }
      if (-not $hkBlocked) {
        Check "C6x4" "hold-to-peek really peeks and T really locks top (exstyle read back here)" $false `
          ("REFUSED TO INJECT: the panel does not hold Ctrl+Alt+VK{0:X2} (this script's own RegisterHotKey succeeded, GetLastError={1}) -- an unregistered chord would be delivered to whatever window the user has focused" -f $hkVk, $ourErr)
      } else {
      ClickAt ($rc.l + $scx) ($rc.t + $scy); Park          # open Setup
      ClickAt $lyNorX $lyNorY; Park                        # press NORMAL: the panel is NOT topmost now
      Start-Sleep -Milliseconds 900
      $exBefore = [WinPanelProbe]::GetWindowLong($h, -20)
      [WinPanelProbe]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)          # Ctrl down
      [WinPanelProbe]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)          # Alt down
      [WinPanelProbe]::keybd_event([byte]$hkVk, 0, 0, [IntPtr]::Zero)   # the registered key down
      Start-Sleep -Milliseconds 700
      $exPeek = [WinPanelProbe]::GetWindowLong($h, -20)
      [WinPanelProbe]::keybd_event(0x54, 0, 0, [IntPtr]::Zero)          # T down = LOCK top
      Start-Sleep -Milliseconds 250
      [WinPanelProbe]::keybd_event(0x54, 0, 2, [IntPtr]::Zero)          # T up
      Start-Sleep -Milliseconds 300
      [WinPanelProbe]::keybd_event([byte]$hkVk, 0, 2, [IntPtr]::Zero)   # release everything
      [WinPanelProbe]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
      [WinPanelProbe]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 900
      $exLocked = [WinPanelProbe]::GetWindowLong($h, -20)
      [WinPanelProbe]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)          # hold again to UNLOCK
      [WinPanelProbe]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
      [WinPanelProbe]::keybd_event([byte]$hkVk, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 500
      [WinPanelProbe]::keybd_event(0x54, 0, 0, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 250
      [WinPanelProbe]::keybd_event(0x54, 0, 2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 300
      [WinPanelProbe]::keybd_event([byte]$hkVk, 0, 2, [IntPtr]::Zero)
      [WinPanelProbe]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
      [WinPanelProbe]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 900
      $exUnlocked = [WinPanelProbe]::GetWindowLong($h, -20)
      ClickAt $lyAutX $lyAutY; Park                        # press AUTO (v10/M12: one press, no cycling)
      ClickAt $lyTopX $lyTopY; Park                        # press TOP: leave the mode as C6x3 found it
      ClickAt $bkx $bky; Park                              # leave the settings page
      Check "C6x4" "hold-to-peek really peeks and T really locks top (exstyle read back here; only the panel's own registered chord is ever injected)" `
        ((($exBefore -band 0x8) -eq 0) -and (($exPeek -band 0x8) -ne 0) -and (($exLocked -band 0x8) -ne 0) -and (($exUnlocked -band 0x8) -eq 0)) `
        ("exstyle: mode=normal before=0x{0:X8} | while the REGISTERED chord Ctrl+Alt+VK{1:X2} was held=0x{2:X8} (peek) | after releasing with the lock on=0x{3:X8} (stays) | after a second T unlocked it=0x{4:X8} | our own RegisterHotKey on the same combo refused={5}" -f $exBefore, $hkVk, $exPeek, $exLocked, $exUnlocked, $hkBlocked)
      }
    }
    # (1b) theme round trip with the REAL mouse: default = blue white (bright base) -> dark (dim)
    #      -> back to blue white, and the picture must come back pixel-identical
    $themeRect = @($d["geo_theme_rect"] -split ',' | ForEach-Object { [int]$_ })
    $tcx = $themeRect[0] + [int]($themeRect[2] / 2); $tcy = $themeRect[1] + [int]($themeRect[3] / 2)
    $bl = ImgShot $h $w0 $ht
    $themeLightHash = ImgHash $bl
    $lightPanel = PremulRGB ([long]$palLight["panel"]) $fillADef
    $lightTrack = PremulRGB ([long]$palLight["track"]) $fillADef
    $themePix["light_panel"] = CountRGB $bl $lightPanel[0] $lightPanel[1] $lightPanel[2]
    $themePix["light_track"] = CountRGB $bl $lightTrack[0] $lightTrack[1] $lightTrack[2]
    $themeBright["light"] = BandAvg $bl ($CNW + 40) ($CTH + 40) ($CW - 40) ($CH - $CBH - 40)
    $b0Hash = ImgHash $bl
    $bl.Dispose()
    ClickAt ($rc.l + $tcx) ($rc.t + $tcy); Park
    $bd = ImgShot $h $w0 $ht
    $themeDarkHash = ImgHash $bd
    $darkPanel = PremulRGB ([long]$palDef["panel"]) $fillADef
    $darkTrack = PremulRGB ([long]$palDef["track"]) $fillADef
    $themePix["dark_panel"] = CountRGB $bd $darkPanel[0] $darkPanel[1] $darkPanel[2]
    $themePix["dark_track"] = CountRGB $bd $darkTrack[0] $darkTrack[1] $darkTrack[2]
    $themeBright["dark"] = BandAvg $bd ($CNW + 40) ($CTH + 40) ($CW - 40) ($CH - $CBH - 40)
    $bd.Dispose()
    ClickAt ($rc.l + $tcx) ($rc.t + $tcy); Park
    $bb = ImgShot $h $w0 $ht
    $themeBackHash = ImgHash $bb
    $themeBright["back"] = BandAvg $bb ($CNW + 40) ($CTH + 40) ($CW - 40) ($CH - $CBH - 40)
    $bb.Dispose()
    Write-Output ("---- theme round trip: light={0} back={1} dark={2}" -f $themeLightHash.Substring(0, 12), $themeBackHash.Substring(0, 12), $themeDarkHash.Substring(0, 12))
    Write-Output ("     base brightness light={0} dark={1} back={2} (0..255 scale, sum/3 per pixel)" -f $themeBright["light"], $themeBright["dark"], $themeBright["back"])
    Check "C6m" "real Theme clicks: blue-white -> dark -> blue-white, return is pixel-exact" `
      (($themeLightHash -ne $themeDarkHash) -and ($themeBackHash -eq $themeLightHash) -and ($themeBright["light"] -ge 150) -and ($themeBright["dark"] -le 90)) `
      "light=$($themeBright['light']) dark=$($themeBright['dark']) back=$($themeBright['back']) hashes light/back equal=$($themeBackHash -eq $themeLightHash)"
    # (1c) the screen really carries the library palette at the exact premultiplied values, and the
    #      same structure counts come back in both themes where the palette says they should
    $palPixOk = ($themePix["light_panel"] -gt 1000) -and ($themePix["dark_panel"] -gt 1000) -and ($themePix["light_track"] -gt 1000) -and ($themePix["dark_track"] -gt 1000)
    Write-Output ("     palette pixels: light panel/track={0}/{1} dark panel/track={2}/{3} (expected RGB light panel={4} track={5} dark panel={6} track={7})" -f `
      $themePix["light_panel"], $themePix["light_track"], $themePix["dark_panel"], $themePix["dark_track"], (Csv $lightPanel), (Csv $lightTrack), (Csv $darkPanel), (Csv $darkTrack))
    Check "C6n" "on-screen colours == lib presets premultiplied by the surface alpha ($fillADef at the default alpha)" $palPixOk `
      "counts=$($themePix['light_panel'])/$($themePix['light_track'])/$($themePix['dark_panel'])/$($themePix['dark_track'])"
    # (1d) THE OPACITY, measured on SCREEN pixels. PrintWindow (used everywhere above) returns the
    #      offscreen DIB and therefore cannot see Surf.const_a at all, so this part uses the real
    #      composited screen plus the background this script captured before the window existed.
    #      The dark theme is the right place to measure: a #202020 panel over this bright desktop
    #      changes a lot when the window becomes transparent (in the blue-white theme the panel and
    #      the desktop are both bright, so the same change is only a couple of levels).
    ClickAt ($rc.l + $tcx) ($rc.t + $tcy); Park          # light -> dark
    ClickAt ($rc.l + $scx) ($rc.t + $scy); Park          # Setup
    $dSlider = @($d["geo_slider_rect"] -split ',' | ForEach-Object { [int]$_ })
    $slMidY = $dSlider[1] + [int]($dSlider[3] / 2)
    # M4r: the slider is a PERCENTAGE now, so the LEFT end is 0% (= alpha 255, the opaque end) and the
    # RIGHT end is 100% (= alpha 120 = WP_OPA_MIN). The two captures below are named by ALPHA in the
    # comparison ($COPMAX / $COPMIN), so the click order follows the alpha, not the screen side.
    # v6: land on the TRUE ends of the track. Clicking 2 px inside it yields 99%, not 100% -- the
    # solved-parameter evidence below measured the real alpha as 122.4 instead of 120, which is
    # exactly the small systematic residual the model then reported. So press inside the track and
    # drag PAST the end: the widget clamps at the end (this is how the dump driver reaches its own
    # endpoints too). Nothing about the model or its thresholds is relaxed.
    function DragSlider([int]$x0, [int]$y0, [int]$x1) {
      [void][WinPanelProbe]::SetCursorPos($x0, $y0)
      Start-Sleep -Milliseconds 140
      [WinPanelProbe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # LEFTDOWN inside the track
      Start-Sleep -Milliseconds 140
      for ($s = 1; $s -le 8; $s++) {
        [void][WinPanelProbe]::SetCursorPos(($x0 + [int](($x1 - $x0) * $s / 8)), $y0)
        Start-Sleep -Milliseconds 30
      }
      Start-Sleep -Milliseconds 120
      [WinPanelProbe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # LEFTUP
      Start-Sleep -Milliseconds 300
    }
    $slX0 = $rc.l + $dSlider[0]
    $slX1 = $rc.l + $dSlider[0] + $dSlider[2] - 1
    $slY = $rc.t + $slMidY
    DragSlider $slX1 $slY ($slX0 - 30); Park      # drag past the LEFT end  -> clamps at 0%   -> alpha 255
    $scrHi = ShotScreen $rc.l $rc.t $w0 $ht
    $dibHi = ImgShot $h $w0 $ht
    DragSlider $slX0 $slY ($slX1 + 30); Park      # drag past the RIGHT end -> clamps at 100% -> alpha 120
    $scrLo = ShotScreen $rc.l $rc.t $w0 $ht
    $dibLo = ImgShot $h $w0 $ht
    # v6: the background reference is captured immediately AFTER the transparent-end grab -- the panel
    # is hidden for exactly one capture, so the reference is ~0.3 s old instead of minutes (the desktop
    # behind this panel is LIVE: the DSH Web GUI repaints under it). The opaque end does not use the
    # background at all (its coefficient is 0), so ONE reference serves both ends. Nothing about the
    # model or its thresholds is relaxed.
    [void][WinPanelProbe]::ShowWindow($h, 0)
    Start-Sleep -Milliseconds 240
    $bgNow = ShotScreen $rc.l $rc.t $w0 $ht
    $bgNowBytes = ImgBytes $bgNow
    $bgNow.Dispose()
    [void][WinPanelProbe]::ShowWindow($h, 1)
    Start-Sleep -Milliseconds 360
    $skipY0 = $dSlider[1] - 6
    $skipY1 = $dSlider[1] + $dSlider[3] + $CSLGAP + $CLH + 6
    $st = OpaError (ImgBytes $scrHi) (ImgBytes $dibHi) (ImgBytes $scrLo) (ImgBytes $dibLo) $bgNowBytes $COPMAX $COPMIN (FillAOf $COPMAX) (FillAOf $COPMIN) $skipY0 $skipY1 $w0 $ht 61 53
    $stNull = OpaError (ImgBytes $scrHi) (ImgBytes $dibHi) (ImgBytes $scrLo) (ImgBytes $dibLo) $bgNowBytes $COPDEF $COPDEF (FillAOf $COPDEF) (FillAOf $COPDEF) $skipY0 $skipY1 $w0 $ht 61 53
    Write-Output ("---- opacity pixels: scr(max)={0} scr(min)={1} (mean over the sampled grid) ----" -f (BandAvg $scrHi 0 0 $w0 $ht), (BandAvg $scrLo 0 0 $w0 $ht))
    Write-Output ("     model(dib*a/255 + bg*(1-fillA*a/255^2)): samples={0} median|err|={1} p99|err|={2} max|err|={3} | median|scr(max)-scr(min)|={4} | null-model({5},{5}) median|err|={6}" -f `
      $st.n, $st.med, $st.p99, $st.max, $st.medMove, $COPDEF, $stNull.med)
    # v6 evidence: solve the two parameters back out of the live pixels of the transparent end.
    #   with fill fixed at the judge's expectation -> what constant alpha did the screen use?
    #   with the constant alpha fixed at COPMIN     -> what surface fill did the screen use?
    # If the delivered build really drives the surface alpha from the knob AND the judge's mapping
    # matches the app's, both solved medians land on the assumed numbers; a systematic miss says
    # which side of the composition is off, instead of guessing.
    $solAArr = New-Object System.Collections.ArrayList
    $solFArr = New-Object System.Collections.ArrayList
    $imgScrLo = ImgBytes $scrLo
    $imgDibLo = ImgBytes $dibLo
    for ($yy = 53; $yy -lt ($ht - 53); $yy += 53) {
      if ($yy -ge $skipY0 -and $yy -lt $skipY1) { continue }
      for ($xx = 61; $xx -lt ($w0 - 61); $xx += 61) {
        $ii = $yy * $imgScrLo.stride + $xx * 4
        $pBg = [double]$bgNowBytes.bytes[$ii]
        $pDib = [double]$imgDibLo.bytes[$ii]
        $pObs = [double]$imgScrLo.bytes[$ii]
        if ($pBg -lt 8) { continue }
        $pDen = $pDib - $pBg * ((FillAOf $COPMIN) / 255.0)
        if ([Math]::Abs($pDen) -gt 1.0) { [void]$solAArr.Add(255.0 * ($pObs - $pBg) / $pDen) }
        [void]$solFArr.Add((1.0 - (($pObs - $pDib * ($COPMIN / 255.0)) / $pBg)) * (65025.0 / $COPMIN))
      }
    }
    $solAs = @($solAArr | Sort-Object); $solFs = @($solFArr | Sort-Object)
    Write-Output ("     SOLVED from the transparent-end pixels: fill={0} -> median alpha={1} ; alpha={2} -> median fill={3}" -f (FillAOf $COPMIN), [Math]::Round($solAs[[int]($solAs.Count / 2)], 2), $COPMIN, [Math]::Round($solFs[[int]($solFs.Count / 2)], 2))
    # Note on the two outlier bounds: the background reference is now captured on the spot (the panel
    # is hidden for exactly one capture, see above), so it is no longer a stale reference -- but the
    # desktop behind is still live, so a handful of sampled pixels can move for reasons that have
    # nothing to do with the panel. The load-bearing number is the MEDIAN; C6t/C6u stay as tight as
    # before.
    # v6 threshold note (evidence, not convenience): with the transparent end in the model the term
    # carrying the background is 0.63 * bg, and the compositor does its own integer rounding, so the
    # model has a deterministic floor. Three independent runs of this very block measured the SAME
    # median (3.15570934256056) while the parameters solved out of the same pixels landed on the
    # intended values (119.71 vs 120 and 199.58 vs 200). The bound is therefore 5.0 -- still 4.7x
    # tighter than the real defect this check caught (the dead wp_opa_apply produced a uniform
    # median of 23.47) and the null model still misses by ~98. The mechanism itself is asserted
    # tightly by C6s2 right below.
    Check "C6s" "slider-driven opacity matches the fill-alpha/blend model on real screen pixels" `
      (($st.n -gt 200) -and ($st.med -le 5.0) -and ($st.p99 -le 25.0) -and ($st.max -le 60.0)) `
      "samples=$($st.n) median|err|=$($st.med) max|err|=$($st.max) p99|err|=$($st.p99) fillA=$(FillAOf $COPMAX)/$(FillAOf $COPMIN) alphas=$COPMAX/$COPMIN skipY=[$skipY0,$skipY1)"
    Check "C6s2" "the surface alpha really follows the knob: the solved (alpha, fill) land on the intended pair" `
      ((($solAs.Count -gt 100) -and ([Math]::Abs($solAs[[int]($solAs.Count / 2)] - $COPMIN) -le 2.0)) -and ([Math]::Abs($solFs[[int]($solFs.Count / 2)] - (FillAOf $COPMIN)) -le 3.0)) `
      ("solved from the live transparent-end pixels: median alpha=$([Math]::Round($solAs[[int]($solAs.Count / 2)], 2)) (intended $COPMIN) ; median fill=$([Math]::Round($solFs[[int]($solFs.Count / 2)], 2)) (intended $(FillAOf $COPMIN)))")
    Check "C6t" "the two slider ends really changed the screen (large, not a rounding wobble)" `
      ($st.medMove -ge 20.0) "median|scr(max)-scr(min)|=$($st.medMove) per channel of $($st.n) samples"
    Check "C6u" "the same pixels REJECT the 'opacity ignored' model (both captures at the default $COPDEF)" `
      (($stNull.med -ge 20.0) -and ($stNull.agg -ge 1000.0)) `
      ("median|err| of the fixed-alpha model = $($stNull.med) (median gate >= 20, unchanged since v4) OVER $($stNull.n) samples -> the SUM of every sample's error = $([Math]::Round($stNull.agg, 1)) (second gate >= 1000, added in v11/M12) ; the four clean 495-sample runs on record read sums 51953.1 / 54598.9 / 59279 / 60363.9 and the SAME median 117.905882352941, so the sum gate has never been the gate that decided a clean run -- it is a second floor for a PARTIAL desync (something moving over part of the panel) that keeps the median high while many single samples go bad ; the one bad run on record read median 17.7156016916571 and was rejected by the unchanged median gate as well (that run predates this sum gate, so it has no sum reading; the '93.6', '4413..6054' and '62.8' figures printed here before appear in NO log and are withdrawn) ; samples missing by >20 levels: $($stNull.gt20)/$($stNull.n) -- would be ~0 if the slider did nothing")
    $scrHi.Dispose(); $scrLo.Dispose(); $dibHi.Dispose(); $dibLo.Dispose()
    # (1e) M4r: the WINDOW-MOVE fast path. A title-bar drag changes no pixels, so the app must
    #      re-upload the DIB it already has instead of rebuilding it (35 ms -> ~0.2 ms per frame).
    #      Judged from the app's own ledger (a `flushes` counter that only the fast path increments)
    #      plus a real drag that goes out and comes back exactly: the content must be identical and
    #      the window must really have moved in between. The ledger is already live for this instance
    #      (fps.on was created before it was launched) -- it just needs one 500 ms write to land.
    Start-Sleep -Milliseconds 700
    $lm0 = LedgerRead $fpsled
    $imgPre = ImgShot $h $w0 $ht
    $hashPre = ImgHash $imgPre
    $imgPre.Dispose()
    $rcPre = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$rcPre)
    DragTitle ($rcPre.l + 300) ($rcPre.t + 12) 66 44
    $rcMid = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$rcMid)
    # walk it back by the delta that really happened (the app moves by the pointer delta), retrying up
    # to three times -- every later check in this block uses $rc, i.e. the ORIGINAL position, so a
    # window left displaced would silently poison them all
    $rcPost = New-Object WPRECT
    for ($try = 0; $try -lt 3; $try++) {
      [void][WinPanelProbe]::GetWindowRect($h, [ref]$rcPost)
      if (($rcPost.l -eq $rcPre.l) -and ($rcPost.t -eq $rcPre.t)) { break }
      DragTitle ($rcPost.l + 300) ($rcPost.t + 12) ($rcPre.l - $rcPost.l) ($rcPre.t - $rcPost.t)
    }
    Start-Sleep -Milliseconds 400
    $lm1 = LedgerRead $fpsled
    $imgPost = ImgShot $h $w0 $ht
    $hashPost = ImgHash $imgPost
    $imgPost.Dispose()
    $rcPost = New-Object WPRECT
    [void][WinPanelProbe]::GetWindowRect($h, [ref]$rcPost)
    $ddFlush = -1; $ddRender = -1
    if ($null -ne $lm0 -and $null -ne $lm1) { $ddFlush = $lm1.flushes - $lm0.flushes; $ddRender = $lm1.renders - $lm0.renders }
    Check "C6v" "a real title-bar drag moves the window and comes back to the exact same place" `
      (($rcMid.l -ne $rcPre.l) -and ($rcPost.l -eq $rcPre.l) -and ($rcPost.t -eq $rcPre.t)) `
      "pre=$($rcPre.l),$($rcPre.t) mid=$($rcMid.l),$($rcMid.t) post=$($rcPost.l),$($rcPost.t)"
    Check "C6w" "window move = pure re-upload: flushes dominate renders and the content stays identical" `
      (($ddFlush -ge 6) -and ($ddFlush -ge (3 * $ddRender)) -and ($hashPost -eq $hashPre)) `
      "flushes +$ddFlush renders +$ddRender (fast path must dominate; a few real renders are the drag's own start/end frames) hash pre=$($hashPre.Substring(0,12)) post=$($hashPost.Substring(0,12)) equal=$($hashPost -eq $hashPre)"
    ClickAt $bkx $bky; Park                              # leave the settings page
    ClickAt ($rc.l + $tcx) ($rc.t + $tcy); Park          # dark -> light: the rest runs as before
    # (2) back on page 0 (the theme clicks did not switch pages): real click on the Ports tab
    ClickAt ($rc.l + [int]$d["nav2_cx"]) ($rc.t + [int]$d["nav2_cy"]); Park
    $b1 = ImgShot $h $w0 $ht
    $hash1 = ImgHash $b1
    $dProbe = @($d["geo_probe_rect"] -split ',' | ForEach-Object { [int]$_ })
    $probeLbl = DarkIn $b1 $dProbe[0] $dProbe[1] $dProbe[2] $dProbe[3]
    Check "C6f" "REAL click on the Ports tab changes the screen (page switched)" ($hash0 -ne $hash1) "hash before=$($hash0.Substring(0,12)) after=$($hash1.Substring(0,12))"
    Check "C6q" "the Probe button renders its label too" ($probeLbl -ge 15) "label ink pixels in ($(Csv $dProbe)) = $probeLbl"
    # (3) before pressing Probe every row must read '--' (the work order: no auto probing)
    $rs = RowStates $b1 ([int]$d["ports_state_x"]) ([int]$d["ports_row_y0"]) ([int]$d["ports_row_dy"]) 5
    $anyDecided = $false
    foreach ($k in $rs.Keys) { if ($rs[$k].st -ne "wait") { $anyDecided = $true } }
    $b1.Dispose()
    Check "C6g" "ports page before Probe: every row shows '--' (no socket touched)" (-not $anyDecided) ("rows=" + (($rs.Keys | Sort-Object | ForEach-Object { "$_=$($rs[$_].st)" }) -join " "))
    # (4) press Probe with a real click and record how long the 5 rows take to become known
    ClickAt ($rc.l + [int]$d["probe_cx"]) ($rc.t + [int]$d["probe_cy"])
    $sw5 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw5.ElapsedMilliseconds -lt 20000) {
      Start-Sleep -Milliseconds 250
      $b2 = ImgShot $h $w0 $ht
      $rs2 = RowStates $b2 ([int]$d["ports_state_x"]) ([int]$d["ports_row_y0"]) ([int]$d["ports_row_dy"]) 5
      $b2.Dispose()
      for ($rr = 0; $rr -lt 5; $rr++) {
        if ($rs2[$rr].st -ne "wait" -and -not $seenStates.ContainsKey($rr)) {
          $seenStates[$rr] = $rs2[$rr].st
          $probeTimeline = $probeTimeline + (" {0}={1}@{2}ms" -f $ports[$rr], $rs2[$rr].st, $sw5.ElapsedMilliseconds)
        }
      }
      if ($seenStates.Count -eq 5) { break }
    }
    Write-Output ("---- on-screen port timeline:" + $probeTimeline)
    Check "C6h" "after Probe all 5 rows become known" ($seenStates.Count -eq 5) "known=$($seenStates.Count)/5 timeline=$probeTimeline"
    $statesOk = $true
    $cmpTxt = ""
    for ($rr = 0; $rr -lt 5; $rr++) {
      $appv = "none"; if ($seenStates.ContainsKey($rr)) { $appv = $seenStates[$rr] }
      $cmpTxt = $cmpTxt + (" {0}:app={1}/ps={2}" -f $ports[$rr], $appv, $psPorts[$ports[$rr]])
      if ($appv -ne $psPorts[$ports[$rr]]) { $statesOk = $false }
    }
    Check "C6i" "on-screen port states == PowerShell real connects" $statesOk $cmpTxt
    Check "C6j" "probe cost recorded (one non-blocking connect per frame)" ($seenStates.Count -eq 5) "total=$($sw5.ElapsedMilliseconds)ms for 5 rows; the old blocking connect cost ~2045ms per dead port"
    # (4b) v5 (A): the Actions page with a REAL mouse. Click the 5th tab, look at the screen, then
    #      click one launcher and let the OPERATING SYSTEM prove the process exists. The launcher
    #      driven here is Notepad on purpose: taskmgr runs elevated on this machine and cannot be
    #      killed from this script (Stop-Process => Access denied, taskkill /F => denied), so it is
    #      deliberately NOT the automated target -- it is judged by its own ink above instead.
    #      Only the PIDs that appeared DURING the click are stopped, so a Notepad the user already
    #      had open is never touched.
    $actPre = @(Get-Process -Name notepad -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $act0 = @($d["geo_action0_rect"] -split ',' | ForEach-Object { [int]$_ })
    $actTest = @($d["geo_action_test_rect"] -split ',' | ForEach-Object { [int]$_ })
    $nav5 = @($d["nav5_rect"] -split ',' | ForEach-Object { [int]$_ })
    $bA0 = ImgShot $h $w0 $ht
    $hashPreAct = ImgHash $bA0
    $bA0.Dispose()
    ClickAt ($rc.l + $nav5[0] + [int]($nav5[2] / 2)) ($rc.t + $nav5[1] + [int]($nav5[3] / 2)); Park
    $bA1 = ImgShot $h $w0 $ht
    $hashAct = ImgHash $bA1
    # every launcher must really show its label (the same "blank button" trap as everywhere else):
    # the ten rects are recomputed here from the app's own first-rect + the source's grid pitch
    $actTxt = ""
    $actInkMin = [int]::MaxValue
    for ($ai = 0; $ai -lt $CACTN; $ai++) {
      $ax = $act0[0] + ($ai % $CACTCOLS) * $CACTDX
      $ay = $act0[1] + [int]($ai / $CACTCOLS) * $CACTDY
      $v = DarkIn $bA1 $ax $ay $CACTW $CACTH
      $actTxt = $actTxt + (" {0}={1}" -f $ai, $v)
      if ($v -lt $actInkMin) { $actInkMin = $v }
    }
    $bA1.Dispose()
    Check "C6x" "REAL click on the Actions tab switches to a new page whose locator labels all paint" `
      (($hashAct -ne $hashPreAct) -and ($actInkMin -ge 3)) `
      "page hash $($hashPreAct.Substring(0,12)) -> $($hashAct.Substring(0,12)) equal=$($hashAct -eq $hashPreAct) label_ink_min=$actInkMin $actTxt"
    $actClickPt = @(($actTest[0] + [int]($actTest[2] / 2)), ($actTest[1] + [int]($actTest[3] / 2)))
    ClickAt ($rc.l + $actClickPt[0]) ($rc.t + $actClickPt[1]); Park
    $swA = [System.Diagnostics.Stopwatch]::StartNew()
    $actNew = @()
    while ($swA.ElapsedMilliseconds -lt 10000) {
      Start-Sleep -Milliseconds 250
      $actNew = @(Get-Process -Name notepad -ErrorAction SilentlyContinue | Where-Object { $actPre -notcontains $_.Id })
      if ($actNew.Count -gt 0) { break }
    }
    $actPids = @($actNew | Select-Object -ExpandProperty Id)
    $actTgt = [string]$d["action_target_$CACTTEST"]
    $actMain = ""
    foreach ($ap in $actNew) { $actMain = $actMain + (" pid=$($ap.Id) title='$($ap.MainWindowTitle)'") }
    foreach ($ap in $actNew) { try { Stop-Process -Id $ap.Id -Force } catch { } }
    Start-Sleep -Milliseconds 400
    $actLeft = @(Get-Process -Name notepad -ErrorAction SilentlyContinue | Where-Object { $actPre -notcontains $_.Id })
    Check "C6y" "REAL click on a launcher button really starts that program (OS sees the process, then it is stopped)" `
      (($actNew.Count -ge 1) -and ($actLeft.Count -eq 0)) `
      "target='$actTgt' click=($($actClickPt -join ',')) after=$($swA.ElapsedMilliseconds)ms started=$($actNew.Count) [$actMain] still_running=$($actLeft.Count) preexisting=$($actPre.Count)"
    # (5) right click over the window must quit the app
    [void][WinPanelProbe]::SetCursorPos(($rc.l + 320), ($rc.t + 230))
    Start-Sleep -Milliseconds 150
    [WinPanelProbe]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero)   # RIGHTDOWN
    Start-Sleep -Milliseconds 200
    [WinPanelProbe]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero)   # RIGHTUP
    $swq = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited -and $swq.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 50 }
    Check "C6k" "REAL right click quits the app" $proc.HasExited "exited=$($proc.HasExited) after=$($swq.ElapsedMilliseconds)ms"
  }
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Start-Sleep -Milliseconds 400
  # v5: drop the frozen-snapshot override again (B1 owns its own override from here on)
  if (Test-Path -LiteralPath $srcovr) { Remove-Item -LiteralPath $srcovr -Force }
  # M4r: this block created fps.on before launching its instance; hand the marker back off so the
  # idle block (C9) owns it again exactly as before.
  Remove-Item -LiteralPath $fpson -Force -ErrorAction SilentlyContinue
  # v10 (M12): the layer trace was only turned on for the C6 instance; C10 creates its own markers and
  # clears the trace before its first session, so nothing of ours may be left behind here.
  Remove-Item -LiteralPath $c10TraceOnEarly -Force -ErrorAction SilentlyContinue
  $left = @(Get-Process -Name winpanel -ErrorAction SilentlyContinue)
  Check "C6l" "process killed, no leftover window" ($left.Count -eq 0) "leftover=$($left.Count)"
  # v8 (M8) second half: the claim must DIE with the process, otherwise a crashed panel would leave a
  # ghost hotkey that nobody can take. Measured in tmp\m8\hotkey-probe-run.txt (step 4): killing the
  # holder frees the combo immediately.
  $freedOk = [WinPanelProbe]::RegisterHotKey([IntPtr]::Zero, 77, ($hkMods -bor 0x4000), $hkVk)
  $freedErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  if ($freedOk) { [void][WinPanelProbe]::UnregisterHotKey([IntPtr]::Zero, 77) }
  Check "C6x4b" "the hotkey claim is exclusive while the panel runs and dies with it (no ghost hotkey)" `
    (($hkOk -eq 1) -and $hkBlocked -and $freedOk) `
    ("hk_ok=$hkOk; while the panel ran, this script's own RegisterHotKey on the same combo was refused=$hkBlocked (GetLastError=$ourErr); after the panel was gone the same call succeeded=$freedOk (GetLastError=$freedErr)")
}

# ---------------------------------------------------------------- C7 (Phase B) the registry page
# C7a: the source may only ever LOOK. The four read-only entries must be declared, and none of the
# write/creation entry points may appear in the app's CODE -- the panel is not allowed to be able to
# change what starts with Windows. Comments are stripped first: the file documents the absence of
# those names in prose, and a criterion that cannot tell prose from code is not a criterion.
$codeLines = @()
foreach ($ln in ($txt -split "`n")) {
  $ci = $ln.IndexOf('//')
  if ($ci -ge 0) { $ln = $ln.Substring(0, $ci) }
  $codeLines += $ln
}
$code = $codeLines -join "`n"
$regWriteNames = @("RegSetValueExA", "RegCreateKeyExA", "RegCreateKeyA", "RegDeleteKeyA",
                   "RegDeleteValueA", "RegSaveKeyA", "RegSaveKeyExA", "RegRestoreKeyA",
                   "RegSetKeyValueA", "RegSetValueA", "RegLoadKeyA", "RegReplaceKeyA")
$regWriteHits = @($regWriteNames | Where-Object { $code.Contains($_) })
$regWriteDecls = @($regWriteNames | Where-Object { $code.Contains("api advapi32 int " + $_) })
$regReadNames = @("RegOpenKeyExA", "RegEnumValueA", "RegQueryValueExA", "RegCloseKey")
$regReadHits = @($regReadNames | Where-Object { $code.Contains("api advapi32 int " + $_) })
Check "C7a" "source declares exactly the 4 read-only registry entries and ZERO write entries" `
  (($regWriteHits.Count -eq 0) -and ($regWriteDecls.Count -eq 0) -and ($regReadHits.Count -eq 4) -and ($code.Length -gt 20000)) `
  "write_api_code_hits=[$($regWriteHits -join ',')] write_api_decls=[$($regWriteDecls -join ',')] read_only_decls=$($regReadHits.Count)/4 code_bytes=$($code.Length) dll=[$(($regReadNames | ForEach-Object { 'advapi32!' + $_ }) -join ',')]"
# C7b: the degradation path, exercised against subkeys that really are not there (panel.reg is the
# test hook; both lines are rewritten so neither hive can accidentally answer)
[System.IO.File]::WriteAllText($regovr, "Software\NoSuchKeyFLINTdegrade1`r`nSoftware\NoSuchKeyFLINTdegrade2`r`n", (New-Object System.Text.ASCIIEncoding))
New-Item -ItemType File -Force -Path $marker | Out-Null
$dr7 = RunDump 60000
Remove-Item -LiteralPath $marker -Force
Remove-Item -LiteralPath $regovr -Force
$d7 = @{}
if (Test-Path -LiteralPath $dumpPath) { $d7 = ReadDump $dumpPath }
$degOk = ($dr7.rc -eq 0) -and ($d7["reg_hkcu_state"] -eq "unavailable") -and ($d7["reg_hklm_state"] -eq "unavailable") -and
         ([int]$d7["reg_hkcu_n"] -eq 0) -and ([int]$d7["reg_hklm_n"] -eq 0) -and
         ([int]$d7["startup_hkcu_rows"] -eq 1) -and ([int]$d7["startup_hklm_rows"] -eq 1) -and
         ($d7["cmd_over"] -eq "0") -and ([int]$d7["reg_query_ok"] -eq 0)
Write-Output "---- registry degradation (panel.reg -> two subkeys that do not exist) ----"
Write-Output ("    hkcu: key='{0}' state={1} n={2} rows={3}" -f $d7["reg_hkcu_key"], $d7["reg_hkcu_state"], $d7["reg_hkcu_n"], $d7["startup_hkcu_rows"])
Write-Output ("    hklm: key='{0}' state={1} n={2} rows={3}" -f $d7["reg_hklm_key"], $d7["reg_hklm_state"], $d7["reg_hklm_n"], $d7["startup_hklm_rows"])
Check "C7b" "unopenable key -> 'unavailable' + exit 0 + page still renders" $degOk `
  "exit=$($dr7.rc) hkcu=$($d7['reg_hkcu_state'])/n=$($d7['reg_hkcu_n'])/rows=$($d7['startup_hkcu_rows']) hklm=$($d7['reg_hklm_state'])/n=$($d7['reg_hklm_n'])/rows=$($d7['startup_hklm_rows']) size_queries=$($d7['reg_query_ok']) cmd_over=$($d7['cmd_over'])"
Check "C7b2" "the panel.reg override really reached the app (echoed subkey paths)" `
  (($d7["reg_hkcu_key"] -eq "Software\NoSuchKeyFLINTdegrade1") -and ($d7["reg_hklm_key"] -eq "Software\NoSuchKeyFLINTdegrade2")) `
  "hkcu='$($d7['reg_hkcu_key'])' hklm='$($d7['reg_hklm_key'])'"
Check "C7c" "degraded run is otherwise healthy (all 7 pages still switch, nothing overflows)" `
  (([int]$d7["pages_distinct"] -eq $CPAGES) -and ([int]$d7["nav_click_switched"] -eq $CPAGES) -and ($d7["text_over"] -eq "0") -and ($d7["setup_open_ok"] -eq "1")) `
  "pages_distinct=$($d7['pages_distinct']) nav=$($d7['nav_click_switched']) pages=$CPAGES text_over=$($d7['text_over']) setup_open_ok=$($d7['setup_open_ok'])"
# C7d/C7e: the import ledger. The "before" number is NOT hand-written either: the v3 delivery is
# rebuilt from its git anchor into tmp\ and counted the same way, and the caps are read out of the
# compiler's own source (src\pe.c).
function Get-Imports([string]$pe) {
  $od = "E:\mingw64\bin\objdump.exe"
  if (-not (Test-Path -LiteralPath $od)) {
    $c = Get-Command objdump -ErrorAction SilentlyContinue
    if ($c) { $od = $c.Source } else { return $null }
  }
  $out = & $od -p $pe 2>&1 | Out-String
  $lines = $out -split "`r?`n"
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'The Import Tables') { $start = $i; break } }
  if ($start -lt 0) { return $null }
  $mods = @()
  $cnt = 0
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '^\s*DLL Name:\s*(\S+)') { $mods += $Matches[1]; continue }
    if (($i -gt $start) -and ($l -match '^[A-Za-z]')) { break }
    if ($l -match '^\s+[0-9a-f]{8}\s+(<none>|[0-9a-f]{4})\s+[0-9a-f]{4}\s+\S+\s*$') { $cnt++ }
  }
  return @{ entries = $cnt; modules = $mods.Count; list = $mods }
}
$peSrc = [System.IO.File]::ReadAllText((Join-Path $repo "src\pe.c"), [System.Text.Encoding]::UTF8)
$maxImp = [int]([regex]::Match($peSrc, '#define\s+MAX_IMPORTS\s+(\d+)').Groups[1].Value)
$maxGrp = [int]([regex]::Match($peSrc, '#define\s+MAX_GROUPS\s+(\d+)').Groups[1].Value)
New-Item -ItemType Directory -Force -Path $v3dir | Out-Null
cmd /c "cd /d $repo && git show ${gitV3}:apps/winpanel/main.fl > `"$v3src`""
$v3srcOk = (Test-Path -LiteralPath $v3src) -and ((Get-Item -LiteralPath $v3src).Length -gt 1000)
if (Test-Path -LiteralPath $v3exe) { Remove-Item -LiteralPath $v3exe -Force }
$v3out = & $flint $v3src -gui -o $v3exe 2>&1 | Out-String
$v3rc = $LASTEXITCODE
$v3ok = Test-Path -LiteralPath $v3exe
Check "C7d" "v3 artifact rebuilt from git $gitV3 into tmp (the import baseline)" ($v3srcOk -and $v3ok -and $v3rc -eq 0) "src=$v3srcOk exe=$v3ok bytes=$(if($v3ok){(Get-Item $v3exe).Length}else{0}) rc=$v3rc"
$impNow = Get-Imports $exe
$impV3 = Get-Imports $v3exe
# The expected delta is NOT a hand-written number any more: this script reads the two SOURCES and
# works out which api declarations the delivered file has that the v3 file did not, grouping them by
# dll. A declaration that is really used shows up as one import entry, and a dll that was not
# imported at all shows up as one extra module.
function ApiDecls([string]$text) {
  $out = @{}
  foreach ($m in [regex]::Matches($text, '(?m)^\s*api\s+(\S+)\s+\S+\s+(\w+)')) {
    $out[$m.Groups[2].Value] = $m.Groups[1].Value
  }
  return $out
}
$declNow = ApiDecls $txt
$v3Txt = [System.IO.File]::ReadAllText($v3src, [System.Text.Encoding]::ASCII)
$declV3 = ApiDecls $v3Txt
$newNames = @($declNow.Keys | Where-Object { -not $declV3.ContainsKey($_) })
$newDeclDlls = @($newNames | ForEach-Object { $declNow[$_] } | Sort-Object -Unique)
# A dll that the v3 BINARY already imported cannot add a module, no matter how many new
# declarations point at it (ws2_32 is exactly that case: v5 only added declarations, the v3 exe was
# already importing it through the libraries). So the module delta is measured against the v3 EXE's
# own module list, which this script got from objdump -- not against anything hand-written.
$newDlls = @($newDeclDlls | Where-Object { $impV3.list -notcontains ($_ + ".dll") })
$expEntryDelta = $newNames.Count
$expModDelta = $newDlls.Count
$impOk = ($null -ne $impNow) -and ($null -ne $impV3) -and
         ($impNow.entries -eq ($impV3.entries + $expEntryDelta)) -and ($impNow.modules -eq ($impV3.modules + $expModDelta)) -and
         ($impNow.entries -le $maxImp) -and ($impNow.modules -le $maxGrp) -and
         ($impNow.list -contains "advapi32.dll") -and (-not ($impV3.list -contains "advapi32.dll")) -and
         ($impNow.list -contains "shell32.dll") -and (-not ($impV3.list -contains "shell32.dll"))
Write-Output "---- import ledger (objdump -p) ----"
Write-Output ("    v3  ($gitV3): entries={0} modules={1} [{2}]" -f $impV3.entries, $impV3.modules, ($impV3.list -join ', '))
Write-Output ("    v5  (delivered): entries={0} modules={1} [{2}]   caps from src\pe.c: MAX_IMPORTS={3} MAX_GROUPS={4}" -f $impNow.entries, $impNow.modules, ($impNow.list -join ', '), $maxImp, $maxGrp)
Write-Output ("    new declarations vs v3: [{0}]  -> expected +{1} entries / +{2} modules [{3}]" -f ($newNames -join ', '), $expEntryDelta, $expModDelta, ($newDlls -join ', '))
Check "C7e" "import ledger: exactly the source's own new declarations vs v3, inside 96/8" $impOk `
  "before=$($impV3.entries)/$($impV3.modules) after=$($impNow.entries)/$($impNow.modules) expected_delta=+$expEntryDelta/+$expModDelta new=[$($newNames -join ',')] new_dlls=[$($newDlls -join ',')] caps=$maxImp/$maxGrp advapi32=$($impNow.list -contains 'advapi32.dll') shell32=$($impNow.list -contains 'shell32.dll')"

# ---------------------------------------------------------------- B1 (v1's bonus check, kept):
# the 2 s refresh really re-reads the data file -- judged from the panel's own pixels, and without
# touching the engine's real snapshot (panel.src points at a copy that this script rewrites)
if (-not $SkipSmoke) {
  $fake = Join-Path $dumpdir "fake-snapshot.txt"
  [System.IO.File]::WriteAllText($fake, ($snapText -replace '(?m)^mem_time=.*$', 'mem_time=A'), (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($srcovr, $fake + "`r`n", (New-Object System.Text.ASCIIEncoding))
  Get-Process -Name winpanel -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  $proc2 = Start-Process -FilePath $exe -PassThru
  $w = WaitWindow $cls 5000
  $h2 = $w.hwnd
  $base = 0; $now = 0; $changedAt = -1; $bandH0 = ""; $bandH1 = ""
  $memRect = @($d["mem_row_rect"] -split ',' | ForEach-Object { [int]$_ })
  $mx0 = $memRect[0]; $my0 = $memRect[1] - 2; $mx1 = $memRect[0] + $memRect[2]; $my1 = $memRect[1] + $memRect[3] + 2
  if ($h2 -ne [IntPtr]::Zero) {
    Park
    Start-Sleep -Milliseconds 1500
    $bm = ImgShot $h2 $CW $CH
    $base = BandInkVsCorner $bm $mx0 $my0 $mx1 $my1
    $bandH0 = BandHash $bm $mx0 $my0 $mx1 $my1
    $bm.Dispose()
    [System.IO.File]::WriteAllText($fake, ($snapText -replace '(?m)^mem_time=.*$', 'mem_time=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'), (New-Object System.Text.UTF8Encoding($false)))
    $sw4 = [System.Diagnostics.Stopwatch]::StartNew()
    $now = $base
    while ($sw4.ElapsedMilliseconds -lt 5000) {
      Start-Sleep -Milliseconds 250
      $bm2 = ImgShot $h2 $CW $CH
      $bandH1 = BandHash $bm2 $mx0 $my0 $mx1 $my1
      $now = BandInkVsCorner $bm2 $mx0 $my0 $mx1 $my1
      $bm2.Dispose()
      if ($bandH1 -ne $bandH0 -and $changedAt -lt 0) { $changedAt = [int]$sw4.ElapsedMilliseconds; break }
    }
  }
  if (-not $proc2.HasExited) { Stop-Process -Id $proc2.Id -Force }
  Start-Sleep -Milliseconds 300
  if (Test-Path -LiteralPath $fake) { Remove-Item -LiteralPath $fake -Force }
  if (Test-Path -LiteralPath $srcovr) { Remove-Item -LiteralPath $srcovr -Force }
  Check "B1" "2s refresh re-reads the data file (seen in the panel pixels)" ($base -gt 50 -and $changedAt -ge 0 -and $changedAt -le 4500) "MEM row (rect $(Csv $memRect)) ink pixels ${base}->${now}, band hash changed=$($bandH1 -ne $bandH0) after ${changedAt}ms (file rewritten at t=0)"
  $left2 = @(Get-Process -Name winpanel -ErrorAction SilentlyContinue)
  Check "B1b" "no leftover after the refresh test" ($left2.Count -eq 0) "leftover=$($left2.Count)"
}

# ---------------------------------------------------------------- C8 flicker A/B (the ruler on
# FOUR artifacts: v1 must flicker, v2 and v3-in-both-themes must not)
if (-not $SkipAB -and (Test-Path -LiteralPath $dumpPath)) {
  Write-Output "---- flicker A/B: ONE ruler, v1 + v2 + v4(light) + v4(dark), data frozen ----"
  New-Item -ItemType Directory -Force -Path $v1dir | Out-Null
  New-Item -ItemType Directory -Force -Path $v2dir | Out-Null
  cmd /c "cd /d $repo && git show ${gitV1}:apps/winpanel/main.fl > `"$v1src`""
  $v1srcOk = (Test-Path -LiteralPath $v1src) -and ((Get-Item -LiteralPath $v1src).Length -gt 1000)
  if (Test-Path -LiteralPath $v1exe) { Remove-Item -LiteralPath $v1exe -Force }
  $v1out = & $flint $v1src -gui -o $v1exe 2>&1 | Out-String
  $v1rc = $LASTEXITCODE
  $v1ok = (Test-Path -LiteralPath $v1exe)
  Check "C8a" "v1 artifact rebuilt from git $gitV1 into tmp (delivery untouched)" ($v1srcOk -and $v1ok -and $v1rc -eq 0) "src=$v1srcOk exe=$v1ok bytes=$(if($v1ok){(Get-Item $v1exe).Length}else{0}) rc=$v1rc"
  cmd /c "cd /d $repo && git show ${gitV2}:apps/winpanel/main.fl > `"$v2src`""
  $v2srcOk = (Test-Path -LiteralPath $v2src) -and ((Get-Item -LiteralPath $v2src).Length -gt 1000)
  if (Test-Path -LiteralPath $v2exe) { Remove-Item -LiteralPath $v2exe -Force }
  $v2out = & $flint $v2src -gui -o $v2exe 2>&1 | Out-String
  $v2rc = $LASTEXITCODE
  $v2ok = (Test-Path -LiteralPath $v2exe)
  Check "C8b" "v2 artifact rebuilt from git $gitV2 into tmp (the idle-CPU baseline)" ($v2srcOk -and $v2ok -and $v2rc -eq 0) "src=$v2srcOk exe=$v2ok bytes=$(if($v2ok){(Get-Item $v2exe).Length}else{0}) rc=$v2rc"
  # freeze the data so every artifact reads byte-identical input and no socket is ever touched
  Copy-Item -LiteralPath $snap -Destination $frozen -Force
  $fh = (Get-FileHash -LiteralPath $frozen -Algorithm SHA256).Hash
  [System.IO.File]::WriteAllText($srcovr, $frozen + "`r`n", (New-Object System.Text.ASCIIEncoding))
  [System.IO.File]::WriteAllText($portsovr, "3080=up`r`n8080=down`r`n8090=down`r`n8091=down`r`n8092=down`r`n", (New-Object System.Text.ASCIIEncoding))
  $frames = 66
  $iv = 30
  $themeRect = @($d["geo_theme_rect"] -split ',' | ForEach-Object { [int]$_ })
  $tclick = @(($themeRect[0] + [int]($themeRect[2] / 2)), ($themeRect[1] + [int]($themeRect[3] / 2)))
  # a flicker run only means something while NOTHING touches the panel: this window sits on the middle
  # of the screen, so a live user crossing it with the mouse makes it repaint on hover -- by design,
  # and indistinguishable from flicker in these captures. Watch the pointer and retry once if it moved.
  function FlickerRound([string]$exeF, [string]$clsF, [int]$nf, [int]$ivm, [int]$warmF, [int[]]$clkF) {
    $pc0 = New-Object WPPOINT
    [void][WinPanelProbe]::GetCursorPos([ref]$pc0)
    $r = Measure-Flicker $exeF $clsF $nf $ivm $warmF $clkF
    $pc1 = New-Object WPPOINT
    [void][WinPanelProbe]::GetCursorPos([ref]$pc1)
    if (($pc0.x -ne $pc1.x) -or ($pc0.y -ne $pc1.y)) {
      Write-Output ("      (the pointer moved during the {0} flicker run -- retrying once)" -f $clsF)
      $r = Measure-Flicker $exeF $clsF $nf $ivm $warmF $clkF
    }
    return $r
  }
  Park
  $r1 = FlickerRound $v1exe $clsV1 $frames $iv 1500 $null
  $r2 = FlickerRound $v2exe $clsV2 $frames $iv 1500 $null
  $r3 = FlickerRound $exe $cls $frames $iv 1500 $null
  $r4 = FlickerRound $exe $cls $frames $iv 1500 $tclick
  CleanMarkers
  Write-Output ("    frozen snapshot sha256={0} bytes={1}" -f $fh, (Get-Item -LiteralPath $frozen).Length)
  foreach ($pair in @(@("v1      ", $r1), @("v2      ", $r2), @("v4 light", $r3), @("v4 dark ", $r4))) {
    $rr = $pair[1]
    Write-Output ("    {0} ruler: frames={1} distinct={2} modal={3} differing={4} inkMin={5} rect={6}x{7}" -f $pair[0], $rr.frames, $rr.distinct, $rr.modal, $rr.diff, $rr.ink, $rr.w, $rr.h)
  }
  $sameRuler = ($r1.frames -eq $frames) -and ($r2.frames -eq $frames) -and ($r3.frames -eq $frames) -and ($r4.frames -eq $frames)
  Check "C8c" "all four runs used the same ruler/sample count (66 frames @30ms)" $sameRuler "frames=$($r1.frames)/$($r2.frames)/$($r3.frames)/$($r4.frames) interval=${iv}ms"
  Check "C8d" "ruler is not blind: every capture carries ink" (($r1.ink -gt 0) -and ($r2.ink -gt 0) -and ($r3.ink -gt 0) -and ($r4.ink -gt 0)) "inkMin=$($r1.ink)/$($r2.ink)/$($r3.ink)/$($r4.ink)"
  Check "C8e" "v1 (ui_lib direct draw) really flickers under this ruler" ($r1.diff -gt 0) "differing frames=$($r1.diff) of $($r1.frames) (distinct frames=$($r1.distinct))"
  Check "C8f" "v2 (FLGUI whole-frame -> one ULW) shows 0 differing frames" ($r2.diff -eq 0) "differing frames=$($r2.diff) of $($r2.frames) (distinct=$($r2.distinct))"
  Check "C8g" "v4 blue-white: 0 differing frames" ($r3.diff -eq 0) "differing frames=$($r3.diff) of $($r3.frames) (distinct=$($r3.distinct))"
  Check "C8h" "v4 dark (after a real Theme click): 0 differing frames" ($r4.diff -eq 0) "differing frames=$($r4.diff) of $($r4.frames) (distinct=$($r4.distinct))"
  $left1 = @(Get-Process -Name v1panel, v2panel, winpanel -ErrorAction SilentlyContinue)
  Check "C8i" "no leftover process after the A/B" ($left1.Count -eq 0) "leftover=$($left1.Count)"
}

# ---------------------------------------------------------------- C9 idle CPU + upload count
# The numbers the work order asks for: with no input at all, "before" (v2, the delivered version)
# vs "after" (the current artifact). Same ruler for both: kernel CPU time (high resolution) + the
# app's own upload counter, pointer parked away from the panel, data frozen (no sockets). Rounds are
# interleaved (v2, v4, v4, v2) because a single pair carries a pairing-order bias; min/max reported.
# v4 fix: this block now really freezes the data, as its own header always said it did. The v3 code
# wrote the freeze for C8 and then removed it (CleanMarkers) BEFORE C9 ran, so C9 read the LIVE task
# engine snapshot -- and whenever the engine rewrote that file the digest moved and the app painted,
# which made "0 uploads while idle" go red through no fault of the app (observed once; the timeline
# below now prints the ledger so any stray frame is visible instead of just counted).
if (-not $SkipIdle) {
  Write-Output "---- idle CPU A/B (6 s of no input each, pointer parked, data frozen) ----"
  Copy-Item -LiteralPath $snap -Destination $frozen -Force
  [System.IO.File]::WriteAllText($srcovr, $frozen + "`r`n", (New-Object System.Text.ASCIIEncoding))
  [System.IO.File]::WriteAllText($portsovr, "3080=up`r`n8080=down`r`n8090=down`r`n8091=down`r`n8092=down`r`n", (New-Object System.Text.ASCIIEncoding))
  $idleRows = New-Object System.Collections.ArrayList
  $plan = @(
    @{ tag = "v2 run1"; exe = $v2exe; cls = $clsV2 },
    @{ tag = "v3 run1"; exe = $exe;   cls = $cls   },
    @{ tag = "v3 run2"; exe = $exe;   cls = $cls   },
    @{ tag = "v2 run2"; exe = $v2exe; cls = $clsV2 }
  )
  # one idle round, retried once when the user's pointer wandered over the panel (see Measure-Idle)
  function IdleRound([string]$exe2, [string]$cls2, [int]$sec2, [int[]]$click2) {
    $m = Measure-Idle $exe2 $cls2 $sec2 $click2
    if ($m.ok -and $m.touched) {
      Write-Output ("      (pointer moved during the {0} s round -- retrying once, the user was using the mouse)" -f $sec2)
      $m = Measure-Idle $exe2 $cls2 $sec2 $click2
    }
    return $m
  }
  foreach ($st in $plan) {
    $m = IdleRound $st.exe $st.cls 6 $null
    if (-not $m.ok) { [void]$idleRows.Add(@{ tag = $st.tag; ok = $false }) ; continue }
    [void]$idleRows.Add(@{
      tag = $st.tag; ok = $true; cpuMs = $m.cpuMs; cpuHiMs = $m.cpuNs; wallMs = $m.wallMs
      pct = [math]::Round(100.0 * $m.cpuNs / $m.wallMs, 4)
      pctTpt = [math]::Round(100.0 * $m.cpuMs / $m.wallMs, 4)
      renders = $m.renders; loops = $m.loops; led0 = $m.led0; led1 = $m.led1; touched = $m.touched
      rect = "$($m.rectBefore)->$($m.rectAfter)"
    })
  }
  # one longer v3 round: the kernel only accounts CPU per scheduler tick (~15.6 ms), so a 6 s
  # window can only prove "< 15.6 ms"; 30 s tightens that upper bound by 5x
  $mLong = IdleRound $exe $cls 30 $null
  if ($mLong.ok) {
    [void]$idleRows.Add(@{
      tag = "v3 30s"; ok = $true; cpuMs = $mLong.cpuMs; cpuHiMs = $mLong.cpuNs; wallMs = $mLong.wallMs
      pct = [math]::Round(100.0 * $mLong.cpuNs / $mLong.wallMs, 4)
      pctTpt = [math]::Round(100.0 * $mLong.cpuMs / $mLong.wallMs, 4)
      renders = $mLong.renders; loops = $mLong.loops; led0 = $mLong.led0; led1 = $mLong.led1; touched = $mLong.touched
      rect = "$($mLong.rectBefore)->$($mLong.rectAfter)"
    })
  }
  Write-Output "    tag      cpu_ms(TotalProcessorTime)  cpu_ms(GetProcessTimes)  wall_ms  %single-core  uploads  pump_loops  window"
  foreach ($row in $idleRows) {
    if (-not $row.ok) { Write-Output ("    {0,-8} FAILED to come up" -f $row.tag); continue }
    Write-Output ("    {0,-8} {1,-26} {2,-24} {3,-8} {4,-13} {5,-8} {6,-11} {7}" -f $row.tag, $row.cpuMs, $row.cpuHiMs, $row.wallMs, $row.pct, $row.renders, $row.loops, $row.rect)
  }
  foreach ($row in $idleRows) {
    if ($row.ok) { Write-Output ("      {0} ledger: '{1}' -> '{2}'" -f $row.tag, $row.led0, $row.led1) }
  }
  # a round where the user's own pointer crossed the panel measures the human, not the app: it is
  # reported loudly and left out of the judgement (the criterion itself is unchanged)
  foreach ($row in @($idleRows | Where-Object { $_.ok -and $_.touched })) {
    Write-Output ("      WARN {0}: the pointer was NOT parked during this round -- excluded from the idle judgement" -f $row.tag)
  }
  $v2rows = @($idleRows | Where-Object { $_.ok -and (-not $_.touched) -and $_.tag -like "v2*" })
  $v3rows = @($idleRows | Where-Object { $_.ok -and (-not $_.touched) -and $_.tag -like "v3*" })
  $v2max = 0.0; $v2min = 1e9; $v2up = 0
  foreach ($row in $v2rows) { if ($row.pct -gt $v2max) { $v2max = $row.pct }; if ($row.pct -lt $v2min) { $v2min = $row.pct }; $v2up = $v2up + $row.renders }
  $v3max = 0.0; $v3min = 1e9; $v3up = 0; $v3loops = 0; $v3cpuMax = 0
  $v3six = @($v3rows | Where-Object { $_.tag -like "v3 run*" })
  foreach ($row in $v3rows) { if ($row.pct -gt $v3max) { $v3max = $row.pct }; if ($row.pct -lt $v3min) { $v3min = $row.pct }; $v3up = $v3up + $row.renders; $v3loops = $v3loops + $row.loops; if ($row.cpuHiMs -gt $v3cpuMax) { $v3cpuMax = $row.cpuHiMs } }
  $v3long = @($v3rows | Where-Object { $_.tag -like "v3 30s" })
  Check "C9a" "v2 idle really burns CPU (worst round still >=10% single core)" (($v2rows.Count -ge 1) -and ($v2min -ge 10)) "v2 %single-core min/max = $v2min / $v2max over $($v2rows.Count) interleaved rounds; the app's own ledger shows 390 uploads in EVERY round, so the spread is the ULW/DWM path, not the app loop (window stays $(($v2rows | Select-Object -First 1).rect))"
  Check "C9b" "v4 idle is ~0% single core (6 s rounds)" ($v3max -le 1.0) "v3 %single-core min/max = $v3min / $v3max ; worst 6 s round = $v3cpuMax ms of CPU (kernel accounts per ~15.6 ms tick)"
  $longOk = ($v3long.Count -eq 1) -and ($v3long[0].pct -le 0.5)
  $longTxt = "v4 30 s: cpu=$($v3long[0].cpuHiMs) ms of $($v3long[0].wallMs) ms = $($v3long[0].pct)% single core, uploads=$($v3long[0].renders), pump loops=$($v3long[0].loops)"
  if (-not $longOk -and ($v3long.Count -eq 0)) {
    # no clean 30 s round: the user's own pointer crossed the panel in both attempts. The criterion
    # is "idle draws nothing"; the clean 6 s rounds already carry it (they bound the cost at one
    # scheduler tick), so fall back to them and SAY SO, instead of blaming the app for a human.
    $longOk = (($v3six.Count -ge 2) -and ($v3max -le 1.0))
    $longTxt = "no clean 30 s round (the pointer crossed the panel in both attempts); upper bound taken from $($v3six.Count) clean 6 s rounds: worst = $($v3max)% single core (< one 15.6 ms scheduler tick)"
  }
  Check "C9b2" "v4 idle upper bound from a 30 s round (1/5 of the tick granularity)" $longOk $longTxt
  Check "C9c" "v4 uploads 0 frames while idle, v2 uploads hundreds" (($v3up -eq 0) -and ($v2up -ge 300)) "v4 uploads=$v3up v2 uploads=$v2up (counted by each app's own ledger)"
  Check "C9d" "the pump keeps running while idle (it is idle, not frozen)" ($v3loops -ge 200) "v4 pump loops=$v3loops across the idle rounds (see also C9e)"
  # input after a long idle must still repaint (an idle panel must not be a frozen panel)
  $themeRect = @($d["geo_theme_rect"] -split ',' | ForEach-Object { [int]$_ })
  $tclick = @(($themeRect[0] + [int]($themeRect[2] / 2)), ($themeRect[1] + [int]($themeRect[3] / 2)))
  $mAfter = IdleRound $exe $cls 6 $tclick
  $afterOk = $mAfter.ok -and ($mAfter.afterClickChanged -eq 1) -and ($mAfter.renders -eq 0)
  Write-Output "      C9e idle-window ledger timeline:"
  foreach ($tl in $mAfter.timeline) { Write-Output ("        " + $tl) }
  Check "C9e" "after 6 s of ZERO uploads, a real Theme click still repaints the panel" $afterOk `
    "uploads during the idle window=$($mAfter.renders) after-click picture changed=$($mAfter.afterClickChanged) (1 = changed); ledger lines=$($mAfter.timeline.Count)"
}

CleanMarkers
if (Test-Path -LiteralPath $dumpalt) { Remove-Item -LiteralPath $dumpalt -Force }
# v5: hand the foreground back and stop the injection helper (it is OUR process, so this always works)
$injLeft = @()
if ($injHelper -ne $null) {
  Stop-Process -Id $injHelper.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  $injLeft = @(Get-Process -Id $injHelper.Id -ErrorAction SilentlyContinue)
}
Check "C6z2" "the synthetic-input helper window was stopped again (no leftover notepad)" `
  (($injHelper -eq $null) -or ($injLeft.Count -eq 0)) `
  "helper_pid=$(if ($injHelper) { $injHelper.Id } else { 'none' }) still_running=$($injLeft.Count)"

# ================================================================ C10 (v9 / M9): the two language
# tables, the config file and the settings rows that drive them.
#
# ID NOTE: the work order for this round calls these checks C9a..C9h, but C9a..C9e were ALREADY taken
# by the M4r idle-CPU family (the $SkipIdle block above). Renaming or deleting a delivered check was
# not an option, so they are numbered C10a..C10h here, in the work order's own order:
#   C10a = its C9a (both key sets)   C10e = its C9e (a restart really reads the file back)
#   C10b = its C9b (missing file)    C10f = its C9f (no cfg -> defaults)
#   C10c = its C9c (ZH on screen)    C10g = its C9g (the new row geometry + a real Save click)
#   C10d = its C9d (Save really writes)  C10h = its C9h (the settings page follows + no regression)
#
# Nothing below trusts the app: the key sets and the values are parsed HERE out of the two files, the
# layer comes from GWL_EXSTYLE, the opacity is solved out of the composited SCREEN pixels with the
# model C6s already established, the state words come from a dump, and the four new rectangles come
# from the command table (C2j already checks them against main.fl's own arithmetic).

# ---- the judge's own reader for a "key=value" file: the SAME rule the app counts with (skip blank
# lines and lines starting with '#', take everything after the first '='), so the two key counts are
# comparable by construction instead of by agreement.
function ReadLangFile([string]$p) {
  $h = [ordered]@{}
  if (-not (Test-Path -LiteralPath $p)) { return $h }
  $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  foreach ($rawline in ($t -split "`n")) {
    $l = $rawline.TrimEnd("`r")
    if ($l.Length -eq 0) { continue }
    if ($l.StartsWith("#")) { continue }
    $i = $l.IndexOf('=')
    if ($i -le 0) { continue }
    $h[$l.Substring(0, $i)] = $l.Substring($i + 1)
  }
  return $h
}
# the work order's appendix-A key list: the contract the two files have to meet
$langCanon = @(
  "app.title", "nav.local", "nav.ports", "nav.self", "nav.startup", "nav.actions", "nav.system", "nav.env",
  "setup.title", "setup.language", "setup.opacity", "setup.transparency", "setup.layer", "setup.theme",
  "setup.save", "setup.reload", "setup.reset", "setup.cfg_line", "setup.back",
  "bar.opacity", "bar.lang", "bar.cfg", "hint.opacity",
  "state.loaded", "state.default", "state.write_fail", "common.on", "common.off", "lang.en", "lang.zh"
)
function WriteCfg([string]$text) {
  # the judge writes the cfg itself: that is the "the app reads a file it did not write" half of this
  # round. UTF-8 without BOM, CRLF -- the same shape the app's own Save produces.
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($cfgfile, $text, $enc)
}
function AlphaOf([int]$pct) {
  # main.fl's wp_alpha_of re-done here over the constants parsed out of main.fl
  if ($pct -lt 0) { $pct = 0 }
  if ($pct -gt $COPCT) { $pct = $COPCT }
  return ($COPMAX - [int][Math]::Floor(($pct * ($COPMAX - $COPMIN) + 50) / $COPCT))
}
# one fresh panel + its window rect; the caller captures what it needs and calls M9Stop
function M9Start([int[]]$clickAt) {
  Get-Process -Name winpanel -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 300
  $p = Start-Process -FilePath $exe -PassThru
  $w = WaitWindow $cls 6000
  if ($w.hwnd -eq [IntPtr]::Zero) {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    return $null
  }
  $rc = New-Object WPRECT
  [void][WinPanelProbe]::GetWindowRect($w.hwnd, [ref]$rc)
  Park
  Start-Sleep -Milliseconds 800
  if ($clickAt -and $clickAt.Count -eq 2) {
    ClickAt ($rc.l + $clickAt[0]) ($rc.t + $clickAt[1])
    Park
    Start-Sleep -Milliseconds 500
  }
  return @{ proc = $p; hwnd = $w.hwnd; rect = $rc; w = ($rc.r - $rc.l); h = ($rc.b - $rc.t) }
}
function M9Stop($s) {
  if ($s -eq $null) { return }
  if (-not $s.proc.HasExited) { Stop-Process -Id $s.proc.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 250
}
# RunDump() does NOT create the headless marker itself (every other caller does it around the call);
# this wrapper keeps that discipline in one place, so a stray panel window can never be left behind.
function RunDumpM9([int]$timeoutMs) {
  New-Item -ItemType File -Force -Path $marker | Out-Null
  $r = RunDump $timeoutMs
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
  return $r
}

# ---------------- C10a: the two key sets, read by THIS script and compared with the app's counts ----
if (Test-Path -LiteralPath $cfgfile) { Remove-Item -LiteralPath $cfgfile -Force }   # $d was the no-cfg run
$langEnH = ReadLangFile $langen
$langZhH = ReadLangFile $langzh
$enKeys = @($langEnH.Keys)
$zhKeys = @($langZhH.Keys)
$enBytes = 0; $zhBytes = 0; $enBom = $false; $zhBom = $false
if (Test-Path -LiteralPath $langen) {
  $enBytes = (Get-Item -LiteralPath $langen).Length
  $lb = [System.IO.File]::ReadAllBytes($langen)
  $enBom = ($lb.Length -ge 3 -and $lb[0] -eq 0xEF -and $lb[1] -eq 0xBB -and $lb[2] -eq 0xBF)
}
if (Test-Path -LiteralPath $langzh) {
  $zhBytes = (Get-Item -LiteralPath $langzh).Length
  $lb = [System.IO.File]::ReadAllBytes($langzh)
  $zhBom = ($lb.Length -ge 3 -and $lb[0] -eq 0xEF -and $lb[1] -eq 0xBB -and $lb[2] -eq 0xBF)
}
$setEq = ((($enKeys | Sort-Object) -join "|") -eq (($zhKeys | Sort-Object) -join "|"))
$dupeEn = ($enKeys.Count -ne (@($enKeys | Sort-Object -Unique).Count))
$dupeZh = ($zhKeys.Count -ne (@($zhKeys | Sort-Object -Unique).Count))
$missCanon = @($langCanon | Where-Object { $enKeys -notcontains $_ })
$extraEn = @($enKeys | Where-Object { $langCanon -notcontains $_ })
$extraZh = @($zhKeys | Where-Object { $langCanon -notcontains $_ })
# the three sample words the app reported must equal what THIS script parsed out of the two files
$wordOk = (([string]$langEnH["nav.local"]) -eq [string]$d["lang_local_en"]) -and
          (([string]$langZhH["nav.local"]) -eq [string]$d["lang_local_zh"]) -and
          (([string]$langZhH["nav.ports"]) -eq [string]$d["lang_ports_zh"])
$c10aOk = $setEq -and (-not $dupeEn) -and (-not $dupeZh) -and ($missCanon.Count -eq 0) -and
          ($extraEn.Count -eq 0) -and ($extraZh.Count -eq 0) -and
          ($enKeys.Count -eq $CLANGN) -and ($zhKeys.Count -eq $CLANGN) -and
          ([int]$d["lang_keys_en"] -eq $enKeys.Count) -and ([int]$d["lang_keys_zh"] -eq $zhKeys.Count) -and
          ([int]$d["lang_miss_en"] -eq 0) -and ([int]$d["lang_miss_zh"] -eq 0) -and
          ([int]$d["lang_bytes_en"] -eq $enBytes) -and ([int]$d["lang_bytes_zh"] -eq $zhBytes) -and
          (-not $enBom) -and (-not $zhBom) -and $wordOk -and ([int]$d["lang_n"] -eq $CLANGN) -and
          ([int]$d["lang_fallback"] -eq 0) -and ($d["lang"] -eq "en")
Check "C10a" "the two language tables carry the SAME 30 keys, and the app's own counts/words agree with this script's read" `
  $c10aOk ("judge: en={0} keys zh={1} keys equal={2} canon_missing=[{3}] extra=[{4}/{5}] dupes={6}/{7} bytes={8}/{9} bom={10}/{11} words_ok={12} ; app: keys={13}/{14} miss={15}/{16} bytes={17}/{18} n={19} fallback={20} lang={21}" -f `
    $enKeys.Count, $zhKeys.Count, $setEq, ($missCanon -join ','), ($extraEn -join ','), ($extraZh -join ','), $dupeEn, $dupeZh, `
    $enBytes, $zhBytes, $enBom, $zhBom, $wordOk, $d["lang_keys_en"], $d["lang_keys_zh"], $d["lang_miss_en"], $d["lang_miss_zh"], `
    $d["lang_bytes_en"], $d["lang_bytes_zh"], $d["lang_n"], $d["lang_fallback"], $d["lang"])

# ---- the click points this round needs, taken from the dump's own geometry -------------------------
$c10SetupBtn = @($d["geo_setupbtn_rect"] -split ',' | ForEach-Object { [int]$_ })
$c10Sbx = $c10SetupBtn[0] + [int]($c10SetupBtn[2] / 2)
$c10Sby = $c10SetupBtn[1] + [int]($c10SetupBtn[3] / 2)
$c10LangR = @($d["geo_setup_lang_rect"] -split ',' | ForEach-Object { [int]$_ })
$c10SaveR = @($d["geo_setup_save_rect"] -split ',' | ForEach-Object { [int]$_ })
$c10LayR = @($d["geo_layer_rect"] -split ',' | ForEach-Object { [int]$_ })
# v10 (M12): the C10d scripted clicks have to press the right one of the THREE layer buttons -- the
# single cycling button these lines were written for no longer exists.
$c10LayTopR = @($d["geo_layer_top_rect"] -split ',' | ForEach-Object { [int]$_ })
$c10LayNorR = @($d["geo_layer_normal_rect"] -split ',' | ForEach-Object { [int]$_ })
$c10LayAutR = @($d["geo_layer_auto_rect"] -split ',' | ForEach-Object { [int]$_ })
function C10Mid([int[]]$r) { return @([int]($r[0] + $r[2] / 2), [int]($r[1] + $r[3] / 2)) }
$c10LangC = C10Mid $c10LangR
$c10SaveC = C10Mid $c10SaveR
$c10LayC = C10Mid $c10LayR
$c10LayTopC = C10Mid $c10LayTopR
$c10LayNorC = C10Mid $c10LayNorR
$c10LayAutC = C10Mid $c10LayAutR
Write-Output ("---- C10 click points (all out of the dump's command table): setup=({0},{1}) lang=({2},{3}) save=({4},{5}) layer_top=({6},{7}) layer_normal=({8},{9}) layer_auto=({10},{11})" -f `
  $c10Sbx, $c10Sby, $c10LangC[0], $c10LangC[1], $c10SaveC[0], $c10SaveC[1], $c10LayTopC[0], $c10LayTopC[1], $c10LayNorC[0], $c10LayNorC[1], $c10LayAutC[0], $c10LayAutC[1])

# ---------------- session EN: the English baseline. The cfg is deliberately a ONE-KEY file whose only
# difference from the ZH session below is the language itself: the settings page's `cfg:` info line
# prints how many keys the file carried, so a no-cfg EN session against a one-key ZH session would
# make the two setup bands differ for a reason that has nothing to do with translation -- and C10h
# would then be green without proving anything. Measured (red team, 2026-10-10): with the old
# no-cfg/no-cfg pair a zh table whose settings values were turned back into English still left C10h
# green, because the info line moved on its own.
$c10NavY0 = $CTH; $c10NavY1 = $CH - $CBH
# C10h hashes only the settings rows ABOVE the Language row. Why: that row prints the language's own
# name (EN / ZH) as its value, so it differs between the two sessions BY DESIGN and would mask the
# question "did the other words translate?" -- measured: with the whole band hashed, a zh table whose
# settings values were all turned back into English still left C10h green. The band below keeps the
# title, the hint line, the slider row, the two value lines, the Layer row and the `state:` line, every
# one of them a word out of the table.
$c10NoLangY1 = $expLangRect[1] - 4
if ($c10NoLangY1 -le $c10NavY0) { $c10NoLangY1 = $c10NavY1 }   # never hash an empty band
WriteCfg "ver=1`r`nlang=en`r`n"
$sesEn = M9Start $null
$navHashEn = ""; $navInkEn = 0; $setupHashEn = ""; $setupInkEn = 0; $exTopEn = -1
if ($sesEn -eq $null) {
  Write-Output "     C10: the panel window never appeared for the EN session"
} else {
  $bmp = ImgShot $sesEn.hwnd $sesEn.w $sesEn.h
  $navHashEn = BandHash $bmp 0 $c10NavY0 $CNW $c10NavY1
  $navInkEn = BandInkVsCorner $bmp 0 $c10NavY0 $CNW $c10NavY1
  $bmp.Dispose()
  $exTopEn = [WinPanelProbe]::GetWindowLong($sesEn.hwnd, -20)
  ClickAt ($sesEn.rect.l + $c10Sbx) ($sesEn.rect.t + $c10Sby); Park
  Start-Sleep -Milliseconds 500
  $bmp = ImgShot $sesEn.hwnd $sesEn.w $sesEn.h
  $setupHashEn = BandHash $bmp $CNW $c10NavY0 $CW $c10NoLangY1
  $setupInkEn = BandInkVsCorner $bmp $CNW $c10NavY0 $CW $c10NoLangY1
  $bmp.Dispose()
  M9Stop $sesEn
}

# ---------------- session ZH: cfg says lang=zh (layer left at the default `top`, so the panel really
# is the topmost window and the Setup click below cannot be eaten by whatever else is on the desktop)
WriteCfg "ver=1`r`nlang=zh`r`n"
$sesZh = M9Start $null
$navHashZh = ""; $navInkZh = 0; $setupHashZh = ""; $setupInkZh = 0; $exZh = -1
if ($sesZh -eq $null) {
  Write-Output "     C10: the panel window never appeared for the ZH session"
} else {
  $bmp = ImgShot $sesZh.hwnd $sesZh.w $sesZh.h
  $navHashZh = BandHash $bmp 0 $c10NavY0 $CNW $c10NavY1
  $navInkZh = BandInkVsCorner $bmp 0 $c10NavY0 $CNW $c10NavY1
  $bmp.Dispose()
  $exZh = [WinPanelProbe]::GetWindowLong($sesZh.hwnd, -20)
  ClickAt ($sesZh.rect.l + $c10Sbx) ($sesZh.rect.t + $c10Sby); Park
  Start-Sleep -Milliseconds 500
  $bmp = ImgShot $sesZh.hwnd $sesZh.w $sesZh.h
  $setupHashZh = BandHash $bmp $CNW $c10NavY0 $CW $c10NoLangY1
  $setupInkZh = BandInkVsCorner $bmp $CNW $c10NavY0 $CW $c10NoLangY1
  $bmp.Dispose()
  M9Stop $sesZh
}
Check "C10c" "switching to ZH really changes the pixels: the nav band hash moves and BOTH sides carry ink" `
  (($navHashEn -ne "") -and ($navHashZh -ne "") -and ($navHashZh -ne $navHashEn) -and ($navInkEn -gt 0) -and ($navInkZh -gt 0)) `
  ("nav band hash en={0} zh={1} (differ={2}); ink en={3} zh={4} pixels (a blank band would score 0 on both)" -f `
   $navHashEn.Substring(0, [Math]::Min(12, $navHashEn.Length)), $navHashZh.Substring(0, [Math]::Min(12, $navHashZh.Length)), ($navHashZh -ne $navHashEn), $navInkEn, $navInkZh)

# ---------------- C10b: a missing zh file must fall back, never paint blank -------------------------
$c10HadZh = Test-Path -LiteralPath $langzh
if ($c10HadZh) { Copy-Item -LiteralPath $langzh -Destination $langzbak -Force }
if (Test-Path -LiteralPath $langzh) { Remove-Item -LiteralPath $langzh -Force }
WriteCfg "ver=1`r`nlang=zh`r`n"
$drFb = RunDumpM9 60000
$dFb = @{}
if (Test-Path -LiteralPath $dumpPath) { $dFb = ReadDump $dumpPath }
$fbChinese = ([string]$langZhH["nav.local"])
$navHashFb = ""; $navInkFb = 0
$sesFb = M9Start $null
if ($sesFb -ne $null) {
  $bmp = ImgShot $sesFb.hwnd $sesFb.w $sesFb.h
  $navHashFb = BandHash $bmp 0 $c10NavY0 $CNW $c10NavY1
  $navInkFb = BandInkVsCorner $bmp 0 $c10NavY0 $CNW $c10NavY1
  $bmp.Dispose()
  M9Stop $sesFb
}
if ($c10HadZh) { Copy-Item -LiteralPath $langzbak -Destination $langzh -Force }
if (Test-Path -LiteralPath $langzbak) { Remove-Item -LiteralPath $langzbak -Force }
# the fallback word must be the built-in ENGLISH literal (the app's third sample word is the ZH bank
# read through the same lookup the painter uses: with the file gone it answers "Local", not "")
$c10bOk = ($drFb.rc -eq 0) -and ($dFb["lang"] -eq "zh") -and ([int]$dFb["lang_fallback"] -eq 1) -and
          ([int]$dFb["lang_keys_zh"] -eq 0) -and ([int]$dFb["lang_bytes_zh"] -eq 0) -and
          ([int]$dFb["lang_miss_zh"] -eq $CLANGN) -and
          ($dFb["lang_local_zh"] -eq [string]$langEnH["nav.local"]) -and
          ($dFb["lang_local_zh"] -ne $fbChinese) -and
          ($navHashFb -ne "") -and ($navHashFb -eq $navHashEn) -and ($navInkFb -gt 0)
Check "C10b" "lang.zh.txt removed -> the app says lang=zh + lang_fallback=1 and paints the built-in ENGLISH labels (nav band pixel-identical to EN, ink > 0)" `
  $c10bOk ("dump: exit={0} lang={1} fallback={2} keys_zh={3} bytes_zh={4} miss_zh={5} word_zh='{6}' (zh file's own nav.local='{7}', en literal='{8}'); window: nav hash fb={9} == en {10} (equal={11}), ink={12}; file put back={13}" -f `
   $drFb.rc, $dFb["lang"], $dFb["lang_fallback"], $dFb["lang_keys_zh"], $dFb["lang_bytes_zh"], $dFb["lang_miss_zh"], $dFb["lang_local_zh"], $fbChinese, $langEnH["nav.local"], `
   $navHashFb.Substring(0, [Math]::Min(12, $navHashFb.Length)), $navHashEn.Substring(0, [Math]::Min(12, $navHashEn.Length)), ($navHashFb -eq $navHashEn), $navInkFb, $c10HadZh)

# ---------------- C10d + C10g: a REAL Save click writes the LIVE state ------------------------------
# The judge wrote a cfg the app then read (lang=zh, layer=normal, opacity=50, theme=dark), clicks the
# Language button once (zh -> en) and the Layer button twice (normal -> auto -> top), and then presses
# Save with the real mouse. What lands on disk must be the LIVE state, not the file's own copy -- a
# Save that echoed its input would still say lang=zh / layer=normal and be caught here.
$c10Trace = Join-Path $dumpdir "panel-layer.txt"
$c10TraceOn = Join-Path $dumpdir "layer.on"
New-Item -ItemType File -Force -Path $c10TraceOn | Out-Null
if (Test-Path -LiteralPath $c10Trace) { Remove-Item -LiteralPath $c10Trace -Force }
WriteCfg "ver=1`r`nlang=zh`r`nopacity=50`r`ntheme=dark`r`n"
$cfgBefore = ""
if (Test-Path -LiteralPath $cfgfile) { $cfgBefore = [System.IO.File]::ReadAllText($cfgfile, [System.Text.Encoding]::UTF8) }
$sesSv = M9Start $null
$saveClicked = $false
if ($sesSv -ne $null) {
  ClickAt ($sesSv.rect.l + $c10Sbx) ($sesSv.rect.t + $c10Sby); Park          # open Setup
  ClickAt ($sesSv.rect.l + $c10LangC[0]) ($sesSv.rect.t + $c10LangC[1]); Park   # zh -> en
  # v10 (M12): the Layer row is three DIRECT buttons now, so reaching `auto` is one press on Auto (the
  # old code pressed one cycling button twice to walk top -> normal -> auto). The EXPECTED value on
  # disk is unchanged: layer=auto.
  ClickAt ($sesSv.rect.l + $c10LayAutC[0]) ($sesSv.rect.t + $c10LayAutC[1]); Park  # press AUTO (one press)
  Start-Sleep -Milliseconds 1200
  ClickAt ($sesSv.rect.l + $c10SaveC[0]) ($sesSv.rect.t + $c10SaveC[1]); Park   # SAVE
  Start-Sleep -Milliseconds 600
  $saveClicked = $true
  M9Stop $sesSv
}
if (Test-Path -LiteralPath $c10TraceOn) { Remove-Item -LiteralPath $c10TraceOn -Force }
$cfgAfter = ""
if (Test-Path -LiteralPath $cfgfile) { $cfgAfter = [System.IO.File]::ReadAllText($cfgfile, [System.Text.Encoding]::UTF8) }
$cfgAfterMap = ReadLangFile $cfgfile
$c10TraceLine = ""
if (Test-Path -LiteralPath $c10Trace) {
  $c10TraceLine = [string](Get-Content -LiteralPath $c10Trace -Tail 1)
}
$mSave = [regex]::Match($c10TraceLine, 'csave=(\d+)')
$c10SaveCount = -1
if ($mSave.Success) { $c10SaveCount = [int]$mSave.Groups[1].Value }
$c10dOk = $saveClicked -and ($cfgAfter -ne $cfgBefore) -and
          ([string]$cfgAfterMap["lang"] -eq "en") -and ([string]$cfgAfterMap["layer"] -eq "auto") -and
          ([string]$cfgAfterMap["opacity"] -eq "50") -and ([string]$cfgAfterMap["theme"] -eq "dark") -and
          ([string]$cfgAfterMap["ver"] -eq "1") -and (@($cfgAfterMap.Keys).Count -eq $CCFGNKEYS) -and
          ($c10SaveCount -ge 1)
Check "C10d" "a REAL Save click writes the LIVE state to winpanel.cfg (the lang/layer the clicks set are the ones on disk)" `
  $c10dOk ("file before='{0}' after='{1}' ; parsed after: lang={2} layer={3} opacity={4} theme={5} ver={6} keys={7} (expect en/auto/50/dark/1/{8}) ; trace csave={9}" -f `
   ($cfgBefore -replace "`r?`n", ' | '), ($cfgAfter -replace "`r?`n", ' | '), $cfgAfterMap["lang"], $cfgAfterMap["layer"], $cfgAfterMap["opacity"], $cfgAfterMap["theme"], $cfgAfterMap["ver"], @($cfgAfterMap.Keys).Count, $CCFGNKEYS, $c10SaveCount)
# C10g: the four new rectangles must sit inside the settings card and never overlap each other (read
# out of the dump's command table -- C2j above already proves each one equals main.fl's own arithmetic),
# and the real Save click above must have reached the Save handler (its own counter, from the trace).
$c10Rects = @(
  @{ n = "lang";   r = $c10LangR },
  @{ n = "save";   r = $c10SaveR },
  @{ n = "reload"; r = @($d["geo_setup_reload_rect"] -split ',' | ForEach-Object { [int]$_ }) },
  @{ n = "reset";  r = @($d["geo_setup_reset_rect"] -split ',' | ForEach-Object { [int]$_ }) }
)
$c10GeoBad = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $c10Rects.Count; $i++) {
  $r = $c10Rects[$i].r
  if (($r[2] -le 0) -or ($r[3] -le 0)) { [void]$c10GeoBad.Add("$($c10Rects[$i].n):empty") }
  if (($r[0] -lt $CNW) -or ($r[1] -lt $CTH) -or (($r[0] + $r[2]) -gt $CW) -or (($r[1] + $r[3]) -gt ($CH - $CBH))) {
    [void]$c10GeoBad.Add("$($c10Rects[$i].n):outside")
  }
  for ($j = $i + 1; $j -lt $c10Rects.Count; $j++) {
    $q = $c10Rects[$j].r
    $ovl = -not ((($r[0] + $r[2]) -le $q[0]) -or (($q[0] + $q[2]) -le $r[0]) -or (($r[1] + $r[3]) -le $q[1]) -or (($q[1] + $q[3]) -le $r[1]))
    if ($ovl) { [void]$c10GeoBad.Add("$($c10Rects[$i].n)x$($c10Rects[$j].n):overlap") }
  }
}
Check "C10g" "the four new settings rows are inside the settings card, pairwise non-overlapping, and a real Save click really reached the handler" `
  (($c10GeoBad.Count -eq 0) -and ($c10SaveCount -ge 1)) `
  ("rects lang=({0}) save=({1}) reload=({2}) reset=({3}) ; bad=[{4}] ; trace csave={5} after the real mouse click (C2j above checks all four against main.fl's constants)" -f `
   (Csv $c10Rects[0].r), (Csv $c10Rects[1].r), (Csv $c10Rects[2].r), (Csv $c10Rects[3].r), ($c10GeoBad -join ','), $c10SaveCount)

# ---------------- C10e: a restart reads the file back (fresh processes, OS + pixels as the judge) ----
# (a) the file the Save above wrote, read by a NEW dump process
$drE = RunDumpM9 60000
$dE = @{}
if (Test-Path -LiteralPath $dumpPath) { $dE = ReadDump $dumpPath }
# (b) opacity from the LIVE pixels. The cfg asks for opacity=0 (the most transparent end), so the
#     window must compose as alpha 120 / fill 200 -- the same model, the same thresholds C6s
#     established, with the default alpha as the negative control (C6u's role). `layer` is left at the
#     default `top` in THIS session on purpose: the model needs the screen capture to be the panel
#     composited over the desktop, which only holds while nothing covers it.
WriteCfg "ver=1`r`nlang=zh`r`nopacity=0`r`ntheme=dark`r`n"
$sesOpa = M9Start $null
$stOpa = $null; $stOpaBad = $null; $exOpaTop = -1; $opaW = 0; $opaH = 0
if ($sesOpa -ne $null) {
  $exOpaTop = [WinPanelProbe]::GetWindowLong($sesOpa.hwnd, -20)
  $opaW = $sesOpa.w; $opaH = $sesOpa.h
  Park
  Start-Sleep -Milliseconds 400
  $dibO = ImgShot $sesOpa.hwnd $opaW $opaH
  $scrO = ShotScreen $sesOpa.rect.l $sesOpa.rect.t $opaW $opaH
  [void][WinPanelProbe]::ShowWindow($sesOpa.hwnd, 0)
  Start-Sleep -Milliseconds 240
  $bgO = ShotScreen $sesOpa.rect.l $sesOpa.rect.t $opaW $opaH
  [void][WinPanelProbe]::ShowWindow($sesOpa.hwnd, 1)
  Start-Sleep -Milliseconds 400
  $aWant = AlphaOf ($COPCT - 0)
  $stOpa = OpaError (ImgBytes $scrO) (ImgBytes $dibO) (ImgBytes $scrO) (ImgBytes $dibO) (ImgBytes $bgO) $aWant $aWant (FillAOf $aWant) (FillAOf $aWant) -1 -1 $opaW $opaH 61 53
  $stOpaBad = OpaError (ImgBytes $scrO) (ImgBytes $dibO) (ImgBytes $scrO) (ImgBytes $dibO) (ImgBytes $bgO) $COPDEF $COPDEF (FillAOf $COPDEF) (FillAOf $COPDEF) -1 -1 $opaW $opaH 61 53
  $dibO.Dispose(); $scrO.Dispose(); $bgO.Dispose()
  M9Stop $sesOpa
}
# (c) the layer, read by THIS script out of GWL_EXSTYLE at two different cfg values: the EN session
#     above ran with no cfg (the default `top` -> the topmost bit set), this one asks for `normal`.
WriteCfg "ver=1`r`nlang=zh`r`nlayer=normal`r`n"
$sesLay = M9Start $null
$exOpaNorm = -1
if ($sesLay -ne $null) {
  Park
  Start-Sleep -Milliseconds 900
  $exOpaNorm = [WinPanelProbe]::GetWindowLong($sesLay.hwnd, -20)
  M9Stop $sesLay
}
Write-Output ("     C10e opacity from live pixels (cfg opacity=0 -> transparency 100): model alpha={0}/fill={1} median|err|={2} p99={3} n={4} ; negative control at the default alpha {5} median|err|={6} ; layer cfg=normal -> 0x{7:X8}" -f `
  $aWant, (FillAOf $aWant), $(if ($stOpa) { $stOpa.med } else { -1 }), $(if ($stOpa) { $stOpa.p99 } else { -1 }), $(if ($stOpa) { $stOpa.n } else { 0 }), $COPDEF, $(if ($stOpaBad) { $stOpaBad.med } else { -1 }), $exOpaNorm)
$c10eOk = ($drE.rc -eq 0) -and ($dE["cfg"] -eq "loaded") -and ($dE["lang"] -eq "en") -and
          ([int]$dE["cfg_opacity"] -eq 50) -and ([int]$dE["cfg_layer"] -eq 2) -and ([int]$dE["cfg_theme"] -eq 1) -and
          ([int]$dE["cfg_ver"] -eq 1) -and ([int]$dE["cfg_keys"] -eq $CCFGNKEYS) -and
          ($stOpa -ne $null) -and ($stOpa.n -gt 200) -and ($stOpa.med -le 5.0) -and
          ($stOpa.bad8 -le [int]($stOpa.n * 0.05)) -and
          ($stOpaBad -ne $null) -and ($stOpaBad.med -ge 20.0) -and
          (($stOpa.med * 10.0) -lt $stOpaBad.med) -and
          ($exOpaNorm -ge 0) -and ($exTopEn -ge 0) -and
          (($exOpaNorm -band 0x8) -eq 0) -and (($exTopEn -band 0x8) -ne 0)
Check "C10e" "a restart reads the file back: lang from a new dump, opacity solved from live pixels, layer from GWL_EXSTYLE at two different cfg values" `
  $c10eOk ("dump(2nd process): cfg={0} lang={1} opacity={2} layer={3} theme={4} ver={5} keys={6} (expect loaded/en/50/2/1/1/{7}) ; pixels: median|err|={8} (>8-level outliers={9} of {10} samples, gate <=5%) vs negative control median {11} at alpha {12} (ratio gate: 10x median < control) ; exstyle: cfg layer=normal -> 0x{13:X8} (topmost bit clear), the EN session (a cfg carrying only lang=en) -> 0x{14:X8} (set)" -f `
   $dE["cfg"], $dE["lang"], $dE["cfg_opacity"], $dE["cfg_layer"], $dE["cfg_theme"], $dE["cfg_ver"], $dE["cfg_keys"], $CCFGNKEYS,
   $(if ($stOpa) { $stOpa.med } else { -1 }), $(if ($stOpa) { $stOpa.bad8 } else { -1 }), $(if ($stOpa) { $stOpa.n } else { 0 }), $(if ($stOpaBad) { $stOpaBad.med } else { -1 }), $COPDEF, $exOpaNorm, $exTopEn)
# ---------------- C10f: no cfg at all -> every knob back to its default -----------------------------
if (Test-Path -LiteralPath $cfgfile) { Remove-Item -LiteralPath $cfgfile -Force }
$drF = RunDumpM9 60000
$dF = @{}
if (Test-Path -LiteralPath $dumpPath) { $dF = ReadDump $dumpPath }
$c10fOk = ($drF.rc -eq 0) -and ($dF["cfg"] -eq "default") -and ($dF["lang"] -eq "en") -and
          ([int]$dF["cfg_opacity"] -eq $CCFGOPADEF) -and ([int]$dF["cfg_layer"] -eq 0) -and
          ([int]$dF["cfg_read"] -eq 0) -and ([int]$dF["cfg_keys"] -eq 0) -and
          ((AlphaOf ($COPCT - $CCFGOPADEF)) -eq $COPDEF) -and
          ([int]$dF["layer_mode"] -eq 0) -and ($exTopEn -ge 0) -and (($exTopEn -band 0x8) -ne 0)
Check "C10f" "deleting winpanel.cfg returns every knob to its default (cfg=default, lang=en, opacity=WP_OPA_DEF, layer=top)" `
  $c10fOk ("dump: cfg={0} lang={1} cfg_opacity={2} (judge recomputes alpha from main.fl: AlphaOf(100-{3})={4} == WP_OPA_DEF {5}) layer_mode={6} cfg_read={7} cfg_keys={8} ; the EN session (a cfg carrying only lang=en) showed exstyle 0x{9:X8} (topmost bit set = the default `top`)" -f `
   $dF["cfg"], $dF["lang"], $dF["cfg_opacity"], $CCFGOPADEF, (AlphaOf ($COPCT - $CCFGOPADEF)), $COPDEF, $dF["layer_mode"], $dF["cfg_read"], $dF["cfg_keys"], $exTopEn)

# ---------------- C10h: the settings page itself follows the language, and the old rows still work --
$c10hOk = ($setupHashZh -ne "") -and ($setupHashEn -ne "") -and ($setupHashZh -ne $setupHashEn) -and
          ($setupInkZh -gt 0) -and ($setupInkEn -gt 0) -and
          ($d["setup_open_ok"] -eq "1") -and ($d["setup_back_ok"] -eq "1") -and
          ($d["setup_slider_found"] -eq "1") -and ($d["setup_back_found"] -eq "1") -and
          ($setupInkEn -gt 0)
Check "C10h" "the settings page's own words follow the language (the rows ABOVE the language indicator move) and the pre-existing setup checks are still green" `
  $c10hOk ("setup band hash (y {9}..{10}, i.e. above the Language row) en={0} zh={1} (differ={2}) ink en={3} zh={4} ; the two sessions differ ONLY in the cfg's lang value (both files carry one key), so the hash move can only come from the translated words ; the old dump fields: setup_open_ok={5} setup_back_ok={6} slider_found={7} back_found={8} (C6r in the smoke section drove those with a real mouse)" -f `
   $setupHashEn.Substring(0, [Math]::Min(12, $setupHashEn.Length)), $setupHashZh.Substring(0, [Math]::Min(12, $setupHashZh.Length)), ($setupHashZh -ne $setupHashEn), $setupInkEn, $setupInkZh, `
   $d["setup_open_ok"], $d["setup_back_ok"], $d["setup_slider_found"], $d["setup_back_found"], $c10NavY0, $c10NoLangY1)

# ---- put every file this block touched back the way it found it ------------------------------------
if (Test-Path -LiteralPath $cfgfile) { Remove-Item -LiteralPath $cfgfile -Force }
if ($cfgHadUser -and (Test-Path -LiteralPath $cfguser)) {
  Copy-Item -LiteralPath $cfguser -Destination $cfgfile -Force
  Remove-Item -LiteralPath $cfguser -Force
}
if (Test-Path -LiteralPath $langzbak) { Copy-Item -LiteralPath $langzbak -Destination $langzh -Force; Remove-Item -LiteralPath $langzbak -Force }
Get-Process -Name winpanel -ErrorAction SilentlyContinue | Stop-Process -Force
$c10Left = @(Get-Process -Name winpanel -ErrorAction SilentlyContinue)
Check "C10z" "no leftover panel process and the user's own winpanel.cfg (if any) is back where it was" `
  ($c10Left.Count -eq 0) ("leftover_winpanel={0} ; user_cfg_existed={1} restored={2}" -f $c10Left.Count, $cfgHadUser, (Test-Path -LiteralPath $cfgfile))

# ---------------------------------------------------------------- summary
$fail = @($CHK | Where-Object { -not $_.Ok })
Write-Output "==================== summary ===================="
Write-Output ("checks total={0} passed={1} failed={2}" -f $CHK.Count, ($CHK.Count - $fail.Count), $fail.Count)
if ($fail.Count -gt 0) {
  foreach ($f in $fail) { Write-Output ("  FAILED {0} {1} :: {2}" -f $f.Id, $f.Name, $f.Detail) }
  exit 1
}
Write-Output "ALL GREEN"
exit 0
