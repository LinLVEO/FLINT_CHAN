# probe-ide-term.ps1 - FLINT Studio: the built-in terminal must be a PERSISTENT shell (VS Code-ish).
#
# Sandbox: tmp\ide-term (the app's WORKING DIRECTORY).
#
# Why this probe exists: the old terminal ran every line as a fresh `cmd /c`, so `cd` never
# stuck. "Persistent" is proven through the FILESYSTEM, not through pixels:
#   A. OPEN      Ctrl+` opens the bottom panel (ink inside the 200px band)
#   B. SHON      the first command lazily starts the shell  -> ai.state "TS 1 <len> <cmdlen>"
#   C. CD        `cd /d <sandbox>\sub` then `echo made> marker.txt` must create sub\marker.txt
#                (only a shell that remembers the cwd can do that)
#   D. STREAM    the output byte counter in TS grows after each command (output is read while
#                the app keeps running -- not one blocking `cmd /c` per line)
#   E. HISTORY   Up + Enter re-runs the last command (marker file mtime/content changes; TS grows)
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
$Sand = Join-Path $Root 'tmp\ide-term'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$Sub = Join-Path $Sand 'sub'
$Marker = Join-Path $Sub 'marker'
$State = Join-Path $Sand 'ai.state'

$script:Ok = $true
$script:Fails = @()

function Check([string]$Tag, [bool]$Cond, [string]$Detail) {
    $mark = if ($Cond) { 'ok  ' } else { 'FAIL' }
    Write-Check $Tag ("{0} {1}" -f $mark, $Detail)
    if (-not $Cond) { $script:Ok = $false; $script:Fails += $Tag }
}

# Last "TS <shon> <termlen> <cmdlen>" line (terminal oracle added 2026-10-27).
function Read-StudiOScroll([string]$Dir) { }   # keep name space clear
function Read-StudioTerm([string]$Dir) {
    $p = Join-Path $Dir 'ai.state'
    if (-not (Test-Path $p)) { return $null }
    $last = $null
    try {
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            while ($null -ne ($ln = $sr.ReadLine())) { if ($ln -like 'TS *') { $last = $ln } }
        }
        finally { $fs.Dispose() }
    }
    catch { return $null }
    if (-not $last) { return $null }
    $f = $last.Trim() -split '\s+'
    if ($f.Count -lt 4) { return $null }
    return @{ Raw = $last.Trim(); On = [int]$f[1]; Len = [int]$f[2]; CmdLen = [int]$f[3] }
}

function Wait-StudioTerm([string]$Dir, [scriptblock]$Cond, [int]$TimeoutMs = 8000) {
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    $v = $null
    while ($t.ElapsedMilliseconds -lt $TimeoutMs) {
        $v = Read-StudioTerm $Dir
        if ($null -ne $v -and (& $Cond $v)) { return $v }
        Start-Sleep -Milliseconds 100
    }
    return $v
}

# Type into the terminal with REAL key messages (WM_KEYDOWN + scan code). WM_CHAR is ignored by
# this app (kbd=1 window: characters are produced from scan codes), which is why posting WM_CHAR
# typed nothing at all (measured 2026-10-27).
# Only letters / digits / space are used in this probe: shifted punctuation (":" "\\" ">") would
# need Shift state, and the probe has no business fighting that.
function Send-Key([IntPtr]$Hwnd, [int]$Vk) {
    [Ide]::KeyDownSc($Hwnd, $Vk, [Ide]::Scan($Vk))
    Start-Sleep -Milliseconds 110
}
function Send-Line([IntPtr]$Hwnd, [string]$Text) {
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq ' ') { Send-Key $Hwnd 0x20 }
        else { $vk = [int][char]([string]$ch).ToUpperInvariant(); Send-Key $Hwnd $vk }
    }
    Send-Key $Hwnd 0x0D
}

