// parse.c — FLINT 语法分析器（v0.6：引用 + void）
// 程序 = 函数定义*（每个 = ("int"|"void") 名 "(" 参数 ")" "{" 语句* "}"）
//   参数 = ("int" ["&"] 标识符) ("," "int" ["&"] 标识符)*   // ≤4；& = 引用形参
//   声明 = "int" 声明符列表 ";" ｜ "int" "&" 标识符 "=" 变量 ";"  // 引用必须初始化绑定
//   语句 = "return" [表达式] ";"
//        | 声明
//        | "{" 语句* "}"                          // 块（新建作用域）
//        | "if" "(" 表达式 ")" 语句 ("else" 语句)?
//        | "while" "(" 表达式 ")" 语句
//        | "for" "(" (声明 | 表达式)? ";" 表达式? ";" 表达式? ")" 语句
//        | 表达式 ";"
// 表达式优先级（低→高）：赋值 → || → && → 相等 → 关系 → 加减 → 乘除 → 一元 → 主
// 主表达式支持函数调用：标识符 "(" 参数列表 ")"（函数名全局表，调用可先于定义——
//   第一遍轻扫收集全部函数名，第二遍正式解析）。
// v0.6 语义：void 函数 return;（无表达式）或落尾；void 调用只能作语句（后遍检查）；
//   引用变量槽存地址（读写自动解引用）；引用形参调用点自动传地址（实参须变量）。
// 作用域：每函数一层（参数+局部）+ 块/for 各一层；同层重名报错，跨层可遮蔽。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flint.h"

// v0.9：-safe 编译模式（main.c -safe / -mode safe 置位）
// 第一规则 = 内存所有权强制：new 结果必须由 own/share 指针接管，杜绝裸持有泄漏
bool flint_safe_mode = false;
// v1.4.25（`-strict` 诊断档）：默认关。开了之后 parse 与 codegen 各加一层"静默转显式"的检查；
//   **关着的时候一行行为都不变**（产物逐字节相同，由 test\等价门.ps1 的指纹基线守着）。
bool flint_strict = false;

// —— 作用域栈 ——
typedef struct LVar LVar;
struct LVar {
  LVar *next;
  char *name;
  int len;
  int offset;
  int ty;         // v0.7：Type（TY_INT/TY_PTR/TY_ARR/TY_STRUCT）
  int elem_ty;    // v1.0.5：TY_ARR 元素 / TY_PTR 指向 类型（TY_CHAR = 字节语义；默认 TY_INT）
  int arr_len;    // TY_ARR：元素个数
  int struct_idx; // TY_STRUCT：Program.structs 下标；TY_PTR：指向的结构体（int* 为 -1）
  bool is_ref;    // v0.6：引用变量（槽存地址，读写自动解引用）
  bool is_global;// v1.3.0：符号表项**不是**局部变量，而是全局变量——此时 offset 存的是
                 //   Program.globals 下标（不是 rbp 偏移）。所有直接读/写槽码必须按它分流。
  bool is_own; // v0.9：own 独占指针（new 初始化；出口自动释放；禁拷贝/重赋值）
  bool is_share; // v0.9：share 引用计数指针（new/share 拷贝初始化；拷贝+1 出口-1 归零释放）
  int fn_sig;    // v1.3.2：TY_FUNCPTR 变量的签名下标（Program.sigs）；其余 = FN_SIG_NONE
  // —— v1.4.25（`-strict` 诊断档）三个只在严格档里用的标记 ——
  bool no_init;    // 声明时**没给初值**（`int x;`）→ 未初始化检查的候选
  bool may_inited; // 已经"可能被写过"（赋值 / 取址 / 形参装载）→ 之后读它一律放行（宁可漏报）
  LVar *all_next;  // 本函数**全部**变量的链（跨块作用域也串着）——strict 后遍查"哪个槽是哪个变量"
};

typedef struct Scope Scope;
struct Scope {
  Scope *prev;
  LVar *vars;    // 本层变量（头插）
};

typedef struct {
  Token *tok;
  Scope *scope;
  int var_count;
  int next_offset;
  LVar *all_lvars;    // v1.4.25：本函数**全部**局部/形参（含块内、跨已弹出的作用域链着）；
                      //   strict 的未初始化检查在后遍跑，那时块作用域已经弹掉了，靠这条链找名字
  Program *prog;      // v0.5：函数表（调用点按名查）
  bool fn_ret_void;   // v0.6：当前解析函数的返回类型是 void（return 检查用）
  int scope_nest;     // v0.9：嵌套作用域深度（块/控制流体；own 声明限函数顶层）
  int loop_nest;      // v1.2.0：循环嵌套深度（while/for 进出 ++/--；break/continue 在 0 层 = 报错）
  int switch_nest;    // v1.3.1：switch 嵌套深度（break 在 switch 里合法；continue 不算——它跳的仍是外层循环）
  bool fn_ret_dbl;    // v1.2.1 double 阶段2：当前解析函数返回 double（return 处做 int→double 提升）
  int fn_ret_ty;      // v1.5.0：当前解析函数的返回类型（TY_PTR → return str([...]) 放行）
} Parser;

// —— token 工具 ——
static bool is_punct(Token *tok, char op) {
  return tok->kind == TK_PUNCT && tok->len == 1 && *tok->loc == op;
}

static bool is_ident(Token *tok, char *s) {
  if (tok->kind != TK_IDENT) return false;
  if (tok->len == (int)strlen(s) && strncmp(tok->loc, s, tok->len) == 0) return true;
  // v1.6.5（int4 ABI）：`int_32` = `int` 的显式别名（4 字节宽度；行为/布局/产物与 int 完全一致）。
  //   只替 "int" 这一个关键字，不放开其它名字（is_ident 也用于 char/void/return 等判定）。
  if (strcmp(s, "int") == 0 && tok->len == 6 && strncmp(tok->loc, "int_32", 6) == 0) return true;
  return false;
}

static Token *skip(Parser *p, char op) {
  if (!is_punct(p->tok, op)) error_at(p->tok->loc, "期望 '%c'", op);
  p->tok = p->tok->next;
  return p->tok;
}

static bool consume(Parser *p, char op) {
  if (is_punct(p->tok, op)) { p->tok = p->tok->next; return true; }
  return false;
}

static bool is_punct_str(Token *tok, char *s) {
  return tok->kind == TK_PUNCT && tok->len == (int)strlen(s)
      && strncmp(tok->loc, s, tok->len) == 0;
}

static bool consume_str(Parser *p, char *s) {
  if (is_punct_str(p->tok, s)) { p->tok = p->tok->next; return true; }
  return false;
}

static bool consume_ident(Parser *p, char *s) {
  if (is_ident(p->tok, s)) { p->tok = p->tok->next; return true; }
  return false;
}

static bool is_keyword(Token *tok) {
  return is_ident(tok, "int") || is_ident(tok, "char") || is_ident(tok, "void") || is_ident(tok, "return")
      || is_ident(tok, "if") || is_ident(tok, "else") || is_ident(tok, "while")
      || is_ident(tok, "for") || is_ident(tok, "new") || is_ident(tok, "own")
      || is_ident(tok, "share") || is_ident(tok, "ptr") || is_ident(tok, "double")   // v1.1.0 浮点
      || is_ident(tok, "int_64")   // v1.7.0：64 位有符号整数（关键字：拦住它当变量名）
      || is_ident(tok, "switch") || is_ident(tok, "case") || is_ident(tok, "default"); // v1.3.1
  // 注意：main 不是关键字（v0.5 函数名；"int main" 由函数定义层识别）
  // v0.9：new = 堆分配（保留）；own = 独占指针标注；share = 引用计数指针标注（都只修饰 * 指针）
  // v0.9.2：ptr 仅作 api 返回类型（api user32 ptr GetModuleHandleA(int);），全局保留防误用
  // v1.0.5：char = 无符号字节类型（B 档；声明/数组/struct 字段/参数/返回）
}

// v0.9.2：对齐取整（结构体字段真实 C 布局用）
static int align_up(int v, int a) {
  return (v + a - 1) / a * a;
}

// —— 作用域操作 ——
static void scope_push(Parser *p) {
  Scope *s = calloc(1, sizeof(Scope));
  s->prev = p->scope;
  p->scope = s;
}

static void scope_pop(Parser *p) {
  p->scope = p->scope->prev;
}

// 当前层内查找（重名检测用）
static LVar *find_in_scope(Scope *s, Token *tok) {
  for (LVar *v = s->vars; v; v = v->next)
    if (v->len == tok->len && strncmp(v->name, tok->loc, tok->len) == 0)
      return v;
  return NULL;
}

// 从内层往外找（引用解析，内层遮蔽外层）
static LVar *find_lvar(Parser *p, Token *tok) {
  for (Scope *s = p->scope; s; s = s->prev) {
    LVar *v = find_in_scope(s, tok);
    if (v) return v;
  }
  return NULL;
}

// —— v1.3.0 全局变量表查找（函数体内任何作用域都能看见；局部变量可遮蔽同名全局）——
static int find_global(Program *prog, Token *tok) {
  for (int i = 0; i < prog->nglobals; i++)
    if (prog->globals[i].len == tok->len
        && strncmp(prog->globals[i].name, tok->loc, tok->len) == 0)
      return i;
  return -1;
}

// 登记变量：分配槽（数组 = arr_len 个槽；结构体 = nfields 个槽）；类型信息入 LVar
static LVar *new_lvar(Parser *p, Token *tok, bool ref, int ty, int arr_len, int struct_idx, int elem_ty) {
  if (find_in_scope(p->scope, tok))
    error_at(tok->loc, "变量 '%.*s' 重复声明", tok->len, tok->loc);
  LVar *v = calloc(1, sizeof(LVar));
  v->name = malloc(tok->len + 1);
  memcpy(v->name, tok->loc, tok->len);
  v->name[tok->len] = '\0';
  v->len = tok->len;
  v->offset = p->next_offset;
  v->ty = ty;
  v->elem_ty = elem_ty;   // v1.0.5：TY_ARR 元素 / TY_PTR 指向（char 字节语义；int 默认）
  v->arr_len = arr_len;
  v->struct_idx = struct_idx;
  v->is_ref = ref;
  v->fn_sig = FN_SIG_NONE;   // v1.3.2：非函数指针变量（函数指针在建立后显式赋值）
  // v0.9.2：结构体变量 = ceil(size/8) 个 8 字节槽（C 布局字节块；字段在块内按类型对齐）
  // v1.6.5（int4 ABI）：int 数组元素 = **4 字节**（C 兼容）；char 数组沿用 8*N 槽（字节缓冲布局不动）；
  //   double 数组 = 8 字节/元素。槽数按元素字节数上取整，基址公式（offset += 8*(slots-1)）不变。
  int _elem_esz = ty_arr_stride(elem_ty);   // v1.7.0：走单点表（char 1 / int 4 / int_64 8 / double 8）
  int slots = (ty == TY_ARR) ? ((elem_ty == TY_CHAR) ? arr_len : (int)(((long long)_elem_esz * arr_len + 7) / 8))
             : (ty == TY_STRUCT) ? (p->prog->structs[struct_idx].size + 7) / 8
             : 1;   // v1.1.0：double 也是 1 个 8 字节槽（它按「值」读写，不是按「块基址」）
  // v1.0.6.2 盲区审计 A6：帧槽累计防 int 溢出——数组长巨大（如 int a[2000000000]）时
  // 8*slots ≈ 1.6e10 超 int32，offset/var_count/frame 全回绕 → sub rsp 巨值/错 offset 的
  // 损坏产物。上限 = 帧槽累计 ≤ (2^31-1)/8 ≈ 268M 槽（2GB 帧，远超任何实际栈；正常代码永不到）
  if ((long long)p->next_offset + 8LL * slots > 0x7FFFFFFFLL)
    error_at(tok->loc, "变量/数组/结构体总长过大（帧槽累计超 2GB 上限）");
  // 🔧 帧物理布局修正（v0.9.2 类型层顺带）：槽按 rbp-off 向上 8 字节计、连续向下分配，
  //   但块变量（数组/结构体）的基址 lea rbp-off 且元素/字段从基址向上走——方向相反，
  //   多槽块的元素会穿进先前变量/调用方栈区（旧测试靠 main 永不返回 + 无交叉干扰侥幸掩盖，
  //   含指针字段的 struct 一进会 return 的普通函数即爆栈）。
  //   修法：块变量基址指其保留区最低字节（offset += 8*(slots-1)），元素向上走正好落在自区内。
  if (slots > 1 && (ty == TY_ARR || ty == TY_STRUCT))
    v->offset += 8 * (slots - 1);
  p->next_offset += 8 * slots;
  p->var_count += slots;
  v->next = p->scope->vars;
  p->scope->vars = v;
  // v1.4.25：再挂进"本函数全部变量"链（块作用域会弹掉，这条链不会）
  v->all_next = p->all_lvars;
  p->all_lvars = v;
  return v;
}

// v1.4.25（`-strict`）：按帧槽偏移找变量。槽偏移在函数内唯一（parse 给每个变量/数组/结构体分的
//   区间互不重叠）⇒ 偏移就能唯一认人，不必再造一张表。
static LVar *lv_by_offset(LVar *all, int off) {
  for (LVar *v = all; v; v = v->all_next)
    if (v->offset == off) return v;
  return NULL;
}

// —— AST 构造 ——
// v1.4.11（`-debug`）：**语句起始 token 的源码位置**。Node 原有的 `loc` 只在 ND_CALL/ND_APICALL 上填过
//   （报错定位用），语句节点普遍没有位置 ⇒ 可审计发射层拿不到"这条语句在第几行"。
//   做法：解析语句时把当前 token 位置记进这个全局，new_node 顺手把「行号 + 源文件序号」刻进节点。
//   为什么不用 node->loc 反查：语句节点压根没有 loc，子节点也多半没有（ND_NUM/ND_VAR 都不填）。
static char *g_stmt_loc = NULL;

static Node *new_node(NodeKind kind, Node *lhs, Node *rhs) {
  Node *n = calloc(1, sizeof(Node));
  n->kind = kind;
  n->lhs = lhs;
  n->rhs = rhs;
  n->fn_sig = FN_SIG_NONE;   // v1.3.2：0 是合法签名下标，所以"无签名"必须显式写 -1
  // v1.4.11：行号/文件序号与编译器报错**同源**（都走 tokenize.c 的 src_spans 表）
  if (g_stmt_loc) { n->line = src_line_of(g_stmt_loc); n->file = src_file_index_of(g_stmt_loc); }
  else { n->line = 0; n->file = -1; }
  return n;
}

// ===== v1.1.0 浮点（阶段1）：类型判定与自动提升（实现见下，声明在 flint.h 供 codegen 共用）=====
// expr_is_dbl：这个表达式的值是不是 double。
// 阶段1 只有「字面量 / double 变量与解引用 / int→double 提升 / to_int(...)（结果 int）」四类来源，
// 其余（函数返回、结构体字段、数组元素、API 返回值）阶段2 再扩——那时读「字段/元素/参数的类型标注」。
bool expr_is_dbl(Node *n) {
  if (!n) return false;
  switch (n->kind) {
    case ND_DBL: return true;
    case ND_I2D: return true;
    // v1.2.5：引用变量按**别名对象的类型**判（double& r 的值是 double）；int& 的 ty 仍是 TY_INT，
    //   行为与旧版完全一致（原来的 `n->is_ref ? false` 在 double 引用不可达时是死条件）
    case ND_VAR: return n->ty == TY_DOUBLE;
    case ND_APICALL: return n->ty == TY_DOUBLE;          // API 返回 double（结果在 xmm0）
    // v1.2.1 double 阶段2：调 double 返回函数 = double 值（结果在 xmm0）。
    //   ⚠️ 与 ND_APICALL 同源：调用节点的 ty 由被调函数 ret_ty 决定（parse 调用点填的）
    case ND_CALL: return n->ty == TY_DOUBLE;
    case ND_DEREF: return n->ty == TY_DOUBLE;            // *p（p 指向 double）
    case ND_ASSIGN: return expr_is_dbl(n->rhs) || n->ty == TY_DOUBLE;
    // v1.8.0 C 风格转型：(double)x 的结果就是 double（结果类型 = 括号里的类型，唯一来源 node->ty）
    case ND_CAST: return n->ty == TY_DOUBLE;
    // v1.3.1：三元的结果类型在 parse 就定死了（两支都 double / 一支 double 提升另一支）——
    //   codegen 直接读 ty，不去重推两分支（避免"两边判据不一致"的浮点旧坑重演）
    case ND_TERN: return n->ty == TY_DOUBLE;
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV:
    case ND_NEG:
      return expr_is_dbl(n->lhs) || expr_is_dbl(n->rhs);
    default: return false;
  }
}
// 兼容旧名（本节内多处调用）
static bool is_dbl_node(Node *n) { return expr_is_dbl(n); }   // 本节内沿用短名

// ===== v1.7.0 int_64：判据 + 提升（与 expr_is_dbl 逐条同形；flint.h 声明、parse/codegen 共用）=====
// 为什么另立一门（不复用 wide/地址类）：int_64 是**值**不是地址，宽度理由完全不同
//   （地址 = 64 位是因为指针宽；int_64 = 64 位是因为它的值域就是 64 位）。
// 与 expr_is_dbl 的分工：本判据**只看值语义**，不看存储；存储宽度由各发射点的 ty 分派负责。
bool expr_is_i64(Node *n) {
  if (!n) return false;
  switch (n->kind) {
    case ND_NUM64: return true;
    case ND_I2L: return true;
    case ND_VAR: return n->ty == TY_INT64;
    case ND_CALL: return n->ty == TY_INT64;        // 调用节点的 ty 由被调函数 ret_ty 决定
    case ND_DEREF: return n->ty == TY_INT64;       // *p / 数组元素 / 结构体字段
    case ND_ASSIGN: return expr_is_i64(n->rhs) || n->ty == TY_INT64;
    // v1.8.0 C 风格转型：(int_64)x 的结果就是 int_64
    case ND_CAST: return n->ty == TY_INT64;
    case ND_TERN: return n->ty == TY_INT64;
    // v1.7.0 P1：++/-- 的值类型 = 操作数类型（前缀=新值、后缀=旧值，两者都是完整 64 位）。
    //   ⚠️ 不补这一档 = `int_64 y = x++;` 会被 asgn_rhs 包成 ND_I2L（movsxd rax,eax），
    //   把高 32 位抹掉 —— 编译过、值错。打印（seg_print_kind）也靠这一档选 _flint_out_i64。
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      return expr_is_i64(n->lhs);
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV: case ND_MOD: case ND_NEG:
    case ND_BITAND: case ND_BITOR: case ND_BITXOR: case ND_SHL: case ND_SHR: case ND_BITNOT:
      // 混合提升：任一操作数是 int_64 就算 int_64（与 double 同一条 C 口径）
      return expr_is_i64(n->lhs) || expr_is_i64(n->rhs);
    default: return false;
  }
}
// widen_i64：需要 64 位时把 32 位侧包一层 ND_I2L（符号扩展）。
//   ⚠️ 「值本身已是地址类」的表达式**不能再包**：地址在 rax 里已经是完整 64 位，
//   包一层 movsxd rax,eax 会把高 32 位抹掉（那正是本设计 §2.4 那个"编译过、值错"的坑）。
Node *expr_widen_i64(Node *n) {
  if (expr_is_i64(n)) return n;
  Node *c = new_node(ND_I2L, n, NULL);
  c->ty = TY_INT64;
  return c;
}
static Node *widen_i64(Node *n) { return expr_widen_i64(n); }

// parse 侧的「这个表达式的值是不是地址」判据 —— codegen 有同名的 is_addr_value，
//   但那边还含 T1「装过地址的 int」标记，parse 拿不到 ⇒ 这里只做一层薄封装（唯一出处仍是
//   tern_addr_info，别在别处再写一份 is_addr 的判据）。定义在 tern_addr_info 之后。
static bool parse_is_addr_value(Node *n);

// ===== D3：宽度口径单点表（flint.h 声明）=====
// 值宽：一次读写几个字节。数组/结构体的元素走本表；槽宽（8）是帧布局的事，不在这里。
int ty_value_bytes(int ty) {
  switch (ty) {
    case TY_CHAR: return 1;
    case TY_INT:  return 4;
    case TY_INT64: return 8;
    case TY_DOUBLE: return 8;
    case TY_PTR: case TY_FUNCPTR: return 8;
    default: return 8;   // TY_ARR/TY_STRUCT/未知：按 8（与旧行为一致）
  }
}
// 元素步长（下标缩放）：FLINT 的 a[i] = *(a + i*stride)。今天数值 == 值宽，
//   但**两列分开**：下一轮改宽度（或引入 4 字节真的对齐 C）时两列会分叉，混写必错。
int ty_arr_stride(int ty) { return ty_value_bytes(ty); }
// widen_dbl：需要 double 时，把 int 侧自动提升（C 语义：int → double，不静默丢精度）
// v1.7.0：int_64 侧**不许**走这里（P0/P1 一律硬错）——这是 int_64↔double 的第二道墙
//   （第一道在 mkbin / asgn_rhs；两道都留着，与「浮点首版判据分叉」的教训同一个理由）。
Node *expr_widen_dbl(Node *n) {
  if (expr_is_dbl(n)) return n;
  if (expr_is_i64(n))
    error("int_64 不能隐式转 double（v1.7.0 P0/P1 不支持两者互转）——请先 to_int32(...) 再转，"
          "或改用整数值");
  Node *c = new_node(ND_I2D, n, NULL);
  c->ty = TY_DOUBLE;
  return c;
}
static Node *widen_dbl(Node *n) { return expr_widen_dbl(n); }
// asgn_rhs：按左值类型处理右值——double 左值接 int 右值自动提升；反向必须显式 to_int（防静默截断）
// v1.3.2：函数指针左值额外做「只能接 &函数名 / 另一个函数指针，且签名一致」的检查
static Node *asgn_rhs(Node *lhs, Node *rhs, char *loc) {
  if (lhs->ty == TY_FUNCPTR) {
    Node *bad = NULL;
    if (rhs->kind == ND_VAR && rhs->ty == TY_FUNCPTR) {
      // 签名比较放到调用方（需要 Program 表）——这里只保证形态合法
    } else if (rhs->kind == ND_FUNC_ADDR) {
      // 形态合法（签名比较在 funcptr_check_asgn 里做）
    } else {
      bad = rhs;
    }
    if (bad)
      error_at(loc, "函数指针只能接「&函数名」或另一个函数指针"
                    "（整数/普通指针/函数调用结果都接不了——C 里裸函数名会退化，FLINT 要求显式写 &）");
    return rhs;
  }
  if (rhs->ty == TY_FUNCPTR)
    error_at(loc, "函数指针不能赋给非函数指针变量（要存就声明成 int (*fp)(...)）");
  // ===== v1.7.0 int_64 的赋值口径（与 double 同一套形状：拓宽隐式、收窄必须显式）=====
  //   ① int_64 ← int（拓宽）：隐式，符号扩展（ND_I2L）
  //   ② int_64 ← 地址值（指针/&x/ptr 字段…）：**原样**（地址本来就是完整 64 位，不能再包 movsxd）
  //   ③ int ← int_64（收窄）：**硬错** + 提示 to_int32（掉高 32 位是本类型 90% 的静默 bug 来源）
  //   ④ int_64 ↔ double：P0/P1 一律硬错（P2 再谈；两条都是"编译过、静默错值"）
  if (lhs->ty == TY_INT64 && expr_is_dbl(rhs))
    error_at(loc, "不能把 double 赋给 int_64（P0/P1 不支持 int_64 与 double 互转）——"
                  "请先用 to_int(...) 转成 int，或改用整数值");
  if (lhs->ty == TY_INT64)
    return parse_is_addr_value(rhs) ? rhs : widen_i64(rhs);
  // 双精度左值：int_64 右值一律硬错（P0/P1 不互转），其余照旧自动提升
  if (is_dbl_node(lhs)) {
    if (expr_is_i64(rhs))
      error_at(loc, "不能把 int_64 赋给 double（v1.7.0 P0/P1 不支持 int_64 与 double 互转）——"
                    "请先显式 to_int32(值) 再赋，或把左值声明成 int_64");
    return widen_dbl(rhs);
  }
  if (expr_is_i64(rhs))
    error_at(loc, "不能把 int_64 赋给 int/char（会静默截断高 32 位：值超出 int 范围的部分丢掉）——"
                  "请显式写 to_int32(值)，"
                  "或把左值声明成 int_64");
  if (is_dbl_node(rhs))
    error_at(loc, "不能把 double 赋给 int（会静默截断小数）——请显式写 to_int(值)，或把左值声明成 double");
  return rhs;
}

static Node *new_num(int val) {
  Node *n = calloc(1, sizeof(Node));
  n->kind = ND_NUM;
  n->val = val;
  n->fn_sig = FN_SIG_NONE;
  return n;
}

static Node *new_var_node(int offset, bool is_ref, int ty, int struct_idx, int elem_ty) {
  Node *n = calloc(1, sizeof(Node));
  n->kind = ND_VAR;
  n->offset = offset;
  n->is_ref = is_ref;
  n->ty = ty;
  n->struct_idx = struct_idx;
  n->elem_ty = elem_ty;   // v1.0.5：数组元素/指针指向（char 字节语义）
  n->fn_sig = FN_SIG_NONE;   // v1.3.2（函数指针变量由调用方显式补 fn_sig）
  return n;
}

// v1.3.0：全局变量引用节点——offset 字段存 **Program.globals 下标**（不是 rbp 偏移），
//   is_global 置位让 codegen 走 rip 相对通路（[rip+disp32] 指 .data），而不是帧槽通路。
static Node *new_global_node(int gi, GlobalVar *g) {
  Node *n = new_var_node(gi, false, g->ty, -1, g->elem_ty);
  n->is_global = true;
  return n;
}

// —— 文法前向声明 ——
static Node *stmt(Parser *p);
static Node *expr(Parser *p);
static Node *assign(Parser *p);
// v1.7.0 P2：int_64 复合赋值的源码层摊平（定义在 mkbin/mkintbin 之后 —— 二元提升口径的唯一出处）
static Node *i64_compound(Parser *p, Node *lv, NodeKind bin_kind, Node *rhs, char *loc);
static Node *ternary(Parser *p);   // v1.3.1 三元：cond ? a : b
static Node *logor(Parser *p);
static Node *logand(Parser *p);
static Node *bitor(Parser *p);   // v0.7.2 位或 |
static Node *bitxor(Parser *p);  // v0.7.2 位异或 ^
static Node *bitand(Parser *p);  // v0.7.2 位与 &
static Node *equality(Parser *p);
static Node *relational(Parser *p);
static Node *shift(Parser *p);   // v0.7.2 移位 << >>
static Node *add(Parser *p);
static Node *mul(Parser *p);
static Node *unary(Parser *p);
static Node *pow_expr(Parser *p);
static Node *postfix(Parser *p);
static Node *primary(Parser *p);
static Node *decl_list(Parser *p, int base_ty); // 解析 int/char 之后的声明符序列，返回语句链（ND_BLOCK 体）
static int find_func(Program *prog, Token *tok);     // 按名查函数，返回下标或 -1
static int find_struct(Program *prog, Token *tok);   // v0.7.x：按名查结构体类型，返回下标或 -1
static int find_api(Program *prog, Token *tok);      // v0.8：按名查 API，返回下标或 -1
// v1.0.8：print 内建输出语句（print([段, ...] [, 换行])）
static Node *print_stmt(Parser *p);
static int seg_print_kind(Parser *p, Token *s0, Node *n);
static Node *print_seg_call(Parser *p, Token *s0, Node *seg);
static int find_func_by_name(Program *prog, const char *name);
// v1.5.0：str 内建（str([段, ...]) → char*，共享静态缓冲）——展开成**语句链**（同 print 的做法）
static bool is_str_call(Token *t);
static Node *str_parse_body(Parser *p, Node **cur);
static Node *str_put_call(Parser *p, Token *s0, Node *seg);
static void str_ctx_error(char *loc);
static void str_decl_init(Parser *p, Node **cur, Node *var, Token *name);   // ① 声明初始化
static Node *str_assign_stmt(Parser *p);                                    // ② 赋值语句
static Node *str_return_stmt(Parser *p);                                    // ③ 指针返回函数的 return

// 把语句链收进 ND_BLOCK（多重声明/块体统一入口）
static Node *block_of(Node *first) {
  return new_node(ND_BLOCK, NULL, first);
}

// ================= v1.3.2 函数指针（C 风格语法）=================
// 形态：`int (*fp)(int, double);` ＝ 返回 int、收 (int, double) 的函数指针变量 fp。
// 三处必须共用同一份解析（**预扫描与正式解析共用**是硬纪律：见「预扫描只补一个字段」家族 4 次复发）：
//   ① 变量声明（decl_list / stmt 的 void 分支）② 函数形参表 ③ collect_funcs 预扫描。
//
// 核心 = parse_funcptr_decl：从 `(` 开始的 `(*名字)(类型表)`，只做词法级解析并吐出 FuncSig + 名字 token。
// 它**不登记变量、不填表**——登记的活儿由各自的调用方做（预扫描没有 Parser、也不该登记局部变量）。
static Token *tok_next_if_punct(Token *t, char c) {   // token 版 consume（预扫描没有 Parser）
  return is_punct(t, c) ? t->next : NULL;
}

