# probe-ide-find.ps1 - FLINT Studio find bar probe (Ctrl+F, type, Enter, Enter, Esc).
#
# Sandbox: tmp\ide-find (the app's WORKING DIRECTORY). The probe (re)writes
# apps\studio_native\main.fl with 4 lines that contain exactly four "int" tokens
# at known byte offsets; the match offsets are re-scanned from the file itself so
# the assertions never trust a hardcoded number.
#
# Typing note (measured, not assumed): this app runs the keyboard tier (kbd=1), so
# WM_CHAR is ignored and characters are produced from WM_KEYDOWN scan codes; on this
# machine the physical path is also routed through a Chinese IME. The probe therefore
# posts one WM_KEYDOWN per character (with the real scan code) - byte-for-byte the
# message a real keystroke delivers - which makes the query deterministic without
# touching the machine's IME. Enter/Esc stay physical SendInput; if the IME eats the
# first Enter the probe presses it once more and reports `enter_presses` (the main
# agent measured that behaviour on this machine).
#
# What it measures:
#   1. Ctrl+F draws the 26 px find bar: #252526 pixels in y=34..60 AND the first
#      editor text row moves down by exactly 26 px (glyph-top y 45 -> 71)
#   2. the typed query is visible in the bar (ink in x 272..330 grows)
#   3. Enter puts the caret on a match: ai.state cur changes, the 3 bytes at cur are
#      "int", the match is selected (selon=1) and #264F78 selection px are painted
#      (text-selection colour changed to VS Code editor.selectionBackground #264F78 on 2026-10-26)
#   4. Enter again moves cur to a different "int" match
#   5. Esc removes the bar (band back to background) and restores row 1 to y=45
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
$Sand = Join-Path $Root 'tmp\ide-find'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'
$Keyword = 'int'

# Line 1 is long enough to wrap and to keep ink at x 700..900 on visual row 1.
$Body = @(
    'int alpha = 1;   // find probe padding line: the editor is wide enough that this row fills the width',
    'int beta = 2;',
    'int gamma = 3;',
    'int main() { return 0; }'
) -join "`n"

function First-InkY([Frame]$Img, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1) {
    for ($y = $Y0; $y -lt $Y1; $y++) {
        for ($x = $X0; $x -lt $X1; $x++) {
            $c = $Img.At($x, $y)
            $r = ($c -shr 16) -band 255; $g = ($c -shr 8) -band 255; $b = $c -band 255
            if ($r -gt 70 -or $g -gt 70 -or $b -gt 70) { return $y }
        }
    }
    return -1
}

# Find all case-insensitive ASCII occurrences of $Needle in a byte[].
function Find-Matches([byte[]]$Bytes, [string]$Needle) {
    $out = New-Object System.Collections.Generic.List[int]
    $nb = [System.Text.Encoding]::ASCII.GetBytes($Needle.ToLowerInvariant())
    for ($i = 0; $i + $nb.Length -le $Bytes.Length; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $nb.Length; $j++) {
            $c = $Bytes[$i + $j]
            if ($c -ge 65 -and $c -le 90) { $c += 32 }
            if ($c -ne $nb[$j]) { $ok = $false; break }
        }
        if ($ok) { $out.Add($i) }
    }
    return $out
}

