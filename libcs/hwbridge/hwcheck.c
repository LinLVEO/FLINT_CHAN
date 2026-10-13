/* hwcheck.c -- 缝合 DLL 的验收宿主：
 *   ① 读 TLS 目录/索引 + TLS 块内 +0x1020 的 Thread 对象（真初始化判据：调用后 flags 应有 TSF_Attached=1）
 *   ② 调 hw_init / hw_snap，把 24 个定点槽 + 有效位掩码打出来（人可读）
 * 用法: hwcheck.exe <DLL 全路径> <日志全路径>
 * 退出码: 42=成功(有 CPU 温度有效) / 41=调用成功但无 CPU 温度(未提权常见) / 3=AV / 4=加载失败 / 5=缺导出
 */
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

typedef int (*fn0)(void);
typedef int (*fn1)(int *);

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

static void dump_thread(const char *when, unsigned int index) {
    void **arr = (void **)__readgsqword(0x58);
    unsigned char *blk = (unsigned char *)arr[index];
    if (!blk) { fprintf(g_log, "  [%s] TLS块为空\n", when); return; }
    unsigned char *th = blk + 0x1020;                 /* TLS 块内 Thread 对象（ILC 常数 0x1020） */
    unsigned int flags = *(volatile unsigned int *)(th + 0x38);
    unsigned long long frame = *(volatile unsigned long long *)(th + 0x40);
    fprintf(g_log, "  [%s] Thread@+0x1020 flags=0x%x (Attached=%d) frame=%llx\n",
            when, flags, flags & 1, frame);
    fflush(g_log);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: hwcheck.exe <DLL> <日志>\n"); return 2; }
    g_log = fopen(argv[2], "ab");
    if (!g_log) return 2;
    setvbuf(g_log, NULL, _IONBF, 0);
    AddVectoredExceptionHandler(1, veh);

    HMODULE m = LoadLibraryA(argv[1]);
    if (!m) { fprintf(g_log, "LOADFAIL err=%lu\n", GetLastError()); fflush(g_log); fclose(g_log); return 4; }
    g_base = (unsigned char *)m;

    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)g_base;
    IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(g_base + dos->e_lfanew);
    ULONGLONG pref = nt->OptionalHeader.ImageBase;
    IMAGE_DATA_DIRECTORY td = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_TLS];
    unsigned int index = 0;
    if (td.VirtualAddress) {
        IMAGE_TLS_DIRECTORY64 *t = (IMAGE_TLS_DIRECTORY64 *)(g_base + td.VirtualAddress);
        index = *(volatile unsigned int *)(g_base + (t->AddressOfIndex - pref));
        fprintf(g_log, "TLS dir=0x%lx raw=[%llx,%llx) zeroFill=0x%lx INDEX=%u\n",
                (unsigned long)td.VirtualAddress,
                (unsigned long long)(t->StartAddressOfRawData - pref),
                (unsigned long long)(t->EndAddressOfRawData - pref),
                (unsigned long)t->SizeOfZeroFill, index);
    } else fprintf(g_log, "无 TLS 目录！\n");
    dump_thread("调用前", index);

    fn0 init = (fn0)GetProcAddress(m, "hw_init");
    fn1 snap = (fn1)GetProcAddress(m, "hw_snap");
    if (!init || !snap) { fprintf(g_log, "缺导出 hw_init/hw_snap\n"); fflush(g_log); fclose(g_log); return 5; }

    int st = init();
    fprintf(g_log, "hw_init() = %d  (bit0=init ok bit1=cpu bit2=gpu bit3=rtss)\n", st);

    /* 调两次：FPS 的 1% low 需要多次采样 */
    static const char *nm[24] = {
        "cpu_temp", "cpu_load", "cpu_clock", "cpu_power", "gpu_temp", "gpu_load",
        "gpu_mem_used", "gpu_mem_total", "gpu_power", "ram_used", "ram_total", "ram_load",
        "fan_rpm", "fps", "fps_low", "disk_load", "disk_used", "disk_total",
        "net_down", "net_up", "sys_power", "base_power", "VALID_MASK", "FLAGS"};
    int buf[24];
    int rc = 0;
    for (int pass = 0; pass < 3; pass++) { for (int i = 0; i < 24; i++) buf[i] = -7; rc = snap(buf); Sleep(300); }
    fprintf(g_log, "hw_snap() = %d\n", rc);
    for (int i = 0; i < 24; i++) {
        int v = buf[i];
        int valid = (i < 22) ? ((buf[22] >> i) & 1) : 1;
        if (i == 22) fprintf(g_log, "  %-14s = 0x%06X\n", nm[i], v);
        else if (i == 23) fprintf(g_log, "  %-14s = 0x%06X\n", nm[i], v);
        else fprintf(g_log, "  %-14s = %-12d %s\n", nm[i], v, valid ? "" : "(无效)");
    }
    dump_thread("调用后", index);
    fflush(g_log); fclose(g_log);

    int cpuTempValid = (buf[22] & 1);
    return cpuTempValid ? 42 : 41;
}
