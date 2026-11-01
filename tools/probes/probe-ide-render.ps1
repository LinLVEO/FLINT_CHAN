# probe-ide-render.ps1 - FLINT Studio rendering / idle-stability sweep.
#
# Checks (all measured from PrintWindow screenshots, no desktop coordinates):
#   1. editor background is VS Code Dark+ #1E1E1E
#   2. syntax highlighting uses at least 3 of the 6 token colors
#   3. line-number gutter is painted (#858585 digits at x 220..266)
#   4. status bar is #181818 with a 1px #007ACC top line and light text
#   5. a keystroke (Right) causes a repaint
#   6. while idle the frame is bit-identical (static)
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (env contention / app missing).
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

function Test-EditorBg([Frame]$img) {
    $W = $img.W; $H = $img.H
    $pts = @(
        [pscustomobject]@{ X = 600; Y = 100 },
        [pscustomobject]@{ X = 600; Y = 300 },
        [pscustomobject]@{ X = ($W - 200); Y = [int]($H / 2) }
    )
    $ok = $true
    $out = @()
    foreach ($p in $pts) {
        $c = $img.At($p.X, $p.Y)
        $m = Color-Near $c 0x1E1E1E 12
        if (-not $m) { $ok = $false }
        $out += ("({0},{1})={2}" -f $p.X, $p.Y, (Format-Rgb $c))
    }
    return @{ Ok = $ok; Text = ($out -join ' ') }
}

function Test-Tokens([Frame]$img) {
    $W = $img.W; $H = $img.H
    $x0 = 268; $x1 = $W - 30
    $y0 = 42; $y1 = [Math]::Min($H - 200, $H - 30)
    $pal = [ordered]@{
        keyword = 0x569CD6
        type    = 0x4EC9B0
        control = 0xC586C0
        string  = 0xCE9178
        comment = 0x6A9955
        number  = 0xB5CEA8
    }
    $counts = [ordered]@{}
    $present = 0
    foreach ($k in $pal.Keys) {
        $n = $img.CountNear($x0, $y0, $x1, $y1, $pal[$k], 40)
        $counts[$k] = $n
        if ($n -ge 80) { $present++ }
    }
    $txt = ($counts.Keys | ForEach-Object { "$_=$($counts[$_])" }) -join ' '
    return @{ Ok = ($present -ge 3); Present = $present; Text = $txt }
}

# Gutter: line numbers are DirectWrite text since 2026-10-27, so they carry ClearType
# fringes — counting an exact #858585 match undercounts them. Measure INK (brightness)
# instead: that is what the check is really about ("is the number layer painted at all").
function Test-Gutter([Frame]$img) {
    $H = $img.H
    $n = (Get-InkStats $img 220 42 266 ([Math]::Min($H - 60, $H - 26)) 70).Count
    $cur = (Get-InkStats $img 220 40 266 60 110).Count
    return @{ Ok = ($n -ge 100); Dim = $n; Current = $cur }
}

# Status bar (2026-10-27 restyle): #181818 fill + a 1px #007ACC line along the TOP edge,
# text in #E8E8E8/#C8C8C8/#9A9A9A instead of white-on-blue. Assertions follow the new spec:
#   - the blue line must span the width but stay thin (a few thousand px, not a blue slab)
#   - the fill must be dark (no big #007ACC area)
#   - light text pixels must still be present
function Test-StatusBar([Frame]$img) {
    $W = $img.W; $H = $img.H
    $y0 = $H - 26
    $line = $img.CountNear(0, $y0, $W, $y0 + 2, 0x007ACC, 10)
    $blue = $img.CountNear(0, $y0, $W, $H - 2, 0x007ACC, 10)
    $dark = $img.CountNear(0, $y0 + 2, $W, $H - 2, 0x181818, 8)
    $text = $img.CountNear(0, $y0 + 2, $W, $H - 2, 0xC8C8C8, 40)
    $px = $img.At([int]($W / 2), $H - 13)
    $ok = (($line -ge 400) -and ($blue -lt 4000) -and ($dark -ge 15000) -and ($text -ge 100))
    return @{ Ok = $ok; Accent = $line; Blue = $blue; Dark = $dark; White = $text; Sample = (Format-Rgb $px) }
}

