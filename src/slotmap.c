// slotmap.c — FLINT 映射层（M1 归口 / M2 位置表 / M3 基本块边界 / M4 寄存器分配第一档）
//
// 职责（详见 IR重构-设计与迁移计划.md §二、§四）：
//   ① **帧槽访问的唯一出口** —— 生成层（gen_expr/gen_stmt）只调本文件的 slot_*；
//      "帧槽偏移 → 机器码"的编码细节**只允许出现在本文件**（审计：test\映射层审计.ps1）。
//   ② **"槽 → 位置"表**（M2）：每槽一条记录 —— 位置种类（MEM / REG）、属性位（被取址 / 数组结构体 /
//      托管 / 形参 / 暂存 / 引用 / T1 装地址 / 跨调用 / 跨基本块）、访问计数、寄存器驻留状态。
//   ③ **跨调用存活**（M2）：每个调用点推进一个"调用纪元"，某槽在两个不同纪元都被访问 ⇒ SF_CROSSCALL。
//   ④ **基本块边界**（M3）：`slotmap_bb_boundary(reason)` 在 label/jmp/jcc/call 四处打点，**只记录**
//      （块号、边界理由、每个槽跨了几个块）。**它不再承担 M4 的失效职责** —— 见下条口径变更。
//   ⑤ **寄存器分配第一档**（M4；M5 ② 起条件⑤ 放开）：对满足条件的槽（TY_INT ＋ 非取址/数组结构体/
//      托管/形参/暂存/引用/T1）把"槽"直接映射到 callee-saved 寄存器，**作用域 = 整个函数**：
//      函数内首访（读）从内存 load 一次，此后寄存器就是权威值（写只写寄存器并记脏），
//      **唯一出口前** `slotmap_flush_all()` 一次性写回。序言 push / 收尾 pop 由生成层发
//      （`slotmap_regs_allocated` 给号），映射层只负责"用哪个寄存器、什么时候 load/store"。
//      **带调用的函数也分配**（M5 ②）：callee-saved 跨调用天然安全，调用点 rsp 对齐由生成层补垫。
//      **位置纪律（M5 ② 用一次 boot 门红换来的）**：一个槽的位置**只许在发射函数体之前定死**
//      （要么全程寄存器、要么全程内存）。发射中途改位置在**跨路径**上不可能自洽：改位置那一处
//      的 flush 只覆盖"执行到那一条"的路径，跳过它的路径（另一分支/递归的另一份）会读到**从未
//      初始化**的内存槽 ⇒ 静默错值。因此：
//        · 需要"内存地址"的形态（取址 `&x` / 引用绑定）⇒ 生成层**静态钉死**（SF_ADDRESSED，走内存）；
//        · 只需要"宽度/形态"的访问器（movsxd / 64 位 / 字节 / double）⇒ **补寄存器路径**；
//        · 两者都漏掉时，`sl_demote` 报**内部错误**（响亮失败，不静默错值）。
//
// ⚠️ **口径变更记录（实测驱动，2026-09-19）**：M4 第一版按"**基本块作用域**"实现（每个块边界把脏值
//   写回内存、新块首访重新 load，原计划 §四 ④ 的字面口径）。实测 `bench\对账2.ps1`：**k1 反而从
//   2.596 掉到 3.007 ns/轮**（k2/k3 同样变慢）—— 循环携带变量（计数器 x/j）在每个边界都要"存一次再读回来"，
//   等于**把原来的直接访存换成了"访存 + 寄存器搬运"**，白付寄存器开销。⇒ 改成**函数作用域**：
//   寄存器在整函数内是权威值、只有出口写一次。**正确性依赖两条**（都已具备）：
//     ① 槽的访问**只有这一个出口**（M1 审计门守着）⇒ 不存在"绕过寄存器直接读写内存"的路径；
//     ② 任何可能让**别人**看到该槽内存地址的路径（取址）⇒ 生成层**静态**把它钉死回内存
//        （M5 ② 起；此前是发射期"降级"，跨路径不安全 —— 见上面的位置纪律）。
//   这样既不需要跨块活跃性分析（原④的用意），又能真正把循环变量留在寄存器里。
//
// ⚠️ 本文件**不许出现 AST 字样**（映射层不理解 AST）：槽的属性由生成层用 slotmap_declare 申报进来。
// ⚠️ M1~M3 全程**零行为变化**（等价门 193 条指纹守着）；**M4 有意改发射形状** —— 判据走计划 §五
//   （等价门 `-UpdateFingerprint -Reason` 记变更清单，其余行为判据一条不放松）。

#include <stdio.h>
#include <stdlib.h>

#include "flint.h"
#include "slotmap.h"

// ===== 槽表（每函数一份，slotmap_begin_function 清空）=====
typedef struct {
  int off;             // 槽偏移（距 rbp；本函数内唯一键）
  int ty;              // 变量类型（Type；TY_INT = 0 —— M4 只对 TY_INT 分配）
  unsigned kind;       // SLOTK_MEM / SLOTK_REG（M4：分配到的槽在函数内恒为 REG，除非被降级）
  unsigned flags;      // SF_* 属性位
  unsigned loads;      // 读次数（含取址）
  unsigned stores;     // 写次数
  int epoch_last;      // 最近一次访问时的调用纪元（判跨调用用）
  int bb_first;        // 首次访问时的基本块号（判"单基本块内"用）
  int touched;         // 是否被访问过
  // —— M4：寄存器驻留状态 ——
  int reg;             // 寄存器号（REGS 下标；仅 kind==SLOTK_REG 有意义）
  int in_reg;          // 寄存器里是否已有有效值（首次读时从内存 load 一次；此后一直有效）
  int dirty;           // 寄存器里的值是否比内存新（唯一出口写回/降级时要 store）
} SlotLoc;

static SlotLoc *g_sl = NULL;
static int g_nsl = 0, g_slcap = 0;
static int g_epoch = 0;      // 调用纪元：每遇一个调用点 +1
static int g_had_call = 0;   // 本函数是否有过调用
static int g_bb = 1;         // 当前基本块号（M3：从 1 起；边界处 +1）
static int g_bb_reasons[BB_REASON_N];  // 边界理由计数（本函数）
static Buf *g_code = NULL;   // 本函数的代码缓冲（M4：边界写回要用它发字节）
static int g_nreg = 0;       // 本函数分配到的寄存器个数
static unsigned long g_reloads_now = 0, g_spills_now = 0;  // M4 实测计数（本函数）

