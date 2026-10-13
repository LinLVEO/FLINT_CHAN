// pe.c — FLINT 自写最小 PE 打包器（v1.3.0：双节 .text + .data）
// 输入：codegen_main 产出的机器码字节（含字符串区/double 常量区）→ 输出：完整最小 x64 控制台 exe。
//
// 关键设计：不依赖 CRT/链接器，进程退出直接调 kernel32!ExitProcess（导入表）。
// 导入表是「代码要调 DLL」的最简正规通道：loader 把函数真实地址写进 IAT 槽，
// 代码用 FF15 [rip+disp32] 跳到该槽。
//
// v0.8 扩展：导入函数集 = kernel32!ExitProcess（内置，槽 0）+ Program 声明的
// API（按 dll 分组，每模块一组 IMAGE_IMPORT_DESCRIPTOR + INT/IAT/hintname/dllname）。
// API 调用点（gen->api_sites）的 FF15 disp 指向各自 IAT 槽。
//
// v1.3.0 扩展（全局变量）：由**单节 .text** 变**双节 .text + .data**。
//   为什么非得加节：全局变量必须可写，而 .text 是 CODE|EXECUTE|READ（写会崩），
//   改 .text 为可写会牺牲代码段保护——所以老实加一个 RW 节。
//   为什么不需要重定位：**产物里没有任何绝对地址**（全部 RIP 相对 + RVA 差值）——与是否 ASLR 无关。
//   于是 .data 里每个字节的运行时地址（DATA_RVA + doff）只以 **disp 差值**进入指令，
//   代码直接 `[rip+disp32]` 指过去（disp 由 codegen 算死，本文件只管把 .data 摆到位）。
//   ⚠️ 原文写的是「DllCharacteristics=0 = 无 ASLR（永远加载在 ImageBase），所以不需要重定位」——
//   2026-09-14 实测证伪（「新路候选.md」§1.1 事实 3）：开 DYNAMIC_BASE、甚至改 ImageBase，
//   产物行为都不变 ⇒「无 ASLR」从来不是前提，**位置无关**才是真理由；v1.3.4 起由下方 I1 断言守着。
//   布局：.text @ 0x1000、.data @ 0x2000（见 flint.h 的 FLINT_TEXT_RVA / FLINT_DATA_RVA）。
//
// 文件布局（64 位 PE32+，双节，FileAlignment=0x200）：
//   0x000  DOS 头（MZ + e_lfanew=0x40）
//   0x040  "PE\0\0" + COFF 头 + PE32+ 可选头 + 节表（.text, .data）
//   0x200  .text 内容（RVA 0x1000 起）：
//           代码（含字符串区与 double 常量区）
//           导入描述符区（每模块 20B + 全零终止 20B）
//           各模块数据（按序）：INT 数组 / IAT 数组 / Hint/Name 块 / DLL 名
//   0x400  .data 内容（RVA 0x2000 起）：全局变量初值（未初始化部分由 padding 补 0）
//
// 全手动字节写入（Buf 只能顺序追加），布局先纯计算后顺序写。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flint.h"

#define IMAGE_BASE  0x140000000ULL
#define SEC_ALIGN   0x1000        // SectionAlignment
#define FILE_ALIGN  0x200         // FileAlignment
#define TEXT_RVA    FLINT_TEXT_RVA   // .text 的 RVA（= 入口点）
#define TEXT_RAW    FLINT_TEXT_RAW   // .text 的文件偏移（0x200；与 flint.h 同一真源）
// 注：.data 的 RVA 不是常量（= TEXT_RVA + align_up(.text 虚拟大小, SEC_ALIGN)，两节必须连续），
//     由下方 pe_build 内的 `data_rva` 现算 —— 见下方「两节紧邻」的规范依据（MSDN PE Format 明文）。
// ⚠️ .data 的**文件偏移**不能写死！必须排在 .text 的实际文件长度之后（见下方 data_raw_ptr 的计算）。
//   第一版写死 0x400，而 .text = 代码（含字符串/double 常量区）+ 导入表，实测可到 0x7B0 →
//   **.data 的原始字节直接盖在 .text 代码上**（静默损坏约 0x210 字节，程序 0xC0000005）。
//   教训：RVA 布局（由 SEC_ALIGN 保证，可预算）与**文件**布局（由实际内容长度决定）是两件事，
//   把后者当成常量就是这类 bug —— 与「假设代码不超过一页」是同一族的错，但那个有守卫、这个漏了。
#define HEADER_SIZE 0x200         // SizeOfHeaders 的**下限**（实际值 = pe_headers_size(...)；见 flint.h 说明）
#define STR2(x) #x
#define STR(x) STR2(x)
// v1.4.7：64 → 96。缘起 = 浮窗第 6 步（config.json 读写）接 `lib\io_lib.fl` 后**实测撞墙**：
//   该 app 的导入函数声明数正好 64 个，加上内置的 `ExitProcess`（槽 0）→ 65 > 64 → 编译期报
//   「导入函数总数超过上限 64」。上限本身只是**编译器侧的固定数组容量**（PE 布局按实际用量现算，
//   不受它影响），所以放宽是安全的；给到 96 留出余量，别再一步一撞。
#define MAX_IMPORTS 96            // 导入函数总数上限
#define MAX_GROUPS  8             // 导入模块数上限
// v1.4.28（B1-3）：导入模块名（写出名）上限 —— ImpGroup.dll 是 char[64] ⇒ 63 字节 + NUL。
//   超长会被写出端静默截断（见下方 pe_import_module_name_len 的注释），故 parse.c 在默认档就拦。
#define IMPORT_DLL_NAME_MAX 63

// ========== v1.4.6：`-admin` = 内嵌 RT_MANIFEST（requireAdministrator）= 第三节 .rsrc ==========
// 动机：FLINT 浮窗要读 MSR（CPU 温度/频率/功耗）⇒ 进程必须先有管理员令牌；C# 参考版的做法是在
//   app.manifest 里声明 requireAdministrator（双击即提权）。FLINT 侧要对等，产物就得**自带清单**。
// 为什么必须是「资源节里的 RT_MANIFEST」：Windows 只从 PE 资源里认清单——类型 24、名字 1，
//   放在别处（比如某个 .data 里的一段 XML）系统根本不看。
// 资源树（标准三层：TYPE → NAME → LANG → 数据项），全部落在 .rsrc 节内、偏移相对节首：
//   +0x00 IMAGE_RESOURCE_DIRECTORY 根目录（16B，NumberOfIdEntries=1）
//   +0x10   目录项：Type=24(RT_MANIFEST)          → 子目录偏移 0x18（高位 0x80000000 表示"是子目录"）
//   +0x18 IMAGE_RESOURCE_DIRECTORY 二层（16B）
//   +0x28   目录项：Name=1(CREATEPROCESS_MANIFEST_RESOURCE_ID) → 子目录偏移 0x30
//   +0x30 IMAGE_RESOURCE_DIRECTORY 三层（16B）
//   +0x40   目录项：Lang=0x409(EN-US)             → 数据项偏移 0x48（**不带**高位）
//   +0x48 IMAGE_RESOURCE_DATA_ENTRY（16B）：{OffsetToData=清单 RVA, Size, CodePage=0, Reserved=0}
//   +0x58 清单 XML 正文（UTF-8，**无 BOM**）
// ⚠️ 目录项那个 32 位字段有两种含义（高位=1 → 低 31 位是子目录偏移；高位=0 → 是数据项偏移），
//   写错就会让系统把"数据项偏移"当"目录偏移"→ 清单静默不生效（双击不提权，且不报任何错）。
#define RSRC_LANG       0x409     // LANG_ENGLISH | SUBLANG_ENGLISH_US
#define RSRC_MF_OFF     0x58      // 清单正文在 .rsrc 内的偏移
#define RSRC_SIZE_MIN   0x58      // 资源树（含数据项）在清单正文之前的固定大小
#define RSRC_CHAR       0x40000040  // .rsrc 节特性：INITIALIZED_DATA | READ
// v1.4.11（`-debug`）三个调试节的特征位：实测真实 MinGW 镜像里 `.debug_*` 就是这个值
//   （INITIALIZED_DATA | READ | DISCARDABLE）—— DISCARDABLE 表示"可丢弃"，也正因如此它们**不参与加载**，
//   所以 I1 的扫描域必须排除它们（DWARF 的 set_address 写的就是绝对地址）。
#define DBG_CHAR        0x42000040
#define MANIFEST_XML \
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" \
  "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n" \
  "  <trustInfo xmlns=\"urn:schemas-microsoft-com:asm.v3\">\n" \
  "    <security>\n" \
  "      <requestedPrivileges>\n" \
  "        <requestedExecutionLevel level=\"requireAdministrator\" uiAccess=\"false\" />\n" \
  "      </requestedPrivileges>\n" \
  "    </security>\n" \
  "  </trustInfo>\n" \
  "</assembly>\n"

static uint32_t align_up(uint32_t v, uint32_t a) {
  return (v + a - 1) / a * a;
}

// v1.4.13：**节总数与头大小的单点定义**（pe.c 与 main.c 的 TSV 都调这里 —— 两处各算一遍 = 迟早不一致）
//   节表顺序：.text[+.data][+.rsrc] + **.idata** + [3 个 .debug_*]
int pe_nsec_all(int two_sec, int has_admin, int has_debug) {
  return (two_sec ? 2 : 1) + (has_admin ? 1 : 0) + 1 + (has_debug ? 3 : 0);
}
// SizeOfHeaders 必须 ≥ 头部实际长度（DOS 0x40 ＋ "PE\0\0" 4 ＋ COFF 20 ＋ 可选头 0xF0 ＋ 节表 n*40），
//   再向上对齐到 FileAlignment；下限保持 0x200（既有产物形态一个字节不变）。
uint32_t pe_headers_size(int nsec_all) {
  uint32_t v = align_up(0x148 + (uint32_t)nsec_all * 40, FILE_ALIGN);
  return v < HEADER_SIZE ? HEADER_SIZE : v;
}

static void w8(Buf *b, uint8_t x) { buf_byte(b, x); }
static void w16(Buf *b, uint16_t x) { buf_byte(b, x & 0xFF); buf_byte(b, (x >> 8) & 0xFF); }
static void w32(Buf *b, uint32_t x) { buf_u32(b, x); }
static void w64(Buf *b, uint64_t x) { buf_u64(b, x); }
static void wz(Buf *b, size_t n) { for (size_t i = 0; i < n; i++) buf_byte(b, 0); }

static void dos_header(Buf *b) {
  w16(b, 0x5A4D); // 'M''Z'
  wz(b, 0x3A);
  w32(b, 0x40);   // e_lfanew
}

