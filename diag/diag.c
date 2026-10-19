// diag.c -- fltdiag.dll：进程内崩溃捕获 + 错误登记
//
// 设计取舍（写之前先定）：
//   · 崩溃处理器里**不用堆、不开文件两次**：只 CreateFile + WriteFile + 静态缓冲；
//     堆在崩溃时可能已经坏了，所以转换/拼接全部走静态缓冲。
//   · 报告目录默认 <exe 目录>\fltdiag\；三个文件同名不同后缀：.txt（人读）/ .json（机器读）/ .dmp（minidump）。
//   · minidump 用 dbghelp.dll 动态加载：拿不到就不写 dmp，不阻塞 txt/json。
//   · 传入的字符串按 ANSI（简中 = GBK）解释并转 UTF-8 —— FLINT 的字符串字面量正好是 GBK。

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#include <dbghelp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "diag.h"

#define MAX_MODS 96
#define MAX_STACK 192

typedef struct {
    unsigned long long base;
    unsigned long size;
    char name[96];          /* ANSI，报告里转 UTF-8 */
} MODINFO;

typedef struct {
    char time[32];
    char app[160];          /* UTF-8 */
    char exe[1024];         /* UTF-8 */
    unsigned int code;
    const char *code_name;
    unsigned long long addr;
    unsigned long long rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp, rip;
    unsigned long long r8, r9, r10, r11, r12, r13, r14, r15;
    char last_err[600];     /* UTF-8，形如 "1001 打不开文件"；空 = 没登记 */
    char ckpt[220];         /* UTF-8 */
    int nmods;
    MODINFO mods[MAX_MODS];
    int nstack;
    unsigned long long stack_vals[MAX_STACK];
    int stack_mod[MAX_STACK];
    unsigned long long stack_off[MAX_STACK];
} REPORT;

static volatile LONG g_inited = 0;
static volatile LONG g_in_handler = 0;
static PVOID g_veh = NULL;

static char g_app[160];     /* UTF-8 */
static char g_dir[MAX_PATH];
static int  g_err_code = 0;
static char g_err_msg[600]; /* UTF-8 */
static char g_ckpt[220];    /* UTF-8 */

static REPORT g_rep;
static char g_buf[65536];

/* ---------- 小工具 ---------- */

static void str_copy(char *dst, int cap, const char *src)
{
    int i = 0;
    if (!dst || cap <= 0) return;
    if (src) { while (src[i] && i < cap - 1) { dst[i] = src[i]; i++; } }
    dst[i] = 0;
}

/* 判断是不是合法 UTF-8（C 程序源文件常是 UTF-8；FLINT 源文件常是 GBK） */
static int is_utf8(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        int n, i;
        if (*p < 0x80) { p++; continue; }
        if ((*p & 0xE0) == 0xC0) n = 1;
        else if ((*p & 0xF0) == 0xE0) n = 2;
        else if ((*p & 0xF8) == 0xF0) n = 3;
        else return 0;
        for (i = 1; i <= n; i++) if ((p[i] & 0xC0) != 0x80) return 0;
        p += n + 1;
    }
    return 1;
}

/* 统一转 UTF-8：已是 UTF-8 的原样用；否则按 ANSI(GBK) 解。不碰堆：供崩溃处理器调用 */
static wchar_t g_wbuf[2048];
static void ansi_to_utf8(const char *src, char *dst, int cap)
{
    int n;
    if (!dst || cap <= 0) return;
    dst[0] = 0;
    if (!src || !*src) return;
    if (is_utf8(src)) { str_copy(dst, cap, src); return; }
    if (MultiByteToWideChar(CP_ACP, 0, src, -1, g_wbuf, 2048) <= 0) { str_copy(dst, cap, src); return; }
    n = WideCharToMultiByte(CP_UTF8, 0, g_wbuf, -1, dst, cap, NULL, NULL);
    if (n <= 0) str_copy(dst, cap, src);
}

static int buf_len;
static void buf_reset(void) { buf_len = 0; g_buf[0] = 0; }

static void appf(const char *fmt, ...)
{
    va_list ap;
    int room, n;
    if (buf_len >= (int)sizeof(g_buf) - 1) return;
    room = (int)sizeof(g_buf) - 1 - buf_len;
    va_start(ap, fmt);
    n = vsnprintf(g_buf + buf_len, room, fmt, ap);
    va_end(ap);
    if (n < 0) { buf_len = (int)sizeof(g_buf) - 1; g_buf[buf_len] = 0; return; }
    buf_len += (n < room) ? n : room;
}

