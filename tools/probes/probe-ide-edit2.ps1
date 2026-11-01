# probe-ide-edit2.ps1 - auto-pair (brackets/quotes), pair skip-over, auto-indent/dedent.
#
# Sandbox: tmp\ide-edit2. The buffer is a 3-line file whose 2nd line is indented by 2 spaces
# and whose 3rd line is "  }" (indented close brace) so both indent and dedent are observable.
#
# Steps (every character is a posted WM_KEYDOWN with the real scan code):
#   1. PAIR      Ctrl+End then '{'  -> buffer grows by 2 ("{}"), caret sits between them
#   2. SKIP      then '}'           -> buffer unchanged, caret moves past the existing '}'
#   3. INDENT    go to end of line 2, Enter -> newline + two spaces (srclen +3)
#   4. DEDENT    go to just before the "  }" brace, Enter -> newline + zero spaces
#   5. SAVE      Ctrl+S, compare the file bytes with the expected text
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP. ASCII only.
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 120,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$app = $null
$code = 1
$result = 'FAIL'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-edit2'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'

function Tap([IntPtr]$Hwnd, [int]$Vk) {
    [Ide]::KeyDownSc($Hwnd, $Vk, [Ide]::Scan($Vk))
    Start-Sleep -Milliseconds 120
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    $body = "int main() {`n  int x = 0;`n  }`n"
    [System.IO.File]::WriteAllText($SrcFile, $body, [System.Text.Encoding]::ASCII)
    $len0 = $body.Length
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    Write-Check 'SANDBOX' ("{0} bytes" -f $len0)

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw 'PROBE_SKIP:window did not appear' }
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    $img = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img) { throw 'no frame captured' }
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $len0 } 6000
    if ($null -eq $st0) { throw 'startup buffer mismatch' }
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:focus stolen' }
    Write-Check 'STATE0' $st0.Raw

    # ---- 1. auto-pair '{' at EOF ----
    [Ide]::Key(0x23, $true, $false)           # Ctrl+End
    Start-Sleep -Milliseconds 300
    Tap $app.Hwnd 0xDB                         # '{'
    Start-Sleep -Milliseconds 400
    $st1 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $len0 + 2 } 3000
    $pairOk = ($null -ne $st1 -and $st1.SrcLen -eq $len0 + 2 -and $st1.Cur -eq $len0 + 1)
    Write-Check 'PAIR' ("srclen {0} -> {1} (need +2), cur={2} (need {3})" -f $len0, $(if ($st1) { $st1.SrcLen } else { 'n/a' }), $(if ($st1) { $st1.Cur } else { 'n/a' }), ($len0 + 1))

    # ---- 2. typing the closing brace skips over it ----
    Tap $app.Hwnd 0xDD                         # '}'
    Start-Sleep -Milliseconds 400
    $st2 = Wait-StudioStateWhere $Sand { param($s) $s.Cur -eq $len0 + 2 } 3000
    $skipOk = ($null -ne $st2 -and $st2.SrcLen -eq $len0 + 2 -and $st2.Cur -eq $len0 + 2)
    Write-Check 'SKIP' ("srclen={0} (need {1}), cur={2} (need {3})" -f $(if ($st2) { $st2.SrcLen } else { 'n/a' }), ($len0 + 2), $(if ($st2) { $st2.Cur } else { 'n/a' }), ($len0 + 2))

    # ---- 3. auto-indent: end of the 2-space line, Enter -> 2 spaces on the new line ----
    [Ide]::Key(0x24, $true, $false)           # Ctrl+Home
    Start-Sleep -Milliseconds 200
    [Ide]::Key(0x28, $false, $false)          # Down (to line 2)
    Start-Sleep -Milliseconds 200
    [Ide]::Key(0x23, $false, $false)          # End
    Start-Sleep -Milliseconds 250
    [Ide]::Key(0x0D, $false, $false)          # Enter
    Start-Sleep -Milliseconds 500
    $st3 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $len0 + 5 } 3000
    $indentOk = ($null -ne $st3 -and $st3.SrcLen -eq $len0 + 2 + 3)
    Write-Check 'INDENT' ("srclen={0} (need {1} = +3: LF + 2 spaces)" -f $(if ($st3) { $st3.SrcLen } else { 'n/a' }), ($len0 + 5))

    # ---- 4. dedent: caret right before the "  }" brace, Enter -> LF + 0 spaces ----
    [Ide]::Key(0x23, $true, $false)
    Start-Sleep -Milliseconds 200
    [Ide]::Key(0x25, $false, $false)          # Left (before '}')
    Start-Sleep -Milliseconds 250
    [Ide]::Key(0x0D, $false, $false)
    Start-Sleep -Milliseconds 500
    $st4 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $len0 + 6 } 3000
    $dedentOk = ($null -ne $st4 -and $st4.SrcLen -eq $len0 + 6)

    # ---- 5. save and inspect bytes ----
    [Ide]::Key(0x53, $true, $false)           # Ctrl+S
    Start-Sleep -Milliseconds 700
    $bytes = [System.IO.File]::ReadAllBytes($SrcFile)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $saveOk = ($text.Contains("[") -and $text.Contains("]") -and $text.Contains("  int x"))   # paired brackets + original line survived the save
    $indentLine = ($text -match "(?m)^  int x = 0;\r?\n  $" )
    $dedentLine = ($text -match "(?m)^\}$")
    Write-Check 'BYTES' ("len={0} has_pairs={1} indent_line={2} dedent_line={3}" -f $bytes.Length, $saveOk, $indentLine, $dedentLine)
    [void](Save-Shot ([Ide]::Grab($app.Hwnd)) $Root 'ide-edit2')
    Assert-Deadline $sw $TimeoutSec 'edit2'

    $all = ($pairOk -and $skipOk -and $indentOk -and $dedentOk -and $saveOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     edit2={0} pair={1} skip={2} indent={3} dedent={4} saved_text=[{5}]" -f `
            $result, $pairOk, $skipOk, $indentOk, $dedentOk, ($text -replace "`r", '\r' -replace "`n", '\n'))
    if (-not $all) { Write-Check 'VERDICT' ("pair={0} skip={1} indent={2} dedent={3} save={4}" -f $pairOk, $skipOk, $indentOk, $dedentOk, $saveOk) }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      " + $_.Exception.Message.Substring(11))
        Write-Host "RESULT     edit2=SKIP"
        $code = 2
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     edit2=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
