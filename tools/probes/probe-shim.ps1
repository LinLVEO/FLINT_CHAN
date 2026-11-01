# probe-shim.ps1 - end-to-end probe for the 5 new studio_text.dll exports.
#
# What it measures (every number printed):
#   1. rebuild shim.exe with the REAL compiler (E:\FLINT-lab\hlc.exe; the 2026-10-26 rename
#      moved flint.exe -> hlc.exe and this probe still pointed at the old name => silent SKIP),
#      copy the new DLL next to it, print both byte sizes and the DLL's export list via objdump
#   2. clipboard: seed the clipboard from PowerShell, launch the test, assert the FLINT
#      side read the seed byte-exactly; then assert tx_clip_put -> tx_clip_get roundtrip
#      (34 bytes, ASCII + UTF-8 multibyte), cap clamp at cap=8 (7 bytes + NUL) and read
#      the clipboard back with PowerShell's Get-Clipboard (independent of our DLL)
#   3. edge hook: find the test window, park the REAL mouse cursor at center / right /
#      bottom / bottom-right / top-left with SetCursorPos, force WM_SETCURSOR, and read
#      GetCursorInfo's hCursor. Restores the mouse position afterwards.
#   4. dialogs: wait for a window of class #32770 owned by the test pid, assert it
#      exists, close it with WM_CLOSE (fallbacks: WM_COMMAND IDCANCEL, Escape), twice
#      (open + save), and assert the test process exits with code 0 and recorded 0.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = SKIP (missing tools / no interactive desktop).
# ASCII only on purpose (avoid BOM / codepage traps).
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot)),
    [string]$Flint = 'E:\FLINT-lab\hlc.exe',
    [int]$TimeoutSec = 120
)
$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fail = 0
$skipReason = ''

function Write-Check([string]$name, [string]$detail) {
    Write-Host ("CHECK      {0,-16} {1}" -f $name, $detail)
}
function Add-Fail([string]$why) {
    $script:fail = $script:fail + 1
    Write-Host ("FAIL       {0}" -f $why)
}

