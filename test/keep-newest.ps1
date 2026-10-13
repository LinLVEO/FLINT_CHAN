# keep-newest.ps1 -- move the OLDEST blocks of a marker-delimited list into an archive file, verbatim.
# Why: PROGRESS.md "handover blocks" (keep newest 5) and 记忆.md update-log entries (keep newest 3)
#   were hand-moved 7 times; every hand-move risked eating a line (see memory: new_string ate the anchor).
# Safety rails: read/write with explicit UTF8 (no BOM -- .md files never carry one), byte-level backup
#   next to the file, line endings preserved (LF stays LF), post-write read-back self checks:
#     1) every non-empty moved line is present in the archive
#     2) the kept head is line-for-line identical to the original head
#     3) the marker count in the new main file == Keep
# ASCII only on purpose (a .ps1 with non-ASCII needs a UTF-8 BOM -- see memory rule).
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$Archive,
  [Parameter(Mandatory=$true)][string]$Pattern,   # regex matched at line start for each block
  [Parameter(Mandatory=$true)][int]$Keep,
  [string]$Continuation = '^>|^$',   # how a line "keeps belonging" to the current block
  [string]$Banner = "",
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$enc = New-Object Text.UTF8Encoding($false)
$raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
$nl = "`n"
if ($raw.Contains("`r`n")) { $nl = "`r`n" }
$lines = $raw -split "`r?`n"
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }

$idx = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^$Pattern") { [void]$idx.Add($i) } }
$n = $idx.Count
Write-Output ("-- file    : {0}  ({1} lines / {2} bytes / newline={3})" -f (Split-Path $Path -Leaf), $lines.Count, (Get-Item $Path).Length, ($(if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' })))
Write-Output ("-- markers : {0}   (pattern ^{1})" -f $n, $Pattern)
if ($n -le $Keep) { Write-Output ("-- nothing to do: markers {0} <= keep {1}" -f $n, $Keep); exit 0 }

$firstMove = $idx[$Keep]
# region end: start scanning AFTER the last block's own marker line (that line is the block's start,
#   it never "extends" itself), then keep consuming continuation lines (blank / '>' prefixed).
$end = $lines.Count - 1
for ($i = $idx[$n - 1] + 1; $i -lt $lines.Count; $i++) {
  $l = $lines[$i]
  if ($l -match $Continuation) { continue }
  $end = $i - 1
  break
}
$moved = @($lines[$firstMove..$end])
$head = @($lines[0..($firstMove - 1)])
$tail = @()
if ($end + 1 -lt $lines.Count) { $tail = @($lines[($end + 1)..($lines.Count - 1)]) }
$movedNonEmpty = @($moved | Where-Object { $_ -ne '' })
Write-Output ("-- keep    : markers 1..{0}  (lines 1..{1})" -f $Keep, $firstMove)
Write-Output ("-- move    : markers {0}..{1}  (lines {2}..{3}, {4} lines / {5} non-empty)" -f ($Keep + 1), $n, ($firstMove + 1), ($end + 1), $moved.Count, $movedNonEmpty.Count)
Write-Output ("-- tail    : {0} lines stay after the moved region" -f $tail.Count)
if (-not $Apply) { Write-Output '-- PREVIEW only (add -Apply to write)'; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$Path.bak-$stamp-thin"
Copy-Item -LiteralPath $Path -Destination $bak -Force
Write-Output ("-- backup  : {0}" -f $bak)

# 1) append to the archive: banner + moved lines, verbatim
$archRaw = ''
if (Test-Path $Archive) { $archRaw = [IO.File]::ReadAllText($Archive, [Text.Encoding]::UTF8) }
if ($archRaw -ne '' -and -not $archRaw.EndsWith($nl)) { $archRaw = $archRaw + $nl }
[IO.File]::WriteAllText($Archive, $archRaw + $nl + $Banner + $nl + $nl + ($moved -join $nl) + $nl, $enc)

# 2) rewrite the main file: head + blank + tail
$newHead = $head
while ($newHead.Count -gt 0 -and $newHead[$newHead.Count - 1] -eq '') { $newHead = @($newHead[0..($newHead.Count - 2)]) }
$newLines = @($newHead) + @('') + @($tail)
while ($newLines.Count -gt 0 -and $newLines[$newLines.Count - 1] -eq '') { $newLines = @($newLines[0..($newLines.Count - 2)]) }
[IO.File]::WriteAllText($Path, (($newLines -join $nl) + $nl), $enc)

# 3) read-back self checks
$fail = 0
$archNow = [IO.File]::ReadAllText($Archive, [Text.Encoding]::UTF8)
$archSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($l in ($archNow -split "`r?`n")) { if ($l -ne '') { [void]$archSet.Add($l) } }
$missing = 0
foreach ($l in $movedNonEmpty) { if (-not $archSet.Contains($l)) { $missing++ } }
if ($missing -eq 0) { Write-Output ("-- check 1: moved non-empty lines all present in archive ({0}) OK" -f $movedNonEmpty.Count) }
else { Write-Output ("!! check 1: {0} moved lines missing from archive" -f $missing); $fail++ }

$nowRaw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
$nowLines = $nowRaw -split "`r?`n"
$headSame = $true
for ($i = 0; $i -lt $newHead.Count; $i++) { if ($nowLines[$i] -ne $newHead[$i]) { $headSame = $false; Write-Output ("!! head differs at line {0}" -f ($i + 1)); break } }
if ($headSame) { Write-Output ("-- check 2: kept head line-for-line identical ({0} lines) OK" -f $newHead.Count) } else { $fail++ }

$cntAfter = 0
foreach ($l in $nowLines) { if ($l -match "^$Pattern") { $cntAfter++ } }
if ($cntAfter -eq $Keep) { Write-Output ("-- check 3: markers in new main = {0} (= keep) OK" -f $cntAfter) }
else { Write-Output ("!! check 3: markers in new main = {0}, expected {1}" -f $cntAfter, $Keep); $fail++ }

Write-Output ("-- result  : main {0} -> {1} bytes / archive {2} -> {3} bytes" -f (Get-Item $Path).Length, (Get-Item $Path).Length, $archRaw.Length, (Get-Item $Archive).Length)
if ($fail -gt 0) { Write-Output '!! FAILED self checks -- restore from the .bak file'; exit 1 }
Write-Output 'DONE (self checks passed)'
exit 0