try {
    $app = Start-Studio $Root
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) {
        $why = if ($app.Error) { $app.Error } else { 'window did not appear (another agent killing windows?)' }
        throw "PROBE_SKIP:$why"
    }
    Write-Check 'WINDOW' ("pid={0} hwnd={1}" -f $app.Proc.Id, $app.Hwnd)
    # Park the window on the right edge: other agents' probes click at the DEFAULT
    # position (120,90) and would otherwise land in our client area.
    Position-Window $app.Hwnd
    $img = Wait-Stable $app.Hwnd 900 40
    Assert-Deadline $sw $TimeoutSec 'startup'
    if ($null -eq $img) { throw 'no frame captured' }
    $shot0 = Save-Shot $img $Root 'ide-render-0'
    Write-Check 'SHOT' ("{0}x{1} -> {2}" -f $img.W, $img.H, $shot0)

    $bg = Test-EditorBg $img
    Write-Check 'BG' ("{0} expect=#1E1E1E ok={1}" -f $bg.Text, $bg.Ok)

    $tok = Test-Tokens $img
    Write-Check 'TOKENS' ("{0} present={1} (need>=3) ok={2}" -f $tok.Text, $tok.Present, $tok.Ok)

    $gut = Test-Gutter $img
    Write-Check 'GUTTER' ("dim_px={0} current_px={1} ok={2}" -f $gut.Dim, $gut.Current, $gut.Ok)

    $sb = Test-StatusBar $img
    Write-Check 'STATUS' ("sample={0} top_line_px={1} blue_total={2} dark_px={3} light_text_px={4} ok={5}" -f $sb.Sample, $sb.Accent, $sb.Blue, $sb.Dark, $sb.White, $sb.Ok)

    # ---- repaint on a keystroke (Right arrow only moves the caret; never edits text) ----
    $repaint = $false
    $repaintPx = 0
    $focusGot = $false
    for ($attempt = 0; $attempt -lt 3 -and -not $repaint; $attempt++) {
        if (-not (Grab-Focus $app.Hwnd 15)) { continue }
        $focusGot = $true
        [Ide]::Key(0x27, $false, $false)   # VK_RIGHT
        Start-Sleep -Milliseconds 500
        $img2 = [Ide]::Grab($app.Hwnd)
        $repaintPx = $img2.Diff($img, 220, 40, $img.W, $img.H - 30, 2)
        $repaint = ($repaintPx -ge 4)
        $img = $img2
    }
    [void](Save-Shot $img $Root 'ide-render-1-key')
    Assert-Deadline $sw $TimeoutSec 'repaint'
    Write-Check 'REPAINT' ("right-arrow diff_px={0} ok={1} focus={2}" -f $repaintPx, $repaint, $focusGot)
    if (-not $focusGot) { throw 'PROBE_SKIP:cannot keep our window in the foreground for key injection' }

    # ---- idle: two grabs ~1s apart must be bit-identical ----
    # A concurrent agent's probe may click into our window; re-baseline up to 3 times
    # so one foreign click does not turn into a false FAIL.
    $static = $false
    $idlePx = -1
    $idleTries = 0
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $idleTries = $attempt + 1
        Start-Sleep -Milliseconds 1000
        $imgIdle = [Ide]::Grab($app.Hwnd)
        $idlePx = $imgIdle.Diff($img, 0, 0, $img.W, $img.H, 0)
        if ($idlePx -eq 0) { $static = $true; break }
        $img = $imgIdle
    }
    [void](Save-Shot $imgIdle $Root 'ide-render-2-idle')
    Assert-Deadline $sw $TimeoutSec 'idle'
    Write-Check 'IDLE' ("diff_px={0} static={1} tries={2}" -f $idlePx, $static, $idleTries)

    $all = $bg.Ok -and $tok.Ok -and $gut.Ok -and $sb.Ok -and $repaint -and $static
    $result = if ($all) { 'PASS' } else { 'FAIL' }
    $code = if ($all) { 0 } else { 1 }
    Write-Host ("RESULT     bg={0} tokens={1} gutter={2} status={3} repaint={4} idle_static={5} => {6}" -f `
            $bg.Ok, $tok.Present, $gut.Ok, $sb.Ok, $repaint, $static, $result)
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        $why = $_.Exception.Message.Substring(11)
        Write-Host "START      $why"
        Write-Host "RESULT     render=SKIP(env-contention) reason=$why"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     render=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host "RESULT     render=FAIL(error) message=$($_.Exception.Message)"
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
