# boot[headroom].ps1 -- STATIC budget meter for boot's ONE function table.
#   (The file NAME is non-ASCII -- "boot" + the Chinese word for headroom -- because the work
#    order fixes that name; the CONTENT is pure ASCII on purpose, so the ASCII-contract gate
#    test\verify-all.ps1 can call it. Below it is spelled tools\boot[headroom].ps1.)
#
# Why this exists (2026-10-13, usability roadmap P1 item 3):
#   boot keeps exactly ONE table holding BOTH `api` declarations AND top-level function
#   definitions. The heaviest chain boot must compile -- apps\m2_float\main.fl -- sits very
#   close to the cap, and the symptom of overflow is a bare `parse err=-85` with no hint
#   about which knob to turn. Until now the only way to see the account was a one-off
#   experiment under tmp\ (tmp\m4o\measure-headroom.ps1) that needed a hand-built worktree.
#   This script turns "count the table before adding an API / a library function" from
#   discipline-remembered-by-humans into a command any gate can call.
#
# WHAT COUNTS AS ONE TABLE ENTRY -- the counting rule is taken from boot's OWN parser, not invented.
#   * limit constant (never hard-coded here): boot\lib_parse.fl:1399
#       `if (p->nfuncs >= 512) return -85;`   (api declaration path)
#     and the same guard in the function-definition path: boot\lib_parse.fl:1526
#       `if (p->nfuncs >= 512) return -85;   // function table cap 512`
#     Both sites are read at run time; if they ever disagree the meter refuses to answer
#     (exit 2) instead of picking one.
#   * one `api` declaration = exactly 1 entry: boot\lib_parse.fl:1311-1408 (parse_apis).
#     The loop `while (tok_ident_eq(p, "api"))` parses ONE `api <dll> <ret> <name>(...);`
#     per iteration and appends ONE entry (fpos/flen/fna/fpty + nfuncs+1 at :1400-1405).
#     There is no multi-name form: after `;` (:1376) control returns to the loop head, so
#     `api a int f(); int g();` would give g() to the function-definition path, not here.
#   * one TOP-LEVEL function DEFINITION = exactly 1 entry: boot\lib_parse.fl:1470-1554
#     (collect_funcs); the append is at :1527-1533, guarded by :1526.
#     `is_func_start_at` (:1448-1468) is the exact shape test, and parse_program
#     (:3573-3592) uses that same test to dispatch function-vs-global-declaration, so a
#     top-level `int g = 1;` is a global variable and never enters this table.
#   * a bodyless declaration is NOT a prototype: collect_funcs requires `{` right after the
#     parameter list (:1534 `if (!(i < n && ks[i] == 3 && vs[i] == '{')) return -86;`).
#     FLINT has no forward declarations inside this table, so there is no "half entry".
#   * `struct X { ... }` goes to a DIFFERENT table (st_add, boot\lib_parse.fl:1193-1207);
#     parse_program peels structs off at :3562-3564 / :3576-3578. Zero entries here.
#     `struct X *f(...)` is a function definition -- is_func_start_at :1459-1466.
#   * `ns::name` is ONE identifier token: boot\lib_token.fl:143-148 glues `a::b::c` into a
#     single ident ("::" must be followed by an ident-first char).
#   * comments never count: `//` and `/* */` are dropped by the tokenizer
#     (boot\lib_token.fl:119-139), and this script drops them the same way before scanning,
#     so a commented-out function definition is not billed.
#   * a leading UTF-8 BOM is skipped (boot\lib_token.fl:57-59); mirrored here.
#
# SOURCE BOOT ITSELF INJECTS BEFORE PARSING -- these entries are part of the account
# (boot\b1_emit.fl:3071-3109). Missing them is exactly how a "headroom 5" could be reported
# for an app that in fact has headroom 0:
#   * if the merged source CALLS print( -> boot PREPENDS <exe dir>\lib_print.fl
#     (b1_emit.fl:3071-3091; reader at :3080, detection at :3073 via src_has_print
#     :2419-2451, which needs the identifier `print` followed by optional SPACE/TAB and `(`).
#     boot\lib_print.fl bills 5 entries: 2 api (:5,:6) + 3 function definitions (:8,:16,:23).
#   * if the merged source mentions new / own / share (src_has_ident :2455-2490, word
#     boundaries, comments and strings skipped) AND does not already mention
#     VirtualAlloc / VirtualFree, boot APPENDS the matching builtin api declaration
#     (b1_emit.fl:3099-3109) -> +1 entry each.
#   * the exe-dir read is not a search-path lookup: it is literally <exe dir>\lib_print.fl.
#
# INCLUDE RESOLUTION (mirrors boot's textual splicer, boot\b1_emit.fl:2681-2754):
#   * only a line whose first non-space/tab characters are `include` counts (:2689-2693);
#     the splicer is TEXTUAL -- it does not know about comments, and neither does this meter.
#   * candidate order: including file's own directory, then <exe dir>lib\, then
#     <exe dir>..\lib\ (:2710-2723). This meter defaults to boot\b1_emit.exe, so the
#     fallback library is <root>\lib\.
#   * every file is expanded at most once, keyed by canonical absolute path (:2724-2744);
#     re-including a file that is still being expanded is a cycle error (:2731).
#   * nesting depth <= 4 (:2733), spliced-source cap 524288 bytes (:3066), and the top file
#     is pre-registered so including itself is a cycle (:3063-3065).
#
# RED / GREEN line (deliberate, argued in the report that introduced this script):
#   * exit 1 (RED) ONLY when headroom < 0. That is the only state in which the app cannot
#     be compiled by boot at all; it is a genuine regression, not a tight budget.
#   * headroom <= 8 exits 0 with a loud WARN. The measured headroom on 2026-10-13 is 0 --
#     i.e. the very next library function overflows -- but a tight budget is the status quo,
#     not a regression. Reporting green-but-loud keeps the gate honest: painting the gate red
#     for the status quo is how a gate gets "temporarily" loosened. The WARN line is
#     greppable: `WARN BOOT-TABLE-TIGHT`.
#   * exit 2 = the meter itself could not produce a number (missing source, limit constant
#     not found/ambiguous, include cycle, spliced source over cap). Never silently green.
#
# Cross-check: tmp\m19\dynamic-headroom.ps1 measures the same number the hard way (append N
# stub functions in a throwaway worktree, bisect the largest N boot still compiles).
# 2026-10-13: static headroom 0 and dynamic max N = 0 agree.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\boot[headroom].ps1
#   powershell ... -File tools\boot[headroom].ps1 -Json
#   powershell ... -File tools\boot[headroom].ps1 -App apps\m2_float\main.fl
#   powershell ... -File tools\boot[headroom].ps1 -LimitOverride 494      (both-direction proof)
#
# Exit codes: 0 = counted (headroom > 8; <= 8 also 0 but WARN) | 1 = headroom < 0 | 2 = meter failure.
# ASCII only on purpose: test\verify-all.ps1 is an ASCII contract and calls this file.

