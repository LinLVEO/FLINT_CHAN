# IdeProbe.ps1 - shared helpers for FLINT Studio probes (ASCII only on purpose).
# Dot-source from a probe:
#   . "$PSScriptRoot\IdeProbe\IdeProbe.ps1"
# Design notes:
#   * every screenshot goes through PrintWindow(hwnd, dc, 2) into a 32bpp DIB - no
#     desktop coordinates, no System.Drawing dependency in the C# part.
#   * every input is converted from CLIENT coords via ClientToScreen - no absolute pixels.
#   * only processes whose executable lives under our own worktree are killed, so a
#     concurrent agent testing another checkout is not disturbed (env-contention).
#   * exit codes used by the probes: 0 = PASS, 1 = FAIL, 2 = SKIP (not implemented /
#     environment contention / app missing).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('Ide' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Ide {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort wVk; public ushort wScan; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MI { public int dx; public int dy; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KI ki; [FieldOffset(8)] public MI mi; }

    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth; public int biHeight;
        public ushort biPlanes; public ushort biBitCount;
        public uint biCompression; public uint biSizeImage;
        public int biXPelsPerMeter; public int biYPelsPerMeter;
        public uint biClrUsed; public uint biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; public uint bmiColors; }

    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] a, int sz);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint c, uint t);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi, uint usage, out IntPtr bits, IntPtr hSection, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);

    public static IntPtr ByClass(int target, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == (uint)target && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(256);
                GetClassName(h, c, 256);
                if (c.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }

    public static Frame Grab(IntPtr h) {
        RECT r = Rect(h);
        int w = r.R - r.L;
        int hh = r.B - r.T;
        if (w <= 0 || hh <= 0) throw new Exception("bad window rect");
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr dc = CreateCompatibleDC(screen);
        BITMAPINFO bmi = new BITMAPINFO();
        bmi.bmiHeader.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -hh;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = 0;
        IntPtr bits;
        IntPtr dib = CreateDIBSection(dc, ref bmi, 0, out bits, IntPtr.Zero, 0);
        if (dib == IntPtr.Zero) { DeleteDC(dc); ReleaseDC(IntPtr.Zero, screen); throw new Exception("CreateDIBSection failed"); }
        IntPtr old = SelectObject(dc, dib);
        PrintWindow(h, dc, 2);
        int[] px = new int[w * hh];
        Marshal.Copy(bits, px, 0, px.Length);
        SelectObject(dc, old);
        DeleteObject(dib);
        DeleteDC(dc);
        ReleaseDC(IntPtr.Zero, screen);
        for (int i = 0; i < px.Length; i++) px[i] &= 0xFFFFFF;
        return new Frame(w, hh, px);
    }

    static void RawKey(ushort vk, bool up) {
        INPUT[] a = new INPUT[1];
        a[0].type = 1;
        a[0].ki.wVk = vk;
        a[0].ki.wScan = (ushort)MapVirtualKey(vk, 0);
        a[0].ki.flags = up ? 2u : 0u;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Key(ushort vk, bool ctrl, bool shift) {
        KeyEx(vk, ctrl, shift, false);
    }

    // Same as Key() plus a real Alt modifier (Alt+Z = soft-wrap toggle).
    public static void KeyEx(ushort vk, bool ctrl, bool shift, bool alt) {
        if (ctrl) { RawKey(0x11, false); System.Threading.Thread.Sleep(60); }
        if (shift) { RawKey(0x10, false); System.Threading.Thread.Sleep(60); }
        if (alt) { RawKey(0x12, false); System.Threading.Thread.Sleep(60); }
        RawKey(vk, false);
        System.Threading.Thread.Sleep(60);
        RawKey(vk, true);
        if (alt) { RawKey(0x12, true); System.Threading.Thread.Sleep(40); }
        if (shift) { RawKey(0x10, true); System.Threading.Thread.Sleep(40); }
        if (ctrl) { RawKey(0x11, true); System.Threading.Thread.Sleep(40); }
        System.Threading.Thread.Sleep(120);
    }

    // Left mouse button press/release through SendInput (the app polls real button state).
    public static void MouseLeft(bool down) {
        INPUT[] a = new INPUT[1];
        a[0].type = 0;
        a[0].mi.flags = down ? 0x0002u : 0x0004u;
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }

    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // Post a WM_CHAR straight to the window: deterministic text input that bypasses
    // this machine's Chinese IME (SendInput letters start a composition instead).
    // Call one character at a time with a >=100 ms gap: the pump carries a single
    // pending-char slot, so a burst would repeat only the last character.
    public static void Char(IntPtr h, int ch) { PostMessage(h, 0x0102, (IntPtr)ch, (IntPtr)1); }

    // Post a WM_KEYDOWN (used for Enter when the IME would eat a physical Enter).
    public static void KeyDown(IntPtr h, int vk) { PostMessage(h, 0x0100, (IntPtr)vk, (IntPtr)1); }

    // Post a WM_KEYDOWN carrying a REAL scan code in lParam bits 16..23.
    // This app runs the keyboard tier (kbd=1): characters are produced from the
    // scan code table, not from WM_CHAR, and a physical key can be swallowed by the
    // Chinese IME (wParam becomes VK_PROCESSKEY=229). A posted key message is exactly
    // the WM_KEYDOWN a real keystroke delivers, minus the IME - deterministic typing.
    public static void KeyDownSc(IntPtr h, int vk, int scan) {
        long lp = ((long)scan << 16) | 1L;
        PostMessage(h, 0x0100, (IntPtr)vk, (IntPtr)lp);
    }

    public static int Scan(int vk) { return (int)MapVirtualKey((uint)vk, 0); }

    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    public static int CursorX() { POINT p; GetCursorPos(out p); return p.X; }
    public static int CursorY() { POINT p; GetCursorPos(out p); return p.Y; }

    public static void Wheel(int notches) {
        INPUT[] a = new INPUT[1];
        a[0].type = 0;
        a[0].mi.flags = 0x0800;
        a[0].mi.mouseData = (uint)(notches * 120);
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(60);
    }

    public static void MoveClient(IntPtr h, int x, int y) {
        POINT p;
        p.X = x; p.Y = y;
        ClientToScreen(h, ref p);
        SetCursorPos(p.X, p.Y);
        System.Threading.Thread.Sleep(40);
    }
}

public sealed class Frame {
    public readonly int W;
    public readonly int H;
    public readonly int[] Px;   // 0x00RRGGBB

    public Frame(int w, int h, int[] px) { W = w; H = h; Px = px; }

    public int At(int x, int y) {
        if (x < 0 || y < 0 || x >= W || y >= H) return -1;
        return Px[y * W + x];
    }

    // int[] with alpha forced opaque, ready for Marshal.Copy into a 32bpp Bitmap.
    public int[] ToArgb() {
        int[] o = new int[Px.Length];
        for (int i = 0; i < Px.Length; i++) o[i] = unchecked((int)0xFF000000) | Px[i];
        return o;
    }

    public ulong Hash() {
        ulong h = 1469598103934665603UL;
        for (int i = 0; i < Px.Length; i++) {
            h ^= (uint)Px[i];
            h *= 1099511628211UL;
        }
        return h;
    }

    public int CountNear(int x0, int y0, int x1, int y1, int rgb, int tol) {
        int n = 0;
        int r0 = (rgb >> 16) & 255, g0 = (rgb >> 8) & 255, b0 = rgb & 255;
        for (int y = y0; y < y1; y++) {
            if (y < 0 || y >= H) continue;
            int baseI = y * W;
            for (int x = x0; x < x1; x++) {
                if (x < 0 || x >= W) continue;
                int c = Px[baseI + x];
                int dr = ((c >> 16) & 255) - r0;
                int dg = ((c >> 8) & 255) - g0;
                int db = (c & 255) - b0;
                if (dr < 0) dr = -dr;
                if (dg < 0) dg = -dg;
                if (db < 0) db = -db;
                if (dr <= tol && dg <= tol && db <= tol) n++;
            }
        }
        return n;
    }

    public int CountDistinct(int x0, int y0, int x1, int y1, int tol) {
        HashSet<int> set = new HashSet<int>();
        int q = tol <= 0 ? 1 : tol;
        for (int y = y0; y < y1; y += 2) {
            if (y < 0 || y >= H) continue;
            for (int x = x0; x < x1; x += 2) {
                if (x < 0 || x >= W) continue;
                int c = Px[y * W + x];
                int r = ((c >> 16) & 255) / q, g = ((c >> 8) & 255) / q, b = (c & 255) / q;
                set.Add((r << 16) | (g << 8) | b);
            }
        }
        return set.Count;
    }

    static bool Near(int a, int b, int tol) {
        int dr = ((a >> 16) & 255) - ((b >> 16) & 255);
        int dg = ((a >> 8) & 255) - ((b >> 8) & 255);
        int db = (a & 255) - (b & 255);
        if (dr < 0) dr = -dr;
        if (dg < 0) dg = -dg;
        if (db < 0) db = -db;
        return dr <= tol && dg <= tol && db <= tol;
    }

    public int Diff(Frame o, int x0, int y0, int x1, int y1, int tol) {
        int n = 0;
        if (o == null || o.W != W || o.H != H) return (x1 - x0) * (y1 - y0);
        for (int y = y0; y < y1; y++) {
            if (y < 0 || y >= H) continue;
            int baseI = y * W;
            for (int x = x0; x < x1; x++) {
                if (x < 0 || x >= W) continue;
                int a = Px[baseI + x], b = o.Px[baseI + x];
                if (!Near(a, b, tol)) n++;
            }
        }
        return n;
    }

    public double DiffPct(Frame o, int x0, int y0, int x1, int y1, int tol) {
        long area = (long)(x1 - x0) * (y1 - y0);
        if (area <= 0) return 100.0;
        return 100.0 * Diff(o, x0, y0, x1, y1, tol) / area;
    }

    // vertical shift s such that this(y) best matches o(y+s); s>0 = content moved down
    public int BestShiftY(Frame o, int x0, int x1, int y0, int y1, int maxShift, int sampleStep) {
        int bestS = 0;
        double bestScore = double.MaxValue;
        if (o == null || o.W != W || o.H != H) return 0;
        if (sampleStep < 1) sampleStep = 1;
        for (int s = -maxShift; s <= maxShift; s++) {
            long diff = 0, cnt = 0;
            for (int y = y0; y < y1; y += sampleStep) {
                int yy = y + s;
                if (yy < 0 || yy >= y1) continue;
                int ia = y * W, ib = yy * W;
                for (int x = x0; x < x1; x += sampleStep) {
                    int ca = Px[ia + x], cb = o.Px[ib + x];
                    int dr = ((ca >> 16) & 255) - ((cb >> 16) & 255);
                    int dg = ((ca >> 8) & 255) - ((cb >> 8) & 255);
                    int db = (ca & 255) - (cb & 255);
                    if (dr < 0) dr = -dr;
                    if (dg < 0) dg = -dg;
                    if (db < 0) db = -db;
                    if (dr > 24 || dg > 24 || db > 24) diff++;
                    cnt++;
                }
            }
            if (cnt == 0) continue;
            double score = (double)diff / cnt;
            if (score < bestScore) { bestScore = score; bestS = s; }
        }
        return bestS;
    }

    // Same, but only "ink" pixels count (background pixels are ignored on both sides).
    // Needed for the line-number gutter: glyphs cover <10% of the strip, so plain
    // correlation is dominated by matching background and peaks on the wrong line.
    public int BestShiftInk(Frame o, int x0, int x1, int y0, int y1, int maxShift, int sampleStep, int bgRgb) {
        int bestS = 0;
        double bestScore = double.MaxValue;
        if (o == null || o.W != W || o.H != H) return 0;
        if (sampleStep < 1) sampleStep = 1;
        int br = (bgRgb >> 16) & 255, bgc = (bgRgb >> 8) & 255, bb = bgRgb & 255;
        for (int s = -maxShift; s <= maxShift; s++) {
            long diff = 0, ink = 0;
            for (int y = y0; y < y1; y += sampleStep) {
                int yy = y + s;
                if (yy < 0 || yy >= y1) continue;
                int ia = y * W, ib = yy * W;
                for (int x = x0; x < x1; x += sampleStep) {
                    int ca = Px[ia + x], cb = o.Px[ib + x];
                    int ar = ((ca >> 16) & 255) - br;
                    int ag = ((ca >> 8) & 255) - bgc;
                    int ab = (ca & 255) - bb;
                    bool aInk = (ar < -14 || ar > 14 || ag < -14 || ag > 14 || ab < -14 || ab > 14);
                    int cr = ((cb >> 16) & 255) - br;
                    int cg = ((cb >> 8) & 255) - bgc;
                    int cb2 = (cb & 255) - bb;
                    bool bInk = (cr < -14 || cr > 14 || cg < -14 || cg > 14 || cb2 < -14 || cb2 > 14);
                    if (!aInk && !bInk) continue;
                    ink++;
                    int dr = ((ca >> 16) & 255) - ((cb >> 16) & 255);
                    int dg = ((ca >> 8) & 255) - ((cb >> 8) & 255);
                    int db = (ca & 255) - (cb & 255);
                    if (dr < 0) dr = -dr;
                    if (dg < 0) dg = -dg;
                    if (db < 0) db = -db;
                    if (dr > 24 || dg > 24 || db > 24) diff++;
                }
            }
            if (ink < 100) continue;
            double score = (double)diff / ink;
            if (score < bestScore) { bestScore = score; bestS = s; }
        }
        return bestS;
    }
}
'@ -Language CSharp
}

