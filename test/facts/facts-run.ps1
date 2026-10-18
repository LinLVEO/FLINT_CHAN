# facts-run.ps1 -- probe runner for the assertion ledger (ASCII only, no BOM).
#
# Lives next to the probes in E:\FLINT-lab\test\facts\ and is the single executable that
# every "review command" in the DSH assertion ledger (task-engine, file name is Chinese:
# duan-yan-tai-zhang.md) calls.
#
# WHY IT EXISTS: b1_emit.exe has no -o switch -- it always drops <source>.exe next to the
# source.  The probes must therefore never be compiled in place, or E:\FLINT-lab would fill
# up with .exe files.  This runner copies the probe into a scratch mirror under
# %TEMP%\dsh-assert\work\<probe>_<compiler>\test\facts\ (plus a copy of lib\ so that the
# probes' "../../lib/*.fl" includes still resolve) and compiles THERE.
#
# USAGE (one end):
#   powershell -NoProfile -ExecutionPolicy Bypass -File facts-run.ps1 -Probe f002_global -Compiler boot
# USAGE (both ends + byte compare of stdout, used by F-006):
#   powershell -NoProfile -ExecutionPolicy Bypass -File facts-run.ps1 -Probe f006_cn -Compare flint boot -ExpectExit 42
#
#   -Probe     <name>            probe base name in this directory (".fl" optional)
#   -Compiler  flint|boot|oldboot
#                                flint   = E:\FLINT-lab\flint.exe            (the real compiler)
#                                boot    = E:\FLINT-lab\boot\b1_emit.exe       (the current bootstrap)
#                                oldboot = a bootstrap built from an OLDER git revision
#                                          (default cc06233~1 = the commit before v1.5.0);
#                                          built once into %TEMP%\dsh-assert\oldboot-bin\
#   -Compare   a b               run BOTH ends, require each exit == -ExpectExit AND require
#                                their raw stdout bytes to be identical
#   -ExpectExit <n>              required exit code of the produced PROGRAM (default 0)
#
# EXIT CODE: 0 = everything matched, 1 = mismatch/compile failure (one line of reason on stdout).
#
# NOTE ON THE OLD BOOTSTRAP: E:\FLINT-lab's working tree equals git HEAD for tracked files,
# so a "worktree at HEAD" would rebuild a byte-identical compiler and the A/B would be empty.
# The runner therefore uses cc06233~1, i.e. the revision right before the str([...]) work,
# and the resulting b1_emit.exe is SHA256-identical to the baseline snapshot that the earlier
# strkit round kept at E:\FLINT-lab\tmp\strkit\baseboot\b1_emit.exe.

