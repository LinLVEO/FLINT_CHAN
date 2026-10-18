// codegen.c — FLINT 自写 x86-64 机器码编码器（v0.5：函数调用）
// 跳转延迟回填机制（函数内）：
//   发射 jmp/jcc 时写 opcode + 4 字节占位，记 rel32 位置 + label id；
//   生成到目标处记 label 字节位置；函数生成完统一回填。
// v0.5 新增：
//   - 多函数：每函数一个 FuncCtx，函数内跳转各自 resolve；
//     函数间 call = E8 rel32 记 ExtCall（外部引用），全部函数生成完、
//     布局偏移确定后二次回填（call 目标是目标函数 code 起点）。
//   - ABI（决策 11）：参数 rcx/rdx/r8/r9（≤4），返回值 eax；
//     call 前不破坏 rsp 对齐——参数先求值 push 暂存、再弹出到寄存器（配对平衡）；
//     普通函数序言装载参数到 [rbp-off] 槽，尾声 leave+ret；main 仍 call ExitProcess。
//
// 比较：cmp eax,ecx (39 C8) + setcc al (0F 9x C0) + movzx eax,al (0F B6 C0)
// 测试：test eax,eax (85 C0)
// 跳转：jmp rel32 = E9；jcc rel32 = 0F 8x（je 84 / jne 85 / jl 8C / jle 8E / jg 8F / jge 8D）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>   // v1.4.25：-strict 的带数字定位报错（error_at_nodef）

#include "flint.h"
#include "slotmap.h"   // v1.4.21（M2）：映射层（帧槽访问的唯一出口 + "槽 → 位置"表）

// ========== v1.0.4.1 rsp≡0 生成期静态自检（决策 26 S3 纪律落地为编译期断言） ==========
// 凡动 rsp 的发射器都同步维护 g_rspm（rsp ≡ mod16，按字节运算 &15）；
// 每个 call 发射点断言 g_rspm==0——「先压栈再跨表达式求值/帧未 16 对齐」类错位
// （决策 32、v1.0.3 帧 +8 忘重对齐、v1.0.4 ptr 字段 32 位写漏网）在编译期即报，
// 不再等到 movaps 类 API 运行时崩。codegen_func 入口置 8（call 压入返回地址后 ≡8）。
static int g_rspm;
// v1.4.11（`-debug`）：可审计发射层开关。定义放这里（codegen 是"记录方"），main.c 置位。
bool flint_debug_info = false;

// ===== v1.4.19（任务卡 T-20260919-010437 · 周期0「账本」的编译器侧）：按函数的发射统计 =====
// 纪律：`flint_stats` 为假时**所有计数函数都不做任何事**（既有产物逐字节不变；由等价门证明）。
bool flint_stats = false;
static unsigned long g_st_ins = 0, g_st_slot = 0, g_st_wvar = 0, g_st_call = 0, g_st_bytes = 0;
static void st_ins(void)  { if (flint_stats) g_st_ins++; }
static void st_slot(int off, int wide) { if (!flint_stats) return; g_st_slot++; if (wide) g_st_wvar++; (void)off; }
static void st_call(void) { if (flint_stats) g_st_call++; }

// v1.4.21（M2）：映射层（slotmap.c）的账本桥 —— 映射层不碰统计状态，只回报"这一条访问算几条指令"。
//   insns==0 ⇒ 不进账本：归口前这些点就不当账，**账本口径在重构中不许变**（判据 5）。
void slotmap_stats_access(int off, int wide, int insns) {
  if (insns <= 0) return;
  st_slot(off, wide);
  st_ins();
}

typedef struct {
  const char *name;
  unsigned long ins, slot, wvar, call, bjmp, bytes;
  SlotSummary sl;   // v1.4.21/22（M2 位置表 + M3 基本块）：映射层给的槽表小结
} FuncStat;
static FuncStat *g_fn_stats = NULL;
static int g_fn_stats_n = 0, g_fn_stats_cap = 0;

void flint_stats_func_begin(const char *name) {
  if (!flint_stats) return;
  if (g_fn_stats_n == g_fn_stats_cap) {
    int cap = g_fn_stats_cap ? g_fn_stats_cap * 2 : 64;
    FuncStat *p = realloc(g_fn_stats, (size_t)cap * sizeof(FuncStat));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    g_fn_stats = p; g_fn_stats_cap = cap;
  }
  FuncStat *f = &g_fn_stats[g_fn_stats_n++];
  f->name = name; f->ins = 0; f->slot = 0; f->wvar = 0; f->call = 0; f->bjmp = 0; f->bytes = 0;
  g_st_ins = 0; g_st_slot = 0; g_st_wvar = 0; g_st_call = 0; g_st_bytes = 0;
}
void flint_stats_func_end(size_t npc_bytes) {
  if (!flint_stats || g_fn_stats_n == 0) return;
  FuncStat *f = &g_fn_stats[g_fn_stats_n - 1];
  f->ins = g_st_ins; f->slot = g_st_slot; f->wvar = g_st_wvar;
  f->call = g_st_call; f->bjmp = 0; f->bytes = (unsigned long)npc_bytes;
  slotmap_summary(&f->sl);   // v1.4.21（M2）：顺带收本函数的槽表小结
}
void flint_stats_dump(void) {
  if (!flint_stats) return;
  printf("\n===== FLINT 发射统计（-stats；按函数）=====\n");
  printf("%-24s %8s %8s %8s %8s %9s\n", "function", "insns", "slots", "of-64b", "calls", "bytes");
  unsigned long ti = 0, ts = 0, tc = 0, tb = 0;
  for (int i = 0; i < g_fn_stats_n; i++) {
    FuncStat *f = &g_fn_stats[i];
    printf("%-24s %8lu %8lu %8lu %8lu %9lu\n", f->name ? f->name : "?", f->ins, f->slot, f->wvar, f->call, f->bytes);
    ti += f->ins; ts += f->slot; tc += f->call; tb += f->bytes;
  }
  printf("%-24s %8lu %8lu %8s %8lu %9lu\n", "TOTAL", ti, ts, "-", tc, tb);
  if (ti > 0) printf("栈槽访问占比 = %lu / %lu = %.1f%%\n", ts, ti, 100.0 * (double)ts / (double)ti);

  // v1.4.21/22（M2 位置表 / M3 基本块）：槽表小结（映射层"槽 → 位置"表的账本）—— M4 的输入就长这样
  printf("\n----- 槽表（M2 位置表 + M3 基本块；映射层记录，本版全 MEM）-----\n");
  printf("%-24s %6s %6s %7s %6s %6s %8s %6s %6s %7s %7s %7s %6s %8s\n",
         "function", "slots", "取址", "跨调用", "跨块", "托管", "数组/结构", "参数", "暂存",
         "候选(单块)", "候选(分块)", "基本块", "边界", "寄存器槽");
  long t_sl = 0, t_ad = 0, t_cc = 0, t_mb = 0, t_mg = 0, t_ag = 0, t_pa = 0, t_sc = 0;
  long t_cd = 0, t_cb = 0, t_rg = 0, t_re = 0, t_sp = 0;
  long t_bb = 0, t_bc[BB_REASON_N];
  for (int r = 0; r < BB_REASON_N; r++) t_bc[r] = 0;
  for (int i = 0; i < g_fn_stats_n; i++) {
    FuncStat *f = &g_fn_stats[i];
    int bound = 0;
    for (int r = 0; r < BB_REASON_N; r++) bound += f->sl.bb_reasons[r];
    printf("%-24s %6d %6d %7d %6d %6d %8d %6d %6d %7d %7d %7d %6d %8d%s\n", f->name ? f->name : "?",
           f->sl.slots, f->sl.addressed, f->sl.crosscall, f->sl.multibb, f->sl.managed, f->sl.aggregate,
           f->sl.param, f->sl.scratch, f->sl.candidates, f->sl.cand_block, f->sl.bb, bound, f->sl.reg_slots,
           f->sl.has_call ? "   <- 有调用（M5 ② 起也分配寄存器）" : "");
    t_sl += f->sl.slots; t_ad += f->sl.addressed; t_cc += f->sl.crosscall; t_mb += f->sl.multibb;
    t_mg += f->sl.managed; t_ag += f->sl.aggregate; t_pa += f->sl.param; t_sc += f->sl.scratch;
    t_cd += f->sl.candidates; t_cb += f->sl.cand_block; t_bb += f->sl.bb; t_rg += f->sl.reg_slots;
    t_re += f->sl.reloads; t_sp += f->sl.spills;
    for (int r = 0; r < BB_REASON_N; r++) t_bc[r] += f->sl.bb_reasons[r];
  }
  printf("%-24s %6ld %6ld %7ld %6ld %6ld %8ld %6ld %6ld %7ld %7ld %7ld %6ld %8ld\n",
         "TOTAL", t_sl, t_ad, t_cc, t_mb, t_mg, t_ag, t_pa, t_sc, t_cd, t_cb, t_bb,
         t_bc[BB_LABEL] + t_bc[BB_JMP] + t_bc[BB_JCC] + t_bc[BB_CALL], t_rg);
  printf("边界理由合计（M3）：label %ld ｜ jmp %ld ｜ jcc %ld ｜ call %ld\n",
         t_bc[BB_LABEL], t_bc[BB_JMP], t_bc[BB_JCC], t_bc[BB_CALL]);
  printf("M4 寄存器（**函数作用域**：首访 load 一次，出口写回一次）：寄存器槽 %ld ｜ 首访装载 %ld ｜ 出口写回 %ld\n", t_rg, t_re, t_sp);
  printf("候选(单块) = M4 条件 ①②③④ 全过（TY_INT ＋ 未取址 ＋ 非数组结构体/托管/参数/引用/暂存/跨调用 ＋ 只在单个基本块内）；\n");
  printf("候选(分块) = 只过 ①②③（不看④）：**按基本块作用域**分配（每块首访 load、块边界 store 回内存）时可用；\n");
  printf("             ⑤（本函数无调用）见行尾标注 —— M5 ② 起 ⑤ 不再当门槛，有调用也分配。\n");
  fflush(stdout);
}
// v1.4.20：发射统计（-stats）的计数器实现见本文件后段；多处发射器先用到，故在此前置声明
static void st_ins(void);
static void st_slot(int off, int wide);
static void st_call(void);

static void rsp_assert_ok(const char *where) {
  if (g_rspm != 0)
    error("内部 rsp 对齐违规（%s 前 rsp≡%d，应 ≡0）——压栈未配对或帧未 16 对齐，改 codegen", where, g_rspm);
}

// ========== 字节缓冲 ==========
void buf_init(Buf *b) { b->data = NULL; b->len = 0; b->cap = 0; }

static void buf_grow(Buf *b, size_t need) {
  if (b->len + need <= b->cap) return;
  size_t cap = b->cap ? b->cap * 2 : 64;
  while (cap < b->len + need) cap *= 2;
  b->data = realloc(b->data, cap);
  if (!b->data) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
  b->cap = cap;
}

void buf_byte(Buf *b, uint8_t x) { buf_grow(b, 1); b->data[b->len++] = x; }

void buf_bytes(Buf *b, const uint8_t *p, size_t n) {
  buf_grow(b, n);
  memcpy(b->data + b->len, p, n);
  b->len += n;
}

void buf_u32(Buf *b, uint32_t x) {
  buf_byte(b, x & 0xFF);
  buf_byte(b, (x >> 8) & 0xFF);
  buf_byte(b, (x >> 16) & 0xFF);
  buf_byte(b, (x >> 24) & 0xFF);
}

void buf_u64(Buf *b, uint64_t x) {
  for (int i = 0; i < 8; i++) buf_byte(b, (x >> (8 * i)) & 0xFF);
}

void buf_patch_u32(Buf *b, size_t off, uint32_t x) {
  if (off + 4 > b->len) { fprintf(stderr, "FLINT: 内部错误：补丁越界\n"); exit(1); }
  b->data[off] = x & 0xFF;
  b->data[off + 1] = (x >> 8) & 0xFF;
  b->data[off + 2] = (x >> 16) & 0xFF;
  b->data[off + 3] = (x >> 24) & 0xFF;
}

static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
  return p;
}

static void *xcalloc(size_t n, size_t sz) {
  void *p = calloc(n, sz);
  if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
  return p;
}

// v1.1.0 浮点（阶段1）：double ↔ 位型（先这样搬，xmm 通路在阶段2 用 movq 直接搬寄存器）
static unsigned long long dbl_bits(double v) {
  unsigned long long b;
  memcpy(&b, &v, sizeof(b));
  return b;
}

// ========== FuncCtx：label + patch + ext 机制（每函数独立）==========
static void ctx_init(FuncCtx *c) {
  buf_init(&c->code);
  c->patches = NULL; c->npatches = 0; c->patches_cap = 0;
  c->label_pos = NULL; c->label_set = NULL; c->nlabels = 0; c->labels_cap = 0;
  c->exit_label_id = 0;
  c->exts = NULL; c->nexts = 0; c->exts_cap = 0;
  c->strrefs = NULL; c->nstrrefs = 0; c->strrefs_cap = 0;
  c->apicalls = NULL; c->napicalls = 0; c->apicalls_cap = 0;
  c->funcaddrs = NULL; c->nfuncaddrs = 0; c->funcaddrs_cap = 0;
  c->dblrefs = NULL; c->ndblrefs = 0; c->dblrefs_cap = 0;
  c->is_main = false;
  c->ret_char = false;
  c->ret_dbl = false;   // v1.2.1：double 值返回（xmm0 直出）
  c->ret_ty = TY_INT;   // v1.4.25：-strict 用（默认关时没人读）
  c->prog = NULL;
  c->disp_off = 0;
  // v1.2.0：循环上下文栈（break/continue 目标 label）
  c->loops = NULL; c->nloops = 0; c->loops_cap = 0;
}

// v1.2.0：压/弹循环上下文（只管最内层 = C 语义）
static void loop_push(FuncCtx *c, int brk, int cont) {
  if (c->nloops == c->loops_cap) {
    int cap = c->loops_cap ? c->loops_cap * 2 : 16;
    void *p = realloc(c->loops, (size_t)cap * sizeof(*c->loops));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->loops = p; c->loops_cap = cap;
  }
  c->loops[c->nloops].brk = brk;
  c->loops[c->nloops].cont = cont;
  c->loops[c->nloops].is_switch = false;
  c->nloops++;
}

// v1.3.1：switch 上下文——break 跳它的末尾（brk=end），但 cont 无意义（-1）：
//   continue 必须穿透到外层真循环（C 语义），见 ND_CONTINUE 分支的向下扫描。
static void loop_push_switch(FuncCtx *c, int end) {
  loop_push(c, end, -1);
  c->loops[c->nloops - 1].is_switch = true;
}

static void loop_pop(FuncCtx *c) {
  if (c->nloops > 0) c->nloops--;
}

// 分配一个新 label id（动态扩容，无硬上限）
static int new_label(FuncCtx *c) {
  if (c->nlabels == c->labels_cap) {
    size_t cap = c->labels_cap ? c->labels_cap * 2 : 64;
    size_t *pos = realloc(c->label_pos, cap * sizeof(*pos));
    bool *set = realloc(c->label_set, cap * sizeof(*set));
    if (!pos || !set) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->label_pos = pos;
    c->label_set = set;
    c->labels_cap = cap;
  }
  int id = (int)c->nlabels++;
  c->label_set[id] = false;
  return id;
}

// 标记 label 的字节位置（label id 必须先 new_label 分配）
static void emit_label(FuncCtx *c, int id) {
  // v1.4.23（M4）：边界钩子必须在**发标签之前** —— 它先把脏寄存器写回内存（新块首访再 load）；
  //   于是标签地址落在"写回"之后：从别处跳进来时，那条路径已在它自己的块边界处写过，语义一致。
  slotmap_bb_boundary(BB_LABEL);
  c->label_pos[id] = c->code.len;
  c->label_set[id] = true;
}

// 记录函数内待回填 rel32（动态扩容）
static void note_patch(FuncCtx *c, int label) {
  if (c->npatches == c->patches_cap) {
    size_t cap = c->patches_cap ? c->patches_cap * 2 : 64;
    Patch *p = realloc(c->patches, cap * sizeof(*p));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->patches = p;
    c->patches_cap = cap;
  }
  c->patches[c->npatches].off = c->code.len;
  c->patches[c->npatches].label = label;
  c->npatches++;
}

// 本函数全部生成完后回填函数内 rel32
static void resolve_patches(FuncCtx *c) {
  for (size_t i = 0; i < c->npatches; i++) {
    int label = c->patches[i].label;
    if (!c->label_set[label]) { fprintf(stderr, "FLINT: 内部错误：标签未定义\n"); exit(1); }
    size_t off = c->patches[i].off;
    uint32_t disp = (uint32_t)(c->label_pos[label] - (off + 4));
    buf_patch_u32(&c->code, off, disp);
  }
  c->npatches = 0;
}

// 记录函数间 call 引用（E8 占位后调用；布局完成后再回填）
static void note_ext(FuncCtx *c, int target) {
  if (c->nexts == c->exts_cap) {
    size_t cap = c->exts_cap ? c->exts_cap * 2 : 16;
    ExtCall *e = realloc(c->exts, cap * sizeof(*e));
    if (!e) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->exts = e;
    c->exts_cap = cap;
  }
  c->exts[c->nexts].off = c->code.len; // E8 之后、占位 rel32 的起点
  c->exts[c->nexts].target = target;
  c->nexts++;
}

// v1.1.0 浮点（阶段1）：登记一条 double 常量（8 字节位型进数据区；movsd 加载）
// 为什么不用 mov rax,imm64 + movq：任意 64 位立即数要走 movabs（10 字节）+ 寄存器中转；
// 放数据区一条 movsd xmm0,[rip+disp32]（8 字节）更短，也和字符串常量同一套机制。
//
// ⚠️ 2026-09-13（v1.2.1 途中实证的真 bug，两层）：
//   ① 本函数原返回 **DblRef***（数组内地址），调用方 `r->off = c->code.len;` 是**后写**的——
//      若这两步之间又有别的常量登记触发 realloc，数组搬家 → 那个指针变悬垂 → `r->off` 写进旧内存，
//      该 movsd 的 disp32 永远不回填（disp=0 → 运行时 `[rip+0]` 读成 0.0，静默错值）。
//   ② 更根本：一条记录只有**一个** off 字段，而同一个常量**可以出现多次**——去重时返回同一条，
//      调用方把 off **覆盖**成最后一次的位置 ⇒ 前面那些 movsd 全都不回填。
//   修法（机制层，两层一起治）：登记返回**下标**（不让指向数组内部的指针跨过任何登记调用存活），
//      记录里挂**出现位置表**（offs/noffs），每个出现位置各自回填。
static size_t note_dblref(FuncCtx *c, double v) {
  for (size_t i = 0; i < c->ndblrefs; i++)            // 去重：同一个值只占一份数据
    if (c->dblrefs[i].bits == dbl_bits(v)) return i;
  if (c->ndblrefs == c->dblrefs_cap) {
    size_t cap = c->dblrefs_cap ? c->dblrefs_cap * 2 : 8;
    DblRef *d = realloc(c->dblrefs, cap * sizeof(*d));
    if (!d) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->dblrefs = d;
    c->dblrefs_cap = cap;
  }
  size_t idx = c->ndblrefs++;
  DblRef *r = &c->dblrefs[idx];
  r->bits = dbl_bits(v);
  r->offs = NULL;
  r->noffs = 0;
  r->offs_cap = 0;
  return idx;
}

// 登记「这个常量在本函数里的一处使用位置」（disp32 在 code 内的偏移）
static void note_dbluse(FuncCtx *c, size_t idx, size_t off) {
  DblRef *r = &c->dblrefs[idx];
  if (r->noffs == r->offs_cap) {
    size_t cap = r->offs_cap ? r->offs_cap * 2 : 4;
    size_t *p = realloc(r->offs, cap * sizeof(*p));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    r->offs = p;
    r->offs_cap = cap;
  }
  r->offs[r->noffs++] = off;
}

// —— v1.3.0 全局变量：rip 相对寻址 ——
// 目标地址 = DATA_RVA + Program.globals[gi].doff，但**只以 disp 差值进入指令**（[rip+disp32]）。
// 每处指令的 disp32 位置登记进 c->guses，codegen_main 收尾时按「函数在拼接代码里的偏移」逐处回填。
// 这就是全局变量方案不需要重定位表的原因——**产物里没有任何绝对地址**（与是否 ASLR 无关；
// ⚠️ 原文写「镜像无 ASLR」，2026-09-14 实测证伪，见「新路候选.md」§1.1 事实 3；pe.c 的 I1 断言守着这条）。
static void note_guse(FuncCtx *c, int gi) {
  if (c->nguses == c->guses_cap) {
    size_t cap = c->guses_cap ? c->guses_cap * 2 : 8;
    GUse *p = realloc(c->guses, cap * sizeof(*p));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->guses = p;
    c->guses_cap = cap;
  }
  c->guses[c->nguses].off = c->code.len;   // 占位 disp32 的起点
  c->guses[c->nguses].gi = gi;
  c->nguses++;
}

// 登记一处全局引用 + 发 4 字节占位 disp（回填时机：codegen_main 收尾）
static void g_use(FuncCtx *c, int gi) {
  note_guse(c, gi);
  buf_u32(&c->code, 0);
}

// —— 全局变量的读/写/取址（ModRM mod=00 rm=101 → [rip+disp32]）——
// 与 emit_*_var 一族（mod=01 rm=101 → [rbp-disp]）是**两套独立寻址**，函数名刻意分开（_g 后缀），
// 防止误用；所有全局变量 bug 的总源头就是把两者混着调。
static void emit_lea_g(FuncCtx *c, int gi) {          // lea rax,[rip+disp32]
  const uint8_t x[] = {0x48, 0x8D, 0x05};
  buf_bytes(&c->code, x, 3);
  g_use(c, gi);
}
// 现场只保留**当前有调用点**的发射器（未用的 7 个已删）：宽口径是「全局 int 一律 64 位读」
//   （见 ND_VAR / ND_ASSIGN 的宽度约定），所以 32 位的 emit_load_g / emit_store_g 用不上；
//   char/double 的写一律走间接通路（先算地址 → [rdx] 写），故 store 侧的 rip 版本也用不上。
//   要加新形态时按需补，别留一堆死发射器（gcc -Wall 会对 unused-function 报警，验收要求零新增警告）。
static void emit_load_g64(FuncCtx *c, int gi) {       // mov rax,[rip+disp32]（全局 int 读 = 64 位）
  const uint8_t x[] = {0x48, 0x8B, 0x05};
  buf_bytes(&c->code, x, 3);
  g_use(c, gi);
}
static void emit_load_gbyte(FuncCtx *c, int gi) {     // movzx eax,byte [rip+disp32]（char 读）
  const uint8_t x[] = {0x0F, 0xB6, 0x05};
  buf_bytes(&c->code, x, 3);
  g_use(c, gi);
}
// double 走 SSE：ModRM mod=00 rm=101 = 0x05（与 rbp 系的 0x45/0x85 区分）
static void emit_load_gdbl(FuncCtx *c, int gi) {      // movsd xmm0,[rip+disp32]
  const uint8_t x[] = {0xF2, 0x0F, 0x10, 0x05};
  buf_bytes(&c->code, x, 4);
  g_use(c, gi);
}

// v1.3.0 全局变量间接 64 位自增/自减（rdx 已持目标地址）——全局 int 的读是 64 位，
//   inc/dec 也必须 64 位，否则只动低 4 字节、高位留残渣，而读回走 64 位 → 静默错值。
static void emit_inc_rax_at_rdx(Buf *b) { const uint8_t x[] = {0x48, 0xFF, 0x02}; buf_bytes(b, x, 3); } // inc qword [rdx]
static void emit_dec_rax_at_rdx(Buf *b) { const uint8_t x[] = {0x48, 0xFF, 0x0A}; buf_bytes(b, x, 3); } // dec qword [rdx]
static void emit_load_rax_at_rdx(Buf *b) { const uint8_t x[] = {0x48, 0x8B, 0x02}; buf_bytes(b, x, 3); } // mov rax,[rdx]（64 位读）

// v0.9.3：记录 &函数名 引用（lea rax,[rip+disp] 占位后调用；布局完成后回填 disp）
static void note_funcaddr(FuncCtx *c, int target) {
  if (c->nfuncaddrs == c->funcaddrs_cap) {
    size_t cap = c->funcaddrs_cap ? c->funcaddrs_cap * 2 : 8;
    FuncAddrRef *f = realloc(c->funcaddrs, cap * sizeof(*f));
    if (!f) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->funcaddrs = f;
    c->funcaddrs_cap = cap;
  }
  c->funcaddrs[c->nfuncaddrs].off = c->code.len; // lea 后、占位 disp32 的起点
  c->funcaddrs[c->nfuncaddrs].target = target;
  c->nfuncaddrs++;
}

// v0.7.3：登记一条字符串引用（返回槽位；gen ND_STR 填内容，排布后回填 disp）
static StrRef *note_strref(FuncCtx *c) {
  if (c->nstrrefs == c->strrefs_cap) {
    size_t cap = c->strrefs_cap ? c->strrefs_cap * 2 : 8;
    StrRef *sr = realloc(c->strrefs, cap * sizeof(*sr));
    if (!sr) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->strrefs = sr;
    c->strrefs_cap = cap;
  }
  return &c->strrefs[c->nstrrefs++];
}

// ========== 指令发射助手 ==========
static void emit_mov_eax_imm(Buf *b, int imm) { buf_byte(b, 0xB8); buf_u32(b, (uint32_t)imm); }
// v1.3.1：cmp eax, imm32（0x3D + 补码 imm32）——switch 排跳转表用（条件值在 eax）
static void emit_cmp_eax_imm(Buf *b, int imm) { buf_byte(b, 0x3D); buf_u32(b, (uint32_t)imm); }
static void emit_mov_ecx_eax(Buf *b)          { const uint8_t x[] = {0x89, 0xC1}; buf_bytes(b, x, 2); }
static void emit_push_rax(Buf *b)             { buf_byte(b, 0x50); g_rspm = (g_rspm - 8) & 15; }
static void emit_pop_rax(Buf *b)              { buf_byte(b, 0x58); g_rspm = (g_rspm + 8) & 15; }
static void emit_pop_rcx(Buf *b)              { buf_byte(b, 0x59); g_rspm = (g_rspm + 8) & 15; }
static void emit_pop_rdx(Buf *b)              { buf_byte(b, 0x5A); g_rspm = (g_rspm + 8) & 15; }
static void emit_pop_r8(Buf *b)               { const uint8_t x[] = {0x41, 0x58}; buf_bytes(b, x, 2); g_rspm = (g_rspm + 8) & 15; }
static void emit_pop_r9(Buf *b)               { const uint8_t x[] = {0x41, 0x59}; buf_bytes(b, x, 2); g_rspm = (g_rspm + 8) & 15; }
// v1.4.23（M4）：callee-saved 寄存器的保存/恢复（序言 push、收尾逆序 pop；g_rspm 必须同步记账）
//   M4 只在"本函数无任何调用"时分配（这样 push 的奇偶不会影响**调用点**的 rsp 对齐）；
//   M5 ②（v1.4.27）起带调用的函数也分配 —— 序言按 push 个数奇偶补 8 字节垫，
//   使函数内每个 call 点恒落 rsp≡0（见 codegen_func 的 reg_pad）。
static void emit_push_saved_reg(Buf *b, int r) {
  switch (r) {
    case 0: buf_byte(b, 0x53); break;                       // push rbx
    case 1: { const uint8_t x[] = {0x41, 0x54}; buf_bytes(b, x, 2); break; }  // push r12
    case 2: { const uint8_t x[] = {0x41, 0x55}; buf_bytes(b, x, 2); break; }  // push r13
    case 3: { const uint8_t x[] = {0x41, 0x56}; buf_bytes(b, x, 2); break; }  // push r14
    case 4: { const uint8_t x[] = {0x41, 0x57}; buf_bytes(b, x, 2); break; }  // push r15
    default: error("内部错误：未知的 callee-saved 寄存器号 %d", r);
  }
  g_rspm = (g_rspm - 8) & 15;
}
static void emit_pop_saved_reg(Buf *b, int r) {
  switch (r) {
    case 0: buf_byte(b, 0x5B); break;                       // pop rbx
    case 1: { const uint8_t x[] = {0x41, 0x5C}; buf_bytes(b, x, 2); break; }  // pop r12
    case 2: { const uint8_t x[] = {0x41, 0x5D}; buf_bytes(b, x, 2); break; }  // pop r13
    case 3: { const uint8_t x[] = {0x41, 0x5E}; buf_bytes(b, x, 2); break; }  // pop r14
    case 4: { const uint8_t x[] = {0x41, 0x5F}; buf_bytes(b, x, 2); break; }  // pop r15
    default: error("内部错误：未知的 callee-saved 寄存器号 %d", r);
  }
  g_rspm = (g_rspm + 8) & 15;
}
static void emit_leave(Buf *b)                { buf_byte(b, 0xC9); g_rspm = 8; } // mov rsp,rbp + pop rbp
static void emit_ret(Buf *b)                  { buf_byte(b, 0xC3); }