function Get-StudioExe([string]$Root) {
    return (Join-Path $Root 'apps\studio_native\studio_win.exe')
}

# Kill ONLY our own checkout's studio_win / studio_server. Never touch a foreign worktree.
function Stop-OwnStudio([string]$Root) {
    $prefix = ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
    foreach ($n in @('studio_win', 'studio_server')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            $pp = $null
            try { $pp = $_.Path } catch { $pp = $null }
            if ($pp -and $pp.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Milliseconds 250
}

function Get-OwnStudioPids([string]$Root) {
    $prefix = ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
    $out = @()
    foreach ($n in @('studio_win', 'studio_server')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            $pp = $null
            try { $pp = $_.Path } catch { $pp = $null }
            if ($pp -and $pp.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $out += [pscustomobject]@{ Name = $n; Id = $_.Id; Path = $pp }
            }
        }
    }
    return $out
}

# Launch the app from its own worktree root. Returns @{Proc;Hwnd;Exited;Error}
function Start-Studio([string]$Root) {
    Stop-OwnStudio $Root
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) {
        return @{ Proc = $null; Hwnd = [IntPtr]::Zero; Exited = $true; Error = "missing exe: $exe" }
    }
    $p = Start-Process -FilePath $exe -WorkingDirectory $Root -WindowStyle Hidden -PassThru
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 100
        $p.Refresh()
        if ($p.HasExited) { break }
        $hwnd = [Ide]::ByClass($p.Id, 'FLINTSTUDIO')
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        [void][Ide]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 350
    }
    return @{ Proc = $p; Hwnd = $hwnd; Exited = $p.HasExited; Error = $null }
}

