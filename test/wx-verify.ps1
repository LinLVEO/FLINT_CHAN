# wx-verify.ps1 -- gate for the "product hardening" rounds (FLINT v1.4.12 W^X assertions, v1.4.13 IAT section)
#
# What it proves (every item is a machine check, not an eyeball):
#   [1] declared section permissions + header geometry, read STRAIGHT OUT OF THE PRODUCT BYTES
#       (not from the C constants, not from objdump):
#         exactly one executable section / no section W|X / no non-code section executable /
#         `.idata` exists and closes the loaded-section set / SizeOfHeaders really covers the section
#         table / .text raw offset == SizeOfHeaders / .idata starts its own page / dir[12] (IAT) present
#         and covering every IAT slot.
#   [2] structural deltas vs the pre-change compiler + behaviour equality:
#         .text/.data/.rsrc keep their VA (only .idata is new, at the tail) and every sample's exit
#         code is unchanged -- replacing the old "byte-identical" item, which this round intentionally
#         breaks (the IAT move rewrites the tool's own product on purpose).
#   [3] runtime protection measured by libcs\wxprobe (CREATE_SUSPENDED + ReadProcessMemory + VirtualQueryEx,
#       dense sampling of EVERY section page during the load window):
#         **the code page must never become writable** (the whole point of the IAT move); the transient
#         writable window must be on the non-executable `.idata` page; steady state .idata = READONLY.
#   [4] injected violations must be refused by I14 / I15 / I18.
#   [5] control run: same injection with the assertions disabled -> product IS emitted and behaves
#       identically (the behaviour-only regression cannot see this class of defect).
#   [6] the loader requirement is pinned as a test: with the IAT directory (dir[12]) omitted, the very
#       same product CRASHES (0xC0000005) -- that is the empirical evidence behind requiring it.
#
# NOTE: this file is deliberately ASCII-only. A .ps1 without a BOM gets decoded as GBK by PS 5.1 and
#   reports fake syntax errors -- keeping it ASCII-only makes that failure mode impossible.
#
# usage: powershell -NoProfile -ExecutionPolicy Bypass -File test\wx-verify.ps1 [-BaselineExe .\flint_before_wx.exe]

param([string]$BaselineExe = '.\flint_before_wx.exe')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flint = Join-Path $root 'flint.exe'
$base  = Join-Path $root $BaselineExe
$probe = Join-Path $root 'libcs\wxprobe\wxprobe.exe'
# v1.4.25: crashprobe -- observe a product's fault through a debugger instead of waiting on its exit
#   code (libcs\crashprobe\crashprobe.c). Rationale in the [6] block below.
$crashprobe = Join-Path $root 'libcs\crashprobe\crashprobe.exe'
$tmp   = Join-Path $root 'tmp'
$gcc   = (Get-Command gcc).Source

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host ("  OK   {0}{1}" -f $name, $(if ($detail) { " : $detail" } else { '' })) }
  else     { $script:fail++; Write-Host ("  FAIL {0}{1}" -f $name, $(if ($detail) { " : $detail" } else { '' })) -ForegroundColor Red }
}
function Head([string]$t) { Write-Host "`n--- $t ---" }

$SCN_EXEC = 0x20000000
$SCN_WRITE = 0x80000000
$SEC_ALIGN = 0x1000

# --- self-contained PE parse of the product file (no external tool) ---
function Get-Pe([string]$exe) {
  $b = [IO.File]::ReadAllBytes($exe)
  $lf = [BitConverter]::ToUInt32($b, 0x3C)
  if ([Text.Encoding]::ASCII.GetString($b, $lf, 4) -ne "PE`0`0") { throw "no PE signature in $exe" }
  $coff = $lf + 4
  $nsec = [BitConverter]::ToUInt16($b, $coff + 2)
  $optsz = [BitConverter]::ToUInt16($b, $coff + 16)     # NOTE: offset 16, not 20
  $opt = $coff + 20
  $soh = [BitConverter]::ToUInt32($b, $opt + 0x3C)
  $iatRva = [BitConverter]::ToUInt32($b, $opt + 0x70 + 12 * 8)
  $iatSize = [BitConverter]::ToUInt32($b, $opt + 0x70 + 12 * 8 + 4)
  $impRva = [BitConverter]::ToUInt32($b, $opt + 0x70 + 1 * 8)
  $sec = $opt + $optsz
  $sections = @()
  for ($i = 0; $i -lt $nsec; $i++) {
    $o = $sec + $i * 40
    $sections += [pscustomobject]@{
      Index = $i
      Name  = [Text.Encoding]::ASCII.GetString($b, $o, 8).TrimEnd([char]0)
      VS    = [BitConverter]::ToUInt32($b, $o + 8)
      VA    = [BitConverter]::ToUInt32($b, $o + 12)
      RawSize = [BitConverter]::ToUInt32($b, $o + 16)
      RawPtr  = [BitConverter]::ToUInt32($b, $o + 20)
      Chars = [BitConverter]::ToUInt32($b, $o + 36)
    }
  }
  return [pscustomobject]@{ Nsec = $nsec; SizeOfHeaders = $soh; IatRva = $iatRva; IatSize = $iatSize
                            ImpRva = $impRva; Sections = $sections; Bytes = $b }
}

# RVA -> file offset via the section table (import descriptors are addressed by RVA; the table lives
# in a different section than the raw pointer suggests, so NEVER read descriptors at the RVA directly)
function Rva-ToOff([object]$pe, [int]$rva) {
  foreach ($s in $pe.Sections) {
    if ($rva -ge $s.VA -and $rva -lt ($s.VA + [Math]::Max($s.RawSize, $s.VS))) {
      return [int]($s.RawPtr + ($rva - $s.VA))
    }
  }
  return -1
}

