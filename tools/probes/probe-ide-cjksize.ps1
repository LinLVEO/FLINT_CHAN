# probe-ide-cjksize.ps1 - DirectWrite font table must survive settings cycling.
#
# User report: "设置那个中文字号换了一个轮回之后 程序就不显示文件文本了"
#   (cycle 中文号 one full round -> the file text disappears, line numbers stay)
#
# Sandbox: tmp\ide-cjksize (the app's WORKING DIRECTORY) so studio.cfg / ai.state
# stay inside the sandbox and the real user config is never touched.
#
# What it measures:
#   1. BASE      the sandbox file renders: >=3 of the 6 syntax colours are on screen
#   2. OPEN      F9 opens the settings card
#   3. CYCLE     row 0->3 (中文号) then Right x8 = a full round back to 自动 (0);
#                the persisted cjksize= must be 0 again (that IS the "轮回")
#   4. AFTER     the text is still painted (>=3 colours, each >=60% of its baseline px)
#                and the gutter still shows line numbers (GDI layer, always drawn)
#   5. TYPE      typing still lands in the buffer after the cycling (ai.state srclen +1)
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

$app = $null
$result = 'FAIL'
$code = 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-cjksize'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$SrcFile = Join-Path $SrcDir 'main.fl'
$Cfg = Join-Path $Sand 'studio.cfg'

# every syntax colour the renderer can emit, with a Chinese literal so the CJK
# font is exercised too (the report is about 中文字号)
$Body = @(
    '// 注释 comment 中文',
    'int main() {',
    '  char *s = "字符串 string 中文";',
    '  return 42;',
    '}'
) -join "`n"

$Pal = [ordered]@{
    keyword = 0x569CD6
    type    = 0x4EC9B0
    control = 0xC586C0
    string  = 0xCE9178
    comment = 0x6A9955
    number  = 0xB5CEA8
}

function Read-Cfg([string]$Path) {
    $h = @{}
    if (-not (Test-Path $Path)) { return $h }
    foreach ($ln in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::ASCII)) {
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    return $h
}

# token pixel counts inside the text column only (x >= 268 excludes the gutter;
# y < H-200 keeps the output panel out of the sample)
function Get-Tokens([Frame]$img) {
    $c = [ordered]@{}
    $x0 = 268; $x1 = $img.W - 30
    $y0 = 42; $y1 = [Math]::Min($img.H - 200, $img.H - 30)
    $present = 0
    foreach ($k in $Pal.Keys) {
        $n = $img.CountNear($x0, $y0, $x1, $y1, $Pal[$k], 40)
        $c[$k] = $n
        if ($n -ge 80) { $present++ }
    }
    return @{ Counts = $c; Present = $present; Text = (($c.Keys | ForEach-Object { "$_=$($c[$_])" }) -join ' ') }
}

