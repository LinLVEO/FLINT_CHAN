// debug.c — v1.4.11 可审计发射层（`-debug`）：把「源码行 → 发射字节区间」变成**产物里能读到的标准信息**。
//
// 为什么要它（价值论证见 `开工简报-可审计发射层.md`）：
//   FLINT 为了「零垫层 + 逐字节」主动交出了链接器这张安全网，产物因此没有任何"可被现成工具读懂的"
//   元信息；调试只能靠 objdump 反汇编 + 人肉对照。本文件把内部那张表**同时**输出成三份：
//     ① **标准腿（DWARF5）** —— `objdump --dwarf=decodedline` / `addr2line` / `gdb` 直接能读（外部可核）；
//     ② **私有腿（TSV）** —— 补标准**不提供**的三个维度：字节区间 / 文件偏移 / 所属节；
//     ③ **变量/帧腿（`<输出>.dbg.json`，v5 D-1 + D-3）** —— 标准腿同样不提供的两件事：
//        帧布局（本仓 PE **没有 .pdata** ⇒ StackWalk64 不认，栈回溯只能手写）和
//        局部变量/形参的帧内地址（DWARF 腿只发行表，没有任何变量 DIE）。
//        格式 = 人/机都能读的 JSON，version 1；字段口径见 debug_build_map 的头注释与
//        `interface\调试器控制接口.md` §二（D-1/D-3）。
//   三腿同源（同一张 DebugRow / DebugFuncSpan 表）⇒ 不存在两套真值。
//
// 最小集是**实测定的**，不是猜的（`调研②-DWARF最小集实测.md`，7 个受控删改变体）：
//   · `.debug_line` + `.debug_info`(最小 CU) + `.debug_abbrev` 三节**缺一不可**（缺 info/abbrev 时
//     gdb 报 "No line number information"、addr2line 退化成 `??`；而 objdump 读行表本身只依赖 .debug_line）；
//   · **不要** `.debug_str` / `.debug_line_str` —— 目录/文件表用内联 `DW_FORM_string`；
//   · PE 侧节名必须走 `/nnn` 长名 + **字符串表**（清掉字符串表指针后 bfd 直接报
//     `file format not recognized`，三通道全瞎）；但**不需要任何符号记录**（`NumberOfSymbols=0` 即可）。
//
// 常量取值照抄工具链实测在用的那一组（GCC/as 实测、tcc 硬编码）：line_base=-5 / line_range=14 /
//   opcode_base=13 / min_inst_len=1 —— 工具链对这条路径最"热"。

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>     // getcwd（comp_dir 绝对化；mingw-w64 提供）

#include "flint.h"

// —— DWARF5 常量（只列本文件用到的）——
#define DW_TAG_compile_unit   0x11
#define DW_AT_name            0x03
#define DW_AT_stmt_list       0x10
#define DW_AT_low_pc          0x11
#define DW_AT_high_pc         0x12
#define DW_AT_language        0x13
#define DW_AT_comp_dir        0x1b
#define DW_AT_producer        0x25
#define DW_FORM_addr          0x01
#define DW_FORM_data8         0x07
#define DW_FORM_string        0x08
#define DW_FORM_data1         0x0b
#define DW_FORM_sec_offset    0x17
#define DW_FORM_udata         0x0f
#define DW_CHILDREN_no        0x00
#define DW_LANG_C99           0x0c
#define DW_UT_compile         0x01

#define DW_LNS_copy           1
#define DW_LNS_advance_pc     2
#define DW_LNS_advance_line   3
#define DW_LNS_set_file       4
#define DW_LNE_end_sequence   1
#define DW_LNE_set_address    2

#define DW_LNCT_path              1
#define DW_LNCT_directory_index   2

#define LINE_BASE   (-5)
#define LINE_RANGE  14
#define OPCODE_BASE 13

