# gen-srclimit.ps1 -- generator + self-asserting probe for the boot compiler's SOURCE SIZE ceiling.
#
# WHY IT EXISTS
#   boot\b1_emit.exe reads the (include-spliced) source into a 262144-byte buffer
#   (boot\b1_emit.fl: `char *fbuf = VirtualAlloc(0, 262144, ...)` then
#    `int n = read_file(name, fbuf, 262144);`), and read_file returns -3 when
#    `got >= cap` (boot\b1_emit.fl: `if (got >= cap) return -3;`).  Caller prints
#    `cannot read '<file>' (err=-3)` and exits 3.
#   The real compiler (flint.exe) has no such ceiling.  So this is a LOUD FAILURE that
#   must stay loud and must stay at the same threshold -- and it is an ERROR CODE, so it
#   is easy to mis-file as a defect.  This script pins both facts.
#
# WHY A GENERATOR (and not a checked-in .fl)
#   The probe source is >256 KiB, most of it 20000 identical statements.  Storing it in the
#   repo would add a quarter-megabyte of noise to git and to every directory listing, so the
#   oversized source is generated at run time under %TEMP% and never enters the repository.
#
# WHAT IT ASSERTS (all expected values computed here, nothing hand-typed)
#   leg A: 262143 bytes (= 262144 - 1, the largest readable source) -> flint.exe compiles,
#          the produced program exits with the statement count; boot\b1_emit.exe compiles
#          the SAME source without complaint (proves the threshold is exactly 262144, not
#          "big files in general").
#   leg B: exactly 262144 bytes (the cap itself)                -> flint.exe still compiles and
#          the produced program still exits with the statement count; boot\b1_emit.exe
#          REFUSES LOUDLY: stdout/stderr contains "err=-3" and its exit code is 3.
#          It must NOT produce an .exe.
#   The two legs differ by ONE byte, so together they pin the threshold exactly: whatever
#   number the cap is moved to, one of them turns red.
#
# WHY THE STATEMENTS ARE CHUNKED (and not 20000 flat ones)
#   boot also has a per-block ceiling: parse_block() buffers a block's DIRECT child statements
#   in `int tmp[512]` (boot\lib_parse.fl) and returns -101 at the 512th (measured 2026-10-15:
#   510 x-statements + `return x;` = 511 children compiles, 511 + `return` = 512 children is
#   refused).  A flat ~20000-statement body therefore dies of -101 long before the 262144-byte
#   file ceiling this script is about.  Every $chunk statements are wrapped in their own nested
#   block instead, which resets that counter per block and leaves the program's meaning alone.
#
# USAGE (ASCII only, no BOM; run it with the same interpreter as every other fact probe):
#   powershell -NoProfile -ExecutionPolicy Bypass -File E:\FLINT-lab\test\facts\gen-srclimit.ps1
# EXIT CODE: 0 = all assertions held, 1 = something regressed (one FAIL line per problem).
#
# NOTE: nothing is written inside E:\FLINT-lab -- all generated sources, .exe files and
#       captured stdout/stderr live under %TEMP%\dsh-assert\srclimit\.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$factsDir = $PSScriptRoot
$lab      = Split-Path (Split-Path $factsDir -Parent) -Parent          # E:\FLINT-lab
$flintExe = Join-Path $lab 'flint.exe'
$bootExe  = Join-Path $lab 'boot\b1_emit.exe'
$work     = Join-Path $env:TEMP 'dsh-assert\srclimit'
$cap      = 262144          # the ceiling under test (boot\b1_emit.fl: VirtualAlloc(...,262144,...) + read_file(name, fbuf, 262144))

$script:Failed = 0
function Say([string]$m) { [Console]::Out.WriteLine($m) }
function Fail([string]$m) { [Console]::Out.WriteLine('FAIL ' + $m); $script:Failed = 1 }
function Q([string]$s) { if ($s -match ' ') { return ('"' + $s + '"') } return $s }

