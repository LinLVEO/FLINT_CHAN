// fltdiag.c -- 外部运行诊断工具（进程外当"调试器"盯着目标程序）
//
// 用法：
//   fltdiag run <程序.exe> [参数...]
//
// 干什么：用 DEBUG_ONLY_THIS_PROCESS 启动目标并接住调试事件：
//   · 二次机会异常（真正没人处理的崩溃）⇒ 立刻抓现场（异常码/地址/寄存器/栈/模块），
//     在进程还活着时写 .txt / .json / .dmp；
//   · 正常退出但退出码非 0 ⇒ 也写报告（按 NTSTATUS 解码，认出 0xC0000005 这类）；
//   · 正常退出且退出码 0 ⇒ 什么都不写。
//
// 产物：<目标目录>\fltdiag\run-<时间戳>.txt / .json / .dmp
// 退出码：目标正常退出 0 ⇒ 0；否则 1（目标的真实退出码写在报告与 stdout 里）。

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <dbghelp.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#define MAX_MODS 128
#define MAX_STACK 192

static char g_buf[65536];
static int  g_len;

static void appf(const char *fmt, ...)
{
    va_list ap; int room, n;
    if (g_len >= (int)sizeof(g_buf) - 1) return;
    room = (int)sizeof(g_buf) - 1 - g_len;
    va_start(ap, fmt);
    n = vsnprintf(g_buf + g_len, room, fmt, ap);
    va_end(ap);
    if (n < 0) { g_len = (int)sizeof(g_buf) - 1; g_buf[g_len] = 0; return; }
    g_len += (n < room) ? n : room;
}

static void appj(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;
    appf("\"");
    if (s) {
        while (*p) {
            if (*p == '"' || *p == '\\') appf("\\%c", *p);
            else if (*p < 0x20) appf("\\u%04X", *p);
            else appf("%c", *p);
            p++;
        }
    }
    appf("\"");
}

static const char *status_name(unsigned int code)
{
    switch (code) {
    case 0xC0000005u: return "ACCESS_VIOLATION（访问了不能读/写的地址）";
    case 0xC000001Du: return "ILLEGAL_INSTRUCTION（非法指令）";
    case 0xC0000094u: return "INTEGER_DIVIDE_BY_ZERO（整数除零）";
    case 0xC00000FDu: return "STACK_OVERFLOW（栈溢出，常见于无限递归）";
    case 0xC0000135u: return "DLL_NOT_FOUND（依赖的 DLL 找不到）";
    case 0xC0000139u: return "ENTRYPOINT_NOT_FOUND（DLL 里找不到入口）";
    case 0x80000003u: return "BREAKPOINT（断点）";
    case 0xC0000409u: return "STACK_BUFFER_OVERRUN（栈保护被触发）";
    default: return "";
    }
}

typedef struct { unsigned long long base; unsigned long size; char name[96]; } MODINFO;
static MODINFO g_mods[MAX_MODS];
static int g_nmods;

static HANDLE g_hp;
static DWORD  g_pid;
static char   g_exe[MAX_PATH];
static char   g_cmdline[4096];

static void add_module(unsigned long long base, unsigned long size, const char *name)
{
    int i;
    for (i = 0; i < g_nmods; i++)
        if (g_mods[i].base == base) { g_mods[i].size = size; return; }
    if (g_nmods >= MAX_MODS) return;
    g_mods[g_nmods].base = base;
    g_mods[g_nmods].size = size;
    strncpy(g_mods[g_nmods].name, name, sizeof(g_mods[g_nmods].name) - 1);
    g_mods[g_nmods].name[sizeof(g_mods[g_nmods].name) - 1] = 0;
    g_nmods++;
}

static void note_module_image(HMODULE hmod)
{
    MODULEINFO mi;
    char path[1024];
    if (!hmod || !g_hp) return;
    if (!GetModuleInformation(g_hp, hmod, &mi, sizeof(mi))) return;
    path[0] = 0;
    GetModuleFileNameExA(g_hp, hmod, path, sizeof(path));
    add_module((unsigned long long)(ULONG_PTR)mi.lpBaseOfDll, mi.SizeOfImage, path);
}

static int mod_index(unsigned long long addr)
{
    int i;
    for (i = 0; i < g_nmods; i++)
        if (addr >= g_mods[i].base && addr < g_mods[i].base + g_mods[i].size) return i;
    return -1;
}