// ===== 可用的 callee-saved 寄存器（Win64 ABI：rbx / r12 / r13 / r14 / r15）=====
// regbits = ModRM.reg 的三位；rex_r = 该寄存器在 **reg 域** 时需要的 REX 前缀（0x44 = REX.R）；
//   rex_b = 该寄存器在 **rm 域** 时需要的 REX 前缀（0x41 = REX.B）。32 位操作 ⇒ W=0。
typedef struct { int regbits; uint8_t rex_r; uint8_t rex_b; const char *name; } RegDef;
static const RegDef REGS[] = {
  { 3, 0x00, 0x00, "rbx" },
  { 4, 0x44, 0x41, "r12" },
  { 5, 0x44, 0x41, "r13" },
  { 6, 0x44, 0x41, "r14" },
  { 7, 0x44, 0x41, "r15" },
};
// ===== M6 ③A（2026-09-19）：可用寄存器池 2 → 5 =====
// 为什么必须扩：M5 ② 放开条件⑤ 之后，带调用的函数每个"跨调用存活的 int 槽"都要占一个 callee-saved 寄存器；
//   k3 这种"累加值 ＋ 计数器 ＋ 返回值"三个都要活的循环，池子只有 rbx/r12 两个 ⇒ 最热的那一个
//   每轮被 push/pop 到栈上（反汇编逐条数过：循环体 10 条里 2 条是这个搬运）。
//   池子扩到 Win64 允许的全部 5 个（rbx/r12/r13/r14/r15）后，分配器的口径不变（装不下就退回内存，
//   **不引入 spill/回写**），只是"装得下"的阈值变宽。
// 安全性（都已具备，不是新增语义）：
//   · 序言 push / 收尾逆序 pop 的编码表本来就覆盖 0~4 号（codegen 的 emit_push_saved_reg / pop）；
//   · 调用点 rsp 对齐：生成层按 push 个数奇偶补 8 字节垫 ⇒ 池子变大不破坏 ≡0（仍是同一条规则）；
//   · 全部编码器都从 REGS[reg] 取 regbits/rex_r/rex_b，r13/r14/r15 的 REX 位本来就走同一条路。
// ⚠️ 只有 Win64 的 callee-saved 才能进池（rbx/r12~r15）—— 换 ABI 要改这里和 codegen 的 push/pop 表。
#define SLOT_REG_POOL 5

// mov r32, [rbp-off]（rex_r：目标在 reg 域）
static void sl_enc_load(Buf *b, int r, int off) {
  const RegDef *d = &REGS[r];
  if (d->rex_r) buf_byte(b, d->rex_r);
  if (off <= 127) {
    buf_byte(b, 0x8B);
    buf_byte(b, (uint8_t)(0x45 | (d->regbits << 3)));
    buf_byte(b, (uint8_t)(-off & 0xFF));
  } else {
    buf_byte(b, 0x8B);
    buf_byte(b, (uint8_t)(0x85 | (d->regbits << 3)));
    buf_u32(b, (uint32_t)(-off));
  }
}
// mov [rbp-off], r32
static void sl_enc_store(Buf *b, int r, int off) {
  const RegDef *d = &REGS[r];
  if (d->rex_r) buf_byte(b, d->rex_r);
  if (off <= 127) {
    buf_byte(b, 0x89);
    buf_byte(b, (uint8_t)(0x45 | (d->regbits << 3)));
    buf_byte(b, (uint8_t)(-off & 0xFF));
  } else {
    buf_byte(b, 0x89);
    buf_byte(b, (uint8_t)(0x85 | (d->regbits << 3)));
    buf_u32(b, (uint32_t)(-off));
  }
}
// mov eax, r32（dest = eax 在 rm 域，src = r 在 reg 域 ⇒ REX.R）
static void sl_enc_mov_eax_reg(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  if (d->rex_r) buf_byte(b, d->rex_r);
  buf_byte(b, 0x89);
  buf_byte(b, (uint8_t)(0xC0 | (d->regbits << 3)));
}
// mov ecx, r32（同上，rm = ecx(001)）
static void sl_enc_mov_ecx_reg(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  if (d->rex_r) buf_byte(b, d->rex_r);
  buf_byte(b, 0x89);
  buf_byte(b, (uint8_t)(0xC1 | (d->regbits << 3)));
}
// movslq rcx, r32（REX.W + 63 /r；rm = r ⇒ REX.B 或 0）
//   M5 ②：这个编码器解决了"降级"的一半 —— 见下面 slot_load_rcx64 的说明。
static void sl_enc_movsxd_rcx_reg(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  buf_byte(b, (uint8_t)(0x48 | d->rex_b));
  buf_byte(b, 0x63);
  buf_byte(b, (uint8_t)(0xC0 | (1 << 3) | d->regbits));   // mod=11, reg=rcx(001), rm=r
}
// mov r32, eax（dest = r 在 rm 域 ⇒ REX.B，src = eax 在 reg 域）
static void sl_enc_mov_reg_eax(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  if (d->rex_b) buf_byte(b, d->rex_b);
  buf_byte(b, 0x89);
  buf_byte(b, (uint8_t)(0xC0 | d->regbits));
}
// inc r32 / dec r32（FF /0、FF /1；rm = r ⇒ REX.B）
static void sl_enc_inc_reg(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  if (d->rex_b) buf_byte(b, d->rex_b);
  buf_byte(b, 0xFF);
  buf_byte(b, (uint8_t)(0xC0 | d->regbits));
}
static void sl_enc_dec_reg(Buf *b, int r) {
  const RegDef *d = &REGS[r];
  if (d->rex_b) buf_byte(b, d->rex_b);
  buf_byte(b, 0xFF);
  buf_byte(b, (uint8_t)(0xC8 | d->regbits));
}
// ALU r32, imm（83 /d ib 短形态 或 81 /d id 长形态；d = 0 add / 5 sub / 4 and）
//   ⚠️ 位宽语义与 v1.4.9 窥孔一致：AND 的 imm8 **只在 imm ∈ [0,127]** 时可用（符号扩展会把高位置 1）。
static void sl_enc_alu_imm_reg(Buf *b, int r, int d, int imm) {
  const RegDef *g = &REGS[r];
  int imm8ok = (imm >= -128 && imm <= 127);
  if (d == 4) imm8ok = imm8ok && (imm >= 0);      // and 不吃负数 imm8
  if (g->rex_b) buf_byte(b, g->rex_b);
  if (imm8ok) {
    buf_byte(b, 0x83);
    buf_byte(b, (uint8_t)(0xC0 | (d << 3) | g->regbits));
    buf_byte(b, (uint8_t)imm);
  } else {
    buf_byte(b, 0x81);
    buf_byte(b, (uint8_t)(0xC0 | (d << 3) | g->regbits));
    buf_u32(b, (uint32_t)imm);
  }
}
// add rDst, rSrc（01 /r：目标在 rm 域 ⇒ REX.B，源在 reg 域 ⇒ REX.R）
static void sl_enc_add_reg_reg(Buf *b, int dst, int src) {
  const RegDef *gd = &REGS[dst], *gs = &REGS[src];
  uint8_t rex = (uint8_t)(gs->rex_r | gd->rex_b);
  if (rex) buf_byte(b, rex);
  buf_byte(b, 0x01);
  buf_byte(b, (uint8_t)(0xC0 | (gs->regbits << 3) | gd->regbits));
}