/* JSON 字符串转义（输入已是 UTF-8） */
static void appj(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;
    if (!s) return;
    appf("\"");
    while (*p) {
        if (*p == '"' || *p == '\\') appf("\\%c", *p);
        else if (*p < 0x20) appf("\\u%04X", *p);
        else appf("%c", *p);
        p++;
    }
    appf("\"");
}

static void write_file(const char *path, const char *data, int len)
{
    HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD wr = 0;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, data, (DWORD)len, &wr, NULL);
    CloseHandle(h);
}

const char *flt_diag_status_name(unsigned int code)
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

/* ---------- 现场采集 ---------- */

static void collect_modules(void)
{
    HMODULE mods[MAX_MODS];
    DWORD needed = 0, i;
    HANDLE hp = GetCurrentProcess();
    g_rep.nmods = 0;
    if (!EnumProcessModules(hp, mods, sizeof(mods), &needed)) return;
    for (i = 0; i < needed / sizeof(HMODULE) && g_rep.nmods < MAX_MODS; i++) {
        MODULEINFO mi;
        if (!GetModuleInformation(hp, mods[i], &mi, sizeof(mi))) continue;
        g_rep.mods[g_rep.nmods].base = (unsigned long long)(ULONG_PTR)mi.lpBaseOfDll;
        g_rep.mods[g_rep.nmods].size = mi.SizeOfImage;
        GetModuleFileNameA(mods[i], g_rep.mods[g_rep.nmods].name, 96);
        g_rep.nmods++;
    }
}

static int module_index(unsigned long long addr)
{
    int i;
    for (i = 0; i < g_rep.nmods; i++) {
        if (addr >= g_rep.mods[i].base && addr < g_rep.mods[i].base + g_rep.mods[i].size)
            return i;
    }
    return -1;
}

static void collect_stack(unsigned long long rsp)
{
    int i;
    g_rep.nstack = 0;
    for (i = 0; i < MAX_STACK; i++) {
        unsigned long long v = 0, addr = rsp + (unsigned long long)i * 8;
        SIZE_T got = 0;
        int m;
        if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(ULONG_PTR)addr, &v, 8, &got) || got != 8)
            break;
        m = module_index(v);
        if (m < 0) continue;
        g_rep.stack_vals[g_rep.nstack] = v;
        g_rep.stack_mod[g_rep.nstack] = m;
        g_rep.stack_off[g_rep.nstack] = v - g_rep.mods[m].base;
        g_rep.nstack++;
    }
}

/* ---------- 报告输出 ---------- */

static void render_txt(void)
{
    int i;
    buf_reset();
    appf("===== FLINT 运行现场报告 =====\r\n");
    appf("时间: %s\r\n", g_rep.time);
    appf("程序: %s\r\n", g_rep.exe);
    appf("应用名: %s\r\n", g_rep.app);
    appf("异常: 0x%08X  %s\r\n", g_rep.code, g_rep.code_name);
    appf("异常地址: 0x%016llX", g_rep.addr);
    if (module_index(g_rep.addr) >= 0) {
        int m = module_index(g_rep.addr);
        appf("  (在 %s + 0x%llX)\r\n", g_rep.mods[m].name, g_rep.addr - g_rep.mods[m].base);
    } else {
        appf("\r\n");
    }
    appf("最后错误: %s\r\n", g_rep.last_err[0] ? g_rep.last_err : "(未登记)");
    appf("最后检查点: %s\r\n", g_rep.ckpt[0] ? g_rep.ckpt : "(未设置)");
    appf("\r\n寄存器:\r\n");
    appf("  RIP=%016llX RSP=%016llX RBP=%016llX\r\n", g_rep.rip, g_rep.rsp, g_rep.rbp);
    appf("  RAX=%016llX RBX=%016llX RCX=%016llX RDX=%016llX\r\n", g_rep.rax, g_rep.rbx, g_rep.rcx, g_rep.rdx);
    appf("  RSI=%016llX RDI=%016llX R8 =%016llX R9 =%016llX\r\n", g_rep.rsi, g_rep.rdi, g_rep.r8, g_rep.r9);
    appf("  R10=%016llX R11=%016llX R12=%016llX R13=%016llX\r\n", g_rep.r10, g_rep.r11, g_rep.r12, g_rep.r13);
    appf("  R14=%016llX R15=%016llX\r\n", g_rep.r14, g_rep.r15);
    appf("\r\n已加载模块 (%d):\r\n", g_rep.nmods);
    for (i = 0; i < g_rep.nmods; i++)
        appf("  %016llX  %s\r\n", g_rep.mods[i].base, g_rep.mods[i].name);
    appf("\r\n栈扫描（落在模块内的值，%d 条）:\r\n", g_rep.nstack);
    for (i = 0; i < g_rep.nstack; i++)
        appf("  %016llX -> %s + 0x%llX\r\n", g_rep.stack_vals[i],
             g_rep.mods[g_rep.stack_mod[i]].name, g_rep.stack_off[i]);
    appf("\r\n提示：把这份 txt（和同名 .dmp）一起提交即可；地址都是 模块基址+偏移，换机器也能对。\r\n");
}