// —— v0.6 引用支持 / v0.7 lvalue 统一 ——
// 槽取址发射器已归口映射层（v1.4.21 M2）：见 src\slotmap.c 的 slot_lea_rax（走过它的槽记 SF_ADDRESSED）
// eax ← [eax]（解引用读：地址在 eax，取 [eax]）
static void emit_deref_eax(Buf *b)            { const uint8_t x[] = {0x8B, 0x00}; buf_bytes(b, x, 2); } // mov eax,[rax]（32 位读）
static void emit_deref_rax64(Buf *b)          { const uint8_t x[] = {0x48, 0x8B, 0x00}; buf_bytes(b, x, 3); } // mov rax,[rax]（v0.9.2 64 位读）
static void emit_store_rax_at_rdx(Buf *b)     { const uint8_t x[] = {0x48, 0x89, 0x02}; buf_bytes(b, x, 3); } // mov [rdx],rax（v0.9.2 64 位写，S2）
// [rdx] ← eax / eax ← [rdx]（间接写/读目标：地址在 edx）
static void emit_store_eax_at_edx(Buf *b)     { const uint8_t x[] = {0x89, 0x02}; buf_bytes(b, x, 2); }
static void emit_load_eax_at_edx(Buf *b)      { const uint8_t x[] = {0x8B, 0x02}; buf_bytes(b, x, 2); }
// rdx ← rax（lvalue 地址转移；64 位，mov edx,eax 会清高 32 位不能用于地址）
static void emit_mov_rdx_rax(Buf *b)          { const uint8_t x[] = {0x48, 0x89, 0xC2}; buf_bytes(b, x, 3); }
// push rdx（复合赋值除法前暂存目标地址）
static void emit_push_rdx(Buf *b)             { buf_byte(b, 0x52); g_rspm = (g_rspm - 8) & 15; }
// inc/dec dword [edx]（引用/解引用目标的 ++/--）
static void emit_inc_mem_edx(Buf *b)          { const uint8_t x[] = {0xFF, 0x02}; buf_bytes(b, x, 2); }
static void emit_dec_mem_edx(Buf *b)          { const uint8_t x[] = {0xFF, 0x0A}; buf_bytes(b, x, 2); }
static void emit_add(Buf *b)                  { const uint8_t x[] = {0x01, 0xC8}; buf_bytes(b, x, 2); }
static void emit_sub(Buf *b)                  { const uint8_t x[] = {0x29, 0xC8}; buf_bytes(b, x, 2); }
// ===== M8 ①（2026-09-19）：把二元运算**直接算进 ecx**（对应 add/sub eax,ecx 的镜像形态）=====
// 用途只有一个：gen_call 的单实参路径想省掉「落 eax → mov rcx,rax」这场往返时，
//   得先能把 `x+y` 直接算在 rcx 里（表里编码的访问器只许在映射层，**指令编码**这一层在这边，与前例一致）。
static void emit_add_ecx_eax(Buf *b)          { const uint8_t x[] = {0x01, 0xC1}; buf_bytes(b, x, 2); } // add ecx,eax
static void emit_sub_ecx_eax(Buf *b)          { const uint8_t x[] = {0x29, 0xC1}; buf_bytes(b, x, 2); } // sub ecx,eax
static void emit_and_ecx_eax(Buf *b)          { const uint8_t x[] = {0x21, 0xC1}; buf_bytes(b, x, 2); } // and ecx,eax
static void emit_or_ecx_eax(Buf *b)           { const uint8_t x[] = {0x09, 0xC1}; buf_bytes(b, x, 2); } // or  ecx,eax
static void emit_xor_ecx_eax(Buf *b)          { const uint8_t x[] = {0x31, 0xC1}; buf_bytes(b, x, 2); } // xor ecx,eax
static void emit_imul(Buf *b)                 { const uint8_t x[] = {0x0F, 0xAF, 0xC1}; buf_bytes(b, x, 3); }
static void emit_cdq(Buf *b)                  { buf_byte(b, 0x99); }
static void emit_idiv(Buf *b)                 { const uint8_t x[] = {0xF7, 0xF9}; buf_bytes(b, x, 2); }
static void emit_mov_eax_edx(Buf *b)          { const uint8_t x[] = {0x89, 0xD0}; buf_bytes(b, x, 2); }
static void emit_neg(Buf *b)                  { const uint8_t x[] = {0xF7, 0xD8}; buf_bytes(b, x, 2); }
// —— v0.7.2 位运算（32 位无前缀，同 add/sub 家族）——
static void emit_and(Buf *b)                  { const uint8_t x[] = {0x21, 0xC8}; buf_bytes(b, x, 2); } // and eax,ecx
static void emit_or(Buf *b)                   { const uint8_t x[] = {0x09, 0xC8}; buf_bytes(b, x, 2); } // or  eax,ecx
static void emit_xor(Buf *b)                  { const uint8_t x[] = {0x31, 0xC8}; buf_bytes(b, x, 2); } // xor eax,ecx
static void emit_shl(Buf *b)                  { const uint8_t x[] = {0xD3, 0xE0}; buf_bytes(b, x, 2); } // shl eax,cl（移位量 cl）
static void emit_sar(Buf *b)                  { const uint8_t x[] = {0xD3, 0xF8}; buf_bytes(b, x, 2); } // sar eax,cl（算术右移保符号）
// —— v1.0.11 幂运算（^^）专用发射器（决策 49）——
static void emit_mov_edx_imm(Buf *b, int imm) { buf_byte(b, 0xBA); buf_u32(b, (uint32_t)imm); }        // mov edx,imm32（acc=1）
static void emit_imul_eax_eax(Buf *b)         { const uint8_t x[] = {0x0F, 0xAF, 0xC0}; buf_bytes(b, x, 3); } // imul eax,eax（base*=base）
static void emit_imul_edx_eax(Buf *b)         { const uint8_t x[] = {0x0F, 0xAF, 0xD0}; buf_bytes(b, x, 3); } // imul edx,eax（acc*=base）
static void emit_test_ecx(Buf *b)             { const uint8_t x[] = {0x85, 0xC9}; buf_bytes(b, x, 2); }       // test ecx,ecx
static void emit_test_cl_1(Buf *b)            { const uint8_t x[] = {0xF6, 0xC1, 0x01}; buf_bytes(b, x, 3); }  // test cl,1（取指数最低位）
static void emit_sar_ecx_1(Buf *b)            { const uint8_t x[] = {0xD1, 0xF9}; buf_bytes(b, x, 2); }       // sar ecx,1（exp>>=1）
//   ⚠️ 必须 D1 /7（移位量 1）；D3 /7 是「按 CL 移位」——CL 正好是 exp 低字节，会一次移光（实测踩过）
static void emit_not(Buf *b)                  { const uint8_t x[] = {0xF7, 0xD0}; buf_bytes(b, x, 2); } // not eax

// cmp eax, ecx（比较左=eax 右=ecx）
static void emit_cmp(Buf *b)                  { const uint8_t x[] = {0x39, 0xC8}; buf_bytes(b, x, 2); }
// test eax, eax
static void emit_test(Buf *b)                 { const uint8_t x[] = {0x85, 0xC0}; buf_bytes(b, x, 2); }
// setcc al + movzx eax, al
static void emit_setcc(Buf *b, uint8_t cc)    { buf_byte(b, 0x0F); buf_byte(b, cc); buf_byte(b, 0xC0); }
static void emit_movzx_eax_al(Buf *b)         { const uint8_t x[] = {0x0F, 0xB6, 0xC0}; buf_bytes(b, x, 3); }

// ===== v1.4.9（任务卡 T-20260917-011322 第一档 · 纯窥孔）：立即数形态的 ALU =====
// 病（靶子 = bench4 的循环体，`a = a + 3; i = i + 1;`）：右操作数哪怕是常量字面量也要
//   「求值成 eax → mov ecx,eax → push rax → pop rax → op eax,ecx」——常量每轮重新物化，还过一次栈。
// 修：右操作数是常量字面量时直接用立即数形态，**一条顶五条**，且不再压栈（rsp 记账天然不变）。
//   ① `83 /d ib`（符号扩展 imm8，2~4 字节，短）② `opcode imm32`（5~6 字节）。
// ⚠️ 位宽语义两条硬约束（写错就是静默错值，别改）：
//   · AND/OR/XOR 的 imm8 **只在 imm ∈ [0,127] 时**可用 —— 符号扩展会把高位置 1
//     （`and eax,0x80` 若写成 imm8 就变成 `and eax,0xFFFFFF80`）；ADD/SUB/CMP 的负数
//     符号扩展是**正确语义**（与 32 位补码一致），照走 imm8。
//   · 64 位（wide）形态的 imm32 一律**符号扩展**——与旧路径 `movsxd rcx,eax` 逐位等价。
// d 的取值 = ModRM 的 reg 字段（rm = 000 = eax/rax）：0=add 1=or 4=and 5=sub 6=xor 7=cmp
static void emit_alu_imm(Buf *b, int d, bool wide, int imm) {
  bool imm8ok = (imm >= -128 && imm <= 127);
  if (d == 1 || d == 4 || d == 6) imm8ok = imm8ok && (imm >= 0);   // or / and / xor 不吃负数 imm8
  if (imm8ok) {
    if (wide) buf_byte(b, 0x48);
    buf_byte(b, 0x83);
    buf_byte(b, (uint8_t)(0xC0 | (d << 3)));
    buf_byte(b, (uint8_t)imm);
    return;
  }
  static const uint8_t opc[8] = {0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D};
  if (wide) buf_byte(b, 0x48);
  buf_byte(b, opc[d & 7]);
  buf_u32(b, (uint32_t)imm);
}

// imul r32/r64, r/m, imm32（69 /r id）—— 乘常量专用（MUL 在 FLINT 里永不 wide，参数留作对称）
static void emit_imul_imm(Buf *b, bool wide, int imm) {
  if (wide) buf_byte(b, 0x48);
  buf_byte(b, 0x69);
  buf_byte(b, 0xC0);
  buf_u32(b, (uint32_t)imm);
}

// v1.4.9② 窥孔用：把局部槽**直接读进 ecx**（不碰 rax）——与 `mov eax,[槽]; mov ecx,eax`
// 逐位等价，但省掉 eax 中转；配合「不再压栈暂存 lhs」，把四条指令压成一条。
// 两个发射器已归口映射层（v1.4.21 M2）：slot_load_ecx（32 位）/ slot_load_rcx64（movsxd，64 位）

// —— v0.9 64 位地址算术（决策 17「地址算术 32 位截断」未竟边界拆除）——
// 地址类值（指针/数组名/结构体地址/字符串地址）参与的 + - 与比较必须 64 位：
// 32 位截断在 Windows 堆/数据段地址 >4GB 时必错（lea 高位被砍 → 解引用崩）
static void emit_mov_rcx_rax(Buf *b)          { const uint8_t x[] = {0x48, 0x89, 0xC1}; buf_bytes(b, x, 3); } // mov rcx,rax
static void emit_mov_r8_rax(Buf *b)           { const uint8_t x[] = {0x49, 0x89, 0xC0}; buf_bytes(b, x, 3); } // mov r8,rax
static void emit_mov_r9_rax(Buf *b)           { const uint8_t x[] = {0x49, 0x89, 0xC1}; buf_bytes(b, x, 3); } // mov r9,rax
static void emit_movsxd_rcx_eax(Buf *b)       { const uint8_t x[] = {0x48, 0x63, 0xC8}; buf_bytes(b, x, 3); } // v1.0.6.2 A7：movsxd rcx,eax（地址链 int 偏移符号扩展）
static void emit_movsxd_rax_eax(Buf *b)       { const uint8_t x[] = {0x48, 0x63, 0xC0}; buf_bytes(b, x, 3); } // v1.0.12：movsxd rax,eax（地址链「int 在左」侧符号扩展）
// 卡 T-20261010-122541：实参落位用的另三个 64 位寄存器版本（rdx/r8/r9 与 rcx 同族）。
//   ⚠️ 编码必须一个字一个字核：`movsxd r64, eax` 的 **rm 域恒为 eax(000)** ⇒ r8/r9 只需要
//   REX.R（0x4C），**不是** REX.R+B（0x4D，那是 movsxd r8,r8d 之类自食其果的形态）。
//   首版写成 4D 63 C0/4D 63 C9 ⇒ r8/r9 保留旧值、第 4 个实参恒为 0（探针 p_bits 的 ret=0 当场抓到）。
static void emit_movsxd_rdx_eax(Buf *b)       { const uint8_t x[] = {0x48, 0x63, 0xD0}; buf_bytes(b, x, 3); } // movsxd rdx,eax
static void emit_movsxd_r8_eax(Buf *b)        { const uint8_t x[] = {0x4C, 0x63, 0xC0}; buf_bytes(b, x, 3); } // movsxd r8,eax
static void emit_movsxd_r9_eax(Buf *b)        { const uint8_t x[] = {0x4C, 0x63, 0xC8}; buf_bytes(b, x, 3); } // movsxd r9,eax
static void emit_add64(Buf *b)                { const uint8_t x[] = {0x48, 0x01, 0xC8}; buf_bytes(b, x, 3); } // add rax,rcx
static void emit_sub64(Buf *b)                { const uint8_t x[] = {0x48, 0x29, 0xC8}; buf_bytes(b, x, 3); } // sub rax,rcx
static void emit_cmp64(Buf *b)                { const uint8_t x[] = {0x48, 0x39, 0xC8}; buf_bytes(b, x, 3); } // cmp rax,rcx
static void emit_test64(Buf *b)               { const uint8_t x[] = {0x48, 0x85, 0xC0}; buf_bytes(b, x, 3); } // test rax,rax

// ===== v1.7.0 int_64：64 位值算术语义的全套发射器 =====
// 口径（§2.9）：溢出 = 2^64 回绕（补码，不饱和/不陷阱，与 int 的 32 位回绕同一条纪律）；
//   除零 / INT64_MIN ÷ -1 = 硬件 #DE（与 int 的 INT32_MIN ÷ -1 完全对称，不做守卫）；
//   移位量 ≥ 64 由硬件掩码（mod 64），与 32 位侧的 mod 32 一致。
// ⚠️ 寄存器约定与 32 位档**逐条同形**：rax = 左/累加，rcx = 右（除法另用 rdx）。
static void emit_imul64(Buf *b)               { const uint8_t x[] = {0x48, 0x0F, 0xAF, 0xC1}; buf_bytes(b, x, 4); } // imul rax,rcx
static void emit_and64(Buf *b)                { const uint8_t x[] = {0x48, 0x21, 0xC8}; buf_bytes(b, x, 3); } // and rax,rcx
static void emit_or64(Buf *b)                 { const uint8_t x[] = {0x48, 0x09, 0xC8}; buf_bytes(b, x, 3); } // or  rax,rcx
static void emit_xor64(Buf *b)                { const uint8_t x[] = {0x48, 0x31, 0xC8}; buf_bytes(b, x, 3); } // xor rax,rcx
static void emit_shl64(Buf *b)                { const uint8_t x[] = {0x48, 0xD3, 0xE0}; buf_bytes(b, x, 3); } // shl rax,cl
static void emit_sar64(Buf *b)                { const uint8_t x[] = {0x48, 0xD3, 0xF8}; buf_bytes(b, x, 3); } // sar rax,cl（算术右移保符号）
static void emit_not64(Buf *b)                { const uint8_t x[] = {0x48, 0xF7, 0xD0}; buf_bytes(b, x, 3); } // not rax
static void emit_neg64(Buf *b)                { const uint8_t x[] = {0x48, 0xF7, 0xD8}; buf_bytes(b, x, 3); } // neg rax
static void emit_cqo(Buf *b)                  { const uint8_t x[] = {0x48, 0x99}; buf_bytes(b, x, 2); }       // cqo（rdx:rax = 符号扩展）
static void emit_idiv64(Buf *b)               { const uint8_t x[] = {0x48, 0xF7, 0xF9}; buf_bytes(b, x, 3); } // idiv rcx（商 rax / 余 rdx）
static void emit_mov_rax_rdx64(Buf *b)        { const uint8_t x[] = {0x48, 0x89, 0xD0}; buf_bytes(b, x, 3); } // mov rax,rdx（取余数）
// int_64 → int（to_int32）：取低 32 位。`mov eax,eax` 顺带把高半清零（64 位寄存器的 32 位写约束）
static void emit_l2i(Buf *b)                  { const uint8_t x[] = {0x89, 0xC0}; buf_bytes(b, x, 2); }
// mov rax, imm64：`48 B8` + 8 字节；能装进 int32 时退 `48 C7 C0 imm32`（符号扩展，短 3 字节）
static void emit_mov_rax_imm64(Buf *b, long long v) {
  if (v >= -2147483648LL && v <= 2147483647LL) {
    const uint8_t x[] = {0x48, 0xC7, 0xC0};
    buf_bytes(b, x, 3);
    buf_u32(b, (uint32_t)(int)v);
    return;
  }
  buf_byte(b, 0x48);
  buf_byte(b, 0xB8);
  buf_u64(b, (uint64_t)v);
}

// —— v0.9 new/own 内存管理助手 ——
static void emit_push_rcx(Buf *b)             { buf_byte(b, 0x51); g_rspm = (g_rspm - 8) & 15; } // push rcx（main 返回值保护）
static void emit_lea_rax_rdx8(Buf *b)         { const uint8_t x[] = {0x48, 0x8D, 0x42, 0x08}; buf_bytes(b, x, 4); } // lea rax,[rdx+8]（负载=基址+头部8B）
static void emit_sub_rax8(Buf *b)             { const uint8_t x[] = {0x48, 0x83, 0xE8, 0x08}; buf_bytes(b, x, 4); } // sub rax,8（基址=负载-头部）
static void emit_mov_rax_rdx(Buf *b)          { const uint8_t x[] = {0x48, 0x89, 0xD0}; buf_bytes(b, x, 3); } // mov rax,rdx
static void emit_inc_eax(Buf *b)              { const uint8_t x[] = {0x83, 0xC0, 0x01}; buf_bytes(b, x, 3); } // add eax,1（refcount++）
static void emit_dec_eax(Buf *b)              { const uint8_t x[] = {0x83, 0xC0, 0xFF}; buf_bytes(b, x, 3); } // add eax,-1（refcount--）
static void emit_inc_rax(Buf *b)              { const uint8_t x[] = {0x48, 0xFF, 0xC0}; buf_bytes(b, x, 3); } // v1.0.6.1 A1：inc rax（指针 ++ 64 位，字节步进——决策 40：裸指针算术=字节单位）
static void emit_dec_rax(Buf *b)              { const uint8_t x[] = {0x48, 0xFF, 0xC8}; buf_bytes(b, x, 3); } // v1.0.6.1 A1：dec rax（指针 -- 64 位，字节步进）

static void emit_push_rbp(Buf *b)             { buf_byte(b, 0x55); g_rspm = (g_rspm - 8) & 15; }
static void emit_mov_rbp_rsp(Buf *b)          { const uint8_t x[] = {0x48, 0x89, 0xE5}; buf_bytes(b, x, 3); }

static void emit_sub_rsp(Buf *b, int imm) {
  g_rspm = (g_rspm - imm) & 15;
  if (imm <= 127) {
    const uint8_t x[] = {0x48, 0x83, 0xEC, (uint8_t)imm};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x81); buf_byte(b, 0xEC); buf_u32(b, (uint32_t)imm);
  }
}

// v0.8：add rsp,imm（API call 后回收 shadow space）
static void emit_add_rsp(Buf *b, int imm) {
  g_rspm = (g_rspm + imm) & 15;
  if (imm <= 127) {
    const uint8_t x[] = {0x48, 0x83, 0xC4, (uint8_t)imm};
    buf_bytes(b, x, 4);
  } else {
    buf_byte(b, 0x48); buf_byte(b, 0x81); buf_byte(b, 0xC4); buf_u32(b, (uint32_t)imm);
  }
}

// 决策 41（B2b 撞墙）：大帧栈探测——帧超一页时逐页 sub + 触碰，逼 OS 守护页按序提交。
// 背景：Windows 线程初始提交栈有限（本机实测 ~24KB），一次性 sub rsp 跳过大页后，凡写深处
//   （push rax / 变量写）会**跳过守护页**直达未提交区 → 0xC0000005。
//   B2b boot 驱动 27KB 帧实证（char 数组按 8B/槽 → 数组帧膨胀快）；23KB 帧因不写深处而侥幸不崩。
// 做法：每 4KB 一次 sub + `mov byte ptr [rsp],0` 探测（[rsp] 每次落在严格更低的页）；
//   余数不足一页再 sub 收尾（其页首触达由后续真实写触发守护页提交）。
static void emit_stack_alloc(Buf *b, int frame) {
  const uint8_t probe[] = {0xC6, 0x04, 0x24, 0x00};   // mov byte ptr [rsp], 0
  int rem = frame;
  while (rem > 4096) {
    emit_sub_rsp(b, 4096);
    buf_bytes(b, probe, 4);
    rem -= 4096;
  }
  if (rem > 0) emit_sub_rsp(b, rem);
}

// ===== v1.4.20/21（任务卡 T-20260919-010437 · IR 重构 M1→M2）：槽访问的**唯一出口** =====
// 实现**全部搬到映射层 `src\slotmap.c`**（M1 归口 10 个发射器；M2 把剩下 14 个也收进来，
//   并加上"槽 → 位置"表与属性记录）。设计见 E:\FLINT-lab\IR重构-设计与迁移计划.md §二。
//   ⚠️ 纪律（不变）：生成层只调 `slot_*` —— **禁止**再在本文件里写帧槽偏移的编码
//      （否则 M4 的寄存器分配失效规则会漏网：漏一处 = 编译过、静默错值）。
//   ⚠️ `-stats` 口径也不许变：哪条访问进账本、哪条不进，逐处与归口前一致（见 slotmap.c 里各 sl_stats）。
//   审计：`test\映射层审计.ps1`（断言帧槽编码只在 slotmap.c、生成层不留旧名调用）
// —— v1.0.5 B 档 char：字节级读/写/自增自减（movzx 零扩展读 0..255；88 写低字节；FE 字节 inc/dec）——
// 槽侧四个发射器（读/写/inc/dec）已归口映射层（v1.4.21 M2）：见 src\slotmap.c
static void emit_load_byte_at_rax(Buf *b) { const uint8_t x[] = {0x0F, 0xB6, 0x00}; buf_bytes(b, x, 3); } // movzx eax, byte [rax]
static void emit_load_byte_at_rdx(Buf *b) { const uint8_t x[] = {0x0F, 0xB6, 0x02}; buf_bytes(b, x, 3); } // movzx eax, byte [rdx]
static void emit_store_byte_at_rdx(Buf *b) { const uint8_t x[] = {0x88, 0x02}; buf_bytes(b, x, 2); }      // mov [rdx], al
// 槽字节 inc/dec 归口映射层（v1.4.21 M2）：slot_inc_byte / slot_dec_byte
static void emit_inc_byte_at_edx(Buf *b) { const uint8_t x[] = {0xFE, 0x02}; buf_bytes(b, x, 2); } // inc byte [rdx]
static void emit_dec_byte_at_edx(Buf *b) { const uint8_t x[] = {0xFE, 0x0A}; buf_bytes(b, x, 2); } // dec byte [rdx]
// v1.0.5：左值是 char 目标（ND_VAR char 标量 / ND_DEREF.ty==TY_CHAR 字段·元素·char*）→ 字节宽
static bool lv_is_char(Node *lv) { return lv->ty == TY_CHAR; }
// —— v0.8 64 位地址链：地址类值（指针变量/引用槽存的地址）全 64 位存取 ——
// 槽侧发射器已归口映射层（v1.4.21 M2）：slot_load_rax64 / slot_store_rax64，见 src\slotmap.c
// 形参装载的 8 个槽发射器（rcx/rdx/r8/r9 的 64 位与 32 位档）已归口映射层（v1.4.21 M2）：
//   slot_store_rcx64 / slot_store_rdx64 / slot_store_r8_64 / slot_store_r9_64
//   slot_store_ecx / slot_store_edx / slot_store_r8d / slot_store_r9d

// call [rip+disp32]（IAT，ExitProcess 用）
static void emit_call_iat(Buf *b, size_t *disp_off) {
  rsp_assert_ok("ExitProcess 调用");   // v1.0.4.1
  slotmap_note_call();                 // v1.4.21（M2）：调用点推进"调用纪元"
  st_call(); st_ins();
  buf_byte(b, 0xFF);
  buf_byte(b, 0x15);
  *disp_off = b->len;
  buf_u32(b, 0);
}

// jmp rel32 → label（E9 + 占位，函数内回填）
static void emit_jmp_label(FuncCtx *c, int label) {
  slotmap_bb_boundary(BB_JMP);   // v1.4.23（M4）：**先**写回脏寄存器（必须在跳转之前），再作废
  buf_byte(&c->code, 0xE9);
  note_patch(c, label);
  buf_u32(&c->code, 0);
}

// jcc rel32 → label（0F 8x + 占位，函数内回填）；cc = 84(je) 85(jne) 8C(jl) 8E(jle) 8F(jg) 8D(jge)
static void emit_jcc_label(FuncCtx *c, uint8_t cc, int label) {
  slotmap_bb_boundary(BB_JCC);   // v1.4.23（M4）：先写回（覆盖落空那条边），再发条件跳转
  buf_byte(&c->code, 0x0F);
  buf_byte(&c->code, cc);
  note_patch(c, label);
  buf_u32(&c->code, 0);
}

// ========== AST → 机器码 ==========
static void gen_expr(FuncCtx *c, Node *node);
static void gen_stmt(FuncCtx *c, Node *node);

// v0.9：表达式值是否「地址类」（须 64 位语义）。判定该表达式参与的
// 加减/比较/判真走 64 位路径。规则：
//   字符串字面量、&x、指针/数组名/结构体名作值 → 地址；
//   引用读 = 解引用后的对象值（int& → int）；结构体引用读 = 对象地址（槽内容）；
//   地址链 ND_ADD/ND_SUB（a[i] = *(a+i*8)、p->x = *(p+off) 的展开）→ 任一侧地址即地址链；
//   解引用 = 对象值（int）；函数/API 返回 = int（句柄先存 int* 槽再算，MVP 边界）
static bool is_addr_expr(Node *n) {
  if (!n) return false;
  switch (n->kind) {
    case ND_STR: return true;
    case ND_ADDR: return true;
    case ND_FUNC_ADDR: return true;   // v0.9.3：函数地址值 = 代码段地址（64 位）
    case ND_VAR:
      if (n->is_ref) return n->ty == TY_STRUCT; // int& 读=值；struct& 读=槽内容(对象地址)
      // v1.3.2：函数指针也是 64 位代码地址（判真/比较/传参都走 64 位通路）
      return n->ty == TY_PTR || n->ty == TY_ARR || n->ty == TY_STRUCT || n->ty == TY_FUNCPTR;
    case ND_ADD: case ND_SUB:
      return is_addr_expr(n->lhs) || is_addr_expr(n->rhs);
    case ND_DEREF: return n->ty == TY_PTR;      // v0.9.2：ptr 字段读回 = 指针值（地址，64 位）
    case ND_CALL: return n->ty == TY_PTR;       // v1.0.6：指针返回函数调用 = 地址值（64 位 rax）
    case ND_APICALL: return n->ty == TY_PTR;    // v0.9.2：ptr 返回 API = 64 位句柄/地址
    case ND_NEW: return true;                   // v0.9.2：new 表达式值 = 负载地址
    // v1.3.1：三元的结果宽度由 parse 定死（两支地址 → ty=TY_PTR；两支值 → int/double）。
    //   这里读 ty 即可——**不重推两分支**（两侧判据不一致是浮点旧坑的来源）。
    case ND_TERN: return n->ty == TY_PTR;
    default: return false;
  }
}

// ===== v1.7.0：64 位取值通道的**单一判据** =====
// 语义：`rax` 里这个表达式的值是不是**完整 64 位**（可以直接参与 64 位 alu / 64 位存槽 / 整搬）。
//   两条来源：① 地址类（is_addr_expr）② int_64 值（expr_is_i64）。
// ⚠️ 这是本设计最关键的一刀（§2.4）：宽档里原来那 6 处
//   `if (wide && !is_addr_expr(x)) emit_movsxd_rax_eax(b);`
//   的语义是"非地址侧是 32 位值，要符号扩展"。int_64 操作数既不满足 is_addr_expr
//   又**不该**被扩展 ⇒ 条件一律改成 `!is64_value(x)`。漏改任何一处 =
//   每个 int64 操作数的高 32 位被 movsxd 抹掉，**编译完全通过、值错**。
static bool is64_value(Node *n) { return is_addr_expr(n) || expr_is_i64(n); }

// ===== v1.0.13 T1：int 装地址的自动适配（评审清单【3】收口，用户拍板「编译器自己判断」）=====
// 病根：int 是 4 字节语义，往 int 槽里存 64 位地址会**静默截断**高 32 位，再当指针用即 0xC0000005。
// T1 规则（判断不了就报错，绝不静默猜一个宽度）：
//   ① 直接 int 变量 ← 地址值 → 槽按 8 字节存，并**标记**它为「装地址的 int」；被标记变量的所有
//      直接存都写满 8 字节（普通 int 值先符号扩展）→ 高半永远确定，不留栈残渣。
//   ② 被标记变量的读一律 8 字节（高半完整）→ 赋给指针目标、与地址比较都拿到完整地址。
//      注：算术仍按 32 位（语义一行未改），所以「地址经算术中转」不在 T1 内——那种值再当指针用
//      会在 ④ 被拦下（不静默）。
//   ③ 间接 int/char 目标（数组元素 / 结构体 int、char 字段 / 解引用）只有 4/1 字节，装不下地址 → 编译期报错。
//   ④ 指针目标只接「64 位算出来的地址表达式 / 显式常量 / API 返回值（句柄兼容，SPEC:152）/ 被标记的 int 变量」；
//      其余（未标记 int、间接 4 字节对象、int 返回函数调用、int 算术链）会截断或读到残渣 → 编译期报错。
// 遗留边界（T2 的事，已写入 SPEC）：int 形参接地址、int 函数返回地址仍按声明类型取低 32 位；
// 需要完整地址请把类型声明成 int * / ptr。boot 侧未接（自举轨道再补，与 v1.0.11 ^^ 同处理）。
static int *g_ai = NULL;   // 被标记的 int 槽偏移（每函数重算）
static int g_nai = 0, g_aicap = 0;

static bool slot_marked(int off) {
  for (int i = 0; i < g_nai; i++) if (g_ai[i] == off) return true;
  return false;
}

static bool mark_slot(int off) {
  if (slot_marked(off)) return false;
  if (g_nai == g_aicap) {
    int cap = g_aicap ? g_aicap * 2 : 8;
    int *p = realloc(g_ai, (size_t)cap * sizeof(int));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    g_ai = p; g_aicap = cap;
  }
  g_ai[g_nai++] = off;
  return true;
}

// 「值本身是地址」的表达式（区别于「地址差」这类标量）——T1 的存宽判定与指针目标门槛都用它。
// 与 is_addr_expr 的分工：is_addr_expr 决定「算术是否走 64 位」；本函数决定「这个值是不是地址」。
static bool is_addr_value(Node *n) {
  if (!n) return false;
  switch (n->kind) {
    case ND_STR: case ND_ADDR: case ND_FUNC_ADDR: case ND_NEW: return true;
    case ND_VAR:
      if (n->is_ref) return n->ty == TY_STRUCT;
      if (n->ty == TY_INT) return slot_marked(n->offset);   // T1：装过地址的 int
      // v1.3.2：函数指针变量本身值就是地址（T1 门槛/存宽判定按 64 位）
      return n->ty == TY_PTR || n->ty == TY_ARR || n->ty == TY_STRUCT || n->ty == TY_FUNCPTR;
    case ND_DEREF: return n->ty == TY_PTR;
    case ND_CALL: case ND_APICALL: return n->ty == TY_PTR;
    // 指针的 ++/--（v1.0.6.1 A1 起值是完整 64 位地址；is_addr_expr 不含 inc/dec 节点，
    // 故 `char *q = p++;`（audit1）这类写法要在本函数里认出来，否则会被 T1 门槛误拦）
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      return is_addr_value(n->lhs);
    case ND_ASSIGN: return is_addr_value(n->rhs);   // 赋值表达式作值 = 被赋的值
    case ND_ADD: return is_addr_value(n->lhs) || is_addr_value(n->rhs);
    case ND_SUB:
      if (is_addr_value(n->lhs) && is_addr_value(n->rhs)) return false;  // 地址 − 地址 = 差值（标量，不是地址）
      return is_addr_value(n->lhs) || is_addr_value(n->rhs);
    case ND_TERN: return n->ty == TY_PTR;   // v1.3.1：两支都是地址（parse 保证同指向类型）
    default: return false;
  }
}