static SlotLoc *sl_get(int off) {
  for (int i = 0; i < g_nsl; i++) if (g_sl[i].off == off) return &g_sl[i];
  if (g_nsl == g_slcap) {
    int cap = g_slcap ? g_slcap * 2 : 32;
    SlotLoc *p = realloc(g_sl, (size_t)cap * sizeof(SlotLoc));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    g_sl = p; g_slcap = cap;
  }
  SlotLoc *s = &g_sl[g_nsl++];
  s->off = off; s->ty = TY_INT; s->kind = SLOTK_MEM; s->flags = 0;
  s->loads = 0; s->stores = 0; s->epoch_last = 0; s->bb_first = 0; s->touched = 0;
  s->reg = -1; s->in_reg = 0; s->dirty = 0;
  return s;
}

// 一次槽访问的登记：读写计数 + 宽度 + 跨调用判定 + 跨基本块判定
//   · 跨调用："在两个不同纪元都访问过" = 存活跨过一次调用
//   · 跨块  ："在两个不同基本块都访问过" = M4 的严格口径④不满足（块作用域口径下无妨）
static SlotLoc *sl_touch(int off, int is_store, int wide) {
  SlotLoc *s = sl_get(off);
  if (is_store) s->stores++; else s->loads++;
  if (wide) s->flags |= SF_WIDE;
  if (s->touched) {
    if (s->epoch_last != g_epoch) s->flags |= SF_CROSSCALL;
    if (s->bb_first != g_bb)     s->flags |= SF_MULTIBB;
  } else {
    s->bb_first = g_bb;
  }
  s->touched = 1;
  s->epoch_last = g_epoch;
  return s;
}

// `-stats` 账本桥（insns = 0 表示这条访问不当账 —— 归口前就是如此，口径不许变）
static void sl_stats(int off, int wide, int insns) { slotmap_stats_access(off, wide, insns); }

// ===== M4：寄存器驻留的三个动作（load / flush / 降级）=====
// 首次访问：内存 → 寄存器（此后寄存器就是权威值；内存只在出口写回时刷新）
static void sl_reg_reload(SlotLoc *s) {
  if (s->in_reg) return;
  sl_enc_load(g_code, s->reg, s->off);
  s->in_reg = 1; s->dirty = 0;
  g_reloads_now++;
}
// 把一个脏寄存器写回内存（唯一出口 / 降级时用；不脏就什么都不做）
static void sl_flush(SlotLoc *s) {
  if (s->kind != SLOTK_REG || !s->in_reg || !s->dirty) return;
  sl_enc_store(g_code, s->reg, s->off);
  s->dirty = 0;
  g_spills_now++;
}
// 永久降级：该槽从此只走内存（取址、或访问器不支持寄存器的形态）
// ⚠️ **M5 ② 定位到的静默错值之源 ⇒ 现在改成"响亮的内部错误"**（2026-09-19）：
//   降级发生在**函数体发射到某一条**的位置，而控制流可能**跳过**降级点
//   （另一个分支 / 循环的另一次迭代 / 递归调用），于是"降级点之后"的代码读到一个
//   **从未被初始化过**的内存槽 ⇒ 静默错值。实测现场（boot 的 splice_file）：
//     `int got = splice_file(incbuf, out + o, outcap - o, depth + 1);`
//     里 `out + o` 走 try_load_var_to_ecx(wide) ⇒ slot_load_rcx64 ⇒ 把 `o` 降级；
//     降级指令在 **include 分支内部** ⇒ 任何走 else 分支（或递归进来的那份）的路径都不执行它，
//     该帧的 `o` 槽是栈残渣（实测恰为调用方的 `i`=18）⇒ 输出整体后移 18 字节。
//   结论（映射层不变量）：**位置只许在发射函数体之前定死** —— 要么全程寄存器、要么全程内存；
//   中途切换在跨路径上不可能自洽。因此：
//     · 需要"内存地址"的形态（取址）⇒ 生成层**静态**把这个槽钉死（SF_ADDRESSED，见 codegen 的
//       slotmap_declare_ast）；· 只需要"宽度/形态"的访问器（movsxd / 64 位 / 字节 / double）
//       ⇒ 给它们补**寄存器路径**（如本文件的 slot_load_rcx64）。
//   走到这里说明上面两条漏了：报错（并给出槽偏移），不要静默错值。
static void sl_demote(SlotLoc *s) {
  if (s->kind != SLOTK_REG) return;
  error("映射层不变量违规：寄存器槽 off=%d 在函数体发射中途被要求降级回内存"
        "（跨路径不可能一致 ⇒ 会静默错值）。修法：取址类把它静态钉死（SF_ADDRESSED），"
        "形态类给对应访问器补寄存器路径 —— 别恢复「先 flush 再降级」的老做法", s->off);
}

