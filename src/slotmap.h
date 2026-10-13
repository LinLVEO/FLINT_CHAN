// slotmap.h — FLINT 映射层接口（IR 重构 M1 归口 / M2 位置表 / M3 基本块边界）
// 设计与迁移计划：E:\FLINT-lab\IR重构-设计与迁移计划.md（判据见该文 §三）
//
// 三层分工（**纪律，不许越界**）：
//   ① 生成层（codegen.c 的 gen_expr / gen_stmt）——**只调 slot_\***，不写帧槽寻址的编码细节
//   ② 映射层（slotmap.c，本接口）——"槽 → 位置"表 + 槽访问的机器码发射；**将来寄存器分配住在这里**
//   ③ 发射层（codegen.c 的 emit_\*）——只负责把一条指令编成字节
//
// 为什么这么切（2026-09-19 实测教训）：曾在"到处直接 emit"的代码上挂了 5 个优化钩子
//   （变量读/写、发标签、发跳转、调用点），钩子互相打架把返回值清掉 —— 回归 679/94、boot 55/155。
//   收敛成单一出口后，"忘刷 / 忘失效"这类 bug 只需审一个文件的一段。
//
// 审计：`test\映射层审计.ps1` 断言「帧槽偏移的编码（-off 掩码）只允许出现在 slotmap.c」，
//   并断言映射层里没有 AST 字样（映射层不许理解 AST）。
#ifndef FLINT_SLOTMAP_H
#define FLINT_SLOTMAP_H

#include "flint.h"

// —— 槽位置种类（M2：全部是内存 MEM；REG 是 M4 的目标）——
enum { SLOTK_MEM = 0, SLOTK_REG = 1 };

// —— 槽属性位：**任何一条命中 ⇒ 该槽钉死在内存**（M4 一律不许给它寄存器）——
enum {
  SF_ADDRESSED = 1u << 0,  // 被取过地址（slot_lea_rax 走过）
  SF_AGGREGATE = 1u << 1,  // 数组 / 结构体（按首槽寻址）
  SF_MANAGED   = 1u << 2,  // own / share 托管指针（函数出口要释放）
  SF_PARAM     = 1u << 3,  // 形参槽
  SF_SCRATCH   = 1u << 4,  // 帧底暂存槽（编译器自用）
  SF_REF       = 1u << 5,  // 引用槽（槽里存的是对象地址）
  SF_T1ADDR    = 1u << 6,  // v1.0.13 T1「装地址的 int」槽
  SF_CROSSCALL = 1u << 7,  // 跨调用存活（函数内有调用，且该槽在调用前后都被访问）
  SF_WIDE      = 1u << 8,  // 有过 8 字节（64 位）访问（记录用，不参与判定）
  SF_MULTIBB   = 1u << 9,  // M3：访问跨越**多个基本块** ⇒ M4 条件 ④ 不满足（这类槽不许分配寄存器）
};
// 钉死集合（M4 条件 ②③④⑤ 的并集；CROSSCALL / MULTIBB = 条件⑤④ 的槽级表现）
#define SF_PINNED (SF_ADDRESSED | SF_AGGREGATE | SF_MANAGED | SF_PARAM | \
                   SF_SCRATCH | SF_REF | SF_T1ADDR | SF_CROSSCALL | SF_MULTIBB)
// M4 **静态**不许进寄存器的槽（条件 ①②③）：取址 / 数组结构体 / 托管 / 形参 / 暂存 / 引用 / T1 装地址。
//   跨块（SF_MULTIBB）与跨调用（SF_CROSSCALL）**不在这张表里** —— 分配口径是**函数作用域**，
//   两者对"全程寄存器"都不构成问题（跨调用另有生成层的序言垫保 rsp 对齐）；M5 ② 起
//   SF_ADDRESSED 由生成层**静态**申报（"这个变量被取过地址"），不再靠发射期"降级"兜底
//   —— 降级会中途改位置，跳过降级点的路径读到没初始化的内存槽（见 slotmap.c 的位置纪律）。
#define SF_NOREG (SF_ADDRESSED | SF_AGGREGATE | SF_MANAGED | SF_PARAM | \
                  SF_SCRATCH | SF_REF | SF_T1ADDR)