static void make_stamp(char *out, int cap)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    snprintf(out, cap, "%04d%02d%02d-%02d%02d%02d", st.wYear, st.wMonth, st.wDay,
             st.wHour, st.wMinute, st.wSecond);
}

static void write_file(const char *path, const char *data, int len)
{
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wr = 0;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, data, (DWORD)len, &wr, NULL);
    CloseHandle(h);
}

typedef BOOL (WINAPI *PFN_MiniDumpWriteDump)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
    PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION, PMINIDUMP_CALLBACK_INFORMATION);

static void write_dump(DWORD tid, EXCEPTION_POINTERS *ep, const char *path)
{
    HMODULE h = LoadLibraryA("dbghelp.dll");
    PFN_MiniDumpWriteDump fn;
    HANDLE f;
    MINIDUMP_EXCEPTION_INFORMATION info;
    if (!h || !g_hp) { if (h) FreeLibrary(h); return; }
    fn = (PFN_MiniDumpWriteDump)(void *)GetProcAddress(h, "MiniDumpWriteDump");
    if (!fn) { FreeLibrary(h); return; }
    f = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        info.ThreadId = tid;
        info.ExceptionPointers = ep;
        info.ClientPointers = FALSE;
        fn(g_hp, g_pid, f, MiniDumpNormal, ep ? &info : NULL, NULL, NULL);
        CloseHandle(f);
    }
    FreeLibrary(h);
}

static int capture(DWORD tid, CONTEXT *ctx)
{
    HANDLE ht = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid);
    if (!ht) return 0;
    SuspendThread(ht);
    ctx->ContextFlags = CONTEXT_FULL;
    if (!GetThreadContext(ht, ctx)) { ResumeThread(ht); CloseHandle(ht); return 0; }
    ResumeThread(ht);
    CloseHandle(ht);
    return 1;
}

static void render_txt(int crashed, unsigned int ex, unsigned long long addr,
                       CONTEXT *ctx, DWORD exit_code, const char *time_s, const char *report_dir)
{
    int i;
    g_len = 0; g_buf[0] = 0;
    appf("===== FLINT 运行现场报告（外部诊断）=====\r\n");
    appf("时间: %s\r\n", time_s);
    appf("程序: %s\r\n", g_exe);
    appf("命令行: %s\r\n", g_cmdline);
    if (crashed) {
        appf("结果: 崩溃\r\n");
        appf("异常: 0x%08X  %s\r\n", ex, status_name(ex));
        appf("异常地址: 0x%016llX", addr);
        {
            int m = mod_index(addr);
            if (m >= 0) appf("  (在 %s + 0x%llX)\r\n", g_mods[m].name, addr - g_mods[m].base);
            else appf("\r\n");
        }
        if (ctx) {
            appf("\r\n寄存器:\r\n");
            appf("  RIP=%016llX RSP=%016llX RBP=%016llX\r\n",
                 (unsigned long long)ctx->Rip, (unsigned long long)ctx->Rsp, (unsigned long long)ctx->Rbp);
            appf("  RAX=%016llX RBX=%016llX RCX=%016llX RDX=%016llX\r\n",
                 (unsigned long long)ctx->Rax, (unsigned long long)ctx->Rbx,
                 (unsigned long long)ctx->Rcx, (unsigned long long)ctx->Rdx);
            appf("  RSI=%016llX RDI=%016llX R8 =%016llX R9 =%016llX\r\n",
                 (unsigned long long)ctx->Rsi, (unsigned long long)ctx->Rdi,
                 (unsigned long long)ctx->R8, (unsigned long long)ctx->R9);
            appf("\r\n栈扫描（落在模块内的值，前 %d 个 8 字节）:\r\n", MAX_STACK);
            for (i = 0; i < MAX_STACK; i++) {
                unsigned long long v = 0, a = (unsigned long long)ctx->Rsp + (unsigned long long)i * 8;
                SIZE_T got = 0;
                int m;
                if (!g_hp || !ReadProcessMemory(g_hp, (LPCVOID)(ULONG_PTR)a, &v, 8, &got) || got != 8) break;
                m = mod_index(v);
                if (m < 0) continue;
                appf("  %016llX -> %s + 0x%llX\r\n", v, g_mods[m].name, v - g_mods[m].base);
            }
        }
    } else {
        appf("结果: 正常退出，但退出码非 0\r\n");
        appf("退出码: %lu (0x%08X) %s\r\n", exit_code, exit_code, status_name(exit_code));
    }
    appf("\r\n已加载模块 (%d):\r\n", g_nmods);
    for (i = 0; i < g_nmods; i++)
        appf("  %016llX + %08lX  %s\r\n", g_mods[i].base, g_mods[i].size, g_mods[i].name);
    appf("\r\n提示：把这份 txt（和同名 .dmp）一起提交即可；地址都是 模块基址+偏移，换机器也能对。\r\n");
    appf("报告目录: %s\r\n", report_dir);
}