static void render_json(void)
{
    int i;
    buf_reset();
    appf("{\n");
    appf("  \"kind\": \"flint-crash\",\n");
    appf("  \"time\": "); appj(g_rep.time); appf(",\n");
    appf("  \"exe\": "); appj(g_rep.exe); appf(",\n");
    appf("  \"app\": "); appj(g_rep.app); appf(",\n");
    appf("  \"exception\": {\n");
    appf("    \"code\": %u,\n", g_rep.code);
    appf("    \"code_hex\": \"0x%08X\",\n", g_rep.code);
    appf("    \"name\": "); appj(g_rep.code_name); appf(",\n");
    appf("    \"address\": %llu,\n", g_rep.addr);
    appf("    \"address_hex\": \"0x%016llX\"\n", g_rep.addr);
    appf("  },\n");
    appf("  \"last_error\": "); appj(g_rep.last_err); appf(",\n");
    appf("  \"last_checkpoint\": "); appj(g_rep.ckpt); appf(",\n");
    appf("  \"registers\": {\"rip\": %llu, \"rsp\": %llu, \"rbp\": %llu, \"rax\": %llu, \"rbx\": %llu,\n",
         g_rep.rip, g_rep.rsp, g_rep.rbp, g_rep.rax, g_rep.rbx);
    appf("                 \"rcx\": %llu, \"rdx\": %llu, \"rsi\": %llu, \"rdi\": %llu,\n",
         g_rep.rcx, g_rep.rdx, g_rep.rsi, g_rep.rdi);
    appf("                 \"r8\": %llu, \"r9\": %llu, \"r10\": %llu, \"r11\": %llu,\n",
         g_rep.r8, g_rep.r9, g_rep.r10, g_rep.r11);
    appf("                 \"r12\": %llu, \"r13\": %llu, \"r14\": %llu, \"r15\": %llu},\n",
         g_rep.r12, g_rep.r13, g_rep.r14, g_rep.r15);
    appf("  \"modules\": [\n");
    for (i = 0; i < g_rep.nmods; i++) {
        appf("    {\"base\": %llu, \"size\": %lu, \"name\": ", g_rep.mods[i].base, g_rep.mods[i].size);
        appj(g_rep.mods[i].name);
        appf("}%s\n", (i + 1 < g_rep.nmods) ? "," : "");
    }
    appf("  ],\n");
    appf("  \"stack\": [\n");
    for (i = 0; i < g_rep.nstack; i++) {
        appf("    {\"value\": %llu, \"module\": ", g_rep.stack_vals[i]);
        appj(g_rep.mods[g_rep.stack_mod[i]].name);
        appf(", \"offset\": %llu}%s\n", g_rep.stack_off[i], (i + 1 < g_rep.nstack) ? "," : "");
    }
    appf("  ]\n");
    appf("}\n");
}

