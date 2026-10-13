# verify-j1.ps1 -- re-runnable gate for enginesnap's J1 criterion.
# J1 = every value shown by the mini-window matches the engine status script output at the same moment.
# How: (1) run the engine status script, which regenerates state-snapshot.txt
#      (2) run enginesnap in self-check mode (puts its parsed values into a text report)
#      (3) compare the two -- numbers key by key, and the Chinese string BYTE-exactly
#          (the snapshot is UTF-8, the window works in ANSI/GBK, so the string is compared after
#           converting the snapshot value with code page 936 -- that is exactly what the app does)
# ASCII only on purpose: a .ps1 containing non-ASCII needs a UTF-8 BOM (see memory rule).
# NOTE: the engine status script's NAME IS CHINESE -- so this file must NOT hard-code that path
# (a non-ASCII path here would make this whole file non-ASCII, and without a BOM PowerShell 5.1
#  would decode it as GBK and report "the -File argument does not exist"). It is resolved by
# wildcard instead, which also keeps this file pure ASCII.
param(
  [string]$StatusDir = "C:\Users\20838\Desktop\.dsh-tools\task-engine",
  [string]$Snapshot  = "C:\Users\20838\Desktop\.dsh-tools\task-engine\state-snapshot.txt",
  [string]$App       = "E:\FLINT-lab\apps\enginesnap\enginesnap.exe",
  [string]$Dump      = "E:\FLINT-lab\tmp\row-probe\enginesnap-dump.txt"
)
$ErrorActionPreference = 'Stop'
$GBK = [Text.Encoding]::GetEncoding(936)

$Status = (Get-ChildItem -LiteralPath $StatusDir -Filter '*-status.ps1' | Select-Object -First 1).FullName
if (-not $Status) { Write-Output "FAIL: status script not found in $StatusDir"; exit 1 }
Write-Output ("[1/3] running the engine status script ({0})..." -f (Split-Path $Status -Leaf))
$null = powershell -NoProfile -ExecutionPolicy Bypass -File $Status 2>&1 | Out-String
if (-not (Test-Path $Snapshot)) { Write-Output "FAIL: snapshot not produced"; exit 1 }
$snap = @{}
foreach ($l in (Get-Content $Snapshot -Encoding UTF8)) {
  $i = $l.IndexOf('=')
  if ($i -gt 0) { $snap[$l.Substring(0, $i)] = $l.Substring($i + 1) }
}

Write-Output "[2/3] running enginesnap self-check..."
$flag = Join-Path (Split-Path $App) 'snap.dump'
Set-Content -LiteralPath $flag -Value '1' -Encoding ASCII
if (Test-Path $Dump) { Remove-Item $Dump -Force }
& $App | Out-Null
$appExit = $LASTEXITCODE
Remove-Item $flag -Force
if ($appExit -ne 0) { Write-Output ("FAIL: app exit={0}" -f $appExit); exit 1 }
if (-not (Test-Path $Dump)) { Write-Output "FAIL: no report produced"; exit 1 }

$dumpGbk = [IO.File]::ReadAllText($Dump, $GBK)
# NOTE: variable names are CASE-INSENSITIVE in PowerShell -- a hashtable here MUST NOT be called
# $dump, or [string]$Dump gets coerced to a string and indexing blows up (known trap, hit again).
# NOTE 2: do NOT split the report on spaces -- a VALUE may contain spaces (mem_time = "date time").
#   Parse numbers with a regex, and read string values up to end of line instead.
$rep = @{}
foreach ($k in @('snap_bytes', 'ansi_bytes', 'tasks_open', 'cand', 'sec_danger', 'sec_warn', 'sec_info', 'disk_c_free_x10', 'disk_e_free_x10')) {
  $m = [regex]::Match($dumpGbk, ("(?:^|\s)" + $k + "=(-?\d+)"))
  if ($m.Success) { $rep[$k] = $m.Groups[1].Value }
}
$m = [regex]::Match($dumpGbk, "mem_time=([^\r\n]*)")
if ($m.Success) { $rep['mem_time'] = $m.Groups[1].Value.Trim() }
$m = [regex]::Match($dumpGbk, "task_first=([^\r\n]*)")
if ($m.Success) { $rep['task_first'] = $m.Groups[1].Value.Trim() }

Write-Output "[3/3] comparing..."
$keys = @('tasks_open', 'cand', 'sec_danger', 'sec_warn', 'sec_info', 'disk_c_free_x10', 'disk_e_free_x10', 'mem_time')
$pass = 0
$fail = 0
foreach ($k in $keys) {
  $a = $snap[$k]
  $b = $rep[$k]
  if ($null -ne $a -and $a -eq $b) { Write-Output ("  OK   {0} = {1}" -f $k, $a); $pass++ }
  else { Write-Output ("  FAIL {0}: snapshot='{1}' window='{2}'" -f $k, $a, $b); $fail++ }
}
# Chinese value: byte-exact after the same UTF-8 -> GBK conversion the app performs
$want = $snap['task_first']
$got = if ($rep.ContainsKey('task_first')) { $rep['task_first'] } else { "<missing>" }
if ($want -eq $got) { Write-Output ("  OK   task_first = {0}" -f $got); $pass++ }
else { Write-Output ("  FAIL task_first: snapshot='{0}' window='{1}'" -f $want, $got); $fail++ }

Write-Output "----"
Write-Output ("pass {0} / fail {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
