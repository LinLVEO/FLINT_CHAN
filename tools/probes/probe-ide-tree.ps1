# probe-ide-tree.ps1 - FLINT Studio file-tree + auto-save probe.
#
# Sandbox: tmp\ide-tree (the app's WORKING DIRECTORY). Tiny tree so row indices are stable:
#   apps\studio_native\main.fl   (opened at startup, 27 bytes)
#   lib\alpha.fl                 (40 bytes)
#   lib\beta.fl                  (60 bytes)
# Row layout at startup (parents of main.fl auto-expanded):
#   0 apps / 1 studio_native / 2 main.fl / 3 lib
# Clicking lib expands it => 4 alpha.fl, 5 beta.fl
#
# What it measures:
#   1. TREE     the sidebar shows the expanded tree (row 2 = the current file): clicking
#               row 2 keeps srclen=27 and the tree band has ink
#   2. AUTOSAVE editing main.fl then clicking another file must WRITE main.fl first
#               (28 bytes on disk) - the old open_file() silently dropped the edit
#   3. OPEN     clicking alpha.fl loads 40 bytes, beta.fl loads 60 bytes (ai.state srclen)
#   4. SCROLL   wheel over the sidebar changes the tree view (row ink shifts)
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
$Sand = Join-Path $Root 'tmp\ide-tree'
$MainDir = Join-Path $Sand 'apps\studio_native'
$LibDir = Join-Path $Sand 'lib'
$MainFile = Join-Path $MainDir 'main.fl'
$Alpha = Join-Path $LibDir 'alpha.fl'
$Beta = Join-Path $LibDir 'beta.fl'

$MainBody = "int main() { return 0; }`n"          # 27 bytes
$AlphaBody = "int alpha = 1;`nint alpha2 = 2;`nint a3 = 3;`n"   # 40 bytes
$BetaBody = "int beta = 1;`nint beta2 = 2;`nint b3 = 3;`nint b4 = 4;`nint b5 = 5;`n"  # 60 bytes

