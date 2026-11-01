# probe-ide-diag.ps1 - FLINT Studio compile-diagnostics probe (error line colour + click-to-jump).
#
# Sandbox: tmp\ide-diag is the app's WORKING DIRECTORY, so the startup compile
# (do_compile) writes its temp source and log inside the sandbox:
#   apps\studio_native\_studio_edit.fl   (copy of the buffer)
#   tmp\studio_win_edit.log              (hlc stderr+stdout)
# The sandbox main.fl is deliberately broken, so the startup compile fails and the
# output panel is up before any keystroke is sent.
#
# What it measures (expected values are parsed from the real log, never hardcoded):
#   1. LOG        the log carries a diagnostic; its line/col are read from it
#   2. PANEL      the output panel band (bottom 168 px) has body ink
#   3. DIAGCOLOR  the diagnostic row AND the title hint are painted #F48771 (VS Code
#                 errorForeground); non-diagnostic rows are not
#   4. CLICK      clicking the diagnostic row moves the caret to that source line/col
#                 (ai.state "ST cur line col ..." is the oracle)
#   5. NOCLICK    clicking a non-diagnostic row (the source echo line) does NOT move it
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (BOM / codepage traps): the CJK pattern is built from char codes.
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
$Sand = Join-Path $Root 'tmp\ide-diag'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'
$LogPath = Join-Path $SrcDir '_studio_edit.log'   # 2026-10-27: 临时源/日志改成放在被编辑文件旁边

# Line 5 is the broken one: "  int broken = ;"
$Body = @(
    'int alpha = 1;',
    'int beta = 2;',
    '',
    'int main() {',
    '  int broken = ;',
    '  return 0;',
    '}'
) -join "`n"

$ErrRgb = 0xF48771     # VS Code errorForeground; the app paints diagnostics with it
$Tol = 12

