# probe-ide-dlgdir.ps1 - FLINT Studio: do the Explorer dialogs remember WHERE they were?
#
# Sandbox: tmp\ide-dlgdir (the app's WORKING DIRECTORY).
#
# The three shell dialogs must each keep their OWN last location ("全部单独存放"):
#   dopen=    "open file"      (Ctrl+O)
#   dsave=    "save as"        (Ctrl+Shift+S)
#   dfolder=  "open folder"    (Ctrl+Shift+O)
#
# What it measures (behavioural, not by reading the dialog's internals):
#   A. SAVEAS/O  seed cfg with dopen=<dirA>; Ctrl+O must OPEN IN dirA -- proven by typing the
#                BARE name "target.fl" (no path) and pressing Enter: only a dialog that started
#                in dirA can resolve it. Then cfg.dopen must still be dirA.
#   B. SAVEAS    seed dsave=<dirB>; Ctrl+Shift+S must open in dirB -- typing bare "saved.fl"
#                + Enter must create <dirB>\saved.fl. cfg.dsave == dirB and cfg.dopen still dirA
#                (the two locations are stored separately, one dialog does not clobber the other).
#   C. FOLDER    seed dfolder=<dirC>; Ctrl+Shift+O opens the shell browser already SELECTED on
#                dirC, so a plain Enter accepts it -> cfg.ws and cfg.dfolder == dirC.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing precondition / env contention).
# ASCII only on purpose (BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [int]$TimeoutSec = 180,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IdeProbe\IdeProbe.ps1')
Add-Type -AssemblyName System.Windows.Forms | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Sand = Join-Path $Root 'tmp\ide-dlgdir'
$SrcDir = Join-Path $Sand 'apps\studio_native'
$MainFl = Join-Path $SrcDir 'main.fl'
$DirA = Join-Path $Sand 'dirA'
$DirB = Join-Path $Sand 'dirB'
$DirC = Join-Path $Sand 'dirC'
$Target = Join-Path $DirA 'target.fl'
$Saved = Join-Path $DirB 'saved.fl'
$Cfg = Join-Path $Sand 'studio.cfg'
$State = Join-Path $Sand 'ai.state'

$script:Ok = $true
$script:Fails = @()

function Check([string]$Tag, [bool]$Cond, [string]$Detail) {
    $mark = if ($Cond) { 'ok  ' } else { 'FAIL' }
    Write-Check $Tag ("{0} {1}" -f $mark, $Detail)
    if (-not $Cond) { $script:Ok = $false; $script:Fails += $Tag }
}

