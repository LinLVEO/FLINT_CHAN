// PresentMonFps.cs —— 桥内置的帧率采集：起外部 PresentMon.exe（Intel 开源，ETW 系统级）并解析它的 stdout CSV。
//
// 为什么跟 PresentMon（用户 2026-09-16 22:5x 拍板选 B）：RTSS 通道本身没错，但真实 RTSS **没钩住任何应用**时
//   读不到值（浮窗显示 `--`），而 C# 参考版此刻能读到 FPS ⇒ 属"用户看得见的差异"，不能只当边界记着。
//   C# 参考版的做法就是「起外部 PresentMon.exe + 解析输出」（E:\HardwareMonitor\PresentMonFps.cs），本文件按
//   同一套口径实现，但**在桥内部托管线程里跑**（宿主 FLINT 侧只多调一个 api）。
//
// 口径（与参考版逐条对齐，别自己发明）：
//   · 无 target = 全系统跟踪（不随前台切换重启）；每进程保留最近 900 个帧间隔（约 15 秒@60fps）。
//   · 选"帧率最高的活跃进程" = 样本 ≥10 且**平均帧间隔最小**；样本 <10 不算数；30 秒无新帧的进程清掉。
//   · **排除 dwm.exe**（系统合成器，帧率恒等于刷新率，会盖掉真实应用）；进程名取不到（<unknown>）也排除。
//   · 1% low = 该进程最近帧间隔里**最大 1% 的平均**（最卡的那批），帧率 = 1000 / 平均帧间隔；样本 ≥60 才给。
//
// 参数组合（坑清单 记忆归档\工具技巧.md「PresentMon(ETW) 帧率采集」，2026-08-30 实测）：
//   · `--output_stdout` 输出 CSV 到 stdout；**不能用 `--no_csv`**（与 output_stdout 互斥，会被忽略）。
//   · 用 `--stop_existing_session`（清残留同名会话）；**不能用 `--terminate_existing_session`**
//     —— 那个是"终止旧会话后**退出**"，现象是启动即退 + 重启循环。
//   · 需要管理员（ETW）；本产物用 `flint -admin` 构建 ⇒ 子进程自然继承提权。
//   · 跟踪 Chromium 必须 `--process_name`（渲染在 GPU 子进程）——本桥做的是"全系统 + 取最高帧率"，不指定 target。
//
// 2026-09-17 本机实测（pmprobe：E:\FLINT-lab\libcs\hwbridge\pmprobe\）：
//   从托管进程起 PresentMon **9ms 返回**、12 秒收到 2885 条数据行；表头 28 列，`ProcessID` 在第 1 列、
//   `MsBetweenPresents` 在第 10 列（**按名字定位，不写死列号**）；144Hz 屏下 dwm 与 msedge 都读到 144.0 fps（dwm 被排除）。
//   注意：`--stop_existing_session` 会**抢走**同名 ETW 会话（8080 参考版的 PresentMon 会被顶掉），
//   反向亦然 —— 两版同刻对照时要知道这件事（见 §"同刻对照"做法）。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace HwBridge
{
    internal static class PresentMonFps
    {
        private const string ExeName = "PresentMon.exe";
        /// <summary>
        /// 本桥 ETW 会话名的**前缀**（与 8080 参考版不同即可）。后缀在每次启动时拼上"宿主 PID + 系统 tick"。
        /// 2026-09-17 一晚实测出四条，按发生顺序留证（别再用"想当然"改回去）：
        ///   ① 两版都用默认名 "PresentMon" → **互相抢**：我们的 `--stop_existing_session` 顶掉参考版会话，
        ///      参考版立刻抢回去 ⇒ 我们这边 `error 4201`，一行数据都没有。
        ///   ② 用"固定专属名 PresentMonHWBRIDGE"：两版不抢了，但**自己下次启动撞自己的残留**——
        ///      被强杀留下的同名 ETW 会话清不掉（`--stop_existing_session` 报"will be stopped"之后就是没有数据：
        ///      实测 00:42:06 / 00:42:41 / 00:43:12 / 00:43:55 / 00:44:31 五次全零数据行，桥日志写得明明白白）。
        ///   ③ 只有"换名重试"那一次拿到了真数据（00:40:45 用 …HWBRIDGE2 → 106.8 fps / src=msedge）。
        ///   ④ 结论：**唯一名（前缀+PID+tick）**才是稳的——名字永不重复 ⇒ 既不需要清别人的会话，也不撞自己的残留；
        ///      重试机制保留，用来兜"名字以外"的启动失败。
        /// 前缀可被同目录 `HwBridge.pmsession.txt` 覆盖（排查时固定名字用）。
        /// </summary>
        private const string DefaultSession = "PresentMonHWBRIDGE";
        private const int FrameHistoryMax = 900;   // 每进程保留最近 15 秒（60fps）
        private const int MinSamples = 10;         // 少于这些帧的进程不算数
        private const int LowMinSamples = 60;      // 1% low 的样本门槛（与参考版一致）
        private const double StaleSec = 30.0;      // 30 秒无新帧的进程清掉，防字典无限增长

        private static readonly object Gate = new object();
        private static readonly Dictionary<int, float[]> Hist = new();      // pid -> 环形缓冲
        private static readonly Dictionary<int, int> HistN = new();         // pid -> 已有样本数
        private static readonly Dictionary<int, int> HistPos = new();       // pid -> 环形写指针
        private static readonly Dictionary<int, DateTime> LastFrame = new();
        private static readonly Dictionary<int, string> ProcNames = new();

        private static Process? s_proc;
        private static int s_tried;            // 0=没试过 1=试过（幂等）
        private static int s_parentQueryOk;    // 父 PID 查询自检：0=没测过 / 1=可用 / -1=不可用
        private static int s_attempt;          // 已启动次数（第 2 次起换会话名重试）
        /// <summary>最多试几次起 PresentMon（每次都换会话名）。上限的存在意义：别在 ETW 不可用时无限重启。</summary>
        private const int MaxAttempts = 3;
        private static string s_sourceDir = ""; // PresentMon.exe 所在目录（默认 = 本 DLL 目录）
        private static int s_status;            // 见 PmStatus
        private static int s_msCol = -1, s_pidCol = -1;
        private static bool s_headerSeen;
        private static StreamWriter? s_dbg;     // 与 DLL 同目录的 HwBridge.pmdebug.txt（只有该文件存在才写）
        private static string s_lastErr = "";
        private static int s_lines;
        private static DateTime s_startedAt;

        // 对外状态位（hw_fps_ext 第 3 个返回值就是它）
        internal const int PM_EXE_FOUND = 1;    // 找到 PresentMon.exe
        internal const int PM_STARTED = 2;      // 子进程起得来
        internal const int PM_DATA = 4;         // 收到过数据行（表头之外）
        internal const int PM_FPS = 8;          // 有可用帧率
        internal const int PM_EXITED = 16;      // 子进程已退出（异常/被杀）
        internal const int PM_NO_EXE = 32;      // 明确没找到 exe（降级：显示 --）
        internal const int PM_STARTING = 64;    // 启动中（防止重入时把"还没起好"误判成"已退出"）

        /// <summary>桥侧意向：0 = 不要跑（默认）/ 1 = 要跑。由 FLINT 侧 hw_pm_want(1) 打开。</summary>
        private static int s_want;

        internal static int Status { get { lock (Gate) return s_status; } }
        internal static int DataLines { get { lock (Gate) return s_lines; } }
        internal static string LastError { get { lock (Gate) return s_lastErr; } }

        internal static void SetSourceDir(string dir) { lock (Gate) if (dir.Length > 0) s_sourceDir = dir; }

        /// <summary>要不要跑（1=要）。桥侧只认这个意向，不自己决定。</summary>
        internal static void Want(int on)
        {
            lock (Gate) s_want = on != 0 ? 1 : 0;
        }

        internal static int WantState() { lock (Gate) return s_want; }

        /// <summary>幂等启动（一次 hw_snap 里最多试一次；**失败会换会话名重试**，上限 MaxAttempts）。</summary>
        internal static void EnsureStarted()
        {
            lock (Gate)
            {
                if (s_want == 0) return;                                  // 桥侧没说要跑
                if (s_tried != 0)
                {
                    Process? p = s_proc;
                    bool dead = p == null || SafeHasExited(p);
                    if (!dead) return;                                    // 还活着（或在启动中）：不动
                    // 子进程已退出/没起来 —— 两种情形都算失败：① 起不来（ETW 4201 等）
                    //   ② 起来了又退出（渲染样本不足时 PresentMon 会自己收工）。都靠**换名重试**自愈。
                    if (s_attempt >= MaxAttempts)
                    {
                        s_status |= PM_EXITED;
                        Dbg("give up after " + s_attempt + " attempts (lines=" + s_lines + ")");
                        return;
                    }
                    Dbg("retry " + (s_attempt + 1) + "/" + MaxAttempts + " (lines=" + s_lines + ")");
                }
                s_tried = 1;
                s_status |= PM_STARTING;
            }
            try { Start(); }
            catch (Exception ex) { lock (Gate) { s_status |= PM_NO_EXE; s_lastErr = "start: " + ex.Message; Dbg(s_lastErr); } }
        }

        private static bool SafeHasExited(Process p) { try { return p.HasExited; } catch { return true; } }

        /// <summary>停止子进程（hw_pm_want(0) / hw_pm_stop 调；进程被宿主强杀时它会跟着死）。</summary>
        internal static void Stop()
        {
            Process? p;
            lock (Gate) { p = s_proc; s_proc = null; }
            if (p == null) return;
            try { if (!p.HasExited) { p.Kill(entireProcessTree: true); p.WaitForExit(500); } } catch { }
            Dbg("stopped");
        }

        private static void Start()
        {
            SweepOrphans();
            string dir;
            lock (Gate) dir = s_sourceDir.Length > 0 ? s_sourceDir : (OwnDir() ?? "");
            string exe = dir.Length > 0 ? Path.Combine(dir, ExeName) : ExeName;
            Dbg("start: dir=" + dir + " exe=" + exe + " exists=" + File.Exists(exe));
            if (!File.Exists(exe))
            {
                lock (Gate)
                {
                    // 兜底：参考版目录（同机 8080 那套）里通常有一份 —— 但**只在同目录缺件时**才借，
                    // 借的是 exe 本身，不影响交付形态（交付目录带自己的那一份）。
                    string alt = @"E:\HardwareMonitor\PresentMon\" + ExeName;
                    if (File.Exists(alt)) { exe = alt; Dbg("fallback exe: " + alt); }
                    else { s_status |= PM_NO_EXE; s_lastErr = "PresentMon.exe not found: " + exe; Dbg(s_lastErr); return; }
                }
            }
            lock (Gate) s_status |= PM_EXE_FOUND;

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetTempPath(),   // 兜底：万一它还是写 CSV，写进临时目录
            };
            psi.ArgumentList.Add("--output_stdout");
            // 会话名：固定专属名 + 第几次尝试（见 DefaultSession）；去空白 —— 名字带空格时 ETW 报 4201，症状与重名一样。
            string baseName = DefaultSession;
            var nameFile = Path.Combine(Path.GetDirectoryName(exe) ?? "", "HwBridge.pmsession.txt");
            try
            {
                if (File.Exists(nameFile))
                {
                    string n = File.ReadAllText(nameFile).Trim();
                    if (n.Length > 0) baseName = n;
                }
            }
            catch { /* 读不到就用默认名 */ }
            baseName = baseName.Replace(" ", "").Replace("\t", "");
            int nth;
            lock (Gate) nth = s_attempt++;
            // 唯一名：前缀 + 宿主 PID + 系统 tick（每次调用都重取 tick ⇒ 重试也必换名字）
            string sess = baseName + UniqueTag();
            psi.ArgumentList.Add("--session_name");
            psi.ArgumentList.Add(sess);
            if (nth == 0) psi.ArgumentList.Add("--stop_existing_session");   // 首次尝试：顺手清同名残留（只碰自己的前缀）

            var p = new Process { StartInfo = psi };
            p.OutputDataReceived += OnOut;
            p.ErrorDataReceived += OnErr;
            bool ok = p.Start();
            if (!ok) { lock (Gate) { s_status |= PM_NO_EXE; s_lastErr = "Process.Start returned false"; } return; }
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            lock (Gate)
            {
                s_proc = p;
                s_headerSeen = false;
                s_msCol = s_pidCol = -1;
                s_status |= PM_STARTED;
                s_status &= ~PM_STARTING;
                s_startedAt = DateTime.UtcNow;
                Hist.Clear(); HistN.Clear(); HistPos.Clear(); LastFrame.Clear(); ProcNames.Clear();
            }
            Dbg("started pid=" + p.Id + " args=" + string.Join(' ', psi.ArgumentList));
        }

        /// <summary>全局唯一后缀：宿主 PID + 系统 tick（同机不可能重名；ETW 会话名上限 200 字符，够用）。
        /// 不用 GUID / 第三方库 —— NativeAOT 下越简单越好。</summary>
        private static string UniqueTag()
        {
            int pid = 0, tick = 0;
            try { pid = Environment.ProcessId; } catch { }
            try { tick = Environment.TickCount; } catch { }
            return pid.ToString() + "_" + (tick < 0 ? tick + int.MaxValue : tick).ToString();
        }

        /// <summary>
        /// 查某进程的父 PID（查不到返回 -1）。用 WMI（Win32_Process）—— .NET 8 的 Process 类没有 ParentId。
        /// ⚠️ NativeAOT 下 WMI 有可能根本不可用（被 trim / COM 路径缺失）⇒ **每次调用都返回 -1**，
        ///    那样清扫器会把**所有**实例都当孤儿（实测：把自己的子进程给扫了，接着一路 4201）。
        ///    所以能不能信这条查询，由 <see cref="ParentQueryWorks"/> 的自检门决定。
        /// </summary>
        private static int ParentPidOf(int pid)
        {
            try
            {
                var q = new System.Management.ManagementObjectSearcher(
                    "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId=" + pid);
                foreach (System.Management.ManagementBaseObject o in q.Get())
                {
                    object? v = o["ParentProcessId"];
                    if (v != null) return Convert.ToInt32(v);
                }
            }
            catch { }
            return -1;
        }

        /// <summary>自检门：拿**本进程自己**试查一次父 PID，验证这条查询在 NativeAOT 下真的好用（结果缓存）。</summary>
        private static bool ParentQueryWorks()
        {
            if (s_parentQueryOk != 0) return s_parentQueryOk > 0;
            bool ok = ParentPidOf(Environment.ProcessId) > 0;
            s_parentQueryOk = ok ? 1 : -1;
            Dbg("parent-query self-test: " + (ok ? "OK" : "UNAVAILABLE -> 清扫器保守跳过"));
            return ok;
        }

        /// <summary>
        /// 清扫**孤儿** PresentMon：父进程已经不存在的实例。
        /// 为什么需要：宿主（浮窗）被强杀时子进程会活下来当孤儿（CLR 的 child-process tracking 不覆盖强杀），
        ///   而会话名是固定的 ⇒ 孤儿占住名字，下次启动就 4201；实测三个孤儿各占 1~3% 单核。
        /// 为什么只清孤儿：8080 参考版也跑 PresentMon，**它的实例父进程活着** ⇒ 一律不碰（两版不互相拆台）。
        /// 保守原则（两次实测教训）：① 父查询自检不过 → 一个都不碰；② 查不到某个实例的父 PID → 跳过它；
        ///   ③ 只有"查到父 PID 且那个进程确实已死"才动手。
        /// </summary>
        private static void SweepOrphans()
        {
            try
            {
                Process[] all = Process.GetProcessesByName("PresentMon");
                if (all.Length == 0) return;
                if (!ParentQueryWorks())
                {
                    Dbg("sweep skipped (" + all.Length + " 个 PresentMon 实例): 父查询不可用");
                    return;
                }
                int swept = 0, kept = 0, unknown = 0;
                foreach (Process p in all)
                {
                    bool orphan = false;
                    if (!p.HasExited && p.Id != Environment.ProcessId)
                    {
                        // ⚠️ .NET 8 **没有** Process.ParentId（那是 .NET 9 才加的；写成 ParentId 直接 CS1061）。
                        //   这里只需要回答"父还在不在"，不必知道父是谁 ⇒ WMI 取父 PID，再查父进程是否已死。
                        int ppid = ParentPidOf(p.Id);
                        if (ppid > 0)
                        {
                            try { using Process parent = Process.GetProcessById(ppid); orphan = parent.HasExited; }
                            catch (ArgumentException) { orphan = true; }     // 父已死
                            catch { orphan = false; }                        // 其它异常：保守不动
                        }
                        else unknown++;
                    }
                    if (orphan)
                    {
                        try { p.Kill(); p.WaitForExit(1000); swept++; Dbg("swept orphan PresentMon pid=" + p.Id); }
                        catch (Exception ex) { Dbg("sweep failed pid=" + p.Id + ": " + ex.Message); }
                    }
                    else kept++;
                }
                Dbg("sweep done: 清掉 " + swept + " / 保留 " + kept + " / 父未知跳过 " + unknown);
            }
            catch { /* 清扫失败不影响主流程 */ }
        }

        /// <summary>本 DLL 所在目录（与 HwBridge.cs 里的同名逻辑同一招：按自身代码地址反查模块）。</summary>
        private static string? OwnDir()
        {
            try
            {
                var m = System.Reflection.Assembly.GetExecutingAssembly().Location;
                if (!string.IsNullOrEmpty(m)) return Path.GetDirectoryName(m);
            }
            catch { }
            try
            {
                string b = AppContext.BaseDirectory;
                if (!string.IsNullOrEmpty(b)) return b.TrimEnd(Path.DirectorySeparatorChar);
            }
            catch { }
            return null;
        }

        private static void OnOut(object sender, DataReceivedEventArgs e)
        {
            string? line = e.Data;
            if (string.IsNullOrWhiteSpace(line)) return;
            try
            {
                var cols = line.Split(',');
                if (!s_headerSeen)
                {
                    for (int i = 0; i < cols.Length; i++)
                    {
                        string n = cols[i].Trim('"').Trim();
                        if (s_pidCol < 0 && n.Equals("ProcessID", StringComparison.OrdinalIgnoreCase)) s_pidCol = i;
                        if (s_msCol < 0 && n.Equals("MsBetweenPresents", StringComparison.OrdinalIgnoreCase)) s_msCol = i;
                    }
                    s_headerSeen = true;
                    lock (Gate) s_lines++;      // 表头也算一行，方便"到底有没有输出"这类判断
                    Dbg("header: cols=" + cols.Length + " pidCol=" + s_pidCol + " msCol=" + s_msCol);
                    return;
                }
                if (s_pidCol < 0 || s_msCol < 0) return;
                if (cols.Length <= s_pidCol || cols.Length <= s_msCol) return;
                if (!int.TryParse(cols[s_pidCol].Trim('"').Trim(), out int pid) || pid <= 0) return;
                if (!float.TryParse(cols[s_msCol].Trim('"').Trim(), out float ms)) return;
                if (ms <= 0.1f || ms >= 2000f) return;      // 有效帧间隔 0.1ms ~ 2s

                lock (Gate)
                {
                    s_lines++;
                    s_status |= PM_DATA;
                    if (!ProcNames.ContainsKey(pid))
                    {
                        string nm = "";
                        try { nm = Process.GetProcessById(pid).ProcessName; } catch { nm = ""; }
                        ProcNames[pid] = nm;
                    }
                    if (!Hist.TryGetValue(pid, out float[]? buf))
                    {
                        buf = new float[FrameHistoryMax];
                        Hist[pid] = buf; HistN[pid] = 0; HistPos[pid] = 0;
                    }
                    int pos = HistPos[pid];
                    buf[pos] = ms;
                    HistPos[pid] = (pos + 1) % FrameHistoryMax;
                    if (HistN[pid] < FrameHistoryMax) HistN[pid]++;
                    LastFrame[pid] = DateTime.UtcNow;
                }
            }
            catch (Exception ex) { lock (Gate) s_lastErr = "parse: " + ex.Message; }
        }

        private static void OnErr(object sender, DataReceivedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(e.Data)) return;
            string s = e.Data.Trim();
            lock (Gate) { s_lastErr = s; Dbg("[stderr] " + s); }
        }

        /// <summary>当前帧率最高的活跃进程 → (fps, 1%low, 来源名)。数据不足返回 null。</summary>
        internal static (float fps, float? low, int samples, string src)? Current()
        {
            EnsureStarted();          // 幂等、不阻塞；只在"桥侧说要跑且还没试过"时真动手
            int bestPid = -1;
            float bestAvg = float.MaxValue;
            int bestN = 0;
            lock (Gate)
            {
                var now = DateTime.UtcNow;
                var dead = new List<int>();
                foreach (var kv in HistN)
                {
                    int pid = kv.Key;
                    if (LastFrame.TryGetValue(pid, out var t) && (now - t).TotalSeconds > StaleSec) { dead.Add(pid); continue; }
                    if (kv.Value < MinSamples) continue;
                    string nm = ProcNames.TryGetValue(pid, out var n) ? n : "";
                    if (nm.Length == 0) continue;                                   // <unknown>：查不到名字的不算
                    if (nm.Equals("dwm", StringComparison.OrdinalIgnoreCase)) continue;  // 系统合成器：帧率恒=刷新率
                    float[] buf = Hist[pid];
                    int cnt = kv.Value, pos = HistPos[pid];
                    float sum = 0;
                    for (int i = 0; i < cnt; i++) sum += buf[i];                    // cnt ≤ 900：全量求和，与参考版同口径
                    float avg = sum / cnt;
                    if (avg > 0 && avg < bestAvg) { bestAvg = avg; bestPid = pid; bestN = cnt; }
                }
                foreach (int pid in dead)
                {
                    Hist.Remove(pid); HistN.Remove(pid); HistPos.Remove(pid);
                    LastFrame.Remove(pid); ProcNames.Remove(pid);
                }
                if (bestPid < 0) return null;
                float fps = 1000f / bestAvg;
                float? low = null;
                if (bestN >= LowMinSamples)
                {
                    float[] buf = Hist[bestPid];
                    int cnt = bestN;
                    var arr = new float[cnt];
                    Array.Copy(buf, arr, cnt);
                    Array.Sort(arr);                                                // 升序：最后面是最慢（最卡）的帧
                    int take = Math.Max(1, cnt / 100);
                    float s = 0;
                    for (int i = cnt - take; i < cnt; i++) s += arr[i];
                    float la = s / take;
                    if (la > 0) low = 1000f / la;
                }
                s_status |= PM_FPS;
                string src = ProcNames[bestPid];
                return (fps, low, bestN, src);
            }
        }

        /// <summary>来源进程名（无数据返回空串）。</summary>
        internal static string SourceName()
        {
            var c = Current();
            return c.HasValue ? c.Value.src : "";
        }

        internal static int SampleCount()
        {
            var c = Current();
            return c.HasValue ? c.Value.samples : 0;
        }

        // ───────────────────────── 诊断日志（只有同目录存在 HwBridge.pmdebug.txt 才写）─────────────────────────
        internal static void Debug(string msg) => Dbg(msg);

        private static void Dbg(string msg)
        {
            try
            {
                if (s_dbg == null)
                {
                    string? dir = OwnDir();
                    if (dir == null) return;
                    string flag = Path.Combine(dir, "HwBridge.pmdebug.txt");
                    if (!File.Exists(flag)) return;
                    s_dbg = new StreamWriter(flag, append: true) { AutoFlush = true };
                    s_dbg.WriteLine("==== PresentMonFps debug @ " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " ====");
                }
                s_dbg.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg);
            }
            catch { /* 日志失败绝不影响测帧 */ }
        }
    }
}
