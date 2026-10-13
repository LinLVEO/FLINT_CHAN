/* pmcheck.c -- v1.4.7 PresentMon 通道的验收宿主（**按 FLINT 的 ABI 调**，不是按 C 的 ABI 调）。
 *
 * 为什么单独写一个：缝合桥那套"导入表直调"有个致命细节——**FLINT 的 int 是 8 字节槽**
 *   （`int b[24]` 的第 j 个元素落在字节偏移 8*j），C 的 int 是 4 字节。用 C 的 int[24] 调 hw_snap64
 *   只会把前 12 个槽写对一半、后面整体错位，现象是"个别值看着对"。所以本宿主的缓冲一律用
 *   **long long[24]**，与 FLINT 侧的 hw_snap64 完全同构 —— 它同时也是 FLINT 侧 ABI 的**可执行参照**。
 *
 * 验的四件事（对应任务卡 T-20260916-225704 的验收项）：
 *   ① hw_pm_want(1) → PresentMon 子进程起得来、开始出数据（hw_pm_lines 增长、hw_pm_status 有 bit2）
 *   ② hw_snap64 → FPS 槽（13/14）有值、有效位掩码 bit13/bit14 置位、FLAGS bit4 = 来自 PresentMon
 *   ③ hw_pm_src(缓冲,容量) → 真把进程名写进**调用方的缓冲**（这是"字符串跨 ABI"的关键点）
 *   ④ hw_pm_stop() → 子进程收掉（不留常驻）
 * 用法: pmcheck.exe <HwBridge.dll 全路径> <日志文件全路径> [观察秒数，默认 8]
 * 退出码: 0=四项全过 / 42=起来了但没帧率(样本不足) / 3=AV / 4=加载失败 / 5=缺导出
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef int (*fn0)(void);
typedef int (*fn1i)(int);
typedef int (*fn1p)(void *);
typedef int (*fn2)(void *, int);

static FILE *g_log = NULL;
static unsigned char *g_base = NULL;

static LONG CALLBACK veh(EXCEPTION_POINTERS *ep) {
    EXCEPTION_RECORD *er = ep->ExceptionRecord;
    if (er->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_CONTINUE_SEARCH;
    CONTEXT *c = ep->ContextRecord;
    fprintf(g_log, "AV rip=+%llx rcx=%llx\n",
            (unsigned long long)(c->Rip - (unsigned long long)(uintptr_t)g_base),
            (unsigned long long)c->Rcx);
    fflush(g_log); fclose(g_log); ExitProcess(3);
    return EXCEPTION_CONTINUE_SEARCH;
}

static int count_pm_procs(void) {
    /* 只看进程数，不做处置：PresentMon 的进程名 = 镜像名去掉 .exe */
    FILE *p = _popen("tasklist /FI \"IMAGENAME eq PresentMon.exe\" /NH", "r");
    char line[512];
    int n = 0;
    if (!p) return -1;
    while (fgets(line, sizeof line, p)) if (strstr(line, "PresentMon.exe")) n++;
    _pclose(p);
    return n;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: pmcheck.exe <DLL> <日志> [秒数]\n"); return 2; }
    int secs = argc > 3 ? atoi(argv[3]) : 8;
    g_log = fopen(argv[2], "ab");
    if (!g_log) return 2;
    setvbuf(g_log, NULL, _IONBF, 0);
    AddVectoredExceptionHandler(1, veh);

    fprintf(g_log, "\n===== pmcheck @ %s =====\n", __TIMESTAMP__);
    HMODULE m = LoadLibraryA(argv[1]);
    if (!m) { fprintf(g_log, "LOADFAIL err=%lu\n", GetLastError()); fflush(g_log); fclose(g_log); return 4; }
    g_base = (unsigned char *)m;
    fprintf(g_log, "loaded: %s\n", argv[1]);

    fn0 init = (fn0)GetProcAddress(m, "hw_init");
    fn1p snap64 = (fn1p)GetProcAddress(m, "hw_snap64");
    fn1i want = (fn1i)GetProcAddress(m, "hw_pm_want");
    fn1p stops = (fn1p)GetProcAddress(m, "hw_pm_stop");   /* hw_pm_stop(int) → 传 0 */
    fn2 src = (fn2)GetProcAddress(m, "hw_pm_src");
    fn0 status = (fn0)GetProcAddress(m, "hw_pm_status");
    fn0 lines = (fn0)GetProcAddress(m, "hw_pm_lines");
    if (!init || !snap64 || !want || !src || !status || !lines || !stops) {
        fprintf(g_log, "缺导出（需要 hw_init/hw_snap64/hw_pm_want/hw_pm_src/hw_pm_status/hw_pm_lines/hw_pm_stop）\n");
        fflush(g_log); fclose(g_log); return 5;
    }
    fprintf(g_log, "all required exports present\n");

    int before = count_pm_procs();
    fprintf(g_log, "PresentMon 进程数（开工前）= %d\n", before);

    int st = init();
    fprintf(g_log, "hw_init() = %d\n", st);

    int intent = want(1);
    fprintf(g_log, "hw_pm_want(1) = %d   (1 = 桥侧已接受「要跑」)\n", intent);

    /* —— 轮询观察：每 500ms 取一次快照，看 FPS 什么时候出现 —— */
    long long b[24];
    int lastFps = 0, lastLow = 0, lastMask = 0, lastFlags = 0, lastLines = 0, lastSt = 0;
    int gotFps = 0;
    for (int t = 0; t < secs * 2; t++) {
        memset(b, 0, sizeof b);
        snap64(b);
        lastMask = (int)b[22];
        lastFlags = (int)b[23];
        lastFps = (int)b[13];
        lastLow = (int)b[14];
        lastLines = lines();
        lastSt = status();
        if ((lastMask & (1 << 13)) && lastFps > 0) { gotFps = 1; break; }
        Sleep(500);
    }
    fprintf(g_log, "hw_pm_status() = %d  (bit0 exe在/bit1 起来了/bit2 有数据/bit3 有帧率/bit4 已退出/bit5 无 exe/bit6 启动中)\n", lastSt);
    fprintf(g_log, "hw_pm_lines()  = %d\n", lastLines);
    fprintf(g_log, "hw_snap64: VALID_MASK = 0x%06X   FLAGS = 0x%08X\n", lastMask, lastFlags);
    fprintf(g_log, "  FPS    槽13 = %d (valid=%d)   ← 1000 定点，即 %.1f fps\n", lastFps, (lastMask >> 13) & 1, lastFps / 1000.0);
    fprintf(g_log, "  1%%low 槽14 = %d (valid=%d)   ← 即 %.1f fps\n", lastLow, (lastMask >> 14) & 1, lastLow / 1000.0);
    fprintf(g_log, "  FLAGS bit4（本条 FPS 来自 PresentMon）= %d\n", (lastFlags >> 4) & 1);
    fprintf(g_log, "  FLAGS 高 8 位（样本数）= %d\n", (lastFlags >> 24) & 0xFF);

    /* —— 字符串 ABI：把来源名拷进**我们自己的**缓冲 —— */
    char name[64];
    memset(name, 0x7E, sizeof name);           /* 先填 '~'：C# 若没写就看得见 */
    int n = src(name, 63);
    fprintf(g_log, "hw_pm_src(buf,63) = %d  bytes = \"%s\"\n", n, name);
    int nameOk = (n > 0 && n < 63 && name[0] != 0x7E && name[n] == 0);

    int afterRun = count_pm_procs();
    fprintf(g_log, "PresentMon 进程数（跑起来后）= %d\n", afterRun);

    stops(0);
    Sleep(800);
    int afterStop = count_pm_procs();
    fprintf(g_log, "PresentMon 进程数（hw_pm_stop 之后）= %d\n", afterStop);

    fprintf(g_log, "结论: gotFps=%d nameOk=%d started=%d stopped=%d\n",
            gotFps, nameOk, afterRun > before, afterStop <= before);
    fflush(g_log); fclose(g_log);

    if (!gotFps) return 42;
    return (nameOk && afterRun > before && afterStop <= before) ? 0 : 1;
}