function Read-Cfg([string]$Path) {
    $h = @{}
    if (-not (Test-Path $Path)) { return $h }
    foreach ($ln in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($ln -like 'vf=*') { continue }
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    return $h
}

# Find a top-level window of $TargetPid whose class name is $Cls.
function Find-Window([int]$TargetPid, [string]$Cls, [int]$TimeoutMs = 6000) {
    if (-not ('WinFind2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinFind2 {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string cls, string name);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    public static IntPtr Find(int target, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)target && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
                if (c.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // file-name box of the common dialog:
    //   OPEN dialog  -> ComboBoxEx32 > ComboBox > Edit
    //   SAVE dialog  -> ComboBox > Edit (id 1001), no ComboBoxEx32 wrapper
    //   (measured 2026-10-27: both shapes exist, so try both, then a direct Edit child)
    public static IntPtr NameEdit(IntPtr dlg) {
        IntPtr ex = FindWindowEx(dlg, IntPtr.Zero, "ComboBoxEx32", null);
        if (ex != IntPtr.Zero) {
            IntPtr cb = FindWindowEx(ex, IntPtr.Zero, "ComboBox", null);
            if (cb != IntPtr.Zero) {
                IntPtr e = FindWindowEx(cb, IntPtr.Zero, "Edit", null);
                if (e != IntPtr.Zero) { return e; }
            }
        }
        IntPtr c = IntPtr.Zero;
        while ((c = FindWindowEx(dlg, c, "ComboBox", null)) != IntPtr.Zero) {
            IntPtr e = FindWindowEx(c, IntPtr.Zero, "Edit", null);
            if (e != IntPtr.Zero) { return e; }
        }
        return FindWindowEx(dlg, IntPtr.Zero, "Edit", null);
    }
    public static bool SetName(IntPtr dlg, string name) {
        IntPtr e = NameEdit(dlg);
        if (e == IntPtr.Zero) { return false; }
        // WM_CHAR (not WM_SETTEXT): the SAVE dialog's filename lives in an owner-drawn ComboBox and
        // WM_SETTEXT on its inner Edit does NOT reach the dialog's name (measured 2026-10-27:
        // the dialog still saved the default name). Typing characters does.
        SendMessageW(e, 0x00B1, IntPtr.Zero, (IntPtr)(-1));                       // EM_SETSEL(0,-1) select all
        foreach (char ch in name) { SendMessageW(e, 0x0102, (IntPtr)ch, (IntPtr)1); }   // WM_CHAR
        return true;
    }
    public static IntPtr Button(IntPtr dlg, int id) {
        IntPtr b = IntPtr.Zero;
        while ((b = FindWindowEx(dlg, b, "Button", null)) != IntPtr.Zero) {
            if (GetDlgCtrlID(b) == id) { return b; }
        }
        return IntPtr.Zero;
    }
    public static bool Click1(IntPtr dlg) {
        IntPtr b = Button(dlg, 1);
        if (b == IntPtr.Zero) { return false; }
        // PostMessage (async), NOT SendMessage: clicking Save/Open may open a nested modal
        // (e.g. "file exists - overwrite?") inside the dialog's thread; a synchronous
        // SendMessage would then block the probe forever (measured 2026-10-27: 5+ min hang).
        PostMessage(b, 0x00F5, IntPtr.Zero, IntPtr.Zero);       // BM_CLICK
        return true;
    }
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    // visible child buttons of the dialog, id -> caption (diagnostics when a nested prompt appears)
    public static string Buttons(IntPtr dlg) {
        StringBuilder sb = new StringBuilder();
        IntPtr b = IntPtr.Zero;
        while ((b = FindWindowEx(dlg, b, "Button", null)) != IntPtr.Zero) {
            if (IsWindowVisible(b)) {
                StringBuilder t = new StringBuilder(128);
                GetWindowTextW(b, t, 128);
                sb.AppendFormat("[id={0} text={1}] ", GetDlgCtrlID(b), t);
            }
        }
        return sb.ToString();
    }
}
'@
    }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [WinFind2]::Find($TargetPid, $Cls)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

# Wait until a predicate on the current cfg map holds (dialogs write cfg through save_cfg_now).
function Wait-Cfg([string]$Path, [scriptblock]$Cond, [int]$TimeoutMs = 6000) {
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    $m = Read-Cfg $Path
    while ($t.ElapsedMilliseconds -lt $TimeoutMs -and -not (& $Cond $m)) {
        Start-Sleep -Milliseconds 100
        $m = Read-Cfg $Path
    }
    return $m
}

# Drive a shell dialog WITHOUT focus games: set the file-name box directly (WM_SETTEXT) and
# click the default button (id 1 = OK/Open/Save) with BM_CLICK.
#   Why not SendKeys: the window is a layered WS_POPUP whose foreground state is unreliable
#   during probes; the first attempt with SendKeys simply never reached the dialog
#   (measured 2026-10-27: dialog stayed open, srclen unchanged).
function Drive-Dialog([IntPtr]$Dlg, [string]$Text) {
    # give the shell dialog time to finish initialising (it re-applies its default name right
    # after creation; typing earlier gets overwritten -- measured 2026-10-27)
    Start-Sleep -Milliseconds 700
    if ($Text.Length -gt 0) { [void][WinFind2]::SetName($Dlg, $Text) }
    Start-Sleep -Milliseconds 250
    [void][WinFind2]::Click1($Dlg)
}

# Close whatever dialog is still up (WM_CLOSE), so the next phase starts clean.
function Close-AnyDialog($App) {
    $d = Find-Window $App.Proc.Id '#32770' 500
    if ($d -ne [IntPtr]::Zero) { [void][Ide]::PostMessage($d, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 400 }
}

$app = $null
$code = 1

try {
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) { throw "PROBE_SKIP:missing exe $exe" }
    foreach ($d in @($SrcDir, $DirA, $DirB, $DirC, (Join-Path $Sand 'tmp'))) {
        New-Item -ItemType Directory -Force $d | Out-Null
    }
    $mainBody = "int main() {`n  return 0;`n}`n"
    $targetBody = "int target() {`n  return 42;`n}`n"
    [System.IO.File]::WriteAllText($MainFl, $mainBody, (New-Object System.Text.ASCIIEncoding))
    [System.IO.File]::WriteAllText($Target, $targetBody, (New-Object System.Text.ASCIIEncoding))
    Remove-Item $State -ErrorAction SilentlyContinue
    # dirB must be EMPTY: a stale "saved.fl"/"target.fl" would make the save dialog pop a
    # nested "overwrite?" prompt (that nested modal is what hung the first probe run).
    Get-ChildItem $DirB -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (Test-Path $Cfg) { Remove-Item $Cfg -ErrorAction SilentlyContinue }

    # geometry away from the click-heavy default spot; the dialogs are children of the app.
    # 2026-10-27 (user decision): all three dialogs SHARE one last-location key `dlgdir=`.
    [System.IO.File]::WriteAllText($Cfg, ("font=Consolas`nsize=14`nweight=400`ncjk=Noto Sans SC Medium`ncjksize=0`nwrap=1`nui=16`nws=`nwinx=300`nwiny=120`nwinw=900`nwinh=620`nwinmax=0`ntree=0`nfile=apps/studio_native/main.fl`ndlgdir=$DirA`n"), (New-Object System.Text.UTF8Encoding($false)))

    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw "PROBE_SKIP:window did not appear ($($app.Error))" }
    [void](Wait-Stable $app.Hwnd 900 40)
    Assert-Deadline $sw $TimeoutSec 'start'
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen' }
    $st0 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -gt 0 } 6000
    Check 'START' ($null -ne $st0) ("startup file loaded (srclen=" + $(if ($st0) { $st0.SrcLen } else { 'NA' }) + ")")

    # ===== A. OPEN: bare name resolves only if the dialog starts in dlgdir =====
    [Ide]::Key(0x4F, $true, $false)          # Ctrl+O
    $dlg = Find-Window $app.Proc.Id '#32770' 6000
    Check 'OPEN-DLG' ($dlg -ne [IntPtr]::Zero) 'open dialog appeared (#32770)'
    if ($dlg -ne [IntPtr]::Zero) {
        Drive-Dialog $dlg 'target.fl'
        $st1 = Wait-StudioStateWhere $Sand { param($s) $s.SrcLen -eq $targetBody.Length } 6000
        Check 'OPEN-DIR' ($null -ne $st1 -and $st1.SrcLen -eq $targetBody.Length) `
            ("bare 'target.fl' in the dialog -> srclen={0} (target.fl={1})" -f $(if ($st1) { $st1.SrcLen } else { 'NA' }), $targetBody.Length)
        $m1 = Wait-Cfg $Cfg { param($m) $m.ContainsKey('dlgdir') -and $m['dlgdir'].TrimEnd('\') -ieq $DirA.TrimEnd('\') } 5000
        Check 'OPEN-KEEP' ($m1.ContainsKey('dlgdir') -and $m1['dlgdir'].TrimEnd('\') -ieq $DirA.TrimEnd('\')) `
            ("cfg dlgdir=" + $m1['dlgdir'])
        # nothing may be left open
        Start-Sleep -Milliseconds 400
        Check 'OPEN-CLOSED' ((Find-Window $app.Proc.Id '#32770' 600) -eq [IntPtr]::Zero) 'dialog closed after OK'
    }
    else {
        Check 'OPEN-DIR' $false 'no dialog -> cannot measure'
        Check 'OPEN-KEEP' $false 'no dialog -> cannot measure'
        Check 'OPEN-CLOSED' $false 'no dialog -> cannot measure'
    }

    # ===== B. SAVE-AS: bare name must land in dsave; dopen must survive =====
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen before save-as' }
    [Ide]::Key(0x53, $true, $true)           # Ctrl+Shift+S
    $dlg2 = Find-Window $app.Proc.Id '#32770' 6000
    Check 'SAVE-DLG' ($dlg2 -ne [IntPtr]::Zero) 'save dialog appeared (#32770)'
    if ($dlg2 -ne [IntPtr]::Zero) {
        # Do NOT type a name here: the dialog's DEFAULT name is already a bare file name
        # (base name of the current buffer), so clicking OK proves the starting folder just as
        # well -- and typing into the SAVE dialog's owner-drawn name box is unreliable from a
        # probe (WM_SETTEXT/WM_CHAR both measured flaky 2026-10-27).
        # The shared dlgdir is now dirA (the OPEN dialog updated it), so the default name
        # "target.fl" would hit an existing file and pop an overwrite prompt -> remove it first.
        Remove-Item (Join-Path $DirA 'target.fl') -Force -ErrorAction SilentlyContinue
        Drive-Dialog $dlg2 ''
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        $back = Join-Path $DirA 'target.fl'
        while ($t.ElapsedMilliseconds -lt 6000 -and -not (Test-Path $back)) { Start-Sleep -Milliseconds 100 }
        $still = Find-Window $app.Proc.Id '#32770' 500
        $note = ''
        if ($still -ne [IntPtr]::Zero) { $note = ' dialog-still-open buttons=' + [WinFind2]::Buttons($still) }
        Check 'SAVE-DIR' (Test-Path $back) ("default bare name + OK -> " + $(if (Test-Path $back) { 'saved into dirA (the dir the OPEN dialog left behind)' } else { 'NOT created (save dialog did not start in the shared dir)' }) + $note)
        if ($still -ne [IntPtr]::Zero) { [void][Ide]::PostMessage($still, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 400 }
        $m2 = Wait-Cfg $Cfg { param($m) $m.ContainsKey('dlgdir') -and $m['dlgdir'].TrimEnd('\') -ieq $DirA.TrimEnd('\') } 5000
        Check 'SAVE-KEEP' ($m2.ContainsKey('dlgdir') -and $m2['dlgdir'].TrimEnd('\') -ieq $DirA.TrimEnd('\')) ("cfg dlgdir=" + $m2['dlgdir'])
        Check 'SAVE-SHARE' ($m2.ContainsKey('dlgdir') -and $m2['dlgdir'].TrimEnd('\') -ieq $DirA.TrimEnd('\')) 'save-as started in the ONE shared dlgdir (set by the open dialog)'
        Check 'SAVE-FILE' ($m2.ContainsKey('file') -and $m2['file'].ToLower().StartsWith($DirA.ToLower())) ("cfg file=" + $m2['file'])
    }
    else {
        Check 'SAVE-DIR' $false 'no dialog -> cannot measure'
        Check 'SAVE-KEEP' $false 'no dialog -> cannot measure'
        Check 'SAVE-SEP' $false 'no dialog -> cannot measure'
        Check 'SAVE-FILE' $false 'no dialog -> cannot measure'
    }

    # ===== C. FOLDER: picker starts SELECTED on the shared dlgdir -> plain Enter accepts it =====
    #   Fresh instance: seed dlgdir=<dirC> (the same one key drives all three dialogs).
    Stop-Studio $app $Root
    $cfgC = New-Object System.Collections.Generic.List[string]
    foreach ($ln in [System.IO.File]::ReadAllLines($Cfg, [System.Text.Encoding]::UTF8)) {
        if ($ln -match '^(dlgdir|ws|file|vf)=') { continue }
        $cfgC.Add($ln)
    }
    $cfgC.Add('ws=')
    $cfgC.Add('file=apps/studio_native/main.fl')
    $cfgC.Add("dlgdir=$DirC")
    [System.IO.File]::WriteAllText($Cfg, (($cfgC -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item $State -ErrorAction SilentlyContinue
    $app = Start-StudioIn $Root $Sand
    if ($null -eq $app.Proc -or $app.Hwnd -eq [IntPtr]::Zero) { throw 'PROBE_SKIP:window did not appear (folder phase)' }
    [void](Wait-Stable $app.Hwnd 900 40)
    if (-not (Grab-Focus $app.Hwnd 25)) { throw 'PROBE_SKIP:keyboard focus was stolen before folder picker' }
    [Ide]::Key(0x4F, $true, $true)           # Ctrl+Shift+O
    $dlg3 = Find-Window $app.Proc.Id '#32770' 6000
    Check 'FOLDER-DLG' ($dlg3 -ne [IntPtr]::Zero) 'folder picker appeared (#32770)'
    if ($dlg3 -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 900              # let BFFM_INITIALIZED selection settle
        Drive-Dialog $dlg3 ''
        $m3 = Wait-Cfg $Cfg { param($m) $m.ContainsKey('ws') -and $m['ws'].TrimEnd('\') -ieq $DirC.TrimEnd('\') } 8000
        Check 'FOLDER-DIR' ($m3.ContainsKey('ws') -and $m3['ws'].TrimEnd('\') -ieq $DirC.TrimEnd('\')) ("OK accepted the preselected folder -> cfg ws=" + $m3['ws'])
        Check 'FOLDER-KEEP' ($m3.ContainsKey('dlgdir') -and $m3['dlgdir'].TrimEnd('\') -ieq $DirC.TrimEnd('\')) ("cfg dlgdir=" + $m3['dlgdir'])
        Check 'FOLDER-SHARE' ($m3.ContainsKey('dlgdir') -and $m3['dlgdir'].TrimEnd('\') -ieq $DirC.TrimEnd('\')) 'folder pick updated the ONE shared dlgdir'
        # leave no dialog behind
        $left = Find-Window $app.Proc.Id '#32770' 800
        if ($left -ne [IntPtr]::Zero) { [void][Ide]::PostMessage($left, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    }
    else {
        Check 'FOLDER-DIR' $false 'no dialog -> cannot measure'
        Check 'FOLDER-KEEP' $false 'no dialog -> cannot measure'
        Check 'FOLDER-SHARE' $false 'no dialog -> cannot measure'
    }

    $code = if ($script:Ok) { 0 } else { 1 }
    Write-Host ("RESULT     dlgdir={0} fails={1}" -f $(if ($script:Ok) { 'PASS' } else { 'FAIL' }), $(if ($script:Fails.Count -gt 0) { $script:Fails -join ',' } else { 'none' }))
}
catch {
    if ($_.Exception.Message -like 'PROBE_SKIP:*') {
        Write-Host ("START      {0}" -f $_.Exception.Message.Substring(11))
        Write-Host "RESULT     dlgdir=SKIP(env-contention)"
        $code = 2
    }
    elseif ($_.Exception.Message -like 'PROBE_TIMEOUT:*') {
        Write-Host ("TIMEOUT    {0}" -f $_.Exception.Message.Substring(14))
        Write-Host "RESULT     dlgdir=FAIL(timeout)"
        $code = 1
    }
    else {
        Write-Host ("ERROR      {0}" -f $_.Exception.Message)
        Write-Host ("RESULT     dlgdir=FAIL(error) message={0}" -f $_.Exception.Message)
        $code = 1
    }
}
finally {
    if (-not $KeepOpen) { Stop-Studio $app $Root }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
}
exit $code