// ===== 生命周期 =====
void slotmap_begin_function(Buf *code) {
  g_nsl = 0; g_epoch = 0; g_had_call = 0; g_bb = 1; g_nreg = 0;
  g_code = code;
  g_reloads_now = 0; g_spills_now = 0;
  for (int i = 0; i < BB_REASON_N; i++) g_bb_reasons[i] = 0;
}

void slotmap_declare(int off, int ty, unsigned flags) {
  SlotLoc *s = sl_get(off);
  s->ty = ty;
  s->flags |= flags;
}

// 调用点：推进调用纪元 + 打一条 BB_CALL 边界（返回点起算新块；实参求值发生在这之前，归上一块）
void slotmap_note_call(void) {
  g_epoch++; g_had_call = 1;
  slotmap_bb_boundary(BB_CALL);
}

// ===== M4：分配计划（生成层在函数体发射之前调；返回要保存的寄存器个数）=====
// M5 ②（2026-09-19，v1.4.27）：**放开条件⑤** —— 带调用的函数也分配 callee-saved。
//   为什么放开是安全的：callee-saved 的语义就是"跨调用存活"（Win64 的 API 与 FLINT 自产函数都保它，
//   后者靠序言 push/收尾 pop），所以"槽在寄存器里"与"跨调用"本来就不冲突；
//   调用点的 rsp 对齐由生成层兜（序言按 push 个数的奇偶补 8 字节垫，见 codegen_func 的 reg_pad）。
//   ⚠️ 第一次尝试（当天早些时候）**失败在别处**：boot 门 183/27（15 个 include 样本上新 flint 编出的
//      boot 编译器自己编不动）。当时二分到"只有排除 splice_file 或 canon_path 之一才转绿"就停了，
//      误判成"大程序才暴露的机制未定位"。**真因是映射层的降级机制**（见 sl_demote / slot_load_rcx64 的
//      说明）：寄存器槽在**发射中途**被降级 ⇒ 跳过降级点的路径读到没初始化的内存槽 ⇒ 静默错值。
//      最小复现 `tmp\c5repro\c5d.fl`（从 boot 的 splice_file 抽出）：`out + o` 走 movsxd 把 `o` 降级在
//      include 分支里，任何走 else 分支/递归进来的那份都拿到栈残渣 ⇒ 拼接结果整体后移 18 字节（68→86）。
//      三处修法：① slot_load_rcx64 补**寄存器路径**（不再降级）；② 取址的槽在生成层**静态钉死**
//      （生成层按"这个变量被取过地址"静态申报 SF_ADDRESSED）；③ 残留的中途降级改成
//      **响亮的内部错误**（不再静默错值）。修后 boot 门回到 213/0。
// ===== M6 ④（2026-09-19）：把"降级路径不可达"从"靠记性"改成"计划期当场断言" =====
// 背景：M5 ② 把残留的中途降级改成响亮报错（sl_demote）之后，仍有 10 处访问器在调它
//   （取址 / rax64 / byte / dbl 一族 + 形参装载的 8 个），当时只能靠"它们应该不会见到寄存器槽"这条**口头**理由。
// 本轮逐处论证 + 静态守卫（判定顺序就是下面这条断言）：
//   ① **类型门**：分配只认 `ty == TY_INT`（本函数第 304 行）⇒ `char`(byte 族) / `double`(dbl 族) /
//      指针·引用·函数指针(64 位族) 的槽**永远不会**是 SLOTK_REG ⇒ 那几族的 sl_demote 不可能命中。
//   ② **钉死门**：`SF_NOREG` = 取址 / 数组结构体 / 托管 / 形参 / 暂存 / 引用 / T1 装地址
//      ⇒ 取址（slot_lea_rax）、形参装载（slot_store_rcx64 一族）也全部被这一条挡在门外。
//   ③ 于是只剩一种可能：**申报漏了**（某个被取址的槽没带上 SF_NOREG）—— 那正是 M5 ② 的静默错值之源。
//      ⇒ 在本函数里当场断言：凡是 ADDRESSED 却进了 REG 的槽，**立刻报错**（连槽号一起给），
//         而不是等到发射到某一条时才由 sl_demote 兜住（那时已经晚了一个控制流分支）。
//   判据：本轮全量门（回归 1009 / boot 213 / 差分门 / wx / debug / strict / 等价门）跑下来一次都没触发
//      ⇒ 10 处 sl_demote 在当前语言子集里**不可达**（这是实测事实，不是推理）。
int slotmap_plan_regs(int has_call) {
  g_nreg = 0;
  (void)has_call;   // M5 ②：条件⑤ 已放开（原先这里 `if (has_call) return 0;`）
  for (int i = 0; i < g_nsl; i++) {
    SlotLoc *s = &g_sl[i];
    if (s->kind != SLOTK_MEM || s->ty != TY_INT) continue;
    if (s->flags & SF_NOREG) continue;      // 条件 ①②③
    if (s->flags & SF_ADDRESSED)            // ③ 的守门：取址的槽绝不许进来（生成层申报漏了才会到这儿）
      error("映射层不变量违规：槽 off=%d 被取过地址却仍被选成寄存器槽（生成层申报漏了 SF_NOREG）"
            "—— 取址的槽必须全程在内存，否则别的路径会读到没初始化的内存槽（见 sl_demote 说明）", s->off);
    if (g_nreg >= SLOT_REG_POOL) break;
    s->kind = SLOTK_REG;
    s->reg = g_nreg++;
    s->in_reg = 0; s->dirty = 0;
  }
  return g_nreg;
}

int slotmap_regs_allocated(int *out, int cap) {
  int n = (g_nreg < cap) ? g_nreg : cap;
  for (int i = 0; i < n; i++) out[i] = i;
  return n;
}

// ===== M3：基本块边界（**只记录** —— 分配口径改成"函数作用域"后，边界不再是失效点）=====
void slotmap_bb_boundary(int reason) {
  g_bb++;
  if (reason >= 0 && reason < BB_REASON_N) g_bb_reasons[reason]++;
}

// ===== M4：收尾写回（函数唯一出口前调一次；把所有脏寄存器 store 回内存）=====
void slotmap_flush_all(void) {
  for (int i = 0; i < g_nsl; i++) sl_flush(&g_sl[i]);
}

int slotmap_has_call(void) { return g_had_call; }