function Tap-Key([ushort]$vk, [int]$waitMs = 200) {
    [Ide]::Key($vk, $false, $false)
    Start-Sleep -Milliseconds $waitMs
}

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    New-Item -ItemType Directory -Force $SrcDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
    # UTF-8 (no BOM) so the Chinese literals survive: the point is to exercise the CJK
    # font path (a previous probe wrote ASCII and silently turned 注释 into ??).
    [System.IO.File]::WriteAllText($SrcFile, $Body + "`n", (New-Object System.Text.UTF8Encoding($false)))
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

    $t0 = Get-Tokens $img0
    $baseOk = ($t0.Present -ge 3)
    Write-Check 'BASE' ("{0} present={1} (need>=3) srclen={2}" -f $t0.Text, $t0.Present, $st0.SrcLen)
    if (-not $baseOk) { throw 'baseline already missing text (probe assumption broken)' }
    [void](Save-Shot $img0 $Root 'ide-cjksize-0-base')

    # ---- open the settings card, walk to row 3 (中文号) ----
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen by a concurrent agent' }
    Tap-Key 0x78 700                       # F9
    $img1 = [Ide]::Grab($app.Hwnd)
    $cw = 520; $ch = 410
    $cx = [int](($W - $cw) / 2); $cy = [int](($H - $ch) / 2)
    $card1 = $img1.CountNear($cx, $cy, ($cx + $cw), ($cy + $ch), 0x363230, 4)
    $openOk = ($card1 -gt 20000)
    Write-Check 'OPEN' ("card_px={0} (need>20000)" -f $card1)
    if (-not $openOk) { throw 'settings card did not open on F9' }

    for ($i = 0; $i -lt 3; $i++) { Tap-Key 0x28 220 }   # Down x3 -> 中文号
    $selRow = $true                                # the panel highlights the active row; we assert via cfg instead

    # ---- two full 轮回: 0 -> 12 -> ... -> 24 -> 0, twice (16 Right presses).
    # 16 steps = 32 DirectWrite text formats requested; the old fixed 16-slot table died
    # after 8 (a single round), so 16 also proves the table recycles instead of leaking.
    $seen = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 16; $i++) {
        Tap-Key 0x27 260                           # Right
        $c = Read-Cfg $Cfg
        if ($c.ContainsKey('cjksize')) { $seen.Add($c['cjksize']) } else { $seen.Add('(none)') }
    }
    Tap-Key 0x1B 600                               # Esc closes the card
    $cEnd = Read-Cfg $Cfg
    $cjEnd = if ($cEnd.ContainsKey('cjksize')) { [int]$cEnd['cjksize'] } else { -1 }
    $cycleOk = ($cjEnd -eq 0)
    Write-Check 'CYCLE' ("cjksize trail={0} final={1} (need final 0 = two full rounds)" -f ($seen -join ','), $cjEnd)
    Assert-Deadline $sw $TimeoutSec 'cycle'

    # ---- the text must still be there ----
    Start-Sleep -Milliseconds 500
    $img2 = [Ide]::Grab($app.Hwnd)
    $t2 = Get-Tokens $img2
    $thin = @()
    foreach ($k in $Pal.Keys) {
        if ($t0.Counts[$k] -ge 80 -and $t2.Counts[$k] -lt [int]($t0.Counts[$k] * 0.6)) {
            $thin += ("{0}:{1}->{2}" -f $k, $t0.Counts[$k], $t2.Counts[$k])
        }
    }
    $textOk = ($t2.Present -ge 3 -and $thin.Count -eq 0)
    Write-Check 'AFTER' ("{0} present={1} (need>={2}) thin=[{3}]" -f $t2.Text, $t2.Present, 3, ($thin -join ' '))
    $gut = (Get-InkStats $img2 220 42 266 ([Math]::Min($H - 60, $H - 26)) 70).Count
    $gutOk = ($gut -ge 100)
    Write-Check 'GUTTER' ("dim_px={0} (need>=100; GDI layer - this is what survived the bug)" -f $gut)
    [void](Save-Shot $img2 $Root 'ide-cjksize-1-after')

    # ---- editing still works after the cycling ----
    #   ai.state is truncated+rewritten every frame, so a single read can catch it empty;
    #   poll for the expected value instead of sampling once.
    $len0 = $null
    $stA = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 4000
    if ($null -ne $stA) { $len0 = $stA.SrcLen }
    [void](Grab-Focus $app.Hwnd 10)
    [Ide]::KeyDownSc($app.Hwnd, 0x5A, [Ide]::Scan(0x5A))   # 'Z'
    $stB = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt $len0 } 4000
    $typeOk = ($null -ne $stA -and $null -ne $stB -and $stB.SrcLen -gt $len0)
    Write-Check 'TYPE' ("srclen {0} -> {1} (need greater)" -f $len0, $(if ($stB) { $stB.SrcLen } else { 'n/a' }))
    Assert-Deadline $sw $TimeoutSec 'type'

    # ---- STRESS: >64 distinct (face, px) pairs, i.e. past the format table size ----
    #  The table holds 64 slots; sweeps across faces/sizes ask for ~90 formats, so this
    #  section is what proves the LRU-eviction path keeps text on screen (and that the
    #  layout cache of an evicted id is dropped instead of drawing with a stale format).
    Tap-Key 0x78 700                                # F9 reopens the card
    for ($i = 0; $i -lt 3; $i++) { Tap-Key 0x26 200 }   # Up x3 -> row 0 (代码字体)
    $fmtAsks = 0
    for ($s = 0; $s -lt 3; $s++) {
        Tap-Key 0x27 200                            # Right: next code font
        Tap-Key 0x28 200                            # Down: row 1 (字号)
        for ($i = 0; $i -lt 16; $i++) {
            if (($s % 2) -eq 0) { Tap-Key 0x27 190 } else { Tap-Key 0x25 190 }   # size sweep
            $fmtAsks++
        }
        $c = Read-Cfg $Cfg
        Tap-Key 0x26 200                            # Up: back to row 0
    }
    Tap-Key 0x1B 700                                # Esc
    Start-Sleep -Milliseconds 500
    $img3 = [Ide]::Grab($app.Hwnd)
    $t3 = Get-Tokens $img3
    $stressOk = ($t3.Present -ge 3)
    Write-Check 'STRESS' ("{0} steps={1} present={2} (need>=3 after >64 font formats)" -f $t3.Text, $fmtAsks, $t3.Present)
    $gut3 = (Get-InkStats $img3 220 42 266 ([Math]::Min($H - 60, $H - 26)) 70).Count
    $stressOk = ($stressOk -and $gut3 -ge 100)
    Write-Check 'STRESSGUT' ("dim_px={0} (need>=100)" -f $gut3)
    [void](Save-Shot $img3 $Root 'ide-cjksize-2-stress')
    Assert-Deadline $sw $TimeoutSec 'stress'

    $all = ($baseOk -and $openOk -and $selRow -and $cycleOk -and $textOk -and $gutOk -and $typeOk -and $stressOk)
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     cjksize={0} base_present={1} after_present={2} trail={3} final_cjksize={4} gutter_px={5} srclen {6}->{7} stress_present={8} fmt_asks={9}" -f `
            $result, $t0.Present, $t2.Present, ($seen -join ','), $cjEnd, $gut, $len0, `
            $(if ($stB) { $stB.SrcLen } else { 'n/a' }), $t3.Present, $fmtAsks)
    if (-not $all) {
        Write-Check 'VERDICT' ("base={0} open={1} cycle={2} text={3} gutter={4} type={5} stress={6}" -f `
                $baseOk, $openOk, $cycleOk, $textOk, $gutOk, $typeOk, $stressOk)
    }
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     cjksize=SKIP reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     cjksize=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     cjksize=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