// v1.6.3 缺陷修复（地址链相减当 print 段用会编译失败）：
//   `print(["d=", (ia + 8) - ia, "\n"])` —— `(ia+8)-ia` 是**标量差值**，可调用点 :1809 的
//   `is_addr_value(chk) || is_addr_expr(chk)` 里，is_addr_expr 对 ND_ADD/ND_SUB **一律**按
//   `lhs || rhs` 判地址（:708-709），**缺了 is_addr_value 早已写好的那条例外**（:773-775：
//   两侧都是地址 ⇒ 地址 − 地址 = 标量）⇒ 差值被误判成地址 ⇒ 报"地址值不能装进 int 形参"。
//   ⚠️ 这里**只**在需要那条例外的判据处修（调用点的"这个值是不是地址"），**不动** is_addr_expr
//   本身：它还管着"算术是否走 64 位"（wide 选择 :1233-1236 / movsxd 分流 :1251,1266,1275），
//   全局改会反过来打坏今天正确的标量路径（`int d = (ia+8)-ia;` 今天 8/8 正确）。
//   判据口径与 is_addr_value 的 ND_SUB 分支逐字一致（两侧都是"值-地址类" ⇒ 结果是标量）。
static bool addr_diff_is_scalar(Node *n) {
  if (!n || n->kind != ND_SUB) return false;
  return is_addr_value(n->lhs) && is_addr_value(n->rhs);
}

// ===== 卡 T-20261010-122541：实参值搬进 64 位 GP 实参寄存器时的「宽度语义」单点 =====
// 病：`mov rcx/rdx/r8/r9, rax` 是**整搬** 64 位，可 rax 里的 int 值是 32 位运算的结果
//     （`mov eax,0; sub eax,2` 会把高 32 位清零）⇒ 负值被**零扩展**成 0x00000000FFFFFFFE。
//     内核按指针宽度比 (HWND) 时 `SetWindowPos(hwnd, 0-2, …)` 报 ERROR_INVALID_WINDOW_HANDLE(1400)。
// 规则（判据复用项目既有那一套，别另发明）：值本身是地址类（is_addr_value / is_addr_expr，
//     含 ND_APICALL 的 ptr 返回值、T1 标记过的 int 句柄槽）⇒ 它本来就是完整 64 位 ⇒ **整搬**；
//     其余都是 int 值（4 字节语义）⇒ **movsxd r64,eax 符号扩展**（与地址链 int 侧同一口径）。
// 调用点三处：gen_call 的双通道落位 / gen_call_many / gen_apicall —— **必须同源**（写错一处就是静默错值）。
static void emit_arg_rax_to_gp(Buf *b, int gi, Node *arg) {
  // v1.7.0：int_64 实参也要**整搬**（它是完整 64 位值；走 movsxd 会截断高 32 位）
  bool addr = is_addr_value(arg) || is_addr_expr(arg) || expr_is_i64(arg);
  if (gi == 0)      { if (addr) emit_mov_rcx_rax(b); else emit_movsxd_rcx_eax(b); }
  else if (gi == 1) { if (addr) emit_mov_rdx_rax(b); else emit_movsxd_rdx_eax(b); }
  else if (gi == 2) { if (addr) emit_mov_r8_rax(b);  else emit_movsxd_r8_eax(b); }
  else              { if (addr) emit_mov_r9_rax(b);  else emit_movsxd_r9_eax(b); }
}

// 标记传递（定点）：x = 地址值 → x 是「装地址的 int」；x = 已标记的 int → 也是（函数内转手不丢）。
static bool ai_pass(Node *n) {
  bool changed = false;
  for (; n; n = n->next) {
    if (n->kind == ND_ASSIGN && n->lhs && n->lhs->kind == ND_VAR && !n->lhs->is_ref &&
        n->lhs->ty == TY_INT && is_addr_value(n->rhs))
      changed |= mark_slot(n->lhs->offset);
    if (n->lhs) changed |= ai_pass(n->lhs);
    if (n->rhs) changed |= ai_pass(n->rhs);
    if (n->els) changed |= ai_pass(n->els);
    if (n->init) changed |= ai_pass(n->init);
    if (n->cond) changed |= ai_pass(n->cond);
    if (n->inc) changed |= ai_pass(n->inc);
  }
  return changed;
}

// v1.4.21（M2）：把函数体 AST 里出现过的变量槽申报给映射层（**生成层认识 AST，映射层不认识**）。
//   递归口径与 ai_pass 完全一致：next 链 = 语句链 / 实参链，五个子指针全走。
//   属性只做"记录"，本版不改任何发射（判据 1：等价门 193 条指纹不变）。
static void slotmap_declare_ast(Node *n) {
  for (; n; n = n->next) {
    if (n->kind == ND_VAR && !n->is_global) {   // 全局变量不是帧槽（走 rip 相对寻址），不申报
      unsigned f = 0;
      if (n->ty == TY_ARR || n->ty == TY_STRUCT) f |= SF_AGGREGATE;   // 数组/结构体：按首槽寻址
      if (n->is_ref) f |= SF_REF;                                     // 引用槽：槽里存对象地址
      if (n->is_own || n->is_share) f |= SF_MANAGED;                  // own/share 托管指针
      if (n->ty == TY_INT && slot_marked(n->offset)) f |= SF_T1ADDR;  // T1「装地址的 int」槽
      slotmap_declare(n->offset, n->ty, f);
    }
    // M5 ②（2026-09-19）：**取址的槽静态钉死**（走内存，不给寄存器）。
    //   为什么静态判而不是发射期兜底：映射层的"运行期降级"只在发射到那一条的位置生效，
    //   而跳过该位置的路径（另一分支 / 递归的另一份）会读到**从未初始化**的内存槽 ⇒ 静默错值
    //   （M5 ② 的 boot 门 183/27 就是这个：`out + o` 的 movsxd 把 `o` 降级在 include 分支里）。
    //   取址是"别人可能直接读写这块内存"的语义 ⇒ 这种槽本来就**必须**全程在内存（与 SF_REF 同族）。
    //   M6 ④（2026-09-19）：**同时显式带上 SF_NOREG** —— 这是"被取址 ⇒ 不给寄存器"的**唯一一处静态决定**，
    //     把话说全（而不是依赖 slotmap.h 里 SF_NOREG 恰好含 SF_ADDRESSED 这条派生关系）：
    //     映射层 `slotmap_plan_regs` 里那条不变量断言就是照这一条写的（ADDRESSED 还进了 REG 就当场报错）。
    if (n->kind == ND_ADDR && n->lhs && n->lhs->kind == ND_VAR && !n->lhs->is_global)
      slotmap_declare(n->lhs->offset, n->lhs->ty, SF_ADDRESSED | SF_NOREG);  // &x
    if (n->kind == ND_REF_BIND && n->rhs && n->rhs->kind == ND_VAR && !n->rhs->is_global)
      slotmap_declare(n->rhs->offset, n->rhs->ty, SF_ADDRESSED | SF_NOREG);  // int &r = x
    if (n->lhs) slotmap_declare_ast(n->lhs);
    if (n->rhs) slotmap_declare_ast(n->rhs);
    if (n->els) slotmap_declare_ast(n->els);
    if (n->init) slotmap_declare_ast(n->init);
    if (n->cond) slotmap_declare_ast(n->cond);
    if (n->inc) slotmap_declare_ast(n->inc);
  }
}

// v1.4.23（M4）：本函数体里到底有没有"调用"（决定要不要做寄存器分配 —— 条件⑤）。
//   算的：普通/间接函数调用、API 调用、new（是 VirtualAlloc 调用）、托管指针的出口释放（也是调用，
//   由调用方把 nown+nshare>0 一并传进来）。递归口径与 ai_pass / slotmap_declare_ast 完全一致。
//   为什么这么保守：本版寄存器分配的"块边界写回"是对的，但**调用点的 rsp 对齐**要求成对 push/pop
//   恰好保持 ≡0 —— 无调用就没有这个要求，先不碰它（跨调用存活另立一轮）。
static bool ast_has_call(Node *n) {
  for (; n; n = n->next) {
    if (n->kind == ND_CALL || n->kind == ND_APICALL || n->kind == ND_NEW) return true;
    if (n->lhs && ast_has_call(n->lhs)) return true;
    if (n->rhs && ast_has_call(n->rhs)) return true;
    if (n->els && ast_has_call(n->els)) return true;
    if (n->init && ast_has_call(n->init)) return true;
    if (n->cond && ast_has_call(n->cond)) return true;
    if (n->inc && ast_has_call(n->inc)) return true;
  }
  return false;
}

// ===== v1.4.26（M5 ①）：数组/指针下标寻址的融合 =====
// 病（实测 bench k2）：`a[j & 3] = a[j & 3] + i` 每次元素访问要 **8 条**只为算出"帧基址 + 下标×8"：
//   lea -0x28(%rbp),%rax / push %rax / mov %r12d,%eax / and $3,%eax / imul $8,%eax,%eax /
//   movslq %eax,%rcx / pop %rax / add %rcx,%rax —— 而**本地数组的基址是编译期常量**（rbp-off）。
// 修法三档（只动"这一条链"的发射；语义逐位对齐，见下"非负"条件）：
//   ① 本地数组 + 常量下标      → `lea rax,[rbp-off+下标*8]` 一条（位移折进 disp8/disp32）
//   ② 本地数组 + 已知非负下标  → `lea rax,[rbp-off+rax*8]` 一条（索引留在 rax 当 SIB 索引）
//   ③ 本地指针槽 `p[i]` + 已知非负且**无副作用**的下标 → `mov rcx,[槽]` + `lea rax,[rcx+rax*8]`
//      （③ 把求值顺序从 base→idx 换成 idx→base ⇒ 下标必须无副作用才等价）
// 为什么"已知非负"是硬条件：老路径对下标 `imul $8` 之后走 **movsxd（符号扩展）**，SIB 用的却是
//   32 位写零扩展出来的 64 位索引 ⇒ 负下标两者结果不同位。只有能证明非负才逐位等价。
// 已知边界（已写进 PROGRESS）：下标 ≥ 2^28 时老路径的 `imul $8,%eax,%eax` 在 32 位内回绕、新路径按
//   64 位算 —— 那种下标早已越出任何帧内数组（越界访问），合法程序碰不到。
static bool is_local_array_var(Node *n) {
  return n && n->kind == ND_VAR && n->ty == TY_ARR && !n->is_ref && !n->is_global;
}
static bool is_local_ptr_var(Node *n) {
  return n && n->kind == ND_VAR && n->ty == TY_PTR && !n->is_ref && !n->is_global;
}

// 已知非负的下标（能证明才 true —— 宁可少优化，不多改一条字节）：
//   常量 ≥ 0 ｜ char 变量（语言语义 0..255）｜ `x & m`（m ≥ 0 ⇒ 结果恒在 [0,m]）
static bool is_nonneg_idx(Node *n) {
  if (!n) return false;
  if (n->kind == ND_NUM) return n->val >= 0;
  if (n->kind == ND_VAR) return n->ty == TY_CHAR && !n->is_ref && !n->is_global;
  if (n->kind == ND_BITAND) {
    if (n->rhs && n->rhs->kind == ND_NUM && n->rhs->val >= 0) return true;
    if (n->lhs && n->lhs->kind == ND_NUM && n->lhs->val >= 0) return true;
  }
  return false;
}

// 无副作用（读内存算无副作用；调用 / API / new / 赋值 / 自增自减一律不算）—— 档③ 换求值顺序的前置条件
static bool is_pure_expr(Node *n) {
  if (!n) return true;
  switch (n->kind) {
    case ND_NUM: case ND_DBL: case ND_STR: case ND_VAR: case ND_DEREF: return true;
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV: case ND_MOD:
    case ND_BITAND: case ND_BITOR: case ND_BITXOR: case ND_SHL: case ND_SHR:
    case ND_EQ: case ND_NE: case ND_LT: case ND_LE: case ND_GT: case ND_GE:
    case ND_LOGAND: case ND_LOGOR:
      return is_pure_expr(n->lhs) && is_pure_expr(n->rhs);
    case ND_NEG: case ND_NOT: case ND_BITNOT: case ND_I2D: case ND_D2I: case ND_ADDR:
      return is_pure_expr(n->lhs);
    default: return false;   // 调用 / API / new / 赋值 / 自增自减 / 三元：保守一律不算
  }
}

// 解 `base + idx*scale` / `base + 常量`（parse 的 `a[i]` 就是这个形态，见 parse.c postfix）
static bool split_elem_addr(Node *addr, Node **base, Node **idx, int *scale) {
  if (!addr || addr->kind != ND_ADD || !addr->lhs || !addr->rhs) return false;
  Node *l = addr->lhs, *r = addr->rhs;
  if (r->kind == ND_MUL && r->rhs && r->rhs->kind == ND_NUM) { *base = l; *idx = r->lhs; *scale = r->rhs->val; return true; }
  if (l->kind == ND_MUL && l->rhs && l->rhs->kind == ND_NUM) { *base = r; *idx = l->lhs; *scale = l->rhs->val; return true; }
  if (r->kind == ND_NUM) { *base = l; *idx = r; *scale = 1; return true; }   // `p + n`（字节差）
  return false;
}

// 元素地址链 → ElemAddr（只认①②：本地数组；其余一律 false ⇒ 照旧走老路径）
static bool make_elem_addr(Node *addr, ElemAddr *ea, Node **idx_out) {
  Node *base = NULL, *idx = NULL; int scale = 1;
  if (!split_elem_addr(addr, &base, &idx, &scale)) return false;
  if (!is_local_array_var(base)) return false;
  if (scale != 1 && scale != 2 && scale != 4 && scale != 8) return false;   // SIB 只吃这四档
  if (idx->kind == ND_NUM) {
    long long d = -(long long)base->offset + (long long)idx->val * scale;
    if (d < -0x7FFFFFFFL || d > 0x7FFFFFFFL) return false;                  // disp32 装不下 ⇒ 老路径
    ea->base_off = base->offset; ea->scale = scale; ea->has_idx = 0; ea->cidx = idx->val;
    if (idx_out) *idx_out = NULL;
    return true;
  }
  if (!is_nonneg_idx(idx)) return false;
  ea->base_off = base->offset; ea->scale = scale; ea->has_idx = 1; ea->cidx = 0;
  if (idx_out) *idx_out = idx;
  return true;
}

// 生成层入口（gen_binop 的宽地址链分支调）：命中即"地址已在 rax"，调用方直接返回
static bool try_gen_elem_addr(FuncCtx *c, Node *node) {
  ElemAddr ea; Node *idx = NULL;
  if (make_elem_addr(node, &ea, &idx)) {          // ①②本地数组
    if (ea.has_idx) gen_expr(c, idx);             // eax/rax = 下标（非负；32 位写 ⇒ 高位为 0）
    slot_elem_lea(&c->code, &ea);
    return true;
  }
  // ③ 本地指针槽 p[i]：基址在槽里（64 位）⇒ mov rcx,[槽] + lea rax,[rcx+rax*scale]
  Node *base = NULL; int scale = 1;
  if (!split_elem_addr(node, &base, &idx, &scale)) return false;
  if (!is_local_ptr_var(base)) return false;
  if (scale != 1 && scale != 2 && scale != 4 && scale != 8) return false;
  // M6 ①：常量下标折进位移（`p[2]`）—— 老路径 10 条（mov 槽→rax / imul 常量 / movsxd / add / …）
  //   ⇒ 本形态 3 条（mov rcx,[槽] + lea rax,[rcx+disp]；槽在寄存器时 `mov rcx,rS` + lea = 2 条）。
  //   逐位等价：常量下标不参与求值，只是字节位移；disp = cidx*scale（与老路径 imul+add 同一个数）。
  //   idx==0 仍走老路径：此时 disp=0、折不出收益，反而多一条 lea（且能保住"槽全在内存"函数的产物形状）。
  if (idx->kind == ND_NUM) {
    long disp = (long)idx->val * (long)scale;
    if (idx->val == 0) return false;                       // 位移 0 ⇒ 没有可折的收益
    if (disp < -2147483647L - 1L || disp > 2147483647L) return false;  // disp32 装不下 ⇒ 老路径
    slot_load_ptr_rcx64(&c->code, base->offset);           // rcx = p
    slot_lea_ptr_disp_rax(&c->code, disp);                 // rax = p + cidx*scale
    return true;
  }
  // ② 复核（M6）：**不再要求"无副作用"** —— 下标的求值只发生一次（本形态算一次、老路径也只算一次），
  //   两条路求值次数相同、结果相同；顺序从 base→idx 换成 idx→base 也不改语义：
  //   idx 写不到 base 这个局部槽（跨函数只能碰自己的帧/全局/堆；语言里没有指向外层局部槽的路径），
  //   调用类下标读到的 base 槽也没人改得动（本地局部槽只在本函数体内被写）。
  //   ⇒ 原来那条 ③ 的限制（is_pure_expr）是对"会不会多算一次"的误判，M6 复核后撤掉。
  //   **"已知非负"一条不放松**：老路径 `imul $8` 后走 movsxd（符号扩展），SIB 用的是 32 位写零扩展，
  //   负下标两者不同位（见文件头 §M5 ① 说明）。
  if (!is_nonneg_idx(idx)) return false;
  gen_expr(c, idx);                               // eax = 下标（已知非负）
  slot_load_ptr_rcx64(&c->code, base->offset);    // rcx = p（不碰 rax）
  slot_lea_ptr_idx_rax(&c->code, scale);
  return true;
}

// 元素目标 `a[k]`（本地数组档）→ ElemAddr
static bool elem_of(Node *n, ElemAddr *ea, Node **idx) {
  if (!n || n->kind != ND_DEREF || n->ty != TY_INT) return false;
  return n->lhs && make_elem_addr(n->lhs, ea, idx);
}

// 结构等价：只认无副作用的 int 表达式（常量/变量/位与/加减乘）——判 `a[k] op= …` 两侧是不是同一个元素
static bool same_int_expr(Node *a, Node *b) {
  if (!a || !b) return a == b;
  if (a->kind != b->kind) return false;
  switch (a->kind) {
    case ND_NUM: return a->val == b->val;
    case ND_VAR: return a->offset == b->offset && a->ty == b->ty
                     && a->is_ref == b->is_ref && a->is_global == b->is_global;
    case ND_BITAND: case ND_ADD: case ND_SUB: case ND_MUL:
      return same_int_expr(a->lhs, b->lhs) && same_int_expr(a->rhs, b->rhs);
    default: return false;
  }
}
static bool same_elem(Node *x, Node *y) {
  ElemAddr ex, ey; Node *ix = NULL, *iy = NULL;
  if (!elem_of(x, &ex, &ix) || !elem_of(y, &ey, &iy)) return false;
  if (ex.base_off != ey.base_off || ex.scale != ey.scale || ex.has_idx != ey.has_idx) return false;
  if (!ex.has_idx) return ex.cidx == ey.cidx;
  return same_int_expr(ix, iy);
}

// ===== v1.4.24（M4 补一档）：表达式语句里的"自反运算"就地融合 =====
// 病（实测 bench k1）：寄存器化之后 `x = x + j` 的老序列是
//   `mov ebx→eax / mov r12d→ecx / add eax,ecx / mov eax→ebx` —— 五次搬运换一次加法，
//   把 M4 的收益吃掉大半。这类"自反运算 + 值没人用"的语句可以就地算：`add r12d,ebx` 一条顶五条。
// 安全条件（三条都要满足，缺一不融合）：
//   ① 只在 **ND_EXPR_STMT**（表达式语句）里调 —— 表达式值没人要；
//   ② 目标槽当前必须是**寄存器槽**（`slotmap_kind_of == SLOTK_REG`）⇒ 融合路径只改到寄存器化的函数，
//      其余函数的产物**逐字节不变**；
//   ③ 参与运算的另一侧必须是"读一个 32 位 int 变量"或"常量字面量"（都无副作用，求值顺序无所谓）。
static bool same_int_var(Node *a, Node *b) {
  return a && b && a->kind == ND_VAR && b->kind == ND_VAR
      && !a->is_ref && !b->is_ref && !a->is_global && !b->is_global
      && a->ty == TY_INT && b->ty == TY_INT && a->offset == b->offset;
}
static bool is_reg_int_var(Node *n) {
  return n && n->kind == ND_VAR && !n->is_ref && !n->is_global && n->ty == TY_INT
      && slotmap_kind_of(n->offset) == SLOTK_REG;
}

// ===== v1.4.26（M5 ①）：元素就地运算（`a[k] = a[k] + i` / `a[k] += i` / `a[k]++`）=====
// 只在**表达式语句**里做（值没人要）＋ 目标能一条寻址（本地数组档）＋ 索引无副作用
//   （就地形态只算一次下标；老路径"读"和"写"各算一遍 ⇒ 下标有副作用时两者不等价）。
// 收益来源：老序列"算地址 → push 保护 → 算 → scratch 槽往返 → 再算一遍地址 → 写"，
//   就地形态是"算一次索引 → 一条 add/and/inc 直接作用在内存元素上"（bench k2 的热点语句）。
static bool try_fused_self_elem(FuncCtx *c, Node *st, Node *t, int incdec) {
  ElemAddr ea; Node *idx = NULL;
  if (!elem_of(t, &ea, &idx)) return false;
  // ⚠️ M6 复核结论：**这里的 is_pure_expr 必须留着**（与 try_gen_elem_addr 那条 ③ 前置不同族，别一起撤）——
  //   就地形态只算一次下标，而老路径"读元素 + 写元素"**各算一遍**（a[k]=a[k]+i 里 k 求值两次）⇒
  //   下标有副作用时两者结果不同（`a[i++] = a[i++] + 1`）。而取基址那条（p[i]）两条路都只算一次，所以能撤。
  //   判据口径：**先问"两条路各算几次"，答案不同才谈副作用；次数相同就不该拿副作用当门槛。**
  if (ea.has_idx && !is_pure_expr(idx)) return false;
  if (incdec != 0) {                                     // a[k]++ / a[k]--
    if (ea.has_idx) gen_expr(c, idx);
    if (incdec > 0) slot_elem_inc(&c->code, &ea);
    else            slot_elem_dec(&c->code, &ea);
    return true;
  }
  Node *r = st->rhs;
  if (!r) return false;
  // a[k] += rhs / a[k] -= rhs
  if (st->kind == ND_ADD_ASSIGN || st->kind == ND_SUB_ASSIGN) {
    int sign = (st->kind == ND_ADD_ASSIGN) ? 1 : -1;
    if (r->kind == ND_NUM) {
      if (ea.has_idx) gen_expr(c, idx);
      slot_elem_add_imm(&c->code, &ea, sign * r->val);
      return true;
    }
    if (sign == 1 && is_reg_int_var(r)) {
      if (ea.has_idx) gen_expr(c, idx);
      slot_elem_add_slot(&c->code, &ea, r->offset);
      return true;
    }
    return false;
  }
  if (st->kind != ND_ASSIGN) return false;
  // a[k] = a[k] ± 常量 / a[k] = a[k] + 寄存器槽
  if ((r->kind == ND_ADD || r->kind == ND_SUB) && same_elem(t, r->lhs)) {
    int sign = (r->kind == ND_ADD) ? 1 : -1;
    if (r->rhs && r->rhs->kind == ND_NUM) {
      if (ea.has_idx) gen_expr(c, idx);
      slot_elem_add_imm(&c->code, &ea, sign * r->rhs->val);
      return true;
    }
    if (sign == 1 && is_reg_int_var(r->rhs)) {
      if (ea.has_idx) gen_expr(c, idx);
      slot_elem_add_slot(&c->code, &ea, r->rhs->offset);
      return true;
    }
  }
  // a[k] = (a[k] + j) & m —— bench k2 的热点语句（老序列 ~20 条 → 2 条 + 索引求值）
  if (r->kind == ND_BITAND && r->rhs && r->rhs->kind == ND_NUM && r->lhs
      && r->lhs->kind == ND_ADD && same_elem(t, r->lhs->lhs) && is_reg_int_var(r->lhs->rhs)) {
    if (ea.has_idx) gen_expr(c, idx);
    slot_elem_add_slot(&c->code, &ea, r->lhs->rhs->offset);
    slot_elem_and_imm(&c->code, &ea, r->rhs->val);
    return true;
  }
  return false;
}

static bool try_fused_self_stmt(FuncCtx *c, Node *st) {
  if (!st) return false;
  Node *t = NULL;
  int incdec = 0;   // 1 = ++，-1 = --
  switch (st->kind) {
    case ND_ASSIGN:      t = st->lhs; break;
    case ND_ADD_ASSIGN:  t = st->lhs; break;   // x += rhs
    case ND_SUB_ASSIGN:  t = st->lhs; break;   // x -= rhs
    case ND_PRE_INC: case ND_POST_INC: t = st->lhs; incdec = 1;  break;
    case ND_PRE_DEC: case ND_POST_DEC: t = st->lhs; incdec = -1; break;
    default: return false;
  }
  // M5 ①：目标也可以是"本地数组元素"（`a[k] = a[k] + i` / `a[k]++` / `a[k] += j`）
  if (t && t->kind == ND_DEREF) return try_fused_self_elem(c, st, t, incdec);
  if (!t || t->kind != ND_VAR || t->is_ref || t->is_global || t->ty != TY_INT) return false;
  if (slotmap_kind_of(t->offset) != SLOTK_REG) return false;   // 条件②
  if (incdec != 0) {   // x++ / x-- / ++x / --x 作语句：一条 inc/dec 顶"读 + 改"
    if (incdec > 0) slot_self_add_imm(&c->code, t->offset, 1);
    else            slot_self_sub_imm(&c->code, t->offset, 1);
    return true;
  }
  Node *r = st->rhs;
  if (!r) return false;
  if (st->kind == ND_ADD_ASSIGN || st->kind == ND_SUB_ASSIGN) {   // x op= rhs（自反形态天然成立）
    if (r->kind == ND_NUM) {
      if (st->kind == ND_ADD_ASSIGN) slot_self_add_imm(&c->code, t->offset, r->val);
      else                           slot_self_sub_imm(&c->code, t->offset, r->val);
      return true;
    }
    if (is_reg_int_var(r)) { slot_self_add_slot(&c->code, t->offset, r->offset); return true; }
    // M5 ①：x += a[k]（x 是寄存器槽、a[k] 是本地数组元素）→ `add rX, [元素]` 一条
    if (st->kind == ND_ADD_ASSIGN) {
      ElemAddr eax_; Node *ix = NULL;
      if (elem_of(r, &eax_, &ix) && (!eax_.has_idx || is_pure_expr(ix))) {
        if (eax_.has_idx) gen_expr(c, ix);
        slot_elem_add_to_reg(&c->code, &eax_, t->offset);
        return true;
      }
    }
    return false;
  }
  // P1：x = x ± k
  if ((r->kind == ND_ADD || r->kind == ND_SUB) && same_int_var(t, r->lhs)
      && r->rhs && r->rhs->kind == ND_NUM) {
    if (r->kind == ND_ADD) slot_self_add_imm(&c->code, t->offset, r->rhs->val);
    else                   slot_self_sub_imm(&c->code, t->offset, r->rhs->val);
    return true;
  }
  // P2：x = x + j（j 是另一个**寄存器槽**）
  if (r->kind == ND_ADD && same_int_var(t, r->lhs) && is_reg_int_var(r->rhs)) {
    slot_self_add_slot(&c->code, t->offset, r->rhs->offset);
    return true;
  }
  // P3：x = (x + j) & m —— bench k1 的热点语句（老序列 5 条 → 2 条）
  if (r->kind == ND_BITAND && r->rhs && r->rhs->kind == ND_NUM && r->lhs
      && r->lhs->kind == ND_ADD && same_int_var(t, r->lhs->lhs) && is_reg_int_var(r->lhs->rhs)) {
    slot_self_add_slot(&c->code, t->offset, r->lhs->rhs->offset);
    slot_self_and_imm(&c->code, t->offset, r->rhs->val);
    return true;
  }
  // P4（M5 ①）：x = x + a[k] —— bench k2 的另一半（累加器吃数组元素）→ `add rX, [元素]` 一条
  if (r->kind == ND_ADD && same_int_var(t, r->lhs)) {
    ElemAddr es; Node *ix = NULL;
    if (elem_of(r->rhs, &es, &ix) && (!es.has_idx || is_pure_expr(ix))) {
      if (es.has_idx) gen_expr(c, ix);
      slot_elem_add_to_reg(&c->code, &es, t->offset);
      return true;
    }
  }
  return false;
}

// 带源码定位的报错（ND_ASSIGN 的 loc v1.0.13 起由 parse 记录；拿不到就退化成无定位报错）
static void error_at_node(Node *n, const char *msg) {
  if (n && n->loc) error_at(n->loc, "%s", (char *)msg);
  else error((char *)msg);
}

// v1.4.25（`-strict`）：要带数字的定位报错（形参序号/下标这类）—— error_at_node 只收固定串，
//   这里先 vsnprintf 成一条再走同一个出口（保持"报错只有一条出口"）。
static void error_at_nodef(Node *n, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  error_at_node(n, buf);
}

