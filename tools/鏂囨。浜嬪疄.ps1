<#
文档事实.ps1 -- FLINT 「单点数字台账」取数器（每个会漂的数字只有这一条命令能取到）

为什么有它（2026-10-15）：
  同一个数字（版本号 / 上限 / 产物字节 / 门里过了多少条）散在 65 份文档里，抄写者各抄一份，
  连着读错四次。根因不是"某人抄错"，是"没有真值源"。
  本脚本把每个会漂的数字变成一条命令：`文档事实.ps1 -Key <键>` 只打印值，值连同**真值源**一起给出。

冻结接口（改名前先看这里；门按这个契约调用）：
  -Key <键>      只打印值：单行、无装饰、无额外输出。成功 exit 0；未知键 exit 2 + stderr 说明。
  -List          表格：key | value | source
  -Json          { "<键>": { value, source, command, asOf } }
  -Ledger        重写 docs\数字台账.md（列：键 ｜ 现值 ｜ 真值源 ｜ 取数命令 ｜ 谁引用我 ｜ 最后复核）
                 生成物文件头写明"机器生成，不许手改"+ 生成命令。
  -Slow          才允许跑重活。默认不跑：慢键（regress / flgui-checks / boot-verify / examples-passed）
                 从**最新门日志**里取摘要；
                 取不到一律 exit 2 并在 stderr 写明 NOT_COLLECTED，**永远不许静默给一个绿数**。

铁律（本脚本自己遵守）：
  1. 每个键**现场算**：grep 守卫行 / 数文件 / 跑只读仪器。脚本里不写死任何数字，上限也必须 grep 出来
     并带 `文件:行`。上限两处写法不一致时判**歧义**，exit 2，不挑一个。
  2. 读中文文本用 [IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)；`.fl` 是**字节契约**（boot 按原始
     字节读，且有 GBK 混排），故按 iso-8859-1 逐字节读 —— 与 tools\boot余量.ps1 同一条纪律。
     行数口径 = **数 \n**（0x0A），禁止 Measure-Object -Line（它数的是非空行）。
  3. **stdout/stderr 一律纯 ASCII**（门会调它）。真值源里有中文文件名（test\边界探针.ps1 等），
     故非 ASCII 字符一律转义：
       * `-List` / `-Key` / stderr：转义成**字面文本** `\uXXXX`（下游怎么打印都还是 ASCII）。
       * `-Json`：转义成**真 JSON 转义**（单反斜杠 `\uXXXX`，且反斜杠本身也按 JSON 规矩写成 `\\`）
         ⇒ 磁盘字节仍是纯 ASCII，但 `ConvertFrom-Json` 解出来是**真中文**路径。
     `-Ledger` 写的是给人看的 .md，保留真实中文。
  4. 不许跑 test\verify-all.ps1、boot\verify.ps1、test\flgui-verify.ps1（重）—— 这些只从日志取数。
  5. 查不到就 exit 2 并说清卡点，不许猜、不许给默认值。

自证：
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\文档事实.ps1 -List
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\文档事实.ps1 -Json
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\文档事实.ps1 -Key version
#>
param(
  [string]$Key = '',
  [switch]$List,
  [switch]$Json,
  [switch]$Ledger,
  [switch]$Slow,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent $PSScriptRoot }
if ($Root -eq '' -or $null -eq $Root) { $Root = (Get-Location).Path }
$rootFull = [IO.Path]::GetFullPath($Root)

$script:LedgerRel = 'docs\数字台账.md'
$script:ProbeRel = 'test\边界探针.ps1'
$script:Facts = @{}
$script:ImpJson = $null
$script:BootJson = $null
$script:BndRun = $null
$script:SpecSec = $null
$script:PixJson = $null

# ------------------------------------------------------------------ 小工具
function Get-TextUtf8([string]$p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('missing file: ' + $p) }
  return [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
}
function Get-TextLatin1([string]$p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('missing file: ' + $p) }
  $bytes = [IO.File]::ReadAllBytes($p)
  return [Text.Encoding]::GetEncoding('iso-8859-1').GetString($bytes)
}
function Count-Lf([string]$p) {
  $bytes = [IO.File]::ReadAllBytes($p)
  $n = 0
  foreach ($b in $bytes) { if ($b -eq 10) { $n = $n + 1 } }
  return $n
}
function Get-LineNo([string]$text, [int]$index) {
  return (($text.Substring(0, $index) -split "`n").Count)
}
function Get-MTime([string]$p) {
  return (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
}
function Get-NowStamp() {
  return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}
function Get-MaxMTimeFrom([object[]]$items) {
  $best = $null
  foreach ($it in $items) {
    $t = $null
    if ($it -is [string]) {
      if (-not (Test-Path -LiteralPath $it -PathType Leaf)) { continue }
      $t = (Get-Item -LiteralPath $it).LastWriteTime
    } else {
      $t = $it.LastWriteTime
    }
    if ($null -eq $best -or $t -gt $best) { $best = $t }
  }
  if ($null -eq $best) { return '' }
  return $best.ToString('yyyy-MM-dd HH:mm:ss')
}
function Get-Rel([string]$full) {
  $fs = [IO.Path]::GetFullPath($full)
  if ($fs.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    return $fs.Substring($rootFull.Length).TrimStart([char]92)
  }
  return $fs
}
function New-Fact([string]$k, [string]$v, [string]$src, [string]$cmd, [string]$asOf) {
  return [pscustomobject]@{ key = $k; value = $v; source = $src; command = $cmd; asOf = $asOf }
}
function ConvertTo-AsciiSafe([string]$s) {
  if ($null -eq $s) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $code = [int]$ch
    if ($code -lt 32 -or $code -gt 126) { [void]$sb.Append('\u' + $code.ToString('x4')) }
    else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}
# JSON 用的字符串转义：真 JSON 转义（反斜杠按 JSON 规矩写成 \\，非 ASCII 写成单反斜杠 \uXXXX），
# 于是磁盘字节是纯 ASCII，而 ConvertFrom-Json 解出来是真中文。
function ConvertTo-JsonText([string]$s) {
  if ($null -eq $s) { return '""' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    $code = [int]$ch
    if ($ch -eq [char]34) { [void]$sb.Append('\"') }
    elseif ($ch -eq [char]92) { [void]$sb.Append('\\') }
    elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.Append('\u' + $code.ToString('x4')) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}
# 手写 -Json 输出（不用 ConvertTo-Json：PS 5.1 的它不转义非 ASCII，会把中文原样吐出来破坏 ASCII 契约）。
function Build-JsonText([object[]]$facts) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('{')
  $i = 0
  foreach ($f in $facts) {
    $i = $i + 1
    $tail = ','
    if ($i -eq $facts.Count) { $tail = '' }
    [void]$sb.AppendLine('  ' + (ConvertTo-JsonText $f.key) + ': {')
    [void]$sb.AppendLine('    "value":   ' + (ConvertTo-JsonText $f.value) + ',')
    [void]$sb.AppendLine('    "source":  ' + (ConvertTo-JsonText $f.source) + ',')
    [void]$sb.AppendLine('    "command": ' + (ConvertTo-JsonText $f.command) + ',')
    [void]$sb.AppendLine('    "asOf":    ' + (ConvertTo-JsonText $f.asOf))
    [void]$sb.AppendLine('  }' + $tail)
  }
  [void]$sb.AppendLine('}')
  return $sb.ToString()
}
function Assert-Ascii([string]$s, [string]$where) {
  $i = 0
  foreach ($ch in $s.ToCharArray()) {
    $code = [int]$ch
    $isWs = ($code -eq 9 -or $code -eq 10 -or $code -eq 13)
    if ($code -gt 126 -or ($code -lt 32 -and -not $isWs)) {
      throw ('non-ASCII character at ' + $where + ' offset ' + $i)
    }
    $i = $i + 1
  }
}

# ------------------------------------------------------------------ grep 守卫行
function Select-Guard {
  param(
    [string]$Rel,
    [string]$Pattern,
    [string]$Label,
    [switch]$Latin1,
    [switch]$RequireUnique
  )
  $full = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw ('truth source missing: ' + $Rel) }
  $text = ''
  if ($Latin1) { $text = Get-TextLatin1 $full } else { $text = Get-TextUtf8 $full }
  $ms = [regex]::Matches($text, $Pattern)
  if ($ms.Count -eq 0) { throw ('no guard found for ' + $Label + ' in ' + $Rel) }
  $vals = New-Object System.Collections.ArrayList
  $lines = New-Object System.Collections.ArrayList
  foreach ($m in $ms) {
    [void]$vals.Add($m.Groups[1].Value)
    [void]$lines.Add((Get-LineNo $text $m.Index))
  }
  $uniq = @($vals | Sort-Object -Unique)
  if ($RequireUnique -and $uniq.Count -ne 1) {
    throw ('ambiguous ' + $Label + ' in ' + $Rel + ': values ' + ($uniq -join '/') + ' at lines ' + ($lines -join ','))
  }
  return [pscustomobject]@{ Raw = $ms[0].Groups[1].Value; Uniq = $uniq; Lines = @($lines); Rel = $Rel; Full = $full }
}
function Get-LimitFact {
  param(
    [string]$K, [string]$Rel, [string]$Pattern, [string]$Label, [string]$Cmd,
    [switch]$Latin1, [switch]$RequireUnique, [switch]$Hex, [string]$Note = ''
  )
  $g = Select-Guard -Rel $Rel -Pattern $Pattern -Label $Label -Latin1:$Latin1 -RequireUnique:$RequireUnique
  $val = $g.Raw
  if ($Hex) { $val = [string]([Convert]::ToInt64($g.Raw, 16)) }
  $src = $g.Rel + ':' + ($g.Lines -join ',') + ' (' + $Label + ' = ' + $g.Raw + ')'
  if ($Note -ne '') { $src = $src + ' -- ' + $Note }
  return New-Fact $K $val $src $Cmd (Get-MTime $g.Full)
}