void slotmap_summary(SlotSummary *out) {
  out->slots = g_nsl; out->addressed = 0; out->crosscall = 0; out->multibb = 0;
  out->managed = 0; out->aggregate = 0; out->param = 0; out->scratch = 0;
  out->candidates = 0; out->cand_block = 0; out->has_call = g_had_call; out->bb = g_bb;
  out->reg_slots = 0; out->reloads = (int)g_reloads_now; out->spills = (int)g_spills_now;
  for (int i = 0; i < BB_REASON_N; i++) out->bb_reasons[i] = g_bb_reasons[i];
  for (int i = 0; i < g_nsl; i++) {
    SlotLoc *s = &g_sl[i];
    if (s->flags & SF_ADDRESSED) out->addressed++;
    if (s->flags & SF_CROSSCALL) out->crosscall++;
    if (s->flags & SF_MULTIBB)   out->multibb++;
    if (s->flags & SF_MANAGED)   out->managed++;
    if (s->flags & SF_AGGREGATE) out->aggregate++;
    if (s->flags & SF_PARAM)     out->param++;
    if (s->flags & SF_SCRATCH)   out->scratch++;
    if (s->kind == SLOTK_REG)    out->reg_slots++;
    if (s->kind != SLOTK_MEM || s->ty != TY_INT) continue;
    // M4 条件 ①②③（SF_PINNED 去掉"跨块/跨调用"两位；⑤ 看 has_call）
    if (!(s->flags & (SF_PINNED & ~(unsigned)(SF_MULTIBB | SF_CROSSCALL)))) out->cand_block++;
    // 严格口径再叠一条 ④：**只在单个基本块内出现**
    if (!(s->flags & SF_PINNED)) out->candidates++;
  }
}

// ===== 槽访问发射器 =====
// 口径：REG 槽在**块内**用寄存器（首访 load、写记脏）；不支持寄存器的形态先降级再走原内存编码。

// rax ← &槽（取地址）：有人要拿它的内存地址 ⇒ 先 flush 再**永久降级**回内存，然后照常发 lea。
void slot_lea_rax(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 0, 0);    // 与其它访问共用一套登记（跨调用/跨块判定口径一致）
  s->flags |= SF_ADDRESSED;
  sl_demote(s);                        // 取址 ⇒ 先落回内存，再永久降级（该槽此后只走内存）
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x8D, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x8D); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// eax ← [槽]（32 位值读）
void slot_load_eax(Buf *b, int off) {
  sl_stats(off, 0, 1);
  SlotLoc *s = sl_touch(off, 0, 0);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_mov_eax_reg(b, s->reg);
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0x8B, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x8B); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// [槽] ← eax（32 位值写）
void slot_store_eax(Buf *b, int off) {
  sl_stats(off, 0, 1);
  SlotLoc *s = sl_touch(off, 1, 0);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_mov_reg_eax(b, s->reg);
    s->dirty = 1;
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0x89, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x89); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// ecx ← [槽]（v1.4.9② 窥孔：不碰 rax 的 32 位读）
void slot_load_ecx(Buf *b, int off) {
  sl_stats(off, 0, 1);
  SlotLoc *s = sl_touch(off, 0, 0);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_mov_ecx_reg(b, s->reg);
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0x8B, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x8B); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// rcx ← 符号扩展的 [槽]（movsxd rcx, dword [槽]；v1.4.9② 的 64 位档；T1 槽 ⇒ 静态已排除寄存器）。
// ⚠️ 这条不当 `-stats` 账（归口前 emit_movsxd_rcx_var 也没有）——账本口径不许在重构中变。
// M5 ②（2026-09-19）：寄存器槽**不再降级**，直接 `movslq rcx, r<reg>`（语义完全相同）。
//   为什么要这样：降级只在"发射到那一条"的位置把寄存器写回内存，而**跳过降级点的路径**
//   （另一分支 / 递归的另一份）会读到没被初始化过的内存槽 = 静默错值（见 sl_demote 的说明）。
void slot_load_rcx64(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 0, 1);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_movsxd_rcx_reg(b, s->reg);
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x63, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x63); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// rax ← [槽]（64 位：指针 / 引用槽 / 装地址的 int / 函数指针）—— T1 等已在静态排除，仍先降级兜底。
void slot_load_rax64(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 0, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x8B, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x8B); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// [槽] ← rax（64 位）
void slot_store_rax64(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 1, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x89, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x89); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// eax ← 槽低字节（movzx eax, byte [槽]；0..255）—— char 槽不进寄存器，仍先降级兜底。
void slot_load_byte(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 0, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0x0F, 0xB6, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x0F); buf_byte(b, 0xB6); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// 槽低字节 ← al
void slot_store_byte(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 1, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0x88, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x88); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// xmm0 ← [槽]（movsd；double 变量读）
void slot_load_dbl(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 0, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0xF2, 0x0F, 0x10, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 5);
  } else {
    buf_byte(b, 0xF2); buf_byte(b, 0x0F); buf_byte(b, 0x10); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// [槽] ← xmm0（movsd；double 变量写）
void slot_store_dbl(Buf *b, int off) {
  sl_stats(off, 1, 1);
  SlotLoc *s = sl_touch(off, 1, 1);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0xF2, 0x0F, 0x11, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 5);
  } else {
    buf_byte(b, 0xF2); buf_byte(b, 0x0F); buf_byte(b, 0x11); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}

// [槽] ← xmm{xi}（N = xi，0..3）——double 形参从各自的 XMM 寄存器落槽。
//   ModRM = mod | (xi<<3) | 101(rbp)：disp8 → 0x45|xi<<3；disp32 → 0x85|xi<<3
//   ⚠️ 这条不当 `-stats` 账（归口前也没有）——账本口径不许在重构中变。
void slot_store_dbl_xmm(Buf *b, int off, int xi) {
  SlotLoc *s = sl_touch(off, 1, 1);
  s = sl_get(off);
  sl_demote(s);
  uint8_t modrm8  = (uint8_t)(0x45 | (xi << 3));
  uint8_t modrm32 = (uint8_t)(0x85 | (xi << 3));
  if (off <= 127) {
    const uint8_t x[] = {0xF2, 0x0F, 0x11, modrm8, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 5);
  } else {
    buf_byte(b, 0xF2); buf_byte(b, 0x0F); buf_byte(b, 0x11); buf_byte(b, modrm32); buf_u32(b, (uint32_t)(-off));
  }
}