# Launch the app that lives under $Root but with a SANDBOX working directory
# (ai.state / studio.cfg / the file the IDE opens are all relative to cwd).
function Start-StudioIn([string]$Root, [string]$WorkDir) {
    Stop-OwnStudio $Root
    $exe = Get-StudioExe $Root
    if (-not (Test-Path $exe)) {
        return @{ Proc = $null; Hwnd = [IntPtr]::Zero; Exited = $true; Error = "missing exe: $exe" }
    }
    $p = Start-Process -FilePath $exe -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 100
        $p.Refresh()
        if ($p.HasExited) { break }
        $hwnd = [Ide]::ByClass($p.Id, 'FLINTSTUDIO')
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        # Park immediately: the window is created at the default (120,90) spot, which
        # is exactly where a concurrent agent's probe clicks. The shorter this window
        # of exposure, the fewer foreign clicks land in our client area.
        Position-Window $hwnd
        [void][Ide]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 350
    }
    return @{ Proc = $p; Hwnd = $hwnd; Exited = $p.HasExited; Error = $null }
}

# Last "ST cur line col nlines srclen nrows selon" line of <Dir>\ai.state.
# Returns $null when the file does not exist yet or has no complete ST line
# (fresh sandbox / probe started before the first frame was written).
function Read-StudioState([string]$Dir) {
    $p = Join-Path $Dir 'ai.state'
    if (-not (Test-Path $p)) { return $null }
    $last = $null
    try {
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            while ($null -ne ($ln = $sr.ReadLine())) {
                if ($ln -like 'ST *') { $last = $ln }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { return $null }
    if (-not $last) { return $null }
    $f = $last.Trim() -split '\s+'
    if ($f.Count -lt 8) { return $null }
    return @{
        Raw       = $last.Trim()
        Cur       = [long]$f[1]
        Line      = [long]$f[2]
        Col       = [long]$f[3]
        LineCount = [long]$f[4]
        SrcLen    = [long]$f[5]
        NRows     = [long]$f[6]
        SelOn     = [long]$f[7]
    }
}

# Wait until ai.state has a value different from $NotThis (or the deadline hits).
function Wait-StudioState([string]$Dir, [hashtable]$NotThis, [int]$TimeoutMs = 5000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = Read-StudioState $Dir
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $st = Read-StudioState $Dir
        if ($null -ne $st) {
            if ($null -eq $NotThis -or $st.Raw -ne $NotThis.Raw) { return $st }
        }
        Start-Sleep -Milliseconds 100
    }
    return $st
}

# Wait until ai.state satisfies a predicate (e.g. SrcLen changed after a paste).
function Wait-StudioStateWhere([string]$Dir, [scriptblock]$Cond, [int]$TimeoutMs = 6000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $st = Read-StudioState $Dir
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $st = Read-StudioState $Dir
        if ($null -ne $st -and (& $Cond $st)) { return $st }
        Start-Sleep -Milliseconds 100
    }
    return $st
}

