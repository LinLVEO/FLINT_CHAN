# audit-ide.ps1 - static quality audit of the FLINT Studio sources (honest numbers, no opinions).
param([string]$Root = (Split-Path (Split-Path $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
$fl = Join-Path $Root 'apps\studio_native\studio_win.fl'
$c  = Join-Path $Root 'apps\studio_native\studio_text.c'
$lib = Join-Path $Root 'lib\flgui_win32.fl'

function Count-Pat([string]$path, [string]$pat) {
    return (Select-String -Path $path -Pattern $pat).Count
}

Write-Host "=== size ==="
foreach ($p in @($fl, $c, $lib)) {
    $n = (Get-Content $p).Count
    Write-Host ("  {0,-42} {1,6} lines" -f (Split-Path $p -Leaf), $n)
}

Write-Host "=== functions / biggest ==="
$starts = Select-String -Path $fl -Pattern '^[a-zA-Z_].*\) \{' | ForEach-Object { [pscustomobject]@{ Line = $_.LineNumber; Text = $_.Line.Trim() } }
Write-Host ("  functions: {0}" -f $starts.Count)
$rows = @()
for ($i = 0; $i -lt $starts.Count - 1; $i++) {
    $len = $starts[$i + 1].Line - $starts[$i].Line
    $name = $starts[$i].Text.Substring(0, [Math]::Min(60, $starts[$i].Text.Length))
    $rows += [pscustomobject]@{ Len = $len; Name = $name }
}
$rows | Sort-Object Len -Descending | Select-Object -First 6 | ForEach-Object { Write-Host ("  {0,5} lines  {1}" -f $_.Len, $_.Name) }

Write-Host "=== duplication (same logic written twice) ==="
Write-Host ("  tree-row loop copies (g_tpath + ti * 160): {0}" -f (Count-Pat $fl 'g_tpath \+ ti \* 160'))
Write-Host ("  line-number math copies (g_lrow[rl]):       {0}" -f (Count-Pat $fl 'g_lrow\[rl\]'))
Write-Host ("  status 'Ln ' formatting blocks:             {0}" -f (Count-Pat $fl '"Ln "'))
Write-Host ("  menu_x/width recomputed at call sites:      {0}" -f (Count-Pat $fl 'ui_cur\(&sf, menu_title'))

Write-Host "=== literal constants (layout magic numbers) ==="
foreach ($n in @(220, 240, 268, 34, 26, 60)) {
    Write-Host ("  {0,4}: {1,3} occurrences" -f $n, (Count-Pat $fl "\b$n\b"))
}

Write-Host "=== hygiene ==="
Write-Host ("  TODO/FIXME/XXX/HACK: {0}" -f (Count-Pat $fl 'TODO|FIXME|XXX|HACK'))
Write-Host ("  empty leftover blocks: {0}" -f (Count-Pat $fl 'if \([^)]*\) \{ \}'))
Write-Host ("  VirtualAlloc sites: {0}" -f (Count-Pat $fl 'VirtualAlloc'))
Write-Host ("  ignored-return calls (bare func(...);): {0}" -f (Count-Pat $fl '^\s*[a-zA-Z_]+\('))

Write-Host "=== probe coverage ==="
$probes = Get-ChildItem (Join-Path $Root 'tmp') -Filter 'probe-*.ps1'
$checks = 0
foreach ($p in $probes) { $checks += (Count-Pat $p.FullName "Write-Check|Check '") }
Write-Host ("  probe scripts: {0}, assertion call sites: {1}" -f $probes.Count, $checks)

Write-Host "=== shim ==="
Write-Host ("  exported tx_* functions: {0}" -f (Count-Pat $c '__declspec\(dllexport\)'))
Write-Host ("  comments (//, /* */ lines): {0}" -f (Count-Pat $c '^\s*(//|/\*|\*)'))