// —— 小工具：DWARF 的 LEB128 / 定长小端 ——
static void u8_(Buf *b, unsigned v) { buf_byte(b, (uint8_t)(v & 0xFF)); }
static void u16_(Buf *b, unsigned v) { u8_(b, v); u8_(b, v >> 8); }
static void u32_(Buf *b, unsigned long v) { u16_(b, (unsigned)v); u16_(b, (unsigned)(v >> 16)); }

static void uleb(Buf *b, unsigned long v) {
  do {
    uint8_t byte = (uint8_t)(v & 0x7F);
    v >>= 7;
    if (v) byte |= 0x80;
    buf_byte(b, byte);
  } while (v);
}

static void sleb(Buf *b, long v) {
  int more = 1;
  while (more) {
    uint8_t byte = (uint8_t)(v & 0x7F);
    int sign = (byte & 0x40) != 0;
    v >>= 7;
    if ((v == 0 && !sign) || (v == -1 && sign)) more = 0;
    else byte |= 0x80;
    buf_byte(b, byte);
  }
}

static void cstr(Buf *b, const char *s) {
  const char *p = s ? s : "";
  buf_bytes(b, (const uint8_t *)p, strlen(p));
  buf_byte(b, 0);
}

// —— 主源文件（CU 名）：**第 0 个登记的源文件**（main.c 先加载命令行文件，include/内建库随后）——
static const char *main_file(void) {
  const char *f = src_file_count() > 0 ? src_file_name(0) : NULL;
  return f ? f : "<unknown>";
}

// 拆出「目录 + 文件名」（两边都用同一份拆分，避免 CU 名与文件表不一致）
static void split_path(const char *path, char *dir, size_t dcap, char *base, size_t bcap) {
  const char *slash = NULL;
  for (const char *p = path; *p; p++)
    if (*p == '/' || *p == '\\') slash = p;
  if (slash) {
    size_t dl = (size_t)(slash - path);
    if (dl >= dcap) dl = dcap - 1;
    memcpy(dir, path, dl);
    dir[dl] = '\0';
    snprintf(base, bcap, "%s", slash + 1);
  } else {
    snprintf(dir, dcap, ".");
    snprintf(base, bcap, "%s", path);
  }
}

// 把目录变成**绝对**的。为什么必须：`comp_dir` 是相对路径时，gdb/addr2line 会把 comp_dir 再前置
//   一次（实测 `test\samples` + 文件项 → 打印成 `test\samples/test\samples/ctrl1.fl`），
//   而 GCC 一律写绝对 comp_dir。绝对化后工具输出就是我们期望的那条路径。
static void abs_dir(const char *dir, char *out, size_t cap) {
  // 手写拷贝而不是 snprintf("%s/%s")：gcc 的 -Wformat-truncation 对"两个未知长度串拼接"必报，
  //   而这里本来就能精确算出长度（项目纪律：警告数必须等于基线，不留新警告）。
  size_t n = strlen(dir);
  int absolute = (dir[0] == '/' || dir[0] == '\\' ||
                  (isalpha((unsigned char)dir[0]) && dir[1] == ':'));
  char cwd[512];
  if (!absolute && getcwd(cwd, sizeof(cwd))) {
    if (strcmp(dir, ".") == 0) { dir = cwd; n = strlen(cwd); }
    else {
      size_t a = strlen(cwd);
      if (a + 1 + n < cap) {
        memcpy(out, cwd, a);
        out[a] = '/';
        memcpy(out + a + 1, dir, n);
        out[a + 1 + n] = '\0';
        return;
      }
    }
  }
  if (n >= cap) n = cap - 1;
  memcpy(out, dir, n);
  out[n] = '\0';
}

// 源文件序号 → (DWARF 文件表下标)。口径（照 dwarf-discuss/GCC 实测）：
//   DWARF5 文件表是 **0 基**，但行号程序的 file 寄存器**初值是 1** ⇒ file[0] 与 file[1] 都放主源文件，
//   别处文件从 2 起；主源文件的行因此**不需要** set_file（少发指令，也避开"只发 file[0] 会越界"的坑）。
static int file_table_index(int src_idx) {
  if (src_idx <= 0) return 1;
  return src_idx + 1;
}