# "Ink" = pixel whose brightest channel is > $MinBright. Editor text is #CCCCCC,
# backgrounds are #1E1E1E / #2A2D2E / #232323 (all well under 70).
# Returns @{Count;MinX;MaxX;MinY;MaxY;Width} (MinX/MaxX are -1 when Count = 0).
function Get-InkStats([Frame]$Img, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$MinBright = 70) {
    $n = 0; $minX = -1; $maxX = -1; $minY = -1; $maxY = -1
    for ($y = $Y0; $y -lt $Y1; $y++) {
        if ($y -lt 0 -or $y -ge $Img.H) { continue }
        $base = $y * $Img.W
        for ($x = $X0; $x -lt $X1; $x++) {
            if ($x -lt 0 -or $x -ge $Img.W) { continue }
            $c = $Img.Px[$base + $x]
            $r = ($c -shr 16) -band 255
            $g = ($c -shr 8) -band 255
            $b = $c -band 255
            if ($r -gt $MinBright -or $g -gt $MinBright -or $b -gt $MinBright) {
                if ($n -eq 0 -or $x -lt $minX) { $minX = $x }
                if ($n -eq 0 -or $x -gt $maxX) { $maxX = $x }
                if ($n -eq 0 -or $y -lt $minY) { $minY = $y }
                if ($n -eq 0 -or $y -gt $maxY) { $maxY = $y }
                $n++
            }
        }
    }
    return @{ Count = $n; MinX = $minX; MaxX = $maxX; MinY = $minY; MaxY = $maxY; Width = ($maxX - $minX) }
}

