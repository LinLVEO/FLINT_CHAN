# budget-gate.ps1 -- the `budget` step's single entry point.
#   (The file NAME is CJK -- "budget" + "gate" in Chinese -- and the CONTENT is pure ASCII on
#    purpose, so the ASCII-contract gate test\verify-all.ps1 can call it. This script builds
#    every CJK path it needs from code points; see the path block below.)
#
# WHY A BASELINE GATE AND NOT AN ABSOLUTE ONE (decided by the main agent, 2026-10-13):
#   The two budget meters (tools\ "import budget" and tools\ "boot headroom") can each be RED for
#   a state that is not a regression:
#     * apps\m2_float\m2_float.exe currently sits at 96/96 imports and 8/8 modules -- a freshly
#       rebuilt product of the current source measures the same, so it is a REAL exhaustion, but
#       it is a pre-existing fact, not something a commit did.
#     * boot's single function table for apps\m2_float\main.fl currently sits at 512/512
#       (headroom 0) -- likewise pre-existing.
#   A gate that is RED every run for the status quo is the worst product this project knows:
#   "the most expensive false red is training people to read real reds as noise". So the gate
#   judges REGRESSION, not status quo -- the same counting rule as the equivalence and
#   differential gates, which compare against a recorded baseline and red on any change that was
#   not explicitly re-recorded.
#
# RULES (deliberate; every one of them reds rather than staying quiet):
#   * baseline missing or unreadable          -> RED, tells you to record it (-UpdateBaseline).
#   * a recorder instrument exits 2           -> RED (the meter itself failed; never silently green).
#   * boot meter exits 1 (occupied > limit)   -> RED (boot genuinely cannot compile the app).
#   * any recorded number CHANGED             -> RED, in BOTH directions. Spending one more import
#     / one more table slot is a real regression; spending one LESS is a counting-rule change that must be
#     re-recorded too, otherwise a later "back to the old level" regression slips under the gate
#     (same family as the archived lesson "after making it faster you must re-record the baseline").
#   * import caps read from src\pe.c changed  -> RED (the budget itself was redefined).
#   * boot table occupied / limit / headroom / api / func changed -> RED (that is the whole account).
#   * module NAME list of a product changed   -> WARN only (the capped quantity is the module COUNT;
#     the names are informational).
#   * a recorded product is MISSING now, or a new FLINT-family product appeared -> WARN only.
#     These .exe files are gitignored build products, and their presence depends on which gate or
#     experiment last ran (test\loop-verify.ps1 leaves/restores apps\m2_float\main.exe), so their
#     set is not a budget fact. They are still printed loudly with their numbers.
#   * the status quo is ALWAYS printed loudly: an at-cap product and a 0-headroom boot table each
#     get a WARN line, so "we are out of budget" stays visible without being a false red.
#
# Recording / re-recording (a re-record is a counting-rule change -- say why, and say it in the commit):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\<this file> -UpdateBaseline -Reason "why"
#   Keep the reason ASCII if you want the baseline JSON to stay pure ASCII; non-ASCII characters
#   are written as \uXXXX escapes (still valid JSON, still byte-ASCII on disk).
#
# Exit codes: 0 = every recorded number matches the baseline | 1 = a difference, a missing baseline,
# or a recorder failure | 2 = this gate itself could not run.
# ASCII only.

param(
  [string]$Root = '',
  [string]$Baseline = '',
  [switch]$UpdateBaseline,
  [string]$Reason = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Root -eq '') { $Root = Split-Path $PSScriptRoot -Parent }
$rootFull = [IO.Path]::GetFullPath($Root)