// ========== ① `.debug_abbrev` ==========
void debug_build_abbrev(Buf *out) {
  buf_init(out);
  uleb(out, 1);                       // 缩写码 1
  uleb(out, DW_TAG_compile_unit);
  uleb(out, DW_CHILDREN_no);
  uleb(out, DW_AT_name);       uleb(out, DW_FORM_string);
  uleb(out, DW_AT_comp_dir);   uleb(out, DW_FORM_string);
  uleb(out, DW_AT_producer);   uleb(out, DW_FORM_string);
  uleb(out, DW_AT_language);   uleb(out, DW_FORM_data1);
  uleb(out, DW_AT_low_pc);     uleb(out, DW_FORM_addr);
  uleb(out, DW_AT_high_pc);    uleb(out, DW_FORM_data8);
  uleb(out, DW_AT_stmt_list);  uleb(out, DW_FORM_sec_offset);
  uleb(out, 0); uleb(out, 0);         // 属性表结束
  uleb(out, 0);                       // 缩写表结束
}

// ========== ② `.debug_info`（最小 CU：一个 DIE，无子节点）==========
// 为什么 CU 必须存在：行表在规范里的挂靠点是 CU 的 `DW_AT_stmt_list`；实测拿掉 `.debug_info` 后
//   gdb 报 "No line number information available"，addr2line 退化成 `?? | hello.c:?`。
void debug_build_info(GenResult *gen, uint32_t text_rva, uint32_t line_sec_off, Buf *out) {
  (void)gen;
  (void)text_rva;
  buf_init(out);
  size_t len_at = out->len;
  u32_(out, 0);                       // unit_length（回填）
  u16_(out, 5);                       // version = DWARF 5
  u8_(out, DW_UT_compile);            // unit_type
  u8_(out, 8);                        // address_size
  u32_(out, 0);                       // debug_abbrev_offset
  char dir[512], base[256], adir[512];
  split_path(main_file(), dir, sizeof(dir), base, sizeof(base));
  abs_dir(dir, adir, sizeof(adir));
  uleb(out, 1);                       // 缩写码
  cstr(out, base);                    // DW_AT_name
  cstr(out, adir);                    // DW_AT_comp_dir（绝对路径，与 GCC 口径一致）
  cstr(out, "hlc (self-hosted, no assembler/linker)");   // DW_AT_producer
  u8_(out, DW_LANG_C99);              // DW_AT_language
  // DW_AT_low_pc / high_pc —— **gdb 认路的必要条件**（实测：没有地址区间时 gdb 报
  //   "No line number information available for address …"，而 objdump/addr2line 仍能解行表）。
  //   约定与我们行表里 set_address 的一致：写**绝对 VA**（IMAGE_BASE + RVA）；high_pc 用"距 low_pc 的
  //   偏移"（DWARF4+ 的常量形式语义），值是代码区长度。
  unsigned long long low = (unsigned long long)0x140000000ULL + text_rva;
  unsigned long long high = (unsigned long long)gen->code.len;   // 代码区长度（不含导入表/字符串区）
  if (gen->ndbg_funcs > 0) {
    DebugFuncSpan *last = &gen->dbg_funcs[gen->ndbg_funcs - 1];
    high = (unsigned long long)(last->off + last->len);
  }
  for (int k = 0; k < 8; k++) u8_(out, (unsigned)(low >> (8 * k)));
  for (int k = 0; k < 8; k++) u8_(out, (unsigned)(high >> (8 * k)));
  u32_(out, line_sec_off);            // DW_AT_stmt_list
  buf_patch_u32(out, len_at, (uint32_t)(out->len - (len_at + 4)));
}