# Real left-button drag in CLIENT coordinates: position, button-down, interpolated
# moves (the app samples the mouse at 30 fps, so steps must be spaced), hold, release.
function Invoke-DragClient([IntPtr]$Hwnd, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$Steps = 8, [int]$HoldMs = 400, [int]$StepMs = 80) {
    if ($Steps -lt 1) { $Steps = 1 }
    [Ide]::MoveClient($Hwnd, $X0, $Y0)
    Start-Sleep -Milliseconds 150
    [Ide]::MouseLeft($true)
    Start-Sleep -Milliseconds 150
    for ($i = 1; $i -le $Steps; $i++) {
        $x = [int][Math]::Round($X0 + ($X1 - $X0) * $i / $Steps)
        $y = [int][Math]::Round($Y0 + ($Y1 - $Y0) * $i / $Steps)
        [Ide]::MoveClient($Hwnd, $x, $y)
        Start-Sleep -Milliseconds $StepMs
    }
    Start-Sleep -Milliseconds $HoldMs
    [Ide]::MouseLeft($false)
    Start-Sleep -Milliseconds 250
}

# Park our window on the far right so a concurrent agent's probes (which click at
# screen coords over the DEFAULT window position 120,90) cannot hit our client area.
# PrintWindow(PW_RENDERFULLCONTENT) still captures the full 1000x700 surface even
# when part of the window hangs off the right edge - verified by the probes.
function Position-Window([IntPtr]$Hwnd, [int]$X = -1, [int]$Y = -1) {
    $scrW = [Ide]::GetSystemMetrics(0)
    $scrH = [Ide]::GetSystemMetrics(1)
    if ($X -lt 0) { $X = $scrW - 1010 }
    if ($Y -lt 0) { $Y = 110 }
    if ($X + 1000 -gt $scrW) { $X = [Math]::Max(0, $scrW - 1010) }
    if ($Y -lt 0 -or $Y + 100 -gt $scrH) { $Y = 110 }
    $SWP_NOSIZE = 0x0001; $SWP_NOZORDER = 0x0004; $SWP_NOACTIVATE = 0x0010
    [void][Ide]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, 0, 0, ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE))
    Start-Sleep -Milliseconds 250
}

