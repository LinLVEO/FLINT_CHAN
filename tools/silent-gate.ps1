# silent-gate.ps1 -- run a command on a PRIVATE, INVISIBLE desktop so nothing it creates can
# ever steal the user's foreground or pop up on top of whatever they are doing.
#
# Why this exists (measured 2026-10-20): any child that creates a window takes the foreground.
#   Probe: foreground hwnd moved from the user's app to the probe's dialog the moment a
#   MessageBox existed.  Inside the gate set that means:
#     * test\debug-verify.ps1 used to RUN api1.fl, whose MessageBoxA stole the foreground and
#       blocked for the 8 s timeout (fixed separately: the run sample is now api2.fl);
#     * test\loop-verify.ps1 runs apps\m2_float\main.exe, a real ULW window that floats on top
#       (its window is WS_EX_NOACTIVATE, so no keyboard focus, but it is still visible).
#   Fixing those two does not protect us from the NEXT window-creating sample, so the durable
#   answer is this wrapper: CreateDesktop + CreateProcessW with lpDesktop = that desktop.
#   Windows created there are never painted on the interactive desktop and never get focus.
#
# Usage (ASCII-only on purpose -- see test\debug-verify.ps1 header for the BOM rationale):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\silent-gate.ps1 `
#     -Exe powershell.exe -Argv "-NoProfile","-ExecutionPolicy","Bypass","-File","test\verify-all.ps1"
#   ... -OutFile tmp\silent\verify-all.out.log -ErrFile tmp\silent\verify-all.err.log -TimeoutSec 1800
#
# Exit code = the child's exit code.  125 = the wrapper itself failed (message on stderr).
# The child always sees CREATE_NO_WINDOW plus redirected stdio; a job object kills any leftover
# child tree when this wrapper exits.
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string[]]$Argv = @(),
  [string]$WorkDir = '',
  [string]$OutFile = '',
  [string]$ErrFile = '',
  [int]$TimeoutSec = 0,
  [string]$PidFile = '',
  [switch]$Stream,
  [switch]$KeepDesktop
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($WorkDir -eq '') { $WorkDir = $root }
if ($OutFile -eq '') { $OutFile = Join-Path $root ('tmp\silent\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.out.log') }
if ($ErrFile -eq '') { $ErrFile = Join-Path $root ('tmp\silent\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.err.log') }
foreach ($f in @($OutFile, $ErrFile)) {
  $d = Split-Path -Parent $f
  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
$OutFile = [IO.Path]::GetFullPath($OutFile)
$ErrFile = [IO.Path]::GetFullPath($ErrFile)
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
$deskName = 'FLINTGATE-' + $PID + '-' + (Get-Date -Format 'HHmmssfff')

$src = @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class FlintSilentDesk
{
    const uint DESKTOP_ALL_ACCESS = 0x000F01FF;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint STARTF_USESTDHANDLES = 0x00000100;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    const uint INFINITE = 0xFFFFFFFF;
    const uint WAIT_TIMEOUT = 0x00000102;
    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public int bInheritHandle; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpReserved;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpDesktop;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOB_BASIC
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public IntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public IntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOB_EXTENDED
    {
        public JOB_BASIC BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public IntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktopW(string lpszDesktop, IntPtr lpszDevice, IntPtr pDevmode, uint dwFlags, uint dwDesiredAccess, IntPtr lpsa);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool CloseDesktop(IntPtr hDesktop);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, string cmdline, IntPtr pa, IntPtr ta, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    static long Pump(string path, long pos, bool toErr)
    {
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (fs.Length <= pos) { return pos; }
                fs.Position = pos;
                byte[] buf = new byte[8192];
                Stream dst = toErr ? Console.OpenStandardError() : Console.OpenStandardOutput();
                int n;
                while ((n = fs.Read(buf, 0, buf.Length)) > 0) { dst.Write(buf, 0, n); dst.Flush(); pos += n; }
            }
        }
        catch { }
        return pos;
    }

    public static int Run(string desk, string exe, string argv, string cwd, string outFile, string errFile, string pidFile, int timeoutSec, bool stream, out string msg)
    {
        msg = "";
        IntPtr hDesk = CreateDesktopW(desk, IntPtr.Zero, IntPtr.Zero, 0, DESKTOP_ALL_ACCESS, IntPtr.Zero);
        if (hDesk == IntPtr.Zero) { msg = "CreateDesktopW failed err=" + Marshal.GetLastWin32Error(); return 125; }

        SECURITY_ATTRIBUTES sa = new SECURITY_ATTRIBUTES();
        sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        sa.bInheritHandle = 1;
        IntPtr hOut = CreateFileW(outFile, GENERIC_WRITE, 3, ref sa, 2, 0x80, IntPtr.Zero);   // CREATE_ALWAYS
        IntPtr hErr = CreateFileW(errFile, GENERIC_WRITE, 3, ref sa, 2, 0x80, IntPtr.Zero);
        IntPtr hIn  = CreateFileW("NUL", GENERIC_READ, 3, ref sa, 3, 0, IntPtr.Zero);          // OPEN_EXISTING

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = desk;
        si.dwFlags = (int)STARTF_USESTDHANDLES;
        si.hStdInput = hIn;
        si.hStdOutput = hOut;
        si.hStdError = hErr;

        string cmdline = "\"" + exe + "\"" + (argv.Length > 0 ? " " + argv : "");
        PROCESS_INFORMATION pi;
        bool ok = CreateProcessW(null, cmdline, IntPtr.Zero, IntPtr.Zero, true, CREATE_NO_WINDOW, IntPtr.Zero, cwd, ref si, out pi);
        int err = Marshal.GetLastWin32Error();
        CloseHandle(hIn);
        if (hOut != INVALID_HANDLE_VALUE) { CloseHandle(hOut); }
        if (hErr != INVALID_HANDLE_VALUE) { CloseHandle(hErr); }
        if (!ok) { CloseDesktop(hDesk); msg = "CreateProcessW failed err=" + err + " cmd=" + cmdline; return 125; }
        if (pidFile != null && pidFile.Length > 0) { try { System.IO.File.WriteAllText(pidFile, pi.dwProcessId.ToString()); } catch {} }

        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job != IntPtr.Zero)
        {
            JOB_EXTENDED ji = new JOB_EXTENDED();
            ji.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int len = Marshal.SizeOf(typeof(JOB_EXTENDED));
            IntPtr p = Marshal.AllocHGlobal(len);
            Marshal.StructureToPtr(ji, p, false);
            SetInformationJobObject(job, 9, p, (uint)len);   // 9 = JobObjectExtendedLimitInformation
            Marshal.FreeHGlobal(p);
            AssignProcessToJobObject(job, pi.hProcess);
        }

        bool timedOut = false;
        uint code;
        long posOut = 0, posErr = 0;
        if (stream)
        {
            DateTime deadline = timeoutSec > 0 ? DateTime.UtcNow.AddSeconds(timeoutSec) : DateTime.MaxValue;
            while (true)
            {
                uint w = WaitForSingleObject(pi.hProcess, 200);
                posOut = Pump(outFile, posOut, false);
                posErr = Pump(errFile, posErr, true);
                if (w != WAIT_TIMEOUT) { break; }
                if (DateTime.UtcNow >= deadline) { timedOut = true; break; }
            }
            if (timedOut)
            {
                if (job != IntPtr.Zero) { TerminateJobObject(job, 1); }
                WaitForSingleObject(pi.hProcess, 10000);
            }
            Pump(outFile, posOut, false);
            Pump(errFile, posErr, true);
        }
        else
        {
            uint ms = timeoutSec > 0 ? (uint)(timeoutSec * 1000) : INFINITE;
            uint w = WaitForSingleObject(pi.hProcess, ms);
            timedOut = (w == WAIT_TIMEOUT);
            if (timedOut)
            {
                if (job != IntPtr.Zero) { TerminateJobObject(job, 1); }
                WaitForSingleObject(pi.hProcess, 10000);
            }
        }
        GetExitCodeProcess(pi.hProcess, out code);
        if (timedOut) { msg = "TIMEOUT after " + timeoutSec + " s"; code = 124; }

        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        if (job != IntPtr.Zero) { CloseHandle(job); }
        CloseDesktop(hDesk);
        return (int)code;
    }
}
'@

function Quote-Arg([string]$s) {
  if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
  return $s
}
$argvStr = (($Argv | ForEach-Object { Quote-Arg $_ }) -join ' ')
$exeFull = $Exe
if (-not [IO.Path]::IsPathRooted($exeFull)) {
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
  if ($cmd) { $exeFull = $cmd.Source }
}
Add-Type -TypeDefinition $src -Language CSharp
$msg = ''
$code = [FlintSilentDesk]::Run($deskName, $exeFull, $argvStr, $WorkDir, $OutFile, $ErrFile, $PidFile, $TimeoutSec, $Stream.IsPresent, [ref]$msg)
if ($msg -ne '') { [Console]::Error.WriteLine('silent-gate: ' + $msg) }
# One trailer line, deliberately ending with ')' so that test\verify-all.ps1's "N / M" summary
# parser (regex: digits at end of line) can never mistake this line for a result line.
Write-Host ('silent-gate: exit ' + $code + ', desktop closed (out: ' + $OutFile + ' | err: ' + $ErrFile + ')')
exit $code