# ------------------------------------------------------------------ 文件集合 / 计数
# ExcludeRx  : 按**文件名**排除（正则）。
# ExcludeDir : 按**目录名**排除，任意深度命中即跳过该子树（相对 $Dir 的路径按段比较）。
#   为什么要它（2026-10-16，任务 4/4）：`test\tmp` 是本仓库 .gitignore 掉的临时产物目录，
#   `test\边界探针.ps1` 每跑一次就往 `test\tmp\边界探针\` 里写一批 .fl。语料计数若把它算进去，
#   文档门会因为「刚跑过探针」而假红（293 -> 342）—— 而探针本身就是门的一步，等于门自己污染
#   自己的真值源。排除规则属于**计数口径**，所以必须写在取数器里（唯一真值源），不许在文档里
#   写死"少算 43 个"这种数字：目录清空后计数不变，才说明口径对。
function Get-FileSet {
  param([string]$Dir, [string]$NameRx, [switch]$Recurse, [string]$ExcludeRx = '', [string[]]$ExcludeDir = @())
  $full = Join-Path $rootFull $Dir
  if (-not (Test-Path -LiteralPath $full)) { throw ('missing directory: ' + $Dir) }
  $items = @()
  if ($Recurse) { $items = @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue) }
  else { $items = @(Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue) }
  $base = $full.TrimEnd([char[]]('\', '/'))
  $sel = New-Object System.Collections.ArrayList
  foreach ($it in $items) {
    if ($NameRx -ne '' -and ($it.Name -notmatch $NameRx)) { continue }
    if ($ExcludeRx -ne '' -and ($it.Name -match $ExcludeRx)) { continue }
    if ($ExcludeDir.Count -gt 0 -and $it.DirectoryName.Length -gt $base.Length) {
      $relDir = $it.DirectoryName.Substring($base.Length)
      $skip = $false
      foreach ($seg in ($relDir -split '[\\/]')) {
        if ($seg -ne '' -and ($ExcludeDir -contains $seg)) { $skip = $true; break }
      }
      if ($skip) { continue }
    }
    [void]$sel.Add($it)
  }
  return @($sel)
}
function Get-CountFact {
  param([string]$K, [string]$Dir, [string]$NameRx, [string]$Cmd, [switch]$Recurse, [string]$ExcludeRx = '', [string[]]$ExcludeDir = @(), [switch]$SumLf, [switch]$SumBytes)
  $set = Get-FileSet -Dir $Dir -NameRx $NameRx -Recurse:$Recurse -ExcludeRx $ExcludeRx -ExcludeDir $ExcludeDir
  if ($set.Count -eq 0) { throw ('no file matched ' + $NameRx + ' under ' + $Dir) }
  $val = 0
  if ($SumLf) {
    $sum = 0
    foreach ($f in $set) { $sum = $sum + (Count-Lf $f.FullName) }
    $val = $sum
  } elseif ($SumBytes) {
    $sum = 0
    foreach ($f in $set) { $sum = $sum + $f.Length }
    $val = $sum
  } else {
    $val = $set.Count
  }
  $scopeNote = ', top level'
  if ($Recurse) { $scopeNote = ', recursive' }
  $exNote = ''
  if ($ExcludeDir.Count -gt 0) { $exNote = ', excluding dir(s): ' + ($ExcludeDir -join ',') }
  $unit = 'files'
  if ($SumLf) { $unit = 'lines (LF 0x0A)' }
  elseif ($SumBytes) { $unit = 'bytes (sum of file length)' }
  $src = $Dir + ' (' + $NameRx + $scopeNote + ', ' + $set.Count + ' files' + $exNote + '; unit: ' + $unit + ')'
  return New-Fact $K ([string]$val) $src $Cmd (Get-MaxMTimeFrom $set)
}

# ------------------------------------------------------------------ 源文件体量（<行数>/<字节>）
function Get-OneFileSize([string]$Rel) {
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('missing file: ' + $Rel) }
  return [pscustomobject]@{ Lines = (Count-Lf $p); Bytes = (Get-Item -LiteralPath $p).Length; Full = $p }
}
function Get-FactLinesBytes([string]$K, [string]$Rel, [string]$Cmd) {
  $s = Get-OneFileSize $Rel
  return New-Fact $K ([string]$s.Lines + '/' + [string]$s.Bytes) ($Rel + ' (lines = LF 0x0A count / bytes = raw file length)') $Cmd (Get-MTime $s.Full)
}
function Get-FactLinesOnly([string]$K, [string]$Rel, [string]$Cmd) {
  $s = Get-OneFileSize $Rel
  return New-Fact $K ([string]$s.Lines) ($Rel + ' (lines = LF 0x0A count)') $Cmd (Get-MTime $s.Full)
}
function Get-FactSetLinesBytes([string]$K, [string]$Dir, [string]$NameRx, [string]$Cmd, [switch]$Recurse) {
  $set = Get-FileSet -Dir $Dir -NameRx $NameRx -Recurse:$Recurse
  if ($set.Count -eq 0) { throw ('no file matched ' + $NameRx + ' under ' + $Dir) }
  $lines = 0
  $bytes = 0
  foreach ($f in $set) { $lines = $lines + (Count-Lf $f.FullName); $bytes = $bytes + $f.Length }
  $scopeNote = 'top level'
  if ($Recurse) { $scopeNote = 'recursive' }
  $src = $Dir + ' (' + $NameRx + ', ' + $scopeNote + ', ' + $set.Count + ' files: sum of lines (LF 0x0A) / sum of bytes)'
  return New-Fact $K ([string]$lines + '/' + [string]$bytes) $src $Cmd (Get-MaxMTimeFrom $set)
}

function Get-FactBytes([string]$K, [string]$Rel, [string]$Cmd) {
  $s = Get-OneFileSize $Rel
  return New-Fact $K ([string]$s.Bytes) ($Rel + ' (raw file length in bytes)') $Cmd (Get-MTime $s.Full)
}

# ------------------------------------------------------------------ 探针用例表
function Get-ProbeCounts {
  $p = Join-Path $rootFull $script:ProbeRel
  $text = Get-TextUtf8 $p
  $ok = 0; $wall = 0; $gap = 0; $total = 0
  $unknown = New-Object System.Collections.ArrayList
  $lines = $text -split "`n"
  $i = 0
  foreach ($ln in $lines) {
    $i = $i + 1
    if ($ln.TrimStart().StartsWith('#')) { continue }
    foreach ($m in [regex]::Matches($ln, 'kind\s*=\s*''([A-Za-z_]+)''')) {
      $kind = $m.Groups[1].Value
      if ($kind -eq 'ok') { $ok = $ok + 1; $total = $total + 1 }
      elseif ($kind -eq 'wall') { $wall = $wall + 1; $total = $total + 1 }
      elseif ($kind -eq 'gap') { $gap = $gap + 1; $total = $total + 1 }
      else { [void]$unknown.Add('line ' + $i + ' kind=' + $kind) }
    }
  }
  if ($unknown.Count -gt 0) { throw ('unknown probe kinds: ' + ($unknown -join '; ')) }
  if ($total -eq 0) { throw ('no case rows parsed from ' + $script:ProbeRel) }
  return [pscustomobject]@{ Ok = $ok; Wall = $wall; Gap = $gap; Total = $total; Full = $p }
}

# ------------------------------------------------------------------ verify-all 步骤
function Get-GateSteps {
  $rel = 'test\verify-all.ps1'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  $rx = '\[string\[\]\]\$Only\s*=\s*@\((?<body>[^)]*)\)'
  $m = [regex]::Match($text, $rx)
  if (-not $m.Success) { throw ('cannot find the $Only default array in ' + $rel) }
  $names = @()
  foreach ($x in [regex]::Matches($m.Groups['body'].Value, "'([A-Za-z0-9_\-]+)'")) { $names += $x.Groups[1].Value }
  if ($names.Count -eq 0) { throw ('$Only default array parsed empty in ' + $rel) }
  $line = Get-LineNo $text $m.Index
  return [pscustomobject]@{ N = $names.Count; Names = $names; Line = $line; Full = $p; Rel = $rel }
}

# ------------------------------------------------------------------ boot\verify.ps1 声明的项
function Get-ParenBody([string]$t, [int]$open) {
  $d = 0
  for ($k = $open; $k -lt $t.Length; $k++) {
    $c = $t[$k]
    if ($c -eq '(') { $d = $d + 1 }
    elseif ($c -eq ')') { $d = $d - 1; if ($d -eq 0) { return $t.Substring($open + 1, $k - $open - 1) } }
  }
  return ''
}
function Get-BootVerify {
  $rel = 'boot\verify.ps1'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  $names = New-Object System.Collections.ArrayList
  # ① 数组字面量：foreach ($n in @( ... )) 与 $diff = @( ... )（按括号配平取整段，避免被行尾注释/`{` 骗）
  $opens = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($text, 'foreach\s*\(\s*\$n\s+in\s+@\(')) {
    $o = $text.IndexOf('(', $m.Index + 5)
    if ($o -ge 0) { [void]$opens.Add($o) }
  }
  $dm = [regex]::Match($text, '\$diff\s*=\s*@\(')
  if ($dm.Success) {
    $o = $text.IndexOf('(', $dm.Index + 5)
    if ($o -ge 0) { [void]$opens.Add($o) }
  }
  if ($opens.Count -eq 0) { throw ('no declared item array found in ' + $rel) }
  foreach ($open in $opens) {
    $body = Get-ParenBody $text $open
    if ($body -eq '') { throw ('unbalanced array literal in ' + $rel) }
    foreach ($m in [regex]::Matches($body, "'([A-Za-z_][A-Za-z0-9_]*)'")) { [void]$names.Add($m.Groups[1].Value) }
  }
  # ② 两张 [ordered]@{} 样本表：从锚点行到第一个独占一行的 '}'，逐行取 `名字 = 数字`（先削行尾注释）
  $lines = $text -split "`n"
  $anchors = @('^\s*\$pos\s*=\s*\[ordered\]@\{', '^\s*\$posSamples\s*=\s*\[ordered\]@\{')
  $tables = 0
  foreach ($rx in $anchors) {
    $s = -1
    for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match $rx) { $s = $k; break } }
    if ($s -lt 0) { continue }
    $e = -1
    for ($k = $s + 1; $k -lt $lines.Count; $k++) { if ($lines[$k].Trim() -eq '}') { $e = $k; break } }
    if ($e -lt 0) { throw ('unterminated sample table in ' + $rel) }
    for ($k = $s + 1; $k -lt $e; $k++) {
      $row = $lines[$k]
      $h = $row.IndexOf('#')
      if ($h -ge 0) { $row = $row.Substring(0, $h) }
      foreach ($m in [regex]::Matches($row, '([A-Za-z_]\w*)\s*=\s*-?\d+')) { [void]$names.Add($m.Groups[1].Value) }
    }
    $tables = $tables + 1
  }
  if ($tables -ne 2) { throw ('expected 2 [ordered] sample tables in ' + $rel + ', found ' + $tables) }
  $uniq = @($names | Sort-Object -Unique)
  if ($uniq.Count -eq 0) { throw ('no declared item parsed from ' + $rel) }
  return [pscustomobject]@{ N = $uniq.Count; Raw = $names.Count; Full = $p; Rel = $rel }
}

