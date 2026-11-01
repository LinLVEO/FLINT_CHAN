# probe-ide-sel.ps1 - FLINT Studio selection / copy / paste / undo / redo / select-all.
#
# Sandbox: tmp\ide-sel (the app's WORKING DIRECTORY).
#   The probe (re)writes apps\studio_native\main.fl with 10 short ASCII lines so the
#   drag lands inside real glyphs and the run is reproducible. Nothing is saved by
#   the app, so the file on disk is only read - its hash is checked before/after.
#
# What it measures (ai.state oracle + PrintWindow pixels):
#   1. a real left-button drag (400,74) -> (600,108) sets selon=1 and paints
#      > 200 px of selection background #264F78 inside the dragged band
#      (the app switched the text-selection colour to VS Code editor.selectionBackground
#       #264F78 on 2026-10-26 01:2x; the old #37373D was invisible on the dark editor)
#      See PROGRESS.md 2026-10-26 01:30 handoff block for the measurement that forced it.
#   2. Ctrl+C then Right + Ctrl+End (clears the selection, caret to EOF) then Ctrl+V:
#      srclen grows by the copied length (delta > 0)
#   3. Ctrl+Z restores the original srclen exactly; Ctrl+Y re-applies the same delta;
#      Ctrl+Z again returns to the original
#   4. Ctrl+A -> selon=1 and cur == srclen; copy-all + paste-over-all then keeps
#      srclen EXACTLY unchanged (the pasted bytes are the whole buffer itself)
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
$Sand = Join-Path $Root 'tmp\ide-sel'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'