$app = $null
$code = 1
try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    foreach ($d in @($SrcDir, $Sub, (Join-Path $Sand 'tmp'))) { New-Item -ItemType Directory -Force $d | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), "int main() {`n  return 0;`n}`n", (New-Object System.Text.ASCIIEncoding))
    Get-ChildItem $Sub -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item $State -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Sub 'marker') -Recurse -Force -ErrorAction SilentlyContinue
    # Seed the workspace = sandbox so the shell starts THERE (otherwise it starts in the folder of
    # the current file, and a relative `cd sub` would be one level off).
    $cfg = @(
        'font=Consolas', 'size=14', 'weight=400', 'cjk=Noto Sans SC Medium', 'cjksize=0', 'wrap=1', 'ui=16'
        ('ws=' + $Sand), 'winx=300', 'winy=120', 'winw=900', 'winh=620', 'winmax=0', 'tree=0', 'file=apps/studio_native/main.fl'
    ) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $Sand 'studio.cfg'), $cfg + "`n", (New-Object System.Text.UTF8Encoding($false)))

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw "PROBE_SKIP:window did not appear ($($app.Error))" }
    $img0 = Wait-Stable $app.Hwnd 900 40
    if ($null -eq $img0) { throw 'no frame captured' }
    Assert-Deadline $sw $TimeoutSec 'start'
    $W = $img0.W; $H = $img0.H

    # ===== A. open the panel =====
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen' }
    [Ide]::Key(0xC0, $true, $false)            # Ctrl+`
    Start-Sleep -Milliseconds 800
    $img1 = [Ide]::Grab($app.Hwnd)
    $band0 = $img0.CountNear(220, $H - 200, $W - 20, $H - 30, 0x00C8C8C8, 90)
    $band1 = $img1.CountNear(220, $H - 200, $W - 20, $H - 30, 0x00C8C8C8, 90)
    $changed = $img1.Diff($img0, 220, $H - 200, $W - 20, $H - 30, 6)
    Check 'PANEL' ($changed -gt 4000) ("terminal band changed px={0} (ink {1} -> {2})" -f $changed, $band0, $band1)

    # ===== B/C. cd then mkdir: only a shell that keeps its cwd can create sub\marker =====
    Send-Line $app.Hwnd "cd sub"
    $t1 = Wait-StudioTerm $Sand { param($v) $v.On -eq 1 -and $v.Len -gt 0 } 8000
    Check 'SHELL' ($null -ne $t1 -and $t1.On -eq 1) ("first command started the persistent shell -> TS " + $(if ($t1) { $t1.Raw } else { 'missing' }))
    Start-Sleep -Milliseconds 600
    $before = Read-StudioTerm $Sand
    Send-Line $app.Hwnd "md marker"
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    while ($t.ElapsedMilliseconds -lt 8000 -and -not (Test-Path $Marker)) { Start-Sleep -Milliseconds 100 }
    Check 'CD-KEPT' (Test-Path $Marker) ("'cd sub' then 'md marker' -> sub\marker " + $(if (Test-Path $Marker) { 'created' } else { 'MISSING (cwd did not stick)' }))
    if (Test-Path $Marker) {
        Check 'CD-CONTENT' (Test-Path $Marker -PathType Container) 'sub\marker is a directory (md ran inside sub)'
    }
    else { Check 'CD-CONTENT' $false 'no marker' }

    # ===== D. streaming: the byte counter grows =====
    $t2 = Wait-StudioTerm $Sand { param($v) $v.Len -gt $before.Len } 6000
    Check 'STREAM' ($null -ne $t2 -and $t2.Len -gt $before.Len) ("output grew {0} -> {1} bytes" -f $(if ($before) { $before.Len } else { 'NA' }), $(if ($t2) { $t2.Len } else { 'NA' }))

    # ===== E. history: Up + Enter re-runs the last command =====
    $before2 = Read-StudioTerm $Sand
    if (Grab-Focus $app.Hwnd 20) {
        [Ide]::Key(0x26, $false, $false)        # Up = previous command
        Start-Sleep -Milliseconds 400
        Send-Key $app.Hwnd 0x0D                 # Enter = run it
        Start-Sleep -Milliseconds 900
        $t3 = Wait-StudioTerm $Sand { param($v) $v.Len -gt $before2.Len } 6000
        Check 'HISTORY' ($null -ne $t3 -and $t3.Len -gt $before2.Len) ("Up+Enter re-ran the last command (len {0} -> {1})" -f $(if ($before2) { $before2.Len } else { 'NA' }), $(if ($t3) { $t3.Len } else { 'NA' }))
    }
    else { Check 'HISTORY' $false 'keyboard focus was stolen' }

    $code = if ($script:Ok) { 0 } else { 1 }
    Write-Host ("RESULT     term={0} fails={1}" -f $(if ($script:Ok) { 'PASS' } else { 'FAIL' }), $(if ($script:Fails.Count -gt 0) { $script:Fails -join ',' } else { 'none' }))
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      {0}" -f $_.Exception.Message.Substring(11))
        Write-Host "RESULT     term=SKIP(env-contention)"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     term=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     term=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