# ------------------------------------------------------------------ 门日志（慢键）
# -AsIs：摘要形如 "<label>: N/M passed"（N of M），值直接取 N/M，**不要**把 M 当成"总数"再相加。
# 不加 -AsIs：摘要形如 "通过 N / 失败 M"，值 = N/(N+M)。
function Find-GateLogFact {
  param([string]$K, [string]$NameRx, [string]$SummaryRx, [string]$Note, [switch]$AsIs)
  $tmpDir = Join-Path $rootFull 'tmp'
  if (-not (Test-Path -LiteralPath $tmpDir)) {
    throw ('no tmp directory: no gate log to read (NOT_COLLECTED; run the gate, or -Slow where allowed)')
  }
  $cands = @(Get-ChildItem -LiteralPath $tmpDir -Recurse -File -Filter *.log -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match $NameRx } | Sort-Object LastWriteTime -Descending)
  if ($cands.Count -eq 0) { throw ('no gate log matching /' + $NameRx + '/ under tmp (NOT_COLLECTED; ' + $Note + ')') }
  foreach ($c in $cands) {
    $hits = @(Select-String -LiteralPath $c.FullName -Pattern $SummaryRx -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($hits.Count -gt 0) {
      $mm = [regex]::Match($hits[$hits.Count - 1].Line, $SummaryRx)
      if (-not $mm.Success) { continue }
      $first = [int]$mm.Groups[1].Value
      $second = [int]$mm.Groups[2].Value
      $rel = Get-Rel $c.FullName
      $stamp = Get-MTime $c.FullName
      $value = ''
      $shape = ''
      if ($AsIs) {
        $value = [string]$first + '/' + [string]$second
        $shape = 'summary line: ' + $first + ' of ' + $second + ' passed'
      } else {
        $value = [string]$first + '/' + [string]($first + $second)
        $shape = 'summary line: ' + $first + ' pass / ' + $second + ' fail'
      }
      $src = $rel + ' (count from the MOST RECENT ACTUAL RUN; ' + $shape + '; log mtime ' + $stamp + ')'
      $cmd = 'Select-String -LiteralPath ' + $rel + " -Pattern '<summary>' -Encoding UTF8"
      return New-Fact $K $value $src $cmd $stamp
    }
  }
  throw ('no gate log matching /' + $NameRx + '/ carried the summary line (NOT_COLLECTED; ' + $Note + ')')
}

# ------------------------------------------------------------------ apps 侧：Check 调用 / 判据编号
function Get-ChecksPanel {
  $rel = 'apps\winpanel\verify-panel.ps1'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  # 调用点 = 行首（可带缩进）的 Check "<id>" ...；函数定义 `function Check([string]$id, ...)` 不匹配。
  $ms = [regex]::Matches($text, '(?m)^[ \t]*Check[ \t]+"([^"]+)"')
  if ($ms.Count -eq 0) { throw ('no Check "<id>" call site found in ' + $rel) }
  $ids = New-Object System.Collections.ArrayList
  foreach ($m in $ms) { [void]$ids.Add($m.Groups[1].Value) }
  $uniq = @($ids | Sort-Object -Unique)
  $dupNote = ''
  $dups = @($ids | Group-Object | Where-Object { $_.Count -gt 1 })
  if ($dups.Count -gt 0) {
    $parts = @()
    foreach ($d in $dups) { $parts += ($d.Name + ' x' + $d.Count) }
    $dupNote = '; repeated ids folded: ' + ($parts -join ', ')
  }
  $src = $rel + ' (calls = lines matching ^\s*Check "<id>"; distinct = unique <id> strings, so an id used N times counts once' + $dupNote + ')'
  $cmd = 'Select-String -LiteralPath ' + $rel + ' -Pattern Check  -> count call lines and unique <id>'
  return New-Fact 'checks-panel' ([string]$ms.Count + '/' + [string]$uniq.Count) $src $cmd (Get-MTime $p)
}

# ------------------------------------------------------------------ -strict 帮助块的编号项
function Get-StrictClasses {
  $rel = 'src\main.c'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  $lines = $text -split "`n"
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'fprintf\(stderr,\s*"\s+-strict\b') { $start = $i; break } }
  if ($start -lt 0) { throw ('cannot find the -strict help line in ' + $rel) }
  $end = -1
  for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'fprintf\(stderr,\s*"\s+-[a-z]') { $end = $i; break } }
  if ($end -lt 0) { throw ('cannot find the end of the -strict help block in ' + $rel) }
  $block = ($lines[$start..($end - 1)] -join "`n")
  # 圈号：①..⑳ = U+2460..U+2473；㉑..㉟ = U+3251..U+325F；㊱..㊿ = U+32B1..U+32BF
  $marks = @([regex]::Matches($block, '[\u2460-\u2473\u3251-\u325F\u32B1-\u32BF]') | ForEach-Object { $_.Value })
  if ($marks.Count -eq 0) { throw ('no circled number marker found in the -strict help block of ' + $rel) }
  $uniq = @($marks | Sort-Object -Unique)
  $src = $rel + ':' + ($start + 1) + '-' + $end + ' (the -strict help block only: distinct circled-number markers; the block ends at the next fprintf flag line)'
  $cmd = 'Select-String -Path ' + $rel + ' -Pattern strict  -> then count distinct circled numbers in that block'
  return New-Fact 'strict-classes' ([string]$uniq.Count) $src $cmd (Get-MTime $p)
}

# ------------------------------------------------------------------ 边界覆盖.mjs（只读对账器）
function Get-BoundaryToolRun {
  if ($null -ne $script:BndRun) { return $script:BndRun }
  $rel = 'tools\边界覆盖.mjs'
  $p = Join-Path $rootFull $rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('tool missing: ' + $rel) }
  Push-Location $rootFull
  try { $out = & node $rel 2>&1 | Out-String } finally { Pop-Location }
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  if ($code -ne 0) { throw ($rel + ' exited ' + $code + ' -- its numbers cannot be trusted') }
  $inputs = New-Object System.Collections.ArrayList
  [void]$inputs.Add($p)
  [void]$inputs.Add((Join-Path $rootFull $script:ProbeRel))
  foreach ($extra in @('C:\Users\20838\Desktop\记忆.md', 'C:\Users\20838\Desktop\.dsh-tools\记忆归档\FLINT编译器.md')) {
    if (Test-Path -LiteralPath $extra -PathType Leaf) { [void]$inputs.Add($extra) }
  }
  $stamp = Get-MaxMTimeFrom @($inputs)
  if ($stamp -eq '') { $stamp = Get-MTime $p }
  $script:BndRun = [pscustomobject]@{ Text = $out; Rel = $rel; Full = $p; Stamp = $stamp; Cmd = 'node ' + $rel }
  return $script:BndRun
}
function Get-BoundaryFact([string]$K, [string]$Rx, [string]$Section) {
  $run = Get-BoundaryToolRun
  $m = [regex]::Match($run.Text, $Rx)
  if (-not $m.Success) { throw ('cannot parse section ' + $Section + ' from ' + $run.Rel + ' stdout (pattern drifted?)') }
  $val = $m.Groups[1].Value
  $src = $run.Rel + ' stdout, section ' + $Section + ' (only-read reconciler; value is the count it printed)'
  return New-Fact $K $val $src $run.Cmd $run.Stamp
}

# ------------------------------------------------------------------ flint.exe 的重建 / 忽略状态
function Get-FlintRebuildNote {
  $rel = 'test\verify-all.ps1'
  $p = Join-Path $rootFull $rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 'rebuilt by ' + $rel + ' step [0] with gcc -O2 (file not found, line unknown)' }
  $text = Get-TextUtf8 $p
  $m = [regex]::Match($text, 'gcc\s+-O2\s+@src\s+-o')
  if (-not $m.Success) { return 'rebuilt by ' + $rel + ' step [0] with gcc -O2 (gcc line not found)' }
  return 'rebuilt by ' + $rel + ':' + (Get-LineNo $text $m.Index) + ' (step [0], gcc -O2)'
}
function Get-FlintIgnoreNote {
  # 现场问 git，别把"gitignored"当口口相传的断言；git 不可用就降级成 unknown，不抛。
  $note = 'gitignore state unknown (git not available)'
  Push-Location $rootFull
  try {
    $out = & git check-ignore -v 'flint.exe' 2>&1 | Out-String
    $code = $LASTEXITCODE
  } catch {
    $out = ''
    $code = 1
  } finally { Pop-Location }
  if ($code -eq 0 -and $out.Trim() -ne '') {
    # git check-ignore -v 输出 <source>:<line>:<pattern><TAB><path>；制表符不压平会被转义成 \u0009
    $flat = ($out.Trim() -replace '\s+', ' ')
    $note = 'gitignored by ' + $flat
  }
  elseif ($code -eq 1) { $note = 'NOT gitignored (git check-ignore found no rule)' }
  return $note
}

# ------------------------------------------------------------------ 只读仪器
function Invoke-ToolJson {
  param([string]$Rel, [string[]]$Argv, [int[]]$AcceptExit)
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('instrument missing: ' + $Rel) }
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $p) + $Argv
  $out = & powershell @all 2>&1 | Out-String
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  if ($AcceptExit -notcontains $code) {
    throw ('instrument ' + $Rel + ' exited ' + $code + ' -- its numbers cannot be trusted')
  }
  $obj = $null
  try { $obj = $out | ConvertFrom-Json } catch { throw ('cannot parse JSON from ' + $Rel + ': ' + $_.Exception.Message) }
  if ($null -eq $obj) { throw ('empty JSON from ' + $Rel) }
  $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $Rel + ' ' + ($Argv -join ' ')
  return [pscustomobject]@{ Obj = $obj; Exit = $code; Rel = $Rel; Full = $p; Cmd = $cmd }
}
function Get-ImportMeter {
  if ($null -eq $script:ImpJson) {
    $script:ImpJson = Invoke-ToolJson -Rel 'tools\导入预算.ps1' -Argv @('-Json') -AcceptExit @(0, 1)
  }
  return $script:ImpJson
}
function Get-BootMeter {
  if ($null -eq $script:BootJson) {
    $script:BootJson = Invoke-ToolJson -Rel 'tools\boot余量.ps1' -Argv @('-Json') -AcceptExit @(0, 1)
  }
  return $script:BootJson
}
function Get-ArtifactRow([string]$ArtifactRel) {
  $meter = Get-ImportMeter
  $row = $null
  foreach ($r in @($meter.Obj.Rows)) { if ($r.Artifact -eq $ArtifactRel) { $row = $r; break } }
  if ($null -eq $row) { throw ('import meter printed no row for ' + $ArtifactRel) }
  return $row
}
function Get-ImportCountFact([string]$K, [string]$ArtifactRel, [string]$Which) {
  $row = Get-ArtifactRow $ArtifactRel
  $field = ''
  if ($Which -eq 'imports') { $field = $row.Imports } else { $field = $row.Groups }
  $n = [int](($field -split '/')[0])
  $capImp = Get-Fact 'limit-imports'
  $capGrp = Get-Fact 'limit-groups'
  $src = 'tools\导入预算.ps1 -Json, row ' + $ArtifactRel + ' (field: ' + $Which + '); caps ' + $capImp.source + ' | ' + $capGrp.source
  $exe = Join-Path $rootFull $ArtifactRel
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw ('artifact missing: ' + $ArtifactRel) }
  return New-Fact $K ([string]$n) $src (Get-ImportMeter).Cmd (Get-MTime $exe)
}
function Get-BootMeterFact([string]$K, [string]$Field) {
  $meter = Get-BootMeter
  $o = $meter.Obj
  $map = @{ 'occupied' = $o.Occupied; 'headroom' = $o.Headroom; 'limit' = $o.Limit }
  if (-not $map.ContainsKey($Field)) { throw ('unknown boot meter field: ' + $Field) }
  $val = [string]$map[$Field]
  $src = 'tools\boot余量.ps1 -Json (field: ' + $Field + '); limit truth source = ' + $o.LimitSource
  $paths = New-Object System.Collections.ArrayList
  foreach ($f in @($o.Files)) { [void]$paths.Add((Join-Path $rootFull $f.File)) }
  [void]$paths.Add((Join-Path $rootFull 'apps\m2_float\main.fl'))
  $asOf = Get-MaxMTimeFrom @($paths)
  if ($asOf -eq '') { $asOf = Get-MTime $meter.Full }
  return New-Fact $K $val $src $meter.Cmd $asOf
}

