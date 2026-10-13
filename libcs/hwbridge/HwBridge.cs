// HwBridge.cs —— 把 C# 的 LibreHardwareMonitor（LHM）在**同进程**内提供给 FLINT 浮窗。
//
// 为什么这样做（用户口径）：浮窗原来靠"外部 C# 版进程 + 8080 JSON"拿 CPU 温度/功耗、GPU、FPS；
// 现在用今天打通的"编译期缝合"能力，把 LHM 直接编进这个原生 DLL，FLINT 用
//   api "HwBridge.dll" int hw_init();
//   api "HwBridge.dll" int hw_snap(int *buf);
// 直调（导入表一条记录），彻底去掉外部进程依赖。
//
// 分工（别重复劳动）：**CPU 温度/功耗、GPU 温度/占用/显存、FPS 由本 DLL 提供**；
// 内存/磁盘/网速 FLINT 侧本来就能自己读（hw.fl），**本 DLL 不碰**，对应槽位留 0 + 有效位清零。
//
// 权限：LHM 的 Ring0（WinRing0 设备 \\.\WinRing0_1_2_0，服务 R0HardwareMonitor）**需要管理员**；
// 宿主（FLINT 产物）用 flint -admin 构建即可（本机 UAC 静默提权）。非管理员时 CPU 传感器会拿不到，
// 但 DLL 仍应稳定可用（GPU 走 AMD ADL，不需要提权）。
using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using LibreHardwareMonitor.Hardware;

namespace HwBridge
{
    /// <summary>导出给原生宿主（FLINT）的 C ABI 面。</summary>
    public static unsafe class Native
    {
        // ── hw_snap 输出缓冲布局（全部 ×1000 定点整数，与 FLINT 侧 JSON 取值层同口径）──
        internal const int I_CPU_TEMP = 0;      // °C
        internal const int I_CPU_LOAD = 1;      // %
        internal const int I_CPU_CLOCK = 2;     // MHz
        internal const int I_CPU_POWER = 3;     // W
        internal const int I_GPU_TEMP = 4;
        internal const int I_GPU_LOAD = 5;
        internal const int I_GPU_MEM_USED = 6;  // GB
        internal const int I_GPU_MEM_TOTAL = 7; // GB
        internal const int I_GPU_POWER = 8;     // W
        internal const int I_RAM_USED = 9;      // 留 0：FLINT 本地能读
        internal const int I_RAM_TOTAL = 10;
        internal const int I_RAM_LOAD = 11;
        internal const int I_FAN_RPM = 12;      // 本机主板无传感器（C# 版同为 null）
        internal const int I_FPS = 13;
        internal const int I_FPS_LOW = 14;
        internal const int I_DISK_LOAD = 15;    // 留 0：FLINT 本地能读
        internal const int I_DISK_USED = 16;
        internal const int I_DISK_TOTAL = 17;
        internal const int I_NET_DOWN = 18;     // 留 0：FLINT 本地能读
        internal const int I_NET_UP = 19;
        internal const int I_SYS_POWER = 20;    // = cpu + gpu + base（与 C# 版 EstimateSystemPower 同式）
        internal const int I_BASE_POWER = 21;   // 底噪常数（C# 版默认 45）
        internal const int I_VALID_MASK = 22;   // bit i = 字段 i 有效
        internal const int I_FLAGS = 23;        // 低 8 位 = 状态位；高位 = 采样序号

        internal const int SNAP_LEN = 24;
        internal const double BASE_POWER = 45.0;

        private static Computer? s_computer;
        private static IHardware? s_cpu;
        private static IHardware? s_gpu;
        private static int s_inited;      // 0=未初始化 1=已尝试
        private static int s_status;      // 见 F_* 位
        private static int s_seq;

        private const int F_INIT_OK = 1;      // hw_init 没抛异常
        private const int F_CPU = 2;          // 找到 CPU 硬件
        private const int F_GPU = 4;          // 找到 GPU 硬件
        private const int F_RTSS = 8;         // RTSS 共享内存可读（曾成功读到 FPS）
        private const int F_PM = 16;          // 本快照的 FPS 来自 PresentMon（bit4；RTSS 来的不置位）
        private const int F_LOW_PM = 32;      // 本快照的 1% low 来自 PresentMon（bit5）
        private const int F_STATUS_MASK = 0x0F;   // F_FLAGS 低 4 位 = 真正的"桥状态"

