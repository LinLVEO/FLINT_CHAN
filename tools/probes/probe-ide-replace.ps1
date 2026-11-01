# probe-ide-replace.ps1 - FLINT Studio replace bar probe (Ctrl+H, Tab, type, Enter, Ctrl+Enter, Esc).
#
# Sandbox: tmp\ide-replace (the app's WORKING DIRECTORY). The probe (re)writes
# apps\studio_native\main.fl with 4 lines, each containing exactly one "int" token
# (4 matches total). Expected content is computed by the probe itself, never hardcoded.
#
# What it measures (all from files on disk after Ctrl+S, so no pixel guessing):
#   1. Ctrl+H opens the two-row bar: the first editor text row moves down by 52 px
#      (single-row Ctrl+F shifts 26) - band background #252526 must cover the 2nd row too
#   2. typing "int" into the find row, Tab (focus -> replace row), typing "float",
#      Enter -> exactly ONE "int" became "float" (file read back after Ctrl+S)
#   3. Ctrl+Enter -> ALL remaining "int" became "float" (4 total, 0 left)
#   4. Esc closes the bar and restores row 1 to its original y
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (avoid BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 180,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$result = 'FAIL'
$code = 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-replace'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'
$Find = 'int'
$Rep = 'float'

$Body = @(
    'int a1 = 1;   // replace probe padding line: wide enough that this row fills the editor width',
    'int b2 = 2;',
    'int c3 = 3;',
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

function Count-Word([string]$Path, [string]$Word) {
    $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII)
    return ([regex]::Matches($t, [regex]::Escape($Word))).Count
}

function Type-Text([IntPtr]$Hwnd, [string]$Text) {
    foreach ($ch in $Text.ToCharArray()) {
        $vk = [int][char]([string]$ch).ToUpperInvariant()
        [Ide]::KeyDownSc($Hwnd, $vk, [Ide]::Scan($vk))
        Start-Sleep -Milliseconds 170
    }
}

function Save-Now([IntPtr]$Hwnd, [string]$Dir) {
    [Ide]::Key(0x53, $true, $false)
    Start-Sleep -Milliseconds 500
    [void](Wait-StudioStateWhere $Dir { param($s) $true } 1500)
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    $n0 = Count-Word $SrcFile $Find
    if ($n0 -lt 2) { throw "PROBE_SKIP:sandbox file has $n0 '$Find' token(s), need >=2" }
    Write-Check 'SANDBOX' ("{0} find={1} x{2} replace={3}" -f $SrcFile, $Find, $n0, $Rep)

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 400)
    Start-Sleep -Milliseconds 150
    $img0 = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 5000
    if ($null -eq $st0) { throw 'ai.state has no ST line after 5s (oracle channel broken)' }
    $rowY0 = First-InkY $img0 700 860 60 140
    Write-Check 'BEFORE' ("row1_glyph_y={0} srclen={1}" -f $rowY0, $st0.SrcLen)
    if ($rowY0 -lt 0) { throw 'no ink found at x 700..900 on the first text row' }

    # ---- 1. Ctrl+H -> two-row bar (editor shifts by 52) ----
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    [Ide]::Key(0x48, $true, $false)
    Start-Sleep -Milliseconds 800
    $img1 = [Ide]::Grab($app.Hwnd)
    # NOTE: scan from y=110 on purpose - the replace row's hint text ("Enter 替换 · ...") starts at
    # x=420 and can reach into x 700..860 at y 67..105, which would be mistaken for editor text.
    $rowY1 = First-InkY $img1 700 860 110 200
    $bar1 = $img1.CountNear(220, 36, $W, 86, 0x252526, 4)
    $barOk = ($bar1 -gt 12000)
    $shiftOk = ([Math]::Abs(($rowY1 - $rowY0) - 52) -le 2)
    Write-Check 'CTRL_H' ("band_bg_px={0} (need>12000, two rows) row1_y={1} (was {2}, need +52)" -f $bar1, $rowY1, $rowY0)
    [void](Save-Shot $img1 $Root 'ide-replace-1-bar')

    # ---- 2. type find string, Tab, type replace string ----
    Type-Text $app.Hwnd $Find
    Start-Sleep -Milliseconds 250
    [Ide]::Key(0x09, $false, $false)      # Tab -> replace field
    Start-Sleep -Milliseconds 250
    Type-Text $app.Hwnd $Rep
    Start-Sleep -Milliseconds 350
    $img2 = [Ide]::Grab($app.Hwnd)
    $inkRow2 = (Get-InkStats $img2 272 62 400 88 70).Count
    $typedOk = ($inkRow2 -gt 40)
    Write-Check 'TYPE' ("replace_row_ink_px={0} (need>40; region x272..400 y63..87)" -f $inkRow2)
    [void](Save-Shot $img2 $Root 'ide-replace-2-typed')
    Assert-Deadline $sw $TimeoutSec 'type'

    # ---- 3. Enter -> replace exactly one ----
    [Ide]::Key(0x0D, $false, $false)
    Start-Sleep -Milliseconds 600
    Save-Now $app.Hwnd $Sand
    $nFind1 = Count-Word $SrcFile $Find
    $nRep1 = Count-Word $SrcFile $Rep
    $oneOk = ($nFind1 -eq ($n0 - 1) -and $nRep1 -eq 1)
    Write-Check 'REPLACE1' ("find {0}->{1} (need {2}) replace_count={3} (need 1)" -f $n0, $nFind1, ($n0 - 1), $nRep1)
    Assert-Deadline $sw $TimeoutSec 'replace1'

    # ---- 4. Ctrl+Enter -> replace all ----
    [Ide]::Key(0x0D, $true, $false)
    Start-Sleep -Milliseconds 700
    Save-Now $app.Hwnd $Sand
    $nFind2 = Count-Word $SrcFile $Find
    $nRep2 = Count-Word $SrcFile $Rep
    $allOk = ($nFind2 -eq 0 -and $nRep2 -eq $n0)
    Write-Check 'REPLACE_ALL' ("find_count={0} (need 0) replace_count={1} (need {2})" -f $nFind2, $nRep2, $n0)
    Assert-Deadline $sw $TimeoutSec 'replaceall'

    # ---- 5. Esc closes the bar ----
    [Ide]::Key(0x1B, $false, $false)
    Start-Sleep -Milliseconds 700
    $img4 = [Ide]::Grab($app.Hwnd)
    $bar4 = $img4.CountNear(220, 61, $W, 95, 0x252526, 4)
    $rowY4 = First-InkY $img4 700 860 60 140
    $escOk = ($bar4 -lt 300 -and [Math]::Abs($rowY4 - $rowY0) -le 2)
    Write-Check 'ESC' ("band_bg_px={0} (need<300) row1_y={1} (need {2})" -f $bar4, $rowY4, $rowY0)

    $all = ($barOk -and $shiftOk -and $typedOk -and $oneOk -and $allOk -and $escOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     replace={0} band_px={1} row1_y={2}->{3}(+{4}) replace_row_ink={5} | int {6}->{7}->{8} float 0->{9}->{10} | esc_band={11} esc_row_y={12}" -f `
            $result, $bar1, $rowY0, $rowY1, ($rowY1 - $rowY0), $inkRow2, $n0, $nFind1, $nFind2, $nRep1, $nRep2, $bar4, $rowY4)
    if (-not $all) {
        Write-Check 'VERDICT' ("two_row_bar={0} shift52={1} replace_typed={2} replace_one={3} replace_all={4} esc_restores={5}" -f `
                $barOk, $shiftOk, $typedOk, $oneOk, $allOk, $escOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     replace=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     replace=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     replace=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
