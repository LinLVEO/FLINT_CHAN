# probe-ide-ime.ps1 - FLINT Studio: backspace while an IME composition is active.
#
# What the user reported (2026-10-27): with the Chinese IME, backspace deleted the IME's own
# pinyin first, and the letters that the auto-IME path had already inserted into the buffer were
# left behind. The fix rolls the app buffer back together with the IME's pinyin (lib
# flgui_win32.fl, auto branch of the VK_PROCESSKEY case).
#
# How it is measured without a real IME session: post WM_KEYDOWN with wParam = VK_PROCESSKEY(229)
# and a REAL scan code in lParam -- that is byte-for-byte what a Chinese-IME keystroke delivers
# on this machine (see tmp\dbg-ime.ps1 history; the app inserts the letter through the auto path).
#   LETTER   two IME keystrokes (a, b) -> srclen +2, caret +2
#   BACKSP   one IME backspace            -> srclen -1, caret -1 (the letter is rolled back too)
#   AGAIN    a new letter after that      -> +1 again (the ledger did not get out of sync)
#
# This probe needs the IME in native (Chinese) mode: if gui_ime_cn is 0 the letters never enter
# the auto path and LETTER fails -> that is reported as SKIP, not FAIL.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP.
# ASCII only on purpose (BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-ime'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$State = Join-Path $Sand 'ai.state'

$script:Ok = $true
$script:Fails = @()

function Check([string]$Tag, [bool]$Cond, [string]$Detail) {
    $mark = if ($Cond) { 'ok  ' } else { 'FAIL' }
    Write-Check $Tag ("{0} {1}" -f $mark, $Detail)
    if (-not $Cond) { $script:Ok = $false; $script:Fails += $Tag }
}

# WM_KEYDOWN as the IME delivers it: wParam = 229, lParam bits 16..23 = hardware scan code.
function Send-Ime([IntPtr]$Hwnd, [int]$Scan) {
    [void][Ide]::PostMessage($Hwnd, 0x0100, [IntPtr]229, [IntPtr]($Scan * 65536))
    Start-Sleep -Milliseconds 450
}

$app = $null
$code = 1
try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), "int main() {`n  return 0;`n}`n", (New-Object System.Text.ASCIIEncoding))
    Remove-Item $State -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw "PROBE_SKIP:window did not appear ($($app.Error))" }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'start'
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen' }
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st0) { throw 'ai.state has no ST line' }
    $len0 = $st0.SrcLen; $cur0 = $st0.Cur

    Send-Ime $app.Hwnd 0x1E      # 'a'
    Send-Ime $app.Hwnd 0x30      # 'b'
    $st1 = Read-StudioState $Sand
    $add = $st1.SrcLen - $len0
    if ($add -ne 2) {
        # 没有真的中文态（gui_ime_cn=0）⇒ auto 档不记字母，这条探针没东西可测
        Write-Host ("SKIP       auto-IME letters did not land (srclen {0} -> {1}); IME not in native mode?" -f $len0, $st1.SrcLen)
        Write-Host "RESULT     ime=SKIP(no-native-ime)"
        $code = 2
        throw "PROBE_SKIP:auto-IME path inactive (srclen $len0 -> $($st1.SrcLen))"
    }
    Check 'LETTER' ($add -eq 2 -and $st1.Cur -eq $cur0 + 2) ("2 IME letters -> srclen +{0}, caret +{1}" -f $add, ($st1.Cur - $cur0))

    Send-Ime $app.Hwnd 0x0E      # backspace scan code
    $st2 = Read-StudioState $Sand
    Check 'BACKSP' (($st2.SrcLen -eq $st1.SrcLen - 1) -and ($st2.Cur -eq $st1.Cur - 1)) `
        ("IME backspace -> srclen {0} -> {1}, caret {2} -> {3} (one auto letter rolled back)" -f $st1.SrcLen, $st2.SrcLen, $st1.Cur, $st2.Cur)

    Send-Ime $app.Hwnd 0x1E      # 'a' again
    $st3 = Read-StudioState $Sand
    Check 'AGAIN' (($st3.SrcLen -eq $st2.SrcLen + 1) -and ($st3.Cur -eq $st2.Cur + 1)) `
        ("next letter still lands: srclen {0} -> {1}" -f $st2.SrcLen, $st3.SrcLen)

    $code = if ($script:Ok) { 0 } else { 1 }
    Write-Host ("RESULT     ime={0} fails={1}" -f $(if ($script:Ok) { 'PASS' } else { 'FAIL' }), $(if ($script:Fails.Count -gt 0) { $script:Fails -join ',' } else { 'none' }))
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      {0}" -f $_.Exception.Message.Substring(11))
        if ($code -ne 2) { Write-Host "RESULT     ime=SKIP(env-contention)"; $code = 2 }
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     ime=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     ime=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