        // FPS 的 1% low 用最近若干次采样的帧时间算（每次 hw_snap 采一次）
        private static readonly float[] s_ftRing = new float[256];
        private static int s_ftCount;
        private static int s_ftPos;

        /// <summary>初始化 LHM（幂等）。返回状态位（&lt;0 表示失败）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_init")]
        public static int HwInit() => InitCore();

        // ⚠️ [UnmanagedCallersOnly] 标注的方法**不能在托管代码里直接调用**（CS8901）→ 真实现放这里，
        // 导出壳与内部调用都走它。
        private static int InitCore()
        {
            if (s_inited != 0) return s_status;
            s_inited = 1;
            try
            {
                var c = new Computer
                {
                    IsCpuEnabled = true,
                    IsGpuEnabled = true,
                    // 内存/磁盘/主板/网络都不开：FLINT 本地能读内存与磁盘，且这几块会拖进 WMI/性能计数器
                    IsMemoryEnabled = false,
                    IsStorageEnabled = false,
                    IsMotherboardEnabled = false,
                    IsControllerEnabled = false,
                    IsNetworkEnabled = false,
                };
                c.Open();
                s_computer = c;
                foreach (IHardware hw in c.Hardware)
                {
                    if (hw.HardwareType == HardwareType.Cpu) s_cpu ??= hw;
                    else if (hw.HardwareType is HardwareType.GpuAmd or HardwareType.GpuNvidia or HardwareType.GpuIntel) s_gpu ??= hw;
                }
                s_status = F_INIT_OK | (s_cpu != null ? F_CPU : 0) | (s_gpu != null ? F_GPU : 0);
            }
            catch (Exception)
            {
                s_status = -1;
            }
            return s_status;
        }

        /// <summary>
        /// 读一次快照，写进调用方的 **4 字节 int** 缓冲（C 宿主 / 探针用）。
        /// ⚠️ FLINT 的 `int` 是 **8 字节槽**（跨语言老坑：同名不同物），所以 FLINT 侧必须用下面的 `hw_snap64`。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_snap")]
        public static unsafe int HwSnap(int* outv)
        {
            if (outv == null) return -1;
            int st;
            fixed (int* src = s_snap)
            {
                st = Fill(src);
                for (int i = 0; i < SNAP_LEN; i++) outv[i] = src[i];
            }
            return st;
        }

        /// <summary>
        /// 同一次快照，写进 **8 字节槽**（`long long*`）——给 FLINT 用（它的 `int` 就是 8 字节槽，
        /// 2026-09-16 实测：`int b[24]` 的第 j 个元素落在字节偏移 8*j 上）。
        /// 这是"缝合"的关键 ABI 约定：**槽宽必须和宿主一致**，否则整个缓冲区错位（值会"看着像对的"）。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_snap64")]
        public static unsafe int HwSnap64(long* outv)
        {
            if (outv == null) return -1;
            int st;
            fixed (int* src = s_snap)
            {
                st = Fill(src);
                for (int i = 0; i < SNAP_LEN; i++) outv[i] = src[i];
            }
            return st;
        }

        private static readonly int[] s_snap = new int[SNAP_LEN];   // 中间结果（两套槽宽共用同一份逻辑）

        // PresentMon 通道（2026-09-17）：**本 DLL 侧不开子进程**，要 FLINT 侧显式说"我要 FPS"才启动
        //   （`hw_pm_want(1)`）—— 理由：桥要保持"你调我才动"，不然任何导入它的产物都凭空多一个
        //   ETW 子进程；且浮窗关掉 FPS 显示项时不该还在测帧（C# 参考版也是按 FpsMode 决定起停）。
        private static bool s_pmFromPm;      // 上一条 FPS 是否来自 PresentMon（决定 bit4/bit5 与样本数）
        private static int s_pmN;            // 上一条 PresentMon 采样数（给 FLAGS 高位用）