static void write_minidump(EXCEPTION_POINTERS *ep, const char *path)
{
    typedef BOOL (WINAPI *PFN_MiniDumpWriteDump)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
        PMINIDUMP_EXCEPTION_INFORMATION, PMINIDUMP_USER_STREAM_INFORMATION, PMINIDUMP_CALLBACK_INFORMATION);
    HMODULE h = LoadLibraryA("dbghelp.dll");
    PFN_MiniDumpWriteDump fn;
    HANDLE f;
    MINIDUMP_EXCEPTION_INFORMATION info;
    if (!h) return;
    fn = (PFN_MiniDumpWriteDump)(void *)GetProcAddress(h, "MiniDumpWriteDump");
    if (!fn) { FreeLibrary(h); return; }
    f = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        info.ThreadId = GetCurrentThreadId();
        info.ExceptionPointers = ep;
        info.ClientPointers = FALSE;
        fn(GetCurrentProcess(), GetCurrentProcessId(), f, MiniDumpNormal, &info, NULL, NULL);
        CloseHandle(f);
    }
    FreeLibrary(h);
}

static void make_stamp(char *out, int cap)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    snprintf(out, cap, "%04d%02d%02d-%02d%02d%02d",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

static volatile LONG g_reported = 0;

static int fatal_code(unsigned int code)
{
    switch (code) {
    case 0xC0000005u: /* AV */
    case 0xC0000006u: /* in-page error */
    case 0xC000001Du: /* illegal instruction */
    case 0xC0000094u: /* int divide by zero */
    case 0xC00000FDu: /* stack overflow */
    case 0xC0000409u: /* stack buffer overrun */
        return 1;
    default:
        return 0;
    }
}

/* 抓现场并落盘。调用者负责去重（g_reported）。 */
static void build_and_write(EXCEPTION_POINTERS *ep)
{
    char stamp[32], path_txt[1024], path_json[1024], path_dmp[1024];
    PEXCEPTION_RECORD er = ep ? ep->ExceptionRecord : NULL;
    PCONTEXT c = ep ? ep->ContextRecord : NULL;

    if (InterlockedExchange(&g_in_handler, 1) != 0) return;

    ZeroMemory(&g_rep, sizeof(g_rep));
    str_copy(g_rep.time, sizeof(g_rep.time), "(未知)");
    {
        SYSTEMTIME st; char t[32];
        GetLocalTime(&st);
        snprintf(t, sizeof(t), "%04d-%02d-%02d %02d:%02d:%02d",
                 st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        str_copy(g_rep.time, sizeof(g_rep.time), t);
    }
    GetModuleFileNameA(NULL, g_rep.exe, sizeof(g_rep.exe) - 1);
    str_copy(g_rep.app, sizeof(g_rep.app), g_app);
    if (!g_rep.app[0]) {
        char tmp[1024];
        str_copy(tmp, sizeof(tmp), g_rep.exe);
        str_copy(g_rep.app, sizeof(g_rep.app), strrchr(tmp, '\\') ? strrchr(tmp, '\\') + 1 : tmp);
    }
    {
        char tmp[1024];
        ansi_to_utf8(g_rep.exe, tmp, sizeof(tmp));
        str_copy(g_rep.exe, sizeof(g_rep.exe), tmp);
    }
    g_rep.code = er ? (unsigned int)er->ExceptionCode : 0;
    g_rep.code_name = flt_diag_status_name(g_rep.code);
    g_rep.addr = er ? (unsigned long long)(ULONG_PTR)er->ExceptionAddress : 0;
    if (g_err_code) {
        char tmp[600];
        snprintf(tmp, sizeof(tmp), "%d %s", g_err_code, g_err_msg);
        str_copy(g_rep.last_err, sizeof(g_rep.last_err), tmp);
    }
    str_copy(g_rep.ckpt, sizeof(g_rep.ckpt), g_ckpt);
    if (c) {
        g_rep.rax = c->Rax; g_rep.rbx = c->Rbx; g_rep.rcx = c->Rcx; g_rep.rdx = c->Rdx;
        g_rep.rsi = c->Rsi; g_rep.rdi = c->Rdi; g_rep.rbp = c->Rbp; g_rep.rsp = c->Rsp;
        g_rep.rip = c->Rip;
        g_rep.r8 = c->R8; g_rep.r9 = c->R9; g_rep.r10 = c->R10; g_rep.r11 = c->R11;
        g_rep.r12 = c->R12; g_rep.r13 = c->R13; g_rep.r14 = c->R14; g_rep.r15 = c->R15;
    }
    collect_modules();
    if (c) collect_stack((unsigned long long)c->Rsp);

    make_stamp(stamp, sizeof(stamp));
    snprintf(path_txt, sizeof(path_txt), "%s\\crash-%s.txt", g_dir, stamp);
    snprintf(path_json, sizeof(path_json), "%s\\crash-%s.json", g_dir, stamp);
    snprintf(path_dmp, sizeof(path_dmp), "%s\\crash-%s.dmp", g_dir, stamp);

    render_txt();
    write_file(path_txt, g_buf, buf_len);
    render_json();
    write_file(path_json, g_buf, buf_len);
    write_minidump(ep, path_dmp);

    InterlockedExchange(&g_in_handler, 0);
}

/* 未处理异常过滤器：有 .pdata / 有 CRT 的普通进程走这条 */
static LONG WINAPI unhandled_filter(EXCEPTION_POINTERS *ep)
{
    if (InterlockedExchange(&g_reported, 1) != 0) return EXCEPTION_CONTINUE_SEARCH;
    build_and_write(ep);
    return EXCEPTION_EXECUTE_HANDLER;
}

/* 向量化异常处理器：**没有 .pdata、没有 CRT 的 PE（FLINT 就是）走不到过滤器** ——
 * 2026-10-20 实测：FLINT 程序空指针写时 SetUnhandledExceptionFilter 没被调用。
 * VEH 在异常分发最前面运行、不依赖栈回溯，所以补这一层。只对"必死"的异常码落盘，
 * 避免把程序自己接住的可恢复异常也记成崩溃。 */
static LONG CALLBACK veh_handler(EXCEPTION_POINTERS *ep)
{
    unsigned int code = (ep && ep->ExceptionRecord) ? (unsigned int)ep->ExceptionRecord->ExceptionCode : 0;
    if (!fatal_code(code)) return EXCEPTION_CONTINUE_SEARCH;
    if (InterlockedExchange(&g_reported, 1) != 0) return EXCEPTION_CONTINUE_SEARCH;
    build_and_write(ep);
    return EXCEPTION_CONTINUE_SEARCH;
}

/* ---------- 导出函数 ---------- */

static void ensure_dir(void)
{
    if (g_dir[0]) return;
    GetModuleFileNameA(NULL, g_dir, MAX_PATH);
    {
        char *p = strrchr(g_dir, '\\');
        if (p) *p = 0;
    }
    strncat(g_dir, "\\fltdiag", MAX_PATH - strlen(g_dir) - 1);
    CreateDirectoryA(g_dir, NULL);
}

int flt_diag_init(const char *app_name)
{
    ensure_dir();
    if (app_name && *app_name) ansi_to_utf8(app_name, g_app, sizeof(g_app));
    if (InterlockedExchange(&g_inited, 1) == 0) {
        SetUnhandledExceptionFilter(unhandled_filter);
        g_veh = AddVectoredExceptionHandler(1, veh_handler);
    }
    return FLTDIAG_OK;
}

int flt_diag_shutdown(void)
{
    SetUnhandledExceptionFilter(NULL);
    if (g_veh) { RemoveVectoredExceptionHandler(g_veh); g_veh = NULL; }
    InterlockedExchange(&g_inited, 0);
    return FLTDIAG_OK;
}

int flt_diag_set_dir(const char *dir)
{
    char full[MAX_PATH];
    if (!dir || !*dir) return FLTDIAG_ERR_ARG;
    if (!GetFullPathNameA(dir, MAX_PATH, full, NULL)) return FLTDIAG_ERR_ARG;
    str_copy(g_dir, sizeof(g_dir), full);
    if (!CreateDirectoryA(g_dir, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
        return FLTDIAG_ERR_IO;
    ensure_dir();
    return FLTDIAG_OK;
}

int flt_err_set(int code, const char *msg)
{
    char tmp[600];
    g_err_code = code;
    if (msg) {
        ansi_to_utf8(msg, tmp, sizeof(tmp));
        str_copy(g_err_msg, sizeof(g_err_msg), tmp);
    } else {
        g_err_msg[0] = 0;
    }
    return 0;
}

int flt_err_get(void) { return g_err_code; }
const char *flt_err_msg(void) { return g_err_msg; }

int flt_checkpoint(const char *where)
{
    char tmp[220];
    if (!where) return FLTDIAG_ERR_ARG;
    ansi_to_utf8(where, tmp, sizeof(tmp));
    str_copy(g_ckpt, sizeof(g_ckpt), tmp);
    return 0;
}