# IAT slot RVAs = FirstThunk of every import descriptor (need the thunk count from the INT)
function Get-IatSlots([object]$pe) {
  $slots = @()
  $base = Rva-ToOff $pe $pe.ImpRva
  if ($base -lt 0) { return $slots }
  for ($k = 0; $k -lt 16; $k++) {
    $o = $base + $k * 20
    if ($o + 20 -gt $pe.Bytes.Length) { break }
    $oft = [BitConverter]::ToUInt32($pe.Bytes, $o)
    $ft  = [BitConverter]::ToUInt32($pe.Bytes, $o + 16)
    if ($oft -eq 0 -and $ft -eq 0) { break }
    $slots += $ft
  }
  return $slots
}

function Get-Product([string]$exe, [string[]]$flags, [string]$src, [string]$out) {
  $a = @()
  if ($flags) { $a += $flags }
  $a += $src
  $a += @('-o', $out)
  if (Test-Path $out) { Remove-Item $out -Force }
  # a refused compile writes its diagnostic to STDERR; PS 5.1 turns redirected native stderr into a
  # terminating NativeCommandError under EAP=Stop -- relax it only around the native call.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $log = & $exe @a 2>&1 } finally { $ErrorActionPreference = $eap }
  return [pscustomobject]@{ Exit = $LASTEXITCODE; Log = ($log -join "`n") }
}

# v1.4.25: suppress the Windows crash dialog for the products under test.
#   Why: when a product under test dies on a fault, Windows may put up an error box; the box is owned by
#   the child/WER path, so the parent's wait never returns -- measured 2026-09-19: the "expected to
#   crash" case sat idle (0 CPU) for 30+ minutes and the whole total gate looked "stuck" (the products
#   were byte-identical to the ones that passed 139/0 earlier the same day, so this is an environment
#   stall, not a product change). SetErrorMode is a PROCESS-level call -- no registry, no system setting
#   -- and the error mode is INHERITED by children: a faulting product then exits with its exception
#   code instead of waiting on a dialog. Kept in try/catch: if Add-Type is unavailable the gate still
#   runs, protected by the timeout in Run-Product below.
$SEM_FAILCRITICALERRORS = 0x0001; $SEM_NOGPFAULTERRORBOX = 0x0002
try {
  if (-not ('WxGate.ErrMode' -as [type])) {
    Add-Type -Namespace WxGate -Name ErrMode -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetErrorMode(uint uMode);
'@
  }
  [void][WxGate.ErrMode]::SetErrorMode($SEM_FAILCRITICALERRORS -bor $SEM_NOGPFAULTERRORBOX)
} catch { }

function Run-Product([string]$exe) {
  if (-not (Test-Path $exe)) { return 'missing' }
  # v1.4.25: this used to be `Start-Process -Wait` with NO timeout. A stall must show up as a FAILED
  #   CHECK, never as a gate that never finishes: wait at most 20s, then kill and return a string
  #   ('timeout' / 'launch-error') that can never equal a numeric expectation.
  try { $p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden } catch { return 'launch-error' }
  if (-not $p.WaitForExit(20000)) {
    try { $p.Kill() } catch {}
    return 'timeout'
  }
  return $p.ExitCode
}

Write-Host "== wx-verify ==  flint=$flint  baseline=$base"