# ------------------------------------------------------------------ 产物字节数
function Get-ProductFact([string]$K, [string]$Rel, [string]$Note = '') {
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('product missing: ' + $Rel) }
  $f = Get-Item -LiteralPath $p
  $cmd = '(Get-Item ' + $Rel + ').Length'
  $src = $Rel + ' (file length in bytes)'
  if ($Note -ne '') { $src = $src + '; ' + $Note }
  return New-Fact $K ([string]$f.Length) $src $cmd ($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
}
function Get-ProductShaFact([string]$K, [string]$Rel, [string]$Note = '') {
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('product missing: ' + $Rel) }
  $f = Get-Item -LiteralPath $p
  $sha = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 16)
  $cmd = '(Get-FileHash ' + $Rel + ' -Algorithm SHA256).Hash.Substring(0,16)'
  $src = 'sha16(SHA256) of ' + $Rel
  if ($Note -ne '') { $src = $src + '; ' + $Note }
  return New-Fact $K $sha $src $cmd ($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
}

# ------------------------------------------------------------------ 产物 sha16：先分清「committed 文件身份」与「重编核对的哈希」
# 2026-10-16 实测（实验在本脚本之外做，数字故意不入本脚本 —— 铁律 1）：
#   同一个 flint.exe 编同一份源码是**确定的**（连着两次重建，sha16 相同）；
#   但**仓库里 committed 的 .exe 不等于重建结果** —— hello 逐字节相同，winpanel / ui_gallery 同尺寸、内容不同。
# ⇒ sha16 键的口径只能声明成「仓库里那个文件的身份」，不能当成「重编核对会得到的哈希」去引用。
function Get-ProductBuildNote([string]$Which) {
  if ($Which -eq 'reproducible') {
    return 'FLINT-built bare PE (no assembler, no linker, no CRT); measured 2026-10-16: a fresh rebuild of the same source IS byte-identical to the committed file => this sha is stable across rebuilds'
  }
  return 'FLINT-built bare PE (no assembler, no linker, no CRT); measured 2026-10-16: a fresh rebuild of the same source is NOT byte-identical to the committed file (same size, different content) => this value is the COMMITTED FILE identity, NOT a rebuild check; do not quote it in documents'
}

# ------------------------------------------------------------------ 图片（PNG 头里的像素尺寸 / 文件字节）
# 口径故意分成两条**独立**的键：`-px` = PNG 像素尺寸（IHDR 字节 16..23），`-bytes` = 文件长度。
# 为什么不合成一条：文档表格里"窗口尺寸"与"PNG 字节"是两列、两个量纲，合成一条就有一列挂不上标记；
# 而且"窗口尺寸"是**文档声明**、"PNG 像素"是**从文件里量出来的**，本次两者恰好相等 != 同一个键。
function Get-PngInfo([string]$Rel) {
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('image missing: ' + $Rel) }
  $b = [IO.File]::ReadAllBytes($p)
  if ($b.Length -lt 24) { throw ('not a PNG (too short): ' + $Rel) }
  if (-not ($b[0] -eq 137 -and $b[1] -eq 80 -and $b[2] -eq 78 -and $b[3] -eq 71)) { throw ('PNG signature mismatch: ' + $Rel) }
  if (-not ($b[12] -eq 73 -and $b[13] -eq 72 -and $b[14] -eq 68 -and $b[15] -eq 82)) { throw ('first PNG chunk is not IHDR: ' + $Rel) }
  $w = ([int]$b[16] * 16777216) + ([int]$b[17] * 65536) + ([int]$b[18] * 256) + [int]$b[19]
  $h = ([int]$b[20] * 16777216) + ([int]$b[21] * 65536) + ([int]$b[22] * 256) + [int]$b[23]
  if ($w -le 0 -or $h -le 0) { throw ('bad PNG dimensions in ' + $Rel) }
  return [pscustomobject]@{ W = $w; H = $h; Bytes = (Get-Item -LiteralPath $p).Length; MTime = (Get-MTime $p) }
}
function Get-ImagePxFact([string]$K, [string]$Rel, [string]$Cmd) {
  $i = Get-PngInfo $Rel
  $src = $Rel + ' (caliber: PIXEL size read from the PNG IHDR chunk, bytes 16..23 = W x H). This is the file''s own pixel size, NOT the window size a document may state -- even when the two numbers agree today'
  return New-Fact $K ([string]$i.W + 'x' + [string]$i.H) $src $Cmd $i.MTime
}
function Get-ImageBytesFact([string]$K, [string]$Rel, [string]$Cmd) {
  $i = Get-PngInfo $Rel
  $src = $Rel + ' (caliber: raw PNG file length in bytes)'
  return New-Fact $K ([string]$i.Bytes) $src $Cmd $i.MTime
}
# 总像素 = W x H。**刻意**不从别的文档抄，也不从 PNG 别的字段猜：W/H 来自上面那条 IHDR 读数，
# 乘一下而已（本机最大 1024x736 = 753664，远在 int32 内）。口径写进 source，免得下次有人以为
# 它是"文件里写着的一个数"。
function Get-ImageTotalPxFact([string]$K, [string]$Rel, [string]$Cmd) {
  $i = Get-PngInfo $Rel
  $src = $Rel + ' (caliber: TOTAL pixels = IHDR width x IHDR height, both read from bytes 16..23 of the file; this is arithmetic on the measured pixel size, NOT a number stored anywhere in the PNG)'
  return New-Fact $K ([string]($i.W * $i.H)) $src $Cmd $i.MTime
}

# ---------------------------------------------------------------- 窗口尺寸（源码常量）
# 与 img-*-px **分开**的两条键（不许合并）：img-*-px 是"PNG 文件里量出来的像素尺寸"，
# win-*-px 是"app 源码里写死的窗口尺寸常量"。本次两者恰好相等，但那是巧合，不是同一个量：
#   * 图是客户端区域抓的（PrintWindow PW_CLIENTONLY），窗口尺寸由源码常量决定；
#   * 有些窗口（apps\m2_float）尺寸是**运行时按数据内容自适应**的，压根没有常量 ⇒ 不建键。
# 只对"源码里有唯一常量"的窗口建键；找不到唯一常量一律 exit 2（宁缺勿猜）。
function Get-WinSizeFromTwoConsts {
  param([string]$K, [string]$Rel, [string]$RxW, [string]$RxH, [string]$LabelW, [string]$LabelH, [string]$Cmd)
  $p = Join-Path $rootFull $Rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('window-size truth source missing: ' + $Rel) }
  $text = Get-TextUtf8 $p
  $mw = @([regex]::Matches($text, $RxW))
  $mh = @([regex]::Matches($text, $RxH))
  if ($mw.Count -ne 1) { throw ('expected exactly ONE ' + $LabelW + ' constant in ' + $Rel + ', found ' + $mw.Count + ' => ambiguous window-size truth source') }
  if ($mh.Count -ne 1) { throw ('expected exactly ONE ' + $LabelH + ' constant in ' + $Rel + ', found ' + $mh.Count + ' => ambiguous window-size truth source') }
  $lw = Get-LineNo $text $mw[0].Index
  $lh = Get-LineNo $text $mh[0].Index
  $srcLines = (@($lw, $lh) | Sort-Object -Unique) -join ','
  $src = $Rel + ':' + $srcLines + ' (window-size constants ' + $LabelW + ' = ' + $mw[0].Groups[1].Value + ', ' + $LabelH + ' = ' + $mh[0].Groups[1].Value + '; caliber: the WINDOW size the app source declares, which is a DIFFERENT quantity from the img-*-px PNG pixel size even when the two agree today)'
  return New-Fact $K ($mw[0].Groups[1].Value + 'x' + $mh[0].Groups[1].Value) $src $Cmd (Get-MTime $p)
}