        /// <summary>诊断日志（只在同目录存在 HwBridge.pmdebug.txt 时写；每 10 次采样写一条，免得日志爆掉）。</summary>
        private static void DbgThrottled(string msg)
        {
            if ((s_seq % 10) != 0) return;
            PresentMonFps.Debug(msg);
        }

        /// <summary>告诉桥要不要跑 PresentMon（1=要；0=不要并停掉；-1=只查询当前意图，只读不改）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_pm_want")]
        public static int HwPmWant(int on)
        {
            if (on < 0) return PresentMonFps.WantState();
            if (on != 0)
            {
                PresentMonFps.SetSourceDir(PmDir() ?? "");
                PresentMonFps.Want(1);
            }
            else
            {
                PresentMonFps.Want(0);
                PresentMonFps.Stop();
            }
            return PresentMonFps.WantState();
        }

        /// <summary>
        /// 把当前帧率来源进程名拷进调用方缓冲（UTF-8 字节），返回实际字节数（0 = 没数据/名称未知）。
        /// 约定：cap = 缓冲**总字节数**（含结尾 0），最多写 cap-1 个字符字节 + 1 个 0。
        /// ⚠️ 调用方传参别自己先减 1（2026-09-17 实测踩到：宿主传 63、这里又减 1 ⇒ 名字被砍成 5 字节，
        ///     dump 里看着像"名字莫名其妙短了一截"）。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_pm_src")]
        public static unsafe int HwPmSrc(byte* buf, int cap)
        {
            if (buf == null || cap <= 0) return 0;
            byte[] bytes;
            try { bytes = System.Text.Encoding.UTF8.GetBytes(PresentMonFps.SourceName()); }
            catch { return 0; }
            if (bytes.Length == 0) return 0;
            int n = bytes.Length < cap - 1 ? bytes.Length : cap - 1;   // 留一个 0 结尾
            for (int i = 0; i < n; i++) buf[i] = bytes[i];
            buf[n] = 0;
            return n;
        }

        /// <summary>PresentMon 的启动诊断（bit0 exe在 / bit1 起来了 / bit2 有数据 / bit3 有帧率 / bit4 已退出 / bit5 没找到 exe）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_pm_status")]
        public static int HwPmStatus() => PresentMonFps.Status;

        /// <summary>PresentMon 收到的数据行数（0 = 一行都没来 → 多半是 ETW 起不来）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_pm_lines")]
        public static int HwPmLines() => PresentMonFps.DataLines;

        /// <summary>PresentMon.exe 的查找目录：环境变量 HWBRIDGE_PM_DIR &gt; 与 DLL 同目录的 HwBridge.pmdir.txt &gt; DLL 自身目录。</summary>
        private static string? PmDir()
        {
            try
            {
                string? e = Environment.GetEnvironmentVariable("HWBRIDGE_PM_DIR");
                if (!string.IsNullOrWhiteSpace(e)) return e;
            }
            catch { }
            try
            {
                string? d = OwnDirectory();
                if (d != null)
                {
                    string f = System.IO.Path.Combine(d, "HwBridge.pmdir.txt");
                    if (System.IO.File.Exists(f))
                    {
                        string t = System.IO.File.ReadAllText(f).Trim();
                        if (t.Length > 0) return t;
                    }
                    return d;
                }
            }
            catch { }
            return null;
        }

        /// <summary>收尾：把 PresentMon 子进程停掉（hw_pm_want(0) 会调；进程被宿主强杀时它会跟着死）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_pm_stop")]
        public static int HwPmStop() { PresentMonFps.Stop(); return 0; }