// 槽++ / 槽--（dword；FF /0 inc、FF /1 dec；**不碰 eax** —— 后缀保留旧值的关键）
void slot_inc_mem(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 1, 0);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_inc_reg(b, s->reg);
    s->dirty = 1;
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0xFF, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0xFF); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_dec_mem(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 1, 0);
  if (s->kind == SLOTK_REG) {
    sl_reg_reload(s);
    sl_enc_dec_reg(b, s->reg);
    s->dirty = 1;
    return;
  }
  if (off <= 127) {
    const uint8_t x[] = {0xFF, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0xFF); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// 槽低字节 ++ / --（FE /0、FE /1；不碰邻字节）—— char 槽不进寄存器。
void slot_inc_byte(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 1, 0);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0xFE, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0xFE); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_dec_byte(Buf *b, int off) {
  SlotLoc *s = sl_touch(off, 1, 0);
  s = sl_get(off);
  sl_demote(s);
  if (off <= 127) {
    const uint8_t x[] = {0xFE, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0xFE); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// ===== 形参装载：寄存器 → 形参槽（普通函数序言用；形参槽静态已排除寄存器）=====
// 64 位档（指针/引用/函数指针形参；各寄存器独立 ModRM）
static void sl_demote_off(int off) { sl_demote(sl_get(off)); }

void slot_store_rcx64(Buf *b, int off) {
  sl_touch(off, 1, 1);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x89, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x89); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_rdx64(Buf *b, int off) {
  sl_touch(off, 1, 1);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x89, 0x55, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x89); buf_byte(b, 0x95); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_r8_64(Buf *b, int off) {
  sl_touch(off, 1, 1);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x4C, 0x89, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x4C); buf_byte(b, 0x89); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_r9_64(Buf *b, int off) {
  sl_touch(off, 1, 1);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x4C, 0x89, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x4C); buf_byte(b, 0x89); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}
// 32 位档（int 值形参）
void slot_store_ecx(Buf *b, int off) {
  sl_touch(off, 1, 0);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x89, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x89); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_edx(Buf *b, int off) {
  sl_touch(off, 1, 0);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x89, 0x55, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 3);
  } else {
    buf_byte(b, 0x89); buf_byte(b, 0x95); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_r8d(Buf *b, int off) {
  sl_touch(off, 1, 0);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x44, 0x89, 0x45, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x44); buf_byte(b, 0x89); buf_byte(b, 0x85); buf_u32(b, (uint32_t)(-off));
  }
}
void slot_store_r9d(Buf *b, int off) {
  sl_touch(off, 1, 0);
  sl_demote_off(off);
  if (off <= 127) {
    const uint8_t x[] = {0x44, 0x89, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x44); buf_byte(b, 0x89); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// ===== M4 融合路径：自反运算就地算（**只对寄存器槽**；生成层保证"表达式值没人用"）=====
int slotmap_kind_of(int off) { return (int)sl_get(off)->kind; }

static SlotLoc *sl_reg_require(int off) {
  SlotLoc *s = sl_get(off);
  if (s->kind != SLOTK_REG)
    error("内部错误：槽 %d 不是寄存器槽（融合路径只能用在寄存器槽上）", off);
  return s;
}

void slot_self_add_imm(Buf *b, int off, int imm) {
  sl_stats(off, 0, 1);
  sl_touch(off, 1, 0);
  SlotLoc *s = sl_reg_require(off);
  if (!s->in_reg) sl_reg_reload(s);
  sl_enc_alu_imm_reg(b, s->reg, 0, imm);   // add r32, imm
  s->dirty = 1;
}

void slot_self_sub_imm(Buf *b, int off, int imm) {
  sl_stats(off, 0, 1);
  sl_touch(off, 1, 0);
  SlotLoc *s = sl_reg_require(off);
  if (!s->in_reg) sl_reg_reload(s);
  sl_enc_alu_imm_reg(b, s->reg, 5, imm);   // sub r32, imm
  s->dirty = 1;
}

void slot_self_add_slot(Buf *b, int off, int other) {
  sl_stats(off, 0, 1);
  sl_stats(other, 0, 1);
  sl_touch(off, 1, 0);
  sl_touch(other, 0, 0);
  SlotLoc *s = sl_reg_require(off);
  SlotLoc *o = sl_reg_require(other);
  if (!s->in_reg) sl_reg_reload(s);
  if (!o->in_reg) sl_reg_reload(o);
  sl_enc_add_reg_reg(b, s->reg, o->reg);   // add rS, rOther
  s->dirty = 1;
}

void slot_self_and_imm(Buf *b, int off, int imm) {
  sl_stats(off, 0, 1);
  sl_touch(off, 1, 0);
  SlotLoc *s = sl_reg_require(off);
  if (!s->in_reg) sl_reg_reload(s);
  sl_enc_alu_imm_reg(b, s->reg, 4, imm);   // and r32, imm
  s->dirty = 1;
}

// ===== v1.4.26（M5 ①）：元素寻址与元素就地运算 =====
// [rbp - base_off (+ rax*scale)] 的 ModRM(+SIB+disp)（reg 域由 mod_reg 给）。
//   ⚠️ base = rbp 时**绝不能用 mod=00** —— mod=00 的 base=101 表示"没有基址 + disp32"，
//      会静默把基址丢掉（这正是 SIB 编码最经典的坑）⇒ 一律 mod=01（disp8）/ mod=10（disp32）。
static void sl_enc_elem_modrm(Buf *b, int mod_reg, const ElemAddr *ea) {
  if (ea->has_idx) {
    int d = -ea->base_off;
    int sbits;
    switch (ea->scale) {
      case 1: sbits = 0; break;
      case 2: sbits = 1; break;
      case 4: sbits = 2; break;
      case 8: sbits = 3; break;
      default: error("内部错误：SIB 步长只支持 1/2/4/8（收到 %d）", ea->scale); return;
    }
    if (d >= -128 && d <= 127) {
      buf_byte(b, (uint8_t)(0x44 | (mod_reg << 3)));   // mod=01 rm=100(SIB)
      buf_byte(b, (uint8_t)((sbits << 6) | 0x05));     // index=rax(000) base=rbp(101)
      buf_byte(b, (uint8_t)(d & 0xFF));
    } else {
      buf_byte(b, (uint8_t)(0x84 | (mod_reg << 3)));   // mod=10
      buf_byte(b, (uint8_t)((sbits << 6) | 0x05));
      buf_u32(b, (uint32_t)d);
    }
    return;
  }
  int d = -ea->base_off + ea->cidx * ea->scale;
  if (d >= -128 && d <= 127) {
    buf_byte(b, (uint8_t)(0x45 | (mod_reg << 3)));     // mod=01 rm=101(rbp)
    buf_byte(b, (uint8_t)(d & 0xFF));
  } else {
    buf_byte(b, (uint8_t)(0x85 | (mod_reg << 3)));     // mod=10
    buf_u32(b, (uint32_t)d);
  }
}

// 元素访存的记账（与其它访问器同口径：一次元素访存 = 一条栈槽访问）
static void sl_elem_access(const ElemAddr *ea, int is_store) {
  sl_stats(ea->base_off, 0, 1);
  sl_touch(ea->base_off, is_store, 0);
}

void slot_elem_lea(Buf *b, const ElemAddr *ea) {
  buf_byte(b, 0x48);            // REX.W
  buf_byte(b, 0x8D);            // lea rax, [元素]
  sl_enc_elem_modrm(b, 0, ea);  // reg=000 → rax
  sl_elem_access(ea, 0);
}

void slot_elem_add_imm(Buf *b, const ElemAddr *ea, int imm) {
  sl_elem_access(ea, 1);
  int imm8ok = (imm >= -128 && imm <= 127);
  if (imm8ok) { buf_byte(b, 0x83); sl_enc_elem_modrm(b, 0, ea); buf_byte(b, (uint8_t)imm); }
  else { buf_byte(b, 0x81); sl_enc_elem_modrm(b, 0, ea); buf_u32(b, (uint32_t)imm); }
}

void slot_elem_and_imm(Buf *b, const ElemAddr *ea, int imm) {
  sl_elem_access(ea, 1);
  int imm8ok = (imm >= 0 && imm <= 127);   // and 不吃负数 imm8（与 sl_enc_alu_imm_reg 同口径）
  if (imm8ok) { buf_byte(b, 0x83); sl_enc_elem_modrm(b, 4, ea); buf_byte(b, (uint8_t)imm); }
  else { buf_byte(b, 0x81); sl_enc_elem_modrm(b, 4, ea); buf_u32(b, (uint32_t)imm); }
}

// dword [元素] += rSrc（src 必须是寄存器槽 —— 生成层保证；值没变 ⇒ **不置 dirty**）
void slot_elem_add_slot(Buf *b, const ElemAddr *ea, int src_off) {
  sl_stats(src_off, 0, 1);
  sl_touch(src_off, 0, 0);
  SlotLoc *s = sl_reg_require(src_off);
  if (!s->in_reg) sl_reg_reload(s);
  const RegDef *g = &REGS[s->reg];
  if (g->rex_r) buf_byte(b, g->rex_r);   // REX.R（reg 域）
  buf_byte(b, 0x01);                     // add r/m32, r32
  sl_enc_elem_modrm(b, g->regbits, ea);
  sl_elem_access(ea, 1);
}

void slot_elem_inc(Buf *b, const ElemAddr *ea) {
  sl_elem_access(ea, 1);
  buf_byte(b, 0xFF);                 // FF /0 = inc r/m32
  sl_enc_elem_modrm(b, 0, ea);
}

void slot_elem_dec(Buf *b, const ElemAddr *ea) {
  sl_elem_access(ea, 1);
  buf_byte(b, 0xFF);                 // FF /1 = dec r/m32
  sl_enc_elem_modrm(b, 1, ea);
}

// rDst += dword [元素]（dst 必须是寄存器槽）—— `s = s + a[k]` 一条顶十来条
void slot_elem_add_to_reg(Buf *b, const ElemAddr *ea, int dst_off) {
  sl_stats(dst_off, 0, 1);
  sl_touch(dst_off, 1, 0);
  SlotLoc *s = sl_reg_require(dst_off);
  if (!s->in_reg) sl_reg_reload(s);   // ⚠️ 必须在算 `add` 之前，且**不碰 rax**（索引还在 rax 里）
  const RegDef *g = &REGS[s->reg];
  if (g->rex_r) buf_byte(b, g->rex_r);
  buf_byte(b, 0x03);                  // add r32, r/m32（目标 = reg 域）
  sl_enc_elem_modrm(b, g->regbits, ea);
  s->dirty = 1;
}

// ===== M5 ①：指针槽基址（`p[i]`：基址是槽里的 64 位值，不是编译期常量）=====
void slot_load_ptr_rcx64(Buf *b, int off) {
  sl_stats(off, 1, 1);
  sl_touch(off, 0, 1);
  sl_demote(sl_get(off));
  if (off <= 127) {
    const uint8_t x[] = {0x48, 0x8B, 0x4D, (uint8_t)(-off & 0xFF)};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x8B); buf_byte(b, 0x8D); buf_u32(b, (uint32_t)(-off));
  }
}

// rax ← [rcx + disp]（M6 ①：常量下标折进位移）
//   lea rax,[rcx+disp] 的编码：mod = 01(disp8) / 10(disp32)、reg = 000(rax)、rm = 001(rcx)。
//   ⚠️ **不能用 mod=00** —— mod=00 的 rm=001 表示 `[rcx]`（无位移），折进去的常量会**静默丢掉**
//      （同族坑：mod=00 的 base=101 表示"没有基址 + disp32"，见 sl_enc_elem_modrm）。
//   调用方（生成层）保证 disp 装得进 disp32（常量下标 × 步长都在 32 位内）。
void slot_lea_ptr_disp_rax(Buf *b, long disp) {
  if (disp >= -128 && disp <= 127) {
    const uint8_t x[] = {0x48, 0x8D, 0x41, (uint8_t)(disp & 0xFF)};   // mod=01 rm=001(rcx)
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x8D);
    buf_byte(b, 0x81);                                   // mod=10 rm=001(rcx)
    buf_u32(b, (uint32_t)disp);
  }
}