param(
    [Parameter(Mandatory = $true)][string]$Probe,
    [string]$Compiler = '',
    # NOTE: a comma separated string, NOT a string[]. "powershell -File script.ps1 -Compare a b"
    # does not bind two values to a string[] parameter (the second one is left dangling and the
    # guard fires "needs exactly two compiler names"), so the ledger passes "-Compare flint,boot".
    [string]$Compare = '',
    [int]$ExpectExit = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$factsDir = $PSScriptRoot
$lab      = Split-Path (Split-Path $factsDir -Parent) -Parent          # E:\FLINT-lab
$flintExe = Join-Path $lab 'flint.exe'
$bootExe  = Join-Path $lab 'boot\b1_emit.exe'
$libDir   = Join-Path $lab 'lib'
$tmpRoot  = Join-Path $env:TEMP 'dsh-assert'
$oldRev   = 'cc06233~1'
$oldBin   = Join-Path $tmpRoot 'oldboot-bin\b1_emit.exe'

$script:Failed = 0
# NOTE: Say/Fail write straight to the console handle, NOT through Write-Output, because the
# helper functions below RETURN values -- anything sent to the success pipeline would be
# swallowed into those return values (this bit once: the per-leg line vanished).
function Say([string]$m) { [Console]::Out.WriteLine($m) }
function Fail([string]$m) { [Console]::Out.WriteLine("FAIL " + $m); $script:Failed = 1 }

function Q([string]$s) { if ($s -match ' ') { return ('"' + $s + '"') } return $s }

# Run an external program, capture raw stdout/stderr to files, return @{Code; Out; Err}
function Invoke-Cap([string]$exe, [string[]]$argv) {
    $tag = [guid]::NewGuid().ToString('N')
    $o = Join-Path $tmpRoot ("cap-$tag.out")
    $e = Join-Path $tmpRoot ("cap-$tag.err")
    $quoted = @()
    foreach ($a in $argv) { $quoted += (Q $a) }
    $p = Start-Process -FilePath $exe -ArgumentList $quoted -NoNewWindow -Wait -PassThru `
         -RedirectStandardOutput $o -RedirectStandardError $e
    $ot = ''
    if (Test-Path $o) { $ot = [IO.File]::ReadAllText($o, [Text.Encoding]::UTF8) }
    $et = ''
    if (Test-Path $e) { $et = [IO.File]::ReadAllText($e, [Text.Encoding]::UTF8) }
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    return @{ Code = $p.ExitCode; Out = $ot; Err = $et }
}

function Ensure-OldBoot() {
    if (Test-Path $oldBin) { return $oldBin }
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { Fail 'oldboot: git not found on PATH'; return '' }
    $wt = Join-Path $tmpRoot 'oldboot-wt'
    New-Item -ItemType Directory -Force -Path $tmpRoot, (Split-Path $oldBin -Parent) | Out-Null
    if (Test-Path $wt) { Remove-Item $wt -Recurse -Force }
    Say ("oldboot: git worktree add --detach " + $wt + " " + $oldRev)
    $r = Invoke-Cap $git @('-C', $lab, 'worktree', 'add', '--detach', $wt, $oldRev)
    Say ("oldboot: worktree add exit=" + $r.Code)
    if ($r.Code -ne 0) { Fail ('oldboot: worktree add failed: ' + $r.Err.Trim()); return '' }
    $oldSrc = Join-Path $wt 'boot\b1_emit.fl'
    if (-not (Test-Path $oldSrc)) { Fail 'oldboot: boot\b1_emit.fl missing in worktree'; return '' }
    Say ("oldboot: compiling " + $oldSrc + " with the current flint.exe")
    $r2 = Invoke-Cap $flintExe @($oldSrc)
    Say ("oldboot: flint exit=" + $r2.Code)
    if ($r2.Code -ne 0) { Fail ('oldboot: build failed: ' + $r2.Out.Trim()); return '' }
    $built = Join-Path $wt 'boot\b1_emit.exe'
    if (-not (Test-Path $built)) { Fail 'oldboot: no b1_emit.exe produced'; return '' }
    Copy-Item $built $oldBin -Force
    # A boot compiler loads its own support libraries (lib_parse/lib_print/lib_str/lib_token)
    # from the directory the .exe sits in, so they must travel with the cached copy.
    $binDir = Split-Path $oldBin -Parent
    Copy-Item (Join-Path $wt 'boot\*.fl') $binDir -Force
    $h = (Get-FileHash $oldBin -Algorithm SHA256).Hash.Substring(0, 16)
    Say ("oldboot: cached " + $oldBin + " sha256=" + $h + " (+ " + @(Get-ChildItem (Join-Path $binDir '*.fl')).Count + " support .fl)")
    # leave nothing stale registered in the FLINT repo
    $r3 = Invoke-Cap $git @('-C', $lab, 'worktree', 'remove', '--force', $wt)
    Say ("oldboot: worktree remove exit=" + $r3.Code)
    return $oldBin
}

function Resolve-Compiler([string]$name) {
    switch ($name) {
        'flint'   { return $flintExe }
        'boot'    { return $bootExe }
        'oldboot' { return (Ensure-OldBoot) }
        default   { Fail ("unknown compiler '" + $name + "'"); return '' }
    }
}

# Compile + run one probe on one end. Returns @{Code; Exe; Stdout(bytes); CompileCode; CompileText}
function Run-One([string]$probeName, [string]$compilerName) {
    $src = Join-Path $factsDir ($probeName + '.fl')
    if (-not (Test-Path $src)) { Fail ('probe not found: ' + $src); return $null }
    $exePath = Resolve-Compiler $compilerName
    if (-not $exePath) { return $null }
    $mirror = Join-Path $tmpRoot ('work\' + $probeName + '_' + $compilerName)
    if (Test-Path $mirror) { Remove-Item $mirror -Recurse -Force }
    $mFacts = Join-Path $mirror 'test\facts'
    New-Item -ItemType Directory -Force -Path $mFacts | Out-Null
    Copy-Item $src (Join-Path $mFacts ($probeName + '.fl')) -Force
    $text = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
    if ($text -match 'include') {
        New-Item -ItemType Directory -Force -Path (Join-Path $mirror 'lib') | Out-Null
        Copy-Item (Join-Path $libDir '*.fl') (Join-Path $mirror 'lib') -Force
    }
    $mSrc = Join-Path $mFacts ($probeName + '.fl')
    $c = Invoke-Cap $exePath @($mSrc)
    $cOut = ($c.Out + $c.Err).Trim() -replace "`r?`n", ' | '
    if ($c.Code -ne 0) {
        Say ("  [" + $probeName + "/" + $compilerName + "] COMPILE exit=" + $c.Code + " :: " + $cOut)
        Fail ($probeName + '/' + $compilerName + ': compile failed (exit ' + $c.Code + ')')
        return $null
    }
    $mExe = Join-Path $mFacts ($probeName + '.exe')
    if (-not (Test-Path $mExe)) {
        Say ("  [" + $probeName + "/" + $compilerName + "] COMPILE exit=0 but no .exe")
        Fail ($probeName + '/' + $compilerName + ': compiler reported success but produced no .exe')
        return $null
    }
    $o = Join-Path $tmpRoot ('stdout-' + $probeName + '-' + $compilerName + '.bin')
    $e2 = Join-Path $tmpRoot ('stderr-' + $probeName + '-' + $compilerName + '.bin')
    $p = Start-Process -FilePath $mExe -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e2
    $bytes = [IO.File]::ReadAllBytes($o)
    $txt = [Text.Encoding]::UTF8.GetString($bytes).TrimEnd("`r", "`n")
    Say ("  [" + $probeName + "/" + $compilerName + "] compile=0 program_exit=" + $p.ExitCode + " stdout_bytes=" + $bytes.Length + " stdout=[" + $txt + "]")
    return @{ Code = $p.ExitCode; Stdout = $bytes; StdoutFile = $o; CompileText = $cOut }
}

Say ("facts-run probe=" + $Probe + " expect_exit=" + $ExpectExit + " compile_output_deleted=yes scratch=" + $tmpRoot)

$ends = @($Compare -split ',' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })

if ($ends.Count -gt 0) {
    if ($ends.Count -ne 2) { Fail '-Compare needs exactly two compiler names (e.g. -Compare flint,boot)'; }
    else {
        $a = Run-One $Probe $ends[0]
        $b = Run-One $Probe $ends[1]
        if ($a -and $b) {
            if ($a.Code -ne $ExpectExit) { Fail ($Probe + '/' + $ends[0] + ': program exit ' + $a.Code + ' != ' + $ExpectExit) }
            if ($b.Code -ne $ExpectExit) { Fail ($Probe + '/' + $ends[1] + ': program exit ' + $b.Code + ' != ' + $ExpectExit) }
            $same = ($a.Stdout.Length -eq $b.Stdout.Length)
            $firstDiff = -1
            if ($same) {
                for ($i = 0; $i -lt $a.Stdout.Length; $i++) {
                    if ($a.Stdout[$i] -ne $b.Stdout[$i]) { $same = $false; $firstDiff = $i; break }
                }
            } else { $firstDiff = [Math]::Min($a.Stdout.Length, $b.Stdout.Length) }
            Say ("  compare " + $ends[0] + " vs " + $ends[1] + ": identical=" + $same + " len_a=" + $a.Stdout.Length + " len_b=" + $b.Stdout.Length + " first_diff_byte=" + $firstDiff)
            if (-not $same) { Fail ($Probe + ': the two ends produced different stdout bytes') }
        }
    }
} else {
    if (-not $Compiler) { Fail 'need -Compiler or -Compare' }
    else {
        $r = Run-One $Probe $Compiler
        if ($r) {
            if ($r.Code -ne $ExpectExit) { Fail ($Probe + '/' + $Compiler + ': program exit ' + $r.Code + ' != ' + $ExpectExit) }
        }
    }
}

if ($script:Failed -ne 0) {
    Say ("RESULT FAIL probe=" + $Probe)
    exit 1
}
Say ("RESULT OK probe=" + $Probe)
exit 0