# Take screenshots until the picture stops changing (startup compile + output panel
# arrive a few seconds after the window shows up). Returns the last Frame.
function Wait-Stable([IntPtr]$Hwnd, [int]$MinMs = 900, [int]$TimeoutSec = 35) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $null
    $img = $null
    $same = 0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $img = [Ide]::Grab($Hwnd)
        if ($null -ne $prev) {
            $d = $img.DiffPct($prev, 0, 0, $img.W, $img.H, 2)
            if ($d -lt 0.02) { $same++ } else { $same = 0 }
        }
        $prev = $img
        if ($same -ge 2 -and $sw.Elapsed.TotalMilliseconds -ge $MinMs) { return $img }
        Start-Sleep -Milliseconds 300
    }
    return $img
}

function Save-Shot([Frame]$Img, [string]$Root, [string]$Name) {
    $dir = Join-Path $Root 'tmp\IdeProbe\shots'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $p = Join-Path $dir ("$Name.png")
    $bmp = New-Object System.Drawing.Bitmap($Img.W, $Img.H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Img.W, $Img.H)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $argb = $Img.ToArgb()
        [System.Runtime.InteropServices.Marshal]::Copy($argb, 0, $bd.Scan0, $argb.Length)
    }
    finally {
        $bmp.UnlockBits($bd)
        $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    return $p
}

function Ensure-Focus([IntPtr]$Hwnd) {
    if ([Ide]::GetForegroundWindow() -ne $Hwnd) {
        [void][Ide]::SetForegroundWindow($Hwnd)
        Start-Sleep -Milliseconds 180
    }
}