function RowY([int]$i) { return 34 + 26 + 30 + $i * 26 + 13 }   # title 34 + menu bar 26 + header 30
function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds 90
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 350
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $MainDir | Out-Null
    New-Item -ItemType Directory -Force $LibDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    [System.IO.File]::WriteAllText($MainFile, $MainBody, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($Alpha, $AlphaBody, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($Beta, $BetaBody, [System.Text.Encoding]::ASCII)
    # 30 filler files so the tree is longer than the viewport (the wheel test needs scrolling)
    for ($i = 1; $i -le 30; $i++) { 
        [System.IO.File]::WriteAllText((Join-Path $LibDir ('zz{0:d2}.fl' -f $i)), ('int zz{0} = {0};' -f $i) + "
", [System.Text.Encoding]::ASCII)
    }
    Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sand 'studio.cfg') -ErrorAction SilentlyContinue
    $mainLen = (Get-Item $MainFile).Length
    $alphaLen = (Get-Item $Alpha).Length
    $betaLen = (Get-Item $Beta).Length
    Write-Check 'SANDBOX' ("main={0}B alpha={1}B beta={2}B" -f $mainLen, $alphaLen, $betaLen)

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    Position-Window $app.Hwnd
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    $img0 = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img0) { throw 'no frame captured' }
    $W = $img0.W; $H = $img0.H
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $mainLen } 6000
    if ($null -eq $st0) { throw 'ai.state does not show the startup file (srclen mismatch)' }
    Write-Check 'STATE0' $st0.Raw
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }

    # ---- 1. tree is drawn and the startup file sits on row 2 ----
    $treeInk = (Get-InkStats $img0 8 34 (216) 400 70).Count
    $treeOk = ($treeInk -gt 300)
    Write-Check 'TREE' ("sidebar_ink_px={0} (need>300)" -f $treeInk)
    [void](Save-Shot $img0 $Root 'ide-tree-0-start')

    # ---- 2. edit the current file, then click another file: the edit must be on disk ----
    [Ide]::KeyDownSc($app.Hwnd, 0x41, [Ide]::Scan(0x41))      # 'A' at the very start
    Start-Sleep -Milliseconds 500
    $stE = Read-StudioState $Sand
    $edited = ($null -ne $stE -and $stE.SrcLen -eq $mainLen + 1)
    Write-Check 'EDIT' ("srclen {0} -> {1} (need +1)" -f $mainLen, $(if ($stE) { $stE.SrcLen } else { 'n/a' }))

    Click-Client $app.Hwnd 60 (RowY 3)                        # row 3 = lib -> expand
    Start-Sleep -Milliseconds 300
    Click-Client $app.Hwnd 60 (RowY 4)                        # row 4 = alpha.fl
    $stA = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $alphaLen } 3000
    if ($null -eq $stA) { $stA = Read-StudioState $Sand }
    $openOk = ($null -ne $stA -and $stA.SrcLen -eq $alphaLen)
    Write-Check 'OPEN_ALPHA' ("srclen={0} (need {1})" -f $(if ($stA) { $stA.SrcLen } else { 'n/a' }), $alphaLen)
    $savedLen = (Get-Item $MainFile).Length
    $saveOk = ($savedLen -eq $mainLen + 1)
    Write-Check 'AUTOSAVE' ("main.fl on disk = {0}B (need {1}B = edit kept)" -f $savedLen, ($mainLen + 1))
    [void](Save-Shot ([Ide]::Grab($app.Hwnd)) $Root 'ide-tree-1-lib')

    # ---- 3. another file opens (row 5 = beta.fl) ----
    Click-Client $app.Hwnd 60 (RowY 5)
    $stB = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $betaLen } 3000
    if ($null -eq $stB) { $stB = Read-StudioState $Sand }
    $open2Ok = ($null -ne $stB -and $stB.SrcLen -eq $betaLen)
    Write-Check 'OPEN_BETA' ("srclen={0} (need {1})" -f $(if ($stB) { $stB.SrcLen } else { 'n/a' }), $betaLen)

    # ---- 4. wheel over the sidebar scrolls the tree (pixels shift) ----
    $shotA = [Ide]::Grab($app.Hwnd)
    $before = Get-InkStats $shotA 8 34 216 400 70
    [Ide]::MoveClient($app.Hwnd, 80, 200)
    [Ide]::Wheel(-3)
    Start-Sleep -Milliseconds 400
    $after = Get-InkStats ([Ide]::Grab($app.Hwnd)) 8 34 216 400 70
    $shotB = [Ide]::Grab($app.Hwnd)
    # compare a pixel fingerprint of the sidebar band (ink minY can stay put while rows shift)
    $fpA = 0; $fpB = 0
    for ($yy = 40; $yy -lt 300; $yy += 7) { for ($xx = 8; $xx -lt 216; $xx += 5) { $fpA = ($fpA * 31 + $shotA.At($xx, $yy)) % 1000000007 } }
    for ($yy = 40; $yy -lt 300; $yy += 7) { for ($xx = 8; $xx -lt 216; $xx += 5) { $fpB = ($fpB * 31 + $shotB.At($xx, $yy)) % 1000000007 } }
    $scrollOk = ($fpA -ne $fpB)
    Write-Check 'WHEEL' ("tree ink minY {0} -> {1} (need a shift)" -f `
            $(if ($before) { $before.MinY } else { 'n/a' }), $(if ($after) { $after.MinY } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'tree'

    $all = ($treeOk -and $edited -and $openOk -and $saveOk -and $open2Ok -and $scrollOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     tree={0} ink={1} edit_srclen={2} alpha_srclen={3} saved_len={4} beta_srclen={5}" -f `
            $result, $treeInk, $(if ($stE) { $stE.SrcLen } else { 'n/a' }), `
            $(if ($stA) { $stA.SrcLen } else { 'n/a' }), $savedLen, $(if ($stB) { $stB.SrcLen } else { 'n/a' }))
    if (-not $all) {
        Write-Check 'VERDICT' ("tree={0} edit={1} open_alpha={2} autosave={3} open_beta={4} wheel={5}" -f `
                $treeOk, $edited, $openOk, $saveOk, $open2Ok, $scrollOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     tree=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     tree=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     tree=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
