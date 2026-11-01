# png2sprite.ps1 -- PNG -> sprite ASCII grid (palette index per pixel)
#
# Usage:
#   pwsh -File tools\png2sprite.ps1 -Path art\hero.png [-Frames 3] [-Out sprites\hero.txt]
#
# - Frames: how many frames are laid out horizontally in the PNG (default 1).
#   Each frame is W/Frames pixels wide. Frames are separated by a blank line
#   in the output (that is what tools\sprite2fl.js expects).
# - alpha < 128 -> '.' (transparent); otherwise nearest of the 6 palette colors (1..6).
# - output: ASCII '0'..'6' + '.' per pixel, CRLF, no trailing newline.
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [string]$Out = "",
  [int]$Frames = 1
)

Add-Type -AssemblyName System.Drawing

$resolved = (Resolve-Path -LiteralPath $Path).Path
$bmp = [System.Drawing.Bitmap]::FromFile($resolved)

$palR = @(0, 0x0B, 0x1B, 0xE8, 0x7F, 0xE8, 0xF2)
$palG = @(0, 0x0E, 0x23, 0xF0, 0xD8, 0x66, 0xC1)
$palB = @(0, 0x1A, 0x40, 0xFF, 0xE8, 0x3C, 0x4E)

$w = $bmp.Width
$h = $bmp.Height
if ($Frames -lt 1) { $Frames = 1 }
if (($w % $Frames) -ne 0) {
  $bmp.Dispose()
  throw "png2sprite: width $w is not divisible by -Frames $Frames"
}
$fw = [int]($w / $Frames)

$lines = New-Object System.Collections.Generic.List[string]

for ($fi = 0; $fi -lt $Frames; $fi++) {
  if ($fi -gt 0) { $lines.Add("") }
  for ($y = 0; $y -lt $h; $y++) {
    $sb = New-Object System.Text.StringBuilder
    for ($x = $fi * $fw; $x -lt ($fi + 1) * $fw; $x++) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.A -lt 128) {
        [void]$sb.Append('.')
        continue
      }
      $best = 1
      $bd = [double]::MaxValue
      for ($k = 1; $k -le 6; $k++) {
        $dr = [int]$c.R - $palR[$k]
        $dg = [int]$c.G - $palG[$k]
        $db = [int]$c.B - $palB[$k]
        $d = $dr * $dr + $dg * $dg + $db * $db
        if ($d -lt $bd) { $bd = $d; $best = $k }
      }
      [void]$sb.Append([string]$best)
    }
    $lines.Add($sb.ToString())
  }
}

$bmp.Dispose()

if ($Out -eq "") { $Out = [System.IO.Path]::ChangeExtension($resolved, ".txt") }
$lines -join "`r`n" | Set-Content -LiteralPath $Out -Encoding ascii -NoNewline
Write-Output ("png2sprite: {0} -> {1} ({2}x{3}, {4} frame(s) of {5}x{6})" -f $resolved, $Out, $w, $h, $Frames, $fw, $h)
