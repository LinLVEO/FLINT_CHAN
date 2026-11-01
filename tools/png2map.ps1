# png2map.ps1 -- tile map PNG -> ASCII map grid (apps\*.txt for lib\mapload.fl)
#
# Usage:
#   pwsh -File tools\png2map.ps1 -Path art\tower.png [-Tile 16] [-Out apps\tower.txt]
#
# Color -> tile char (sample = center pixel of each tile):
#   alpha < 128 OR very dark  -> '.' (empty, tile 0)
#   #E8663C (red, palette 5)  -> '1' (solid)
#   #7FD8E8 (cyan, palette 4) -> '9' (one-way platform)
#   any other opaque color    -> '1' (solid, fallback)
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$Out = "",
  [int]$Tile = 16
)

Add-Type -AssemblyName System.Drawing

$resolved = (Resolve-Path -LiteralPath $Path).Path
$bmp = [System.Drawing.Bitmap]::FromFile($resolved)

$w = $bmp.Width
$h = $bmp.Height
if ($Tile -lt 1) { $Tile = 16 }
if (($w % $Tile) -ne 0 -or ($h % $Tile) -ne 0) {
  $bmp.Dispose()
  throw "png2map: image ${w}x${h} is not divisible by tile size $Tile"
}
$tw = [int]($w / $Tile)
$th = [int]($h / $Tile)

$lines = New-Object System.Collections.Generic.List[string]
$half = [int]($Tile / 2)

for ($ty = 0; $ty -lt $th; $ty++) {
  $sb = New-Object System.Text.StringBuilder
  for ($tx = 0; $tx -lt $tw; $tx++) {
    $c = $bmp.GetPixel($tx * $Tile + $half, $ty * $Tile + $half)
    if ($c.A -lt 128) {
      [void]$sb.Append('.')
      continue
    }
    # very dark = empty (so a dark background reads as empty, not solid)
    if (($c.R + $c.G + $c.B) -lt 60) {
      [void]$sb.Append('.')
      continue
    }
    $dr = [int]$c.R - 0xE8; $dg = [int]$c.G - 0x66; $db = [int]$c.B - 0x3C
    $dRed = $dr * $dr + $dg * $dg + $db * $db
    $cr = [int]$c.R - 0x7F; $cg = [int]$c.G - 0xD8; $cb = [int]$c.B - 0xE8
    $dCyan = $cr * $cr + $cg * $cg + $cb * $cb
    if ($dCyan -lt $dRed) {
      [void]$sb.Append('9')
    } else {
      [void]$sb.Append('1')
    }
  }
  $lines.Add($sb.ToString())
}

$bmp.Dispose()

if ($Out -eq "") { $Out = [System.IO.Path]::ChangeExtension($resolved, ".txt") }
$lines -join "`r`n" | Set-Content -LiteralPath $Out -Encoding ascii -NoNewline
Write-Output ("png2map: {0} -> {1} ({2}x{3} tiles, tile {4}px)" -f $resolved, $Out, $tw, $th, $Tile)