$cs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class ShimProbe {
    public delegate bool EnumProc(IntPtr h, IntPtr lp);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }

    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr inst, IntPtr name);
    [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);

    public static IntPtr FindTopWindow(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (cls != null && !string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindDialog(uint pid, out string title) {
        IntPtr found = IntPtr.Zero;
        string t = "";
        EnumWindows(delegate(IntPtr h, IntPtr lp) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            StringBuilder sb = new StringBuilder(256);
            GetClassName(h, sb, 256);
            if (!string.Equals(sb.ToString(), "#32770", StringComparison.OrdinalIgnoreCase)) return true;
            StringBuilder tb = new StringBuilder(512);
            GetWindowText(h, tb, 512);
            t = tb.ToString();
            found = h;
            return false;
        }, IntPtr.Zero);
        title = t;
        return found;
    }

    public static string ClassOf(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString();
    }

    public static IntPtr CursorNow() {
        CURSORINFO ci = new CURSORINFO();
        ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) return IntPtr.Zero;
        return ci.hCursor;
    }

    public static IntPtr LoadResize(int id) { return LoadCursor(IntPtr.Zero, (IntPtr)id); }

    public static int SendSetCursor(IntPtr hwnd) {
        IntPtr lp = (IntPtr)((0x0200 << 16) | 1);
        return (int)SendMessage(hwnd, 0x0020, hwnd, lp).ToInt64();
    }

    public static int[] CursorPos() {
        POINT p;
        GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    public static bool MoveCursor(int x, int y) { return SetCursorPos(x, y); }

    // SetCursor only takes effect when the pointer is over a window of the calling thread,
    // so the probe forces the test window above every other window before the cursor sweep.
    public static bool SetTopmost(IntPtr h) {
        return SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040);
    }
    public static bool ClearTopmost(IntPtr h) {
        return SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x0001 | 0x0002);
    }

    public static int[] ClientBox(IntPtr hwnd) {
        RECT r;
        GetClientRect(hwnd, out r);
        POINT o;
        o.X = 0; o.Y = 0;
        ClientToScreen(hwnd, ref o);
        return new int[] { o.X, o.Y, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static IntPtr CursorAt(IntPtr hwnd, int x, int y) {
        SetCursorPos(x, y);
        SendSetCursor(hwnd);
        return CursorNow();
    }

    // Move, force WM_SETCURSOR, then verify BOTH the pointer position and the cursor shape.
    // Retries are needed because another process on this desktop can move the shared cursor
    // between our SetCursorPos and our GetCursorInfo call.
    // expect != 0  -> success when hCursor == expect
    // expect == 0  -> success when hCursor is not any of the four "bad" resize handles
    public static long[] ProbeCursor(IntPtr hwnd, int x, int y, long expect,
                                     long bad1, long bad2, long bad3, long bad4, int tries) {
        IntPtr last = IntPtr.Zero;
        long posOk = 0;
        long attempts = 0;
        for (int i = 0; i < tries; i++) {
            attempts++;
            SetCursorPos(x, y);
            SendSetCursor(hwnd);
            POINT p;
            GetCursorPos(out p);
            IntPtr c = CursorNow();
            last = c;
            bool at = (p.X == x && p.Y == y);
            if (at) posOk++;
            if (at) {
                bool ok;
                if (expect != 0) ok = ((long)c == expect);
                else ok = ((long)c != bad1 && (long)c != bad2 && (long)c != bad3 && (long)c != bad4);
                if (ok) return new long[] { 1, (long)c, attempts, posOk };
            }
            System.Threading.Thread.Sleep(5);
        }
        return new long[] { 0, (long)last, attempts, posOk };
    }

    public static bool IsResize(long c, long we, long ns, long nwse, long nesw) {
        return (c == we || c == ns || c == nwse || c == nesw);
    }

    public static string ForegroundInfo() {
        IntPtr f = GetForegroundWindow();
        if (f == IntPtr.Zero) return "none";
        StringBuilder sb = new StringBuilder(256);
        GetClassName(f, sb, 256);
        uint pid;
        GetWindowThreadProcessId(f, out pid);
        return "hwnd=0x" + f.ToInt64().ToString("X") + " class=" + sb.ToString() + " pid=" + pid;
    }

    public static string AtPointInfo(int x, int y) {
        POINT p;
        p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return "none";
        IntPtr root = GetAncestor(h, 2);
        StringBuilder sb = new StringBuilder(256);
        GetClassName(root, sb, 256);
        uint pid;
        GetWindowThreadProcessId(root, out pid);
        return "hwnd=0x" + root.ToInt64().ToString("X") + " class=" + sb.ToString() + " pid=" + pid;
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

$work = Join-Path $Root 'tmp\shimtest'
$src = Join-Path $work 'shim.fl'
$exe = Join-Path $work 'shim.exe'
$dllSrc = Join-Path $Root 'apps\studio_native\studio_text.dll'
$dllDst = Join-Path $work 'studio_text.dll'
$resultPath = Join-Path $work 'result.txt'
$proc = $null
$sizewe = [IntPtr]::Zero
$sizens = [IntPtr]::Zero

function Read-Result([string]$path) {
    $h = @{}
    if (-not (Test-Path $path)) { return $h }
    foreach ($ln in (Get-Content -Path $path -Encoding ASCII)) {
        $i = $ln.IndexOf('=')
        if ($i -gt 0) { $h[$ln.Substring(0, $i)] = $ln.Substring($i + 1) }
    }
    return $h
}

function Wait-Key([string]$path, [string]$key, [int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        $h = Read-Result $path
        if ($h.ContainsKey($key)) { return $h }
        Start-Sleep -Milliseconds 50
    }
    return (Read-Result $path)
}

function Show-Result([string]$path) {
    Write-Host "RESULTFILE $path"
    if (Test-Path $path) {
        foreach ($ln in (Get-Content -Path $path -Encoding ASCII)) { Write-Host ("  | " + $ln) }
    } else {
        Write-Host '  | (missing)'
    }
}

try {
    # ---------- build ----------
    if (-not (Test-Path $Flint)) { throw "PROBE_SKIP:compiler not found: $Flint" }
    if (-not (Test-Path $dllSrc)) { throw "PROBE_SKIP:shim dll not found: $dllSrc" }
    if (-not (Test-Path $src)) { throw "PROBE_SKIP:test source not found: $src" }
    if (Test-Path $exe) { Remove-Item $exe -Force }
    $build = & $Flint $src -o $exe 2>&1 | Out-String
    $buildCode = $LASTEXITCODE
    Write-Check 'BUILD' ("flint exit={0} msg={1}" -f $buildCode, ($build.Trim() -replace "`r?`n", ' '))
    if ($buildCode -ne 0 -or -not (Test-Path $exe)) { throw 'build failed' }
    Copy-Item $dllSrc $dllDst -Force
    $dllBytes = (Get-Item $dllDst).Length
    $exeBytes = (Get-Item $exe).Length
    Write-Check 'ARTIFACTS' ("exe={0} bytes dll={1} bytes" -f $exeBytes, $dllBytes)

    $objdump = 'E:\mingw64\bin\objdump.exe'
    if (Test-Path $objdump) {
        $exp = & $objdump -p $dllDst | Select-String -Pattern '^\s+\[\s*\d+\].*\stx_' | ForEach-Object { ($_.Line -split '\s+')[-1] }
        Write-Check 'EXPORTS' ("count={0} names={1}" -f $exp.Count, ($exp -join ','))
        foreach ($need in @('tx_init', 'tx_font', 'tx_fontA', 'tx_begin', 'tx_end', 'tx_text', 'tx_measure',
                            'tx_clip_put', 'tx_clip_get', 'tx_dlg_open', 'tx_dlg_save', 'tx_edge_hook')) {
            if ($exp -notcontains $need) { Add-Fail "missing export $need" }
        }
    } else {
        Write-Check 'EXPORTS' 'objdump not found, skipped export list'
    }

    # ---------- independent desktop check ----------
    $before = [ShimProbe]::CursorPos()
    if (-not [ShimProbe]::MoveCursor($before[0] + 1, $before[1])) { throw 'PROBE_SKIP:SetCursorPos failed (no interactive desktop?)' }
    [void][ShimProbe]::MoveCursor($before[0], $before[1])
    Write-Check 'DESKTOP' ("interactive, cursor at {0},{1}" -f $before[0], $before[1])

    # ---------- seed the clipboard from an independent process ----------
    $seedText = 'probe-seed-42'
    Set-Clipboard -Value $seedText
    $seedBytes = [Text.Encoding]::UTF8.GetBytes($seedText)
    Write-Check 'SEED' ("clipboard set to '{0}' ({1} utf8 bytes)" -f $seedText, $seedBytes.Length)

    foreach ($f in @('result.txt', 'seed.txt', 'clip.txt', 'clip_got.txt', 'clamp.txt')) {
        $fp = Join-Path $work $f
        if (Test-Path $fp) { Remove-Item $fp -Force }
    }

    # ---------- launch the FLINT test ----------
    $proc = Start-Process -FilePath $exe -WorkingDirectory $work -WindowStyle Hidden -PassThru
    Write-Check 'LAUNCH' ("pid={0} exe={1}" -f $proc.Id, $exe)

    # ---------- clipboard seed read (tx_clip_get against a foreign writer) ----------
    $h = Wait-Key $resultPath 'seed_bytes' 15000
    if (-not $h.ContainsKey('seed_bytes')) { throw 'seed stage never appeared' }
    $gotSeed = [int]$h['seed_bytes']
    Write-Check 'CLIP-SEED' ("seed_bytes={0} expect={1} text='{2}'" -f $gotSeed, $seedBytes.Length, $h['seed_text'])
    if ($gotSeed -ne $seedBytes.Length) { Add-Fail "clipboard seed bytes $gotSeed != $($seedBytes.Length)" }
    if ($h['seed_text'] -ne $seedText) { Add-Fail "clipboard seed text '$($h['seed_text'])' != '$seedText'" }
    if (Test-Path (Join-Path $work 'seed.txt')) {
        $seedFile = [IO.File]::ReadAllBytes((Join-Path $work 'seed.txt'))
        Write-Check 'CLIP-SEED-FILE' ("file_bytes={0}" -f $seedFile.Length)
        if ($seedFile.Length -ne $seedBytes.Length) { Add-Fail 'seed.txt length mismatch' }
    }

    # ---------- clipboard put/get roundtrip ----------
    $h = Wait-Key $resultPath 'clip_match' 15000
    if (-not $h.ContainsKey('clip_match')) { throw 'clipboard roundtrip stage never appeared' }
    $prefix = 'FLINT shim clipboard AaZz09!'
    $expList = New-Object System.Collections.Generic.List[byte]
    $expList.AddRange([Text.Encoding]::UTF8.GetBytes($prefix))
    $expList.AddRange([byte[]](228, 184, 173, 230, 150, 135))
    $expected = $expList.ToArray()
    Write-Check 'CLIP' ("put_ret={0} text_bytes={1} get_bytes={2} match={3} expected_bytes={4}" -f `
            $h['clip_put_ret'], $h['clip_text_bytes'], $h['clip_get_bytes'], $h['clip_match'], $expected.Length)
    if ($h['clip_put_ret'] -ne '1') { Add-Fail 'tx_clip_put returned != 1' }
    if ([int]$h['clip_text_bytes'] -ne $expected.Length) { Add-Fail 'clip_text_bytes != 34' }
    if ([int]$h['clip_get_bytes'] -ne $expected.Length) { Add-Fail 'clip_get_bytes != 34' }
    if ($h['clip_match'] -ne '1') { Add-Fail 'clipboard roundtrip byte compare failed' }
    foreach ($f in @('clip.txt', 'clip_got.txt')) {
        $fp = Join-Path $work $f
        if (Test-Path $fp) {
            $b = [IO.File]::ReadAllBytes($fp)
            $same = ($b.Length -eq $expected.Length)
            if ($same) { for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -ne $expected[$i]) { $same = $false; break } } }
            Write-Check 'CLIP-FILE' ("{0} bytes={1} equals_expected={2}" -f $f, $b.Length, $same)
            if (-not $same) { Add-Fail "$f does not hold the expected bytes" }
        } else { Add-Fail "$f missing" }
    }
    # independent reader: PowerShell's own clipboard stack, not our DLL
    $clipNow = Get-Clipboard -Raw
    $expStr = $prefix + [char]0x4E2D + [char]0x6587
    Write-Check 'CLIP-EXTERNAL' ("Get-Clipboard chars={0} expect={1} equal={2}" -f $clipNow.Length, $expStr.Length, ($clipNow -ceq $expStr))
    if ($clipNow -cne $expStr) { Add-Fail 'independent Get-Clipboard text mismatch' }

    # ---------- cap clamp ----------
    $h = Wait-Key $resultPath 'clip_cap8_nul' 15000
    Write-Check 'CLIP-CLAMP' ("cap8_ret={0} cap8_nul={1} cap8_last7_nul={2}" -f $h['clip_cap8_ret'], $h['clip_cap8_nul'], $h['clip_cap8_last7_nul'])
    if ([int]$h['clip_cap8_ret'] -ne 7) { Add-Fail 'tx_clip_get(cap=8) did not return 7' }
    if ([int]$h['clip_cap8_nul'] -ne 0) { Add-Fail 'tx_clip_get(cap=8) did not NUL-terminate at byte 7' }
    if ([int]$h['clip_cap8_last7_nul'] -ne 0) { Add-Fail 'tx_clip_get(cap=8) wrote past cap-1 (byte 7 not NUL)' }
    $clampFp = Join-Path $work 'clamp.txt'
    if (Test-Path $clampFp) {
        $cb = [IO.File]::ReadAllBytes($clampFp)
        $okClamp = ($cb.Length -eq 7)
        if ($okClamp) { for ($i = 0; $i -lt 7; $i++) { if ($cb[$i] -ne $expected[$i]) { $okClamp = $false; break } } }
        Write-Check 'CLIP-CLAMP-FILE' ("clamp.txt bytes={0} prefix_ok={1}" -f $cb.Length, $okClamp)
        if (-not $okClamp) { Add-Fail 'clamp.txt content/length wrong' }
    }

    # ---------- edge hook: cursor sweep ----------
    $h = Wait-Key $resultPath 'edge_hook' 20000
    if (-not $h.ContainsKey('edge_hook')) { throw 'edge hook stage never appeared' }
    Write-Check 'EDGE-HOOK-RET' ("window_ok={0} edge_hook={1}" -f $h['window_ok'], $h['edge_hook'])
    if ($h['edge_hook'] -ne '1') { Add-Fail 'tx_edge_hook did not return 1' }

    $hwnd = [ShimProbe]::FindTopWindow([uint32]$proc.Id, 'Edit')
    if ($hwnd -eq [IntPtr]::Zero) {
        $hwnd = [ShimProbe]::FindTopWindow([uint32]$proc.Id, $null)
        Write-Check 'WINDOW' ("class=Edit not found, fallback hwnd=0x{0:X} class={1}" -f $hwnd.ToInt64(), [ShimProbe]::ClassOf($hwnd))
    } else {
        Write-Check 'WINDOW' ("hwnd=0x{0:X} class={1}" -f $hwnd.ToInt64(), [ShimProbe]::ClassOf($hwnd))
    }
    if ($hwnd -eq [IntPtr]::Zero) { Add-Fail 'test window not found' }
    else {
        # NOTE: do NOT call SetForegroundWindow here. The test process is normally the
        # newly-activated foreground window right after launch, which is exactly the state
        # in which Windows honours SetCursor from its thread; a background process calling
        # SetForegroundWindow returns TRUE but does not reliably transfer activation (measured:
        # with Chrome foreground GetCursorInfo kept the arrow 0x10019 through 40 retries).
        $top = [ShimProbe]::SetTopmost($hwnd)
        Start-Sleep -Milliseconds 400
        Write-Check 'ZORDER' ("set_topmost={0} foreground={1}" -f $top, [ShimProbe]::ForegroundInfo())
        if ([ShimProbe]::ForegroundInfo() -notlike "*pid=$($proc.Id)") {
            Write-Check 'ZORDER-WARN' 'test window is not foreground; cursor assertions may be unreliable'
        }
        $box = [ShimProbe]::ClientBox($hwnd)
        Write-Check 'CLIENT' ("origin={0},{1} size={2}x{3}" -f $box[0], $box[1], $box[2], $box[3])
        $oldPos = [ShimProbe]::CursorPos()
        $w = $box[2]; $ht = $box[3]
        $x0 = $box[0]; $y0 = $box[1]
        $cx = $x0 + [int]($w / 2); $cy = $y0 + [int]($ht / 2)
        $arrow = [ShimProbe]::LoadResize(32512)
        $sizewe = [ShimProbe]::LoadResize(32644)
        $sizens = [ShimProbe]::LoadResize(32645)
        $sizenwse = [ShimProbe]::LoadResize(32642)
        $sizenesw = [ShimProbe]::LoadResize(32643)

        [void][ShimProbe]::MoveCursor(($x0 + $w - 3), $cy)
        $res = [ShimProbe]::SendSetCursor($hwnd)
        Write-Check 'POINT-CENTER' ([ShimProbe]::AtPointInfo($cx, $cy))
        Write-Check 'POINT-RIGHT' ([ShimProbe]::AtPointInfo(($x0 + $w - 3), $cy))
        Write-Check 'POINT-BOTTOM' ([ShimProbe]::AtPointInfo($cx, ($y0 + $ht - 3)))
        Write-Check 'POINT-BR' ([ShimProbe]::AtPointInfo(($x0 + $w - 3), ($y0 + $ht - 3)))
        Write-Check 'POINT-TL' ([ShimProbe]::AtPointInfo(($x0 + 2), ($y0 + 2)))

        $weL = $sizewe.ToInt64(); $nsL = $sizens.ToInt64()
        $nwseL = $sizenwse.ToInt64(); $neswL = $sizenesw.ToInt64()
        # retries guard against another process moving the shared cursor mid-measurement;
        # whole-sweep rounds guard against Windows still finishing our window's activation
        # (measured: the first ~1 s can still show the previous foreground app's arrow even
        # though SetForegroundWindow/GetForegroundWindow already name our window).
        $rC = $null; $rR = $null; $rB = $null; $rBR = $null; $rTL = $null
        $allOk = $false
        $round = 0
        for ($round = 1; $round -le 4; $round++) {
            $rC = [ShimProbe]::ProbeCursor($hwnd, $cx, $cy, 0, $weL, $nsL, $nwseL, $neswL, 15)
            $rR = [ShimProbe]::ProbeCursor($hwnd, ($x0 + $w - 3), $cy, $weL, 0, 0, 0, 0, 15)
            $rB = [ShimProbe]::ProbeCursor($hwnd, $cx, ($y0 + $ht - 3), $nsL, 0, 0, 0, 0, 15)
            $rBR = [ShimProbe]::ProbeCursor($hwnd, ($x0 + $w - 3), ($y0 + $ht - 3), $nwseL, 0, 0, 0, 0, 15)
            $rTL = [ShimProbe]::ProbeCursor($hwnd, ($x0 + 2), ($y0 + 2), $nwseL, 0, 0, 0, 0, 15)
            $allOk = (($rC[0] -eq 1) -and ($rR[0] -eq 1) -and ($rB[0] -eq 1) -and ($rBR[0] -eq 1) -and ($rTL[0] -eq 1))
            if ($allOk) { break }
            if ($round -lt 4) { Start-Sleep -Milliseconds 400 }
        }
        Write-Check 'CURSOR-ROUNDS' ("rounds_used={0} all_ok={1}" -f $round, $allOk)

        [void][ShimProbe]::MoveCursor($oldPos[0], $oldPos[1])
        $nowPos = [ShimProbe]::CursorPos()
        $restored = (($nowPos[0] -eq $oldPos[0]) -and ($nowPos[1] -eq $oldPos[1]))

        Write-Check 'CURSOR-HANDLES' ("arrow=0x{0:X} sizewe=0x{1:X} sizens=0x{2:X} nwse=0x{3:X} nesw=0x{4:X}" -f `
                $arrow.ToInt64(), $weL, $nsL, $nwseL, $neswL)
        Write-Check 'CURSOR-WMSETCURSOR-RET' ("right-edge SendMessage(WM_SETCURSOR) ret={0}" -f $res)
        Write-Check 'CURSOR-CENTER' ("{0},{1} hCursor=0x{2:X} not_resize={3} attempts={4} pos_ok={5}" -f `
                $cx, $cy, $rC[1], ($rC[0] -eq 1), $rC[2], $rC[3])
        Write-Check 'CURSOR-RIGHT' ("{0},{1} hCursor=0x{2:X} ==sizewe:{3} attempts={4} pos_ok={5}" -f `
                ($x0 + $w - 3), $cy, $rR[1], ($rR[0] -eq 1), $rR[2], $rR[3])
        Write-Check 'CURSOR-BOTTOM' ("{0},{1} hCursor=0x{2:X} ==sizens:{3} attempts={4} pos_ok={5}" -f `
                $cx, ($y0 + $ht - 3), $rB[1], ($rB[0] -eq 1), $rB[2], $rB[3])
        Write-Check 'CURSOR-BR' ("hCursor=0x{0:X} ==nwse:{1} attempts={2} pos_ok={3}" -f `
                $rBR[1], ($rBR[0] -eq 1), $rBR[2], $rBR[3])
        Write-Check 'CURSOR-TL' ("hCursor=0x{0:X} ==nwse:{1} attempts={2} pos_ok={3}" -f `
                $rTL[1], ($rTL[0] -eq 1), $rTL[2], $rTL[3])
        Write-Check 'CURSOR-RESTORED' ("{0},{1} restored={2}" -f $nowPos[0], $nowPos[1], $restored)
        [void][ShimProbe]::ClearTopmost($hwnd)

        # center must NOT be any resize cursor (the actual arrow handle can differ from
        # LoadCursor's return value, so "not a resize cursor" is the honest assertion)
        if ($rC[0] -ne 1) { Add-Fail 'center cursor is a resize cursor (or pointer kept moving)' }
        if ($rR[0] -ne 1) { Add-Fail 'right-edge cursor is not IDC_SIZEWE' }
        if ($rB[0] -ne 1) { Add-Fail 'bottom-edge cursor is not IDC_SIZENS' }
        if ($rBR[0] -ne 1) { Add-Fail 'bottom-right corner cursor is not IDC_SIZENWSE' }
        if ($rTL[0] -ne 1) { Add-Fail 'top-left corner cursor is not IDC_SIZENWSE' }
        if (-not $restored) { Add-Fail 'mouse position not restored' }
    }

    # ---------- dialogs ----------
    $seen = 0
    $closed = 0
    $dialogHwnds = @()
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        $title = ''
        $dlg = [ShimProbe]::FindDialog([uint32]$proc.Id, [ref]$title)
        if ($dlg -ne [IntPtr]::Zero) {
            $seen = $seen + 1
            $safe = -join ($title.ToCharArray() | ForEach-Object { if ([int]$_ -lt 32 -or [int]$_ -gt 126) { '?' } else { "$_" } })
            Write-Check 'DIALOG' ("#{0} hwnd=0x{1:X} class=#32770 title_len={2} title='{3}'" -f $seen, $dlg.ToInt64(), $title.Length, $safe)
            $dialogHwnds += $dlg
            [void][ShimProbe]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            $gone = $false
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 50
                if (-not [ShimProbe]::IsWindow($dlg)) { $gone = $true; break }
            }
            if (-not $gone) {
                Write-Host 'INFO       WM_CLOSE did not close it, sending WM_COMMAND IDCANCEL'
                [void][ShimProbe]::PostMessage($dlg, 0x0111, [IntPtr]2, [IntPtr]::Zero)
                for ($i = 0; $i -lt 40; $i++) {
                    Start-Sleep -Milliseconds 50
                    if (-not [ShimProbe]::IsWindow($dlg)) { $gone = $true; break }
                }
            }
            if (-not $gone) {
                Write-Host 'INFO       IDCANCEL did not close it, sending WM_KEYDOWN/WM_KEYUP VK_ESCAPE'
                [void][ShimProbe]::PostMessage($dlg, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
                [void][ShimProbe]::PostMessage($dlg, 0x0101, [IntPtr]0x1B, [IntPtr]::Zero)
                for ($i = 0; $i -lt 40; $i++) {
                    Start-Sleep -Milliseconds 50
                    if (-not [ShimProbe]::IsWindow($dlg)) { $gone = $true; break }
                }
            }
            if ($gone) {
                $closed = $closed + 1
                Write-Check 'DIALOG-CLOSED' ("#{0} closed={1} dialogs_closed={2}" -f $seen, $gone, $closed)
            } else {
                Add-Fail "dialog #$seen did not close"
                break
            }
            if ($seen -ge 2) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Check 'DIALOGS' ("seen={0} closed={1} of expected 2" -f $seen, $closed)
    if ($seen -lt 2) { Add-Fail "only $seen #32770 dialog(s) appeared (expected 2)" }

    # ---------- process exit ----------
    $exited = $proc.WaitForExit(30000)
    if (-not $exited) { throw 'test process did not exit within 30 s' }
    $proc.Refresh()
    Write-Check 'EXIT' ("code={0}" -f $proc.ExitCode)
    if ($proc.ExitCode -ne 0) { Add-Fail "test process exit code $($proc.ExitCode) != 0" }

    # ---------- final result.txt assertions ----------
    Start-Sleep -Milliseconds 200
    Show-Result $resultPath
    $h = Read-Result $resultPath
    if ($h['stage'] -ne 'done') { Add-Fail "result stage '$($h['stage'])' != done" }
    if ($h['dialog_open_ret'] -ne '0') { Add-Fail 'dialog_open_ret != 0 (cancel expected)' }
    if ($h['dialog_save_ret'] -ne '0') { Add-Fail 'dialog_save_ret != 0 (cancel expected)' }
    if ([int]$h['dialog_open_len'] -ne 0) { Add-Fail 'dialog_open_len != 0 on cancel' }
    if ([int]$h['dialog_save_len'] -ne 0) { Add-Fail 'dialog_save_len != 0 on cancel' }
    if ($closed -ne 2) { Add-Fail "closed $closed dialogs, expected 2" }

    if ($fail -eq 0) {
        Write-Host ("RESULT     build=OK exports=OK clipboard_put={0} clip_roundtrip={1}B dialog_class=#32770 dialogs_closed={2} cursor_we=0x{3:X} cursor_ns=0x{4:X} => PASS" -f `
                $h['clip_put_ret'], $h['clip_get_bytes'], $closed, ($sizewe.ToInt64()), ($sizens.ToInt64()))
        exit 0
    } else {
        Write-Host ("RESULT     failures={0} => FAIL" -f $fail)
        exit 1
    }
}
catch {
    $msg = $_.Exception.Message
    if ($msg -like 'PROBE_SKIP:*') {
        Write-Host ("SKIP       {0}" -f $msg.Substring(11))
        Write-Host 'RESULT     shim probe => SKIP'
        $code = 2
    } else {
        Write-Host ("ERROR      {0}" -f $msg)
        Write-Host ("RESULT     shim probe => FAIL ({0})" -f $msg)
        $code = 1
    }
    if ($proc -ne $null -and -not $proc.HasExited) {
        $p2 = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p2 -ne $null -and $p2.Path -like ($Root + '\*')) { Stop-Process -Id $proc.Id -Force }
    }
    Write-Host ("ELAPSED    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
    exit $code
}