// rax ← [rcx + rax*scale]（基址在 rcx、索引在 rax；rcx 不是 rbp/r13 ⇒ mod=00 安全）
void slot_lea_ptr_idx_rax(Buf *b, int scale) {
  int sbits;
  switch (scale) {
    case 1: sbits = 0; break;
    case 2: sbits = 1; break;
    case 4: sbits = 2; break;
    case 8: sbits = 3; break;
    default: error("内部错误：SIB 步长只支持 1/2/4/8（收到 %d）", scale); return;
  }
  buf_byte(b, 0x48);                                    // REX.W
  buf_byte(b, 0x8D);                                    // lea
  buf_byte(b, 0x04);                                    // mod=00 reg=000(rax) rm=100(SIB)
  buf_byte(b, (uint8_t)((sbits << 6) | 0x00 | 0x01));   // index=rax(000) base=rcx(001)
}

// ===== v1.4.26（M5 ③）：比较就地化 =====
// `op r32, [rbp-off]`（reg 域 = g，rm = 帧槽）—— REX.R 给 reg 域（g 是 r12~r15 时）。
static void sl_enc_reg_mem(Buf *b, const RegDef *g, int off, uint8_t op) {
  if (g->rex_r) buf_byte(b, g->rex_r);
  buf_byte(b, op);
  if (off <= 127) {
    buf_byte(b, (uint8_t)(0x45 | (g->regbits << 3)));
    buf_byte(b, (uint8_t)(-off & 0xFF));
  } else {
    buf_byte(b, (uint8_t)(0x85 | (g->regbits << 3)));
    buf_u32(b, (uint32_t)(-off));
  }
}
// ecx 的 RegDef（"两侧都在内存"时拿它当中间寄存器：只碰 ecx，**比老路径少碰 eax**）
static const RegDef SL_ECX = { 1, 0x00, 0x00, "ecx" };