function Press-EnterUntilChange([string]$Dir, [long]$OldCur, [int]$MaxPresses = 2) {
    $presses = 0
    $st = $null
    for ($i = 0; $i -lt $MaxPresses; $i++) {
        [Ide]::Key(0x0D, $false, $false)
        $presses++
        $st = Wait-StudioStateWhere $Dir { param($s) $s.Cur -ne $OldCur } 2500
        if ($null -ne $st -and $st.Cur -ne $OldCur) { break }
    }
    return @{ State = $st; Presses = $presses }
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    $bytes = [System.IO.File]::ReadAllBytes($SrcFile)
    $matches = Find-Matches $bytes $Keyword
    if ($matches.Count -lt 2) { throw "PROBE_SKIP:sandbox file has $($matches.Count) '$Keyword' match(es), need >=2" }
    Write-Check 'SANDBOX' ("{0} bytes={1} keyword={2} matches={3} at=[{4}]" -f $SrcFile, $bytes.Length, $Keyword, $matches.Count, ($matches -join ','))

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
# Park the cursor away from the title-bar buttons: the app caches the last WM_MOUSEMOVE
# client position, so after Position-Window a stale hover can paint the settings button (#505050)
# and the old ink scan (x 700..900) mistook it for editor text.
[Ide]::MoveClient($app.Hwnd, 500, 400)
Start-Sleep -Milliseconds 150
    $img0 = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 5000
    if ($null -eq $st0) { throw 'ai.state has no ST line after 5s (oracle channel broken)' }
    $rowY0 = First-InkY $img0 700 860 60 130
    $bar0 = $img0.CountNear(220, 61, $W, 85, 0x252526, 4)
    Write-Check 'STATE0' $st0.Raw
    Write-Check 'BEFORE' ("row1_glyph_y={0} find_band_bg_px={1} (region x220..W y35..59)" -f $rowY0, $bar0)
    if ($rowY0 -lt 0) { throw 'no ink found at x 700..900 on the first text row (sandbox line 1 too short)' }
    [void](Save-Shot $img0 $Root 'ide-find-0-start')

    # ---- 1. Ctrl+F ----
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    [Ide]::Key(0x46, $true, $false)
    Start-Sleep -Milliseconds 700
    $img1 = [Ide]::Grab($app.Hwnd)
    $bar1 = $img1.CountNear(220, 61, $W, 85, 0x252526, 4)
    $rowY1 = First-InkY $img1 700 860 91 160
    $barOk = ($bar1 -gt 8000)
    $shiftOk = ([Math]::Abs(($rowY1 - $rowY0) - 26) -le 2)
    Write-Check 'CTRL_F' ("find_band_bg_px={0} (need>8000) row1_glyph_y={1} (was {2}, need +26)" -f $bar1, $rowY1, $rowY0)
    [void](Save-Shot $img1 $Root 'ide-find-1-bar')

    # ---- 2. type the query (one posted key message per char, real scan code) ----
    $ink0 = (Get-InkStats $img1 272 62 330 84 70).Count
    foreach ($ch in $Keyword.ToCharArray()) {
        $vk = [int][char]([string]$ch).ToUpperInvariant()
        [Ide]::KeyDownSc($app.Hwnd, $vk, [Ide]::Scan($vk))
        Start-Sleep -Milliseconds 160
    }
    Start-Sleep -Milliseconds 350
    $img2 = [Ide]::Grab($app.Hwnd)
    $ink1 = (Get-InkStats $img2 272 62 330 84 70).Count
    $typedOk = ($ink1 -gt $ink0 + 20)
    Write-Check 'TYPE' ("query={0} bar_ink_px {1} -> {2} (need +20; region x272..330 y36..58)" -f $Keyword, $ink0, $ink1)
    [void](Save-Shot $img2 $Root 'ide-find-2-typed')
    Assert-Deadline $sw $TimeoutSec 'type'

    # ---- 3. Enter -> jump to a match ----
    $cur0 = $st0.Cur
    $r1 = Press-EnterUntilChange $Sand $cur0 2
    $st1 = $r1.State
    $hitOk = $false
    $bytes1 = 'n/a'
    if ($null -ne $st1) {
        $b1 = [System.IO.File]::ReadAllBytes($SrcFile)
        if ($st1.Cur + $Keyword.Length -le $b1.Length) {
            $bytes1 = [System.Text.Encoding]::ASCII.GetString($b1, [int]$st1.Cur, $Keyword.Length)
        }
        $hitOk = ($st1.Cur -ne $cur0 -and $st1.SelOn -eq 1 -and $bytes1 -eq $Keyword)
    }
    $img3 = [Ide]::Grab($app.Hwnd)
    $selPx = $img3.CountNear(268, 60, $W - 20, 500, 0x264F78, 8)
    Write-Check 'ENTER1' ("cur {0} -> {1} presses={2} selon={3} bytes_at_cur={4} sel_bg_px={5}" -f `
            $cur0, $(if ($st1) { $st1.Cur } else { 'n/a' }), $r1.Presses, $(if ($st1) { $st1.SelOn } else { 'n/a' }), $bytes1, $selPx)
    [void](Save-Shot $img3 $Root 'ide-find-3-hit1')
    Assert-Deadline $sw $TimeoutSec 'enter1'

    # ---- 4. Enter again -> next match ----
    $cur1 = if ($st1) { $st1.Cur } else { $cur0 }
    $r2 = Press-EnterUntilChange $Sand $cur1 2
    $st2 = $r2.State
    $nextOk = $false
    $bytes2 = 'n/a'
    if ($null -ne $st2) {
        $b2 = [System.IO.File]::ReadAllBytes($SrcFile)
        if ($st2.Cur + $Keyword.Length -le $b2.Length) {
            $bytes2 = [System.Text.Encoding]::ASCII.GetString($b2, [int]$st2.Cur, $Keyword.Length)
        }
        $nextOk = ($st2.Cur -ne $cur1 -and $st2.SelOn -eq 1 -and $bytes2 -eq $Keyword)
    }
    Write-Check 'ENTER2' ("cur {0} -> {1} presses={2} selon={3} bytes_at_cur={4}" -f `
            $cur1, $(if ($st2) { $st2.Cur } else { 'n/a' }), $r2.Presses, $(if ($st2) { $st2.SelOn } else { 'n/a' }), $bytes2)
    Assert-Deadline $sw $TimeoutSec 'enter2'

    # ---- 5. Esc closes the bar ----
    [Ide]::Key(0x1B, $false, $false)
    Start-Sleep -Milliseconds 700
    $img4 = [Ide]::Grab($app.Hwnd)
    $bar4 = $img4.CountNear(220, 61, $W, 85, 0x252526, 4)
    $rowY4 = First-InkY $img4 700 860 60 130
    $escOk = ($bar4 -lt 300 -and [Math]::Abs($rowY4 - $rowY0) -le 2)
    Write-Check 'ESC' ("find_band_bg_px={0} (need<300) row1_glyph_y={1} (need {2})" -f $bar4, $rowY4, $rowY0)
    [void](Save-Shot $img4 $Root 'ide-find-4-esc')
    Assert-Deadline $sw $TimeoutSec 'esc'

    $all = ($barOk -and $shiftOk -and $typedOk -and $hitOk -and $nextOk -and $escOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     find={0} bar_bg={1} row1_y={2}->{3}(+{4}) bar_ink={5}->{6} | cur0={7} cur1={8}({9}) cur2={10}({11}) selon={12} sel_bg_px={13} enter_presses={14},{15} | esc_bar_bg={16} esc_row1_y={17} matches=[{18}]" -f `
            $result, $bar1, $rowY0, $rowY1, ($rowY1 - $rowY0), $ink0, $ink1, $cur0, `
            $(if ($st1) { $st1.Cur } else { 'n/a' }), $bytes1, $(if ($st2) { $st2.Cur } else { 'n/a' }), $bytes2, `
            $(if ($st1) { $st1.SelOn } else { 'n/a' }), $selPx, $r1.Presses, $r2.Presses, $bar4, $rowY4, ($matches -join ','))
    if (-not $all) {
        Write-Check 'VERDICT' ("bar_drawn={0} row_shift_26={1} query_visible={2} first_jump={3} next_jump={4} esc_restores={5}" -f `
                $barOk, $shiftOk, $typedOk, $hitOk, $nextOk, $escOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     find=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     find=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     find=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code