# ---- CJK paths, built from code points so this file stays pure ASCII ----
# tool file 1  = "tools\" + U+5BFC U+5165 U+9884 U+7B97 + ".ps1"      (CJK: import budget)
# tool file 2  = "tools\boot" + U+4F59 U+91CF + ".ps1"                (CJK: headroom)
# baseline     = "test\" + U+9884 U+7B97 U+57FA U+7EBF + ".json"      (CJK: budget baseline)
$importTool = Join-Path $rootFull ('tools\' + [char]0x5BFC + [char]0x5165 + [char]0x9884 + [char]0x7B97 + '.ps1')
$bootTool = Join-Path $rootFull ('tools\boot' + [char]0x4F59 + [char]0x91CF + '.ps1')
if ($Baseline -eq '') { $Baseline = Join-Path $rootFull ('test\' + [char]0x9884 + [char]0x7B97 + [char]0x57FA + [char]0x7EBF + '.json') }
$psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')

function Write-Line([string]$s) { Write-Host $s }

function Run-Instrument([string]$label, [string]$tool) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    return [pscustomobject]@{ Label = $label; Tool = $tool; Ran = $false; Exit = -1; Json = $null; Note = "missing instrument: $tool" }
  }
  $t = & powershell @psArgs @($tool, '-Json') 2>&1
  $c = $LASTEXITCODE
  if ($null -eq $c) { $c = 1 }
  $text = (@($t) -join [string][char]10)
  $obj = $null
  if ($c -ne 2) {
    try { $obj = $text | ConvertFrom-Json } catch { }
  }
  return [pscustomobject]@{ Label = $label; Tool = $tool; Ran = $true; Exit = $c; Json = $obj; Note = $text }
}

$imp = Run-Instrument 'import-budget' $importTool
$boot = Run-Instrument 'boot-headroom' $bootTool
$fatal = New-Object System.Collections.ArrayList

if (-not $imp.Ran) { [void]$fatal.Add($imp.Note) }
elseif ($imp.Exit -eq 2) { [void]$fatal.Add('import-budget meter failed (exit 2); output: ' + $imp.Note) }
elseif ($null -eq $imp.Json) { [void]$fatal.Add('import-budget -Json output could not be parsed') }
if (-not $boot.Ran) { [void]$fatal.Add($boot.Note) }
elseif ($boot.Exit -eq 2) { [void]$fatal.Add('boot-headroom meter failed (exit 2); output: ' + $boot.Note) }
elseif ($null -eq $boot.Json) { [void]$fatal.Add('boot-headroom -Json output could not be parsed') }
elseif ($boot.Exit -eq 1) { [void]$fatal.Add(('boot function table is OVER its limit: occupied {0} > limit {1} (boot reports parse err=-85 on this app)' -f $boot.Json.Occupied, $boot.Json.Limit)) }

# ---- current state, reduced to the numbers the baseline records ----
$maxImports = 0
$maxGroups = 0
$products = @()
$foreign = @()
if ($imp.Json -ne $null) {
  $maxImports = [int]$imp.Json.MaxImports
  $maxGroups = [int]$imp.Json.MaxGroups
  foreach ($r in @($imp.Json.Rows)) {
    if ($null -eq $r) { continue }
    if ([string]$r.Kind -notlike 'FLINT*') { $foreign += $r; continue }
    $products += [pscustomobject]@{
      Artifact = [string]$r.Artifact
      Imports = [int](([string]$r.Imports -split '/')[0])
      Groups = [int](([string]$r.Groups -split '/')[0])
      Modules = [string]$r.Modules
    }
  }
  $products = @($products | Sort-Object -Property Artifact)
}
$bootNow = $null
if ($boot.Json -ne $null) {
  $bootNow = [pscustomobject]@{
    App = [string]$boot.Json.App
    Occupied = [int]$boot.Json.Occupied
    Limit = [int]$boot.Json.Limit
    Headroom = [int]$boot.Json.Headroom
    Api = [int]$boot.Json.Api
    Func = [int]$boot.Json.Func
    LimitSource = [string]$boot.Json.LimitSource
  }
}

# ---- loud status quo (never a red by itself) ----
$status = New-Object System.Collections.ArrayList
foreach ($p in $products) {
  $atCap = ($p.Imports -ge $maxImports -or $p.Groups -ge $maxGroups)
  $line = ('  {0,-42} imports {1,3}/{2}  modules {3}/{4}  {5}' -f $p.Artifact, $p.Imports, $maxImports, $p.Groups, $maxGroups, $p.Modules)
  [void]$status.Add($line)
  if ($atCap) {
    [void]$status.Add(('WARN {0} {1}/{2} imports, {3}/{4} modules -- AT LIMIT, needs attribution / budget re-layout' -f $p.Artifact, $p.Imports, $maxImports, $p.Groups, $maxGroups))
  }
}
foreach ($f in $foreign) {
  [void]$status.Add(('  {0,-42} foreign ({1}) -- listed, not counted against the cap' -f [string]$f.Artifact, [string]$f.Kind))
}
if ($bootNow -ne $null) {
  [void]$status.Add(('  boot table ({0}): occupied {1}/{2}  headroom {3}  api {4} + func {5}' -f $bootNow.App, $bootNow.Occupied, $bootNow.Limit, $bootNow.Headroom, $bootNow.Api, $bootNow.Func))
  if ($bootNow.Headroom -lt 0) {
    [void]$status.Add(('WARN boot table {0}/{1} (headroom {2}) -- OVER LIMIT' -f $bootNow.Occupied, $bootNow.Limit, $bootNow.Headroom))
  } elseif ($bootNow.Headroom -le 8) {
    [void]$status.Add(('WARN boot table {0}/{1} (headroom {2}) -- adding one library function fails with parse err=-85' -f $bootNow.Occupied, $bootNow.Limit, $bootNow.Headroom))
  }
}

function New-BaselineObject([string]$why) {
  $rec = [pscustomobject]@{
    Schema = 1
    Tool = 'budget-gate'
    Recorded = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Reason = $why
    ImportCaps = [pscustomobject]@{ MaxImports = $maxImports; MaxGroups = $maxGroups; Source = 'src\pe.c' }
    Products = @($products | ForEach-Object { [pscustomobject]@{ Artifact = $_.Artifact; Imports = $_.Imports; Groups = $_.Groups; Modules = $_.Modules } })
    BootTable = $(if ($bootNow -eq $null) { $null } else { [pscustomobject]@{ App = $bootNow.App; Occupied = $bootNow.Occupied; Limit = $bootNow.Limit; Headroom = $bootNow.Headroom; Api = $bootNow.Api; Func = $bootNow.Func; LimitSource = $bootNow.LimitSource } })
  }
  return $rec
}

function ConvertTo-AsciiJson($obj) {
  $j = $obj | ConvertTo-Json -Depth 8
  # keep the file byte-ASCII: escape every non-ASCII character as a JSON \uXXXX escape
  $j = [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u' + ('{0:x4}' -f [int][char]$m.Value) })
  return $j
}

# ---- record mode ----
if ($UpdateBaseline) {
  if ($fatal.Count -gt 0) {
    Write-Line ''
    Write-Line 'budget gate: REFUSING to record a baseline from a failed meter:'
    foreach ($f in $fatal) { Write-Line ('  !! ' + $f) }
    exit 1
  }
  if ($Reason -eq '') {
    Write-Line ''
    Write-Line 'budget gate: -UpdateBaseline needs -Reason "<why>" -- a re-record is a counting-rule change and must say why.'
    exit 2
  }
  $obj = New-BaselineObject $Reason
  $dir = Split-Path $Baseline -Parent
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Baseline, (ConvertTo-AsciiJson $obj) + [string][char]10, (New-Object System.Text.UTF8Encoding($false)))
  Write-Line ''
  Write-Line ('budget gate: recorded baseline -> ' + $Baseline)
  Write-Line ('  products: {0}   boot table: {1}/{2} (headroom {3})   reason: {4}' -f $products.Count, $bootNow.Occupied, $bootNow.Limit, $bootNow.Headroom, $Reason)
  exit 0
}

# ---- compare mode ----
$diffs = New-Object System.Collections.ArrayList
$warns = New-Object System.Collections.ArrayList
if (-not (Test-Path -LiteralPath $Baseline -PathType Leaf)) {
  [void]$fatal.Add('baseline file not found: ' + $Baseline)
} else {
  $base = $null
  try { $base = [IO.File]::ReadAllText($Baseline, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
  if ($null -eq $base) {
    [void]$fatal.Add('baseline file unreadable/not JSON: ' + $Baseline)
  } else {
    if ([int]$base.ImportCaps.MaxImports -ne $maxImports) {
      [void]$diffs.Add(('ImportCaps.MaxImports {0} -> {1} (the cap moved; re-record)' -f [int]$base.ImportCaps.MaxImports, $maxImports))
    }
    if ([int]$base.ImportCaps.MaxGroups -ne $maxGroups) {
      [void]$diffs.Add(('ImportCaps.MaxGroups {0} -> {1} (the cap moved; re-record)' -f [int]$base.ImportCaps.MaxGroups, $maxGroups))
    }
    $baseProd = @{}
    foreach ($p in @($base.Products)) { if ($null -ne $p) { $baseProd[[string]$p.Artifact] = $p } }
    $curProd = @{}
    foreach ($p in $products) { $curProd[$p.Artifact] = $p }
    foreach ($k in @($baseProd.Keys | Sort-Object)) {
      $b = $baseProd[$k]
      if (-not $curProd.ContainsKey($k)) {
        [void]$warns.Add(('gone: {0} was recorded with {1} imports / {2} modules but is not present now (gitignored build product)' -f $k, [int]$b.Imports, [int]$b.Groups))
        continue
      }
      $c = $curProd[$k]
      if ([int]$b.Imports -ne $c.Imports) {
        [void]$diffs.Add(('{0}: imports {1} -> {2}' -f $k, [int]$b.Imports, $c.Imports))
      }
      if ([int]$b.Groups -ne $c.Groups) {
        [void]$diffs.Add(('{0}: modules {1} -> {2}' -f $k, [int]$b.Groups, $c.Groups))
      }
      if ([string]$b.Modules -ne $c.Modules) {
        [void]$warns.Add(('{0}: module NAME list changed ({1} -> {2}); the capped number is the count' -f $k, [string]$b.Modules, $c.Modules))
      }
    }
    foreach ($k in @($curProd.Keys | Sort-Object)) {
      if (-not $baseProd.ContainsKey($k)) {
        [void]$warns.Add(('new: {0} ({1} imports / {2} modules) is not in the baseline (gitignored build product)' -f $k, $curProd[$k].Imports, $curProd[$k].Groups))
      }
    }
    if ($null -eq $base.BootTable) {
      [void]$diffs.Add('baseline has no BootTable record (re-record)')
    } elseif ($bootNow -eq $null) {
      [void]$diffs.Add('boot table could not be measured (re-record after fixing the meter)')
    } else {
      $bb = $base.BootTable
      if ([int]$bb.Occupied -ne $bootNow.Occupied) { [void]$diffs.Add(('boot table occupied {0} -> {1}' -f [int]$bb.Occupied, $bootNow.Occupied)) }
      if ([int]$bb.Limit -ne $bootNow.Limit) { [void]$diffs.Add(('boot table limit {0} -> {1}' -f [int]$bb.Limit, $bootNow.Limit)) }
      if ([int]$bb.Headroom -ne $bootNow.Headroom) { [void]$diffs.Add(('boot table headroom {0} -> {1}' -f [int]$bb.Headroom, $bootNow.Headroom)) }
      if ([int]$bb.Api -ne $bootNow.Api) { [void]$diffs.Add(('boot table api entries {0} -> {1}' -f [int]$bb.Api, $bootNow.Api)) }
      if ([int]$bb.Func -ne $bootNow.Func) { [void]$diffs.Add(('boot table function definitions {0} -> {1}' -f [int]$bb.Func, $bootNow.Func)) }
      if ([string]$bb.App -ne $bootNow.App) { [void]$diffs.Add(('boot table target app {0} -> {1}' -f [string]$bb.App, $bootNow.App)) }
    }
    Write-Line ''
    Write-Line ('baseline      : {0}' -f $Baseline)
    Write-Line ('  recorded    : {0}   reason: {1}' -f [string]$base.Recorded, [string]$base.Reason)
  }
}

$red = ($fatal.Count -gt 0 -or $diffs.Count -gt 0)

if ($Json) {
  [pscustomobject]@{
    Red = $red
    Fatal = @($fatal)
    Diffs = @($diffs)
    Warns = @($warns)
    Products = @($products)
    Foreign = @($foreign | ForEach-Object { [string]$_.Artifact })
    BootTable = $bootNow
    Baseline = $Baseline
    BaselinePresent = (Test-Path -LiteralPath $Baseline -PathType Leaf)
    Exits = [pscustomobject]@{ ImportBudget = $imp.Exit; BootHeadroom = $boot.Exit }
  } | ConvertTo-Json -Depth 8
  if ($red) { exit 1 }
  exit 0
}

Write-Line ''
Write-Line '===== budget gate (regression vs recorded baseline) ====='
Write-Line ''
Write-Line 'current status (printed loudly, never a red by itself):'
foreach ($s in $status) { Write-Line $s }
Write-Line ''
Write-Line ('meter exits   : import-budget={0} boot-headroom={1}' -f $imp.Exit, $boot.Exit)
if ($base -ne $null) {
  Write-Line ('baseline      : {0}  (recorded {1}: {2})' -f $Baseline, [string]$base.Recorded, [string]$base.Reason)
} else {
  Write-Line ('baseline      : {0}  (MISSING or unreadable)' -f $Baseline)
}
Write-Line ''
if ($warns.Count -gt 0) {
  foreach ($w in $warns) { Write-Line ('WARN ' + $w) }
  Write-Line ''
}
if ($fatal.Count -gt 0) {
  foreach ($f in $fatal) { Write-Line ('RED  ' + $f) }
}
if ($diffs.Count -gt 0) {
  Write-Line 'RED  the budget account CHANGED vs the recorded baseline (both directions are red on purpose):'
  foreach ($d in $diffs) { Write-Line ('       ' + $d) }
}
if ($red) {
  Write-Line ''
  Write-Line 'RED budget gate. If the change is intentional, re-record it and say why in the commit:'
  Write-Line ('  powershell -NoProfile -ExecutionPolicy Bypass -File tools\budget-gate.ps1 -UpdateBaseline -Reason "<why>"')
  Write-Line ('  baseline file: ' + $Baseline)
  Write-Line ('budget gate: RED; boot table occupied {0} / {1}' -f $(if ($bootNow -eq $null) { '?' } else { $bootNow.Occupied }), $(if ($bootNow -eq $null) { '?' } else { $bootNow.Limit }))
  exit 1
}
Write-Line ('OK   budget gate: {0} products match the baseline, boot table {1}/{2} (headroom {3}).' -f $products.Count, $bootNow.Occupied, $bootNow.Limit, $bootNow.Headroom)
Write-Line ('budget gate: GREEN; {0} products match the baseline; boot table {1} / {2}' -f $products.Count, $bootNow.Occupied, $bootNow.Limit)
exit 0
