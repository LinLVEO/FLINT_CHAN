# probe-ide-resize.ps1 - FLINT Studio borderless window resize probe (real mouse drags).
#
# The window is a borderless WS_POPUP, so the app implements its own 5 px resize
# border (studio_win.fl: in.mx >= W-5 => right edge, in.my >= H-5 => bottom edge,
# min size 620x420). This probe drives the real mouse: press, 6 interpolated moves,
# 400+ ms hold, release (the app samples the mouse at 30 fps, so the hold matters).
#
# What it measures (GetWindowRect + PrintWindow):
#   1. right edge (W-2,300) -> (W+118,300): width 1000 -> ~1118 (+/-6); the newly
#      exposed region x 1000..1100 is repainted editor background #1E1E1E, not
#      black/stale; the status bar is still the last 26 px (top row y = H-26)
#   2. bottom edge (400,H-2) -> +100 px: height 700 -> ~800 (+/-6), status bar at H-26
#   3. right edge dragged far left: clamped to 620 wide (615..625)
#   4. SetWindowPos restores 1000x700
#
# The drag is verified to have kept our cursor at the target point; if another probe
# stole the mouse the attempt is retried (up to 3) and every attempt's width is printed.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (avoid BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$result = 'FAIL'
$code = 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-resize'
$SrcDir = Join-Path $Sand 'apps\studio_native'

$TARGET_W = 1118     # 1000 + 118 client px of drag; app: nw = 1000 + (1118-998) = 1120
$TARGET_W_MIN = 1112
$TARGET_W_MAX = 1124
$TARGET_H = 800
$TARGET_H_MIN = 794
$TARGET_H_MAX = 806
$MIN_W = 620
$MIN_W_TOL = 5

function Get-WinSize([IntPtr]$H) {
    $r = [Ide]::Rect($H)
    return @{ L = $r.L; T = $r.T; W = ($r.R - $r.L); H = ($r.B - $r.T); R = $r.R; B = $r.B }
}

function Set-WinRect([IntPtr]$H, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $SWP_NOZORDER = 0x0004; $SWP_NOACTIVATE = 0x0010
    [void][Ide]::SetWindowPos($H, [IntPtr]::Zero, $X, $Y, $Width, $Height, ($SWP_NOZORDER -bor $SWP_NOACTIVATE))
}

# Topmost y of the status bar (the first row from which >80% of the width is #007ACC).
function Find-StatusTop([Frame]$Img) {
    $h = $Img.H; $w = $Img.W
    for ($y = [Math]::Max(0, $h - 60); $y -lt $h; $y++) {
        $n = $Img.CountNear(0, $y, $w, $y + 1, 0x007ACC, 10)
        if ($n -gt ($w * 0.8)) { return $y }
    }
    return -1
}

