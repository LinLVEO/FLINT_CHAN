# probe-ide-cfg.ps1 - FLINT Studio config probe (settings + SESSION STATE).
#
# Sandbox: tmp\ide-cfg (the app's WORKING DIRECTORY), so studio.cfg / ai.state land
# inside the sandbox and the probe never touches the real user config.
#
# What it measures (4 phases, every number read from disk, never from pixels):
#   A. FRESH   - no studio.cfg: window is still the built-in 1000x700 default
#   B. WRITE   - scroll the buffer (3x PageDown), then close with the title-bar X:
#                studio.cfg must record file= / vf=<path>|<cur>|<line> / winx..winh / tree=
#                (vf.cur and vf.line are compared with ai.state's ST cur and SC top)
#   C. RESTORE - hand-written cfg (file=restore.fl, geometry 900x600 @ 200,150, a vf
#                entry pointing at line 40): the app must come back at that size/place,
#                with that file loaded, the caret at that byte offset and the view
#                scrolled to that SOURCE line (SC top). Old vf entries must survive.
#   D. MAXWIN  - cfg winmax=1: the window must come back as "window fullscreen"
#                (work area size), not a plain 1000x700 box.
#
# Window placement: this probe does NOT park the window (Position-Window is skipped on
# purpose) because phase C asserts the restored X/Y. It parks the window only AFTER the
# geometry assert.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 180,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-cfg'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$MainFl = Join-Path $SrcDir 'main.fl'
$RestoreFl = Join-Path $Sand 'restore.fl'
$Cfg = Join-Path $Sand 'studio.cfg'
$State = Join-Path $Sand 'ai.state'

$script:Ok = $true
$script:Fails = @()

function Check([string]$Tag, [bool]$Cond, [string]$Detail) {
    $mark = if ($Cond) { 'ok  ' } else { 'FAIL' }
    Write-Check $Tag ("{0} {1}" -f $mark, $Detail)
    if (-not $Cond) { $script:Ok = $false; $script:Fails += $Tag }
}

# Launch the IDE in $WorkDir WITHOUT parking it (see header).
function Start-StudioAt([string]$Root, [string]$WorkDir) {
    Stop-OwnStudio $Root
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { return @{ Proc = $null; Hwnd = [IntPtr]::Zero; Error = "missing exe: $exe" } }
    $p = Start-Process -FilePath $exe -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 100
        $p.Refresh()
        if ($p.HasExited) { break }
        $hwnd = [Ide]::ByClass($p.Id, 'FLINTSTUDIO')
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][Ide]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 350
    }
    return @{ Proc = $p; Hwnd = $hwnd; Error = $null }
}