static void coff_header(Buf *b, int nsections, uint32_t ptr_symtab, uint32_t nsyms) {
  w16(b, 0x8664);            // Machine: x64
  w16(b, (uint16_t)nsections);// NumberOfSections
  w32(b, 0);                 // TimeDateStamp
  // v1.4.11（`-debug`）：PE 规范说镜像里 `PointerToSymbolTable` "should be zero"（COFF 调试信息已废弃），
  //   但**节名 >8 字符时只能靠字符串表**，而字符串表只能通过这个指针找到 —— GNU ld 明知故犯
  //   （`ld.bfd(1)` 原话：GDB relies on the use of PE long section names to find Dwarf-2 debug
  //   information sections in an executable image at runtime）。实测 `NumberOfSymbols=0` +
  //   指针指向裸字符串表即可（不需要任何符号记录）。非 `-debug` 时两者恒为 0 ⇒ 既有产物不变。
  w32(b, ptr_symtab);        // PointerToSymbolTable（-debug 时 = 字符串表文件偏移）
  w32(b, nsyms);             // NumberOfSymbols（恒 0：只要字符串表，不要符号记录）
  w16(b, 0xF0);              // SizeOfOptionalHeader
  w16(b, 0x0022);            // Characteristics
}

static void opt_header(Buf *b, uint32_t size_of_image, uint32_t size_of_code,
                       uint32_t size_of_init_data, uint32_t size_of_headers,
                       uint32_t import_rva, uint32_t import_size,
                       uint32_t rsrc_rva, uint32_t rsrc_size,
                       uint32_t iat_rva, uint32_t iat_size,
                       uint32_t entry_rva, uint16_t subsystem) {
  w16(b, 0x20B);             // Magic: PE32+
  w8(b, 0); w8(b, 0);        // Linker 版本
  w32(b, size_of_code);      // SizeOfCode（.text 的 SizeOfRawData）
  w32(b, size_of_init_data); // SizeOfInitializedData（v1.3.0：.data 的 SizeOfRawData）
  w32(b, 0);                 // SizeOfUninitializedData
  // ⚠️ 入口点与 BaseOfCode 现在由调用方传入（entry_rva，v1.3.3 起）——原先把 TEXT_RVA 写死在这里，
  //   一旦将来调换节序就会让入口指到 .data（立刻崩）。抽成参数后，pe_build 里的 I7 断言就有独立对象可查。
  w32(b, entry_rva);         // AddressOfEntryPoint（代码开头 = main）
  w32(b, entry_rva);         // BaseOfCode
  w64(b, IMAGE_BASE);        // ImageBase
  w32(b, SEC_ALIGN);         // SectionAlignment
  w32(b, FILE_ALIGN);        // FileAlignment
  w16(b, 6); w16(b, 0);      // OS 版本 6.0
  w16(b, 0); w16(b, 0);      // Image 版本
  w16(b, 6); w16(b, 0);      // Subsystem 版本 6.0
  w32(b, 0);                 // Win32VersionValue
  w32(b, size_of_image);     // SizeOfImage
  w32(b, size_of_headers);   // SizeOfHeaders（v1.4.13：自适应 —— 必须真的盖住"DOS头+PE头+可选头+节表"）
  w32(b, 0);                 // CheckSum
  // v1.4.28（`-gui`）：Subsystem 改由调用方传入 —— 2 = WINDOWS_GUI（双击不弹控制台黑窗）／
  //   3 = CONSOLE（默认，既有产物形态不变）。这是本开关**唯一**改动的字段：
  //   同一样本加/不加 `-gui` 的产物只差这一个字（判据见 `test\wx-verify.ps1` [8] 节）。
  w16(b, subsystem);         // Subsystem: 2 = GUI（-gui）／3 = CONSOLE（默认）
  // ⚠️ 实测更正（2026-09-14，见「新路候选.md」§1.1 事实 3）：ASLR 位**不是**正确性前提 ——
  //   产物只含 RIP 相对寻址 + RVA 差值（IMAGE_BASE 从未烧进任何一条指令），本来就是位置无关的：
  //   把 DllCharacteristics 开成 DYNAMIC_BASE、甚至改 ImageBase，产物行为都不变（已实测）。
  //   DllCharacteristics 见下方 I20/I21（v1.4.14 起 = 0x0160）。
  w16(b, 0x0160);            // DllCharacteristics: DYNAMIC_BASE|HIGH_ENTROPY_VA|NX_COMPAT（v1.4.14 开 ASLR）
  w64(b, 0x100000);          // SizeOfStackReserve
  w64(b, 0x1000);            // SizeOfStackCommit
  w64(b, 0x100000);          // SizeOfHeapReserve
  w64(b, 0x1000);            // SizeOfHeapCommit
  w32(b, 0);                 // LoaderFlags
  w32(b, 16);                // NumberOfRvaAndSizes
  for (int i = 0; i < 16; i++) {
    if (i == 1) { w32(b, import_rva); w32(b, import_size); } // [1] Import
    else if (i == 2) { w32(b, rsrc_rva); w32(b, rsrc_size); } // [2] Resource（v1.4.6：-admin 时指向 .rsrc）
    // ▶ [12] IAT（v1.4.13 **必须给**）：实测结论 —— IAT 与导入目录**不同页**时（本轮把它挪进 `.idata`），
    //   本机 Windows loader 靠这个目录定位"要临时放开的页"；不给 ⇒ 导入解析直接 0xC0000005
    //   （证据：探针实测 .idata 页全程 READONLY 未被放开、样本退出码 -1073741819）。
    //   ⚠️ 与 2026-09-17 上半场那条"不是 must"不矛盾：IAT 与导入目录**同页**时不给也能跑（实测），
    //   **跨页**时才必需 —— 也就是"规范没有 must" ≠ "任何形态都不需要它"。
    else if (i == 12) { w32(b, iat_rva); w32(b, iat_size); } // [12] IAT
    else { w32(b, 0); w32(b, 0); }
  }
}

// v1.3.0：节表头参数化（名字/RVA/特征），供 .text 与 .data 两节复用
static void section_header(Buf *b, const char *name, uint32_t virtual_size,
                           uint32_t rva, uint32_t size_of_raw, uint32_t raw_ptr,
                           uint32_t characteristics) {
  char nm[8];
  memset(nm, 0, sizeof(nm));
  size_t nl = strlen(name);
  if (nl > 8) nl = 8;
  memcpy(nm, name, nl);
  buf_bytes(b, (const uint8_t *)nm, 8);
  w32(b, virtual_size);      // VirtualSize
  w32(b, rva);               // VirtualAddress
  w32(b, size_of_raw);       // SizeOfRawData
  w32(b, raw_ptr);           // PointerToRawData
  w32(b, 0);                 // PointerToRelocations（产物无绝对地址 ⇒ 不需要任何重定位；由 I1 断言守）
  w32(b, 0);                 // PointerToLinenumbers
  w16(b, 0);                 // NumberOfRelocations
  w16(b, 0);                 // NumberOfLinenumbers
  w32(b, characteristics);
}

// —— 导入模块（一个 DLL 一组）——
typedef struct {
  char dll[64];        // 模块文件名（如 kernel32.dll）
  int nfuncs;          // 本模块函数数
  char *names[MAX_IMPORTS]; // 函数名
} ImpGroup;

// —— v1.4.28（B1-3）：导入模块名（写出名）的**长度口径单点** ——
// 为什么需要它：上面 ImpGroup.dll 是 char[64]，写出端用 snprintf 落名字 ⇒ 名字超过
//   IMPORT_DLL_NAME_MAX 字节会**静默截断**成"半个路径"的导入表：编译期零提示，
//   进程启动期才炸 0xC0000135（STATUS_DLL_NOT_FOUND）。
//   实测（本刀）：70 个 'A' 的模块名编译 exit 0，产物文件里只剩 63 个 'A'，运行即 0xC0000135。
// 判据（写出端与 parse.c 的默认档守卫**共用这一份**，别再抄第二遍）：
//   名字里含 '.' / '\' / '/' → 原样写；否则补 ".dll"（裸短名行为不变）。
//   注：原写出端把 kernel32 / user32 / gdi32 三条短名单独写成特例，结果与这条通用判据逐字节相同
//   （三个名字都不含 . \ /），故合并成一条 —— 行为等价由等价门/差分门守住。
int pe_import_module_name_len(const char *declared) {
  int n = (int)strlen(declared);
  if (strchr(declared, '.') || strchr(declared, '\\') || strchr(declared, '/'))
    return n;                  // 全名 / 带路径：原样写（出端不补后缀）
  return n + 4;                // 裸短名：补 ".dll"
}

// 把最终写进导入表的名字格式化进 out（cap 至少 = pe_import_module_name_len(declared) + 1）
void pe_import_module_name(const char *declared, char *out, size_t cap) {
  if (strchr(declared, '.') || strchr(declared, '\\') || strchr(declared, '/'))
    snprintf(out, cap, "%s", declared);
  else
    snprintf(out, cap, "%s.dll", declared);
}

static void group_add(ImpGroup *g, const char *name) {
  g->names[g->nfuncs++] = strdup(name);
}

// —— v1.4.6：写 `.rsrc` 节内容（资源树 + 清单正文）——
// 只发一条最简资源链：TYPE=24(RT_MANIFEST) → NAME=1 → LANG=0x409 → 数据项 → 清单。
// 布局见文件上方 RSRC_* 注释块；这里**顺序追加**，故调用前必须已经把 out 垫到 .rsrc 的文件偏移。
static void rsrc_write(Buf *b, uint32_t rsrc_rva) {
  const uint32_t mlen = (uint32_t)strlen(MANIFEST_XML);

  // 根目录（0x00）：NumberOfIdEntries=1
  w32(b, 0); w32(b, 0); w16(b, 0); w16(b, 0); w16(b, 0); w16(b, 1);
  // 目录项（0x10）：Type=RT_MANIFEST(24) → 二层目录偏移 0x18
  w32(b, 24); w32(b, 0x80000000u | 0x18u);
  // 二层目录（0x18）
  w32(b, 0); w32(b, 0); w16(b, 0); w16(b, 0); w16(b, 0); w16(b, 1);
  // 目录项（0x28）：Name=1（CREATEPROCESS_MANIFEST_RESOURCE_ID）→ 三层目录偏移 0x30
  w32(b, 1); w32(b, 0x80000000u | 0x30u);
  // 三层目录（0x30）
  w32(b, 0); w32(b, 0); w16(b, 0); w16(b, 0); w16(b, 0); w16(b, 1);
  // 目录项（0x40）：Lang=0x409 → 数据项偏移 0x48（**不带**目录高位标志）
  w32(b, RSRC_LANG); w32(b, 0x48u);
  // 数据项（0x48）：清单的 RVA + 长度
  w32(b, rsrc_rva + RSRC_MF_OFF); w32(b, mlen); w32(b, 0); w32(b, 0);
  // 清单正文（0x58）
  buf_bytes(b, (const uint8_t *)MANIFEST_XML, mlen);
}