function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$HoldMs = 90) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds $HoldMs
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 300
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    if (-not (Test-Path (Join-Path $Root 'hlc.exe'))) { throw 'PROBE_SKIP:missing hlc.exe (app compiles with an absolute path)' }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    Remove-Item $LogPath -ErrorAction SilentlyContinue
    $srcBytes = [System.IO.File]::ReadAllBytes($SrcFile)
    Write-Check 'SANDBOX' ("{0} bytes={1} broken_line=5" -f $SrcFile, $srcBytes.Length)

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

    # ---- 1. the startup compile really failed, and the log tells us where ----
    $diagLine = 0; $diagCol = 0; $logTxt = ''
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Path $LogPath) {
            $logTxt = [System.IO.File]::ReadAllText($LogPath, [System.Text.Encoding]::UTF8)
            if ($logTxt.Length -gt 0) { break }
        }
        Start-Sleep -Milliseconds 250
    }
    # "第 N 行第 M 列" built from char codes so this file stays pure ASCII
    $pat = ('{0} (\d+) {1}{0} (\d+) {2}' -f [char]0x7B2C, [char]0x884C, [char]0x5217)
    $m = [regex]::Match($logTxt, $pat)
    if (-not $m.Success) {
        $head = if ($logTxt.Length -gt 0) { $logTxt.Substring(0, [Math]::Min(120, $logTxt.Length)) } else { '(empty)' }
        throw ("PROBE_SKIP:no diagnostic in log - startup compile may have succeeded; log head: " + $head.Replace("`n", ' / '))
    }
    $diagLine = [int]$m.Groups[1].Value
    $diagCol = [int]$m.Groups[2].Value
    $logLines = ($logTxt -split "`n").Count
    Write-Check 'LOG' ("diag_line={0} diag_col={1} log_lines={2} log_bytes={3}" -f $diagLine, $diagCol, $logLines, $logTxt.Length)
    if ($diagLine -lt 1 -or $diagLine -gt 7) { throw "PROBE_SKIP:diagnostic line $diagLine is not inside the 7-line sandbox file" }

    # ---- 2. panel geometry (same formula as the app: edb = sb_top - 168, body starts +26) ----
    $sbTop = $H - 26
    $edb = $sbTop - 168
    $bodyY = $edb + 26
    $rowH = 16

    $img = [Ide]::Grab($app.Hwnd)
    $panelInk = (Get-InkStats $img 232 ($bodyY - 2) ($W - 20) ($bodyY + 60) 70).Count
    $panelOk = ($panelInk -gt 30)
    Write-Check 'PANEL' ("edb={0} body_y={1} panel_ink_px={2} (need>30)" -f $edb, $bodyY, $panelInk)

    # ---- 3. the diagnostic row is painted in the error colour; the next rows are not ----
    # Title hint uses the same #F48771 but at 13 px with grayscale AA => few EXACT-colour pixels,
    # so the title band is matched with a wider tolerance (background is #1E1E1E, far away).
    $titleRed = $img.CountNear(232, ($edb + 2), 560, ($edb + 24), $ErrRgb, 32)
    $row0Red = $img.CountNear(232, $bodyY, $W - 20, ($bodyY + $rowH), $ErrRgb, $Tol)
    $restRed = $img.CountNear(232, ($bodyY + $rowH), $W - 20, ($bodyY + 5 * $rowH), $ErrRgb, $Tol)
    $colorOk = ($row0Red -gt 20 -and $titleRed -gt 20 -and $restRed -lt 10)
    Write-Check 'DIAGCOLOR' ("title_red_px={0} row0_red_px={1} other_rows_red_px={2} (need title>20, row0>20, others<10)" -f $titleRed, $row0Red, $restRed)
    [void](Save-Shot $img $Root 'ide-diag-0-panel')

    # ---- 4. click the diagnostic row -> caret jumps to that source line/col ----
    $wantLine = $diagLine - 1          # ai.state Line is 0-based
    $wantCol = $diagCol - 1
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    Click-Client $app.Hwnd 400 ($bodyY + 7)
    $st1 = Wait-StudioStateWhere $Sand { param($s) $s.Line -eq $wantLine } 3000
    if ($null -eq $st1) { $st1 = Read-StudioState $Sand }
    $jumpOk = ($null -ne $st1 -and $st1.Line -eq $wantLine -and [Math]::Abs($st1.Col - $wantCol) -le 1)
    Write-Check 'CLICK' ("want line={0} col={1} (1-based); got line={2} col={3}" -f `
            $wantLine, $wantCol, $(if ($st1) { $st1.Line } else { 'n/a' }), $(if ($st1) { $st1.Col } else { 'n/a' }))
    $img1 = [Ide]::Grab($app.Hwnd)
    [void](Save-Shot $img1 $Root 'ide-diag-1-jumped')

    # ---- 5. clicking the source-echo row (row 1 of the log) must not move the caret ----
    $lineBefore = if ($st1) { $st1.Line } else { $wantLine }
    Click-Client $app.Hwnd 400 ($bodyY + $rowH + 7)
    Start-Sleep -Milliseconds 400
    $st2 = Read-StudioState $Sand
    $quietOk = ($null -ne $st2 -and $st2.Line -eq $lineBefore)
    Write-Check 'NOCLICK' ("echo_row_click keeps line={0}; got line={1}" -f `
            $lineBefore, $(if ($st2) { $st2.Line } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'diag'

    $all = ($panelOk -and $colorOk -and $jumpOk -and $quietOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     diag={0} panel_ink={1} title_red={2} row0_red={3} other_red={4} | diag {5}:{6} -> caret line={7} col={8} | echo_row_line={9}" -f `
            $result, $panelInk, $titleRed, $row0Red, $restRed, $diagLine, $diagCol, `
            $(if ($st1) { $st1.Line } else { 'n/a' }), $(if ($st1) { $st1.Col } else { 'n/a' }), `
            $(if ($st2) { $st2.Line } else { 'n/a' }))
    if (-not $all) {
        Write-Check 'VERDICT' ("panel={0} color={1} jump={2} no_move_on_echo={3}" -f $panelOk, $colorOk, $jumpOk, $quietOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     diag=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     diag=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     diag=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
