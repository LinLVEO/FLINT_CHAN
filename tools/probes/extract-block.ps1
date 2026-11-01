# extract-block.ps1 - the safe way to cut a block out of studio_win.fl into its own function.
#
# Why this exists: three extractions failed because the block's tail brace belonged to an OUTER
# wrapper (`if (g_seton == 0) { ... }`) - a plain "cut from marker A to marker B" then leaves the
# file with unbalanced braces and the compiler points somewhere useless. This script refuses to
# write unless the slice is brace-balanced by itself.
#
# Usage:
#   pwsh tools\probes\extract-block.ps1 -Fn handle_foo -Params "struct GuiInput *in" `
#        -StartPat '^    // —— 滚轮' -EndPat '^    // —— 下一次' -Call '    handle_foo(&in);'
#
#   -EndPat is the regex of the line AFTER the block (exclusive).
#   -DryRun prints the slice and the brace check without touching the file.
param(
    [string]$Path = 'E:\FLINT-lab\apps\studio_native\studio_win.fl',
    [Parameter(Mandatory = $true)][string]$Fn,
    [Parameter(Mandatory = $true)][string]$Params,
    [Parameter(Mandatory = $true)][string]$StartPat,
    [Parameter(Mandatory = $true)][string]$EndPat,
    [Parameter(Mandatory = $true)][string]$Call,
    [string]$Comment = '',
    [int]$MinLines = 5,
    [int]$MaxLines = 220,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$nl = "`r`n"

# 去掉字符串与行注释后再数花括号（够用：本仓的字符串里没有 `{`，注释里偶尔有）
function Strip-Noise([string]$s) {
    $s = [regex]::Replace($s, '"[^"]*"', '""')
    $s = [regex]::Replace($s, '//.*$', '')
    return $s
}
function Brace-Delta([string]$s) {
    $t = Strip-Noise $s
    $open = ([regex]::Matches($t, '\{')).Count
    $close = ([regex]::Matches($t, '\}')).Count
    return ($open - $close)
}

$lines = [System.IO.File]::ReadAllText($Path) -split "`r`n"
$start = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $StartPat) { $start = $i; break } }
if ($start -lt 0) { throw "start anchor missing: $StartPat" }
for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $EndPat) { $end = $i - 1; break } }
if ($end -lt 0) { throw "end anchor missing: $EndPat" }
$n = $end - $start + 1
if ($n -lt $MinLines -or $n -gt $MaxLines) { throw ("block size {0} outside {1}..{2}" -f $n, $MinLines, $MaxLines) }

# 1) 直接切：花括号必须自平衡
$slice = $lines[$start..$end]
$delta = 0
$lastNonEmpty = $end
for ($i = $start; $i -le $end; $i++) { $delta += (Brace-Delta $lines[$i]) }
while ($lastNonEmpty -gt $start -and $lines[$lastNonEmpty].Trim() -eq '') { $lastNonEmpty-- }
if ($lastNonEmpty -ne $end) { $slice = $lines[$start..$lastNonEmpty] }

# 2) 自愈：delta > 0 说明块自己还没闭合（尾巴在后面），往后补到 delta 归零；
#    delta < 0 说明切多了（把外层的收尾捎进来了），从尾部往前退到 delta 归零。
$guard = 0
while ($delta -gt 0) {
    $lastNonEmpty++
    if ($lastNonEmpty -ge $lines.Count) { throw 'slice never closes (ran off the file)' }
    $delta += (Brace-Delta $lines[$lastNonEmpty])
    $guard++
    if ($guard -gt 30) { throw 'too many lines added while closing the slice' }
}
$guard = 0
while ($delta -lt 0) {
    $delta -= (Brace-Delta $lines[$lastNonEmpty])
    $lastNonEmpty--
    $guard++
    if ($guard -gt 30) { throw 'too many lines trimmed while balancing the slice' }
}
$slice = $lines[$start..$lastNonEmpty]
if ($delta -ne 0) { throw ("slice still unbalanced (delta {0})" -f $delta) }

$body = ([string]::Join($nl, $slice)) -replace '\bin\.', 'in->'
# &sf 是 main 的画布指针：函数里要收 struct Surf *s 并改写成 s。漏了会编译报"未声明 sf"。
if ($body -match '&sf') {
    if ($Params -notmatch 'struct Surf \*s') { throw 'slice uses &sf -> add "struct Surf *s" as the FIRST param and pass &sf in -Call' }
    $body = $body.Replace('&sf', 's')
}

$header = @(
    ('// ===== ' + $Fn + ' ====='),
    ('//   ' + $Comment),
    ('int ' + $Fn + '(' + $Params + ') {'),
    '  int y = 0;',
    '  int i = 0;',
    '  int j = 0;',
    $body,
    '  return 0;',
    '}',
    ''
)
if ($DryRun) {
    Write-Host ("OK (dry): {0} lines, brace delta 0 -> would become {1}()" -f $slice.Count, $Fn)
    $slice | ForEach-Object { Write-Host ("   | " + $_) }
    exit 0
}

$before = [string]::Join($nl, $lines[0..($start - 1)])
$after = [string]::Join($nl, $lines[($lastNonEmpty + 1)..($lines.Count - 1)])
$t2 = $before + $nl + $Call + $nl + $after
$t2 = $t2.Replace('int main() {', ([string]::Join($nl, $header)) + $nl + 'int main() {')
[System.IO.File]::WriteAllText($Path, $t2, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("OK {0}: {1} lines -> main shrinks" -f $Fn, $slice.Count)