        private static unsafe int Fill(int* outv)
        {
            if (outv == null) return -1;
            if (s_inited == 0) InitCore();
            for (int i = 0; i < SNAP_LEN; i++) outv[i] = 0;

            int mask = 0;
            try
            {
                Update(s_cpu);
                Update(s_gpu);

                double? cpuTemp = MaxSensByName(s_cpu, SensorType.Temperature, "package", "tjmax", "core");
                cpuTemp ??= Sens(s_cpu, SensorType.Temperature, "package", "core");
                Put(outv, ref mask, I_CPU_TEMP, cpuTemp);
                Put(outv, ref mask, I_CPU_LOAD, Sens(s_cpu, SensorType.Load, "total"));
                Put(outv, ref mask, I_CPU_CLOCK, MaxSens(s_cpu, SensorType.Clock));
                Put(outv, ref mask, I_CPU_POWER, Sens(s_cpu, SensorType.Power, "package"));

                Put(outv, ref mask, I_GPU_TEMP, Sens(s_gpu, SensorType.Temperature, "core"));
                Put(outv, ref mask, I_GPU_LOAD, Sens(s_gpu, SensorType.Load, "core"));
                // LHM 的显存传感器在 SmallData 里，单位 MB
                double? memUsedMb = Sens(s_gpu, SensorType.SmallData, "memory used");
                double? memTotalMb = Sens(s_gpu, SensorType.SmallData, "memory total");
                Put(outv, ref mask, I_GPU_MEM_USED, memUsedMb / 1024.0);
                Put(outv, ref mask, I_GPU_MEM_TOTAL, memTotalMb / 1024.0);
                Put(outv, ref mask, I_GPU_POWER, Sens(s_gpu, SensorType.Power, "package", "gpu"));

                // —— FPS：**PresentMon 优先，RTSS 回退**（2026-09-17；口径对齐 C# 参考版的 FpsMode=auto）——
                // 为什么不让 RTSS 优先：RTSS 只在"它钩住了应用"时有值，没钩住就显示 `--`（用户看得见的差异）；
                // PresentMon 是全系统 ETW，不注入、不挑应用。RTSS 顺手还读一次（不额外开销），
                // 值保留在 hw_rtss_flags 里供诊断，但不再抢 FPS 槽位。
                float? pmFps = null, pmLow = null; int pmN = 0;
                var pm = PresentMonFps.Current();
                DbgThrottled("pm=" + (pm.HasValue ? ("fps=" + pm.Value.fps.ToString("F1") + " low=" + (pm.Value.low.HasValue ? pm.Value.low.Value.ToString("F1") : "null") + " n=" + pm.Value.samples + " src=" + pm.Value.src) : "null"));
                if (pm.HasValue && pm.Value.fps > 1f)
                {
                    pmFps = pm.Value.fps;
                    pmLow = pm.Value.low;
                    pmN = pm.Value.samples;
                }
                float? fps = pmFps;
                bool fpsFromPm = fps.HasValue;
                if (fps.HasValue)
                {
                    s_status |= F_PM;
                    PushFrameTime(1000f / fps.Value);
                }
                else
                {
                    fps = RtssFps(out bool fresh);
                    if (fps.HasValue && fresh) PushFrameTime(1_000_000f / fps.Value);
                }
                if (fps.HasValue) Put(outv, ref mask, I_FPS, fps.Value);

                // 1% low：有 PresentMon 就用它的（样本 ≥60 才算，与参考版一致）；
                // 否则用本地帧时间环（RTSS 通道的旧口径），保持回退路径与从前一致。
                float? low = pmLow;
                bool lowFromPm = low.HasValue;
                if (!low.HasValue) low = OnePercentLow();
                Put(outv, ref mask, I_FPS_LOW, low);

                double? cpuP = mask.At(I_CPU_POWER) ? outv[I_CPU_POWER] / 1000.0 : null;
                double? gpuP = mask.At(I_GPU_POWER) ? outv[I_GPU_POWER] / 1000.0 : null;
                Put(outv, ref mask, I_BASE_POWER, BASE_POWER);
                if (cpuP.HasValue || gpuP.HasValue)
                    Put(outv, ref mask, I_SYS_POWER, (cpuP ?? 0) + (gpuP ?? 0) + BASE_POWER);

                outv[I_VALID_MASK] = mask;
                // ⚠️ 低 4 位 = **真正的桥状态位**；bit4/bit5 是"本帧 FPS/1%low 来自 PresentMon"的**瞬时**标记，
                //   必须每帧重算 —— 不能直接用会累积的 s_status（PresentMon 一旦起不来/退出，会把 bit4/5 留成脏值，
                //   宿主就会把 RTSS 的值当成 PresentMon 的：2026-09-17 实测踩到，现象是"来源名永远为空"）。
                s_status = (s_status & ~(F_PM | F_LOW_PM)) | (fpsFromPm ? F_PM : 0) | (lowFromPm ? F_LOW_PM : 0);
                // 低 8 位 = 状态位；bit8 起 = 采样序号；高 8 位 = 本次选中的进程样本数（上限 255）
                // ⚠️ 顺序：先按**本帧**的 fpsFromPm 采样数、再更新 s_pmFromPm —— 反过来的话样本数会慢一帧
                //   （首帧明明有帧率却报 0；2026-09-17 pmcheck 首跑实测到的就是这个错帧）。
                int pmSamples = fpsFromPm && pmN > 0 ? (pmN > 255 ? 255 : pmN) : 0;
                outv[I_FLAGS] = s_status | ((s_seq++ & 0xFFFF) << 8) | (pmSamples << 24);
                DbgThrottled("结果: fps来源=" + (fpsFromPm ? "PM" : "RTSS/无") + " fps=" + (fps.HasValue ? fps.Value.ToString("F1") : "--")
                             + " low来源=" + (lowFromPm ? "PM" : "本地环") + " 状态位=0x" + s_status.ToString("X2") + " FLAGS=0x" + outv[I_FLAGS].ToString("X8"));
                s_pmN = pmN;
                s_pmFromPm = fpsFromPm;
            }
            catch (Exception)
            {
                // 任何一次读失败都不许把宿主拖崩：返回 0 值 + 状态位
                for (int i = 0; i < I_VALID_MASK; i++) outv[i] = 0;
                outv[I_VALID_MASK] = 0;
                outv[I_FLAGS] = -2;
            }
            return s_status;
        }