param(
  [string]$Root = '',
  [string]$App = 'apps\m2_float\main.fl',
  [string]$BootExe = 'boot\b1_emit.exe',
  [int]$LimitOverride = 0,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Root -eq '') { $Root = Split-Path $PSScriptRoot -Parent }
$rootFull = [IO.Path]::GetFullPath($Root)

function Get-Latin1([string]$p) {
  # Byte-faithful read: .fl files are ASCII/GBK byte contracts, and boot reads raw bytes.
  # Latin-1 maps byte N to char N, so no transcoding can merge or drop a byte.
  $b = [IO.File]::ReadAllBytes($p)
  return [Text.Encoding]::GetEncoding('iso-8859-1').GetString($b)
}

# ---------------------------------------------------------------- limit (truth source)
$limitFile = Join-Path $rootFull 'boot\lib_parse.fl'
if (-not (Test-Path -LiteralPath $limitFile -PathType Leaf)) {
  Write-Host "bootbudget: FAIL cannot read limit truth source: $limitFile"
  exit 2
}
$limitText = Get-Latin1 $limitFile
$limitHits = @()
foreach ($m in [regex]::Matches($limitText, 'nfuncs\s*>=\s*(\d+)')) {
  $limitHits += [pscustomobject]@{ Value = [int]$m.Groups[1].Value; Line = (1 + ($limitText.Substring(0, $m.Index) -split "`n").Count - 1) }
}
if ($limitHits.Count -eq 0) {
  Write-Host 'bootbudget: FAIL no `nfuncs >= <n>` capacity guard found in boot\lib_parse.fl'
  exit 2
}
$limitValues = @($limitHits | ForEach-Object { $_.Value } | Sort-Object -Unique)
if ($limitValues.Count -ne 1) {
  Write-Host ('bootbudget: FAIL ambiguous capacity constants in boot\lib_parse.fl: ' + (($limitHits | ForEach-Object { "line $($_.Line)=$($_.Value)" }) -join ' '))
  exit 2
}
$limit = [int]$limitValues[0]
$limitSource = 'boot\lib_parse.fl:' + (($limitHits | ForEach-Object { $_.Line }) -join ',')
$limitOverridden = $false
if ($LimitOverride -gt 0) {
  $limit = $LimitOverride
  $limitOverridden = $true
}

