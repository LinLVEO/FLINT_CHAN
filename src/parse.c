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
// v1.9.0：类型名的人话（报错文案用；定义在下面 sig_desc 之前）
static const char *ty_name(int ty);
// v1.9.0：通常算术转换（定义在 mkbin 之前；ternary 也更早用到，故先声明）
static int usual_arith_ty(int a, int b);
static int int_promote(int t);

// —— 作用域栈 ——
typedef struct LVar LVar;
struct LVar {
  LVar *next;
  char *name;
  int len;
  int offset;
  int ty;         // v0.7：Type（TY_INT/TY_PTR/TY_ARR/TY_STRUCT）
  int elem_ty;    // v1.0.5：TY_ARR 元素 / TY_PTR 指向 类型（TY_CHAR = 字节语义；默认 TY_INT）
  int arr_len;    // TY_ARR：元素个数（v2.2.0：二维数组时 = **行数**，列数在 cols）
  int cols;       // v2.2.0：二维数组的**列数**（第二维 / stride）；0 = 一维或非数组
                  //   元素总数 = arr_len * cols；`m[i][j]` 在 postfix 折成 `m[i*cols + j]`，
                  //   ⇒ codegen 一行不用改（复用既有「基址 + 下标×元素宽」通路）
  int struct_idx; // TY_STRUCT：Program.structs 下标；TY_PTR：指向的结构体（int* 为 -1）
  bool is_ref;    // v0.6：引用变量（槽存地址，读写自动解引用）
  bool is_global;// v1.3.0：符号表项**不是**局部变量，而是全局变量——此时 offset 存的是
                 //   Program.globals 下标（不是 rbp 偏移）。所有直接读/写槽码必须按它分流。
  bool is_own; // v0.9：own 独占指针（new 初始化；出口自动释放；禁拷贝/重赋值）
  bool is_share; // v0.9：share 引用计数指针（new/share 拷贝初始化；拷贝+1 出口-1 归零释放）
  int fn_sig;    // v1.3.2：TY_FUNCPTR 变量的签名下标（Program.sigs）；其余 = FN_SIG_NONE
  // ===== v2.12.0：**指针数组** `char *names[N]` =====
  //   elem_ty == TY_PTR 时，本字段 = 元素指针的**指向类型**（char* 数组 → TY_CHAR；
  //   int* 数组 → TY_INT；double* 数组 → TY_DOUBLE …）。
  //   为什么 elem_ty 记 TY_PTR 而不是 char：数组的元素宽/下标步长/读写宽度全部按 elem_ty 走
  //   （new_lvar 的槽数、postfix 的 ty_arr_stride、ND_DEREF.ty 的读宽）—— 记 TY_CHAR 会得到
  //   1 字节步长 + 1 字节读写（把 8 字节地址读成半截），必须让"元素类型 = 指针"这一档成立，
  //   指向类型则另存本字段（与 Node.elem_ty/TY_PTR 的分工同形：ty 说宽度，elem_ty 说指向什么）。
  int elem_ptr_ty;
  // v5（`-debug`，D-1）：声明所在源码行 + 是不是形参 —— 变量位置表（`<out>.dbg.json`）要用。
  //   行号与编译器报错同源（src_line_of），不另解析源码。
  int line;
  bool is_param;
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
  int depth;          // v2.7.0：递归下降深度（括号/语句块嵌套）。超过 PARSE_MAX_DEPTH 就是栈溢出前兆
  // v2.14.0（struct 按值返回）：当前函数按值返回的结构体下标（-1 = 不是按值返回 struct），
  //   以及隐藏返回缓冲指针的槽偏移（0 = 无）。return 的整条分支靠这两个字段判形态/取缓冲。
  int fn_ret_struct;
  int fn_retbuf_off;
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

// ===== v1.9.0：类型关键字 → Type 的**单点表** =====
// 为什么单点：类型关键字出现在 9 个位置（局部/全局声明、形参、返回类型、struct 字段、
//   for 头、转型、new、api 声明、预扫描），每处原来都手写一串 is_ident(...)。加一种类型
//   若漏改一处，那里就**静默当 int 处理**（本刀最大风险）。所有位置一律走这里。
//   注意 `int_32` 由 is_ident 的别名规则覆盖（`is_ident(t,"int")` 对 "int_32" 也为真）。
static int type_kw_of(Token *t) {
  if (!t || t->kind != TK_IDENT) return -1;
  if (is_ident(t, "int"))     return TY_INT;      // 含 int_32 别名
  if (is_ident(t, "int_64"))  return TY_INT64;
  if (is_ident(t, "char"))    return TY_CHAR;
  if (is_ident(t, "double"))  return TY_DOUBLE;
  if (is_ident(t, "uint_8"))  return TY_UINT8;    // v1.9.0
  if (is_ident(t, "uint_32")) return TY_UINT32;
  if (is_ident(t, "uint_64")) return TY_UINT64;
  return -1;
}
// 值类型关键字（不含 double —— 声明位置的 double 有自己的一档处理）
static int type_kw_int(Token *t) {
  int ty = type_kw_of(t);
  return (ty == TY_DOUBLE) ? -1 : ty;
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
      || is_ident(tok, "uint_8") || is_ident(tok, "uint_32") || is_ident(tok, "uint_64")  // v1.9.0
      || is_ident(tok, "switch") || is_ident(tok, "case") || is_ident(tok, "default"); // v1.3.1
  // 注意：main 不是关键字（v0.5 函数名；"int main" 由函数定义层识别）
  // v0.9：new = 堆分配（保留）；own = 独占指针标注；share = 引用计数指针标注（都只修饰 * 指针）
  // v0.9.2：ptr 仅作 api 返回类型（api user32 ptr GetModuleHandleA(int);），全局保留防误用
  // v1.0.5：char = 无符号字节类型（B 档；声明/数组/struct 字段/参数/返回）
  // v1.9.0：uint_8/uint_32/uint_64 = 无符号整数（同表示、异类型；防止当变量名用）
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

// —— v2.1.0 enum：具名整数常量查找（局部变量/全局变量优先级更高；常量只是字面量别名）——
static int find_enum(Program *prog, Token *tok) {
  for (int i = 0; i < prog->nenums; i++) {
    EnumConst *e = &prog->enums[i];
    if ((int)strlen(e->name) == tok->len && strncmp(e->name, tok->loc, (size_t)tok->len) == 0)
      return i;
  }
  return -1;
}

static void add_enum_const(Program *prog, Token *tok, int value) {
  if (prog->nenums >= prog->enums_cap) {
    prog->enums_cap = prog->enums_cap ? prog->enums_cap * 2 : 8;
    prog->enums = realloc(prog->enums, sizeof(EnumConst) * (size_t)prog->enums_cap);
    if (!prog->enums) error_at(tok->loc, "内存不足：枚举常量表扩容失败");
  }
  char *nm = malloc((size_t)tok->len + 1);
  memcpy(nm, tok->loc, (size_t)tok->len);
  nm[tok->len] = 0;
  prog->enums[prog->nenums].name = nm;
  prog->enums[prog->nenums].value = value;
  prog->enums[prog->nenums].tok = tok;
  prog->nenums++;
}

// ===== v2.15.0（G7）：编译期整数常量表达式 =====
// 只认「字面量 / enum 常量 / 括号 / 一元 + - ~ / 二元 * / % << >> & | ^（+ - 也收）」。
// **不走 expr()**：变量、函数调用、运行期量在这里一律失败 —— 数组长度/枚举值都要在 parse 期算死。
// 失败返回 false，由调用点按各自既有文案报硬错（各位置的判据不同，统一文案反而会丢关键词）。
// 优先级按 C：| < ^ < & < << >> < + - < * / %；只做整数运算（long long 中间值）。
static bool parse_const_int(Parser *p, long long *out);

static bool const_int_primary(Parser *p, long long *out) {
  Token *t = p->tok;
  if (t->kind == TK_NUM)   { *out = t->val;  p->tok = t->next; return true; }
  if (t->kind == TK_NUM64) { *out = t->lval; p->tok = t->next; return true; }
  if (is_punct(t, '(')) {
    p->tok = t->next;
    if (!parse_const_int(p, out)) return false;
    if (!is_punct(p->tok, ')')) return false;
    p->tok = p->tok->next;
    return true;
  }
  if (is_punct(t, '-') || is_punct(t, '+') || is_punct(t, '~')) {
    char op = *t->loc;
    p->tok = t->next;
    long long v = 0;
    if (!const_int_primary(p, &v)) return false;
    *out = (op == '-') ? -v : (op == '~') ? ~v : v;
    return true;
  }
  if (t->kind == TK_IDENT && !is_keyword(t)) {
    int ei = find_enum(p->prog, t);
    if (ei >= 0) { *out = p->prog->enums[ei].value; p->tok = t->next; return true; }
  }
  return false;
}

static bool const_int_mul(Parser *p, long long *out) {
  if (!const_int_primary(p, out)) return false;
  for (;;) {
    char op;
    if (is_punct(p->tok, '*')) op = '*';
    else if (is_punct(p->tok, '/')) op = '/';
    else if (is_punct(p->tok, '%')) op = '%';
    else break;
    Token *opt = p->tok;
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_primary(p, &rhs)) return false;
    if (op == '*') {
      // 无符号乘法再回转：避免有符号溢出的 UB（数组长度本来就会在调用点做范围检查）
      *out = (long long)((unsigned long long)*out * (unsigned long long)rhs);
    } else {
      if (rhs == 0) { error_at(opt->loc, "数组长度常量表达式里不能除以 0"); return false; }
      if (op == '/') *out = *out / rhs;
      else           *out = *out % rhs;
    }
  }
  return true;
}

static bool const_int_add(Parser *p, long long *out) {
  if (!const_int_mul(p, out)) return false;
  for (;;) {
    char op;
    if (is_punct(p->tok, '+')) op = '+';
    else if (is_punct(p->tok, '-')) op = '-';
    else break;
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_mul(p, &rhs)) return false;
    if (op == '+') *out = (long long)((unsigned long long)*out + (unsigned long long)rhs);
    else           *out = (long long)((unsigned long long)*out - (unsigned long long)rhs);
  }
  return true;
}

static bool const_int_shift(Parser *p, long long *out) {
  if (!const_int_add(p, out)) return false;
  for (;;) {
    char op;
    if (is_punct_str(p->tok, "<<")) op = 'L';
    else if (is_punct_str(p->tok, ">>")) op = 'R';
    else break;
    Token *opt = p->tok;
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_add(p, &rhs)) return false;
    if (rhs < 0 || rhs > 63)
      error_at(opt->loc, "数组长度常量表达式的位移位数须在 0..63（得到 %lld）", rhs);
    if (op == 'L') *out = (long long)((unsigned long long)*out << rhs);
    else           *out = *out >> rhs;
  }
  return true;
}

static bool const_int_and(Parser *p, long long *out) {
  if (!const_int_shift(p, out)) return false;
  while (is_punct(p->tok, '&')) {
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_shift(p, &rhs)) return false;
    *out = *out & rhs;
  }
  return true;
}

static bool const_int_xor(Parser *p, long long *out) {
  if (!const_int_and(p, out)) return false;
  while (is_punct(p->tok, '^')) {
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_and(p, &rhs)) return false;
    *out = *out ^ rhs;
  }
  return true;
}

static bool const_int_or(Parser *p, long long *out) {
  if (!const_int_xor(p, out)) return false;
  while (is_punct(p->tok, '|')) {
    p->tok = p->tok->next;
    long long rhs = 0;
    if (!const_int_xor(p, &rhs)) return false;
    *out = *out | rhs;
  }
  return true;
}

static bool parse_const_int(Parser *p, long long *out) {
  return const_int_or(p, out);
}

// 登记变量：分配槽（数组 = arr_len × cols 个元素；结构体 = ceil(size/8) 个槽）；类型信息入 LVar
//   v2.4.0：结构体槽数**只看 size**（不是 nfields）——嵌套值字段的字节数在 parse_structdef 的布局期
//   已整块累加进外层 size，所以嵌套深浅都不改这里的算法。
static LVar *new_lvar(Parser *p, Token *tok, bool ref, int ty, int arr_len, int cols,
                      int struct_idx, int elem_ty) {
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
  v->cols = cols;         // v2.2.0：二维数组列数（0 = 一维/非数组）
  v->struct_idx = struct_idx;
  v->is_ref = ref;
  v->fn_sig = FN_SIG_NONE;   // v1.3.2：非函数指针变量（函数指针在建立后显式赋值）
  v->line = src_line_of(tok->loc);   // v5（D-1）：声明行 —— 与报错定位同源
  // v0.9.2：结构体变量 = ceil(size/8) 个 8 字节槽（C 布局字节块；字段在块内按类型对齐）
  // v1.6.5（int4 ABI）：int 数组元素 = **4 字节**（C 兼容）；char 数组沿用 8*N 槽（字节缓冲布局不动）；
  //   double 数组 = 8 字节/元素。槽数按元素字节数上取整，基址公式（offset += 8*(slots-1)）不变。
  // v2.2.0：二维数组元素总数 = 行 × 列（cols=0 视为 1）——槽只按**总元素数**分配，
  //   行列结构只活在 LVar.cols 里，寻址由 postfix 折叠成一维（帧布局与一维数组同一口径）。
  long long _nelem = (long long)arr_len * (cols > 0 ? cols : 1);
  if (cols > 0 && _nelem > 0x1FFFFFFFLL)   // 只挡二维的行×列乘法回绕（一维沿用下面的既有检查）
    error_at(tok->loc, "二维数组总长过大（行×列 = %lld）——帧槽累计超 2GB 上限", _nelem);
  int _elem_esz = ty_arr_stride(elem_ty);   // v1.7.0：走单点表（char 1 / int 4 / int_64 8 / double 8）
  int slots;
  if (ty == TY_ARR) {
    slots = ty_is8(elem_ty) ? (int)_nelem : (int)((_elem_esz * _nelem + 7) / 8);
  } else if (ty == TY_STRUCT) {
    // ===== v2.1.0：局部 struct 数组 `struct S a[N];` =====
    //   每元素 = ceil(size/8) 个 8 字节槽（与单变量**同一口径**，见上一行同理）；N 个元素连排
    //   ⇒ **元素步长 = 8*ceil(size/8)**（不是 C 的 sizeof，也不是 size）。为什么必须槽对齐：
    //   帧槽的分配/基址公式（offset += 8*(slots-1)）以 8 字节为单位，步长取 8 的倍数才能保证
    //   「元素 i 的基址 + 字段字节偏移」永远落在本元素自己的槽区间里（含指针字段的 8B 对齐）。
    long long per = (p->prog->structs[struct_idx].size + 7) / 8;
    long long n = arr_len > 0 ? (long long)arr_len : 1LL;
    if (per * n > 0x1FFFFFFFLL)   // 与下面的 2GB 帧上限同源；先挡乘法回绕
      error_at(tok->loc, "结构体数组总长过大（帧槽累计超 2GB 上限）");
    slots = (int)(per * n);
  } else {
    slots = 1;   // v1.1.0：double 也是 1 个 8 字节槽（它按「值」读写，不是按「块基址」）
  }
  // ===== slot4：本地标量 `int` / `int_32` = **4 字节**（C 语义），其余标量仍 8 字节 =====
  //   只动「单标量 TY_INT 且非引用」：
  //     · 数组 / 结构体走 8 字节块口径（基址公式 offset += 8*(slots-1)、元素步长 8*slots）——不动；
  //     · 引用槽里存的是 8 字节**对象地址**（int &r）——不动；
  //     · uint_32 不是 int（值宽 4，但本轮只收窄 int；槽仍 8）；
  //     · int_32 是 int 的别名（type_kw_of 返回 TY_INT）⇒ 自动同宽。
  //   槽数仍记 1（var_count 是"变量/槽个数"，数组/结构体按槽计），帧**字节数**走 FuncDef.frame_bytes。
  //   ⚠️ alloc 用 long long 算：`int a[2000000000]` 的字节数 = 8e9 超 int32，先溢出再比就会漏掉
  //      "巨长数组"这条防线（实测：4 字节 int 数组的元素数只有一半 ⇒ 8*slots 正好在 2^32 附近回绕）。
  long long alloc_ll = 8LL * slots;
  if (ty == TY_INT && slots == 1 && !ref) alloc_ll = 4;
  // v1.0.6.2 盲区审计 A6：帧槽累计防 int 溢出——数组长巨大（如 int a[2000000000]）时
  // 8*slots ≈ 1.6e10 超 int32，offset/var_count/frame 全回绕 → sub rsp 巨值/错 offset 的
  // 损坏产物。上限 = 帧累计 ≤ (2^31-1) 字节（2GB 帧，远超任何实际栈；正常代码永不到）
  if ((long long)p->next_offset + alloc_ll > 0x7FFFFFFFLL)
    error_at(tok->loc, "变量/数组/结构体总长过大（帧槽累计超 2GB 上限）");
  int alloc = (int)alloc_ll;   // 上面的守卫保证 next_offset+alloc ≤ 2^31-1 ⇒ alloc 必装得下
  // 🔧 帧物理布局修正（v0.9.2 → slot4 重写成一条统一公式）：
  //   槽按 rbp-off 计、连续**向下**分配；一个变量占的物理字节区（偏移空间）= [U_old+1, U_new]，
  //   其中 U = 已用字节数 = next_offset - 8。槽的“基址”（最低地址、最大偏移）= U_new。
  //   ⇒ 基址 = next_offset + alloc - 8：
  //        · 8 字节标量：v = next_offset（旧行为不变）；
  //        · 数组/结构体块：v = next_offset + 8*slots - 8（与旧版 `offset += 8*(slots-1)` 逐字等价，
  //          块变量基址指保留区最低字节，元素/字段向上走正好落在自区内）；
  //        · **4 字节 int**：v = next_offset - 4 —— 必须一起走这条公式，否则后一个 8 字节变量
  //          （指针/double/int_64）的槽会覆盖它（slot4 第一版就踩了：int 后面接指针的函数全部错数据）。
  v->offset = p->next_offset - 8 + alloc;
  p->next_offset += alloc;
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

static Node *new_var_node(int offset, bool is_ref, int ty, int struct_idx, int elem_ty);  // 定义在 new_node 之后

// ===== v2.14.0（struct 按值返回）：调用点的隐藏返回缓冲 =====
// 约定（只在「函数返回 struct 值」这一族里成立，其余函数一个字节都不变）：
//   被调方的**第 1 个整型参数**（rcx）不是用户形参，而是调用者分配的返回缓冲地址；
//   用户形参整体后移一位（rdx/r8/r9/第 4 个起走栈参）。
// 实作：给 ND_CALL 的实参链**头插**一个"缓冲地址"表达式，让它走既有 gen_call 的
//   求值/落位通路（第 i 个实参 → 第 i 个参数位置）—— 于是隐藏参数不需要第二条发射路径。
static void sret_attach_arg(Node *call, Node *hidden) {
  hidden->next = call->rhs;    // 头插：hidden 成为 args[0]（= rcx）
  call->rhs = hidden;
  call->nargs++;
  call->sret_ok = 1;
}

// 目标结构体变量的**地址**（`&dst`）—— 声明/赋值的右值用。
// 复制一个 ND_VAR 而不是复用原节点：原节点同时是 ND_STRUCT_COPY.lhs，
// 同一个节点出现在两处会让 slotmap_declare_ast/后遍检查各走一遍（本仓"一个节点挂两处"的老坑）。
static Node *sret_dst_addr(Node *lv) {
  Node *cpy = new_node(ND_VAR, NULL, NULL);
  cpy->offset = lv->offset;
  cpy->ty = TY_STRUCT;
  cpy->elem_ty = TY_INT;
  cpy->struct_idx = lv->struct_idx;
  cpy->is_ref = lv->is_ref;
  cpy->is_global = lv->is_global;
  cpy->loc = lv->loc;
  Node *ad = new_node(ND_ADDR, cpy, NULL);
  ad->ty = TY_PTR;
  ad->elem_ty = TY_STRUCT;
  ad->struct_idx = lv->struct_idx;
  ad->loc = lv->loc;
  return ad;
}

// `return f();`（f 也按值返回 struct）：把**本函数的**隐藏缓冲地址当 f 的隐藏首参传下去
// （隐藏槽里存的就是调用者给我们的缓冲地址，64 位值直接当实参）。
static Node *sret_retbuf_addr(Parser *p, Node *call) {
  if (p->fn_retbuf_off <= 0)
    error("内部错误：struct 按值返回函数缺少隐藏返回缓冲槽（parse_funcdef 未分配）");
  Node *hb = new_var_node(p->fn_retbuf_off, false, TY_PTR, -1, TY_INT);
  hb->loc = call->loc;
  return hb;
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
    case ND_U2L: return true;   // v1.9.0：零扩展拓宽也是**完整 64 位值**（漏这一档 = 又被 movsxd 抹掉高半）
    // v1.9.0：uint_64 与 int_64 的**值宽**同族（8/8/8）⇒ 所有"是不是 64 位完整值"的
    //   宽度判据都要认它（`is64_value` / 实参整搬 / 64 位发射器）。**符号性另判**
    //   （div/mod/shr/比较/打印走 expr_is_u64），两者不要混。
    case ND_VAR: return ty_is64(n->ty);
    case ND_CALL: return ty_is64(n->ty);        // 调用节点的 ty 由被调函数 ret_ty 决定
    // v1.11.0（2026-11-04）：api 返回 int_64/uint_64 时，ND_APICALL 也是**完整 64 位值**。
    //   ⚠️ 漏这一档 = `int_64 v = GetTickCount64();` 会被 asgn_rhs 包成 ND_I2L（movsxd rax,eax）
    //   抹掉高 32 位；print / 64 位比较 / 再当 int_64 实参传出去也全都退化成 32 位（编译过、值错）。
    //   ty 来自 parse 的 `call->ty = a->ret_ty;`（唯一来源），这里只读不重推。
    case ND_APICALL: return ty_is64(n->ty);
    case ND_DEREF: return ty_is64(n->ty);       // *p / 数组元素 / 结构体字段
    case ND_ASSIGN: return expr_is_i64(n->rhs) || ty_is64(n->ty);
    // v1.8.0 C 风格转型：(int_64)x / (uint_64)x 的结果就是 64 位值
    case ND_CAST: return ty_is64(n->ty);
    case ND_TERN: return ty_is64(n->ty);
    // v1.7.0 P1：++/-- 的值类型 = 操作数类型（前缀=新值、后缀=旧值，两者都是完整 64 位）。
    //   ⚠️ 不补这一档 = `int_64 y = x++;` 会被 asgn_rhs 包成 ND_I2L（movsxd rax,eax），
    //   把高 32 位抹掉 —— 编译过、值错。打印（seg_print_kind）也靠这一档选 _flint_out_i64。
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      return expr_is_i64(n->lhs);
    case ND_NEG: case ND_BITNOT:
      // v1.9.0：一元节点由 parse 刻结果类型（整型提升后）；没刻时回落到操作数判据
      return ty_is64(n->ty) || expr_is_i64(n->lhs);
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV: case ND_MOD:
    case ND_BITAND: case ND_BITOR: case ND_BITXOR: case ND_SHL: case ND_SHR:
      // v1.9.0：二元节点在 mkbin/mkintbin 里已刻好**通常算术转换**的结果类型 ⇒ 直接读。
      //   （旧行为 = 递归看两侧，与"两侧都提升到 int_64"等价；刻类型后不再重推子树。）
      return ty_is64(n->ty);
    default: return false;
  }
}

// ===== v1.9.0：无符号三类型的**值类型**判据（与 expr_is_i64 同族，parse/codegen 共用）=====
// 为什么最后只用 node->ty 而不是像 expr_is_i64 那样递归看子树：
//   mkbin/mkintbin 在建节点时就把 C 的通常算术转换结果刻进 node->ty 了
//   （`uint_32 + int` → TY_UINT32；`uint_32 + int_64` → TY_INT64；`int_64 + uint_64` → TY_UINT64），
//   于是"表达式值类型"是一张**已经算好的表**，问一次 O(1)。递归重推 = 第二份实现 = 迟早分叉。
int expr_ty_of(Node *n) {
  if (!n) return TY_INT;
  switch (n->kind) {
    case ND_NUM: return TY_INT;
    case ND_NUM64: return TY_INT64;
    case ND_DBL: case ND_I2D: return TY_DOUBLE;
    case ND_I2L: return TY_INT64;
    case ND_U2L: return TY_INT64;   // v1.9.0：零扩展后的 64 位值（符号性由上游的 node->ty 决定）
    case ND_L2I: return TY_INT;
    case ND_STR: case ND_ADDR: case ND_NEW: case ND_FUNC_ADDR: return TY_PTR;
    // 结果类型 = 节点自己刻的类型（parse 已经在这些节点上写好）
    case ND_VAR: case ND_DEREF: case ND_CALL: case ND_APICALL:
    case ND_CAST: case ND_TERN: return n->ty;
    // 赋值表达式的值 = 被赋的值；左值是 uint 时 parse 会把左值类型刻进 node->ty
    case ND_ASSIGN: return ty_uns(n->ty) ? n->ty : expr_ty_of(n->rhs);
    case ND_PRE_INC: case ND_PRE_DEC: case ND_POST_INC: case ND_POST_DEC:
      return n->ty == TY_INT ? expr_ty_of(n->lhs) : n->ty;   // parse 已按操作数类型刻好
    case ND_NEG: case ND_BITNOT: case ND_BITAND: case ND_BITOR: case ND_BITXOR:
    case ND_ADD: case ND_SUB: case ND_MUL: case ND_DIV: case ND_MOD:
    case ND_SHL: case ND_SHR:
      return n->ty;     // mkbin/mkintbin/一元解析刻好的通常算术转换结果（0 = TY_INT）
    default: return TY_INT;
  }
}
bool expr_is_u64(Node *n) { return expr_ty_of(n) == TY_UINT64; }
bool expr_is_u32(Node *n) { return expr_ty_of(n) == TY_UINT32; }
bool expr_is_uns(Node *n) { return ty_uns(expr_ty_of(n)); }

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

// v1.9.0：拓宽到 64 位 —— **值保持**（C11 6.3.1.3 的"新类型能表示原值就值不变"）：
//   有符号 32 位源 → 符号扩展（movsxd）｜无符号 32 位源 → 零扩展（ND_U2L：mov eax,eax）。
//   ⚠️ 这一档就是 `int_64 + uint_32`（→ int_64）与 `uint_64 + uint_32`（→ uint_64）的
//   唯一分岔点。若统一走 movsxd，`(uint_32)0-1` 参与 64 位运算会被抹成 -1 ⇒ 静默错值。
Node *expr_widen_to64(Node *n, bool dst_uns) {
  (void)dst_uns;                        // 目标符号性不影响"值保持"这一步（C 口径）
  if (expr_is_i64(n)) return n;
  int st = expr_ty_of(n);
  if (ty_uns(st)) {                     // 无符号 8/32 位源 → 零扩展
    Node *c = new_node(ND_U2L, n, NULL);
    c->ty = TY_INT64;
    return c;
  }
  return expr_widen_i64(n);             // 有符号/字节源 → 符号扩展（char 值 0..255，等价）
}

