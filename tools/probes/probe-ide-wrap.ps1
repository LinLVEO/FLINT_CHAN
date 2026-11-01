# probe-ide-wrap.ps1 - FLINT Studio soft-wrap probe.
#
# Sandbox: tmp\ide-wrap (used as the app's WORKING DIRECTORY; the IDE opens
# apps\studio_native\main.fl and writes ai.state / studio.cfg relative to cwd).
# The exe itself is always the repo-root build (apps\studio_native\studio_win.exe):
# the sandbox also carries an older copy of the exe, which would silently test a
# stale binary.
#
# What it measures (all from PrintWindow screenshots + the ai.state oracle):
#   1. wrap ON  : visual row 1 ink reaches x >= 900 (line fills the width)
#                 visual row 2 is the continuation (ink starts at x 260..300, > 150 px)
#   2. wrap ON  : the line-number gutter only labels source row 1 - visual rows 2 and 3
#                 have (almost) no gutter ink
#   3. wrap ON  : ai.state nrows > nlines
#   4. Alt+Z    : wrap OFF -> nrows == nlines and visual row 2 gets source line 2
#                 (its line number appears in the gutter); Alt+Z again restores wrap.
#
# NOTE on the original acceptance text ("wrap off -> row 2 ink < 50 px"): the
# sandbox's source line 2 is a long Chinese comment, so with wrap OFF row 2 is
# line 2 and legitimately carries ~3000 ink pixels. The discriminating evidence
# that the continuation row is gone is nrows == nlines plus the line-number
# glyph (which wrap ON does not draw) appearing on visual row 2.
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
$Sand = Join-Path $Root 'tmp\ide-wrap'
$LH = 20
$TOP = 66      # title 34 + menu bar 26 + 6
$TXT_X0 = 268
$TXT_X1 = 984          # stop before the scrollbar strip (its hover color is bright)
$GUT_X0 = 220
$GUT_X1 = 266

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    $src = Join-Path $Sand 'apps\studio_native\main.fl'
    if (-not (Test-Path $src)) { throw "PROBE_SKIP:missing wrap sandbox source $src" }
    $bytes = [System.IO.File]::ReadAllBytes($src)
    $lines = [System.Text.Encoding]::UTF8.GetString($bytes) -split "`r?`n"
    if ($lines.Count -lt 2) { throw "PROBE_SKIP:sandbox source has $($lines.Count) line(s), need >=2" }
    $l1 = [System.Text.Encoding]::UTF8.GetByteCount($lines[0])
    $l2 = [System.Text.Encoding]::UTF8.GetByteCount($lines[1])
    if ($l1 -lt 150) { throw "PROBE_SKIP:sandbox line 1 is only $l1 bytes (not a wrap case)" }
    Write-Check 'SANDBOX' ("{0} bytes={1} line1={2}B line2={3}B" -f $src, $bytes.Length, $l1, $l2)

    # A stale studio.cfg (wrap=0 from an aborted earlier run) would poison the run.
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    $img = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img) { throw 'no frame captured' }
    $W = $img.W; $H = $img.H
    Write-Check 'GEOMETRY' ("{0}x{1} lh={2} first_row_y={3} text_x={4}..{5} gutter_x={6}..{7}" -f $W, $H, $LH, $TOP, $TXT_X0, $TXT_X1, $GUT_X0, $GUT_X1)
    [void](Save-Shot $img $Root 'ide-wrap-0-on')

    # ai.state may not exist for the first frames of a fresh sandbox: poll for it.
    $stOn = $null
    for ($i = 0; $i -lt 30; $i++) {
        $stOn = Read-StudioState $Sand
        if ($null -ne $stOn -and $stOn.NRows -gt 0) { break }
        Start-Sleep -Milliseconds 150
    }
    if ($null -eq $stOn) { throw 'ai.state has no ST line after 4.5s (oracle channel broken)' }
    Write-Check 'STATE_ON' $stOn.Raw
    Assert-Deadline $sw $TimeoutSec 'state-on'

    # ---- wrap ON: row 1 fills the width, row 2 is the continuation ----
    $r1 = Get-InkStats $img $TXT_X0 $TOP $TXT_X1 ($TOP + $LH) 70
    $r2 = Get-InkStats $img $TXT_X0 ($TOP + $LH) $TXT_X1 ($TOP + 2 * $LH) 70
    $g2 = Get-InkStats $img $GUT_X0 ($TOP + $LH) $GUT_X1 ($TOP + 2 * $LH) 70
    $g3 = Get-InkStats $img $GUT_X0 ($TOP + 2 * $LH) $GUT_X1 ($TOP + 3 * $LH) 70
    $a1 = ($r1.MaxX -ge 900)
    $a2 = ($r2.Count -gt 150 -and $r2.MinX -ge 260 -and $r2.MinX -le 300)
    $b1 = ($g2.Count -le 5 -and $g3.Count -le 5)
    $c1 = ($stOn.NRows -gt $stOn.LineCount)
    Write-Check 'WRAP_ON' ("row1_ink={0} row1_maxx={1} (need>=900) | row2_ink={2} row2_minx={3} (need 260..300, >150) | gutter2={4} gutter3={5} (need<=5) | nrows={6} nlines={7} (need nrows>nlines)" -f `
            $r1.Count, $r1.MaxX, $r2.Count, $r2.MinX, $g2.Count, $g3.Count, $stOn.NRows, $stOn.LineCount)

    # ---- Alt+Z: wrap OFF ----
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    [Ide]::KeyEx(0x5A, $false, $false, $true)
    $stOff = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 150
        $stOff = Read-StudioState $Sand
        if ($null -ne $stOff -and $stOff.NRows -eq $stOff.LineCount) { break }
    }
    if ($null -eq $stOff) { throw 'ai.state disappeared after Alt+Z' }
    Start-Sleep -Milliseconds 300
    $imgOff = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $imgOff $Root 'ide-wrap-1-off')
    $r2off = Get-InkStats $imgOff $TXT_X0 ($TOP + $LH) $TXT_X1 ($TOP + 2 * $LH) 70
    $g2off = Get-InkStats $imgOff $GUT_X0 ($TOP + $LH) $GUT_X1 ($TOP + 2 * $LH) 70
    $greenOff = $imgOff.CountNear($TXT_X0, ($TOP + $LH), $TXT_X1, ($TOP + 2 * $LH), 0x6A9955, 30)
    $d1 = ($stOff.NRows -eq $stOff.LineCount)
    $d2 = ($g2off.Count -ge 8)
    Write-Check 'STATE_OFF' $stOff.Raw
    Write-Check 'WRAP_OFF' ("nrows={0} nlines={1} (need equal) | row2_ink={2} row2_gutter_ink={3} (line number present, need>=8) | row2_comment_green={4}" -f `
            $stOff.NRows, $stOff.LineCount, $r2off.Count, $g2off.Count, $greenOff)
    Assert-Deadline $sw $TimeoutSec 'wrap-off'

    # ---- Alt+Z again: wrap back ON ----
    [Ide]::KeyEx(0x5A, $false, $false, $true)
    $stOn2 = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 150
        $stOn2 = Read-StudioState $Sand
        if ($null -ne $stOn2 -and $stOn2.NRows -gt $stOn2.LineCount) { break }
    }
    if ($null -eq $stOn2) { throw 'ai.state disappeared after second Alt+Z' }
    Start-Sleep -Milliseconds 300
    $imgOn2 = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $imgOn2 $Root 'ide-wrap-2-on-again')
    $r2on2 = Get-InkStats $imgOn2 $TXT_X0 ($TOP + $LH) $TXT_X1 ($TOP + 2 * $LH) 70
    $g2on2 = Get-InkStats $imgOn2 $GUT_X0 ($TOP + $LH) $GUT_X1 ($TOP + 2 * $LH) 70
    $d3 = ($stOn2.NRows -eq $stOn.NRows)
    $d4 = ($r2on2.Count -gt 150 -and $g2on2.Count -le 5)
    Write-Check 'STATE_ON2' $stOn2.Raw
    Write-Check 'WRAP_ON2' ("nrows={0} (need {1}) | row2_ink={2} gutter2={3}" -f $stOn2.NRows, $stOn.NRows, $r2on2.Count, $g2on2.Count)
    Assert-Deadline $sw $TimeoutSec 'wrap-on2'

    $all = ($a1 -and $a2 -and $b1 -and $c1 -and $d1 -and $d2 -and $d3 -and $d4)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     wrap={0} nrows_on={1} nlines={2} row1_ink={3} row1_maxx={4} row2_ink_on={5} row2_minx_on={6} gutter2_on={7} gutter3_on={8} | alt_z_off: nrows={9} row2_ink={10} row2_gutter={11} | alt_z_on2: nrows={12} row2_ink={13} gutter2={14}" -f `
            $result, $stOn.NRows, $stOn.LineCount, $r1.Count, $r1.MaxX, $r2.Count, $r2.MinX, $g2.Count, $g3.Count, `
            $stOff.NRows, $r2off.Count, $g2off.Count, $stOn2.NRows, $r2on2.Count, $g2on2.Count)
    if (-not $all) {
        Write-Check 'VERDICT' ("row1_fills={0} row2_continuation={1} gutter_only_row1={2} nrows_gt_nlines={3} off_nrows_eq_nlines={4} off_line_number_row2={5} on2_nrows_restored={6} on2_continuation={7}" -f `
                $a1, $a2, $b1, $c1, $d1, $d2, $d3, $d4)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     wrap=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     wrap=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     wrap=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