# ---------------------------------------------------------------- 非背景像素（Node 只读仪器）
# 口径（2026-10-16 定，可复现）：背景 = **出现次数最多的那个颜色**（按文件里存的 R,G,B,A 四元组算），
# 非背景像素 = 与它不同的像素数。规则由 tools\像素统计.mjs 实现，本脚本只读它的 --json。
# 为什么值不从本脚本里数：字节级/像素级取证不该用 PowerShell（旧账：.fl 行数被 GBK 解码骗过），
# 而且候选规则不止一条 —— 仪器把**每条试过的规则**都打出来，本脚本只认它声明的那一条。
function Get-PixCensusRun {
  if ($null -ne $script:PixJson) { return $script:PixJson }
  $rel = 'tools\像素统计.mjs'
  $p = Join-Path $rootFull $rel
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('instrument missing: ' + $rel) }
  Push-Location $rootFull
  try { $out = & node $rel --json 2>&1 | Out-String } finally { Pop-Location }
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  if ($code -ne 0) { throw ($rel + ' exited ' + $code + ' -- its numbers cannot be trusted') }
  $obj = $null
  try { $obj = $out | ConvertFrom-Json } catch { throw ('cannot parse JSON from ' + $rel + ': ' + $_.Exception.Message) }
  if ($null -eq $obj) { throw ('empty JSON from ' + $rel) }
  $script:PixJson = [pscustomobject]@{ Obj = $obj; Rel = $rel; Full = $p; Cmd = 'node ' + $rel + ' --json' }
  return $script:PixJson
}
function Get-PixRow([string]$Id) {
  $run = Get-PixCensusRun
  $row = $null
  foreach ($r in @($run.Obj.results)) { if ($r.id -eq $Id) { $row = $r; break } }
  if ($null -eq $row) { throw ('pixel census printed no row with id=' + $Id + ' (ids are ASCII on purpose: PS 5.1 decodes a child process'' stdout with the console codepage, so a CJK path would come back as mojibake)') }
  return $row
}
function Get-ImageNonBgFact([string]$K, [string]$Id) {
  $row = Get-PixRow $Id
  $src = (Get-PixCensusRun).Rel + ' --json, row id=' + $Id + ' (non-background pixel count; caliber: ' + $row.caliberRule + ')'
  return New-Fact $K ([string]$row.nonBackgroundCount) $src (Get-PixCensusRun).Cmd (Get-MTime (Get-PixCensusRun).Full)
}
function Get-ImageNonBgPctFact([string]$K, [string]$Id) {
  $row = Get-PixRow $Id
  $src = (Get-PixCensusRun).Rel + ' --json, row id=' + $Id + ' (non-background COUNT / total pixels, rounded to 2 decimals; ' + $row.nonBackgroundCount + ' / ' + $row.pixels + ')'
  return New-Fact $K ([string]$row.nonBackgroundPct) $src (Get-PixCensusRun).Cmd (Get-MTime (Get-PixCensusRun).Full)
}
# ------------------------------------------------------------------ SPEC 设计原则条数 / 行号
# 2026-10-16：行号也是数字，也会漂。docs\索引.md 曾把 §设计原则 写成 "起 :96 / 第 11 条在 :142"，
# 而实测标题在 :100、第 1 条 :102、最后一条 :146（差 4 行，静默漂了两刀没人发现）。
# ⇒ 行号一律由**本函数现场解析 SPEC.md** 给出，文档里写成活标记；SPEC 一改，门就红，--fix 一跑自动跟新。
function Get-SpecSection {
  if ($null -ne $script:SpecSec) { return $script:SpecSec }
  $rel = 'SPEC.md'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  $lines = @($text.Split([char]10))
  $start = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].TrimEnd() -eq '## 设计原则') { $start = $i; break }
  }
  if ($start -lt 0) { throw ('no heading "## 设计原则" in ' + $rel) }
  $end = $lines.Count - 1
  for ($i = $start + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith('## ')) { $end = $i - 1; break }
  }
  $nums = New-Object System.Collections.ArrayList
  $firstLine = 0
  $lastLine = 0
  for ($i = $start + 1; $i -le $end; $i++) {
    $m = [regex]::Match($lines[$i], '^\s*(\d+)\.\s+\*\*')
    if ($m.Success) {
      [void]$nums.Add([int]$m.Groups[1].Value)
      if ($firstLine -eq 0) { $firstLine = $i + 1 }
      $lastLine = $i + 1
    }
  }
  if ($nums.Count -eq 0) { throw ('no top-level numbered principle found in ' + $rel + ' section 设计原则') }
  $expect = @(1..$nums.Count)
  $got = @($nums | Sort-Object)
  if (($expect -join ',') -ne ($got -join ',')) {
    throw ('principle numbering in ' + $rel + ' is not contiguous 1..N (found ' + ($nums -join ',') + ') => ambiguous, refusing to pick a number')
  }
  $script:SpecSec = [pscustomobject]@{
    Rel = $rel; Full = $p; N = $nums.Count
    SecLine = $start + 1; FirstLine = $firstLine; LastLine = $lastLine; LastNum = $nums[$nums.Count - 1]
    MTime = (Get-MTime $p)
  }
  return $script:SpecSec
}
function Get-SpecPrinciples {
  $s = Get-SpecSection
  $src = $s.Rel + ':' + $s.FirstLine + '-' + $s.LastLine + ' (section "## 设计原则" up to the next "## "; top-level "N. **" items, numbering checked contiguous 1..' + $s.N + ')'
  $cmd = 'Select-String -Path ' + $s.Rel + ' -Pattern "^[0-9]+[.] [*][*]" inside the 设计原则 section (first item line ' + $s.FirstLine + ', last ' + $s.LastLine + ')'
  return New-Fact 'spec-principles' ([string]$s.N) $src $cmd $s.MTime
}
function Get-SpecLineFact([string]$K, [string]$Which) {
  $s = Get-SpecSection
  $val = 0
  $note = ''
  if ($Which -eq 'sec') {
    $val = $s.SecLine
    $note = 'line number of the "## 设计原则" section HEADING itself (the section body starts after it)'
  } elseif ($Which -eq 'first') {
    $val = $s.FirstLine
    $note = 'line number of principle 1, the first top-level "N. **" item inside that section'
  } else {
    $val = $s.LastLine
    $note = 'line number of principle ' + $s.LastNum + ', the LAST top-level "N. **" item inside that section'
  }
  $src = $s.Rel + ':' + $val + ' (' + $note + '; recomputed from the file on every read, so an edit to SPEC.md above this point turns the gate red instead of drifting silently)'
  $cmd = 'Select-String -Path ' + $s.Rel + ' -Pattern "^## 设计原则" / "^[0-9]+[.] [*][*]" (line numbers, 1-based, counted on LF)'
  return New-Fact $K ([string]$val) $src $cmd $s.MTime
}

# ------------------------------------------------------------------ INT32 十进制字面量上限
function Get-Int32MaxFact {
  $rel = 'src\tokenize.c'
  $p = Join-Path $rootFull $rel
  $text = Get-TextUtf8 $p
  # v1.7.0：十进制 > INT32_MAX 改为"自动升级成 64 位字面量"（不再报错），守卫形状随之变化；
  #   上限值本身没变（仍是 0x7FFFFFFF），所以只更新**取数用的两个独立陈述**，判据语义不动。
  $gm = [regex]::Matches($text, 'is_hex\s*\?\s*\(uv\s*>\s*0xFFFFFFFFULL\)\s*:\s*\(v\s*>\s*(0x7FFFFFFF)LL\)')
  if ($gm.Count -ne 1) { throw ('expected exactly one decimal-literal guard in ' + $rel + ', found ' + $gm.Count) }
  $guardLine = Get-LineNo $text $gm[0].Index
  $fromGuard = [Convert]::ToInt64($gm[0].Groups[1].Value.Substring(2), 16)
  # 同一份文件里的注释是**第二处独立陈述**：两处不一致就判歧义，不挑一个（铁律 1）
  $msgs = [regex]::Matches($text, 'INT32_MAX\s*\((\d+)\)')
  if ($msgs.Count -ne 1) { throw ('expected exactly one INT32_MAX(n) statement in ' + $rel + ', found ' + $msgs.Count) }
  $msgLine = Get-LineNo $text $msgs[0].Index
  $fromMsg = [int64]$msgs[0].Groups[1].Value
  if ($fromGuard -ne $fromMsg) {
    throw ('ambiguous INT32 decimal cap in ' + $rel + ': guard says ' + $fromGuard + ' (line ' + $guardLine + '), comment says ' + $fromMsg + ' (line ' + $msgLine + ')')
  }
  $src = $rel + ':' + $guardLine + ',' + $msgLine + ' (decimal literal cap = ' + $gm[0].Groups[1].Value + '; same file states the same limit in a comment)'
  $cmd = 'Select-String -Path ' + $rel + ' -Pattern "is_hex" (the guard), then cross-check the INT32_MAX(n) comment'
  return New-Fact 'limit-int32max' ([string]$fromGuard) $src $cmd (Get-MTime $p)
}

# ------------------------------------------------------------------ 自举不动点
function Get-SelfHostFact {
  $rels = @('boot\b1_emit.fl', 'boot\self1.fl', 'boot\self2.fl')
  $rows = New-Object System.Collections.ArrayList
  foreach ($r in $rels) {
    $p = Join-Path $rootFull $r
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('self-hosting source missing: ' + $r + ' (run boot\verify.ps1 to regenerate self1/self2)') }
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0, 16)
    [void]$rows.Add([pscustomobject]@{ Rel = $r; Sha = $h })
  }
  $uniq = @($rows | ForEach-Object { $_.Sha } | Sort-Object -Unique)
  if ($uniq.Count -ne 1) {
    $detail = @($rows | ForEach-Object { $_.Rel + '=' + $_.Sha }) -join ' '
    throw ('boot fixed point BROKEN (sha16 differ): ' + $detail)
  }
  $src = 'sha16(SHA256) of ' + (($rows | ForEach-Object { $_.Rel }) -join ' + ') + ' (must be byte-identical)'
  $cmd = 'Get-FileHash boot\b1_emit.fl,boot\self1.fl,boot\self2.fl -Algorithm SHA256'
  $asOf = Get-MaxMTimeFrom @(($rows | ForEach-Object { Join-Path $rootFull $_.Rel }))
  return New-Fact 'selfhost-shas' $uniq[0] $src $cmd $asOf
}

# ------------------------------------------------------------------ version
function Get-VersionFact {
  $relH = 'src\flint.h'
  $ph = Join-Path $rootFull $relH
  $htext = Get-TextUtf8 $ph
  $rxMacro = '^\s*#\s*define\s+FLINT_VERSION\s+([^\s/]+)'
  $mm = [regex]::Match($htext, $rxMacro, [Text.RegularExpressions.RegexOptions]::Multiline)
  if ($mm.Success) {
    $v = $mm.Groups[1].Value.Trim('"')
    $line = Get-LineNo $htext $mm.Index
    return New-Fact 'version' $v ($relH + ':' + $line + ' (FLINT_VERSION macro)') ('Select-String -Path ' + $relH + ' -Pattern FLINT_VERSION') (Get-MTime $ph)
  }
  $relM = 'src\main.c'
  $pm = Join-Path $rootFull $relM
  $mtext = Get-TextUtf8 $pm
  $best = $null
  $bestLine = 0
  foreach ($m in [regex]::Matches($mtext, 'v(\d+)\.(\d+)\.(\d+)')) {
    $ver = [version]($m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value)
    if ($null -eq $best -or $ver -gt $best) { $best = $ver; $bestLine = Get-LineNo $mtext $m.Index }
  }
  if ($null -eq $best) { throw ('no FLINT_VERSION in ' + $relH + ' and no vX.Y.Z in ' + $relM) }
  $src = $relM + ':' + $bestLine + ' (highest vX.Y.Z in usage text; ' + $relH + ' has no FLINT_VERSION)'
  $cmd = 'Select-String -Path ' + $relM + ' -Pattern vN.N.N  -> take the maximum match'
  return New-Fact 'version' ([string]$best) $src $cmd (Get-MTime $pm)
}

