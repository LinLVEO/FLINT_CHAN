# sarp-scale.ps1 -- card T-20260922-201154 acceptance: local struct with a fixed-length int array
# field, at the six lengths the FLGUI probes used, BOTH compilers, N runs each, no crash allowed.
# The frame must be >= 4 + 8*N and the element stride must stay 8.
$ErrorActionPreference = 'Continue'
$root = 'E:\FLINT-lab'
$tmp = Join-Path $root 'tmp\sarp-scale'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$flint = Join-Path $root 'flint.exe'
$boot = Join-Path $root 'boot\b1_emit.exe'
$runs = 10
$lengths = @(144, 176, 184, 188, 190, 192)

$body = @'
struct S { int n; int a[__N__]; }
int main() {
  struct S s;
  s.n = 1;
  int i = 0;
  while (i < __N__) {
    s.a[i] = i + 1;
    i = i + 1;
  }
  int k = 0;
  int sum = 0;
  while (k < __N__) {
    sum = sum + s.a[k];
    k = k + 1;
  }
  return sum + s.n;
}
'@

foreach ($n in $lengths) {
  $src = Join-Path $tmp ("sarp$n.fl")
  [IO.File]::WriteAllText($src, ($body.Replace('__N__', "$n")), (New-Object Text.UTF8Encoding($false)))
  $expect = ($n * ($n + 1)) / 2 + 1
  Push-Location $root
  & $flint $src -o (Join-Path $tmp "f$n.exe") 2>&1 | Out-Null
  $cf = $LASTEXITCODE
  & $boot $src 2>&1 | Out-Null
  $cb = $LASTEXITCODE
  Pop-Location
  $bf = Join-Path $tmp ("sarp$n.exe")
  $fx = Join-Path $tmp "f$n.exe"
  $fr = @(); $br = @()
  if (Test-Path $fx) { for ($i = 0; $i -lt $runs; $i++) { & $fx; $fr += $LASTEXITCODE } }
  if (Test-Path $bf) {
    for ($i = 0; $i -lt $runs; $i++) { & $bf; $br += $LASTEXITCODE }
    $frame = (& objdump -d $bf 2>&1 | Select-String -Pattern 'sub\s+\$0x([0-9a-f]+),%rsp' | Select-Object -First 1)
    Remove-Item $bf -Force -ErrorAction SilentlyContinue
  } else { $frame = 'no product' }
  Remove-Item $fx -Force -ErrorAction SilentlyContinue
  $fc = @($fr | Sort-Object -Unique); $bc = @($br | Sort-Object -Unique)
  Write-Output ("N=$n compile flint=$cf boot=$cb | flint runs unique=[$($fc -join ',')] | boot runs unique=[$($bc -join ',')] | expect=$expect")
  Write-Output ("      boot frame: " + ("$frame".Trim()))
}
Write-Output ("scratch: " + $tmp)