# ---------------------------------------------------------------- [1] declared permissions + geometry
Head '[1] declared section permissions + header geometry (parsed from product bytes)'
$shapes = @(
  @{ n = 'single-sec';    f = @();                  s = 'test\samples\st1.fl';     o = "$tmp\wx-one.exe" },
  @{ n = 'two-sec';       f = @();                  s = 'test\samples\global1.fl'; o = "$tmp\wx-two.exe" },
  @{ n = 'admin';         f = @('-admin');          s = 'test\samples\st1.fl';     o = "$tmp\wx-adm.exe" },
  @{ n = 'debug';         f = @('-debug');          s = 'test\samples\st1.fl';     o = "$tmp\wx-dgb.exe" },
  @{ n = 'debug+admin';   f = @('-debug','-admin'); s = 'test\samples\global1.fl'; o = "$tmp\wx-dbg.exe" }
)
foreach ($sh in $shapes) {
  $r = Get-Product $flint $sh.f $sh.s $sh.o
  Check "$($sh.n): compile exit=0" ($r.Exit -eq 0) "exit=$($r.Exit)"
  $pe = Get-Pe $sh.o
  $execCount = 0; $wx = 0; $badExec = @(); $idata = $null; $text = $null
  foreach ($x in $pe.Sections) {
    if ($x.Chars -band $SCN_EXEC) { $execCount++ }
    if (($x.Chars -band $SCN_EXEC) -and ($x.Chars -band $SCN_WRITE)) { $wx++ }
    if ($x.Index -gt 0 -and ($x.Chars -band $SCN_EXEC)) { $badExec += $x.Name }
    if ($x.Name -eq '.idata') { $idata = $x }
    if ($x.Name -eq '.text')  { $text = $x }
    Write-Host ("      {0,-11} {1,-12} va=0x{2:X8} vs=0x{3:X6} chars=0x{4:X8}" -f $sh.n, $x.Name, $x.VA, $x.VS, $x.Chars)
  }
  Check "$($sh.n): no section is W|X" ($wx -eq 0) "count=$wx"
  Check "$($sh.n): exactly one executable section" ($execCount -eq 1) "count=$execCount"
  Check "$($sh.n): no non-code section executable" ($badExec.Count -eq 0) ($badExec -join ',')
  Check "$($sh.n): .idata present" ($null -ne $idata)
  # header geometry: the header must really cover the section table, and .text must start right after it
  Check "$($sh.n): SizeOfHeaders covers the section table" ($pe.SizeOfHeaders -ge 0x148 + $pe.Nsec * 40) "soh=0x$('{0:X}' -f $pe.SizeOfHeaders) nsec=$($pe.Nsec)"
  Check "$($sh.n): .text raw offset == SizeOfHeaders" ($text.RawPtr -eq $pe.SizeOfHeaders) "raw=0x$('{0:X}' -f $text.RawPtr)"
  if ($idata -and $text) {
    Check "$($sh.n): .idata starts its own page (not .text's)" (($idata.VA % $SEC_ALIGN) -eq 0 -and ($idata.VA - $SEC_ALIGN) -ge $text.VA) ("idata=0x{0:X} text=0x{1:X}" -f $idata.VA, $text.VA)
    Check "$($sh.n): .idata VA is adjacent to the previous section end" (($text.VA + [Math]::Max($text.VS, 0)) -le $idata.VA) ""
  }
  # IAT directory must exist and cover every import descriptor's FirstThunk
  Check "$($sh.n): IAT directory present" (($pe.IatRva -ne 0) -and ($pe.IatSize -ne 0)) ("rva=0x{0:X} size=0x{1:X}" -f $pe.IatRva, $pe.IatSize)
  $slots = Get-IatSlots $pe
  $covered = $true
  foreach ($sl in $slots) { if ($sl -lt $pe.IatRva -or ($sl + 8) -gt ($pe.IatRva + $pe.IatSize)) { $covered = $false } }
  Check "$($sh.n): IAT directory covers every FirstThunk" ($covered -and $slots.Count -gt 0) ("slots=$($slots.Count)")
  Check "$($sh.n): IAT directory lies inside .idata" ($pe.IatRva -ge $idata.VA -and ($pe.IatRva + $pe.IatSize) -le ($idata.VA + $idata.VS)) ""
}

# ---------------------------------------------------------------- [2] structural deltas + behaviour
Head '[2] structural deltas vs baseline + behaviour equality'
$cmp = @(
  @{ n = 'single-sec';  f = @();                  s = 'test\samples\st1.fl';     want = 34 },
  @{ n = 'two-sec';     f = @();                  s = 'test\samples\global1.fl'; want = 255 },
  @{ n = 'admin';       f = @('-admin');          s = 'test\samples\st1.fl';     want = 34 },
  @{ n = 'debug';       f = @('-debug');          s = 'test\samples\st1.fl';     want = 34 },
  @{ n = 'debug+admin'; f = @('-debug','-admin'); s = 'test\samples\global1.fl'; want = 255 }
)
foreach ($c in $cmp) {
  $a = Get-Product $base  $c.f $c.s "$tmp\wxb.exe"
  $b = Get-Product $flint $c.f $c.s "$tmp\wxn.exe"
  if ($a.Exit -ne 0 -or $b.Exit -ne 0) { Check "$($c.n): both compilers build" $false "base=$($a.Exit) new=$($b.Exit)"; continue }
  $pa = Get-Pe "$tmp\wxb.exe"; $pn = Get-Pe "$tmp\wxn.exe"
  # every pre-existing section keeps its VA; .idata is the only new one and closes the loaded set
  # only the LOADED sections must keep their VA. The three `.debug_*` sections legitimately shift:
  #   `.idata` is inserted before them (they are DISCARDABLE / non-loaded, so their VA is ours to move).
  $SCN_DISC = 0x02000000
  $vaSame = $true
  foreach ($x in $pa.Sections) {
    if ($x.Chars -band $SCN_DISC) { continue }
    $y = $pn.Sections | Where-Object { $_.Name -eq $x.Name }
    if (-not $y -or $y.VA -ne $x.VA) { $vaSame = $false }
  }
  Check "$($c.n): loaded sections keep their VA" $vaSame
  Check "$($c.n): one more section than baseline (.idata)" ($pn.Nsec -eq $pa.Nsec + 1) "base=$($pa.Nsec) new=$($pn.Nsec)"
  $rb = Run-Product "$tmp\wxb.exe"
  $rn = Run-Product "$tmp\wxn.exe"
  Check "$($c.n): new product exits with the expected code" ($rn -eq $c.want) "new=$rn want=$($c.want)"
  if ($rb -eq $rn) {
    Check "$($c.n): baseline product behaves the same" $true "both=$rn"
  } else {
    # A baseline difference is acceptable ONLY when the baseline product itself was broken by the old
    # header overflow (pre-v1.4.13: SizeOfHeaders hard-coded 0x200 while >=5 sections need 0x210/0x238).
    $baseBroken = $pa.SizeOfHeaders -lt (0x148 + $pa.Nsec * 40)
    Check "$($c.n): baseline difference explained by the old header overflow" $baseBroken ("base=$rb new=$rn base_soh=0x{0:X} nsec={1}" -f $pa.SizeOfHeaders, $pa.Nsec)
  }
}