// —— 基本块边界的"理由"（M3：只记录、不动作；M4 起 = **失效与写回的唯一来源**）——
// 生成层只在三处打点：emit_label（块的入口 = 跳转/分支的落点）、emit_jmp_label（返跳转结束当前块）、
//   emit_jcc_label（条件跳转结束当前块；落空的那条边从下一条指令继续 = 新块）；调用点由 note_call 顺带打。
enum { BB_LABEL = 0, BB_JMP, BB_JCC, BB_CALL, BB_REASON_N };

// 一个函数的槽表小结（`-stats` 用）。
// candidates 已按 M4 条件 ①TY_INT ②未取址 ③非数组/结构体/托管/参数/引用/暂存 ④单基本块内 筛过
//   （④ 自 M3 起可判：跨块的槽记 SF_MULTIBB 并被剔除）；
//   条件 ⑤（本函数无调用）不在这里剔除，看 has_call 自己判。
typedef struct {
  int slots;      // 本函数申报的槽数
  int addressed;  // 被取址
  int crosscall;  // 跨调用存活
  int multibb;    // 跨基本块（M3）
  int managed;    // own/share 托管
  int aggregate;  // 数组/结构体
  int param;      // 形参
  int scratch;    // 暂存槽
  int candidates; // 可分配候选（严格：过 ①②③④ —— 条件④ = 只在单个基本块内出现）
  int cand_block; // 可分配候选（按"基本块作用域"口径：过 ①②③，**不看④** —— 每个块各自 load/store，
                  //   内存仍是块边界的权威值，因此不需要跨块活跃性分析；M4 采用哪一口径由账本定）
  int has_call;   // 本函数是否有调用（M4 条件 ⑤；M5 ② 曾试行放开、实测 boot 门红 ⇒ 回退）
  int bb;         // 基本块数（M3：初值 1，每个边界 +1）
  int bb_reasons[BB_REASON_N];  // 边界理由计数：label / jmp / jcc / call
  // —— M4 实测数字 ——
  int reg_slots;  // 本函数真正分到寄存器的槽数
  int reloads;    // 块内首次访问的"内存 → 寄存器"装载次数
  int spills;     // 块边界处"寄存器 → 内存"写回次数
} SlotSummary;

// ===== 生命周期（codegen_func 每函数各调一次）=====
void slotmap_begin_function(Buf *code);                   // 清表 + 纪元/基本块归零；code = 本函数代码缓冲
void slotmap_declare(int off, int ty, unsigned flags);    // 申报一个槽（生成层按 AST/签名申报）
void slotmap_note_call(void);                             // 每个调用点调一次（推进"调用纪元" + 打 BB_CALL 边界）
void slotmap_bb_boundary(int reason);                     // M3：基本块边界（**只记录**，不动发射）
void slotmap_flush_all(void);                             // M4：唯一出口前调一次（脏寄存器写回内存）
void slotmap_summary(SlotSummary *out);                   // 取本函数小结
int  slotmap_has_call(void);

// ===== M4：寄存器分配第一档（函数作用域）=====
// `slotmap_plan_regs` 由生成层在**函数体发射之前**调用（此时槽表已申报完）：
//   M5 ②（v1.4.27）起**带调用的函数也分配**（has_call 参数保留只为账本/兼容，不再当门槛）——
//   callee-saved 跨调用天然安全，调用点 rsp 对齐由生成层的序言垫兜（见 codegen_func 的 reg_pad）。
//   ⚠️ 一次失败记录（M5 ② 首次尝试）：boot 门 183/27，真因是映射层的"发射中途降级"
//      （跳过降级点的路径读到未初始化的内存槽）—— 修法写在 slotmap.c 的位置纪律里。
//   返回分配到的寄存器个数；随后生成层用 `slotmap_regs_allocated` 取号、在序言 push / 收尾 pop（**次序相反**）。
int  slotmap_plan_regs(int has_call);
int  slotmap_regs_allocated(int *out, int cap);