static void render_json(int crashed, unsigned int ex, unsigned long long addr, DWORD exit_code, const char *time_s)
{
    int i;
    g_len = 0; g_buf[0] = 0;
    appf("{\n  \"kind\": \"flint-run\",\n");
    appf("  \"time\": "); appj(time_s); appf(",\n");
    appf("  \"exe\": "); appj(g_exe); appf(",\n");
    appf("  \"cmdline\": "); appj(g_cmdline); appf(",\n");
    appf("  \"crashed\": %s,\n", crashed ? "true" : "false");
    appf("  \"exit_code\": %lu,\n", exit_code);
    if (crashed) {
        appf("  \"exception\": {\"code\": %u, \"code_hex\": \"0x%08X\", \"name\": ", ex, ex);
        appj(status_name(ex));
        appf(", \"address\": %llu, \"address_hex\": \"0x%016llX\"},\n", addr, addr);
    }
    appf("  \"modules\": [\n");
    for (i = 0; i < g_nmods; i++) {
        appf("    {\"base\": %llu, \"size\": %lu, \"name\": ", g_mods[i].base, g_mods[i].size);
        appj(g_mods[i].name);
        appf("}%s\n", (i + 1 < g_nmods) ? "," : "");
    }
    appf("  ]\n}\n");
}

static void usage(void)
{
    printf("fltdiag -- FLINT 外部运行诊断工具\n\n");
    printf("用法:\n  fltdiag run <程序.exe> [参数...]\n\n");
    printf("失败（崩溃或退出码非 0）时，在 <程序目录>\\fltdiag\\ 写 run-<时间戳>.txt/.json/.dmp。\n");
    printf("退出码: 目标正常退出 0 => 0；其余 => 1。\n");
}