// T1 ④：指针目标的值门槛
static void check_ptr_target(Node *st, Node *rhs) {
  if (is_addr_expr(rhs)) return;                                     // 64 位算出来的地址（含地址链）
  if (rhs->kind == ND_NUM) return;                                   // 显式常量（0/null 等）
  if (rhs->kind == ND_APICALL) return;                               // API 返回值全宽（句柄兼容路径）
  if (rhs->kind == ND_VAR && rhs->ty == TY_INT && slot_marked(rhs->offset)) return;  // T1 ②：装地址的 int
  if (rhs->kind == ND_ASSIGN) { check_ptr_target(st, rhs->rhs); return; }            // 赋值表达式：看被赋的值
  if ((rhs->kind == ND_PRE_INC || rhs->kind == ND_PRE_DEC || rhs->kind == ND_POST_INC || rhs->kind == ND_POST_DEC) &&
      rhs->lhs && (rhs->lhs->ty == TY_PTR || is_addr_expr(rhs->lhs)))
    return;                                                          // 指针 ++/--（值是 64 位地址，A1 语义）
  // 到这里还不放行的，只有两类「拿不准」：① 32 位算出来的地址（int 变量参与算术）；② 32 位值的搬运
  if (is_addr_value(rhs))
    error_at_node(st, "这个地址是 int 变量参与算术/中转算出来的（按 32 位算，高半已截断）"
                      "——请把地址先放进 int * 变量再做指针算术（例：int *t = s; t + 8）");
  error_at_node(st, "指针目标只能接「地址表达式」（&x / 字符串 / 指针变量 / 数组名 / new / 指针返回函数 / API 返回值 / 地址链）、"
                    "显式常量、或一个装过地址的 int 变量——这里的值只有 32 位，当指针用会指向错地方"
                    "（int 形参、int 返回值、4 字节的 int 字段/元素里都装不下地址，请把类型声明成 int * 或 ptr）");
}

// 二元算术（结果 eax；地址类走 64 位 add/sub——v0.9）
// ===== v1.4.9② 窥孔：右操作数是「普通局部 int 变量」的读 → 直接载入 ecx，不过栈 =====
// 病（靶子 = bench4 / regbench 的循环条件 `while (i < n)`，n 是**变量**不是常量）：
//   旧：push rax / mov eax,[rbp-n] / mov ecx,eax / pop rax —— 四条只为把 rhs 放进 ecx；
//   新：mov ecx,[rbp-n]（wide 时 movsxd rcx,dword [rbp-n]）—— 一条，且**完全不碰 rax**（lhs 天然保住）。
// 限制条件逐条都有理由，别放宽：
//   · 只认「普通局部 int」：全局读走 rip-relative 的 64 位约定、char 是 movzx 字节读、double 走 xmm0、
//     数组/结构体名是首地址、is_ref 要先 64 位读地址再解引用、T1 标记槽是 8 字节读 ——
//     这些宽度/语义各不相同，在这里再复刻一份就是「同一条规则两处实现」，迟早分叉。
//   · rhs 必须是无副作用的变量读（因此求值顺序无关，可以安全地"先读进 ecx"）。
static bool try_load_var_to_ecx(FuncCtx *c, Node *n, bool wide) {
  Buf *b = &c->code;
  if (!n || n->kind != ND_VAR) return false;
  if (n->is_global || n->is_ref) return false;
  if (n->ty != TY_INT) return false;
  if (slot_marked(n->offset)) return false;
  if (wide) slot_load_rcx64(b, n->offset);   // movsxd rcx, dword [槽]
  else      slot_load_ecx(b, n->offset);     // mov ecx, [rbp-off]
  return true;
}

// v1.4.26（M5 ③）：上面那套「什么才算普通局部 int 变量读」的**唯一出处**（返回槽偏移，不是则 -1）。
//   比较就地化（`cmp rS,[rbp-n]` 一条顶三条）也要用同一套条件 —— 两处各判一次迟早分叉，
//   而 char/double/引用/全局/T1 装地址槽的宽度语义各不相同（漏判 = 编译过、静默错值）。
//   槽偏移一律为正（rbp-off），故 -1 当"没有"是安全的。
static int simple_int_var_off(Node *n) {
  if (!n || n->kind != ND_VAR) return -1;
  if (n->is_global || n->is_ref) return -1;
  if (n->ty != TY_INT) return -1;
  if (slot_marked(n->offset)) return -1;
  if (n->offset <= 0) return -1;
  return n->offset;
}

static void gen_binop(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  // ===== v1.7.0：64 位通道的两个来源要**分开判**（合并判会改掉既有 int 程序的字节）=====
  //   ① 地址类：只有 ADD/SUB 才点火（决策 17/40 的老口径，一行未改）
  //   ② int_64：**所有**二元算术/位运算/移位都点火（它的值域就是 64 位）
  bool addr_wide = (node->kind == ND_ADD || node->kind == ND_SUB) &&
                   (is_addr_expr(node->lhs) || is_addr_expr(node->rhs));
  bool i64_wide = expr_is_i64(node->lhs) || expr_is_i64(node->rhs);
  bool wide = addr_wide || i64_wide;
  // ===== v1.4.26（M5 ①）：下标地址链融合 =====
  //   `a[i]` 被 parse 展开成 *(基址 + i*8)；本地数组的基址是**编译期常量**（rbp-off）
  //   ⇒ 一条 SIB 寻址顶老路径的 8 条（lea+push+算下标+imul+movsxd+pop+add）。详见 try_gen_elem_addr。
  if (wide && node->kind == ND_ADD && try_gen_elem_addr(c, node)) return;
  // ===== v1.4.9③ 窥孔：右操作数是**常量字面量** → 立即数形态 =====
  // 旧：mov eax,3 / mov ecx,eax / push rax / pop rax / add eax,ecx（常量每轮重新物化 + 过一次栈）
  // 新：add eax,3 —— 一条。push/pop **整对**消失，rsp 记账天然不变。
  // 只收 ADD/SUB/MUL/AND/OR/XOR：DIV/MOD 要 ecx 当除数、移位要 cl，都不能塞进立即数形态（另算一档）；
  // 立即数的位宽与符号扩展规则见 emit_alu_imm 上方注释（AND/OR/XOR 不吃负数 imm8）。
  if (node->rhs && node->rhs->kind == ND_NUM &&
      (node->kind == ND_ADD || node->kind == ND_SUB || node->kind == ND_MUL ||
       node->kind == ND_BITAND || node->kind == ND_BITOR || node->kind == ND_BITXOR)) {
    int v = node->rhs->val;
    gen_expr(c, node->lhs);
    if (wide && !is64_value(node->lhs)) emit_movsxd_rax_eax(b);
    switch (node->kind) {
      case ND_ADD:    emit_alu_imm(b, 0, wide, v); break;
      case ND_SUB:    emit_alu_imm(b, 5, wide, v); break;
      case ND_MUL:    emit_imul_imm(b, wide, v);  break;   // v1.7.0：int_64 常量要 48 前缀
      case ND_BITAND: emit_alu_imm(b, 4, wide, v); break;  // v1.7.0：int_64 位运算同理
      case ND_BITOR:  emit_alu_imm(b, 1, wide, v); break;
      default:        emit_alu_imm(b, 6, wide, v); break;  // ND_BITXOR
    }
    return;
  }
  gen_expr(c, node->lhs);
  // v1.0.12（评审清单【1】）：地址链的「左」侧同样要符号扩展——原实现只认 rhs，
  // `i + p`（负 int 在左、地址在右）把 -8 零扩展成 0xFFFFFFF8（约 42 亿）→ 野指针 0xC0000005。
  // 规则统一：wide 时「非 64 位值的一侧」必须 movsxd（地址/int_64 一侧 64 位已完整）。
  // v1.7.0：判据从 is_addr_expr 改成 is64_value —— int_64 操作数不该被 movsxd（§2.4 的坑 #1）
  if (wide && !is64_value(node->lhs)) emit_movsxd_rax_eax(b);
  // v1.4.9② 窥孔：rhs 是普通局部 int 变量 → 直接读进 ecx（整对 push/pop 与 eax 中转一起消失）
  if (!try_load_var_to_ecx(c, node->rhs, wide)) {
    emit_push_rax(b);
    gen_expr(c, node->rhs);
    if (wide) {
      // v1.0.6.2 盲区审计 A7：地址链 rhs 若是 int（下标×宽 / p±n 的 n）须符号扩展 movsxd——
      // 原恒 mov rcx,rax：32 位乘/负偏移零扩展成 0xFFFFFFF8 巨大正数 → p[-1]/p-n 解引用崩
      // （正偏移侥幸对，负偏移必现；栈地址 <4GB 时正偏移掩盖了路径本身 32 位残留问题）
      // v1.7.0：int_64 的 rhs 也是 64 位完整值 ⇒ 整搬（判据同 is64_value）
      if (is64_value(node->rhs)) emit_mov_rcx_rax(b);   // rhs 真地址 / int_64 值（64 位完整）
      else emit_movsxd_rcx_eax(b);                      // rhs int 偏移 → 符号扩展
    } else emit_mov_ecx_eax(b);        // ecx = rhs
    emit_pop_rax(b);                 // rax = lhs
  }
  switch (node->kind) {
    case ND_ADD: if (wide) emit_add64(b); else emit_add(b); break;
    case ND_SUB: if (wide) emit_sub64(b); else emit_sub(b); break;
    // v1.7.0：int_64 的乘/除/取模/位运算/移位全部走 64 位档（§2.4 的 P0 清单）
    case ND_MUL: if (i64_wide) emit_imul64(b); else emit_imul(b); break;
    case ND_DIV: if (i64_wide) { emit_cqo(b); emit_idiv64(b); }
                 else { emit_cdq(b); emit_idiv(b); } break;
    case ND_MOD: if (i64_wide) { emit_cqo(b); emit_idiv64(b); emit_mov_rax_rdx64(b); }
                 else { emit_cdq(b); emit_idiv(b); emit_mov_eax_edx(b); } break;
    // v0.7.2 位运算（eax op ecx；移位量在 cl）
    case ND_BITAND: if (i64_wide) emit_and64(b); else emit_and(b); break;
    case ND_BITOR:  if (i64_wide) emit_or64(b);  else emit_or(b); break;
    case ND_BITXOR: if (i64_wide) emit_xor64(b); else emit_xor(b); break;
    case ND_SHL:    if (i64_wide) emit_shl64(b); else emit_shl(b); break;
    case ND_SHR:    if (i64_wide) emit_sar64(b); else emit_sar(b); break;
    default: break;
  }
}

// ===== v1.1.0 浮点（阶段1）：SSE 发射器 + 求值流 =====
// 全程用 xmm0 当「double 累加器」（对应整数路径的 eax）；跨二元运算用 rax 中转压栈暂存
// （movq xmm0,rax / movq rax,xmm0），保持 gen_binop 那套「lhs → push → rhs」求值顺序不变。
static void emit_movq_rax_xmm0(Buf *b)  { const uint8_t x[] = {0x66, 0x48, 0x0F, 0x7E, 0xC0}; buf_bytes(b, x, 5); }
static void emit_movq_xmm0_rax(Buf *b)  { const uint8_t x[] = {0x66, 0x48, 0x0F, 0x6E, 0xC0}; buf_bytes(b, x, 5); }
static void emit_movq_xmm1_rax(Buf *b)  { const uint8_t x[] = {0x66, 0x48, 0x0F, 0x6E, 0xC8}; buf_bytes(b, x, 5); }
static void emit_movq_xmm2_rax(Buf *b)  { const uint8_t x[] = {0x66, 0x48, 0x0F, 0x6E, 0xD0}; buf_bytes(b, x, 5); }
static void emit_movq_xmm3_rax(Buf *b)  { const uint8_t x[] = {0x66, 0x48, 0x0F, 0x6E, 0xD8}; buf_bytes(b, x, 5); }
static void emit_cvtsi2sd_xmm0_eax(Buf *b) { const uint8_t x[] = {0xF2, 0x0F, 0x2A, 0xC0}; buf_bytes(b, x, 4); }
static void emit_cvttsd2si_eax_xmm0(Buf *b) { const uint8_t x[] = {0xF2, 0x0F, 0x2C, 0xC0}; buf_bytes(b, x, 4); }
static void emit_sse_binop(Buf *b, char op) {
  switch (op) {
    case '+': { const uint8_t x[] = {0xF2, 0x0F, 0x58, 0xC1}; buf_bytes(b, x, 4); return; } // addsd xmm0,xmm1
    case '-': { const uint8_t x[] = {0xF2, 0x0F, 0x5C, 0xC1}; buf_bytes(b, x, 4); return; } // subsd
    case '*': { const uint8_t x[] = {0xF2, 0x0F, 0x59, 0xC1}; buf_bytes(b, x, 4); return; } // mulsd
    case '/': { const uint8_t x[] = {0xF2, 0x0F, 0x5E, 0xC1}; buf_bytes(b, x, 4); return; } // divsd
  }
}
// double 取负：翻符号位（xorpd xmm0,xmm1；xmm1 载的是 -0.0 = 0x8000000000000000）
static void emit_xorpd_xmm0_xmm1(Buf *b) { const uint8_t x[] = {0x66, 0x0F, 0x57, 0xC1}; buf_bytes(b, x, 4); }
// ===== v1.2.4：double 左值/间接目标（double 数组元素、double 结构体字段、d += 1.0）=====
static void emit_movapd_xmm1_xmm0(Buf *b) { const uint8_t x[] = {0x66, 0x0F, 0x28, 0xC8}; buf_bytes(b, x, 4); } // movapd xmm1,xmm0
static void emit_load_dbl_at_rdx(Buf *b)   { const uint8_t x[] = {0xF2, 0x0F, 0x10, 0x02}; buf_bytes(b, x, 4); } // movsd xmm0,[rdx]
static void emit_store_dbl_at_rdx(Buf *b)  { const uint8_t x[] = {0xF2, 0x0F, 0x11, 0x02}; buf_bytes(b, x, 4); } // movsd [rdx],xmm0
// double 比较（无符号语义条件码：A=above B=below AE=above-or-equal BE=below-or-equal；
// 先配 p 变体处理 NaN → x==x 为假，与 C 一致）
static void emit_ucomisd_xmm0_xmm1(Buf *b) { const uint8_t x[] = {0x66, 0x0F, 0x2E, 0xC1}; buf_bytes(b, x, 4); }
static void emit_setnp_al(Buf *b)  { const uint8_t x[] = {0x0F, 0x9B, 0xC0}; buf_bytes(b, x, 3); }
static void emit_setp_al(Buf *b)   { const uint8_t x[] = {0x0F, 0x9A, 0xC0}; buf_bytes(b, x, 3); }  // v1.2.3：有序=0 / 无序(NaN)=1
static void emit_seta_al(Buf *b)   { const uint8_t x[] = {0x0F, 0x97, 0xC0}; buf_bytes(b, x, 3); }
static void emit_setae_al(Buf *b)  { const uint8_t x[] = {0x0F, 0x93, 0xC0}; buf_bytes(b, x, 3); }
static void emit_setb_al(Buf *b)   { const uint8_t x[] = {0x0F, 0x92, 0xC0}; buf_bytes(b, x, 3); }
static void emit_setbe_al(Buf *b)  { const uint8_t x[] = {0x0F, 0x96, 0xC0}; buf_bytes(b, x, 3); }
static void emit_sete_al(Buf *b)   { const uint8_t x[] = {0x0F, 0x94, 0xC0}; buf_bytes(b, x, 3); }
static void emit_setne_al(Buf *b)  { const uint8_t x[] = {0x0F, 0x95, 0xC0}; buf_bytes(b, x, 3); }
static void emit_movzx_eax_al_now(Buf *b) { const uint8_t x[] = {0x0F, 0xB6, 0xC0}; buf_bytes(b, x, 3); }

// double 二元运算：lhs → 暂存 → rhs → xmm1 → lhs 回 xmm0 → 运算（顺序与 gen_binop 一致）
static void gen_dbl_binop(FuncCtx *c, Node *node, char op) {
  Buf *b = &c->code;
  gen_expr(c, node->lhs);
  emit_movq_rax_xmm0(b);
  emit_push_rax(b);
  gen_expr(c, node->rhs);
  emit_movq_rax_xmm0(b);
  emit_movq_xmm1_rax(b);          // xmm1 = rhs
  emit_pop_rax(b);
  emit_movq_xmm0_rax(b);          // xmm0 = lhs
  emit_sse_binop(b, op);
}

// v1.0.11：a ^^ b —— int 幂（快速幂：平方-乘，O(log b)），决策 49
// 语义：0^^0 = 1；负指数 = 0（整型无分数幂，统一取 0）；溢出按 32 位回绕（imul 自然回绕）
// 寄存器：eax=base、ecx=exp、edx=acc —— 全 caller-saved，循环内无 call（决策 2 纪律）
// 与 gen_binop 同序求值：lhs → push → rhs → ecx → pop rax（求值顺序一致，不引入新约定）
static void gen_pow(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  gen_expr(c, node->lhs);            // eax = base
  emit_push_rax(b);
  gen_expr(c, node->rhs);            // eax = exp
  emit_mov_ecx_eax(b);               // ecx = exp
  emit_pop_rax(b);                   // eax = base
  int neg = new_label(c), loop = new_label(c), skip = new_label(c);
  int endloop = new_label(c), done = new_label(c);
  emit_test_ecx(b);                  // test ecx,ecx
  emit_jcc_label(c, 0x88, neg);      // js  → 负指数（结果 0）
  emit_mov_edx_imm(b, 1);            // edx = 1（acc）
  emit_label(c, loop);
  emit_test_ecx(b);                  // test ecx,ecx
  emit_jcc_label(c, 0x8E, endloop);  // jle → exp <= 0 结束
  emit_test_cl_1(b);                 // test cl,1
  emit_jcc_label(c, 0x84, skip);     // je  → 该位为 0，跳过累乘
  emit_imul_edx_eax(b);              // acc *= base
  emit_label(c, skip);
  emit_imul_eax_eax(b);              // base *= base
  emit_sar_ecx_1(b);                 // exp >>= 1
  emit_jmp_label(c, loop);
  emit_label(c, endloop);
  emit_mov_eax_edx(b);               // eax = acc
  emit_jmp_label(c, done);
  emit_label(c, neg);
  emit_mov_eax_imm(b, 0);            // 负指数 → 0
  emit_label(c, done);
}

// 比较（结果 0/1）：cmp → setcc al → movzx；地址类操作数走 64 位 cmp（v0.9）
// v1.1.0 double 比较：求值顺序同 gen_binop（lhs → 暂存 → rhs → xmm1 → lhs 回 xmm0）→ ucomisd
//   → setcc 结果 0/1 进 eax。两个坑都实测过：
//   ① 必须用「无符号」条件码（B/BE/A/AE）：ucomisd 只置 CF/ZF，用 setl/setg 会把 `1.0 < 2.0` 判反；
//   ② == / != 要处理 NaN 无序（PF=1）：x==x 应为假、x!=x 应为真 → 用 setnp 与 setcc 相与。
// ⚠️ v1.2.3 修的真 bug（`!=` 恒等于 `==`，2026-09-13 写浮点打印时撞出，**旧编译器同样错**）：
//   原 `!=` 分支 = ecx:setnp(有序) + al:setne → `xor eax,1` → `and` —— 算出来是「有序**且 ZF**」
//   ＝ **等于**！后果：double 的 `!=` 与 `==` 同义（实测 `1.5 != 1.5` 为真、`1.5 != 2.5` 为假），
//   属「编译过、静默错值」家族，且 659 项回归里没有一条 double `!=` 反例（缺覆盖）。
//   正确语义：`!=` = **无序(NaN) 或 不相等**（IEEE）；`<` / `<=` 同理要 AND 有序（无序时 CF=1，
//   会把 NaN 判成"小于"）；`>` / `>=` 用 seta/setae 天然正确（无序时 CF=1 → 结果 0）。
static void gen_dbl_cmp(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  gen_expr(c, node->lhs);
  emit_movq_rax_xmm0(b);
  emit_push_rax(b);
  gen_expr(c, node->rhs);
  emit_movq_rax_xmm0(b);
  emit_movq_xmm1_rax(b);          // xmm1 = rhs
  emit_pop_rax(b);
  emit_movq_xmm0_rax(b);          // xmm0 = lhs
  emit_ucomisd_xmm0_xmm1(b);
  if (node->kind == ND_EQ || node->kind == ND_NE) {
    const uint8_t movzx_ecx_al[] = {0x0F, 0xB6, 0xC8};   // movzx ecx,al（不动标志位）
    const uint8_t and_eax_ecx[] = {0x21, 0xC8};          // and eax,ecx
    const uint8_t or_eax_ecx[]  = {0x09, 0xC8};          // or  eax,ecx
    if (node->kind == ND_EQ) {
      emit_setnp_al(b);                      // ecx = 有序（1）/ 无序（0）
      buf_bytes(b, movzx_ecx_al, 3);
      emit_sete_al(b);                       // al = ZF（相等）
      buf_bytes(b, and_eax_ecx, 2);          // 有序 && 相等 = `==`（NaN → 假 ✓）
    } else {
      emit_setp_al(b);                       // ecx = 无序（NaN = 1）/ 有序（0）
      buf_bytes(b, movzx_ecx_al, 3);
      emit_setne_al(b);                      // al = ¬ZF（不相等）
      buf_bytes(b, or_eax_ecx, 2);           // 无序 || 不相等 = `!=`（NaN → 真 ✓，相等 → 假 ✓）
    }
    emit_movzx_eax_al(b);
    return;
  }
  switch (node->kind) {
    case ND_LT: emit_setb_al(b);  break;    // below
    case ND_LE: emit_setbe_al(b); break;    // below-or-equal
    case ND_GT: emit_seta_al(b);  break;    // above
    case ND_GE: emit_setae_al(b); break;    // above-or-equal
    default: break;
  }
  // v1.2.3：`<` / `<=` 的 NaN 修正——ucomisd 无序时 CF=1，setb/setbe 会把 NaN 判成"小于"；
  //   IEEE 规定 NaN 参与的大小比较全为假 → 谓词 AND 有序标志（谓词先存 ecx，再用 setnp 取有序）。
  if (node->kind == ND_LT || node->kind == ND_LE) {
    const uint8_t movzx_ecx_al[] = {0x0F, 0xB6, 0xC8};
    const uint8_t and_eax_ecx[] = {0x21, 0xC8};
    buf_bytes(b, movzx_ecx_al, 3);           // ecx = 谓词（setb/setbe 的结果）
    emit_setnp_al(b);                        // al = 有序（1）/ 无序（0）
    buf_bytes(b, and_eax_ecx, 2);            // 谓词 && 有序
  }
  emit_movzx_eax_al(b);
}

// double 一元负号：翻符号位（xmm0 ^= -0.0）。rax 做中转，不压栈（此处无跨调用，rsp 不受影响）
static void gen_dbl_neg(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  gen_expr(c, node->lhs);                 // xmm0 = 操作数
  emit_movq_rax_xmm0(b);                  // rax  = 位型（中转）
  size_t nr = note_dblref(c, -0.0);       // 先登记（可能 realloc）→ 再用下标记位置
  buf_bytes(b, (const uint8_t[]){0xF2, 0x0F, 0x10, 0x0D}, 4);   // movsd xmm1,[rip+disp32]（-0.0）
  note_dbluse(c, nr, c->code.len);
  buf_u32(b, 0);
  emit_movq_xmm0_rax(b);                  // xmm0 = 操作数
  emit_xorpd_xmm0_xmm1(b);                // 翻符号位
}

// v1.4.9：比较的「求值到标志位为止」这一段（不物化 0/1）—— gen_cmp 与 try_gen_cmp_branch 共用。
// 共用的意义：保证「作值的比较」与「作条件的比较」在取值/宽度/立即数路径上**逐字节一致**，
// 塌缩只发生在结尾（setcc+movzx ↔ 取反 jcc），不会悄悄改掉宽度或符号扩展规则。
static void gen_cmp_flags(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  // v1.7.0：判据从 is_addr_expr 改成 is64_value —— int_64 的比较必须 64 位（谓词仍是有符号 setl/setg）
  bool wide = is64_value(node->lhs) || is64_value(node->rhs);
  // ===== v1.4.26（M5 ③）：比较就地化 =====
  // 病（三个基准的循环条件都是它）：`while (i < n)` 老路 `mov i→eax / mov n→ecx / cmp eax,ecx`
  //   —— 三条里前两条纯搬运；i/n 都进寄存器后（M4/②）最省的是 `cmp [rbp-n], rS` **一条**。
  // 只在**非地址类**（32 位 int 语义）且左侧是"普通局部 int 变量读"时开：
  //   · 两侧性质判定走 simple_int_var_off（与 try_load_var_to_ecx 同一套条件，不另起一份）
  //   · 左侧不是普通槽（常量 / 表达式 / 地址类）⇒ 一律退老路径，别在这里做半吊子重排
  //   · flags 语义必须仍是 `lhs - rhs`（编码方向见 slotmap.c 的 slot_cmp_slots）
  if (!wide) {
    int loff = simple_int_var_off(node->lhs);
    if (loff >= 0) {
      if (node->rhs && node->rhs->kind == ND_NUM) {
        if (slot_cmp_slot_imm(b, loff, node->rhs->val)) return;      // cmp [槽],imm（或 cmp $imm,rS）
      } else {
        int roff = simple_int_var_off(node->rhs);
        if (roff >= 0 && slot_cmp_slots(b, loff, roff)) return;      // 槽 vs 槽（四种位置组合）
      }
    }
  }
  gen_expr(c, node->lhs);
  // v1.0.12（评审清单【1】同族）：64 位比较两侧都要按 64 位语义取值——左侧非地址类（int）
  // 须 movsxd；否则 `i < &a[0]`（i = -1）把 0xFFFFFFFF 当正整数与栈地址比 → 结果反了。
  if (wide && !is64_value(node->lhs)) emit_movsxd_rax_eax(b);
  // v1.4.9③ 窥孔：右操作数是常量字面量 → 直接立即数比较（省掉 push/pop 与 mov ecx,eax）
  if (node->rhs && node->rhs->kind == ND_NUM) {
    emit_alu_imm(b, 7, wide, node->rhs->val);
    return;
  }
  // v1.4.9② 窥孔：右操作数是普通局部 int 变量 → 直接读进 ecx（整对 push/pop 一起消失）
  if (try_load_var_to_ecx(c, node->rhs, wide)) {
    if (wide) emit_cmp64(b);
    else emit_cmp(b);
    return;
  }
  emit_push_rax(b);
  gen_expr(c, node->rhs);
  // 右侧同理：地址类 → mov rcx,rax（64 位完整）；int → movsxd rcx,eax（原恒 mov rcx,rax
  // 零扩展，`p == -1`/负 int 参与 64 位比较全错）
  if (!wide) emit_mov_ecx_eax(b);                     // 非地址比较照旧走 32 位
  else if (is64_value(node->rhs)) emit_mov_rcx_rax(b);   // v1.7.0：地址 / int_64 都整搬
  else emit_movsxd_rcx_eax(b);
  emit_pop_rax(b);
  if (wide) emit_cmp64(b);
  else emit_cmp(b);
}

// 比较谓词 → setcc 操作码（返回 0 = 不是比较节点）。jcc 操作码 = setcc − 0x10。
static int setcc_of(int kind) {
  switch (kind) {
    case ND_EQ: return 0x94; // sete
    case ND_NE: return 0x95; // setne
    case ND_LT: return 0x9C; // setl
    case ND_LE: return 0x9E; // setle
    case ND_GT: return 0x9F; // setg
    case ND_GE: return 0x9D; // setge
    default: return 0;
  }
}

static void gen_cmp(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  gen_cmp_flags(c, node);
  int cc = setcc_of(node->kind);
  if (cc) emit_setcc(b, (uint8_t)cc);
  emit_movzx_eax_al(b);
}

// ===== v1.4.9①（任务卡 T-20260917-011322 第一档）：比较塌缩 =====
// 病（靶子 = bench4 循环体 `while (i < n) { ... }`）：
//   旧：cmp eax,ecx / setl al / movzx eax,al / test eax,eax / je 目标 —— **五条干一条**
//   新：cmp eax,ecx / jge 目标                                     —— 一条
// 只用在**条件位置**（if / while / for / 三元 / `!x`），比较表达式「作值」时的语义一行未改
// （作值仍走 gen_cmp：setcc + movzx，结果就是 0/1）。
// 边界：**double 比较一律不塌缩**——NaN 语义（v1.2.3 修好的 `!=`/`<`)在 gen_dbl_cmp 里，
//   多谓词组合（有序 ∧ 谓词）不是单个条件码能表达的，硬塌缩会把那两个 bug 放回来。
static bool try_gen_cmp_branch(FuncCtx *c, Node *cond, bool jump_if_false, int label) {
  Buf *b = &c->code;
  if (!cond) return false;
  // `!x`：判真 ⇔ x==0；「假则跳」⇔ x!=0 则跳（旧路同样是 test + setcc + movzx + test，白绕三圈）
  if (cond->kind == ND_NOT) {
    Node *in = cond->lhs;
    if (!in) return false;
    gen_expr(c, in);
    if (is64_value(in)) emit_test64(b); else emit_test(b);
    emit_jcc_label(c, jump_if_false ? 0x85 : 0x84, label);
    return true;
  }
  if (!setcc_of(cond->kind)) return false;
  if (expr_is_dbl(cond->lhs) || expr_is_dbl(cond->rhs)) return false;
  gen_cmp_flags(c, cond);
  int cc = setcc_of(cond->kind);
  int jcc;
  if (jump_if_false) {
    // 取反条件码：je↔jne、jl↔jge、jle↔jg
    switch (cc) {
      case 0x94: jcc = 0x85; break;   // sete  → jne
      case 0x95: jcc = 0x84; break;   // setne → je
      case 0x9C: jcc = 0x8D; break;   // setl  → jge
      case 0x9D: jcc = 0x8C; break;   // setge → jl
      case 0x9E: jcc = 0x8F; break;   // setle → jg
      default:   jcc = 0x8E; break;   // setg  → jle
    }
  } else {
    jcc = cc - 0x10;                  // jcc 操作码 = setcc − 0x10（setl 0x9C → jl 0x8C …）
  }
  emit_jcc_label(c, (uint8_t)jcc, label);
  return true;
}

// 短路 &&：a==0 → 0；b==0 → 0；否则 1（操作数地址类 → test rax,rax，v0.9）
static void gen_logand(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  int f = new_label(c), end = new_label(c);
  gen_expr(c, node->lhs);
  if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
  emit_jcc_label(c, 0x84, f);      // je false
  gen_expr(c, node->rhs);
  if (is64_value(node->rhs)) emit_test64(b); else emit_test(b);
  emit_jcc_label(c, 0x84, f);      // je false
  emit_mov_eax_imm(b, 1);
  emit_jmp_label(c, end);
  emit_label(c, f);
  emit_mov_eax_imm(b, 0);
  emit_label(c, end);
}

// 短路 ||：a≠0 → 1；b≠0 → 1；否则 0（操作数地址类 → test rax,rax，v0.9）
static void gen_logor(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  int t = new_label(c), end = new_label(c);
  gen_expr(c, node->lhs);
  if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
  emit_jcc_label(c, 0x85, t);      // jne true
  gen_expr(c, node->rhs);
  if (is64_value(node->rhs)) emit_test64(b); else emit_test(b);
  emit_jcc_label(c, 0x85, t);      // jne true
  emit_mov_eax_imm(b, 0);
  emit_jmp_label(c, end);
  emit_label(c, t);
  emit_mov_eax_imm(b, 1);
  emit_label(c, end);
}