# Deterministic short lines: no soft wrap, and x=400 / x=600 fall inside glyphs.
$Body = @(
    'int alpha = 100;   // selection sample line 01',
    'int beta = 200;    // selection sample line 02',
    'int gamma = 300;   // selection sample line 03',
    'int delta = 400;   // selection sample line 04',
    'int epsilon = 500; // selection sample line 05',
    'int zeta = 600;    // selection sample line 06',
    'int eta = 700;     // selection sample line 07',
    'int theta = 800;   // selection sample line 08',
    'int iota = 900;    // selection sample line 09',
    'int kappa = 1000;  // selection sample line 10'
) -join "`n"

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    $hash0 = (Get-FileHash $SrcFile).Hash
    Write-Check 'SANDBOX' ("{0} bytes={1} sha16={2}" -f $SrcFile, (Get-Item $SrcFile).Length, $hash0.Substring(0, 16))

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    $img0 = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 5000
    if ($null -eq $st0) { throw 'ai.state has no ST line after 5s (oracle channel broken)' }
    Write-Check 'STATE0' $st0.Raw
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }

    # Normalise a foreign click that may have landed while the window was still at its
    # default (120,90) position during startup: Ctrl+Home puts the caret at byte 0.
    if ($st0.Cur -ne 0) { Write-Check 'START_CARET' ("cur={0} (foreign click during startup) -> Ctrl+Home" -f $st0.Cur) }
    [Ide]::Key(0x24, $true, $false)    # Ctrl+Home
    [void](Wait-StudioStateWhere $Sand { param($s) $s.Cur -eq 0 } 3000)
    $st0 = Read-StudioState $Sand
    if ($null -eq $st0) { throw 'ai.state disappeared after Ctrl+Home' }
    $s0 = $st0.SrcLen
    if ($s0 -le 0) { throw "initial srclen is $s0" }
    Write-Check 'STATE0B' ("{0} (caret at start, srclen={1})" -f $st0.Raw, $s0)

    # ---- 1. real drag selection ----
    Invoke-DragClient $app.Hwnd 400 74 600 108 8 400 80
    $stSel = Wait-StudioStateWhere $Sand { param($s) $s.SelOn -eq 1 } 4000
    Start-Sleep -Milliseconds 250
    $imgSel = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $imgSel $Root 'ide-sel-1-drag')
    $selPx = $imgSel.CountNear(268, 73, 800, 110, 0x264F78, 8)
    $selOn = ($null -ne $stSel -and $stSel.SelOn -eq 1)
    $selOk = ($selOn -and $selPx -gt 200)
    Write-Check 'SELECT' ("selon={0} cur={1} sel_bg_px={2} (need>200, region x268..800 y73..110)" -f `
            $(if ($stSel) { $stSel.SelOn } else { 'n/a' }), $(if ($stSel) { $stSel.Cur } else { 'n/a' }), $selPx)
    Assert-Deadline $sw $TimeoutSec 'select'

    # ---- 2. copy, clear selection, caret to EOF, paste ----
    [Ide]::Key(0x43, $true, $false)    # Ctrl+C
    Start-Sleep -Milliseconds 250
    [Ide]::Key(0x27, $false, $false)   # Right: a non-shift arrow clears the selection
    Start-Sleep -Milliseconds 150
    [Ide]::Key(0x23, $true, $false)    # Ctrl+End -> g_cur = g_srclen
    $stAtEnd = Wait-StudioStateWhere $Sand { param($s) $s.Cur -eq $s.SrcLen -and $s.SelOn -eq 0 } 3000
    $atEnd = ($null -ne $stAtEnd -and $stAtEnd.Cur -eq $stAtEnd.SrcLen -and $stAtEnd.SelOn -eq 0)
    Write-Check 'CARET_EOF' ("cur={0} srclen={1} selon={2} (need cur==srclen, selon=0)" -f `
            $(if ($stAtEnd) { $stAtEnd.Cur } else { 'n/a' }), $(if ($stAtEnd) { $stAtEnd.SrcLen } else { 'n/a' }), $(if ($stAtEnd) { $stAtEnd.SelOn } else { 'n/a' }))
    [Ide]::Key(0x56, $true, $false)    # Ctrl+V
    $stPaste = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -ne $s0 } 4000
    $s1 = if ($stPaste) { $stPaste.SrcLen } else { $s0 }
    $delta = $s1 - $s0
    $pasteOk = ($delta -gt 0)
    Write-Check 'PASTE' ("srclen {0} -> {1} delta={2} (copied length, need>0) cur={3}" -f $s0, $s1, $delta, $(if ($stPaste) { $stPaste.Cur } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'paste'

    # ---- 3. undo / redo / undo ----
    [Ide]::Key(0x5A, $true, $false)    # Ctrl+Z
    $stUndo = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $s0 } 4000
    $undoOk = ($null -ne $stUndo -and $stUndo.SrcLen -eq $s0)
    Write-Check 'UNDO' ("srclen={0} (need {1}) cur={2} delta_vs_original={3}" -f `
            $(if ($stUndo) { $stUndo.SrcLen } else { 'n/a' }), $s0, $(if ($stUndo) { $stUndo.Cur } else { 'n/a' }), $(if ($stUndo) { $stUndo.SrcLen - $s0 } else { 'n/a' }))
    [Ide]::Key(0x59, $true, $false)    # Ctrl+Y
    $stRedo = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $s1 } 4000
    $redoOk = ($null -ne $stRedo -and $stRedo.SrcLen -eq $s1)
    Write-Check 'REDO' ("srclen={0} (need {1}) delta={2} (need {3})" -f `
            $(if ($stRedo) { $stRedo.SrcLen } else { 'n/a' }), $s1, $(if ($stRedo) { $stRedo.SrcLen - $s0 } else { 'n/a' }), $delta)
    [Ide]::Key(0x5A, $true, $false)    # Ctrl+Z
    $stUndo2 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $s0 } 4000
    $undo2Ok = ($null -ne $stUndo2 -and $stUndo2.SrcLen -eq $s0)
    Write-Check 'UNDO2' ("srclen={0} (need {1})" -f $(if ($stUndo2) { $stUndo2.SrcLen } else { 'n/a' }), $s0)
    Assert-Deadline $sw $TimeoutSec 'undo-redo'

    # ---- 4. select all ----
    [Ide]::Key(0x41, $true, $false)    # Ctrl+A
    $stAll = Wait-StudioStateWhere $Sand { param($s) $s.SelOn -eq 1 -and $s.Cur -eq $s.SrcLen } 4000
    $allOk = ($null -ne $stAll -and $stAll.SelOn -eq 1 -and $stAll.Cur -eq $stAll.SrcLen)
    Write-Check 'SELECT_ALL' ("selon={0} cur={1} srclen={2} (need selon=1 and cur==srclen)" -f `
            $(if ($stAll) { $stAll.SelOn } else { 'n/a' }), $(if ($stAll) { $stAll.Cur } else { 'n/a' }), $(if ($stAll) { $stAll.SrcLen } else { 'n/a' }))
    $imgAll = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $imgAll $Root 'ide-sel-2-selectall')
    $allBgPx = $imgAll.CountNear(268, 40, 900, 500, 0x264F78, 8)
    Write-Check 'SELECT_ALL_PX' ("sel_bg_px={0} (region x268..900 y40..500)" -f $allBgPx)

    # copy-all + paste-over-all: replacement by identical bytes must not change srclen
    [Ide]::Key(0x43, $true, $false)    # Ctrl+C (whole buffer)
    Start-Sleep -Milliseconds 250
    [Ide]::Key(0x56, $true, $false)    # Ctrl+V (replaces the whole-buffer selection)
    $stSame = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $s0 -and $s.SelOn -eq 0 } 5000
    $exactOk = ($null -ne $stSame -and $stSame.SrcLen -eq $s0)
    Write-Check 'COPY_ALL_EXACT' ("srclen={0} (need {1} = original) selon={2} cur={3}" -f `
            $(if ($stSame) { $stSame.SrcLen } else { 'n/a' }), $s0, $(if ($stSame) { $stSame.SelOn } else { 'n/a' }), $(if ($stSame) { $stSame.Cur } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'select-all'

    $hash1 = (Get-FileHash $SrcFile).Hash
    $diskOk = ($hash0 -eq $hash1)
    Write-Check 'DISK' ("sha16 before={0} after={1} unchanged={2}" -f $hash0.Substring(0, 16), $hash1.Substring(0, 16), $diskOk)

    $all = ($selOk -and $atEnd -and $pasteOk -and $undoOk -and $redoOk -and $undo2Ok -and $allOk -and $exactOk -and $diskOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     sel={0} selon={1} sel_bg_px={2} | srclen0={3} paste_delta={4} srclen_paste={5} | undo_srclen={6} redo_srclen={7} undo2_srclen={8} | select_all_selon={9} select_all_cur={10} copy_all_srclen={11} disk_unchanged={12}" -f `
            $result, $(if ($stSel) { $stSel.SelOn } else { 'n/a' }), $selPx, $s0, $delta, $s1, `
            $(if ($stUndo) { $stUndo.SrcLen } else { 'n/a' }), $(if ($stRedo) { $stRedo.SrcLen } else { 'n/a' }), $(if ($stUndo2) { $stUndo2.SrcLen } else { 'n/a' }), `
            $(if ($stAll) { $stAll.SelOn } else { 'n/a' }), $(if ($stAll) { $stAll.Cur } else { 'n/a' }), $(if ($stSame) { $stSame.SrcLen } else { 'n/a' }), $diskOk)
    if (-not $all) {
        Write-Check 'VERDICT' ("selection={0} caret_eof={1} paste_grows={2} undo_restores={3} redo_reapplies={4} undo2_restores={5} select_all={6} copy_all_exact={7} disk_unchanged={8}" -f `
                $selOk, $atEnd, $pasteOk, $undoOk, $redoOk, $undo2Ok, $allOk, $exactOk, $diskOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     sel=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     sel=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     sel=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code

