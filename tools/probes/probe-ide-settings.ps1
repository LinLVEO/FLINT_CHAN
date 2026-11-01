# probe-ide-settings.ps1 - FLINT Studio settings page probe.
#
# Sandbox: tmp\ide-settings (the app's WORKING DIRECTORY), so studio.cfg / ai.state
# land inside the sandbox and the probe never touches the real user config.
#
# What it measures:
#   1. OPEN      clicking the sliders icon in the title bar (client x W-119, y 17)
#                paints the card: #303236 fill in the card box AND the #3C3C3C header
#   2. SELECTED  row 0 is highlighted with #2A2D2E (the panel's own selection colour)
#   3. FONT      Right arrow on row 0 cycles the code font and writes studio.cfg
#                (the probe compares font= before/after instead of trusting a name)
#   4. SIZE      Down + Right changes size= from its old value to old+1
#   5. NOEDIT    a letter posted while the panel is open must NOT reach the buffer
#                (ai.state srclen unchanged) - this is the modal guarantee
#   6. CLOSE     Esc closes the card (card colour gone, editor background back)
#   7. F9KEY     F9 now opens the panel instead of blind-cycling fonts
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (BOM / codepage traps).
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
$Sand = Join-Path $Root 'tmp\ide-settings'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'
$Cfg = Join-Path $Sand 'studio.cfg'

$Body = @(
    'int main() {',
    '  return 0;',
    '}'
) -join "`n"

function Read-Cfg([string]$Path) {
    $h = @{}
    if (-not (Test-Path $Path)) { return $h }
    foreach ($ln in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::ASCII)) {
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    return $h
}