// ========== ③ `.debug_line`（DWARF5 行号表）==========
void debug_build_line(GenResult *gen, uint32_t text_rva, Buf *out) {
  buf_init(out);
  size_t unit_len_at = out->len;
  u32_(out, 0);                       // unit_length（回填）
  u16_(out, 5);                       // version
  u8_(out, 8);                        // address_size
  u8_(out, 0);                        // segment_selector_size
  size_t hdr_len_at = out->len;
  u32_(out, 0);                       // header_length（回填）
  u8_(out, 1);                        // minimum_instruction_length
  u8_(out, 1);                        // maximum_operations_per_instruction
  u8_(out, 1);                        // default_is_stmt
  u8_(out, (unsigned)(LINE_BASE & 0xFF));   // line_base = -5（按位型写）
  u8_(out, LINE_RANGE);               // line_range
  u8_(out, OPCODE_BASE);              // opcode_base
  {
    static const unsigned std_lens[12] = {0,1,1,1,1,0,0,0,1,0,0,1};
    for (int i = 0; i < 12; i++) u8_(out, std_lens[i]);
  }
  char dir[512], base[256], adir[512];
  split_path(main_file(), dir, sizeof(dir), base, sizeof(base));
  abs_dir(dir, adir, sizeof(adir));
  // 目录表：v5 用「格式描述符 + 条目」，用内联 DW_FORM_string ⇒ 不需要 .debug_line_str；
  //   每个源文件带**自己的目录项**（include 进来的库文件常在不同目录）。
  int nsrc0 = src_file_count();
  char dirs[64][512];
  int dir_idx[64];
  int ndirs = 0;
  snprintf(dirs[0], sizeof(dirs[0]), "%s", adir);   // dir[0] = 编译目录（规范：第一项 = 当前目录）
  ndirs = 1;
  for (int i = 0; i < nsrc0 && i < 64; i++) {
    char d2[512], b2[256];
    const char *nm = src_file_name(i);
    split_path(nm ? nm : "<unknown>", d2, sizeof(d2), b2, sizeof(b2));
    char a2[512];
    abs_dir(d2, a2, sizeof(a2));
    int found = -1;
    for (int k = 0; k < ndirs; k++)
      if (strcmp(dirs[k], a2) == 0) { found = k; break; }
    if (found < 0 && ndirs < 64) { snprintf(dirs[ndirs], sizeof(dirs[0]), "%s", a2); found = ndirs; ndirs++; }
    dir_idx[i] = found < 0 ? 0 : found;
  }
  u8_(out, 1);                        // directory_entry_format_count
  uleb(out, DW_LNCT_path); uleb(out, DW_FORM_string);
  uleb(out, (unsigned long)ndirs);    // directories_count
  for (int k = 0; k < ndirs; k++) cstr(out, dirs[k]);
  // 文件表：file[0] 与 file[1] 都是主源文件（file 寄存器初值 = 1），其余按登记序从 2 起
  u8_(out, 2);                        // file_name_entry_format_count
  uleb(out, DW_LNCT_path);             uleb(out, DW_FORM_string);
  uleb(out, DW_LNCT_directory_index);  uleb(out, DW_FORM_udata);
  int nsrc = nsrc0;
  uleb(out, (unsigned long)(nsrc + 1));   // file[0] 占位 + 每个源文件一项
  cstr(out, base); uleb(out, 0);          // file[0]  = 主源文件
  cstr(out, base); uleb(out, 0);          // file[1]  = 主源文件（初值 1 落在这一项）
  for (int i = 1; i < nsrc; i++) {        // file[2..] = 其余源文件（include / 内建库）
    char d2[512], b2[256];
    const char *nm = src_file_name(i);
    split_path(nm ? nm : "<unknown>", d2, sizeof(d2), b2, sizeof(b2));
    cstr(out, b2);
    uleb(out, (unsigned long)dir_idx[i]);
  }
  buf_patch_u32(out, hdr_len_at, (uint32_t)(out->len - (hdr_len_at + 4)));

  // —— 行号程序：**每个函数一条 sequence**（各自 set_address → 若干行 → end_sequence）——
  int cur_file_entry = 1;             // file 寄存器初值 = 1（= 主源文件）
  size_t row = 0;
  for (int f = 0; f < gen->ndbg_funcs; f++) {
    DebugFuncSpan *sp = &gen->dbg_funcs[f];
    size_t fend = sp->off + sp->len;
    if (row >= gen->ndbg_rows || gen->dbg_rows[row].off >= fend) continue;   // 本函数没有语句
    // DW_LNE_set_address（扩展操作码：0 长度 操作码 地址）
    buf_byte(out, 0); uleb(out, 9); u8_(out, DW_LNE_set_address);
    {
      unsigned long long addr = (unsigned long long)0x140000000ULL + text_rva + sp->off;
      for (int k = 0; k < 8; k++) u8_(out, (unsigned)(addr >> (8 * k)));
    }
    size_t prev_off = sp->off;        // address 寄存器（相对 sequence 起点）
    int prev_line = 1;                // line 寄存器初值 = 1
    while (row < gen->ndbg_rows && gen->dbg_rows[row].off < fend) {
      DebugRow *r = &gen->dbg_rows[row];
      // 防御：行表要求 sequence 内地址非递减。万一有记录落在本函数区间之外/乱序，
      //   宁可跳过也不发一条负的 advance_pc（那会让整张表解成垃圾）。
      if (r->off < prev_off) { row++; continue; }
      unsigned long daddr = (unsigned long)(r->off - prev_off);
      int dline = r->line - prev_line;
      if (daddr) { u8_(out, DW_LNS_advance_pc); uleb(out, daddr); }
      int fe = file_table_index(r->file);
      if (fe != cur_file_entry) { u8_(out, DW_LNS_set_file); uleb(out, (unsigned long)fe); cur_file_entry = fe; }
      if (dline >= LINE_BASE && dline < LINE_BASE + LINE_RANGE) {
        // 特殊操作码：一次同时推进行号并"发一行"（addr 前进 0）——省掉 advance_line + copy 两条
        u8_(out, (unsigned)(OPCODE_BASE + (dline - LINE_BASE)));
      } else {
        if (dline) { u8_(out, DW_LNS_advance_line); sleb(out, dline); }
        u8_(out, DW_LNS_copy);
      }
      prev_off = r->off;
      prev_line = r->line;
      row++;
    }
    // 把地址寄存器推到函数末尾**再**收尾 —— 否则 end_sequence 落在最后一条语句的起始地址上，
    //   那条语句的范围会被压成空（实测：addr2line 对末地址返回 `??:0`）。
    if (fend > prev_off) { u8_(out, DW_LNS_advance_pc); uleb(out, (unsigned long)(fend - prev_off)); }
    buf_byte(out, 0); uleb(out, 1); u8_(out, DW_LNE_end_sequence);   // 每条 sequence 必须收尾
  }
  buf_patch_u32(out, unit_len_at, (uint32_t)(out->len - (unit_len_at + 4)));
}

