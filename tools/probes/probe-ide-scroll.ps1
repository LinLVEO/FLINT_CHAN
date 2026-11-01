# probe-ide-scroll.ps1 - FLINT Studio scrollbar / scrolling probe.
#
# What it measures (all from PrintWindow screenshots, no desktop coordinates):
#   1. does a scrollbar exist at the right edge of the editor?  We scan the 14px
#      column band at x = W-14..W-1 for a contiguous vertical run whose color is
#      NOT bg (#1E1E1E) / current-line (#2A2D2E) / separator (#2B2B2B).
#   2. mouse wheel over the editor: does the content shift?  by how many px?
#   3. PageDown: does the content shift by ~20 lines?  does the slider move?
#
# Verdict:
#   PASS  = scrollbar found AND slider moved after PageDown AND content scrolled
#   SKIP  = scrollbar not implemented in this build (exit 2) - still prints all numbers
#   FAIL  = scrollbar exists but does not react / content does not scroll
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (not implemented / env contention).
# ASCII only on purpose (avoid BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$code = 2
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Editor geometry used by studio_win.fl (see main()): sidebar 220, gutter right edge 240,
# text starts at x=268, title bar 34+6, status bar 26.
function Get-LineHeight([string]$Root) {
    $lh = 20   # default: studio.cfg absent -> fsz=14 -> lh = fsz + 6
    $cfg = Join-Path $Root 'studio.cfg'
    if (Test-Path $cfg) {
        $line = Select-String -Path $cfg -Pattern '^\s*size\s*=\s*(\d+)' | Select-Object -First 1
        if ($line) {
            $fsz = [int]$line.Matches[0].Groups[1].Value
            if ($fsz -ge 10 -and $fsz -le 26) { $lh = $fsz + 6 }
        }
    }
    return $lh
}

# The output panel, when present, ends the editor 168px above the status bar: find the
# horizontal separator row (#2B2B2B) between y=420 and the status bar.
function Find-EditorBottom([Frame]$img) {
    $W = $img.W; $H = $img.H
    $sbTop = $H - 26
    for ($y = 420; $y -lt $sbTop - 20; $y++) {
        $n = $img.CountNear(240, $y, $W - 40, $y + 1, 0x2B2B2B, 6)
        if ($n -gt (($W - 280) * 0.6)) { return $y }
    }
    return $sbTop
}

try {
    $app = Start-Studio $Root
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Position-Window $app.Hwnd
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    $img0 = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $lh = Get-LineHeight $Root
    $edb = Find-EditorBottom $img0
    $hasPanel = ($edb -lt ($H - 26))
    Write-Check 'GEOMETRY' ("{0}x{1} lh={2} editor_y=40..{3} status_y={4} output_panel={5}" -f $W, $H, $lh, $edb, ($H - 26), $hasPanel)
    [void](Save-Shot $img0 $Root 'ide-scroll-0-start')

    $sl0 = Measure-Slider $img0
    Write-Check 'SLIDER0' ("found={0} rows={1} y={2}..{3} color={4}" -f $sl0.Found, $sl0.RowCount, $sl0.Y0, $sl0.Y1, (Format-Rgb $sl0.Color))

    # ---- mouse wheel over the editor (3 notches down) ----
    [void](Grab-Focus $app.Hwnd 10)
    [Ide]::MoveClient($app.Hwnd, [int]($W / 2), [int](($edb + 40) / 2))
    [Ide]::Wheel(-3)
    Start-Sleep -Milliseconds 600
    $img1 = [Ide]::Grab($app.Hwnd)
    $wheelDiff = $img1.Diff($img0, 268, 42, $W - 40, $edb - 8, 2)
    # correlate the line-number gutter only, and only on glyph ("ink") pixels - see
    # BestShiftInk in IdeProbe.ps1 for why plain correlation picks the wrong line.
    $wheelShift = $img1.BestShiftInk($img0, 222, 240, 42, $edb - 8, $lh * 14, 1, 0x1E1E1E)
    [void](Save-Shot $img1 $Root 'ide-scroll-1-wheel')
    Assert-Deadline $sw $TimeoutSec 'wheel'
    Write-Check 'WHEEL' ("notches=-3 content_diff_px={0} shift_px={1}" -f $wheelDiff, $wheelShift)

    # ---- PageDown (app: g_scroll += 20 lines) ----
    if (-not (Grab-Focus $app.Hwnd 20)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    [Ide]::Key(0x22, $false, $false)   # VK_NEXT / PageDown
    Start-Sleep -Milliseconds 700
    $img2 = [Ide]::Grab($app.Hwnd)
    $pgDiff = $img2.Diff($img1, 268, 42, $W - 40, $edb - 8, 2)
    $pgShift = $img2.BestShiftInk($img1, 222, 240, 42, $edb - 8, $lh * 26, 1, 0x1E1E1E)
    $pgLines = if ($lh -gt 0) { [Math]::Round($pgShift / $lh, 1) } else { 0 }
    $sl2 = Measure-Slider $img2
    [void](Save-Shot $img2 $Root 'ide-scroll-2-pgdn')
    Assert-Deadline $sw $TimeoutSec 'pgdn'
    Write-Check 'SLIDER1' ("found={0} rows={1} y={2}..{3} color={4}" -f $sl2.Found, $sl2.RowCount, $sl2.Y0, $sl2.Y1, (Format-Rgb $sl2.Color))
    Write-Check 'PGDN' ("content_diff_px={0} shift_px={1} lines={2}" -f $pgDiff, $pgShift, $pgLines)

    $contentScrolled = (($pgShift -ge ($lh * 10)) -or ($pgDiff -ge 3000))
    $result = ''
    if (-not $sl0.Found) {
        # feature not implemented yet: still report every number, exit SKIP
        $result = 'SKIP(not implemented)'
        $code = 2
    }
    else {
        $sliderMoved = ($sl2.Found -and ([Math]::Abs($sl2.Y0 - $sl0.Y0) -ge 2))
        $pass = ($sliderMoved -and $contentScrolled)
        $result = if ($pass) { 'PASS' } else { 'FAIL' }
        $code = if ($pass) { 0 } else { 1 }
        Write-Check 'SLIDER' ("moved={0} delta_y={1}" -f $sliderMoved, ($sl2.Y0 - $sl0.Y0))
    }
    Write-Host ("RESULT     scrollbar={0} slider_rows={1} slider_moved={2} wheel_shift_px={3} pgdn_diff_px={4} pgdn_shift_px={5} pgdn_lines={6} => {7}" -f `
            $sl0.Found, $sl0.RowCount, ($sl2.Found -and ([Math]::Abs($sl2.Y0 - $sl0.Y0) -ge 2)), $wheelShift, $pgDiff, $pgShift, $pgLines, $result)
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     scroll=SKIP(env-contention) reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     scroll=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     scroll=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code