# ---------------------------------------------------------------- [3] runtime protection
Head '[3] runtime protection (wxprobe: every section page sampled during the load window)'
$spin = @'
int g = 7;
int main() {
  int i = 0;
  while (i < 2000000000) { i = i + 1; }
  return (i + g) % 256;
}
'@
Set-Content -Path "$tmp\wxspin2.fl" -Value $spin -Encoding ASCII
$rb = Get-Product $flint @() 'tmp\wxspin2.fl' "$tmp\wxspin2.exe"
Check 'takes: long-lived two-section target builds' ($rb.Exit -eq 0) "exit=$($rb.Exit)"
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $plog = & $probe "$tmp\wxspin2.exe" 2>&1 } finally { $ErrorActionPreference = $eap }
$ptxt = $plog -join "`n"
$pb = [regex]::Split($ptxt, 'moment B:')
$pB = if ($pb.Count -gt 1) { $pb[1] } else { '' }
$mt = [regex]::Match($pB, '\[0\] \.text[\s\S]*?\(B\)\s*:\s*protect=0x([0-9A-F]{3})')
$md = [regex]::Match($pB, '\[1\] \.data[\s\S]*?\(B\)\s*:\s*protect=0x([0-9A-F]{3})')
$mi = [regex]::Match($pB, '\[2\] \.idata[\s\S]*?\(B\)\s*:\s*protect=0x([0-9A-F]{3})')
Check 'probe: .text steady state is PAGE_EXECUTE_READ' ($mt.Success -and $mt.Groups[1].Value -eq '020') "protect=$($mt.Groups[1].Value)"
Check 'probe: .data steady state is not executable' ($md.Success -and ($md.Groups[1].Value -in @('004','008'))) "protect=$($md.Groups[1].Value)"
Check 'probe: .idata steady state is READONLY (loader restored it)' ($mi.Success -and $mi.Groups[1].Value -eq '002') "protect=$($mi.Groups[1].Value)"
# per-page watches during the whole load window
$watches = @{}
foreach ($line in ($ptxt -split "`n")) {
  $m = [regex]::Match($line, '^watch\s+(\S+)\s+0x([0-9A-Fa-f]+)\s+samples=(\d+)\s+distinct:(.*)$')
  if ($m.Success) { $watches[$m.Groups[1].Value] = [pscustomobject]@{ Samples = [int]$m.Groups[3].Value; Distinct = $m.Groups[4].Value.Trim() } }
}
$wt = $watches['.text']; $wi = $watches['.idata']
Check 'probe: load window really sampled' ($wt -and $wt.Samples -gt 1000) ("samples=" + $(if ($wt) { $wt.Samples } else { 0 }))
Check 'probe: **code page never becomes writable** during load' ($wt -and ($wt.Distinct -notmatch 'WRITE')) ("distinct=" + $(if ($wt) { $wt.Distinct } else { '' }))
Check 'probe: code page stays executable throughout' ($wt -and ($wt.Distinct -match 'EXECUTE_READ'))
Check 'probe: transient write happens on the non-exec .idata page' ($wi -and ($wi.Distinct -match 'WRITE') -and ($wi.Distinct -notmatch 'EXECUTE')) ("distinct=" + $(if ($wi) { $wi.Distinct } else { '' }))

# ---------------------------------------------------------------- [4]/[5] injections + control
Head '[4] injected violations must be refused by I14 / I15 / I18'
$lab = "$tmp\wxlab"
if (Test-Path $lab) { Remove-Item $lab -Recurse -Force }
New-Item -ItemType Directory -Path $lab | Out-Null
Copy-Item (Join-Path $root 'src\*.c') $lab
Copy-Item (Join-Path $root 'src\*.h') $lab
$enc = New-Object Text.UTF8Encoding($false)
function Patch([string]$dir, [string]$from, [string]$to) {
  foreach ($f in Get-ChildItem "$dir\*.c") {
    $t = [IO.File]::ReadAllText($f.FullName)
    if ($t.Contains($from)) { [IO.File]::WriteAllText($f.FullName, $t.Replace($from, $to), $enc); return }
  }
  throw "patch anchor not found: $from"
}
function Build-Variant([string]$tag, [string[]]$patches) {
  $d = "$lab\v_$tag"
  if (Test-Path $d) { Remove-Item $d -Recurse -Force }
  New-Item -ItemType Directory -Path $d | Out-Null
  Copy-Item "$lab\*.c" $d; Copy-Item "$lab\*.h" $d
  for ($i = 0; $i -lt $patches.Count; $i += 2) { Patch $d $patches[$i] $patches[$i + 1] }
  $exe = "$lab\flint_$tag.exe"
  $out = & $gcc -O2 -w (Get-ChildItem "$d\*.c").FullName -o $exe 2>&1
  if ($LASTEXITCODE -ne 0) { throw "variant $tag failed to build: $out" }
  return $exe
}

$CH_DATA = 'const uint32_t DATA_SEC_CHAR = 0xC0000040;'
$CH_TEXT = 'const uint32_t TEXT_SEC_CHAR = 0x60000020;'
$CH_IATD = '{ w32(b, iat_rva); w32(b, iat_size); }'
$AS_WX   = 'if ((c & SCN_WRITE) && (c & SCN_EXEC)) {'
$AS_EXEC = 'if (i > 0 && (c & SCN_EXEC)) {'
$AS_CNT  = 'if (n_exec != 1) {'

$vA = Build-Variant 'A_data_exec' @($CH_DATA, 'const uint32_t DATA_SEC_CHAR = 0x60000040;')
$vB = Build-Variant 'B_data_wx'   @($CH_DATA, 'const uint32_t DATA_SEC_CHAR = 0xE0000040;')
$vC = Build-Variant 'C_text_w'    @($CH_TEXT, 'const uint32_t TEXT_SEC_CHAR = 0xE0000020;')
$vE0 = Build-Variant 'E0_no_iatdir' @($CH_IATD, '{ w32(b, 0); w32(b, 0); }')