# ---------------------------------------------------------------- include closure (textual splice)
$bootFull = Join-Path $rootFull $BootExe
$exeDir = Split-Path $bootFull -Parent
$mainFull = [IO.Path]::GetFullPath((Join-Path $rootFull $App))

$script:sb = New-Object System.Text.StringBuilder
$script:seg = New-Object System.Collections.ArrayList   # file attribution segments
$script:state = @{}                                     # canon path -> 1 expanding / 0 expanded
$script:order = New-Object System.Collections.ArrayList  # closure file list, first-seen order

function Add-Seg([string]$file, [string]$s) {
  if ($s.Length -eq 0) { return }
  $st = $script:sb.Length
  [void]$script:sb.Append($s)
  $n = $script:seg.Count
  if ($n -gt 0 -and $script:seg[$n - 1].File -ceq $file -and $script:seg[$n - 1].End -eq $st) {
    $script:seg[$n - 1].End = $script:sb.Length
  } else {
    [void]$script:seg.Add([pscustomobject]@{ File = $file; Start = $st; End = $script:sb.Length })
  }
}

function Splice-File([string]$name, [int]$depth) {
  if (-not (Test-Path -LiteralPath $name -PathType Leaf)) { return -1 }
  $text = Get-Latin1 $name
  [void]$script:order.Add([pscustomobject]@{ Path = $name; Bytes = $text.Length; Injected = $false })
  $len = $text.Length
  $i = 0
  while ($i -lt $len) {
    $eol = $text.IndexOf([char]10, $i)
    if ($eol -lt 0) { $eol = $len }
    $line = $text.Substring($i, $eol - $i)
    $m = [regex]::Match($line, '^[ \t]*include(?![A-Za-z0-9_])')
    if ($m.Success) {
      $r = [regex]::Match($line, '^[ \t]*include(?![A-Za-z0-9_])[ \t]*"([^"]*)"')
      if (-not $r.Success) { $script:err = "include syntax error (boot err=-4) in $name"; return -4 }
      $incname = $r.Groups[1].Value
      if ($incname.Length -gt 255) { $script:err = "include name longer than 255 bytes (boot err=-4) in $name"; return -4 }
      $dir = Split-Path $name -Parent
      $full = Join-Path $dir $incname
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $alt = Join-Path $exeDir ('lib\' + $incname)
        if (Test-Path -LiteralPath $alt -PathType Leaf) { $full = $alt }
        else {
          $alt2 = Join-Path $exeDir ('..\lib\' + $incname)
          if (Test-Path -LiteralPath $alt2 -PathType Leaf) { $full = $alt2 }
        }
      }
      $canon = ([IO.Path]::GetFullPath($full)).ToLowerInvariant()
      if ($script:state.ContainsKey($canon)) {
        if ($script:state[$canon] -eq 1) { $script:err = "include cycle (boot err=-8): $full"; return -8 }
        # already fully expanded: boot splices nothing
      } else {
        if ($depth -ge 4) { $script:err = "include depth over 4 (boot err=-6): $full"; return -6 }
        $script:state[$canon] = 1
        $got = Splice-File $full ($depth + 1)
        $script:state[$canon] = 0
        if ($got -lt 0) { return $got }
        Add-Seg $name ([string][char]10)
      }
    } else {
      if ($eol -lt $len) { Add-Seg $name ($text.Substring($i, $eol - $i + 1)) }
      else { Add-Seg $name ($text.Substring($i, $eol - $i)) }
    }
    $i = $eol + 1
  }
  if ($script:sb.Length -ge 524288) { $script:err = 'spliced source over 524288 bytes (boot err=-5)'; return -5 }
  return 0
}

$script:err = ''
if (-not (Test-Path -LiteralPath $mainFull -PathType Leaf)) {
  Write-Host "bootbudget: FAIL main file not found: $mainFull"
  exit 2
}
$script:state[([IO.Path]::GetFullPath($mainFull)).ToLowerInvariant()] = 1
$rc = Splice-File $mainFull 0
if ($rc -lt 0) {
  Write-Host ("bootbudget: FAIL include closure failed: {0}" -f $script:err)
  exit 2
}
$spliced = $script:sb.ToString()
$segLen = $spliced.Length

# ---------------------------------------------------------------- boot's own injections (b1_emit.fl:3071-3109)
# The mask is LENGTH-PRESERVING (each comment/string becomes as many spaces as it had bytes):
# token offsets must stay comparable with the buffer offsets used for per-file attribution.
$reSkip = '(?s)//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*'''
$maskEval = { param($m) ' ' * $m.Length }
$maskedSpliced = [regex]::Replace($spliced, $reSkip, $maskEval)
$injPrint = [regex]::IsMatch($maskedSpliced, '(?<![A-Za-z0-9_])print[ \t]*\(')
$printFile = Join-Path $exeDir 'lib_print.fl'
$pre = ''
$injNotes = New-Object System.Collections.ArrayList
if ($injPrint) {
  if (-not (Test-Path -LiteralPath $printFile -PathType Leaf)) {
    Write-Host ("bootbudget: FAIL source calls print( but boot's injected library is missing: {0} (boot returns 3 here)" -f $printFile)
    exit 2
  }
  $pre = (Get-Latin1 $printFile) + [string][char]10
  [void]$injNotes.Add('print( found -> boot prepends ' + $printFile + ' (b1_emit.fl:3073-3091)')
} else {
  [void]$injNotes.Add('no print( call -> no print-library prepend')
}

$combined0 = $pre + $spliced
$masked0 = [regex]::Replace($combined0, $reSkip, $maskEval)
$injNew = [regex]::IsMatch($masked0, '(?<![A-Za-z0-9_])new(?![A-Za-z0-9_])')
$injOwn = [regex]::IsMatch($masked0, '(?<![A-Za-z0-9_])own(?![A-Za-z0-9_])')
$injShare = [regex]::IsMatch($masked0, '(?<![A-Za-z0-9_])share(?![A-Za-z0-9_])')
$hasAlloc = [regex]::IsMatch($masked0, '(?<![A-Za-z0-9_])VirtualAlloc(?![A-Za-z0-9_])')
$hasFree = [regex]::IsMatch($masked0, '(?<![A-Za-z0-9_])VirtualFree(?![A-Za-z0-9_])')
$suffix = ''
if ($injNew -or $injOwn -or $injShare) {
  if (($injNew -or $injOwn) -and -not $hasAlloc) {
    $suffix += [string][char]10 + 'api kernel32 ptr VirtualAlloc(int, int, int, int);' + [string][char]10
    [void]$injNotes.Add('new/own found and VirtualAlloc absent -> boot appends api kernel32 ptr VirtualAlloc(...) (b1_emit.fl:3103-3105)')
  }
  if (($injOwn -or $injShare) -and -not $hasFree) {
    $suffix += [string][char]10 + 'api kernel32 int VirtualFree(int, int, int);' + [string][char]10
    [void]$injNotes.Add('own/share found and VirtualFree absent -> boot appends api kernel32 int VirtualFree(...) (b1_emit.fl:3106-3108)')
  }
}

$buf = $pre + $spliced + $suffix
$preLen = $pre.Length
$sufStart = $preLen + $segLen
if ($buf.Length -ge 524288) {
  Write-Host 'bootbudget: FAIL injected source over 524288 bytes (boot would report source too large / err=-5)'
  exit 2
}

# ---------------------------------------------------------------- tokenize (mirrors boot\lib_token.fl)
$masked = [regex]::Replace($buf, $reSkip, $maskEval)
$reTok = '[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*|0[xX][0-9A-Fa-f]+|\d+|[^\sA-Za-z0-9_]'
$ms = [regex]::Matches($masked, $reTok)
$script:nt = $ms.Count
$script:kind = New-Object 'int[]' $script:nt
$script:txt = New-Object 'string[]' $script:nt
$script:off = New-Object 'int[]' $script:nt
for ($k = 0; $k -lt $script:nt; $k++) {
  $mm = $ms[$k]
  $s = $mm.Value
  $script:off[$k] = $mm.Index
  $c = $s[0]
  if (($c -ge 'a' -and $c -le 'z') -or ($c -ge 'A' -and $c -le 'Z') -or $c -eq '_') { $script:kind[$k] = 1 }
  elseif ($c -ge '0' -and $c -le '9') { $script:kind[$k] = 2 }
  else { $script:kind[$k] = 3 }
  $script:txt[$k] = $s
}

function Sym([int]$i, [string]$w) { return ($script:kind[$i] -eq 3 -and $script:txt[$i] -ceq $w) }
function Id([int]$i, [string]$w) { return ($script:kind[$i] -eq 1 -and $script:txt[$i] -ceq $w) }

# is_func_start_at -- boot\lib_parse.fl:1448-1468, token for token
function Is-FuncStart([int]$i) {
  if ($i -ge $script:nt -or $script:kind[$i] -ne 1) { return $false }
  $t = $script:txt[$i]
  if ($t -ceq 'int' -or $t -ceq 'char' -or $t -ceq 'void') {
    $j = $i + 1
    if ($j -lt $script:nt -and (Sym $j '*')) { $j = $j + 1 }
    if ($j + 1 -lt $script:nt -and $script:kind[$j] -eq 1 -and (Sym ($j + 1) '(')) { return $true }
    return $false
  }
  if ($t -ceq 'struct') {
    $j = $i + 1
    if ($j -ge $script:nt -or $script:kind[$j] -ne 1) { return $false }
    $j = $j + 1
    if ($j -ge $script:nt -or -not (Sym $j '*')) { return $false }
    $j = $j + 1
    if ($j + 1 -lt $script:nt -and $script:kind[$j] -eq 1 -and (Sym ($j + 1) '(')) { return $true }
  }
  return $false
}

function Skip-Braces([int]$i) {   # $i points at '{' -> index after the matching '}'
  $d = 0
  while ($i -lt $script:nt) {
    if ($script:kind[$i] -eq 3) {
      $c = $script:txt[$i]
      if ($c -ceq '{') { $d = $d + 1 }
      elseif ($c -ceq '}') { $d = $d - 1; if ($d -eq 0) { return $i + 1 } }
    }
    $i = $i + 1
  }
  return -1
}

function Skip-Paren([int]$i) {    # $i points at '(' -> index after the matching ')'
  $d = 0
  while ($i -lt $script:nt) {
    if ($script:kind[$i] -eq 3) {
      $c = $script:txt[$i]
      if ($c -ceq '(') { $d = $d + 1 }
      elseif ($c -ceq ')') { $d = $d - 1; if ($d -eq 0) { return $i + 1 } }
    }
    $i = $i + 1
  }
  return -1
}

function Skip-To([int]$i, [string]$sym) {   # index after the first $sym at or after $i
  while ($i -lt $script:nt) {
    if (Sym $i $sym) { return $i + 1 }
    $i = $i + 1
  }
  return -1
}

# ---------------------------------------------------------------- top-level scan (mirrors parse_program)
$api = 0
$func = 0
$entries = New-Object System.Collections.ArrayList
$globals = 0
$structs = 0
$i = 0
$guard = 0
$fail = ''
while ($i -lt $script:nt) {
  $guard = $guard + 1
  if ($guard -gt 4096) { $fail = 'top-level item guard exceeded (boot err=-66)'; break }
  if ((Id $i 'struct') -and -not (Is-FuncStart $i)) {
    $structs = $structs + 1
    $b = Skip-To $i '{'
    if ($b -lt 0) { $fail = 'struct without body'; break }
    $i = Skip-Braces ($b - 1)
    if ($i -lt 0) { $fail = 'unterminated struct body'; break }
  } elseif (Id $i 'api') {
    $api = $api + 1
    [void]$entries.Add([pscustomobject]@{ Kind = 'api'; Off = $script:off[$i] })
    $i = Skip-To $i ';'
    if ($i -lt 0) { $fail = 'api declaration without ;'; break }
  } elseif (Is-FuncStart $i) {
    $func = $func + 1
    [void]$entries.Add([pscustomobject]@{ Kind = 'func'; Off = $script:off[$i] })
    $j = $i + 1
    $p = -1
    while ($j -lt $script:nt) { if (Sym $j '(') { $p = $j; break }; $j = $j + 1 }
    if ($p -lt 0) { $fail = 'function without ( '; break }
    $a = Skip-Paren $p
    if ($a -lt 0) { $fail = 'unterminated parameter list'; break }
    if (-not (Sym $a '{')) { $fail = 'function without body (boot err=-86)'; break }
    $i = Skip-Braces $a
    if ($i -lt 0) { $fail = 'unterminated function body'; break }
  } else {
    $globals = $globals + 1
    $i = Skip-To $i ';'
    if ($i -lt 0) { $fail = 'unterminated top-level declaration'; break }
  }
}

if ($fail -ne '') {
  Write-Host ("bootbudget: FAIL " + $fail + " (in " + $App + ")")
  exit 2
}

# ---------------------------------------------------------------- per-file attribution
$injLabel = '(injected by boot: builtin api)'
$perFile = @{}
if ($injPrint) { $perFile[$printFile] = 0 }
foreach ($f in $script:order) { if (-not $perFile.ContainsKey($f.Path)) { $perFile[$f.Path] = 0 } }
$perFile[$injLabel] = 0
foreach ($e in $entries) {
  $owner = ''
  if ($e.Off -lt $preLen) { $owner = $printFile }
  elseif ($e.Off -ge $sufStart) { $owner = $injLabel }
  else {
    $ro = $e.Off - $preLen
    foreach ($sg in $script:seg) {
      if ($ro -ge $sg.Start -and $ro -lt $sg.End) { $owner = $sg.File; break }
    }
  }
  if ($owner -eq '') { $owner = '(unattributed)' }
  if ($perFile.ContainsKey($owner)) { $perFile[$owner] = $perFile[$owner] + 1 }
  else { $perFile[$owner] = 1 }
}

$occupied = $api + $func
$headroom = $limit - $occupied

$rel = @{}
foreach ($k in $perFile.Keys) {
  $r = $k
  if ($k.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $r = $k.Substring($rootFull.Length).TrimStart('\') }
  $rel[$k] = $r
}

$orderList = New-Object System.Collections.ArrayList
if ($injPrint) { [void]$orderList.Add([pscustomobject]@{ Path = $printFile; Bytes = $pre.Length; Injected = $true }) }
foreach ($f in $script:order) { [void]$orderList.Add($f) }
if ($suffix.Length -gt 0) { [void]$orderList.Add([pscustomobject]@{ Path = $injLabel; Bytes = $suffix.Length; Injected = $true }) }

if ($Json) {
  $fileRows = @()
  foreach ($f in $orderList) {
    $fileRows += [pscustomobject]@{
      File = $rel[$f.Path]
      Bytes = $f.Bytes
      Entries = [int]$perFile[$f.Path]
      Injected = [bool]$f.Injected
    }
  }
  [pscustomobject]@{
    App = $App
    BootExe = $BootExe
    Limit = $limit
    LimitSource = $limitSource
    LimitOverridden = $limitOverridden
    Occupied = $occupied
    Api = $api
    Func = $func
    Structs = $structs
    Globals = $globals
    Headroom = $headroom
    SplicedBytes = $segLen
    ParsedBytes = $buf.Length
    ClosureFiles = $script:order.Count
    Injections = @($injNotes)
    Files = $fileRows
  } | ConvertTo-Json -Depth 6
} else {
  Write-Host ''
  Write-Host '===== boot function-table budget (static; rule read from boot\lib_parse.fl) ====='
  Write-Host ("target        : {0}   (via {1})" -f $App, $BootExe)
  Write-Host ("limit source  : {0} = {1}{2}" -f $limitSource, $limit, $(if ($limitOverridden) { "  [OVERRIDDEN to $limit]" } else { '' }))
  Write-Host ("occupied      : {0}  = api {1} + top-level function definitions {2}" -f $occupied, $api, $func)
  Write-Host ("headroom      : {0}" -f $headroom)
  Write-Host ("also counted  : struct definitions {0} (different table, not billed) | top-level global decls {1} (not billed)" -f $structs, $globals)
  Write-Host ("source        : spliced {0} B + injected {1} B = {2} B (cap 524288), {3} closure files" -f $segLen, ($buf.Length - $segLen), $buf.Length, $script:order.Count)
  Write-Host 'boot injections (b1_emit.fl:3071-3109):'
  foreach ($n in $injNotes) { Write-Host ("  - {0}" -f $n) }
  Write-Host ''
  Write-Host 'per-file contribution (boot injects the first/last rows):'
  foreach ($f in $orderList) {
    $r = $rel[$f.Path]
    $tag = ''
    if ($f.Injected) { $tag = '  [injected by boot]' }
    Write-Host ("  {0,5} entries  {1,8} B  {2}{3}" -f ([int]$perFile[$f.Path]), $f.Bytes, $r, $tag)
  }
  Write-Host ''
  if ($headroom -lt 0) {
    Write-Host ("RED BOOT-TABLE-OVERFLOW: occupied {0} > limit {1} -- boot would report parse err=-85 on this app." -f $occupied, $limit)
  } elseif ($headroom -le 8) {
    Write-Host ("WARN BOOT-TABLE-TIGHT: headroom {0} <= 8 -- the next library functions will overflow boot's table." -f $headroom)
  } else {
    Write-Host ("OK boot table: headroom {0} of {1}." -f $headroom, $limit)
  }
  Write-Host ("boot table occupied {0} / {1}" -f $occupied, $limit)
}

if ($headroom -lt 0) { exit 1 }
exit 0