# ------------------------------------------------------------------ 键表
$script:KeyOrder = @(
  'version', 'src-files', 'src-loc', 'src-c-loc', 'src-c-bytes', 'src-h-loc', 'src-h-bytes',
  'test-samples', 'test-corpus', 'facts-probes',
  'probe-cases', 'probe-ok', 'probe-wall', 'probe-gap',
  'spec-principles', 'spec-principles-sec', 'spec-principles-first', 'spec-principles-last',
  'gate-steps', 'boot-verify', 'boot-verify-items', 'regress', 'flgui-checks',
  'examples-passed', 'strict-classes', 'memory-flint-rows', 'boundary-suspect-uncovered',
  'imports-m2float', 'modules-m2float', 'imports-winpanel',
  'boot-occupied', 'boot-headroom', 'boot-limit',
  'limit-imports', 'limit-groups', 'limit-dllname', 'limit-code', 'limit-strbuf',
  'limit-structfields', 'limit-funcargs', 'limit-apiargs', 'limit-int32max',
  'limit-boottable', 'limit-blockchildren', 'limit-constpool',
  'limit-bootsrcbytes', 'limit-bootreadbuf', 'limit-splicesize',
  'app-winpanel-mainfl', 'app-m2float-mainfl', 'app-m2float-allfl', 'app-uigallery-mainfl',
  'lib-flgui-win32', 'lib-flgui', 'lib-ui-lib',
  'lang-en-bytes', 'lang-zh-bytes',
  'img-winpanel-px', 'img-winpanel-bytes', 'img-uigallery-px', 'img-uigallery-bytes', 'img-m2float-px', 'img-m2float-bytes',
  'img-winpanel-totalpx', 'img-uigallery-totalpx', 'img-m2float-totalpx',
  'img-winpanel-nonbg', 'img-uigallery-nonbg', 'img-m2float-nonbg',
  'img-winpanel-nonbg-pct', 'img-uigallery-nonbg-pct', 'img-m2float-nonbg-pct',
  'win-winpanel-px', 'win-uigallery-px',
  'app-winpanel-verifypanel-loc', 'app-winpanel-验收-loc', 'test-loop-verify-loc', 'checks-panel',
  'product-flint', 'product-flint-sha16',
  'product-hello', 'product-window', 'product-winpanel', 'product-m2float', 'product-uigallery', 'product-student',
  'product-winpanel-sha16', 'product-hello-sha16', 'product-uigallery-sha16',
  'selfhost-shas'
)

$patternMaxImports = '#define\s+MAX_IMPORTS\s+(\d+)'
$patternMaxGroups = '#define\s+MAX_GROUPS\s+(\d+)'
$patternDllName = '#define\s+IMPORT_DLL_NAME_MAX\s+(\d+)'
$patternMaxText = '#define\s+FLINT_MAX_TEXT\s+(0x[0-9A-Fa-f]+)'
$patternFields = 'StructField\s+fields\[(\d+)\]'
$patternFuncArgs = '#define\s+FUNC_MAX_ARGS\s+(\d+)'
$patternApiArgs = '#define\s+API_MAX_ARGS\s+(\d+)'
$patternNFuncs = 'nfuncs\s*>=\s*(\d+)'
$patternBlockKids = 'cnt\s*>=\s*(\d+)\)\s*return -101'
$patternSpool = 'spcur\s*>=\s*(\d+)'
$patternBootSrc = 'char\s+\*src\s*=\s*VirtualAlloc\(0,\s*(\d+)'
$patternSpliceCap = 'splice_file\(inb,\s*src,\s*(\d+)'
$patternStrbuf = '#define\s+FLINT_STRBUF_CAP\s+(\d+)'
$patternBootReadBuf = 'read_file\(name,\s*fbuf,\s*(\d+)\)'