        /// <summary>初始化状态位（0=还没初始化）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_ready")]
        public static int HwReady() => s_inited;

        /// <summary>状态位原样（F_INIT_OK/F_CPU/F_GPU/F_RTSS）。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_status")]
        public static int HwStatus() => s_status;

        // ───────────────────────── 内部：传感器读取 ─────────────────────────

        private static void Update(IHardware? hw)
        {
            if (hw == null) return;
            hw.Update();
            foreach (IHardware sub in hw.SubHardware) sub.Update();
        }

        private static double? Sens(IHardware? hw, SensorType t, params string[] nameHints)
        {
            if (hw == null) return null;
            double? exact = null, loose = null;
            foreach (ISensor s in hw.Sensors)
            {
                if (s.SensorType != t || s.Value == null) continue;
                string n = s.Name.ToLowerInvariant();
                bool hit = false;
                foreach (string h in nameHints) if (n.Contains(h)) { hit = true; break; }
                if (!hit) continue;
                // 偏好"正好等于提示词"的那种（例如 CPU Package 而不是 Package #1）
                foreach (string h in nameHints) if (n == h || n.EndsWith(" " + h)) { exact ??= s.Value; break; }
                loose ??= s.Value;
            }
            return exact ?? loose;
        }

        private static double? MaxSens(IHardware? hw, SensorType t)
        {
            if (hw == null) return null;
            double? best = null;
            foreach (ISensor s in hw.Sensors)
            {
                if (s.SensorType != t || s.Value == null) continue;
                if (best == null || s.Value > best) best = s.Value;
            }
            return best;
        }

        // 只按名字提示过滤后再取最大值。
        // 2026-09-16 实测对齐（FLINT明细 §4.9 ①）：C# 参考版读 CPU 温度是
        // 「Package / TjMax / Core 里取最大」（`E:\HardwareMonitor\HardwareReader.cs:82`），
        // 我们原来只取 Package（`Sens(..., "package")`）⇒ 同刻原始值 48 vs 参考 57（差约 9°C），
        // 套上 −11 校准后就成了"偏低 9 度"。改成与参考同口径。
        private static double? MaxSensByName(IHardware? hw, SensorType t, params string[] nameHints)
        {
            if (hw == null) return null;
            double? best = null;
            foreach (ISensor s in hw.Sensors)
            {
                if (s.SensorType != t || s.Value == null) continue;
                string n = s.Name.ToLowerInvariant();
                bool hit = false;
                foreach (string h in nameHints) if (n.Contains(h)) { hit = true; break; }
                if (!hit) continue;
                if (best == null || s.Value > best) best = s.Value;
            }
            return best;
        }