// ========== ④ 私有腿：TSV（同源，补标准不提供的维度）==========
// 列：源文件 / 行 / 节 / .text 内偏移 / 绝对地址(VA) / 文件偏移 / 字节数
void debug_build_tsv(GenResult *gen, uint32_t text_rva, uint32_t text_raw_ptr, const char *exe_name, Buf *out) {
  buf_init(out);
  char hdr[512];
  int hn = snprintf(hdr, sizeof(hdr),
      "# FLINT 可审计发射层 TSV（v1.4.11）—— 与产物内 DWARF 行表**同源**（同一张内部表生成，不是两套真值）\n"
      "# exe: %s\n"
      "# 列：src_file\\tsrc_line\\tsection\\toff_in_text\\tva\\tfile_offset\\tbyte_len\n"
      "# 说明：DWARF 行表只给 (地址, 文件, 行)；本表补标准**不提供**的三个维度：字节区间 / 文件偏移 / 所属节。\n"
      "src_file\tsrc_line\tsection\toff_in_text\tva\tfile_offset\tbyte_len\n",
      exe_name ? exe_name : "?");
  if (hn > 0) buf_bytes(out, (const uint8_t *)hdr, (size_t)hn);
  for (size_t i = 0; i < gen->ndbg_rows; i++) {
    DebugRow *r = &gen->dbg_rows[i];
    const char *nm = (r->file >= 0) ? src_file_name(r->file) : NULL;
    char line[1024];
    int n = snprintf(line, sizeof(line), "%s\t%d\t.text\t0x%zX\t0x%llX\t0x%zX\t%zu\n",
                     nm ? nm : "<unknown>", r->line,
                     r->off,
                     (unsigned long long)0x140000000ULL + text_rva + r->off,
                     (size_t)text_raw_ptr + r->off,       // .text 内偏移 → 文件偏移（.text RawPtr 由调用方给）
                     r->len);
    if (n > 0) buf_bytes(out, (const uint8_t *)line, (size_t)n);
  }
}