// 函数调用（v0.5）：参数 ≤4 寄存器传参。
// 求值顺序：从右往左；每个参数值求完 push 暂存，再从左往右弹出到 rcx/rdx/r8/r9；
// push/pop 配对 → call 前 rsp 回到进入时的对齐态，不破坏 16 对齐。
//
// ===== M6 ③B 前置：is_call_free（"求值过程里不会出现 call"的显式白名单）=====
// 为什么需要它：`push rax / pop rcx` 这套搬运**表面上只是把值放进 rcx**，实际还承担了
//   "把值藏进栈、躲开后面求值里可能出现的 call" 这个职责 —— 而 call 会改写 rcx。
//   ⇒ 想省掉这两条，必须先能证明"这段求值不会 call"。用白名单（认不得的一律 false），
//   别用黑名单（新节点类型悄悄漏进来就静默错值）。
// 白名单：常量 / 变量读 / 解引用读 / 纯算术·位运算·比较·逻辑（含一元） / 取址 / 函数地址。
//   **不在名单**：调用 / API 调用 / 赋值（含复合赋值）/ 自增自减 / new / 库里新的调用类节点。
//   ⚠️ 除法与取模**不列进来**：本项目历史上它们是运行时辅助路径，保守当"会 call"处理（宁可少优化）。
static bool is_call_free(Node *n) {
  if (!n) return true;
  switch (n->kind) {
    case ND_NUM: case ND_DBL: case ND_STR: case ND_VAR:
    case ND_DEREF: case ND_ADDR: case ND_FUNC_ADDR:
      return true;
    case ND_ADD: case ND_SUB: case ND_MUL:
    case ND_BITAND: case ND_BITOR: case ND_BITXOR: case ND_SHL: case ND_SHR:
    case ND_EQ: case ND_NE: case ND_LT: case ND_LE: case ND_GT: case ND_GE:
    case ND_LOGAND: case ND_LOGOR:
      return is_call_free(n->lhs) && is_call_free(n->rhs);
    case ND_NEG: case ND_NOT: case ND_BITNOT: case ND_I2D: case ND_D2I:
      return is_call_free(n->lhs);
    default: return false;
  }
}

// ===== M8 ② 函数内联：接手前必读的三条（2026-09-19「一次打全」插桩实测，卡 T-20260919-215224）=====
// 前三次尝试全部"静默错值"（不崩、值一字不变），当时以为是"跳过形参叶子"的判据错 —— 实测**不是**。三条硬结论：
// ① **交接是硬约束，不是优化**：老路 `call` 之后调用方读的是 **eax**（被调函数 ret 前把值放进 eax）；
//    内联把结果留在 rcx ⇒ **必须补一句 `mov eax,ecx`（89 C8）**。缺这一步 = 调用方读到 eax 里的**残值**。
//    矩阵实测（变体编译器 tmp\inline-probe\flint_var.exe，主检出未动）：补上 ⇒ m9/m10/m7 = 0/0/194 **全对**；
//    不补 ⇒ **-50/-36/32** 全错。唯一变量就是那一句 89 C8（字节级 A/B：首差偏移正是老路 call 所在处）。
// ② **"跳过形参叶子"只作用于被调函数体**：实参树由 try_gen_arg_to_rcx 走 slot_load_ecx/eax 发射，
//    **根本不经过 skip**；而实参树（属调用方 AST）与函数体（属被调方 AST，所有调用点共用一个形参叶子指针）
//    **从不共用节点**。⇒ 判据用 ptr 还是 slot offset，三个探针产物**字节完全相同**（哈希逐条相等）——
//    别再在"判据"上做实验（那是空转，第三/四次尝试"换成传指针比较"值一字不变就是这个原因）。
// ③ 发"形参 ± 常量"**不能用 emit_alu_imm** —— 它是**累加器形态**（d 是算子、目标**恒为 eax**），
//    用它发"ecx += imm"会**静默发成 `add eax,imm`**（写错寄存器、不报错）。必须走 ModRM 形态写 ecx：
//    `83 C1 ib / 81 C1 id`（add ecx,imm8/imm32）、`83 E9 ib / 81 E9 id`（sub ecx,imm8/imm32）。
// ⚠️ 落地前先等用户点头（协作协议：FLINT 代码改动一律等用户点头）；验收照 M8 ② 原口径：
//    k3 循环体 8→6 条（call 消失）＋ 总门 ALL GREEN 11/11 ＋ 全语料 .text 不变大 ＋ 同会话 A/B 采样 ≥3 轮。
// ===== M8 ①（2026-09-19）：单实参调用 —— 把实参**直接算进 rcx**（「表达式的目标寄存器」档）=====
// 病（bench k3 循环体逐条数出来的基线，M6 ③B 之后剩 8 条）：
//   `a = bc_inc(a + i)` 的实参仍是「先落 eax 再搬一次」——
//     mov eax,ebx / mov ecx,r12d / add eax,ecx / mov rcx,rax   （4 条）
//   其中**两条 mov 是纯搬运**：算式先落 eax 是为了满足"表达式结果在 eax"这个旧约定，
//   而 Win64 的第一个实参位置就是 **rcx**（M6 ③B 已经证明单实参可以不绕栈）。
//   ⇒ 让表达式**直接发射到 rcx**：add 家族有镜像编码 `add ecx,eax`（01 C1），一条顶两条。
//   `a + i` 于是变成：mov ecx,ebx / add ecx,r12d（2 条），比老路省 2 条 mov。
// 安全性（这三条是这条档的全部前提，别放宽）：
//   ① 只走 gen_call 里 `arg1_direct` 已经成立的那条路（单实参 + 非 double + is_call_free）；
//      多实参的保序搬运（push/pop 配对）不碰 —— 那条路一改就要重排"先算谁"。
//   ② 两个操作数都必须是**普通局部 int 变量读**（判据 = simple_int_var_off 的唯一出处）：
//      · rhs 先读进 eax 只对"读"才安全 —— 若 rhs 有副作用（自增/调用），先算它= 改求值顺序=错；
//      · 两个简单变量之间**不可能互相改写**（本工程没有别名到局部槽的途径），故无 WAR 风险；
//      · 宽度/语义域与我们复刻的老路径完全一致（char/引用/全局/double/T1 槽不在条件里）。
//   ③ **绝不跨"值/地址"这层**（M7 两次失败的教训）：这里只搬 32 位 int 值，rcx 里装的
//      就是"实参值"本身，不是任何槽的地址；不使用 `[rcx±x]` 这类解引用。
// 失败（返回 false）= 调用方原样退 M6 ③B 的老路（gen_expr → mov rcx,rax），不做半吊子。
static bool try_gen_arg_to_rcx(FuncCtx *c, Node *a) {
  Buf *b = &c->code;
  if (!a || expr_is_dbl(a)) return false;
  // —— (1) 单个普通局部 int 变量：直接进 rcx（连 mov ecx→rcx 都省了）——
  if (a->kind == ND_VAR && !a->is_global && !a->is_ref && a->ty == TY_INT && !slot_marked(a->offset)) {
    slot_load_rcx64(b, a->offset);
    return true;
  }
  // —— (2) `x <op> y`（两个普通局部 int 变量）：mem→ecx，mem→eax，就地运算落 ecx ——
  //     只收"结果 = 低 32 位"且不碰 rcx 的算子；MUL/DIV/MOD/移位不吃这条（要 eax 累加器 / cl 除数）。——
  if (!a->lhs || !a->rhs) return false;
  if (a->kind != ND_ADD && a->kind != ND_SUB && a->kind != ND_BITAND &&
      a->kind != ND_BITOR && a->kind != ND_BITXOR) return false;
  if (!is_call_free(a)) return false;   // 只读节点，兜底再证一遍"求值不会 call"
  int lo = simple_int_var_off(a->lhs);
  int lo2 = simple_int_var_off(a->rhs);
  if (lo < 0 || lo2 < 0) return false;
  slot_load_ecx(b, lo);                 // ecx = x（左操作数，先算它 = 保持原求值顺序）
  slot_load_eax(b, lo2);                // eax = y（临时；rcx 是目标，全程不被这两条碰）
  switch (a->kind) {
    case ND_ADD:    emit_add_ecx_eax(b); break;
    case ND_SUB:    emit_sub_ecx_eax(b); break;
    case ND_BITAND: emit_and_ecx_eax(b); break;
    case ND_BITOR:  emit_or_ecx_eax(b);  break;
    default:        emit_xor_ecx_eax(b); break;   // ND_BITXOR
  }
  return true;
}

// ===== v1.4.30（M8 ② 内联）：单实参小函数**内联** —— 连 `call` 一起省 =====
// 动机（账本给的下一档）：k3 循环体 8 条里 `call` ＋ 返回值落回 `mov %eax,%ebx` 已是地板 ⇒ 再要收益必须消掉 call。
// 做法：**实参照常按 `gen_expr` 发射（值落在 `eax` —— 这本来就是"表达式结果"的约定位置）**，
//   被调函数体的返回表达式**直接在这棵 `eax` 上继续叠**：形参叶子什么都不发、
//   `形参 ± 常量` 发一条 `add/sub eax,imm`。**不发 `call`**。
// ⚠️ **为什么必须落在 `eax`、而不是 `rcx`（前三次尝试的死因，接手必读）**：老路 `call` 之后调用方读的是
//   **eax**（被调函数 `ret` 前把值放进 eax）。前三次把结果留在 **rcx** 却**没有交接** ⇒ 调用方读的是 eax 里的
//   **残值**（静默错值、不崩；矩阵实测：不补交接 ⇒ 探针 -50/-36/32 全错，补一句 `mov eax,ecx` ⇒ 0/0/194 全对）。
//   ⇒ **正解不是"补一句交接"，而是"一开始就别换寄存器"**：结果留在 eax 就天然满足调用约定，那句交接
//   根本不必存在（本轮先落了一版"rcx ＋ 交接"，实测循环体反而多 1 条，故改成本版）。
//   同轮还证掉两个疑点：`SKIP=ptr` 与 `SKIP=off` **产物字节完全相同**（skip 只在被调函数体里被查询、
//   实参树根本不经过它）⇒ "跳过形参叶子的判据"是**无意义旋钮**；**重复发射清单 = 0** ⇒ 与"共用 AST /
//   求值流走两遍"无关。取证见 PROGRESS 22:0x 条与 `tmp\inline-probe\`（那套 env/插桩只在副本里）。
// 资格（**全部在发射任何字节之前判完** —— 否则"体不进白名单"时实参已发一遍、老路再发一遍 = 实参被发两次）：
//   ① 直接调用 FLINT 函数（非函数指针间接调用）、恰好 1 个实参、实参非 double 且 `is_call_free`
//      （= 老路 M6 ③B / M8 ① 那条"直搬不绕栈"路的前提）；
//   ② 被调函数：非 main、非 void、`ret_ty == TY_INT`、1 个**非引用** `int` 形参；
//   ③ 函数体**只有一条 `return <表达式>;`**，且表达式在白名单内：`形参` 或 `形参 ± 常量字面量`。
//      白名单外的形态一律不内联（半吊子内联会把"求值顺序 / 副作用 / 宽度"这类前提一起带进来）。
// 不满足 ⇒ 返回 false，调用方原样走老路（老路逐字节不变 ⇒ 等价门能钉住改动范围）。
// 不带任何环境开关 / 调试插桩：定位用的那套只在副本 `tmp\inline-probe\` 里。
// 「这一支是不是形参叶子」的唯一判据 = **指针同一性**（按槽偏移认是错的：调用点的局部量可能恰好同槽）。
static bool inl_is_param_leaf(Node *n, Node *param) { return n && n->kind == ND_VAR && n == param; }

// 在被调函数体里找形参叶子（按槽偏移找一次，之后一律用指针比较）。
static Node *inl_find_param(Node *n, int off) {
  if (!n) return NULL;
  if (n->kind == ND_VAR && n->offset == off) return n;
  Node *r;
  if ((r = inl_find_param(n->lhs, off))) return r;
  if ((r = inl_find_param(n->rhs, off))) return r;
  if ((r = inl_find_param(n->els, off))) return r;
  return NULL;
}

// 体表达式的白名单（纯判据，不发射）：只有这两条形态。
static bool inl_body_ok(Node *e, Node *param) {
  if (!e || !param) return false;
  if (inl_is_param_leaf(e, param)) return true;                    // `return x;`
  if ((e->kind == ND_ADD || e->kind == ND_SUB) && e->lhs && e->rhs &&  // `return x ± 常量;`
      inl_is_param_leaf(e->lhs, param) && e->rhs->kind == ND_NUM)
    return true;
  return false;
}

// 把体表达式"叠"在 eax 上（调用前 inl_body_ok 必须已为真）。
// ⚠️ 这里用 `emit_alu_imm`（**累加器形态**、目标恒为 eax）是**正确**的 —— 因为约定的结果位置就是 eax；
//   反过来说：想发"ecx += imm"就**不能**用它（会静默变成 `add eax,imm`，本项目踩过）。
static void inl_emit_on_eax(FuncCtx *c, Node *e) {
  if (e->kind == ND_VAR) return;                    // 形参叶子：值已经在 eax 里 ⇒ 不发指令
  int v = e->rhs->val;
  if (e->kind == ND_ADD) emit_alu_imm(&c->code, 0, false, v);
  else                   emit_alu_imm(&c->code, 5, false, v);
}

static bool try_inline_call(FuncCtx *c, Node *node) {
  if (!c->prog || node->func_index < 0) return false;         // 间接调用（函数指针）不碰
  if (node->is_void || node->ty != TY_INT) return false;      // 结果不是 int 值（void / 指针 / double）不碰
  FuncDef *cf = &c->prog->funcs[node->func_index];
  if (cf->is_main || cf->ret_void || cf->ret_ty != TY_INT) return false;
  if (cf->nargs != 1 || cf->param_ref[0] || cf->param_ty[0] != TY_INT) return false;
  if (!cf->body || cf->body->kind != ND_RETURN || cf->body->next) return false;  // 体只有一条 return
  Node *ret_e = cf->body->lhs;
  if (!ret_e || expr_is_dbl(ret_e)) return false;
  Node *args[4]; int n = 0;
  for (Node *a = node->rhs; a; a = a->next) args[n++] = a;
  if (n != 1) return false;
  if (expr_is_dbl(args[0]) || !is_call_free(args[0])) return false;
  Node *param = inl_find_param(ret_e, cf->param_offsets[0]);
  if (!inl_body_ok(ret_e, param)) return false;               // ⚠️ 必须在发射之前判完
  gen_expr(c, args[0]);              // 实参照常发射（值落 eax；到这里已确定要内联 ⇒ 实参只发这一次）
  inl_emit_on_eax(c, ret_e);         // 体在 eax 上叠；`return x;` 时什么都不发（eax 已是返回值）
  return true;                       // 结果本来就该在 eax ⇒ **不需要任何"交接"指令**
}

// v1.4.26：实参 > 4 的调用走**栈参路径**（发射器定义在 emit_store_rax_rsp 之后 —— 那里有栈参写入 helper）
static void gen_call_many(FuncCtx *c, Node *node, Node **args, int n);

static void gen_call(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  // 收集参数（≤FUNC_MAX_ARGS = 32，parse 已保证；v1.4.26 由 4 抬到 32）
  Node *args[FUNC_MAX_ARGS];
  int n = 0;
  for (Node *a = node->rhs; a; a = a->next) args[n++] = a;
  // ===== v1.4.25（`-strict`）①③ ＋ v1.4.27（卡 T-20261012-210751）**默认口径** =====
  //   ① 值 → 指针形参（`-strict` 报 E-T1-INTTOPTR；默认报「地址形参需要指针」）
  //   ③ 地址值(64 位) → 值形参（`-strict` 报 E-STRICT-WIDTH；默认报「地址值不能装进 int 形参」）
  // 判据**复用 T1 那一套**（is_addr_value / is_addr_expr / 显式常量 / API 返回值）—— 别在这儿另写
  //   一份"这值像不像地址"（同一条规则两处实现迟早分叉，这是本项目的老账）。
  // ⚠️ 只查 FLINT 函数调用（直接调用 func_index >= 0）：**API 调用不查** —— Win32 的 api 形参按约定
  //   都声明成 int（句柄、缓冲地址都往 int 形参里塞），那是唯一正确写法，拦它等于拦所有真程序。
  //
  // v1.4.27 这一刀（把两条 gap 从"静默通过"收成"编译期硬错"）**为什么落在这里**：
  //   · 这两条方向**本来就只有这一处判定**（上面那句"别另写一份"就是理由）：判据
  //     `is_addr_value/is_addr_expr` 是 codegen 的静态函数（还读 T1 的 g_ai 标记表），
  //     parse.c 侧只有一套**不同源**的三元专用判定 `tern_addr_info` —— 在那边再实现一遍 =
  //     同一条规则两处实现，正是本文件禁止的老账（且会漏掉"装地址的 int"这一类）。
  //   · codegen 跑在 parse **之后**：`cf->param_ty[]` 对**每一个**调用点都已是最终值
  //     （含"调用点在定义之前"的前向调用与自递归）。写在 parse.c 得先改预扫描把 `*` 也提前落表，
  //     那是白搭的解析期行为变化。
  //   · `-strict` 档的判据、稳定错误码、文案**一个字都不改**（命中时走下面 flint_strict 那两句话）。
  // 默认口径的两处**有意收窄**（宁可有漏报，也绝不把合法写法打死）：
  //   · 方向①仍放行**整数字面量**（FLINT 没有 NULL 关键字，`f(0)` 是写空指针的唯一方式）与
  //     **API 返回值**（句柄/缓冲地址本来就从 API 出来）—— 与 `-strict` 的放行表逐字一致。
  //   · 方向②只查 `int`/`char`/`double` 三种**值**形参；引用形参、函数指针形参都不进（它们要的就是地址）。
  //     `-strict` 侧仍只查 `int`（保持它既有的四类口径不变）。
  if (node->func_index >= 0 && c->prog) {
    FuncDef *cf = &c->prog->funcs[node->func_index];
    for (int i = 0; i < n && i < cf->nargs; i++) {
      Node *a = args[i];
      bool by_addr = cf->param_ref[i] || cf->param_ty[i] == TY_PTR || cf->param_ty[i] == TY_FUNCPTR;
      // ⚠️ double 形参：parse 侧已把 int 实参包了一层 ND_I2D（C 语义自动提升）⇒ 判"这是不是地址"
      //    必须**看穿那层**：否则 `f(&x)`（f 的形参是 double）会静默通过
      //    （口径核对脚本 `tmp\t1\口径核对.ps1` 实测抓到的洞，别删这层解包）。
      //    指针/引用形参不会走到这里被包（parse 的 widen 分支要求 !by_addr），所以解包对方向①无影响。
      Node *chk = a;
      if (chk->kind == ND_I2D && chk->lhs) chk = chk->lhs;
      // v1.4.27：`(ia + 8) - ia`（地址 − 地址 = 标量差值）不是地址 —— 见 addr_diff_is_scalar 的注释。
      bool arg_is_addr = (is_addr_value(chk) || is_addr_expr(chk)) && !addr_diff_is_scalar(chk);
      if (by_addr && !arg_is_addr && a->kind != ND_NUM && a->kind != ND_APICALL) {
        if (flint_strict)
          error_at_nodef(node, "[E-T1-INTTOPTR] 实参只有 32 位（int 值），而第 %d 个形参是指针"
                               "——传进去的只有低 32 位，被调方当指针用会指向错地方。"
                               "请传地址（&x / 指针变量 / 数组名 / new / API 返回值），或把形参改成 int"
                               "（-strict 诊断）", i + 1);
        error_at_nodef(node, "地址形参需要指针——函数 '%s' 的第 %d 个形参收地址，实参却是整数/值"
                             "（要传地址请写 &x，或把形参改成值类型）", cf->name, i + 1);
      }
      if (!by_addr && arg_is_addr) {
        if (flint_strict && cf->param_ty[i] == TY_INT)
          error_at_nodef(node, "[E-STRICT-WIDTH] 实参是**地址值**（64 位），而第 %d 个形参声明成 int"
                               "（4 字节语义）⇒ 高 32 位会被丢掉（SPEC 记的 T1 遗留边界）。"
                               "请把形参声明成 int *（-strict 诊断）", i + 1);
        if (cf->param_ty[i] == TY_INT || cf->param_ty[i] == TY_CHAR || cf->param_ty[i] == TY_DOUBLE)
          error_at_nodef(node, "地址值不能装进 int 形参——函数 '%s' 的第 %d 个形参是值类型"
                               "（int/char/double），实参却是指针/地址"
                               "（请先解引用 *p，或把形参改成指针类型）", cf->name, i + 1);
      }
    }
  }
  // ===== v1.4.26：实参 > 4 ⇒ 第 5 个起走**栈参**（Win64 规范；与 gen_apicall 同一套 rsp 纪律）=====
  //   n ≤ 4 的调用点**一个字节都不变** —— 老路径原样留在下面，回归门与 dump 基线钉得住。
  //   （放在 strict 诊断之后：>4 的调用点照样要过 E-T1-INTTOPTR / E-STRICT-WIDTH 两条检查）
  if (n > 4) { gen_call_many(c, node, args, n); return; }
  // 从右往左求值入栈
  // ===== M6 ③B（2026-09-19）：单实参且"求值不会碰 rcx"时**不绕栈** =====
  // 病（bench k3 循环体实测逐条数）：`a = bc_inc(a + i)` 的实参搬运是
  //   `mov eax,ebx / mov ecx,r12d / add eax,ecx / push rax / pop rcx` —— 最后两条只为"把值放到 rcx"，
  //   而这两条指令**既多占前端带宽、又多两次栈访问**。
  // 本档：n == 1 且实参不是 double 且 `is_call_free(实参)` ⇒ 直接求值后 `mov rcx,rax`（栈完全不动）。
  //   安全性：① 单实参 ⇒ 没有"后来的实参要保护前一个"的问题；
  //   ② `is_call_free` 保证求值过程里**不会出现 call**（否则 call 会改写 rcx，而 push/pop 版本靠栈
  //      把值保住了 —— 这就是不能无条件去掉 push/pop 的原因）；
  //   ③ 栈指针没动 ⇒ 与 push/pop 版本的 rsp 对齐态逐点相同（call 前的 ≡0 校验逻辑不受影响）。
  //   多实参仍走原路（低效，但要保序：`pop rcx / pop rdx` 与"先算谁"的顺序绑在一起，动了容易错）。
  // ===== M8 ②（2026-09-19 第四次尝试）：能内联就直接内联（连 call 一起省）=====
  //   资格与发射全在 try_inline_call 里，且它保证"判不过就一个字节都不发"（实参不会发两遍）；
  //   返回 false ⇒ 下面老路逐字节不变。返回值交接（rcx → eax）在那边末尾做，别在这里补。
  if (try_inline_call(c, node)) return;
  bool arg1_direct = (n == 1) && !expr_is_dbl(args[0]) && is_call_free(args[0]);
  // ===== M8 ①（2026-09-19）：直落 rcx 优先 =====
  //   老路（M6 ③B）：gen_expr(实参) → mov rcx,rax —— 表达式先落 eax、再搬一次。
  //   新路：try_gen_arg_to_rcx 把实参**直接算进 rcx**（镜像编码 add ecx,eax）。
  //   它返回 false 时老路逐字节不变（所以不满足条件的调用点产物与 M6 完全一致，等价门能钉住）。
  if (arg1_direct) {
    // M8 ①：先试"直接算进 rcx"；它自己负责发射，发射不了再走老路
    if (!try_gen_arg_to_rcx(c, args[0])) {
      gen_expr(c, args[0]);
      emit_mov_rcx_rax(b);            // rcx = 实参（不绕栈）
    }
  } else {
    for (int i = n - 1; i >= 0; i--) {
      gen_expr(c, args[i]);
      // v1.2.2 double 实参：值在 xmm0（不是 rax）→ 先 movq 到 rax 再压栈，统一搬运
      if (expr_is_dbl(args[i])) emit_movq_rax_xmm0(b);
      emit_push_rax(b);
    }
  }
  // 从左往右弹出到参数寄存器
  // v1.2.2：双通道落位——整数实参按序进 GP（rcx/rdx/r8/r9），double 实参按序进 XMM（xmm0-3），
  //   两套序列**并行计数**（Win64 约定，与 gen_apicall 一致）。纯整数实参走原路径，
  //   产物字节级不变（旧回归钉过字节序列）。
  bool has_dbl = false;
  for (int i = 0; i < n; i++) if (expr_is_dbl(args[i])) has_dbl = true;
  if (arg1_direct) {
    // M6 ③B：实参已经在 rcx（上面直接搬的），**没有压栈 ⇒ 也就没有出栈**（栈指针全程未动）
  } else if (!has_dbl) {
    if (n > 0) emit_pop_rcx(b);
    if (n > 1) emit_pop_rdx(b);
    if (n > 2) emit_pop_r8(b);
    if (n > 3) emit_pop_r9(b);
  } else {
    int gi = 0, xi = 0;
    for (int i = 0; i < n; i++) {
      emit_pop_rax(b);                          // 第 i 个实参（栈顶 = arg1）
      if (expr_is_dbl(args[i])) {
        if (xi == 0)      emit_movq_xmm0_rax(b);
        else if (xi == 1) emit_movq_xmm1_rax(b);
        else if (xi == 2) emit_movq_xmm2_rax(b);
        else              emit_movq_xmm3_rax(b);
        xi++;
      } else {
        emit_arg_rax_to_gp(b, gi, args[i]);   // 卡 T-20261010-122541：地址类整搬 / int 值符号扩展
        gi++;
      }
    }
    // 寄存器的数量上限由 parse 保证（总参数 ≤4；double ≤4 → XMM0-3 够用）
  }
  // call 被调函数（E8 rel32；目标位置布局后由 note_ext 回填）
  // v1.0.12（评审清单【2】）：call 点必须 rsp≡0——被调函数按「入口 rsp≡8」做序言
  // （push rbp → ≡0 → sub 16 倍数 → ≡0），它内部的每条 FF15 API 调用才落在 ≡0。
  // 原注释「内部函数无 SSE 故不校验」错在：16 字节对齐是给**被调函数内部**的 API 调用用的。
  // 违例实例：g() + g() —— 第一次调用 ≡0，返回值 push 后第二次调用 ≡8 → g 里 FF15 落 ≡8，
  // 换成任何用 movaps 的 API 即崩。修法：call 前按需补 8 字节垫，call 后原样回收。
  int pad = 0;
  if (g_rspm == 8) { emit_sub_rsp(b, 8); pad = 8; }          // 垫平（rax 不动，无 clobber）
  else if (g_rspm != 0)
    error("内部 rsp 状态异常（FLINT 函数调用点 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen", g_rspm);
  slotmap_note_call();   // v1.4.21（M2）：调用点推进"调用纪元"（判槽是否跨调用存活）
  if (node->func_index < 0) {
    // v1.3.2：间接调用（函数指针）——目标地址在**实参全部就位之后**才装进 rax，然后 FF D0。
    //   ⚠️ 顺序是硬约束：目标装载若放在实参求值之前，任何实参里的函数调用/运算都可能改写 rax
    //      → 跳到野地址（v1.3.2 的变体实验专门钉了这一条：把装载提前 = 样本必崩）。
    //   `mov rax,[rbp-off]` 只写 rax，不碰 rcx/rdx/r8/r9 与 xmm0-3（实参寄存器），故安全。
    Node *tv = node->lhs;   // 被调用的函数指针变量（parse 填：ND_VAR，指示调用目标）
    if (!tv || tv->kind != ND_VAR)
      error("内部错误：间接调用节点缺少函数指针目标");
    slot_load_rax64(b, tv->offset);       // rax = fp（代码地址，64 位全宽）
    st_call(); st_ins();
    buf_byte(b, 0xFF);
    buf_byte(b, 0xD0);                    // call rax（FF D0）
  } else {
    st_call(); st_ins();
    buf_byte(b, 0xE8);
    note_ext(c, node->func_index);
    buf_u32(b, 0);
  }
  if (pad) emit_add_rsp(b, pad);    // 回收垫（返回值在 rax，add 不影响）
  // 返回值 eax
}

// v0.8.1：mov [rsp+disp], rax（栈参数写入；Win64 第 5 参起在 [rsp+32+..]）
// ⚠️ v1.4.26：**disp8 只到 127** —— 32 参时栈参偏移最大 = 32 + 27*8 = 248 ⇒ 必须走 disp32 形态。
//   （api 侧 API_MAX_ARGS=16 时最大 120，所以旧实现在 api 路径上从没撞到；抬到 32 参后必撞，
//     症状 = 高编号栈参写进错槽/回卷，编译零提示 —— 同族 `disp8 要带 off<=127 守卫`。）
static void emit_store_rax_rsp(Buf *b, int off) {
  if (off <= 127) {
    // 48 89 44 24 imm8（rsp 基址 SIB；off ≤127）
    const uint8_t x[] = {0x48, 0x89, 0x44, 0x24, (uint8_t)off};
    buf_bytes(b, x, 5);
  } else {
    // 48 89 84 24 disp32 = mov [rsp+disp32], rax
    const uint8_t x[] = {0x48, 0x89, 0x84, 0x24};
    buf_bytes(b, x, 4);
    buf_u32(b, (uint32_t)off);
  }
}

// v1.4.26：读「调用者栈区」的第 5 参起 —— [rbp+disp32]。
//   rbp+0 = 旧 rbp、rbp+8 = 返回地址、rbp+16..rbp+47 = shadow(32B) ⇒ **第 5 参在 rbp+48**。
//   kind 0 = mov eax,[rbp+d32]（int/char：32 位装载，与寄存器路径同宽度语义）
//   kind 1 = mov rax,[rbp+d32]（指针 / 引用 / 函数指针：64 位）
//   kind 2 = movsd xmm0,[rbp+d32]（double；规范：浮点第 5 个起同样落栈）
static void emit_load_rbp_pos(Buf *b, int disp, int kind) {
  if (kind == 2) {
    const uint8_t x[] = {0xF2, 0x0F, 0x10, 0x85};
    buf_bytes(b, x, 4);
  } else if (kind == 1) {
    const uint8_t x[] = {0x48, 0x8B, 0x85};
    buf_bytes(b, x, 3);
  } else {
    const uint8_t x[] = {0x8B, 0x85};
    buf_bytes(b, x, 2);
  }
  buf_u32(b, (uint32_t)disp);
}