// —— 主入口：打包成 exe ——
// 布局（RVA）：.text 0x1000 起 = code（含字符串/double 常量区）→ 导入描述符区 → 各模块
// （INT / IAT / Hint/Name / DLL 名）；.data **紧贴 .text 之后**（两节虚拟地址必须连续，见文件头）。
// 回填：gen->disp_off（ExitProcess）→ 槽 0；gen->api_sites → 各自 API 的槽；
//   gen->guses → 各全局变量 `[rip+disp32]`（**必须在本函数回填**：.data 的 RVA 取决于 .text 大小）。
int pe_build(GenResult *gen, Buf *out, char **err) {
  buf_init(out);
  if (err) *err = NULL;

  const uint32_t code_len = (uint32_t)gen->code.len;

  // —— 1. 组装模块表：组 0 = kernel32（ExitProcess + kernel32 系 API）；其余按声明序 ——
  ImpGroup groups[MAX_GROUPS];
  int ngroups = 0;
  int api_slot[MAX_IMPORTS];   // apis[i] → 全局 IAT 槽序（= 组基址 + 组内序，S1 修复后）
  int api_group[MAX_IMPORTS];  // apis[i] → 所在导入组下标（组装循环记录）
  int api_pos[MAX_IMPORTS];    // apis[i] → 组内函数序（0 起；组 0 的 ExitProcess 占 0）
  int total = 0;

  memset(groups, 0, sizeof(groups));
  snprintf(groups[0].dll, sizeof(groups[0].dll), "kernel32.dll");
  group_add(&groups[0], "ExitProcess");
  ngroups = 1;
  total = 1;                   // 槽 0 = ExitProcess

  for (int i = 0; i < gen->napis; i++) {
    ApiDef *a = &gen->apis[i];
    char fn[64];
    // v1.4.8：全名 / 带路径（含 '.' / '\' / '/'）→ 原样用；裸短名 → 补 ".dll"（行为不变）。
    // v1.4.28（B1-3）：判据搬进 pe_import_module_name（单点，与 parse.c 的守卫共用一份）。
    pe_import_module_name(a->dll, fn, sizeof(fn));
    int gi = -1;
    for (int g = 0; g < ngroups; g++)
      if (strcmp(groups[g].dll, fn) == 0) { gi = g; break; }
    if (gi < 0) {
      if (ngroups >= MAX_GROUPS) { if (err) *err = "导入模块超过 8 个"; return -1; }
      gi = ngroups;
      snprintf(groups[gi].dll, sizeof(groups[gi].dll), "%s", fn);
      ngroups++;
    }
    ImpGroup *g = &groups[gi];
    if (g->nfuncs >= MAX_IMPORTS || total >= MAX_IMPORTS) {
      if (err) *err = "导入函数总数超过上限 " STR(MAX_IMPORTS) "（见 pe.c MAX_IMPORTS）";
      return -1;
    }
    api_group[i] = gi;
    api_pos[i] = g->nfuncs;   // 组内追加位置（组 0 的 ExitProcess 已占 0）
    group_add(g, a->import_name ? a->import_name : a->name);   // v1.1.0：导入表写真名
    total++;
  }

  // —— S1 修复（v0.9.1）：api_slot 按「组基址 + 组内序」算，与下方布局的组内连续排位同构 ——
  // 旧实现按声明序记 total（api_slot[i]=total），布局却按组连续排 iat_slot_rva，
  // 跨 DLL 交错声明（如 user32 API 声明在 kernel32 API 之前）时回填错位：
  //  GetSystemMetrics 的调用点会指向 GetTickCount 的 IAT 槽 → 正常程序静默调错函数。
  // 组 0 基址 0 且含 ExitProcess（组内位置 0 = 全局槽 0），与 iat_slot_rva 排布完全一致。
  {
    int base_slot[MAX_GROUPS];
    base_slot[0] = 0;
    for (int g = 1; g < ngroups; g++)
      base_slot[g] = base_slot[g - 1] + groups[g - 1].nfuncs;
    for (int i = 0; i < gen->napis; i++)
      api_slot[i] = base_slot[api_group[i]] + api_pos[i];
  }

  // —— 2. 纯计算布局（Buf 顺序写，先全部算好）——
  // 各模块布局 RVA
  uint32_t mod_int_rva[MAX_GROUPS], mod_iat_rva[MAX_GROUPS];
  uint32_t mod_dll_rva[MAX_GROUPS];                    // desc Name 字段用
  uint32_t hint_item_rva[MAX_GROUPS][MAX_IMPORTS]; // 模块 g 内函数 f 的 hintname RVA
  uint32_t iat_slot_rva[MAX_IMPORTS];              // 全局槽序 → IAT 槽 RVA

  uint32_t cursor = align_up(TEXT_RVA + code_len, 8);
  uint32_t desc_rva = cursor;
  uint32_t desc_bytes = (uint32_t)(ngroups + 1) * 20;
  cursor += desc_bytes;

  // v1.4.13：**IAT 不再排在 `.text` 里** —— 本节只留导入描述符 + INT + hintname + DLL 名（全是只读数据）。
  //   IAT 的 RVA 要等 `.data`/`.rsrc` 的几何定下来才能算（见下方 `idata_rva` 块）：它自成 `.idata` 节。
  for (int g = 0; g < ngroups; g++) {
    ImpGroup *grp = &groups[g];
    mod_int_rva[g] = cursor;
    cursor += (uint32_t)(grp->nfuncs + 1) * 8;
    for (int f = 0; f < grp->nfuncs; f++) {
      hint_item_rva[g][f] = cursor;
      cursor += 2 + (uint32_t)strlen(grp->names[f]) + 1;
    }
    mod_dll_rva[g] = cursor;
    cursor += (uint32_t)strlen(grp->dll) + 1;
  }
  uint32_t text_end = cursor;
  // ⚠️ VirtualSize 必须覆盖**整个 .text 内容**（代码 + 描述符区 + 导入表），而不是只有代码。
  //   🐞 这里踩过一次真坑（实测，全局变量落地时才炸）：原用 `align_up(text_end - TEXT_RVA, 8)`
  //   把「布局游标（末尾）」当成了「代码长度」→ .text 只声明约 0x120 字节，
  //   于是下方 `.data` 的文件偏移跟着算早了，**直接压在 .text 的代码中段上**
  //   （实测 garr[2] 的赋值被 `.data` 的零字节覆盖成 no-op，全局累加静默错值）。
  //   两个关联错误同源：**把「声明尺寸」当成「实际占用」**——改这类布局代码时两边都要对。
  uint32_t text_vsize = align_up(text_end - TEXT_RVA, 8);
  uint32_t text_raw_size = align_up(text_vsize, FILE_ALIGN);

  // ⚠️ v1.3.0 硬约束：代码不得越过上限（见 flint.h FLINT_MAX_TEXT）。
  //   越过就会与 .data 的地址重叠 → 全局变量指到代码字节上（静默错值）。宁可编译期拦下。
  if (text_vsize > FLINT_MAX_TEXT) {
    if (err) *err = "代码段超过 1 MiB 上限（FLINT_MAX_TEXT）——请精简代码";
    return -1;
  }

  // —— .data 的 RVA：**紧贴 .text 之后**（两节虚拟地址必须连续）——
  //   这是本项工程实测出来的硬规律：`.data` 的 RVA 写死成 0x2000/0x3000/0x4000/0x100000 时，
  //   只有「恰好紧贴 .text」（两节之间无空洞）那一种 Windows 肯加载，其余一律报
  //   「指定的可执行文件不是此操作系统的有效应用程序」。所以这里按 .text 的实际虚拟大小推。
  // v1.4.13：**头部实际长度** = 0x148 + 节表(n*40)，向上对齐到 FileAlignment（下限 0x200）——
  //   单点算式 = pe_headers_size()（main.c 的 TSV 也调它）。这里必须**提前**算出来：文件布局
  //   （.text 的起始偏移 = 头大小）比 NSEC_ALL 原来的声明位置更早就要用到。
  const int nsec_pre = pe_nsec_all(gen->data_size > 0 ? 1 : 0, gen->want_admin != 0, gen->want_debug != 0);
  const uint32_t hdr_size = pe_headers_size(nsec_pre);
  const uint32_t text_file_end = hdr_size + text_raw_size;      // .text 占用的文件末尾
  const uint32_t data_raw_ptr = align_up(text_file_end, FILE_ALIGN);   // .data 的文件偏移（排在 .text 之后）
  const uint32_t data_rva = TEXT_RVA + align_up(text_vsize, SEC_ALIGN);
  const uint32_t data_vsize = (uint32_t)gen->data_size;   // 恒为 SEC_ALIGN 的整数倍（parse 已取整）
  const uint32_t data_raw_size = data_vsize ? align_up(data_vsize, FILE_ALIGN) : 0;
  const int TWO_SEC = data_vsize > 0;   // 没有全局变量就仍是单节（保持既有产物形态不变）

  // —— v1.4.6：`.rsrc`（第三节）布局 —— 只在 `-admin` 时发，默认分支一个字节都不多 ——
  //   位置口径与 .data 同一套：RVA 紧贴前一节末尾（按 SEC_ALIGN 取整），文件偏移紧跟前一节原始字节之后
  //   （按 FILE_ALIGN 取整）。⚠️ 这里**不能**复用 data_raw_ptr 的"写死常量"式假设（见上方 .data 的
  //   历史真 bug：文件布局由实际内容长度决定，RVA 布局由 SEC_ALIGN 决定，两者是两件事）。
  const int HAS_ADMIN = gen->want_admin != 0;
  const uint32_t rsrc_vsize    = HAS_ADMIN ? align_up(RSRC_SIZE_MIN + (uint32_t)strlen(MANIFEST_XML), 8) : 0;
  const uint32_t rsrc_raw_size = HAS_ADMIN ? align_up(rsrc_vsize, FILE_ALIGN) : 0;
  const uint32_t rsrc_rva      = HAS_ADMIN ? (data_rva + align_up(data_vsize, SEC_ALIGN)) : 0;
  const uint32_t rsrc_raw_ptr  = HAS_ADMIN ? align_up(data_raw_ptr + data_raw_size, FILE_ALIGN) : 0;
  const int NSEC = (TWO_SEC ? 2 : 1) + (HAS_ADMIN ? 1 : 0);

  // —— v1.4.11：`-debug` 产物形态开关（默认 0 ⇒ 下面所有分支一个字节都不多）——
  //   落地的三个阶段（见 `开工简报-可审计发射层.md` / `调研②-DWARF最小集实测.md`）：
  //     ① 三个 `.debug_*` 节排在**所有参与加载的节之后**（RVA 与文件偏移都升序紧邻，规范 must）；
  //     ② 节名走 `/nnn` 长名形式 —— PE 镜像不支持 >8 字符的节名（规范明文），GNU ld 的做法是
  //        在镜像里追加一张**字符串表**并把 COFF 头的 PointerToSymbolTable 指过去；
  //     ③ 实测（受控删改变体）：**不需要任何符号记录**，`NumberOfSymbols=0` + 指针指向裸字符串表即可。
  const int HAS_DEBUG = gen->want_debug != 0;

  // —— 「参与加载的节」的文件末尾 = I1 的扫描域上界（v1.4.11 新增）——
  //   为什么需要它：`.debug_*` 是 `MEM_DISCARDABLE`、不参与加载、loader 不重定位它们，
  //   而 DWARF 里 `DW_LNE_set_address` **必须**写绝对地址（实测 GCC 产物里是 `0x140001760`）
  //   ⇒ I1（扫「指向本镜像的绝对地址」）若不排除这些节，会在**每个**带调试信息的产物上误报。
  //   这不是放水：不变量管的是「**被加载的镜像**位置无关」；未加载节里的地址不构成任何重定位需求。
  const uint32_t text_file_end_all = hdr_size + text_raw_size;
  const uint32_t data_file_end     = TWO_SEC   ? (data_raw_ptr + data_raw_size)   : 0;
  const uint32_t rsrc_file_end     = HAS_ADMIN ? (rsrc_raw_ptr + rsrc_raw_size)   : 0;
  uint32_t loaded_file_end = text_file_end_all;
  if (data_file_end > loaded_file_end) loaded_file_end = data_file_end;
  if (rsrc_file_end > loaded_file_end) loaded_file_end = rsrc_file_end;

  // ========== v1.4.13：`.idata` —— **IAT 独立成节**（只读、不可执行） ==========
  // 动机（有实测证据，见 `PROGRESS.md` 的 W^X 轮记录）：IAT 原排在 `.text` 里 ⇒ 加载期 loader 往 IAT
  //   写解析结果时必须把**整个代码页**临时改成可写一次（探针 `libcs\wxprobe\` 抓到了那个 `READWRITE`
  //   窗口）。IAT 挪进自己的节后，**被临时放开的只有这个非执行页**，代码页全程 R|X。
  // 位置：排在**所有参与加载的节之后**（`.text` / `.data` / `.rsrc` 的 RVA 一点没动）⇒ 全局变量的
  //   `[rip+disp32]` 不用重算、产物差异面最小；仍在三个 `.debug_*` 节之前（升序 + 紧邻是规范 must）。
  // 形态：每组一个 IAT 块（`(nfuncs+1)*8`，末项 0 终止），**按组序连续**排（一个节必须是一段连续字节）。
  //   特征位 = `READ|INITIALIZED_DATA`（照抄 `.rsrc`）：只读不执行；loader 写完自己还原保护（已实测）。
  const uint32_t prev_loaded_vend = HAS_ADMIN ? (rsrc_rva + rsrc_vsize)
                                  : (TWO_SEC ? (data_rva + data_vsize) : (TEXT_RVA + text_vsize));
  const uint32_t idata_rva = align_up(prev_loaded_vend, SEC_ALIGN);
  uint32_t idata_end_rva = idata_rva;
  {
    int sc = 0;
    uint32_t ic = idata_rva;
    for (int g = 0; g < ngroups; g++) {
      ImpGroup *grp = &groups[g];
      mod_iat_rva[g] = ic;
      ic += (uint32_t)(grp->nfuncs + 1) * 8;
      for (int f = 0; f < grp->nfuncs; f++)
        iat_slot_rva[sc++] = mod_iat_rva[g] + (uint32_t)f * 8;
    }
    idata_end_rva = ic;
  }
  const uint32_t idata_vsize    = align_up(idata_end_rva - idata_rva, 8);
  const uint32_t idata_raw_size = align_up(idata_vsize, FILE_ALIGN);
  const uint32_t idata_raw_ptr  = align_up(loaded_file_end, FILE_ALIGN);
  // `.idata` 也是**参与加载**的节 ⇒ 计入 I1 扫描域上界（下面的 debug 块正用它推文件偏移）
  if (idata_raw_ptr + idata_raw_size > loaded_file_end) loaded_file_end = idata_raw_ptr + idata_raw_size;

  // —— v1.4.11 `-debug`：三个 DWARF 节 + 一张 COFF 字符串表 ——
  //   ① 三个节排在**所有参与加载的节之后**（RVA 与文件偏移都升序紧邻 —— PE 规范 must 的三条：
  //      升序 / 紧邻 / SEC_ALIGN 倍数）；
  //   ② 节名走 **`/nnn` 长名**：PE 镜像不支持 >8 字符的节名（规范明文），GNU ld 的做法是在镜像里
  //      追加一张**字符串表**（`[u32 总长][名字\0…]`，首个名字在偏移 4）并把 COFF 头的
  //      `PointerToSymbolTable` 指过去；实测（受控删改变体）**不需要任何符号记录**：
  //      `NumberOfSymbols=0` + 指针指向裸字符串表即可被 bfd/gdb 正确解析。
  //   ③ 特征位照抄实测值 0x42000040（INITIALIZED_DATA|READ|DISCARDABLE）—— 不参与加载、可丢弃。
  Buf dbg_line, dbg_info, dbg_abbrev;
  uint32_t dbg_line_rva = 0, dbg_info_rva = 0, dbg_abbrev_rva = 0;
  uint32_t dbg_line_raw = 0, dbg_info_raw = 0, dbg_abbrev_raw = 0;
  uint32_t dbg_line_vs = 0, dbg_info_vs = 0, dbg_abbrev_vs = 0;
  uint32_t dbg_line_rs = 0, dbg_info_rs = 0, dbg_abbrev_rs = 0;
  uint32_t strtab_off = 0, strtab_size = 0;
  uint32_t name_off_line = 0, name_off_info = 0, name_off_abbrev = 0;
  if (HAS_DEBUG) {
    debug_build_abbrev(&dbg_abbrev);
    debug_build_line(gen, TEXT_RVA, &dbg_line);
    debug_build_info(gen, TEXT_RVA, 0, &dbg_info);
    dbg_line_vs   = (uint32_t)dbg_line.len;
    dbg_info_vs   = (uint32_t)dbg_info.len;
    dbg_abbrev_vs = (uint32_t)dbg_abbrev.len;
    dbg_line_rs   = align_up(dbg_line_vs, FILE_ALIGN);
    dbg_info_rs   = align_up(dbg_info_vs, FILE_ALIGN);
    dbg_abbrev_rs = align_up(dbg_abbrev_vs, FILE_ALIGN);
    // RVA：从最后一个已加载节之后按 SEC_ALIGN 逐节紧贴
    // v1.4.13：`.idata` 现在是**最后一个参与加载的节** ⇒ 调试节必须紧贴它之后（升序 + 紧邻是规范 must）
    uint32_t prev_rva = idata_rva + idata_vsize;
    dbg_line_rva   = align_up(prev_rva, SEC_ALIGN);
    dbg_info_rva   = align_up(dbg_line_rva + dbg_line_vs, SEC_ALIGN);
    dbg_abbrev_rva = align_up(dbg_info_rva + dbg_info_vs, SEC_ALIGN);
    // 文件偏移：从最后一个已加载节的原始数据之后逐节紧贴
    dbg_line_raw   = align_up(loaded_file_end, FILE_ALIGN);
    dbg_info_raw   = dbg_line_raw + dbg_line_rs;
    dbg_abbrev_raw = dbg_info_raw + dbg_info_rs;
    strtab_off     = dbg_abbrev_raw + dbg_abbrev_rs;
    // 字符串表：总长（含 4 字节长度字段）+ 名字串；名字偏移从 4 起
    const char *nm_line = ".debug_line", *nm_info = ".debug_info", *nm_abbrev = ".debug_abbrev";
    name_off_line   = 4;
    name_off_info   = name_off_line   + (uint32_t)strlen(nm_line) + 1;
    name_off_abbrev = name_off_info   + (uint32_t)strlen(nm_info) + 1;
    strtab_size     = name_off_abbrev + (uint32_t)strlen(nm_abbrev) + 1;
  }

  // SizeOfImage —— 规范（MSDN PE Format，`SizeOfImage` 字段）：**must be a multiple of SectionAlignment**
  //   ⚠️ 2026-09-15 调研①查规范后修正（此前是既存静默 bug）：原式 `TEXT_RVA + text_vsize`
  //   **没有按 SEC_ALIGN 取整** —— 双节时天然对齐（data_rva 与 data_vsize 都是 0x1000 的倍数），
  //   但**单节且 .text 超过一页**时漏（实测 69 个产物里 8 个违规：main.exe 0x7008 / student.exe 0x6440 /
  //   dblcmp1 等 6 个 double 样本）。加载器不挑（自己按页映射，所以能跑），但违反规范明文。
  //   附带修好 I1 的扫描上限：此前 hi = IMAGE_BASE + size_of_image 小于镜像页尾
  //   → 落在"真实大小之外、页尾之内"的绝对地址 I1 抓不到；取整后 hi 覆盖整个映射区间。
  uint32_t size_of_image = data_vsize ? (data_rva + data_vsize) : (TEXT_RVA + text_vsize);
  if (HAS_ADMIN && rsrc_rva + rsrc_vsize > size_of_image) size_of_image = rsrc_rva + rsrc_vsize;
  // v1.4.13：`.idata` 也参与加载 ⇒ 必须计入 SizeOfImage
  if (idata_rva + idata_vsize > size_of_image) size_of_image = idata_rva + idata_vsize;
  // v1.4.11：三个 `.debug_*` 节也有 VA、也在镜像里（规范要求节 VA 升序紧邻），所以必须计入 SizeOfImage
  if (HAS_DEBUG && dbg_abbrev_rva + dbg_abbrev_vs > size_of_image)
    size_of_image = dbg_abbrev_rva + dbg_abbrev_vs;
  size_of_image = align_up(size_of_image, SEC_ALIGN);

  // 节总数 = 参与加载的节（.text[+.data][+.rsrc] ＋ **.idata**）＋ 3 个调试节
  //   v1.4.13：`.idata` **恒存在**（产物永远导入 ExitProcess）⇒ 无条件 +1
  const int NSEC_ALL = NSEC + 1 + (HAS_DEBUG ? 3 : 0);

  // —— 产物标识量：各自独立取名（便于断言，也便于将来把入口点与节 RVA 分开）——
  const uint32_t entry_rva     = TEXT_RVA;      // AddressOfEntryPoint / BaseOfCode（= main 代码开头）
  const uint32_t text_sec_va   = TEXT_RVA;      // 第一节 .text 的 VirtualAddress
  const uint32_t TEXT_SEC_CHAR = 0x60000020;    // 第一节 .text 的 Characteristics：CODE|EXECUTE|READ
  const uint32_t DATA_SEC_CHAR = 0xC0000040;    // .data 的 Characteristics：INITIALIZED_DATA|READ|WRITE
  // v1.4.13 `.idata`（IAT 独立成节）：特征位照抄 `.rsrc` —— READ|INITIALIZED_DATA，**不可执行**
  //   （W^X：IAT 是数据，不需要 X；loader 写它之前会自己临时放开、写完还原，已实测）
  const uint32_t IDATA_SEC_CHAR = 0x40000040;

  // ========== v1.4.12（W^X 轮次）：节权限 = 硬化子集策略（现状 + 实测证据，2026-09-17） ==========
  // 声明侧：.text = CODE|EXECUTE|READ ／ .data = INIT_DATA|READ|WRITE ／ .rsrc = INIT_DATA|READ ／
  //   .debug_* = INIT_DATA|READ|DISCARDABLE（不参与加载）⇒ **没有任何节同时 W|X**。
  // 运行侧（探针 `libcs\wxprobe\`：挂起创建 → 读远程镜像头 → `VirtualQueryEx` 逐节采样）：
  //   .text 实际 = `PAGE_EXECUTE_READ`、.data 实际 = `PAGE_WRITECOPY`、IAT 页稳态 = `PAGE_EXECUTE_READ`；
  //   加载瞬态（`ResumeThread` 后 200ms 内 **90908 次**采样）抓到过 `READWRITE(0x004)` —— 那是 loader
  //   往**不可写**的 IAT 页写解析结果时临时放开、写完还原 ⇒ **任意采样时刻都没有 W|X 同页**。
  // ⚠️ 诚实边界（两条已知缺口，别当成已解决）：
  //   ① IAT 排在 .text 里 ⇒ 加载期 loader 必须把**整个代码页**临时改成可写一次（实测抓到了）。
  //      窗口是"有 W 无 X"（不违反 W^X），但代码页确实被放开过；要关掉它只能把 IAT 挪到独立的
  //      只读节（`.idata`）—— 属待拍板的后续项（布局/I1 扫描域/门都要跟着改）。
  //   ② **不提供 IAT 数据目录（index 12）**：调研阶段曾判"IAT 在只读节 ⇒ 必须有 index 12"，
  //      2026-09-17 本机实测**推翻**（不给也照样解析导入、写完还原保护），MSDN PE 规范对该目录
  //      只写"地址与大小"、**没有 must**（原文已抓取核对）；GNU ld 会写（本机实测 size=0x200）。
  //      本轮拍板 = 只加断言、**零产物变化**（见任务卡 T-20260917-230135）。

  // ========== 产物不变量断言（v1.3.3：把只写在注释里的规律变成编译期检查） ==========
  // 依据 `新路候选.md` §4.2：8 条产物不变量里，此前只有 I5（代码上限）与 I8（决策 33 的 rsp≡0）有断言，
  // 其余 6 条只靠「写对 + 注释」，其中 5 条已真实发生过 bug（4 条静默错值 / 静默损坏）。
  // 本块把 I2 / I3 / I4 / I6 / I7 落成检查；机制与 I5 一致（err 出参 → main.c 打成
  // 「FLINT: PE 打包失败: …」）。
  // ⚠️ 设计纪律：断言必须写成「两个**独立**算出来的量之间的关系」（相等/覆盖），
  //    如果只是把左边的算式重述一遍，那它就是**永远不触发的装饰** —— 实验 3 会用变体逐个复核这一点。
  {
    // I2 两节虚拟地址必须"紧贴"：只允许按 SEC_ALIGN 向上取整，不得再有额外空隙。
    //    ⚠️ 2026-09-15 调研①修正：「留空隙 Windows 拒载」不是孤立的实测规律 —— MSDN PE Format 明文
    //    「In an image file, the VAs for sections must be assigned by the linker so that they are in
    //     ascending order and adjacent, and they must be a multiple of the SectionAlignment value」
    //    （即 **升序 + 紧邻 + SA 倍数** 三条一起是规范 must）。（原注释写"实测规律"，是因为当时没查到规范。）
    //    触发条件是**空隙本身**（SizeOfImage 与文件偏移两个混淆项已排除）。
    if (data_rva != align_up(TEXT_RVA + text_vsize, SEC_ALIGN)) {
      if (err) *err = "内部布局违规(I2)：.data 与 .text 之间出现额外虚拟地址空隙（Windows 会拒载）——请检查 data_rva 算式";
      return -1;
    }
    // I11（v1.4.6）三节同族：`.rsrc` 也必须紧贴前一节（升序 + 紧邻 + SA 倍数，PE 规范 must）。
    //    独立复算：这次从「前一节的**末尾**」按 SEC_ALIGN 取整推，而不是重述 rsrc_rva 的赋值式。
    if (HAS_ADMIN) {
      if (rsrc_rva != align_up(data_rva + data_vsize, SEC_ALIGN)) {
        if (err) *err = "内部布局违规(I11)：.rsrc 与前一节之间出现额外虚拟地址空隙（Windows 会拒载）——请检查 rsrc_rva 算式";
        return -1;
      }
      // I10（v1.4.6）资源链完整性：数据项必须**正好**收在清单正文之前，且清单不越出节尾。
      //    为什么值得断言：清单偏移写错时系统**静默忽略**整个资源（双击不提权、不报错），
      //    这类失败在回归里只能靠"产物字节"看出来 —— 而断言能在编译期直接拦下。
      const uint32_t mlen = (uint32_t)strlen(MANIFEST_XML);
      const uint32_t de_end = 0x48 + 16;                 // 数据项（0x48 起 16 字节）的末尾，独立再算一遍
      if (de_end != RSRC_MF_OFF || rsrc_rva + RSRC_MF_OFF + mlen > rsrc_rva + rsrc_vsize) {
        if (err) *err = "内部布局违规(I10)：资源数据项/清单正文越出 .rsrc 节（系统读不到清单→双击不提权且不报错）——请检查 RSRC_* 偏移与 rsrc_vsize 算式";
        return -1;
      }
    }
    // I3 节文件区间不得重叠：.data 必须正好排在 .text 文件末尾之后（按 FILE_ALIGN 取整）。
    //    🐞 历史真 bug：data_raw_ptr 写死 0x400 → .data 的零字节盖在 .text 代码中段
    //    （表现为"某个下标写了没效果"）；编译**静默通过**、产物 0xC0000005。
    if (data_raw_ptr != align_up(text_file_end, FILE_ALIGN)) {
      if (err) *err = "内部布局违规(I3)：.data 文件偏移不落在 .text 末尾之后（节文件区间重叠，会静默覆盖代码）——请检查 data_raw_ptr 算式";
      return -1;
    }
    // I4 .text 声明的 VirtualSize 必须覆盖**放进它里面的每一样东西**
    //    （代码 + 导入描述符区 + INT/IAT + hintname + dll 名）。
    //    ⚠️ 这里刻意**不复用布局游标 text_end**，而是按各结构的实际落点重新推一遍 need：
    //    独立算两遍，才能抓住「游标推进对了、但声明尺寸算错」这一类历史真 bug（VirtualSize 只声明约 0x120 字节）。
    uint32_t need = TEXT_RVA + code_len;
    if (desc_rva + desc_bytes > need) need = desc_rva + desc_bytes;
    for (int g = 0; g < ngroups; g++) {
      uint32_t dll_end = mod_dll_rva[g] + (uint32_t)strlen(groups[g].dll) + 1;
      if (dll_end > need) need = dll_end;
      for (int f = 0; f < groups[g].nfuncs; f++) {
        uint32_t hn_end = hint_item_rva[g][f] + 2 + (uint32_t)strlen(groups[g].names[f]) + 1;
        if (hn_end > need) need = hn_end;
      }
    }
    // v1.4.13：**IAT 已不在 .text 里**（挪进 `.idata`）⇒ 这条不再把 IAT 槽算进 .text 的 VirtualSize；
    //   IAT 的覆盖由下面的 I17 单独保证（若漏改一处让槽留在 .text，I17 会拒出产物）。
    if (TEXT_RVA + text_vsize < need) {
      if (err) *err = "内部布局违规(I4)：.text 的 VirtualSize 装不下节内结构（代码/导入描述符/导入表）——请检查 text_vsize 算式";
      return -1;
    }
    // I6 导入槽序必须与「声明所属模块组」同构（S1 修复的不变量）。
    //    🐞 历史真 bug：api_slot 按声明序记、布局却按组内连续排 → 跨 DLL 交错声明时
    //    调用点指向别人家的 IAT 槽（静默调错函数，最危险的一类）。
    for (int i = 0; i < gen->napis; i++) {
      uint32_t s = iat_slot_rva[api_slot[i]];
      uint32_t gbeg = mod_iat_rva[api_group[i]];
      uint32_t gend = gbeg + (uint32_t)groups[api_group[i]].nfuncs * 8;
      if (s < gbeg || s >= gend) {
        if (err) *err = "内部布局违规(I6)：导入槽序与声明模块组不同构（调用点会指向别的 IAT 槽、静默调错函数）——请检查 api_slot 算式";
        return -1;
      }
    }
    // I7 入口点必须落在第一节（.text）的虚拟区间内，且该节必须可执行。
    //    ⚠️ 诚实标注：这是本组里**最弱**的一条 —— 当前 entry_rva 与 text_sec_va 都取自 TEXT_RVA，天然成立。
    //    它的价值只在"将来有人调换节序 / 把这两个值拆开"时兜底（本轮已把它们抽成独立参数，使这条断言有对象可查）。
    {
      int in_range = (entry_rva >= text_sec_va) &&
                     ((uint64_t)entry_rva + 16 <= (uint64_t)text_sec_va + (uint64_t)text_vsize);
      int exec_ok  = (TEXT_SEC_CHAR & 0x20000000u) != 0;   // MEM_EXECUTE=0x20000000
      if (!in_range || !exec_ok) {
        if (err) *err = "内部布局违规(I7)：入口点不在可执行的第一节虚拟区间内——请检查节序与入口点算式";
        return -1;
      }
    }
    // I9 SizeOfImage 必须是 SectionAlignment 的整数倍。
    //    📖 规范依据（MSDN PE Format，SizeOfImage 字段）：「The size (in bytes) of the image, including
    //    all headers, as the image is loaded in memory. **It must be a multiple of SectionAlignment.**」
    //    加上它的**非重述**部分：镜像**页尾必须落在 SizeOfImage 之内** —— 内存里 0x140000000+SizeOfImage
    //    往上到页边界那段虽然加载器会映射，但不属于"声明的镜像"；I1（扫发射字节找绝对地址）正是拿
    //    SizeOfImage 当扫描上界，所以这条同时护住 I1 的**完备性**（页尾那段漏扫会让 I1 假绿）。
    //    🐞 历史真 bug（2026-09-15 调研①按规范复核 69 个产物时抓到）：单节分支的 size_of_image
    //    没按 SEC_ALIGN 取整 → 8/69 产物违反 must（main.exe 0x7008、student.exe 0x6440、
    //    dblcmp1/dblcompound1/dblconst1/dblfield1/dblparam1/dblprint1）；能跑（加载器自己按页映射），
    //    738 项回归也看不见（样本恰好都小）——属"断言买到回归买不到的东西"。
    if (size_of_image != align_up(size_of_image, SEC_ALIGN)) {
      if (err) *err = "内部布局违规(I9)：SizeOfImage 不是 SectionAlignment 的整数倍（违反 PE 规范 must，且让 I1 漏扫页尾）——请检查 size_of_image 是否漏了 align_up";
      return -1;
    }
    // I12（v1.4.11，`-debug`）调试节链：升序 + 紧邻 + SEC_ALIGN 倍数（与 I2/I11 同族，PE 规范 must）。
    //    独立复算：从**前一节末尾**按 SEC_ALIGN 推，不是重述上面的赋值式。
    if (HAS_DEBUG) {
      // v1.4.13：`.idata` 是最后一个参与加载的节 ⇒ 调试节链紧贴它
      uint32_t prev_end_rva = idata_rva + idata_vsize;
      if (dbg_line_rva != align_up(prev_end_rva, SEC_ALIGN) ||
          dbg_info_rva != align_up(dbg_line_rva + dbg_line_vs, SEC_ALIGN) ||
          dbg_abbrev_rva != align_up(dbg_info_rva + dbg_info_vs, SEC_ALIGN)) {
        if (err) *err = "内部布局违规(I12)：调试节之间出现额外虚拟地址空隙（规范要求节 VA 升序且紧邻）——请检查 dbg_*_rva 算式";
        return -1;
      }
      // I1 扫描域护栏②：被排除在 I1 之外的字节必须**正好**是调试节，且该节不可执行 ——
      //   否则"限定扫描域"就成了给 I1 挖一个永久漏洞。
      if (dbg_line_raw != align_up(loaded_file_end, FILE_ALIGN) || (DBG_CHAR & 0x20000000u) != 0) {
        if (err) *err = "内部布局违规(I1/扫描域)：被 I1 排除的字节不正好是（不可执行的）调试节 —— 会漏扫绝对地址，请检查 dbg_line_raw 算式";
        return -1;
      }
      // I13（v1.4.11）：COFF 字符串表偏移必须与三个 `/nnn` 名字对得上。写错 = 工具读不出节名，
      //   而实测"节名读不出"会让 bfd 直接判 `file format not recognized`（objdump/addr2line/gdb 三通道全瞎）。
      if (name_off_line != 4 ||
          name_off_info != name_off_line + (uint32_t)strlen(".debug_line") + 1 ||
          name_off_abbrev != name_off_info + (uint32_t)strlen(".debug_info") + 1 ||
          strtab_size != name_off_abbrev + (uint32_t)strlen(".debug_abbrev") + 1) {
        if (err) *err = "内部布局违规(I13)：COFF 字符串表偏移与节名不匹配（工具会读不出节名 → 整个文件不可识别）——请检查 name_off_*/strtab_size 算式";
        return -1;
      }
    }
  }

  // ========== I16 / I17（v1.4.13）：IAT 必须**独占自己的非执行页** ==========
  // 为什么值得断言：本轮改动的**全部目的**就是"loader 写 IAT 时不要放开代码页"。这条性质只靠
  //   "看起来挪对了"是靠不住的（布局是一堆 cursor 算术，漏改一处就悄悄退回去），所以钉成判据。
  {
    // I16a 页隔离：`.idata` 与 `.text` 不得落在同一页（页 = SEC_ALIGN）。
    //   独立复算：两节的**页号**各自从 RVA 算出来再比 —— 不复述 idata_rva 的赋值式。
    if (idata_rva / SEC_ALIGN <= (TEXT_RVA + text_vsize - 1) / SEC_ALIGN) {
      if (err) *err = "内部布局违规(I16)：.idata 与 .text 落在同一页（loader 写 IAT 会连带放开代码页）——请检查 idata_rva 算式";
      return -1;
    }
    // I16b 紧邻：`.idata` 必须紧贴前一节末尾（升序 + 紧邻 + SEC_ALIGN 倍数，PE 规范 must）
    if (idata_rva != align_up(prev_loaded_vend, SEC_ALIGN)) {
      if (err) *err = "内部布局违规(I16)：.idata 与前一节之间出现额外虚拟地址空隙（Windows 会拒载）——请检查 idata_rva 算式";
      return -1;
    }
    // I17 覆盖 + 防半挪：每个 IAT 槽必须落在 `.idata` 区间内，且 `.text` 区间内一个都不许有
    for (int k = 0; k < total; k++) {
      uint32_t sl = iat_slot_rva[k];
      if (sl < idata_rva || sl + 8 > idata_rva + idata_vsize) {
        if (err) *err = "内部布局违规(I17)：IAT 槽没有落在 .idata 区间内（防半挪状态）——请检查 mod_iat_rva 算式";
        return -1;
      }
      if (sl >= TEXT_RVA && sl < TEXT_RVA + text_vsize) {
        if (err) *err = "内部布局违规(I17)：.text 区间内仍有 IAT 槽（代码页会被 loader 临时放开）——请检查布局";
        return -1;
      }
    }
    // （`.idata` 的特征位由下面的 I14/I15 从**产物字节**读回检查：不可执行、且不许 W|X；
    //   **IAT 数据目录（索引 12）的读回也在那里** —— 这里绝不能读 `out`：此刻产物头还没写进去）
  }

  // —— 3. 回填 FF15 disp（导入表）——
  // ExitProcess：槽 0；API 调用点：api_slot[api]
  {
    uint32_t d = iat_slot_rva[0] - (TEXT_RVA + (uint32_t)gen->disp_off + 4);
    buf_patch_u32(&gen->code, gen->disp_off, d);
  }
  for (size_t i = 0; i < gen->napi_sites; i++) {
    int slot = api_slot[gen->api_sites[i].api];
    uint32_t d = iat_slot_rva[slot] - (TEXT_RVA + (uint32_t)gen->api_sites[i].off + 4);
    buf_patch_u32(&gen->code, gen->api_sites[i].off, d);
  }

  // —— 3b. 回填全局变量 `[rip+disp32]` ——
  //   disp = 目标地址 - 指令尾地址 = (data_rva + globals[gi].doff) - (TEXT_RVA + off + 4)
  //   ⚠️ 这里用的是 code 内**拼接后全局偏移**（gen->guses 已转好），与 DblRef 那种
  //   「目标在 code 尾部」的回填是两套基准，别混。
  for (size_t i = 0; i < gen->nguses; i++) {
    GUse *u = &gen->guses[i];
    int64_t tgt = (int64_t)data_rva + gen->globals[u->gi].doff;
    int64_t insn_end = (int64_t)TEXT_RVA + (int64_t)u->off + 4;
    buf_patch_u32(&gen->code, u->off, (uint32_t)(tgt - insn_end));
  }

  // —— 4. 写头 ——
  dos_header(out);
  buf_bytes(out, (const uint8_t *)"PE\0\0", 4);
  coff_header(out, NSEC_ALL, HAS_DEBUG ? strtab_off : 0, 0);
  opt_header(out, size_of_image, text_raw_size,
             data_raw_size + rsrc_raw_size + (HAS_DEBUG ? (dbg_line_rs + dbg_info_rs + dbg_abbrev_rs) : 0),
             hdr_size,
             desc_rva, desc_bytes, rsrc_rva, rsrc_vsize, idata_rva, idata_vsize, entry_rva,
             (uint16_t)(gen->want_gui ? 2 : 3));   // v1.4.28：-gui → GUI 子系统（其余字段一字不动）
  section_header(out, ".text", text_vsize, text_sec_va, text_raw_size, hdr_size,
                 TEXT_SEC_CHAR);   // CODE|EXECUTE|READ
  if (TWO_SEC)
    section_header(out, ".data", data_vsize, data_rva, data_raw_size, data_raw_ptr,
                   DATA_SEC_CHAR); // INITIALIZED_DATA|READ|WRITE
  if (HAS_ADMIN)
    section_header(out, ".rsrc", rsrc_vsize, rsrc_rva, rsrc_raw_size, rsrc_raw_ptr,
                   RSRC_CHAR);     // INITIALIZED_DATA|READ（v1.4.6：清单资源）
  // v1.4.13：`.idata`（IAT 自成节）—— 节表必须按 RVA 升序，所以它排在所有加载节之后、调试节之前
  section_header(out, ".idata", idata_vsize, idata_rva, idata_raw_size, idata_raw_ptr,
                 IDATA_SEC_CHAR);  // INITIALIZED_DATA|READ（非执行）
  if (HAS_DEBUG) {
    // 节名走 `/nnn` 形式（指向字符串表内的偏移）——PE 镜像不支持 >8 字符的节名，这是唯一出路
    char n1[16], n2[16], n3[16];
    snprintf(n1, sizeof(n1), "/%u", (unsigned)name_off_line);
    snprintf(n2, sizeof(n2), "/%u", (unsigned)name_off_info);
    snprintf(n3, sizeof(n3), "/%u", (unsigned)name_off_abbrev);
    section_header(out, n1, dbg_line_vs, dbg_line_rva, dbg_line_rs, dbg_line_raw, DBG_CHAR);
    section_header(out, n2, dbg_info_vs, dbg_info_rva, dbg_info_rs, dbg_info_raw, DBG_CHAR);
    section_header(out, n3, dbg_abbrev_vs, dbg_abbrev_rva, dbg_abbrev_rs, dbg_abbrev_raw, DBG_CHAR);
  }
  while (out->len < hdr_size) buf_byte(out, 0);

  // —— 5. 代码（含字符串区/double 常量区）——
  buf_bytes(out, gen->code.data, code_len);
  while (out->len < hdr_size + (desc_rva - TEXT_RVA)) buf_byte(out, 0);

  // —— 6. 导入描述符区（每模块 20B + 全零终止）——
  for (int g = 0; g < ngroups; g++) {
    w32(out, mod_int_rva[g]);   // OriginalFirstThunk（INT）
    w32(out, 0);                // TimeDateStamp
    w32(out, 0);                // ForwarderChain
    w32(out, mod_dll_rva[g]);   // Name
    w32(out, mod_iat_rva[g]);   // FirstThunk（IAT）
  }
  wz(out, 20);                  // 终止描述符

  // —— 7. 各模块数据（按布局顺序：INT → hintnames → dll 名；**IAT 已挪进 `.idata`**，见 9d）——
  for (int g = 0; g < ngroups; g++) {
    ImpGroup *grp = &groups[g];
    // INT：每项 = 对应 Hint/Name RVA，末项 0
    for (int f = 0; f < grp->nfuncs; f++)
      w64(out, (uint64_t)hint_item_rva[g][f]);
    w64(out, 0);
    // Hint/Name 块
    for (int f = 0; f < grp->nfuncs; f++) {
      w16(out, 0);              // Hint
      buf_bytes(out, (const uint8_t *)grp->names[f], strlen(grp->names[f]));
      buf_byte(out, 0);
    }
    // DLL 名
    buf_bytes(out, (const uint8_t *)grp->dll, strlen(grp->dll));
    buf_byte(out, 0);
  }

  // —— 8. 补到 .text 的 SizeOfRawData ——
  while (out->len < hdr_size + text_raw_size) buf_byte(out, 0);

  // —— 9. v1.3.0 .data 节内容 ——
  // 全局变量按声明序摆放（doff 由 parse 算好，此处只按偏移落字节）。
  // ⚠️ data_raw_ptr 是**文件偏移**，data_rva 是**运行时地址**，两者不要混用。
  if (TWO_SEC) {
    while (out->len < data_raw_ptr) buf_byte(out, 0);
    // 先把整节铺零，再按 doff 覆盖初值（未初始化/未覆盖部分 = 0，即 C 的零初始化语义）
    for (uint32_t i = 0; i < data_vsize; i++) buf_byte(out, 0);
    for (int i = 0; i < gen->nglobals; i++) {
      GlobalVar *g = &gen->globals[i];
      if (g->init_len <= 0) continue;
      size_t at = data_raw_ptr + (size_t)g->doff;
      for (int b = 0; b < g->init_len; b++)
        out->data[at + (size_t)b] = g->init[b];
    }
    while (out->len < data_raw_ptr + data_raw_size) buf_byte(out, 0);
  }

  // —— 9b. v1.4.6 `.rsrc` 节内容（仅 -admin）——
  //   与 .data 同一纪律：先垫到**文件偏移**，再顺序写节内容，最后补齐到 SizeOfRawData。
  if (HAS_ADMIN) {
    while (out->len < rsrc_raw_ptr) buf_byte(out, 0);
    rsrc_write(out, rsrc_rva);
    while (out->len < rsrc_raw_ptr + rsrc_raw_size) buf_byte(out, 0);
  }

  // —— 9d. v1.4.13 `.idata` 节内容（IAT 块：初值 = Hint/Name RVA，loader 加载时覆写成真实地址）——
  //   与 .data/.rsrc 同一纪律：先垫到**文件偏移**、再顺序写内容、最后补齐到 SizeOfRawData。
  {
    while (out->len < idata_raw_ptr) buf_byte(out, 0);
    for (int g = 0; g < ngroups; g++) {
      ImpGroup *grp = &groups[g];
      for (int f = 0; f < grp->nfuncs; f++)
        w64(out, (uint64_t)hint_item_rva[g][f]);
      w64(out, 0);                 // 每组末项 0 终止
    }
    while (out->len < idata_raw_ptr + idata_raw_size) buf_byte(out, 0);
  }

  // —— 9c. v1.4.11 `-debug`：三个调试节内容 + COFF 字符串表 ——
  //   与 .data/.rsrc 同一纪律：先垫到**文件偏移**、再顺序写内容、最后补齐到 SizeOfRawData。
  if (HAS_DEBUG) {
    while (out->len < dbg_line_raw) buf_byte(out, 0);
    buf_bytes(out, dbg_line.data, dbg_line.len);
    while (out->len < dbg_line_raw + dbg_line_rs) buf_byte(out, 0);
    while (out->len < dbg_info_raw) buf_byte(out, 0);
    buf_bytes(out, dbg_info.data, dbg_info.len);
    while (out->len < dbg_info_raw + dbg_info_rs) buf_byte(out, 0);
    while (out->len < dbg_abbrev_raw) buf_byte(out, 0);
    buf_bytes(out, dbg_abbrev.data, dbg_abbrev.len);
    while (out->len < dbg_abbrev_raw + dbg_abbrev_rs) buf_byte(out, 0);
    // 字符串表（COFF 风格）：[u32 总长][名字\0 …]，**首个名字就在偏移 4**（实测真实镜像如此）
    while (out->len < strtab_off) buf_byte(out, 0);
    w32(out, strtab_size);
    buf_bytes(out, (const uint8_t *)".debug_line", strlen(".debug_line"));   buf_byte(out, 0);
    buf_bytes(out, (const uint8_t *)".debug_info", strlen(".debug_info"));   buf_byte(out, 0);
    buf_bytes(out, (const uint8_t *)".debug_abbrev", strlen(".debug_abbrev")); buf_byte(out, 0);
  }

  // ========== I1（v1.3.4）：产物内不得出现「指向本镜像的绝对地址」 ==========
  // 真实形态的不变量（替换掉原注释里那条**假**不变量「无 ASLR 是全局变量方案的前提」，已实测证伪）：
  //   产物是**位置无关**的 ⇒ 镜像里任何地方都不得出现一个值 = IMAGE_BASE + RVA；所有引用必须是
  //   RIP 相对 / RVA 差值。这是「为什么不需要重定位表」的真正理由，也是将来发 `.reloc` 节、
  //   开真 ASLR 的前提（有了它才谈得上位置无关）。
  // 实现：扫**发射完的字节**，找 8 字节小端值落进 [IMAGE_BASE, IMAGE_BASE + SizeOfImage)；
  //   命中即拒出产物。位置无关的产物 ⇒ 该窗口内不该有任何值。
  //   🔴 扫描域（v1.4.11，任务卡 T-20260917-223210）：**只扫「参与加载的节」**（`loaded_file_end` 之前）。
  //   `.debug_*` 节是 `MEM_DISCARDABLE`、不参与加载、loader 不重定位，而 DWARF 的 `DW_LNE_set_address`
  //   **必须**写绝对地址 ⇒ 不排除就在每个带调试信息的产物上误报。两条护栏见下方代码（①无调试节时
  //   扫描域必须等于整文件 ②被排除的字节必须逐个落在不可执行的节里）。
  //   ⚠️ 跳过 PE 头（hdr_size 之前）：头里全是「半地址半尺寸」的混合字段，**相邻字段会拼出
  //   IMAGE_BASE** —— 实测证据（2026-09-15）：`boot\samples\w9.exe` 在 file+0x14d 命中 0x140000000，
  //   但那 8 字节是节名尾部（`.text` 后 3 个 0）+ `VirtualSize(0x140)` + `VirtualAddress(0x1000)`
  //   拼出来的，与「发射内容」无关。头是我们按规范写的元数据，不是产物的机器码/数据。
  // 能力边界（诚实标注）：只抓**指向本镜像**的绝对地址。指向镜像外的绝对地址（如 kernel32 的
  //   真实函数地址）抓不到 —— 但那种值编译期根本不可知（导入表 IAT 就是为此存在的），
  //   所以对「编译期能烧进字节的绝对地址」这条判据是完备的。
  // 已知（理论上的）假阳性面：.data 里的 double/int 初值字节或字符串，若其 8 字节窗口**恰好**
  //   等于一个本镜像地址（约 1/2^40 量级），会被误判。当前不是问题（初值只支持编译期常量、
  //   且指针类型全局变量尚未开放）；真撞上时应改判据，而不是放水。
  {
    const uint64_t lo = IMAGE_BASE;
    const uint64_t hi = IMAGE_BASE + (uint64_t)size_of_image;
    // 🔴 扫描域护栏①（v1.4.11，"非重述"写法）：**没有调试节时，扫描域必须等于整个文件** ——
    //   保证这次"限定扫描域"的改动**没有让今天任何一个产物少扫一个字节**（改判据先自证判据没缩水）。
    if (!HAS_DEBUG && loaded_file_end != out->len) {
      if (err) *err = "内部布局违规(I1/扫描域)：无调试节时 I1 扫描域必须覆盖整个文件（否则会漏扫绝对地址）——请检查 loaded_file_end 算式";
      return -1;
    }
    for (size_t i = hdr_size; i + 8 <= loaded_file_end; i++) {
      uint64_t v = 0;
      for (int k = 7; k >= 0; k--) v = (v << 8) | (uint64_t)out->data[i + (size_t)k];
      if (v >= lo && v < hi) {
        // 🟥 v1.4.27（2026-09-27）：**只在"真能承载一个绝对地址"的位置上判违规** —— 上面那条
        //   "已知假阳性面"（注释里预告过）**当天就撞上了**，而且是**代码区**、不是 .data：
        //   实测 `test\samples\flgui3.fl`：file+0x81CE 命中 0x140000000，那 8 字节 =
        //   `00 00 00 40 01 00 00 00` —— 前 3 个 0 是**上一条指令立即数的尾巴**、`40 01 00 00`
        //   是**另一条指令的 imm32(0x140)**，两个都不指向任何东西。触发条件是"布局恰好拼出这个窗"
        //   （内核加了几行代码、.text 一移，窗就存在了；**同一个函数在别的样本里命中 0 次**）。
        //   ⇒ 判据从"任何 8 字节窗落进镜像区间就算"收紧成"**真引用**才算"，三条取证形态：
        //     ① `REX.W + B8+r` 之后的 8 字节立即数（`mov r64, imm64`）
        //     ② `REX.W + A0..A3` 之后的 8 字节（`mov rax, moffs64` / 存回）
        //     ③ **8 字节对齐**的窗口（.data 里的指针初值/数据项落在 8 字节槽上）
        //   ⚠️ 这不是放水，是"能力覆盖"的等价重述：本镜像 IMAGE_BASE = 0x140000000 > 2^32
        //     ⇒ **32 位 imm 在算术上不可能**编码出镜像地址（B8+r / C7 /0 / 68 那些形态天生覆盖不到），
        //     所以只有"64 位立即数 / 8 字节数据槽"这两类位置需要扫。判据力由注入实验守住
        //     （2026-09-27 实测：人工烧一条 `48 B8 <IMAGE_BASE+…>` 进产物 ⇒ 新判据照样拒出）。
        int rexw = (i >= 2) && ((out->data[i - 2] & 0xF8) == 0x48);
        int imm64_after_mov = rexw && ((out->data[i - 1] & 0xF8) == 0xB8);
        int moffs64 = rexw && ((out->data[i - 1] & 0xFC) == 0xA0);
        int aligned_slot = ((i & 7u) == 0);
        if (imm64_after_mov || moffs64 || aligned_slot) {
          if (err) *err = "内部布局违规(I1)：产物内出现指向本镜像的绝对地址（破坏位置无关性）——请改为 RIP 相对 / RVA 差值寻址";
          return -1;
        }
      }
    }
  }

  // ========== I14 / I15（v1.4.12，W^X 轮次）：节权限硬化子集 ==========
  // 为什么值得断言：产物**本来就**满足 W^X（.text = R|X、.data = R|W、.rsrc/.debug = R），
  //   但这条性质此前**只写在常量的注释里** —— 今天谁把 `.data` 的特征位加上 X（或给 `.text` 加 W），
  //   编译器一句话不说、773 项回归也照样全绿（回归只跑**行为**，从不读节权限）。
  // 写法纪律（本项目老坑）：**不复述常量**，而是从**已经写进 `out` 缓冲的产物字节**里把节表读回来 ——
  //   检查的是产物本身，将来谁换了写节表的路径或常量来源，它照样抓得住。
  {
    const uint32_t SEC_TAB_OFF = 0x40 + 4 + 20 + 0xF0;  // DOS stub(0x40)+"PE\0\0"+COFF(20)+可选头(0xF0)
    const uint32_t SCN_EXEC    = 0x20000000u;           // IMAGE_SCN_MEM_EXECUTE
    const uint32_t SCN_WRITE   = 0x80000000u;           // IMAGE_SCN_MEM_WRITE
    int n_exec = 0;                                     // 独立数一遍：产物里到底有几个可执行节
    for (uint32_t i = 0; i < (uint32_t)NSEC_ALL; i++) {
      const uint8_t *s = out->data + SEC_TAB_OFF + (size_t)i * 40;
      uint32_t c = (uint32_t)s[36] | ((uint32_t)s[37] << 8) |
                   ((uint32_t)s[38] << 16) | ((uint32_t)s[39] << 24);   // Characteristics 在节头 +36
      // I14 禁 RWX：可写代码页是"改自己"的入口，硬化子集策略明确禁止（UEFI CA 签名条文同款要求）。
      //   诚实标注：**PE 规范与桌面 loader 都不禁止 RWX**（规范只给三句权限位说明、实测 loader
      //   对 RWX 既不拒绝也不警告）⇒ 这是**我们自己的硬化子集策略**，不是"规范要求"。
      if ((c & SCN_WRITE) && (c & SCN_EXEC)) {
        if (err) *err = "内部布局违规(I14)：某节同时可写可执行（W|X 同页，硬化子集策略禁止）——请检查节特征位";
        return -1;
      }
      if (c & SCN_EXEC) n_exec++;
      // I15 可执行节的**集合**必须恰好是第一节（.text）—— 数据/资源/调试节一个都不许可执行。
      //   这不是"重述常量"：它管的是"产物里有哪些节可执行"这个集合性质。数据节里可能放着被当
      //   函数指针/返回地址用的字节，一旦该节可执行，那些字节就直接成了可执行代码。
      if (i > 0 && (c & SCN_EXEC)) {
        if (err) *err = "内部布局违规(I15)：非代码节被标成可执行（数据/资源/调试节必须不可执行）——请检查节特征位";
        return -1;
      }
    }
    if (n_exec != 1) {
      if (err) *err = "内部布局违规(I15)：产物里可执行节的数量不是 1（入口点所在的 .text 必须且只能是唯一可执行节）——请检查节特征位";
      return -1;
    }
    // 与 I7 合起来的完整形态 = 「W^X 硬化子集」的可断言表述：
    //   入口点在第一节内（I7）＋ 第一节可执行（I7）＋ **只有**第一节可执行（I15）＋ 任何节都不 W|X（I14）。
    //
    // I18（v1.4.13）：**IAT 数据目录（索引 12）必须存在且正好覆盖 `.idata` 里的每个 IAT 槽**。
    //   为什么这条是必需项（实测挣来的）：IAT 与导入目录**跨页**之后，本机 Windows loader 靠这个
    //   目录定位"要临时放开哪些页" —— 缺了它，loader 去放开**代码页**、却仍往只读的 `.idata` 页写
    //   ⇒ 导入解析直接 `0xC0000005`（同批实测：样本退出码 -1073741819）。
    //   ⚠️ 与上半场那条"不是 must"不矛盾：IAT 与导入目录**同页**时不给也能跑（实测过）；
    //   **跨页**时才必需 —— "规范没有 must" ≠ "任何形态都不需要它"。
    //   读回位置：可选头起点 0x58 ＋ 目录表起点 0x70 ＋ 12*8。
    //   ⚠️ 必须在**头写完**之后读（这里就是写完之后）—— 放到写头之前会读到未初始化/越界内存
    //   （本轮真踩过：编译器直接 0xC0000005）。
    {
      const uint32_t off = 0x58 + 0x70 + 12 * 8;
      uint32_t ir = (uint32_t)out->data[off] | ((uint32_t)out->data[off + 1] << 8) |
                    ((uint32_t)out->data[off + 2] << 16) | ((uint32_t)out->data[off + 3] << 24);
      uint32_t is = (uint32_t)out->data[off + 4] | ((uint32_t)out->data[off + 5] << 8) |
                    ((uint32_t)out->data[off + 6] << 16) | ((uint32_t)out->data[off + 7] << 24);
      if (ir == 0 || is == 0) {
        if (err) *err = "内部布局违规(I18)：IAT 数据目录（索引 12）为空 —— IAT 与导入目录不同页时本机 loader 靠它定位要放开的页，缺了导入解析会崩";
        return -1;
      }
      for (int k = 0; k < total; k++) {
        uint32_t sl = iat_slot_rva[k];
        if (sl < ir || sl + 8 > ir + is) {
          if (err) *err = "内部布局违规(I18)：IAT 数据目录没有覆盖到某个 IAT 槽（loader 会漏放开一页）——请检查目录 12 的 rva/size 算式";
          return -1;
        }
      }
      if (ir < idata_rva || ir + is > idata_rva + idata_vsize) {
        if (err) *err = "内部布局违规(I18)：IAT 数据目录指到了 .idata 区间之外（会把别的节当 IAT 放开）——请检查目录 12 的 rva/size 算式";
        return -1;
      }
    }

    // I19（v1.4.13）：**头必须真的盖住节表** —— 从产物读回 NumberOfSections 与 SizeOfHeaders，
    //   断言 `SizeOfHeaders ≥ 0x148 + nsec*40` 且节数与编译器内部算的一致。
    //   为什么值得钉：原来 SizeOfHeaders 与 .text 的文件偏移都写死 0x200，而节数 ≥5 时头部已经长到
    //   0x210（6 节 0x238）⇒ **头把 .text 开头盖住 16/56 字节**，节表却仍写 0x200 ——
    //   实测现象：产物入口点字节成了 `00 00`（`add [rax],al`）、一跑就是 0xC0000005；
    //   而**既有回归完全看不见**这一族（产物照样生成、objdump 照样能读，只有真跑才炸）。
    {
      uint32_t ns_prod = (uint32_t)out->data[0x46] | ((uint32_t)out->data[0x47] << 8);  // COFF+2
      uint32_t soh = 0;
      for (int k = 0; k < 4; k++) soh |= (uint32_t)out->data[0x58 + 0x3C + (size_t)k] << (8 * k);
      if ((int)ns_prod != NSEC_ALL) {
        if (err) *err = "内部布局违规(I19)：产物里的节数与编译器内部算的不一致（节表会有一个写不进去）——请检查 pe_nsec_all 与 NSEC_ALL 的口径";
        return -1;
      }
      if (soh < 0x148 + ns_prod * 40) {
        if (err) *err = "内部布局违规(I19)：SizeOfHeaders 盖不住节表（头会压住 .text 开头 ⇒ 产物一跑就崩）——请检查 pe_headers_size 算式";
        return -1;
      }
    }
    // I20 / I21（v1.4.14，ASLR 轮次）：**ASLR 必须真的开着，而且不许被"静默吃掉"**。
    //   读数位置（**文件偏移**）：COFF Characteristics 在 **0x56**（= e_lfanew+4+18；⚠️ 别读成 0x46 ——
    //   那是 NumberOfSections，本轮第一版就读错它 ⇒ 3 节产物被误判成"RELOCS_STRIPPED 置位"）；
    //   可选头 DllCharacteristics 在 **0x9E**（= opt+0x46，opt = e_lfanew+24 = 0x58）。
    //   ✅ **订正（2026-09-18，v1.4.16 轮次复测）**：本节此前写着"本编译器的 `opt_header()` 根本没写
    //   OS/Image/Subsystem 版本 ＋ Win32VersionValue 这一整块（0x18 字节）⇒ 后面所有字段比 PE32+ 规范位置
    //   提前 0x18 字节（`Subsystem` 落在 opt+0x44、`DllCharacteristics` 落在 opt+0x46）"、以及"教科书的
    //   DllCharacteristics 是 opt+0x5E" —— **这两句都是错的**。
    //   实测（4 种产物形态 plain / `-debug` / `-admin` / `-debug -admin` ＋ 本机 MinGW ld 产物对照，
    //   并以 `objdump -p` 作**独立读取者**交叉验证它读出 `MajorOSystemVersion=6` /
    //   `MajorSubsystemVersion=6` / `Subsystem=3 (CUI)` / `DllCharacteristics=0x0160`）：
    //     · `opt_header()` **写了**那一块：`opt+0x28` = OS 6.0、`opt+0x2C` = Image 0.0、
    //       `opt+0x30` = Subsystem 6.0、`opt+0x34` = Win32VersionValue 0（16 字节，与 ld 产物同构）；
    //     · `SizeOfImage(0x38)` / `SizeOfHeaders(0x3C)` / `Subsystem(0x44)` / `DllCharacteristics(0x46)` /
    //       `NumberOfRvaAndSizes(0x6C)` **全部落在 PE32+ 规范位置**，`SizeOfOptionalHeader = 0xF0` 也正好是
    //       `0x70 + 16*8`（16 个数据目录）；
    //     · **PE32+ 规范里 `DllCharacteristics` 本来就是 `opt+0x46`**（`opt+0x5E` 不是规范位置）⇒
    //       文件偏移 `0x9E` = `0x58 + 0x46` **就是规范位置**；本机 ld 产物 `opt=0x98` → `0xDE`，同一公式。
    //   ⇒ 结论：**产物与规范一致，没有"错位"，不需要补任何字段**。当时真正发生的，是把"自己写错的偏移
    //   （0x5E / 0xB6）"当成了"规范偏移"，再倒推出一套"缺版本块"的解释。已把这条假结论一起订正到
    //   `test\wx-verify.ps1`（并新增第 [7a] 节的**布局钉子**：版本块在 `opt+0x28`、`Subsystem` 在 `opt+0x44`、
    //   `opt+0x46` 与 `0x9E` 读到同一个 dword、`NumberOfRvaAndSizes = 16`）、`test\debug-verify.ps1` 与
    //   `FLINT明细.md`。
    //   教训与「I1 扫描跳过 PE 头」「断言要读回产物字节」同族：**读回位置必须自己先被证实** ——
    //   本轮这一条上连踩三次（先写 0x1FA、再写 0xB6、再把 0x46 当 Characteristics），全靠断言自曝；
    //   再加一条：**算式/读数位置这类结论必须拿外部规范工具（objdump / MSDN 原文）复核一次再落文档**，
    //   否则"自己推的偏移"会变成下一轮的"实测发现"。
    //   为什么值得断言：**`DllCharacteristics` 只写在 `opt_header()` 的常量里**，谁把它改回去、或谁
    //   在 COFF 头里打开 `RELOCS_STRIPPED`，编译器**一句话不说**，773 项回归（只跑行为）也照样全绿。
    //   I21 是这轮最有价值的一条：实测过的**静默失效**组合 —— `RELOCS_STRIPPED=1` 与 `DYNAMIC_BASE=1`
    //   同置时，**loader 不报错、不拒绝，但 RELOCS_STRIPPED 胜出、ASLR 完全失效**（基址固定回首选值）。
    //   真实工具链同样主动禁止该组合（binutils `peXXigen.c`），所以它是一条"该被断言、而不是指望
    //   loader 报错"的不变量。
    {
      uint32_t coff_ch = (uint32_t)out->data[0x56] | ((uint32_t)out->data[0x57] << 8);
      uint32_t dll_ch  = (uint32_t)out->data[0x9E] | ((uint32_t)out->data[0x9F] << 8);
      const uint32_t DYN_BASE = 0x0040u, HI_ENTROPY = 0x0020u, NX = 0x0100u;
      const uint32_t RELOCS_STRIPPED = 0x0001u;
      // I20：ASLR 形态三件套必须齐（DYNAMIC_BASE ＋ HIGH_ENTROPY_VA ＋ NX_COMPAT）。
      //   HIGH_ENTROPY_VA 只有跟 DYNAMIC_BASE 一起才有意义（单独置位会被忽略），这里一起断言。
      //   ⚠️ 例外：老形态 `NX_COMPAT` **单独**置位放行 —— 那正是本轮"改前"的唯一形态（0x0100），也是
      //   门脚本重新生成"改前基线 exe"（`flint_before_aslr.exe`）时需要的形态；除此之外 ASLR 位缺一个都拒。
      const int has_aslr_form      = ((dll_ch & (DYN_BASE | HI_ENTROPY | NX)) == (DYN_BASE | HI_ENTROPY | NX));
      const int is_legacy_nx_only  = ((dll_ch & (DYN_BASE | HI_ENTROPY | NX)) == NX);
      if (!has_aslr_form && !is_legacy_nx_only) {
        if (err) *err = "内部布局违规(I20)：产物缺少 ASLR 形态位（需 DYNAMIC_BASE|HIGH_ENTROPY_VA|NX_COMPAT = 0x0160）——请检查 opt_header 的 DllCharacteristics";
        return -1;
      }
      // I21：与 RELOCS_STRIPPED **不得同置**（COFF 头里那位 + 可选头里那位都查一遍 —— loader 实际上
      //   是两者任一命中就吃掉 ASLR，本断言与 binutils 的口径对齐；防的是"从 COFF 头那边漏进来"）。
      if ((coff_ch & RELOCS_STRIPPED) || (dll_ch & RELOCS_STRIPPED)) {
        if (err) *err = "内部布局违规(I21)：RELOCS_STRIPPED 与 DYNAMIC_BASE 同置 —— loader 不报错但 ASLR 静默失效（binutils 同样禁止该组合）";
        return -1;
      }
    }
  }

  // 释放组内名字
  for (int g = 0; g < ngroups; g++)
    for (int f = 0; f < groups[g].nfuncs; f++)
      free(groups[g].names[f]);

  return 0;
}
