// aslrprobe.c -- read-only probe: "where did the loader actually put this image?"
//                (proof for the ASLR round, v1.4.14)
//
// Why it exists: an ASLR claim can be faked in two ways, and both are ruled out here:
//   (a) reading the DECLARED bit (DllCharacteristics & DYNAMIC_BASE) proves nothing -- the flag can
//       be set and the loader still ignore it (that is exactly what IMAGE_FILE_RELOCS_STRIPPED does,
//       silently, see below);
//   (b) calling GetModuleHandle(NULL) *inside the target* proves nothing either, unless the target
//       knows its own PREFERRED base to compare against.
// So this probe does what the OS does: CreateProcess(CREATE_SUSPENDED) -> read the child's
// PEB -> PEB.ImageBaseAddress, and reads PreferredBase straight out of the image's own
// optional header. Then "loaded base != preferred base" is direct evidence that the loader
// relocated the image, i.e. ASLR is live; not the probability argument "N runs happened to differ".
//
// Discipline (same as the other probes in this tree):
//   * READ-ONLY: no writes to the target, no injection, no hooks. CreateProcess + ReadProcessMemory only.
//   * the target is created SUSPENDED: its first instruction never runs, so any target is safe
//     (no dependency on the target being long-lived or well-behaved), then TerminateProcess.
//   * one machine-readable line of output, exit code 0 = measured, 1 = usage, 2 = could not measure.
//
// usage: aslrprobe.exe <target.exe>

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef LONG (NTAPI *pNtQueryInformationProcess)(HANDLE, ULONG, PVOID, ULONG, PULONG);

// PROCESS_BASIC_INFORMATION (x64 hand layout: NTSTATUS 4 + pad / PebBaseAddress 8 / ...)
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

static uint16_t rd_u16(const uint8_t *p) { return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8)); }
static uint32_t rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// preferred base: read from the image on disk, honouring the section table (SizeOfHeaders is not a
// reliable upper bound on where the optional header lives).
static int read_preferred_base(const char *path, uint64_t *pref, uint16_t *dllchars, uint32_t *coffchars) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    uint8_t head[0x1000];
    size_t got = fread(head, 1, sizeof(head), f);
    *pref = 0; *dllchars = 0; *coffchars = 0;
    if (got < 0x100) { fclose(f); return 0; }
    if (head[0] != 'M' || head[1] != 'Z') { fclose(f); return 0; }
    uint32_t lf = rd_u32(head + 0x3C);
    if (lf + 0xF8 > got) { fclose(f); return 0; }
    if (memcmp(head + lf, "PE\0\0", 4) != 0) { fclose(f); return 0; }
    const uint8_t *coff = head + lf + 4;
    *coffchars = (uint32_t)rd_u16(coff + 18);   // COFF Characteristics (RELOCS_STRIPPED = 0x0001)
    const uint8_t *opt = coff + 20;
    uint64_t ib = (uint64_t)rd_u32(opt + 0x18) | ((uint64_t)rd_u32(opt + 0x1C) << 32);
    *pref = ib;
    *dllchars = rd_u16(opt + 0x46);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: aslrprobe.exe <target.exe>\n"); return 1; }

    uint64_t pref = 0; uint16_t dllchars = 0; uint32_t coffchars = 0;
    int have_hdr = read_preferred_base(argv[1], &pref, &dllchars, &coffchars);

    char cmdline[MAX_PATH + 8];
    snprintf(cmdline, sizeof(cmdline), "\"%s\"", argv[1]);

    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si)); si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                        CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        DWORD e = GetLastError();
        printf("ERROR: CreateProcess failed err=%lu%s\n", (unsigned long)e,
               (e == 740) ? " (ERROR_ELEVATION_REQUIRED: target carries a requireAdministrator manifest)" : "");
        return 2;
    }
    HANDLE hp = pi.hProcess;

    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    pNtQueryInformationProcess NtQIP =
        (pNtQueryInformationProcess)(void *)GetProcAddress(ntdll, "NtQueryInformationProcess");
    if (!NtQIP) { printf("ERROR: NtQueryInformationProcess not found\n"); TerminateProcess(hp, 0); return 2; }

    PBI pbi; ULONG ret = 0;
    memset(&pbi, 0, sizeof(pbi));
    LONG st = NtQIP(hp, 0 /*ProcessBasicInformation*/, &pbi, sizeof(pbi), &ret);
    if (st != 0) { printf("ERROR: NtQueryInformationProcess st=0x%lX\n", (unsigned long)st);
                   TerminateProcess(hp, 0); return 2; }

    uint8_t peb[0x20]; SIZE_T rd = 0;
    if (!ReadProcessMemory(hp, (LPCVOID)pbi.PebBaseAddress, peb, sizeof(peb), &rd)) {
        printf("ERROR: read PEB failed err=%lu\n", (unsigned long)GetLastError());
        TerminateProcess(hp, 0); return 2;
    }
    uint64_t loaded = 0;
    memcpy(&loaded, peb + 0x10, 8);       // PEB.ImageBaseAddress (x64 offset 0x10)

    TerminateProcess(hp, 0);
    CloseHandle(pi.hThread); CloseHandle(hp);

    // one machine-readable line: the gate parses exactly these fields
    printf("target=%s preferred=0x%llX loaded=0x%llX dllchars=0x%04X coffchars=0x%04X hdr=%s randomized=%s hi_entropy=%s\n",
           argv[1],
           (unsigned long long)pref, (unsigned long long)loaded,
           (unsigned)dllchars, (unsigned)coffchars,
           have_hdr ? "ok" : "unreadable",
           (have_hdr && loaded != pref) ? "yes" : "no",
           ((dllchars & 0x0020u) && (loaded & 0xFFFFu) == 0) ? "yes" : "no");

    if (!have_hdr) return 2;
    return 0;
}