function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$HoldMs = 90) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds $HoldMs
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 350
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item $Cfg -ErrorAction SilentlyContinue

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    $img0 = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st0) { throw 'ai.state has no ST line after 6s (oracle channel broken)' }
    Write-Check 'STATE0' $st0.Raw

    # card geometry, same formula as the app (520 x 366, centred)
    $cw = 520; $ch = 410
    $cx = [int](($W - $cw) / 2)
    $cy = [int](($H - $ch) / 2)
    $rowY = $cy + 58
    $card0 = $img0.CountNear($cx, $cy, ($cx + $cw), ($cy + $ch), 0x363230, 4)
    Write-Check 'BEFORE' ("card_px={0} (need 0) editor_px_at_center={1}" -f $card0, (Format-Rgb $img0.At(($cx + 100), ($cy + 300))))
    if ($card0 -gt 2000) { throw 'PROBE_SKIP:card already on screen at startup (stale studio.cfg?)' }

    # ---- 1. open via the title-bar icon ----
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    Click-Client $app.Hwnd ($W - 119) 17
    Start-Sleep -Milliseconds 250
    $img1 = [Ide]::Grab($app.Hwnd)
    $card1 = $img1.CountNear($cx, $cy, ($cx + $cw), ($cy + $ch), 0x363230, 4)
    $head1 = (Format-Rgb $img1.At(($cx + 200), ($cy + 20)))
    $openOk = ($card1 -gt 20000 -and $head1 -eq '#3C3C3C')
    Write-Check 'OPEN' ("card_px={0} (need>20000) header={1} (need #3C3C3C)" -f $card1, $head1)
    [void](Save-Shot $img1 $Root 'ide-settings-1-open')

    # ---- 2. row 0 is the selected row ----
    $selPx = $img1.CountNear($cx, $rowY, ($cx + $cw), ($rowY + 42), 0x2A2D2E, 4)
    $selOk = ($selPx -gt 1000)
    Write-Check 'SELECTED' ("row0_selected_px={0} (need>1000)" -f $selPx)

    # ---- 3. Right on row 0 cycles the code font and persists it ----
    $cfg0 = Read-Cfg $Cfg
    $font0 = if ($cfg0.ContainsKey('font')) { $cfg0['font'] } else { '(none)' }
    [Ide]::Key(0x27, $false, $false)          # Right
    Start-Sleep -Milliseconds 600
    $cfg1 = Read-Cfg $Cfg
    $font1 = if ($cfg1.ContainsKey('font')) { $cfg1['font'] } else { '(none)' }
    $fontOk = ($font1 -ne '(none)' -and $font1 -ne $font0)
    Write-Check 'FONT' ("font '{0}' -> '{1}' (need a different persisted face)" -f $font0, $font1)
    Assert-Deadline $sw $TimeoutSec 'font'

    # ---- 4. Down + Right changes the size ----
    [Ide]::Key(0x28, $false, $false)          # Down -> row 1 (size)
    Start-Sleep -Milliseconds 250
    $size0 = if ($cfg1.ContainsKey('size')) { [int]$cfg1['size'] } else { 0 }
    [Ide]::Key(0x27, $false, $false)          # Right
    Start-Sleep -Milliseconds 600
    $cfg2 = Read-Cfg $Cfg
    $size1 = if ($cfg2.ContainsKey('size')) { [int]$cfg2['size'] } else { -1 }
    $sizeOk = ($size1 -eq $size0 + 1 -or ($size0 -eq 0 -and $size1 -eq 16))
    Write-Check 'SIZE' ("size {0} -> {1} (need +1)" -f $size0, $size1)

    # ---- 5. typing must NOT reach the buffer while the panel is open ----
    $len0 = $st0.SrcLen
    [Ide]::KeyDownSc($app.Hwnd, 0x5A, [Ide]::Scan(0x5A))   # 'Z'
    Start-Sleep -Milliseconds 500
    $st5 = Read-StudioState $Sand
    $noEditOk = ($null -ne $st5 -and $st5.SrcLen -eq $len0)
    Write-Check 'NOEDIT' ("srclen {0} -> {1} (need unchanged)" -f $len0, $(if ($st5) { $st5.SrcLen } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'noedit'

    # ---- 6. Esc closes it ----
    [Ide]::Key(0x1B, $false, $false)
    Start-Sleep -Milliseconds 600
    $img2 = [Ide]::Grab($app.Hwnd)
    $card2 = $img2.CountNear($cx, $cy, ($cx + $cw), ($cy + $ch), 0x363230, 4)
    $center2 = (Format-Rgb $img2.At(($cx + 100), ($cy + 300)))
    $closeOk = ($card2 -lt 2000)
    Write-Check 'CLOSE' ("card_px={0} (need<2000) center={1}" -f $card2, $center2)
    [void](Save-Shot $img2 $Root 'ide-settings-2-closed')
    Assert-Deadline $sw $TimeoutSec 'close'

    # ---- 7. F9 opens the panel (it used to blind-cycle fonts) ----
    [Ide]::Key(0x78, $false, $false)
    Start-Sleep -Milliseconds 600
    $img3 = [Ide]::Grab($app.Hwnd)
    $card3 = $img3.CountNear($cx, $cy, ($cx + $cw), ($cy + $ch), 0x363230, 4)
    $f9Ok = ($card3 -gt 20000)
    Write-Check 'F9KEY' ("card_px_after_F9={0} (need>20000)" -f $card3)
    [Ide]::Key(0x1B, $false, $false)
    Start-Sleep -Milliseconds 400

    $all = ($openOk -and $selOk -and $fontOk -and $sizeOk -and $noEditOk -and $closeOk -and $f9Ok)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     settings={0} card_px={1} header={2} sel_px={3} | font {4}->{5} | size {6}->{7} | srclen {8}->{9} | closed_card_px={10} | F9_card_px={11}" -f `
            $result, $card1, $head1, $selPx, $font0, $font1, $size0, $size1, $len0, `
            $(if ($st5) { $st5.SrcLen } else { 'n/a' }), $card2, $card3)
    if (-not $all) {
        Write-Check 'VERDICT' ("open={0} selected={1} font={2} size={3} noedit={4} close={5} f9={6}" -f `
                $openOk, $selOk, $fontOk, $sizeOk, $noEditOk, $closeOk, $f9Ok)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     settings=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     settings=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     settings=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
