// wxprobe.c —— 只读探针：实测「目标产物各节的**运行时实际保护级别**」（W^X 轮次的未核实项）
//
// 为什么需要它：`objdump -h` 只能读到**声明**的节特征位（Characteristics），读不到 loader 把页
//   映射成什么保护。构造「声明 R|X 但实际 RWX」这类假绿就靠它来排除。实测点是两个时刻：
//     (A) 挂起点        —— 镜像已映射、loader 还没跑（= 由节特征位直接推出的保护）
//     (B) 运行期挂起点  —— ResumeThread + 等 200ms 再 SuspendThread（loader 已解析导入、
//                          已经往 IAT 写过真实地址）⇒ 能看出 loader **写完 IAT 后有没有还原保护**
//        （这一条直接决定「IAT 落在只读节里到底要不要给数据目录 12」—— 调研的说法 vs 本机实测）
//
// 纪律（与项目既有探针一致）：
//   · **只读**：不改目标内存、不注入任何代码、不挂钩子；只 CreateProcess + ReadProcessMemory + VirtualQueryEx。
//   · 两个时刻都在**挂起**状态下采样（A 挂起创建；B 采样前 SuspendThread），保证不与被测的执行竞争。
//   · 收工一律 TerminateProcess（目标可能是死循环样本，靠它自己退不可靠）。
//   · 退出码即判据：0 = 采样成功；1 = 用法错；2 = 起目标失败（含 740 提权清单）；3 = 目标太快退（只有 A 没有 B）。
//
// 用法：wxprobe.exe <目标.exe>

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef LONG (NTAPI *pNtQueryInformationProcess)(HANDLE, ULONG, PVOID, ULONG, PULONG);

// PROCESS_BASIC_INFORMATION（x64 手写布局：NTSTATUS 4 + 4 pad / PebBaseAddress 8 / AffinityMask 8
//   / BasePriority 4 + 4 pad / UniqueProcessId 8 / InheritedFromUniqueProcessId 8）
typedef struct {
    LONG      ExitStatus;
    ULONG     Pad0;
    ULONG_PTR PebBaseAddress;
    ULONG_PTR AffinityMask;
    LONG      BasePriority;
    ULONG     Pad1;
    ULONG_PTR UniqueProcessId;
    ULONG_PTR InheritedFromUniqueProcessId;
} PBI;

static uint32_t rd_u16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
static uint32_t rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// 保护位 → 人话（不带颜色，便于 grep）
static void prot_str(DWORD p, char *out, size_t n) {
    const char *base = "?";
    switch (p & 0xFF) {
        case PAGE_NOACCESS:          base = "NOACCESS";          break;
        case PAGE_READONLY:          base = "READONLY";          break;
        case PAGE_READWRITE:         base = "READWRITE";         break;
        case PAGE_WRITECOPY:         base = "WRITECOPY";         break;
        case PAGE_EXECUTE:           base = "EXECUTE";           break;
        case PAGE_EXECUTE_READ:      base = "EXECUTE_READ";      break;
        case PAGE_EXECUTE_READWRITE: base = "EXECUTE_READWRITE"; break;
        case PAGE_EXECUTE_WRITECOPY: base = "EXECUTE_WRITECOPY"; break;
        default: break;
    }
    char mod[32] = "";
    if (p & PAGE_GUARD)        strcat(mod, "|GUARD");
    if (p & PAGE_NOCACHE)      strcat(mod, "|NOCACHE");
    if (p & PAGE_WRITECOMBINE) strcat(mod, "|WRITECOMBINE");
    snprintf(out, n, "0x%03lX %s%s", (unsigned long)p, base, mod);
}

static void chars_str(uint32_t c, char *out, size_t n) {
    snprintf(out, n, "0x%08lX %s%s%s%s%s%s",
             (unsigned long)c,
             (c & 0x00000020u) ? "CODE " : "",
             (c & 0x20000000u) ? "EXECUTE " : "",
             (c & 0x40000000u) ? "READ " : "",
             (c & 0x80000000u) ? "WRITE " : "",
             (c & 0x02000000u) ? "DISCARDABLE " : "",
             (c & 0x00000040u) ? "INIT_DATA" : "UNINIT_DATA");
}