$ra = Get-Product $vA @() 'test\samples\global1.fl' "$tmp\wxv-a.exe"
Check 'A: .data made executable is refused (I15)' ($ra.Exit -ne 0 -and $ra.Log -match 'I15') "exit=$($ra.Exit)"
$rb2 = Get-Product $vB @() 'test\samples\global1.fl' "$tmp\wxv-b.exe"
Check 'B: .data made W|X is refused (I14)' ($rb2.Exit -ne 0 -and $rb2.Log -match 'I14') "exit=$($rb2.Exit)"
$rc = Get-Product $vC @() 'test\samples\global1.fl' "$tmp\wxv-c.exe"
Check 'C: .text made writable is refused (I14)' ($rc.Exit -ne 0 -and $rc.Log -match 'I14') "exit=$($rc.Exit)"

Head '[5] control run: same injection with the assertions disabled'
# NOTE on choosing the injection: it must be BEHAVIOUR-NEUTRAL, otherwise this control proves nothing.
#   .data made executable-only (X without W) makes global writes hit a read-only page -> the product
#   dies with 0xC0000005, i.e. the defect WOULD be visible to a behaviour-only test. The neutral form
#   is DATA = 0xE0000040: X added while W kept, so the product still runs exactly as before.
$vD = Build-Variant 'D_data_wx_noassert' @(
  $CH_DATA, 'const uint32_t DATA_SEC_CHAR = 0xE0000040;',
  $AS_WX,   'if (0 && (c & SCN_WRITE) && (c & SCN_EXEC)) {',
  $AS_EXEC, 'if (0 && i > 0 && (c & SCN_EXEC)) {',
  $AS_CNT,  'if (0 && n_exec != 1) {'
)
$rd = Get-Product $vD @() 'test\samples\global1.fl' "$tmp\wxv-d.exe"
Check 'D: violation compiles once the assertions are off' ($rd.Exit -eq 0) "exit=$($rd.Exit)"
if ($rd.Exit -eq 0) {
  $ds = (Get-Pe "$tmp\wxv-d.exe").Sections | Where-Object { $_.Name -eq '.data' }
  Check 'D: the injected violation really is in the product' ($ds -and ($ds.Chars -band $SCN_EXEC)) ("chars=0x{0:X8}" -f $ds.Chars)
  $ed = Run-Product "$tmp\wxv-d.exe"
  $en = Run-Product "$tmp\wx-two.exe"
  Check 'D: behaviour is unchanged (exit codes equal)' ($ed -eq $en) "violating=$ed normal=$en"
}

# ---------------------------------------------------------------- [6] loader requirement, pinned
Head '[6] pinning the loader requirement: no IAT directory -> compiler refuses, force it -> crash'
# E0: with I18 in place, the compiler REFUSES to emit the product at all (the loader's hidden
#     requirement has been promoted to a compile-time assertion)
$re0 = Get-Product $vE0 @() 'test\samples\global1.fl' "$tmp\wxv-e0.exe"
Check 'E0: omitting dir[12] is refused by I18' ($re0.Exit -ne 0 -and $re0.Log -match 'I18') "exit=$($re0.Exit)"
# E: with I18 disabled so the product IS emitted, the loader then crashes on it -- this is the
#    empirical evidence behind requiring dir[12] once the IAT lives on its own page
$AS_IAT0 = 'if (ir == 0 || is == 0) {'
$AS_IAT1 = 'if (sl < ir || sl + 8 > ir + is) {'
$AS_IAT2 = 'if (ir < idata_rva || ir + is > idata_rva + idata_vsize) {'
$vE = Build-Variant 'E_no_iatdir_noassert' @(
  $CH_IATD, '{ w32(b, 0); w32(b, 0); }',
  $AS_IAT0, 'if (0 && (ir == 0 || is == 0)) {',
  $AS_IAT1, 'if (0 && (sl < ir || sl + 8 > ir + is)) {',
  $AS_IAT2, 'if (0 && (ir < idata_rva || ir + is > idata_rva + idata_vsize)) {'
)
$re = Get-Product $vE @() 'test\samples\global1.fl' "$tmp\wxv-e.exe"
Check 'E: product builds once I18 is off' ($re.Exit -eq 0) "exit=$($re.Exit)"
if ($re.Exit -eq 0) {
  $peE = Get-Pe "$tmp\wxv-e.exe"
  Check 'E: IAT directory really is empty in that product' (($peE.IatRva -eq 0) -and ($peE.IatSize -eq 0)) ""
  # v1.4.25: observe the fault via crashprobe (debugger-attached) instead of Run-Product.
  #   Measured 2026-09-19: Run-Product (Start-Process -Wait, even with a 20s cap) hits a *stall* on this
  #   product -- the process sits at 1 thread, CPU 0, WaitReason = LpcReply (the console/CSRSS path),
  #   neither crashing nor exiting, so the check could only ever report 'timeout'. With a debugger
  #   attached the fault is delivered to the debugger first, so the same product reports
  #   `exception=0xC0000005` immediately and deterministically -- which is exactly the evidence this
  #   case is after ("omitting dir[12] breaks the product at load time").
  if (-not (Test-Path $crashprobe)) {
    & $gcc -O2 -Wall -o $crashprobe (Join-Path $root 'libcs\crashprobe\crashprobe.c')
    Check 'probe: crashprobe builds' ($LASTEXITCODE -eq 0) ""
  }
  $ee = (& $crashprobe "$tmp\wxv-e.exe" 15000 | Out-String).Trim()
  Check 'E: and the product CRASHES (0xC0000005)' ($ee -match 'exception=0xC0000005') "$ee"
}

