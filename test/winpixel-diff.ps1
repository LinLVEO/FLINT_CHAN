# winpixel-diff.ps1 -- compare two winpixel.ps1 snapshots (render-layer criterion for FLGUI M3 dogfood).
# Reports: differing pixel count / ratio / bbox / top colour transitions / per-row distribution.
# ASCII only on purpose (a .ps1 with non-ASCII needs a UTF-8 BOM; see the memory rule).
# Usage: powershell -File winpixel-diff.ps1 -A <before> -B <after>
param(
  [Parameter(Mandatory=$true)][string]$A,
  [Parameter(Mandatory=$true)][string]$B,
  [int]$MaxListLines = 12
)
$ErrorActionPreference = 'Stop'
$script:snapW = 0; $script:snapH = 0; $script:snapMap = $null

function Load-Snap([string]$path) {
  $ls = [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)
  $h = $ls[0] -split ' '
  $w = [int]($h[0].Substring(2)); $ht = [int]($h[1].Substring(2))
  $map = [int[]]::new($w * $ht * 3)
  for ($i = 1; $i -lt $ls.Count; $i++) {
    $l = $ls[$i]
    if ($l.Length -eq 0) { continue }
    $f = $l.Split(' ')
    if ($f.Count -lt 5) { continue }
    $x = [int]$f[1]; $y = [int]$f[0]
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $w -or $y -ge $ht) { continue }
    $k = ($y * $w + $x) * 3
    $map[$k] = [int]$f[2]; $map[$k + 1] = [int]$f[3]; $map[$k + 2] = [int]$f[4]
  }
  $script:snapW = $w; $script:snapH = $ht; $script:snapMap = $map
  Write-Output ("loaded " + (Split-Path $path -Leaf) + " : " + $w + "x" + $ht)
}

Load-Snap $A
$aw = $script:snapW; $ah = $script:snapH; $am = $script:snapMap
Load-Snap $B
$bw = $script:snapW; $bh = $script:snapH; $bm = $script:snapMap

if ($aw -ne $bw -or $ah -ne $bh) { Write-Output 'SIZE MISMATCH -- cannot compare pixel by pixel'; exit 2 }

$total = $aw * $ah
$diff = 0
$minx = 999999; $miny = 999999; $maxx = -1; $maxy = -1
$pairs = @{}
$rowdiff = [int[]]::new($ah)
for ($y = 0; $y -lt $ah; $y++) {
  for ($x = 0; $x -lt $aw; $x++) {
    $k = ($y * $aw + $x) * 3
    if ($am[$k] -ne $bm[$k] -or $am[$k + 1] -ne $bm[$k + 1] -or $am[$k + 2] -ne $bm[$k + 2]) {
      $diff = $diff + 1
      $rowdiff[$y] = $rowdiff[$y] + 1
      if ($x -lt $minx) { $minx = $x }
      if ($x -gt $maxx) { $maxx = $x }
      if ($y -lt $miny) { $miny = $y }
      if ($y -gt $maxy) { $maxy = $y }
      $pk = "($($am[$k]),$($am[$k+1]),$($am[$k+2])) -> ($($bm[$k]),$($bm[$k+1]),$($bm[$k+2]))"
      if ($pairs.ContainsKey($pk)) { $pairs[$pk] = $pairs[$pk] + 1 } else { $pairs[$pk] = 1 }
    }
  }
}
$pct = 0.0
if ($total -gt 0) { $pct = [Math]::Round(100.0 * $diff / $total, 3) }
Write-Output ("DIFF pixels = " + $diff + " / " + $total + "  (" + $pct + "%)")
if ($diff -gt 0) { Write-Output ("bbox = x[" + $minx + ".." + $maxx + "] y[" + $miny + ".." + $maxy + "]") }
Write-Output '--- top colour changes ---'
$pairs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { Write-Output ("  x" + $_.Value + "  " + $_.Key) }
Write-Output ("--- rows with most changes (top " + $MaxListLines + ") ---")
$order = 0..($ah - 1) | Sort-Object { -$rowdiff[$_] }
$shown = 0
foreach ($y in $order) {
  if ($rowdiff[$y] -le 0) { continue }
  Write-Output ("  y=" + $y + "  changed=" + $rowdiff[$y])
  $shown = $shown + 1
  if ($shown -ge $MaxListLines) { break }
}
if ($diff -eq 0) { Write-Output 'VERDICT: identical' } else { Write-Output 'VERDICT: different' }