// 解析函数指针的“参数类型表”：out->param_ty/param_sig/nargs 由本函数填。
// ret_ty/ret_elem/ret_struct/ret_void 描述返回类型。返回参数表之后的 token。
static Token *parse_funcptr_decl(FuncSig *out, Token *t, int ret_ty, int ret_elem, int ret_struct,
                                 bool ret_void, Token **out_name) {
  memset(out, 0, sizeof(*out));
  out->ret_void = ret_void;
  out->ret_ty = ret_void ? TY_INT : ret_ty;
  out->ret_elem = ret_elem;
  out->ret_struct = ret_struct;
  // ⚠️ ret_elem/ret_struct 只对「指针返回」有意义 —— 值返回（int/char/double/void）时**归一化**，
  //    否则同一个签名从两条路构造出来就会不一样（实测：`apply_h(double (*cb)(double), …)` 的形参
  //    签名 ret_elem=TY_DOUBLE（形参解析路径按基类型填），而变量 `double (*hf2)(double)` 是 TY_INT
  //    → 同一套 double(double) 被判"签名不一致"，编译期误报）。
  if (out->ret_ty != TY_PTR) { out->ret_elem = TY_INT; out->ret_struct = -1; }
  for (int i = 0; i < FUNC_MAX_ARGS; i++) out->param_sig[i] = FN_SIG_NONE;

  if (!is_punct(t, '('))
    error_at(t->loc, "内部错误：函数指针声明符应以 '(' 开头");
  t = t->next;                                        // 吃 '('
  if (!is_punct(t, '*'))
    error_at(t->loc, "函数指针声明要写成「(*名字)(参数表)」：int (*fp)(int)");
  t = t->next;                                        // 吃 '*'
  Token *name = t;
  if (name->kind != TK_IDENT || is_keyword(name))
    error_at(name->loc, "函数指针声明需要变量名：int (*fp)(int)");
  t = t->next;
  // v1.3.2 边界：函数指针数组写成 `int (*t[2])(int)`（'[' 在括号内）—— 明确报错，别落进"缺少 ')'"
  if (is_punct(t, '['))
    error_at(t->loc, "函数指针数组暂不支持（v1.3.2 边界：回调表请用几个单独变量 + if 链）");
  if (!is_punct(t, ')'))
    error_at(t->loc, "函数指针声明缺少 ')'（要写成 (*名字)）");
  t = t->next;
  if (!is_punct(t, '('))
    error_at(t->loc, "函数指针声明缺少参数表：int (*fp)(int)");
  t = t->next;

  int n = 0;
  if (is_punct(t, ')')) {
    t = t->next;                                      // `()` = 无参（C 里是"未指定"，FLINT 一律按 0 参）
  } else {
    for (;;) {
      if (n >= FUNC_MAX_ARGS)
        error_at(t->loc, "函数指针的参数上限 %d 个（前 4 个走 rcx/rdx/r8/r9，第 5 个起走栈参，v1.4.26）",
                 FUNC_MAX_ARGS);
      int pty = TY_INT;
      if (is_ident(t, "void")) {
        if (n == 0 && is_punct(t->next, ')')) { t = t->next; break; }   // `(void)` = 无参
        error_at(t->loc, "void 只能单独写成「无参」：(void)");
      } else if (is_ident(t, "int")) { pty = TY_INT; t = t->next; }
      else if (is_ident(t, "int_64"))
        error_at(t->loc, "函数指针的签名里暂不支持 int_64（v1.7.0 P0 边界：FuncSig.param_ty 还没有这一档）"
                         "——请改成 int 形参，或先用普通函数接住");
      else if (is_ident(t, "char")) { pty = TY_CHAR; t = t->next; }
      else if (is_ident(t, "double")) { pty = TY_DOUBLE; t = t->next; }
      else if (is_ident(t, "struct")) {
        t = t->next;
        if (t->kind != TK_IDENT || is_keyword(t)) error_at(t->loc, "struct 后需跟类型名");
        t = t->next;
        pty = TY_STRUCT;
      } else {
        error_at(t->loc, "函数指针的参数类型需是 int / char / double / struct S *"
                         "（要收函数指针请先用变量承接：这类嵌套签名暂不支持）");
      }
      bool pp = tok_next_if_punct(t, '*') != NULL;
      if (pp) t = t->next;
      if (is_punct(t, '&'))
        error_at(t->loc, "函数指针的参数不支持引用（int&）——请写成指针");
      if (is_punct(t, '['))
        error_at(t->loc, "函数指针的参数不支持数组，请用指针");
      if (pty == TY_STRUCT && !pp)
        error_at(t->loc, "结构体参数要写成指针（struct S *p）");
      out->param_ty[n] = pp ? TY_PTR : pty;
      out->param_sig[n] = FN_SIG_NONE;
      n++;
      if (is_punct(t, ',')) { t = t->next; continue; }
      break;
    }
  }
  if (!is_punct(t, ')'))
    error_at(t->loc, "函数指针的参数表缺少 ')'");
  t = t->next;
  out->nargs = n;
  *out_name = name;
  return t;
}

// 签名入表（返回下标；下标 0 是合法值，所以"无签名"一律用 FN_SIG_NONE(-1)）
//   Program 版供预扫描（collect_funcs 没有 Parser）使用 —— 两个入口同一份逻辑，别再写第二份。
static int add_sig_prog(Program *prog, FuncSig s) {
  if (prog->nsigs == prog->sigs_cap) {
    prog->sigs_cap = prog->sigs_cap ? prog->sigs_cap * 2 : 8;
    prog->sigs = realloc(prog->sigs, (size_t)prog->sigs_cap * sizeof(FuncSig));
    if (!prog->sigs) error("内存不足（函数指针签名表）");
  }
  prog->sigs[prog->nsigs] = s;
  return prog->nsigs++;
}
static int add_sig(Parser *p, FuncSig s) { return add_sig_prog(p->prog, s); }

// FuncDef → FuncSig：**唯一**的转换点（`fp = &foo` 的一致性检查、把函数名当函数指针实参都走它）
static FuncSig sig_of_func(FuncDef *fn) {
  FuncSig s;
  memset(&s, 0, sizeof(s));
  s.ret_void = fn->ret_void;
  s.ret_ty = fn->ret_void ? TY_INT : fn->ret_ty;
  s.ret_elem = fn->ret_elem;
  s.ret_struct = fn->ret_struct;
  s.nargs = fn->nargs;
  for (int i = 0; i < 4; i++) {
    s.param_ty[i] = fn->param_ty[i];
    s.param_sig[i] = fn->param_sig[i];
  }
  if (s.ret_ty != TY_PTR) { s.ret_elem = TY_INT; s.ret_struct = -1; }   // 与 parse_funcptr_decl 同口径
  return s;
}

// 签名比较（含"形参本身是函数指针"的递归）。返回 1/0。
// ⚠️ 参数只比**类型大类**（int/char/double/指针）：FuncSig 里没有逐参数的指向类型，
//    所以 `int*` 与 `char*` 形参会被判同签名 = v1.3.2 已知边界（写进 SPEC）。
static bool sig_equal(Program *prog, FuncSig *a, FuncSig *b) {
  if (a->ret_void != b->ret_void || a->ret_ty != b->ret_ty) return false;
  // 指向类型只对**指针返回**有意义（值返回时两侧都已归一化成 TY_INT/-1，这里再守一道，
  // 防止将来有新构造路径忘了归一化 → 同签名误判不一致）
  if (a->ret_ty == TY_PTR
      && (a->ret_elem != b->ret_elem || a->ret_struct != b->ret_struct)) return false;
  if (a->nargs != b->nargs) return false;
  for (int i = 0; i < a->nargs; i++) {
    if (a->param_ty[i] != b->param_ty[i]) return false;
    if (a->param_ty[i] == TY_FUNCPTR
        && a->param_sig[i] != FN_SIG_NONE && b->param_sig[i] != FN_SIG_NONE
        && !sig_equal(prog, &prog->sigs[a->param_sig[i]], &prog->sigs[b->param_sig[i]]))
      return false;
  }
  return true;
}
static bool sig_equal_func(Program *prog, FuncSig *a, FuncDef *fn) {
  FuncSig b = sig_of_func(fn);
  return sig_equal(prog, a, &b);
}

// 签名的人话描述（报错用）：如 `int(int, char*)`。buf 由调用方给（静态缓冲，够用）
static const char *ty_name(int ty) {
  switch (ty) {
    case TY_INT: return "int";
    case TY_CHAR: return "char";
    case TY_DOUBLE: return "double";
    case TY_INT64: return "int_64";   // v1.7.0
    case TY_PTR: return "指针";
    case TY_STRUCT: return "struct";
    case TY_FUNCPTR: return "函数指针";
    default: return "?";
  }
}
static const char *sig_desc(Program *prog, int idx) {
  static char buf[160];
  if (idx == FN_SIG_NONE) return "(未知签名)";
  FuncSig *s = &prog->sigs[idx];
  int n = snprintf(buf, sizeof(buf), "%s(", s->ret_void ? "void" : ty_name(s->ret_ty));
  for (int i = 0; i < s->nargs && n < (int)sizeof(buf) - 16; i++)
    n += snprintf(buf + n, sizeof(buf) - (size_t)n, "%s%s", i ? ", " : "",
                  s->param_ty[i] == TY_FUNCPTR ? "函数指针" : ty_name(s->param_ty[i]));
  snprintf(buf + n, sizeof(buf) - (size_t)n, ")");
  return buf;
}

// 函数指针赋值的**签名**一致性（形态合法性由 asgn_rhs 管、这里管签名——需要 Program 签名表）
//   已知边界：签名只比"类型大类"，不比指针指向类型（见 sig_equal 注释）。
static void funcptr_check_asgn(Program *prog, Node *lhs, Node *rhs, char *loc) {
  if (lhs->ty != TY_FUNCPTR || lhs->fn_sig == FN_SIG_NONE) return;
  if (rhs->kind == ND_FUNC_ADDR) {
    if (rhs->func_index < 0 || rhs->func_index >= prog->nfuncs) return;
    if (!sig_equal_func(prog, &prog->sigs[lhs->fn_sig], &prog->funcs[rhs->func_index]))
      error_at(loc, "函数指针签名不一致：'%s' 与左侧声明的 %s 不是同一套签名",
               prog->funcs[rhs->func_index].name, sig_desc(prog, lhs->fn_sig));
  } else if (rhs->kind == ND_VAR && rhs->ty == TY_FUNCPTR && rhs->fn_sig != FN_SIG_NONE) {
    if (!sig_equal(prog, &prog->sigs[lhs->fn_sig], &prog->sigs[rhs->fn_sig]))
      error_at(loc, "函数指针签名不一致：左侧 %s vs 右侧 %s",
               sig_desc(prog, lhs->fn_sig), sig_desc(prog, rhs->fn_sig));
  }
}


static Node *decl_funcptr_stmt(Parser *p, int ret_ty, int ret_elem, int ret_struct, bool ret_void) {
  FuncSig s;
  Token *name = NULL;
  p->tok = parse_funcptr_decl(&s, p->tok, ret_ty, ret_elem, ret_struct, ret_void, &name);
  if (is_punct(p->tok, '['))
    error_at(p->tok->loc, "函数指针数组暂不支持（v1.3.2 边界：回调表请用几个单独变量 + if 链）");
  if (p->scope_nest != 0)
    error_at(name->loc, "函数指针暂只支持函数顶层作用域声明（块/循环内 = v1.3.2 边界）");
  int sig = add_sig(p, s);
  LVar *v = new_lvar(p, name, false, TY_FUNCPTR, 0, -1, TY_INT);
  v->fn_sig = sig;
  if (!consume(p, '=')) return block_of(NULL);
  Node *var = new_var_node(v->offset, false, TY_FUNCPTR, -1, TY_INT);
  var->fn_sig = sig;
  Node *init = expr(p);
  // 只能接「&函数名」或另一个函数指针（C 里裸函数名也能退化成指针，FLINT 要求写出 &：见 primary 的报错）
  int rsig = FN_SIG_NONE;
  if (init->kind == ND_FUNC_ADDR) {
    FuncDef *fn = &p->prog->funcs[init->func_index];
    if (!sig_equal_func(p->prog, &p->prog->sigs[sig], fn))
      error_at(name->loc, "函数指针签名不一致：'%s' 的类型是 %s，而 '%.*s' 是另一套签名",
               fn->name, sig_desc(p->prog, sig), name->len, name->loc);
  } else if (init->kind == ND_VAR && init->ty == TY_FUNCPTR) {
    rsig = init->fn_sig;
    if (!sig_equal(p->prog, &p->prog->sigs[sig], &p->prog->sigs[rsig]))
      error_at(name->loc, "函数指针签名不一致：左边 %s vs 右边 %s",
               sig_desc(p->prog, sig), sig_desc(p->prog, rsig));
  } else {
    error_at(name->loc, "函数指针只能由「&函数名」或另一个函数指针初始化"
                        "（不能接整数 / 普通指针 / 结构体字段 / 函数调用结果）");
  }
  Node *asgn = new_node(ND_ASSIGN, var, init);
  asgn->loc = name->loc;
  return block_of(new_node(ND_EXPR_STMT, asgn, NULL));
}

// 间接调用：`fp(实参...)`（fp 是 TY_FUNCPTR 变量）——按签名表做「个数 / 双通道 / 传地址」三条检查，
// 与直接调用（primary 里的函数名分支）**逐条同口径**，否则同一份源码换个调用方式就静默传错寄存器。
static Node *parse_indirect_call(Parser *p, LVar *fp) {
  FuncSig *s = &p->prog->sigs[fp->fn_sig];
  Token *nm = p->tok;
  Node *target = new_var_node(fp->offset, false, TY_FUNCPTR, -1, TY_INT);   // 调用目标（codegen 装 rax）
  target->fn_sig = fp->fn_sig;
  p->tok = p->tok->next;              // 吃变量名
  skip(p, '(');
  Node *head = NULL;
  Node **cur = &head;
  int nargs = 0;
  if (!is_punct(p->tok, ')')) {
    for (;;) {
      if (nargs >= s->nargs)
        error_at(p->tok->loc, "实参个数超过这个函数指针的形参个数（%d 个）", s->nargs);
      Node *arg = assign(p);
      int pty = s->param_ty[nargs];
      bool by_addr = (pty == TY_PTR || pty == TY_STRUCT || pty == TY_FUNCPTR);
      if (!by_addr && pty == TY_DOUBLE) {
        arg = widen_dbl(arg);
      } else if (!by_addr && expr_is_dbl(arg)) {
        error_at(p->tok->loc, "这个形参是 int——double 实参请写 to_int(值) 显式转换（不静默截断小数）");
      }
      if (pty == TY_FUNCPTR) {
        // 实参必须是签名一致的函数指针（或未知签名 = 预扫描尚未落表的场景，放行但绝不换通道）
        int want = s->param_sig[nargs];
        if (arg->kind == ND_VAR && arg->ty == TY_FUNCPTR) {
          if (want != FN_SIG_NONE && arg->fn_sig != FN_SIG_NONE
              && !sig_equal(p->prog, &p->prog->sigs[want], &p->prog->sigs[arg->fn_sig]))
            error_at(nm->loc, "实参的函数指针签名与该形参不一致（需要 %s，给的是 %s）",
                     sig_desc(p->prog, want), sig_desc(p->prog, arg->fn_sig));
        } else if (arg->kind == ND_FUNC_ADDR) {
          if (want != FN_SIG_NONE
              && !sig_equal_func(p->prog, &p->prog->sigs[want], &p->prog->funcs[arg->func_index]))
            error_at(nm->loc, "实参函数 '&%s' 的签名与该形参不一致（需要 %s）",
                     p->prog->funcs[arg->func_index].name, sig_desc(p->prog, want));
        } else {
          error_at(nm->loc, "这个形参收的是函数指针——请传「&函数名」或函数指针变量");
        }
      }
      *cur = arg;
      cur = &arg->next;
      nargs++;
      if (!consume(p, ',')) break;
    }
  }
  skip(p, ')');
  if (nargs != s->nargs)
    error_at(p->tok->loc, "这个函数指针需要 %d 个实参，这里只给了 %d 个", s->nargs, nargs);
  Node *call = new_node(ND_CALL, target, head);
  call->func_index = -1;              // ← 间接调用的唯一判据（codegen 据此走 FF D0）
  call->fn_sig = fp->fn_sig;
  call->nargs = nargs;
  call->is_void = s->ret_void;
  call->ty = s->ret_void ? TY_INT : s->ret_ty;
  call->elem_ty = s->ret_elem;
  call->struct_idx = s->ret_struct;
  call->loc = nm->loc;
  return call;
}

// —— v0.9.1 S4 修复：-safe 下「new 必须由 own/share 接管」的统一深层检查 ——
// 决策 22 教训：检查点分散（只查 声明初始化 / 赋值 rhs / 表达式语句根 3 处）必漏——
// 实参（f(new int)）、return new int、条件、for 各段都漏过，-safe 承诺破功。
// 改法：每个语句级表达式根（声明初始化 / 表达式语句 / return / if·while·for 条件 /
// for 初始化·增量）都做一次整棵子树扫描；new 唯一合法位置 = own/share 声明
// 初始化的直接 rhs（该路径在 decl_list 内单独放行，不走本扫描），其余任何出现 = 泄漏报错。
static bool subtree_has_new(Node *n) {
  if (!n) return false;
  if (n->kind == ND_NEW) return true;
  return subtree_has_new(n->lhs) || subtree_has_new(n->rhs) || subtree_has_new(n->els)
      || subtree_has_new(n->init) || subtree_has_new(n->cond) || subtree_has_new(n->inc)
      || subtree_has_new(n->next);
}