// 采样：把一个地址的当前保护打进 buf（含"实际是否比声明多出了 W/X"判定交给调用方）
typedef struct {
    int     ok;
    DWORD   protect;
    DWORD   alloc_protect;
    DWORD   state;
    SIZE_T  region;
} Samp;

static Samp sample(HANDLE hp, uint64_t addr) {
    Samp s; memset(&s, 0, sizeof(s));
    MEMORY_BASIC_INFORMATION mbi;
    SIZE_T got = VirtualQueryEx(hp, (LPCVOID)(uintptr_t)addr, &mbi, sizeof(mbi));
    if (got != sizeof(mbi)) return s;   // ok=0
    s.ok = 1;
    s.protect = mbi.Protect;
    s.alloc_protect = mbi.AllocationProtect;
    s.state = mbi.State;
    s.region = mbi.RegionSize;
    return s;
}

static void print_samp(const char *tag, HANDLE hp, uint64_t addr) {
    char b[64];
    Samp s = sample(hp, addr);
    if (!s.ok) { printf("      %-4s : <VirtualQueryEx 失败 err=%lu> addr=0x%llX\n", tag,
                        (unsigned long)GetLastError(), (unsigned long long)addr); return; }
    prot_str(s.protect, b, sizeof(b));
    printf("      %-4s : protect=%s  alloc=0x%03lX  state=0x%lX  region=0x%llX\n", tag, b,
           (unsigned long)s.alloc_protect, (unsigned long)s.state, (unsigned long long)s.region);
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: wxprobe.exe <target.exe>\n"); return 1; }

    char cmdline[MAX_PATH + 8];
    snprintf(cmdline, sizeof(cmdline), "\"%s\"", argv[1]);

    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));

    printf("== wxprobe (read-only) ==\n");
    printf("target : %s\n", argv[1]);

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                        CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        DWORD e = GetLastError();
        printf("ERROR  : CreateProcess 失败 err=%lu%s\n", (unsigned long)e,
               (e == 740) ? "  (ERROR_ELEVATION_REQUIRED：目标带 requireAdministrator 清单)" : "");
        return 2;
    }
    HANDLE hp = pi.hProcess;

    // —— 取 PEB → ImageBaseAddress ——
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    pNtQueryInformationProcess NtQIP =
        (pNtQueryInformationProcess)GetProcAddress(ntdll, "NtQueryInformationProcess");
    if (!NtQIP) { printf("ERROR  : 取不到 NtQueryInformationProcess\n"); TerminateProcess(hp, 0); return 2; }

    PBI pbi; ULONG ret = 0;
    memset(&pbi, 0, sizeof(pbi));
    LONG st = NtQIP(hp, 0 /*ProcessBasicInformation*/, &pbi, sizeof(pbi), &ret);
    if (st != 0) { printf("ERROR  : NtQueryInformationProcess st=0x%lX\n", (unsigned long)st);
                   TerminateProcess(hp, 0); return 2; }

    uint8_t peb[0x20]; SIZE_T rd = 0;
    if (!ReadProcessMemory(hp, (LPCVOID)pbi.PebBaseAddress, peb, sizeof(peb), &rd)) {
        printf("ERROR  : 读 PEB 失败 err=%lu\n", (unsigned long)GetLastError());
        TerminateProcess(hp, 0); return 2;
    }
    uint64_t image_base = 0;
    memcpy(&image_base, peb + 0x10, 8);   // PEB.ImageBaseAddress（x64 偏移 0x10）

    // —— 读镜像头（0x1000 足够覆盖我们产物的头）——
    uint8_t hdr[0x1000];
    if (!ReadProcessMemory(hp, (LPCVOID)(uintptr_t)image_base, hdr, sizeof(hdr), &rd)) {
        printf("ERROR  : 读镜像头失败 err=%lu\n", (unsigned long)GetLastError());
        TerminateProcess(hp, 0); return 2;
    }
    uint32_t e_lfanew = rd_u32(hdr + 0x3C);
    if (memcmp(hdr + e_lfanew, "PE\0\0", 4) != 0) { printf("ERROR  : 头里没有 PE 签名\n"); TerminateProcess(hp, 0); return 2; }

    const uint8_t *coff = hdr + e_lfanew + 4;
    uint32_t nsec      = rd_u16(coff + 2);
    // ⚠️ SizeOfOptionalHeader 在 COFF 头的 **偏移 16**（不是 20 —— 20 是 optional header 的起点，
    //    第一版就写成了 20，读到的其实是 Characteristics(0x22) ⇒ 节表偏移整整错了 34 字节，
    //    打印出 va=0 / chars=0 的"幽灵节"）。这正是本项目那条老纪律：探针自己也要先自证。
    uint32_t opt_size  = rd_u16(coff + 16);
    const uint8_t *opt = coff + 20;
    uint32_t dllchars  = rd_u16(opt + 0x46);
    uint32_t nrva      = rd_u32(opt + 0x6C);
    (void)nrva;

    printf("image  : base=0x%llX  DllCharacteristics=0x%04lX %s%s\n",
           (unsigned long long)image_base, (unsigned long)dllchars,
           (dllchars & 0x0040u) ? "DYNAMIC_BASE " : "", (dllchars & 0x0100u) ? "NX_COMPAT" : "");

    // 数据目录 [1] Import、[12] IAT
    uint32_t imp_rva = 0, imp_size = 0, iat_rva = 0, iat_size = 0;
    const uint8_t *dd = opt + 0x70;
    imp_rva = rd_u32(dd + 1 * 8); imp_size = rd_u32(dd + 1 * 8 + 4);
    iat_rva = rd_u32(dd + 12 * 8); iat_size = rd_u32(dd + 12 * 8 + 4);
    printf("dir[1] : Import  rva=0x%08lX size=0x%lX\n", (unsigned long)imp_rva, (unsigned long)imp_size);
    printf("dir[12]: IAT     rva=0x%08lX size=0x%lX   %s\n", (unsigned long)iat_rva, (unsigned long)iat_size,
           (iat_rva == 0 && iat_size == 0) ? "(未提供)" : "");

    // —— 节表 ——
    const uint8_t *sec = opt + opt_size;
    printf("sections (%lu):\n", (unsigned long)nsec);
    for (uint32_t i = 0; i < nsec; i++) {
        const uint8_t *s = sec + (size_t)i * 40;
        char name[9]; memset(name, 0, sizeof(name)); memcpy(name, s, 8);
        uint32_t vs = rd_u32(s + 8), va = rd_u32(s + 12), chars = rd_u32(s + 36);
        char cb[96]; chars_str(chars, cb, sizeof(cb));
        printf("  [%lu] %-8s va=0x%08lX vs=0x%08lX  chars=%s\n",
               (unsigned long)i, name, (unsigned long)va, (unsigned long)vs, cb);
        print_samp("(A)", hp, image_base + va);
    }

    // —— 采样时刻 B 之前：在「启动窗口」里密集采样 IAT 页 ——
    //   问的是：loader 往一个**不可写**的节里写解析结果时，会不会把它临时放开、放开了多久？
    //   （W^X 关心的正是这个窗口 —— 它决定"IAT 落在只读节里"是不是真的全程不可写）
    uint64_t iat_probe_addr = 0;
    if (iat_size) iat_probe_addr = image_base + iat_rva;
    else if (imp_rva) {
        uint8_t d0[20];
        if (ReadProcessMemory(hp, (LPCVOID)(uintptr_t)(image_base + imp_rva), d0, sizeof(d0), &rd))
            iat_probe_addr = image_base + rd_u32(d0 + 16);      // FirstThunk（描述符第 1 个就是 IAT）
    }
    // —— 启动窗口：密集采样**每一节的首页** ＋ IAT 页 ——
    //   问的是：loader 往不可写的节里写解析结果时，把**哪一页**临时放开了？
    //   本轮的核心判据 = 「**代码页**在整段加载窗口里，任何时刻都不得可写」。
    #define MAXW 16
    struct Watch { uint64_t addr; char tag[12]; DWORD seen[8]; int nseen; long nsamp; } w[MAXW];
    int nw = 0;
    for (uint32_t k = 0; k < nsec && nw < MAXW; k++) {
        const uint8_t *s = sec + (size_t)k * 40;
        char nm[16]; memset(nm, 0, sizeof(nm)); memcpy(nm, s, 8);
        w[nw].addr = image_base + rd_u32(s + 12);
        snprintf(w[nw].tag, sizeof(w[nw].tag), "%s", nm);
        w[nw].nseen = 0; w[nw].nsamp = 0;
        nw++;
    }
    if (iat_probe_addr && nw < MAXW) {
        w[nw].addr = iat_probe_addr;
        snprintf(w[nw].tag, sizeof(w[nw].tag), "IAT");
        w[nw].nseen = 0; w[nw].nsamp = 0;
        nw++;
    }
    ResumeThread(pi.hThread);
    {
        DWORD t0 = GetTickCount();
        while (GetTickCount() - t0 < 200) {
            for (int i = 0; i < nw; i++) {
                Samp sm = sample(hp, w[i].addr);
                w[i].nsamp++;
                if (sm.ok) {
                    int dup = 0;
                    for (int k2 = 0; k2 < w[i].nseen; k2++) if (w[i].seen[k2] == sm.protect) dup = 1;
                    if (!dup && w[i].nseen < 8) w[i].seen[w[i].nseen++] = sm.protect;
                }
            }
            DWORD ec0 = 0; GetExitCodeProcess(hp, &ec0);
            if (ec0 != STILL_ACTIVE) break;                     // 目标太快退了，别空转
        }
    }
    for (int i = 0; i < nw; i++) {
        char b[64];
        printf("watch %-10s 0x%llX  samples=%ld  distinct:", w[i].tag,
               (unsigned long long)w[i].addr, w[i].nsamp);
        for (int k2 = 0; k2 < w[i].nseen; k2++) { prot_str(w[i].seen[k2], b, sizeof(b)); printf(" [%s]", b); }
        printf("\n");
    }
    Sleep(200);
    SuspendThread(pi.hThread);
    DWORD ec = 0; GetExitCodeProcess(hp, &ec);
    int alive = (ec == STILL_ACTIVE);
    printf("moment B: %s (exit=0x%lX)\n", alive ? "目标仍活着，已挂起采样" : "目标已退出，只能报时刻 A", (unsigned long)ec);

    if (alive) {
        for (uint32_t i = 0; i < nsec; i++) {
            const uint8_t *s = sec + (size_t)i * 40;
            char name[9]; memset(name, 0, sizeof(name)); memcpy(name, s, 8);
            uint32_t va = rd_u32(s + 12);
            printf("  [%lu] %-8s\n", (unsigned long)i, name);
            print_samp("(B)", hp, image_base + va);
        }
        // IAT 区间（数据目录 12）与导入描述符里的 FirstThunk，各采一次
        if (iat_size) {
            printf("IAT dir[12] page:\n");
            print_samp("(B)", hp, image_base + iat_rva);
        }
        if (imp_rva) {
            uint8_t desc[20];
            for (int k = 0; k < 16; k++) {
                if (!ReadProcessMemory(hp, (LPCVOID)(uintptr_t)(image_base + imp_rva + (uint32_t)k * 20),
                                       desc, sizeof(desc), &rd)) break;
                uint32_t oft = rd_u32(desc + 0), name_rva = rd_u32(desc + 12), ft = rd_u32(desc + 16);
                if (oft == 0 && name_rva == 0 && ft == 0) break;
                printf("import desc[%d]: INT=0x%08lX FirstThunk=0x%08lX\n", k,
                       (unsigned long)oft, (unsigned long)ft);
                print_samp("(B)", hp, image_base + ft);
            }
        }
    }

    TerminateProcess(hp, 0);
    CloseHandle(pi.hThread); CloseHandle(hp);
    printf("== done ==\n");
    return alive ? 0 : 3;
}