# Try to become the foreground window. A concurrent agent's probe may hold/steal it;
# wait a few seconds instead of failing on the first miss.
function Grab-Focus([IntPtr]$Hwnd, [int]$Tries = 25) {
    for ($i = 0; $i -lt $Tries; $i++) {
        Ensure-Focus $Hwnd
        if ([Ide]::GetForegroundWindow() -eq $Hwnd) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Write-Check([string]$Tag, [string]$Text) {
    Write-Host ("{0,-12} {1}" -f $Tag, $Text)
}

# Total-runtime guard: call between phases so a slow/stuck step cannot hang the probe
# past -TimeoutSec. All waits inside are bounded (150 x 100ms for the window,
# ~40 x 300ms for stable frames, fixed 0.3-1s sleeps).
function Assert-Deadline([System.Diagnostics.Stopwatch]$Sw, [int]$TimeoutSec, [string]$Phase) {
    if ($Sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
        throw ("PROBE_TIMEOUT:{0} after {1:N0}s" -f $Phase, $Sw.Elapsed.TotalSeconds)
    }
}

function Format-Rgb([int]$c) {
    if ($c -lt 0) { return 'n/a' }
    return ("#{0:X2}{1:X2}{2:X2}" -f (($c -shr 16) -band 255), (($c -shr 8) -band 255), ($c -band 255))
}

function Color-Near([int]$c, [int]$rgb, [int]$tol) {
    if ($c -lt 0) { return $false }
    $dr = [Math]::Abs((($c -shr 16) -band 255) - (($rgb -shr 16) -band 255))
    $dg = [Math]::Abs((($c -shr 8) -band 255) - (($rgb -shr 8) -band 255))
    $db = [Math]::Abs(($c -band 255) - ($rgb -band 255))
    return ($dr -le $tol -and $dg -le $tol -and $db -le $tol)
}

# Longest vertical run of "scrollbar-like" pixels at the right edge of the editor.
# Returns @{Found;Y0;Y1;Color;RowCount}
function Measure-Slider([Frame]$Img) {
    # 适配当前实现：轨道 #232323、滑块 #424242、悬停 #4E4E4E，条带 x = W-14..W（内边距 2px）
    $W = $Img.W
    $H = $Img.H
    $top = 40
    $sbTop = $H - 26
    $ys = New-Object System.Collections.Generic.List[int]
    $cols = @{}
    for ($y = $top; $y -lt $sbTop - 1; $y++) {
        $c = $Img.At($W - 7, $y)
        if ($c -lt 0) { continue }
        $r = $c -band 0xFF
        $g = ($c -shr 8) -band 0xFF
        $b = ($c -shr 16) -band 0xFF
        if ($r -ge 0x30 -and $g -ge 0x30 -and $b -ge 0x30 -and $r -lt 0xA0) {
            $ys.Add($y)
            $cols[$y] = $c
        }
    }
    $bestLen = 0; $bestY0 = -1; $bestY1 = -1; $bestColor = 0
    $i = 0
    while ($i -lt $ys.Count) {
        $start = $ys[$i]
        $end = $start
        $j = $i + 1
        while ($j -lt $ys.Count -and $ys[$j] -eq $end + 1) { $end = $ys[$j]; $j++ }
        $len = $end - $start + 1
        if ($len -gt $bestLen) { $bestLen = $len; $bestY0 = $start; $bestY1 = $end; $bestColor = $cols[$start] }
        $i = $j
    }
    $found = ($bestLen -ge 8)
    if (-not $found) { $bestY0 = -1; $bestY1 = -1; $bestColor = 0 }
    return @{ Found = $found; Y0 = $bestY0; Y1 = $bestY1; Color = $bestColor; RowCount = $bestLen }
}

function Stop-Studio([hashtable]$App, [string]$Root) {
    if ($null -ne $App -and $null -ne $App.Proc) {
        try { if (-not $App.Proc.HasExited) { Stop-Process -Id $App.Proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    Stop-OwnStudio $Root
}