# ---------------------------------------------------------------- [7] ASLR (v1.4.14)
Head '[7] ASLR: declared bits + relocation directory + the loader really randomises the base'
# The whole point of this round: the product declares DYNAMIC_BASE|HIGH_ENTROPY_VA|NX_COMPAT (0x0160),
# keeps the relocation directory 0/0 (no .reloc section), and the loader then REALLY moves it --
# measured by libcs\aslrprobe (CREATE_SUSPENDED + PEB.ImageBaseAddress vs the image's own preferred
# base), not by reading the flag back at ourselves. "loaded != preferred" is the direct evidence;
# "N runs differed from each other" would only be a probability argument.
$DYN_BASE = 0x0040; $HI_ENTROPY = 0x0020; $NX = 0x0100; $RELOCS_STRIPPED = 0x0001
$aslrprobe = Join-Path $root 'libcs\aslrprobe\aslrprobe.exe'
if (-not (Test-Path $aslrprobe)) {
  & $gcc -O2 -Wall -o $aslrprobe (Join-Path $root 'libcs\aslrprobe\aslrprobe.c')
  Check 'probe: aslrprobe builds' ($LASTEXITCODE -eq 0) ""
}

function Get-DllChars([string]$exe) {
  $b = [IO.File]::ReadAllBytes($exe)
  $lf = [BitConverter]::ToUInt32($b, 0x3C)
  # DllCharacteristics file offset 0x9E = opt + 0x46 with opt = lf + 24 = 0x58 -- which IS the PE32+
  # SPEC offset. (A note added on 2026-09-18 claimed our header omitted the OS/Image/Subsystem version
  # block so everything sat 0x18 early; that was WRONG -- measured again on four product forms with
  # objdump -p as an independent reader: the version block is written and every later field is at its
  # spec offset. See the [7a] layout pin below and src\pe.c's I20 block.) COFF Characteristics is 0x56.
  return [pscustomobject]@{
    Lf = $lf
    CoffChars = [BitConverter]::ToUInt16($b, $lf + 4 + 18)
    DllChars  = [BitConverter]::ToUInt16($b, 0x9E)
  }
}
# PE32+ optional-header layout, read at the SPEC offsets only. This pins the header so the false story
# above cannot come back: if a future round shifts the header, these checks go red instead of the gate
# silently reading the wrong dword (which is exactly what produced that false conclusion).
function Get-OptLayout([string]$exe) {
  $b = [IO.File]::ReadAllBytes($exe)
  $lf = [BitConverter]::ToUInt32($b, 0x3C)
  $opt = $lf + 24
  return [pscustomobject]@{
    Lf            = $lf
    Opt           = $opt
    OptHdrSz      = [BitConverter]::ToUInt16($b, $lf + 4 + 16)
    OsVer         = [BitConverter]::ToUInt16($b, $opt + 0x28)
    SubsysVer     = [BitConverter]::ToUInt16($b, $opt + 0x30)
    SizeOfImage   = [BitConverter]::ToUInt32($b, $opt + 0x38)
    SizeOfHeaders = [BitConverter]::ToUInt32($b, $opt + 0x3C)
    Subsystem     = [BitConverter]::ToUInt16($b, $opt + 0x44)
    DllChars      = [BitConverter]::ToUInt16($b, $opt + 0x46)
    NumRva        = [BitConverter]::ToUInt32($b, $opt + 0x6C)
  }
}
function Get-RelocHdr([string]$exe) {
  $b = [IO.File]::ReadAllBytes($exe)
  $lf = [BitConverter]::ToUInt32($b, 0x3C); $opt = $lf + 24
  return @([BitConverter]::ToUInt32($b, $opt + 0x70 + 5 * 8), [BitConverter]::ToUInt32($b, $opt + 0x70 + 5 * 8 + 4))
}
# one probe run -> the parsed fields (or $null when the target cannot be started, e.g. err=740)
function Invoke-Aslr([string]$exe) {
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $log = & $aslrprobe $exe 2>&1 } finally { $ErrorActionPreference = $eap }
  $t = $log -join "`n"
  $m = [regex]::Match($t, 'preferred=0x([0-9A-F]+) loaded=0x([0-9A-F]+) dllchars=0x([0-9A-F]+) coffchars=0x([0-9A-F]+) hdr=(\w+) randomized=(yes|no) hi_entropy=(yes|no)')
  if (-not $m.Success) { return $null }
  return [pscustomobject]@{
    Preferred = [uint64]("0x" + $m.Groups[1].Value)
    Loaded    = [uint64]("0x" + $m.Groups[2].Value)
    DllChars  = [uint16]("0x" + $m.Groups[3].Value)
    CoffChars = [uint16]("0x" + $m.Groups[4].Value)
    Hdr       = $m.Groups[5].Value
    Rand      = $m.Groups[6].Value
    HiEntropy = $m.Groups[7].Value
  }
}