// ===== M5 ①：数组元素寻址与元素就地运算（帧槽基址 ＋ 索引 × 步长）=====
// 为什么在这层：`[rbp-off]` 与 SIB 的编码是"位置 → 机器码"的事，按 M1 纪律只允许出现在 slotmap.c。
// 背景（bench k2 实测）：`a[j & 3] = a[j & 3] + i` 老序列每个元素访问要 **8 条**只为算出"帧基址 + 下标×8"
//   （lea 基址 → push rax → 算下标 → imul 8 → movsxd rcx → pop rax → add），而**本地数组的基址是编译期常量**
//   （rbp-off）⇒ 一条 `[rbp-off+idx*8]` 直接寻址就够；元素本身还能就地运算（`add [元素], rSrc`）。
// 两种寻址形态（生成层填好再调；映射层只管编码）：
//   · 常量下标：`has_idx = 0`，位移 = cidx*scale - base_off（折进 disp8/disp32）
//   · 变量下标：`has_idx = 1`，**索引必须已经在 eax/rax**（生成层负责求值 + 把关"已知非负"，见 codegen
//     的 is_nonneg_idx：SIB 用的是零扩展索引，老路径是 movsxd 符号扩展 ⇒ 只有非负才等价）
// 元素宽度 = 4 字节（与 `p[i]` / `a[i]` 的既有读写宽度一致）。
typedef struct {
  int base_off;   // 数组槽偏移（帧内；[rbp - base_off]）
  int scale;      // 元素步长（int 元素 = 8）
  int has_idx;    // 1 = 索引在 eax/rax；0 = 下标是编译期常量 cidx
  int cidx;       // 常量下标（仅 has_idx == 0）
} ElemAddr;

void slot_elem_lea(Buf *b, const ElemAddr *ea);                    // rax ← &元素
void slot_elem_add_imm(Buf *b, const ElemAddr *ea, int imm);       // dword [元素] += imm
void slot_elem_and_imm(Buf *b, const ElemAddr *ea, int imm);       // dword [元素] &= imm
void slot_elem_add_slot(Buf *b, const ElemAddr *ea, int src_off);  // dword [元素] += rSrc（src 须是寄存器槽）
void slot_elem_inc(Buf *b, const ElemAddr *ea);                    // dword [元素]++
void slot_elem_dec(Buf *b, const ElemAddr *ea);                    // dword [元素]--
void slot_elem_add_to_reg(Buf *b, const ElemAddr *ea, int dst_off);// rDst += dword [元素]（dst 须是寄存器槽）

// 指针槽基址（`p[i]`：基址是槽里的 64 位值，不是编译期常量）
void slot_load_ptr_rcx64(Buf *b, int off);   // rcx ← [槽]（64 位；**不碰 rax**）
void slot_lea_ptr_idx_rax(Buf *b, int scale); // rax ← [rcx + rax*scale]
// M6 ①：常量下标折进位移 —— rax ← [rcx + disp]（disp = cidx*scale，调用方保证装得进 disp32）
// 为什么要它：`p[2]` 老路径 10 条（mov 槽→rax / imul 常量 / movsxd / add / …），本形态 **3 条**
// （mov rcx,[槽] + lea rax,[rcx+disp]；槽在寄存器时 2 条）。
void slot_lea_ptr_disp_rax(Buf *b, long disp);

// ===== M5 ③：比较就地化（32 位 int 语义；flags = [lhs] - [rhs]）=====
// 病：`while (i < n)` 老路是 `mov i→eax / mov n→ecx / cmp eax,ecx` —— 三条里两条纯搬运。
// 就地形态按两侧各自的位置（寄存器槽 / 内存槽）挑编码，最省一条 `cmp rS,[rbp-n]`。
// 返回 false = 这一对操作数不吃就地形态（调用方退老路径，**不做半吊子**）。
// ⚠️ 只许用在「普通 32 位 int 调用数」上（生成层负责筛：与 try_load_var_to_ecx 同一套条件）——
//    char/double/引用/全局/T1 装地址槽的宽度语义各不相同，走这里就是静默错值。
bool slot_cmp_slots(Buf *b, int lhs_off, int rhs_off);   // 槽 vs 槽
bool slot_cmp_slot_imm(Buf *b, int off, int imm);        // 槽 vs 常量（flags = [槽] - imm）