// ===== v1.4.26（2026-09-27）：实参 > 4 的 FLINT 函数调用 —— 第 5 个起按 Win64 规范走**栈参** =====
// 口径与 gen_apicall **逐条一致**（同一份规范、同一套 rsp 纪律），差别只在 call 的形态（E8 / FF D0，不是 FF15）。
//   ① 调用者恒留 32B shadow；② 第 5 参起写 [rsp+32+(i-5)*8]；③ **右→左求值**；
//   ④ 总分配 16 对齐（call 点 rsp≡0）；⑤ 浮点第 5 个起同样落栈（8 字节位型）。
// ⚠️ 顺序是硬约束（v0.8.1 在 api 侧栽过）：**先 sub 预留**（此后 rsp 即 call 时 rsp，栈参偏移恒定）
//   → 再右→左写栈参 → 再右→左求值 push 前 4 个 → 按参数序出栈落位 → call → add 回收。
static void gen_call_many(FuncCtx *c, Node *node, Node **args, int n) {
  Buf *b = &c->code;
  // 进入时允许 rsp≡0 或 ≡8（≡8 = 外层有未消费压栈：二元左值 / 外层调用已压参数）
  if (g_rspm != 0 && g_rspm != 8)
    error("内部 rsp 状态异常（多参调用入口 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen", g_rspm);
  int total = 32 + (n - 4) * 8;
  total = (total + 15) / 16 * 16;               // shadow32 + 栈参区，16 对齐
  if (g_rspm == 8) total += 8;                  // 垫平外层未消费压栈（同 gen_apicall v1.0.4.1）
  emit_sub_rsp(b, total);
  // 栈参数 i = n..5：右→左求值，直接写 [rsp+32+(i-5)*8]（此阶段 rsp 未动 ⇒ 偏移恒定）
  for (int i = n; i >= 5; i--) {
    gen_expr(c, args[i - 1]);
    if (expr_is_dbl(args[i - 1])) emit_movq_rax_xmm0(b);   // double：位型搬进 rax 再落内存
    emit_store_rax_rsp(b, 32 + (i - 5) * 8);
  }
  // 前 4 个（寄存器参数）：右→左求值 push 暂存 → 按参数序出栈，GP / xmm 双通道各自计数
  for (int i = 4; i >= 1; i--) {
    gen_expr(c, args[i - 1]);
    if (expr_is_dbl(args[i - 1])) emit_movq_rax_xmm0(b);
    emit_push_rax(b);
  }
  {
    int gi = 0, xi = 0;
    for (int i = 1; i <= 4; i++) {
      emit_pop_rax(b);
      if (expr_is_dbl(args[i - 1])) {
        if (xi == 0)      emit_movq_xmm0_rax(b);
        else if (xi == 1) emit_movq_xmm1_rax(b);
        else if (xi == 2) emit_movq_xmm2_rax(b);
        else              emit_movq_xmm3_rax(b);
        xi++;
      } else {
        emit_arg_rax_to_gp(b, gi, args[i - 1]);   // 卡 T-20261010-122541：地址类整搬 / int 值符号扩展
        gi++;
      }
    }
    // 第 5 个及以后的 double 走栈 ⇒ **不占 XMM 序列**；FLINT 函数无可变参 ⇒ 不需要 gen_apicall 那套 AL 计数
  }
  // call 点 rsp≡0（total 是 16 的倍数 ⇒ 与入口同余，垫平后恒 ≡0）
  rsp_assert_ok("FLINT 多参调用发射");
  slotmap_note_call();
  if (node->func_index < 0) {
    // 间接调用（函数指针）：目标地址在**实参全部就位之后**才装进 rax（顺序与老路同一条硬约束）
    Node *tv = node->lhs;
    if (!tv || tv->kind != ND_VAR)
      error("内部错误：间接调用节点缺少函数指针目标");
    slot_load_rax64(b, tv->offset);
    st_call(); st_ins();
    buf_byte(b, 0xFF);
    buf_byte(b, 0xD0);                          // call rax（FF D0）
  } else {
    st_call(); st_ins();
    buf_byte(b, 0xE8);
    note_ext(c, node->func_index);
    buf_u32(b, 0);
  }
  emit_add_rsp(b, total);                       // 回收 shadow ＋ 栈参区（返回值在 rax）
}

// v0.9：FF15 [rip+disp32] → api_index 的 IAT 槽 + 回收预留空间（前向声明，gen_apicall 先用）
static void apicall_tail(FuncCtx *c, int api_index, int total);

// v0.8：外部 API 调用（Win64 ABI）——
// 参数：前 4 rcx/rdx/r8/r9，第 5 个起**栈参数**：调用者预留 shadow(32B) + 栈参空间，
// 栈参数 i(5..n) 放 [rsp+32+(i-5)*8]，总分配按 16 对齐（call 前 rsp≡0 不破坏）；
// call 走 IAT：FF15 [rip+disp32]（disp 由 pe_build 布局导入后回填）；
// call 后 add rsp 回收；返回值 rax（int 语义取低 32，句柄/指针全 64 保留）。
// ⚠️ v0.9 修复（v0.8.1 核心真 bug）：原先「先 push 全参 → 再 sub rsp 预留 → 再 pop」，
// pop 时 rsp 已下移 32B，读的是参数下方的 shadow 区 → 寄存器/栈参数全部传 0/垃圾
// （MessageBoxA/窗口样本的 EXIT=0 是 h==0→GetLastError()=0 的假阳性，从未真正传参成功）。
// 正确顺序：先 sub rsp 预留（此时 rsp = call 时 rsp）→ 栈参数(5..n) 直接写 [rsp+32+..]
// （右→左求值、rsp 未动偏移恒定）→ 寄存器参数(4..1) push 暂存（右→左，arg1 在顶）
// → 按序 pop rcx/rdx/r8/r9（rsp 回到 call 位）→ call。
static void gen_apicall(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  // v1.0.4.1 静态自检：进入时允许 ≡0 或 ≡8——≡8 是合法的外层未消费压栈
  // （二元运算左值 / FLINT 调用先求值参数已压栈，右操作数/后求值参数含 API 时即此态）。
  // 其它态（≡?）说明压栈未配对。
  if (g_rspm != 0 && g_rspm != 8)
    error("内部 rsp 状态异常（API 调用入口 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen", g_rspm);
  Node *args[API_MAX_ARGS];   // v1.4.0：上限单点定义（原 12，CreateFontA 14 参撞墙）
  int n = 0;
  for (Node *a = node->rhs; a; a = a->next) args[n++] = a;
  // 预留 shadow(32B) + 栈参区(5..n)，16 对齐；此后 rsp 即 call 时 rsp（16 对齐不变）
  int total = 32;
  if (n > 4) {
    total = 32 + (n - 4) * 8;
    total = (total + 15) / 16 * 16;
  }
  // v1.0.4.1 修复：进入 ≡8（外层压栈未消费：二元左值/FLINT 参数右→左已压栈，右操作数或
  // 后求值参数含 API）时预留 +8 垫——sub 后 FF15 处 rsp≡0（不加垫则 FF15 ≡8 错位，
  // 潜伏 bug：现有测试只把 API 放左操作数/直接语句，从未覆盖此路径）
  if (g_rspm == 8) total += 8;
  emit_sub_rsp(b, total);
  // 栈参数 i=5..n：右→左求值，直接写 [rsp+32+(i-5)*8]（此阶段 rsp 未动）
  for (int i = n; i >= 5; i--) {
    if (expr_is_dbl(args[i - 1]))
      error("浮点阶段1：double 实参只支持前 4 个（XMM0-3）——第 %d 个 double 参数暂未支持（栈上浮点参数 = 阶段2）", i);
    gen_expr(c, args[i - 1]);
    emit_store_rax_rsp(b, 32 + (i - 5) * 8);
  }
  // 寄存器参数：右→左求值 push 暂存，再左→右出栈按类型落位。
  // v1.1.0 修正（浮点暴露的老缺陷）：Win64 的**整数参数与浮点参数各有独立寄存器序列**——
  //   第 i 个 int → GP[i]（rcx/rdx/r8/r9），第 j 个 double → XMM[j]（xmm0-3），两者**并行计数**。
  //   旧实现把「位置 i → 第 i 个寄存器」硬绑（声明 `printf(int,double…)` 时第 1 个 double 被塞进
  //   xmm1、xmm0 空着）→ printf 读到全 0（实测输出 0.00|0.00|0.00）。纯 int 的 API 行为不变。
  int regs = n > 4 ? 4 : n;
  // v1.1.0：求值顺序不变（右→左 push 暂存），但**出栈严格按参数序**：第 i 次 pop 一定对应第 i 个参数。
  //   首版按类型分两轮出栈（先 XMM 后 GP / 或反之）——两种都错过：栈顶是 arg1，
  //   类型分轮会让「第 1 个 pop 决定谁」与参数序脱节（实测 printf 把格式串当 double 吃掉 → 输出 0.00）。
  //   正确做法：pop 到 rax 后**按该参数的类型**搬进对应寄存器（GP 侧 rcx/rdx/r8/r9 与浮点侧 xmm0-3 各自计数）。
  for (int i = regs; i >= 1; i--) {
    gen_expr(c, args[i - 1]);
    if (expr_is_dbl(args[i - 1])) emit_movq_rax_xmm0(b);   // xmm0 → rax（位型；统一用 rax 压栈）
    emit_push_rax(b);
  }
  int xi_used = 0;
  {
    int gi = 0, xi = 0;
    for (int i = 1; i <= regs; i++) {
      emit_pop_rax(b);                     // 第 i 个参数
      if (expr_is_dbl(args[i - 1])) {
        if (xi == 0)      { /* 已在 xmm0：movq xmm0,rax */ emit_movq_xmm0_rax(b); }
        else if (xi == 1) { emit_movq_xmm1_rax(b); }
        else if (xi == 2) { emit_movq_xmm2_rax(b); }
        else              { emit_movq_xmm3_rax(b); }
        xi++;
      } else {
        emit_arg_rax_to_gp(b, gi, args[i - 1]);   // 卡 T-20261010-122541：地址类整搬 / int 值符号扩展
        gi++;
      }
    }
    xi_used = xi;
  }
    // v1.1.0：可变参 API（printf 这类）必须把「用到的 XMM 寄存器个数」放进 AL（Win64 varargs 约定）——
    //   不设 AL 时 msvcrt 的 va_arg 完全读不到浮点实参（实测输出 0.00|0.00|0.00）。纯整数调用 AL=0，无害。
    if (xi_used > 0) { const uint8_t mov_al[] = {0xB0, (uint8_t)xi_used}; buf_bytes(b, mov_al, 2); }
    apicall_tail(c, node->api_index, total);
}

// v0.9：FF15 [rip+disp32] → api_index 的 IAT 槽 + 回收预留空间。
// gen_apicall / ND_NEW / own 出口清理共用（参数已按 Win64 就位）。
static void apicall_tail(FuncCtx *c, int api_index, int total) {
  Buf *b = &c->code;
  rsp_assert_ok("FF15 API 发射");   // v1.0.4.1：call 前 rsp≡0（S3 垫应在前面把 ≡8 补平）
  slotmap_note_call();              // v1.4.21（M2）：调用点推进"调用纪元"
  buf_byte(b, 0xFF);
  buf_byte(b, 0x15);
  if (c->napicalls == c->apicalls_cap) {
    size_t cap = c->apicalls_cap ? c->apicalls_cap * 2 : 8;
    ApiCallRef *ar = realloc(c->apicalls, cap * sizeof(*ar));
    if (!ar) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->apicalls = ar;
    c->apicalls_cap = cap;
  }
  ApiCallRef *ar = &c->apicalls[c->napicalls++];
  ar->off = c->code.len;   // disp32 位置
  ar->api = api_index;
  buf_u32(b, 0);           // 占位（pe_build 回填）
  emit_add_rsp(b, total);
}

// v0.9：rax = 块基址 → VirtualFree(base, 0, MEM_RELEASE)（3 参寄存器路径；栈平衡）
// own 出口释放 / share 归零释放共用（须在 apicall_tail 之后定义）
// ⚠️ S3 修复（v0.9.1）：调用方（函数出口清理段）先压了保护返回值 → 进本函数时
//   rsp≡8 (mod16)。原实现 sub32：FF15 在 rsp≡8 处执行，破自家「call 前 rsp≡0」
//   不变量——被 VirtualFree 宽容掩盖，未来换任何入口用 movaps 的 API 即崩。
//   预留改 40B（shadow32 + 8 对齐垫）：3push(−24)+sub40(−64)+3pop(+24) →
//   FF15 在 rsp≡(8−40)≡0 处执行；add rsp,40 收平。调用约定：进函数 rsp≡8。
static void emit_virtual_free(FuncCtx *c, int api_free) {
  Buf *b = &c->code;
  emit_push_rax(b);                    // arg1 = base
  emit_mov_eax_imm(b, 0);
  emit_push_rax(b);                    // arg2 = 0
  emit_mov_eax_imm(b, 0x8000);         // MEM_RELEASE
  emit_push_rax(b);                    // arg3
  emit_sub_rsp(b, 40);                 // S3：shadow 32 + 8 对齐垫（进函数 rsp≡8 → FF15 前 ≡0）
  emit_pop_rcx(b);
  emit_pop_rdx(b);
  emit_pop_r8(b);
  apicall_tail(c, api_free, 40);       // FF15 → VirtualFree + add rsp,40
}

// v1.3.0：这个左值是不是**直接局部变量**（帧槽 [rbp-off] 可一步寻址）。
// 全局变量（is_global）虽然 kind 也是 ND_VAR，但它的 offset 是 globals 下标、寻址是 [rip+disp]，
// **绝不能**走 emit_*_var(c->offset) 一族 —— 所以这里一并排除，把它推给「间接左值」通路
// （gen_lvalue_addr + [rdx] 存），那条路本来就能正确处理任意地址。
// ⚠️ 所有 `lhs->kind == ND_VAR && !lhs->is_ref` 的直接寻址分流都必须用本函数，
//    别各写各的——漏一处就是「编译过、静默错值」（v1.2.4「漏过一道处理」家族）。
static bool is_direct_var(Node *n) {
  return n && n->kind == ND_VAR && !n->is_ref && !n->is_global;
}

// 左值目标地址 → eax：
//   ND_VAR 普通/数组名 → lea [rbp-off]；引用变量 → 槽内容（对象地址）
//   v1.3.0 全局变量 → lea [rip+disp]（指 .data；offset 字段存的是 globals 下标）
//   ND_DEREF（*p / a[i] 展开）→ 内部地址表达式求值
// 供赋值/复合/++ 的间接写、引用绑定（ND_REF_BIND）、取址（ND_ADDR）统一使用
static void gen_lvalue_addr(FuncCtx *c, Node *lv) {
  Buf *b = &c->code;
  if (lv->kind == ND_DEREF) { gen_expr(c, lv->lhs); return; }
  if (lv->is_global) { emit_lea_g(c, lv->offset); return; }   // ⚠️ offset = globals 下标
  if (lv->is_ref) slot_load_rax64(b, lv->offset);   // v0.8：引用槽存地址 → 64 位读
  else slot_lea_rax(b, lv->offset);
}

