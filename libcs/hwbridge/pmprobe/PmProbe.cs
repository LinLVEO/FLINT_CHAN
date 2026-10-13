// PmProbe.cs —— 一次性探针：验证"从 .NET 子里程碑直起 PresentMon.exe + 读 stdout CSV"这条路能否走通。
// 用途：HwBridge.dll 里要内置 PresentMon 通道，先用它把①参数组合②会话冲突③帧速率数字 摸清楚，
//       免得把探路成本塞进 DLL（DLL 里出问题只能靠浮窗表现猜）。
//
// 用法： pmprobe.exe [秒数] [会话名]        默认 8 秒 / 空会话名（用 PresentMon 默认 "PresentMon"）
// ⚠️ 显式 using（本机 SDK 的 ImplicitUsings 没生效，写全了省事）
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

int secs = args.Length > 0 && int.TryParse(args[0], out int s) ? s : 8;
string sess = args.Length > 1 ? args[1] : "";
string exe = args.Length > 2 ? args[2] : @"E:\HardwareMonitor\PresentMon\PresentMon.exe";

Console.WriteLine($"exe      = {exe}  exists={File.Exists(exe)}");
Console.WriteLine($"secs     = {secs}");
Console.WriteLine($"session  = '{(sess.Length == 0 ? "(default)" : sess)}'");

var psi = new ProcessStartInfo
{
    FileName = exe,
    UseShellExecute = false,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    CreateNoWindow = true,
    WorkingDirectory = Path.GetTempPath(),
};
psi.ArgumentList.Add("--output_stdout");
if (sess.Length > 0) { psi.ArgumentList.Add("--session_name"); psi.ArgumentList.Add(sess); }
else psi.ArgumentList.Add("--stop_existing_session");

var lines = new List<string>();
int dataLines = 0;
string? header = null;
int pidCol = -1, msCol = -1;
var byProc = new Dictionary<int, List<float>>();

using var p = new Process { StartInfo = psi };
p.OutputDataReceived += (_, e) =>
{
    if (string.IsNullOrWhiteSpace(e.Data)) return;
    lock (lines)
    {
        if (lines.Count < 6) lines.Add(e.Data);
        if (header == null)
        {
            header = e.Data;
            var hc = header.Split(',');
            for (int i = 0; i < hc.Length; i++)
            {
                string n = hc[i].Trim('"').Trim();
                if (pidCol < 0 && n.Equals("ProcessID", StringComparison.OrdinalIgnoreCase)) pidCol = i;
                if (msCol < 0 && n.Equals("MsBetweenPresents", StringComparison.OrdinalIgnoreCase)) msCol = i;
            }
            Console.WriteLine($"header cols = {hc.Length}  pidCol={pidCol} msCol={msCol}");
            return;
        }
        dataLines++;
        var c = e.Data.Split(',');
        if (pidCol < 0 || msCol < 0 || c.Length <= Math.Max(pidCol, msCol)) return;
        if (int.TryParse(c[pidCol].Trim('"'), out int pid) && float.TryParse(c[msCol].Trim('"'), out float ms))
        {
            if (!byProc.TryGetValue(pid, out var q)) byProc[pid] = q = new List<float>();
            if (ms > 0.1f && ms < 2000f && q.Count < 4000) q.Add(ms);
        }
    }
};
p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Console.Error.WriteLine("  [stderr] " + e.Data); };

var sw = Stopwatch.StartNew();
bool started = p.Start();
Console.WriteLine($"started  = {started}  pid={p.Id}  in {(int)sw.ElapsedMilliseconds}ms");
if (!started) return 4;
p.BeginOutputReadLine();
p.BeginErrorReadLine();
await Task.Delay(secs * 1000);
Console.WriteLine($"alive after {secs}s = {!p.HasExited}");
try { if (!p.HasExited) p.Kill(true); } catch { }
try { p.WaitForExit(3000); } catch { }

Console.WriteLine($"exit     = {(p.HasExited ? p.ExitCode.ToString() : "still running")}");
lock (lines)
{
    Console.WriteLine($"lines    = {lines.Count} (data={dataLines})");
    Console.WriteLine("---- 前几行 ----");
    foreach (var l in lines) Console.WriteLine("  " + (l.Length > 220 ? l.Substring(0, 220) + "…" : l));
    Console.WriteLine("---- 按 pid 汇总（帧间隔样本数 / 平均 fps）----");
    foreach (var kv in byProc.OrderByDescending(k => k.Value.Count).Take(8))
    {
        float avg = kv.Value.Average();
        string name = "";
        try { name = Process.GetProcessById(kv.Key).ProcessName; } catch { name = "?"; }
        Console.WriteLine($"  pid={kv.Key,-7} n={kv.Value.Count,-5} avgTabMs={avg,8:F3}  fps={1000f / avg,7:F1}  {name}");
    }
}
return p.HasExited && p.ExitCode != 0 ? p.ExitCode : 0;