// ===== M6 ④（2026-09-19）：这些访问器里 sl_demote 的不可达性（逐族论证，别再靠记性）=====
// 仍在调 sl_demote 的 10 处 = 本文件的访问器：取址（slot_lea_rax）/ 64 位族（slot_load_rax64、
//   slot_store_rax64）/ 字节族（load·store·inc·dec byte）/ double 族（load·store·store_xmm）
//   ＋ 形参装载族（slot_store_rcx64 / rdx64 / r8_64 / r9_64 / ecx / edx / r8d / r9d）。
// 它们**命中不了**寄存器槽，靠三道门（判定顺序 = slotmap_plan_regs 里的实现）：
//   ① 类型门：只有 ty == TY_INT 的槽会被分配 ⇒ 指针/引用/函数指针（64 位族）、char（字节族）、
//      double（double 族）**永远不是** SLOTK_REG；形参槽另被 ② 挡住。
//   ② 钉死门：SF_NOREG（取址 / 数组结构体 / 托管 / 形参 / 暂存 / 引用 / T1 装地址）不进分配
//      ⇒ slot_lea_rax（取址）与形参装载族都被这一条挡在门外。
//   ③ 申报漏了才会漏进来 —— 所以 plan_regs 里对 ADDRESSED 槽加了**计划期当场断言**（响亮失败）。
// 判据 = 实测：全量门跑下来 0 次触发（见 slotmap.c 里 M6 ④ 那段注释）。

// ===== M4 融合路径（生成层在"表达式值没人用"的语句里调；**只对寄存器槽有效**）=====
// 为什么需要：寄存器化之后 `x = x + j` 的老序列是"搬进 eax → 搬进 ecx → 加 → 搬回寄存器"，
//   五次搬运换一次加法 —— 实测（2026-09-19 bench k1）这一项就吃掉了大半收益。
//   这类"自反运算且值没人用"的语句可以**就地算**：一条 `add r32,r32` 顶五条。
//   ⚠️ 只能用在值没人用的地方（表达式语句）；`y = (x = x+1)` 这种要用值的必须走老路径。
int  slotmap_kind_of(int off);                            // SLOTK_MEM / SLOTK_REG（融合路径的开关）
void slot_self_add_imm(Buf *b, int off, int imm);         // 槽 += imm（32 位，就地）
void slot_self_sub_imm(Buf *b, int off, int imm);         // 槽 -= imm（就地）
void slot_self_add_slot(Buf *b, int off, int other);      // 槽 += 另一个槽（就地）
void slot_self_and_imm(Buf *b, int off, int imm);         // 槽 &= imm（就地）

// ===== 映射层出口：槽访问（生成层只许调这一族；帧槽偏移的编码只在本层出现）=====
void slot_lea_rax(Buf *b, int off);        // rax ← &槽
void slot_load_eax(Buf *b, int off);       // eax ← 槽（32 位）
void slot_store_eax(Buf *b, int off);      // 槽 ← eax
void slot_load_ecx(Buf *b, int off);       // ecx ← 槽（32 位）
void slot_load_rcx64(Buf *b, int off);     // rcx ← 符号扩展后的槽（dword → 64 位）
void slot_load_rax64(Buf *b, int off);     // rax ← 槽（64 位）
void slot_store_rax64(Buf *b, int off);    // 槽 ← rax（64 位）
void slot_load_byte(Buf *b, int off);      // eax ← 槽低字节（movzx）
void slot_store_byte(Buf *b, int off);     // 槽低字节 ← al
void slot_load_dbl(Buf *b, int off);       // xmm0 ← 槽（movsd）
void slot_store_dbl(Buf *b, int off);      // 槽 ← xmm0（movsd）
void slot_store_dbl_xmm(Buf *b, int off, int xi);  // 槽 ← xmm{xi}（double 形参落槽）
void slot_inc_mem(Buf *b, int off);        // 槽++（dword，不碰 eax）
void slot_dec_mem(Buf *b, int off);        // 槽--（dword，不碰 eax）
void slot_inc_byte(Buf *b, int off);       // 槽低字节++（不碰邻字节）
void slot_dec_byte(Buf *b, int off);       // 槽低字节--
// 形参装载：寄存器 → 形参槽（普通函数序言用；32/64 位两档）
void slot_store_ecx(Buf *b, int off);
void slot_store_edx(Buf *b, int off);
void slot_store_r8d(Buf *b, int off);
void slot_store_r9d(Buf *b, int off);
void slot_store_rcx64(Buf *b, int off);
void slot_store_rdx64(Buf *b, int off);
void slot_store_r8_64(Buf *b, int off);
void slot_store_r9_64(Buf *b, int off);

// ===== 由 codegen.c 实现（`-stats` 的栈槽/指令账本；映射层不碰统计状态）=====
// insns = 本次访问算几条指令（0 = 不进账本，与归口前的口径**逐处一致**）。
void slotmap_stats_access(int off, int wide, int insns);

#endif