function Invoke-Cap([string]$exe, [string[]]$argv) {
    $tag = [guid]::NewGuid().ToString('N')
    $o = Join-Path $work ("cap-$tag.out")
    $e = Join-Path $work ("cap-$tag.err")
    $quoted = @()
    foreach ($a in $argv) { $quoted += (Q $a) }
    # NOTE: a bare `@()` return of `$quoted` collapses to $null, and Start-Process rejects an
    # empty/-null ArgumentList on PowerShell 5.1 -- so branch instead of always passing a list.
    if ($quoted.Count -eq 0) {
        $p = Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $o -RedirectStandardError $e
    } else {
        $p = Start-Process -FilePath $exe -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
             -RedirectStandardOutput $o -RedirectStandardError $e
    }
    $ot = ''; $et = ''
    if (Test-Path $o) { $ot = [IO.File]::ReadAllText($o, [Text.Encoding]::UTF8) }
    if (Test-Path $e) { $et = [IO.File]::ReadAllText($e, [Text.Encoding]::UTF8) }
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    return @{ Code = $p.ExitCode; Out = $ot; Err = $et }
}

# Build `int main() { int x = 0; <n> x = x + 1;  return x; }` padded to an exact byte size.
# Padding goes into trailing spaces on the opening brace line, which are inside the function
# body but outside any expression -- so it cannot change the program's meaning.
#
# WHY THE STATEMENTS ARE CHUNKED: boot's parse_block buffers a block's DIRECT child statements
# in `int tmp[512]` (boot\lib_parse.fl) and returns -101 when the 512th direct child is reached
# (measured 2026-10-15: 511 children pass, 512 is refused) -- so ~20000 statements in one flat
# block would hit THAT ceiling long before the 262144-byte file ceiling this probe is about.
# Wrapping every $chunk statements in their own nested block keeps every block far under 512 and
# leaves the program's meaning untouched (nesting blocks scopes nothing here; x stays the outer
# local).  The chunk size is derived from the 512 figure rather than typed in a second time.
# Returns @{ Path; Bytes; Stmts; ExpectExit } or $null on failure.
function Build-Source([string]$dir, [string]$name, [int]$targetBytes) {
    $limit = 512                 # boot\lib_parse.fl tmp[512]: at most 512 direct children per block
    $chunk = $limit - 112        # = 400: leaves 112 slots of headroom; derived, not a second source of truth
    $head = "int main()`n{"      # no trailing newline yet: padding goes here
    $tail = "`n  int x = 0;`n"
    $foot = "  return x;`n}`n"
    $stmt = "  x = x + 1;`n"
    $open = "{`n"; $close = "}`n"
    # first pass: count statements so that head + tail + n*stmt + blocks + foot reaches targetBytes
    $n = 0
    $size = $head.Length + $tail.Length + $foot.Length
    while ($true) {
        $nn = $n + 1
        $blocks = [Math]::Ceiling($nn / $chunk)
        if ($size + $nn * $stmt.Length + $blocks * ($open.Length + $close.Length) -gt $targetBytes) { break }
        $n = $nn
    }
    $blocks = [Math]::Ceiling($n / $chunk)
    $size = $size + $n * $stmt.Length + $blocks * ($open.Length + $close.Length)
    $pad = $targetBytes - $size
    if ($pad -lt 0) { Fail ("Build-Source ${name}: target $targetBytes is smaller than the fixed skeleton"); return $null }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($head)
    if ($pad -gt 0) { [void]$sb.Append(' ' * $pad) }
    [void]$sb.Append($tail)
    $done = 0
    while ($done -lt $n) {
        $take = $chunk
        if ($n - $done -lt $chunk) { $take = $n - $done }
        [void]$sb.Append($open)
        for ($i = 0; $i -lt $take; $i++) { [void]$sb.Append($stmt) }
        [void]$sb.Append($close)
        $done = $done + $take
    }
    [void]$sb.Append($foot)
    $path = Join-Path $dir ($name + '.fl')
    # UTF8Encoding($false) => NO BOM. Sources must stay pure ASCII for both ends.
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    if (-not (Test-Path $path)) { Fail ("Build-Source ${name}: write failed"); return $null }
    $bytes = (Get-Item $path).Length
    if ($bytes -ne $targetBytes) { Fail ("Build-Source ${name}: asked $targetBytes bytes, got $bytes"); return $null }
    # independence check: no byte >= 128 (the "pure ASCII" self-check every FLINT artifact needs)
    $raw = [IO.File]::ReadAllBytes($path)
    $hi = 0
    foreach ($b in $raw) { if ($b -gt 127) { $hi = $hi + 1 } }
    if ($hi -ne 0) { Fail ("Build-Source ${name}: $hi byte(s) >127 -- not pure ASCII"); return $null }
    return @{ Path = $path; Bytes = $bytes; Stmts = $n; ExpectExit = $n }
}