function Get-Fact([string]$k) {
  if ($script:Facts.ContainsKey($k)) { return $script:Facts[$k] }
  $f = $null
  if ($k -eq 'version') { $f = Get-VersionFact }
  elseif ($k -eq 'src-files') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.(c|h)$' -ExcludeRx '\.bak' -Cmd 'Get-ChildItem src\*.c, src\*.h (excluding *.bak*)'
  }
  elseif ($k -eq 'src-loc') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.(c|h)$' -ExcludeRx '\.bak' -SumLf -Cmd 'sum of LF bytes in src\*.c + src\*.h (excluding *.bak*)'
  }
  elseif ($k -eq 'src-c-loc') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.c$' -ExcludeRx '\.bak' -SumLf -Cmd 'sum of LF bytes in src\*.c (excluding *.bak*)'
  }
  elseif ($k -eq 'src-c-bytes') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.c$' -ExcludeRx '\.bak' -SumBytes -Cmd 'sum of (Get-Item src\*.c).Length'
  }
  elseif ($k -eq 'src-h-loc') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.h$' -ExcludeRx '\.bak' -SumLf -Cmd 'sum of LF bytes in src\*.h (excluding *.bak*)'
  }
  elseif ($k -eq 'src-h-bytes') {
    $f = Get-CountFact -K $k -Dir 'src' -NameRx '\.h$' -ExcludeRx '\.bak' -SumBytes -Cmd 'sum of (Get-Item src\*.h).Length'
  }
  elseif ($k -eq 'test-samples') { $f = Get-CountFact -K $k -Dir 'test\samples' -NameRx '\.fl$' -Cmd 'Get-ChildItem test\samples\*.fl' }
  elseif ($k -eq 'test-corpus') { $f = Get-CountFact -K $k -Dir 'test' -NameRx '\.fl$' -Recurse -ExcludeDir 'tmp' -Cmd 'Get-ChildItem test -Recurse -Filter *.fl (excluding test\tmp\)' }
  elseif ($k -eq 'facts-probes') { $f = Get-CountFact -K $k -Dir 'test\facts' -NameRx '\.fl$' -Cmd 'Get-ChildItem test\facts\*.fl' }
  elseif ($k -eq 'probe-cases' -or $k -eq 'probe-ok' -or $k -eq 'probe-wall' -or $k -eq 'probe-gap') {
    $pc = Get-ProbeCounts
    $val = 0
    if ($k -eq 'probe-cases') { $val = $pc.Total }
    elseif ($k -eq 'probe-ok') { $val = $pc.Ok }
    elseif ($k -eq 'probe-wall') { $val = $pc.Wall }
    else { $val = $pc.Gap }
    $src = $script:ProbeRel + ' (case table: kind=ok/wall/gap, comment lines excluded)'
    $cmd = 'Select-String -Path ' + $script:ProbeRel + " -Pattern kind="
    $f = New-Fact $k ([string]$val) $src $cmd (Get-MTime $pc.Full)
  }
  elseif ($k -eq 'spec-principles') { $f = Get-SpecPrinciples }
  elseif ($k -eq 'spec-principles-sec') { $f = Get-SpecLineFact $k 'sec' }
  elseif ($k -eq 'spec-principles-first') { $f = Get-SpecLineFact $k 'first' }
  elseif ($k -eq 'spec-principles-last') { $f = Get-SpecLineFact $k 'last' }
  elseif ($k -eq 'gate-steps') {
    $gs = Get-GateSteps
    $src = $gs.Rel + ':' + $gs.Line + ' ($Only default array)'
    $cmd = 'Select-String -Path ' + $gs.Rel + ' -Pattern ' + [char]36 + 'Only'
    $f = New-Fact $k ([string]$gs.N) $src $cmd (Get-MTime $gs.Full)
  }
  elseif ($k -eq 'boot-verify') {
    # 与 regress / flgui-checks 同一口径：**只**从最新 boot 门日志读最近一次实跑的断言数。
    # boot\verify.ps1 在"不许跑"清单上 ⇒ 即使 -Slow 也不重跑，永远走日志。
    $f = Find-GateLogFact -K $k -NameRx 'boot' -SummaryRx '通过\s*(\d+)\s*/\s*失败\s*(\d+)' -Note 'boot\verify.ps1 is on the do-not-run list, so -Slow does NOT rerun it; run boot\verify.ps1 in a normal gate run (it logs to tmp\verify-all\boot.log)'
  }
  elseif ($k -eq 'boot-verify-items') {
    # 口径 = 脚本里**声明**的测试项，去重后计数（与上面那个"最近一次实跑断言数"是两件事，别混）。
    $bv = Get-BootVerify
    $src = $bv.Rel + ':128,297,345,365,405 (distinct DECLARED test items: $pos + $posSamples + negative lists + $diff)'
    $cmd = 'parse ' + $bv.Rel + ' ($pos/$posSamples tables + @() item arrays), then distinct-count'
    $f = New-Fact $k ([string]$bv.N) $src $cmd (Get-MTime $bv.Full)
  }
  elseif ($k -eq 'regress') {
    if ($Slow) {
      $rel = 'test\run-tests.js'
      $p = Join-Path $rootFull $rel
      if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('missing ' + $rel) }
      Push-Location $rootFull
      try { $out = & node $rel 2>&1 | Out-String } finally { Pop-Location }
      $ms = [regex]::Matches($out, '通过\s*(\d+)\s*/\s*失败\s*(\d+)')
      if ($ms.Count -eq 0) { throw ('NOT_COLLECTED: node ' + $rel + ' printed no summary line') }
      $last = $ms[$ms.Count - 1]
      $pass = [int]$last.Groups[1].Value
      $fail = [int]$last.Groups[2].Value
      $f = New-Fact $k ([string]$pass + '/' + [string]($pass + $fail)) ('node ' + $rel + ' (live run, -Slow)') ('node ' + $rel) (Get-NowStamp)
    } else {
      $f = Find-GateLogFact -K $k -NameRx 'regress' -SummaryRx '通过\s*(\d+)\s*/\s*失败\s*(\d+)' -Note 'run test\verify-all.ps1 -Only regress, or pass -Slow to run node test\run-tests.js now'
    }
  }
  elseif ($k -eq 'flgui-checks') {
    $f = Find-GateLogFact -K $k -NameRx 'flgui' -SummaryRx '通过\s*(\d+)\s*[｜|]\s*失败\s*(\d+)' -Note 'test\flgui-verify.ps1 is on the do-not-run list, so -Slow does NOT rerun it; run the FLGUI gate yourself and keep its log under tmp\'
  }
  elseif ($k -eq 'examples-passed') {
    # 慢键。日志摘要形如 "examples: 5/5 passed"（N of M）⇒ 值原样 N/M，**不能**按"通过 N / 失败 M"相加。
    $f = Find-GateLogFact -K $k -NameRx 'run-all' -SummaryRx 'examples:\s*(\d+)\s*/\s*(\d+)\s*passed' -AsIs -Note 'run examples\run-all.ps1 (it logs to tmp\examples\run-all.log); -Slow does NOT rerun it'
  }
  elseif ($k -eq 'strict-classes') { $f = Get-StrictClasses }
  elseif ($k -eq 'memory-flint-rows') { $f = Get-BoundaryFact $k '\[3\][^\n]*?速查行\s*(\d+)\s*行' '[3]' }
  elseif ($k -eq 'boundary-suspect-uncovered') { $f = Get-BoundaryFact $k '\[4\][^\n]*?记录\s*(\d+)\s*条' '[4]' }
  elseif ($k -eq 'imports-m2float') { $f = Get-ImportCountFact $k 'apps\m2_float\m2_float.exe' 'imports' }
  elseif ($k -eq 'modules-m2float') { $f = Get-ImportCountFact $k 'apps\m2_float\m2_float.exe' 'groups' }
  elseif ($k -eq 'imports-winpanel') { $f = Get-ImportCountFact $k 'apps\winpanel\winpanel.exe' 'imports' }
  elseif ($k -eq 'boot-occupied') { $f = Get-BootMeterFact $k 'occupied' }
  elseif ($k -eq 'boot-headroom') { $f = Get-BootMeterFact $k 'headroom' }
  elseif ($k -eq 'boot-limit') { $f = Get-BootMeterFact $k 'limit' }
  elseif ($k -eq 'limit-imports') { $f = Get-LimitFact -K $k -Rel 'src\pe.c' -Pattern $patternMaxImports -Label 'MAX_IMPORTS' -Cmd 'Select-String -Path src\pe.c -Pattern MAX_IMPORTS' }
  elseif ($k -eq 'limit-groups') { $f = Get-LimitFact -K $k -Rel 'src\pe.c' -Pattern $patternMaxGroups -Label 'MAX_GROUPS' -Cmd 'Select-String -Path src\pe.c -Pattern MAX_GROUPS' }
  elseif ($k -eq 'limit-dllname') { $f = Get-LimitFact -K $k -Rel 'src\pe.c' -Pattern $patternDllName -Label 'IMPORT_DLL_NAME_MAX' -Cmd 'Select-String -Path src\pe.c -Pattern IMPORT_DLL_NAME_MAX' }
  elseif ($k -eq 'limit-code') { $f = Get-LimitFact -K $k -Rel 'src\flint.h' -Pattern $patternMaxText -Label 'FLINT_MAX_TEXT' -Hex -Cmd 'Select-String -Path src\flint.h -Pattern FLINT_MAX_TEXT' }
  elseif ($k -eq 'limit-structfields') { $f = Get-LimitFact -K $k -Rel 'src\flint.h' -Pattern $patternFields -Label 'StructField fields[N]' -Cmd 'Select-String -Path src\flint.h -Pattern StructField' }
  elseif ($k -eq 'limit-funcargs') { $f = Get-LimitFact -K $k -Rel 'src\flint.h' -Pattern $patternFuncArgs -Label 'FUNC_MAX_ARGS' -Cmd 'Select-String -Path src\flint.h -Pattern FUNC_MAX_ARGS' }
  elseif ($k -eq 'limit-apiargs') { $f = Get-LimitFact -K $k -Rel 'src\flint.h' -Pattern $patternApiArgs -Label 'API_MAX_ARGS' -Cmd 'Select-String -Path src\flint.h -Pattern API_MAX_ARGS' }
  elseif ($k -eq 'limit-int32max') { $f = Get-Int32MaxFact }
  elseif ($k -eq 'limit-strbuf') { $f = Get-LimitFact -K $k -Rel 'src\flint.h' -Pattern $patternStrbuf -Label 'FLINT_STRBUF_CAP' -RequireUnique -Cmd 'Select-String -Path src\flint.h -Pattern FLINT_STRBUF_CAP' }
  elseif ($k -eq 'limit-boottable') { $f = Get-LimitFact -K $k -Rel 'boot\lib_parse.fl' -Pattern $patternNFuncs -Label 'nfuncs >= N' -Latin1 -RequireUnique -Cmd 'Select-String -Path boot\lib_parse.fl -Pattern nfuncs' }
  elseif ($k -eq 'limit-blockchildren') { $f = Get-LimitFact -K $k -Rel 'boot\lib_parse.fl' -Pattern $patternBlockKids -Label 'cnt >= N (single-block direct children; parse_block tmp[N])' -Latin1 -RequireUnique -Cmd 'Select-String -Path boot\lib_parse.fl -Pattern cnt' }
  elseif ($k -eq 'limit-constpool') { $f = Get-LimitFact -K $k -Rel 'boot\lib_parse.fl' -Pattern $patternSpool -Label 'spcur >= N' -Latin1 -RequireUnique -Cmd 'Select-String -Path boot\lib_parse.fl -Pattern spcur' }
  elseif ($k -eq 'limit-bootsrcbytes') { $f = Get-LimitFact -K $k -Rel 'boot\b1_emit.fl' -Pattern $patternBootSrc -Label 'src buffer bytes' -Latin1 -RequireUnique -Note 'the buffer holding the source AFTER include splicing; NOT the same as limit-bootreadbuf (that one is per-file)' -Cmd 'Select-String -Path boot\b1_emit.fl -Pattern VirtualAlloc' }
  elseif ($k -eq 'limit-bootreadbuf') { $f = Get-LimitFact -K $k -Rel 'boot\b1_emit.fl' -Pattern $patternBootReadBuf -Label 'read_file single-file buffer' -Latin1 -RequireUnique -Note 'reads ONE source file into fbuf (the VirtualAlloc that feeds it is 262144 too); this is a DIFFERENT thing from limit-bootsrcbytes = 524288, which is the POST-SPLICE buffer' -Cmd 'Select-String -Path boot\b1_emit.fl -Pattern read_file' }
  elseif ($k -eq 'limit-splicesize') { $f = Get-LimitFact -K $k -Rel 'boot\b1_emit.fl' -Pattern $patternSpliceCap -Label 'splice_file cap' -Latin1 -RequireUnique -Cmd 'Select-String -Path boot\b1_emit.fl -Pattern splice_file' }
  elseif ($k -eq 'app-winpanel-mainfl') { $f = Get-FactLinesBytes $k 'apps\winpanel\main.fl' '(Get-Item apps\winpanel\main.fl) + LF count' }
  elseif ($k -eq 'app-m2float-mainfl') { $f = Get-FactLinesBytes $k 'apps\m2_float\main.fl' '(Get-Item apps\m2_float\main.fl) + LF count' }
  elseif ($k -eq 'app-m2float-allfl') { $f = Get-FactSetLinesBytes -K $k -Dir 'apps\m2_float' -NameRx '\.fl$' -Cmd 'Get-ChildItem apps\m2_float\*.fl  -> sum lines(LF) / sum bytes' }
  elseif ($k -eq 'app-uigallery-mainfl') { $f = Get-FactLinesBytes $k 'apps\ui_gallery\main.fl' '(Get-Item apps\ui_gallery\main.fl) + LF count' }
  elseif ($k -eq 'app-winpanel-verifypanel-loc') { $f = Get-FactLinesOnly $k 'apps\winpanel\verify-panel.ps1' 'LF (0x0A) count of apps\winpanel\verify-panel.ps1' }
  elseif ($k -eq 'app-winpanel-验收-loc') { $f = Get-FactLinesOnly $k 'apps\winpanel\验收.md' 'LF (0x0A) count of apps\winpanel\验收.md' }
  elseif ($k -eq 'lib-flgui-win32') { $f = Get-FactLinesBytes $k 'lib\flgui_win32.fl' '(Get-Item lib\flgui_win32.fl).Length + count of LF (0x0A)' }
  elseif ($k -eq 'lib-flgui') { $f = Get-FactLinesBytes $k 'lib\flgui.fl' '(Get-Item lib\flgui.fl).Length + count of LF (0x0A)' }
  elseif ($k -eq 'lib-ui-lib') { $f = Get-FactLinesBytes $k 'lib\ui_lib.fl' '(Get-Item lib\ui_lib.fl).Length + count of LF (0x0A)' }
  elseif ($k -eq 'lang-en-bytes') { $f = Get-FactBytes $k 'apps\winpanel\lang.en.txt' '(Get-Item apps\winpanel\lang.en.txt).Length' }
  elseif ($k -eq 'lang-zh-bytes') { $f = Get-FactBytes $k 'apps\winpanel\lang.zh.txt' '(Get-Item apps\winpanel\lang.zh.txt).Length' }
  elseif ($k -eq 'img-winpanel-px') { $f = Get-ImagePxFact $k 'docs\图片\winpanel-面板.png' 'read the PNG IHDR bytes 16..23 of docs\图片\winpanel-面板.png' }
  elseif ($k -eq 'img-winpanel-bytes') { $f = Get-ImageBytesFact $k 'docs\图片\winpanel-面板.png' '(Get-Item docs\图片\winpanel-面板.png).Length' }
  elseif ($k -eq 'img-uigallery-px') { $f = Get-ImagePxFact $k 'docs\图片\ui_gallery-控件.png' 'read the PNG IHDR bytes 16..23 of docs\图片\ui_gallery-控件.png' }
  elseif ($k -eq 'img-uigallery-bytes') { $f = Get-ImageBytesFact $k 'docs\图片\ui_gallery-控件.png' '(Get-Item docs\图片\ui_gallery-控件.png).Length' }
  elseif ($k -eq 'img-m2float-px') { $f = Get-ImagePxFact $k 'docs\图片\m2_float-浮窗.png' 'read the PNG IHDR bytes 16..23 of docs\图片\m2_float-浮窗.png' }
  elseif ($k -eq 'img-m2float-bytes') { $f = Get-ImageBytesFact $k 'docs\图片\m2_float-浮窗.png' '(Get-Item docs\图片\m2_float-浮窗.png).Length' }
  elseif ($k -eq 'img-winpanel-totalpx') { $f = Get-ImageTotalPxFact $k 'docs\图片\winpanel-面板.png' 'read the PNG IHDR bytes 16..23 of docs\图片\winpanel-面板.png, then multiply W x H' }
  elseif ($k -eq 'img-uigallery-totalpx') { $f = Get-ImageTotalPxFact $k 'docs\图片\ui_gallery-控件.png' 'read the PNG IHDR bytes 16..23 of docs\图片\ui_gallery-控件.png, then multiply W x H' }
  elseif ($k -eq 'img-m2float-totalpx') { $f = Get-ImageTotalPxFact $k 'docs\图片\m2_float-浮窗.png' 'read the PNG IHDR bytes 16..23 of docs\图片\m2_float-浮窗.png, then multiply W x H' }
  elseif ($k -eq 'img-winpanel-nonbg') { $f = Get-ImageNonBgFact $k 'winpanel' }
  elseif ($k -eq 'img-uigallery-nonbg') { $f = Get-ImageNonBgFact $k 'uigallery' }
  elseif ($k -eq 'img-m2float-nonbg') { $f = Get-ImageNonBgFact $k 'm2float' }
  elseif ($k -eq 'img-winpanel-nonbg-pct') { $f = Get-ImageNonBgPctFact $k 'winpanel' }
  elseif ($k -eq 'img-uigallery-nonbg-pct') { $f = Get-ImageNonBgPctFact $k 'uigallery' }
  elseif ($k -eq 'img-m2float-nonbg-pct') { $f = Get-ImageNonBgPctFact $k 'm2float' }
  elseif ($k -eq 'win-winpanel-px') {
    $f = Get-WinSizeFromTwoConsts -K $k -Rel 'apps\winpanel\main.fl' -RxW 'int\s+WP_W\s*=\s*(\d+)\s*;' -RxH 'int\s+WP_H\s*=\s*(\d+)\s*;' -LabelW 'WP_W' -LabelH 'WP_H' -Cmd 'Select-String -Path apps\winpanel\main.fl -Pattern WP_W, WP_H'
  }
  elseif ($k -eq 'win-uigallery-px') {
    $f = Get-WinSizeFromTwoConsts -K $k -Rel 'apps\ui_gallery\main.fl' -RxW 'win\.w\s*=\s*(\d+)\s*;' -RxH 'win\.h\s*=\s*(\d+)\s*;' -LabelW 'win.w' -LabelH 'win.h' -Cmd 'Select-String -Path apps\ui_gallery\main.fl -Pattern "win.w|win.h"'
  }
  elseif ($k -eq 'test-loop-verify-loc') { $f = Get-FactLinesOnly $k 'test\loop-verify.ps1' 'count of LF (0x0A) in test\loop-verify.ps1' }
  elseif ($k -eq 'checks-panel') { $f = Get-ChecksPanel }
  elseif ($k -eq 'product-flint') {
    $note = (Get-FlintIgnoreNote) + '; ' + (Get-FlintRebuildNote) + ' => the number changes on every rebuild'
    $f = Get-ProductFact $k 'flint.exe' $note
  }
  elseif ($k -eq 'product-flint-sha16') {
    $note = (Get-FlintIgnoreNote) + '; ' + (Get-FlintRebuildNote) + ' => the hash changes on every rebuild'
    $f = Get-ProductShaFact $k 'flint.exe' $note
  }
  elseif ($k -eq 'product-hello') { $f = Get-ProductFact $k 'examples\hello\hello.exe' }
  elseif ($k -eq 'product-window') { $f = Get-ProductFact $k 'examples\window\window.exe' }
  elseif ($k -eq 'product-winpanel') { $f = Get-ProductFact $k 'apps\winpanel\winpanel.exe' }
  elseif ($k -eq 'product-m2float') { $f = Get-ProductFact $k 'apps\m2_float\m2_float.exe' }
  elseif ($k -eq 'product-uigallery') { $f = Get-ProductFact $k 'apps\ui_gallery\ui_gallery.exe' }
  elseif ($k -eq 'product-student') { $f = Get-ProductFact $k 'apps\student\student.exe' }
  elseif ($k -eq 'product-winpanel-sha16') { $f = Get-ProductShaFact $k 'apps\winpanel\winpanel.exe' (Get-ProductBuildNote 'not-reproducible') }
  elseif ($k -eq 'product-hello-sha16') { $f = Get-ProductShaFact $k 'examples\hello\hello.exe' (Get-ProductBuildNote 'reproducible') }
  elseif ($k -eq 'product-uigallery-sha16') { $f = Get-ProductShaFact $k 'apps\ui_gallery\ui_gallery.exe' (Get-ProductBuildNote 'not-reproducible') }
  elseif ($k -eq 'selfhost-shas') { $f = Get-SelfHostFact }
  else { throw ('unknown key: ' + $k) }
  if ($null -eq $f) { throw ('no fact produced for key: ' + $k) }
  $script:Facts[$k] = $f
  return $f
}