// ========== ⑤ 第三份调试信息：帧表（D-3）+ 变量位置表（D-1）→ `<输出>.dbg.json` ==========
// 为什么必须是编译器出、且必须是 JSON：
//   · **帧表**：我们的 PE 没有 `.pdata`（`test\wx-verify.ps1` 守着产物 W^X、无 unwind 信息），
//     Windows 的 `StackWalk64` 只能吃 `.pdata`/FPO ⇒ 对它无效。栈回溯只能由调试器按
//     「帧大小 + 返回地址偏移 + 保存寄存器 + 序言/尾声区间」自己走 ⇒ 这些数只有发射现场知道。
//   · **变量位置**：DWARF 腿只发 `.debug_line`（最小 CU，无子 DIE），标准工具能回答"地址是哪一行"，
//     回答不了"变量在第几字节"。让调试器去源码里猜类型/槽位必然与编译器分叉 ⇒ 必须编译器出。
//   · JSON：本仓没有链接器/符号表机制可挂，JSON 人和机器都能读，也不需要两边版本对齐 DWARF 的
//     生产者/消费者规则（一旦对不上就是静默错位）。
// 字段口径（调试器**直接**拿去做地址运算，改一个就是破坏契约）：
//   start / end       函数在镜像里的绝对地址（= 0x140000000 + text.rva + 函数内偏移；与 .tsv 同坐标系，end 不含）
//   frame.size        序言 `sub rsp, imm` 的 imm（大帧多段 sub 时 = 各段之和；没有 sub = 0）
//   frame.pushBytes   被调者保存寄存器 push 的总字节数
//   frame.retAddrOff  返回地址相对 rbp 的偏移（本仓 8；取自序言 `push rbp` 的字节数）
//   frame.savedRegs   按 **push 顺序** 的寄存器名（rbx/r12/r13/r14/r15）
//   frame.prologue    序言字节区间（start = 函数起点；调试器判"PC 是否还在序言里"）
//   frame.epilogue    尾声字节区间（写回首条指令 → leave/ret 或 call ExitProcess）
//   vars[].slot       rbp 相对偏移 = -LVar.offset（数组/结构体 = **首槽**）
//   vars[].type       FLINT 写法（`int` / `int_64` / `char*` / `uint_32` / `int[5]` / `struct Point`）
//   vars[].kind       local / param / aggregate（数组、结构体值变量）
//   vars[].line       声明所在源码行（1 起）
// 同源：全部来自 GenResult.dbg_funcs —— 帧字段是 codegen_func 在**发射现场**记的，变量表是 parse 的
//   LVar 链（与分槽同一张表）。本函数**只排版**，不重算、不反汇编、不再解析源码。
// 确定性：函数按 (start) 升序；变量按 (slot, name) 升序；不写时间戳、不写绝对路径（exe 字段是调用方
//   给的原样输出路径）⇒ 同输入两次编译逐字节相同（`debug` 门 [8] 用 SHA256 守）。
static void jstr(Buf *b, const char *s) {
  buf_byte(b, '"');
  const unsigned char *p = (const unsigned char *)(s ? s : "");
  for (; *p; p++) {
    switch (*p) {
      case '"':  buf_bytes(b, (const uint8_t *)"\\\"", 2); break;
      case '\\': buf_bytes(b, (const uint8_t *)"\\\\", 2); break;
      case '\n': buf_bytes(b, (const uint8_t *)"\\n", 2); break;
      case '\r': buf_bytes(b, (const uint8_t *)"\\r", 2); break;
      case '\t': buf_bytes(b, (const uint8_t *)"\\t", 2); break;
      default:
        if (*p < 0x20 || *p >= 0x80) {
          // 控制符与**非 ASCII 字节**一律 \u00XX 转义：保证输出文件**永远是合法 UTF-8/JSON**。
          // 为什么不做编码转换：`-o` 路径来自 argv（中文 Windows 上是 ANSI/GBK 字节，UTF-8 控制台上是
          //   UTF-8 字节），纯 C 无法判断它是哪种编码；照原样写出会让 JSON 在非 ASCII 路径下**非法**
          //   （实测：GBK 路径写出 4 个非法字节，严格解析器直接拒收）。所以这里只保证"可解析"，
          //   需要真实路径时请用「产物路径 + .dbg.json」定位（调试器本来就拿得到产物路径）。
          //   ASCII 路径（门与日常用法）输出与本转义无关 ⇒ 逐字节不受影响。
          char esc[8];
          snprintf(esc, sizeof(esc), "\\u%04X", (unsigned)*p);
          buf_bytes(b, (const uint8_t *)esc, 6);
        } else {
          buf_byte(b, *p);   // ASCII 原样（本仓标识符/结构体名都是 ASCII）
        }
    }
  }
  buf_byte(b, '"');
}
static void jraw(Buf *b, const char *s) { buf_bytes(b, (const uint8_t *)s, strlen(s)); }
static void jint(Buf *b, long long v) {
  char t[32];
  int n = snprintf(t, sizeof(t), "%lld", v);
  if (n > 0) buf_bytes(b, (const uint8_t *)t, (size_t)n);
}