function Click-Client([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    [Ide]::MoveClient($Hwnd, $X, $Y)
    Start-Sleep -Milliseconds 120
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds 90
    [Ide]::MouseLeft($false)
}

# Window box with W/H computed (Ide::Rect exposes only L/T/R/B).
function Get-WinBox([IntPtr]$Hwnd) {
    $r = [Ide]::Rect($Hwnd)
    return @{ L = $r.L; T = $r.T; W = ($r.R - $r.L); H = ($r.B - $r.T) }
}

# Read the last "SC <top> <row> <pend>" line (the cfg probe channel added 2026-10-27).
function Read-StudiOScroll([string]$Dir) {
    $p = Join-Path $Dir 'ai.state'
    if (-not (Test-Path $p)) { return $null }
    $last = $null
    try {
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            while ($null -ne ($ln = $sr.ReadLine())) {
                if ($ln -like 'SC *') { $last = $ln }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { return $null }
    if (-not $last) { return $null }
    $f = $last.Trim() -split '\s+'
    if ($f.Count -lt 4) { return $null }
    return @{ Raw = $last.Trim(); Top = [long]$f[1]; Row = [long]$f[2]; Pend = [long]$f[3] }
}

function Wait-StudiOScroll([string]$Dir, [scriptblock]$Cond, [int]$TimeoutMs = 8000) {
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    while ($t.ElapsedMilliseconds -lt $TimeoutMs) {
        $s = Read-StudiOScroll $Dir
        if ($null -ne $s -and (& $Cond $s)) { return $s }
        Start-Sleep -Milliseconds 100
    }
    return (Read-StudiOScroll $Dir)
}

function Read-Cfg([string]$Path) {
    $h = @{}
    $vf = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $Path)) { return @{ Map = $h; Vf = $vf } }
    foreach ($ln in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($ln -like 'vf=*') { $vf.Add($ln.Substring(3)); continue }
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    return @{ Map = $h; Vf = $vf }
}

# vf line -> @{Path;Cur;Line}
function Parse-Vf([string]$s) {
    $p = $s.Split('|')
    if ($p.Count -lt 3) { return @{ Path = $s; Cur = -1; Line = -1 } }
    return @{ Path = $p[0]; Cur = [long]$p[1]; Line = [long]$p[2] }
}

function Find-Vf($CfgObj, [string]$Suffix) {
    foreach ($s in $CfgObj.Vf) {
        $v = Parse-Vf $s
        if ($v.Path.Replace('/', '\').ToLower().EndsWith($Suffix.ToLower())) { return $v }
    }
    return $null
}

function Close-ViaX($App) {
    $r = Get-WinBox $app.Hwnd
    Click-Client $App.Hwnd ($r.W - 17) 17
    $exited = $false
    try { $exited = $App.Proc.WaitForExit(8000) } catch { $exited = $true }
    return $exited
}

$app = $null
$code = 1
$st1 = $null; $sc1 = $null; $r1 = $null
$st2 = $null; $sc2 = $null

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null

    # 120 identical-width lines => byte offset of line N is a fixed arithmetic value
    $lineCount = 120
    $lines = @()
    for ($i = 0; $i -lt $lineCount; $i++) { $lines += ("int v{0:D3} = {0:D3};" -f $i) }
    $body = ($lines -join "`n") + "`n"
    $lineLen = $lines[0].Length + 1                      # + LF
    $restoreCur = 40 * $lineLen
    $restoreLen = $body.Length

    # ===== A. FRESH (no cfg) =====
    [System.IO.File]::WriteAllText($MainFl, $body, (New-Object System.Text.ASCIIEncoding))
    Remove-Item $Cfg -ErrorAction SilentlyContinue
    Remove-Item $State -ErrorAction SilentlyContinue

    $app = Start-StudioAt $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        throw "PROBE_SKIP:window did not appear ($($app.Error))"
    }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'A-start'
    $r0 = Get-WinBox $app.Hwnd
    Check 'FRESH' (($r0.W -eq 1000) -and ($r0.H -eq 700)) ("no cfg -> 1000x700 default (got {0}x{1} at {2},{3})" -f $r0.W, $r0.H, $r0.L, $r0.T)

    # ===== B. WRITE: scroll, then close with X =====
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen' }
    for ($i = 0; $i -lt 3; $i++) {
        [Ide]::Key(0x22, $false, $false)     # PageDown (app: g_scroll += 20)
        Start-Sleep -Milliseconds 260
    }
    Start-Sleep -Milliseconds 700
    $sc1 = Wait-StudiOScroll $Sand { param($s) $s.Top -ge 20 } 6000
    $st1 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    if ($null -eq $st1) { throw 'ai.state has no ST line (oracle channel broken)' }
    Assert-Deadline $sw $TimeoutSec 'B-scroll'
    Check 'SCROLL' ($null -ne $sc1 -and $sc1.Top -ge 20) ("3x PageDown -> SC {0}" -f $(if ($sc1) { $sc1.Raw } else { 'missing' }))
    $r1 = Get-WinBox $app.Hwnd

    $exited = Close-ViaX $app
    Check 'CLOSEX' $exited 'title-bar X exits the process'
    Start-Sleep -Milliseconds 400
    Assert-Deadline $sw $TimeoutSec 'B-close'

    $cfg1 = Read-Cfg $Cfg
    Check 'CFGEXISTS' (Test-Path $Cfg) 'studio.cfg written on normal exit'
    $fileKey = if ($cfg1.Map.ContainsKey('file')) { $cfg1.Map['file'] } else { '' }
    Check 'CFGFILE' ($fileKey.Replace('/', '\').ToLower().EndsWith('apps\studio_native\main.fl')) ("file=$fileKey")
    $v1 = Find-Vf $cfg1 'apps\studio_native\main.fl'
    Check 'CFGVF' (($null -ne $v1) -and ($v1.Cur -eq $st1.Cur) -and ($v1.Line -eq $sc1.Top)) `
        ("vf.cur={0} (ST cur={1})  vf.line={2} (SC top={3})" -f $(if ($v1) { $v1.Cur } else { 'NA' }), $st1.Cur, $(if ($v1) { $v1.Line } else { 'NA' }), $sc1.Top)
    $wOk = $cfg1.Map.ContainsKey('winw') -and ([int]$cfg1.Map['winw'] -eq $r1.W) -and ([int]$cfg1.Map['winh'] -eq $r1.H)
    $pOk = $cfg1.Map.ContainsKey('winx') -and ([int]$cfg1.Map['winx'] -eq $r1.L) -and ([int]$cfg1.Map['winy'] -eq $r1.T)
    Check 'CFGWIN' ($wOk -and $pOk) ("cfg win={0},{1} {2}x{3} vs rect {4},{5} {6}x{7}" -f $cfg1.Map['winx'], $cfg1.Map['winy'], $cfg1.Map['winw'], $cfg1.Map['winh'], $r1.L, $r1.T, $r1.W, $r1.H)
    Check 'CFGTREE' $cfg1.Map.ContainsKey('tree') ("tree=" + $cfg1.Map['tree'])

    # ===== C. RESTORE: hand-written cfg pointing at restore.fl line 40 =====
    [System.IO.File]::WriteAllText($RestoreFl, $body, (New-Object System.Text.ASCIIEncoding))
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($ln in [System.IO.File]::ReadAllLines($Cfg, [System.Text.Encoding]::UTF8)) {
        if ($ln -match '^(file|winx|winy|winw|winh|winmax|tree)=') { continue }
        $keep.Add($ln)
    }
    $keep.Add('file=restore.fl')
    $keep.Add('winx=200')
    $keep.Add('winy=150')
    $keep.Add('winw=900')
    $keep.Add('winh=600')
    $keep.Add('winmax=0')
    $keep.Add("vf=restore.fl|$restoreCur|40")
    [System.IO.File]::WriteAllText($Cfg, (($keep -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item $State -ErrorAction SilentlyContinue

    $app = Start-StudioAt $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw "PROBE_SKIP:window did not appear on restore ($($app.Error))" }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'C-start'
    $r2 = Get-WinBox $app.Hwnd
    Check 'RESTOREGEOM' (($r2.W -eq 900) -and ($r2.H -eq 600) -and ($r2.L -eq 200) -and ($r2.T -eq 150)) `
        ("cfg 900x600 @ 200,150 -> rect {0}x{1} @ {2},{3}" -f $r2.W, $r2.H, $r2.L, $r2.T)
    # park it now (other probes/users click near 120,90)
    [void][Ide]::SetWindowPos($app.Hwnd, [IntPtr]::Zero, [int]([Ide]::GetSystemMetrics(0) - 1010), 110, 0, 0, 0x0011)

    $st2 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -ge 1000 } 8000
    $sc2 = Wait-StudiOScroll $Sand { param($s) $s.Pend -eq -1 } 8000
    if ($null -eq $st2) { throw 'restore: no ST line after 8s' }
    Assert-Deadline $sw $TimeoutSec 'C-oracle'
    Check 'RESTOREFILE' ($st2.SrcLen -eq $restoreLen) ("srclen={0} (restore.fl={1})" -f $st2.SrcLen, $restoreLen)
    Check 'RESTORECUR' (($st2.Cur -eq $restoreCur) -and ($st2.Line -eq 40)) ("ST cur={0} line={1} (want cur={2} line=40)" -f $st2.Cur, $st2.Line, $restoreCur)
    Check 'RESTORESCROLL' ($null -ne $sc2 -and $sc2.Top -eq 40) ("SC {0} (want top=40)" -f $(if ($sc2) { $sc2.Raw } else { 'missing' }))

    $exited2 = Close-ViaX $app
    Start-Sleep -Milliseconds 400
    $cfg2 = Read-Cfg $Cfg
    $vMain = Find-Vf $cfg2 'apps\studio_native\main.fl'
    $vRest = Find-Vf $cfg2 'restore.fl'
    Check 'PERSISTVF' (($null -ne $vMain) -and ($null -ne $vRest) -and ($vMain.Cur -eq $st1.Cur)) `
        ("vf entries={0}  main.cur={1} restore={2}" -f $cfg2.Vf.Count, $(if ($vMain) { $vMain.Cur } else { 'NA' }), $(if ($vRest) { 'yes' } else { 'NO' }))

    # ===== D. MAXWIN: window fullscreen restore =====
    $cfg3 = New-Object System.Collections.Generic.List[string]
    foreach ($ln in [System.IO.File]::ReadAllLines($Cfg, [System.Text.Encoding]::UTF8)) {
        if ($ln -match '^winmax=') { continue }
        $cfg3.Add($ln)
    }
    $cfg3.Add('winmax=1')
    [System.IO.File]::WriteAllText($Cfg, (($cfg3 -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $app = Start-StudioAt $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw 'PROBE_SKIP:window did not appear on maxwin' }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'D-start'
    $r3 = Get-WinBox $app.Hwnd
    Check 'MAXWIN' (([Math]::Abs($r3.W - $wa.Width) -le 2) -and ([Math]::Abs($r3.H - $wa.Height) -le 2)) `
        ("winmax=1 -> {0}x{1} (work area {2}x{3})" -f $r3.W, $r3.H, $wa.Width, $wa.Height)

    # ===== E. F11 -> Esc: must come back to the USER geometry, not 1000x700@120,90 =====
    #   (set_winmode(0) used to hard-code the default box: resize/move + F11 + Esc = window "pops back")
    $cfg4 = New-Object System.Collections.Generic.List[string]
    foreach ($ln in [System.IO.File]::ReadAllLines($Cfg, [System.Text.Encoding]::UTF8)) {
        if ($ln -match '^(winmax|winx|winy|winw|winh)=') { continue }
        $cfg4.Add($ln)
    }
    $cfg4.Add('winx=160')
    $cfg4.Add('winy=120')
    $cfg4.Add('winw=880')
    $cfg4.Add('winh=620')
    $cfg4.Add('winmax=0')
    [System.IO.File]::WriteAllText($Cfg, (($cfg4 -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    $app = Start-StudioAt $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw 'PROBE_SKIP:window did not appear on F11 round-trip' }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'E-start'
    $rE0 = Get-WinBox $app.Hwnd
    Check 'EGEOM' (($rE0.W -eq 880) -and ($rE0.H -eq 620) -and ($rE0.L -eq 160) -and ($rE0.T -eq 120)) `
        ("880x620 @160,120 -> {0}x{1} @ {2},{3}" -f $rE0.W, $rE0.H, $rE0.L, $rE0.T)
    [void][Ide]::SetWindowPos($app.Hwnd, [IntPtr]::Zero, [int]([Ide]::GetSystemMetrics(0) - 1010), 110, 0, 0, 0x0011)
    if (Grab-Focus $app.Hwnd 25) {
        [Ide]::Key(0x7A, $false, $false)     # F11 -> window fullscreen
        Start-Sleep -Milliseconds 1000
        $rE1 = Get-WinBox $app.Hwnd
        Check 'EFULL' (([Math]::Abs($rE1.W - $wa.Width) -le 2) -and ([Math]::Abs($rE1.H - $wa.Height) -le 2)) `
            ("F11 -> {0}x{1} (work area {2}x{3})" -f $rE1.W, $rE1.H, $wa.Width, $wa.Height)
        [Ide]::Key(0x1B, $false, $false)     # Esc -> back to normal
        Start-Sleep -Milliseconds 1000
        $rE2 = Get-WinBox $app.Hwnd
        Check 'EBACK' (($rE2.W -eq 880) -and ($rE2.H -eq 620)) `
            ("Esc -> {0}x{1} (want 880x620: the captured normal-mode box, NOT the 1000x700 default)" -f $rE2.W, $rE2.H)
    }
    else {
        Check 'EFULL' $false 'keyboard focus was stolen (F11 round-trip not measured)'
        Check 'EBACK' $false 'keyboard focus was stolen'
    }

    $code = if ($script:Ok) { 0 } else { 1 }
    Write-Host ("RESULT     cfg={0} fails={1}" -f $(if ($script:Ok) { 'PASS' } else { 'FAIL' }), $(if ($script:Fails.Count -gt 0) { $script:Fails -join ',' } else { 'none' }))
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      {0}" -f $_.Exception.Message.Substring(11))
        Write-Host "RESULT     cfg=SKIP(env-contention)"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     cfg=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     cfg=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