// parse 侧的「这个表达式的值是不是地址」判据 —— codegen 有同名的 is_addr_value，
//   但那边还含 T1「装过地址的 int」标记，parse 拿不到 ⇒ 这里只做一层薄封装（唯一出处仍是
//   tern_addr_info，别在别处再写一份 is_addr 的判据）。定义在 tern_addr_info 之后。
static bool parse_is_addr_value(Node *n);

// ===== D3：宽度口径单点表（flint.h 声明）=====
// 值宽：一次读写几个字节。数组/结构体的元素走本表；槽宽（8）是帧布局的事，不在这里。
int ty_value_bytes(int ty) {
  switch (ty) {
    case TY_CHAR:  case TY_UINT8:  return 1;   // v1.9.0：uint_8 与 char 同表示
    case TY_INT:   case TY_UINT32: return 4;   // v1.9.0：uint_32 与 int 同值宽（slot4 起 int 本地槽 4、uint_32 仍 8）
    case TY_INT64: case TY_UINT64: return 8;   // v1.9.0：uint_64 与 int_64 同（值宽=槽宽=步长）
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
    error("64 位整数（int_64/uint_64）不能隐式转 double（两者互转只走显式转型）——"
          "请先显式收窄再转，或改用整数值");
  // v1.9.0：uint_8 / uint_32 / uint_64 与 double 的**隐式**转换一律不许（C 的通常算术转换里
  //   无符号整型与 double 混算要先做整型转换；本仓口径 = 必须写出显式转型）。
  //   显式 `(double)u` **已经实现正确转换**（uint_32 零扩展后按 64 位有符号转；uint_64 高位
  //   走 ((v>>1)|(v&1)) 再翻倍的分支，见 codegen 的 ND_CAST），所以这里只拦隐式那一档。
  if (ty_uns(expr_ty_of(n)))
    error("无符号整数不能隐式转 double（要先写显式转型，如 (double)u）——"
          "或者改用整数值");
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
    // v2.6.0：右侧不再限定「变量」——函数指针数组元素 `ops[i]` 也是 TY_FUNCPTR 值（签名在节点上），
    //   这样 `ops[0] = ops[1]` / `fp = ops[0]` 与单变量赋值走同一条检查。
    if (rhs->ty == TY_FUNCPTR && rhs->fn_sig != FN_SIG_NONE) {
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
  // ===== v1.7.0 int_64 / v1.9.0 uint_* 的赋值口径（同一套形状：拓宽隐式、收窄必须显式）=====
  //   ① 64 位左值 ← 32/8 位（拓宽）：隐式，**值保持**（有符号源符号扩展、无符号源零扩展）
  //   ② 64 位左值 ← 地址值（指针/&x/ptr 字段…）：**原样**（地址本来就是完整 64 位，不能再包 movsxd）
  //   ③ 32/8 位左值 ← 64 位右值（收窄）：**硬错**（掉高 32 位是这类类型 90% 的静默 bug 来源）
  //   ④ uint_* ↔ double：一律硬错 —— 两条都是"编译过、静默错值"，只留显式转型
  //   ⑤ 同宽互换（int←→uint_32、char←→uint_8）：位型重解释，不饱和、不产码
  if (ty_uns(lhs->ty) && expr_is_dbl(rhs))
    error_at(loc, "不能把 double 赋给 %s（只有显式转型能跨浮点/整数）——"
                  "请写 (%s)值，或改用整数值", ty_name(lhs->ty), ty_name(lhs->ty));
  if (ty_is64(lhs->ty))
    return parse_is_addr_value(rhs) ? rhs : expr_widen_to64(rhs, ty_uns(lhs->ty));
  // 双精度左值：int_64 / uint_64 右值一律硬错（P0/P1 不互转），其余照旧自动提升
  if (is_dbl_node(lhs)) {
    if (expr_is_i64(rhs))
      error_at(loc, "不能把 %s 赋给 double（两者互转只走显式转型）——"
                    "请先显式 (int)值 再赋，或把左值声明成 %s", ty_name(expr_ty_of(rhs)), ty_name(expr_ty_of(rhs)));
    return widen_dbl(rhs);
  }
  if (expr_is_i64(rhs))
    error_at(loc, "不能把 %s 赋给 %s（会静默截断高 32 位：值超出范围的部分丢掉）——"
                  "请显式写 (%s)值，或把左值声明成 %s",
                  ty_name(expr_ty_of(rhs)), ty_name(lhs->ty), ty_name(lhs->ty), ty_name(expr_ty_of(rhs)));
  if (is_dbl_node(rhs))
    error_at(loc, "不能把 double 赋给 int / 整数类型（此处是 %s，会静默截断小数）——"
                  "请显式写 (int)值，或把左值声明成 double", ty_name(lhs->ty));
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
  // v2.13.0：struct 族全局要带上 sid —— `g.a` / `gs[i].a` / `gp->a` 的字段表就是靠 node->struct_idx
  //   查的（普通全局仍是显式 -1，别让 memset 的 0 冒充 struct 0）。
  Node *n = new_var_node(gi, false, g->ty, g->struct_idx, g->elem_ty);
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
static void parse_enumdef(Parser *p, Program *prog); // v2.15.0：enum 定义（预扫描 + 顶层跳 token 共用）
// v1.0.8：print 内建输出语句（print([段, ...] [, 换行])）
static Node *print_stmt(Parser *p);
// v2.0.0：try 错误传播糖（`try <变量> = <表达式>;`）—— 展开成两条已有语句，零 codegen
static Node *try_stmt(Parser *p);
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
                                 bool ret_void, Token **out_name, int *out_arr_len) {
  memset(out, 0, sizeof(*out));
  if (out_arr_len) *out_arr_len = 0;
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
  // ===== v2.6.0：函数指针数组 `int (*ops[2])(int, int)` =====
  //   `[N]` 写在**名字之后、右括号之前**（C 声明符的读法：`(*ops[2])` 是「ops 是 2 个元素的数组，
  //   元素是函数指针」）。N 必须是正整数数字常量——帧槽在 parse 期就要算死，跟 `int a[N]` 同一条口径。
  //   ⚠️ 这个函数被 4 条路共用（变量声明 / 函数形参 / 预扫描 / void 分支），所以数组长度从出口参数
  //   吐给调用方，**不在这里登记变量**：预扫描没有 Parser、也不该分帧槽（老约定，别破坏）。
  int arr_len = 0;
  if (is_punct(t, '[')) {
    t = t->next;
    if (t->kind != TK_NUM)
      error_at(t->loc, "函数指针数组的长度须为数字常量（不支持省略长度 `(*ops[])`，也不是变量/表达式）");
    arr_len = t->val;
    if (arr_len <= 0)
      error_at(t->loc, "函数指针数组长度须为正数（这里写了 %d）", arr_len);
    t = t->next;
    if (!is_punct(t, ']'))
      error_at(t->loc, "函数指针数组长度缺少 ']'（写法：int (*ops[2])(int, int)）");
    t = t->next;
    if (is_punct(t, '['))
      error_at(t->loc, "多维函数指针数组暂不支持（v2.6.0 边界：只开一维 `(*ops[N])(...)`）");
  }
  if (!is_punct(t, ')'))
    error_at(t->loc, "函数指针声明缺少 ')'（要写成 (*名字) 或 (*名字[N])）");
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
      else if (is_ident(t, "int_64") || ty_uns(type_kw_of(t)))
        error_at(t->loc, "函数指针的签名里暂不支持 %s（v1.7.0 P0 边界：FuncSig.param_ty 还没有这一档）"
                         "——请改成 int 形参，或先用普通函数接住", ty_name(type_kw_of(t)));
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
  if (out_arr_len) *out_arr_len = arr_len;
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
    case TY_UINT8: return "uint_8";   // v1.9.0
    case TY_UINT32: return "uint_32";
    case TY_UINT64: return "uint_64";
    case TY_PTR: return "指针";
    case TY_STRUCT: return "struct";
    case TY_FUNCPTR: return "函数指针";
    default: return "?";
  }
}
// ===== v5（`-debug`，D-1）：类型 → **FLINT 写法**（变量位置表的 type 字段）=====
// 与 ty_name 同源：标量名一律走上面那张 switch（同一张表，别在两处各写一份拼写）；
// 这里只补 ty_name 不做的三件事：指针（`T*`）、数组（`T[N]`）、结构体（`struct 名`）。
// 缓冲区由调用方给（DebugVar.type 是 64 字节，这里 cap 至少 64）。
static const char *ty_decl_str(char *buf, size_t cap, int ty, int elem_ty, int elem_ptr_ty,
                               int arr_len, int cols, int struct_idx, Program *prog) {
  char base[48];
  if (ty == TY_STRUCT || (ty == TY_PTR && struct_idx >= 0)) {
    // struct 名：struct 表是唯一真源（parse 时结构体已定义；越界只可能是内部错，退化为 "struct"）
    if (struct_idx >= 0 && struct_idx < prog->nstructs && prog->structs[struct_idx].name)
      snprintf(base, sizeof(base), "struct %s", prog->structs[struct_idx].name);
    else
      snprintf(base, sizeof(base), "struct");
  } else if (ty == TY_ARR && elem_ty == TY_STRUCT && struct_idx >= 0) {
    // v2.13.0：**struct 数组**的调试器写法 `struct E[N]` —— 与 TY_STRUCT+arr_len 那条同形。
    //   漏这一档会经下面的 `ty == TY_ARR` 分支打成 `struct[N]`（ty_name(TY_STRUCT) = "struct"），
    //   调试器就不知道元素是哪个结构体（字段表/槽宽都无从查）。
    if (struct_idx >= 0 && struct_idx < prog->nstructs && prog->structs[struct_idx].name)
      snprintf(base, sizeof(base), "struct %s", prog->structs[struct_idx].name);
    else
      snprintf(base, sizeof(base), "struct");
  } else if (ty == TY_ARR && elem_ty == TY_PTR) {
    // v2.12.0：**指针数组** `char *names[N]` 的调试器写法 `T*[N]`（元素是指针，不是 T）。
    //   漏这一档会打成 `指针[3]`：调试器按 8 字节槽读值没错，但人读不出指向什么。
    snprintf(base, sizeof(base), "%s*", ty_name(elem_ptr_ty));
  } else if (ty == TY_PTR || ty == TY_ARR) {
    snprintf(base, sizeof(base), "%s", ty_name(elem_ty));
  } else if (ty == TY_FUNCPTR) {
    snprintf(base, sizeof(base), "int(*)()");   // 函数指针：FLINT 写法缩写（调试器只按 8 字节地址读）
  } else {
    snprintf(base, sizeof(base), "%s", ty_name(ty));
  }
  if (ty == TY_PTR)      snprintf(buf, cap, "%s*", base);
  else if (ty == TY_ARR && cols > 0) {
    // 二维：`T[行][列]`。先用 128 字节本地缓冲拼，再**显式按 cap 截断**复制 ——
    //   直接 snprintf(buf, cap, "%s[%d][%d]", ...) 会被 -Wformat-truncation 判为可能截断
    //   （base 最多 47 + 两个 %d 各 11 + 4 个括号 = 73 > DebugVar.type 的 64），
    //   而 warn 门要求警告数不增长 ⇒ 格式化与截断分成两步，警告从源头消失。
    char tmp[128];
    int n = snprintf(tmp, sizeof(tmp), "%s[%d][%d]", base, arr_len > 0 ? arr_len : 0, cols);
    if (n < 0) n = 0;
    if ((size_t)n >= cap) n = (int)cap - 1;
    memcpy(buf, tmp, (size_t)n);
    buf[n] = '\0';
  }
  else if (ty == TY_ARR) snprintf(buf, cap, "%s[%d]", base, arr_len > 0 ? arr_len : 0);
  // v2.1.0：struct 数组 `struct S a[N]` 的调试器写法 —— 与 int 数组同一形态 `T[N]`
  //   （不加这一档的话，调试器看到的是 `struct Pair`，会把 4 个元素的块当成单个 struct）
  else if (ty == TY_STRUCT && arr_len > 0) snprintf(buf, cap, "%s[%d]", base, arr_len);
  else                   snprintf(buf, cap, "%s", base);
  return buf;
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
  } else if (rhs->ty == TY_FUNCPTR && rhs->fn_sig != FN_SIG_NONE) {
    // v2.6.0：含函数指针数组元素（ND_DEREF）——右值签名同样要比
    if (!sig_equal(prog, &prog->sigs[lhs->fn_sig], &prog->sigs[rhs->fn_sig]))
      error_at(loc, "函数指针签名不一致：右侧的函数指针与左侧声明的 %s 不是同一套签名",
               sig_desc(prog, lhs->fn_sig));
  }
}


// ===== v2.6.0：函数指针数组的元素左值 = `*(基址 + 下标×8)` =====
// 与 v2.5.0 的 arr_init_elem_stmt 同一条路子（基址 + 下标×元素宽 → ND_DEREF），
// 差别只在元素类型是 TY_FUNCPTR、并且**必须把签名带着走**（fn_sig 是后续赋值/调用检查的唯一来源）。
static Node *fp_arr_elem_lhs(LVar *v, int idx, int sig, char *loc) {
  Node *base = new_var_node(v->offset, false, TY_ARR, -1, TY_FUNCPTR);
  Node *scaled = new_node(ND_MUL, new_num(idx), new_num(ty_arr_stride(TY_FUNCPTR)));
  Node *addr = new_node(ND_ADD, base, scaled);
  Node *lhs = new_node(ND_DEREF, addr, NULL);
  lhs->ty = TY_FUNCPTR;
  lhs->fn_sig = sig;
  lhs->loc = loc;
  return lhs;
}

// ===== v2.6.0：函数指针数组初值的**单个元素** =====
// 收三种写法：`&函数名`（普通表达式路）、**裸函数名**（只有这个位置放行 —— 探针 fp2 就是这么写的，
//   而普通表达式位置仍按既有口径要求写 &）、函数指针变量/函数指针数组元素（签名一致即可）。
// 为什么裸名只在这里开：primary 里「函数名不带括号」是既有明确报错（v1.3.2 口径），
//   全局放宽会动到旧负例；而数组初值是 C 里最自然写裸名的地方，单独在解析器这一格识别风险最小。
static Node *fp_arr_init_one(Parser *p, int sig, Token *arr_tok) {
  Token *t0 = p->tok;
  Node *init = NULL;
  if (t0->kind == TK_IDENT && !is_keyword(t0)
      && !find_lvar(p, t0) && find_func(p->prog, t0) >= 0
      && !(t0->next && is_punct(t0->next, '('))) {
    init = new_node(ND_FUNC_ADDR, NULL, NULL);
    init->func_index = find_func(p->prog, t0);
    init->loc = t0->loc;
    p->tok = t0->next;
  } else {
    init = expr(p);
  }
  if (init->kind == ND_FUNC_ADDR) {
    if (init->func_index < 0 || init->func_index >= p->prog->nfuncs)
      error_at(arr_tok->loc, "内部错误：函数地址下标越界（%d）", init->func_index);
    FuncDef *fn = &p->prog->funcs[init->func_index];
    if (!sig_equal_func(p->prog, &p->prog->sigs[sig], fn))
      error_at(init->loc ? init->loc : arr_tok->loc,
               "函数指针数组的元素签名不一致：'%s' 与数组元素声明的 %s 不是同一套签名",
               fn->name, sig_desc(p->prog, sig));
  } else if (init->ty == TY_FUNCPTR && init->fn_sig != FN_SIG_NONE) {
    if (!sig_equal(p->prog, &p->prog->sigs[sig], &p->prog->sigs[init->fn_sig]))
      error_at(init->loc ? init->loc : arr_tok->loc,
               "函数指针数组的元素签名不一致：右边这个函数指针与数组元素声明的 %s 不是同一套签名",
               sig_desc(p->prog, sig));
  } else {
    error_at(arr_tok->loc,
             "函数指针数组的初值只能是「&函数名」/ 裸函数名 / 函数指针变量"
             "（不能接整数、普通指针、函数调用结果）");
  }
  return init;
}

static Node *decl_funcptr_stmt(Parser *p, int ret_ty, int ret_elem, int ret_struct, bool ret_void) {
  FuncSig s;
  Token *name = NULL;
  int arr_len = 0;
  p->tok = parse_funcptr_decl(&s, p->tok, ret_ty, ret_elem, ret_struct, ret_void, &name, &arr_len);
  if (p->scope_nest != 0)
    error_at(name->loc, arr_len > 0
      ? "函数指针数组暂只支持函数顶层作用域声明（块/循环内 = v2.6.0 边界）"
      : "函数指针暂只支持函数顶层作用域声明（块/循环内 = v1.3.2 边界）");
  int sig = add_sig(p, s);
  // ===== v2.6.0：数组形态 —— 登记成普通 TY_ARR（元素 TY_FUNCPTR，元素签名存 LVar.fn_sig）=====
  //   帧布局 / 下标寻址 / 越界诊断全部复用 int 数组那条路（元素 8 字节槽，见 new_lvar 的槽数算法）。
  if (arr_len > 0) {
    LVar *v = new_lvar(p, name, false, TY_ARR, arr_len, 0, -1, TY_FUNCPTR);
    v->fn_sig = sig;
    if (!consume(p, '=')) return block_of(NULL);
    if (!is_punct(p->tok, '{'))
      error_at(p->tok->loc, "函数指针数组的初始化必须写成 {&函数名, ...}（长度由声明给出，"
                            "不支持单个标量初值，也不支持省略长度）");
    p->tok = p->tok->next;   // 吃 '{'
    if (is_punct(p->tok, '}'))
      error_at(p->tok->loc, "函数指针数组初值不能是空 {}（每个元素都要给一个函数）");
    Node head = {0};
    Node *cur = &head;
    int idx = 0;
    for (;;) {
      if (idx >= arr_len)
        error_at(p->tok->loc, "函数指针数组初值元素比声明长度多（声明 %d 个）", arr_len);
      Node *val = fp_arr_init_one(p, sig, name);
      Node *lhs = fp_arr_elem_lhs(v, idx, sig, name->loc);
      Node *asgn = new_node(ND_ASSIGN, lhs, val);
      asgn->loc = name->loc;
      cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
      idx++;
      if (is_punct(p->tok, ',')) {
        p->tok = p->tok->next;
        if (is_punct(p->tok, '}')) break;   // 允许尾逗号
        continue;
      }
      break;
    }
    if (idx != arr_len)
      error_at(name->loc, "函数指针数组初值需要正好 %d 个元素（这里给了 %d 个）——"
                          "不补零、不省略长度", arr_len, idx);
    skip(p, '}');
    return block_of(head.next);
  }
  LVar *v = new_lvar(p, name, false, TY_FUNCPTR, 0, 0, -1, TY_INT);
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
  } else if (init->ty == TY_FUNCPTR && init->fn_sig != FN_SIG_NONE) {
    // v2.6.0：右边也可以是函数指针数组元素 `ops[i]`（ND_DEREF，签名在节点上）
    rsig = init->fn_sig;
    if (!sig_equal(p->prog, &p->prog->sigs[sig], &p->prog->sigs[rsig]))
      error_at(name->loc, "函数指针签名不一致：右边的函数指针与左边 '%.*s' 声明的 %s 不是同一套签名",
               name->len, name->loc, sig_desc(p->prog, sig));
  } else {
    error_at(name->loc, "函数指针只能由「&函数名」或另一个函数指针初始化"
                        "（不能接整数 / 普通指针 / 结构体字段 / 函数调用结果）");
  }
  Node *asgn = new_node(ND_ASSIGN, var, init);
  asgn->loc = name->loc;
  return block_of(new_node(ND_EXPR_STMT, asgn, NULL));
}

