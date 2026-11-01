# debug-verify.ps1 -- gate for the -debug audit layer (task card T-20260917-223210).
# ASCII-only on purpose (Chinese text in .ps1 needs a UTF-8 BOM, and edit/write tools keep
# eating it -- see memory note "the edit tool eats the BOM"). English comments/format strings only.
#
# What it proves, per sample:
#   [1] three channels agree: objdump --dwarf=decodedline rows == our own TSV rows
#       (same address, same line, same file basename) -- machine comparison, no eyeballing;
#   [2] addr2line maps every TSV address back to the recorded line;
#   [3] the -debug product still runs and its exit code equals the plain product's;
#   [4] with the switch OFF the product's *shape* matches the pre-change compiler: same loaded section
#       set + same VAs + same exit code, and the only intended delta is the declared DllCharacteristics
#       (v1.4.14 ASLR round: baseline 0x0100 -> new 0x0160). Use a baseline from the round BEFORE this
#       one (flint_before_aslr.exe), otherwise the dllchars delta check fails by design.
#
#   [7] v5 (2026-10-21, D-2): with -debug the slot->register residency must be OFF (a debugger would
#       otherwise read stale frame slots). Judge = `-debug -stats` reports 0 register slots.
#   [8] v5 (2026-10-21, D-1 + D-3): the THIRD debug artifact <out>.dbg.json -- frame table + variable
#       location table. Nine assertions per sample: (1) version 1 + parseable; (2) every function
#       range inside .text and ascending; (3) frame.size == objdump's `sub $imm,%rsp`; (4) savedRegs /
#       pushBytes == objdump's callee-saved push sequence; (5) var count + name set == the declarations
#       counted from the SOURCE by regex (independent judge); (6) slots inside the frame and unique;
#       (7) type/kind/line well-formed (whitelist regex); (8) recompiling reproduces the file (SHA256);
#       (9) no .dbg.json when the switch is OFF.
#
# and once, on a dedicated sample:
#   [6] v1.4.16 (task card T-20260918-012105): control-statement CONDITION bytes carry their OWN
#       source line. DWARF rows mean "from this address on, line = X", so before this round the
#       condition bytes of if/while/for fell inside the PREVIOUS statement's row and addr2line
#       blamed the line before the control statement (measured: `if (a < b)` on line 9 was
#       reported as line 8). Checked on test\samples\dbgcond.fl: every `cmp` instruction must
#       resolve to a line that really opens a control statement in that source -- the expected
#       line set is derived from the sample itself, not hardcoded.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\debug-verify.ps1
#   powershell ... -File test\debug-verify.ps1 -BaselineExe .\archive\exe\flint_before_aslr.exe
# 2026-10-20: the run-behaviour sample is api2.fl (kernel32 GetTickCount), NOT api1.fl.
#   api1 pops a MessageBoxA: the window steals the foreground from whatever the user is doing, and
#   it blocks until the 8 s timeout, so the plain/debug exit codes depended on which dialog got
#   dismissed first (intermittent false red). api1 keeps its compile + import-table checks in
#   test\run-tests.js; gate the RUN path on a non-UI sample.
param(
  [string[]]$Samples = @('ctrl1.fl','comp1.fl','st1.fl','arr1.fl','api2.fl','dbgcond.fl'),
  [string]$BaselineExe = '',
  [string]$Objdump = 'E:\mingw64\bin\objdump.exe',
  [string]$Addr2line = 'E:\mingw64\bin\addr2line.exe'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$flint = Join-Path $root 'hlc.exe'
$tmp = Join-Path $root 'tmp\debug-gate'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$pass = 0; $fail = 0
function Ok($m) { Write-Host "  OK   $m"; $script:pass++ }
function Bad($m) { Write-Host "  FAIL $m"; $script:fail++ }

# section table straight out of the product bytes (used by the [4] shape checks)
function Get-SecInfo($exe) {
  $b = [IO.File]::ReadAllBytes($exe)
  $lf = [BitConverter]::ToUInt32($b, 0x3C)
  $coff = $lf + 4
  $nsec = [BitConverter]::ToUInt16($b, $coff + 2)
  $optsz = [BitConverter]::ToUInt16($b, $coff + 16)
  $sec = $coff + 20 + $optsz
  $out = @()
  for ($i = 0; $i -lt $nsec; $i++) {
    $o = $sec + $i * 40
    $out += [pscustomobject]@{
      Name  = [Text.Encoding]::ASCII.GetString($b, $o, 8).TrimEnd([char]0)
      VA    = [BitConverter]::ToUInt32($b, $o + 12)
      Chars = [BitConverter]::ToUInt32($b, $o + 36)
    }
  }
  return $out
}

function Parse-DecodedLine($exe) {
  $out = & $Objdump --dwarf=decodedline $exe 2>$null
  $rows = @()
  foreach ($l in $out) {
    if ($l -match '^\s*(\S.*?)\s+(\d+)\s+0x([0-9a-fA-F]+)\s') {
      $rows += [pscustomobject]@{
        file = [IO.Path]::GetFileName($matches[1])
        line = [int]$matches[2]
        addr = [Convert]::ToUInt64($matches[3], 16)
      }
    }
  }
  return $rows
}

function Parse-Tsv($path) {
  $rows = @()
  foreach ($l in (Get-Content $path -Encoding UTF8)) {
    if ($l.StartsWith('#')) { continue }
    if ($l.StartsWith('src_file')) { continue }
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $f = $l -split "`t"
    if ($f.Count -lt 7) { continue }
    $rows += [pscustomobject]@{
      file = [IO.Path]::GetFileName($f[0])
      line = [int]$f[1]
      addr = [Convert]::ToUInt64(($f[4] -replace '^0x', ''), 16)
      llen = [int]$f[6]
    }
  }
  return $rows
}

# instruction boundaries from objdump -d (the TSV "byte range" column is the dimension
# DWARF does NOT provide, so it has to be checked against the disassembler, not against itself)
function Parse-Instructions($exe) {
  $ins = @()
  foreach ($l in (& $Objdump -d $exe 2>$null)) {
    if ($l -match '^\s*([0-9a-fA-F]+):\s+((?:[0-9a-fA-F]{2} )+)\s') {
      $bytes = ($matches[2].Trim() -split '\s+')
      $ins += [pscustomobject]@{
        addr = [Convert]::ToUInt64($matches[1], 16)
        len  = $bytes.Count
      }
    }
  }
  return $ins
}

# ===== v5 (2026-10-21) D-1 + D-3: `-debug` writes a THIRD debug artifact, <out>.dbg.json =====
# It carries what neither DWARF leg has: the FRAME layout (this repo's PE has no .pdata, so Windows'
# StackWalk64 cannot be used -- a debugger has to walk frames by hand) and the frame SLOT of every
# local/parameter (the DWARF leg is a line table only: no variable DIEs). Format = JSON, version 1.
# The checks below compare it against INDEPENDENT judges only:
#   * objdump -h / -d  (section range, `sub $imm,%rsp`, the callee-saved push sequence)
#   * the sample source (declaration count/name set, recomputed by regex, never hardcoded)
#   * recompiling the same file (SHA256 determinism) and compiling WITHOUT -debug (no side file)

# .text range straight from the disassembler's section table
function Get-TextSection($exe) {
  foreach ($l in (& $Objdump -h $exe 2>$null)) {
    if ($l -match '^\s*\d+\s+\.text\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s') {
      return [pscustomobject]@{
        Size = [Convert]::ToUInt64($matches[1], 16)
        VMA  = [Convert]::ToUInt64($matches[2], 16)
      }
    }
  }
  return $null
}

# instruction stream with mnemonic + operands (the frame checks need the operands, not just lengths)
function Parse-Disasm($exe) {
  $rows = @()
  foreach ($l in (& $Objdump -d $exe 2>$null)) {
    if ($l -match '^\s*([0-9a-fA-F]+):\s+((?:[0-9a-fA-F]{2} )+)\s+([a-z][a-z0-9.]*)\s*(.*)$') {
      $rows += [pscustomobject]@{
        addr = [Convert]::ToUInt64($matches[1], 16)
        op   = $matches[3]
        arg  = $matches[4].Trim()
      }
    }
  }
  return $rows
}

# Independent judge: every "type name" declaration inside one function, counted from the SOURCE.
# Params come from the signature parens, locals from the body text (brace-matched, so a top-level
# `struct Point { int x; ... }` definition is never mistaken for a local declaration).
function Get-SourceDecls($path, $func) {
  $txt = [IO.File]::ReadAllText($path)
  $typeRe = '(?:int_32|int_64|uint_8|uint_32|uint_64|int|char|double|struct\s+[A-Za-z_]\w*)'
  $sig = [regex]::Match($txt, '(?m)^\s*' + $typeRe + '\s*\*?\s*' + [regex]::Escape($func) + '\s*\(([^)]*)\)\s*\{')
  if (-not $sig.Success) { return $null }
  $bodyStart = $sig.Index + $sig.Length - 1
  $depth = 0; $end = -1
  for ($i = $bodyStart; $i -lt $txt.Length; $i++) {
    $ch = $txt[$i]
    if ($ch -eq '{') { $depth++ }
    elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
  }
  if ($end -lt 0) { return $null }
  $body = $txt.Substring($bodyStart, $end - $bodyStart + 1)
  $names = @()
  $params = $sig.Groups[1].Value
  if (-not [string]::IsNullOrWhiteSpace($params)) {
    foreach ($pdec in ($params -split ',')) {
      $pm = [regex]::Match($pdec, $typeRe + '\s*\*{0,2}\s*([A-Za-z_]\w*)')
      if ($pm.Success) { $names += $pm.Groups[1].Value }
    }
  }
  foreach ($m in [regex]::Matches($body, '(?m)(?:^|[({;,])\s*' + $typeRe + '\s*(\*{0,2})\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:=|;|,|\))')) {
    $names += $m.Groups[2].Value
  }
  return @($names)
}

# function names DEFINED in the source (top level): type, optional '*', name, '(' ... ')' '{'
function Get-SourceFuncNames($path) {
  $txt = [IO.File]::ReadAllText($path)
  $typeRe = '(?:void|int_32|int_64|uint_8|uint_32|uint_64|int|char|double|struct\s+[A-Za-z_]\w*)'
  $out = @()
  foreach ($m in [regex]::Matches($txt, '(?m)^\s*' + $typeRe + '\s*\*?\s*([A-Za-z_]\w*)\s*\([^)]*\)\s*\{')) {
    $out += $m.Groups[1].Value
  }
  return @($out)
}

Push-Location $root
foreach ($s in $Samples) {
  $src = Join-Path $root "test\samples\$s"
  if (-not (Test-Path $src)) { Bad "$s (sample missing)"; continue }
  $plain = Join-Path $tmp "p_$s.exe"
  $dbg   = Join-Path $tmp "d_$s.exe"
  $tsv   = "$dbg.tsv"
  $map   = "$dbg.dbg.json"
  Remove-Item $plain, $dbg, $tsv, $map, "$plain.dbg.json" -ErrorAction SilentlyContinue

  & $flint $src -o $plain *>$null
  & $flint -debug $src -o $dbg *>$null
  if (-not (Test-Path $dbg)) { Bad "$s : -debug compile produced no exe"; continue }
  if (-not (Test-Path $tsv)) { Bad "$s : no TSV written"; continue }

  $od = Parse-DecodedLine $dbg
  $tv = Parse-Tsv $tsv
  if ($tv.Count -eq 0) { Bad "$s : TSV has no rows"; continue }

  # [1] same row set (address + line + file basename), order included
  $mismatch = 0
  if ($od.Count -ne $tv.Count) { $mismatch++ }
  $n = [Math]::Min($od.Count, $tv.Count)
  for ($i = 0; $i -lt $n; $i++) {
    if ($od[$i].addr -ne $tv[$i].addr -or $od[$i].line -ne $tv[$i].line -or $od[$i].file -ne $tv[$i].file) { $mismatch++ }
  }
  if ($mismatch -eq 0) { Ok "$s : objdump rows == TSV rows ($($tv.Count) rows, address+line+file)" }
  else { Bad "$s : objdump/TSV mismatch (objdump=$($od.Count) tsv=$($tv.Count) bad=$mismatch)" }

  # [2] addr2line round-trip on every recorded address
  $bad = 0
  foreach ($r in $tv) {
    $hex = '0x{0:X}' -f $r.addr
    $a = & $Addr2line -f -C -e $dbg $hex 2>$null
    $loc = ($a | Select-Object -Last 1)
    if ($loc -notmatch ":(\d+)$" -or [int]$matches[1] -ne $r.line) { $bad++ }
  }
  if ($bad -eq 0) { Ok "$s : addr2line resolved all $($tv.Count) addresses to the recorded line" }
  else { Bad "$s : addr2line disagreed on $bad of $($tv.Count) addresses" }

  # [5] the private-leg dimension: every TSV byte range must be exactly covered by whole
  #     instructions (never split an instruction). This is what DWARF cannot express.
  $ins = Parse-Instructions $dbg
  $splits = 0
  foreach ($r in $tv) {
    $end = $r.addr + $r.llen
    $cover = 0
    foreach ($i in $ins) {
      if ($i.addr -ge $r.addr -and $i.addr -lt $end) { $cover += $i.len }
    }
    if ($cover -ne $r.llen) { $splits++ }
  }
  if ($splits -eq 0) { Ok "$s : every TSV byte range is exactly whole instructions (vs objdump -d)" }
  else { Bad "$s : $splits TSV byte range(s) do not align with instruction boundaries" }

  # [3] behaviour unchanged with the switch ON
  $e1 = $null; $e2 = $null
  if (Test-Path $plain) {
    $p1 = Start-Process -FilePath $plain -PassThru -WindowStyle Hidden
    if ($p1.WaitForExit(8000)) { $e1 = $p1.ExitCode } else { try { $p1.Kill() } catch {}; $e1 = 'timeout' }
  }
  $p2 = Start-Process -FilePath $dbg -PassThru -WindowStyle Hidden
  if ($p2.WaitForExit(8000)) { $e2 = $p2.ExitCode } else { try { $p2.Kill() } catch {}; $e2 = 'timeout' }
  if ("$e1" -eq "$e2") { Ok "$s : exit code unchanged with -debug (both $e2)" }
  else { Bad "$s : exit differs plain=$e1 debug=$e2" }

  # [7] v5（2026-10-21，D-2）：-debug 必须关掉寄存器驻留。否则帧槽在函数中段是旧值，
  #     调试器读变量会系统性读错（比没有接口更危险）。判据 = -stats 里"寄存器槽 0"。
  $stExe = Join-Path $tmp "s_$s.exe"
  Remove-Item $stExe -ErrorAction SilentlyContinue
  $stOut = (& $flint -debug -stats $src -o $stExe 2>&1) | Out-String
  $mrg = [regex]::Match($stOut, '寄存器槽\s*(\d+)')
  if (-not $mrg.Success) { Bad "$s : -debug -stats did not print the register-slot count" }
  elseif ([int]$mrg.Groups[1].Value -ne 0) { Bad "$s : -debug still keeps $($mrg.Groups[1].Value) register slot(s) (a debugger would read stale frame slots)" }
  else { Ok "$s : -debug disables register residency (0 register slots)" }
  Remove-Item $stExe -ErrorAction SilentlyContinue
  # [4] switch OFF must not change the product's *shape* versus the baseline compiler.
  #     v1.4.13: the old "byte-identical" wording was retired ON PURPOSE -- that round moved the IAT into
  #     its own `.idata` section, i.e. it intentionally rewrote every product. The duty "every difference
  #     must be explainable" now lives in test\wx-verify.ps1 item [2]. What must still hold here:
  #       (a) with -debug OFF there is no long-named (debug) section at all;
  #       (b) loaded sections keep their VA;
  #       (c) behaviour (exit code) is unchanged;
  #       (d) the loaded section SET is identical to the baseline's (v1.4.14: the round before asserted
  #           "one more section than baseline (.idata)"; ASLR adds no section, so the check is now
  #           "same sections" -- with -BaselineExe pointing at flint_before_wx.exe the delta assertion
  #           would legitimately fail, hence the baseline for this gate is flint_before_aslr.exe);
  #       (e) v1.4.14: the ONLY product difference is the declared DllCharacteristics -- baseline ships
  #           the legacy NX-only form (0x0100), the new one must ship the ASLR form (0x0160).
  #           NOTE the field's file offset here is 0x9E = opt + 0x46 with opt = e_lfanew + 24 = 0x58,
  #           which IS the PE32+ SPEC offset: the optional header writes the OS/Image/Subsystem version
  #           block at opt+0x28..0x37, so nothing is shifted. (The 2026-09-18 v1.4.14 note claiming a
  #           0x18-byte shift and a "textbook 0x5E" was wrong -- re-measured on four product forms with
  #           objdump -p as an independent reader; see src\pe.c's I20 block and test\wx-verify.ps1 [7a].)
  if ($BaselineExe -and (Test-Path $BaselineExe)) {
    $base = Join-Path $tmp "b_$s.exe"
    Remove-Item $base -ErrorAction SilentlyContinue
    & $BaselineExe $src -o $base *>$null
    if ((Test-Path $base) -and (Test-Path $plain)) {
      $sn = Get-SecInfo $plain
      $longNames = @($sn | Where-Object { $_.Name -like '/*' })
      if ($longNames.Count -eq 0) { Ok "$s : -debug OFF emits no long-named (debug) section" }
      else { Bad "$s : -debug OFF still emits $($longNames.Count) long-named section(s)" }
      $sb = Get-SecInfo $base
      $sbLoaded = @($sb | Where-Object { $_.Name -notlike '/*' })
      $vaOk = $true
      foreach ($x in $sbLoaded) {
        if ($x.Chars -band 0x02000000) { continue }
        $y = $sn | Where-Object { $_.Name -eq $x.Name }
        if (-not $y -or $y.VA -ne $x.VA) { $vaOk = $false }
      }
      if ($vaOk) { Ok "$s : loaded sections keep their VA vs baseline" } else { Bad "$s : a loaded section moved" }
      $setNew = (@($sn | ForEach-Object { $_.Name }) | Sort-Object) -join ','
      $setOld = (@($sbLoaded | ForEach-Object { $_.Name }) | Sort-Object) -join ','
      if ($setNew -eq $setOld) { Ok "$s : loaded section set unchanged vs baseline ($setNew)" }
      else { Bad "$s : loaded section set changed new=$setNew base=$setOld" }
      # (e) the round's intended delta: DllCharacteristics 0x0100 (baseline) -> 0x0160 (ASLR form)
      $bn = [IO.File]::ReadAllBytes($plain); $bo = [IO.File]::ReadAllBytes($base)
      $dcNew = [BitConverter]::ToUInt16($bn, 0x9E); $dcOld = [BitConverter]::ToUInt16($bo, 0x9E)
      if ($dcNew -eq 0x0160) { Ok "$s : product declares the ASLR form (dllchars=0x0160)" }
      else { Bad "$s : dllchars is 0x$('{0:X4}' -f $dcNew), expected 0x0160" }
      if ($dcOld -ne $dcNew) { Ok "$s : baseline differs exactly there (baseline dllchars=0x$('{0:X4}' -f $dcOld))" }
      else { Bad "$s : baseline has the same DllCharacteristics (0x$('{0:X4}' -f $dcOld)) -- wrong baseline exe?" }
      $pb = Start-Process -FilePath $base -PassThru -WindowStyle Hidden
      if ($pb.WaitForExit(8000)) { $eb = $pb.ExitCode } else { try { $pb.Kill() } catch {}; $eb = 'timeout' }
      if ("$eb" -eq "$e1") { Ok "$s : baseline product exits the same ($eb)" }
      else { Bad "$s : baseline exit differs base=$eb plain=$e1" }
    }
  }

  # ================= [8] v5 (2026-10-21) D-1 + D-3: <out>.dbg.json =================
  # Nine assertions per sample. Every expected value comes from an independent judge
  # (objdump / the sample source / a second compile), never from the JSON itself.
  $j = $null
  $mapOk = $false
  if (-not (Test-Path $map)) {
    Bad "$s : [8.1] -debug wrote no .dbg.json beside the product"
  } else {
    try {
      $j = (Get-Content $map -Raw -Encoding UTF8) | ConvertFrom-Json
      $mapOk = $true
    } catch {
      Bad "$s : [8.1] .dbg.json is not valid JSON -- $($_.Exception.Message)"
    }
  }

  if ($mapOk) {
    $funcs = @($j.functions)

    # [8.1] readable: version 1 + at least one function
    if ($j.version -eq 1 -and $funcs.Count -gt 0) {
      Ok "$s : dbg.json v1, $($funcs.Count) function(s)"
    } else {
      Bad "$s : [8.1] dbg.json version=$($j.version) functions=$($funcs.Count)"
    }

    # [8.2] address coordinate: start < end, inside .text (objdump -h), ascending, and the JSON's
    #       text.rva agrees with the section table (same coordinate system as the TSV)
    $ts = Get-TextSection $dbg
    $addrBad = 0
    if (-not $ts) { $addrBad++ }
    else {
      if ([uint64]$j.text.rva -ne [uint64]($ts.VMA - 0x140000000)) { $addrBad++ }
      $prev = [uint64]0
      foreach ($f in $funcs) {
        $st = [uint64]$f.start; $en = [uint64]$f.end
        if ($st -ge $en) { $addrBad++ }
        if ($st -lt $ts.VMA -or $en -gt ($ts.VMA + $ts.Size)) { $addrBad++ }
        if ($st -lt $prev) { $addrBad++ }
        $prev = $st
        # the frame windows must sit inside the function they describe
        if ([uint64]$f.frame.prologue.start -ne $st -or [int]$f.frame.prologue.len -le 0) { $addrBad++ }
        if ([uint64]$f.frame.epilogue.start -lt $st -or
            ([uint64]$f.frame.epilogue.start + [uint64]$f.frame.epilogue.len) -gt $en) { $addrBad++ }
      }
    }
    if ($addrBad -eq 0) {
      Ok "$s : every function range lies inside .text and ascends (vs objdump -h); prologue/epilogue inside"
    } else {
      Bad "$s : [8.2] $addrBad address/window problem(s) (text VMA=0x$('{0:X}' -f $ts.VMA) size=0x$('{0:X}' -f $ts.Size))"
    }

    # [8.3] frame.size == the `sub $imm,%rsp` immediate the disassembler sees in the prologue.
    #       Big frames are emitted as several `sub $0x1000` + probe pairs (page-by-page commit), so the
    #       window is 64 bytes and the immediates are summed; no sub at all => frame.size must be 0.
    $dis = Parse-Disasm $dbg
    $frameBad = 0
    foreach ($f in $funcs) {
      $st = [uint64]$f.start
      # window = the prologue the JSON declares (the immediates themselves always come from objdump).
      # Bounding the window this way keeps a body-level `sub rsp,32` (shadow space around a call) out
      # of the sum, while still catching every page-probe segment of a big frame.
      $win = $st + [uint64]$f.frame.prologue.len
      $sum = [uint64]0; $found = 0
      foreach ($i in $dis) {
        if ($i.addr -lt $st -or $i.addr -ge $win) { continue }
        if ($i.op -eq 'sub' -and $i.arg -match '^\$0x([0-9a-fA-F]+),%rsp$') {
          $sum += [Convert]::ToUInt64($matches[1], 16); $found++
        }
      }
      if ($found -eq 0) {
        if ([int]$f.frame.size -ne 0) { $frameBad++ }
      } elseif ([uint64]$sum -ne [uint64]$f.frame.size) {
        $frameBad++
      }
    }
    if ($frameBad -eq 0) { Ok "$s : frame.size matches objdump's sub rsp immediate (sum over multi-page prologues)" }
    else { Bad "$s : [8.3] $frameBad function(s) disagree with objdump on the stack-allocation immediate" }

    # [8.4] savedRegs == the callee-saved push sequence objdump shows, in the same order
    $regBad = 0
    foreach ($f in $funcs) {
      $st = [uint64]$f.start
      $win = $st + [uint64]$f.frame.prologue.len
      $seen = @()
      foreach ($i in $dis) {
        if ($i.addr -lt $st -or $i.addr -ge $win) { continue }
        if ($i.op -eq 'push' -and $i.arg -match '^%(rbx|r12|r13|r14|r15)$') { $seen += $matches[1] }
      }
      $declared = @($f.frame.savedRegs | ForEach-Object { "$_" })
      if (($seen -join ',') -ne ($declared -join ',')) { $regBad++ }
      if ([int]$f.frame.pushBytes -ne 8 * $seen.Count) { $regBad++ }
    }
    if ($regBad -eq 0) { Ok "$s : frame.savedRegs + pushBytes match objdump's callee-saved push sequence" }
    else { Bad "$s : [8.4] $regBad saved-register mismatch(es) vs objdump" }

    # [8.5] variable count + name set == the declarations counted from the SOURCE (independent judge)
    $srcFuncs = Get-SourceFuncNames $src
    $declBad = 0
    if ($srcFuncs.Count -eq 0) { $declBad++ }
    foreach ($fn in $srcFuncs) {
      $jf = @($funcs | Where-Object { $_.name -eq $fn })
      if ($jf.Count -ne 1) { $declBad++; continue }
      $decl = Get-SourceDecls $src $fn
      if ($null -eq $decl) { $declBad++; continue }
      $jnames = @($jf[0].vars | ForEach-Object { "$($_.name)" })
      if ($decl.Count -ne $jnames.Count) { $declBad++; continue }
      $a = (($decl | Sort-Object -Unique) -join ',')
      $b = (($jnames | Sort-Object -Unique) -join ',')
      if ($a -ne $b) { $declBad++ }
    }
    if ($declBad -eq 0) {
      $tot = 0
      foreach ($fn in $srcFuncs) { $tot += @(@($funcs | Where-Object { $_.name -eq $fn })[0].vars).Count }
      Ok "$s : var count + name set match the source scan ($($srcFuncs.Count) function(s), $tot var(s))"
    } else {
      Bad "$s : [8.5] $declBad function(s) disagree with the source declaration scan"
    }

    # [8.6] every slot inside the frame and unique within its function
    $slotBad = 0
    foreach ($f in $funcs) {
      $seen = @{}
      foreach ($v in @($f.vars)) {
        $sl = [int]$v.slot
        if ($sl -lt (-[int]$f.frame.size) -or $sl -gt -8) { $slotBad++ }
        if ($seen.ContainsKey($sl)) { $slotBad++ } else { $seen[$sl] = 1 }
      }
    }
    if ($slotBad -eq 0) { Ok "$s : every slot is inside the frame (-size..-8) and unique per function" }
    else { Bad "$s : [8.6] $slotBad slot problem(s) (out of frame or duplicated)" }

    # [8.7] type spelling whitelist (no garbage accepted; arrays/pointers/struct names allowed)
    $tyBad = 0
    $tyRe = '^(?:struct\s+[A-Za-z_]\w*|int_32|int_64|uint_8|uint_32|uint_64|int|char|double)(?:\[[0-9]+\]|\*)?$'
    foreach ($f in $funcs) {
      foreach ($v in @($f.vars)) {
        if ("$($v.type)" -notmatch $tyRe) { $tyBad++ }
        if (@('local', 'param', 'aggregate') -notcontains "$($v.kind)") { $tyBad++ }
        if ([int]$v.line -lt 1) { $tyBad++ }
      }
    }
    if ($tyBad -eq 0) { Ok "$s : every variable type/kind/line is well-formed" }
    else { Bad "$s : [8.7] $tyBad malformed type/kind/line field(s)" }

    # [8.8] determinism: recompiling the SAME source to the SAME output must reproduce the file
    $h1 = (Get-FileHash -Algorithm SHA256 -Path $map).Hash
    & $flint -debug $src -o $dbg *>$null
    $h2 = (Get-FileHash -Algorithm SHA256 -Path $map).Hash
    if ($h1 -eq $h2 -and (Test-Path $map)) {
      Ok "$s : dbg.json is deterministic (SHA256 $($h1.Substring(0, 16))...)"
    } else {
      Bad "$s : [8.8] recompiling produced a different dbg.json ($h1 vs $h2)"
    }

    # [8.9] no side file when the switch is OFF (ordinary products stay untouched)
    if (Test-Path "$plain.dbg.json") {
      Bad "$s : [8.9] -debug OFF still wrote a .dbg.json"
    } else {
      Ok "$s : -debug OFF writes no .dbg.json"
    }
  }
}
Pop-Location

# [6] v1.4.16 (task card T-20260918-012105): the condition bytes of a control statement must carry
#     the condition's OWN source line. Before this round they were covered by the row of the statement
#     BEFORE the if/while/for, so a debugger showed the wrong line for the comparison.
$condSrc = Join-Path $root 'test\samples\dbgcond.fl'
if (-not (Test-Path $condSrc)) {
  Bad 'condition attribution: sample test\samples\dbgcond.fl is missing'
} else {
  $d6 = Join-Path $tmp 'd_dbgcond.exe'
  Remove-Item $d6, "$d6.tsv" -ErrorAction SilentlyContinue
  & $flint -debug $condSrc -o $d6 *>$null
  if (-not (Test-Path $d6)) {
    Bad 'condition attribution: -debug compile produced no exe'
  } else {
    # expected set: the source line of every control statement opening with `if (` / `while (` / `for (`
    $exp = @()
    $n = 0
    foreach ($l in (Get-Content $condSrc -Encoding UTF8)) {
      $n++
      if ($l -match '^\s*(if|while|for)\s*\(') { $exp += $n }
    }
    # actual set: the line every comparison instruction resolves to, via addr2line (external oracle)
    $got = @()
    foreach ($l in (& $Objdump -d $d6 2>$null)) {
      # v5（2026-10-21，D-2）：-debug 关掉驻留后，立即数比内存的条件会打印成 `cmpl`（带尺寸后缀），
      #   老正则只认裸 `cmp`，会把 while/for 的条件**漏读**（假红）。语义上 cmpl/cmpq 都是比较指令，一并收。
      if ($l -match '^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2} )+\s*cmp[lwq]?\s') {
        $a = [Convert]::ToUInt64($matches[1], 16)
        $loc = (& $Addr2line -f -C -e $d6 ('0x{0:X}' -f $a) 2>$null | Select-Object -Last 1)
        if ($loc -match ':(\d+)$') { $got += [int]$matches[1] }
      }
    }
    if ($exp.Count -eq 0) {
      Bad 'condition attribution: no control statement found in dbgcond.fl (sample changed?)'
    } else {
      # v1.4.17：判据改成**集合比对**。原判据是"条件里的 cmp 逐条对应的行，去重排序后必须等于期望串"，
      #   隐含"每个条件的行只出现一次"。窥孔第二档「循环头反转」把 while/for 的条件**求值两次**
      #   （头部一次 + 尾部回边一次），于是同一行会在 addr2line 的结果里出现两次 —— 那是
      #   "条件真的被求值了两次"的如实反映，不是归属错误。
      #   等价性论证：去重后集合仍相等 ⇔ 每条 cmp 的行都**真实**是某个 if(/while(/for( 的行，
      #   且每个控制语句的条件都至少有一条 cmp 被正确归属。原判据的"漏归属"能力(多出的 14 那种)由去重保留。
      $e = (($exp | Sort-Object -Unique) -join ',')
      $g = (($got | Sort-Object -Unique) -join ',')
      if ($e -eq $g) { Ok "dbgcond.fl : every condition cmp resolves to its own line (lines $g)" }
      else { Bad "dbgcond.fl : condition line mismatch -- expected=[$e] addr2line=[$g]" }
    }
  }
}

Write-Host '----'
Write-Host "passed $pass / failed $fail"
if ($fail -gt 0) { exit 1 }
exit 0