# --- [7a] declared form, read back out of the product bytes ---
$aslrShapes = @(
  @{ n = 'single-sec';  f = @();                  s = 'test\samples\st1.fl';     o = "$tmp\ax-one.exe" },
  @{ n = 'two-sec';     f = @();                  s = 'test\samples\global1.fl'; o = "$tmp\ax-two.exe" },
  @{ n = 'debug';       f = @('-debug');          s = 'test\samples\st1.fl';     o = "$tmp\ax-dbg.exe" }
)
foreach ($sh in $aslrShapes) {
  $r = Get-Product $flint $sh.f $sh.s $sh.o
  Check "$($sh.n): compile exit=0" ($r.Exit -eq 0) "exit=$($r.Exit)"
  if ($r.Exit -ne 0) { continue }
  $dc = Get-DllChars $sh.o
  Check "$($sh.n): DllCharacteristics has DYNAMIC_BASE|HIGH_ENTROPY_VA|NX_COMPAT" `
        (($dc.DllChars -band ($DYN_BASE -bor $HI_ENTROPY -bor $NX)) -eq ($DYN_BASE -bor $HI_ENTROPY -bor $NX)) `
        ("dllchars=0x{0:X4}" -f $dc.DllChars)
  Check "$($sh.n): no RELOCS_STRIPPED in DllCharacteristics" (($dc.DllChars -band $RELOCS_STRIPPED) -eq 0) ("dllchars=0x{0:X4}" -f $dc.DllChars)
  # the loader eats ASLR when EITHER header carries the stripped bit -> both are checked (I21)
  Check "$($sh.n): no RELOCS_STRIPPED in COFF Characteristics" (($dc.CoffChars -band $RELOCS_STRIPPED) -eq 0) ("coffchars=0x{0:X4}" -f $dc.CoffChars)
  # no .reloc: the complete ASLR form is "no absolute address in the image + flags + directory 0/0"
  $rh = Get-RelocHdr $sh.o
  Check "$($sh.n): relocation directory is 0/0 (no .reloc)" (($rh[0] -eq 0) -and ($rh[1] -eq 0)) ("rva=0x{0:X} size=0x{1:X}" -f $rh[0], $rh[1])
  $names = (Get-Pe $sh.o).Sections | ForEach-Object { $_.Name }
  Check "$($sh.n): no .reloc section exists" (-not ($names -contains '.reloc')) ($names -join ',')
  # layout pin (v1.4.16, task card T-20260918-012105): the optional header is at its PE32+ spec offsets.
  # The version block at opt+0x28..0x37 is present, so opt+0x46 IS the spec position of
  # DllCharacteristics -- i.e. the 0x9E read above is spec, not "shifted by 0x18".
  $ol = Get-OptLayout $sh.o
  Check "$($sh.n): version block present (OS/Subsystem version at opt+0x28 / opt+0x30)" (($ol.OsVer -gt 0) -and ($ol.SubsysVer -gt 0)) ("os={0} subsys={1}" -f $ol.OsVer, $ol.SubsysVer)
  Check "$($sh.n): SizeOfOptionalHeader = 0x70 + 16*8 data directories" ($ol.OptHdrSz -eq 0xF0) ("0x{0:X}" -f $ol.OptHdrSz)
  Check "$($sh.n): Subsystem sits at the spec offset opt+0x44 (=3, console)" ($ol.Subsystem -eq 3) ("subsystem={0}" -f $ol.Subsystem)
  Check "$($sh.n): opt+0x46 read equals the 0x9E read (same dword, spec offset)" ($ol.DllChars -eq $dc.DllChars) ("opt+0x46=0x{0:X4} file0x9E=0x{1:X4}" -f $ol.DllChars, $dc.DllChars)
  Check "$($sh.n): NumberOfRvaAndSizes at opt+0x6C is 16" ($ol.NumRva -eq 16) ("{0}" -f $ol.NumRva)
}

# --- [7b] the loader really moves the image (behaviour, not declaration) ---
$probed = 0; $randoms = 0; $distinct = @()
for ($i = 0; $i -lt 6; $i++) {
  $p = Invoke-Aslr "$tmp\ax-two.exe"
  if ($null -eq $p) { break }                            # e.g. err=740 (elevation manifest)
  $probed++
  if ($p.Rand -eq 'yes') { $randoms++ }
  $distinct += $p.Loaded
}
if ($probed -eq 0) {
  Check 'probe: could not start the target (elevation?) - runtime evidence skipped' $false 'aslrprobe failed on every run'
} else {
  Check "probe: ran $probed times" ($probed -eq 6) ""
  Check 'probe: loaded base != preferred base on EVERY run (loader relocated the image)' ($randoms -eq $probed) "$randoms/$probed"
  Check 'probe: loaded base is 64K-aligned (HIGH_ENTROPY_VA in effect)' (($distinct | Where-Object { ($_ % 0x10000) -ne 0 }).Count -eq 0) (($distinct | ForEach-Object { '0x{0:X}' -f $_ }) -join ' ')
  Write-Host ("      distinct bases over {0} runs: {1}" -f $probed, (($distinct | Select-Object -Unique | ForEach-Object { '0x{0:X}' -f $_ }) -join ' '))
}

# --- [7c] the injected violation must be refused by I21 ---
Head '[7c] injected RELOCS_STRIPPED must be refused by I21'
$CH_COFFCH = 'w16(b, 0x0022);            // Characteristics'
$vF = Build-Variant 'F_relocs_stripped' @($CH_COFFCH, 'w16(b, 0x0023);            // Characteristics (RELOCS_STRIPPED injected)')
$rf = Get-Product $vF @() 'test\samples\st1.fl' "$tmp\axv-f.exe"
Check 'F: RELOCS_STRIPPED is refused (I21)' ($rf.Exit -ne 0 -and $rf.Log -match 'I21') "exit=$($rf.Exit)"