# Compile with one end; returns @{ Code; ExeExists; Out }
function Compile-One([string]$exe, [string]$src) {
    $exePath = [IO.Path]::ChangeExtension($src, '.exe')
    if (Test-Path $exePath) { Remove-Item $exePath -Force }
    $r = Invoke-Cap $exe @($src)
    return @{ Code = $r.Code; ExeExists = (Test-Path $exePath); Exe = $exePath; Out = (($r.Out + $r.Err).Trim() -replace "`r?`n", ' | ') }
}

function Run-Program([string]$exePath) {
    $r = Invoke-Cap $exePath @()
    return @{ Code = $r.Code; Out = $r.Out }
}

Say ("gen-srclimit cap=$cap work=$work")
Say ("  flint=" + $flintExe)
Say ("  boot =" + $bootExe)
foreach ($p in @($flintExe, $bootExe)) { if (-not (Test-Path $p)) { Fail ('missing compiler: ' + $p) } }
if ($script:Failed -ne 0) { Say 'RESULT FAIL gen-srclimit (setup)'; exit 1 }

New-Item -ItemType Directory -Force -Path $work | Out-Null

# ---------------- leg A: exactly cap-1 bytes = the largest source boot can read ----------
$a = Build-Source $work 'at_limit' ($cap - 1)
if (-not $a) { Say 'RESULT FAIL gen-srclimit (legA build)'; exit 1 }
Say ("leg A bytes=" + $a.Bytes + " stmts=" + $a.Stmts + " expect_program_exit=" + $a.ExpectExit)

$fa = Compile-One $flintExe $a.Path
Say ("  flint compile exit=" + $fa.Code + " exe=" + $fa.ExeExists + " :: " + $fa.Out)
if ($fa.Code -ne 0 -or -not $fa.ExeExists) { Fail 'leg A: real flint must compile a 262143-byte source' }
else {
    $ra = Run-Program $fa.Exe
    Say ("  flint program exit=" + $ra.Code)
    if ($ra.Code -ne $a.ExpectExit) { Fail ('leg A: real flint program exit ' + $ra.Code + ' != ' + $a.ExpectExit) }
}

$ba = Compile-One $bootExe $a.Path
Say ("  boot compile exit=" + $ba.Code + " exe=" + $ba.ExeExists + " :: " + $ba.Out)
if ($ba.Code -ne 0 -or -not $ba.ExeExists) { Fail ('leg A: boot must still accept a source at cap-1 bytes (exit ' + $ba.Code + ') -- threshold moved?') }
else {
    $rb = Run-Program $ba.Exe
    Say ("  boot program exit=" + $rb.Code)
    if ($rb.Code -ne $a.ExpectExit) { Fail ('leg A: boot program exit ' + $rb.Code + ' != ' + $a.ExpectExit) }
}

# ---------------- leg B: exactly cap bytes = boot must refuse LOUDLY with err=-3 ---------
$b = Build-Source $work 'at_cap' $cap
if (-not $b) { Say 'RESULT FAIL gen-srclimit (legB build)'; exit 1 }
Say ("leg B bytes=" + $b.Bytes + " (= " + $cap + ", one byte more than leg A) stmts=" + $b.Stmts + " expect_program_exit=" + $b.ExpectExit)

$fb = Compile-One $flintExe $b.Path
Say ("  flint compile exit=" + $fb.Code + " exe=" + $fb.ExeExists + " :: " + $fb.Out)
if ($fb.Code -ne 0 -or -not $fb.ExeExists) { Fail 'leg B: real flint must compile a source at the cap (no ceiling on that end)' }
else {
    $rb2 = Run-Program $fb.Exe
    Say ("  flint program exit=" + $rb2.Code)
    if ($rb2.Code -ne $b.ExpectExit) { Fail ('leg B: real flint program exit ' + $rb2.Code + ' != ' + $b.ExpectExit) }
}

$bb = Compile-One $bootExe $b.Path
Say ("  boot compile exit=" + $bb.Code + " exe=" + $bb.ExeExists + " :: " + $bb.Out)
if ($bb.Code -ne 3) { Fail ('leg B: boot must fail loudly with process exit 3 on an over-cap source, got ' + $bb.Code) }
if ($bb.Out -notmatch 'err=-3') { Fail ('leg B: boot must report err=-3 in its message, got: ' + $bb.Out) }
if ($bb.ExeExists) { Fail 'leg B: boot must NOT leave an .exe after refusing an over-cap source' }

if ($script:Failed -ne 0) { Say 'RESULT FAIL gen-srclimit'; exit 1 }
Say 'RESULT OK gen-srclimit'
exit 0