static void gen_expr(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  switch (node->kind) {
    case ND_NUM: emit_mov_eax_imm(b, node->val); return;
    // ===== v1.7.0 int_64 =====
    case ND_NUM64:   // 64 位字面量 → rax（小值退 mov rax,imm32 符号扩展，短 3 字节）
      emit_mov_rax_imm64(b, node->lval);
      return;
    case ND_I2L:     // int → int_64（符号扩展：movsxd rax,eax）
      gen_expr(c, node->lhs);
      emit_movsxd_rax_eax(b);
      return;
    case ND_L2I:     // int_64 → int（显式收窄 to_int32：低 32 位）
      gen_expr(c, node->lhs);
      emit_l2i(b);
      return;
    // ===== v1.1.0 浮点（阶段1）=====
    case ND_DBL: {
      // double 字面量 → xmm0（内容 8 字节位型进数据区，disp 排布后回填）
      // ⚠️ 登记必须在发指令**之前**（note_dblref 可能 realloc，指针不能跨它存活）；
      //    同一常量多次出现 = 多个位置（note_dbluse 逐处记，回填时逐个补）
      size_t r = note_dblref(c, node->dval);
      const uint8_t movsd[] = {0xF2, 0x0F, 0x10, 0x05};   // movsd xmm0,[rip+disp32]
      buf_bytes(b, movsd, 4);
      note_dbluse(c, r, c->code.len);
      buf_u32(b, 0);                                       // 占位
      return;
    }
    case ND_I2D:   // int → double（cvtsi2sd xmm0,eax）
      gen_expr(c, node->lhs);
      emit_cvtsi2sd_xmm0_eax(b);
      return;
    case ND_D2I:   // double → int（cvttsd2si eax,xmm0，截断取整；越界 = 0x80000000，同 C）
      gen_expr(c, node->lhs);
      emit_cvttsd2si_eax_xmm0(b);
      return;
    case ND_STR: {
      // v0.7.3：字符串字面量值 = 数据段地址。lea rax,[rip+disp32]（48 8D 05）；
      // disp 目标是拼接 code 尾部的字符串区，全部函数生成完、排布后统一回填
      const uint8_t lea[] = {0x48, 0x8D, 0x05};
      buf_bytes(b, lea, 3);
      StrRef *r = note_strref(c);
      r->off = c->code.len;   // disp32 位置
      r->str = node->str;
      r->len = node->str_len;
      r->str_off = 0;
      buf_u32(b, 0);          // 占位
      return;
    }
    case ND_VAR:
      // v1.3.0：全局变量读——宽度随类型走 [rip+disp32]（offset 存 globals 下标）
      if (node->is_global) {
        int gi = node->offset;
        if (node->ty == TY_ARR || node->ty == TY_STRUCT) { emit_lea_g(c, gi); return; }  // 数组名 = 首地址
        if (node->ty == TY_DOUBLE) { emit_load_gdbl(c, gi); return; }                    // xmm0 ← [rip+disp]
        if (node->ty == TY_CHAR) { emit_load_gbyte(c, gi); return; }                     // movzx 字节
        if (node->ty == TY_PTR) { emit_load_g64(c, gi); return; }                        // 64 位值
        // int：**64 位读**（与写入侧的 64 位间接写配对）。读写宽度不一致会让 .data 槽高 4 字节
        //   留下上一次的残渣 → 后续 64 位读回垃圾（静默错值）。见 ND_ASSIGN 处「全局 int 宽度约定」。
        emit_load_g64(c, gi);
        return;
      }
      // 数组名/结构体变量名作表达式 = 其首地址（v0.7.x：无整体值语义；v0.8 引用槽 64 位读）
      if (node->ty == TY_ARR || node->ty == TY_STRUCT) {
        if (node->is_ref) slot_load_rax64(b, node->offset);
        else slot_lea_rax(b, node->offset);
        return;
      }
      if (node->is_ref) {
        // v0.8：引用变量槽 = 对象地址（64 位读）→ 解引用取对象值（32 位）
        // v1.2.5：double& → 别名对象是 8 字节浮点，必须走 SSE 取（整数路径只会读到低 4 字节位型）
        if (node->ty == TY_DOUBLE) {
          slot_load_rax64(b, node->offset);
          emit_mov_rdx_rax(b);
          emit_load_dbl_at_rdx(b);   // xmm0 = [r]
          return;
        }
        slot_load_rax64(b, node->offset);
        emit_deref_eax(b);   // [rax]（地址 64 位完整）
        return;
      }
      // v1.3.2：函数指针变量值 = 代码地址（64 位完整）——漏掉这一档会按 32 位读，
      //   传给函数指针形参/当实参时高 32 位丢 → 跳到野地址（本轮实测：p11/p12 探针当场崩）
      if (node->ty == TY_PTR || node->ty == TY_FUNCPTR) {
        // v0.8：指针变量值 = 地址（64 位完整；可指数据段/栈，供 API 传参）
        slot_load_rax64(b, node->offset);
        return;
      }
      if (node->ty == TY_CHAR) {
        // v1.0.5：char 读 = movzx 字节（0..255；槽上层字节可为残留，只取低字节）
        slot_load_byte(b, node->offset);
        return;
      }
      if (node->ty == TY_DOUBLE) {           // v1.1.0：double 变量读 → xmm0
        slot_load_dbl(b, node->offset);
        return;
      }
      // v1.7.0：int_64 局部读 = 8 字节整读（必须排在 slot_load_eax 兜底之前 —— 漏补这一档 = 读半截）
      if (node->ty == TY_INT64) {
        slot_load_rax64(b, node->offset);
        return;
      }
      // v1.0.13 T1 ②：装地址的 int 变量 → 8 字节读（高半完整；算术仍只消费 eax，语义不变）
      if (node->ty == TY_INT && slot_marked(node->offset)) {
        slot_load_rax64(b, node->offset);
        return;
      }
      slot_load_eax(b, node->offset);        // int 值（32 位）
      return;
    case ND_DEREF:
      gen_expr(c, node->lhs);    // rax = 地址（64 位完整）
      // v0.9.2：读写宽度随读取目标类型——ptr 字段（s.hwnd）→ 64 位；int 字段/*p/a[i] → 32 位
      // v1.0.5：char 目标（char 字段/元素/char* 解引用）→ movzx 字节读
      if (node->ty == TY_PTR) emit_deref_rax64(b);
      // v1.7.0：int_64 目标（int_64 数组元素 / 结构体 int_64 字段 / int_64* 解引用）→ 8 字节整读
      else if (node->ty == TY_INT64) emit_deref_rax64(b);
      else if (node->ty == TY_CHAR) emit_load_byte_at_rax(b);
      // v1.2.4：double 目标（double 数组元素 / double 结构体字段 / double 指针解引用）→ SSE 8 字节读
      else if (node->ty == TY_DOUBLE) { emit_mov_rdx_rax(b); emit_load_dbl_at_rdx(b); }
      else emit_deref_eax(b);    // eax = [rax]（32 位对象值）
      return;
    case ND_ASSIGN: {
      // v1.3.0 全局 int/char：**宽度约定**——全局标量一律按 64 位读（ND_VAR 处）与 64 位写（下方间接通路），
      //   两侧宽度必须一致，否则 .data 槽高 4 字节留残渣 → 下次 64 位读回垃圾。
      //   代价：「把地址装进全局 int」没法不截断（全局变量不参与 T1 的 slot-marked 机制，
      //   运行时判不出来）→ 明确报错，不静默截断（与 v1.0.13 T1 ③④ 同一红线）。
      if (node->lhs->kind == ND_VAR && node->lhs->is_global
          && (node->lhs->ty == TY_INT || node->lhs->ty == TY_CHAR)
          && is_addr_value(node->rhs))
        error_at_node(node, "地址值（64 位）不能装进全局 int / char 变量——全局变量会被按 4/1 字节写回，"
                            "高 32 位必然丢失（不静默截断）。请把地址存在**局部** int * 变量里，"
                            "或用局部变量接收后再逐值算出所需整数");
      // 直接目标 = 普通（非引用）变量：右值 → [rbp-off]（v0.8：指针变量 64 位写）
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      if (direct) {
        if (node->lhs->ty == TY_DOUBLE) {   // v1.1.0：double 赋值（右值已在 xmm0，整型右值已被 parse 提升）
          gen_expr(c, node->rhs);
          slot_store_dbl(b, node->lhs->offset);
          return;
        }
        // v1.3.2：函数指针变量也是 64 位地址——必须 64 位写槽（按 32 位写 = 高半留残渣，
        //   随后 `mov rax,[rbp-off]` 读出野地址 → call rax 崩。本轮 p1 探针就是这么崩的）
        if (node->lhs->ty == TY_PTR || node->lhs->ty == TY_FUNCPTR)
          check_ptr_target(node, node->rhs);   // v1.0.13 T1 ④
        gen_expr(c, node->rhs);
        if (node->lhs->ty == TY_PTR || node->lhs->ty == TY_FUNCPTR)
          slot_store_rax64(b, node->lhs->offset);
        // v1.7.0：int_64 局部槽必须 8 字节整写（排在所有 32 位档之前；parse 已保证 rhs 是
        //   64 位值或 ND_I2L，这里再兜一道 movsxd 保证高半确定 —— 与 T1 ① 同一条纪律）
        else if (node->lhs->ty == TY_INT64) {
          if (!is64_value(node->rhs)) emit_movsxd_rax_eax(b);
          slot_store_rax64(b, node->lhs->offset);
        }
        else if (node->lhs->ty == TY_CHAR) { slot_store_byte(b, node->lhs->offset); emit_movzx_eax_al(b); } // v1.0.5 字节写（v1.0.6.2 A2：表达式值截断=存储字节）
        // v1.0.13 T1 ①：装地址的 int 槽按 8 字节存——地址值原样写满；普通 int 值先符号扩展再写满
        // （否则高半留旧值/栈残渣，T1 ② 的 8 字节读会读回垃圾）
        else if (node->lhs->ty == TY_INT && slot_marked(node->lhs->offset)) {
          if (!is_addr_value(node->rhs)) emit_movsxd_rax_eax(b);
          slot_store_rax64(b, node->lhs->offset);
        }
        else slot_store_eax(b, node->lhs->offset);
        return;
      }
      // 间接写（引用 r / *p / a[i] / 结构体字段）：右值 eax/rax，弹 rdx，[rdx]=值
      // v0.9.2（S2 修复）：右值是地址类（指针变量/字符串/取址/ptr 字段读/ptr 返回 API/new/地址链）
      //   → 64 位写（旧实现恒 32 位，句柄/地址经字段/解引用写入即截断高 32 位）；int 值 → 32 位
      // v1.0.3（rsp≡0 纪律）：原「地址先入栈 → 求值 rhs」若 rhs 含 API 调用，压栈让 call 时
      //   rsp≡8 → movaps 类 API（CreateWindowExA/RegisterClassW）崩溃。改先求值 rhs 存帧底
      //   暂存槽（不压栈），再算目标地址、弹槽写入——所有 API 调用点 rsp≡0。
      // v1.2.4：double 间接目标（数组元素 / 结构体字段）→ 值先落帧底暂存槽（不压栈，跨 call 安全）、
      //   再算目标地址、xmm0 取回值、movsd [rdx]。绝不走 32 位整数写（那会只写半个 double = 静默错值）。
      // v1.2.5：double& 引用变量（槽里存地址）与 *p / a[i] / s.f 共用这条 SSE 间接写路径。
      // v1.3.0：**全局 double 变量**同样走这条（它是 ND_VAR 但 is_global —— 漏了它就会掉进
      //   下面的整数通路，用 32 位写只写半个 double = 静默错值。实测 `gd = gd2 * 2.0` 得 0）。
      //   与 gen_lvalue_addr 的 is_global 分支是同一族：**新增「ND_VAR 的第三种身份」时，
      //   凡按 kind/is_ref 判断目标类型的地方都要一起过一遍**。
      if ((node->lhs->kind == ND_DEREF || (node->lhs->kind == ND_VAR && (node->lhs->is_ref || node->lhs->is_global)))
          && node->lhs->ty == TY_DOUBLE) {
        gen_expr(c, node->rhs);                  // xmm0 = 右值（parse 已保证是 double）
        slot_store_dbl(b, c->scratch_off);   // 暂存（8 字节）
        gen_lvalue_addr(c, node->lhs);           // rax = 目标地址
        emit_mov_rdx_rax(b);                     // rdx = 目标地址
        slot_load_dbl(b, c->scratch_off);    // xmm0 = 右值
        emit_store_dbl_at_rdx(b);                // movsd [rdx],xmm0
        return;
      }
      // v1.0.13 T1 ③④：间接目标的宽度门槛（不静默截断）
      if ((node->lhs->ty == TY_INT || node->lhs->ty == TY_CHAR) && is_addr_value(node->rhs))
        error_at_node(node, "地址值是 64 位，装不进 4 字节的 int / 1 字节的 char 目标"
                            "（数组元素、结构体 int/char 字段、解引用都只有这么宽）"
                            "——请把目标声明成 int *（或先存进一个 int * 变量再整体赋值）");
      if (node->lhs->kind == ND_DEREF && node->lhs->ty == TY_PTR) check_ptr_target(node, node->rhs);
      gen_expr(c, node->rhs);                 // eax/rax = 右值（内部 call 对齐）
      // v1.7.0：int_64 间接目标兜一道符号扩展（parse 已保证右侧是 64 位值或 ND_I2L；
      //   这里再守一次，保证写进内存的高 32 位永远是确定值，不留栈残渣）
      if (node->lhs->ty == TY_INT64 && !is64_value(node->rhs)) emit_movsxd_rax_eax(b);
      slot_store_rax64(b, c->scratch_off);    // [rbp-scratch] = rax（值暂存）
      gen_lvalue_addr(c, node->lhs);          // rax = 目标地址（无 call 跨越，安全）
      emit_push_rax(b);
      emit_pop_rdx(b);                        // rdx = 目标地址
      slot_load_rax64(b, c->scratch_off);     // rax = 值
      // v1.0.4.1 写宽判定补漏（S2 家族）：仅随 rhs 地址类会漏「ptr 字段清零/赋整数字面量」——
      // `wc.cur = 0`（rhs 非地址类 → 32 位写）只清低 4 字节，高 4 字节残留栈上旧值
      // （0x00007ffc…DLL 返回地址残渣）→ RegisterClassA 读 hCursor=0x7ffc00000000 巨值
      // err 87（大帧换栈位置即现，v1.0.4 撞墙；小帧残留恰 0 侥幸掩盖）。
      // 判定：rhs 地址类 或 目标本身是指针字段（ND_DEREF.ty==TY_PTR）→ 64 位写。
      // v1.7.0：+ 目标本身是 int_64（数组元素/结构体字段/*p）→ 必须 64 位写（32 位写 = 只写低半）
      bool wide = is_addr_expr(node->rhs) ||
                  (node->lhs->kind == ND_DEREF && node->lhs->ty == TY_PTR) ||
                  node->lhs->ty == TY_INT64;
      if (node->lhs->kind == ND_DEREF && node->lhs->ty == TY_CHAR) {
        emit_store_byte_at_rdx(b);   // v1.0.5：char 目标（字段/元素/char*）88 02 字节写（不碰邻字节）
        emit_movzx_eax_al(b);        // v1.0.6.2 A2：表达式值截断=存储字节（88 写后 eax 高 24 位残留运算结果）
      }
      else if (wide) emit_store_rax_at_rdx(b);   // 48 89 02
      else emit_store_eax_at_edx(b);        // 89 02；eax 保持新值 = 表达式值
      return;
    }
    case ND_FUNC_ADDR: {   // v0.9.3：&函数名 → 函数代码地址（lea rax,[rip+disp32]，布局后回填）
      const uint8_t lea[] = {0x48, 0x8D, 0x05};
      buf_bytes(b, lea, 3);
      note_funcaddr(c, node->func_index);
      buf_u32(b, 0);       // 占位 disp（codegen_main 布局后回填）
      return;
    }
    case ND_ADDR: gen_lvalue_addr(c, node->lhs); return;
    case ND_REF_BIND:
      // 引用声明绑定：r 槽 = x 的地址（64 位写槽；不走引用写）
      gen_lvalue_addr(c, node->rhs);
      slot_store_rax64(b, node->lhs->offset);
      return;
    // 复合赋值 x op= e：右值→ecx，读 x→eax，运算，写回；eax 留新值
    // 间接左值（引用/*p/a[i]）：地址先入栈（除法 cdq 清 edx，需保护）
    case ND_ADD_ASSIGN: case ND_SUB_ASSIGN: case ND_MUL_ASSIGN:
    case ND_DIV_ASSIGN: case ND_MOD_ASSIGN:
    case ND_AND_ASSIGN: case ND_OR_ASSIGN: case ND_XOR_ASSIGN:
    case ND_SHL_ASSIGN: case ND_SHR_ASSIGN: {
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      bool lvchar = lv_is_char(node->lhs);   // v1.0.5：char 左值读 movzx/写字节（防邻字节污染）
      // v1.2.4：double 左值复合赋值 d += 1.0（值走 xmm0/xmm1，与整数路径完全分开；
      //   parse 已保证只有 += -= *= /= 走到这里）。顺序：xmm0 = 左值、xmm1 = 右值 → 运算 → 写回
      //   （非交换的 - / 依赖这个顺序：subsd xmm0,xmm1 = 左值 - 右值）。
      if (expr_is_dbl(node->lhs)) {
        char op = node->kind == ND_ADD_ASSIGN ? '+' : node->kind == ND_SUB_ASSIGN ? '-'
                : node->kind == ND_MUL_ASSIGN ? '*' : '/';
        if (node->kind != ND_ADD_ASSIGN && node->kind != ND_SUB_ASSIGN
            && node->kind != ND_MUL_ASSIGN && node->kind != ND_DIV_ASSIGN)
          error("内部错误：double 复合赋值只支持 += -= *= /=（parse 应已拦下）");
        if (direct) {
          gen_expr(c, node->rhs);                      // xmm0 = 右值
          emit_movapd_xmm1_xmm0(b);                    // xmm1 = 右值
          slot_load_dbl(b, node->lhs->offset);     // xmm0 = 左值（只写 xmm0，不动 xmm1）
          emit_sse_binop(b, op);                       // xmm0 = 左值 op 右值
          slot_store_dbl(b, node->lhs->offset);
        } else {
          gen_lvalue_addr(c, node->lhs);               // rax = 目标地址
          emit_push_rax(b);                            // 保地址（右值求值可能含 call）
          gen_expr(c, node->rhs);                      // xmm0 = 右值
          emit_movapd_xmm1_xmm0(b);                    // xmm1 = 右值
          emit_pop_rdx(b);                             // rdx = 目标地址（pop 不动 SSE）
          emit_load_dbl_at_rdx(b);                     // xmm0 = 左值
          emit_sse_binop(b, op);
          emit_store_dbl_at_rdx(b);                    // [rdx] = 新值
        }
        return;
      }
      // v0.9：指针变量 p += n / p -= n → 全 64 位（读槽 64 + add/sub 64 + 写槽 64）
      bool ptr_direct = direct && node->lhs->ty == TY_PTR &&
                        (node->kind == ND_ADD_ASSIGN || node->kind == ND_SUB_ASSIGN);
      if (ptr_direct) {
        gen_expr(c, node->rhs);
        // v1.0.6.2 盲区审计 A7：p += n 的 n 若 int（负量如 p += -2）须符号扩展——原 mov rcx,rax
        // 零扩展 32 位负值成 0xFFFFFFF8 巨大正数 → p 指向巨地址（同族 bug：gen_binop wide 已修）
        if (is_addr_expr(node->rhs)) emit_mov_rcx_rax(b);   // rhs 地址类（罕见）64 位完整
        else emit_movsxd_rcx_eax(b);                        // n int → 符号扩展
        slot_load_rax64(b, node->lhs->offset);  // rax = p（64 位地址）
        if (node->kind == ND_ADD_ASSIGN) emit_add64(b);
        else emit_sub64(b);
        slot_store_rax64(b, node->lhs->offset); // p = 新地址
        return;
      }
      if (!direct) {
        gen_lvalue_addr(c, node->lhs);   // eax = 目标地址
        emit_push_rax(b);
        gen_expr(c, node->rhs);
        emit_mov_ecx_eax(b);             // ecx = 右值（移位复合：cl = 移位量）
        emit_pop_rdx(b);                 // rdx = 目标地址
        if (lvchar) emit_load_byte_at_rdx(b);  // v1.0.5：char 旧值 = movzx 字节
        else emit_load_eax_at_edx(b);         // eax = 旧值
        emit_push_rdx(b);                // 除法前保护地址
        switch (node->kind) {
          case ND_ADD_ASSIGN: emit_add(b); break;
          case ND_SUB_ASSIGN: emit_sub(b); break;
          case ND_MUL_ASSIGN: emit_imul(b); break;
          case ND_DIV_ASSIGN: emit_cdq(b); emit_idiv(b); break;
          case ND_MOD_ASSIGN: emit_cdq(b); emit_idiv(b); emit_mov_eax_edx(b); break;
          case ND_AND_ASSIGN: emit_and(b); break;
          case ND_OR_ASSIGN: emit_or(b); break;
          case ND_XOR_ASSIGN: emit_xor(b); break;
          case ND_SHL_ASSIGN: emit_shl(b); break;
          case ND_SHR_ASSIGN: emit_sar(b); break;
          default: break;
        }
        emit_pop_rdx(b);                 // 恢复地址
        if (lvchar) { emit_store_byte_at_rdx(b); emit_movzx_eax_al(b); } // v1.0.5：char 写回=字节（v1.0.6.2 A2：表达式值截断=存储字节）
        // v1.3.0 全局 int：**必须 64 位写回**，与全局 int 的 64 位读配对。
        //   🐞 这里踩过一次真坑（实测）：全局读用 `48 8B 05`（64 位）、写却用 `89 02`（32 位）
        //   → .data 槽高 4 字节保留**初值**；初值为 0 时侥幸对，初值非 0（如另一个全局给了 7）
        //   就被 64 位读回高位残渣 → `gsum += n` 静默加错值（实测 3+4 变 7）。宽度不配对必错。
        //   ⚠️ 与「局部 int 走 32 位读改写」不冲突：局部槽的高位由 T1 机制另管，全局槽归这条口径。
        else if (node->lhs->is_global) {
          if (!is_addr_value(node->rhs)) emit_movsxd_rax_eax(b);   // 普通 int 值符号扩展后写满
          slot_store_rax64(b, c->scratch_off);                     // 落到暂存槽，再整体 64 位写回内存
          gen_lvalue_addr(c, node->lhs);                           // rax = 目标地址（重算，值已安全落槽）
          emit_mov_rdx_rax(b);
          slot_load_rax64(b, c->scratch_off);
          emit_store_rax_at_rdx(b);                                // mov [rdx],rax
        }
        else emit_store_eax_at_edx(b);        // 写回；eax = 新值
        return;
      }
      gen_expr(c, node->rhs);
      emit_mov_ecx_eax(b);              // ecx = 右值
      // v1.3.0：全局变量走**间接**通路（direct=false），但全局 int 的宽度约定是 64 位读写配对；
      //   间接通路用的是 32 位读改写（只动低 4 字节，高位保持初值 0 → 仍是自洽的）。
      //   ⚠️ 别在这里补 64 位版本：高 4 字节若是「写入时零扩展过的旧值」，读-改-写只碰低 4 字节是对的。
      if (lvchar) slot_load_byte(b, node->lhs->offset);  // v1.0.5：char 左值 movzx 读
      else slot_load_eax(b, node->lhs->offset); // eax = 左值 x
      switch (node->kind) {
        case ND_ADD_ASSIGN: emit_add(b); break;
        case ND_SUB_ASSIGN: emit_sub(b); break;
        case ND_MUL_ASSIGN: emit_imul(b); break;
        case ND_DIV_ASSIGN: emit_cdq(b); emit_idiv(b); break;
        case ND_MOD_ASSIGN: emit_cdq(b); emit_idiv(b); emit_mov_eax_edx(b); break;
        case ND_AND_ASSIGN: emit_and(b); break;
        case ND_OR_ASSIGN: emit_or(b); break;
        case ND_XOR_ASSIGN: emit_xor(b); break;
        case ND_SHL_ASSIGN: emit_shl(b); break;
        case ND_SHR_ASSIGN: emit_sar(b); break;
        default: break;
      }
      if (lvchar) { slot_store_byte(b, node->lhs->offset); emit_movzx_eax_al(b); } // v1.0.5：char 写回=字节（v1.0.6.2 A2：表达式值截断=存储字节）
      else slot_store_eax(b, node->lhs->offset); // x = 新值；eax 即新值 = 表达式值
      return;
    }
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV: case ND_MOD:
    case ND_BITAND: case ND_BITOR: case ND_BITXOR: case ND_SHL: case ND_SHR:
      // v1.1.0：任一操作数是 double → 走 SSE 通路（+ - * /；% 已被 parse 拦掉）
      if (expr_is_dbl(node->lhs) || expr_is_dbl(node->rhs)) {
        gen_dbl_binop(c, node, node->kind == ND_ADD ? '+' : node->kind == ND_SUB ? '-'
                          : node->kind == ND_MUL ? '*' : '/');
        return;
      }
      gen_binop(c, node); return;
    case ND_POW: gen_pow(c, node); return;   // v1.0.11 幂（快速幂发射器）
    case ND_NEG:
      // v1.1.0：double 取负 = 翻符号位（统一走 gen_dbl_neg，别在这里重复实现一份）
      if (expr_is_dbl(node->lhs)) { gen_dbl_neg(c, node); return; }
      gen_expr(c, node->lhs);
      // v1.7.0：int_64 取负 = neg rax（48 F7 D8）；int 仍是 32 位 neg eax
      if (expr_is_i64(node->lhs)) emit_neg64(b); else emit_neg(b);
      return;
    // v1.3.1：三元——条件判真后**只生成被选中的那一支**（C 语义；不选的那支不求值）
    case ND_TERN: {
      int else_l = new_label(c), end = new_label(c);
      if (!try_gen_cmp_branch(c, node->lhs, true, else_l)) {   // v1.4.9① 比较塌缩（条件为假 → 跳 else）
        gen_expr(c, node->lhs);
        if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
        emit_jcc_label(c, 0x84, else_l);   // je else
      }
      gen_expr(c, node->rhs);            // 真分支（double 时结果天然落 xmm0）
      emit_jmp_label(c, end);
      emit_label(c, else_l);
      gen_expr(c, node->els);            // 假分支
      emit_label(c, end);
      return;
    }
    case ND_CALL: gen_call(c, node); return;
    case ND_APICALL:
      gen_apicall(c, node);   // v0.8
      // v1.1.0：double 返回的 API 结果天然在 xmm0（值语义），无需搬运——见 expr_is_dbl 的 ND_APICALL 分支
      return;
    case ND_SHARED_ACQUIRE: {
      // v0.9 share 拷贝初始化：q 槽 = p 值；[p-8] refcount++（共享所有权）
      Buf *b = &c->code;
      gen_expr(c, node->rhs);              // rax = p（share 变量值 = 负载地址）
      emit_push_rax(b);                    // 暂存 p
      emit_sub_rax8(b);                    // rax = p-8（块基址）
      emit_mov_rdx_rax(b);                 // rdx = base
      emit_load_eax_at_edx(b);             // eax = refcount
      emit_inc_eax(b);                     // ++
      emit_store_eax_at_edx(b);            // [base] = 新计数
      emit_pop_rax(b);                     // 恢复 p
      slot_store_rax64(b, node->lhs->offset); // q 槽 = p（64 位）
      return;
    }
    case ND_NEW: {   // v0.9：new int → 堆对象（头部 8B refcount + int 负载 8B；返回负载地址）
      // 内联为 4 字面量参数的 VirtualAlloc 调用（复用 gen_apicall 寄存器路径）
      Node a[4];
      memset(a, 0, sizeof(a));
      a[0].kind = ND_NUM; a[0].val = 0;              // lpAddress = NULL
      a[1].kind = ND_NUM; a[1].val = 16;             // 头部 8 + 负载 8
      a[2].kind = ND_NUM; a[2].val = 0x3000;         // MEM_COMMIT | MEM_RESERVE
      a[3].kind = ND_NUM; a[3].val = 4;              // PAGE_READWRITE
      for (int i = 0; i < 3; i++) a[i].next = &a[i + 1];
      Node fake;
      memset(&fake, 0, sizeof(fake));
      fake.kind = ND_APICALL;
      fake.api_index = node->api_index;              // 内置 VirtualAlloc 下标
      fake.nargs = 4;
      fake.rhs = &a[0];
      gen_apicall(c, &fake);                         // rax = 块基址
      // 分配失败（rax==0，64 位判真）→ 表达式值 0
      int ok = new_label(c), end = new_label(c);
      emit_test64(b);
      emit_jcc_label(c, 0x85, ok);                   // jne ok
      emit_mov_eax_imm(b, 0);
      emit_jmp_label(c, end);
      emit_label(c, ok);
      // 头部：refcount @ [base] = 1（share 引用计数地基；own 走出口整体释放）
      emit_mov_rdx_rax(b);                           // rdx = base
      emit_mov_eax_imm(b, 1);
      emit_store_eax_at_edx(b);                      // [base] = 1
      // 负载 = base + 8（own 清理回退：VirtualFree(p-8)）
      emit_lea_rax_rdx8(b);                          // rax = base+8
      emit_label(c, end);
      return;
    }
    // 前缀 ++x/--x：先改内存，值(新)进 eax
    // 间接目标（引用 r / *p / a[i]）：地址 → rdx，间接 inc/dec
    case ND_PRE_INC: {
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      // v1.0.6.1 审计 A1：指针变量 ++ = 64 位（值=新地址；原 32 位 inc/读 → 数据段指针截断崩）
      if (direct && node->lhs->ty == TY_PTR) {
        slot_load_rax64(b, node->lhs->offset);
        emit_inc_rax(b);
        slot_store_rax64(b, node->lhs->offset);
        return;
      }
      bool lvchar = lv_is_char(node->lhs);   // v1.0.5：char 字节自增（FE /0，不碰邻字节）
      if (direct) {
        if (lvchar) slot_inc_byte(b, node->lhs->offset);
        else slot_inc_mem(b, node->lhs->offset);
        if (lvchar) slot_load_byte(b, node->lhs->offset);
        else slot_load_eax(b, node->lhs->offset);
        return;
      }
      gen_lvalue_addr(c, node->lhs);   // eax = 目标地址
      emit_mov_rdx_rax(b);             // rdx = 地址
      // v1.3.0：全局 int —— 读用 64 位（`48 8B 05`），自增/自减也必须 64 位
      //   （间接通路原是 32 位 inc/dec + 32 位读回，对全局会只动低 4 字节、高位留残渣）
      if (node->lhs->is_global && !lvchar) {
        emit_load_rax_at_rdx(b);       // rax = 旧值（64 位，含高位）
        emit_inc_rax(b);
        emit_store_rax_at_rdx(b);      // [rdx] = 新值（64 位）
        return;                        // 表达式值 = 新值（在 rax）
      }
      if (lvchar) emit_inc_byte_at_edx(b);   // 目标++（字节）
      else emit_inc_mem_edx(b);             // 目标++
      if (lvchar) emit_load_byte_at_rdx(b);  // eax = 新值（movzx）
      else emit_load_eax_at_edx(b);         // eax = 新值
      return;
    }
    case ND_PRE_DEC: {
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      // v1.0.6.1 审计 A1：指针变量 -- = 64 位
      if (direct && node->lhs->ty == TY_PTR) {
        slot_load_rax64(b, node->lhs->offset);
        emit_dec_rax(b);
        slot_store_rax64(b, node->lhs->offset);
        return;
      }
      bool lvchar = lv_is_char(node->lhs);   // v1.0.5：char 字节自减（FE /1）
      if (direct) {
        if (lvchar) slot_dec_byte(b, node->lhs->offset);
        else slot_dec_mem(b, node->lhs->offset);
        if (lvchar) slot_load_byte(b, node->lhs->offset);
        else slot_load_eax(b, node->lhs->offset);
        return;
      }
      gen_lvalue_addr(c, node->lhs);
      emit_mov_rdx_rax(b);
      // v1.3.0：全局 int —— 64 位自减（同 ND_PRE_INC 的口径）
      if (node->lhs->is_global && !lvchar) {
        emit_load_rax_at_rdx(b);
        emit_dec_rax(b);
        emit_store_rax_at_rdx(b);
        return;
      }
      if (lvchar) emit_dec_byte_at_edx(b);
      else emit_dec_mem_edx(b);
      if (lvchar) emit_load_byte_at_rdx(b);
      else emit_load_eax_at_edx(b);
      return;
    }
    // 后缀 x++/x--：值(旧)先进 eax，再改内存（旧值保留的关键：先读后改）
    case ND_POST_INC: {
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      // v1.0.6.1 审计 A1：指针变量 x++ = 64 位（值=旧地址，槽+1）
      if (direct && node->lhs->ty == TY_PTR) {
        slot_load_rax64(b, node->lhs->offset);  // rax = 旧地址
        emit_push_rax(b);
        slot_load_rax64(b, node->lhs->offset);
        emit_inc_rax(b);
        slot_store_rax64(b, node->lhs->offset);
        emit_pop_rax(b);                         // rax = 旧地址（表达式值）
        return;
      }
      bool lvchar = lv_is_char(node->lhs);
      if (direct) {
        if (lvchar) slot_load_byte(b, node->lhs->offset);   // eax = 旧值（movzx）
        else slot_load_eax(b, node->lhs->offset);
        if (lvchar) slot_inc_byte(b, node->lhs->offset);
        else slot_inc_mem(b, node->lhs->offset);
        return;
      }
      gen_lvalue_addr(c, node->lhs);
      emit_mov_rdx_rax(b);
      // v1.3.0：全局 int —— 64 位读改写；表达式值 = 旧值。
      //   ⚠️ 旧值必须先落帧底暂存槽：下面重算地址（gen_lvalue_addr）会把 rax 冲掉，
      //     而 rax 正是要返回的旧值（这是后缀运算特有的顺序坑，前缀不需要）。
      if (node->lhs->is_global && !lvchar) {
        emit_load_rax_at_rdx(b);                  // rax = 旧值（64 位）
        slot_store_rax64(b, c->scratch_off);      // 暂存旧值
        emit_inc_rax_at_rdx(b);                   // [rdx]++（64 位）
        gen_lvalue_addr(c, node->lhs);            // rax = 地址（重算，安全）
        slot_load_rax64(b, c->scratch_off);       // rax = 旧值（表达式值）
        return;
      }
      if (lvchar) emit_load_byte_at_rdx(b);   // eax = 旧值（movzx）
      else emit_load_eax_at_edx(b);   // eax = 旧值
      if (lvchar) emit_inc_byte_at_edx(b);
      else emit_inc_mem_edx(b);
      return;
    }
    case ND_POST_DEC: {
      bool direct = is_direct_var(node->lhs);   // v1.3.0：全局变量不走直接帧槽，转间接通路
      // v1.0.6.1 审计 A1：指针变量 x-- = 64 位
      if (direct && node->lhs->ty == TY_PTR) {
        slot_load_rax64(b, node->lhs->offset);
        emit_push_rax(b);
        slot_load_rax64(b, node->lhs->offset);
        emit_dec_rax(b);
        slot_store_rax64(b, node->lhs->offset);
        emit_pop_rax(b);
        return;
      }
      bool lvchar = lv_is_char(node->lhs);
      if (direct) {
        if (lvchar) slot_load_byte(b, node->lhs->offset);
        else slot_load_eax(b, node->lhs->offset);
        if (lvchar) slot_dec_byte(b, node->lhs->offset);
        else slot_dec_mem(b, node->lhs->offset);
        return;
      }
      gen_lvalue_addr(c, node->lhs);
      emit_mov_rdx_rax(b);
      // v1.3.0：全局 int —— 64 位读改写；表达式值 = 旧值（同 ND_POST_INC 的暂存顺序坑）
      if (node->lhs->is_global && !lvchar) {
        emit_load_rax_at_rdx(b);
        slot_store_rax64(b, c->scratch_off);
        emit_dec_rax_at_rdx(b);                   // [rdx]--（64 位）
        gen_lvalue_addr(c, node->lhs);
        slot_load_rax64(b, c->scratch_off);
        return;
      }
      if (lvchar) emit_load_byte_at_rdx(b);
      else emit_load_eax_at_edx(b);
      if (lvchar) emit_dec_byte_at_edx(b);
      else emit_dec_mem_edx(b);
      return;
    }
    case ND_EQ: case ND_NE: case ND_LT: case ND_LE: case ND_GT: case ND_GE:
      // v1.1.0：double 比较走 ucomisd（无符号条件码 + p 变体处理 NaN：x==x 为假，与 C 一致）
      if (expr_is_dbl(node->lhs) || expr_is_dbl(node->rhs)) { gen_dbl_cmp(c, node); return; }
      gen_cmp(c, node); return;
    case ND_LOGAND: gen_logand(c, node); return;
    case ND_LOGOR: gen_logor(c, node); return;
    case ND_NOT:
      gen_expr(c, node->lhs);
      if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
      emit_setcc(b, 0x94); // sete：eax==0 → 1
      emit_movzx_eax_al(b);
      return;
    case ND_BITNOT:   // v0.7.2：~x = not eax；v1.7.0：int_64 → not rax（48 F7 D0）
      gen_expr(c, node->lhs);
      if (expr_is_i64(node->lhs)) emit_not64(b); else emit_not(b);
      return;
    default:
      fprintf(stderr, "FLINT: 内部错误：表达式出现语句节点（kind=%d）\n", (int)node->kind);
      exit(1);
  }
}

// ===== v1.4.11（`-debug`）：语句级「源行 → 发射字节区间」记录 =====
// 设计纪律（`开工简报-可审计发射层.md` §5）：
//   · **纯加法**：只在发射前后各取一次 `c->code.len`，不改任何一条指令的发射；
//   · **只管叶子语句**：容器语句（块 / if / while / for / switch）自身不记，让里面的语句各自记 ——
//     这样行表里每个地址只出现一次、天然非递减（DWARF 要求同一 sequence 内地址升序）；
//   · **没发字节的语句不记**（否则同一地址出现两行）；
//   · 控制语句的**条件字节**：v1.4.16 起**自己单独记一条**（行取条件表达式的行）——
//     过去它落在「上一条记录」里（行表语义是"从该地址起行号 = X"，不是逐字节归属），
//     于是调试器把 `if (a < b)` 的 `cmp` 算成上一条语句的代码（实测见 test\verify-all.ps1 的 gate 项）。
static bool dbg_is_container(NodeKind k) {
  return k == ND_BLOCK || k == ND_IF || k == ND_WHILE || k == ND_FOR || k == ND_SWITCH;
}

// v1.4.16（任务卡 T-20260918-012105）：把 [start,end) 记成一条「源行 → 发射字节区间」记录。
//   零长度不记（否则同一地址出现两行）；file/line 取自传入节点（条件记条件表达式自己的行）。
static void dbg_record(FuncCtx *c, Node *node, size_t start, size_t end) {
  if (!flint_debug_info || end <= start) return;
  if (c->ndbg == c->dbg_cap) {
    size_t cap = c->dbg_cap ? c->dbg_cap * 2 : 64;
    DebugRow *p = realloc(c->dbg, cap * sizeof(DebugRow));
    if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
    c->dbg = p;
    c->dbg_cap = cap;
  }
  c->dbg[c->ndbg].file = node->file;
  c->dbg[c->ndbg].line = node->line > 0 ? node->line : 1;
  c->dbg[c->ndbg].off = start;
  c->dbg[c->ndbg].len = end - start;
  c->ndbg++;
}

static void gen_stmt_inner(FuncCtx *c, Node *node);

static void gen_stmt(FuncCtx *c, Node *node) {
  if (!flint_debug_info || dbg_is_container(node->kind)) { gen_stmt_inner(c, node); return; }
  size_t start = c->code.len;
  gen_stmt_inner(c, node);
  dbg_record(c, node, start, c->code.len);
}

static void gen_stmt_inner(FuncCtx *c, Node *node) {
  Buf *b = &c->code;
  switch (node->kind) {
    case ND_EXPR_STMT:
      // v1.4.24（M4 补一档）：表达式值**没人用** ⇒ 自反运算可以就地算（只对寄存器槽生效；
      //   内存槽照旧走原路径，字节一字不变）。理由见 slotmap.h 的"融合路径"注释。
      if (node->lhs && try_fused_self_stmt(c, node->lhs)) return;
      if (node->lhs) gen_expr(c, node->lhs);
      return;
    case ND_BLOCK:
      for (Node *s = node->rhs; s; s = s->next) gen_stmt(c, s);
      return;
    case ND_RETURN:
      if (node->lhs) {
        // v1.4.25（`-strict`）③：地址值（64 位）从 int 返回函数里返回 = 静默截断（T1 遗留边界②）
        //   ⚠️ main 除外：main 的返回值按语言定义就是退出码（int），"把指针字段当退出码"是
        //   探针类程序的常规写法，而 main 也没法声明成 int * —— 拦它只会制造无法执行的告警。
        if (flint_strict && !c->is_main && c->ret_ty == TY_INT && node->lhs->kind != ND_NUM
            && is_addr_value(node->lhs))
          error_at_node(node, "[E-STRICT-WIDTH] 地址值（64 位）从 int 返回函数里返回 ⇒ 高 32 位会被丢掉"
                              "（SPEC 记的 T1 遗留边界）。请把返回类型声明成 int *（-strict 诊断）");
        gen_expr(c, node->lhs);   // eax = 返回值（return; 无值）
        // v1.2.1 double 阶段2：double 返回函数 → 表达式求值后**结果已在 xmm0**（SSE 通路统一用 xmm0
        //   当累加器），什么都不用搬；原「落回 int 返回槽」的截断只对非 double 返回函数做。
        if (!c->ret_dbl && expr_is_dbl(node->lhs)) emit_cvttsd2si_eax_xmm0(b);
      }
      if (c->ret_char) emit_movzx_eax_al(b);   // 2026-09-09：char 值返回 → 截断到 0..255（SPEC 第 165 行）
      if (c->is_main) emit_mov_ecx_eax(b);     // main：ecx = ExitProcess 参数
      emit_jmp_label(c, c->exit_label_id);     // 跳本函数统一退出点
      return;
    case ND_IF: {
      int else_l = new_label(c), end = new_label(c);
      size_t cstart = c->code.len;   // v1.4.16：条件字节的起点（下面单独记一条行表记录）
      if (!try_gen_cmp_branch(c, node->lhs, true, else_l)) {   // v1.4.9① 比较塌缩（条件为假 → 跳 else）
        gen_expr(c, node->lhs);       // cond
        if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
        emit_jcc_label(c, 0x84, else_l); // je else
      }
      dbg_record(c, node->lhs, cstart, c->code.len);   // v1.4.16：条件（取条件表达式的行）
      gen_stmt(c, node->rhs);       // then
      emit_jmp_label(c, end);
      emit_label(c, else_l);
      if (node->els) gen_stmt(c, node->els);
      emit_label(c, end);
      return;
    }
    case ND_WHILE: {
      int loop = new_label(c), end = new_label(c);
      // v1.2.0：本循环上下文（continue 目标 = 条件判断处，while 语义）
      loop_push(c, end, loop);
      emit_label(c, loop);
      size_t cstart = c->code.len;   // v1.4.16：条件字节的起点
      if (!try_gen_cmp_branch(c, node->lhs, true, end)) {      // v1.4.9① 比较塌缩（条件为假 → 跳出循环）
        gen_expr(c, node->lhs);       // cond
        if (is64_value(node->lhs)) emit_test64(b); else emit_test(b);
        emit_jcc_label(c, 0x84, end); // je end
      }
      dbg_record(c, node->lhs, cstart, c->code.len);   // v1.4.16：条件（取条件表达式的行）
      gen_stmt(c, node->rhs);       // body
      emit_jmp_label(c, loop);
      emit_label(c, end);
      loop_pop(c);
      return;
    }
    case ND_FOR: {
      int loop = new_label(c), end = new_label(c);
      int cont = new_label(c);      // v1.2.0：continue 目标 = 增量之前（C 语义：先增量再判条件）
      loop_push(c, end, cont);
      if (node->init) gen_stmt(c, node->init);
      emit_label(c, loop);
      if (node->cond) {
        size_t cstart = c->code.len;   // v1.4.16：条件字节的起点
        if (!try_gen_cmp_branch(c, node->cond, true, end)) {   // v1.4.9① 比较塌缩（条件为假 → 跳出循环）
          gen_expr(c, node->cond);
          if (is64_value(node->cond)) emit_test64(b); else emit_test(b);
          emit_jcc_label(c, 0x84, end);
        }
        dbg_record(c, node->cond, cstart, c->code.len);   // v1.4.16：条件（取条件表达式的行）
      }
      gen_stmt(c, node->rhs);       // body
      emit_label(c, cont);          // ← continue 落点：跳过 body 剩余，但仍执行增量
      if (node->inc) gen_stmt(c, node->inc);
      emit_jmp_label(c, loop);
      emit_label(c, end);
      loop_pop(c);
      return;
    }
    // v1.3.1：switch —— 扁平链（case 标记 + 段内容为兄弟语句），C 语义：
    //   ① 先算条件一次，留在 eax，然后逐个 case 发 `cmp eax,常量` + `je 该段标签`（线性比较，v1.3.1 不做跳转表）；
    //   ② 全不中 → 跳 default 段（没有 default 就跳 end）；
    //   ③ 段体顺序展开，case 标记处落标签 ⇒ **段间贯穿**天然成立；break 已由 ND_BREAK 跳到 end。
    //   条件表达式即使是地址类（64 位 rax）也按 eax 比较——switch 只服务整型（parse 已拦 double）。
    case ND_SWITCH: {
      int end = new_label(c);
      loop_push_switch(c, end);
      size_t cstart = c->code.len;               // v1.4.16：switch 表达式也自己记一条
      gen_expr(c, node->lhs);                    // eax = 条件值
      dbg_record(c, node->lhs, cstart, c->code.len);   // v1.4.16：条件（取表达式的行）
      int dflt = -1;
      for (Node *cs = node->rhs; cs; cs = cs->next) {
        if (cs->kind != ND_CASE) continue;
        cs->label_id = new_label(c);             // 先给每段分配标签（回填机制要求先分配再引用）
        if (cs->is_default) { dflt = cs->label_id; continue; }
        emit_cmp_eax_imm(b, cs->val);
        emit_jcc_label(c, 0x84, cs->label_id);   // je 该段
      }
      emit_jmp_label(c, dflt >= 0 ? dflt : end);
      for (Node *s = node->rhs; s; s = s->next) {
        if (s->kind == ND_CASE) { emit_label(c, s->label_id); continue; }
        gen_stmt(c, s);
      }
      emit_label(c, end);
      loop_pop(c);
      return;
    }
    // v1.2.0：循环控制（C 语义，只管最内层；parser 已保证不在循环外）
    case ND_BREAK:
      emit_jmp_label(c, c->loops[c->nloops - 1].brk);
      return;
    // v1.3.1：continue 要跳过栈顶的 switch 段（switch 不是循环，continue 属于外层真循环）——
    //   从栈顶往下找第一个「真循环」上下文；parser 只在 loop_nest>0 时放行，故一定找得到。
    case ND_CONTINUE: {
      int i = c->nloops - 1;
      while (i >= 0 && c->loops[i].is_switch) i--;
      if (i < 0) {
        fprintf(stderr, "FLINT: 内部错误：continue 不在循环上下文（parser 应已拦截）\n");
        exit(1);
      }
      emit_jmp_label(c, c->loops[i].cont);
      return;
    }
    default:
      fprintf(stderr, "FLINT: 内部错误：语句出现表达式节点\n");
      exit(1);
  }
}