# --- [7d] control run: same injection, assertion off -> product IS emitted; note the loader's response.
#     The injection is BEHAVIOUR-NEUTRAL on purpose (only bit0 of COFF Characteristics changes, and the
#     image carries no relocation bits the loader needs), so a behaviour-only regression sees nothing --
#     which is exactly why this class of defect needs an assertion. The control also measures (rather
#     than assumes) what the loader does with the flag present.
Head '[7d] control run: RELOCS_STRIPPED with I21 disabled (behaviour-neutral injection)'
$AS_I21 = 'if ((coff_ch & RELOCS_STRIPPED) || (dll_ch & RELOCS_STRIPPED)) {'
$vG = Build-Variant 'G_stripped_noassert' @(
  $CH_COFFCH, 'w16(b, 0x0023);            // Characteristics (RELOCS_STRIPPED injected)',
  $AS_I21,    'if (0 && ((coff_ch & RELOCS_STRIPPED) || (dll_ch & RELOCS_STRIPPED))) {'
)
$rg = Get-Product $vG @() 'test\samples\st1.fl' "$tmp\axv-g.exe"
Check 'G: product builds once I21 is off' ($rg.Exit -eq 0) "exit=$($rg.Exit)"
if ($rg.Exit -eq 0) {
  $dg = Get-DllChars "$tmp\axv-g.exe"
  Check 'G: the injected bit really is in the product' (($dg.CoffChars -band $RELOCS_STRIPPED) -ne 0) ("coffchars=0x{0:X4}" -f $dg.CoffChars)
  $eg = Run-Product "$tmp\axv-g.exe"
  Check 'G: behaviour unchanged (exit code equal to the normal product)' ($eg -eq 34) "violating=$eg normal=34"
  $gp = Invoke-Aslr "$tmp\axv-g.exe"
  if ($null -eq $gp) {
    Write-Host '      (probe could not start that product - loader response not measured)'
  } else {
    Write-Host ("      loader response to RELOCS_STRIPPED: loaded=0x{0:X} preferred=0x{1:X} randomized={2}" -f $gp.Loaded, $gp.Preferred, $gp.Rand)
    Check 'G: loader still started the image (stripped bit is not fatal)' $true "loaded=0x$('{0:X}' -f $gp.Loaded)"
  }
}
# G also pins the point of the assertion in one line: the ASSERTION is the only thing that speaks.

# --- [8] GUI subsystem switch (-gui, v1.4.28, card T-20260927-212533) ---
# SPEC's face-gate item 1 is "no console window on double-click", and that is exactly ONE word of the
# optional header: Subsystem at opt+0x44 (3 = CONSOLE default, 2 = WINDOWS_GUI with -gui). The judge
# below pins the switch in both directions and -- more to the point -- pins that it moves NOTHING ELSE:
# the same sample compiled with and without -gui must differ in exactly ONE byte, at exactly that
# offset, and must behave identically. Same trick as the ImageBase experiment: a "minimal change"
# claim is only worth something once it is counted.
Head '[8] -gui subsystem switch (Subsystem opt+0x44: 3=console default, 2=GUI)'
$rp = Get-Product $flint @()       'test\samples\st1.fl' "$tmp\gui-plain.exe"
$rg = Get-Product $flint @('-gui') 'test\samples\st1.fl' "$tmp\gui-win.exe"
Check 'gui: both forms compile' (($rp.Exit -eq 0) -and ($rg.Exit -eq 0)) "plain=$($rp.Exit) gui=$($rg.Exit)"
if ($rp.Exit -eq 0 -and $rg.Exit -eq 0) {
  $sp = (Get-OptLayout "$tmp\gui-plain.exe").Subsystem
  $sg = (Get-OptLayout "$tmp\gui-win.exe").Subsystem
  Check 'gui: default product is Subsystem=3 (console)' ($sp -eq 3) "subsystem=$sp"
  Check 'gui: -gui product is Subsystem=2 (GUI)' ($sg -eq 2) "subsystem=$sg"
  $ba = [IO.File]::ReadAllBytes("$tmp\gui-plain.exe")
  $bb = [IO.File]::ReadAllBytes("$tmp\gui-win.exe")
  $dcnt = 0; $doff = -1
  if ($ba.Length -eq $bb.Length) {
    for ($i = 0; $i -lt $ba.Length; $i++) { if ($ba[$i] -ne $bb[$i]) { $dcnt++; if ($doff -lt 0) { $doff = $i } } }
  } else { $dcnt = -1 }
  $lfanew = [BitConverter]::ToUInt32($ba, 0x3C)
  $subOff = [int]$lfanew + 4 + 20 + 0x44
  Check 'gui: same product length as the default form' ($ba.Length -eq $bb.Length) ("plain={0} gui={1}" -f $ba.Length, $bb.Length)
  Check 'gui: exactly ONE byte differs (nothing else moves)' ($dcnt -eq 1) "diffcount=$dcnt"
  Check 'gui: that byte is Subsystem (e_lfanew+4+20+0x44)' ($doff -eq $subOff) ("diff=0x{0:X} want=0x{1:X}" -f $doff, $subOff)
  $ep = Run-Product "$tmp\gui-plain.exe"
  $eg = Run-Product "$tmp\gui-win.exe"
  Check 'gui: behaviour unchanged (both products exit 34)' (($ep -eq 34) -and ($eg -eq 34)) "plain=$ep gui=$eg"
}

Head 'summary'
Write-Host ("passed {0} / failed {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