// flags = [lhs] - [rhs]（32 位）。用例：
//   两边都是寄存器槽 → `cmp rL, rR`（0x39：r/m 域 = 被减数 = lhs）
//   lhs 寄存器、rhs 内存 → `cmp rL, [rbp-rhs]`（0x3B）
//   lhs 内存、rhs 寄存器 → `cmp [rbp-lhs], rR`（0x39）
//   两边都在内存     → `mov ecx,[rbp-rhs]` + `cmp [rbp-lhs],ecx`（两条，仍比老路少一条）
bool slot_cmp_slots(Buf *b, int lhs_off, int rhs_off) {
  SlotLoc *l = sl_get(lhs_off), *r = sl_get(rhs_off);
  int lreg = (l->kind == SLOTK_REG), rreg = (r->kind == SLOTK_REG);
  if (lreg && !l->in_reg) sl_reg_reload(l);
  if (rreg && !r->in_reg) sl_reg_reload(r);
  sl_stats(lhs_off, 0, 1); sl_touch(lhs_off, 0, 0);
  sl_stats(rhs_off, 0, 1); sl_touch(rhs_off, 0, 0);
  if (lreg) {
    const RegDef *gl = &REGS[l->reg];
    if (rreg) {
      const RegDef *gr = &REGS[r->reg];
      uint8_t rex = (uint8_t)(gr->rex_r | gl->rex_b);   // reg 域 = 减数（REX.R）、rm 域 = 被减数（REX.B）
      if (rex) buf_byte(b, rex);
      buf_byte(b, 0x39);
      buf_byte(b, (uint8_t)(0xC0 | (gr->regbits << 3) | gl->regbits));
    } else {
      sl_enc_reg_mem(b, gl, rhs_off, 0x3B);             // cmp rL, [rbp-rhs]
    }
    return true;
  }
  if (rreg) { sl_enc_reg_mem(b, &REGS[r->reg], lhs_off, 0x39); return true; }   // cmp [rbp-lhs], rR
  // 两边都在内存：ecx 当中间寄存器（老路径要 eax+ecx 两条搬运，这里一条）
  sl_enc_reg_mem(b, &SL_ECX, rhs_off, 0x8B);            // mov ecx, [rbp-rhs]
  sl_enc_reg_mem(b, &SL_ECX, lhs_off, 0x39);            // cmp [rbp-lhs], ecx
  return true;
}

// flags = [槽] - imm（32 位；寄存器槽 → `cmp $imm,rS`，内存槽 → `cmp dword [rbp-off],imm`）
bool slot_cmp_slot_imm(Buf *b, int off, int imm) {
  SlotLoc *s = sl_get(off);
  int imm8ok = (imm >= -128 && imm <= 127);
  sl_stats(off, 0, 1); sl_touch(off, 0, 0);
  if (s->kind == SLOTK_REG) {
    if (!s->in_reg) sl_reg_reload(s);
    const RegDef *g = &REGS[s->reg];
    if (g->rex_b) buf_byte(b, g->rex_b);
    if (imm8ok) {
      buf_byte(b, 0x83);
      buf_byte(b, (uint8_t)(0xC0 | (7 << 3) | g->regbits));   // /7 = cmp
      buf_byte(b, (uint8_t)imm);
    } else {
      buf_byte(b, 0x81);
      buf_byte(b, (uint8_t)(0xC0 | (7 << 3) | g->regbits));
      buf_u32(b, (uint32_t)imm);
    }
    return true;
  }
  // ⚠️ disp8 只有在 `off <= 127`（即 -off 落在有符号 8 位内）时才能用 —— 少了这个守卫，
  //    槽偏移 192 会编码成 `+0x40(%rbp)` 而不是 `-0xC0(%rbp)`：**读到帧外的垃圾**（实测踩过：
  //    audit2 的 `z != 42` 因此读错地址 → 退出码 24）。老访问器（slot_load_eax 一族）都有这个守卫。
  if (imm8ok && off <= 127) {
    const uint8_t x[] = {0x83, 0x7D, (uint8_t)(-off & 0xFF), (uint8_t)imm};   // cmp dword [rbp-off], imm8
    buf_bytes(b, x, 4);
  } else if (off <= 127) {
    buf_byte(b, 0x81); buf_byte(b, 0x7D); buf_byte(b, (uint8_t)(-off & 0xFF)); buf_u32(b, (uint32_t)imm);
  } else {
    buf_byte(b, 0x81); buf_byte(b, 0xBD); buf_u32(b, (uint32_t)(-off)); buf_u32(b, (uint32_t)imm);
  }
  return true;
}