static const char *saved_reg_name(int r) {
  switch (r) {
    case 0: return "rbx";
    case 1: return "r12";
    case 2: return "r13";
    case 3: return "r14";
    case 4: return "r15";
    default: return "?";
  }
}
static const char *var_kind_name(int k) {
  return k == 1 ? "param" : k == 2 ? "aggregate" : "local";
}

static int cmp_span_ptr(const void *a, const void *b) {
  const DebugFuncSpan *x = *(const DebugFuncSpan *const *)a;
  const DebugFuncSpan *y = *(const DebugFuncSpan *const *)b;
  if (x->off != y->off) return x->off < y->off ? -1 : 1;
  return 0;   // 偏移唯一（函数不重叠）⇒ 不需要二级键
}
static int cmp_var_ptr(const void *a, const void *b) {
  const DebugVar *x = *(const DebugVar *const *)a;
  const DebugVar *y = *(const DebugVar *const *)b;
  if (x->slot != y->slot) return x->slot < y->slot ? -1 : 1;
  int c = strcmp(x->name ? x->name : "", y->name ? y->name : "");
  return c;
}

void debug_build_map(GenResult *gen, uint32_t text_rva, uint32_t text_raw_ptr,
                     const char *exe_name, Buf *out) {
  buf_init(out);
  int nf = gen->ndbg_funcs;
  DebugFuncSpan **fs = NULL;
  if (nf > 0) {
    fs = (DebugFuncSpan **)malloc((size_t)nf * sizeof(DebugFuncSpan *));
    if (!fs) { fprintf(stderr, "hlc: 内存不足\n"); exit(1); }
    for (int i = 0; i < nf; i++) fs[i] = &gen->dbg_funcs[i];
    qsort(fs, (size_t)nf, sizeof(DebugFuncSpan *), cmp_span_ptr);
  }

  jraw(out, "{\n  \"version\": 1,\n  \"exe\": ");
  jstr(out, exe_name ? exe_name : "?");
  jraw(out, ",\n  \"text\": { \"rva\": ");
  jint(out, (long long)text_rva);
  jraw(out, ", \"rawPtr\": ");
  jint(out, (long long)text_raw_ptr);
  jraw(out, " },\n  \"functions\": [");

  for (int f = 0; f < nf; f++) {
    DebugFuncSpan *sp = fs[f];
    unsigned long long fstart = (unsigned long long)0x140000000ULL + text_rva + sp->off;
    unsigned long long fend   = fstart + sp->len;
    jraw(out, f ? ",\n    {\n" : "\n    {\n");
    jraw(out, "      \"name\": ");
    jstr(out, sp->name ? sp->name : "?");
    jraw(out, ",\n      \"start\": ");
    jint(out, (long long)fstart);
    jraw(out, ", \"end\": ");
    jint(out, (long long)fend);
    jraw(out, ",\n      \"frame\": { \"size\": ");
    jint(out, (long long)sp->frame_size);
    jraw(out, ", \"pushBytes\": ");
    jint(out, (long long)sp->push_bytes);
    jraw(out, ", \"retAddrOff\": ");
    jint(out, (long long)sp->ret_addr_off);
    jraw(out, ", \"savedRegs\": [");
    for (int k = 0; k < sp->nsaved && k < 8; k++) {
      if (k) jraw(out, ",");
      jraw(out, "\"");
      jraw(out, saved_reg_name(sp->saved_regs[k]));
      jraw(out, "\"");
    }
    jraw(out, "],\n                 \"prologue\": { \"start\": ");
    jint(out, (long long)fstart);                    // 序言恒从函数首字节开始
    jraw(out, ", \"len\": ");
    jint(out, (long long)sp->prolog_len);
    jraw(out, " },\n                 \"epilogue\": { \"start\": ");
    jint(out, (long long)(fstart + sp->epilog_off));
    jraw(out, ", \"len\": ");
    jint(out, (long long)sp->epilog_len);
    jraw(out, " } },\n      \"vars\": [");

    // 变量：**副本排序**（不动 parse 建的那张表：它是唯一真值，别在这里改顺序）
    int nv = sp->nvars;
    if (nv > 0 && sp->vars) {
      DebugVar **vs = (DebugVar **)malloc((size_t)nv * sizeof(DebugVar *));
      if (!vs) { fprintf(stderr, "hlc: 内存不足\n"); exit(1); }
      for (int i = 0; i < nv; i++) vs[i] = &sp->vars[i];
      qsort(vs, (size_t)nv, sizeof(DebugVar *), cmp_var_ptr);
      for (int i = 0; i < nv; i++) {
        DebugVar *v = vs[i];
        jraw(out, i ? ",\n        { \"name\": " : "\n        { \"name\": ");
        jstr(out, v->name ? v->name : "?");
        jraw(out, ", \"type\": ");
        jstr(out, v->type);
        jraw(out, ", \"kind\": ");
        jstr(out, var_kind_name(v->kind));
        jraw(out, ", \"slot\": ");
        jint(out, (long long)v->slot);
        jraw(out, ", \"line\": ");
        jint(out, (long long)v->line);
        jraw(out, " }");
      }
      free(vs);
      jraw(out, "\n      ]\n    }");
    } else {
      jraw(out, "]\n    }");
    }
  }
  jraw(out, nf ? "\n  ]\n}\n" : "]\n}\n");
  free(fs);
}