# SetWindowPos X/Y for the probe window: right-ish but with >=140 px free on the
# right so a +118 px drag stays on screen, and far from the default (120,90) spot.
$scrW = [Ide]::GetSystemMetrics(0)
$scrH = [Ide]::GetSystemMetrics(1)
$winX = $scrW - 1140
if ($winX -lt 20) { $winX = 20 }
$winY = 110
if ($winY + 700 -gt $scrH) { $winY = 20 }

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), "int x = 1;`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    Write-Check 'SANDBOX' $Sand

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1} screen={2}x{3}" -f $app.Proc.Id, $app.Hwnd, $scrW, $scrH)
    Set-WinRect $app.Hwnd $winX $winY 1000 700
    Start-Sleep -Milliseconds 300
    $img = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    $s0 = Get-WinSize $app.Hwnd
    Write-Check 'RECT0' ("{0},{1} {2}x{3}" -f $s0.L, $s0.T, $s0.W, $s0.H)
    [void](Save-Shot $img $Root 'ide-resize-0-start')
    if ($s0.W -lt 990 -or $s0.W -gt 1010 -or $s0.H -lt 690 -or $s0.H -gt 710) {
        throw ("window is {0}x{1}, expected 1000x700 (not in normal mode?)" -f $s0.W, $s0.H)
    }
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }

    # ---- 1. right edge: grow by 118 client px, 3 attempts max ----
    $dragW = @()
    $s1 = $null
    for ($try = 1; $try -le 3; $try++) {
        Invoke-DragClient $app.Hwnd ($s0.W - 2) 300 ($s0.W + 118) 300 6 450 90
        Start-Sleep -Milliseconds 500
        $s1 = Get-WinSize $app.Hwnd
        $dragW += $s1.W
        Write-Check 'GROW_TRY' ("try={0} width={1} (need {2}..{3}) cursor=({4},{5})" -f $try, $s1.W, $TARGET_W_MIN, $TARGET_W_MAX, [Ide]::CursorX(), [Ide]::CursorY())
        if ($s1.W -ge $TARGET_W_MIN -and $s1.W -le $TARGET_W_MAX) { break }
        Set-WinRect $app.Hwnd $winX $winY 1000 700
        Start-Sleep -Milliseconds 500
    }
    $img1 = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $img1 $Root 'ide-resize-1-wide')
    $growOk = ($s1.W -ge $TARGET_W_MIN -and $s1.W -le $TARGET_W_MAX)
    Write-Check 'GROW' ("width 1000 -> {0} (need {1}+/-6) tries={2}" -f $s1.W, $TARGET_W, $dragW.Count)
    Assert-Deadline $sw $TimeoutSec 'grow'

    # repaint of the newly exposed strip + status bar still at the bottom
    $bgPx = 0; $blackPx = 0; $statusTop = -1
    if ($img1.W -ge $s1.W - 2) {
        $bgPx = $img1.CountNear(1000, 40, 1100, 500, 0x1E1E1E, 6)
        $blackPx = $img1.CountNear(1000, 40, 1100, 500, 0x000000, 6)
        $statusTop = Find-StatusTop $img1
    }
    $paintOk = ($bgPx -ge 25000 -and $blackPx -lt 500)
    $statusOk1 = ($statusTop -eq ($s1.H - 26))
    Write-Check 'REPAINT' ("new_strip={0}px frame={1}x{2} bg_1E1E1E_px={3} (need>=25000) black_px={4} (need<500) status_top_y={5} (expect {6})" -f `
            ($s1.W - 1000), $img1.W, $img1.H, $bgPx, $blackPx, $statusTop, ($s1.H - 26))

    # ---- 2. bottom edge: grow height by 100 ----
    $dragH = @()
    $s2 = $null
    for ($try = 1; $try -le 3; $try++) {
        Invoke-DragClient $app.Hwnd 400 ($s1.H - 2) 400 ($s1.H + 98) 6 450 90
        Start-Sleep -Milliseconds 500
        $s2 = Get-WinSize $app.Hwnd
        $dragH += $s2.H
        Write-Check 'TALL_TRY' ("try={0} height={1} (need {2}..{3})" -f $try, $s2.H, $TARGET_H_MIN, $TARGET_H_MAX)
        if ($s2.H -ge $TARGET_H_MIN -and $s2.H -le $TARGET_H_MAX) { break }
        Set-WinRect $app.Hwnd $winX $winY $s1.W 700
        Start-Sleep -Milliseconds 500
    }
    $img2 = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $img2 $Root 'ide-resize-2-tall')
    $tallOk = ($s2.H -ge $TARGET_H_MIN -and $s2.H -le $TARGET_H_MAX)
    $statusTop2 = Find-StatusTop $img2
    $statusOk2 = ($statusTop2 -eq ($s2.H - 26))
    Write-Check 'TALL' ("height 700 -> {0} (need {1}+/-6) tries={2} frame={3}x{4} status_top_y={5} (expect {6})" -f `
            $s2.H, $TARGET_H, $dragH.Count, $img2.W, $img2.H, $statusTop2, ($s2.H - 26))
    Assert-Deadline $sw $TimeoutSec 'tall'

    # ---- 3. right edge dragged far left: clamp to 620 ----
    $dragMin = @()
    $s3 = $null
    for ($try = 1; $try -le 3; $try++) {
        Invoke-DragClient $app.Hwnd ($s2.W - 2) 300 200 300 8 450 90
        Start-Sleep -Milliseconds 500
        $s3 = Get-WinSize $app.Hwnd
        $dragMin += $s3.W
        Write-Check 'MIN_TRY' ("try={0} width={1} (need {2}+/-{3})" -f $try, $s3.W, $MIN_W, $MIN_W_TOL)
        if ([Math]::Abs($s3.W - $MIN_W) -le $MIN_W_TOL) { break }
        Set-WinRect $app.Hwnd $winX $winY $s2.W $s2.H
        Start-Sleep -Milliseconds 500
    }
    $img3 = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $img3 $Root 'ide-resize-3-min')
    $minOk = ([Math]::Abs($s3.W - $MIN_W) -le $MIN_W_TOL)
    $statusTop3 = Find-StatusTop $img3
    $statusOk3 = ($statusTop3 -eq ($s3.H - 26))
    Write-Check 'MIN' ("width -> {0} (need {1}+/-{2}) tries={3} frame={4}x{5} status_top_y={6} (expect {7})" -f `
            $s3.W, $MIN_W, $MIN_W_TOL, $dragMin.Count, $img3.W, $img3.H, $statusTop3, ($s3.H - 26))
    Assert-Deadline $sw $TimeoutSec 'min'

    # ---- 4. restore 1000x700 for later phases ----
    Set-WinRect $app.Hwnd $winX $winY 1000 700
    Start-Sleep -Milliseconds 600
    $s4 = Get-WinSize $app.Hwnd
    $restoreOk = ($s4.W -eq 1000 -and $s4.H -eq 700)
    Write-Check 'RESTORE' ("{0},{1} {2}x{3} (need 1000x700) rect={4},{5},{6},{7}" -f $s4.L, $s4.T, $s4.W, $s4.H, $s4.L, $s4.T, $s4.R, $s4.B)
    Assert-Deadline $sw $TimeoutSec 'restore'

    $all = ($growOk -and $paintOk -and $statusOk1 -and $tallOk -and $statusOk2 -and $minOk -and $statusOk3 -and $restoreOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     resize={0} grow_w={1} (need {2}+/-6, tries=[{3}]) new_strip_bg={4} black={5} status_y={6}/{7} | tall_h={8} (need {9}+/-6, tries=[{10}]) status_y={11}/{12} | min_w={13} (need {14}+/-{15}, tries=[{16}]) status_y={17}/{18} | restored={19}x{20}" -f `
            $result, $s1.W, $TARGET_W, ($dragW -join ','), $bgPx, $blackPx, $statusTop, ($s1.H - 26), `
            $s2.H, $TARGET_H, ($dragH -join ','), $statusTop2, ($s2.H - 26), $s3.W, $MIN_W, $MIN_W_TOL, ($dragMin -join ','), $statusTop3, ($s3.H - 26), $s4.W, $s4.H)
    if (-not $all) {
        Write-Check 'VERDICT' ("grow={0} repaint={1} status1={2} tall={3} status2={4} min={5} status3={6} restore={7}" -f `
                $growOk, $paintOk, $statusOk1, $tallOk, $statusOk2, $minOk, $statusOk3, $restoreOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     resize=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     resize=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     resize=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    # always leave the window at 1000x700 so later phases are unaffected
    if ($null -ne $app -and $null -ne $app.Hwnd -and $app.Hwnd -ne [IntPtr]::Zero) {
        try { Set-WinRect $app.Hwnd $winX $winY 1000 700 } catch { }
    }
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