// ========== 单个函数生成 ==========
// v0.9：收集函数体内 own/share 指针变量槽（任意深度块/控制流，统一函数出口释放 MVP——
// 块级精确释放（嵌套块提前 return 路径）记已知边界；声明限函数顶层（parse 保证））
static void collect_managed_vars(Node *n, int *uniq, int *nuniq, int *sh, int *nsh, int cap) {
  if (!n) return;
  switch (n->kind) {
    case ND_EXPR_STMT: {
      Node *e = n->lhs;
      if (!e) return;
      // 声明初始化形态：ND_ASSIGN(ND_VAR(managed), rhs) ｜ ND_SHARED_ACQUIRE(ND_VAR(share), p)
      Node *lv = NULL;
      if (e->kind == ND_ASSIGN && e->lhs && e->lhs->kind == ND_VAR) lv = e->lhs;
      else if (e->kind == ND_SHARED_ACQUIRE && e->lhs && e->lhs->kind == ND_VAR) lv = e->lhs;
      if (lv && (lv->is_own || lv->is_share)) {
        if (lv->is_own) { if (*nuniq < cap) uniq[(*nuniq)++] = lv->offset; }
        else { if (*nsh < cap) sh[(*nsh)++] = lv->offset; }
      }
      return;
    }
    case ND_BLOCK:
      for (Node *s = n->rhs; s; s = s->next) collect_managed_vars(s, uniq, nuniq, sh, nsh, cap);
      return;
    case ND_IF:
      collect_managed_vars(n->rhs, uniq, nuniq, sh, nsh, cap);
      collect_managed_vars(n->els, uniq, nuniq, sh, nsh, cap);
      return;
    case ND_WHILE:
      collect_managed_vars(n->rhs, uniq, nuniq, sh, nsh, cap);
      return;
    case ND_FOR:
      collect_managed_vars(n->init, uniq, nuniq, sh, nsh, cap);   // for 头声明
      collect_managed_vars(n->rhs, uniq, nuniq, sh, nsh, cap);
      return;
    // v1.3.1：switch 段是扁平链（ND_CASE 只是标记，自身无子树）——walk 一遍链即可；
    //   三元是表达式（own/share 声明不会出现在这里），递归子节点只为不给将来的扩展留盲区。
    case ND_SWITCH:
      for (Node *s = n->rhs; s; s = s->next) collect_managed_vars(s, uniq, nuniq, sh, nsh, cap);
      return;
    case ND_TERN:
      collect_managed_vars(n->rhs, uniq, nuniq, sh, nsh, cap);
      collect_managed_vars(n->els, uniq, nuniq, sh, nsh, cap);
      return;
    default: return;
  }
}

static void codegen_func(FuncCtx *c, FuncDef *fn, Program *prog) {
  g_rspm = 8;   // v1.0.4.1：函数入口 rsp≡8（call 压入返回地址）；push rbp 后 ≡0
  // v1.4.21/23（M2/M4）：本函数的"槽 → 位置"表开工（清表 + 调用纪元/块号归零；属性由下面几处 declare 申报）
  //   code 传进去是因为 M4 的"块边界写回"要往这个缓冲里发 store。
  slotmap_begin_function(&c->code);
  // 帧：参数 + 局部变量槽，从 rbp-8 向下；≥32 保 shadow；16 对齐
  int frame = fn->var_count * 8;
  if (frame < 32) frame = 32;
  frame = (frame + 15) / 16 * 16;
  // v1.0.3：帧底部再留 8B 暂存槽——间接赋值（结构体字段/解引用/数组元素 = API 调用结果）
  // 先存槽再算目标地址，避免「地址压栈跨越 API 调用」把 call 时 rsp 顶成 ≡8
  // （CreateWindowExA/RegisterClassW 走 movaps 类指令即崩，决策 26 S3 纪律）。
  // 槽位于旧帧最底 8B 之下：offset = frame+8；保留区须重新 16 对齐（旧帧 ≡0 mod 16，
  // 直接 +8 会让 sub rsp 后 rsp≡8——每处 API 调用全错位，比不修更糟）
  c->scratch_off = frame + 8;
  frame = (frame + 8 + 15) / 16 * 16;

  emit_push_rbp(&c->code);
  emit_mov_rbp_rsp(&c->code);
  emit_stack_alloc(&c->code, frame);   // 决策 41：大帧逐页探测（>4KB 帧不再跳过守护页）

  // 参数装载：寄存器 → 本函数栈槽（main 无参数，parse 已保证）
  // v0.8：指针/引用形参槽里是地址 → 64 位落槽；int 值 → 32 位
  // v1.2.2：double 形参 → 从第 xi 个 XMM 寄存器 movsd 落槽；GP 侧按**整数参数序**计数
  //   （两套序列并行，纯 int 函数的 gi == i → 与旧产物完全一致）
  if (!fn->is_main) {
    int gi = 0, xi = 0;
    for (int i = 0; i < fn->nargs; i++) {
      // v1.4.21（M2）：形参槽申报进"槽 → 位置"表 —— 形参一律钉死内存（M4 条件 ③）
      slotmap_declare(fn->param_offsets[i], fn->param_ty[i],
                      SF_PARAM | (fn->param_ref[i] ? SF_REF : 0));
      // ===== v1.4.26：第 5 个形参起**不在寄存器里** —— 从调用者栈区读 =====
      //   规范：前 4 个按位置进 RCX/RDX/R8/R9 与 XMM0-3（两套序列并行），**第 5 个起一律落栈**。
      //   rbp+8 = 返回地址、+16..+47 = shadow ⇒ 第 i(i≥5) 个形参在 [rbp+48+(i-5)*8]。
      if (i >= 4) {
        int disp = 48 + (i - 4) * 8;
        bool wide2 = fn->param_ref[i] || fn->param_ty[i] == TY_PTR || fn->param_ty[i] == TY_FUNCPTR
                  || fn->param_ty[i] == TY_INT64;   // v1.7.0：int_64 栈参也整 64 位落槽
        if (fn->param_ty[i] == TY_DOUBLE) {
          emit_load_rbp_pos(&c->code, disp, 2);              // movsd xmm0,[rbp+disp]
          slot_store_dbl_xmm(&c->code, fn->param_offsets[i], 0);
        } else if (wide2) {
          emit_load_rbp_pos(&c->code, disp, 1);              // mov rax,[rbp+disp]
          slot_store_rax64(&c->code, fn->param_offsets[i]);
        } else {
          emit_load_rbp_pos(&c->code, disp, 0);              // mov eax,[rbp+disp]
          slot_store_eax(&c->code, fn->param_offsets[i]);
        }
        continue;
      }
      if (fn->param_ty[i] == TY_DOUBLE) {
        slot_store_dbl_xmm(&c->code, fn->param_offsets[i], xi);
        xi++;
        continue;
      }
      // v1.3.2：函数指针形参 = 地址 → 也要 64 位落槽（记 TY_INT 会截断成 32 位 = 静默传野地址）
      bool wide = fn->param_ref[i] || fn->param_ty[i] == TY_PTR || fn->param_ty[i] == TY_FUNCPTR
               || fn->param_ty[i] == TY_INT64;   // v1.7.0：int_64 值形参 → 64 位 GP 落槽
      switch (gi) {
        case 0:
          if (wide) slot_store_rcx64(&c->code, fn->param_offsets[i]);
          else slot_store_ecx(&c->code, fn->param_offsets[i]);
          break;
        case 1:
          if (wide) slot_store_rdx64(&c->code, fn->param_offsets[i]);
          else slot_store_edx(&c->code, fn->param_offsets[i]);
          break;
        case 2:
          if (wide) slot_store_r8_64(&c->code, fn->param_offsets[i]);
          else slot_store_r8d(&c->code, fn->param_offsets[i]);
          break;
        case 3:
          if (wide) slot_store_r9_64(&c->code, fn->param_offsets[i]);
          else slot_store_r9d(&c->code, fn->param_offsets[i]);
          break;
      }
      gi++;
    }
  }

  // v0.9：收集 own/share 指针（函数出口统一释放）+ 槽入口清零
  // （清零防线：声明前提前 return 时槽为 0 → 出口清理跳过，防 free 垃圾地址）
  int *uoffs = NULL, *soffs = NULL;
  int nown = 0, nshare = 0;
  if (fn->var_count > 0) {
    uoffs = xmalloc((size_t)fn->var_count * sizeof(int));
    soffs = xmalloc((size_t)fn->var_count * sizeof(int));
    collect_managed_vars(fn->body, uoffs, &nown, soffs, &nshare, fn->var_count);
    // v1.4.21（M2）：own/share 托管槽申报（出口要释放 ⇒ 一律钉死内存，M4 条件 ③）
    for (int i = 0; i < nown; i++)   slotmap_declare(uoffs[i], TY_PTR, SF_MANAGED);
    for (int i = 0; i < nshare; i++) slotmap_declare(soffs[i], TY_PTR, SF_MANAGED);
    for (int i = 0; i < nown; i++) {
      emit_mov_eax_imm(&c->code, 0);
      slot_store_rax64(&c->code, uoffs[i]);   // 槽 = 0
    }
    for (int i = 0; i < nshare; i++) {
      emit_mov_eax_imm(&c->code, 0);
      slot_store_rax64(&c->code, soffs[i]);   // 槽 = 0
    }
  }

  // 本函数统一退出点：id 必须先分配（body 里 return 要跳它），位置在 body 生成后标记
  c->exit_label_id = new_label(c);

  // v1.0.13 T1：先算「装地址的 int」标记（定点收敛，最多 8 轮），body 生成时据此定存取宽度
  c->prog = prog;              // v1.4.25：-strict 在调用点要查被调函数的形参类型
  c->ret_ty = fn->ret_ty;      // v1.4.25：-strict 判"地址值经 int 返回被截断"
  g_nai = 0;
  for (int it = 0; it < 8; it++) if (!ai_pass(fn->body)) break;

  // v1.4.21（M2）：把本函数所有变量槽与其属性申报给映射层。
  //   ⚠️ 必须在 ai_pass 之后 —— T1「装地址的 int」标记此时才确定（要记 SF_T1ADDR）。
  //   ⚠️ 申报由**生成层**做（它认识 AST），映射层只存（slotmap.c 里不许出现 AST 字样）。
  slotmap_declare(c->scratch_off, TY_INT, SF_SCRATCH);
  slotmap_declare_ast(fn->body);

  // v1.4.23（M4）：寄存器分配第一档 —— 计划在做完申报之后、发射函数体之前定下来。
  //   分配到的寄存器在这里 push（序言），收尾处**逆序** pop；范围与口径全部由映射层决定，本层只按号保存/恢复。
  //   M5 ②（v1.4.27）：**条件⑤ 已放开** —— 带调用的函数也分配（callee-saved 跨调用天然安全）。
  //     代价是**调用点的 rsp 对齐**要自己兜：进函数 rsp≡8，push rbp 后 ≡0，帧是 16 的倍数，
  //     再 push nreg 个 callee-saved ⇒ nreg 为奇数时 rsp≡8 ⇒ 补 8 字节垫把 call 点拉回 ≡0
  //     （否则变成"每个调用点各自临时垫"，产物会大一圈；这也是首次尝试踩过的坑：那次 boot 门红 183/27
  //     真因不在垫平，而在映射层"发射中途降级"——见 slotmap.c 的位置纪律）。
  int saved_regs[8];
  int nreg = slotmap_plan_regs((ast_has_call(fn->body) || nown + nshare > 0) ? 1 : 0);
  if (nreg > 0) nreg = slotmap_regs_allocated(saved_regs, 8);
  for (int i = 0; i < nreg; i++) emit_push_saved_reg(&c->code, saved_regs[i]);
  int reg_pad = (nreg % 2) ? 8 : 0;   // 奇数个 push ⇒ 补 8 字节垫，函数内每个 call 点恒 ≡0
  if (reg_pad) emit_sub_rsp(&c->code, reg_pad);

  flint_stats_func_begin(fn->name);   // v1.4.19：本函数统计起点（-stats）
  size_t st_len0 = c->code.len;
  // 函数体（顶层语句链表）
  for (Node *s = fn->body; s; s = s->next) gen_stmt(c, s);
  flint_stats_func_end(c->code.len - st_len0);   // 统计收口（只算函数体这一段）

  // 自然流到末尾 = 隐式返回 0
  // v1.2.1：double 返回函数的隐式返回值 = **显式回填 xmm0 = 0.0**。
  //   ⚠️ 别想当然「xmm0 这时候恰好是 0」——首版就是这么删掉 `mov eax,0` 的，实测炸在：
  //   `double maybe(int x){ if (x==1) return 1.5; }` 里 xmm0 留着 `x == 1` 比较的操作数
  //   （maybe(2) 时 = 2.0）→ `maybe(2) == 0.0` 判假（静默错值）；而"直接打印"那条路径
  //   因为紧接着 cvttsd2si 覆盖了标志位，看起来又是对的——**同一个错值在不同上下文两种表现**。
  //   0.0 从常量区取（note_dblref/note_dbluse 自己排布 + 回填，重复登记自动去重）。
  if (!fn->ret_void && c->ret_dbl) {
    size_t zidx = note_dblref(c, 0.0);
    const uint8_t movsd0[] = {0xF2, 0x0F, 0x10, 0x05};   // movsd xmm0,[rip+disp32]
    buf_bytes(&c->code, movsd0, 4);
    note_dbluse(c, zidx, c->code.len);
    buf_u32(&c->code, 0);                                // 占位（常量区排布后回填）
  }
  if (!fn->ret_void && !c->ret_dbl) {
    emit_mov_eax_imm(&c->code, 0);
    if (fn->is_main) emit_mov_ecx_eax(&c->code); // main：ExitProcess 参数
  }

  // 统一退出点收尾
  emit_label(c, c->exit_label_id);

  // v0.9 own/share 自动释放（统一函数出口；保护返回值：main 的 ExitProcess 参数在
  // ecx、普通函数返回值在 eax——清理调用会破坏）。own = 直接 free(p-8)；
  // share = [p-8] refcount--，归零才 free。
  if (nown + nshare > 0) {
    if (fn->is_main) emit_push_rcx(&c->code);
    else emit_push_rax(&c->code);
    // own：直接释放
    for (int i = 0; i < nown; i++) {
      int skip = new_label(c);
      slot_load_rax64(&c->code, uoffs[i]);   // rax = p
      emit_test64(&c->code);
      emit_jcc_label(c, 0x84, skip);         // je skip（p==0）
      emit_sub_rax8(&c->code);               // base = p - 8（头部）
      emit_virtual_free(c, prog->api_free);  // VirtualFree(base, 0, MEM_RELEASE)
      emit_label(c, skip);
    }
    // share：refcount--，归零才释放
    for (int i = 0; i < nshare; i++) {
      int skip = new_label(c);
      slot_load_rax64(&c->code, soffs[i]);   // rax = p
      emit_test64(&c->code);
      emit_jcc_label(c, 0x84, skip);         // je skip（p==0）
      emit_sub_rax8(&c->code);               // base = p - 8
      emit_mov_rdx_rax(&c->code);            // rdx = base
      emit_load_eax_at_edx(&c->code);        // eax = refcount
      emit_dec_eax(&c->code);                // refcount--
      emit_store_eax_at_edx(&c->code);       // [base] = 新计数
      emit_test(&c->code);                   // 32 位判零
      emit_jcc_label(c, 0x85, skip);         // jne skip（仍有引用 → 不释放）
      emit_mov_rax_rdx(&c->code);            // rax = base
      emit_virtual_free(c, prog->api_free);
      emit_label(c, skip);
    }
    if (fn->is_main) emit_pop_rcx(&c->code);
    else emit_pop_rax(&c->code);
  }

  // v1.4.23（M4）：收尾两件事，次序不能反 ——
  //   ① 先把寄存器里的权威值写回内存（`slotmap_flush_all`）；② 再逆序 pop 出序言 push 的寄存器。
  //   （写回用的是那些寄存器，所以必须在 pop 之前。）
  slotmap_flush_all();
  if (reg_pad) emit_add_rsp(&c->code, reg_pad);
  for (int i = nreg - 1; i >= 0; i--) emit_pop_saved_reg(&c->code, saved_regs[i]);

  if (fn->is_main) {
    size_t disp_off = 0;
    emit_call_iat(&c->code, &disp_off); // call ExitProcess（不返回）
    c->disp_off = disp_off;
  } else {
    emit_leave(&c->code); // mov rsp,rbp; pop rbp
    emit_ret(&c->code);   // 返回 caller（返回值 eax）
  }

  free(uoffs);
  free(soffs);

  g_nai = 0;   // v1.0.13 T1：标记是函数内概念，出函数即清（槽偏移跨函数会撞号）

  // 回填本函数内跳转
  resolve_patches(c);
}

// ========== 程序整体 ==========
// 布局：main 的 code 放最前（PE 入口 = code 开头，pe.c 零改动），其余按源序随后；
// 函数间 call 在布局确定后二次回填；各函数 code 依次拼接成一块返回。
GenResult codegen_main(Program prog) {
  int n = prog.nfuncs;
  int *order = xmalloc((size_t)n * sizeof(int));       // ctx 序 → func 下标
  int *ctx_of_func = xmalloc((size_t)n * sizeof(int)); // func 下标 → ctx 序
  size_t *offsets = xmalloc((size_t)n * sizeof(size_t));
  FuncCtx *ctxs = xcalloc((size_t)n, sizeof(FuncCtx));

  // 生成顺序：main 第一个，其余按源序
  int k = 0;
  order[k++] = prog.main_index;
  for (int i = 0; i < n; i++)
    if (i != prog.main_index) order[k++] = i;

  for (int i = 0; i < n; i++) {
    ctx_init(&ctxs[i]);
    ctxs[i].is_main = prog.funcs[order[i]].is_main;
    // 2026-09-09：char 值返回函数在返回处截断到 0..255（对齐 SPEC 第 165 行；main 恒为 int 不受影响）
    ctxs[i].ret_char = !prog.funcs[order[i]].ret_void
                    && prog.funcs[order[i]].ret_ty == TY_CHAR
                    && !prog.funcs[order[i]].is_main;
    // v1.2.1 double 阶段2：double 值返回 → 返回值在 xmm0 直出（不截断）；出口 own/share 清理
    //   只压/弹 rax，不碰 xmm0（main 恒 int，不受影响）
    ctxs[i].ret_dbl = !prog.funcs[order[i]].ret_void
                   && prog.funcs[order[i]].ret_ty == TY_DOUBLE
                   && !prog.funcs[order[i]].is_main;
    codegen_func(&ctxs[i], &prog.funcs[order[i]], &prog);
    ctx_of_func[order[i]] = i;
  }

  // 布局偏移（函数内跳转已各自 resolve；这里定各函数 code 起点）
  offsets[0] = 0;
  for (int i = 1; i < n; i++) offsets[i] = offsets[i - 1] + ctxs[i - 1].code.len;

  // 二次回填函数间 call：disp = 目标函数起点 - (本函数起点 + rel32 位置 + 4)
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t e = 0; e < c->nexts; e++) {
      int tctx = ctx_of_func[c->exts[e].target];
      size_t off = c->exts[e].off;
      uint32_t disp = (uint32_t)(offsets[tctx] - (offsets[i] + off + 4));
      buf_patch_u32(&c->code, off, disp);
    }
  }

  // v0.9.3：回填 &函数名 的 lea disp（disp = 目标函数起点 - (本函数起点 + disp 位置 + 4)）
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t a = 0; a < c->nfuncaddrs; a++) {
      int tctx = ctx_of_func[c->funcaddrs[a].target];
      size_t off = c->funcaddrs[a].off;
      uint32_t disp = (uint32_t)(offsets[tctx] - (offsets[i] + off + 4));
      buf_patch_u32(&c->code, off, disp);
    }
  }

  // v0.7.3：字符串数据区排布（按 ctx 序 = 生成序紧凑排布，每条 内容+\0）
  // ⚠️ 回填必须在拼接拷贝之前（patch 写 ctx code，拷进 out 后再改就晚了）
  size_t code_pure_len = offsets[n - 1] + ctxs[n - 1].code.len; // 字符串区起点（拼接内偏移）
  size_t str_cursor = 0;
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t s = 0; s < c->nstrrefs; s++) {
      StrRef *r = &c->strrefs[s];
      r->str_off = str_cursor;
      str_cursor += (size_t)r->len + 1;   // 含末尾 \0
      uint32_t disp = (uint32_t)((code_pure_len + r->str_off) - (offsets[i] + r->off + 4));
      buf_patch_u32(&c->code, r->off, disp);
    }
  }

  // v1.3.0 全局变量：这里**不再回填** `[rip+disp32]` —— 因为 `.data` 的 RVA 取决于 `.text` 的实际
  //   虚拟大小（两节必须虚拟地址连续，见 flint.h 顶部），只有 pe_build 算得出。
  //   本处只把「本函数 code 内偏移」转成**拼接后全局偏移**并汇总（与 api_sites 同一套做法）。
  //   ⚠️ GenResult r 必须在这里声明（汇总循环要用它）——原声明在下方「拼接代码」处，已上移。
  GenResult r;
  r.globals = prog.globals;
  r.nglobals = prog.nglobals;
  r.data_size = prog.data_size;
  r.guses = NULL; r.nguses = 0; r.guses_cap = 0;   // ⚠️ 必须在下面这个汇总循环之前初始化
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t k = 0; k < c->nguses; k++) {
      if (r.nguses == r.guses_cap) {
        size_t cap = r.guses_cap ? r.guses_cap * 2 : 16;
        GUse *g = realloc(r.guses, cap * sizeof(GUse));
        if (!g) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
        r.guses = g;
        r.guses_cap = cap;
      }
      r.guses[r.nguses].off = offsets[i] + c->guses[k].off;   // 拼接后全局偏移
      r.guses[r.nguses].gi = c->guses[k].gi;
      r.nguses++;
    }
  }

  // v1.4.11（-debug）：语句级记录 → 转全局偏移汇总 + 每函数区间（DWARF 每函数发一条 sequence）。
  //   **按 ctx 序（= 生成序 = 最终 code 里的顺序）汇总**，保证偏移非递减；
  //   关闭开关时这里除两次赋值外什么都不做 ⇒ 既有产物逐字节不变。
  r.dbg_rows = NULL; r.ndbg_rows = 0; r.dbg_rows_cap = 0;
  r.dbg_funcs = NULL; r.ndbg_funcs = 0; r.dbg_funcs_cap = 0;
  if (flint_debug_info) {
    r.dbg_funcs_cap = (size_t)n;
    r.dbg_funcs = xmalloc((size_t)n * sizeof(DebugFuncSpan));
    for (int i = 0; i < n; i++) {
      r.dbg_funcs[i].off = offsets[i];
      r.dbg_funcs[i].len = ctxs[i].code.len;
      r.ndbg_funcs = i + 1;
    }
    for (int i = 0; i < n; i++) {
      FuncCtx *c = &ctxs[i];
      for (size_t k = 0; k < c->ndbg; k++) {
        if (r.ndbg_rows == r.dbg_rows_cap) {
          size_t cap = r.dbg_rows_cap ? r.dbg_rows_cap * 2 : 256;
          DebugRow *p = realloc(r.dbg_rows, cap * sizeof(DebugRow));
          if (!p) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
          r.dbg_rows = p;
          r.dbg_rows_cap = cap;
        }
        r.dbg_rows[r.ndbg_rows].file = c->dbg[k].file;
        r.dbg_rows[r.ndbg_rows].line = c->dbg[k].line;
        r.dbg_rows[r.ndbg_rows].off = offsets[i] + c->dbg[k].off;
        r.dbg_rows[r.ndbg_rows].len = c->dbg[k].len;
        r.ndbg_rows++;
      }
    }
  }

  // v1.1.0 浮点（阶段1）：double 常量区 = 字符串区之后，按 8 字节对齐（movsd 要求）
  size_t dbl_base = (code_pure_len + str_cursor + 7) / 8 * 8;
  size_t dbl_pad = dbl_base - (code_pure_len + str_cursor);
  size_t dbl_cursor = 0;
  size_t ndbl_total = 0;
  for (int i = 0; i < n; i++) ndbl_total += ctxs[i].ndblrefs;
  unsigned long long *dbl_vals = ndbl_total ? (unsigned long long *)xcalloc(ndbl_total, sizeof(unsigned long long)) : NULL;
  // v1.1.0 浮点：double 常量区排布（每个值一份数据；每个使用位置各自回填 disp）
  size_t dv = 0;
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t k = 0; k < c->ndblrefs; k++) {
      DblRef *r = &c->dblrefs[k];
      size_t tgt = dbl_base + dbl_cursor;
      // 该常量在本函数里的**每一处**使用都各自回填（同一常量可出现多次）
      for (size_t u = 0; u < r->noffs; u++)
        buf_patch_u32(&c->code, r->offs[u], (uint32_t)(tgt - (offsets[i] + r->offs[u] + 4)));
      dbl_vals[dv++] = r->bits;
      dbl_cursor += 8;
    }
  }

  // 拼接全部函数代码（main 在最前 → PE 入口 = code 0）
  Buf out;
  buf_init(&out);
  for (int i = 0; i < n; i++)
    buf_bytes(&out, ctxs[i].code.data, ctxs[i].code.len);
  // 追加字符串区字节（内容 + \0）
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t s = 0; s < c->nstrrefs; s++) {
      buf_bytes(&out, (const uint8_t *)c->strrefs[s].str, (size_t)c->strrefs[s].len);
      buf_byte(&out, 0);
    }
  }
  // 追加对齐填充 + double 常量区（低位在前 = 小端，位型原样落盘）
  for (size_t i = 0; i < dbl_pad; i++) buf_byte(&out, 0);
  for (size_t i = 0; i < dv; i++)
    for (int bsel = 0; bsel < 8; bsel++) buf_byte(&out, (uint8_t)(dbl_vals[i] >> (8 * bsel)));

  // v1.3.0：GenResult r 已在上方「汇总全局变量引用」之前声明并填了 globals/guses 等字段
  r.code = out;
  r.disp_off = ctxs[0].disp_off; // ctx 0 = main

  // v1.3.0：全局变量表 / .data 大小 / 引用回填表 已在上方「汇总全局变量引用」之前带出
  //   （那里一开始就初始化了 r.guses，有顺序依赖说明）——此处不再重复。

  // v0.8：拷贝 API 表 + 汇总 API 调用点（off 转全局偏移；IAT disp 由 pe_build 布局后回填）
  r.apis = NULL; r.napis = 0;
  r.api_sites = NULL; r.napi_sites = 0; r.api_sites_cap = 0;
  if (prog.napis > 0) {
    r.apis = xcalloc((size_t)prog.napis, sizeof(ApiDef));
    for (int i = 0; i < prog.napis; i++) {
      ApiDef *dst = &r.apis[i];
      ApiDef *src = &prog.apis[i];
      dst->dll = xmalloc(strlen(src->dll) + 1);
      strcpy(dst->dll, src->dll);
      dst->name = xmalloc(strlen(src->name) + 1);
      strcpy(dst->name, src->name);
      // v1.1.0：真名重绑定必须跟着拷（漏拷 = 导入表退回 FLINT 侧名字 → 加载期 STATUS_ENTRYPOINT_NOT_FOUND）
      if (src->import_name) {
        dst->import_name = xmalloc(strlen(src->import_name) + 1);
        strcpy(dst->import_name, src->import_name);
      }
      dst->nargs = src->nargs;
      dst->ret_void = src->ret_void;
    }
    r.napis = prog.napis;
  }
  for (int i = 0; i < n; i++) {
    FuncCtx *c = &ctxs[i];
    for (size_t s = 0; s < c->napicalls; s++) {
      if (r.napi_sites == r.api_sites_cap) {
        size_t cap = r.api_sites_cap ? r.api_sites_cap * 2 : 8;
        r.api_sites = realloc(r.api_sites, cap * sizeof(ApiCallRef));
        if (!r.api_sites) { fprintf(stderr, "FLINT: 内存不足\n"); exit(1); }
        r.api_sites_cap = cap;
      }
      r.api_sites[r.napi_sites].off = offsets[i] + c->apicalls[s].off; // 全局偏移
      r.api_sites[r.napi_sites].api = c->apicalls[s].api;
      r.napi_sites++;
    }
  }

  for (int i = 0; i < n; i++) {
    free(ctxs[i].code.data);
    free(ctxs[i].patches);
    free(ctxs[i].label_pos);
    free(ctxs[i].label_set);
    free(ctxs[i].exts);
    free(ctxs[i].strrefs);
    free(ctxs[i].dblrefs);
    free(ctxs[i].guses);   // v1.3.0：全局变量引用表
    free(ctxs[i].apicalls);
    free(ctxs[i].funcaddrs);
  }
  free(ctxs);
  free(order);
  free(ctx_of_func);
  free(offsets);
  return r;
}