// 间接调用：`fp(实参...)` / v2.6.0 `ops[i](实参...)` —— 按签名表做「个数 / 双通道 / 传地址」三条检查，
// 与直接调用（primary 里的函数名分支）**逐条同口径**，否则同一份源码换个调用方式就静默传错寄存器。
// v2.6.0：核心改为收**目标表达式节点**（变量 / 数组元素都行），p->tok 一律在 '(' 上。
static Node *parse_indirect_call_core(Parser *p, Node *target, int sig, Token *nm) {
  FuncSig *s = &p->prog->sigs[sig];
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
        // v2.6.0：函数指针数组元素（ND_DEREF，签名在节点上）与变量同一条检查
        if (arg->ty == TY_FUNCPTR && arg->fn_sig != FN_SIG_NONE) {
          if (want != FN_SIG_NONE
              && !sig_equal(p->prog, &p->prog->sigs[want], &p->prog->sigs[arg->fn_sig]))
            error_at(nm->loc, "实参的函数指针签名与该形参不一致（形参需要 %s）——"
                              "右边这个函数指针是另一套签名", sig_desc(p->prog, want));
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
  call->fn_sig = sig;
  call->nargs = nargs;
  call->is_void = s->ret_void;
  call->ty = s->ret_void ? TY_INT : s->ret_ty;
  call->elem_ty = s->ret_elem;
  call->struct_idx = s->ret_struct;
  call->loc = nm->loc;
  // v2.6.0：目标**不是局部变量**（= 函数指针数组元素）时，codegen 没法用 [rbp-off] 一步装载。
  //   分一个**匿名帧槽**（不进作用域/不查重名，同 i64_compound 的做法）：codegen 在求实参**之前**
  //   先把目标表达式算进这个槽，等实参全部就位后再从槽里装 rax —— 目标表达式里的函数调用/寄存器
  //   使用就绝不会打乱已经摆好的实参寄存器（顺序是硬约束，见 gen_call 间接调用那段的注释）。
  if (target->kind != ND_VAR) {
    if (!p->scope)
      error_at(nm->loc, "内部错误：函数指针数组的间接调用出现在函数体外");
    if ((long long)p->next_offset + 8LL > 0x7FFFFFFFLL)
      error_at(nm->loc, "变量/数组/结构体总长过大（帧槽累计超 2GB 上限）");
    call->fp_tmp = p->next_offset;
    p->next_offset += 8;
    p->var_count += 1;
  }
  return call;
}

static Node *parse_indirect_call(Parser *p, LVar *fp) {
  Token *nm = p->tok;
  Node *target = new_var_node(fp->offset, false, TY_FUNCPTR, -1, TY_INT);   // 调用目标（codegen 装 rax）
  target->fn_sig = fp->fn_sig;
  p->tok = p->tok->next;              // 吃变量名
  return parse_indirect_call_core(p, target, fp->fn_sig, nm);
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
// 引用 → ND_REF_BIND（r 槽存 x 地址）；v2.5.0 起局部 int 数组支持 `= {v0, v1, ...}` 整体初始化。

// ===== v2.5.0（2026-11-01）：局部 int 数组整体初始化的**单元素展开** =====
// 造 `a[idx] = val;` 这条**既有**赋值语句（ND_ASSIGN(ND_DEREF(ND_ADD(基址, idx*元素宽)))）——
// 与 postfix 给 `a[i]` 生成的形态逐字同形 ⇒ codegen 一行不改，宽度/T1/double 门槛全部沿用。
//   · 元素宽走单点表 ty_arr_stride（int = 4 字节；实测钉死见 tmp\stride_probe.fl：
//     `int *p = a; p+4; *p=22` 能写进 a[1] ⇒ 步长 4，槽仍是 8 字节基址单位）。
//   · 二维数组同理：帧里本来就是 row-major 连续块，整体初始化按**一维线性下标**填
//     （`int m[2][2] = {1,2,3,4}` ⇔ m[0][0..1], m[1][0..1]；**不做**嵌套大括号）。
static Node *arr_init_elem_stmt(LVar *v, int idx, Node *val, char *loc) {
  Node *base = new_var_node(v->offset, false, TY_ARR, -1, v->elem_ty);
  Node *scaled = new_node(ND_MUL, new_num(idx), new_num(ty_arr_stride(v->elem_ty)));
  Node *addr = new_node(ND_ADD, base, scaled);
  Node *lhs = new_node(ND_DEREF, addr, NULL);
  lhs->ty = v->elem_ty;
  Node *rhs = asgn_rhs(lhs, val, loc);          // double→int 这类静默截断照旧被拦
  Node *asgn = new_node(ND_ASSIGN, lhs, rhs);
  asgn->loc = loc;
  return new_node(ND_EXPR_STMT, asgn, NULL);
}
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
    int cols = 0;                         // v2.2.0：二维数组列数（0 = 一维）
    bool is_ptr_arr = false;              // v2.12.0：`char *names[N]` = 元素为 8 字节指针的数组
    if (is_punct(p->tok, '[')) {          // char a[N] / int a[5] / char *names[3]
      // v2.12.0：**指针数组**放行（`char *names[3]` / `int *ps[4]` / `double *ds[2]`）。
      //   元素类型 = TY_PTR（宽度 8 / 步长 8 / 8 字节读写都由既有 TY_PTR 通路承担），
      //   指向类型另存 LVar.elem_ptr_ty（见该字段的注释）。
      //   引用仍不能带数组（`int &a[3]` 本来就没有可绑定的对象），文案保持原样。
      if (ref)
        error_at(p->tok->loc, "数组暂不能与 &/* 组合（v0.7 单修饰符）");
      p->tok = p->tok->next;
      // v2.15.0（G7）：长度 = 编译期常量（字面量 / enum 常量 / 常量表达式）；变量/调用仍硬错
      Token *len_tok = p->tok;
      long long lenv = 0;
      if (!parse_const_int(p, &lenv))
        error_at(len_tok->loc, "数组长度须为数字常量（字面量 / enum 常量 / 常量表达式）"
                               "——变量、函数调用、运行期量都不行（帧槽在 parse 期就得算死）");
      if (lenv <= 0) error_at(len_tok->loc, "数组长度须为正数（得到 %lld）", lenv);
      if (lenv > 2147483647LL)
        error_at(len_tok->loc, "数组长度过大（%lld；上限 2147483647）", lenv);
      arr_len = (int)lenv;
      skip(p, ']');
      ty = TY_ARR;
      if (ptr) {
        is_ptr_arr = true;
        elem = TY_PTR;            // 元素 = 指针（8 字节槽；不是 base_ty 的 1/4/8 元素宽）
        if (is_punct(p->tok, '['))
          error_at(p->tok->loc, "指针数组暂不支持二维（v2.12 边界：只开一维 char *a[N] / int *a[N]）");
      } else {
      // ===== v2.2.0：二维数组 `int m[行][列];`（只开局部 int；char/double/全局/形参都不做）=====
      //   语义 = row-major 一维化：m[i][j] ≡ m[i*cols + j]（越界不检查，与一维数组同口径）。
      //   落地 = parse 期把第二维折成一维线性下标（见 postfix），**codegen 零改动**。
      //   行列两个维度都必须编译期字面量：帧槽在 parse 期就得算死（与一维数组同一条理由）。
      if (is_punct(p->tok, '[')) {
        if (base_ty != TY_INT)
          error_at(p->tok->loc, "二维数组暂只支持 int（%s 不做——char/double 的整块布局还没定）",
                   ty_name(base_ty));
        p->tok = p->tok->next;
        // v2.15.0（G7）：列数同样接受编译期常量表达式
        Token *col_tok = p->tok;
        long long colv = 0;
        if (!parse_const_int(p, &colv))
          error_at(col_tok->loc, "二维数组的列数须为数字常量（字面量 / enum 常量 / 常量表达式）"
                                 "——变量、函数调用、运行期量都不行（帧槽在 parse 期就得算死）");
        if (colv <= 0) error_at(col_tok->loc, "二维数组的列数须为正数（得到 %lld）", colv);
        if (colv > 2147483647LL)
          error_at(col_tok->loc, "二维数组的列数过大（%lld；上限 2147483647）", colv);
        cols = (int)colv;
        skip(p, ']');
        if (is_punct(p->tok, '['))
          error_at(p->tok->loc, "三维数组暂不支持（只开二维 int m[行][列]）");
      }
      }   // end !is_ptr_arr
    }
    // v1.0.5 已知边界：char 引用（&c 别名读写需解引用字节宽度，未入）与 char own/share（堆对象仅 int）暂拒
    if (ref && ty_is8(base_ty))
      error_at(name->loc, "%s 引用暂不支持（可用 %s* 指针或 &c 取址）", ty_name(base_ty), ty_name(base_ty));
    // v1.7.0：int_64 引用暂不支持 —— 引用读走 32 位解引用（emit_deref_eax），会把高 32 位静默丢掉。
    //   要别名 64 位值请用 int_64 *（指针在本版已开，读写走 8 字节）。v1.9.0：uint_64 同理。
    if (ref && ty_is64(base_ty))
      error_at(name->loc, "%s 引用暂不支持（引用读是 32 位解引用，会静默截断）——"
                          "请用 %s *p = &x; 显式指针", ty_name(base_ty), ty_name(base_ty));
    if ((is_uni || is_sh) && ty_is8(base_ty))
      error_at(name->loc, "'own'/'share' 只能修饰 int*（%s 无堆所有权语义）", ty_name(base_ty));
    LVar *v = new_lvar(p, name, ref, ty, arr_len, cols, -1, elem);
    if (is_ptr_arr) v->elem_ptr_ty = base_ty;   // v2.12.0：元素指针的指向类型（char*/int*/double*…）
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
      // ===== v2.5.0（2026-11-01）：局部 int 数组整体初始化 `int a[N] = {v0, v1, ...};` =====
      //   语义 = 逐元素赋值（parse 期展开成 ND_ASSIGN 语句链，见 arr_init_elem_stmt）；
      //   元素数 k ≤ N，不足 N 的**补 0**（C 口径），k > N 编译期硬错；元素只收 int 表达式
      //   （负号 / enum 常量 / 简单算式都走既有 expr）。
      //   边界（明确不做，保持响亮报错）：char/double/int_64 数组、struct 数组、字符串初始化、
      //   省略长度 `int a[] = {...}`、嵌套大括号；全局数组的 `{..}` 走 .data 的独立通路
      //   （parse_global_init，本分支只负责函数体内的局部声明）。
      if (consume(p, '=')) {
        // v2.12.0：指针数组同一条初始化通路（元素 = 8 字节指针，初值收地址值/字符串字面量/0）。
        if (base_ty != TY_INT && !is_ptr_arr)
          error_at(p->tok->loc, "数组暂不支持整体初始化（只开了局部 int 数组；%s 数组的整块布局未定）",
                   ty_name(base_ty));
        if (!is_punct(p->tok, '{'))
          error_at(p->tok->loc, is_ptr_arr
                   ? "指针数组整体初始化必须写成 {\"串\", &x, ...}（数组没有标量初值语义）"
                   : "int 数组整体初始化必须写成 {v0, v1, ...}（数组没有标量初值语义）");
        int nelem = (cols > 0) ? arr_len * cols : arr_len;   // 二维按 row-major 一维总数
        p->tok = p->tok->next;                                 // 吃 '{'
        if (is_punct(p->tok, '}'))
          error_at(p->tok->loc, "数组初值不能是空 {}（至少写一个元素；全零请写 {0}）");
        int idx = 0;
        for (;;) {
          if (idx >= nelem)
            error_at(p->tok->loc, "数组初值元素比声明长度多（声明 %d 个）", nelem);
          Node *val = expr(p);
          cur = cur->next = arr_init_elem_stmt(v, idx, val, name->loc);
          idx = idx + 1;
          if (is_punct(p->tok, ',')) {
            p->tok = p->tok->next;
            if (is_punct(p->tok, '}')) break;                  // 允许尾逗号
            continue;
          }
          break;
        }
        skip(p, '}');
        for (; idx < nelem; idx++)                             // 不足 N：补 0（C 口径）
          cur = cur->next = arr_init_elem_stmt(v, idx, new_num(0), name->loc);
        had_init = true;
      }
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
    if (!had_init && (ty_isint(ty) || ty == TY_DOUBLE
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
  // v2.7.0：语句嵌套的**唯一**计数点。块 `{{{...}}}`、`if (1) if (1) ...`、while/for/switch 体
  //   都从这里递归回 stmt；平铺语句逐条进出、depth 立刻还原，不会累积。
  //   原来只加在 stmt_inner 的 '{' 分支，漏了无花括号的 if/while 链（深层仍会 0xC00000FD）。
  //   error_at 自己 exit(1)，报错路径不需要回退 depth。
  p->depth = p->depth + 1;
  if (p->depth > PARSE_MAX_DEPTH)
    error_at(p->tok->loc, "嵌套过深（上限 %d 层）：括号或语句块套得太深，请拆成变量/函数", PARSE_MAX_DEPTH);
  Node *n = stmt_inner(p);
  p->depth = p->depth - 1;
  g_stmt_loc = saved;
  return n;
}

static Node *stmt_inner(Parser *p) {
  Node *node;

  // return [表达式]; —— v0.6：void 函数可 return;（无表达式）
  if (is_ident(p->tok, "return")) {
    p->tok = p->tok->next;
    if (consume(p, ';')) {
      if (p->fn_ret_struct >= 0)
        error_at(p->tok->loc, "struct 按值返回的函数必须 `return <同类型 struct 值>;`"
                              "（`return;` 只能用在 void 函数）");
      if (!p->fn_ret_void)
        error_at(p->tok->loc, "'return;' 只能用在 void 函数");
      return new_node(ND_RETURN, NULL, NULL);
    }
    if (p->fn_ret_void)
      error_at(p->tok->loc, "void 函数不能 return 表达式");
    // ===== v2.14.0（struct 值语义第四刀）：**struct 按值返回**的 return =====
    //   只开两种右值形态（其余一律响亮报错，绝不静默发一条没有缓冲的 call）：
    //     ① `return v;` / `return q.inner;` —— 同一 struct 的变量/字段（地址链，按 size 字节搬到隐藏缓冲）；
    //     ② `return f();` —— f 也是按值返回 struct（把**本函数的**隐藏缓冲地址转交给 f，零额外拷贝）。
    //   `return (a = b);` 这类复合表达式不支持：赋值结点不是地址链（先赋给变量再 return）。
    if (p->fn_ret_struct >= 0) {
      Token *rt0 = p->tok;
      Node *e = expr(p);
      if (!e || e->ty != TY_STRUCT)
        error_at(rt0->loc, "struct 按值返回要求 return 的值是 struct %s 类型（这里给的是 %s）",
                 p->prog->structs[p->fn_ret_struct].name, ty_name(e ? expr_ty_of(e) : TY_INT));
      if (e->struct_idx != p->fn_ret_struct)
        error_at(rt0->loc, "struct 按值返回要求 return **同一个** struct 类型（本函数返回 struct %s，"
                           "这里给的是 struct %s）——不同类型布局不同，不能逐字节搬",
                 p->prog->structs[p->fn_ret_struct].name,
                 e->struct_idx >= 0 ? p->prog->structs[e->struct_idx].name : "?");
      if (e->kind == ND_CALL) {
        if (e->func_index < 0 || p->prog->funcs[e->func_index].ret_ty != TY_STRUCT)
          error_at(rt0->loc, "return 的调用结果不是**按值返回 struct** 的函数（只有 struct S f() 形态"
                             "能把返回值直接转交给调用者的缓冲）");
        sret_attach_arg(e, sret_retbuf_addr(p, e));
        skip(p, ';');
        return new_node(ND_RETURN, e, NULL);
      }
      // 只认**地址链**：ND_VAR（变量/引用/全局）与 ND_ADD（字段/数组元素的地址链）。
      //   `*sp`（ND_DEREF，ty=TY_STRUCT）不在此列：解引用读那一路按「值宽」取数（TY_STRUCT
      //   会落到 32 位兜底），拿它当 struct 本体地址是错的 —— 明确拒收，别静默搬错地址。
      if (e->kind != ND_VAR && e->kind != ND_ADD)
        error_at(rt0->loc, "struct 按值返回的 return 只支持「return <struct 变量/字段/数组元素>;」或"
                           "「return <同类型按值返回函数调用>;」——"
                           "`return (a = b);` / `return *sp;` / `return f().x;` 这类形态暂不支持，"
                           "请先赋给变量再 return");
      skip(p, ';');
      return new_node(ND_RETURN, e, NULL);
    }
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
    // v1.9.0：uint_64 同一条通道（拓宽时按**源侧符号性**取值保持）
    if (!p->fn_ret_void && ty_is64(p->fn_ret_ty) && e) {
      if (expr_is_dbl(e))
        error_at(rt0->loc, "不能把 double 值 return 给 %s 返回函数（两者互转只走显式转型）",
                 ty_name(p->fn_ret_ty));
      e = parse_is_addr_value(e) ? e : expr_widen_to64(e, ty_uns(p->fn_ret_ty));
    } else if (!p->fn_ret_void && e && expr_is_i64(e)) {
      error_at(rt0->loc, "不能把 %s 值 return 给 %s 返回函数（会静默截断高 32 位："
                         "值超出范围的部分丢掉）——"
                         "请显式转型，或把返回类型改成 %s",
                 ty_name(expr_ty_of(e)), ty_name(p->fn_ret_ty), ty_name(expr_ty_of(e)));
    }
    return new_node(ND_RETURN, e, NULL);
  }

  // v2.0.0：try 错误传播糖 —— 只认 `try <ident> ...` 这一格（`try` 仍可作普通变量名：
  //   `try = 5;` 不进入这里）。`try a[0] = ...` 也进来，但由 try_stmt 给清晰错误。
  if (is_ident(p->tok, "try") && p->tok->next && p->tok->next->kind == TK_IDENT
      && !is_keyword(p->tok->next)) {
    return try_stmt(p);
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

  // 标量声明符列表;（int / int_32 / int_64 / char / uint_8 / uint_32 / uint_64）
  //   v1.9.0：类型关键字一律走 type_kw_int 这张单点表 —— 漏一处 = 那个类型静默当 int 处理。
  //   （原先是 int_64 / int / char 三个各自手抄的 is_ident 链，加类型时必须每处都改。）
  if (type_kw_int(p->tok) >= 0) {
    int base = type_kw_int(p->tok);
    p->tok = p->tok->next;
    node = decl_list(p, base);
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
    // ===== 2026-10-24（v2.2）：struct 指针变量 `struct S *p;` / `struct S *p = &a[i];` =====
    //   原来**只有形参**能写 `struct S *p`，局部变量一律落进「期望变量名」（写库时的实测缺口）。
    //   这里补声明 + 可选初值（初值必须是地址值，T1 口径与 int* 完全同一条）。
    if (is_punct(p->tok, '*')) {
      p->tok = p->tok->next;
      Token *pn = p->tok;
      if (pn->kind != TK_IDENT || is_keyword(pn))
        error_at(pn->loc, "期望变量名（struct 指针请写 struct S *p;）");
      p->tok = p->tok->next;
      LVar *pv = new_lvar(p, pn, false, TY_PTR, 0, 0, sidx, TY_INT);
      Node *head = NULL;
      if (consume(p, '=')) {
        Token *eq = p->tok;
        Node *init = expr(p);
        if (!parse_is_addr_value(init))
          error_at(eq->loc, "struct 指针的初值必须是地址值（&变量 / &a[i] / 指针变量 / new / 字符串）——"
                            "T1 口径：地址值与 int 不能互相装");
        Node *vr = new_var_node(pv->offset, false, TY_PTR, sidx, TY_INT);
        head = new_node(ND_EXPR_STMT, new_node(ND_ASSIGN, vr, init), NULL);
      }
      skip(p, ';');
      return block_of(head);
    }
    Token *vn = p->tok;
    if (vn->kind != TK_IDENT || is_keyword(vn))
      error_at(vn->loc, "期望变量名");
    // ===== v2.1.0：局部 struct 数组 `struct S a[N];` =====
    //   长度口径与 `int a[N]` **一字不差**（正整数数字常量；0 / 变量 / 表达式一律编译期硬错）。
    //   元素步长 = 8*ceil(size/8) 由 new_lvar 的槽数单点决定（见那里的注释）；下标在 postfix 里
    //   摊平成地址链 `基址 + i*步长`，字段访问复用既有 `.` 字段通路（D11：不新增 codegen 通路）。
    int sarr = 0;
    if (is_punct(p->tok->next, '[')) {
      p->tok = p->tok->next;   // '['
      p->tok = p->tok->next;
      // v2.15.0（G7）：与 int a[N] 同一口径 —— 编译期常量（字面量 / enum 常量 / 常量表达式）
      Token *slen_tok = p->tok;
      long long slenv = 0;
      if (!parse_const_int(p, &slenv))
        error_at(slen_tok->loc, "struct 数组长度须为数字常量（与 int a[N] 同口径；"
                                "字面量 / enum 常量 / 常量表达式）——变量、函数调用都不行");
      if (slenv <= 0) error_at(slen_tok->loc, "struct 数组长度须为正数（得到 %lld）", slenv);
      if (slenv > 2147483647LL)
        error_at(slen_tok->loc, "struct 数组长度过大（%lld；上限 2147483647）", slenv);
      sarr = (int)slenv;
      skip(p, ']');
    }
    LVar *sv = new_lvar(p, vn, false, TY_STRUCT, sarr, 0, sidx, TY_INT);   // 登记变量
    if (sarr > 0) {   // 数组形态：p->tok 已越过 ']'（不消费变量名 token）
      if (consume(p, '='))
        error_at(p->tok->loc, "struct 数组暂不支持整体初始化（逐元素 a[i].字段 = 值）");
      skip(p, ';');
      return block_of(NULL);
    }
    p->tok = p->tok->next;
    // ===== v2.9.0（struct 值语义第一刀）：`struct E e = {0};` 与 `struct E b = a;` =====
    //   只开这两条，布局/ABI 一个字节不动：
    //     · {0} = 把目标本体的 size 字节清零（C 的 {0} 语义；不是通用初始化列表）；
    //     · 变量初始化 = 同一 struct 类型的**字节浅拷贝**（指针字段复制指针值，嵌套值字段整块覆盖）。
    //   两种形态都摊平成一条语句节点（ND_STRUCT_ZERO / ND_STRUCT_COPY），codegen 里各只加一个发射器。
    Node *init_stmt = NULL;
    if (consume(p, '=')) {
      char *eq_loc = p->tok->loc;   // 右值起点（报错 caret）
      Node *dst = new_var_node(sv->offset, false, TY_STRUCT, sidx, TY_INT);
      dst->loc = vn->loc;
      if (is_punct(p->tok, '{')) {
        Token *lb = p->tok;
        p->tok = p->tok->next;   // 吃 '{'
        if (is_punct(p->tok, '}'))
          error_at(lb->loc, "空初始化列表 {} 不接受——C 的 {0} 才表示「全字段清零」，请写 {0}");
        if (p->tok->kind != TK_NUM || p->tok->val != 0)
          error_at(p->tok->loc, "结构体整体初始化只支持 {0}（全字段清零）——"
                                "{v0, v1, ...} 这种通用初始化列表暂不支持，请声明后逐字段赋值");
        p->tok = p->tok->next;   // 吃 0
        if (!is_punct(p->tok, '}'))
          error_at(p->tok->loc, "结构体整体初始化只支持**恰好一个 0** 的 {0}——"
                                "通用初始化列表暂不支持，请声明后逐字段赋值");
        p->tok = p->tok->next;   // 吃 '}'
        Node *z = new_node(ND_STRUCT_ZERO, dst, NULL);
        z->ty = TY_STRUCT;
        z->struct_idx = sidx;
        z->loc = eq_loc;
        init_stmt = new_node(ND_EXPR_STMT, z, NULL);
      } else {
        Node *src = assign(p);
        if (src->ty != TY_STRUCT)
          error_at(eq_loc, "结构体初始化右边必须是**同一个 struct 类型**的值（这里给的是 %s）——"
                           "全零请写 {0}；要搬字段请声明后逐字段赋值",
                   ty_name(expr_ty_of(src)));
        if (src->struct_idx != sidx)
          error_at(eq_loc, "结构体整体拷贝要求两边是**同一个 struct 类型**"
                           "（不同 struct 的布局/字段不同，不能逐字节搬）——请逐字段赋值");
        Node *cp = new_node(ND_STRUCT_COPY, dst, src);
        cp->ty = TY_STRUCT;
        cp->struct_idx = sidx;
        cp->loc = eq_loc;
        // v2.14.0：右值是「按值返回 struct 的函数调用」⇒ 把目标变量的地址补成隐藏首参
        //   （被调方直接写进这个变量；codegen 的 gen_struct_copy 见到这种 rhs 只发 call，不再回拷）。
        if (src->kind == ND_CALL) sret_attach_arg(src, sret_dst_addr(dst));
        init_stmt = new_node(ND_EXPR_STMT, cp, NULL);
      }
    }
    skip(p, ';');
    return block_of(init_stmt);
  }

  // 块 { 语句* }（新作用域）
  // v2.7.0：这里的嵌套由 stmt() 包装层统一计数（块内每条语句都经 stmt 递归），本分支不再单独计。
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
    if (type_kw_int(p->tok) >= 0 && !is_ident(p->tok, "double")) {
      int fbase = type_kw_int(p->tok);   // v1.7.0：for 头可声明 int_64；v1.9.0：uint_*
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
    // v1.7.0：switch 的排表是 32 位（cmp eax,imm32）⇒ 64 位条件会静默截断，明确报错
    //   （v1.9.0：uint_32 可以——32 位相等比较与符号性无关；uint_64 同 int_64 一律拒）
    if (expr_is_i64(cond))
      error_at(cd0->loc, "switch 的条件暂不支持 64 位整数（int_64/uint_64；v1.7.0 P0 边界：跳转表是 32 位比较）——"
                         "请先显式收窄，或改写成 if/else 链");
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
          // v2.15.0（G5）：case 标签 = 整数字面量（可带 +/-）**或 enum 常量**。
          //   刻意不收常量表达式：`case 1 + 1:` 仍走下面 ':' 的硬错（run-tests 的既有判据）。
          long long cv = 0;
          bool got = false;
          if (p->tok->kind == TK_NUM) {
            cv = p->tok->val;
            p->tok = p->tok->next;
            got = true;
          } else if (p->tok->kind == TK_IDENT) {
            int ei = find_enum(p->prog, p->tok);
            if (ei >= 0) {
              cv = p->prog->enums[ei].value;
              p->tok = p->tok->next;
              got = true;
            }
          }
          if (!got)
            error_at(p->tok->loc, "case 标签必须是整型常量（case 3: / case -1: / case 'a': / case 枚举常量:）"
                                  "——变量、函数调用、case 1 + 1 这类表达式都不行（switch 要在编译期排跳转表）");
          v = neg ? -(int)cv : (int)cv;
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
  // v2.6.0：判据从「ND_VAR / ND_FUNC_ADDR」放宽到**任何 TY_FUNCPTR 值**（含函数指针数组元素
  //   ops[i]），否则元素落到下面的整数通路 = 签名与 64 位地址一起被静默丢掉。
  if (a->ty == TY_FUNCPTR || b->ty == TY_FUNCPTR)
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
  // v1.9.0：改用通常算术转换 —— `uint_32 ? a : b` 两支无符号 ⇒ 结果仍 uint_32（符号性不能丢）
  int trt = usual_arith_ty(expr_ty_of(a), expr_ty_of(b));
  if (ty_is64(trt)) {
    n->rhs = expr_widen_to64(a, ty_uns(trt));
    n->els = expr_widen_to64(b, ty_uns(trt));
    n->ty = trt;
    return n;
  }
  n->ty = ty_isint(trt) ? trt : TY_INT;   // char/uint_8 提升为 int（同「char 参与运算」的既有口径）
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
      // v2.9.0：struct 只有「整体拷贝」一种写操作 —— 复合赋值没有 C 语义（不能 b += a）
      if (node->kind == ND_VAR && node->ty == TY_STRUCT)
        error_at(p->tok->loc, "struct 不支持复合赋值（结构体只支持整体拷贝 b = a; 与 {0} 零初始化）");
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
    // ===== v2.9.0（struct 值语义第一刀）：`b = a;` 整体字节拷贝 =====
    //   只认「目标 = 结构体变量（含 struct 引用形参）」。`a[0] = b` / `p.inner = q` 这类
    //   元素/字段整体赋值仍**不**开（它们不是 ND_VAR 左值，照旧报下面的错）——本刀边界。
    bool struct_var = (node->kind == ND_VAR && node->ty == TY_STRUCT);
    char *rhs_loc = p->tok->loc;
    if (!struct_var && !is_lvalue(node))
      error_at(p->tok->loc, "赋值左边必须是变量或 *p/a[i]");
    if (node->kind == ND_VAR && (node->is_own || node->is_share))
      error_at(p->tok->loc, "own/share 指针不能重新赋值（所有权由声明初始化 + 出口自动释放管理）");
    // v1.5.0：str([...]) 作赋值右值 —— 这里**不再放行**（改由 stmt_inner 的语句级展开处理：
    //   `s = str([...]);` 必须先按语句形态识别，才不会把缓冲复位夹进表达式求值序里）。
    //   于是 `x = str([...])`（x 不是指针）等写法直接落到 primary 的响亮报错。
    Node *rhs = assign(p);
    if (struct_var) {
      if (rhs->ty != TY_STRUCT)
        error_at(rhs_loc, "struct 整体赋值右边必须是**同一个 struct 类型**的值（这里给的是 %s）——"
                          "结构体没有整体值语义，只有同类型逐字节拷贝",
                 ty_name(expr_ty_of(rhs)));
      if (rhs->struct_idx != node->struct_idx)
        error_at(rhs_loc, "struct 整体赋值要求两边是**同一个 struct 类型**"
                          "（不同 struct 的布局/字段不同，不能逐字节搬）——请逐字段赋值");
      Node *cp = new_node(ND_STRUCT_COPY, node, rhs);
      cp->ty = TY_STRUCT;
      cp->struct_idx = node->struct_idx;
      cp->loc = rhs_loc;
      // v2.14.0：`p = mk(...)` —— 同上，目标地址补成隐藏首参（右值是指针字段/元素调用时同一条）
      if (rhs->kind == ND_CALL) sret_attach_arg(rhs, sret_dst_addr(node));
      return cp;   // 语句位置使用；FLINT 仍无 struct 整体值语义（别当值用）
    }
    if (rhs->kind == ND_VAR && (rhs->is_own || rhs->is_share))
      error_at(p->tok->loc, "own/share 指针不能拷贝给其他变量（share 拷贝请用 int *share q = p; 初始化）");
    if (flint_safe_mode && subtree_has_new(rhs))
      error_at(p->tok->loc, "安全模式（-safe）：new 结果必须由 own/share 接管（裸指针持有会泄漏）");
    rhs = asgn_rhs(node, rhs, p->tok->loc);   // v1.1.0：double 左值接 int 右值自动提升；反向必须 to_int
    funcptr_check_asgn(p->prog, node, rhs, p->tok->loc);   // v1.3.2：函数指针签名一致性
    node = new_node(ND_ASSIGN, node, rhs);
    // v1.9.0：无符号左值 ⇒ 赋值表达式的值类型就是左值类型（`(u = 5) + 1` 才不会被当 int）
    if (ty_uns(node->lhs->ty)) node->ty = node->lhs->ty;
    node->loc = p->tok->loc;   // v1.0.13：T1 报错定位（指向右值起点，报错时 caret 落在被赋的值上）
  }
  return node;
}

// ===== v1.9.0：C 的通常算术转换（C11 6.3.1.1/6.3.1.8）=====
// 整数提升：char / uint_8 的值域（0..255）被 int 全部装得下 ⇒ 一律先提升到 int。
static int int_promote(int t) { return ty_is8(t) ? TY_INT : t; }
// 二元算术/比较/位运算的**结果类型**。三条口径（与 SPEC「uint_* 语义」表逐条对应）：
//   ① 同宽混合：任一侧无符号 ⇒ 无符号胜（int + uint_32 → uint_32；int_64 + uint_64 → uint_64）
//   ② 不同宽：更宽者胜。int_64 能装下 uint_32 的全部值（2^32-1 < 2^63）⇒ uint_32 + int_64 → int_64
//   ③ uint_64 与任何 32 位侧 ⇒ uint_64（C 同此：uint_64 压过 int）
static int usual_arith_ty(int a, int b) {
  if (a == TY_DOUBLE || b == TY_DOUBLE) return TY_DOUBLE;
  a = int_promote(a);
  b = int_promote(b);
  int ra = ty_rank(a), rb = ty_rank(b);
  if (ra == rb) {
    if (ty_uns(a)) return a;
    if (ty_uns(b)) return b;
    return a;
  }
  return ra > rb ? a : b;
}
static bool kind_is_cmp(NodeKind k) {
  return k == ND_EQ || k == ND_NE || k == ND_LT || k == ND_LE || k == ND_GT || k == ND_GE;
}
static bool kind_is_arith(NodeKind k) {
  return k == ND_ADD || k == ND_SUB || k == ND_MUL || k == ND_DIV;
}

// ===== v2.8.0（B 阶段①）：常量折叠（只在 parse 层；codegen 一行未改、不知道有这回事）=====
// 纪律（保守版）：
//   ① 只折「两侧都是 ND_NUM 字面量」的节点 ⇒ 天然不可能丢副作用（调用/赋值/++/-- 都不是 ND_NUM）；
//      `1 && f()` 右侧不是字面量 ⇒ 不折，短路语义原样保留；
//   ② 不做常量传播（`int x = 5; x + 1` 不折）、不做代数化简（`x*0` / `x*1` 不碰）；
//   ③ 折叠值必须与**运行期实际发射的指令**逐位一致 —— 口径逐条对着 codegen 的发射器：
//      · int 是 32 位、溢出回绕（add/sub/imul/neg 的 32 位形态）⇒ 一律用 uint32_t 算再转回 int；
//      · `/` `%` 走 cdq+idiv：向零截断、余数随被除数符号 ⇒ 用 int64 算（32 位域内精确），
//        **除数为 0、或 INT_MIN / -1（idiv 溢出 #DE）一律不折** —— 折了等于把运行期崩溃变成静默值；
//      · `<<` `>>` 走 shl/sar eax,cl：x86 只取 cl 的低 5 位 ⇒ 折叠按 count & 31（不是 C 的 UB 口径）；
//        `>>` 是**算术**右移（sar，符号位补齐），不借 C 的实现定义行为；
//      · 比较走 setcc+movzx、`&&` `||` 走 gen_logand/gen_logor ⇒ 结果都是 0/1（不是操作数本身）；
//      · 一元 `-`/`~`/`!` 同理，只在操作数是 ND_NUM 时折。
//   ④ ND_NUM 恒为 TY_INT（new_num 不刻别的类型）⇒ 只有 int 语义进得来；
//      ND_NUM64（>2^31-1 的字面量）**故意不折**（64 位语义另立一门，不在本轮）。
#define FOLD_INT_MIN (-2147483647 - 1)

static int fold_shl32(int a, int b) {
  return (int)((uint32_t)a << (unsigned)(b & 31));    // 对齐 shl eax,cl（cl 低 5 位）
}
static int fold_sar32(int a, int b) {
  int c = b & 31;
  if (c == 0) return a;
  uint32_t u = (uint32_t)a;
  if (a >= 0) return (int)(u >> c);                    // 非负：逻辑右移与算术右移相同
  return (int)((u >> c) | (~(uint32_t)0 << (32 - c))); // 负数：显式补符号位（sar）
}

// 二元折叠：命中返回 true 并写 *out（调用方返回 new_num(*out)）。未命中 = 原样建节点。
static bool fold_bin_const(NodeKind kind, Node *lhs, Node *rhs, int *out) {
  if (!lhs || !rhs || lhs->kind != ND_NUM || rhs->kind != ND_NUM) return false;
  int a = lhs->val, b = rhs->val;
  switch (kind) {
    case ND_ADD: *out = (int)((uint32_t)a + (uint32_t)b); return true;
    case ND_SUB: *out = (int)((uint32_t)a - (uint32_t)b); return true;
    case ND_MUL: *out = (int)((uint32_t)a * (uint32_t)b); return true;
    case ND_DIV:
      if (b == 0 || (a == FOLD_INT_MIN && b == -1)) return false;   // 运行期是 #DE 崩 ⇒ 不折
      *out = (int)((long long)a / (long long)b);
      return true;
    case ND_MOD:
      if (b == 0 || (a == FOLD_INT_MIN && b == -1)) return false;
      *out = (int)((long long)a % (long long)b);
      return true;
    case ND_SHL: *out = fold_shl32(a, b); return true;
    case ND_SHR: *out = fold_sar32(a, b); return true;
    case ND_BITAND: *out = a & b; return true;
    case ND_BITOR:  *out = a | b; return true;
    case ND_BITXOR: *out = a ^ b; return true;
    case ND_EQ: *out = (a == b); return true;
    case ND_NE: *out = (a != b); return true;
    case ND_LT: *out = (a < b); return true;
    case ND_LE: *out = (a <= b); return true;
    case ND_GT: *out = (a > b); return true;
    case ND_GE: *out = (a >= b); return true;
    // `&&` / `||`：只在两侧都是字面量时折 —— `0 && f()` 右侧不是字面量 ⇒ 不折（副作用不会被吞）
    case ND_LOGAND: *out = (a != 0 && b != 0); return true;
    case ND_LOGOR:  *out = (a != 0 || b != 0); return true;
    default: return false;
  }
}
static bool fold_un_const(NodeKind kind, Node *operand, int *out) {
  if (!operand || operand->kind != ND_NUM) return false;
  switch (kind) {
    case ND_NEG:    *out = (int)(0u - (uint32_t)operand->val); return true;   // int 回绕（neg eax）
    case ND_NOT:    *out = (operand->val == 0); return true;                  // sete + movzx
    case ND_BITNOT: *out = ~operand->val; return true;                        // not eax
    default: return false;
  }
}

// mkbin：二元节点统一构造——v1.1.0 起在此做 int→double 自动提升（C 语义）；
// v1.7.0 起同样在 int_64 上做提升（任一操作数 int_64 ⇒ 另一侧包 ND_I2L）；
// v1.9.0 起按**通常算术转换**决定提升目标：有符号源符号扩展、无符号源零扩展（ND_U2L）。
// 两侧都是 int 时是零开销（不做任何包装，行为与原实现完全一致）。
static Node *mkbin(NodeKind kind, Node *lhs, Node *rhs) {
  // v2.8.0：两侧都是字面量 ⇒ 当场算成常量（口径见上面的 fold_bin_const 长注释）
  int fv;
  if (fold_bin_const(kind, lhs, rhs, &fv)) return new_num(fv);
  bool li = expr_is_i64(lhs), ri = expr_is_i64(rhs);
  // ⚠️ int_64 ↔ double 的混算一律硬错（P0/P1）：必须**先于** double 提升判 ——
  //   否则 `d * big` 会走进 widen_dbl(int_64) 把它当 32 位 int 转 double（静默错值）。
  if ((li || ri) && (is_dbl_node(lhs) || is_dbl_node(rhs)))
    error("int_64/uint_64 与 double 不能混算（两者互转只走显式转型）——"
          "请先把一侧显式转成另一类（(int)… / (double)…）");
  int rt = usual_arith_ty(expr_ty_of(lhs), expr_ty_of(rhs));
  if (li || ri) {
    // 64 位档：按**值保持**拓宽（有符号源 movsxd / 无符号源 mov eax,eax）
    lhs = expr_widen_to64(lhs, ty_uns(rt));
    rhs = expr_widen_to64(rhs, ty_uns(rt));
  } else if (is_dbl_node(lhs) || is_dbl_node(rhs)) {
    lhs = widen_dbl(lhs);
    rhs = widen_dbl(rhs);
  }
  Node *n = new_node(kind, lhs, rhs);
  // v1.9.0：把结果类型刻进节点（expr_is_i64 / expr_is_uns / expr_ty_of 的唯一来源）。
  //   只刻整数/浮点（指针算术保持 0 = TY_INT，与 v1.8.0 前逐字节一致）。
  //   比较节点的**操作数**公共类型另存 elem_ty（结果本身恒为 int 0/1，不能写进 ty）。
  if (kind_is_arith(kind)) {
    if (ty_isint(rt) || rt == TY_DOUBLE) n->ty = rt;
  } else if (kind_is_cmp(kind)) {
    if (ty_isint(rt)) n->elem_ty = rt;
  }
  return n;
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
  // v2.8.0：位/移位/取模同样在两侧都是字面量时当场算（口径见 fold_bin_const）
  int fv;
  if (fold_bin_const(kind, lhs, rhs, &fv)) return new_num(fv);
  if (is_dbl_node(lhs) || is_dbl_node(rhs))
    error_at(p->tok->loc, "这个运算符不支持 double（位运算/移位/取模只对整数）");
  int rt = usual_arith_ty(expr_ty_of(lhs), expr_ty_of(rhs));
  // v1.9.0：移位的结果类型 = **左侧提升后**的类型（C11 6.5.7：右操作数不参与结果类型），
  //   所以 `int >> uint_32` 仍是 int（算术右移），`uint_32 >> 1` 才是逻辑右移。
  if (kind == ND_SHL || kind == ND_SHR) rt = int_promote(expr_ty_of(lhs));
  if (expr_is_i64(lhs) || expr_is_i64(rhs)) {   // v1.7.0：位运算/移位/取模同样按 64 位提升
    lhs = expr_widen_to64(lhs, ty_uns(rt));
    rhs = expr_widen_to64(rhs, ty_uns(rt));
  }
  Node *n = new_node(kind, lhs, rhs);
  if (ty_isint(rt)) n->ty = rt;     // v1.9.0：结果类型（移位的 rt 已在上面收紧为左侧类型）
  return n;
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
  // v1.9.0：槽的**指向类型**取左值的值类型（uint_64 的左值不能再按 int_64 展开 —— 否则
  //   `u >>= 1` 会走算术右移、`u /= 2` 会走有符号除法，编译过、静默错值）。
  int lty = expr_ty_of(lv);
  if (!ty_isint(lty)) lty = lv->ty;   // 兜底：解析期还没确定值类型时用节点类型
  Node *bind = new_node(ND_ASSIGN, new_var_node(slot, false, TY_PTR, -1, lty),
                        new_node(ND_ADDR, lv, NULL));
  // ② *t = *t op RHS —— 读旧值走 bind 的值（同一个地址），写回走另一次 t 读
  Node *old = new_node(ND_DEREF, bind, NULL);
  old->ty = lty;
  bool bitlike = (bin_kind == ND_BITAND || bin_kind == ND_BITOR || bin_kind == ND_BITXOR
               || bin_kind == ND_SHL || bin_kind == ND_SHR);
  Node *bin = bitlike ? mkintbin(p, bin_kind, old, rhs) : mkbin(bin_kind, old, rhs);
  Node *dst = new_node(ND_DEREF, new_var_node(slot, false, TY_PTR, -1, lty), NULL);
  dst->ty = lty;
  Node *out = new_node(ND_ASSIGN, dst, bin);
  out->ty = lty;    // 表达式值 = 新值（ND_ASSIGN 的值语义），类型 = 左值的值类型
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
  return type_kw_of(t) >= 0
      || is_ident(t, "void") || is_ident(t, "struct")
      || is_ident(t, "ptr");
}
// 前视 `(` + 类型关键字 ⇒ 这是一条转型。普通括号表达式 `(x)` 的 x 不可能是类型关键字
//   （int/char/double/int_64/void/struct/ptr 都是保留字，禁止当变量名）⇒ 不会误判。
static bool is_cast_start(Parser *p) {
  return is_punct(p->tok, '(') && tok_is_cast_type(p->tok->next);
}
static char *cast_type_name(int ty) {
  return ty == TY_PTR ? "指针" : (char *)ty_name(ty);
}
static Node *cast_expr(Parser *p) {
  Token *lp = p->tok;                 // '('
  p->tok = p->tok->next;
  Token *tt = p->tok;                 // 类型关键字
  int ty = type_kw_of(tt);            // v1.9.0：单点表（含 uint_8/uint_32/uint_64）
  int elem = TY_INT;                  // (T*) 的指向类型
  bool is_ptr = false;
  if (ty >= 0) { /* 标量类型词 */ }
  else if (is_ident(tt, "void"))
    error_at(tt->loc, "不支持 (void) 转型：FLINT 没有 void 值（要丢弃结果就写成表达式语句）");
  else if (is_ident(tt, "struct"))
    error_at(tt->loc, "不支持 struct 转型：struct 没有整体值语义 —— 要换类型请声明一个 struct 指针变量"
                      "（v1.8.0 边界，见 SPEC）");
  else
    error_at(tt->loc, "不支持 (ptr) 转型：ptr 只是 api 返回类型的关键字，"
                      "指针类型请写 int* / char* / double* / int_64* / uint_32*");
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
                          "（类型可写 int / int_32 / int_64 / char / double / uint_8 / uint_32 / uint_64，"
                          "或它们加 * 的指针类型）");
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
  // (char)double / (uint_8)double：v1 只给了 (int)/(int_64)/(uint_32)/(uint_64) 的 double 截断，
  //   两步请写清（别让编译器替你猜越界口径）
  if (ty_is8(ty) && from_dbl)
    error_at(lp->loc, "不支持 (%s)double：v1 的 double 截断只有 (int) / (int_64) / (uint_32) / (uint_64)"
                      "（越界 = 0x80000000，同 C）。请写 (%s)(int)值，把两步写清", ty_name(ty), ty_name(ty));
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
    // v2.8.0：一元负号的操作数是字面量 ⇒ 当场折（int 回绕，与运行期 neg eax 逐位一致）。
    //   ND_NUM64 不在这里（64 位语义另立一门），保持原节点。
    int fv;
    if (fold_un_const(ND_NEG, operand, &fv)) return new_num(fv);
    Node *neg = new_node(ND_NEG, operand, NULL);
    if (is_dbl_node(operand)) neg->ty = TY_DOUBLE;
    else {
      // v1.9.0：一元 - 先做整数提升，结果类型仍是提升后的类型（`-(uint_32)1` 还是 uint_32，
      //   二进制补码回绕；`-(uint_8)1` 提升成 int ⇒ -1，不是 255）
      int rt = int_promote(expr_ty_of(operand));
      if (ty_isint(rt)) neg->ty = rt;
    }
    return neg;
  }
  if (consume(p, '!')) {
    Node *operand = unary(p);
    if (is_dbl_node(operand))
      error_at(p->tok->loc, "! 不支持 double（先比较：d != 0.0）");
    int fv;
    if (fold_un_const(ND_NOT, operand, &fv)) return new_num(fv);   // v2.8.0：!字面量当场折（0/1）
    return new_node(ND_NOT, operand, NULL);
  }
  if (consume(p, '~')) {
    Node *operand = unary(p);
    if (is_dbl_node(operand))
      error_at(p->tok->loc, "~ 不支持 double（位运算只对整数）");
    int fv;
    if (fold_un_const(ND_BITNOT, operand, &fv)) return new_num(fv);   // v2.8.0：~字面量当场折（not eax）
    Node *n = new_node(ND_BITNOT, operand, NULL);
    int rt = int_promote(expr_ty_of(operand));   // v1.9.0：整数提升，结果类型随提升后类型
    if (ty_isint(rt)) n->ty = rt;
    return n;
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
    // v2.1.0：&a[i]（struct 数组元素）—— 元素地址节点的**值本来就是那个地址**（见 postfix 的下标
    //   分支），直接返回它、不套 ND_ADDR：ND_ADDR 的 codegen 只认 ND_VAR / ND_DEREF，套在地址链上
    //   会退回按「帧槽」取址 ⇒ 静默给错地址。`&a[i].f` 仍是 ND_DEREF，走下面既有通路。
    if (operand->kind == ND_ADD && operand->ty == TY_STRUCT && operand->struct_idx >= 0)
      return operand;
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
    if (ty_is8(pe))
      d->ty = pe;                        // char* → char（字符打印）；uint_8* → uint_8（无符号数字打印）
    // v1.2.5：double* 解引用（含 double* 字段读、double* 返回调用、double 数组名退化后的链式偏移）
    //   → 目标类型 TY_DOUBLE ⇒ codegen 走 8 字节 SSE 读（movsd）与 SSE 写，绝不落 32 位整数路径
    else if (pe == TY_DOUBLE)
      d->ty = TY_DOUBLE;
    // v1.7.0 P1：int_64* 的解引用读宽 = 8 字节。P0 漏了这一档 ⇒ `*p` 的节点类型掉回 TY_INT：
    //   读只读低 32 位、写只写低半槽，而且 `int_64 x = *p;` 会被包上 movsxd（编译过、值错）。
    //   `p[i]` 是另一条路（postfix 下标分支自己设 TY_INT64），两条都要对。
    //   v1.9.0：uint_64* 同宽度（8 字节），类型保留无符号性。
    else if (ty_is64(pe))
      d->ty = pe;
    else if (pe == TY_UINT32)
      d->ty = TY_UINT32;                 // v1.9.0：uint_32* 解引用（读宽同 int，符号性保留）
    // v2.12.0：*指针数组 = 元素指针（`*names` ≡ names[0]，值宽 8 字节）。这条通路目前拿不到
    //   元素的**指向类型**（ptr_elem_ty 只回 TY_PTR），掉进默认 TY_INT 就会 4 字节读半个指针
    //   ⇒ 静默错值。本版只开下标形态，裸解引用一律响亮报错（绝不静默按 int 读）。
    else if (pe == TY_PTR)
      error_at(p->tok->loc, "指针数组请用下标访问（`char *a[N]` 的 a[i]）——"
                            "`*a` / `*(a+i)` 暂不支持（本版拿不到元素的指向类型，按 32 位读半个指针会静默错值）");
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
      if (expr_is_i64(operand)) n->ty = expr_ty_of(operand);   // v1.7.0 P1：值 = 新的 64 位值（v1.9.0：保留 uint_64）
      else if (expr_is_u32(operand)) n->ty = TY_UINT32;        // v1.9.0：uint_32 的 ++ 仍是 uint_32
      return n;
  }
  if (consume_str(p, "--")) {
    Node *operand = unary(p);
    if (!is_lvalue(operand))
      error_at(p->tok->loc, "-- 需要可修改的变量或 *p（左值）");
    check_field_incr(p, operand);
    check_dbl_incr(p, operand);
    Node *n = new_node(ND_PRE_DEC, operand, NULL);
    if (expr_is_i64(operand)) n->ty = expr_ty_of(operand);   // v1.7.0 P1（v1.9.0：保留 uint_64）
    else if (expr_is_u32(operand)) n->ty = TY_UINT32;
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
    // v1.7.0：幂是 **32 位**累加器（eax/ecx/edx 快速幂）⇒ 64 位整数的 ^^ 会静默截断，明确不做
    if (expr_is_i64(node) || expr_is_i64(rexp)) {
      error_at(p->tok->loc, "^^ 暂不支持 64 位整数（int_64/uint_64；快速幂是 32 位累加器，会静默截断高 32 位）——"
                            "请改成连乘/循环，或先显式收窄");
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
static int struct_field_lookup(StructDef *s, Token *fn, int *fty, int *felem, int *fsid) {
  *fty = TY_INT;
  *felem = TY_INT;
  if (fsid) *fsid = -1;
  if (fn->kind != TK_IDENT) return -1;
  for (int i = 0; i < s->nfields; i++)
    if ((int)strlen(s->fields[i].name) == fn->len
        && strncmp(s->fields[i].name, fn->loc, (size_t)fn->len) == 0) {
      *fty = s->fields[i].ty;
      *felem = s->fields[i].elem;
      if (fsid) *fsid = s->fields[i].sid;
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
  //   v1.9.0：uint_64 走同一条通道（拓宽按源侧符号性取值保持）；uint_32/uint_8 形参照旧 32 位通道，
  //   只额外禁掉 double 实参（跨浮点只走显式转型）。
  int pty = (nargs < fn->nargs) ? fn->param_ty[nargs] : TY_INT;
  if (!by_addr && ty_is64(pty)) {
    if (expr_is_dbl(arg))
      error_at(p->tok->loc, "这个形参是 %s——double 实参不支持（两者互转只走显式转型），请先 (int)值 再 (…)",
               ty_name(pty));
    // 地址值（指针/&x）原样传（已是完整 64 位）；其余按源侧符号性拓宽
    arg = parse_is_addr_value(arg) ? arg : expr_widen_to64(arg, ty_uns(pty));
  } else if (!by_addr && expr_is_i64(arg)) {
    error_at(p->tok->loc, "这个形参是 %s——%s 实参会被静默截断高 32 位（超出范围的部分丢掉），"
                          "请显式转型（或把形参声明成 %s）",
              ty_name(pty), ty_name(expr_ty_of(arg)), ty_name(expr_ty_of(arg)));
  } else if (!by_addr && ty_uns(pty) && expr_is_dbl(arg)) {
    error_at(p->tok->loc, "这个形参是 %s——double 实参不支持（两者互转只走显式转型）", ty_name(pty));
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
    // v2.6.0：函数指针数组元素（ND_DEREF，签名在节点上）与变量同一条检查
    if (arg->ty == TY_FUNCPTR && arg->fn_sig != FN_SIG_NONE) {
      if (want != FN_SIG_NONE
          && !sig_equal(p->prog, &p->prog->sigs[want], &p->prog->sigs[arg->fn_sig]))
        error_at(p->tok->loc, "实参函数指针的签名与形参不一致（形参需要 %s）——"
                              "右边这个函数指针是另一套签名", sig_desc(p->prog, want));
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
  if (struct_field_lookup(s, name, &fty, &felem, NULL) >= 0)
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

// v2.6.0：函数指针数组的**常量下标**求值（只折字面量 / 负号 / 加减——够覆盖 `ops[2]`、`ops[-1]`、
//   `ops[N-1]` 这类写法；变量下标当然求不出来，保持运行期语义）。为什么要折：函数指针数组的越界
//   调用是**跳到野地址**（不是写错一个值），默认档就必须在编译期拦下来，不能等运行期崩。
static bool fp_const_index(Node *n, int *out) {
  long long a;
  int tmp;
  if (!n) return false;
  switch (n->kind) {
    case ND_NUM: a = n->val; break;
    case ND_NEG:
      if (!fp_const_index(n->lhs, &tmp)) return false;
      a = -(long long)tmp;
      break;
    case ND_ADD:
      if (!fp_const_index(n->lhs, &tmp)) return false;
      a = tmp;
      if (!fp_const_index(n->rhs, &tmp)) return false;
      a += tmp;
      break;
    case ND_SUB:
      if (!fp_const_index(n->lhs, &tmp)) return false;
      a = tmp;
      if (!fp_const_index(n->rhs, &tmp)) return false;
      a -= tmp;
      break;
    default: return false;
  }
  if (a < -2147483647LL - 1 || a > 2147483647LL) return false;   // 溢出 int ⇒ 不当常量（照变量下标处理）
  *out = (int)a;
  return true;
}

static Node *postfix(Parser *p) {
  Node *node = primary(p);
  for (;;) {
    if (consume(p, '[')) {
      // ===== v2.6.0：函数指针数组取元素 `ops[i]` =====
      //   形态 = 普通数组那条「基址 + 下标×元素宽 → ND_DEREF」，但**必须**把元素签名带到节点上
      //   （TY_FUNCPTR 的专用通路：没有 fn_sig 就没法做调用/赋值检查，codegen 也就不知道该不该调）。
      //   边界：只认局部数组变量形态（与 struct 数组同一条线）；全局函数指针数组本版未开。
      if (node->ty == TY_ARR && node->elem_ty == TY_FUNCPTR) {
        if (node->kind != ND_VAR || node->is_global)
          error_at(p->tok->loc, "函数指针数组的下标只支持局部数组变量形态 ops[i]"
                                "（v2.6.0 边界：全局/表达式结果下标暂不支持）");
        LVar *av = lv_by_offset(p->all_lvars, node->offset);
        if (!av || av->ty != TY_ARR || av->elem_ty != TY_FUNCPTR)
          error_at(p->tok->loc, "内部错误：找不到函数指针数组 '%s' 的声明信息", av ? av->name : "?");
        Token *idx_tok = p->tok;
        Node *idx = expr(p);
        skip(p, ']');
        // 越界：**常量**下标一律当场报错（函数指针数组的越界调用 = 跳到野地址，比写错值更凶；
        //   这里不跟 -strict 开关走，默认档也拦 —— 长度在声明期已完全确定，没有误报空间）。
        int cidx = 0;
        if (fp_const_index(idx, &cidx) && (cidx < 0 || cidx >= av->arr_len))
          error_at(idx_tok->loc, "函数指针数组 '%s' 的常量下标 %d 越界（合法下标 0..%d）",
                   av->name, cidx, av->arr_len - 1);
        Node *scaled = new_node(ND_MUL, idx, new_num(ty_arr_stride(TY_FUNCPTR)));
        Node *addr = new_node(ND_ADD, node, scaled);
        Node *d = new_node(ND_DEREF, addr, NULL);
        d->ty = TY_FUNCPTR;
        d->fn_sig = av->fn_sig;
        d->loc = idx_tok->loc;
        node = d;
        continue;
      }
      // ===== v2.13.0（struct 值语义第三刀）：**struct 数组值的通用下标** =====
      //   覆盖两条新来源（局部 struct 数组仍是下面 v2.1.0 那支，`node->ty == TY_STRUCT`）：
      //     ① 全局 struct 数组 `struct E gs[3];` → 变量节点 ty=TY_ARR + elem=TY_STRUCT + struct_idx；
      //     ② struct 数组字段 `w.es[i]` → `.es` 造出的地址链 ty=TY_ARR + elem=TY_STRUCT + struct_idx。
      //   语义与局部 `a[i]` **一字不差**：结果是**元素地址**（不套 ND_DEREF）⇒ `w.es[i].f` / `&w.es[i]`
      //   / 传给 `struct E *` 形参三条用法与局部数组同形。
      //   步长单点 = 8*ceil(size/8)（与局部数组 new_lvar 槽数、struct 指针下标**同一条口径**）；
      //   布局期（parse_structdef / collect_globals）也用这同一个式子 ⇒ 下标与布局不可能分叉。
      if (node->ty == TY_ARR && node->elem_ty == TY_STRUCT) {
        if (node->struct_idx < 0)
          error_at(p->tok->loc, "内部错误：struct 数组缺少结构体下标（parse 应已带上）");
        int alen = -1;   // -1 = 长度拿不到（struct 数组字段；-strict 的常量越界检查据此跳过）
        if (node->kind == ND_VAR) {
          if (node->is_global) alen = p->prog->globals[node->offset].arr_len;
          else { LVar *av = lv_by_offset(p->all_lvars, node->offset); if (av) alen = av->arr_len; }
        }
        int stride = 8 * ((p->prog->structs[node->struct_idx].size + 7) / 8);
        Token *idx_tok = p->tok;
        Node *idx = expr(p);
        skip(p, ']');
        // 二维 struct 数组（`es[i][j]`）本版不做 —— 响亮拒收，别让第二个 '[' 落到别处去。
        if (is_punct(p->tok, '['))
          error_at(p->tok->loc, "struct 数组只支持一维下标（二维 `es[i][j]` 暂不支持）——"
                                "要二维请写一维 `es[i*cols + j]` 自己算");
        if (flint_strict && idx->kind == ND_NUM && alen > 0
            && (idx->val < 0 || idx->val >= alen))
          error_at(idx_tok->loc, "[E-STRICT-BOUNDS] 常量下标 %d 越界：这个 struct 数组只有 %d 个元素"
                                 "（合法下标 0..%d）", idx->val, alen, alen - 1);
        Node *scaled = new_node(ND_MUL, idx, new_num(stride));
        Node *addr = new_node(ND_ADD, node, scaled);
        addr->ty = TY_STRUCT;                  // 元素地址：地址链 + 目标结构体类型
        addr->struct_idx = node->struct_idx;
        node = addr;
        continue;
      }
      // ===== v2.1.0：struct 数组元素 `a[i]` =====
      //   语义 = **元素地址**（基址 + i×步长），与「struct 变量名作表达式 = 首地址」同一条口径
      //   ⇒ 三种用法自然成立：`a[i].f`（字段通路）、`&a[i]`（地址就是这个值）、把 `a[i]` 传给
      //   `struct S *` 形参。D11 摊平：这里是 ND_ADD/ND_MUL 地址链（**复用**「数组字段作表达式」
      //   那条路，见下方 `.` 分支的 TY_ARR 注释），codegen 一行未加。
      //   步长单点 = 8*ceil(size/8)（与 new_lvar 的槽数同源）⇒ 元素区间互不重叠、字段不越界。
      if (node->ty == TY_STRUCT) {
        if (node->kind != ND_VAR || node->struct_idx < 0 || node->is_global)
          error_at(p->tok->loc, "这里不能下标（struct 数组下标只支持局部变量形态 a[i]，"
                                "二维 a[i][j] 与表达式结果下标都不支持）");
        LVar *av = lv_by_offset(p->all_lvars, node->offset);
        int alen = av ? av->arr_len : 0;
        if (alen <= 0)
          error_at(p->tok->loc, "结构体变量 '%s' 不是数组，不能下标"
                                "（要写 a[i] 得先声明成 struct 类型名 %s[N];）",
                   av ? av->name : "?", av ? av->name : "?");
        int stride = 8 * ((p->prog->structs[node->struct_idx].size + 7) / 8);   // 元素步长（槽对齐）
        Token *idx_tok = p->tok;   // -strict 越界报错指到「下标」那个 token（与数组同口径）
        Node *idx = expr(p);
        skip(p, ']');
        // v1.4.25（-strict）④ 同一条判据：长度编译器完全知道，常量下标越界不静默放过
        if (flint_strict && idx->kind == ND_NUM && (idx->val < 0 || idx->val >= alen))
          error_at(idx_tok->loc, "[E-STRICT-BOUNDS] 常量下标 %d 越界：这个 struct 数组只有 %d 个元素"
                                 "（合法下标 0..%d）", idx->val, alen, alen - 1);
        Node *scaled = new_node(ND_MUL, idx, new_num(stride));
        Node *addr = new_node(ND_ADD, node, scaled);
        addr->ty = TY_STRUCT;                  // 元素地址：地址链 + 目标结构体类型
        addr->struct_idx = node->struct_idx;
        node = addr;
        continue;
      }
      // ===== 2026-10-24（v2.2）：struct 指针下标 `p[i]`（p = struct S *）=====
      //   语义 = **元素地址**（p 的值 + i×步长），与 struct 数组的 `a[i]` 完全同一条口径
      //   ⇒ `p[i].f` 走字段通路、`&p[i]` 就是它自己、`p[i]` 可直接传给 `struct S *` 形参。
      //   步长与 `a[i]` 同源（8*ceil(size/8)）—— 两处各算一套的话，同一个结构体会出现两种下标步长。
      // v2.3：条件从「ND_VAR|ND_CALL」放宽到**任一** struct 指针值 —— `s.next[i].v` 的基址是字段读节点
      //   （ND_DEREF，ty=TY_PTR、struct_idx=指向的结构体）。int* 的 struct_idx 恒 -1，不会被这支接住。
      if (node->ty == TY_PTR && node->struct_idx >= 0) {
        int stride = 8 * ((p->prog->structs[node->struct_idx].size + 7) / 8);
        Node *idx = expr(p);
        skip(p, ']');
        Node *scaled = new_node(ND_MUL, idx, new_num(stride));
        Node *addr = new_node(ND_ADD, node, scaled);
        addr->ty = TY_STRUCT;                  // 元素地址：地址链 + 目标结构体类型
        addr->struct_idx = node->struct_idx;
        node = addr;
        continue;
      }
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
      // ===== v2.2.0：二维数组 `m[i][j]` —— 第二维在这里合成**一维线性下标** =====
      //   语义（row-major）：m[i][j] ≡ m[i*cols + j]。折出来的 idx 直接喂给下面**已有**的
      //   「基址 + 下标×元素宽 → ND_DEREF」通路 ⇒ codegen 一行不改（D11 摊平原则）。
      //   只认「局部变量名 + 两个下标」；表达式结果/全局二维（未开）都走不到这里。
      int cols2 = 0;
      const char *arr_name = "?";
      if (node->kind == ND_VAR && node->ty == TY_ARR && !node->is_global) {
        LVar *av = lv_by_offset(p->all_lvars, node->offset);
        if (av) { cols2 = av->cols; arr_name = av->name; }
      }
      if (cols2 > 0) {
        if (!is_punct(p->tok, '['))
          error_at(idx_tok->loc, "二维数组 '%s' 需要两个下标（m[行][列]）——"
                                 "只写一维会静默读到别的行", arr_name);
        p->tok = p->tok->next;
        Token *idx2_tok = p->tok;
        Node *idx2 = expr(p);
        skip(p, ']');
        if (flint_strict && idx2->kind == ND_NUM && (idx2->val < 0 || idx2->val >= cols2))
          error_at(idx2_tok->loc, "[E-STRICT-BOUNDS] 常量列下标 %d 越界：这个二维数组只有 %d 列"
                                  "（合法列下标 0..%d）", idx2->val, cols2, cols2 - 1);
        idx = new_node(ND_ADD, new_node(ND_MUL, idx, new_num(cols2)), idx2);
      }
      // a[i] = *(a + i*scale)：基址表达式（数组名 lea / 指针 load）+ 下标×元素宽
      //   int 元素 = 8 字节槽（旧语义）；v1.0.5 char 元素 = 1 字节（字节缓冲/字符串构建）
      int elem = node->elem_ty;
      // ===== v2.12.0：**指针数组元素** `names[i]`（元素类型 = TY_PTR）=====
      //   元素宽 8、读写 8 字节（既有的 TY_PTR 通路），但还要把**指向类型**带给节点 ——
      //   `names[i][0]` 的下标缩放、`*names[i]` 的读宽、`print([names[i]])` 的分派全靠节点
      //   elem_ty（口径与指针变量/指针字段同一条：ty 说宽度，elem_ty 说指向什么）。
      //   指向类型存在 LVar.elem_ptr_ty（数组声明期记的 base_ty）；结构体指针数组本版未开，
      //   故这里只接局部 ND_VAR 形态（与函数指针数组/struct 数组同一条线）。
      int ptr_arr_elem = TY_INT;
      if (elem == TY_PTR) {
        LVar *av = (node->kind == ND_VAR && !node->is_global)
                 ? lv_by_offset(p->all_lvars, node->offset) : NULL;
        if (!av || av->ty != TY_ARR || av->elem_ty != TY_PTR)
          error_at(p->tok->loc, "指针数组的下标只支持局部数组变量形态 names[i]"
                                "（v2.12 边界：全局/结构体字段/表达式结果下标暂不支持）");
        ptr_arr_elem = av->elem_ptr_ty;
      }
      // ⚠️ 元素宽必须与**语言的数组语义**一致，不是与 C 的 sizeof 一致：
      //   FLINT 的 int 元素 = **8 字节槽**（见本文件 postfix：`a[i] = *(a + i*8)`，SPEC 亦如此），
      //   所以 .data 里全局 int 数组也必须按 8 字节/元素摆放（见下方 collect_globals 的 esize）。
      //   🐞 实测踩过：`.data` 按 C 的 4 字节摆、下标却按 8 缩放 → `garr[2]` 跨到 +16 = **下一个全局变量**
      //   的槽上（静默写坏别的变量；[0]/[1] 恰好在界内所以看不出来，长程序才炸）。
      int esize_bytes = ty_arr_stride(elem);   // v1.7.0：走单点表（char 1 / int 4 / int_64 8 / double 8）
      Node *scaled = new_node(ND_MUL, idx, new_num(esize_bytes));
      Node *addr = new_node(ND_ADD, node, scaled);
      node = new_node(ND_DEREF, addr, NULL);
      // v1.9.0：元素读类型 = **元素类型原值**（不再手抄一条 if 链 —— 那条链每加一个类型就要改
      //   一次，漏了就把 uint_64 元素读成 32 位）。char/uint_8→1 字节，int/uint_32→4，int_64/uint_64→8。
      //   v2.12.0：指针元素 = TY_PTR + 指向类型（读 64 位；struct_idx 显式 -1，别让 0 冒充 struct 0）。
      if (elem == TY_PTR) {
        node->ty = TY_PTR;
        node->elem_ty = ptr_arr_elem;
        node->struct_idx = -1;
      } else {
        node->ty = ty_isint(elem) || elem == TY_DOUBLE ? elem : TY_INT;
      }
    } else if (consume(p, '.')) {
      // p.x：p = 结构体变量（普通或引用；名字作表达式 = 结构体地址）
      // v1.6.0：方法调用点糖 recv.name(args) ⇒ Type_name(&recv, args) —— 判据 = **括号**
      //   （名字后面紧跟 '(' 才是方法候选；不带括号一律按字段访问的老语义走）
      Token *mname0 = p->tok;
      bool mcall = (mname0->kind == TK_IDENT && mname0->next && is_punct(mname0->next, '('));
      bool recv_val = (node->kind == ND_VAR && node->ty == TY_STRUCT && node->struct_idx >= 0);
      // v2.1.0：struct 数组元素 `a[i]` 是**元素地址**（ND_ADD 地址链，ty=TY_STRUCT）——
      //   `a[i].f` 与 `s.f` 走同一条字段通路（基址表达式换成那条链），不新增 codegen 通路。
      bool recv_el = (node->kind == ND_ADD && node->ty == TY_STRUCT && node->struct_idx >= 0);
      // 指针接收者的 '.' 形态只认**变量**（与既有字段语义同一条线：'.' 左侧须是变量）。
      //   表达式结果（f().g(...)）不走 '.'——它没有可取的地址；要指针接收者请写 f()->g(...)。
      bool recv_ptr = (node->kind == ND_VAR && node->ty == TY_PTR && node->struct_idx >= 0);
      if (recv_ptr && !mcall)
        error_at(mname0->loc, "'.' 左侧是指向结构体的指针：**字段**访问请写 '->'（p->x）；"
                              "只有方法调用点 p.%.*s(...) 才允许用 '.'", mname0->len, mname0->loc);
      // v2.1.0：元素地址链上的方法调用点糖**暂不支持**——响亮报错（糖摊平后首参是 &a[i]，
      //   指针/引用接收者两条路对地址链的处理各不相同，留作独立一刀；手写形式完全等价且已可用）。
      if (mcall && recv_el)
        error_at(mname0->loc, "struct 数组元素上的方法调用点糖暂不支持（a[i].%.*s(...)）——"
                              "请手写自由函数形式：类型名_%.*s(&a[i], ...)",
                 mname0->len, mname0->loc, mname0->len, mname0->loc);
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
      if (!recv_val && !recv_el) {
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
      int fsid = -1;   // v2.3：struct 指针字段 → 指向的结构体（其余字段 -1）
      foff = struct_field_lookup(s, fn, &fty, &felem, &fsid);
      if (foff < 0)
        no_such_field_error(p, s, fn);
      p->tok = p->tok->next;
      // v1.4.4：**数组字段作表达式 = 首元素地址**（与数组名退化同语义）→ 直接给地址节点、不套 ND_DEREF。
      //   这样三种用法全部自然成立：`s.buf[i]`（下标按 elem_ty 缩放）、`&s.buf[0]`、把 `s.buf` 传给 `int p[]`。
      if (fty == TY_ARR) {
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_ARR;
        da->elem_ty = felem;
        // v2.13.0：**struct 数组字段** `struct E es[N]` 的地址链要把元素结构体带上 ——
        //   下一级 `[` 靠它算步长、再下一级 `.f` 靠它查字段表。普通数组字段（int/char/double）
        //   仍是 -1（new_node 的清零会让 0 冒充"struct 0"）。
        da->struct_idx = (felem == TY_STRUCT) ? fsid : -1;
        node = da;
      } else if (fty == TY_STRUCT && fsid >= 0) {
        // ===== v2.4.0：嵌套 struct **值字段** `a.b` = 字段地址（不套 ND_DEREF）=====
        //   与数组字段同一手法：给的是地址链，不是一次读。下一级 `.` 由 recv_el 接住
        //   （`node->kind == ND_ADD && ty == TY_STRUCT`），偏移继续累加 ⇒ `a.b.c` 在 parse 期
        //   折成 *( (a + off_b) + off_c )，**codegen 零改动**（与二维数组、struct 数组同一条通路）。
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_STRUCT;
        da->struct_idx = fsid;      // 下一级字段表 = 内层 struct
        da->elem_ty = TY_INT;       // 无指向类型；显式写上，别让 0 冒充语义
        node = da;
      } else {
        Node *d = new_node(ND_DEREF, new_node(ND_ADD, node, new_num(foff)), NULL);
        d->ty = fty;   // v0.9.2：ptr 字段读 = 64 位、int 字段读 = 32 位
        // v1.2.5：指针字段把**指向类型**带到节点上 —— `*s.p` 的读写宽度（ptr_elem_ty 读 elem_ty）、
        //   `s.p[i]` 的下标缩放都由它决定（否则 double* 字段会被当 int* 静默按 32 位/元素 8 字节错走）
        if (fty == TY_PTR) {
          d->elem_ty = felem;
          d->struct_idx = fsid;   // v2.3：struct 指针字段把指向的结构体带上来（普通指针字段 = -1）
        } else {
          d->struct_idx = -1;
        }
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
      // v2.3：去掉「ND_VAR|ND_CALL」限制 —— `s.next->v` 的左侧是**字段读节点**（ND_DEREF，ty=TY_PTR、
      //   struct_idx=指向的结构体）。判据收敛成「是个 struct 指针值」：int*/char*/double* 的 struct_idx 恒 -1。
      if (node->ty != TY_PTR || node->struct_idx < 0)
        error_at(p->tok->loc, "'->' 左侧须为指向结构体的指针");
      StructDef *s = &p->prog->structs[node->struct_idx];
      Token *fn = p->tok;
      int foff = -1;
      int fty = TY_INT;   // v0.9.2：字段类型（决定读写宽度）
      int felem = TY_INT;   // v1.2.5：指针字段的指向类型（int* → TY_INT；double* → TY_DOUBLE）
      int fsid = -1;   // v2.3：struct 指针字段 → 指向的结构体（其余字段 -1）
      foff = struct_field_lookup(s, fn, &fty, &felem, &fsid);
      if (foff < 0)
        no_such_field_error(p, s, fn);
      p->tok = p->tok->next;
      // v1.4.4：**数组字段作表达式 = 首元素地址**（与数组名退化同语义）→ 直接给地址节点、不套 ND_DEREF。
      //   这样三种用法全部自然成立：`s.buf[i]`（下标按 elem_ty 缩放）、`&s.buf[0]`、把 `s.buf` 传给 `int p[]`。
      if (fty == TY_ARR) {
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_ARR;
        da->elem_ty = felem;
        // v2.13.0：**struct 数组字段** `struct E es[N]` 的地址链要把元素结构体带上 ——
        //   下一级 `[` 靠它算步长、再下一级 `.f` 靠它查字段表。普通数组字段（int/char/double）
        //   仍是 -1（new_node 的清零会让 0 冒充"struct 0"）。
        da->struct_idx = (felem == TY_STRUCT) ? fsid : -1;
        node = da;
      } else if (fty == TY_STRUCT && fsid >= 0) {
        // v2.4.0：`p->b`（b 是 struct 值字段）→ 字段地址链，余下同 `.` 分支（见上面那段注释）
        Node *da = new_node(ND_ADD, node, new_num(foff));
        da->ty = TY_STRUCT;
        da->struct_idx = fsid;
        da->elem_ty = TY_INT;
        node = da;
      } else {
        Node *d = new_node(ND_DEREF, new_node(ND_ADD, node, new_num(foff)), NULL);
        d->ty = fty;   // v0.9.2：ptr 字段读 = 64 位、int 字段读 = 32 位
        // v1.2.5：指针字段把**指向类型**带到节点上 —— `*s.p` 的读写宽度（ptr_elem_ty 读 elem_ty）、
        //   `s.p[i]` 的下标缩放都由它决定（否则 double* 字段会被当 int* 静默按 32 位/元素 8 字节错走）
        if (fty == TY_PTR) {
          d->elem_ty = felem;
          d->struct_idx = fsid;   // v2.3：struct 指针字段把指向的结构体带上来（普通指针字段 = -1）
        } else {
          d->struct_idx = -1;
        }
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
      int oty = expr_ty_of(node);   // v1.9.0：值类型 = 操作数类型（uint_64 保留无符号性）
      node = new_node(ND_POST_INC, node, NULL);
      if (i64) node->ty = oty;
      else if (oty == TY_UINT32) node->ty = TY_UINT32;
    } else if (consume_str(p, "--")) {
      if (!is_lvalue(node))
        error_at(p->tok->loc, "-- 需要可修改的变量或 *p（左值）");
      check_field_incr(p, node);
      check_dbl_incr(p, node);
      // v1.7.0 P1：int_64 的 -- 同 ND_POST_INC
      bool i64 = expr_is_i64(node);
      int oty = expr_ty_of(node);   // v1.9.0：同 ND_POST_INC
      node = new_node(ND_POST_DEC, node, NULL);
      if (i64) node->ty = oty;
      else if (oty == TY_UINT32) node->ty = TY_UINT32;
    } else if (is_punct(p->tok, '(') && node->ty == TY_FUNCPTR) {
      // ===== v2.6.0：函数指针**表达式**的间接调用 `ops[i](实参...)` =====
      //   变量形态 `fp(...)` 早在 primary 里就被接走了（那条路保持逐字节不变）；这里接的是
      //   postfix 造出来的解引用节点（数组元素）。签名取自节点（parse 在取元素时从 LVar 带上来）。
      if (node->fn_sig == FN_SIG_NONE)
        error_at(p->tok->loc, "内部错误：函数指针表达式缺少签名（取元素时应已从声明带上来）");
      node = parse_indirect_call_core(p, node, node->fn_sig, p->tok);
      continue;
    } else {
      return node;
    }
  }
}

// ===== 2026-11-04：sizeof 运算符（编译期常量，结果类型 int）=====
// 语法：sizeof(<类型>) 与 sizeof(<标识符>)。
//   类型 = 8 种标量（int/int_32/int_64/uint_8/uint_32/uint_64/char/double）｜ struct <名>
//          ｜以上加 *（指针，可重复）｜以上加 [<编译期常量>]（数组，可重复 ⇒ 连乘）。
//   标识符 = 已声明的局部/全局变量（按**声明类型**算；数组 = 整个数组的字节数）。
// **不是关键字**：词法不动，`sizeof` 仍是普通标识符，只在 primary 里前视 '(' 特判（同 to_int 族）。
//
// 口径（唯一真源，绝不在这里另算一套布局）：
//   · 标量 / 指针 → ty_value_bytes（D3 值宽单点表，flint.h 声明、本文件定义）
//       int/int_32/uint_32 = 4 ｜ char/uint_8 = 1 ｜ int_64/uint_64/double/指针 = 8
//   · struct      → StructDef.size（parse_structdef 布局期唯一真值：C 布局、尾部 padding 已含、
//                    嵌套值字段/数组字段整块累加过）——find_struct 取下标，不重算字段
//   · T[N]        → N × sizeof(T)（乘法口径，与 §2 的"值宽"一致；二维/多维连乘）
//   · **槽宽不算**：局部标量槽 8 字节、struct 数组元素步长 8*ceil(size/8) 都是**帧布局**，
//     不是值字节数 —— 所以 sizeof(int) 必须是 4（不是 8），sizeof(struct S) 是 C 的 size。
// 结果 = new_num(...) ⇒ 直接走既有 int 字面量通路，codegen 一行不用改。
static long long sizeof_struct_size(Program *prog, int sidx) {
  if (sidx < 0 || sidx >= prog->nstructs)
    error("内部错误：sizeof 拿到的结构体下标越界（%d）", sidx);
  return prog->structs[sidx].size;
}

// 一个对象（非数组，或数组的"一个元素"）的值字节数。
//   ty = 声明类型；elem_ty/struct_idx 按各登记表的约定（见 flint.h 的 LVar/GlobalVar 注释）。
//   ⚠️ 两类数组的编码不同：**局部 struct 数组** = ty==TY_STRUCT + arr_len=N；
//      **全局 struct 数组** = ty==TY_ARR + elem_ty==TY_STRUCT。两种都在这里归一，别在调用点判。
static long long sizeof_elem_bytes(Program *prog, int ty, int elem_ty, int struct_idx) {
  if (ty == TY_STRUCT || elem_ty == TY_STRUCT) return sizeof_struct_size(prog, struct_idx);
  if (ty == TY_PTR || ty == TY_FUNCPTR) return 8;
  if (ty == TY_ARR) return ty_value_bytes(elem_ty);   // 数组的元素宽（指针数组 = 8、char = 1…）
  return ty_value_bytes(ty);
}

static long long sizeof_obj_bytes(Program *prog, int ty, int elem_ty,
                                  int arr_len, int cols, int struct_idx) {
  bool is_arr = (ty == TY_ARR) || (ty == TY_STRUCT && arr_len > 0);
  if (is_arr) {
    long long n = (long long)(arr_len > 0 ? arr_len : 1) * (cols > 0 ? cols : 1);
    return n * sizeof_elem_bytes(prog, ty, elem_ty, struct_idx);
  }
  return sizeof_elem_bytes(prog, ty, elem_ty, struct_idx);
}

// sizeof(<标识符>)：按声明类型算；找不到就响亮报错（绝不给一个猜的数）。
static long long sizeof_var_bytes(Parser *p, Token *tok) {
  LVar *v = find_lvar(p, tok);
  if (v)
    return sizeof_obj_bytes(p->prog, v->ty, v->elem_ty, v->arr_len, v->cols, v->struct_idx);
  int gi = find_global(p->prog, tok);
  if (gi >= 0) {
    GlobalVar *g = &p->prog->globals[gi];
    return sizeof_obj_bytes(p->prog, g->ty, g->elem_ty, g->arr_len, 0, g->struct_idx);
  }
  int fi = find_func(p->prog, tok);
  if (fi >= 0)
    error_at(tok->loc, "sizeof(...) 的实参是函数名 '%.*s' —— 函数没有对象大小（sizeof 只接受类型或变量）",
             tok->len, tok->loc);
  int ei = find_enum(p->prog, tok);
  if (ei >= 0)
    error_at(tok->loc, "sizeof(...) 的实参是 enum 常量 '%.*s'（值不是对象）—— 枚举常量按 int 存，请写 sizeof(int)",
             tok->len, tok->loc);
  error_at(tok->loc, "sizeof 里的 '%.*s' 未声明 —— sizeof(<标识符>) 只接受已声明的变量；"
                     "类型请写 sizeof(int) / sizeof(struct S)", tok->len, tok->loc);
  return 0;
}

// sizeof(<类型>)：tt = 类型首 token（调用点已确认它是类型词 / struct / void / ptr）。
// 出口停在 ')' 上（由调用方 skip）。
static long long sizeof_type_bytes(Parser *p, Token *tt) {
  long long bytes;
  int sidx = -1;
  if (is_ident(tt, "void"))
    error_at(tt->loc, "sizeof(void) 没有意义：void 不是有值的类型 —— 要字节视图请用 sizeof(char*)"
                      "（指针恒 8 字节）");
  if (is_ident(tt, "ptr"))
    error_at(tt->loc, "sizeof(ptr) 没有意义：ptr 只是 api 返回类型的关键字 —— "
                      "指针请写 sizeof(int*)（指针恒 8 字节）");
  if (is_ident(tt, "struct")) {
    p->tok = tt->next;
    Token *sn = p->tok;
    if (sn->kind != TK_IDENT || is_keyword(sn))
      error_at(sn->loc, "sizeof 里 struct 后需跟结构体名（写法：sizeof(struct Point)）");
    sidx = find_struct(p->prog, sn);
    if (sidx < 0)
      error_at(sn->loc, "sizeof 里的结构体 '%.*s' 未定义 —— 请先写 struct %.*s { ... } 再用 sizeof"
                        "（要完整字段布局才能算大小）", sn->len, sn->loc, sn->len, sn->loc);
    p->tok = sn->next;
    bytes = sizeof_struct_size(p->prog, sidx);
  } else {
    int base = type_kw_of(tt);
    if (base < 0)
      error_at(tt->loc, "sizeof 括号里不是可识别的类型（可写 int / int_32 / int_64 / char / double / "
                        "uint_8 / uint_32 / uint_64 / struct 名，可加 * 或 [常量]）");
    p->tok = tt->next;
    bytes = ty_value_bytes(base);
  }
  // 指针后缀：任意层 * ⇒ 8（指向什么不影响指针宽度）；`struct S *` 同样 8
  while (is_punct(p->tok, '*')) {
    p->tok = p->tok->next;
    bytes = 8;
  }
  // 数组后缀：[<编译期常量>]（可重复 ⇒ 连乘；长度口径与声明处一致：parse_const_int）
  while (is_punct(p->tok, '[')) {
    Token *lb = p->tok;
    p->tok = p->tok->next;
    Token *cnt = p->tok;
    long long n = 0;
    if (!parse_const_int(p, &n))
      error_at(cnt->loc, "sizeof 的数组长度必须是编译期常量（字面量 / enum 常量 / 常量表达式）"
                         "——变量、函数调用、运行期量都不行（sizeof 在 parse 期就得算死）");
    if (n <= 0) error_at(cnt->loc, "sizeof 的数组长度须为正数（得到 %lld）", n);
    if (n > 2147483647LL)
      error_at(cnt->loc, "sizeof 的数组长度过大（%lld；上限 2147483647）", n);
    skip(p, ']');
    if (bytes > 0 && n > 2147483647LL / bytes)
      error_at(lb->loc, "sizeof 的结果超出 int 范围（2147483647）—— 数组类型太大了，"
                        "而 sizeof 的结果类型是 int");
    bytes *= n;
  }
  if (!is_punct(p->tok, ')'))
    error_at(p->tok->loc, "sizeof 的类型写法不对：期望 ')'（类型 = int / int_32 / int_64 / char / "
                          "double / uint_8 / uint_32 / uint_64 / struct 名，可加 * 或 [常量]）");
  return bytes;
}

// sizeof 入口：先吃掉 '('（调用点已前视），再分「类型形态 / 变量形态」两路。
static Node *sizeof_expr(Parser *p) {
  Token *kw = p->tok;            // 'sizeof'
  p->tok = p->tok->next;         // '('
  Token *arg = p->tok->next;     // '(' 之后的第一个 token（类型或变量名的起点）
  p->tok = arg;
  long long bytes;
  bool type_form = arg->kind == TK_IDENT
      && (type_kw_of(arg) >= 0 || is_ident(arg, "struct")
          || is_ident(arg, "void") || is_ident(arg, "ptr"));
  if (type_form) {
    bytes = sizeof_type_bytes(p, arg);
  } else if (arg->kind == TK_IDENT && !is_keyword(arg) && is_punct(arg->next, ')')) {
    bytes = sizeof_var_bytes(p, arg);
    p->tok = arg->next;          // 越过变量名，停在 ')'
  } else {
    error_at(arg->loc, "sizeof 只接受类型或变量名（sizeof(int) / sizeof(struct P) / sizeof(buf)）"
                       "——不接受表达式：sizeof(表达式) 在编译期拿不到对象大小");
    bytes = 0;
  }
  if (bytes > 2147483647LL)
    error_at(kw->loc, "sizeof 的结果 %lld 字节超出 int 范围（2147483647）—— sizeof 的结果类型是 int",
             bytes);
  skip(p, ')');
  Node *n = new_num((int)bytes);
  n->loc = kw->loc;
  return n;
}

// primary = "(" expr ")" | NUM | 标识符
static Node *primary(Parser *p) {
  // v2.7.0：`((((1))))` 走这里 → expr 的递归；进括号先记深度，正常出口再还原。
  //   ⚠️ 只加在这个 '(' 分支 —— postfix/expr/assign/add 等链式函数是 while 循环，不递归。
  if (consume(p, '(')) {
    p->depth = p->depth + 1;
    if (p->depth > PARSE_MAX_DEPTH)
      error_at(p->tok->loc, "嵌套过深（上限 %d 层）：括号或语句块套得太深，请拆成变量/函数", PARSE_MAX_DEPTH);
    Node *n = expr(p);
    skip(p, ')');
    p->depth = p->depth - 1;
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
      error_at(kw->loc, "to_int32(...) 只用于 64 位整数（int_64/uint_64）→ int 的显式收窄"
                        "（实参已经是 32 位：不必转）");
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
      error_at(p->tok->loc, "to_int64(...) 不支持 double（两者互转只走显式转型）");
    return widen_i64(arg);
  }
  // ===== 2026-11-04：sizeof（见上面的 sizeof_expr）=====
  //   ⚠️ 必须在通用 TK_IDENT 分支**之前**判：否则 `sizeof(int)` 会先被 postfix 当函数调用吃掉，
  //   落进「使用了未声明的变量 'sizeof'」（与本文件 to_int 的老教训同一条位置要求）。
  if (p->tok->kind == TK_IDENT && is_ident(p->tok, "sizeof")) {
    if (p->tok->next && is_punct(p->tok->next, '('))
      return sizeof_expr(p);
    // 不是 '(' ⇒ 写漏了括号。`sizeof` 仍是普通标识符：真有人声明了同名变量就照旧当变量读。
    if (!find_lvar(p, p->tok) && find_global(p->prog, p->tok) < 0)
      error_at(p->tok->loc, "sizeof 需要括号：sizeof(int) / sizeof(struct S) / sizeof(变量名)");
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
      // v1.9.0：uint_* 同族（同一张边界，别让它们掉进下面的 'new int' 检查）
      if (type_kw_of(p->tok) >= 0 && type_kw_of(p->tok) != TY_INT)
        error_at(p->tok->loc, "'new %s' 暂不支持（v1.7.0 P0 边界）——"
                              "堆上要 64 位可以 new int（负载 8 字节）再用 %s * 承接",
                 ty_name(type_kw_of(p->tok)), ty_name(type_kw_of(p->tok)));
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
    // v2.1.0 enum：具名整数常量（字面量别名；局部变量与全局变量已优先遮蔽）
    int ei = find_enum(p->prog, p->tok);
    if (ei >= 0) {
      Node *n = new_num(p->prog->enums[ei].value);
      n->loc = p->tok->loc;
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
          // ===== v1.11.0（2026-11-04）：api 实参按**声明类型**校验（声明侧唯一口径 = ApiDef.param_ty）=====
          //   放行：64 位形参 ← 64 位实参（同宽，位型直传）
          //         64 位形参 ← 32/8 位实参（**宽化**：按源侧符号性，编译期包 ND_I2L / ND_U2L，
          //           生成侧 emit_arg_rax_to_gp 见 expr_is_i64 为真就整搬 64 位）
          //   硬错：32 位形参 ← 64 位实参（静默丢高 32 位，必须显式 (int) 收窄）
          //         ptr 形参 ← 64 位整数（地址 ≠ 整数，与 T1「地址值不能装进 int」同一条红线）
          //         double 形参 ← 64 位整数（互转只走显式转型，同 asgn_rhs）
          int pty = (nargs < API_MAX_ARGS) ? a->param_ty[nargs] : TY_INT;
          if (pty == TY_DOUBLE) {
            // v1.1.0：声明 double 就必须传 double（int 实参自动提升；int_64 实参由 widen_dbl 响亮报错）
            arg = widen_dbl(arg);
          } else if (pty == TY_PTR) {
            if (expr_is_i64(arg))
              error_at(p->tok->loc, "这个 API 形参声明的是 ptr（64 位地址/句柄）——64 位整数（%s）不能当地址传"
                                    "（地址 ≠ 整数）：要传地址请用指针/&变量，要传数值请把形参改成 int_64",
                       ty_name(expr_ty_of(arg)));
            else if (is_dbl_node(arg))
              error_at(p->tok->loc, "这个 API 形参声明的是 ptr——double 实参会走 XMM 通道，声明与实参必须一致");
          } else if (ty_is64(pty)) {
            if (expr_is_dbl(arg))
              error_at(p->tok->loc, "这个 API 形参声明的是 %s——double 实参不支持（两者互转只走显式转型），"
                                    "请先写出显式转型再传", ty_name(pty));
            // 地址值原样传（已是完整 64 位，包 movsxd 会抹高半）；其余按源侧符号性宽化
            arg = parse_is_addr_value(arg) ? arg : expr_widen_to64(arg, ty_uns(pty));
          } else {
            // 声明的是 32 位 int 档（int / char 类）：64 位实参必须显式收窄
            if (expr_is_i64(arg))
              error_at(p->tok->loc, "这个 API 形参声明的是 %s——64 位整数（%s）实参会被静默截断高 32 位："
                                    "请先显式收窄（(int) 转型），或把 api 声明改成 %s",
                       ty_name(pty), ty_name(expr_ty_of(arg)), ty_name(expr_ty_of(arg)));
            if (is_dbl_node(arg))
              error_at(p->tok->loc, "这个 API 参数声明的是 int——double 实参会走 XMM 通道，声明与实参必须一致");
          }
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

// 段输出类别：0=串 1=字符 2=int 3=double 4=int_64（v1.7.0） 5=uint_32/uint_8 6=uint_64（v1.9.0）
static int seg_print_kind(Parser *p, Token *s0, Node *n) {
  // v1.2.3 浮点打印：double 段走 _flint_out_dbl（纯 FLINT 写的 double→字符串，见 main.c 内置输出库）——
  //   固定 6 位小数 + 四舍五入；负数/零/进位都由它自己处理。到达这里之前**已经不是静默**：
  //   上一版是编译期报错，现在是真支持（靠 v1.2.2 打通的 double 形参把值送进去）。
  if (expr_is_dbl(n)) return 3;
  // v1.9.0：**无符号必须排在 int_64 之前**——uint_64 也是"64 位值"（expr_is_i64 为真），
  //   顺序反了就会用有符号格式化器打出 18446744073709551615 的补码（-1）。
  //   uint_32/uint_8 走 32 位无符号器（uint_8 的值域 0..255 在 eax 里，同一条腿）。
  if (expr_is_u64(n)) return 6;
  if (expr_is_u32(n) || expr_ty_of(n) == TY_UINT8) return 5;
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
    // v2.12.0：char* 结构体字段 / char* 指针数组元素（ND_DEREF + ty=TY_PTR + elem=TY_CHAR）
    //   的值就是字符串首地址 → 与 char* 变量同一档整串输出。
    if (n->ty == TY_PTR && n->elem_ty == TY_CHAR) return 0;
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
                 : (k == 5) ? "_flint_out_u32"
                 : (k == 6) ? "_flint_out_u64"
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
  if (is_ident(t, "str") && t->next && is_punct(t->next, '(')
      && t->next->next && is_punct(t->next->next, '['))
    return true;
  // v2.3.0：str_into(dst, cap, [...]) —— 形态不同（前两个参数是表达式，不是 '['），
  //   但生成端共用同一套 begin/put/end 语句链（末尾换成 _flint_str_end_to）。
  if (is_ident(t, "str_into") && t->next && is_punct(t->next, '('))
    return true;
  return false;
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
                 : (k == 5) ? "_flint_str_put_u32"
                 : (k == 6) ? "_flint_str_put_u64"
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
  bool into = is_ident(kw, "str_into");   // v2.3.0：str_into(dst, cap, [...])
  p->tok = p->tok->next;   // 吃 str / str_into
  skip(p, '(');
  Node *dst = NULL;
  Node *cap = NULL;
  if (into) {
    // 目标缓冲（char* 表达式）+ 总字节数（int 表达式，**含结尾 0**）
    // v2.3.1：两参数形态 str_into(buf, [...]) —— dst 是数组时 cap 由**声明**推出来
    //   （编译器本来就知道 `char buf[64]` 有多大），省掉手算容量这个容易错的活。
    Token *dtok = p->tok;
    dst = assign(p);
    skip(p, ',');
    if (is_punct(p->tok, '[')) {
      LVar *dv = (dtok->kind == TK_IDENT) ? find_lvar(p, dtok) : NULL;
      if (!dv || dv->ty != TY_ARR)
        error_at(dtok->loc, "str_into(dst, [...]) 的 dst 必须是本函数里声明的数组（char buf[N];）—— "
                            "dst 是指针或表达式时请用三参数形态 str_into(dst, cap, [...])");
      cap = new_node(ND_NUM, NULL, NULL);
      cap->val = ty_arr_stride(dv->elem_ty) * dv->arr_len;
      cap->loc = dtok->loc;
    } else {
      cap = assign(p);
      skip(p, ',');
    }
  }
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
  int fe = find_func_by_name(p->prog, into ? "_flint_str_end_to" : "_flint_str_end");
  if (fe < 0)
    error_at(kw->loc, "内部错误：str 需要内置缓冲函数 %s（编译器注入缺失）",
             into ? "_flint_str_end_to" : "_flint_str_end");
  Node *end = new_node(ND_CALL, NULL, dst);
  end->func_index = fe;
  if (into) {
    // 参数链存法与 func_call 一致：rhs = 第 1 个参数，往后走 next
    dst->next = cap;
    cap->next = NULL;
    end->nargs = 2;
  } else {
    end->nargs = 0;
  }
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

// ===== v2.0.0：try 错误传播糖 =====
// 形态（只此一种）：  try <变量> = <表达式> ;
// 展开（D11 I1：只用已有语句，codegen 一行不动）：
//     <变量> = <表达式>;
//     if (<变量> != 0) { return <变量>; }
// 错误值约定 = 非 0（沿用全仓 `if (err != 0) return err;` 的惯用法）。
// 为什么左值只能是"单个变量"：展开要读两次左值（条件一次、返回一次），
//   带下标的左值（a[i++]）会被求值两次 ⇒ 直接编译错，不做局部求值一次的隐藏临时（那要花帧槽）。
// 为什么只允许返回 int 的函数：`return <变量>` 走的是已有 return 通路，错误码就是 int；
//   返回 void / 指针 / double 的函数没有"错误码"这个概念，直接编译错（不静默）。
static Node *try_stmt(Parser *p) {
  Token *kw = p->tok;
  p->tok = p->tok->next;   // 吃 try

  if (p->tok->kind != TK_IDENT || is_keyword(p->tok))
    error_at(p->tok->loc, "try 的形态是 `try <变量> = <表达式>;`（try 后必须是变量名）");
  Token *vn = p->tok;
  LVar *v = find_lvar(p, vn);
  if (!v)
    error_at(vn->loc, "try 的目标变量 '%.*s' 未声明（先在本函数里声明，如 int err = 0;）",
             vn->len, vn->loc);
  if (!(p->tok->next && is_punct(p->tok->next, '=')))
    error_at(p->tok->loc, "try 的形态是 `try <变量> = <表达式>;`（左值只能是单个变量，"
                          "不能是 a[i] / s.x —— 那样会被求值两次）");
  if (v->ty == TY_ARR || v->ty == TY_STRUCT || v->ty == TY_PTR || v->ty == TY_DOUBLE
      || v->ty == TY_FUNCPTR || ty_is64(v->ty))
    error_at(vn->loc, "try 的目标变量必须是 32 位整数（int / int_32 / char / uint_8 / uint_32；"
                      "错误码是 int，不接受 %s —— 64 位值 return 给 int 函数会静默截断）",
             ty_name(v->ty));
  if (p->fn_ret_void)
    error_at(kw->loc, "void 函数里不能用 try（没有返回值可带错误码）");
  if (p->fn_ret_ty != TY_INT)
    error_at(kw->loc, "try 只能用在返回 int 的函数里（本函数返回 %s；错误码约定是 int）",
             ty_name(p->fn_ret_ty));

  p->tok = p->tok->next->next;   // 越过 <变量> 和 '='，指向右值
  Node *rhs = assign(p);
  skip(p, ';');

  // 展开：三处变量引用各建一个节点（AST 是树，同一节点不能挂两处）
  Node *lhs1 = new_var_node(v->offset, v->is_ref, v->ty, v->struct_idx, v->elem_ty);
  lhs1->loc = vn->loc;
  Node *asgn = new_node(ND_ASSIGN, lhs1, rhs);

  Node *lhs2 = new_var_node(v->offset, v->is_ref, v->ty, v->struct_idx, v->elem_ty);
  lhs2->loc = vn->loc;
  Node *zero = new_node(ND_NUM, NULL, NULL);
  zero->val = 0;
  zero->loc = vn->loc;
  Node *cond = new_node(ND_NE, lhs2, zero);
  cond->ty = TY_INT;

  Node *lhs3 = new_var_node(v->offset, v->is_ref, v->ty, v->struct_idx, v->elem_ty);
  lhs3->loc = vn->loc;
  Node *ret = new_node(ND_RETURN, lhs3, NULL);
  ret->loc = vn->loc;

  Node *ifs = new_node(ND_IF, cond, ret);
  ifs->loc = kw->loc;

  Node head = {0};
  Node *cur = &head;
  cur = cur->next = new_node(ND_EXPR_STMT, asgn, NULL);
  cur = cur->next = ifs;
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
    // v1.7.0：+ int_64（8 字节 / 对齐 8，与 double、指针同族）
    // ===== 2026-10-24（v2.3）：**struct 指针字段** `struct S *next;` =====
    //   自引用天然可行：结构体名在字段循环**之前**就进了 prog->structs（上面的 nstructs++）。
    //   布局复用 int* 那一族（8 字节 / 对齐 8）。
    // ===== v2.4.0（本刀）：**struct 值字段** `struct B b;`（内层必须已定义）=====
    //   布局逐字节照 C：按内层自身的对齐（StructDef.align）落位，占内层 size 字节 ——
    //   `a.b.c` 因此就是 `*(a + off_b + off_c)`；帧槽数仍由外层 size 一次算死（new_lvar 不用改）。
    //   不做：自嵌套值字段（尺寸无穷）、嵌套数组字段（`struct B b[4];`）、前向/互相嵌套。
    if (is_ident(p->tok, "struct")) {
      p->tok = p->tok->next;
      Token *sn = p->tok;
      if (sn->kind != TK_IDENT || is_keyword(sn))
        error_at(sn->loc, "struct 后需跟类型名");
      int fsid0 = find_struct(prog, sn);
      if (fsid0 < 0)
        error_at(sn->loc, "未定义的结构体类型 '%.*s'（struct 须先定义后使用；"
                          "嵌套值字段不做前向引用——请把内层定义挪到外层之前）", sn->len, sn->loc);
      p->tok = p->tok->next;
      bool fptr0 = is_punct(p->tok, '*');
      if (fptr0) p->tok = p->tok->next;
      Token *fn0 = p->tok;
      if (fn0->kind != TK_IDENT || is_keyword(fn0))
        error_at(fn0->loc, "期望字段名");
      if (s->nfields >= 128)
        error_at(fn0->loc, "结构体字段上限 128");
      for (int i = 0; i < s->nfields; i++)
        if ((int)strlen(s->fields[i].name) == fn0->len
            && strncmp(s->fields[i].name, fn0->loc, (size_t)fn0->len) == 0)
          error_at(fn0->loc, "字段 '%.*s' 重复", fn0->len, fn0->loc);
      p->tok = p->tok->next;
      // ===== v2.13.0（struct 值语义第三刀）：**struct 数组字段** `struct E es[4];` =====
      //   布局 = 按内层对齐落位、占 `N × 8*ceil(size/8)` 字节；下标步长与局部 `struct E a[N]`
      //   **同一条口径**（8*ceil(size/8)，见 new_lvar 的槽数与 postfix 的 struct 数组下标）。
      //   ⚠️ 别照 C 的 sizeof 当步长：FLINT 的 struct 数组元素一直是 8 字节槽对齐的，
      //   两处用不同步长 = `w.es[1]` 与布局错位（编译过、静默写坏邻字段）。
      //   边界（全部响亮拒收）：自嵌套数组（尺寸无穷）、二维 `[2][3]`、struct 指针数组字段。
      int fsarr = 0;   // 0 = 不是数组字段（与 arr_len=1 的标量字段区分开）
      if (is_punct(p->tok, '[')) {
        if (fptr0)
          error_at(p->tok->loc, "struct 指针字段暂不支持数组形态（v2.3 边界）");
        p->tok = p->tok->next;
        Token *cnt0 = p->tok;
        // v2.15.0（G7）：与 `int buf[N]` 同一口径 —— 编译期常量（字面量 / enum 常量 / 常量表达式）
        long long fsv = 0;
        if (!parse_const_int(p, &fsv))
          error_at(cnt0->loc, "struct 数组字段长度须为正整数常量（字面量 / enum 常量 / 常量表达式）"
                              "——变量、函数调用、运行期量都不行（布局在 parse 期就得算死）");
        if (fsv <= 0)
          error_at(cnt0->loc, "struct 数组字段长度须为正整数常量（得到 %lld）", fsv);
        if (fsv > 2147483647LL)
          error_at(cnt0->loc, "struct 数组字段长度过大（%lld；上限 2147483647）", fsv);
        fsarr = (int)fsv;
        skip(p, ']');
        if (is_punct(p->tok, '['))
          error_at(p->tok->loc, "struct 数组字段只支持一维（`struct E es[N]`）——二维 "
                                "`struct E es[2][3]` 暂不支持；要二维请声明成一维 `es[2*3]` 自己算下标");
      }
      StructField *sf0 = &s->fields[s->nfields];
      sf0->name = malloc((size_t)fn0->len + 1);
      memcpy(sf0->name, fn0->loc, (size_t)fn0->len);
      sf0->name[fn0->len] = '\0';
      sf0->arr_len = fsarr > 0 ? fsarr : 1;
      if (fptr0) {
        sf0->ty = TY_PTR;
        sf0->elem = TY_INT;    // 指向类型走 sid（与 struct* 形参同一口径）
        sf0->sid = fsid0;
        sf0->offset = align_up(cur, 8);
        cur = sf0->offset + 8;
        has_ptr = true;
        if (max_align < 8) max_align = 8;
      } else {
        // 自嵌套拦截：当前结构体在字段循环**之前**就进了表（nstructs++），find_struct 找得到自己。
        //   指针形态的自引用合法（上面那支），**值**形态 = 尺寸无穷 ⇒ 必须先于布局检查。
        //   v2.13.0：数组形态 `struct A a[2]` 同样是值形态（N 份自身 = 尺寸无穷），一并拦。
        if (fsid0 == prog->nstructs - 1)
          error_at(sn->loc, "结构体不能把自身作为值字段（`struct %s { struct %s ... }` 尺寸无穷）——"
                            "数组形态 `struct %s a[N]` 同样不行；自引用请写指针形态 `struct %s *next;`",
                   s->name, s->name, s->name, s->name);
        StructDef *in = &prog->structs[fsid0];
        int ialign = in->align > 0 ? in->align : 1;
        sf0->sid = fsid0;
        sf0->offset = align_up(cur, ialign);
        if (fsarr > 0) {
          // 数组字段：元素步长 = 8*ceil(size/8)（与局部 struct 数组下标同一式子）
          int stride = 8 * ((in->size + 7) / 8);
          long long end = (long long)sf0->offset + (long long)stride * fsarr;
          if (end > 0x7FFFFFFFLL)
            error_at(fn0->loc, "结构体字段 '%s' 过大（%d 个元素 × %d 字节）——结构体总长不能超过 2GB",
                     sf0->name, fsarr, stride);
          sf0->ty = TY_ARR;
          sf0->elem = TY_STRUCT;   // 元素就是整个结构体（sid 说哪个）
          cur = (int)end;
        } else {
          sf0->ty = TY_STRUCT;
          sf0->elem = TY_INT;    // 值字段没有指向类型；只借用字段存类型（sid 才是真值）
          cur = sf0->offset + in->size;
        }
        if (ialign > max_align) max_align = ialign;
      }
      s->nfields++;
      skip(p, ';');
      continue;
    }
    // v1.9.0：+ uint_8/uint_32/uint_64（表示逐条沿用 char/int/int_64 —— 布局不新增第二个真源）
    int fty0 = type_kw_of(p->tok);
    bool fi64 = ty_is64(fty0);                 // 8 字节 / 对齐 8
    bool fchar = ty_is8(fty0);                 // 1 字节 / 对齐 1（char 与 uint_8）
    bool fdbl = (fty0 == TY_DOUBLE);
    bool fint = (fty0 == TY_INT || fty0 == TY_UINT32);
    if (!fchar && !fdbl && !fi64 && !fint)
      error_at(p->tok->loc, "结构体字段类型支持 char / int / int_64 / double / uint_8 / uint_32 / uint_64"
                            " / int* / char* / double* / 已定义 struct 的值或指针（v2.12）");
    p->tok = p->tok->next;
    // v1.3.2：函数指针字段（`int (*cb)(int);`）暂不做 —— 明确报错，别让 `(` 落到"期望字段名"那种含糊提示上
    if (is_punct(p->tok, '('))
      error_at(p->tok->loc, "结构体暂不支持函数指针字段（v1.3.2 边界）——"
                            "回调请存成局部函数指针变量，或把一个整数/地址字段 + 间接调用拆开写");
    bool fptr = consume(p, '*');   // int *p = 指针/句柄字段（8 字节）
    // ===== v2.12.0：**char * 字段** `char *name;` =====
    //   布局/表示与 int*/double*/struct* 字段**完全同族**：8 字节地址、对齐 8、偏移走
    //   StructField.offset / StructDef.size（不另算一套）；差别只在指向类型（f->elem = TY_CHAR），
    //   `*s.name` 按字节读、`s.name[i]` 按 1 字节缩放、`print([s.name])` 按字符串输出。
    //   原来这里把 ty_is8 的指针字段一律拒收（v1.0.5 边界），本轮收掉。
    //   uint_8* 同族（ty_is8 一并放行：指向类型保留无符号性，宽度仍 1 字节）。
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
      // v2.15.0（G7）：固定长度数组字段同样接受编译期常量（字面量 / enum 常量 / 常量表达式）
      long long fav = 0;
      if (!parse_const_int(p, &fav))
        error_at(cnt->loc, "数组字段长度须为正整数常量（字面量 / enum 常量 / 常量表达式）"
                           "——变量、函数调用、运行期量都不行（布局在 parse 期就得算死）");
      if (fav <= 0) error_at(cnt->loc, "数组字段长度须为正整数常量（得到 %lld）", fav);
      if (fav > 2147483647LL)
        error_at(cnt->loc, "数组字段长度过大（%lld；上限 2147483647）", fav);
      arr_len = (int)fav;
      skip(p, ']');
    }
    // v2.12.0：**指针数组字段**（`char *p[4];` / `int *p[4];`）仍不做 —— 但必须响亮拒收。
    //   旧实现会静默按「单个指针字段」布局（只留 8 字节），随后 s.p[i] 越界写到下一个字段上。
    //   本轮放开 char* 字段后这条静默路径更容易被踩到，故补上（文案与 struct* 数组字段同一条）。
    if (fptr && arr_len > 1)
      error_at(fn->loc, "struct 指针字段暂不支持数组形态（v2.3 边界）");
    StructField *f = &s->fields[s->nfields];
    f->sid = -1;   // 2026-10-24（v2.3）：普通字段必须显式 -1 —— memset 的 0 会让 int* 字段冒充"指向 struct 0"
    f->name = malloc((size_t)fn->len + 1);
    memcpy(f->name, fn->loc, (size_t)fn->len);
    f->name[fn->len] = '\0';
    f->arr_len = arr_len;
    // v1.7.0：基类型归一 —— 下面 ty/elem/align/fsz 四处都读它
    // v1.9.0：**不归一成同宽对照类型**：字段类型必须保留无符号性（打印/除法要知道）。
    //   读写宽度另由 codegen 的 ty_* 助手归一（uint_32 与 int 同宽），布局不新增第二个真源。
    int fbase = fty0;
    if (fptr) {
      f->ty = TY_PTR;
    } else if (arr_len > 1) {
      f->ty = TY_ARR;
    } else {
      f->ty = fbase;
    }
    f->elem = fptr ? fbase : fbase;
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
  s->align = has_ptr ? 8 : max_align;                 // v2.4：同一口径 —— 嵌套我时按这个对齐落位
  if (s->nfields == 0) error_at(name->loc, "结构体不能为空");
}

// ===== v2.15.0（G7）：**enum 定义预扫描** =====
// 为什么需要它：全局数组的 .data 布局（collect_globals）、struct 字段长度（preparse_structs）
//   都要在 parse 早期算死，而 enum 常量的登记原本发生在第二遍顶层循环（太晚）——
//   `enum K { POOL = 4 } struct E es[POOL];` 会报"须为数字常量"。
// 做法：在 preparse_structs / collect_globals **之前**把顶层 enum 定义按源序登记一遍；
//   第二遍顶层循环遇到 enum 只跳 token、不再重复解析（否则报"重复声明"）。
// 副作用（与 struct 预扫描同向放宽、可接受）：enum 常量的可见范围从"定义点之后"变成整个文件。
// 代价：登记时全局/函数表还没建 ⇒ 与全局变量/函数同名的冲突检查挪到 collect_funcs 之后补
//   （check_enum_conflicts），报错位置仍是定义处的名字 token。
static void preparse_enums(Token *tok, Program *prog) {
  Parser p = {0};
  p.tok = tok;
  p.prog = prog;
  int depth = 0;
  while (p.tok->kind != TK_EOF) {
    if (is_punct(p.tok, '{')) { depth++; p.tok = p.tok->next; continue; }
    if (is_punct(p.tok, '}')) { depth--; p.tok = p.tok->next; continue; }
    if (depth == 0 && is_ident(p.tok, "enum")) {
      Token *en = p.tok->next;
      if (en && en->kind == TK_IDENT && !is_keyword(en) && is_punct(en->next, '{')) {
        parse_enumdef(&p, prog);   // 消费整条定义（含 '}' / 可选 ';'），depth 不变
        continue;
      }
    }
    p.tok = p.tok->next;
  }
}

// ===== v2.13.0（struct 值语义第三刀）：**struct 定义预扫描** =====
// 为什么需要它：全局变量的 .data 布局在 collect_globals 里**一次算死**（doff 决定所有 [rip+disp32]），
//   而 struct 全局的尺寸/对齐只能从 StructDef 拿 —— 可 collect_globals 跑在第二遍（parse_structdef）
//   之前。原实现因此只能把 struct 全局整个拒掉。
// 做法：在 collect_globals 之前把**顶层 struct 定义**先解析一遍（源序 ⇒ 内层先定义这条判据不变），
//   第二遍的顶层循环遇到 `struct 名 {` 只跳 token、不再重复解析（否则报"重复定义"）。
// 副作用（已知、可接受）：结构体定义在文件里的**可见范围**从"定义点之后"放宽到"整个文件"——
//   原来"函数写在 struct 定义之前就用它"会报未定义，现在能用。方向是放宽，不会让既有合法程序变非法。
// 判据"顶层"与 collect_globals 同源：花括号深度 0 处的 `struct IDENT {`；函数体/形参里的不算。
static void preparse_structs(Token *tok, Program *prog) {
  Parser p = {0};
  p.tok = tok;
  p.prog = prog;
  p.next_offset = 8;   // 与 parse() 里的主 Parser 同初值（struct 解析不用它，只为口径一致）
  int depth = 0;
  while (p.tok->kind != TK_EOF) {
    if (is_punct(p.tok, '{')) { depth++; p.tok = p.tok->next; continue; }
    if (is_punct(p.tok, '}')) { depth--; p.tok = p.tok->next; continue; }
    if (depth == 0 && is_ident(p.tok, "struct")) {
      Token *sn = p.tok->next;
      if (sn && sn->kind == TK_IDENT && !is_keyword(sn) && is_punct(sn->next, '{')) {
        parse_structdef(&p, prog);   // 消费整条定义（含 '}'），depth 不变
        continue;
      }
    }
    p.tok = p.tok->next;
  }
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

// ===== v2.14.0：struct 按值返回的**用法后遍检查** =====
// 只有两个位置会给调用节点补隐藏返回缓冲（sret_ok）：
//   ① struct 变量声明初始化 / 整体赋值的右值（parse 的声明/赋值两支）；
//   ② struct 返回函数里的 `return f();`。
// 其余任何位置（`mk(1,2).x`、`f(mk(1,2))`、`p = mk(1,2) + 1`、把调用当语句丢弃……）都**明确报错**：
//   这些位置没有"目标变量"，硬发一条 call 会让被调方往一个不存在的缓冲里写（静默踩栈）。
// 为什么用后遍而不是在每个表达式入口各拦一次：入口有 10+ 个（实参/二元/条件/三元/下标/字段链…），
//   漏一处就是静默错值；"补过缓冲的调用才会有 sret_ok"是构造期就定死的事实，后遍扫一遍就完备。
static void check_sret_calls(Parser *p, Node *n) {
  if (!n) return;
  if (n->kind == ND_CALL) {
    FuncDef *f = n->func_index >= 0 ? &p->prog->funcs[n->func_index] : NULL;
    if (f && f->ret_ty == TY_STRUCT && !n->sret_ok) {
      const char *sn = (f->ret_struct >= 0) ? p->prog->structs[f->ret_struct].name : "S";
      if (n->loc) error_at(n->loc,
        "struct 按值返回的函数 '%s' 的调用只能出现在两个位置："
        "① `struct %s v = %s(...);` / `v = %s(...);` 的右值；"
        "② 按值返回 struct 的函数里的 `return %s(...);`。"
        "不能把结果塞进任意表达式（`%s(...).x` / f(%s(...)) / 参与运算 / 丢弃结果）——"
        "本语言没有 struct 整体值语义；请先赋给同类型 struct 变量再逐字段用",
        f->name, sn, f->name, f->name, f->name, f->name, f->name);
      error("struct 按值返回调用出现在不支持的位置（见上一条）");
    }
    for (Node *a = n->rhs; a; a = a->next) check_sret_calls(p, a);
    return;
  }
  check_sret_calls(p, n->lhs);
  check_sret_calls(p, n->rhs);
  check_sret_calls(p, n->els);
  check_sret_calls(p, n->init);
  check_sret_calls(p, n->cond);
  check_sret_calls(p, n->inc);
  check_sret_calls(p, n->next);
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
      error_at(t->loc, "double 字面量不能作为整数全局变量的初值"
                       "（会静默截断小数）——请把全局变量声明成 double");
    if (!isdbl && ty == TY_DOUBLE)
      error_at(t->loc, "double 全局变量的初值必须是浮点字面量（如 1.5，而不是 1）"
                       "——写成整数会被当成整数位型读成 5e-324");
    // v1.7.0：64 位字面量只能进 64 位全局（进 32/8 位 = 静默截断高 32 位 ⇒ 硬错）
    //   v1.9.0：uint_64 与 int_64 同宽，同样收
    if (!isdbl && t->kind == TK_NUM64 && !ty_is64(ty))
      error_at(t->loc, "这个全局变量是 %s，初值却是 64 位字面量（会静默截断高 32 位："
                       "值超出范围的部分丢掉）——请把全局变量声明成 int_64 / uint_64", ty_name(ty));
    if (isdbl) {
      double d = t->dval;
      if (neg) d = -d;
      memcpy(bytes + off, &d, 8);
    } else {
      long long v = (t->kind == TK_NUM64) ? t->lval : (long long)t->val;
      if (neg) v = -v;
      if (ty_is8(ty)) {           // char / uint_8：1 字节（0..255）
        if (v < -128 || v > 255)
          error_at(t->loc, "%s 全局变量初值 %lld 超出 0..255（字节类型）", ty_name(ty), v);
        bytes[off] = (uint8_t)v;
      } else if (ty_is64(ty)) {   // int_64 / uint_64：8 字节整体写（.data 里 64 位标量/元素都是 8）
        memcpy(bytes + off, &v, 8);
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
    // 类型词（v1.9.0：一律走 type_kw_of 单点表 —— uint_* 也在这里被认出来）
    int base_ty;
    bool is_struct_ty = false;
    int struct_sid = -1;   // v2.13.0：struct 全局的类型下标（preparse_structs 已把结构体表建好）
    int kw0 = type_kw_of(t);
    if (kw0 >= 0) { base_ty = kw0; t = t->next; }
    else if (is_ident(t, "struct")) {
      // v2.13.0：`struct S 名...` —— 结构体表此时已由 preparse_structs 填好，直接查 sid。
      Token *sn = t->next;
      if (!sn || sn->kind != TK_IDENT || is_keyword(sn)) continue;
      struct_sid = find_struct(prog, sn);
      if (struct_sid < 0) {
        error_at(sn->loc, "未定义的结构体类型 '%.*s'（struct 须先定义后使用）", sn->len, sn->loc);
        t = sn->next;
        continue;   // 已报错（g_err_count>0 ⇒ 不产 exe）；继续扫，别拿 -1 去算布局
      }
      is_struct_ty = true;
      base_ty = TY_INT;      // 标量基类型占位：struct 的尺寸/对齐只从 StructDef 取（下面分档）
      t = sn->next;
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
        // v2.15.0（G7）：全局数组长度 = 编译期常量（字面量 / enum 常量 / 常量表达式）。
        //   enum 常量已在 preparse_enums 阶段登记（本函数跑在其后）；变量/调用仍硬错。
        Parser gcp = {0};
        gcp.tok = sz;
        gcp.prog = prog;
        long long glen = 0;
        if (!sz) error_at(name->loc, "全局数组声明缺少长度");
        if (!parse_const_int(&gcp, &glen))
          error_at(sz->loc, "全局数组长度必须是正整数常量（字面量 / enum 常量 / 常量表达式）"
                            "——全局数组在 .data 里，长度编译期就得定；变量、函数调用都不行");
        if (glen <= 0) error_at(sz->loc, "全局数组长度必须为正（得到 %lld）", glen);
        if (glen > 2147483647LL)
          error_at(sz->loc, "全局数组长度过大（%lld；上限 2147483647）", glen);
        arr_len = (int)glen;
        Token *rb = gcp.tok;
        if (!rb || !is_punct(rb, ']')) error_at(sz->loc, "全局数组声明期望 ']'");
        after = rb->next;
        // v2.2.0：二维数组只开**局部**（.data 里的行列布局与全局初始化都还没定）
        if (after && is_punct(after, '['))
          error_at(after->loc, "全局二维数组暂不支持（只开局部 int m[行][列]；"
                               "全局要二维请用一维 g[行*列] 自己算下标）");
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

      // v1.10.0（IDE 服务端）：**标量指针全局**（int* / char* / double* / int_64* / uint_*）开放。
      //   过去这里两条 error 把指针与 struct 一起挡掉，而报错文案又推荐「请用 struct 指针全局变量」——
      //   那条建议自己也会撞上同样的 error（走不通的指路）。现按类型分档，只说真不支持的。
      //   v2.13.0：**struct 族全局全部开放**（按值 / 数组 / 指针）—— GlobalVar 加了 struct_idx，
      //   布局按 StructDef.size/align 走（见下面分档）。旧的「暂不支持 struct 按值/指针全局」两条负例
      //   在本轮改判（见 test\run-tests.js 的 ng_struct_init）。
      if (is_ptr && arr_len > 0)
        error_at(name->loc, "指针全局不支持数组形式（`int *g[4]` 是「4 个指针」——数组元素是指针的全局还没开）");

      // ===== v2.13.0：**布局分档**（标量族 / struct 族）=====
      //   struct 族的尺寸/对齐**只从 StructDef 取**（size/align 是布局期唯一真值，别在这里重算字段）；
      //   元素步长的口径必须与 postfix 的下标缩放**同一式子**（struct 数组元素 = 8*ceil(size/8)）。
      int elem_ty = base_ty;
      int ty = (arr_len > 0) ? TY_ARR : base_ty;
      int count = (arr_len > 0) ? arr_len : 1;
      int esize;
      int align;
      if (is_struct_ty) {
        StructDef *sd = &prog->structs[struct_sid];
        if (is_ptr) {
          // struct 指针全局：8 字节地址槽；指向哪个结构体记在 struct_idx（`gp->f` / `gp[i]` 要用）
          ty = TY_PTR; elem_ty = TY_INT; count = 1; esize = 8; align = 8;
        } else if (arr_len > 0) {
          // struct 数组全局：元素步长与局部 `struct E a[N]` 一字不差（8*ceil(size/8)）
          ty = TY_ARR; elem_ty = TY_STRUCT; count = arr_len;
          esize = 8 * ((sd->size + 7) / 8);
          align = sd->align > 0 ? sd->align : 1;
        } else {
          // 按值 struct 全局：占 StructDef.size 字节，按 StructDef.align 落位
          ty = TY_STRUCT; elem_ty = TY_INT; count = 1;
          esize = sd->size;
          align = sd->align > 0 ? sd->align : 1;
        }
      } else {
        if (is_ptr) { ty = TY_PTR; count = 1; }   // 指针：8 字节槽，elem_ty 记指向类型（codegen 已按 TY_PTR 走 64 位读写）

        // 元素对齐/尺寸 —— 必须与 **postfix 的下标缩放口径**（a[i] = *(a+i*esize)）严格一致！
        //   🐞 实测踩过真坑：这里原按 C 的 sizeof 摆（int=4），而下标缩放是语言口径（int 元素 8 字节槽）
        //   → `garr[2]` 算到 base+16 = **下一个全局变量的槽**上，静默写坏别处（"编译过、静默错值"）。
        //   判据：凡「布局尺寸」与「寻址步长」分处两个文件时，两处的元素宽必须写进同一张口径表。
        esize = ty_is64(base_ty) ? ty_arr_stride(TY_INT64)   // v1.7.0：标量/数组元素都是 8（值宽 = 步长）
              : ty_is8(base_ty) ? 1                          // v1.9.0：uint_8 与 char 同（1 字节）
              : (base_ty == TY_DOUBLE) ? 8
              : (arr_len > 0) ? ty_arr_stride(base_ty) : 8;   // v1.6.5：int/uint_32 数组元素 4 字节；全局 int 标量仍 8（读写 64 位约定）
        if (is_ptr) esize = 8;                                // 指针槽恒 8 字节（与局部指针变量同口径）
        align = (esize > 8) ? 8 : esize;
      }

      long long total = (long long)esize * count;
      // 2026-10-24：`.data` 用自己的上限 FLINT_MAX_DATA（原借 FLINT_MAX_TEXT，两个资源共用一个数）
      if (total > (long long)FLINT_MAX_DATA)
        error_at(name->loc, "全局变量过大（%lld 字节）——.data 单节上限 %d 字节",
                 total, FLINT_MAX_DATA);

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
      g->struct_idx = is_struct_ty ? struct_sid : -1;   // v2.13.0：非 struct 族显式 -1（0 冒充 struct 0）
      g->size = (int)total;
      g->doff = align_up(cur, align);
      g->init_len = 0;
      cur = g->doff + g->size;
      if (cur > FLINT_MAX_DATA)
        error_at(name->loc, "全局变量总量超出 .data 单节上限（%d 字节）——第一版不开放多节 .data",
                 FLINT_MAX_DATA);

      // 初值（只支持编译期常量；见 parse_global_init）
      if (is_punct(after, '=')) {
        if (is_struct_ty) {
          // v2.13.0：struct 全局**只开 .bss 语义**（无初值 ⇒ 全零，与 C 的 `struct E g;` 相同）。
          //   整体初始化列表不做（init[64] 也装不下一个结构体）；指针形态与标量指针同一红线。
          //   ⚠️ 两个分支各自写成**单条字面量**的 error_at（不写成三目 + 相邻字面量拼接）：
          //   tools\诊断ID.mjs 对「三目分支里的相邻字面量」只收录第一段，运行时 fmt 是拼好的整串
          //   ⇒ 查表落空、这条诊断就没有 ID（v2.10.0 的不变量）。拆成两条调用各自命中。
          if (is_ptr)
            error_at(after->loc, "struct 指针全局暂不支持初值——请在函数里赋值（例如 gp = &g; 或 gp = 0;）");
          else
            error_at(after->loc, "struct 全局变量暂不支持整体初始化（`struct E g = {...}`）——全局 struct 只有 .bss 语义（全零）；要初值请在 main 里逐字段赋值，或用局部 struct 造好后整体拷贝 g = 局部值");
          while (after->kind != TK_EOF && !is_punct(after, ',') && !is_punct(after, ';'))
            after = after->next;
        } else if (is_ptr) {
          error_at(after->loc, "指针全局暂不支持初值——请在函数里赋值（例如 g = 0; 或 g = new ...），"
                               "避免把 4 字节常量写进 8 字节指针槽");
        } else {
          Token *vt = after->next;
          int ilen = 0;
          const uint8_t *bytes = parse_global_init(vt, base_ty, count, esize, &ilen);
          // 2026-11-03（int4-abi）：这里原来量的是 `sizeof(g->init)` = 64 字节的**结构体字段容量**，
          //   于是「初值能进 .data」这件事被一个与 .data 无关的数组大小挡住（16 KiB 的 int 数组直接报错，
          //   用户只能退化成逐元素赋值 → 4096 个 mov）。现在按实际长度 malloc，且上面的
          //   `total > FLINT_MAX_DATA` 已经把单个全局变量框在 .data 单节容量内；这条检查留着当兜底
          //   （文案/诊断 ID 不变），上限口径改成 .data 单节上限而不是字段大小。
          if (ilen > FLINT_MAX_DATA)
            error_at(name->loc, "全局变量初值过长（%d 字节，上限 %d）", ilen, FLINT_MAX_DATA);
          if (ilen > 0) {
            g->init = malloc((size_t)ilen);
            if (!g->init) error("内存不足（全局变量初值）");
            memcpy(g->init, bytes, (size_t)ilen);
          }
          g->init_len = ilen;
          free((void *)bytes);
          // 跳过初值（含 '}' 与元素逗号）→ 停在 ',' 或 ';'
          // —— 2026-11-03（int4-abi）：必须**按花括号深度**跳，不能"见到第一个 ',' 就停"。
          //   为什么：`int g[3] = {1,2,3};` 的元素逗号在花括号里，旧写法停在那里，把 `t` 丢进初值中段；
          //   外层 for 继续逐 token 扫，扫到收尾的 '}' 时把它当成**函数体右括号**（depth-- ⇒ -1），
          //   于是 `depth != 0` 把**其后所有全局声明静默吞掉**（症状：`使用了未声明的变量 'g7'`，
          //   而源码里明明声明了）。多元素初始化列表天然带逗号 ⇒ 大数组初值一放开就必踩。
          //   判据：全局初值里的 ',' 是**元素分隔符**，只有花括号外的 ',' 才是声明分隔符。
          {
            int brace = 0;
            while (after->kind != TK_EOF) {
              if (is_punct(after, '{')) brace++;
              else if (is_punct(after, '}')) brace--;
              else if (brace <= 0 && (is_punct(after, ',') || is_punct(after, ';'))) break;
              after = after->next;
            }
          }
        }
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
    // v1.0.6：返回类型可 = int|char|void|double|int_64|uint_* | struct 名（指针返回 = 后跟 '*'）；找函数名跳过类型词
    bool is_ret = is_ident(t, "void") || is_ident(t, "struct") || type_kw_of(t) >= 0;
    if (!is_ret) continue;
    Token *name = t->next;
    // v1.2.1：预扫描就把**返回类型**记进函数表 —— 否则「先调用、后定义」的 double 返回函数
    //   在调用点解析时 fn->ret_ty 还是默认 0（int）→ 解析期的类型判定（expr_is_dbl / to_int 提升 /
    //   mkbin 自动提升）全部当它是 int，生成 `cvtsi2sd eax` 静默读错值（实测：to_int(half()) 得 0）。
    //   这里只读 token 判类型（真正的签名检查仍在 parse_funcdef，两处口径由本注释对齐）。
    //   v1.9.0：uint_* 也必须在这里认出来，否则"先调用、后定义"的 uint 返回函数会被当 int。
    bool ret_is_ptr = false;
    int pre_ret_ty = TY_INT;
    int pre_struct = -1;   // v2.14.0：`struct V f(...)`（按值返回）的结构体下标
    if (is_ident(t, "void")) pre_ret_ty = TY_INT;                 // void 由 parse_funcdef 置 ret_void
    else if (type_kw_of(t) >= 0) pre_ret_ty = type_kw_of(t);     // v1.9.0：单点表
    else if (is_ident(t, "struct")) {
      if (!name || name->kind != TK_IDENT || is_keyword(name)) continue;  // struct 类型名
      // v2.14.0：按值返回 struct —— 结构体表已由 preparse_structs 建好，这里能把下标提前落表。
      //   不落这一格的后果与 v1.2.1 的 double 返回同族：**先调用、后定义**时调用点把返回值当 int，
      //   声明初始化会走 int 赋值路径（静默错值）。指针返回（后跟 '*'）仍走老路，pre_struct 置 -1。
      if (!is_punct(name->next, '*')) {
        pre_struct = find_struct(prog, name);
        if (pre_struct < 0) continue;   // 未定义类型：交给 parse_funcdef 报精确错
      }
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
    // v2.14.0：struct 按值返回也提前落表（ret_ty = TY_STRUCT + ret_struct = 结构体下标）
    f->ret_ty = ret_is_ptr ? TY_PTR : (pre_struct >= 0 ? TY_STRUCT : pre_ret_ty);
    // v1.2.5：指针返回的**指向类型**同样要提前落表（理由与返回类型一致）——否则「先调用、后定义」的
    //   `*f()` / `f()[i]` 在调用点按 int 语义走：double* 会被当 int* 读 4 字节（静默错值）。
    f->ret_elem = ret_is_ptr ? pre_ret_ty : TY_INT;
    f->ret_struct = ret_is_ptr ? -1 : pre_struct;
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
            int psz = 0;
            pt = parse_funcptr_decl(&ps, q, pr_ty, pr_elem, -1, pr_void, &pn, &psz);
            // v2.6.0：函数指针**数组**作形参暂不支持 —— 预扫描这一路也必须响亮报错，
            //   否则它会静默把 `int (*t[2])(int)` 当成单个函数指针形参（"预扫描只补一个字段"家族）。
            if (psz > 0)
              error_at(pn->loc, "函数指针数组作函数形参暂不支持（v2.6.0 边界）——"
                                "请传单个函数指针，或在函数内声明数组后逐个赋值");
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
        int puns = -1;        // v1.9.0：无符号形参类型（uint_8/uint_32/uint_64）
        if (is_ident(pt, "double")) { pdbl = true; pt = pt->next; }
        else if (type_kw_of(pt) >= 0) {
          int pt0 = type_kw_of(pt);
          pi64p = ty_is64(pt0);
          if (ty_uns(pt0)) puns = pt0;
          pt = pt->next;
        }
        else if (is_ident(pt, "struct")) { pt = pt->next; if (pt) pt = pt->next; }   // 跳过 struct 类型名
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
                        : (puns >= 0 && !pdir) ? puns          // v1.9.0：uint_* 值形参
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
// 语法：api <模块短名> <int|int_64|uint_64|void|ptr|double> <函数名> ( <类型>, ... );
// 参数类型只影响**编译期检查**（64 位实参能不能进 / double 走不走 XMM）；发射侧按**实参表达式**
//   的类型落寄存器（emit_arg_rax_to_gp），不读声明 —— 所以这里记下来的 param_ty 是"检查口径"的单点。
// v1.4.8：模块名支持**字符串字面量**形式 `api "cabridge.dll" ...` / `api "E:\x\y.dll" ...`
//   （多语言交火·编译期缝合需要）——标识符词法不吃 '.'，故带点全名/带路径只能走字面量；
//   pe.c 侧规则：模块名含 '.' 或 '\' 就**原样用**，否则补 ".dll"（裸短名行为不变）。
//
// v1.11.0：同名重复声明的**比较口径**——逐参比"通道大类"，不是逐字比枚举：
//   · 相等 = 同一个类型；
//   · TY_INT 与 TY_PTR 视为同类：两者都是 32 位 GP 档（声明不参与发射；64 位实参对两者都硬错，
//     唯一差别是报错文案）。历史库里同一 API 有 `int(ptr)` / `int(int)` 两种写法（bgm vs sys_lib
//     的 GetFileAttributesA、flgui_win32 vs cn_lib 的 MultiByteToWideChar）——逐字比会让本来能
//     同单元编译的库组合突然硬错，这是无关回归，不是本刀要堵的洞；
//   · double 与 64 位整型**必须逐字相等**：这两档直接决定 XMM/GP 通道与"64 位实参放不放行"，
//     只差一档就是"先声明的那份静默生效、调用点按错宽度传"。
static bool api_param_same_class(int a, int b) {
  if (a == b) return true;
  return a != TY_DOUBLE && b != TY_DOUBLE && !ty_is64(a) && !ty_is64(b);
}
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
                           // v1.11.0（2026-11-04）：+ int_64 / uint_64（64 位整数返回，rax 全 64 位）
    int param_ty[API_MAX_ARGS];      // v1.11.0：参数 i 的声明类型（取代原 bool param_dbl[]，见 flint.h ApiDef）
    for (int i = 0; i < API_MAX_ARGS; i++) param_ty[i] = TY_INT;
    if (is_ident(tok, "void")) ret_void = true;
    else if (is_ident(tok, "ptr")) ret_ty = TY_PTR;
    else if (is_ident(tok, "double")) { ret_ty = TY_DOUBLE; ret_void = false; }   // v1.1.0：浮点返回（XMM0）
    // v1.11.0：64 位整数返回 —— **uint_64 不能并进 int_64**（打印/比较/右移的符号性不同）
    else if (is_ident(tok, "int_64")) { ret_ty = TY_INT64; ret_void = false; }
    else if (is_ident(tok, "uint_64")) { ret_ty = TY_UINT64; ret_void = false; }
    else if (!is_ident(tok, "int"))
      error_at(tok->loc, "api 返回类型须为 int / int_64 / uint_64 / void / ptr / double（ptr = 64 位句柄/指针；"
                          "int_64/uint_64 = 64 位整数，值走 rax 全 64 位）");
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
        // v1.11.0：形参类型逐档落表（声明侧唯一真相）；char/uint_8/uint_32 不单列 —— 都按 int 档（GP 32 位值）
        if (is_ident(tok, "double")) param_ty[nargs] = TY_DOUBLE;
        else if (is_ident(tok, "ptr")) param_ty[nargs] = TY_PTR;
        else if (is_ident(tok, "int_64")) param_ty[nargs] = TY_INT64;
        else if (is_ident(tok, "uint_64")) param_ty[nargs] = TY_UINT64;
        else if (!is_ident(tok, "int"))
          error_at(tok->loc, "api 参数类型只能是 int / int_64 / uint_64 / double / ptr（ptr = 64 位句柄/指针，"
                              "double = XMM 通道；int_64/uint_64 = 64 位整数，值走 GP 全 64 位）");
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
        // v1.11.0：签名 = 返回类型 + **逐参类型**（按 api_param_same_class 的口径；只看 nargs 会把
        //   `int f(int)` 与 `int f(int_64)` 判成同一个签名 ⇒ 先声明的那份静默生效、调用点按错宽度传）
        bool same = (ex->nargs == nargs && ex->ret_void == ret_void && ex->ret_ty == ret_ty);
        for (int k = 0; same && k < nargs && k < API_MAX_ARGS; k++)
          if (!api_param_same_class(ex->param_ty[k], param_ty[k])) same = false;
        if (same) {
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
    for (int i = 0; i < nargs && i < API_MAX_ARGS; i++) a->param_ty[i] = param_ty[i];   // v1.11.0
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

// ===== v2.8.0（B 阶段②）：死代码消除（语句层，保守）=====
// 只做三件"不可达"的事，**不做**常量传播/代数化简/寄存器分配：
//   ① `if (字面量)` → 只留被选中的那一支（无 else = 整条语句消失；两支都先递归优化过）；
//   ② `while (0)` / `for (; 0; ...)` → 删掉（`for` 的 init 在 C 里**执行一次** ⇒ 有 init 时只保留 init，
//      别把 `for (f(); 0;)` 的 f() 一起删了——那是可观察副作用）；
//   ③ 同一条链上 `return` / `break` / `continue` 之后的语句 → 删掉（不可达）。
//
// 为什么放在 parse_funcdef 的**最后**（-strict 未初始化/越界诊断、void 用法检查都跑完之后）：
//   那些检查都在原 AST 上做 ⇒ 删除语句不会让任何既有诊断变松/变紧（诊断口径零变化，门不会因此翻红）。
//
// ⚠️ `switch` 的 rhs 是**扁平语句链**，`case/default` 标记本身就是跳转入口 —— 那条链上**绝不截断**：
//   `break` 之后到下一个 case 之间的语句虽然不可达，但**下一个 case 标记仍可被跳进来**；
//   在链上做"终止符后全删"会把 case 标签一起删掉 = 静默删分支（编译过、行为错）。
//   所以 switch 链只逐条递归优化，不做链级截断。
static Node *opt_chain(Node *chain, bool in_switch);

// 返回替换后的语句链（NULL = 整条语句消失；可能把 if 分支/for-init 就地展开成链）
static Node *opt_stmt(Node *s) {
  if (!s) return NULL;
  switch (s->kind) {
    case ND_BLOCK:
      s->rhs = opt_chain(s->rhs, false);
      return s;
    case ND_IF:
      s->rhs = opt_stmt(s->rhs);          // 先优化两支（里面可能还有 if/while/block）
      s->els = opt_stmt(s->els);
      if (s->lhs && s->lhs->kind == ND_NUM)   // 条件已折叠成字面量
        return s->lhs->val ? s->rhs : s->els; // 被选中那一支（可能 NULL）
      return s;
    case ND_WHILE:
      s->rhs = opt_stmt(s->rhs);
      if (s->lhs && s->lhs->kind == ND_NUM && s->lhs->val == 0) return NULL;   // while (0) 整条删
      return s;
    case ND_FOR:
      s->rhs = opt_stmt(s->rhs);
      if (s->cond && s->cond->kind == ND_NUM && s->cond->val == 0) {
        if (!s->init) return NULL;                 // for (; 0; ...) ⇒ 什么都不执行
        if (!s->init->next) return s->init;        // init 恰好一条语句 ⇒ 只留它
        Node *b = new_node(ND_BLOCK, NULL, NULL);  // init 是声明链：包成块当一条语句（不产码）
        b->rhs = s->init;
        return b;
      }
      return s;
    case ND_SWITCH:
      s->rhs = opt_chain(s->rhs, true);            // 扁平链：只优化、不截断（见上面的长注释）
      return s;
    default:
      return s;
  }
}

static bool opt_is_terminator(Node *s) {
  return s && (s->kind == ND_RETURN || s->kind == ND_BREAK || s->kind == ND_CONTINUE);
}
// 这条语句链是否**必然**以终止符收尾（块看它最后一条；if 不算——只走一支不算必然）
static bool opt_chain_terminates(Node *chain) {
  if (!chain) return false;
  Node *last = chain;
  while (last->next) last = last->next;
  if (opt_is_terminator(last)) return true;
  if (last->kind == ND_BLOCK) return opt_chain_terminates(last->rhs);
  return false;
}

static Node *opt_chain(Node *chain, bool in_switch) {
  Node head = {0};
  Node *tail = &head;
  bool dead = false;                 // 本链已遇到终止符 ⇒ 后面的语句不可达
  for (Node *s = chain; s; ) {
    Node *rest = s->next;            // 先存后继（下面会把 s 摘下来重接）
    s->next = NULL;
    if (!dead) {
      Node *r = opt_stmt(s);
      if (r) {
        tail->next = r;
        while (tail->next) tail = tail->next;
        if (!in_switch && opt_chain_terminates(r)) dead = true;
      }
    }
    s = rest;
  }
  return head.next;
}


// ===== C1 阶段：函数级错误恢复 =====
// 恢复点记录：parse_funcdef 在吃函数体 '{' 之前把它记在这里。
//   解析中途 error_at/error → longjmp 回来 → 凭它做括号配平，跳到**本函数体结束之后**。
//   若错误发生在函数头（还没见到函数体 '{'），这里保持 NULL，改走"跳到下一个顶层项"。
static Token *g_recover_body_open = NULL;

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
  } else if (type_kw_of(p->tok) >= 0) {
    // v1.9.0：int_64 / uint_8 / uint_32 / uint_64 值返回（单点表；漏认 = 静默当 int 返回）
    ret_ty = type_kw_of(p->tok);
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "double")) {          // v1.2.1：double 值返回（结果走 xmm0）
    ret_ty = TY_DOUBLE;
    p->tok = p->tok->next;
  } else if (is_ident(p->tok, "int")) {
    p->tok = p->tok->next;
  } else {
    error_at(p->tok->loc, "函数返回类型须为 int / int_64 / char / double / uint_8 / uint_32 / uint_64 / void / struct 名（指针返回加 *）");
  }

  if (is_void_ret) {
    if (consume(p, '*'))
      error_at(p->tok->loc, "void 不能返回指针");
    if (fn->is_main)
      error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
    fn->ret_void = true;
  } else {
    // v2.14.0（struct 值语义第四刀）：**struct 按值返回** `struct V f(...)`。
    //   返回类型记 TY_STRUCT + ret_struct（字段早已存在）；调用约定在 codegen 侧实现为
    //   「隐藏返回缓冲指针 = 第 1 个整型参数」。`struct V *f()` 的老路（v1.0.6）**一字不动**。
    bool struct_val_ret = (ret_ty == TY_STRUCT && !is_punct(p->tok, '*'));
    if (consume(p, '*')) {                    // v1.0.6：指针/句柄返回（64 位 rax）
      // v1.2.5：double* 指针返回开放 —— 指向类型进 ret_elem（`*f()` / `f()[i]` 的读写宽度与缩放靠它）
      if (fn->is_main)
        error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
      // v1.9.0：指向类型/返回类型一律用**原值**（uint_8/uint_32/uint_64 不归一 —— 调用点要知道符号性）
      fn->ret_elem = (ty_isint(ret_ty) || ret_ty == TY_DOUBLE) ? ret_ty : TY_INT;
      fn->ret_struct = (ret_ty == TY_STRUCT) ? ret_sidx : -1;
      fn->ret_ty = TY_PTR;
    } else if (struct_val_ret) {
      if (fn->is_main)
        error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
      fn->ret_ty = TY_STRUCT;
      fn->ret_elem = TY_INT;
      fn->ret_struct = ret_sidx;
      fn->retbuf_off = 0;   // 下面解析完形参表后分配（形参槽从它之后开始）
    } else {
      if (fn->is_main && ret_ty != TY_INT)
        error_at(p->tok->loc, "main 必须返回 int（退出码 = main 返回值）");
      fn->ret_ty = (ty_isint(ret_ty) || ret_ty == TY_DOUBLE) ? ret_ty : TY_INT;   // v1.9.0：+ uint_*
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
  // v2.14.0：struct 按值返回的**隐藏返回缓冲指针**槽（rcx 收进来的那个地址）。
  //   放在参数之前分配 ⇒ 槽偏移 8，用户形参整体后移；它**不进** scope/all_lvars（用户不可见，
  //   调试变量表也不列它）——代码生成只靠 FuncDef.retbuf_off 找到它。
  p->fn_ret_struct = (fn->ret_ty == TY_STRUCT) ? fn->ret_struct : -1;  // 指针返回的 ret_struct 也存 sidx，别混
  p->fn_retbuf_off = 0;
  if (p->fn_ret_struct >= 0) {
    fn->retbuf_off = p->next_offset;
    p->next_offset += 8;
    p->var_count += 1;
    p->fn_retbuf_off = fn->retbuf_off;
  }
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
          int psz = 0;
          p->tok = parse_funcptr_decl(&ps, t0, pr_ty, pr_elem, -1, pr_void, &pn, &psz);
          // v2.6.0：数组形参要在**正式定义**这一路也拦住（预扫描已拦一道，两道同口径）
          if (psz > 0)
            error_at(pn->loc, "函数指针数组作函数形参暂不支持（v2.6.0 边界）——"
                              "请传单个函数指针，或在函数内声明数组后逐个赋值");
          if (fn->nargs >= FUNC_MAX_ARGS)
            error_at(pn->loc, "函数参数最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参，v1.4.26）",
                     FUNC_MAX_ARGS);
          int psig = add_sig(p, ps);
          LVar *v = new_lvar(p, pn, false, TY_FUNCPTR, 0, 0, -1, TY_INT);
          v->fn_sig = psig;
          v->is_param = true;     // v5（D-1）：变量位置表的 kind = param
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
      } else if (type_kw_of(p->tok) >= 0) {
        // v1.9.0：char / int_64 / uint_8 / uint_32 / uint_64 形参（单点表）
        //   uint_32 值形参走 32 位 GP 通道（与 int 同）；uint_64 值形参走 8 字节 GP 通道（与 int_64 同）；
        //   `T *p` 走 TY_PTR + elem=T（指向类型保留无符号性 → *p / p[i] 的读写宽度与除法都对）
        int pt0 = type_kw_of(p->tok);
        p->tok = p->tok->next;
        ty = pt0;
        elem = pt0;
        pchar = ty_is8(pt0);
        pi64 = ty_is64(pt0);
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
        error_at(p->tok->loc, "%s 引用形参暂不支持（v1.0.5：用 %s* 指针）", ty_name(elem), ty_name(elem));
      // v1.7.0：int_64 引用形参暂不支持（引用读是 32 位解引用 ⇒ 静默截断）；v1.9.0：uint_64 同
      if (ref && pi64)
        error_at(p->tok->loc, "%s 引用形参暂不支持（引用读是 32 位解引用，会静默截断）——"
                              "请用 %s *p 显式指针", ty_name(elem), ty_name(elem));
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
      LVar *v = new_lvar(p, an, ref, ty, 0, 0, sidx, elem); // PTR/STRUCT 携带结构体下标；int 系 -1
      v->is_param = true;     // v5（D-1）：变量位置表的 kind = param
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
  // v2.14.0：struct 按值返回 = 隐藏返回缓冲占用第 1 个整型参数（rcx）⇒ 用户参数上限减 1。
  //   （codegen 的 gen_call 用 `Node *args[FUNC_MAX_ARGS]`，补上隐藏参数后最多 FUNC_MAX_ARGS 个。）
  if (p->fn_ret_struct >= 0 && fn->nargs >= FUNC_MAX_ARGS)
    error_at(p->tok->loc, "struct 按值返回的函数最多 %d 个用户参数（第 1 个整型参数 rcx 被隐藏的"
                          "返回缓冲指针占用；其余函数仍是 %d 个）",
             FUNC_MAX_ARGS - 1, FUNC_MAX_ARGS);
  // C1：记录函数体 '{' 的位置 —— 解析中途报错时，恢复路径靠它做括号配平（见 parse_funcdef_recover）。
  //   放在 skip 之前：skip 失败（当前不是 '{'）时恢复路径会检查类型后退回"跳到下一个顶层项"。
  g_recover_body_open = p->tok;
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
  // slot4：帧**字节数**记在分槽现场（next_offset = 已用到的最高槽偏移；本地 int 只占 4 字节后
  //   `var_count * 8` 不再等于帧大小）。codegen 序言 sub rsp, frame 只读这个字段（再 16 对齐）。
  fn->frame_bytes = p->next_offset;

  // v2.14.0：struct 按值返回调用的**位置检查**（只有声明/赋值右值与直接 return 两处合法）。
  //   放在 DCE 之前：`return` 之后的死语句会被 DCE 掉，不能靠"反正不执行"放过（那是静默）。
  check_sret_calls(p, fn->body);

  // ===== v5（`-debug`，D-1）：本函数的**变量位置表**（调试器读局部量/形参的唯一依据）=====
  // 数据源 = p->all_lvars —— 与"给变量分槽"是**同一张表**（offset/ty/elem_ty/arr_len/struct_idx 全在 LVar 上），
  //   所以 JSON 里的 slot/type 不可能与 codegen 实际用的槽位分叉。
  // 为什么在这个位置做：块作用域此时已弹掉，但 all_lvars 链还完整；到 codegen 再遍历 AST 找声明
  //   就是第二套真值（本仓"两处口径"病的老配方）。
  // 开关：只在 `-debug` 时建（普通编译不分配这张表，产物与内存行为都不受影响）。
  fn->dbg_vars = NULL;
  fn->ndbg_vars = 0;
  if (flint_debug_info) {
    int nv = 0;
    for (LVar *v = p->all_lvars; v; v = v->all_next) nv++;
    if (nv > 0) {
      DebugVar *dv = calloc((size_t)nv, sizeof(DebugVar));
      if (!dv) { fprintf(stderr, "hlc: 内存不足\n"); exit(1); }
      int i = 0;
      for (LVar *v = p->all_lvars; v; v = v->all_next) {
        DebugVar *d = &dv[i++];
        d->name = v->name;                 // LVar 的名字内存全程序存活 ⇒ 共享，不再复制
        d->slot = -v->offset;              // 口径：rbp 相对偏移 = -(LVar.offset)
        d->line = v->line;
        d->kind = v->is_param ? 1
                : ((v->ty == TY_ARR || v->ty == TY_STRUCT) ? 2 : 0);   // 0=local 1=param 2=aggregate
        ty_decl_str(d->type, sizeof(d->type), v->ty, v->elem_ty, v->elem_ptr_ty,
                    v->arr_len, v->cols, v->struct_idx, p->prog);
      }
      fn->dbg_vars = dv;
      fn->ndbg_vars = nv;
    }
  }

  // v1.4.25（`-strict`）②：未初始化局部量检查。放在这里跑是因为：AST 已经齐了、
  //   p->all_lvars 也齐了（块作用域虽已弹出，但变量链还在）。
  if (flint_strict) strict_uninit_func(p, fn->body);

  // void 调用用法检查（结果不能当值）
  for (Node *s = fn->body; s; s = s->next) check_stmt_void(s);

  // v2.8.0（B 阶段②）：死代码消除。**放在所有 parse 期诊断之后**（-strict / void 用法检查
  //   都在原 AST 上跑过 ⇒ 诊断口径零变化）；只做不可达删除，codegen 一行未改。
  fn->body = opt_chain(fn->body, false);
}

// ===== C1 阶段：函数级错误恢复的实现 =====
// 粒度 = **一个函数**：某函数解析中报错 → longjmp 回本函数调用点 → 跳到该函数之后 → 继续下一个顶层项。
// 为什么不做语句级：语句级要在坏 AST 上继续解析，级联错误多，还可能原地打转（死循环）；
//   函数级的出口只有「解析完 / 跳到函数体后」，前进性可以一眼证明。
// 内存取舍：longjmp 跳过栈上清理 —— 出错函数里已分配但没挂进 AST 的 Node/LVar/Scope 会泄漏。
//   编译器是**短命进程**（一次编译一次 exit），这点泄漏可接受；本函数不尝试手工回收（回收反而可能二次释放）。
static bool tok_starts_toplevel(Token *t) {
  if (!t || t->kind != TK_IDENT) return false;
  return is_ident(t, "int") || is_ident(t, "int_64") || is_ident(t, "char")
      || is_ident(t, "double") || is_ident(t, "void") || is_ident(t, "struct")
      || is_ident(t, "uint_8") || is_ident(t, "uint_32") || is_ident(t, "uint_64")
      || is_ident(t, "enum") || is_ident(t, "api");
}

// 从函数体 '{' 起做括号配平，返回**匹配 '}' 之后**的 token。
// 前进性：open 是 '{'，返回值严格在它之后；缺右花括号时一路扫到 EOF 返回 EOF（仍在前进）。
static Token *skip_past_brace_group(Token *open) {
  int depth = 0;
  Token *t = open;
  for (; t && t->kind != TK_EOF; t = t->next) {
    if (is_punct(t, '{')) depth++;
    else if (is_punct(t, '}')) {
      depth--;
      if (depth == 0) return t->next;
    }
  }
  return t;   // EOF（函数体没配平：已经走到文件尾，保证不回头）
}

// 函数头就出错（还没见到函数体 '{'）时的兜底：从出错点扫到下一个**顶层**声明起点。
// 前进性：`advanced` 保证至少吃掉一个 token 才允许返回 —— 否则 p->tok 原地不动 → 主循环死循环。
// 括号深度从 start 扫到 from 现算（不猜），避免把形参表里的 `int` 误认成顶层声明。
static Token *skip_to_next_toplevel(Token *start, Token *from) {
  if (!from) return NULL;
  int paren = 0, brace = 0, brack = 0;
  for (Token *t = start; t && t != from && t->kind != TK_EOF; t = t->next) {
    if (is_punct(t, '(')) paren++;
    else if (is_punct(t, ')')) { if (paren > 0) paren--; }
    else if (is_punct(t, '[')) brack++;
    else if (is_punct(t, ']')) { if (brack > 0) brack--; }
    else if (is_punct(t, '{')) brace++;
    else if (is_punct(t, '}')) { if (brace > 0) brace--; }
  }
  bool advanced = false;
  Token *t = from;
  while (t && t->kind != TK_EOF) {
    if (is_punct(t, '(')) paren++;
    else if (is_punct(t, ')')) { if (paren > 0) paren--; }
    else if (is_punct(t, '[')) brack++;
    else if (is_punct(t, ']')) { if (brack > 0) brack--; }
    else if (is_punct(t, '{')) brace++;
    else if (is_punct(t, '}')) { if (brace > 0) brace--; }
    if (advanced && paren == 0 && brace == 0 && brack == 0 && tok_starts_toplevel(t))
      return t;
    t = t->next;
    advanced = true;
  }
  return t;   // EOF（或 NULL）
}

// 恢复现场（静态区）：setjmp 之后自动变量可能被 longjmp "clobber"（GCC -Wclobbered），
//   而恢复路径要用出错前的这些值 —— 一律存静态变量，不依赖被 longjmp 跳过的栈帧。
static struct {
  Parser *p;
  Program *prog;
  int fi;
  Token *start;
  Scope *scope;
  int scope_nest, loop_nest, switch_nest, depth;
  char *stmt_loc;
} g_recover_saved;

// 出错后的复位 + 跳转（独立函数：负责所有"弄脏了要擦干净"的状态）
static void recover_after_error(void) {
  Parser *p = g_recover_saved.p;
  Program *prog = g_recover_saved.prog;
  int fi = g_recover_saved.fi;

  // 复位 Parser 状态：longjmp 跳过 scope_pop / depth-- / loop_nest--，
  //   不清的话下一个函数会带着「作用域链、递归深度、循环深度」的残值解析 —— 轻则误报，重则再炸。
  p->scope = g_recover_saved.scope;          // 丢掉出错函数里没弹干净的作用域层
  p->scope_nest = g_recover_saved.scope_nest;
  p->loop_nest = g_recover_saved.loop_nest;
  p->switch_nest = g_recover_saved.switch_nest;
  p->depth = g_recover_saved.depth;          // 否则下一个函数一开始就撞 PARSE_MAX_DEPTH
  p->var_count = 0;
  p->next_offset = 8;
  p->all_lvars = NULL;
  p->fn_ret_struct = -1;   // v2.14.0：别让坏函数的"按值返回"标记漏到下一个函数
  p->fn_retbuf_off = 0;
  g_stmt_loc = g_recover_saved.stmt_loc;     // 语句行号游标不能带着坏函数的值

  if (g_recover_body_open && is_punct(g_recover_body_open, '{'))
    p->tok = skip_past_brace_group(g_recover_body_open);              // 已开体：配平到体后
  else
    p->tok = skip_to_next_toplevel(g_recover_saved.start, p->tok);    // 还没开体：扫到下一个顶层项

  // 半截函数不入 AST：清掉可能写了一半的签名信息（本轮有错不进 codegen，这里只为后续解析不受污染）
  FuncDef *fn = &prog->funcs[fi];
  fn->body = NULL;
  fn->nargs = 0;
  fn->ret_void = false;
  fn->ret_ty = TY_INT;
  fn->ret_elem = TY_INT;
  fn->ret_struct = -1;
  fn->retbuf_off = 0;   // v2.14.0：半截函数不留隐藏返回缓冲槽
  fn->var_count = 0;
  fn->frame_bytes = 0;  // slot4：半截函数不进 codegen，帧字节数一并清零
  fn->dbg_vars = NULL;
  fn->ndbg_vars = 0;
}

// parse_funcdef 的恢复外壳：两个调用点都走这里。
// 正常路径 = 原样调用；出错路径 = 复位 Parser 状态 + 跳到下一个函数。
static void parse_funcdef_recover(Parser *p, Program *prog, int fi) {
  // 防御：fi 必须落在预扫描函数表内。坏输入下的恢复可能让"解析调用数"超过预扫描登记数；
  //   越界就只跳 token、绝不碰 prog->funcs —— 宁可少报，也不能越界写坏内存（"不能崩"优先）。
  if (fi < 0 || fi >= prog->nfuncs) {
    p->tok = skip_to_next_toplevel(p->tok, p->tok);   // 至少前进一个 token，不会原地打转
    return;
  }

  g_recover_saved.p = p;
  g_recover_saved.prog = prog;
  g_recover_saved.fi = fi;
  g_recover_saved.start = p->tok;
  g_recover_saved.scope = p->scope;
  g_recover_saved.scope_nest = p->scope_nest;
  g_recover_saved.loop_nest = p->loop_nest;
  g_recover_saved.switch_nest = p->switch_nest;
  g_recover_saved.depth = p->depth;
  g_recover_saved.stmt_loc = g_stmt_loc;

  g_recover_body_open = NULL;
  if (setjmp(g_err_jb) == 0) {
    g_err_recovering = 1;
    parse_funcdef(p, prog, fi);
    g_err_recovering = 0;
    g_recover_body_open = NULL;
    return;
  }
  // —— 出错恢复路径（error_at/error 已经打印过）——
  g_err_recovering = 0;
  recover_after_error();
}

// —— v2.1.0 enum 定义：`enum Name { A, B = 3, C }` ——
// 口径（最小形态，不做类型/枚举变量/switch 完备性）：
//   - 首项 0，后续 = 上一项 + 1；显式赋值只认「整数字面量 / 已登记常量 / 负号 + 字面量」；
//   - 常量名与全局变量/函数/已有常量同名 = 编译期硬错（局部变量仍可遮蔽常量）；
//   - 常量在 parse 期折成字面量 ⇒ codegen 零改动、产物零变化。
static void parse_enumdef(Parser *p, Program *prog) {
  p->tok = p->tok->next;   // 吃 'enum'
  Token *nm = p->tok;
  if (nm->kind != TK_IDENT || is_keyword(nm))
    error_at(nm->loc, "enum 后需要名字（写法：enum Name { A, B }）");
  p->tok = p->tok->next;
  skip(p, '{');
  int next_val = 0;
  int count = 0;
  while (!is_punct(p->tok, '}')) {
    Token *it = p->tok;
    if (it->kind != TK_IDENT || is_keyword(it))
      error_at(it->loc, "enum 里期望常量名，得到 '%.*s'", it->len, it->loc);
    p->tok = p->tok->next;
    int val = next_val;
    if (is_punct(p->tok, '=')) {
      p->tok = p->tok->next;
      int neg = 0;
      if (is_punct(p->tok, '-')) { neg = 1; p->tok = p->tok->next; }
      if (p->tok->kind == TK_NUM) {
        val = p->tok->val;
        p->tok = p->tok->next;
      } else {
        int ei = find_enum(prog, p->tok);
        if (ei < 0)
          error_at(p->tok->loc, "enum 常量赋值只认整数字面量或已登记的枚举常量");
        val = prog->enums[ei].value;
        p->tok = p->tok->next;
      }
      if (neg) val = 0 - val;
    }
    // v2.15.0：与全局变量/函数同名的检查已挪到 check_enum_conflicts（预扫描时两表还没建）
    if (find_enum(prog, it) >= 0)
      error_at(it->loc, "枚举常量 '%.*s' 重复声明", it->len, it->loc);
    add_enum_const(prog, it, val);
    next_val = val + 1;
    count++;
    if (is_punct(p->tok, ',')) { p->tok = p->tok->next; continue; }
    break;
  }
  skip(p, '}');
  if (is_punct(p->tok, ';')) p->tok = p->tok->next;   // 末尾分号可选（`enum A { X };` 与 `enum A { X }` 都收）
  if (count == 0)
    error_at(nm->loc, "enum '%.*s' 里至少要有一个常量", nm->len, nm->loc);
}

// v2.15.0：enum 预扫描先于 collect_globals/collect_funcs，登记时这两张表还是空的 ⇒
//   原本在 parse_enumdef 里的"与全局变量/函数同名"检查挪到这里（collect_funcs 之后）补做。
//   常量自身的重复声明已在预扫描登记时查过；这里只补跨表冲突。
static void check_enum_conflicts(Program *prog) {
  for (int i = 0; i < prog->nenums; i++) {
    EnumConst *e = &prog->enums[i];
    if (!e->tok) continue;
    if (find_global(prog, e->tok) >= 0)
      error_at(e->tok->loc, "枚举常量 '%.*s' 与全局变量同名", e->tok->len, e->tok->loc);
    if (find_func(prog, e->tok) >= 0)
      error_at(e->tok->loc, "枚举常量 '%.*s' 与函数同名", e->tok->len, e->tok->loc);
  }
}

Program parse(Token *tok) {
  Program prog = {0};

  // v2.15.0：**enum 定义预扫描最先**——struct 字段长度与全局数组长度都要在扫布局时用常量值，
  //   而常量登记原本在第二遍顶层循环（太晚）。第二遍遇到 enum 只跳 token（见下）。
  preparse_enums(tok, &prog);
  // v2.13.0：**struct 定义预扫描**——collect_globals 要给 `struct E g;` 算 .data 的尺寸/对齐，
  //   而这两样只有 StructDef 知道；结构体表必须在全局布局之前建好。
  //   第二遍的顶层循环遇到 struct 定义只跳 token（见下），不会重复解析。
  preparse_structs(tok, &prog);
  // v1.3.0：全局变量预扫描**必须最先**——它把 .data 偏移一次算死，供函数体（含前向引用）
  //   建出 ND_VAR；同时它也跳过 API/函数定义，与 collect_funcs 共用同一套顶层识别口径。
  collect_globals(tok, &prog);
  // 第一遍：预登记函数名（前向调用可用）+ 顶部 API 声明（v0.8）
  collect_funcs(tok, &prog);
  collect_apis(tok, &prog);
  // v2.15.0：enum 常量与全局变量/函数同名的冲突（预扫描时两表还没建，这里补）
  check_enum_conflicts(&prog);
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
  //   tok, scope, var_count, next_offset, all_lvars, prog, fn_ret_void, scope_nest, loop_nest,
  //   switch_nest, fn_ret_dbl, fn_ret_ty, depth
  //   （v1.5.0 加 fn_ret_ty 时漏了这一处 ⇒ gcc 报 missing initializer、warn 门从 7 变 8；补 0 = TY_INT）
  //   （v2.7.0 加 depth 时同样补末位 0；Parser 全局只有这一处位置初始化）
  Parser p = { tok, NULL, 0, 8, NULL, &prog, false, 0, 0, 0, false, 0, 0, -1, 0 };
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
    if (is_ident(p.tok, "enum")) {
      seen_toplevel = true;
      // v2.15.0：定义已由 preparse_enums 登记（数组长度要先知道常量值）——这里只跳 token，
      //   别再 parse_enumdef（会报"重复声明"）。形态不完整时仍交 parse_enumdef 报准确错。
      Token *en = p.tok->next;
      if (en && en->kind == TK_IDENT && !is_keyword(en) && is_punct(en->next, '{')) {
        while (p.tok->kind != TK_EOF && !is_punct(p.tok, '}')) p.tok = p.tok->next;
        if (p.tok->kind == TK_EOF) error_at(p.tok->loc, "enum 缺少右花括号 '}'");
        else p.tok = p.tok->next;
        if (is_punct(p.tok, ';')) p.tok = p.tok->next;   // 末尾分号可选
      } else {
        parse_enumdef(&p, &prog);
      }
      continue;
    }
    if (is_ident(p.tok, "struct")) {
      seen_toplevel = true;
      // struct 定义 = struct 名 { ... }；其余 struct 名 开头 = 全局 struct 声明 或 函数
      //   （v1.0.6 指针返回 struct S *f()；非法的值返回 struct P f() → 交 parse_funcdef 报精确错）
      Token *sn = p.tok->next;
      Token *after = (sn && sn->kind == TK_IDENT) ? sn->next : NULL;
      if (after && is_punct(after, '{')) {
        // v2.13.0：定义已由 preparse_structs 解析（全局布局要先知道尺寸）——这里只跳过 token，
        //   别再 parse_structdef（会报"重复定义"）。
        while (p.tok->kind != TK_EOF && !is_punct(p.tok, '}')) p.tok = p.tok->next;
        if (p.tok->kind == TK_EOF) error_at(p.tok->loc, "结构体缺少右花括号 '}'");
        else p.tok = p.tok->next;
        continue;
      }
      // v2.13.0：**全局 struct 声明**（按值 / 数组 / 指针）——collect_globals 已登记 .data 偏移，
      //   这里只跳过整条声明。判据与标量全局同一套：声明符扫到 ';' / '=' / ','。
      //   名字后跟 '(' 的仍是函数（struct S *f()），交给 parse_funcdef_recover。
      if (after) {
        Token *end = scan_declarator(after);
        if (end && (is_punct(end, ';') || is_punct(end, '=') || is_punct(end, ','))) {
          while (p.tok->kind != TK_EOF && !is_punct(p.tok, ';')) p.tok = p.tok->next;
          if (p.tok->kind == TK_EOF) error_at(p.tok->loc, "全局 struct 声明缺少 ';'");
          else p.tok = p.tok->next;
          continue;
        }
      }
      parse_funcdef_recover(&p, &prog, fi);   // C1：函数级错误恢复（出错不退出，继续下一个函数）
      fi++;
      continue;
    }
    if (!is_ident(p.tok, "void") && !is_ident(p.tok, "struct") && type_kw_of(p.tok) < 0)
      error_at(p.tok->loc, "顶层只允许 struct 定义、函数定义或全局变量声明"
                           "（int/int_64/char/double/uint_8/uint_32/uint_64/void 名称(...) "
                           "或同组类型 名称[= 常量];）");
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
                           "（int/int_64/char/double/uint_8/uint_32/uint_64/void 名称(...) "
                           "或同组类型 名称[= 常量];）");
    parse_funcdef_recover(&p, &prog, fi);   // C1：函数级错误恢复（出错不退出，继续下一个函数）
    fi++;
  }
  // C1：有错时不再要求"解析数 == 预扫描数"——恢复路径可能跳过坏掉的顶层项，
  //   这是错误恢复的预期行为，不是内部错误（无错路径口径完全不变）。
  if (g_err_count == 0 && fi != prog.nfuncs)
    error_at(tok->loc, "内部错误：函数解析数与预扫描不一致");
  // C1：有错 → 打一行汇总，main.c 见 g_err_count > 0 就不进 codegen、不产 exe。
  //   只在**多错**时打：单错输出必须与 C1 之前一字不差（判据 3）。
  if (g_err_count > 1)
    fprintf(stderr, "hlc: 共 %d 个错误，未生成产物\n", g_err_count);
  return prog;
}
