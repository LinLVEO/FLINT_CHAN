# snapshot.ps1 - whole-window pixel baseline. The 21 probes check behaviour; this one checks
# that the PIXELS did not move while refactoring. Run -Update once (after an intended visual
# change) to re-baseline, then it guards every later commit.
#
#   pwsh tools\probes\snapshot.ps1            # compare against tools\baselines\window.png
#   pwsh tools\probes\snapshot.ps1 -Update    # write/refresh the baseline
#
# Sandbox is fully deterministic: fixed cfg, fixed 12-line source, fixed window position.
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [switch]$Update,
    [double]$MaxDiffPct = 0.02,     # 0.02% = 140px：只吸收光标闪烁(~44px)。布局一动就是几千 px，跑不掉
    [int]$Tol = 12
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')

$Sand = Join-Path $Root 'tmp\ide-snapshot'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$BaseDir = Join-Path $Root 'tools\baselines'
$BasePng = Join-Path $BaseDir 'window.png'
New-Item -ItemType Directory -Force $SrcDir | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Sand 'tmp') | Out-Null
New-Item -ItemType Directory -Force $BaseDir | Out-Null

$body = @(
    '// snapshot sample · 中文注释',
    'int main() {',
    '    char *s = "hello 中文";',
    '    int n = 42;',
    '    return n;',
    '}',
    '',
    '// tail line for the gutter'
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $SrcDir 'main.fl'), $body + "`n", (New-Object System.Text.UTF8Encoding($false)))
$cfg = @('font=Consolas', 'size=15', 'weight=400', 'cjk=Noto Sans SC Medium', 'cjksize=0', 'wrap=0', 'ui=19', 'aa=1',
    'winx=120', 'winy=90', 'winw=1000', 'winh=700', 'winmax=0', 'tree=0', 'file=apps/studio_native/main.fl') -join "`n"
[System.IO.File]::WriteAllText((Join-Path $Sand 'studio.cfg'), $cfg + "`n", [System.Text.Encoding]::ASCII)
Remove-Item (Join-Path $Sand 'ai.state') -ErrorAction SilentlyContinue

$app = $null
$code = 1
try {
    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc) { throw 'window did not appear' }
    Position-Window $app.Hwnd
    # 鼠标必须停在编辑区中央：鼠标若恰好压在标题栏按钮上，hover 底色会让快照偶发不一致
    [Ide]::MoveClient($app.Hwnd, 500, 300)
    Start-Sleep -Milliseconds 150
    $img = Wait-Stable $app.Hwnd 1500 40
    if ($null -eq $img) { throw 'no frame' }
    Start-Sleep -Milliseconds 900
    $img = [Ide]::Grab($app.Hwnd)
    $shot = Save-Shot $img $Root 'ide-snapshot'
    Write-Host ("FRAME      {0}x{1}" -f $img.W, $img.H)

    if ($Update -or -not (Test-Path $BasePng)) {
        Copy-Item $shot $BasePng -Force
        Write-Host ("SNAPSHOT   baseline written: {0}" -f $BasePng)
        Write-Host "RESULT     snapshot=PASS(baseline)"
        $code = 0
    }
    else {
        $old = [System.Drawing.Bitmap]::FromFile($BasePng)
        $now = [System.Drawing.Bitmap]::FromFile($shot)
        try {
            if ($old.Width -ne $now.Width -or $old.Height -ne $now.Height) {
                Write-Host ("SNAPSHOT   size changed {0}x{1} -> {2}x{3}" -f $old.Width, $old.Height, $now.Width, $now.Height)
                Write-Host "RESULT     snapshot=FAIL(size)"
                $code = 1
            }
            else {
                $W = $now.Width; $H = $now.Height
                $diff = 0
                # stride-safe: compare row by row
                for ($y = 0; $y -lt $H; $y++) {
                    for ($x = 0; $x -lt $W; $x++) {
                        $a = $old.GetPixel($x, $y); $b = $now.GetPixel($x, $y)
                        $dr = [Math]::Abs($a.R - $b.R); $dg = [Math]::Abs($a.G - $b.G); $db = [Math]::Abs($a.B - $b.B)
                        if ($dr -gt $Tol -or $dg -gt $Tol -or $db -gt $Tol) { $diff++ }
                    }
                }
                $pct = 100.0 * $diff / ($W * $H)
                $ok = ($pct -le $MaxDiffPct)
                Write-Host ("SNAPSHOT   diff_px={0} ({1:N3}% of {2}px, tol={3}, max={4}%)" -f $diff, $pct, ($W * $H), $Tol, $MaxDiffPct)
                Write-Host ("RESULT     snapshot={0}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))
                $code = if ($ok) { 0 } else { 1 }
            }
        }
        finally { $old.Dispose(); $now.Dispose() }
    }
}
catch {
    Write-Host ("ERROR      {0}" -f $_.Exception.Message)
    Write-Host "RESULT     snapshot=FAIL(error)"
    $code = 1
}
finally {
    Stop-Studio $app $Root
}
exit $code