// —— 声明符列表：修饰符 标识符 [数组] ["=" 表达式] ("," ...)* ——
// 修饰符（v0.7 单项互斥）："&" 引用（须 = 变量绑定）｜"*" 指针 ｜ 名后 "[n]" 数组（n 个 int 槽）
// 不消费结尾的 ';'（for 头复用）。普通/指针变量可选初始化 → ND_ASSIGN；
// 引用 → ND_REF_BIND（r 槽存 x 地址）；数组不支持整体初始化。
static Node *decl_list(Parser *p, int base_ty) {   // v1.0.5：base_ty = TY_INT | TY_CHAR
  Node head = {0};
  Node *cur = &head;

  for (;;) {
    // v1.3.2 函数指针声明：`int (*fp)(int);` / `int *(*fp)(int);`（指针返回）——类型词之后是 '('
    //   （或 '*' 后跟 '('）。放在最前面：`(` 在这个位置除函数指针外无第二种解释。
    if (is_punct(p->tok, '(') || (is_punct(p->tok, '*') && is_punct(p->tok->next, '('))) {
      bool ret_ptr = consume(p, '*');
      cur = cur->next = decl_funcptr_stmt(p, ret_ptr ? TY_PTR : base_ty,
                                          ret_ptr ? base_ty : TY_INT, -1, false);
      if (!consume(p, ',')) break;
      continue;
    }
    bool ref = consume(p, '&');
    bool ptr = consume(p, '*');
    if (ref && ptr)
      error_at(p->tok->loc, "引用与指针不能组合（v0.7 单修饰符）");
    // v0.9：所有权标注（int *own p / int *share p）——只修饰指针，二选一
    bool is_uni = consume_ident(p, "own");
    bool is_sh = !is_uni && consume_ident(p, "share");
    if ((is_uni || is_sh) && !ptr)
      error_at(p->tok->loc, "'own'/'share' 只能修饰指针（int *own/share p = new int;）");
    Token *name = p->tok;
    if (name->kind != TK_IDENT) error_at(name->loc, "声明后需跟变量名");
    if (is_keyword(name)) error_at(name->loc, "'%.*s' 不能作变量名", name->len, name->loc);
    p->tok = p->tok->next;

    // v1.0.5：char 基类型——数组元素/char* 指向 = 字节语义（movzx 读/低字节写）；int 系不变
    int elem = base_ty;
    int ty = ptr ? TY_PTR : base_ty;
    int arr_len = 0;
    if (is_punct(p->tok, '[')) {          // char a[N] / int a[5]
      if (ref || ptr)
        error_at(p->tok->loc, "数组暂不能与 &/* 组合（v0.7 单修饰符）");
      p->tok = p->tok->next;
      if (p->tok->kind != TK_NUM) error_at(p->tok->loc, "数组长度须为数字常量");
      arr_len = p->tok->val;
      if (arr_len <= 0) error_at(p->tok->loc, "数组长度须为正数");
      p->tok = p->tok->next;
      skip(p, ']');
      ty = TY_ARR;
    }
    // v1.0.5 已知边界：char 引用（&c 别名读写需解引用字节宽度，未入）与 char own/share（堆对象仅 int）暂拒
    if (ref && base_ty == TY_CHAR)
      error_at(name->loc, "char 引用暂不支持（可用 char* 指针或 &c 取址）");
    // v1.7.0：int_64 引用暂不支持 —— 引用读走 32 位解引用（emit_deref_eax），会把高 32 位静默丢掉。
    //   要别名 64 位值请用 int_64 *（指针在本版已开，读写走 8 字节）。
    if (ref && base_ty == TY_INT64)
      error_at(name->loc, "int_64 引用暂不支持（引用读是 32 位解引用，会静默截断）——"
                          "请用 int_64 *p = &x; 显式指针");
    if ((is_uni || is_sh) && base_ty == TY_CHAR)
      error_at(name->loc, "'own'/'share' 只能修饰 int*（char 无堆所有权语义）");
    LVar *v = new_lvar(p, name, ref, ty, arr_len, -1, elem);
    bool had_init = ref;   // v1.4.25：这条声明最终有没有初值（strict 未初始化检查的判据）
    if (is_uni || is_sh) {
      if (p->scope_nest != 0)
        error_at(name->loc, "own/share 指针暂只支持函数顶层作用域声明（块/循环内 = 已知边界 v0.9）");
      if (is_uni) v->is_own = true;
      else v->is_share = true;
    }

    if (ref) {
      // 引用绑定：int &r = x;（x 必须变量；x 是引用/数组则绑定其对象/首元素）
      if (!consume(p, '='))
        error_at(name->loc, "引用必须初始化（int &r = x;）");
      Node *init = expr(p);
      if (init->kind != ND_VAR)
        error_at(p->tok->loc, "引用只能绑定变量（int &r = x; / double &r = d;）");
      // v1.2.5：引用两侧类型必须一致——别名不改变对象的字节宽度，混着绑会静默读半截/读错位型
      if (base_ty == TY_DOUBLE && init->ty != TY_DOUBLE)
        error_at(name->loc, "double 引用只能绑定 double 变量（int 槽只有 4 字节 → 按 double 读 8 字节会读到别的位型）");
      if (base_ty != TY_DOUBLE && init->ty == TY_DOUBLE)
        error_at(name->loc, "int 引用不能绑定 double 变量（会静默按 32 位读错值）——请写 double &r = 那个变量;");
      // v1.2.5：绑定节点的类型跟 base_ty（double& 读 r 时按 8 字节 SSE 解引用，见 codegen）
      Node *bind = new_node(ND_REF_BIND, new_var_node(v->offset, true, base_ty, -1, base_ty), init);
      cur = cur->next = new_node(ND_EXPR_STMT, bind, NULL);
    } else if (ty == TY_ARR) {
      if (consume(p, '='))
        error_at(p->tok->loc, "数组暂不支持整体初始化（v0.7 用 a[i] = v 逐元素）");
    } else if (v->is_own) {
      // v0.9 own：必须 = new（对象带头部布局；拷贝初始化禁止）
      if (!consume(p, '='))
        error_at(name->loc, "own 指针必须由 new 初始化（int *own p = new int;）");
      Node *init = expr(p);
      if (init->kind != ND_NEW)
        error_at(name->loc, "own 指针只能由 new 初始化（独占所有权，禁止拷贝）");
      Node *var = new_var_node(v->offset, false, v->ty, v->struct_idx, v->elem_ty);
      var->is_own = true;   // codegen 出口清理收集用
      Node *asgn = new_node(ND_ASSIGN, var, init);
      cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
    } else if (v->is_share) {
      // v0.9 share：= new int（refcount 起点 1）或 = share 变量（拷贝 +1）
      if (!consume(p, '='))
        error_at(name->loc, "share 指针必须初始化（int *share p = new int; 或 = share 变量）");
      Node *init = expr(p);
      Node *var = new_var_node(v->offset, false, v->ty, v->struct_idx, v->elem_ty);
      var->is_share = true;   // codegen 出口清理收集用
      if (init->kind == ND_NEW) {
        Node *asgn = new_node(ND_ASSIGN, var, init);
        cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
      } else if (init->kind == ND_VAR && init->is_share) {
        // 共享拷贝：q 槽 = p 值 + [p-8] refcount++
        Node *acq = new_node(ND_SHARED_ACQUIRE, var, init);
        cur = cur->next = new_node(ND_EXPR_STMT, acq, NULL);
      } else {
        error_at(name->loc, "share 指针只能由 new 或 share 变量初始化（拷贝需共享所有权）");
      }
    } else if ((had_init = consume(p, '='))) {
      Node *var = new_var_node(v->offset, false, v->ty, v->struct_idx, v->elem_ty);
      if (ty == TY_PTR && is_str_call(p->tok)) {
        // v1.5.0：char *s = str([...]); —— 指针声明的初始化（展开成语句链；非指针声明落到下面 → 响亮报错）
        str_decl_init(p, &cur, var, name);
      } else {
        Node *init = expr(p);
        if (init->kind == ND_VAR && (init->is_own || init->is_share))
          error_at(name->loc, "own/share 指针不能拷贝给裸指针（请用 int *own/share q = p; 声明接管）");
        if (flint_safe_mode && subtree_has_new(init))
          error_at(name->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（裸指针持有会泄漏）");
        // v1.1.0 浮点修（bug a）：声明带初始化原先**直接建 ND_ASSIGN**，没过 asgn_rhs →
        // ① `int n = 7.5;` 静默把 double 位模式漏进 int 槽（1073745920）
        // ② `double d = 2;` 漏掉 int→double 提升，存进去的是"整数 2 的位模式"（≈1e-323）
        // 两者共用同一道处理：double 左值接 int 右值自动提升；反向必须显式 to_int。
        init = asgn_rhs(var, init, name->loc);
        Node *asgn = new_node(ND_ASSIGN, var, init);
        asgn->loc = name->loc;   // v1.0.13：T1 存取宽度/指针目标门槛的报错要指到变量名
        cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
      }
    }
    // v1.4.25（`-strict`）：标量声明且这一路**没吃到 '='** ⇒ 记「声明时无初值」。
    //   只标标量：数组/结构体靠 &x / 逐元素写，追"整块有没有被写过"误报太多，不进第一档。
    if (!had_init && (ty == TY_INT || ty == TY_CHAR || ty == TY_DOUBLE || ty == TY_INT64
                      || ty == TY_PTR || ty == TY_FUNCPTR))
      v->no_init = true;
    if (!consume(p, ',')) break;
  }
  return block_of(head.next);   // 无初始化时为空块（无指令）
}

// —— 语句 ——
// v1.4.11（`-debug`）：语句行号靠一层 wrapper —— 进语句时把"当前语句起始位置"记进 g_stmt_loc，
//   出语句时**恢复**上一层。为什么必须显式恢复：语句里的嵌套语句（块/循环体）会把它改成内层位置，
//   若不恢复，外层语句后续创建的子节点就会被算成内层那一行（行号错、且错得没有规律）。
static Node *stmt_inner(Parser *p);

static Node *stmt(Parser *p) {
  char *saved = g_stmt_loc;
  g_stmt_loc = p->tok ? p->tok->loc : NULL;
  Node *n = stmt_inner(p);
  g_stmt_loc = saved;
  return n;
}

static Node *stmt_inner(Parser *p) {
  Node *node;

  // return [表达式]; —— v0.6：void 函数可 return;（无表达式）
  if (is_ident(p->tok, "return")) {
    p->tok = p->tok->next;
    if (consume(p, ';')) {
      if (!p->fn_ret_void)
        error_at(p->tok->loc, "'return;' 只能用在 void 函数");
      return new_node(ND_RETURN, NULL, NULL);
    }
    if (p->fn_ret_void)
      error_at(p->tok->loc, "void 函数不能 return 表达式");
    // v1.5.0：return str([...]); —— 只在指针返回函数里（展开成语句链 + ND_RETURN）
    if (is_str_call(p->tok)) {
      if (p->fn_ret_ty != TY_PTR)
        error_at(p->tok->loc, "str([...]) 只在 ① 指针变量声明初始化（char *s = str([...]);）"
                              "② 赋值语句右值（s = str([...]);）③ **指针返回函数**的 return 值 —— 这 3 个位置可用；"
                              "本函数的返回类型不是 char*/int*（return str([...]) 不成立：那是地址，不是数值）");
      return str_return_stmt(p);
    }
    Token *rt0 = p->tok;
    Node *e = expr(p);
    if (flint_safe_mode && subtree_has_new(e))
      error_at(rt0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（return 直接泄漏）");
    // v1.0.6.2 盲区审计 A3：return own/share 变量 = 所有权逃逸——出口清理立即释放/归零，
    // caller 拿到悬垂指针（静默 UAF；同族：作实参已拦，return 漏网）
    if (e->kind == ND_VAR && (e->is_own || e->is_share))
      error_at(rt0->loc, e->is_own
        ? "own 指针不能作 return 值（出口自动释放 → 悬垂；所有权转移特性 = 已知边界）"
        : "share 指针不能作 return 值（引用计数随函数出口管理，caller 无 +1 → 悬垂；return 转移特性 = 已知边界）");
    skip(p, ';');
    // v1.2.1 double 阶段2：返回类型 double → 返回值必须按 double 出去（结果在 xmm0）
    //   int 表达式自动提升 = 与 asgn_rhs / MKbin 同一条规则（C 语义，不静默丢精度）
    e = p->fn_ret_dbl ? expr_widen_dbl(e) : e;
    // v1.2.1：int 返回函数 return double 值 → 编译期报错（与「赋值给 int」同口径：不静默截断）。
    //   原实现会静默走 cvttsd2si 截断（`int f(){return 1.5;}` 得 1）——SPEC 红线是「拿不准就报错」。
    //   double 返回函数此时 e 已被 expr_widen_dbl 包成 double，不受本检查影响。
    if (!p->fn_ret_void && !p->fn_ret_dbl && e && expr_is_dbl(e))
      error_at(rt0->loc, "不能把 double 值 return 给 int 返回函数（会静默截断小数）——请显式写 to_int(值)，或把函数返回类型改成 double");
    // v1.7.0：int_64 返回通道（与 asgn_rhs 同口径：拓宽隐式、收窄硬错、不碰 double）
    if (!p->fn_ret_void && p->fn_ret_ty == TY_INT64 && e) {
      if (expr_is_dbl(e))
        error_at(rt0->loc, "不能把 double 值 return 给 int_64 返回函数（P0/P1 不支持两者互转）");
      e = parse_is_addr_value(e) ? e : widen_i64(e);   // 地址值原样（已是完整 64 位）
    } else if (!p->fn_ret_void && e && expr_is_i64(e)) {
      error_at(rt0->loc, "不能把 int_64 值 return 给 int 返回函数（会静默截断高 32 位："
                         "值超出 int 范围的部分丢掉）——"
                         "请显式写 to_int32(值)，或把返回类型改成 int_64");
    }
    return new_node(ND_RETURN, e, NULL);
  }

  // v1.0.8：print 内建输出语句 —— print([段, ...] [, 换行])
  // 形态：print ( [ 表达式 (, 表达式)* ] (, 0|1)? ) ;   段类型自适应分派
  if (is_ident(p->tok, "print") && p->tok->next && is_punct(p->tok->next, '(')
      && p->tok->next->next && is_punct(p->tok->next->next, '[')) {
    return print_stmt(p);
  }

  // v1.2.0 循环控制（C 语义，只管最内层循环）：break; / continue;
  // 循环外使用 = 编译期报错（不做"静默跳到底"那种猜——SPEC 红线：拿不准就报错）
  // v1.3.1：break 在 switch 里也合法（跳 switch 末尾）；**continue 不算**——switch 不是循环，
  //   `switch` 里的 continue 跳的是外层那个 while/for（C 语义），所以仍要求 loop_nest > 0。
  if (is_ident(p->tok, "break") || is_ident(p->tok, "continue")) {
    bool is_brk = is_ident(p->tok, "break");
    Token *kw = p->tok;
    if (is_keyword(kw))
      error_at(kw->loc, "'%.*s' 不能作变量名", kw->len, kw->loc);
    p->tok = p->tok->next;
    if (is_brk && p->loop_nest == 0 && p->switch_nest == 0)
      error_at(kw->loc, "break 只能用在循环（while / for）或 switch 里"
                        "（编译器不会替你猜跳哪里）");
    if (!is_brk && p->loop_nest == 0)
      error_at(kw->loc, p->switch_nest > 0
        ? "continue 在 switch 里没有意义（switch 不是循环——它跳的是外层循环，这里没有外层循环；"
          "要跳出 switch 用 break）"
        : "continue 只能用在循环里（while / for 内；编译器不会替你猜跳哪里）");
    skip(p, ';');
    return new_node(is_brk ? ND_BREAK : ND_CONTINUE, NULL, NULL);
  }

  // v1.3.2：void 返回的函数指针声明（`void (*fp)(int);`）——`void` 作变量类型的唯一合法位置
  if (is_ident(p->tok, "void") && is_punct(p->tok->next, '(')) {
    p->tok = p->tok->next;
    Node *d = decl_funcptr_stmt(p, TY_INT, TY_INT, -1, true);
    skip(p, ';');
    return block_of(d);
  }

  // int_64 声明符列表;（v1.7.0）——必须排在 "int" 之前识别：is_ident 是整词比较，
  //   "int" 匹配不到 "int_64"，但顺序上放前面读代码的人不用想。
  if (is_ident(p->tok, "int_64")) {
    p->tok = p->tok->next;
    node = decl_list(p, TY_INT64);
    skip(p, ';');
    return node;
  }

  // int 声明符列表;
  if (is_ident(p->tok, "int")) {
    p->tok = p->tok->next;
    node = decl_list(p, TY_INT);
    skip(p, ';');
    return node;
  }

  // v1.0.5 B 档：char 声明符列表（字节变量/char 数组/char* 指针）
  if (is_ident(p->tok, "char")) {
    p->tok = p->tok->next;
    node = decl_list(p, TY_CHAR);
    skip(p, ';');
    return node;
  }

  // v1.1.0 浮点：double 声明（double d; / double d = 1.5; / v1.2.4 起 double a[N] 数组；
  //   指针/引用仍未开 = 已知边界）
  if (is_ident(p->tok, "double")) {
    p->tok = p->tok->next;
    node = decl_list(p, TY_DOUBLE);
    skip(p, ';');
    return node;
  }

  // struct 类型变量声明：struct S v;（先定义后使用；无整体初始化）
  if (is_ident(p->tok, "struct")) {
    p->tok = p->tok->next;
    if (p->tok->kind != TK_IDENT || is_keyword(p->tok))
      error_at(p->tok->loc, "struct 后需跟类型名");
    int sidx = find_struct(p->prog, p->tok);
    if (sidx < 0)
      error_at(p->tok->loc, "未定义的结构体类型 '%.*s'（struct 须先定义后使用）", p->tok->len, p->tok->loc);
    p->tok = p->tok->next;
    Token *vn = p->tok;
    if (vn->kind != TK_IDENT || is_keyword(vn))
      error_at(vn->loc, "期望变量名");
    if (is_punct(p->tok->next, '['))
      error_at(vn->loc, "struct 数组暂不支持（v0.7.x 单变量）");
    new_lvar(p, vn, false, TY_STRUCT, 0, sidx, TY_INT);   // 登记变量（无初始化，无后续引用）
    p->tok = p->tok->next;
    if (consume(p, '='))
      error_at(p->tok->loc, "结构体暂不支持整体初始化（逐字段赋值）");
    skip(p, ';');
    return block_of(NULL);
  }

  // 块 { 语句* }（新作用域）
  if (is_punct(p->tok, '{')) {
    p->tok = p->tok->next;
    scope_push(p);
    p->scope_nest++;
    Node head = {0};
    Node *cur = &head;
    while (!is_punct(p->tok, '}')) {
      if (p->tok->kind == TK_EOF) error_at(p->tok->loc, "块缺少右花括号 '}'");
      cur = cur->next = stmt(p);
    }
    p->scope_nest--;
    scope_pop(p);
    skip(p, '}');
    return block_of(head.next);
  }

  // if (cond) then [else els]
  if (is_ident(p->tok, "if")) {
    p->tok = p->tok->next;
    skip(p, '(');
    Token *cd0 = p->tok;
    Node *cond = expr(p);
    if (flint_safe_mode && subtree_has_new(cond))
      error_at(cd0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（条件里泄漏）");
    skip(p, ')');
    p->scope_nest++;
    Node *then = stmt(p);
    Node *els = NULL;
    if (is_ident(p->tok, "else")) {
      p->tok = p->tok->next;
      els = stmt(p);
    }
    p->scope_nest--;
    node = new_node(ND_IF, cond, then);
    node->els = els;
    return node;
  }

  // while (cond) body
  if (is_ident(p->tok, "while")) {
    p->tok = p->tok->next;
    skip(p, '(');
    Token *cd0 = p->tok;
    Node *cond = expr(p);
    if (flint_safe_mode && subtree_has_new(cond))
      error_at(cd0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（条件里泄漏）");
    skip(p, ')');
    p->scope_nest++;
    p->loop_nest++;          // v1.2.0：循环体里 break/continue 合法
    Node *body = stmt(p);
    p->loop_nest--;
    p->scope_nest--;
    return new_node(ND_WHILE, cond, body);
  }

  // for (init?; cond?; inc?) body —— for 头建作用域（int i 只在 for 内可见）
  if (is_ident(p->tok, "for")) {
    p->tok = p->tok->next;
    skip(p, '(');
    scope_push(p);   // for 作用域：init 声明 + cond + body 都可见
    p->scope_nest++;
    p->loop_nest++;  // v1.2.0：for 体里 break/continue 合法（body 解析完 --）

    Node *init = NULL;
    if (is_ident(p->tok, "int") || is_ident(p->tok, "char") || is_ident(p->tok, "int_64")) {
      int fbase = is_ident(p->tok, "char") ? TY_CHAR
                : is_ident(p->tok, "int_64") ? TY_INT64 : TY_INT;   // v1.7.0：for 头可声明 int_64
      p->tok = p->tok->next;
      init = decl_list(p, fbase);  // 不消费 ';'（for 的分号由下面 skip）
    } else if (!is_punct(p->tok, ';')) {
      Token *i0 = p->tok;
      Node *ie = expr(p);
      if (flint_safe_mode && subtree_has_new(ie))
        error_at(i0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（for 初始化泄漏）");
      init = new_node(ND_EXPR_STMT, ie, NULL);
    }
    skip(p, ';');

    Node *cond = NULL;
    if (!is_punct(p->tok, ';')) {
      Token *c0 = p->tok;
      Node *ce = expr(p);
      if (flint_safe_mode && subtree_has_new(ce))
        error_at(c0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（for 条件泄漏）");
      cond = ce;
    }
    skip(p, ';');

    Node *inc = NULL;
    if (!is_punct(p->tok, ')')) {
      Token *n0 = p->tok;
      Node *ne = expr(p);
      if (flint_safe_mode && subtree_has_new(ne))
        error_at(n0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（for 增量泄漏）");
      inc = new_node(ND_EXPR_STMT, ne, NULL);
    }
    skip(p, ')');

    Node *body = stmt(p);      // body 若为块，内部再 push 一层
    p->loop_nest--;            // v1.2.0：循环体范围结束（body 解析完就恢复）
    p->scope_nest--;
    scope_pop(p);              // for 作用域结束

    Node *f = new_node(ND_FOR, NULL, body);
    f->init = init;
    f->cond = cond;
    f->inc = inc;
    return f;
  }

  // v1.3.1：switch (整型表达式) { case 常量: 语句... default: 语句... }
  // 设计要点（与 C 一致，不做"聪明"的改动）：
  //   · **扁平链**：switch 的 rhs 是一条语句链，case/default 只是链上的**标记节点**（ND_CASE），
  //     段的内容 = 标记后面的兄弟语句 → 段间**贯穿 fallthrough** 天然成立（写不写 break 由用户决定）。
  //   · case 值必须是编译期整型常量（十进制/0x/字符字面量，可带一元负号）——变量/表达式报错。
  //   · case 之前出现语句 = 报错（那段代码永远不可达；编译器不替你静默丢弃也不替你猜归属）。
  //   · 重复 case 常量 / 多于一个 default = 报错；case 上限 64（v1.3.1 边界，超出明确报错）。
  //   · break 归 switch（见 break 分支）；**continue 不属于 switch**——它穿透到外层循环（C 语义）。
  if (is_ident(p->tok, "switch")) {
    Token *sw0 = p->tok;
    p->tok = p->tok->next;
    skip(p, '(');
    Token *cd0 = p->tok;
    Node *cond = expr(p);
    if (flint_safe_mode && subtree_has_new(cond))
      error_at(cd0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（switch 条件里泄漏）");
    if (is_dbl_node(cond))
      error_at(cd0->loc, "switch 的条件不支持 double（相等比较要按位型，浮点不行）——"
                         "请用整数，或先 to_int(值)（注意那是截断取整）");
    // v1.7.0：switch 的排表是 32 位（cmp eax,imm32）⇒ int_64 条件会静默截断，明确报错
    if (expr_is_i64(cond))
      error_at(cd0->loc, "switch 的条件暂不支持 int_64（v1.7.0 P0 边界：跳转表是 32 位比较）——"
                         "请先 to_int32(值)，或改写成 if/else 链");
    skip(p, ')');
    skip(p, '{');
    scope_push(p);
    p->scope_nest++;
    p->switch_nest++;
    Node head = {0};
    Node *cur = &head;
    bool seen_case = false, seen_default = false;
    int case_vals[64];
    int ncase = 0;
    while (!is_punct(p->tok, '}')) {
      if (p->tok->kind == TK_EOF)
        error_at(p->tok->loc, "switch 缺少右花括号 '}'");
      if (is_ident(p->tok, "case") || is_ident(p->tok, "default")) {
        bool is_def = is_ident(p->tok, "default");
        Token *kw = p->tok;
        p->tok = p->tok->next;
        int v = 0;
        if (is_def) {
          if (seen_default)
            error_at(kw->loc, "switch 里只能有一个 default");
          seen_default = true;
        } else {
          bool neg = false;
          if (is_punct(p->tok, '-')) { neg = true; p->tok = p->tok->next; }
          else if (is_punct(p->tok, '+')) p->tok = p->tok->next;
          if (p->tok->kind != TK_NUM)
            error_at(p->tok->loc, "case 标签必须是整型常量（case 3: / case -1: / case 'a':）"
                                  "——变量、函数调用、运算表达式都不行（switch 要在编译期排跳转表）");
          v = neg ? -p->tok->val : p->tok->val;
          p->tok = p->tok->next;
          for (int i = 0; i < ncase; i++)
            if (case_vals[i] == v)
              error_at(kw->loc, "case 常量 %d 重复（同一个值写两次，先写的那段永远不会被选中）", v);
          if (ncase >= 64)
            error_at(kw->loc, "switch 的 case 分支上限 64（v1.3.1 边界）");
          case_vals[ncase++] = v;
        }
        if (!is_punct(p->tok, ':'))
          error_at(p->tok->loc, "case/default 标签后应为 ':'——case 只能跟一个**整型常量**"
                                "（case 1 + 1: / case n: 这类都不行，编译期要按常量发比较指令）");
        p->tok = p->tok->next;
        Node *c = new_node(ND_CASE, NULL, NULL);
        c->val = v;
        c->is_default = is_def;
        cur = cur->next = c;
        seen_case = true;
        continue;
      }
      if (!seen_case)
        error_at(p->tok->loc, "switch 里 case/default 之前的语句永远执行不到——"
                              "编译器不替你猜它属于哪一段（请把它移到某个 case 之后）");
      cur = cur->next = stmt(p);
    }
    p->switch_nest--;
    p->scope_nest--;
    scope_pop(p);
    skip(p, '}');
    (void)sw0;   // 空 switch（无 case）= 合法语法、什么都不做（不报警：C 也这么算，且没有"猜错"的空间）
    return new_node(ND_SWITCH, cond, head.next);
  }

  // v1.5.0：`s = str([...]);` —— 赋值右值（左值必须是已声明的 char*/int* 指针变量）。
  //   必须在通用表达式语句**之前**按语句形态识别：str 的展开是一串语句（复位缓冲 + 逐段追加 + 赋值），
  //   夹进表达式求值序里就会与实参求值顺序打架（实测过：嵌套调用链会静默拼错）。
  if (p->tok->kind == TK_IDENT && is_punct(p->tok->next, '=')
      && is_str_call(p->tok->next->next))
    return str_assign_stmt(p);

  // 表达式语句
  {
    Token *e0 = p->tok;
    Node *e = expr(p);
    if (flint_safe_mode && subtree_has_new(e))
      error_at(e0->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（此处丢弃会泄漏）");
    node = new_node(ND_EXPR_STMT, e, NULL);
  }
  skip(p, ';');
  return node;
}

// —— 表达式层级 ——
static Node *expr(Parser *p) { return assign(p); }

// 左值：可写的目标 = 变量（非数组/结构体名）或解引用（*p、a[i]、p.x 展开）
static bool is_lvalue(Node *n) {
  if (n->kind == ND_DEREF) return true;
  if (n->kind == ND_VAR) return n->ty != TY_ARR && n->ty != TY_STRUCT; // 数组/结构体名不可整体赋值
  return false;
}

// v0.9.2：指针字段（deref ty==TY_PTR，如 s.hwnd）禁 ++/--/复合赋值——这些路径走 32 位
// 内存操作，会截断 64 位字段；普通赋值 s.f = 地址已支持 64 位宽（S2 修复）
static void check_field_incr(Parser *p, Node *lv) {
  // v1.3.2：函数指针不能当整数算 —— ++/--/复合赋值 的整数路径会把 64 位代码地址按 32 位算坏（静默）
  if (lv->ty == TY_FUNCPTR)
    error_at(p->tok->loc, "函数指针不支持 ++/--/复合赋值（代码地址不能参与整数运算）");
  if (lv->kind == ND_DEREF && lv->ty == TY_PTR)
    error_at(p->tok->loc, "指针字段暂不支持 ++/--/复合赋值（v0.9.2 边界；用 s.f = s.f ± n 整体赋值）");
}
// v1.2.4：double 的 ++/-- 尚未实现 —— codegen 的整数自增路径会把 8 字节 double 槽当 **32 位**读-改-写
// （典型"编译过、静默错值"）→ 显式拒收。复合赋值 `d += 1.0` 已支持，写法不受限。
static void check_dbl_incr(Parser *p, Node *lv) {
  if (lv->ty == TY_DOUBLE)
    error_at(p->tok->loc, "double 的 ++/-- 暂不支持（请写 d += 1.0 或 d = d + 1.0）");
}

// ===== v1.3.1 三元 cond ? a : b =====
// 语义（C 一致）：条件先求值，**只求值被选中的那一支**；右结合（a ? b : c ? d : e = a ? b : (c ? d : e)）。
// 类型规则（拿不准就报错，绝不静默截断——SPEC 红线）：
//   ① 任一支是 double → 另一支自动提升 int→double（同 asgn_rhs/mkbin 的口径），结果 double；
//   ② 两支都是地址类 → 结果按指针（64 位值语义）；指向类型必须一致（int* 与 char* 混 = 报错）；
//   ③ 一支地址、一支整数 → 报错（C 允许 `c ? p : 0` 这类写法，FLINT 要求写清类型，别让编译器猜宽度）；
//   ④ 其余按 int（char 参与运算同样提升为 int）。
//
// 为什么必须自己判「地址类」而不是只看 node->ty：&x / 数组名 / 字符串 / 函数地址这些节点 ty 是 0(=TY_INT)，
//   若按 int 落档，64 位地址走 32 位路径 = 静默截断（v1.0.13 T1 家族的同一种病）。
typedef struct { bool is_addr; int elem; int sidx; } TernAddr;
static void tern_addr_info(Node *n, TernAddr *out) {
  out->is_addr = false; out->elem = TY_INT; out->sidx = -1;
  if (!n) return;
  switch (n->kind) {
    case ND_STR: out->is_addr = true; out->elem = TY_CHAR; return;   // 字符串字面量 = char*
    case ND_FUNC_ADDR: out->is_addr = true; out->elem = TY_INT; return;
    case ND_ADDR: {
      out->is_addr = true;
      Node *o = n->lhs;
      if (o && o->kind == ND_VAR) {
        out->elem = (o->ty == TY_ARR) ? o->elem_ty : o->ty;
        out->sidx = (o->ty == TY_STRUCT) ? o->struct_idx : -1;
      } else if (o && o->kind == ND_DEREF) {
        out->elem = o->ty; out->sidx = o->struct_idx;
      }
      return;
    }
    case ND_VAR:
      if (n->is_ref) {                    // 引用读 = 别名对象的值；struct& 读 = 对象地址
        if (n->ty == TY_STRUCT) { out->is_addr = true; out->elem = TY_STRUCT; out->sidx = n->struct_idx; }
        return;
      }
      if (n->ty == TY_PTR || n->ty == TY_ARR || n->ty == TY_STRUCT) {
        out->is_addr = true;
        // ⚠️ 指向类型在 **elem_ty**（不是 ty！）——`int *p` 的 elem_ty=TY_INT、`char *q` 的 =TY_CHAR。
        //    首版这里写成 out->elem = n->ty（即 TY_PTR），于是 int* 与 char* 被判成"同类型"，
        //    负例 nt_tern_ptrmix 当场变红才抓到（正是这条负例存在的意义）。
        if (n->ty == TY_STRUCT) { out->elem = TY_STRUCT; out->sidx = n->struct_idx; }
        else { out->elem = n->elem_ty; out->sidx = (n->ty == TY_PTR) ? n->struct_idx : -1; }
      }
      return;
    case ND_DEREF: case ND_CALL: case ND_APICALL:
      if (n->ty == TY_PTR) { out->is_addr = true; out->elem = n->elem_ty; out->sidx = n->struct_idx; }
      return;
    case ND_NEW: out->is_addr = true; out->elem = TY_INT; return;
    // v1.8.0 C 风格转型：(T*)p 是地址值，指向类型来自节点（与 ND_VAR 的 TY_PTR 同口径：
    //   指向类型在 elem_ty —— 不是 ty）。
    case ND_CAST:
      if (n->ty == TY_PTR) { out->is_addr = true; out->elem = n->elem_ty; out->sidx = n->struct_idx; }
      return;
    case ND_ASSIGN: tern_addr_info(n->rhs, out); return;   // 赋值表达式的值 = 被赋的值
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      tern_addr_info(n->lhs, out); return;
    case ND_ADD: {
      TernAddr l = {0}, r = {0};
      tern_addr_info(n->lhs, &l); tern_addr_info(n->rhs, &r);
      *out = l.is_addr ? l : r;
      return;
    }
    case ND_SUB: {
      TernAddr l = {0}, r = {0};
      tern_addr_info(n->lhs, &l); tern_addr_info(n->rhs, &r);
      if (l.is_addr && r.is_addr) return;    // 地址 − 地址 = 差值（标量，不是地址）
      *out = l.is_addr ? l : r;
      return;
    }
    default: return;
  }
}

// v1.7.0：asgn_rhs 用的「值是不是地址」判据（唯一出处 = 上面那个 tern_addr_info）
static bool parse_is_addr_value(Node *n) {
  TernAddr t = {0};
  tern_addr_info(n, &t);
  return t.is_addr;
}

// ternary = logor ("?" expr ":" ternary)?      （右结合；中间是真分支的完整表达式）
static Node *ternary(Parser *p) {
  Node *cond = logor(p);
  if (!is_punct(p->tok, '?')) return cond;
  Token *q0 = p->tok;
  p->tok = p->tok->next;
  Node *a = expr(p);
  if (!is_punct(p->tok, ':'))
    error_at(p->tok->loc, "三元 ?: 缺少 ':'（写法：条件 ? 真值 : 假值）");
  p->tok = p->tok->next;
  Node *b = ternary(p);                 // 右结合：假分支继续吃三元
  if (flint_safe_mode && (subtree_has_new(a) || subtree_has_new(b)))
    error_at(q0->loc, "安全模式（-safe）：三元分支里的 new 必须由 own/share 接管（此处丢弃会泄漏）");
  TernAddr ta = {0}, tb = {0};
  tern_addr_info(a, &ta);
  tern_addr_info(b, &tb);
  // v1.3.2：函数指针分支不做 —— 三元只能表达"值/地址两类"，而函数指针还带**签名**，
  //   落成通用的 TY_PTR 会把签名丢掉（后续调用就没人检查了）→ 明确报错，别静默退化。
  if ((a->kind == ND_VAR && a->ty == TY_FUNCPTR) || a->kind == ND_FUNC_ADDR
      || (b->kind == ND_VAR && b->ty == TY_FUNCPTR) || b->kind == ND_FUNC_ADDR)
    error_at(q0->loc, "三元的函数指针分支暂不支持（v1.3.2 边界：签名会被丢掉）——"
                      "请用 if/else 给函数指针变量赋值");
  if (ta.is_addr != tb.is_addr)
    error_at(q0->loc, "三元两分支类型不一致：一边是地址（指针/数组/&x/字符串），一边是整数——"
                      "请显式统一（如 to_int(值)，或先用指针变量承接地址）");
  Node *n = new_node(ND_TERN, cond, a);
  n->els = b;
  n->loc = q0->loc;
  if (ta.is_addr) {
    if (ta.elem != tb.elem || ta.sidx != tb.sidx)
      error_at(q0->loc, "三元两分支的指针指向类型不一致（如 int* 与 char*）——解引用宽度不同，编译器不替你猜");
    n->ty = TY_PTR; n->elem_ty = ta.elem; n->struct_idx = ta.sidx;
    return n;
  }
  if (is_dbl_node(a) || is_dbl_node(b)) {
    n->rhs = widen_dbl(a);              // int 侧自动提升（C 语义，与 mkbin/asgn_rhs 同一口径）
    n->els = widen_dbl(b);
    n->ty = TY_DOUBLE;
    return n;
  }
  // v1.7.0：两支都是 int_64（或一支 int_64）⇒ 结果 int_64，int 侧包 ND_I2L
  //   （与 double 同一条提升口径；codegen 的 ND_TERN 直接读 ty，不重推两分支）
  if (expr_is_i64(a) || expr_is_i64(b)) {
    n->rhs = widen_i64(a);
    n->els = widen_i64(b);
    n->ty = TY_INT64;
    return n;
  }
  n->ty = TY_INT;                       // char 也提升为 int（同「char 参与运算」的既有口径）
  return n;
}

// assign = ternary (赋值运算符 assign)?   （右结合；左值必须变量或解引用）
static Node *assign(Parser *p) {
  Node *node = ternary(p);
  // 复合赋值表：符号 → 节点类型（kind）+ 对应的**二元**节点类型（bin：int_64 摊平时要用）
  struct { char *op; NodeKind kind; NodeKind bin; } compound[] = {
    { "+=", ND_ADD_ASSIGN, ND_ADD }, { "-=", ND_SUB_ASSIGN, ND_SUB },
    { "*=", ND_MUL_ASSIGN, ND_MUL }, { "/=", ND_DIV_ASSIGN, ND_DIV },
    { "%=", ND_MOD_ASSIGN, ND_MOD },
    // v0.7.2 位复合赋值
    { "&=", ND_AND_ASSIGN, ND_BITAND }, { "|=", ND_OR_ASSIGN, ND_BITOR },
    { "^=", ND_XOR_ASSIGN, ND_BITXOR },
    { "<<=", ND_SHL_ASSIGN, ND_SHL }, { ">>=", ND_SHR_ASSIGN, ND_SHR },
  };
  for (int i = 0; i < 10; i++) {
    if (consume_str(p, compound[i].op)) {
      if (!is_lvalue(node))
        error_at(p->tok->loc, "赋值左边必须是变量或 *p/a[i]");
      if (node->kind == ND_VAR && (node->is_own || node->is_share))
        error_at(p->tok->loc, "own/share 指针不能复合赋值（所有权由声明初始化 + 出口自动释放管理）");
      check_field_incr(p, node);   // v0.9.2：指针字段禁复合赋值（32 位路径会截断）
      // ===== v1.7.0 P2：int_64 的复合赋值 = 源码层摊平（决策 D11），codegen 一行未加 =====
      //   `LV op= RHS` ⇒ `t = &LV; *t = *t op RHS`（t = 本函数帧里一个**匿名** int_64* 槽）。
      //   摊平后落到的全是**已有**通路：ND_ADDR / ND_ASSIGN（int_64 间接目标 = 64 位写）/
      //   ND_DEREF（int_64 读 = 8 字节）/ 二元运算（P1 的 64 位发射器）——不新增 codegen 通路。
      //   ⚠️ 为什么不是朴素地抄一遍左值（`LV = LV op RHS`）：那样 `a[i++] += 1` 会把 i 加两次、
      //   `a[ix()] += 1` 会调两次 ix()。这里 &LV 在展开树里**只出现一次** ⇒ 左值恰好求值一次
      //   （f041_i64_compound_evalonce.fl 用调用计数器把这条钉成判据）。
      //   二元提升口径不在这里另写一份：算术走 mkbin、位/移位走 mkintbin（与 `x = x op y` 逐条一致，
      //   含「int_64 与 double 不能混算」「位运算不收 double」两条硬错）。
      //   帧槽是匿名的（不入符号表）：不与用户变量重名，-strict 的未初始化检查按 lv_by_offset
      //   找不到它 ⇒ 放行（见 strict_read 的「不是局部量」分支）。
      if (expr_is_i64(node)) {
        Node *crhs = assign(p);   // 右结合：`x += (y += 2)` 照旧
        return i64_compound(p, node, compound[i].bin, crhs, p->tok->loc);
      }
      // v1.2.4 浮点：double 左值的复合赋值支持 += -= *= /=（值走 SSE，见 codegen 的同名分支）；
      //   %= 与位运算/移位对浮点无意义 → 编译期报错（绝不静默按整数位算）。反向（int 左值收 double
      //   右值）由下面的 asgn_rhs 拦（不能把 double 赋给 int）。
      if (is_dbl_node(node)
          && !(compound[i].kind == ND_ADD_ASSIGN || compound[i].kind == ND_SUB_ASSIGN
            || compound[i].kind == ND_MUL_ASSIGN || compound[i].kind == ND_DIV_ASSIGN))
        error_at(p->tok->loc, "double 只支持 += -= *= /=（%%= 与位运算/移位是整数运算，请写 d = d * 2.0 这类形式）");
      Node *crhs = assign(p);
      // ⚠️ 必须**接住** asgn_rhs 的返回值：它不只报错，还会把 int 右值包成 double（int→double 提升）。
      //   首版这里把返回值丢了 → `d += 1;`（int 右值）在 codegen 里仍按整数路径求值（值在 eax 而非 xmm0）
      //   → 加出来是垃圾（实测 `d` 从 3.0 变成 6.0）——**与浮点 bug(a)「漏过 asgn_rhs」同族**，
      //   本轮由样本 dblcompound1.fl 第 5 项当场抓住。
      crhs = asgn_rhs(node, crhs, p->tok->loc);
      return new_node(compound[i].kind, node, crhs); // 右结合
    }
  }
  if (consume(p, '=')) {
    if (!is_lvalue(node))
      error_at(p->tok->loc, "赋值左边必须是变量或 *p/a[i]");
    if (node->kind == ND_VAR && (node->is_own || node->is_share))
      error_at(p->tok->loc, "own/share 指针不能重新赋值（所有权由声明初始化 + 出口自动释放管理）");
    // v1.5.0：str([...]) 作赋值右值 —— 这里**不再放行**（改由 stmt_inner 的语句级展开处理：
    //   `s = str([...]);` 必须先按语句形态识别，才不会把缓冲复位夹进表达式求值序里）。
    //   于是 `x = str([...])`（x 不是指针）等写法直接落到 primary 的响亮报错。
    Node *rhs = assign(p);
    if (rhs->kind == ND_VAR && (rhs->is_own || rhs->is_share))
      error_at(p->tok->loc, "own/share 指针不能拷贝给其他变量（share 拷贝请用 int *share q = p; 初始化）");
    if (flint_safe_mode && subtree_has_new(rhs))
      error_at(p->tok->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（裸指针持有会泄漏）");
    rhs = asgn_rhs(node, rhs, p->tok->loc);   // v1.1.0：double 左值接 int 右值自动提升；反向必须 to_int
    funcptr_check_asgn(p->prog, node, rhs, p->tok->loc);   // v1.3.2：函数指针签名一致性
    node = new_node(ND_ASSIGN, node, rhs);
    node->loc = p->tok->loc;   // v1.0.13：T1 报错定位（指向右值起点，报错时 caret 落在被赋的值上）
  }
  return node;
}

// mkbin：二元节点统一构造——v1.1.0 起在此做 int→double 自动提升（C 语义）；
// v1.7.0 起同样在 int_64 上做提升（任一操作数 int_64 ⇒ 另一侧包 ND_I2L）；
// 两侧都是 int 时是零开销（不做任何包装，行为与原实现完全一致）。
static Node *mkbin(NodeKind kind, Node *lhs, Node *rhs) {
  bool li = expr_is_i64(lhs), ri = expr_is_i64(rhs);
  // ⚠️ int_64 ↔ double 的混算一律硬错（P0/P1）：必须**先于** double 提升判 ——
  //   否则 `d * big` 会走进 widen_dbl(int_64) 把它当 32 位 int 转 double（静默错值）。
  if ((li || ri) && (is_dbl_node(lhs) || is_dbl_node(rhs)))
    error("int_64 与 double 不能混算（v1.7.0 P0/P1 不支持两者互转）——"
          "请先把一侧显式转成另一类（to_int32(...) 或 to_int(...)）");
  if (li || ri) {
    lhs = widen_i64(lhs);
    rhs = widen_i64(rhs);
  } else if (is_dbl_node(lhs) || is_dbl_node(rhs)) {
    lhs = widen_dbl(lhs);
    rhs = widen_dbl(rhs);
  }
  return new_node(kind, lhs, rhs);
}

// logor = logand ("||" logand)*
static Node *logor(Parser *p) {
  Node *node = logand(p);
  while (consume_str(p, "||")) node = mkbin(ND_LOGOR, node, logand(p));
  return node;
}

// logand = bitor ("&&" bitor)*
static Node *logand(Parser *p) {
  Node *node = bitor(p);
  while (consume_str(p, "&&")) node = mkbin(ND_LOGAND, node, bitor(p));
  return node;
}

// —— v0.7.2 位运算优先级层（C 语义：&& > | > ^ > & > 相等）——
// ⚠️ v1.1.0：位运算/移位/取模不接受 double（C 同此语义）——mkintbin 负责拦
static Node *mkintbin(Parser *p, NodeKind kind, Node *lhs, Node *rhs) {
  if (is_dbl_node(lhs) || is_dbl_node(rhs))
    error_at(p->tok->loc, "这个运算符不支持 double（位运算/移位/取模只对整数）");
  if (expr_is_i64(lhs) || expr_is_i64(rhs)) {   // v1.7.0：位运算/移位/取模同样按 int_64 提升
    lhs = widen_i64(lhs);
    rhs = widen_i64(rhs);
  }
  return new_node(kind, lhs, rhs);
}

// ===== v1.7.0 P2：`int_64 左值 op= RHS` 的源码层摊平（决策 D11 = 糖必须能在源码层摊平）=====
// 产出形状（**只用已有节点**，src\codegen.c 一行未改）：
//     t = &LV;            ND_ASSIGN(ND_VAR t, ND_ADDR LV)     —— 地址只算一次
//     *t = *t op RHS      ND_ASSIGN(ND_DEREF t, binop(ND_DEREF t', RHS))
// 为什么要 t 这个帧槽：朴素展开 `LV = LV op RHS` 把左值写了**两遍** ⇒ `a[i++] += 1` 会把 i 加两次、
//   `a[ix()] += 1` 会调两次 ix()、`*p += f()` 会在 f() 之后**重算**目标地址（写到新 p 指的地方）。
//   有了 t：左值恰好求值一次，写目标就是那一次算出来的地址（C 的复合赋值语义）。
// 槽是**匿名**的（不进作用域/不查重名）：用户看不见，也不会和用户变量撞名；-strict 的未初始化
//   检查按帧偏移反查 LVar，查不到 ⇒ 放行（strict_read 的"不是局部量"分支），不会假报。
// 二元提升口径**不在这里另写一份**：算术走 mkbin、位/移位走 mkintbin（`x = x op y` 的同一条路，
//   因此「int_64 与 double 不能混算」「位运算/移位不收 double」两张硬错自然一致）。
static Node *i64_compound(Parser *p, Node *lv, NodeKind bin_kind, Node *rhs, char *loc) {
  if (!p->scope)
    error_at(loc, "int_64 的复合赋值只能出现在函数体内（v1.7.0 P2 边界）");
  // 匿名帧槽：与 new_lvar 同一套账（next_offset 分配 / var_count 计入帧大小），只是不登记名字。
  if ((long long)p->next_offset + 8LL > 0x7FFFFFFFLL)
    error_at(loc, "变量/数组/结构体总长过大（帧槽累计超 2GB 上限）");
  int slot = p->next_offset;
  p->next_offset += 8;
  p->var_count += 1;

  // ① t = &LV —— 左值在这棵展开树里**只出现这一次**
  Node *bind = new_node(ND_ASSIGN, new_var_node(slot, false, TY_PTR, -1, TY_INT64),
                        new_node(ND_ADDR, lv, NULL));
  // ② *t = *t op RHS —— 读旧值走 bind 的值（同一个地址），写回走另一次 t 读
  Node *old = new_node(ND_DEREF, bind, NULL);
  old->ty = TY_INT64;
  bool bitlike = (bin_kind == ND_BITAND || bin_kind == ND_BITOR || bin_kind == ND_BITXOR
               || bin_kind == ND_SHL || bin_kind == ND_SHR);
  Node *bin = bitlike ? mkintbin(p, bin_kind, old, rhs) : mkbin(bin_kind, old, rhs);
  Node *dst = new_node(ND_DEREF, new_var_node(slot, false, TY_PTR, -1, TY_INT64), NULL);
  dst->ty = TY_INT64;
  Node *out = new_node(ND_ASSIGN, dst, bin);
  out->ty = TY_INT64;    // 表达式值 = 新值（ND_ASSIGN 的值语义），类型 = int_64
  out->loc = loc;
  return out;
}

// bitor = bitxor ("|" bitxor)*
static Node *bitor(Parser *p) {
  Node *node = bitxor(p);
  while (consume(p, '|')) node = mkintbin(p, ND_BITOR, node, bitxor(p));
  return node;
}

// bitxor = bitand ("^" bitand)*
static Node *bitxor(Parser *p) {
  Node *node = bitand(p);
  while (consume(p, '^')) node = mkintbin(p, ND_BITXOR, node, bitand(p));
  return node;
}

// bitand = equality ("&" equality)*
static Node *bitand(Parser *p) {
  Node *node = equality(p);
  while (consume(p, '&')) node = mkintbin(p, ND_BITAND, node, equality(p));
  return node;
}

// equality = relational ("==" relational | "!=" relational)*
static Node *equality(Parser *p) {
  Node *node = relational(p);
  for (;;) {
    if (consume_str(p, "==")) node = mkbin(ND_EQ, node, relational(p));
    else if (consume_str(p, "!=")) node = mkbin(ND_NE, node, relational(p));
    else return node;
  }
}

// relational = shift ("<" shift | "<=" shift | ">" shift | ">=" shift)*
static Node *relational(Parser *p) {
  Node *node = shift(p);
  for (;;) {
    if (consume(p, '<')) node = mkbin(ND_LT, node, shift(p));
    else if (consume_str(p, "<=")) node = mkbin(ND_LE, node, shift(p));
    else if (consume(p, '>')) node = mkbin(ND_GT, node, shift(p));
    else if (consume_str(p, ">=")) node = mkbin(ND_GE, node, shift(p));
    else return node;
  }
}

// shift = add ("<<" add | ">>" add)*   （v0.7.2；位级低于加减——C 语义）
static Node *shift(Parser *p) {
  Node *node = add(p);
  for (;;) {
    if (consume_str(p, "<<")) node = mkintbin(p, ND_SHL, node, add(p));
    else if (consume_str(p, ">>")) node = mkintbin(p, ND_SHR, node, add(p));
    else return node;
  }
}

// add = mul ("+" mul | "-" mul)*
// ⚠️ v1.0.6.2 A7 语义澄清：裸指针 ± int = **字节单位**（决策 17 实现 + share 头 p-8 约定 +
// str1 字节差实测）；只有下标 a[i]/p[i] 才按元素宽缩放（postfix 内 ×8/×1，SPEC a[i]=*(a+i*8)）。
// 曾按 C 语义试图把裸 ± 改元素缩放 → 破坏 share p-8/回归样本，已回滚（详见决策 40）。
// ===== v1.6.4（`-strict` 第五类）：E-STRICT-PTRSTEP =====
// 病：FLINT 的裸指针 ± 整数是**字节**步进（决策 40；SPEC.md:262/:486 与 PROGRESS 都记着——
//   当年按 C 语义改成元素缩放被回滚，sh1/sh2/arr4/ptr64b 全红）。这在 1 字节元素
//   （char* / char[] / 字符串字面量）上**恰好等于**元素步进（本来就是想要的），
//   而在非 1 字节元素指针（int* / double* / struct* / 指针的指针）上就是**静默错值**：
//   `p + 3` 只走 3 个**字节**，落进 p[0] 的中间；要第 3 个元素得写 p[3]（偏移 3*8 = 24 字节）。
//   本档**一个字都不改**决策 40 的语义，只把它在 -strict 下报出来（默认档零变化）。
//
// 元素宽度（**与下标缩放同源**：唯一出处 = postfix 的下标展开口径，见本文件 postfix 的 esize_bytes）：
//   char 元素 = 1 字节；int / double / struct / 指针元素 = **8 字节槽**。
//   ⚠️ 别照 C 的 sizeof 写 4：FLINT 的 int 元素是 8 字节槽（`a[i] = *(a + i*8)`，
//      test\facts\f025_ptr_arith.fl 实测 `&ia[3]` = 字节 24）；写 4 就会报出一个**错的正解数字**。
static int ptr_step_elem_width(int elem) {
  // v1.7.0：改走单点表（char 1 / int 4 / int_64 8 / double/struct/指针 8）——
  //   本函数是 -strict 诊断的"正解数字"来源，抄第二份就是第二个真值源
  return ty_arr_stride(elem);
}

// 判据（逐条对齐口径；宁可漏报，绝不误报——与 codegen 的默认档口径同一条纪律）：
//   命中：ND_ADD/ND_SUB 的**一侧是地址**（指针变量/数组名/&x/字符串/new/函数地址/地址链）、
//         另一侧是**整数**，且该地址的元素宽度 > 1 字节。
//   不命中：① 下标/字段展开（`p[i]`、`&p[i]`、`s.buf`、`s.p`）——它们**不走本函数**（见下）；
//           ② 1 字节元素（char* / char[] / 字符串字面量）：字节步进 == 元素步进，本就是正解；
//           ③ 地址 − 地址（标量差值；与 codegen 的 addr_diff_is_scalar 同一条口径）；
//           ④ 两侧都是地址的 +，以及两侧都值的普通算术；⑤ double 参与（浮点口径另算）；
//           ⑥ 非 -strict 档（本函数只被 flint_strict 分支调用）。
//
// **为什么落在这里、不落在 codegen 的 gen_binop**：codegen 看到的 AST 里，`p[i]` 与用户手写的
//   `p + i*8` **形状完全相同**（都是 ND_ADD(p, ND_MUL(i,8))）——下标展开之后已经**分不出**
//   哪一个是"正解的下标"、哪一个是"用户裸写的 ±"，只能靠形状嗅探（脆弱且必漏）。
//   而本函数只被**用户写在源码里的** +/- 调到：postfix 的下标展开（postfix 内的 esize_bytes）
//   与结构体字段偏移（'.'/'->' 两处 new_node(ND_ADD,…)）都是**直接造节点**、不经 add() ⇒ 天然不误报。
//   代价 = 地址判定用 parse 侧既有的 tern_addr_info（不含 codegen 的 T1「装过地址的 int」标记）⇒
//   对 `int h = &x; h + 8;` 这类**漏报**——正是想要的保守侧：那种写法连元素宽度都无从得知，
//   报不出"正解"的数字（而 T1 的算术本就按 32 位走，是另一条已记录的边界，见 codegen 的 T1 注释）。
static void strict_ptr_step_check(NodeKind kind, Node *lhs, Node *rhs, Token *op_tok) {
  TernAddr l = {0}, r = {0};
  tern_addr_info(lhs, &l);
  tern_addr_info(rhs, &r);
  if (!l.is_addr && !r.is_addr) return;                    // 纯整数（或 double）算术
  if (kind == ND_SUB && l.is_addr && r.is_addr) return;    // 地址 − 地址 = 标量差值（不是地址）
  TernAddr *a = (l.is_addr && !r.is_addr) ? &l
              : (r.is_addr && !l.is_addr) ? &r : NULL;
  if (!a) return;                                          // 两侧都是地址的 +（无元素宽度可言）
  Node *other = (a == &l) ? rhs : lhs;
  if (is_dbl_node(other)) return;                          // 另一侧不是「整数偏移」（浮点口径另算）
  int width = ptr_step_elem_width(a->elem);
  if (width <= 1) return;                                  // 1 字节元素：字节步进就是元素步进
  if (other->kind == ND_NUM) {
    long long n = other->val;
    if (n == 0) return;   // `p + 0` / `p - 0` = 恒等（0 字节偏移）——没有陷阱，别误报
    long long bytes = (kind == ND_ADD) ? n : -n;
    error_at(op_tok->loc,
             "[E-STRICT-PTRSTEP] 裸指针 '%s' 按**字节**步进（FLINT 决策 40）：这个指针的元素宽度是 %d 字节，"
             "所以这里走的是 %lld 个**字节**，第 %d 个元素的偏移是 %lld 字节。"
             "要取元素请改用 p[i] / &p[i]（-strict 诊断）",
             kind == ND_ADD ? "+" : "-", width, bytes, other->val, n * width);
  }
  error_at(op_tok->loc,
           "[E-STRICT-PTRSTEP] 裸指针 '%s' 按**字节**步进（FLINT 决策 40）：这个指针的元素宽度是 %d 字节，"
           "所以 `p %s i` 拿到的是 i 个**字节**之后的地址，不是第 i 个元素。"
           "要取元素请改用 p[i] / &p[i]（-strict 诊断）",
           kind == ND_ADD ? "+" : "-", width, kind == ND_ADD ? "+" : "-");
}

// add = mul ("+" mul | "-" mul)*
// ⚠️ v1.0.6.2 A7 语义澄清：裸指针 ± int = **字节单位**（决策 17 实现 + share 头 p-8 约定 +
// str1 字节差实测）；只有下标 a[i]/p[i] 才按元素宽缩放（postfix 内 ×8/×1，SPEC a[i]=*(a+i*8)）。
// 曾按 C 语义试图把裸 ± 改元素缩放 → 破坏 share p-8/回归样本，已回滚（详见决策 40）。
// v1.6.4：决策 40 **语义一行未改**，只在 -strict 档把「非 1 字节元素指针上的裸 ±」报成
//   E-STRICT-PTRSTEP（见上面的 strict_ptr_step_check）。默认档走到的是同一棵 AST、同一批字节。
static Node *add(Parser *p) {
  Node *node = mul(p);
  for (;;) {
    Token *op_tok = p->tok;   // v1.6.4：命中时把 caret 落在 '+'/'-' 那个 token 上
    if (consume(p, '+')) {
      Node *rhs = mul(p);
      if (flint_strict) strict_ptr_step_check(ND_ADD, node, rhs, op_tok);
      node = mkbin(ND_ADD, node, rhs);
    } else if (consume(p, '-')) {
      Node *rhs = mul(p);
      if (flint_strict) strict_ptr_step_check(ND_SUB, node, rhs, op_tok);
      node = mkbin(ND_SUB, node, rhs);
    } else return node;
  }
}

// mul = unary ("*" unary | "/" unary | "%" unary)*
static Node *mul(Parser *p) {
  Node *node = unary(p);
  for (;;) {
    if (consume(p, '*')) node = mkbin(ND_MUL, node, unary(p));
    else if (consume(p, '/')) node = mkbin(ND_DIV, node, unary(p));
    else if (consume(p, '%')) node = mkintbin(p, ND_MOD, node, unary(p));
    else return node;
  }
}

// unary = ("+" | "-" | "!" | "~" | "&" | "*" | "++" | "--")? unary | pow
//   （v1.0.11：末档由 postfix 改为 pow —— 幂比一元负号紧：-2^^2 = -(2^^2)）
// v1.0.13：取「指针类表达式的指向类型」——用于 *p 的读宽判定（char 指向 → 字节读）。
// 变量/调用/解引用看各自的 elem_ty；地址链（a ± n）看地址那一侧；字符串字面量 = char*。
// 拿不到指向类型（结构体指针字段无指向类型等）→ 退回 TY_INT（原行为，不改变已钉语义）。
static int ptr_elem_ty(Node *n) {
  if (!n) return TY_INT;
  switch (n->kind) {
    case ND_VAR: case ND_CALL: case ND_APICALL:
      // 数组名作表达式 = 指向首元素（退化），元素类型即指向类型
      return (n->ty == TY_PTR || n->ty == TY_ARR) ? n->elem_ty : TY_INT;
    case ND_DEREF:
      return n->ty == TY_PTR ? n->elem_ty : TY_INT;
    case ND_ADD: case ND_SUB: {
      // 链式偏移要递归：`*(q + i - 1)` 的 AST 是 ((q+i) - 1)，外层 lhs 是链节点（自己不带类型）
      int a = n->lhs ? ptr_elem_ty(n->lhs) : TY_INT;
      if (a != TY_INT) return a;
      return n->rhs ? ptr_elem_ty(n->rhs) : TY_INT;
    }
    case ND_STR: return TY_CHAR;      // 字符串字面量值 = char*
    // v1.8.0 C 风格转型：(T*)p 的指向类型就是括号里那个 T（只换类型、不产码）
    case ND_CAST: return n->ty == TY_PTR ? n->elem_ty : TY_INT;
    default: return TY_INT;
  }
}

// ===== v1.8.0：C 风格转型 `(type)expr` =====
// 文法位置 = **一元转换**（C 的标准位置）：`(int)x * 2` ⇒ `((int)x) * 2`，`(int)(x * 2)` 照括号。
//   操作数取 unary 一层 ⇒ 前缀运算符与转型可互相嵌套：(int)-x / -(int)x 都行；
//   postfix 比转型紧 ⇒ `(int)x[0]` = `(int)(x[0])`（与 C 一致）。
// ⚠️ 已知偏差（FLINT 独有的幂 `^^`）：pow_expr 挂在 unary 尾部 ⇒ `(int)x^^2` 解析成 `(int)(x^^2)`。
//   C 没有 ^^，这条只影响"先转型还是先求幂"的 64 位边界；已写进 SPEC 与 docs\语言参考.md。
//
// 判定 `(type)` 只看 `(` 后紧跟的**类型关键字**：int / int_32（is_ident 的别名）/ int_64 / char / double。
//   void / struct / ptr 也认出来（否则会掉进普通括号表达式、报"意外的关键字"这种看不懂的错），
//   但立刻硬错 —— v1 不支持（边界见 SPEC「C 风格转型」节）。
// 语义（v1 口径，逐条与 SPEC/docs 一致）：
//   (int)←int/int_32/char 恒等 ｜ (int)←int_64 取低 32 位 ｜ (int)←double cvttsd2si（截断向零，越界=0x80000000）
//   (int_64)←int/char 符号扩展 ｜ (int_64)←int_64 恒等 ｜ (int_64)←double cvttsd2si 64 位
//   (char)←int/int_64 取低 8 位（movzx，0..255） ｜ (double)←int/char cvtsi2sd 32 位 ｜ (double)←int_64 cvtsi2sd 64 位
//   (T*)p ← 任意地址值：**只换类型、不产码** ｜ int↔指针 / struct / void / 数组转型：编译期硬错
static bool tok_is_cast_type(Token *t) {
  if (!t || t->kind != TK_IDENT) return false;
  return is_ident(t, "int") || is_ident(t, "int_64") || is_ident(t, "char")
      || is_ident(t, "double") || is_ident(t, "void") || is_ident(t, "struct")
      || is_ident(t, "ptr");
}
// 前视 `(` + 类型关键字 ⇒ 这是一条转型。普通括号表达式 `(x)` 的 x 不可能是类型关键字
//   （int/char/double/int_64/void/struct/ptr 都是保留字，禁止当变量名）⇒ 不会误判。
static bool is_cast_start(Parser *p) {
  return is_punct(p->tok, '(') && tok_is_cast_type(p->tok->next);
}
static char *cast_type_name(int ty) {
  return ty == TY_INT ? "int" : ty == TY_INT64 ? "int_64" : ty == TY_CHAR ? "char"
       : ty == TY_DOUBLE ? "double" : "指针";
}
static Node *cast_expr(Parser *p) {
  Token *lp = p->tok;                 // '('
  p->tok = p->tok->next;
  Token *tt = p->tok;                 // 类型关键字
  int ty = TY_INT;
  int elem = TY_INT;                  // (T*) 的指向类型
  bool is_ptr = false;
  if (is_ident(tt, "int")) ty = TY_INT;                 // 含 int_32 别名
  else if (is_ident(tt, "int_64")) ty = TY_INT64;
  else if (is_ident(tt, "char")) ty = TY_CHAR;
  else if (is_ident(tt, "double")) ty = TY_DOUBLE;
  else if (is_ident(tt, "void"))
    error_at(tt->loc, "不支持 (void) 转型：FLINT 没有 void 值（要丢弃结果就写成表达式语句）");
  else if (is_ident(tt, "struct"))
    error_at(tt->loc, "不支持 struct 转型：struct 没有整体值语义 —— 要换类型请声明一个 struct 指针变量"
                      "（v1.8.0 边界，见 SPEC）");
  else
    error_at(tt->loc, "不支持 (ptr) 转型：ptr 只是 api 返回类型的关键字，"
                      "指针类型请写 int* / char* / double* / int_64*");
  p->tok = p->tok->next;
  if (consume(p, '*')) {              // (T*)p
    is_ptr = true;
    elem = ty;
    ty = TY_PTR;
  }
  if (is_punct(p->tok, '['))
    error_at(p->tok->loc, "不支持数组转型：数组没有整体值语义 —— 要字节视图请用 char*");
  if (!is_punct(p->tok, ')'))
    error_at(p->tok->loc, "转型写法是 (类型)表达式 —— 期望 ')'"
                          "（类型可写 int / int_32 / int_64 / char / double，或它们加 * 的指针类型）");
  p->tok = p->tok->next;
  Node *operand = unary(p);
  if (!operand) error_at(lp->loc, "内部错误：转型缺少操作数");
  // 函数指针：代码地址带签名，转成数据指针就把签名丢了（v1 边界，别静默退化）
  if (operand->ty == TY_FUNCPTR || operand->kind == ND_FUNC_ADDR)
    error_at(lp->loc, "函数指针不能转型（代码地址带签名，转成数据指针会丢签名）——"
                      "要调用就写 int (*fp)(...)，要地址就写 &函数名");
  bool from_addr = parse_is_addr_value(operand);
  bool from_dbl = expr_is_dbl(operand);
  if (is_ptr) {
    // (T*)p：源必须是**地址值**。整数 → 指针是 T1 边界的反向（地址值不能装进 int 的对偶）
    if (!from_addr)
      error_at(lp->loc, "指针转型的源必须是地址值（指针 / 数组名 / &x / 字符串 / new）——"
                        "整数不能转指针（T1 边界：地址值与 int 不能互相装；空指针请写 int *p = 0;）");
    Node *c = new_node(ND_CAST, operand, NULL);
    c->ty = TY_PTR;
    c->elem_ty = elem;
    c->struct_idx = -1;
    c->loc = lp->loc;
    return c;
  }
  // 数值转型 ← 地址值：int 只有 4 字节 ⇒ 高 32 位必丢（T1 红线，沿用既有判据与文案关键词）
  if (from_addr)
    error_at(lp->loc, "地址值（64 位）不能转成 %s —— 转型不提供「地址 ↔ 整数」通道"
                      "（T1 边界：地址值不能装进 int，反向同理）。要地址请用指针变量承接，"
                      "要数值请从字段/字节取出",
             cast_type_name(ty));
  // (char)double：v1 只给了 (int)/(int_64) 的 double 截断，两步请写清（别让编译器替你猜越界口径）
  if (ty == TY_CHAR && from_dbl)
    error_at(lp->loc, "不支持 (char)double：v1 的 double 截断只有 (int) / (int_64)"
                      "（越界 = 0x80000000，同 C）。请写 (char)(int)值，把两步写清");
  Node *c = new_node(ND_CAST, operand, NULL);
  c->ty = ty;
  c->loc = lp->loc;
  return c;
}

// v0.7：&x 取址（ND_ADDR，仅变量/数组名）；*p 解引用（ND_DEREF，可作左值）
// v0.7.2：~x 按位取反（ND_BITNOT）
static Node *unary(Parser *p) {
  // v1.8.0：C 风格转型在**一元转换**这一档（`(int)x * 2` = ((int)x)*2；`(int)(x * 2)` 照括号）
  if (is_cast_start(p)) return cast_expr(p);
  if (consume(p, '+')) return unary(p);
  if (consume(p, '-')) {
    // v1.1.0：一元负号**不在解析期提升**——把 `-10` 硬提升成 double 会让 `-10 % 3` / `-10 & 3`
    // 这类整数写法被「不支持 double」拦掉（实测 28 项回归炸）。真正提升交给外层 mkbin。
    Node *operand = unary(p);
    Node *neg = new_node(ND_NEG, operand, NULL);
    if (is_dbl_node(operand)) neg->ty = TY_DOUBLE;
    return neg;
  }
  if (consume(p, '!')) {
    Node *operand = unary(p);
    if (is_dbl_node(operand))
      error_at(p->tok->loc, "! 不支持 double（先比较：d != 0.0）");
    return new_node(ND_NOT, operand, NULL);
  }
  if (consume(p, '~')) {
    Node *operand = unary(p);
    if (is_dbl_node(operand))
      error_at(p->tok->loc, "~ 不支持 double（位运算只对整数）");
    return new_node(ND_BITNOT, operand, NULL);
  }
  if (consume(p, '&')) {
    // v0.9.3：&函数名 = 函数地址值（WNDPROC 回调等）——函数名后非 '(' 才取址
    // （函数名已全局预登记，支持取后定义的函数；&f() 仍是取调用的地址 → 走下方报错）
    if (p->tok->kind == TK_IDENT && !is_keyword(p->tok)) {
      LVar *v0 = find_lvar(p, p->tok);   // 局部变量优先（& 局部变量 = 原语义）
      if (!v0) {
        int fai = find_func(p->prog, p->tok);
        bool is_call = p->tok->next && is_punct(p->tok->next, '(');
        if (fai >= 0 && !is_call) {
          Node *n = new_node(ND_FUNC_ADDR, NULL, NULL);
          n->func_index = fai;
          p->tok = p->tok->next;
          return n;
        }
      }
    }
    Node *operand = unary(p);
    if (operand->kind != ND_VAR && operand->kind != ND_DEREF)
      error_at(p->tok->loc, "& 需要变量/数组名/字段/函数名（&x &a &p.x &a[i] &f）");
    return new_node(ND_ADDR, operand, NULL);
  }
  if (consume(p, '*')) {
    // v1.0.5/1.0.6：*p 读宽随指向类型——char* 变量或 char* 返回调用解引用 = 字节读（movzx）
    // v1.0.13：原先只认「裸变量 / 函数调用」两种操作数，`*(charPtr + n)`、`*(p->s + i)` 这类
    // **地址链**落到默认 TY_INT → 4 字节读（静默读错：2026-09-10 评审清单之外新发现的真 bug，
    // 由新样本 rev4 暴露，旧/新编译器都错）。改为统一取「指针类表达式的指向类型」。
    Node *op = unary(p);
    // v1.3.2：函数指针不能解引用 —— `*fp` 会被当数据指针按 8 字节读代码字节（静默错值/崩溃）。
    //   要调用请写 fp(args)（间接调用）。
    if (op->ty == TY_FUNCPTR)
      error_at(p->tok->loc, "函数指针不能解引用：要调用就写 fp(实参)（间接调用），"
                            "要存地址就写 &函数名");
    Node *d = new_node(ND_DEREF, op, NULL);
    // ⚠️ 不能看 op->ty：地址链（ND_ADD/ND_SUB）节点不带类型（ty 只有变量/调用/解引用才设）——
    // 原判断「op->ty == TY_PTR」对 `*(q + 1)` 恒假，所以链上解引用永远按 int 读。
    int pe = ptr_elem_ty(op);
    if (pe == TY_CHAR)
      d->ty = TY_CHAR;
    // v1.2.5：double* 解引用（含 double* 字段读、double* 返回调用、double 数组名退化后的链式偏移）
    //   → 目标类型 TY_DOUBLE ⇒ codegen 走 8 字节 SSE 读（movsd）与 SSE 写，绝不落 32 位整数路径
    else if (pe == TY_DOUBLE)
      d->ty = TY_DOUBLE;
    // v1.7.0 P1：int_64* 的解引用读宽 = 8 字节。P0 漏了这一档 ⇒ `*p` 的节点类型掉回 TY_INT：
    //   读只读低 32 位、写只写低半槽，而且 `int_64 x = *p;` 会被包上 movsxd（编译过、值错）。
    //   `p[i]` 是另一条路（postfix 下标分支自己设 TY_INT64），两条都要对。
    else if (pe == TY_INT64)
      d->ty = TY_INT64;
    return d;
  }
  if (consume_str(p, "++")) {
    Node *operand = unary(p);
    if (!is_lvalue(operand))
      error_at(p->tok->loc, "++ 需要可修改的变量或 *p（左值）");
    // v0.9.2：指针字段禁 ++/--（+ 复合赋值，见 check_field_incr）
      check_field_incr(p, operand);
      check_dbl_incr(p, operand);
      Node *n = new_node(ND_PRE_INC, operand, NULL);
      if (expr_is_i64(operand)) n->ty = TY_INT64;   // v1.7.0 P1：值 = 新的 64 位值
      return n;
  }
  if (consume_str(p, "--")) {
    Node *operand = unary(p);
    if (!is_lvalue(operand))
      error_at(p->tok->loc, "-- 需要可修改的变量或 *p（左值）");
    check_field_incr(p, operand);
    check_dbl_incr(p, operand);
    Node *n = new_node(ND_PRE_DEC, operand, NULL);
    if (expr_is_i64(operand)) n->ty = TY_INT64;   // v1.7.0 P1：值 = 新的 64 位值
    return n;
  }
  return pow_expr(p);
}

// pow = postfix ("^^" unary)?   （v1.0.11 幂运算符，决策 49）
// 优先级高于一元负号（Python/D 惯例）：-2^^2 = -(2^^2) = -4；右侧可带一元 → 2^^-1（运行期 = 0）
// 右结合靠右侧递归回 unary → pow：2^^3^^2 = 2^^(3^^2) = 512
// 与乘法：^^ 高于 * / %（2 * 3^^2 = 18）
static Node *pow_expr(Parser *p) {
  Node *node = postfix(p);
  if (consume_str(p, "^^")) {
    // ⚠️ v1.1.0：`^^` 的**实现是整数快速幂**（test/sar/imul）——double 直接进会静默算错
    //   （实测 `2.0 ^^ 3` 得 0）。阶段1 两侧都拦，绝不静默；浮点幂留阶段2（std::pow 或自写）
    Node *rexp = unary(p);
    if (is_dbl_node(node) || is_dbl_node(rexp)) {
      error_at(p->tok->loc, "^^ 暂不支持 double（阶段1：幂只有整数版）——请写 d = d * d * d 或等阶段2 的浮点幂");
    }
    // v1.7.0：幂是 **32 位**累加器（eax/ecx/edx 快速幂）⇒ int_64 的 ^^ 会静默截断，明确不做
    if (expr_is_i64(node) || expr_is_i64(rexp)) {
      error_at(p->tok->loc, "^^ 暂不支持 int_64（快速幂是 32 位累加器，会静默截断高 32 位）——"
                            "请改成连乘/循环，或先用 to_int32(...)");
    }
    node = new_node(ND_POW, node, rexp);
  }
  return node;
}

// postfix = primary ("[" 表达式 "]" | "." 字段 | "->" 字段 | "++" | "--")*
// v0.7：a[i] / p[i] 下标 → 展开成 *(基址 + i*8)（int 元素 8 字节槽）
// v0.7.x：p.x / ptr->x 字段 → 展开成 *(基址 + 字段偏移)（int 字段 8 字节槽）
// ========== v1.6.0 方法调用点糖 recv.name(args) ⇒ Type_name(&recv, args) ==========
// M22 §7 候选一「方法/关联函数，语法层最小形态」的第一刀。口径（口径已定，照做）：
//   · **定义侧一个字都不改**：方法就是普通自由函数 int M_f(struct M *self, int x)；
//   · 命名约定 = 结构体名_方法名（先精确匹配 M_f；再**唯一**的大小写不敏感候选 ——
//     用来接住仓库里既有的小写前缀写法 struct Seg ↔ seg_mk / struct Db ↔ db_list，
//     候选多于一个 = 响亮报歧义，不猜）；
//   · 接收者 = struct 变量（m.f(...) ⇒ M_f(&m, ...)）｜指向 struct 的指针（p->f(...) 与
//     p.f(...) 都 ⇒ M_f(p, ...)，不额外取址）｜解引用链（(*p).f(...) ⇒ M_f(p, ...)）；
//   · 零参 m.f() ⇒ M_f(&m)；实参链按**源序**建，与手写 M_f(&m, x, ...) 的 AST 同形。
// D11 四不变量（docs\设计决策.md）：
//   I1 展开只用已有的 ND_CALL/ND_ADDR ⇒ src\codegen.c 一行未改；
//   I2 接收者那一格是**地址/指针值**（lea 或原值），不带副作用的求值 ⇒ 实参「右→左」求值
//      （实测台账 F-008）不受影响，与手写形式逐字节同结果；
//   I3 不写方法语法 ⇒ 本块完全不执行 ⇒ 产物逐字节不变；
//   I4 找不到 / 形态不合法一律 error_at 编译期响亮报错，绝不静默降级。

// 名字相等（只看 ASCII 大小写）——用于糖名的「类型名段」比对
static bool name_eq_ci(const char *a, const char *b) {
  for (; *a && *b; a++, b++) {
    char ca = *a, cb = *b;
    if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
    if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
    if (ca != cb) return false;
  }
  return *a == '\0' && *b == '\0';
}

// <结构体名>_<方法名> 查表：返回函数下标；-1 = 不存在；-2 = 大小写不敏感兜底撞上多个（歧义）
static int find_method_func(Program *prog, const char *sname, const char *mname) {
  int sn = (int)strlen(sname), mn = (int)strlen(mname);
  if (sn + mn + 2 > 200) return -1;
  char exact[200];
  memcpy(exact, sname, (size_t)sn);
  exact[sn] = '_';
  memcpy(exact + sn + 1, mname, (size_t)mn);
  exact[sn + 1 + mn] = '\0';
  int hit = find_func_by_name(prog, exact);
  if (hit >= 0) return hit;
  int found = -1, cnt = 0;
  for (int i = 0; i < prog->nfuncs; i++) {
    const char *fn = prog->funcs[i].name;
    if ((int)strlen(fn) != sn + 1 + mn) continue;
    if (fn[sn] != '_') continue;
    if (strncmp(fn + sn + 1, mname, (size_t)mn) != 0) continue;
    char seg[200];
    memcpy(seg, fn, (size_t)sn);
    seg[sn] = '\0';
    if (!name_eq_ci(seg, sname)) continue;
    found = i;
    cnt++;
  }
  if (cnt > 1) return -2;
  return found;
}

// 结构体字段查表（'.' 字段路径 / '->' 字段路径 / 方法糖的「字段 vs 方法」歧义判定 三处共用）
//   命中返回字段偏移；未命中返回 -1，并把 *fty/*felem 复位成默认（调用方原来的口径）
static int struct_field_lookup(StructDef *s, Token *fn, int *fty, int *felem) {
  *fty = TY_INT;
  *felem = TY_INT;
  if (fn->kind != TK_IDENT) return -1;
  for (int i = 0; i < s->nfields; i++)
    if ((int)strlen(s->fields[i].name) == fn->len
        && strncmp(s->fields[i].name, fn->loc, (size_t)fn->len) == 0) {
      *fty = s->fields[i].ty;
      *felem = s->fields[i].elem;
      return s->fields[i].offset;
    }
  return -1;
}

// 单个实参的规范化（own/share、double 通道、函数指针签名、引用形参自动取址）——
// **普通调用与方法糖共用这一份**：两条路各写一份必然分叉，而判据是「与手写形式逐字节同结果」。
static Node *call_arg_norm(Parser *p, FuncDef *fn, int nargs, Node *arg) {
  if (arg->kind == ND_VAR && (arg->is_own || arg->is_share))
    error_at(p->tok->loc, "own/share 指针不能作实参（所有权语义，拷贝初始化专属 v0.9）");
  bool by_addr = fn->param_ref[nargs] || fn->param_ty[nargs] == TY_PTR
              || fn->param_ty[nargs] == TY_FUNCPTR;   // v1.3.2：函数指针形参 = 地址（GP 64 位）
  // ===== v1.7.0：int_64 实参通道（三条硬规则，与 asgn_rhs 同口径）=====
  if (!by_addr && nargs < fn->nargs && fn->param_ty[nargs] == TY_INT64) {
    if (expr_is_dbl(arg))
      error_at(p->tok->loc, "这个形参是 int_64——double 实参不支持（P0/P1 不互转），请先 to_int(值) 再 to_int64(...)");
    // 地址值（指针/&x）原样传（已是完整 64 位）；其余 int 侧符号扩展
    arg = parse_is_addr_value(arg) ? arg : widen_i64(arg);
  } else if (!by_addr && expr_is_i64(arg)) {
    error_at(p->tok->loc, "这个形参是 int——int_64 实参会被静默截断高 32 位（超出 int 范围的部分丢掉），"
                          "请显式写 to_int32(值)（或把形参声明成 int_64）");
  }
  if (!by_addr && nargs < fn->nargs && fn->param_ty[nargs] == TY_DOUBLE) {
    arg = widen_dbl(arg);
  } else if (!by_addr && expr_is_dbl(arg)) {
    error_at(p->tok->loc, "这个形参是 int——double 实参请写 to_int(值) 显式转换（不静默截断小数），"
                          "或把形参也改成 double");
  }
  // v1.3.2：函数指针形参 → 实参必须是签名一致的「&函数名」或函数指针变量
  if (fn->param_ty[nargs] == TY_FUNCPTR) {
    int want = fn->param_sig[nargs];
    if (arg->kind == ND_VAR && arg->ty == TY_FUNCPTR) {
      if (want != FN_SIG_NONE && arg->fn_sig != FN_SIG_NONE
          && !sig_equal(p->prog, &p->prog->sigs[want], &p->prog->sigs[arg->fn_sig]))
        error_at(p->tok->loc, "实参函数指针的签名与形参不一致（需要 %s，给的是 %s）",
                 sig_desc(p->prog, want), sig_desc(p->prog, arg->fn_sig));
    } else if (arg->kind == ND_FUNC_ADDR) {
      if (want != FN_SIG_NONE
          && !sig_equal_func(p->prog, &p->prog->sigs[want], &p->prog->funcs[arg->func_index]))
        error_at(p->tok->loc, "实参 '&%s' 的签名与形参不一致（需要 %s）",
                 p->prog->funcs[arg->func_index].name, sig_desc(p->prog, want));
    } else {
      error_at(p->tok->loc, "函数 '%s' 的第 %d 个形参收的是函数指针——请传「&函数名」或函数指针变量",
               fn->name, nargs + 1);
    }
  }
  if (fn->param_ref[nargs]) {
    // v0.6 引用形参：实参必须变量（普通或引用），包 ND_ADDR 传其地址
    if (arg->kind != ND_VAR)
      error_at(p->tok->loc, "引用形参需要变量实参（如 swap(a, b)）");
    arg = new_node(ND_ADDR, arg, NULL);
  }
  return arg;
}

// 实参表尾段：p->tok 已经在 '(' 之后；head 是已有的实参链（普通调用 = NULL，方法糖 = 接收者），
// nargs = 已有几个。返回 ND_CALL 节点。普通调用路径（primary）与方法糖共用，保证两条路同形。
static Node *call_finish(Parser *p, FuncDef *fn, int fi, Node *head, int nargs, char *fn_loc) {
  Node **cur = &head;
  while (*cur) cur = &(*cur)->next;
  if (!is_punct(p->tok, ')')) {
    for (;;) {
      if (nargs >= FUNC_MAX_ARGS)
        error_at(p->tok->loc, "实参最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参；v1.4.26 由 4 抬到 %d）",
                 FUNC_MAX_ARGS, FUNC_MAX_ARGS);
      // v1.2.2：实参个数**当场**对不上就报错（原来完全没查：多给的实参静默被忽略、
      //   少给的形参读未初始化寄存器 —— 都是「编译过、静默错值」家族）。
      if (nargs >= fn->nargs)
        error_at(p->tok->loc, "实参个数超过函数 '%s' 的形参个数（%d 个）", fn->name, fn->nargs);
      Node *arg = assign(p);   // 参数是完整赋值表达式
      arg = call_arg_norm(p, fn, nargs, arg);
      *cur = arg;
      cur = &arg->next;
      nargs++;
      if (!consume(p, ',')) break;
    }
  }
  skip(p, ')');
  if (nargs != fn->nargs)
    error_at(p->tok->loc, "函数 '%s' 需要 %d 个实参，这里只给了 %d 个（FLINT 没有默认实参）",
             fn->name, fn->nargs, nargs);
  Node *call = new_node(ND_CALL, NULL, head);
  call->func_index = fi;
  call->nargs = nargs;
  call->is_void = fn->ret_void;   // void 调用结果不能当值（后遍检查）
  // v1.0.6：指针返回函数 → 调用表达式带返回类型信息（TY_PTR → 地址类 64 位语义；
  //   elem/struct 供 *f() / f()[i] / f()->x 读写宽度与穿透）
  call->ty = fn->ret_void ? TY_INT : fn->ret_ty;
  call->elem_ty = fn->ret_elem;
  call->struct_idx = fn->ret_struct;
  call->loc = fn_loc;             // v0.9.1
  return call;
}

// v1.6.0（I4 ⑤）**括号判据的歧义闸门**：名字后面紧跟 '(' ⇒ 这是方法调用点的形态；
//   此刻若这个名字同时还是结构体的**字段**，一律编译期响亮报错 —— 绝不静默替人挑一个语义。
//   区分口径（写进报告）：不带括号 recv.f = 字段访问（老语义一行未改）；带括号 recv.f(...) = 方法糖；
//   两者同名 = 歧义 ⇒ 报错，改名字或去掉括号。
static void method_vs_field_guard(Parser *p, int sidx, Token *name) {
  StructDef *s = &p->prog->structs[sidx];
  int fty = TY_INT, felem = TY_INT;
  if (struct_field_lookup(s, name, &fty, &felem) >= 0)
    error_at(name->loc, "'%.*s' 是结构体 %s 的**字段**，不是方法——FLINT 用括号区分："
                        "不带括号 recv.%.*s 读字段，带括号 recv.%.*s(...) 才是方法糖"
                        "（糖摊平后要找的自由函数是 '%s_%.*s'）；字段不可调用",
             name->len, name->loc, s->name, name->len, name->loc,
             name->len, name->loc, s->name, name->len, name->loc);
}

// 名字既不是字段、也不带调用括号时的报错（I4 ③）：若它是某个「糖摊平后的名字」，
// 就把"必须带括号"这条口径当面说清，绝不让人以为字段访问被静默换成了别的意思。
static void no_such_field_error(Parser *p, StructDef *s, Token *fn) {
  if (fn->kind == TK_IDENT && fn->len < 200) {
    char mname[200];
    memcpy(mname, fn->loc, (size_t)fn->len);
    mname[fn->len] = '\0';
    int fi = find_method_func(p->prog, s->name, mname);
    if (fi >= 0)
      error_at(fn->loc, "'%.*s' 不是结构体 %s 的字段，但存在自由函数 '%s'——"
                        "方法调用点糖**必须带括号**：写 recv.%.*s(实参)（糖摊平后要找的是 '%s_%.*s'；"
                        "不带括号当值用不支持）",
               fn->len, fn->loc, s->name, p->prog->funcs[fi].name,
               fn->len, fn->loc, s->name, fn->len, fn->loc);
  }
  error_at(fn->loc, "结构体 %s 无字段 '%.*s'", s->name, fn->len, fn->loc);
}

// 解析一次方法调用点：p->tok 在方法名上、后面紧跟 '('。
//   recv = **源级接收者**表达式；value_recv = 接收者是结构体**值**（要补 &recv），
//   false = 接收者已经是指向该结构体的指针（原样传）。recv_desc 只用于报错文案。
// ⚠️ 这里对 recv **不做任何求值**：只取地址（ND_ADDR，codegen 出 lea）或直接复用指针值。
static Node *method_call(Parser *p, Node *recv, bool value_recv, int sidx, const char *recv_desc) {
  StructDef *s = &p->prog->structs[sidx];
  Token *mtok = p->tok;
  char mname[200];
  if (mtok->len >= (int)sizeof(mname))
    error_at(mtok->loc, "方法名过长（%d 字节）", mtok->len);
  memcpy(mname, mtok->loc, (size_t)mtok->len);
  mname[mtok->len] = '\0';
  char sugar[300];
  snprintf(sugar, sizeof(sugar), "%s_%.*s", s->name, mtok->len, mtok->loc);
  int fi = find_method_func(p->prog, s->name, mname);
  if (fi == -2)
    error_at(mtok->loc, "方法糖 'recv.%.*s(...)'（%s）摊平后要找的自由函数名有歧义："
                        "'%s' 与「忽略大小写的类型名段」都能匹配到多个函数——"
                        "请把类型名段的大小写写准（命名约定 = 结构体名_方法名，精确名 '%s'）",
             mtok->len, mtok->loc, recv_desc, mname, sugar);
  if (fi < 0)
    error_at(mtok->loc, "方法糖 'recv.%.*s(...)'（%s）摊平后要找的自由函数 '%s' 不存在——"
                        "方法就是普通自由函数：定义 int %s(struct %s *self, ...)，首参由调用方自动补 &recv"
                        "（命名约定 = 类型名_函数名）",
             mtok->len, mtok->loc, recv_desc, sugar, sugar, s->name);
  FuncDef *fn = &p->prog->funcs[fi];
  if (fn->nargs < 1)
    error_at(mtok->loc, "方法糖 'recv.%.*s(...)' 找到的 '%s' 一个形参都没有——"
                        "方法的首参必须是接收者（struct %s *self）", mtok->len, mtok->loc, fn->name, s->name);
  // 首参：**源级等价写法**就是 M_f(&m, ...)（值接收者）或 M_f(p, ...)（指针接收者）
  Node *arg0;
  if (fn->param_ref[0]) {
    if (!value_recv)
      error_at(mtok->loc, "方法糖 'recv.%.*s(...)' 找到的 '%s' 首参是引用形参（struct %s &self）——"
                          "引用形参只适用于结构体**值**接收者（m.f(...)）；指针接收者请把首参写成 struct %s *self",
               mtok->len, mtok->loc, fn->name, s->name, s->name);
    arg0 = recv;   // 交给 call_arg_norm 补 ND_ADDR，与手写 M_f(m, x) 同形
  } else if (fn->param_ty[0] == TY_PTR) {
    arg0 = value_recv ? new_node(ND_ADDR, recv, NULL) : recv;
  } else {
    error_at(mtok->loc, "方法糖 'recv.%.*s(...)' 找到的 '%s' 首参不是接收者指针/引用（收的是值形参）——"
                        "糖摊平后要传的是接收者地址，首参请写 struct %s *self",
             mtok->len, mtok->loc, fn->name, s->name);
    arg0 = NULL;
  }
  char *fn_loc = mtok->loc;   // v0.9.1：调用点源码位置（后遍 void 检查定位用）
  p->tok = p->tok->next;      // 吃方法名，p->tok 落在 '('
  skip(p, '(');
  arg0 = call_arg_norm(p, fn, 0, arg0);
  return call_finish(p, fn, fi, arg0, 1, fn_loc);
}

static Node *postfix(Parser *p) {
  Node *node = primary(p);
  for (;;) {
    if (consume(p, '[')) {
      // v1.0.6：指针返回调用 f() 也可下标（f()[i]，elem 随返回指向类型）
      // v1.0.9：结构体指针字段直接下标 s.arr[i] / p->arr[i]（字段读 = ND_DEREF+TY_PTR，
      //   语义 = 先取字段里的指针值再按元素宽缩放，等价于旧写法 `int *a = s.arr; a[i]`）
      // v1.4.4：放行地址链（ND_ADD/ND_SUB）——结构体**数组字段**作表达式时就是地址链节点
      //   （`s.buf` = (结构体地址 + 字段偏移)，ty=TY_ARR）；类型检查（TY_ARR/TY_PTR）在下一行仍兜底。
      if (node->kind != ND_VAR && node->kind != ND_CALL && node->kind != ND_DEREF
          && node->kind != ND_ADD && node->kind != ND_SUB)
        error_at(p->tok->loc, "下标需要数组名或指针变量");
      if (node->ty != TY_ARR && node->ty != TY_PTR)
        error_at(p->tok->loc, "下标对象须为数组或指针");
      Token *idx_tok = p->tok;   // v1.4.25：strict 下标越界的报错要指到「下标」那个 token
      Node *idx = expr(p);
      skip(p, ']');
      // ===== v1.4.25（`-strict`）④：常量下标越界 =====
      // 编译器**完全知道**数组有多长，静默放过等于把"写坏隔壁变量"（本文件 1554 行记的真实事故）
      // 留给运行期。只查**常量**下标（可静态判定）；变量下标不查（要值域分析，误报多）；
      // 指针下标不查（长度未知）。全局数组与非全局数组都查（长度分别来自 GlobalVar / LVar）。
      if (flint_strict && idx->kind == ND_NUM && node->kind == ND_VAR && node->ty == TY_ARR) {
        int len = -1;
        if (node->is_global) len = p->prog->globals[node->offset].arr_len;
        else { LVar *av = lv_by_offset(p->all_lvars, node->offset); if (av) len = av->arr_len; }
        if (len > 0 && (idx->val < 0 || idx->val >= len))
          error_at(idx_tok->loc, "[E-STRICT-BOUNDS] 常量下标 %d 越界：这个数组只有 %d 个元素"
                                 "（合法下标 0..%d）", idx->val, len, len - 1);
      }
      // a[i] = *(a + i*scale)：基址表达式（数组名 lea / 指针 load）+ 下标×元素宽
      //   int 元素 = 8 字节槽（旧语义）；v1.0.5 char 元素 = 1 字节（字节缓冲/字符串构建）
      int elem = node->elem_ty;
      // ⚠️ 元素宽必须与**语言的数组语义**一致，不是与 C 的 sizeof 一致：
      //   FLINT 的 int 元素 = **8 字节槽**（见本文件 postfix：`a[i] = *(a + i*8)`，SPEC 亦如此），
      //   所以 .data 里全局 int 数组也必须按 8 字节/元素摆放（见下方 collect_globals 的 esize）。
      //   🐞 实测踩过：`.data` 按 C 的 4 字节摆、下标却按 8 缩放 → `garr[2]` 跨到 +16 = **下一个全局变量**
      //   的槽上（静默写坏别的变量；[0]/[1] 恰好在界内所以看不出来，长程序才炸）。
      int esize_bytes = ty_arr_stride(elem);   // v1.7.0：走单点表（char 1 / int 4 / int_64 8 / double 8）
      Node *scaled = new_node(ND_MUL, idx, new_num(esize_bytes));
      Node *addr = new_node(ND_ADD, node, scaled);
      node = new_node(ND_DEREF, addr, NULL);
      node->ty = (elem == TY_CHAR) ? TY_CHAR
               : (elem == TY_DOUBLE) ? TY_DOUBLE
               : (elem == TY_INT64) ? TY_INT64 : TY_INT;   // v1.7.0：int_64 元素读 = 8 字节；char 元素读 = 字节（movzx）；double 元素 = 8 字节 SSE
    } else if (consume(p, '.')) {
      // p.x：p = 结构体变量（普通或引用；名字作表达式 = 结构体地址）
      // v1.6.0：方法调用点糖 recv.name(args) ⇒ Type_name(&recv, args) —— 判据 = **括号**
      //   （名字后面紧跟 '(' 才是方法候选；不带括号一律按字段访问的老语义走）
      Token *mname0 = p->tok;
      bool mcall = (mname0->kind == TK_IDENT && mname0->next && is_punct(mname0->next, '('));
      bool recv_val = (node->kind == ND_VAR && node->ty == TY_STRUCT && node->struct_idx >= 0);
      // 指针接收者的 '.' 形态只认**变量**（与既有字段语义同一条线：'.' 左侧须是变量）。
      //   表达式结果（f().g(...)）不走 '.'——它没有可取的地址；要指针接收者请写 f()->g(...)。
      bool recv_ptr = (node->kind == ND_VAR && node->ty == TY_PTR && node->struct_idx >= 0);
      if (recv_ptr && !mcall)
        error_at(mname0->loc, "'.' 左侧是指向结构体的指针：**字段**访问请写 '->'（p->x）；"
                              "只有方法调用点 p.%.*s(...) 才允许用 '.'", mname0->len, mname0->loc);
      if (mcall && (recv_val || recv_ptr)) {
        // ⑤ 括号判据的**歧义闸门**：这个名字同时是字段 ⇒ 响亮报错（绝不静默替人做选择）
        method_vs_field_guard(p, node->struct_idx, mname0);
        node = method_call(p, node, recv_val, node->struct_idx,
                           recv_val ? "值接收者" : "指针接收者的点号形式");
        continue;
      }
      // v1.6.0：解引用链 (*p).f(...) ⇒ M_f(p, ...)——与 p->f(...) 等价（地址就是 p 本身）
      if (mcall && node->kind == ND_DEREF && node->lhs
          && node->lhs->ty == TY_PTR && node->lhs->struct_idx >= 0) {
        method_vs_field_guard(p, node->lhs->struct_idx, mname0);
        node = method_call(p, node->lhs, false, node->lhs->struct_idx, "解引用链 (*p) 接收者");
        continue;
      }
      if (node->kind != ND_VAR || node->ty != TY_STRUCT || node->struct_idx < 0) {
        // v1.6.0（I4 ①④）：带括号 = 方法调用点的形态，接收者不可寻址 / 不是 struct ⇒ 专门的文案
        if (mcall) {
          bool addr_like = (node->ty == TY_STRUCT) || (node->ty == TY_PTR && node->struct_idx >= 0);
          if (addr_like)
            error_at(mname0->loc, "接收者是**表达式结果**而不是变量：'.' 形式的方法调用点糖要取接收者的地址"
                                  "（糖摊平后首参 = &recv），对 f()/(a+b) 这类临时量取地址是错的——"
                                  "指针接收者请写 recv->%.*s(...)（f()->g(...) 合法；f().g(...) 是编译期错误）",
                     mname0->len, mname0->loc);
          error_at(mname0->loc, "接收者的类型不是结构体（这是方法调用点糖 'recv.%.*s(...)' 的形态，"
                                "糖摊平后 = 类型名_%.*s(&recv, ...)）——接收者须是 struct 变量 / "
                                "指向 struct 的变量 / 解引用链 (*p)",
                   mname0->len, mname0->loc, mname0->len, mname0->loc);
        }
        error_at(p->tok->loc, "'.' 左侧须为结构体变量");
      }
      StructDef *s = &p->prog->structs[node->struct_idx];
      Token *fn = p->tok;
      int foff = -1;
      int fty = TY_INT;   // v0.9.2：字段类型（决定读写宽度）
      int felem = TY_INT;   // v1.2.5：指针字段的指向类型（int* → TY_INT；double* → TY_DOUBLE）
      foff = struct_field_lookup(s, fn, &fty, &felem);
      if (foff < 0)
        no_such_field_error(p, s, fn);
      p->tok = p->tok->next;
      // v1.4.4：**数组字段作表达式 = 首元素地址**（与数组名退化同语义）→ 直接给地址节点、不套 ND_DEREF。
      //   这样三种用法全部自然成立：`s.buf[i]`（下标按 elem_ty 缩放）、`&s.buf[0]`、把 `s.buf` 传给 `int p[]`。
      if (fty == TY_ARR) {
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_ARR;
        da->elem_ty = felem;
        node = da;
      } else {
        Node *d = new_node(ND_DEREF, new_node(ND_ADD, node, new_num(foff)), NULL);
        d->ty = fty;   // v0.9.2：ptr 字段读 = 64 位、int 字段读 = 32 位
        // v1.2.5：指针字段把**指向类型**带到节点上 —— `*s.p` 的读写宽度（ptr_elem_ty 读 elem_ty）、
        //   `s.p[i]` 的下标缩放都由它决定（否则 double* 字段会被当 int* 静默按 32 位/元素 8 字节错走）
        if (fty == TY_PTR) d->elem_ty = felem;
        node = d;
      }
    } else if (consume_str(p, "->")) {
      // ptr->x：ptr = 指向结构体的指针
      // v1.0.6：struct* 返回调用 f()->x 穿透（struct_idx 随返回）
      // v1.6.0：方法调用点糖 —— p->f(...) ⇒ M_f(p, ...)（指针接收者原样传，不取址）
      Token *mname1 = p->tok;
      bool mcall1 = (mname1->kind == TK_IDENT && mname1->next && is_punct(mname1->next, '('));
      if (mcall1 && node->ty == TY_PTR && node->struct_idx >= 0) {
        method_vs_field_guard(p, node->struct_idx, mname1);   // ⑤ 同名歧义 ⇒ 响亮报错
        node = method_call(p, node, false, node->struct_idx, "指针接收者的箭头形式");
        continue;
      }
      if ((node->kind != ND_VAR && node->kind != ND_CALL) || node->ty != TY_PTR || node->struct_idx < 0)
        error_at(p->tok->loc, "'->' 左侧须为指向结构体的指针");
      StructDef *s = &p->prog->structs[node->struct_idx];
      Token *fn = p->tok;
      int foff = -1;
      int fty = TY_INT;   // v0.9.2：字段类型（决定读写宽度）
      int felem = TY_INT;   // v1.2.5：指针字段的指向类型（int* → TY_INT；double* → TY_DOUBLE）
      foff = struct_field_lookup(s, fn, &fty, &felem);
      if (foff < 0)
        no_such_field_error(p, s, fn);
      p->tok = p->tok->next;
      // v1.4.4：**数组字段作表达式 = 首元素地址**（与数组名退化同语义）→ 直接给地址节点、不套 ND_DEREF。
      //   这样三种用法全部自然成立：`s.buf[i]`（下标按 elem_ty 缩放）、`&s.buf[0]`、把 `s.buf` 传给 `int p[]`。
      if (fty == TY_ARR) {
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_ARR;
        da->elem_ty = felem;
        node = da;
      } else {
        Node *d = new_node(ND_DEREF, new_node(ND_ADD, node, new_num(foff)), NULL);
        d->ty = fty;   // v0.9.2：ptr 字段读 = 64 位、int 字段读 = 32 位
        // v1.2.5：指针字段把**指向类型**带到节点上 —— `*s.p` 的读写宽度（ptr_elem_ty 读 elem_ty）、
        //   `s.p[i]` 的下标缩放都由它决定（否则 double* 字段会被当 int* 静默按 32 位/元素 8 字节错走）
        if (fty == TY_PTR) d->elem_ty = felem;
        node = d;
      }
    } else if (consume_str(p, "++")) {
      if (!is_lvalue(node))
        error_at(p->tok->loc, "++ 需要可修改的变量或 *p（左值）");
      check_field_incr(p, node);
      check_dbl_incr(p, node);
      // v1.7.0 P1：int_64 的 ++ 已放开（P0 的 32 位通路会静默只改低半槽，所以当时拦下）。
      //   值 = **旧的** 64 位值；codegen 的 ND_POST_INC 有专门的 int64 分支。
      bool i64 = expr_is_i64(node);
      node = new_node(ND_POST_INC, node, NULL);
      if (i64) node->ty = TY_INT64;
    } else if (consume_str(p, "--")) {
      if (!is_lvalue(node))
        error_at(p->tok->loc, "-- 需要可修改的变量或 *p（左值）");
      check_field_incr(p, node);
      check_dbl_incr(p, node);
      // v1.7.0 P1：int_64 的 -- 同 ND_POST_INC
      bool i64 = expr_is_i64(node);
      node = new_node(ND_POST_DEC, node, NULL);
      if (i64) node->ty = TY_INT64;
    } else {
      return node;
    }
  }
}

// primary = "(" expr ")" | NUM | 标识符
static Node *primary(Parser *p) {
  if (consume(p, '(')) {
    Node *n = expr(p);
    skip(p, ')');
    return n;
  }
  if (p->tok->kind == TK_NUM) {
    Node *n = new_num(p->tok->val);
    p->tok = p->tok->next;
    return n;
  }
  // v1.7.0：64 位字面量（词法层已按宽度规则判过：十进制 > INT32_MAX / 十六进制 > 0xFFFFFFFF / L 后缀）
  if (p->tok->kind == TK_NUM64) {
    Node *n = new_node(ND_NUM64, NULL, NULL);
    n->lval = p->tok->lval;
    n->ty = TY_INT64;
    p->tok = p->tok->next;
    return n;
  }
  // v1.1.0 浮点（阶段1）：double 字面量（值已由词法层解析成 double）
  if (p->tok->kind == TK_DBL) {
    Node *n = new_node(ND_DBL, NULL, NULL);
    n->dval = p->tok->dval;
    n->ty = TY_DOUBLE;
    p->tok = p->tok->next;
    return n;
  }
  // v0.7.3：字符串字面量 → ND_STR（值 = 数据段地址；内容与 token 同生命周期）
  if (p->tok->kind == TK_STR) {
    Node *n = new_node(ND_STR, NULL, NULL);
    n->str = p->tok->sval;
    n->str_len = p->tok->slen;
    p->tok = p->tok->next;
    return n;
  }
  // v1.1.0 浮点（阶段1）：to_int(表达式) —— double → int 的**显式**转换（截断取整，cvttsd2si）
  // ⚠️ 必须在 primary 的最前面判：postfix 会先把 `(` 当函数调用吃掉（首版插在 TK_IDENT 分支里，
  //    结果 to_int(...) 被解析成调用 → 28 项回归炸出「内部错误：表达式出现语句节点」）
  if (p->tok->kind == TK_IDENT && is_ident(p->tok, "to_int")
      && p->tok->next && is_punct(p->tok->next, '(')) {
    p->tok = p->tok->next;
    p->tok = p->tok->next;            // 吃掉 '('
    // v1.2.1 修：实参**已经是 double** 时不能再 widen —— 原实现无条件 widen_dbl，
    //   而 expr_widen_dbl 对 int 才包 ND_I2D；对已是 double 的表达式本应恒等返回。
    //   实测（2026-09-13）：`to_int(half())`（half 返回 0.5）先被包成 ND_I2D →
    //   生成 `cvtsi2sd %eax` 把 double 值当 int 读低 32 位（0.5 的位型低半 = 0）→
    //   0.5 → 0.0 → to_int 得 0（静默错值）。判据仍是同一个 expr_is_dbl。
    Node *arg = expr(p);
    Node *in = expr_is_dbl(arg) ? arg : widen_dbl(arg);
    skip(p, ')');
    return new_node(ND_D2I, in, NULL);
  }
  // ===== v1.7.0：int_64 的显式转换（与 to_int 同族，**必须**在 primary 的最前面判——
  //   postfix 会先把 `(` 当函数调用吃掉，见上面 to_int 的教训）=====
  //   to_int32(值)：int_64 → int 的**显式收窄**（取低 32 位）。赋值/实参里收窄是硬错，
  //     这是唯一的合法通道 —— 也是 64 位探针造"退出码判据"的唯一办法（main 返回 int）。
  //   to_int64(值)：int → int_64 的显式拓宽（隐式也会做，留着它让口径可写全）。
  if (p->tok->kind == TK_IDENT && is_ident(p->tok, "to_int32")
      && p->tok->next && is_punct(p->tok->next, '(')) {
    Token *kw = p->tok;
    p->tok = p->tok->next;
    p->tok = p->tok->next;            // 吃掉 '('
    Node *arg = expr(p);
    skip(p, ')');
    if (!expr_is_i64(arg))
      error_at(kw->loc, "to_int32(...) 只用于 int_64 → int 的显式收窄（实参已经是 int：不必转）");
    Node *c = new_node(ND_L2I, arg, NULL);
    c->ty = TY_INT;
    return c;
  }
  if (p->tok->kind == TK_IDENT && is_ident(p->tok, "to_int64")
      && p->tok->next && is_punct(p->tok->next, '(')) {
    p->tok = p->tok->next;
    p->tok = p->tok->next;            // 吃掉 '('
    Node *arg = expr(p);
    skip(p, ')');
    if (expr_is_dbl(arg))
      error_at(p->tok->loc, "to_int64(...) 不支持 double（P0/P1 不支持 int_64 与 double 互转）");
    return widen_i64(arg);
  }
  // v1.5.0：str([段, ...]) 内建 —— 段数组拼进静态缓冲，产物是 char*（不输出到 stdout）。
  //   **本处（表达式里）一律不支持**：展开是语句链，只认 3 个语句级形态（声明初始化 / 赋值右值 /
  //   指针返回函数的 return），由 stmt_inner 与 decl_list 在语句层识别 ⇒ 落到这里就是响亮报错。
  if (is_str_call(p->tok))
    str_ctx_error(p->tok->loc);
  if (p->tok->kind == TK_IDENT) {
    // v0.9：new int —— 堆分配（头部 8B refcount + int 负载 8B，返回负载地址）
    if (is_ident(p->tok, "new")) {
      p->tok = p->tok->next;
      // v1.7.0：new int_64 明确报错（堆负载按类型分派还没做；要 64 位堆对象请 new int 再用 int_64* 承接）
      if (is_ident(p->tok, "int_64"))
        error_at(p->tok->loc, "'new int_64' 暂不支持（v1.7.0 P0 边界）——"
                              "堆上要 64 位可以 new int（负载 8 字节）再用 int_64 * 承接");
      if (!is_ident(p->tok, "int"))
        error_at(p->tok->loc, "'new' 暂支持 'new int'（结构体/数组 new 后续版本）");
      p->tok = p->tok->next;
      if (is_punct(p->tok, '['))
        error_at(p->tok->loc, "数组 new 暂不支持（v0.9 单对象 new int）");
      if (p->prog->api_alloc < 0)
        error_at(p->tok->loc, "内部错误：'new' 需要内置 VirtualAlloc 登记");
      Node *n = new_node(ND_NEW, NULL, NULL);
      n->api_index = p->prog->api_alloc;
      n->val = 8;   // int 负载 8 字节
      return n;
    }
    if (is_keyword(p->tok))
      error_at(p->tok->loc, "意外的关键字 '%.*s'", p->tok->len, p->tok->loc);
    bool paren = p->tok->next && is_punct(p->tok->next, '(');
    // 变量优先（作用域内）
    LVar *v = find_lvar(p, p->tok);
    if (v) {
      if (paren) {
        // v1.3.2：函数指针变量可调用（间接调用 FF D0）；其余变量仍不可调用
        if (v->ty != TY_FUNCPTR)
          error_at(p->tok->loc, "变量 '%.*s' 不可调用（它不是函数指针；函数指针用 int (*fp)(int) 声明）",
                   p->tok->len, p->tok->loc);
        return parse_indirect_call(p, v);
      }
      Node *n = new_var_node(v->offset, v->is_ref, v->ty, v->struct_idx, v->elem_ty);
      n->loc = p->tok->loc;   // v1.4.25：变量读也带上源码位置（strict 的未初始化诊断要 caret 指到位）
      n->is_own = v->is_own;   // v0.9：own/share 读（拷贝限制在赋值/实参处）
      n->is_share = v->is_share;
      n->fn_sig = v->fn_sig;   // v1.3.2：函数指针变量把签名带走（赋值/实参检查要用）
      p->tok = p->tok->next;
      return n;
    }
    // v1.3.0：全局变量（局部变量已在上一步遮蔽同名全局——C 的作用域规则）
    int gi = find_global(p->prog, p->tok);
    if (gi >= 0) {
      if (paren)
        error_at(p->tok->loc, "全局变量 '%.*s' 不可调用", p->tok->len, p->tok->loc);
      Node *n = new_global_node(gi, &p->prog->globals[gi]);
      p->tok = p->tok->next;
      return n;
    }
    // 函数调用（名字在第一遍预扫描时已全部登记，支持先调用后定义）
    int fi = find_func(p->prog, p->tok);
    if (fi >= 0) {
      FuncDef *fn = &p->prog->funcs[fi];
      if (!paren)
        error_at(p->tok->loc, "函数 '%.*s' 需带括号调用", p->tok->len, p->tok->loc);
      char *fn_loc = p->tok->loc;   // v0.9.1：调用点源码位置（后遍 void 检查定位用）
      p->tok = p->tok->next;   // 吃函数名
      skip(p, '(');
      // v1.6.0：实参解析 / 规范化 / 收尾整段抽成 call_finish + call_arg_norm ——
      //   方法调用点糖（method_call）与这里**共用同一份**：两条路各写一份必然分叉，
      //   而方法糖的判据是「与手写自由函数调用逐字节同结果」（D11 I2）。
      //   v1.2.2 的实参个数当场检查 / double 通道自动提升 / 引用形参自动取址 / 函数指针签名比对
      //   全部原样搬进 call_arg_norm 与 call_finish，本行以下的语义与改动前逐条相同。
      return call_finish(p, fn, fi, NULL, 0, fn_loc);
    }
    // v0.8：API 调用（声明在文件顶；参数全按 Win64 寄存器传，类型无关）
    int ai = find_api(p->prog, p->tok);
    if (ai >= 0) {
      ApiDef *a = &p->prog->apis[ai];
      if (!paren)
        error_at(p->tok->loc, "API '%.*s' 需带括号调用", p->tok->len, p->tok->loc);
      char *fn_loc = p->tok->loc;   // v0.9.1：调用点源码位置（后遍 void 检查定位用）
      p->tok = p->tok->next;
      skip(p, '(');
      Node *head = NULL;
      Node **cur = &head;
      int nargs = 0;
      if (!is_punct(p->tok, ')')) {
        for (;;) {
          if (nargs >= a->nargs)
            error_at(p->tok->loc, "实参个数超过 API 声明（%d 个）", a->nargs);
          Node *arg = assign(p);
          if (arg->kind == ND_VAR && (arg->is_own || arg->is_share))
            error_at(p->tok->loc, "own/share 指针不能作实参（所有权语义，拷贝初始化专属 v0.9）");
          // v1.1.0：声明 double 就必须传 double（声明与实参不一致 = 静默传错寄存器通道）
          // v1.7.0：int_64 实参一律硬错（api 的参数宽度在声明里无从表达 ⇒ 只能按 int 32 位传 = 静默截断）
          if (expr_is_i64(arg))
            error_at(p->tok->loc, "int_64 实参不能直接传给 api 函数（v1.7.0 P0 边界：api 声明没有 64 位参数档，"
                                  "会按 32 位传）——请先显式写 to_int32(值)");
          if (nargs < API_MAX_ARGS && a->param_dbl[nargs]) arg = widen_dbl(arg);
          else if (nargs < API_MAX_ARGS && is_dbl_node(arg))
            error_at(p->tok->loc, "这个 API 参数声明的是 int——double 实参会走 XMM 通道，声明与实参必须一致");
          *cur = arg;
          cur = &arg->next;
          nargs++;
          if (!consume(p, ',')) break;
        }
      }
      skip(p, ')');
      Node *call = new_node(ND_APICALL, NULL, head);
      call->api_index = ai;
      call->nargs = nargs;
      call->is_void = a->ret_void;
      call->ty = a->ret_ty;   // v0.9.2：ptr 返回 → 调用表达式按地址类（64 位）参与运算/比较/间接写
      call->loc = fn_loc;             // v0.9.1
      return call;
    }
    error_at(p->tok->loc, "使用了未声明的变量 '%.*s'", p->tok->len, p->tok->loc);
  }
  error_at(p->tok->loc, "期望数字/变量/'('，得到 '%.*s'", p->tok->len, p->tok->loc);
  return NULL;
}

// —— 顶层（v0.5 多函数）——
// 按名查函数（Program.funcs 线性扫），返回下标或 -1
static int find_func(Program *prog, Token *tok) {
  for (int i = 0; i < prog->nfuncs; i++) {
    FuncDef *f = &prog->funcs[i];
    if ((int)strlen(f->name) == tok->len && strncmp(f->name, tok->loc, tok->len) == 0)
      return i;
  }
  return -1;
}

// ========== v1.0.8 print 内建输出语句 ==========
// print([段, ...] [, 换行?]) ；段 = 任意表达式，类型自适应分派：
//   char*（字符串字面量/char 数组名/char* 表达式）→ 整串输出（_flint_out_str）
//   char 值 → 单字符输出（_flint_out_char）
//   int 值（含算术/比较等表达式）→ 十进制输出（_flint_out_int）
//   double 值（v1.2.3）→ 定点 6 位小数输出（_flint_out_dbl；纯 FLINT 实现，含四舍五入/负数/NaN 守卫）
// 换行第二参：0/1 常量（1 = 换行）；省略 = 不换行（cout 式默认）。
// 实现：展开为对 _flint_out_* 隐藏函数的调用语句链——这些函数由 main.c 探测到
// print 后把内置库源码注入编译单元头部提供（parse 时已被 collect_funcs 预扫登记）。
static int find_func_by_name(Program *prog, const char *name) {
  Token tmp;
  tmp.loc = (char *)name;
  tmp.len = (int)strlen(name);
  return find_func(prog, &tmp);
}

// 段输出类别：0=串 1=字符 2=int 3=double 4=int_64（v1.7.0）
static int seg_print_kind(Parser *p, Token *s0, Node *n) {
  // v1.2.3 浮点打印：double 段走 _flint_out_dbl（纯 FLINT 写的 double→字符串，见 main.c 内置输出库）——
  //   固定 6 位小数 + 四舍五入；负数/零/进位都由它自己处理。到达这里之前**已经不是静默**：
  //   上一版是编译期报错，现在是真支持（靠 v1.2.2 打通的 double 形参把值送进去）。
  if (expr_is_dbl(n)) return 3;
  // v1.7.0：int_64 段必须在 switch **之前**判 —— ND_ADD/ND_DEREF/ND_VAR 的 kind 分支
  //   一律按 32 位 int 落档（打印器读的是 eax 的那半截），漏这一条 = 打印出高 32 位丢掉的值。
  if (expr_is_i64(n)) return 4;
  switch (n->kind) {
  case ND_STR: return 0;    // 字符串字面量
  case ND_NUM: return 2;    // 数字字面量（字符字面量 'A' = int 值 65，打数字——已知边界）
  case ND_VAR:
    if (n->ty == TY_ARR) {
      if (n->elem_ty == TY_CHAR) return 0;   // char 数组名 = char*（须 \0 终止）
      error_at(s0->loc, "int 数组不能整体打印（逐元素 print([a[i]])）");
    }
    if (n->ty == TY_PTR) {
      if (n->elem_ty == TY_CHAR) return 0;   // char*
      error_at(s0->loc, "该指针暂不支持直接打印（仅 char* 串可用；int*/struct* = 已知边界）");
    }
    if (n->ty == TY_CHAR) return 1;          // char 变量 → 字符
    if (n->ty == TY_INT) return 2;
    if (n->ty == TY_FUNCPTR)
      error_at(s0->loc, "函数指针不能直接打印（它存的是代码地址，不是可显示的数值）");
    error_at(s0->loc, "struct 变量不能整体打印（逐字段 print([s.x])）");
  case ND_CALL:
    if (n->ty == TY_PTR) {
      if (n->elem_ty == TY_CHAR) return 0;   // char* 返回函数调用
      error_at(s0->loc, "该指针返回暂不支持直接打印（仅 char* 串可用）");
    }
    if (n->ty == TY_CHAR) return 1;
    return 2;                                // int 返回
  case ND_DEREF:
    if (n->ty == TY_CHAR) return 1;          // *p (char*) = char 值 → 字符
    if (n->ty == TY_INT) return 2;
    if (n->ty == TY_PTR) error_at(s0->loc, "指针字段/指针解引用结果暂不支持直接打印");
    return 2;
  case ND_NEW:
    error_at(s0->loc, "new 地址不能直接打印（先由 own/share 接管或存变量）");
  case ND_ADDR:
    error_at(s0->loc, "地址值（&x）暂不支持直接打印（64 位，起步边界）");
  case ND_CAST:
    // v1.8.0：转型结果按**括号里的类型**分派（double / int_64 档已被上面的共用判据接走）
    if (n->ty == TY_PTR) {
      if (n->elem_ty == TY_CHAR) return 0;   // (char*)p = 字符串
      error_at(s0->loc, "指针转型结果暂不支持直接打印（仅 char* 串可用）");
    }
    if (n->ty == TY_CHAR) return 1;          // (char)x → 字符
    return 2;                                // (int)x → 数字
  default:
    return 2;   // 算术/位/比较/逻辑/赋值/自增自减 = int 值语义
  }
}

// 单段 → 输出调用节点（ND_CALL _flint_out_xxx(段)）
static Node *print_seg_call(Parser *p, Token *s0, Node *seg) {
  int k = seg_print_kind(p, s0, seg);
  const char *fn = (k == 0) ? "_flint_out_str"
                 : (k == 1) ? "_flint_out_char"
                 : (k == 3) ? "_flint_out_dbl"
                 : (k == 4) ? "_flint_out_i64"
                            : "_flint_out_int";
  int fi = find_func_by_name(p->prog, fn);
  if (fi < 0)
    error_at(s0->loc, "内部错误：print 需要内置输出函数 %s（编译器注入缺失）", fn);
  Node *call = new_node(ND_CALL, NULL, seg);
  call->func_index = fi;
  call->nargs = 1;
  call->ty = TY_INT;   // 输出函数返回 int（语句位值丢弃）
  call->loc = s0->loc;
  return call;
}

// ========== v1.5.0 str 内建：段数组 → char*（共享静态缓冲）==========
// 形态：str([段, ...])——段分派与 print **逐条同口径**（同一个 seg_print_kind、同一批
//   _flint_out_str/_char/_int/_dbl 格式化函数），区别只在"去哪儿"：注入库的 _flint_out_bytes
//   按 _flint_sink 分派（0=stdout 给 print，1=静态缓冲给 str）⇒ **只有一套格式化实现**，不会分叉。
// 展开 = **语句链**（与 print_stmt 同一种做法，零 codegen 改动）：
//   char *s = str([a, b]);  →  { _flint_str_begin(); _flint_str_put_str(a); _flint_str_put_int(b);
//                                s = _flint_str_end(); }
// ⚠️ 为什么不能写成嵌套调用链（`_end(_seg(b, _seg(a, _begin())))`）：FLINT 的**实参求值顺序是
//   右→左**（探针 tmp\strkit\p4_argorder.fl 实测输出 "BA"）⇒ "段值"会先于外层缓冲复位求值，
//   段里间接再跑到 str() 时结果静默错（实测：段含 fn_str() 时得 "mnFNlitmnFNlit" 而不是 0/
//   正确值）。语句链把顺序钉死在语句序上，与实参求值顺序无关。
// 上限：_flint_buf[FLINT_STRBUF_CAP]（单点定义在 flint.h）——内容超过 CAP-1 字节 ⇒ 整个 str()
//   返回 0（响亮失败，**不静默截断**）；段全是字面量时还能在**编译期**算出总长直接拦。
// 别名语义：所有 str() 共用同一个静态缓冲 ⇒ **第二次 str() 覆盖第一次的结果**（探针钉住）。
static bool is_str_call(Token *t) {
  return is_ident(t, "str") && t->next && is_punct(t->next, '(')
      && t->next->next && is_punct(t->next->next, '[');
}

// 上下文不符时的统一报错文案（primary 兜底 + return 类型不符处复用）
static void str_ctx_error(char *loc) {
  error_at(loc, "str([...]) 只在 ① 指针变量声明初始化（char *s = str([...]);）"
                "② 赋值语句右值（s = str([...]);，左值是 char*/int* 变量）"
                "③ 指针返回函数的 return 值 —— 这 3 个位置、且作整个右值可用；"
                "本处不支持（不能作 print 段/实参/条件/算术的一部分，不能嵌套，也不能当语句丢弃）");
}

// ND_NUM 段的十进制字节数（与 _flint_out_int 的数位口径逐条对应：负号 + 数位；0 → 1 位）。
//   ND_NUM 的值就是 int32（Token.val / Node.val 都是 int），所以本核算对字面量是精确的
static int int_dec_len(int v) {
  long long x = v;
  int n = 1;
  if (x < 0) { n = 2; x = -x; }
  while (x >= 10) { x /= 10; n++; }
  return n;
}

// 单段 → 缓冲追加调用（_flint_str_put_xxx(段)）；段类别判定与 print **同一个** seg_print_kind
static Node *str_put_call(Parser *p, Token *s0, Node *seg) {
  int k = seg_print_kind(p, s0, seg);
  const char *fn = (k == 0) ? "_flint_str_put_str"
                 : (k == 1) ? "_flint_str_put_char"
                 : (k == 3) ? "_flint_str_put_dbl"
                 : (k == 4) ? "_flint_str_put_i64"
                            : "_flint_str_put_int";
  int fi = find_func_by_name(p->prog, fn);
  if (fi < 0)
    error_at(s0->loc, "内部错误：str 需要内置缓冲函数 %s（编译器注入缺失）", fn);
  Node *call = new_node(ND_CALL, NULL, seg);
  call->func_index = fi;
  call->nargs = 1;
  call->ty = TY_INT;           // 追加函数返回 int（语句位值丢弃，与 print 的 _flint_out_* 同型）
  call->loc = s0->loc;
  return call;
}

// ===== v1.6.2：print / str **段位置**里的裸 `endl`（C++ 的 std::endl 用法）=====
//   口径（所有者 2026-10-15 提的写法 `print(["a = ", a, endl]);`）：
//     **段位置**上的裸标识符 `endl`、且后面紧跟 ',' 或 ']' ⇒ 展开成**已有的**字符串字面量 "\n"
//     ⇒ 零 codegen 改动（D11 的 I1）、不写就不花预算（I3）、段序由语句序钉死（I2）。
//   其它位置一律还是普通标识符（`endl + 1` 照旧报"未声明"，不会静默变成换行）。
//   `str([...])` 同享这一条 —— 两条腿共用同一套段机制，规则分叉只会让生成端要记两套写法。
//   ⚠️ 这是**位置性**记号：段列表里若真有个叫 `endl` 的变量会被遮住（仓库现有代码里没有同名变量）。
static bool at_endl_seg(Parser *p) {
  if (p->tok->kind != TK_IDENT || p->tok->len != 4) return false;
  if (strncmp(p->tok->loc, "endl", 4) != 0) return false;
  Token *nx = p->tok->next;
  return nx && (is_punct(nx, ',') || is_punct(nx, ']'));
}
static Node *endl_seg_node(Parser *p) {
  Token *t = p->tok;
  p->tok = p->tok->next;                 // 吃 endl
  Node *n = new_node(ND_STR, NULL, NULL);
  n->str = strdup("\n");
  n->str_len = 1;
  n->loc = t->loc;
  return n;
}

// 段列表 → 语句链：p->tok 停在 'str' 上。begin + 各段 put 追加到 *cur（调用方已有的语句链尾），
// 返回末尾的 `_flint_str_end()` 调用节点（值 = char*，超限时 0）——由调用方决定它怎么落地
// （声明初始化 / 赋值 / return）。
static Node *str_parse_body(Parser *p, Node **cur) {
  Token *kw = p->tok;
  p->tok = p->tok->next;   // 吃 str
  skip(p, '(');
  skip(p, '[');
  int fb = find_func_by_name(p->prog, "_flint_str_begin");
  if (fb < 0)
    error_at(kw->loc, "内部错误：str 需要内置缓冲函数 _flint_str_begin（编译器注入缺失）");
  Node *b = new_node(ND_CALL, NULL, NULL);
  b->func_index = fb;
  b->nargs = 0;
  b->ty = TY_PTR;              // 返回缓冲地址（语句位值丢弃）
  b->elem_ty = TY_CHAR;
  b->loc = kw->loc;
  *cur = (*cur)->next = new_node(ND_EXPR_STMT, b, NULL);
  int lit_total = 0;           // 全字面量时的编译期总长核算（非字面量段 ⇒ lit_ok=0，交给运行期守卫）
  bool lit_ok = true;
  while (!is_punct(p->tok, ']')) {
    if (p->tok->kind == TK_EOF) error_at(p->tok->loc, "str 段列表缺少 ']'");
    if (is_str_call(p->tok)) str_ctx_error(p->tok->loc);   // 嵌套的 str([...])（段里不允许）
    Token *s0 = p->tok;
    Node *seg = at_endl_seg(p) ? endl_seg_node(p) : assign(p);   // 段 = 完整赋值表达式（与 print 同一层）；v1.6.2：裸 endl = "\n" 段
    if (flint_safe_mode && subtree_has_new(seg))
      error_at(s0->loc, "安全模式（-safe）：str 段内 new 会泄漏（先由 own/share 接管再拼）");
    if (seg->kind == ND_STR) lit_total += seg->str_len;
    else if (seg->kind == ND_NUM) lit_total += int_dec_len(seg->val);
    else lit_ok = false;
    Node *put = str_put_call(p, s0, seg);
    *cur = (*cur)->next = new_node(ND_EXPR_STMT, put, NULL);
    if (!consume(p, ',')) {
      if (!is_punct(p->tok, ']'))
        error_at(p->tok->loc, "str 段之间用 ',' 分隔，段列表以 ']' 结束");
      break;
    }
  }
  p->tok = p->tok->next;   // 吃 ]
  if (is_punct(p->tok, ','))
    error_at(p->tok->loc, "str([...]) 不接受 print 的第二参（换行标志 0|1）——要换行请用 print([...], 1)；"
                          "str 的产物是 char*，本身没有'换行'这回事");
  skip(p, ')');
  if (lit_ok && lit_total > FLINT_STRBUF_CAP - 1)
    error_at(kw->loc, "str([...]) 的段全是字面量、总长 %d 字节 > 缓冲上限 %d 字节 —— 编译期直接拦下"
                      "（运行期超限同样是响亮失败：str() 返回 0，绝不静默截断）",
             lit_total, FLINT_STRBUF_CAP - 1);
  int fe = find_func_by_name(p->prog, "_flint_str_end");
  if (fe < 0)
    error_at(kw->loc, "内部错误：str 需要内置缓冲函数 _flint_str_end（编译器注入缺失）");
  Node *end = new_node(ND_CALL, NULL, NULL);
  end->func_index = fe;
  end->nargs = 0;
  end->ty = TY_PTR;            // 产物 = char*（超限时是 0）
  end->elem_ty = TY_CHAR;
  end->loc = kw->loc;
  return end;
}

// ① 声明初始化：char *s = str([...]);（调用方已确认声明是指针类型、且当前 token = str ( [）
static void str_decl_init(Parser *p, Node **cur, Node *var, Token *name) {
  Node *end = str_parse_body(p, cur);
  Node *asgn = new_node(ND_ASSIGN, var, end);
  asgn->loc = name->loc;
  *cur = (*cur)->next = new_node(ND_EXPR_STMT, asgn, NULL);
}

// ② 赋值语句：s = str([...]);（左值 = 已声明的 char*/int* 变量；与 assign 的同名检查逐条对齐）
static Node *str_assign_stmt(Parser *p) {
  Token *nm = p->tok;
  LVar *v = find_lvar(p, nm);
  if (!v)
    error_at(nm->loc, "str([...]) 的赋值左值 '%.*s' 未声明——要先声明指针（char *s;）再 s = str([...]);",
             nm->len, nm->loc);
  if (v->ty != TY_PTR)
    error_at(nm->loc, "str([...]) 只能赋给 char*/int* 指针变量（'%.*s' 不是指针）——"
                      "它只在 ① 指针变量声明初始化 ② 赋值语句右值 ③ 指针返回函数的 return 值 可用",
             nm->len, nm->loc);
  if (v->is_own || v->is_share)
    error_at(nm->loc, "own/share 指针不能重新赋值（所有权由声明初始化 + 出口自动释放管理）");
  p->tok = p->tok->next;   // 吃变量名
  skip(p, '=');
  Node *lhs = new_var_node(v->offset, v->is_ref, v->ty, v->struct_idx, v->elem_ty);
  lhs->is_own = v->is_own;
  lhs->is_share = v->is_share;
  Node head = {0};
  Node *cur = &head;
  Node *end = str_parse_body(p, &cur);
  Node *asgn = new_node(ND_ASSIGN, lhs, end);
  asgn->loc = nm->loc;
  cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
  skip(p, ';');
  return block_of(head.next);
}

// ③ 指针返回函数的 return：return str([...]);
static Node *str_return_stmt(Parser *p) {
  Node head = {0};
  Node *cur = &head;
  Node *end = str_parse_body(p, &cur);
  cur = cur->next = new_node(ND_RETURN, end, NULL);
  skip(p, ';');
  return block_of(head.next);
}

static Node *print_stmt(Parser *p) {
  p->tok = p->tok->next;   // print
  skip(p, '(');
  skip(p, '[');
  Node head = {0};
  Node *cur = &head;
  while (!is_punct(p->tok, ']')) {
    if (p->tok->kind == TK_EOF) error_at(p->tok->loc, "print 段列表缺少 ']'");
    Token *s0 = p->tok;
    Node *seg = at_endl_seg(p) ? endl_seg_node(p) : assign(p);   // 段 = 完整赋值表达式；v1.6.2：裸 endl = "\n" 段
    if (flint_safe_mode && subtree_has_new(seg))
      error_at(s0->loc, "安全模式（-safe）：print 段内 new 会泄漏（先由 own/share 接管再打印）");
    Node *call = print_seg_call(p, s0, seg);
    cur = cur->next = new_node(ND_EXPR_STMT, call, NULL);
    if (!consume(p, ',')) {
      if (!is_punct(p->tok, ']'))
        error_at(p->tok->loc, "print 段之间用 ',' 分隔，段列表以 ']' 结束");
      break;
    }
  }
  p->tok = p->tok->next;   // 吃 ]
  if (consume(p, ',')) {
    // 第二参 = 换行标志（0/1 常量；1 = 换行，endl 语义）
    Token *n0 = p->tok;
    Node *nl = assign(p);
    if (nl->kind != ND_NUM)
      error_at(n0->loc, "print 换行参数须为 0/1 常量（1 = 换行）；省略 = 不换行");
    if (nl->val != 0) {
      Node *nls = new_node(ND_STR, NULL, NULL);
      nls->str = strdup("\n");
      nls->str_len = 1;
      nls->loc = n0->loc;
      Node *c = new_node(ND_CALL, NULL, nls);
      c->func_index = find_func_by_name(p->prog, "_flint_out_str");
      if (c->func_index < 0)
        error_at(n0->loc, "内部错误：print 换行需要内置输出函数 _flint_out_str");
      c->nargs = 1;
      c->ty = TY_INT;
      c->loc = n0->loc;
      cur = cur->next = new_node(ND_EXPR_STMT, c, NULL);
    }
  }
  skip(p, ')');
  skip(p, ';');
  return block_of(head.next);
}

// 按名查结构体类型（Program.structs 线性扫），返回下标或 -1
static int find_struct(Program *prog, Token *tok) {
  for (int i = 0; i < prog->nstructs; i++) {
    StructDef *s = &prog->structs[i];
    if ((int)strlen(s->name) == tok->len && strncmp(s->name, tok->loc, tok->len) == 0)
      return i;
  }
  return -1;
}

// 顶层 struct 定义：struct 名 { int 字段; | int *指针字段; ... }（须先定义后使用）
// v0.9.2：字段真实 C 布局——int 4 字节/对齐 4、int * 指针/句柄字段 8 字节/对齐 8；
//   offset 按类型对齐累加（Win32 结构体如 WNDCLASS 非 8×8B 也能精确对位）
static void parse_structdef(Parser *p, Program *prog) {
  p->tok = p->tok->next;   // 吃 struct
  Token *name = p->tok;
  if (name->kind != TK_IDENT || is_keyword(name))
    error_at(name->loc, "struct 后需跟类型名");
  if (find_struct(prog, name) >= 0)
    error_at(name->loc, "结构体类型 '%.*s' 重复定义", name->len, name->loc);
  p->tok = p->tok->next;
  skip(p, '{');

  if (prog->nstructs == prog->structs_cap) {
    int cap = prog->structs_cap ? prog->structs_cap * 2 : 8;
    prog->structs = realloc(prog->structs, (size_t)cap * sizeof(StructDef));
    prog->structs_cap = cap;
  }
  StructDef *s = &prog->structs[prog->nstructs];
  memset(s, 0, sizeof(StructDef));
  s->name = malloc((size_t)name->len + 1);
  memcpy(s->name, name->loc, (size_t)name->len);
  s->name[name->len] = '\0';
  prog->nstructs++;

  int cur = 0;          // v0.9.2：当前布局字节（对齐累加游标）
  bool has_ptr = false; // 含 8 字节指针字段 → 结构体总对齐 8
  int max_align = 1;    // v1.0.5：最大对齐（char 1 / int 4 / ptr 8；全 char 结构体不再强行 4）
  while (!is_punct(p->tok, '}')) {
    if (p->tok->kind == TK_EOF) error_at(p->tok->loc, "结构体缺少右花括号 '}'");
    // v1.0.5：字段类型 = char（1 字节/对齐 1）｜ int（4 字节/对齐 4）｜ int *（8 字节/对齐 8）
    // v1.2.4：+ double（8 字节/对齐 8，与 int * 同布局槽；真实 C 布局）
    bool fi64 = is_ident(p->tok, "int_64");   // v1.7.0：8 字节 / 对齐 8（与 double、指针同族）
    bool fchar = !fi64 && is_ident(p->tok, "char");
    bool fdbl = !fi64 && is_ident(p->tok, "double");
    bool fint = !fi64 && is_ident(p->tok, "int");
    if (!fchar && !fdbl && !fi64 && !fint)
      error_at(p->tok->loc, "结构体字段类型支持 char / int / int_64 / double / int *（v1.7.0 起含 int_64）");
    p->tok = p->tok->next;
    // v1.3.2：函数指针字段（`int (*cb)(int);`）暂不做 —— 明确报错，别让 `(` 落到"期望字段名"那种含糊提示上
    if (is_punct(p->tok, '('))
      error_at(p->tok->loc, "结构体暂不支持函数指针字段（v1.3.2 边界）——"
                            "回调请存成局部函数指针变量，或把一个整数/地址字段 + 间接调用拆开写");
    bool fptr = consume(p, '*');   // int *p = 指针/句柄字段（8 字节）
    if (fptr && fchar)
      error_at(p->tok->loc, "char 指针字段暂不支持（v1.0.5：指针字段仍 int*/double*/结构体指针）");
    // v1.2.5：double* 字段开放 —— 字段本身仍是 8 字节地址（与 int* 同槽），差别在**指向类型**
    // （f->elem = TY_DOUBLE）→ `*s.p` 8 字节 SSE 读写、`s.p[i]` 下标按 8 字节缩放（见 postfix）
    Token *fn = p->tok;
    if (fn->kind != TK_IDENT || is_keyword(fn))
      error_at(fn->loc, "期望字段名");
    if (s->nfields >= 128)
      error_at(fn->loc, "结构体字段上限 128");
    for (int i = 0; i < s->nfields; i++)
      if ((int)strlen(s->fields[i].name) == fn->len && strncmp(s->fields[i].name, fn->loc, fn->len) == 0)
        error_at(fn->loc, "字段 '%.*s' 重复", fn->len, fn->loc);
    p->tok = p->tok->next;
    // v1.4.4：**固定长度数组字段** —— `int buf[8];` / `char buf[64];`（真实 Win32 结构太需要它了）
    //   元素宽按 FLINT 的语言语义（不是 C 的 sizeof）：int/double 元素 = 8 字节槽、char = 1 字节
    //   → `s.buf[i]` 与既有下标缩放（postfix 的 esize_bytes）完全一致，不引入第二套语义。
    int arr_len = 1;
    if (consume(p, '[')) {
      Token *cnt = p->tok;
      if (cnt->kind != TK_NUM || cnt->val <= 0)
        error_at(cnt->loc, "数组字段长度须为正整数常量");
      arr_len = (int)cnt->val;
      p->tok = p->tok->next;
      skip(p, ']');
    }
    StructField *f = &s->fields[s->nfields];
    f->name = malloc((size_t)fn->len + 1);
    memcpy(f->name, fn->loc, (size_t)fn->len);
    f->name[fn->len] = '\0';
    f->arr_len = arr_len;
    // v1.7.0：基类型归一（fchar/fdbl/fi64 之外 = int）——下面 ty/elem/align/fsz 四处都读它
    int fbase = fchar ? TY_CHAR : (fdbl ? TY_DOUBLE : (fi64 ? TY_INT64 : TY_INT));
    if (fptr) {
      f->ty = TY_PTR;
    } else if (arr_len > 1) {
      f->ty = TY_ARR;
    } else {
      f->ty = fbase;
    }
    f->elem = fptr ? (fdbl ? TY_DOUBLE : (fi64 ? TY_INT64 : TY_INT)) : fbase;
    int align = fptr ? 8 : (fchar ? 1 : (fdbl ? 8 : (fi64 ? 8 : 4)));
    int fsz = fptr ? 8 : (fchar ? 1 : (fdbl ? 8 : (fi64 ? 8 : 4)));
    if (arr_len > 1 && !fptr) fsz = arr_len * ty_arr_stride(f->elem);   // 数组：元素宽 × 个数（走单点表）
    if (fptr) has_ptr = true;
    if (align > max_align) max_align = align;
    f->offset = align_up(cur, align);   // 真实 C 布局：char 1B 对齐 1、int 4B 对齐 4、指针 8B 对齐 8
    cur = f->offset + fsz;
    s->nfields++;
    skip(p, ';');
  }
  skip(p, '}');
  s->size = align_up(cur, has_ptr ? 8 : max_align);   // 总大小按最大对齐取整（帧内槽数 = ceil(size/8)）
  if (s->nfields == 0) error_at(name->loc, "结构体不能为空");
}

// —— v0.6 后遍检查：void 函数调用只能作为表达式语句的根 ——
// 结果不能当值用：禁止出现在 return/条件/赋值右值/参数/运算里。
static void check_expr_void(Node *n) {
  if (!n) return;
  if (n->kind == ND_CALL || n->kind == ND_APICALL) {   // v0.8：API void 同规则
    if (n->is_void) {
      // v0.9.1：裸 error() 无行无列 → error_at（调用点 loc 在构建时记录，带行号/列号/上下文）
      if (n->loc) error_at(n->loc, "void 函数调用不能用于表达式或参数");
      error("void 函数调用不能用于表达式或参数");
    }
    for (Node *a = n->rhs; a; a = a->next) check_expr_void(a);
    return;
  }
  check_expr_void(n->lhs);
  check_expr_void(n->rhs);
  check_expr_void(n->els);   // v1.3.1：三元假分支（void 调用出现在三元里 → 报错）
}

static void check_stmt_void(Node *n) {
  if (!n) return;
  switch (n->kind) {
    case ND_EXPR_STMT:
      // 根允许 void 调用（当语句），但其参数里不允许
      if (n->lhs && (n->lhs->kind == ND_CALL || n->lhs->kind == ND_APICALL) && n->lhs->is_void) {
        for (Node *a = n->lhs->rhs; a; a = a->next) check_expr_void(a);
      } else {
        check_expr_void(n->lhs);
      }
      break;
    case ND_BLOCK:
      for (Node *s = n->rhs; s; s = s->next) check_stmt_void(s);
      break;
    case ND_RETURN:
      check_expr_void(n->lhs);
      break;
    case ND_IF:
      check_expr_void(n->lhs);   // cond
      check_stmt_void(n->rhs);   // then
      check_stmt_void(n->els);   // else
      break;
    case ND_WHILE:
      check_expr_void(n->lhs);   // cond
      check_stmt_void(n->rhs);   // body
      break;
    case ND_FOR:
      check_stmt_void(n->init);  // init 是语句（声明块或表达式语句）
      check_expr_void(n->cond);
      check_stmt_void(n->inc);   // inc 是表达式语句
      check_stmt_void(n->rhs);   // body
      break;
    case ND_SWITCH:              // v1.3.1：条件 + 各段语句（ND_CASE 只是标记，段内容是它的兄弟语句）
      check_expr_void(n->lhs);
      for (Node *s = n->rhs; s; s = s->next) check_stmt_void(s);
      break;
    default: break;
  }
}

// 第一遍：轻扫 token 流，收集所有函数名（模式 ("int"|"void") IDENT "("）
// —— v1.3.0 全局变量预扫描 ——
// 在 collect_funcs 之前跑：把每个顶层全局变量的 .data 偏移**一次算死**，
// 这样函数体解析时随时能建出带正确 doff 的 ND_VAR（含「函数在前、全局在后」的前向引用）。
//
// 为什么非得在这里定 doff：代码用 `[rip+disp32]` 寻址，disp = (DATA_RVA+doff) - (TEXT_RVA+指令尾)。
//   两个节的 RVA 是编译期常量，所以只要 doff 定下来，disp（是**差值**，不是绝对地址）就是可算死的常数
//   —— 不需要任何重定位表、不需要二次回填。代价是 doff 必须在生成代码之前全部确定。
//
// 初值只支持**编译期常量**（字面量 / 一元正负 / 字面量间的算术），C 的 `int g;` 全局 = 0 由
//   .data 全零保证（不写 init 字节）。复杂初值（含变量/函数调用/字符串）→ 明确报错，绝不静默清零。
static const uint8_t *parse_global_init(Token *t, int ty, int count, int esize,
                                        int *out_len) {
  uint8_t *bytes = calloc((size_t)(count > 0 ? count : 1) * 8, 1);
  int off = 0;
  bool braced = is_punct(t, '{');
  if (braced) t = t->next;                    // 吃掉 '{'
  // 大括号形式：逐元素（允许元素少于声明长度 → 余下留 0）
  // 非大括号形式：**只**解析一个值（标量 `int g = 5;`），解析完即止
  for (int i = 0; braced ? (i < count) : (i == 0); i++) {
    if (braced) {
      if (is_punct(t, '}')) break;            // 提前收尾：余下元素保持 0（C 语义）
      if (i > 0) {
        if (!is_punct(t, ',')) error_at(t->loc, "全局数组初值里期望 ','（在元素 %d 之后）", i);
        t = t->next;
        if (is_punct(t, '}')) break;          // 允许尾逗号
      }
    }
    bool neg = false;
    if (is_punct(t, '-')) { neg = true; t = t->next; }
    else if (is_punct(t, '+')) t = t->next;
    bool isdbl = t->kind == TK_DBL;
    // v1.7.0：TK_NUM64 也是字面量（64 位初值进 int_64 全局；进 int/char 在下面硬错）
    if (t->kind != TK_NUM && t->kind != TK_DBL && t->kind != TK_NUM64)
      error_at(t->loc, "全局变量初值必须是编译期常量（只支持一个字面量，可带正负号）"
                       "——全局变量在程序启动前就写进 .data，不能依赖运行时才有的值");
    if (isdbl && ty != TY_DOUBLE)
      error_at(t->loc, "double 字面量不能作为 int/char/int_64 全局变量的初值"
                       "（会静默截断小数）——请把全局变量声明成 double");
    if (!isdbl && ty == TY_DOUBLE)
      error_at(t->loc, "double 全局变量的初值必须是浮点字面量（如 1.5，而不是 1）"
                       "——写成整数会被当成整数位型读成 5e-324");
    // v1.7.0：64 位字面量只能进 int_64 全局（进 int/char = 静默截断高 32 位 ⇒ 硬错）
    if (!isdbl && t->kind == TK_NUM64 && ty != TY_INT64)
      error_at(t->loc, "这个全局变量是 %s，初值却是 64 位字面量（会静默截断高 32 位："
                       "值超出 int 范围的部分丢掉）——请把全局变量声明成 int_64", ty_name(ty));
    if (isdbl) {
      double d = t->dval;
      if (neg) d = -d;
      memcpy(bytes + off, &d, 8);
    } else {
      long long v = (t->kind == TK_NUM64) ? t->lval : (long long)t->val;
      if (neg) v = -v;
      if (ty == TY_CHAR) {
        if (v < -128 || v > 255)
          error_at(t->loc, "char 全局变量初值 %lld 超出 0..255（char = 无符号字节）", v);
        bytes[off] = (uint8_t)v;
      } else if (ty == TY_INT64) {
        memcpy(bytes + off, &v, 8);   // v1.7.0：8 字节整体写（.data 里 int_64 标量/元素都是 8）
      } else {
        int iv = (int)v;
        memcpy(bytes + off, &iv, 4);
      }
    }
    off += esize;   // 元素步进 = 与布局/寻址同一口径（int = 8 字节槽）
    t = t->next;
  }
  if (braced) {
    if (!is_punct(t, '}'))
      error_at(t->loc, "全局数组初值元素比声明长度多（声明 %d 个）", count);
    t = t->next;
  } else {
    // —— v1.4.28（B1-5）：非大括号初值只吃**一个字面量**，尾巴上不许再留 token ——
    // 旧行为（v1.3.0 起）：这里什么都不查，调用方 `collect_globals` 一路 **静默跳到 ','/';'**，
    //   于是 `int g = 0 - 1;` **编译 exit 0 而 g == 0**（`- 1` 被吞）、`int g = 5 * 3;` ⇒ g == 5、
    //   `int g = 7 9 ;` ⇒ g == 7；最坏的是 `int g = 1 + x;` —— **x 是变量也照收**、g == 1，
    //   连"初值必须是编译期常量"这道既有判据都被绕过（run-tests 的 ng_nonconst 只钉了 `= x` 那一种写法）。
    // 现在：多出来的 token = **默认档硬错**，位置就指在那个多出来的 token 上（不指别处）。
    //   ⇒ 真 flint 与 boot 同结论（boot 侧 = 专码 -213）。⚠️ 这条不是"收窄真能力"：改前它给的是**错值**。
    if (!is_punct(t, ',') && !is_punct(t, ';'))
      error_at(t->loc, "全局变量初值只支持一个字面量（可带正负号）——"
                       "这里多出来的 token 会被丢弃、初值就是错的（表达式不会被求值）；"
                       "要算表达式请挪进 main 里赋值（全局只写 int g; 再在 main 里 g = 0 - 1;）");
  }
  *out_len = off;
  return bytes;
}

// v1.3.0：从「类型词之后」扫过一个声明符，**停在分隔符上**（',' ｜ '=' ｜ ';'）。
//   collect_globals 与顶层跳过逻辑共用同一套扫描（写两遍必有一遍先腐坏——
//   「预扫描只补一个字段」家族的同族教训）。
static Token *scan_declarator(Token *t) {
  while (is_punct(t, '*')) t = t->next;              // 修饰符
  if (t->kind == TK_IDENT && !is_keyword(t)) t = t->next;   // 名字
  if (is_punct(t, '[')) {                            // 数组后缀：跳到 ']'
    while (t->kind != TK_EOF && !is_punct(t, ']')) t = t->next;
    if (t->kind != TK_EOF) t = t->next;
  }
  return t;
}

static void collect_globals(Token *tok, Program *prog) {
  prog->globals = NULL;
  prog->nglobals = 0;
  prog->globals_cap = 0;
  prog->data_size = 0;
  int cur = 0;   // .data 内当前偏移（相对节首，不含 DATA_RVA）
  // ⚠️⚠️ 「只认顶层」的两道守卫 —— 这里踩过两轮真坑，是本函数最容易写错的地方：
  //   ① 花括号深度：函数体内的 `int g = 99;` 会被当成全局声明（报"重复声明"），
  //      函数内语句（`int x = g++;` 里的 `g++`）会被当成全局初值去解析。
  //   ② **圆括号 + struct 定义**（第二轮踩到）：只守花括号不够 ——
  //      `void set(int *p, int v) {` 的**形参**会被当全局声明（"暂不支持指针类型的全局变量"），
  //      `struct Point { int x; int y; }` 的**字段**会被当 struct 全局（"暂不支持 struct 全局变量"）
  //      → 直接打挂全部带指针形参/结构体的既有样本（70 项回归红）。
  //   判据：预扫描与正式解析必须用**同一套"什么算顶层"的判据**（后者靠 parse() 的
  //   「struct + {」与「名字 + (」两条识别躲开），漏一条就是"看起来能用、换样本就炸"。
  int depth = 0;       // 花括号深度
  int pdepth = 0;      // 圆括号深度（形参表）
  for (Token *t = tok; t->kind != TK_EOF; t = t->next) {
    if (pdepth > 0) {                       // 形参表内：全部跳过（先判后改，)` 也要吃掉）
      if (is_punct(t, '(')) pdepth++;
      else if (is_punct(t, ')')) pdepth--;
      continue;
    }
    if (is_punct(t, '(')) { pdepth++; continue; }   // 进入形参表（函数定义）
    if (is_punct(t, '{')) { depth++; continue; }
    if (is_punct(t, '}')) { depth--; continue; }
    if (depth != 0) continue;   // 函数体内：全局变量与这里无关
    // struct **定义**（struct 名 { ... }）整体跳过 —— 别把字段当全局变量
    if (is_ident(t, "struct")) {
      Token *sn = t->next;
      Token *br = (sn && sn->kind == TK_IDENT && !is_keyword(sn)) ? sn->next : NULL;
      if (br && is_punct(br, '{')) {
        while (t->kind != TK_EOF && !is_punct(t, '}')) t = t->next;
        continue;                            // 外层 for 的 t++ 跳过 '}'
      }
    }
    // api 声明行整体跳过
    if (is_ident(t, "api")) {
      while (t->kind != TK_EOF && !is_punct(t, ';')) t = t->next;
      continue;
    }
    // 类型词
    int base_ty;
    bool is_struct_ty = false;
    if (is_ident(t, "int_64")) { base_ty = TY_INT64; t = t->next; }   // v1.7.0（须在 "int" 之前判，整词比较）
    else if (is_ident(t, "int")) { base_ty = TY_INT; t = t->next; }
    else if (is_ident(t, "double")) { base_ty = TY_DOUBLE; t = t->next; }
    else if (is_ident(t, "char")) { base_ty = TY_CHAR; t = t->next; }
    else if (is_ident(t, "struct")) {
      // struct S name; → 跳过结构体名（第一版只支持标量/数组全局，struct 全局走下面报错）
      Token *sn = t->next;
      if (!sn || sn->kind != TK_IDENT || is_keyword(sn)) continue;
      is_struct_ty = true;
      base_ty = TY_INT;      // 占位值：真正的报错在下面「暂不支持 struct 全局变量」
      t = sn;
      t = t->next;
    }
    else continue;

    // v1.3.2：全局函数指针（`int (*fp)(int);`）—— 明确报错（别落到"期望变量名"那种含糊提示）
    if (is_punct(t, '(') || (is_punct(t, '*') && is_punct(t->next, '(')))
      error_at(t->loc, "暂不支持全局函数指针（v1.3.2 边界：只开局部函数指针变量）——"
                       "请在函数里声明 int (*fp)(int)，或用函数名直接调用");

    // v1.3.0：支持逗号声明表（`int a = 1, b[4], c;`）——与函数内 `int a = 1, b = 2;` 语义对齐。
    //   第一版只认「一个名字」：全局写 `int a = 1, b;` 时 a 被登记、b 被静默丢掉，
    //   之后引用 b 报出**误导性的**「使用了未声明的变量 'b'」（真因是「不支持」而非「没声明」）
    //   —— 语义不对称本身就是 bug，这里补齐。
    for (;;) {
      // 修饰符（每个声明符可各自带 '*'）
      bool is_ptr = false;
      while (is_punct(t, '*')) { is_ptr = true; t = t->next; }

      // 变量名
      if (t->kind != TK_IDENT || is_keyword(t)) break;
      Token *name = t;
      Token *after = name->next;

      // 数组后缀
      int arr_len = -1;
      if (after && is_punct(after, '[')) {
        Token *sz = after->next;
        if (!sz || sz->kind != TK_NUM)
          error_at(name->loc, "全局数组长度必须是正整数常量（全局数组在 .data 里，长度编译期就得定）");
        arr_len = sz->val;
        if (arr_len <= 0) error_at(sz->loc, "全局数组长度必须为正（得到 %d）", arr_len);
        Token *rb = sz->next;
        if (!rb || !is_punct(rb, ']')) error_at(sz->loc, "全局数组声明期望 ']'");
        after = rb->next;
      }

      // 函数定义 = 名字后跟 '('：交给 collect_funcs
      if (after && is_punct(after, '(')) break;

      // 到这里才算「全局变量声明」——必须紧跟 ';' 或 '=' 或 ','
      if (!(after && (is_punct(after, ';') || is_punct(after, '=') || is_punct(after, ','))))
        break;   // 不是我们认识的形态，交给后续顶层检查报错

      // 重名检测（同名函数也报错——避免「调用 g() 还是读 g」的歧义）
      if (find_global(prog, name) >= 0)
        error_at(name->loc, "全局变量 '%.*s' 重复声明", name->len, name->loc);
      for (int i = 0; i < prog->nfuncs; i++)
        if ((int)strlen(prog->funcs[i].name) == name->len
            && strncmp(prog->funcs[i].name, name->loc, name->len) == 0)
          error_at(name->loc, "全局变量 '%.*s' 与同名函数冲突（读变量和调函数会分不清）",
                   name->len, name->loc);

      if (is_struct_ty)
        error_at(name->loc, "暂不支持 struct 全局变量（第一版只开 int / int_64 / char / double 标量与数组）"
                            "——请用 struct 指针全局变量，或在函数里声明局部 struct");
      if (is_ptr)
        error_at(name->loc, "暂不支持指针类型的全局变量（int* / char* / double* 全局）"
                            "——第一版只开 int / char / double 标量与数组");

      int elem_ty = base_ty;
      int ty = (arr_len > 0) ? TY_ARR : base_ty;
      int count = (arr_len > 0) ? arr_len : 1;

      // 元素对齐/尺寸 —— 必须与 **postfix 的下标缩放口径**（a[i] = *(a+i*esize)）严格一致！
      //   🐞 实测踩过真坑：这里原按 C 的 sizeof 摆（int=4），而下标缩放是语言口径（int 元素 8 字节槽）
      //   → `garr[2]` 算到 base+16 = **下一个全局变量的槽**上，静默写坏别处（"编译过、静默错值"）。
      //   判据：凡「布局尺寸」与「寻址步长」分处两个文件时，两处的元素宽必须写进同一张口径表。
      int esize = (base_ty == TY_INT64) ? ty_arr_stride(TY_INT64)   // v1.7.0：标量/数组元素都是 8（值宽 = 步长）
                : (base_ty == TY_CHAR) ? 1
                : (base_ty == TY_DOUBLE) ? 8
                : (arr_len > 0) ? ty_arr_stride(base_ty) : 8;   // v1.6.5：int 数组元素 4 字节；全局 int 标量仍 8（读写 64 位约定）
      int align = (esize > 8) ? 8 : esize;

      long long total = (long long)esize * count;
      if (total > (long long)FLINT_MAX_TEXT)
        error_at(name->loc, "全局变量过大（%lld 字节）——.data 单节上限 %d 字节",
                 total, FLINT_MAX_TEXT);

      // 登记
      if (prog->nglobals == prog->globals_cap) {
        prog->globals_cap = prog->globals_cap ? prog->globals_cap * 2 : 8;
        prog->globals = realloc(prog->globals,
                                (size_t)prog->globals_cap * sizeof(GlobalVar));
        if (!prog->globals) error("内存不足（全局变量表）");
      }
      GlobalVar *g = &prog->globals[prog->nglobals];
      memset(g, 0, sizeof(GlobalVar));
      g->name = malloc((size_t)name->len + 1);
      memcpy(g->name, name->loc, (size_t)name->len);
      g->name[name->len] = '\0';
      g->len = name->len;
      g->ty = ty;
      g->elem_ty = elem_ty;
      g->arr_len = count;
      g->size = (int)total;
      g->doff = align_up(cur, align);
      g->init_len = 0;
      cur = g->doff + g->size;
      if (cur > FLINT_MAX_TEXT)
        error_at(name->loc, "全局变量总量超出 .data 单节上限（%d 字节）——第一版不开放多节 .data",
                 FLINT_MAX_TEXT);

      // 初值（只支持编译期常量；见 parse_global_init）
      if (is_punct(after, '=')) {
        Token *vt = after->next;
        int ilen = 0;
        const uint8_t *bytes = parse_global_init(vt, base_ty, count, esize, &ilen);
        if (ilen > (int)sizeof(g->init))
          error_at(name->loc, "全局变量初值过长（%d 字节，上限 %d）", ilen, (int)sizeof(g->init));
        memcpy(g->init, bytes, (size_t)ilen);
        g->init_len = ilen;
        free((void *)bytes);
        // 跳过初值（含 '}' 与元素逗号）→ 停在 ',' 或 ';'
        while (after->kind != TK_EOF && !is_punct(after, ',') && !is_punct(after, ';'))
          after = after->next;
      }
      prog->nglobals++;

      // 声明符之间以 ',' 分隔；';' 结束整条声明（外层 for 的 t++ 跳过 ';'）
      if (is_punct(after, ',')) { t = after->next; continue; }
      t = after;   // after 是 ';'
      break;
    }
  }

  // 节大小按页取整（保证 .data 的 RVA 恒为 DATA_RVA，与 data_size 无关）
  prog->data_size = cur > 0 ? ((cur + 0xFFF) / 0x1000) * 0x1000 : 0;
}

// 骨架先登记（名字/is_main），body/参数等第二遍正式解析时填充；
// 这样函数调用可以出现在定义之前（前向调用）。
static void collect_funcs(Token *tok, Program *prog) {  int n = 0, cap = 8;
  prog->funcs = calloc((size_t)cap, sizeof(FuncDef));
  prog->main_index = -1;

  for (Token *t = tok; t->kind != TK_EOF; t = t->next) {
    // v0.8：api 声明行整体跳过（别把 "int 名(" 误当函数定义收集）
    if (is_ident(t, "api")) {
      while (t->kind != TK_EOF && !is_punct(t, ';')) t = t->next;
      continue;
    }
    // v1.0.6：返回类型可 = int|char|void | struct 名（指针返回 = 后跟 '*'）；找函数名跳过类型词
    bool is_ret = is_ident(t, "int") || is_ident(t, "char") || is_ident(t, "void")
               || is_ident(t, "struct") || is_ident(t, "double")
               || is_ident(t, "int_64");   // v1.7.0：int_64 值返回
    if (!is_ret) continue;
    Token *name = t->next;
    // v1.2.1：预扫描就把**返回类型**记进函数表 —— 否则「先调用、后定义」的 double 返回函数
    //   在调用点解析时 fn->ret_ty 还是默认 0（int）→ 解析期的类型判定（expr_is_dbl / to_int 提升 /
    //   mkbin 自动提升）全部当它是 int，生成 `cvtsi2sd eax` 静默读错值（实测：to_int(half()) 得 0）。
    //   这里只读 token 判类型（真正的签名检查仍在 parse_funcdef，两处口径由本注释对齐）。
    bool ret_is_ptr = false;
    int pre_ret_ty = TY_INT;
    if (is_ident(t, "void")) pre_ret_ty = TY_INT;                 // void 由 parse_funcdef 置 ret_void
    else if (is_ident(t, "char")) pre_ret_ty = TY_CHAR;
    else if (is_ident(t, "double")) pre_ret_ty = TY_DOUBLE;
    else if (is_ident(t, "int_64")) pre_ret_ty = TY_INT64;   // v1.7.0
    else if (is_ident(t, "struct")) {
      if (!name || name->kind != TK_IDENT || is_keyword(name)) continue;  // struct 类型名
      name = name->next;
    }
    if (name && is_punct(name, '*')) { name = name->next; ret_is_ptr = true; }  // int*/char*/struct S*
    if (!name || name->kind != TK_IDENT) continue;
    Token *lp = name->next;
    if (!lp || !is_punct(lp, '(')) continue;

    // 重名检测
    for (int i = 0; i < n; i++) {
      FuncDef *f = &prog->funcs[i];
      if ((int)strlen(f->name) == name->len && strncmp(f->name, name->loc, name->len) == 0)
        error_at(name->loc, "函数 '%.*s' 重复定义", name->len, name->loc);
    }
    if (n == cap) {
      cap *= 2;
      prog->funcs = realloc(prog->funcs, (size_t)cap * sizeof(FuncDef));
    }
    FuncDef *f = &prog->funcs[n];
    memset(f, 0, sizeof(FuncDef));
    f->name = malloc((size_t)name->len + 1);
    memcpy(f->name, name->loc, (size_t)name->len);
    f->name[name->len] = '\0';
    f->is_main = is_ident(name, "main");
    // v1.2.1：返回类型提前落表（parse_funcdef 会再正式算一遍并覆盖，这里只为「调用点在定义之前」兜底）
    f->ret_ty = ret_is_ptr ? TY_PTR : pre_ret_ty;
    // v1.2.5：指针返回的**指向类型**同样要提前落表（理由与返回类型一致）——否则「先调用、后定义」的
    //   `*f()` / `f()[i]` 在调用点按 int 语义走：double* 会被当 int* 读 4 字节（静默错值）。
    f->ret_elem = ret_is_ptr ? pre_ret_ty : TY_INT;
    f->ret_struct = -1;
    // v1.2.2 double 阶段2 第二步：预扫描**同时记形参类型**（这里只关心 double 与否）——理由同返回类型：
    //   「先调用、后定义」的 double 形参函数，调用点解析时 param_ty 还是 0（= TY_INT）→ int 实参不提升、
    //   double 实参被当 int 收 → 实参走 rax 通道而值在 xmm0 ＝ 静默传垃圾。只做「类型词+修饰符+名字」浅扫描；
    //   真正的签名检查仍在 parse_funcdef（两处口径由本注释对齐，与 v1.2.1 返回类型同款做法）。
    {
      Token *pt = lp->next;
      int pi = 0;
      for (int z = 0; z < FUNC_MAX_ARGS; z++) f->param_sig[z] = FN_SIG_NONE;   // 0 是合法签名下标，别靠 memset 的 0
      while (pt && pt->kind != TK_EOF && !is_punct(pt, ')') && pi < FUNC_MAX_ARGS) {
        // v1.3.2：形参本身是函数指针（`int (*cb)(int)`）——预扫描必须**整体吃掉并落两个字段**：
        //   param_ty = TY_FUNCPTR（调用点据此判「传地址」、装载侧据此走 64 位 GP）
        //   + param_sig（调用点比签名）。只落一个 = 「预扫描只补一个字段」家族第 5 次，故写在一起。
        {
          Token *q = pt;
          int pr_ty = TY_INT, pr_elem = TY_INT;
          bool pr_void = false, fp = false;
          if (is_ident(q, "void") && is_punct(q->next, '(')) { pr_void = true; fp = true; q = q->next; }
          else if (is_ident(q, "int") || is_ident(q, "char") || is_ident(q, "double")) {
            if (is_ident(q, "char")) { pr_ty = TY_CHAR; pr_elem = TY_CHAR; }
            else if (is_ident(q, "double")) { pr_ty = TY_DOUBLE; pr_elem = TY_DOUBLE; }
            q = q->next;
            if (is_punct(q, '*') && is_punct(q->next, '(')) { pr_ty = TY_PTR; q = q->next; }
            if (is_punct(q, '(')) fp = true;
          }
          if (fp) {
            FuncSig ps;
            Token *pn = NULL;
            pt = parse_funcptr_decl(&ps, q, pr_ty, pr_elem, -1, pr_void, &pn);
            f->param_ty[pi] = TY_FUNCPTR;
            f->param_ref[pi] = false;
            f->param_sig[pi] = add_sig_prog(prog, ps);
            pi++;
            if (pt && is_punct(pt, ',')) { pt = pt->next; continue; }
            break;
          }
        }
        bool pdbl = false;
        bool pi64p = false;   // v1.7.0：int_64 值形参（预扫描也要认，否则前向调用把它当 int 判）
        if (is_ident(pt, "double")) { pdbl = true; pt = pt->next; }
        else if (is_ident(pt, "int_64")) { pi64p = true; pt = pt->next; }
        else if (is_ident(pt, "struct")) { pt = pt->next; if (pt) pt = pt->next; }   // 跳过 struct 类型名
        else if (is_ident(pt, "int") || is_ident(pt, "char")) pt = pt->next;
        // v1.2.5：修饰符要扫出「有没有 * / &」——`double *p` / `double &r` 传的都是**地址**（GP），
        //   不是 XMM 里的浮点值。老坑同族（「预扫描只补了一个字段」）：只看类型词不看修饰符，
        //   前向调用就会把地址按 double 塞进 xmm0（被调方按 GP 读）＝ 静默传垃圾。
        bool pdir = false;
        bool pref = false;   // v1.2.5：`&` 引用形参 → 调用点传**地址**（值语义检查要跳过）
        while (pt && (is_punct(pt, '&') || is_punct(pt, '*'))) {
          if (is_punct(pt, '*')) pdir = true;
          if (is_punct(pt, '&')) pref = true;
          pt = pt->next;
        }
        if (pt && pt->kind == TK_IDENT) pt = pt->next;                               // 参数名
        // ===== v1.6.1（2026-10-15）：预扫描的「指针形参」也要记 TY_PTR =====
        //   旧写法 `(pdbl && !pdir) ? TY_DOUBLE : TY_INT` 把**所有**指针形参记成 TY_INT，
        //   只有 double 那一路分了对错。于是**前向**调用（被调函数定义在调用点之后）看到的
        //   是"值形参"：方法糖 method_call 要求首参 param_ty[0]==TY_PTR，便误报
        //   「首参不是接收者指针/引用（收的是值形参）」—— 实测 `a.f(10)` 且 `A_f` 定义在
        //   main 之后：**真 flint 编译失败、boot 正常编出 11**（双端分岔，flint 错）。
        //   口径与定义处对齐（parse_funcdef：`if (ptr) ty = TY_PTR;`）：只按"有没有 `*`"分派。
        //   影响面只有两处读 param_ty 的诊断/装载路径（call_arg_norm 的 double 通道、
        //   sig_of_func 的签名比较），**不产生机器码差异**（非 double 实参的规范化结果不变）。
        f->param_ty[pi] = (pdbl && !pdir) ? TY_DOUBLE
                        : (pi64p && !pdir) ? TY_INT64
                        : (pdir ? TY_PTR : TY_INT);
        // v1.2.5：**引用标志也要提前落表** —— 调用点靠它判断「这个形参收的是地址还是值」
        //   （只看 param_ty 不够：double& 的 param_ty 记 TY_INT/TY_PTR 都不是「值」）。
        f->param_ref[pi] = pref;
        pi++;
        if (pt && is_punct(pt, ',')) { pt = pt->next; continue; }
        break;
      }
      // ⚠️ 形参**个数**也要提前落表：调用点的「形参是 double 吗 / 个数对得上吗」两处判定都要用它，
      //   而 fn->nargs 原本只在 parse_funcdef（= 定义处）才填 → 前向调用时恒为 0（实测踩到：
      //   `int main(){ return to_int(half(5)); } double half(double x){...}` 编译通过但形参收到垃圾，
      //   静默返回 0）。parse_funcdef 里已配套 `fn->nargs = 0` 重新正式登记。
      f->nargs = pi;
    }
    if (f->is_main) {
      if (prog->main_index >= 0)
        error_at(name->loc, "main 函数重复定义");
      prog->main_index = n;
    }
    n++;
  }
  prog->nfuncs = n;
}

// —— v0.8 API 声明收集（须在文件最顶部、任何 struct/函数之前）——
// 语法：api <模块短名> <int|void|ptr|double> <函数名> ( int, ... );
// 参数类型统一写 int 占位（数量决定 Win64 参数寄存器个数；类型无关——
// 值参数 mov eax 零扩展 64、地址参数 lea rax 全 64，都正确落入 API 寄存器）
// v1.4.8：模块名支持**字符串字面量**形式 `api "cabridge.dll" ...` / `api "E:\x\y.dll" ...`
//   （多语言交火·编译期缝合需要）——标识符词法不吃 '.'，故带点全名/带路径只能走字面量；
//   pe.c 侧规则：模块名含 '.' 或 '\' 就**原样用**，否则补 ".dll"（裸短名行为不变）。
static void collect_apis(Token *tok, Program *prog) {
  prog->apis = NULL; prog->napis = 0; prog->apis_cap = 0;
  while (tok->kind != TK_EOF && is_ident(tok, "api")) {
    Token *decl_start = tok;
    tok = tok->next;
    char *dll = NULL;
    if (tok->kind == TK_IDENT) {
      dll = malloc((size_t)tok->len + 1);
      memcpy(dll, tok->loc, (size_t)tok->len);
      dll[tok->len] = '\0';
    } else if (tok->kind == TK_STR) {
      dll = malloc((size_t)tok->slen + 1);
      memcpy(dll, tok->sval, (size_t)tok->slen);
      dll[tok->slen] = '\0';
      if (dll[0] == '\0')
        error_at(tok->loc, "api 的模块名字符串不能为空");
    } else {
      error_at(tok->loc, "api 后需跟模块名（裸短名如 user32，或字符串字面量如 \"cabridge.dll\"）");
    }
    // —— v1.4.28（B1-3）：导入模块名（写出名）长度硬上限，**默认档**就报 ——
    // 真因：写出端（pe.c）的 ImpGroup.dll 是 char[64]，名字超过 IMPORT_DLL_NAME_MAX 字节会被
    //   snprintf **静默截断** ⇒ 导入表里是"半个路径"（编译期零提示、进程启动期才炸 0xC0000135）。
    //   判据与写出端同一份（pe_import_module_name_len）：含 '.' / '\' / '/' 原样写（不补后缀），
    //   否则补 ".dll" —— **裸短名那 4 个字节也算在内**。
    {
      int modlen = pe_import_module_name_len(dll);
      if (modlen > IMPORT_DLL_NAME_MAX)
        error_at(tok->loc,
                 "导入模块名过长：写出名最长 63 字节，现在 %d 字节（%s）——"
                 "名字会被截断成半个路径、进程启动期才报错，请缩短模块名",
                 modlen,
                 (strchr(dll, '.') || strchr(dll, '\\') || strchr(dll, '/'))
                   ? "含 '.' / '/' / '\\' 故原样写，不补后缀"
                   : "裸短名会自动补 \".dll\" 后缀，含后缀一起算");
    }
    tok = tok->next;

    bool ret_void = false;
    int ret_ty = TY_INT;   // v0.9.2：ptr = 64 位句柄/指针返回（HWND/HMODULE 等，直入 struct 指针字段/64 位比较）
    bool param_dbl[API_MAX_ARGS];    // v1.1.0：double 参数 → 走 XMM0-3（printf 打印浮点必须的通道）
    memset(param_dbl, 0, sizeof(param_dbl));
    if (is_ident(tok, "void")) ret_void = true;
    else if (is_ident(tok, "ptr")) ret_ty = TY_PTR;
    else if (is_ident(tok, "double")) { ret_ty = TY_DOUBLE; ret_void = false; }   // v1.1.0：浮点返回（XMM0）
    else if (!is_ident(tok, "int"))
      error_at(tok->loc, "api 返回类型须为 int / void / ptr / double（int_64 暂不支持：v1.7.0 P0 边界，"
                          "64 位返回值请用 ptr 承接）");
    tok = tok->next;

    if (tok->kind != TK_IDENT)
      error_at(tok->loc, "api 声明期望函数名");
    char *name = malloc((size_t)tok->len + 1);
    memcpy(name, tok->loc, (size_t)tok->len);
    name[tok->len] = '\0';
    tok = tok->next;

    // 与本地函数重名（API 名全局唯一）
    for (int i = 0; i < prog->nfuncs; i++)
      if (strcmp(prog->funcs[i].name, name) == 0)
        error_at(tok->loc, "API '%.*s' 与本地函数重名", (int)strlen(name), name);
    // （API 同名检查移到参数解析后：v1.0.8 起同名同签名 = 幂等忽略，见登记前）

    if (!is_punct(tok, '(')) error_at(tok->loc, "api 声明期望 '('");
    tok = tok->next;
    int nargs = 0;
    if (!is_punct(tok, ')')) {
      for (;;) {
        if (nargs >= API_MAX_ARGS)
          error_at(tok->loc, "API 参数最多 %d 个（4 寄存器 + %d 栈参，v1.4.0 由 12 提到 16：CreateFontA 14 参）",
                   API_MAX_ARGS, API_MAX_ARGS - 4);
        if (is_ident(tok, "double")) param_dbl[nargs] = true;      // v1.1.0：浮点实参 → XMM
        else if (!is_ident(tok, "int"))
          error_at(tok->loc, "api 参数类型只能是 int 或 double（v1.1.0 起 double = XMM 通道；"
                              "int_64 实参暂不支持：v1.7.0 P0 边界，请先 to_int32(...)）");
        tok = tok->next;
        nargs++;
        if (!is_punct(tok, ',')) break;
        tok = tok->next;
      }
    }
    if (!is_punct(tok, ')')) error_at(tok->loc, "api 声明期望 ')'");
    tok = tok->next;
    // v1.1.0：真实导出名重绑定 `as "真名"`——FLINT 侧可换名/按签名分绑定，
    // 导入表仍写 DLL 里真实存在的符号（否则 LoadLibrary 期即 STATUS_ENTRYPOINT_NOT_FOUND）
    char *import_name = NULL;
    if (is_ident(tok, "as")) {
      tok = tok->next;
      if (tok->kind != TK_STR) error_at(tok->loc, "as 后需跟 DLL 里的真实函数名字符串（as \"_printf\"）");
      import_name = malloc((size_t)tok->slen + 1);
      memcpy(import_name, tok->sval, (size_t)tok->slen);
      import_name[tok->slen] = '\0';
      tok = tok->next;
    }
    if (!is_punct(tok, ';')) error_at(tok->loc, "api 声明期望 ';'");
    tok = tok->next;

    // v1.0.8：同名同签名 = 幂等忽略（多文件库各自带 api 声明、print 内置库注入会重复声明
    // GetStdHandle/WriteFile）；同名不同签名 = 冲突报错（防静默调错）
    bool api_dup_ok = false;
    for (int i = 0; i < prog->napis; i++)
      if (strcmp(prog->apis[i].name, name) == 0) {
        ApiDef *ex = &prog->apis[i];
        if (ex->nargs == nargs && ex->ret_void == ret_void && ex->ret_ty == ret_ty) {
          api_dup_ok = true;   // 幂等忽略
          break;
        }
        error_at(tok->loc, "API '%.*s' 重复声明但签名不一致（已声明 %d 参 %s）",
                 (int)strlen(name), name, ex->nargs, ex->dll);
      }
    if (api_dup_ok) continue;   // 跳过登记（本行已消费到 ';'）

    if (prog->napis == prog->apis_cap) {
      int cap = prog->apis_cap ? prog->apis_cap * 2 : 8;
      prog->apis = realloc(prog->apis, (size_t)cap * sizeof(ApiDef));
      prog->apis_cap = cap;
    }
    ApiDef *a = &prog->apis[prog->napis++];
    memset(a, 0, sizeof(ApiDef));
    a->dll = dll;
    a->name = name;
    a->nargs = nargs;
    a->ret_void = ret_void;
    a->ret_ty = ret_ty;   // v0.9.2
    a->import_name = import_name;   // v1.1.0：NULL = 与 name 相同
    for (int i = 0; i < nargs && i < API_MAX_ARGS; i++) a->param_dbl[i] = param_dbl[i];   // v1.1.0
    (void)decl_start;
  }
}

// 按名查 API（Program.apis 线性扫），返回下标或 -1
static int find_api(Program *prog, Token *tok) {
  for (int i = 0; i < prog->napis; i++) {
    ApiDef *a = &prog->apis[i];
    if ((int)strlen(a->name) == tok->len && strncmp(a->name, tok->loc, tok->len) == 0)
      return i;
  }
  return -1;
}

// v0.9：登记内置 API（同名已存在则复用），返回 apis 下标
static int ensure_api(Program *prog, const char *dll, const char *name, int nargs, bool ret_void) {
  for (int i = 0; i < prog->napis; i++)
    if (strcmp(prog->apis[i].name, name) == 0)
      return i;
  if (prog->napis == prog->apis_cap) {
    int cap = prog->apis_cap ? prog->apis_cap * 2 : 8;
    prog->apis = realloc(prog->apis, (size_t)cap * sizeof(ApiDef));
    prog->apis_cap = cap;
  }
  ApiDef *a = &prog->apis[prog->napis++];
  memset(a, 0, sizeof(ApiDef));
  a->dll = strdup(dll);
  a->name = strdup(name);
  a->nargs = nargs;
  a->ret_void = ret_void;
  return prog->napis - 1;
}

// 第二遍：正式解析一个函数定义（p->tok 指向 'int'/'void'；骨架 prog->funcs[fi] 已登记）
// ===== v1.4.25（`-strict`）②：读一个从没赋过值的局部量 =====
// 为什么值得拦：FLINT 的局部量住在栈槽里，`int x;` 之后读 x 读到的是**栈上的残留字节**
//   （上次调用/上一轮循环留下的东西）——不报错、行为随栈布局漂移，是最难查的一类 bug。
// 口径（**宁可漏报，绝不误报** —— 严格档一次误报就会让人不再用它）：
//   · 只查**标量**局部量（int/char/double/指针/函数指针）；数组/结构体跳过（部分写没法追）
//   · 「可能被写过」是**单调标记**：赋值、复合赋值、++/--、取址(&x)、引用绑定都算写过；
//     一旦标上，后续读一律放行 ⇒ 只会报"从声明到这一点一路都没写过"的那种（真错）
//   · 形参 = 已初始化（调用方装好）；全局变量不查（.data 天生有初值）
//   · 文本序单遍：循环体"先读后写"会报（第一轮就是未初始化读——真 bug）；"先写后读"不报；
//     循环**外面**读循环里写过的变量不报（这是漏报，接受）
static void strict_read(Parser *p, Node *n) {
  if (!flint_strict || !n || n->kind != ND_VAR) return;
  if (n->is_global || n->is_ref) return;
  LVar *v = lv_by_offset(p->all_lvars, n->offset);
  if (!v) return;                                       // 不是局部量（暂存槽/解引用目标等）
  if (v->ty == TY_ARR || v->ty == TY_STRUCT) return;    // 只查标量
  if (v->may_inited) return;
  if (n->loc)
    error_at(n->loc, "[E-STRICT-UNINIT] 局部量 '%s' 在这里被读取，但从声明到现在从没赋过值"
                     "（读到的是栈上残留）——请声明时给初值（int %s = 0;）或先赋值", v->name, v->name);
  error("[E-STRICT-UNINIT] 局部量 '%s' 在这里被读取，但从声明到现在从没赋过值（读到的是栈上残留）"
        "——请声明时给初值（int %s = 0;）或先赋值", v->name, v->name);
}

static void strict_mark(Parser *p, Node *n) {
  if (!n || n->kind != ND_VAR) return;
  LVar *v = lv_by_offset(p->all_lvars, n->offset);
  if (v) v->may_inited = true;
}

static void strict_walk(Parser *p, Node *n) {
  if (!n) return;
  switch (n->kind) {
    case ND_ASSIGN:
      strict_walk(p, n->rhs);
      if (n->lhs && n->lhs->kind == ND_VAR) strict_mark(p, n->lhs);
      else strict_walk(p, n->lhs);          // *p = / a[i] = ：地址侧照常按读查（p 本身要已初始化）
      return;
    case ND_ADD_ASSIGN: case ND_SUB_ASSIGN: case ND_MUL_ASSIGN:
    case ND_DIV_ASSIGN: case ND_MOD_ASSIGN:
    case ND_AND_ASSIGN: case ND_OR_ASSIGN: case ND_XOR_ASSIGN:
    case ND_SHL_ASSIGN: case ND_SHR_ASSIGN:
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      strict_read(p, n->lhs);               // 读改写：先按读查
      strict_walk(p, n->rhs);
      if (n->lhs && n->lhs->kind == ND_VAR) strict_mark(p, n->lhs);
      else strict_walk(p, n->lhs);
      return;
    case ND_ADDR:                           // &x：地址交出去了 ⇒ x 可能被别人写 → 保守标上
      strict_mark(p, n->lhs);
      return;
    case ND_REF_BIND:                       // int &r = x;：同一件事
      strict_mark(p, n->rhs);
      strict_mark(p, n->lhs);
      return;
    case ND_SHARED_ACQUIRE:                 // int *share q = p;：q 是**写目标**（槽 = p 值 + rc++）
      strict_walk(p, n->rhs);
      strict_mark(p, n->lhs);
      return;
    // —— 控制流：**按执行顺序**走，别按结构体字段顺序走 ——
    //   ND_FOR 的字段序是 (init, cond, inc, rhs=body)，而执行序是 init → cond → body → inc；
    //   照字段顺序（先 rhs）会把 `for (int i = 1; i <= 10; i++) { 用 i }` 误报成"i 没赋过值"
    //   —— **实测踩过**：全样本扫一遍时 8 个样本假红，全是这一条。
    case ND_IF:
      strict_walk(p, n->lhs);
      strict_walk(p, n->rhs);
      strict_walk(p, n->els);
      strict_walk(p, n->next);
      return;
    case ND_WHILE:
      strict_walk(p, n->lhs);
      strict_walk(p, n->rhs);
      strict_walk(p, n->next);
      return;
    case ND_FOR:
      strict_walk(p, n->init);
      strict_walk(p, n->cond);
      strict_walk(p, n->rhs);
      strict_walk(p, n->inc);
      strict_walk(p, n->next);
      return;
    case ND_VAR:
      strict_read(p, n);
      return;
    default: break;
  }
  strict_walk(p, n->lhs);
  strict_walk(p, n->rhs);
  strict_walk(p, n->els);
  strict_walk(p, n->init);
  strict_walk(p, n->cond);
  strict_walk(p, n->inc);
  strict_walk(p, n->next);
}

// 入口：一个函数体走一遍（调用点见 parse_funcdef 末尾，只在 -strict 下跑）
static void strict_uninit_func(Parser *p, Node *body) {
  for (Node *s = body; s; s = s->next) strict_walk(p, s);
}

static void parse_funcdef(Parser *p, Program *prog, int fi) {
  FuncDef *fn = &prog->funcs[fi];

  // v1.3.0：函数名与全局变量同名 → 报错（读变量/调函数分不清）。
  //   ⚠️ 这一半检查必须放在**解析函数处**而不是 collect_globals 里：collect_globals 先跑，
  //   它只能看见「变量在前」的顺序（那时函数表已由 collect_funcs 填好）；
  //   「函数在前、变量在后」被它拦住了，但**反序**（`int f = 2;` 在前、`int f(){...}` 在后）
  //   在那个时点还看不见 —— 实测漏网：两序都编译通过，且 `return f;` 被解析成**函数调用**，
  //   静默把变量读成了函数地址调用结果（本可以编译过、静默错值）。
  //   判据：双向关系（A↔B 重名）要在**两侧各自所在的那一遍**都查一遍，不能只查一侧。
  {
    // 函数名 token 位置：此刻 p->tok 指向返回类型词，函数名在其后（跳过一个可选 '*'）
    Token *nt = p->tok->next;
    if (nt && is_punct(nt, '*')) nt = nt->next;
    if (nt && nt->kind == TK_IDENT && find_global(prog, nt) >= 0)
      error_at(nt->loc, "函数 '%.*s' 与同名全局变量冲突（读变量和调函数会分不清）",
               nt->len, nt->loc);
  }

  // 返回类型（v1.0.6）：void ｜ int|char ｜ struct 名，后可选 '*' = 指针返回（int*/char*/struct S*）
  // main 必须裸 int（退出码 = main 返回值）
  bool is_void_ret = false;
  int ret_ty = TY_INT;
  int ret_sidx = -1;
  if (is_ident(p->tok, "void")) {
    is_void_ret = true;
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "struct")) {
    p->tok = p->tok->next;
    if (p->tok->kind != TK_IDENT || is_keyword(p->tok))
      error_at(p->tok->loc, "struct 后需跟类型名");
    ret_sidx = find_struct(p->prog, p->tok);
    if (ret_sidx < 0)
      error_at(p->tok->loc, "未定义的结构体类型 '%.*s'", p->tok->len, p->tok->loc);
    p->tok = p->tok->next;
    ret_ty = TY_STRUCT;
  } else if (is_ident(p->tok, "char")) {
    ret_ty = TY_CHAR;
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "int_64")) {            // v1.7.0：int_64 值返回（结果在 rax）
    ret_ty = TY_INT64;
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "double")) {          // v1.2.1：double 值返回（结果走 xmm0）
    ret_ty = TY_DOUBLE;
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "int")) {
    p->tok = p->tok->next;
  } else {
    error_at(p->tok->loc, "函数返回类型须为 int / int_64 / char / double / void / struct 名（指针返回加 *）");
  }

  if (is_void_ret) {
    if (consume(p, '*'))
      error_at(p->tok->loc, "void 不能返回指针");
    if (fn->is_main)
      error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
    fn->ret_void = true;
  } else {
    if (ret_ty == TY_STRUCT && !is_punct(p->tok, '*'))
      error_at(p->tok->loc, "struct 须指针返回（struct S *f()——按值返回暂不支持）");
    if (consume(p, '*')) {                    // v1.0.6：指针/句柄返回（64 位 rax）
      // v1.2.5：double* 指针返回开放 —— 指向类型进 ret_elem（`*f()` / `f()[i]` 的读写宽度与缩放靠它）
      if (fn->is_main)
        error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
      fn->ret_elem = (ret_ty == TY_CHAR) ? TY_CHAR : (ret_ty == TY_DOUBLE) ? TY_DOUBLE
                   : (ret_ty == TY_INT64) ? TY_INT64 : TY_INT;
      fn->ret_struct = (ret_ty == TY_STRUCT) ? ret_sidx : -1;
      fn->ret_ty = TY_PTR;
    } else {
      if (fn->is_main && ret_ty != TY_INT)
        error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
      fn->ret_ty = (ret_ty == TY_CHAR) ? TY_CHAR
                 : (ret_ty == TY_DOUBLE) ? TY_DOUBLE
                 : (ret_ty == TY_INT64) ? TY_INT64 : TY_INT;   // v1.7.0：+ int_64 值返回
    }
  }
  Token *name = p->tok;
  if (name->kind != TK_IDENT) error_at(name->loc, "期望函数名");
  p->tok = p->tok->next;

  skip(p, '(');

  // 每函数独立作用域 + 变量槽：参数先占（rbp-8 起），函数体变量随后
  p->var_count = 0;
  p->next_offset = 8;
  p->all_lvars = NULL;   // v1.4.25：strict 的"本函数全部变量"链每函数重建
  fn->nargs = 0;   // v1.2.2：预扫描为「前向调用」预填过形参个数，这里清零后正式重新登记
  for (int z = 0; z < FUNC_MAX_ARGS; z++) fn->param_sig[z] = FN_SIG_NONE;   // v1.3.2（0 是合法签名下标，不能靠清零）
  scope_push(p);
  p->fn_ret_void = fn->ret_void;
  p->fn_ret_dbl = (!fn->ret_void && fn->ret_ty == TY_DOUBLE);   // v1.2.1：return 处做 int→double 提升
  p->fn_ret_ty = fn->ret_void ? TY_INT : fn->ret_ty;            // v1.5.0：return str([...]) 的许可判据

  if (fn->is_main && !is_punct(p->tok, ')'))
    error_at(p->tok->loc, "main 函数不需要参数");
  if (!is_punct(p->tok, ')')) {
    for (;;) {
      // 类型词：int/char 或 struct 名（struct 须先定义）；修饰符 & 引用 / * 指针；void 参数拒绝
      int ty = TY_INT;
      int elem = TY_INT;      // v1.0.5：参数基类型元素/指向（char 标量 = TY_CHAR、char* 指向 = TY_CHAR）
      int sidx = -1;
      bool is_struct = false;
      bool pchar = false;     // v1.0.5：char 基类型参数
      bool pi64 = false;      // v1.7.0：int_64 基类型参数（引用形态未开）
      // v1.3.2：形参**本身是函数指针**（`int (*cb)(int)` / `void (*cb)(int)` / `char* (*cb)(void)`）
      //   —— 回调注册的常规写法。必须在这里整体吃掉，不能落进下面的普通形参路径
      //   （普通路径只认「类型词 + 修饰符 + 名字」，会把 `(` 当"没有名字"报错）。
      {
        Token *t0 = p->tok;
        int pr_ty = TY_INT, pr_elem = TY_INT;
        bool pr_void = false, is_fp = false;
        if (is_ident(t0, "void") && is_punct(t0->next, '(')) {
          pr_void = true; is_fp = true; t0 = t0->next;
        } else if (is_ident(t0, "int") || is_ident(t0, "char") || is_ident(t0, "double")) {
          if (is_ident(t0, "char")) { pr_ty = TY_CHAR; pr_elem = TY_CHAR; }
          else if (is_ident(t0, "double")) { pr_ty = TY_DOUBLE; pr_elem = TY_DOUBLE; }
          t0 = t0->next;
          if (is_punct(t0, '*') && is_punct(t0->next, '(')) { pr_ty = TY_PTR; t0 = t0->next; }
          if (is_punct(t0, '(')) is_fp = true;
        }
        if (is_fp) {
          FuncSig ps;
          Token *pn = NULL;
          p->tok = parse_funcptr_decl(&ps, t0, pr_ty, pr_elem, -1, pr_void, &pn);
          if (fn->nargs >= FUNC_MAX_ARGS)
            error_at(pn->loc, "函数参数最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参，v1.4.26）",
                     FUNC_MAX_ARGS);
          int psig = add_sig(p, ps);
          LVar *v = new_lvar(p, pn, false, TY_FUNCPTR, 0, -1, TY_INT);
          v->fn_sig = psig;
          v->may_inited = true;   // v1.4.25：形参由调用方装好 → strict 未初始化检查一律放行
          fn->param_offsets[fn->nargs] = v->offset;
          fn->param_ref[fn->nargs] = false;
          fn->param_ty[fn->nargs] = TY_FUNCPTR;   // → codegen 序言按 64 位 GP 装载
          fn->param_sig[fn->nargs] = psig;        // → 调用点比签名用
          fn->nargs++;
          if (!consume(p, ',')) break;
          continue;
        }
      }
      if (is_ident(p->tok, "struct")) {
        p->tok = p->tok->next;
        if (p->tok->kind != TK_IDENT || is_keyword(p->tok))
          error_at(p->tok->loc, "struct 后需跟类型名");
        sidx = find_struct(p->prog, p->tok);
        if (sidx < 0)
          error_at(p->tok->loc, "未定义的结构体类型 '%.*s'", p->tok->len, p->tok->loc);
        p->tok = p->tok->next;
        ty = TY_STRUCT;
        is_struct = true;
      } else if (is_ident(p->tok, "void")) {
        error_at(p->tok->loc, "void 不能作参数类型（无参函数直接写 f()）");
      } else if (is_ident(p->tok, "char")) {
        p->tok = p->tok->next;   // 吃 char
        ty = TY_CHAR;
        elem = TY_CHAR;
        pchar = true;
      } else if (is_ident(p->tok, "int_64")) {
        // v1.7.0：int_64 形参（值 += 8 字节 GP 通道；int_64* 走 TY_PTR + elem=TY_INT64）
        p->tok = p->tok->next;   // 吃 int_64
        ty = TY_INT64;
        elem = TY_INT64;
        pi64 = true;
      } else if (is_ident(p->tok, "double")) {
        // v1.2.2 double 阶段2 第二步：double 形参 → XMM0-3（值语义）。int 形参照旧走 rcx/rdx/r8/r9，
        //   两套寄存器序列**并行计数**（与 API 侧 v1.1.0 同一条 Win64 约定）。
        // v1.2.5：double* / double& 也开 —— elem 一并置 TY_DOUBLE，指向类型/别名对象类型都跟着走
        p->tok = p->tok->next;   // 吃 double
        ty = TY_DOUBLE;
        elem = TY_DOUBLE;
      } else if (!is_ident(p->tok, "int")) {
        error_at(p->tok->loc, "参数需以 'int'/'int_64'/'char'/'double'/'struct' 开头");
      } else {
        p->tok = p->tok->next;   // 吃 int
      }
      bool ref = consume(p, '&');
      bool ptr = consume(p, '*');
      if (ref && ptr)
        error_at(p->tok->loc, "引用与指针不能组合（v0.7 单修饰符）");
      if (is_struct && !ref && !ptr)
        error_at(p->tok->loc, "结构体按值传参暂不支持，用指针/引用（struct S *p 或 struct S &r）");
      if (ref && pchar)
        error_at(p->tok->loc, "char 引用形参暂不支持（v1.0.5：用 char* 指针）");
      // v1.7.0：int_64 引用形参暂不支持（引用读是 32 位解引用 ⇒ 静默截断）
      if (ref && pi64)
        error_at(p->tok->loc, "int_64 引用形参暂不支持（引用读是 32 位解引用，会静默截断）——"
                              "请用 int_64 *p 显式指针");
      // v1.2.5：double 的三种形参形态都开——值（double x，走 XMM0-3）、指针（double *p，走 GP 传地址）、
      //   引用（double &r，调用点自动传地址）。指针/引用的**指向类型**都是 TY_DOUBLE（elem 已置），
      //   所以 callee 里 `*p` / `r` 的读写宽度、`p[i]` 的下标缩放不会误落整数路径。
      if (is_punct(p->tok, '['))
        error_at(p->tok->loc, "数组形参暂不支持，请用指针（int *p / char *p / double *p）");
      if (ptr) ty = TY_PTR;
      Token *an = p->tok;
      if (an->kind != TK_IDENT || is_keyword(an))
        error_at(an->loc, "参数需为变量名");
      if (fn->nargs >= FUNC_MAX_ARGS)
        error_at(an->loc, "函数参数最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参，v1.4.26）",
                 FUNC_MAX_ARGS);
      LVar *v = new_lvar(p, an, ref, ty, 0, sidx, elem); // PTR/STRUCT 携带结构体下标；int 系 -1
      v->may_inited = true;   // v1.4.25：形参由调用方装好 → strict 未初始化检查一律放行
      fn->param_offsets[fn->nargs] = v->offset;
      fn->param_ref[fn->nargs] = ref;   // 引用形参调用点自动传地址；指针形参用 &x 显式
      // v0.8：装载宽度用（PTR/引用 64 位落槽）
      // v1.2.5：double& 形参的装载记 TY_PTR（调用点传的是地址 → GP 落槽）——**不能记 TY_DOUBLE**，
      //   否则装载侧走 movsd xmm 落槽（把地址当浮点位型），callee 一读就是垃圾。lvar 那边仍是
      //   TY_DOUBLE（别名对象的类型），读 r 走「引用槽取地址 + 8 字节 SSE 解引用」。
      fn->param_ty[fn->nargs] = (ref && ty == TY_DOUBLE) ? TY_PTR : ty;
      fn->nargs++;
      p->tok = p->tok->next;
      if (!consume(p, ',')) break;
    }
  }
  skip(p, ')');
  skip(p, '{');

  Node head = {0};
  Node *cur = &head;
  while (!is_punct(p->tok, '}')) {
    if (p->tok->kind == TK_EOF) error_at(p->tok->loc, "函数缺少右花括号 '}'");
    cur = cur->next = stmt(p);
  }
  skip(p, '}');
  scope_pop(p);

  fn->body = head.next;
  fn->var_count = p->var_count;

  // v1.4.25（`-strict`）②：未初始化局部量检查。放在这里跑是因为：AST 已经齐了、
  //   p->all_lvars 也齐了（块作用域虽已弹出，但变量链还在）。
  if (flint_strict) strict_uninit_func(p, fn->body);

  // void 调用用法检查（结果不能当值）
  for (Node *s = fn->body; s; s = s->next) check_stmt_void(s);
}

Program parse(Token *tok) {
  Program prog = {0};

  // v1.3.0：全局变量预扫描**必须最先**——它把 .data 偏移一次算死，供函数体（含前向引用）
  //   建出 ND_VAR；同时它也跳过 API/函数定义，与 collect_funcs 共用同一套顶层识别口径。
  collect_globals(tok, &prog);
  // 第一遍：预登记函数名（前向调用可用）+ 顶部 API 声明（v0.8）
  collect_funcs(tok, &prog);
  collect_apis(tok, &prog);
  // v0.9：内置堆 API（VirtualAlloc/VirtualFree）——源码含 'new' 才登记，纯算数 exe 零污染
  prog.api_alloc = -1;
  prog.api_free = -1;
  bool need_heap = false;
  for (Token *t = tok; t->kind != TK_EOF; t = t->next)
    if (is_ident(t, "new")) { need_heap = true; break; }
  if (need_heap) {
    prog.api_alloc = ensure_api(&prog, "kernel32", "VirtualAlloc", 4, false);
    prog.api_free = ensure_api(&prog, "kernel32", "VirtualFree", 3, false);
  }
  if (prog.main_index < 0)
    error_at(tok->loc, "缺少 main 函数（程序入口）");

  // 第二遍：按源序解析 struct 定义与函数定义
  // ⚠️ 位置初始化与 Parser 字段顺序一一对应（新增字段必须同步这里，否则「名字对不上值」的静默错位）：
  //   tok, scope, var_count, next_offset, prog, fn_ret_void, scope_nest, loop_nest, switch_nest, fn_ret_dbl, fn_ret_ty
  //   （v1.5.0 加 fn_ret_ty 时漏了这一处 ⇒ gcc 报 missing initializer、warn 门从 7 变 8；补 0 = TY_INT）
  Parser p = { tok, NULL, 0, 8, NULL, &prog, false, 0, 0, 0, false, 0 };
  int fi = 0;
  bool seen_toplevel = false;   // 是否已见 struct/函数（api 只允许在此之前）
  while (p.tok->kind != TK_EOF) {
    if (is_ident(p.tok, "api")) {
      if (seen_toplevel)
        error_at(p.tok->loc, "api 声明必须放在文件最顶部（任何 struct/函数之前）");
      // 顶部 api：collect_apis 已登记，这里跳过整行
      while (p.tok->kind != TK_EOF && !is_punct(p.tok, ';')) p.tok = p.tok->next;
      p.tok = p.tok->next;
      continue;
    }
    if (is_ident(p.tok, "struct")) {
      seen_toplevel = true;
      // struct 定义 = struct 名 { ... }；其余 struct 名 开头 = 函数（v1.0.6 指针返回 struct S *f()
      //   或非法的值返回 struct P f() → 交 parse_funcdef 报精确错）
      Token *sn = p.tok->next;
      Token *after = (sn && sn->kind == TK_IDENT) ? sn->next : NULL;
      if (!after || !is_punct(after, '{')) {
        parse_funcdef(&p, &prog, fi);
        fi++;
        continue;
      }
      parse_structdef(&p, &prog);
      continue;
    }
    if (!is_ident(p.tok, "int") && !is_ident(p.tok, "char") && !is_ident(p.tok, "void")
        && !is_ident(p.tok, "double") && !is_ident(p.tok, "int_64"))   // v1.2.1 double；v1.7.0 int_64
      error_at(p.tok->loc, "顶层只允许 struct 定义、函数定义或全局变量声明"
                           "（int/int_64/char/double/void 名称(...) 或 int/int_64/char/double 名称[= 常量];）");
    seen_toplevel = true;
    // v1.0.6：函数名前可跳一个 '*'（指针返回 int*/char*）
    Token *nn = p.tok->next;
    if (nn && is_punct(nn, '*')) nn = nn->next;
    // v1.3.0：全局变量声明（collect_globals 已登记其 .data 偏移），这里只跳过整条声明
    //   （含逗号声明表 `int a = 1, b;`——整条一起跳过）
    if (nn && nn->kind == TK_IDENT && !is_keyword(nn)) {
      Token *after = scan_declarator(p.tok->next);
      if (after && (is_punct(after, ';') || is_punct(after, '=') || is_punct(after, ','))) {
        while (p.tok->kind != TK_EOF && !is_punct(p.tok, ';')) p.tok = p.tok->next;
        p.tok = p.tok->next;                        // 跳过 ';'
        continue;
      }
    }
    if (!nn || nn->kind != TK_IDENT || !nn->next || !is_punct(nn->next, '('))
      error_at(p.tok->loc, "顶层只允许 struct 定义、函数定义或全局变量声明"
                           "（int/int_64/char/double/void 名称(...) 或 int/int_64/char/double 名称[= 常量];）");
    parse_funcdef(&p, &prog, fi);
    fi++;
  }
  if (fi != prog.nfuncs)
    error_at(tok->loc, "内部错误：函数解析数与预扫描不一致");
  return prog;
}