        private static void Put(int* outv, ref int mask, int idx, double? v)
        {
            if (!v.HasValue) return;
            double d = v.Value;
            if (double.IsNaN(d) || double.IsInfinity(d)) return;
            if (d > 200000.0) d = 200000.0;
            if (d < -200000.0) d = -200000.0;
            outv[idx] = (int)Math.Round(d * 1000.0);
            mask |= 1 << idx;
        }

        private static bool At(this int mask, int idx) => (mask & (1 << idx)) != 0;

        // ───────────────────────── 内部：FPS（RTSS 共享内存）─────────────────────────
        // 代码口径抄自本项目 C# 版的 RtssReader.cs（RTSS SDK v2.x 的 APP_ENTRY 布局）。
        private const string RtssMapDefault = "RTSSSharedMemoryV2";
        private const uint RtssSignature = 0x52545353;
        // APP_ENTRY 内关键字段偏移（RTSS SDK v2.x，与 C# 版 RtssReader.cs 逐字一致）
        private const int OffFlags = 264, OffTime0 = 268, OffTime1 = 272, OffFrames = 276, OffFrameTime = 280;
        private const uint ApiUsageMask = 0x0000FFFF;
        private static uint s_rtssLastTime1;

        /// <summary>
        /// RTSS 共享内存名。默认就是 RTSS 的正式名字；允许用环境变量 `HWBRIDGE_RTSS_MAP` 覆盖，
        /// 这样"通道是否真的能读"可以**在被控样本上验证**（造一张同样布局的假共享内存来跑），
        /// 而不是靠"偏移看着对"下结论（2026-09-16 加）。
        /// </summary>
        /// <summary>RTSS 共享内存名的来源：0=默认名字，1=环境变量，2=与 DLL 同目录的 HwBridge.rtssmap.txt。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_rtss_mode")]
        public static int HwRtssMode() { RtssMapName(); return s_rtssNameSrc; }

        /// <summary>最近一次 FPS 读取结果：bit0=读到值，bit1=共享内存能打开，bit2=签名匹配，bit3=有条目命中 API 位。</summary>
        [UnmanagedCallersOnly(EntryPoint = "hw_rtss_flags")]
        public static int HwRtssFlags() => s_rtssFlags;

        private static int s_rtssNameSrc = -1;   // -1 = 还没解析过
        private static int s_rtssFlags = 0;
        private static string? s_rtssName;