# ------------------------------------------------------------------ 谁引用我
# 一次扫完仓库根 *.md 与 docs\*.md，把 <!--fact:键--> 标记按键归档（别每个键重扫一遍）。
function Get-AllRefs {
  $map = @{}
  # 键名允许非 ASCII（例：app-winpanel-验收-loc），所以字符类不能写成 [A-Za-z0-9_-]；
  # 但也不能跨空白，否则本台账头部那行"`<!--fact:` + 键 + `-->`"的说明文字会被当成引用。
  $rx = '<!--fact:\s*([^>\s]+?)\s*-->'
  $globs = @((Join-Path $rootFull '*.md'), (Join-Path $rootFull 'docs\*.md'))
  foreach ($g in $globs) {
    foreach ($h in @(Select-String -Path $g -Pattern $rx -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      foreach ($km in [regex]::Matches($h.Line, $rx)) {
        $k = $km.Groups[1].Value
        if ($k -eq '') { continue }
        if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.ArrayList }
        [void]$map[$k].Add((Get-Rel $h.Path) + ':' + $h.LineNumber)
      }
    }
  }
  return $map
}
function Get-RefsText($map, [string]$k) {
  if ($null -eq $map) { return '（暂无引用）' }
  if (-not $map.ContainsKey($k)) { return '（暂无引用）' }
  $list = @($map[$k] | Sort-Object)
  if ($list.Count -eq 0) { return '（暂无引用）' }
  return ($list -join ' ')
}

# ------------------------------------------------------------------ 取全部键（失败不吞）
function Get-AllFacts {
  $list = New-Object System.Collections.ArrayList
  $failed = New-Object System.Collections.ArrayList
  foreach ($k in $script:KeyOrder) {
    try {
      [void]$list.Add((Get-Fact $k))
    } catch {
      $msg = $_.Exception.Message
      [void]$failed.Add($k + ': ' + $msg)
      [void]$list.Add((New-Fact $k 'NOT_COLLECTED' ('NOT_COLLECTED -- ' + $msg) '-' ''))
    }
  }
  return [pscustomobject]@{ Facts = @($list); Failed = @($failed) }
}

# ------------------------------------------------------------------ 台账
function Write-Ledger([object[]]$facts, [string]$stamp) {
  $rel = $script:LedgerRel
  $full = Join-Path $rootFull $rel
  $dir = Split-Path -Parent $full
  if (-not (Test-Path -LiteralPath $dir)) { throw ('missing docs directory: ' + $dir) }
  $refMap = Get-AllRefs
  $cmdLine = 'powershell -NoProfile -ExecutionPolicy Bypass -File tools\文档事实.ps1 -Ledger'
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# 数字台账')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('> **机器生成，不许手改。**')
  [void]$sb.AppendLine('>')
  [void]$sb.AppendLine('> 生成命令：`' + $cmdLine + '`')
  [void]$sb.AppendLine('>')
  [void]$sb.AppendLine('> 生成时间：' + $stamp + '（= 每一行的「最后复核」）')
  [void]$sb.AppendLine('>')
  [void]$sb.AppendLine('> 本表由 `tools\文档事实.ps1` 从**真值源**现场算出：每个键要么 grep 守卫行／数文件／跑只读仪器，')
  [void]$sb.AppendLine('> 要么从**最新门日志**取摘要。脚本里没有写死任何数字，上限也必须 grep 出来并带 `文件:行`。')
  [void]$sb.AppendLine('> 慢键（`regress` / `flgui-checks` / `boot-verify` / `examples-passed`）默认不跑重活；取不到时 exit 2 且不填绿数。')
  [void]$sb.AppendLine('>')
  [void]$sb.AppendLine('> 引用约定：文档里写 `<!--fact:` + 键 + `-->` 即声明「我引用了这个键」，')
  [void]$sb.AppendLine('> `-Ledger` 会用 Select-String 扫仓库根 `*.md` 与 `docs\*.md` 把引用点列进「谁引用我」。')
  [void]$sb.AppendLine('>')
  [void]$sb.AppendLine('> `-List` / `-Key` / stderr 的输出是**纯 ASCII**（门要调它），真值源里的中文文件名转义成')
  [void]$sb.AppendLine('> **字面文本** `\uXXXX`；`-Json` 用的是**真 JSON 转义**（磁盘字节同样纯 ASCII，但 `ConvertFrom-Json`')
  [void]$sb.AppendLine('> 解出来是**真中文**路径）；本 .md 是给人看的，保留真实中文。')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| 键 | 现值 | 真值源 | 取数命令 | 谁引用我 | 最后复核 |')
  [void]$sb.AppendLine('|---|---|---|---|---|---|')
  foreach ($f in $facts) {
    $cells = @($f.key, $f.value, $f.source, $f.command, (Get-RefsText $refMap $f.key), $stamp)
    $esc = @()
    foreach ($c in $cells) {
      $t = [string]$c
      $t = $t.Replace('|', '\|')
      $t = $t.Replace("`r", ' ').Replace("`n", ' ')
      $esc += $t
    }
    [void]$sb.AppendLine('| ' + ($esc -join ' | ') + ' |')
  }
  [void]$sb.AppendLine('')
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($full, $sb.ToString(), $utf8)
  return $full
}

# ------------------------------------------------------------------ 主流程
$modes = 0
if ($Key -ne '') { $modes = $modes + 1 }
if ($List) { $modes = $modes + 1 }
if ($Json) { $modes = $modes + 1 }
if ($Ledger) { $modes = $modes + 1 }
$thisRel = 'tools\' + (Split-Path -Leaf $MyInvocation.MyCommand.Path)
if ($modes -eq 0) {
  [Console]::Error.WriteLine('usage: powershell -NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-AsciiSafe $thisRel) + ' (-Key <key> | -List | -Json | -Ledger) [-Slow]')
  exit 2
}

if ($Key -ne '') {
  if ($script:KeyOrder -notcontains $Key) {
    [Console]::Error.WriteLine('unknown key: ' + (ConvertTo-AsciiSafe $Key))
    [Console]::Error.WriteLine('known keys: ' + ($script:KeyOrder -join ' '))
    exit 2
  }
  $fact = $null
  try {
    $fact = Get-Fact $Key
  } catch {
    [Console]::Error.WriteLine('NOT_COLLECTED [' + $Key + ']: ' + (ConvertTo-AsciiSafe $_.Exception.Message))
    exit 2
  }
  if ($fact.value -eq 'NOT_COLLECTED') {
    [Console]::Error.WriteLine('NOT_COLLECTED [' + $Key + ']: ' + (ConvertTo-AsciiSafe $fact.source))
    exit 2
  }
  $line = ConvertTo-AsciiSafe $fact.value
  Assert-Ascii $line 'value'
  [Console]::Out.WriteLine($line)
  exit 0
}

$all = Get-AllFacts
$stamp = Get-NowStamp

if ($List) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('key | value | source')
  foreach ($f in $all.Facts) {
    [void]$sb.AppendLine((ConvertTo-AsciiSafe $f.key) + ' | ' + (ConvertTo-AsciiSafe $f.value) + ' | ' + (ConvertTo-AsciiSafe $f.source))
  }
  $txt = $sb.ToString()
  Assert-Ascii $txt 'list'
  [Console]::Out.Write($txt)
}

if ($Json) {
  $txt = Build-JsonText -facts $all.Facts
  Assert-Ascii $txt 'json'
  [Console]::Out.WriteLine($txt)
}

if ($Ledger) {
  $full = Write-Ledger -facts $all.Facts -stamp $stamp
  [Console]::Out.WriteLine('LEDGER_WRITTEN rows=' + $all.Facts.Count + ' at=' + (ConvertTo-AsciiSafe (Get-Rel $full)))
}

if ($all.Failed.Count -gt 0) {
  foreach ($m in $all.Failed) { [Console]::Error.WriteLine('NOT_COLLECTED ' + (ConvertTo-AsciiSafe $m)) }
  exit 2
}
exit 0
