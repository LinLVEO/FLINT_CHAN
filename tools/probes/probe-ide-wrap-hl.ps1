# probe-ide-wrap-hl.ps1 - soft wrap must keep the comment colour on continuation rows.
#
# Regression for the reported bug: "触发视觉换行后，注释的高亮会失效".
# The sandbox file's line 1 is a long `// ...` comment that wraps into 2-3 display rows;
# line 2 is plain code. Assertion: the SECOND display row of that comment carries the
# comment colour (#6A9955) - before the fix it was painted as default code text (#CCCCCC).
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP.
# ASCII only on purpose.
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
$Sand = Join-Path $Root 'tmp\ide-wrap-hl'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'

# long comment (wraps), then two code lines
$Comment = '// ' + ('wrap comment padding text that is long enough to break into several display rows ' * 2)
$Body = $Comment + "`n" + 'int main() { return 0; }' + "`n" + 'int second = 2;' + "`n"

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($SrcFile, $Body, [System.Text.Encoding]::ASCII)
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    Write-Check 'SANDBOX' ("{0} bytes, line1={1} bytes" -f $Body.Length, $Comment.Length)

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear' }
        throw "PROBE_SKIP:$why"
    }
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    $img = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img) { throw 'no frame captured' }
    $W = $img.W; $H = $img.H
    $st = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st) { throw 'ai.state has no ST line' }
    Write-Check 'STATE' $st.Raw
    if ($st.NRows -le $st.LineCount) { throw "PROBE_SKIP:no wrap happened (nrows={0} nlines={1}); window too wide" -f $st.NRows, $st.LineCount }

    # row geometry: text starts at y = 34+6 = 40, line height = size+3 (default 14 -> 17)
    $lh = 20
    $row1 = 66      # title 34 + menu bar 26 + 6
    $row2 = 66 + $lh
    $c_com = 0x6A9955
    $row1Green = $img.CountNear(268, ($row1 - 3), ($W - 20), ($row1 + $lh - 2), $c_com, 40)
    $row2Green = $img.CountNear(268, ($row2 - 3), ($W - 20), ($row2 + $lh - 2), $c_com, 40)
    $row2All = (Get-InkStats $img 268 ($row2 - 3) ($W - 20) ($row2 + $lh - 2) 70).Count
    # the wrapped row must be comment-coloured: green ink dominates, plain text would be ~0 green
    $ok = ($row1Green -gt 40 -and $row2Green -gt 40 -and $row2Green -ge ($row2All * 0.5))
    Write-Check 'WRAPHL' ("row1_green_px={0} row2_green_px={1} row2_all_ink={2} (need row2 green >= half of its ink)" -f `
            $row1Green, $row2Green, $row2All)
    [void](Save-Shot $img $Root 'ide-wrap-hl')
    Assert-Deadline $sw $TimeoutSec 'wrap-hl'

    $result = if ($ok) { 'PASS' } else { 'FAIL' }
    $code = if ($ok) { 0 } else { 1 }
    Write-Host ("RESULT     wraplh={0} nrows={1} nlines={2} row1_green={3} row2_green={4} row2_ink={5}" -f `
            $result, $st.NRows, $st.LineCount, $row1Green, $row2Green, $row2All)
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     wraplh=SKIP reason=$why"
        $code = 2
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     wraplh=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