int main(int argc, char **argv)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DEBUG_EVENT de;
    char cmdline[4096];
    char stamp[32];
    char time_s[32];
    char dir[MAX_PATH];
    char path_txt[MAX_PATH * 2], path_json[MAX_PATH * 2], path_dmp[MAX_PATH * 2];
    DWORD exit_code = 0;
    int crashed = 0, got_exit = 0, i, reported = 0;

    if (argc < 3 || strcmp(argv[1], "run") != 0) { usage(); return 2; }

    strncpy(g_exe, argv[2], sizeof(g_exe) - 1);
    if (!GetFullPathNameA(g_exe, MAX_PATH, g_exe, NULL)) { printf("无法解析程序路径: %s\n", argv[2]); return 2; }
    snprintf(cmdline, sizeof(cmdline), "\"%s\"", g_exe);
    for (i = 3; i < argc; i++) {
        int n = (int)strlen(cmdline);
        snprintf(cmdline + n, sizeof(cmdline) - n, " %s", argv[i]);
    }
    strncpy(g_cmdline, cmdline, sizeof(g_cmdline) - 1);

    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, DEBUG_ONLY_THIS_PROCESS,
                        NULL, NULL, &si, &pi)) {
        printf("启动失败（错误码 %lu）: %s\n", GetLastError(), g_exe);
        return 2;
    }
    g_hp = pi.hProcess;
    g_pid = pi.dwProcessId;
    printf("FLTDIAG run: %s\n", g_exe);

    for (;;) {
        DWORD cont = DBG_CONTINUE;
        if (!WaitForDebugEvent(&de, INFINITE)) break;
        switch (de.dwDebugEventCode) {
        case CREATE_PROCESS_DEBUG_EVENT:
            if (de.u.CreateProcessInfo.hFile) CloseHandle(de.u.CreateProcessInfo.hFile);
            note_module_image((HMODULE)de.u.CreateProcessInfo.lpBaseOfImage);
            break;
        case LOAD_DLL_DEBUG_EVENT:
            if (de.u.LoadDll.hFile) CloseHandle(de.u.LoadDll.hFile);
            note_module_image((HMODULE)de.u.LoadDll.lpBaseOfDll);
            break;
        case EXCEPTION_DEBUG_EVENT:
            if (de.u.Exception.dwFirstChance) {
                cont = DBG_EXCEPTION_NOT_HANDLED;
            } else {
                CONTEXT ctx;
                int have_ctx;
                crashed = 1;
                have_ctx = capture(de.dwThreadId, &ctx);

                make_stamp(stamp, sizeof(stamp));
                {
                    SYSTEMTIME st;
                    GetLocalTime(&st);
                    snprintf(time_s, sizeof(time_s), "%04d-%02d-%02d %02d:%02d:%02d",
                             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
                }
                strncpy(dir, g_exe, sizeof(dir) - 1);
                {
                    char *p = strrchr(dir, '\\');
                    if (p) *p = 0;
                }
                snprintf(dir + strlen(dir), sizeof(dir) - strlen(dir), "\\fltdiag");
                CreateDirectoryA(dir, NULL);
                snprintf(path_txt, sizeof(path_txt), "%s\\run-%s.txt", dir, stamp);
                snprintf(path_json, sizeof(path_json), "%s\\run-%s.json", dir, stamp);
                snprintf(path_dmp, sizeof(path_dmp), "%s\\run-%s.dmp", dir, stamp);

                render_txt(1, (unsigned)de.u.Exception.ExceptionRecord.ExceptionCode,
                           (unsigned long long)(ULONG_PTR)de.u.Exception.ExceptionRecord.ExceptionAddress,
                           have_ctx ? &ctx : NULL, 0, time_s, dir);
                write_file(path_txt, g_buf, g_len);
                render_json(1, (unsigned)de.u.Exception.ExceptionRecord.ExceptionCode,
                            (unsigned long long)(ULONG_PTR)de.u.Exception.ExceptionRecord.ExceptionAddress,
                            0, time_s);
                write_file(path_json, g_buf, g_len);
                {
                    EXCEPTION_POINTERS ep;
                    ep.ExceptionRecord = &de.u.Exception.ExceptionRecord;
                    ep.ContextRecord = have_ctx ? &ctx : NULL;
                    write_dump(de.dwThreadId, &ep, path_dmp);
                }
                printf("CRASH 0x%08X %s\n", (unsigned)de.u.Exception.ExceptionRecord.ExceptionCode,
                       status_name((unsigned)de.u.Exception.ExceptionRecord.ExceptionCode));
                printf("REPORT %s\n", path_txt);
                reported = 1;
                /* 关键：抓完就地终止。继续执行会让同一条指令再次触发异常，
                 * 结果是"每秒一份报告"的死循环（2026-10-20 实测踩过）。 */
                TerminateProcess(g_hp, (UINT)de.u.Exception.ExceptionRecord.ExceptionCode);
                cont = DBG_CONTINUE;
            }
            break;
        case EXIT_PROCESS_DEBUG_EVENT:
            exit_code = de.u.ExitProcess.dwExitCode;
            got_exit = 1;
            break;
        default:
            break;
        }
        ContinueDebugEvent(de.dwProcessId, de.dwThreadId, cont);
        if (got_exit) break;
    }

    g_hp = NULL;
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    if (got_exit && exit_code != 0 && !crashed && !reported) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        snprintf(time_s, sizeof(time_s), "%04d-%02d-%02d %02d:%02d:%02d",
                 st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        make_stamp(stamp, sizeof(stamp));
        strncpy(dir, g_exe, sizeof(dir) - 1);
        {
            char *p = strrchr(dir, '\\');
            if (p) *p = 0;
        }
        snprintf(dir + strlen(dir), sizeof(dir) - strlen(dir), "\\fltdiag");
        CreateDirectoryA(dir, NULL);
        snprintf(path_txt, sizeof(path_txt), "%s\\run-%s.txt", dir, stamp);
        snprintf(path_json, sizeof(path_json), "%s\\run-%s.json", dir, stamp);
        render_txt(0, 0, 0, NULL, exit_code, time_s, dir);
        write_file(path_txt, g_buf, g_len);
        render_json(0, 0, 0, exit_code, time_s);
        write_file(path_json, g_buf, g_len);
        printf("EXIT %lu (0x%08X) %s\n", exit_code, exit_code, status_name(exit_code));
        printf("REPORT %s\n", path_txt);
        return 1;
    }

    if (crashed) return 1;
    printf("EXIT 0（无报告）\n");
    return 0;
}