        private static string RtssMapName()
        {
            if (s_rtssNameSrc >= 0 && s_rtssName != null) return s_rtssName;
            // ① 环境变量（测试宿主方便覆盖）
            try
            {
                string? n = Environment.GetEnvironmentVariable("HWBRIDGE_RTSS_MAP");
                if (!string.IsNullOrWhiteSpace(n)) { s_rtssNameSrc = 1; s_rtssName = n; return n; }
            }
            catch { /* 取不到就往下走 */ }
            // ② 与**本 DLL** 同目录的 `HwBridge.rtssmap.txt`（提权场景环境变量不继承；而 FLINT 手链 PE 当宿主时
            //    `AppContext.BaseDirectory` 不保证是产物目录，所以用 GetModuleFileName 定位自己，见 OwnDirectory()）
            try
            {
                string? dir = OwnDirectory();
                if (dir != null)
                {
                    string f = System.IO.Path.Combine(dir, "HwBridge.rtssmap.txt");
                    if (System.IO.File.Exists(f))
                    {
                        string n = System.IO.File.ReadAllText(f).Trim();
                        if (n.Length > 0) { s_rtssNameSrc = 2; s_rtssName = n; return n; }
                    }
                }
            }
            catch { /* 读不到就用默认 */ }
            // ③ 默认 = RTSS 正式名字
            s_rtssNameSrc = 0; s_rtssName = RtssMapDefault;
            return s_rtssName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool GetModuleHandleExW(uint flags, IntPtr address, out IntPtr module);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetModuleFileNameW(IntPtr module, System.Text.StringBuilder buf, uint size);

        /// <summary>本 DLL 所在目录（用自身代码地址反查模块句柄 —— 不依赖宿主怎么设 CWD/BaseDirectory）。</summary>
        private static unsafe string? OwnDirectory()
        {
            if (!GetModuleHandleExW(0x00000004 /*FROM_ADDRESS*/, (IntPtr)(delegate* unmanaged<int>)&HwStatus, out IntPtr h))
                return null;
            var sb = new System.Text.StringBuilder(512);
            uint n = GetModuleFileNameW(h, sb, (uint)sb.Capacity);
            if (n == 0) return null;
            return System.IO.Path.GetDirectoryName(sb.ToString());
        }

        private static float? RtssFps(out bool fresh)
        {
            fresh = false;
            try
            {
                using var mmf = MemoryMappedFile.OpenExisting(RtssMapName(), MemoryMappedFileRights.Read);
                using var view = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
                s_rtssFlags |= 2;                                                   // bit1 = 共享内存能打开
                if (view.ReadUInt32(0) != RtssSignature) return null;
                s_rtssFlags |= 4;                                                   // bit2 = 签名匹配
                uint entrySize = view.ReadUInt32(8), arrOffset = view.ReadUInt32(12), arrSize = view.ReadUInt32(16);
                if (entrySize < 400 || arrOffset == 0) return null;

                uint lastFg = view.ReadUInt32(64);
                uint t1 = 0;
                float? fps = lastFg < arrSize ? ReadEntry(view, arrOffset + lastFg * entrySize, out t1) : null;
                if (fps == null)
                {
                    float best = 0; uint bestT1 = 0; bool any = false;
                    for (uint i = 0; i < arrSize && i < 256; i++)
                    {
                        float? f = ReadEntry(view, arrOffset + i * entrySize, out uint cand);
                        if (f.HasValue && (!any || f.Value > best)) { best = f.Value; bestT1 = cand; any = true; }
                    }
                    if (any) { fps = best; t1 = bestT1; }
                }
                if (fps.HasValue)
                {
                    s_status |= F_RTSS;
                    s_rtssFlags |= 1 | 8;                                           // bit0=读到值 / bit3=有条目命中 API 位
                    if (t1 != s_rtssLastTime1) { s_rtssLastTime1 = t1; fresh = true; }   // 时间戳变了 = 这一帧是新的
                }
                return fps;
            }
            catch { return null; }
        }

        private static float? ReadEntry(MemoryMappedViewAccessor view, long off, out uint time1)
        {
            time1 = 0;
            uint flags = view.ReadUInt32(off + OffFlags);
            if ((flags & ApiUsageMask) == 0) return null;
            uint frameTime = view.ReadUInt32(off + OffFrameTime);
            time1 = view.ReadUInt32(off + OffTime1);
            if (frameTime >= 1000 && frameTime <= 1000000)
            {
                float fps = 1000000f / frameTime;
                if (fps > 1) return fps;
            }
            uint t0 = view.ReadUInt32(off + OffTime0), frames = view.ReadUInt32(off + OffFrames);
            if (time1 > t0 && frames > 0)
            {
                float fps = 1000f * frames / (time1 - t0);
                if (fps > 1) return fps;
            }
            return null;
        }

        private static void PushFrameTime(float ms)
        {
            if (ms <= 0 || ms > 1000) return;
            s_ftRing[s_ftPos] = ms;
            s_ftPos = (s_ftPos + 1) % s_ftRing.Length;
            if (s_ftCount < s_ftRing.Length) s_ftCount++;
        }

        /// <summary>1% low：把已有帧时间从大到小排序，取第 1% 那个（不足 20 个样本不给值）。</summary>
        private static float? OnePercentLow()
        {
            if (s_ftCount < 20) return null;
            var arr = new float[s_ftCount];
            Array.Copy(s_ftRing, arr, s_ftCount);
            Array.Sort(arr);                       // 升序：arr[0] 是最快的
            int idx = Math.Min(s_ftCount - 1, (int)(s_ftCount * 0.99));   // 第 99 百分位 = 最慢的那一档
            float ms = arr[idx];
            return ms > 0 ? 1000f / ms : null;
        }
    }
}
