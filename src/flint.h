// flint.h — FLINT 编译器公共定义（v0.5 野路子：函数调用 → 自产机器码 PE）
#ifndef FLINT_H
#define FLINT_H

// 对外发布版本（开源版）：只此一处真源 —— 编译器 `-h` 打印它，取数器 version 键读它。
// 内部开发史（v1.x 那些记号）只留在注释/进度档案里，不再作为"当前版本"对外。
#define FLINT_VERSION "0.1.0"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// v0.9：-safe 编译模式开关（main.c 置位；parse 做内存所有权强制检查）
extern bool flint_safe_mode;
// v1.4.11（`-debug`）：可审计发射层的总开关（main.c 在 codegen_main **之前**置位；
//   与 flint_safe_mode 同一套路 —— codegen 拿到的是 Program，而"产物形态开关"挂在 GenResult 上、
//   要等 codegen 返回后才由 main.c 填，所以这个开关必须走全局）。
extern bool flint_debug_info;
// v1.4.19（-stats）：按函数的发射统计（账本；关时零开销、产物逐字节不变）
extern bool flint_stats;
// v1.4.25（`-strict` 诊断档）：默认关。**只加诊断、绝不改产物** —— 关着的时候产物与从前逐字节相同
// （这条由 test\等价门.ps1 守着：本档上线后指纹基线一行未变）。
extern bool flint_strict;
void flint_stats_func_begin(const char *name);
void flint_stats_func_end(size_t npc_bytes);
void flint_stats_dump(void);

// ========== 词法 ==========
typedef enum {
  TK_IDENT, // 标识符（含关键字，parser 判定）
  TK_NUM,   // 整数
  TK_STR,   // 字符串字面量 "..."（v0.7.3：sval=解码后字节，slen=字节数，不含 \0）
  TK_PUNCT, // 运算符/分隔符
  TK_EOF,   // 文件结束
  TK_DBL,   // v1.1.0：浮点字面量（dval=已解析的 double 值）——与 TK_NUM 分开，不放宽整数规则
  TK_NUM64, // v1.7.0：64 位整数字面量（lval=已解析的 long long）——**追加在末尾**，
            //   与 TK_NUM 分开：TK_NUM 仍是 32 位值（0xFFFFFFFF = -1 的位型语义一个字节不动）。
            //   词法规则（tokenize.c）：十进制 > INT32_MAX 自动升级 ｜ 十六进制 > 0xFFFFFFFF 或
            //   9 位以上按 64 位位型 ｜ `L` 后缀强制 64 位。
} TokenKind;

typedef struct Token Token;
struct Token {
  TokenKind kind;
  Token *next;
  int val;        // TK_NUM：数值
  char *loc;      // 源码位置（报错用）
  int len;        // 文本长度
  int line;       // 行号（1 起）
  char *sval;     // TK_STR：解码后内容（malloc，含内部字节，不含末尾 \0）
  int slen;       // TK_STR：内容字节数
  double dval;    // v1.1.0：TK_DBL 的已解析值（词法层就转成 double，后续各层只认值）
  long long lval; // v1.7.0：TK_NUM64 的已解析值（不经 double，2^53 以上不丢位）
};

Token *tokenize(char *p, char *filename);   // v0.9.1：filename 用于报错头（可 NULL）
// v1.4.11（可审计发射层，`-debug`）：由源码位置反查「所属源文件序号 / 文件内行号」。
//   实现与报错定位同源（tokenize.c 的 src_spans 表）⇒ 调试信息与编译器报错的 file:line 口径一致。
//   反查不到时：index 返回 -1、line 返回 1（不猜也不炸）。
int src_file_index_of(char *loc);
int src_line_of(char *loc);
int src_file_count(void);        // 本次编译登记过的源文件数（含 include 与内建库）
char *src_file_name(int i);      // i 越界返回 NULL
void error_at(char *loc, char *fmt, ...);
void error(char *fmt, ...);

// ========== 语法（AST）==========
// v0.7：指针/数组。节点：声明/赋值/return/if/while/for/块/函数调用/解引用；
// 表达式含比较与逻辑短路。
typedef enum {
  ND_NUM,     // 数字
  ND_STR,     // 字符串字面量（v0.7.3：str=str 内容指针，str_len=字节数；值=数据段地址）
  ND_VAR,     // 读变量（ty=TY_ARR 时 = 首元素地址，退化）
  ND_ASSIGN,  // 赋值 a = expr（lhs=变量/解引用）
  // 算术
  ND_ADD, ND_SUB, ND_MUL, ND_DIV, ND_MOD, ND_NEG,
  // 幂（v1.0.11）：lhs ^^ rhs——int 幂，快速幂发射（决策 49）
  ND_POW,
  // 位运算（v0.7.2）
  ND_BITAND, ND_BITOR, ND_BITXOR, ND_SHL, ND_SHR, ND_BITNOT,
  // 自增自减（lhs = 变量/解引用）
  ND_PRE_INC,   // ++x 值=新
  ND_PRE_DEC,   // --x 值=新
  ND_POST_INC,  // x++ 值=旧
  ND_POST_DEC,  // x-- 值=旧
  // 比较（结果 0/1）
  ND_EQ, ND_NE, ND_LT, ND_LE, ND_GT, ND_GE,
  // 复合赋值（lhs=变量/解引用, rhs=表达式；表达式值=新值）
  ND_ADD_ASSIGN, ND_SUB_ASSIGN, ND_MUL_ASSIGN, ND_DIV_ASSIGN, ND_MOD_ASSIGN,
  // 位复合赋值（v0.7.2）
  ND_AND_ASSIGN, ND_OR_ASSIGN, ND_XOR_ASSIGN, ND_SHL_ASSIGN, ND_SHR_ASSIGN,
  // 逻辑短路
  ND_LOGAND, ND_LOGOR, ND_NOT,
  // —— 语句 ——
  ND_RETURN,    // return 表达式;
  ND_EXPR_STMT, // 表达式语句
  ND_IF,        // if (cond) then [else els]：lhs=cond, rhs=then, els=else
  ND_WHILE,     // while (cond) body：lhs=cond, rhs=body
  ND_FOR,       // for (init; cond; inc) body
  ND_BLOCK,     // { stmt* }：rhs=语句链头
  // —— v1.2.0 循环控制（C 语义：只管最内层循环）——
  ND_BREAK,     // break;    跳出最内层循环（跳到循环的 end 标签之后）
  ND_CONTINUE,  // continue; 直接进下一轮（while=跳条件；for=**先执行增量再判条件**，与 C 一致）
  // —— v0.5 函数调用 ——
  ND_CALL,      // 调用：func_index=被调函数下标；rhs=参数链表（rhs->next 串行）
  ND_APICALL,   // v0.8 外部 API 调用：api_index=Program.apis 下标；rhs=参数链表（Win64 ABI+shadow）
  // —— v0.6 引用 / void ——
  ND_ADDR,      // 取变量地址（lhs=ND_VAR）：普通变量 lea；引用变量 = 槽内容（已是地址）
  ND_REF_BIND,  // 引用声明绑定：lhs=ND_VAR(引用变量 r)，rhs=ND_VAR(x)；r 槽 = x 的地址
  // —— v0.9.3 回调机制：函数地址 ——
  ND_FUNC_ADDR, // &函数名 = 函数代码地址（WNDPROC 等回调：lea rax,[rip+disp]，布局后回填）
  // —— v1.1.0 浮点（阶段1）——
  ND_DBL,       // double 字面量：dval = 解析后的值（内容按 8 字节常量进数据区，movsd 加载）
  ND_I2D,       // int → double 自动提升（cvtsi2sd）
  ND_D2I,       // double → int 显式转换（to_int；cvttsd2si 截断取整）
  // —— v0.7 指针/数组 ——
  ND_DEREF,     // 解引用（lhs=地址表达式）：读 = [addr]；作赋值/复合/++ 的 lhs = 写内存目标
  // —— v0.9 内存管理（安全模式地基）——
  ND_NEW,       // new 表达式：api_index=内置 VirtualAlloc 下标；val=负载字节（int=8）
  ND_SHARED_ACQUIRE, // v0.9 share 拷贝初始化：lhs=ND_VAR(share q)，rhs=ND_VAR(p share)；
                     // 语义 = q 槽=p 值 + [p-8] refcount++（共享所有权）
  // —— v1.3.1 三元 / switch ——
  ND_TERN,      // 条件 ? 真值 : 假值：lhs=条件, rhs=真分支, els=假分支（只求值被选中那一支）
  ND_SWITCH,    // switch (条件) { ... }：lhs=条件；rhs=**扁平语句链**，其中 ND_CASE 节点是段标记
                //   （不是子树！case 段的内容就是链上它后面的兄弟语句——这样 fallthrough 天然成立）
  ND_CASE,      // case 常量 / default 段标记（只出现在 ND_SWITCH 的 rhs 链上）：
                //   val=case 常量值；is_default=default 段；label_id=生成期分配的标签号
  // —— v1.7.0 int_64（64 位有符号整数）——
  ND_NUM64,     // 64 位字面量：lval = 值（codegen: mov rax,imm64）
  ND_I2L,       // int → int_64 拓宽（符号扩展：movsxd rax,eax）——隐式提升用
  ND_L2I,       // int_64 → int 显式收窄（to_int32；取低 32 位）
  // —— v1.8.0 C 风格转型 `(type)expr` ——
  //   **一个节点覆盖全部转型**：ty = 括号里的目标类型（TY_INT/TY_INT64/TY_CHAR/TY_DOUBLE/TY_PTR），
  //   lhs = 操作数；源类型在发射点用共用判据回推（expr_is_dbl / expr_is_i64 / is_addr_expr）。
  //   为什么不自造一堆 I2L64/I2D64/TRUNC8 节点：那样每个新节点都要在 expr_is_dbl / expr_is_i64 /
  //   is_addr_expr / is_addr_value / tern_addr_info / 打印分派里各补一档（6 处，漏一处 = 静默错值）；
  //   ND_CAST 让"结果类型"只有一个来源 = node->ty。
  //   指针转型（(T*)p）在这里**只换类型、不产码**（elem_ty/struct_idx 记指向类型）。
  ND_CAST,
} NodeKind;

// 变量类型（v0.7 起；v0.7.x 加结构体）
typedef enum {
  TY_INT,    // int 值（8 字节槽存值）
  TY_PTR,    // 指针（槽存地址；显式 * 解引用；struct_idx = 指向的结构体，int 指针为 -1）
  TY_ARR,    // int a[N]（N 个槽；名字作表达式 = 首槽地址）
  TY_STRUCT, // 结构体变量（nfields 个 8 字节槽；名字作表达式 = 首地址；无整体值语义）
  TY_CHAR,   // v1.0.5 B 档：char 无符号字节（0..255）——读 = movzx 零扩展、写 = 只写低字节；
             //   变量仍占 8 字节槽（上层字节可为旧值，一律 movzx 读低字节，语义安全）
  TY_DOUBLE, // v1.1.0：double 双精度浮点（IEEE754 binary64）——槽 8 字节，值走 xmm0；
             //   int→double 自动提升（同 C）；double→int 必须显式 to_int（防静默截断）
  TY_FUNCPTR,// v1.3.2：函数指针（C 风格声明 `int (*fp)(int)`）——槽 8 字节存**代码地址**（64 位，
             //   与 TY_PTR 同族：判真/比较/赋值走 64 位通路）；签名信息在 Program.sigs[fn_sig]。
             //   ⚠️ 与 TY_PTR 的区别：TY_PTR 是**数据**指针（可变宽度解引用），TY_FUNCPTR 只能被调用
             //   （`fp(args)` → FF D0 间接调用），不能解引用、不能算术、不能下标——这些一律编译期报错。
  TY_INT64,  // v1.7.0：int_64 = 64 位有符号整数。
             //   ⚠️ 与 TY_INT 的区别不是"更宽"，而是**值宽 = 槽宽 = 元素步长**三者相等
             //   （8 / 8 / 8）⇒ 不存在"半槽读写"，`p[i] == *(p + i*8)`。
             //   不进 T1「装地址的 int」标记机制（它本来就是 8 字节）；
             //   不进寄存器分配（slotmap.c 的类型门 `s->ty != TY_INT` 自动排除）。
             //   **必须**是独立枚举值（不做 TY_INT 的位标志）：parse 83 处 / codegen 27 处
             //   `TY_INT` 判据靠"不匹配"落到安全侧，位标志会让它们静默变宽。
             //   末尾追加 ⇒ TY_INT 仍是 0（slotmap.c:48/:201 拿 0 当默认）。
} Type;

// —— v0.7.x 结构体 ——
typedef struct {
  char *name;  // 字段名
  int ty;      // v0.9.2：字段类型 TY_INT（4 字节，对齐 4）｜ TY_PTR（8 字节指针/句柄字段，对齐 8）
               //   v1.4.4：+ TY_ARR = **固定长度数组字段**（`int buf[8]` / `char buf[64]`）
  int elem;    // v1.2.5：指针字段的**指向类型**（double* → TY_DOUBLE；int* → TY_INT）——
               //   `*s.p` 的读写宽度、`s.p[i]` 的下标缩放都靠它（非指针字段 = TY_INT）
               //   v1.4.4：数组字段 = 元素类型（int/char/double）
  int arr_len; // v1.4.4：数组字段的元素个数（非数组 = 1）
  int offset;  // 距结构体首地址（v0.9.2：真实 C 布局，按字段类型对齐累加；旧版 = 字段序 × 8）
} StructField;

typedef struct {
  char *name;         // 结构体类型名
  int nfields;
  StructField fields[128]; // 字段上限 128（v1.4.4：32 → 64；2026-09-27：64 → 128 ——
                           //   FLGUI 的 `GuiCtx` 已 64/64 满（面板要加的阴影/二级色/焦点圈没地方放），
                           //   真实 Win32 结构也动辄 40+ 字段。⚠️ boot 侧同一上限（`lib_parse.fl` 的
                           //   `st_nfields >= 128`）必须同步，否则又成"boot 比真 flint 窄"的双端断点）
  int size;           // v0.9.2：总字节 = 末字段后按最大对齐取整（C 布局；帧内槽数 = ceil(size/8)）
} StructDef;

typedef struct Node Node;
struct Node {
  NodeKind kind;
  Node *lhs;
  Node *rhs;
  Node *els;     // ND_IF 的 else 分支
  Node *init;    // ND_FOR 初始化（表达式）
  Node *cond;    // ND_FOR 条件（可 NULL=永真）
  Node *inc;     // ND_FOR 增量（表达式）
  Node *next;    // 语句链（块内按序串行）/ ND_CALL 的参数链
  int val;       // ND_NUM：值
  long long lval;// v1.7.0：ND_NUM64 的值（64 位；不经过 double ⇒ 2^53 以上不丢位）
  double dval;   // v1.1.0：ND_DBL 的值（按位型进数据区，movsd 加载）
  char *str;     // ND_STR：字符串内容（token 的 sval，同生命周期）
  int str_len;   // ND_STR：内容字节数
  int offset;    // ND_VAR/ND_ASSIGN：变量距 rbp 的偏移
  int func_index;// ND_CALL：被调函数在 Program.funcs 的下标
  int api_index; // ND_APICALL：API 在 Program.apis 的下标（v0.8）
  int nargs;     // ND_CALL：参数个数（0..4）
  int ty;        // ND_VAR：变量类型（Type；TY_ARR 时 offset = 首槽）
                 // v0.9.2：ND_DEREF = 读取目标的类型（TY_PTR 字段 → 64 位读；int → 32 位读）
                 //          ND_APICALL = API 返回类型（ApiDef.ret_ty：ptr → 地址类 64 位语义）
                 // v1.0.6：ND_CALL = 被调函数返回类型（指针返回 TY_PTR → 调用表达式按地址类 64 位）
  int elem_ty;   // v1.0.5 B 档：TY_ARR 的元素类型 / TY_PTR 的指向类型（char* 的字节语义）；
                 //   TY_INT 默认（0）——int 数组/指针旧语义；TY_CHAR → 元素/解引用按字节（movzx/88）
  int struct_idx;// TY_STRUCT：Program.structs 下标；TY_PTR：指向的结构体（int* 为 -1）
  bool is_ref;   // ND_VAR：变量是引用（槽里存地址，读写自动解引用）
  // v1.3.0：ND_VAR 是**全局变量**（存 .data 的 rip 相对地址，不是 rbp 帧槽）。
  //   ⚠️ 置位时 offset 字段存的是 Program.globals 下标，**绝不能**传给 emit_*_var 一族
  //   （那些全是 rbp 寻址）——两套寻址是所有全局变量 bug 的总源头。
  bool is_global;
  bool is_void;  // ND_CALL：被调函数返回 void（结果不能当值用）
  bool is_own;// v0.9 ND_VAR/声明左值：own 独占指针（作用域出口自动释放；禁止拷贝/重赋值）
  bool is_share;// v0.9 ND_VAR/声明左值：share 引用计数指针（拷贝 +1/出口 -1/归零释放）
  bool is_default; // v1.3.1：ND_CASE 是 default 段（不是 case 常量）
  int label_id;  // v1.3.1：ND_CASE 生成期分配的标签号（emit_label / jcc 目标）
  int fn_sig;    // v1.3.2：ND_VAR(ty==TY_FUNCPTR) / 间接 ND_CALL 的**签名表下标**（Program.sigs）
                 //   ⚠️ 间接调用的判据是 `func_index < 0 && fn_sig >= 0`；直接调用恒为 func_index>=0
  char *loc;     // v0.9.1：节点对应源码位置（报错定位用；ND_CALL/ND_APICALL 构建时记录，
                 //          后遍检查（void 误用等）无 p->tok 可用时 error_at 定位）
  // v1.4.11（`-debug` 可审计发射层）：语句级**行号 + 源文件序号**。parse.c 建节点时从"当前语句起始
  //   token"刻进来（与编译器报错同源 —— 都走 tokenize.c 的 src_spans 表）；line==0 表示没记到。
  int line;
  int file;
};

// ===== v1.1.0 浮点（阶段1）：表达式是不是 double =====
// parse 用它做 int→double 自动提升的**同一张判据**，codegen 也用它选 SSE 通路——
// 两边必须共用（首版 codegen 自己另判，导致「幂/widen 后的节点」判据不一致）。
bool expr_is_dbl(Node *n);
Node *expr_widen_dbl(Node *n);              // 需要 double 时，把 int 侧包一层 ND_I2D

// ===== v1.7.0 int_64：与 expr_is_dbl 同族的**单一判据** =====
// ⚠️ 必须 parse 与 codegen **共用**（`flint.h` 这一处）：浮点首版就是 codegen 自己另判，
//   导致「幂/widen 后的节点」判据不一致（见上一条注释的教训原文）。
bool expr_is_i64(Node *n);                  // 这个表达式的值是不是 int_64（含混合运算的提升结果）
Node *expr_widen_i64(Node *n);              // 需要 64 位时把 32 位侧包一层 ND_I2L（符号扩展）
// ===== D3：宽度口径的**单点表**（值宽 / 元素步长两列）=====
// 病根：本仓已有 4 处各抄一份元素宽（parse.c 的 new_lvar 槽数、postfix 的下标缩放、
//   ptr_step_elem_width 的 -strict 诊断、collect_globals 的 .data 布局），而
//   parse.c:2915-2918 记着这条 bug 的真实事故：`.data` 按 4 摆、下标按 8 缩放 ⇒ 静默写坏下一个
//   全局变量。第 5 个类型（int_64）若再手抄一份就是第 5 次分裂 —— 六处调用点一律走下面两个函数。
//   今天两列**数值相同**（char 1 / int 4 / int_64 8 / double 8 / 指针 8），但两列分开命名：
//   "值宽"回答「一次读写几个字节」，"元素步长"回答「a[i] 的 i 缩放几倍」——混成一个数
//   在下一轮改宽度时一定出错（`int` 的元素步长 4 / 全局标量 8 就是现成的反例）。
int ty_value_bytes(int ty);                 // 值宽：char 1 / int 4 / int_64 8 / double 8 / 指针 8
int ty_arr_stride(int ty);                  // 元素步长（下标缩放）：同上（int_64 = 8，无半槽）

// ========== v1.3.0 全局变量（PE 第二节 .data）==========
// 设计要点（2026-09-13；2026-09-15 更正）：全局变量不需要重定位表，是因为**产物里没有任何绝对地址**
//   （代码用 `[rip+disp32]` 指到 .data，只有 disp 差值）——**与是否 ASLR 无关**。
//   ⚠️ 原文写「DllCharacteristics=0 = 无 ASLR（永远加载在 ImageBase 0x140000000）」，2026-09-14 实测证伪
//   （见「新路候选.md」§1.1 事实 3）；这条真不变量 v1.3.4 起由 pe.c 的 I1 断言守着。
//
// 布局（唯一真源）：.text @ FLINT_TEXT_RVA(0x1000) ｜ .data **紧贴 .text 之后**（两节虚拟地址必须连续）
//   ⚠️ 实测教训（本项工程最费时的一个坑）：`.data` 的 RVA 我先后写死过 0x2000 / 0x3000 / 0x4000 /
//     0x100000 —— **只有「恰好紧贴 .text」的那一种 Windows 肯加载**（判据 = 节虚拟地址连续），
//     其余一律报「指定的可执行文件不是此操作系统的有效应用程序」。所以它不是常量，
//     而是 DATA_RVA = FLINT_TEXT_RVA + align_up(.text 实际虚拟大小, SEC_ALIGN)。
//   因此 `[rip+disp32]` 的 disp **不能一次算死**（取决于 .text 多大）→
//     由 pe.c 在算完 .text 大小后统一回填（GenResult.guses 机制，见 codegen_main 收尾）。
#define FLINT_TEXT_RVA 0x1000          // .text 的 RVA（= 入口点；main 代码在代码块最前）
#define FLINT_TEXT_RAW 0x200           // .text 文件偏移 / SizeOfHeaders 的**下限**（唯一真源，pe.c/TSV 同用）
// v1.4.13：**头大小改成自适应**（上面那个 0x200 从此只当**下限**）。
//   为什么：节表本身有长度 —— 5 节时头部已到 0x210、6 节到 0x238，而 SizeOfHeaders 与 .text 文件偏移
//   原来写死 0x200 ⇒ **头把 .text 开头盖住 16/56 字节**，节表却仍写 0x200（实测：产物入口点字节成了
//   `00 00`，跑起来就是 0xC0000005；`-debug -admin` 组合其实早就坏了，被"弹窗样本等于 timeout"掩盖）。
//   单点计算在 pe.c：`pe_headers_size(pe_nsec_all(...))`，pe.c 与 main.c 的 TSV 共用同一份算式。
int pe_nsec_all(int two_sec, int has_admin, int has_debug);
uint32_t pe_headers_size(int nsec_all);
#define FLINT_MAX_TEXT 0x100000        // 代码上限 1 MiB（保守值，远小于 disp32 的 ±2GB）

// .data 内一个全局变量
typedef struct {
  char *name;
  int len;
  int ty;          // Type：TY_INT / TY_CHAR / TY_DOUBLE / TY_INT64（标量）｜ TY_ARR（数组）
  int elem_ty;     // TY_ARR 的元素类型 / TY_PTR 的指向类型
  int arr_len;     // TY_ARR：元素个数（非数组 = 1）
  int size;        // 本变量占的字节数
  int doff;        // 在 .data 内的字节偏移（已按类型对齐；**不含** DATA_RVA）
  int init_len;    // 初值字节数（0 = 全零，仅 .bss 语义；C 的 `int g;` 全局 = 0）
  uint8_t init[64];// 初值字节（标量/小数组）。⚠️ int 元素是 **8 字节槽**（同数组寻址口径），
                   //   故 int a[N]={...} 每元素占 8 字节 → 上限 = 8 个 int。更长的数组初值会明确报错
                   //   （不静默截断）；要长数组请用「声明 + 运行时赋值」。
} GlobalVar;

// ========== 程序（多函数）==========
// v0.6：函数返回类型 int 或 void；参数可带引用（int &a——槽存地址，自动解引用）。
// 参数 = 函数帧里的普通变量槽（parse 时从 rbp-8 起分配，装载代码在函数序言生成）。
//
// v1.4.26（2026-09-27）：**函数形参 / 实参上限**从 4 抬到 32（原"寄存器传参 rcx/rdx/r8/r9"）。
//   规范依据 = Microsoft「x64 calling convention」（learn.microsoft.com，2026-09-27 实取）：
//     ① 「The caller must always allocate sufficient space to store four register parameters」⇒ shadow 恒 32B
//     ② 「Any parameters beyond the first four must be stored on the stack after the shadow store」
//     ③ 「Remaining arguments are passed on the stack in right-to-left order … 8-byte alignment for each」
//     ④ 浮点第 5 个起也是落栈（参数表）；⑤ 「The stack pointer must remain 16-byte aligned」
//   ⇒ 调用者侧：第 5 参起在 [rsp+32+(i-5)*8]（**右→左求值**），总分配 16 对齐（codegen.c: gen_call_many）；
//     被调方侧：rbp+0=旧 rbp、+8=返回地址、+16..+47=shadow ⇒ **第 5 参在 [rbp+48+(i-5)*8]**。
//   上限**单点定义**在这里：FuncDef 四个数组、FuncSig 两个数组、parse 的四处检查与三处清零、
//   codegen 的实参暂存数组全用它（"上限写死两处、改一处漏一处"本项目已栽过）。
//   ⚠️ boot（自举侧）**没有全局变量** ⇒ 那边只能写字面量 32，必须靠 `test\边界探针.ps1` 复核
//      （纪律：boot 写死的上限一律拿探针复核 ——「当年对齐过」≠「现在还齐」）。
#define FUNC_MAX_ARGS 32

// —— v1.5.0 str 内建（str([段, ...]) → char*）的静态缓冲上限：**单点定义在这里** ——
//   注入库（src/main.c 的 LIB_* 分块）里数组声明与超限判定都用 FLINT_STRBUF_CAP_S（"4096" 的字面量形式），
//   parse.c 的全字面量编译期核算用 FLINT_STRBUF_CAP ⇒ 两处**必须同步**；
//   main() 启动时有一条自检（atoi(FLINT_STRBUF_CAP_S) != FLINT_STRBUF_CAP → 直接报错退出）防漂移。
//   语义：可用内容 = CAP-1 字节（末字节固定留给结尾 0）；超过 ⇒ str() 整个返回 0（响亮失败，不静默截断）。
#define FLINT_STRBUF_CAP 4096
#define FLINT_STRBUF_CAP_S "4096"
typedef struct {
  char *name;          // 函数名
  bool is_main;        // 是否 main（入口，须 int 返回、无参）
  bool ret_void;       // 返回类型 void（无返回值函数；main 不得 void）
  int ret_ty;          // v1.0.6：返回类型 TY_INT/TY_CHAR（值语义）｜ TY_PTR（指针/句柄返回，64 位 rax）
  int ret_elem;        // v1.0.6：指针返回的指向类型（char* → TY_CHAR；int* → TY_INT；默认 TY_INT）
  int ret_struct;      // v1.0.6：struct S* 返回的结构体下标（-1 = 非结构体指向）
  int nargs;           // 参数个数 0..FUNC_MAX_ARGS（v1.4.26 由 4 抬到 32）
  int param_offsets[FUNC_MAX_ARGS];// 参数 i 的变量槽偏移（距 rbp）
  bool param_ref[FUNC_MAX_ARGS];   // 参数 i 是引用形参（调用点传地址）
  int param_ty[FUNC_MAX_ARGS];     // v0.8：参数 i 的类型（TY_INT/TY_PTR/TY_STRUCT；装载宽度用）
                       //   v1.3.2：也可以是 TY_FUNCPTR（形参本身是函数指针 → GP 64 位装载，
                       //   调用点还要拿 param_sig[i] 比签名）
  int param_sig[FUNC_MAX_ARGS];    // v1.3.2：参数 i 是函数指针时的签名下标；否则 -1。
                       //   ⚠️ 预扫描（collect_funcs）也必须落这个字段 —— 「预扫描只补一个字段」
                       //   家族已经栽过 4 次，凡是**调用点/被调方要读的字段**都得在预扫描里齐。
  Node *body;          // 函数体语句链表头
  int var_count;       // 本函数帧变量槽数（参数 + 局部）
} FuncDef;

// v0.8：外部 API 声明（api <dll> <返回> <名>(参数...);）
// dll 为短名（kernel32/user32/gdi32 → pe.c 拼 .dll）；参数全按 Win64 寄存器传（值零扩展/地址全 64）。
// v0.9.2：返回类型记 ret_ty —— int（值）｜ void（ret_void）｜ ptr（64 位句柄/指针，如 HWND/HMODULE，
//         声明后 API 调用表达式按地址类参与 64 位写/比较，可直入 struct 指针字段，不再依赖 int* 变量绕道）
// v1.4.0：API 实参上限 12 → 16（4 寄存器 + 12 栈参）。动机 = 真 Windows API 里有超过 12 参的
//   常用函数：CreateFontA 是 **14 参**（字形层/浮窗还原第一步直接撞上限，"API 参数最多 12 个"）。
//   上限单点定义在 API_MAX_ARGS：声明侧（parse.c）、调用侧（codegen.c 暂存数组）、
//   ApiDef.param_dbl 三处共用，避免"改一处漏一处"（历史上"预扫描只补一个字段"家族已 5 次）。
#define API_MAX_ARGS 16

// v1.4.28（B1-3）：导入模块名（写出名）上限 —— pe.c 的 ImpGroup.dll 是 char[64]，
//   名字超过 IMPORT_DLL_NAME_MAX 字节会被写出端 snprintf 截断 ⇒ 导入表里是"半个路径"，
//   编译期零提示、进程启动期 0xC0000135（旧行为实测：编译 exit 0）。
//   单点：下面两个函数由 pe.c 定义（含自动补 ".dll" 的判据），pe.c 写出端与 parse.c 的
//   默认档守卫共用；boot 侧有一份自己的等价实现（boot\lib_parse.fl 的 parse_apis）。
#define IMPORT_DLL_NAME_MAX 63
int  pe_import_module_name_len(const char *declared);                 // 写出名总字节数（含补的后缀）
void pe_import_module_name(const char *declared, char *out, size_t cap);

typedef struct {
  char *dll;           // 模块短名（如 user32）
  char *name;          // FLINT 侧绑定的名字（源码里写的名字）
  char *import_name;   // v1.1.0：真实导出名（`api msvcrt int p(int) as "printf";`）——NULL = 与 name 相同
  int nargs;           // 参数个数 0..API_MAX_ARGS
  bool ret_void;       // 返回 void
  int ret_ty;          // v0.9.2：非 void 返回类型 TY_INT（默认）｜ TY_PTR（64 位句柄/指针）
  bool param_dbl[API_MAX_ARGS];  // v1.1.0 浮点（阶段1）：参数 i 是 double → 走 XMM（int 侧仍按顺序占 rcx/rdx/r8/r9）
} ApiDef;

// ========== v1.3.2 函数指针：签名表 ==========
// FN_SIG_NONE：没有签名（非函数指针对应的所有节点/变量都用它）——显式取 -1 而不是 0，
//   因为 0 是**合法的签名下标**（第一个签名），拿 0 当"无"就是下一篇静默 bug。
#define FN_SIG_NONE (-1)
// 声明 `int (*fp)(int, double)` 的类型信息。**函数指针变量只存地址，签名在这里查**——
// 调用点靠它做「实参个数 / 双通道（GP vs XMM）/ 形参是不是传地址」三条检查，
// 生成侧靠它决定实参落哪个寄存器（与 gen_call 对直接调用的口径**逐条一致**）。
//
// ⚠️ 与 FuncDef 的关系：FuncDef 是"函数自己的签名"，FuncSig 是"函数指针类型写的签名"，
//   两者必须能互相比较（`fp = &foo` 要判 foo 的签名与 fp 的类型是否一致）——
//   所以下面这个构造器 sig_of_func() 是**唯一**把 FuncDef 翻成 FuncSig 的地方，别在别处再写一份。
typedef struct {
  bool ret_void;    // 返回 void（调用结果不能当值用）
  int  ret_ty;      // TY_INT / TY_CHAR / TY_DOUBLE / TY_PTR（64 位地址返回）
  int  ret_elem;    // ret_ty==TY_PTR 时的指向类型（char* / double* …）
  int  ret_struct;  // ret_ty==TY_PTR 且指向 struct 时的结构体下标（-1 = 非结构体）
  int  nargs;       // 参数个数 0..FUNC_MAX_ARGS（沿用 FLINT 的参数上限，v1.4.26 = 32）
  int  param_ty[FUNC_MAX_ARGS]; // 参数 i 的类型（TY_INT/TY_CHAR/TY_DOUBLE/TY_PTR/TY_STRUCT/TY_FUNCPTR）
  int  param_sig[FUNC_MAX_ARGS];// 参数 i 若本身是函数指针 → 它的 sig 下标；否则 -1
} FuncSig;

// 结构体：既要在 parse 内造签名、也要在 codegen 侧被间接调用读取（codegen 只读 nargs/返回类型，
// 参数通道仍按「实参表达式是不是 double」分派 —— 与直接调用同一条路，见 gen_call 注释）

typedef struct {
  FuncDef *funcs;      // 函数数组（动态，源定义序）
  int nfuncs;
  int main_index;      // main 下标（-1 = 无，语法层已保证有）
  StructDef *structs;  // v0.7.x：结构体类型表（动态，源定义序）
  int nstructs;
  int structs_cap;
  ApiDef *apis;        // v0.8：外部 API 表（动态，声明序）
  int napis;
  int apis_cap;
  // v1.3.0 全局变量：声明序数组 + .data 总长（按页取整）。codegen 靠 globals[gi].doff 算 rip disp，
  //   pe.c 靠 data_size 定 .data 节大小并拷贝 init 字节。
  GlobalVar *globals;
  int nglobals;
  int globals_cap;
  int data_size;       // .data 节大小（按 SEC_ALIGN 取整；0 = 无全局）
  int api_alloc;       // v0.9：内置 kernel32!VirtualAlloc 的 apis 下标（-1=源码未用 new）
  int api_free;        // v0.9：内置 kernel32!VirtualFree 的 apis 下标（-1=未用）
  // v1.3.2 函数指针：签名表（声明序；FN_SIG_NONE = 无签名 / 非函数指针）
  FuncSig *sigs;
  int nsigs;
  int sigs_cap;
} Program;

Program parse(Token *tok);

// ========== 代码生成（自写 x86-64 机器码编码器）==========
// 字节缓冲：动态增长
typedef struct {
  uint8_t *data;
  size_t len;
  size_t cap;
} Buf;

void buf_init(Buf *b);
void buf_byte(Buf *b, uint8_t x);            // 1 字节
void buf_bytes(Buf *b, const uint8_t *p, size_t n);
void buf_u32(Buf *b, uint32_t x);            // 小端 4 字节
void buf_u64(Buf *b, uint64_t x);            // 小端 8 字节
// 在偏移处回填 4 字节小端（disp32 修正用）
void buf_patch_u32(Buf *b, size_t off, uint32_t x);

// ========== 每函数代码生成上下文（v0.4.4 重构 / v0.5 多函数）==========
// 每函数一个 FuncCtx：函数内 label/patch 独立、动态数组（无硬上限）；
// 函数间 call 用 exts（外部引用）记录，全部函数生成完、布局定后再二次回填。
typedef struct {
  size_t off;   // 待回填 rel32 在 code 内的偏移
  int label;    // 目标 label id
} Patch;

// 函数间 call：call rel32 的目标是另一个函数的 code 起点（布局后才知道）
typedef struct {
  size_t off;    // E8 占位 rel32 在本函数 code 内的偏移
  int target;    // 目标函数在 Program.funcs 的下标
} ExtCall;

// v0.7.3：字符串引用——lea rax,[rip+disp32] 的 disp 待回填；
// 目标 = 数据段（拼接 code 尾部）内偏移，全部函数生成完、字符串区排布后统一回填
typedef struct {
  size_t off;     // lea 指令 disp32 在本函数 code 内的偏移
  char *str;      // 内容字节（token 解码后，不含末尾 \0）
  int len;        // 内容字节数
  size_t str_off; // 排布后：本串在数据段内的起始偏移
} StrRef;

// v0.8：API 调用引用——FF15 [rip+disp32] 的 disp 指向 IAT 槽；
// IAT 槽 RVA 由 pe_build 按导入布局决定，须经 GenResult 汇总后回填
typedef struct {
  size_t off;    // FF15 占位 disp32 在 code 内的偏移（拼接后为全局偏移）
  int api;       // Program.apis 下标
} ApiCallRef;

// v0.9.3：函数地址引用——&函数名 的 lea rax,[rip+disp32] disp 待回填；
// 目标 = 目标函数的 code 起点（布局后按 ctx 偏移回填，机制同 ExtCall）
typedef struct {
  size_t off;     // lea 指令 disp32 在本函数 code 内的偏移
  int target;     // 目标函数在 Program.funcs 的下标
} FuncAddrRef;

// v1.1.0 浮点（阶段1）：double 常量引用——movsd xmm0,[rip+disp32] 的 disp 待回填；
// 目标 = 数据段尾部（字符串区之后，按 8 字节对齐）内的 8 字节位型
// ⚠️ 2026-09-13（v1.2.1 途中实证的真 bug）：off 原为**单个** size_t —— 同一个常量在一次编译里
//   被用两次以上时（`double a = 2.0; … if (a * 2.0 == …)`），后一次登记会把 off **覆盖**掉，
//   前一处 movsd 的 disp32 就永远不回填（disp=0 → 运行时 `[rip+0]` 读成 0.0，静默错值）。
//   改成「一条记录 = 一份数据 + 一张出现位置表」，每个出现位置都各自回填。
typedef struct {
  unsigned long long bits; // 值的 IEEE754 位型（同一个值只占一份数据）
  size_t *offs;            // 各次出现：movsd 指令 disp32 在本函数 code 内的偏移
  size_t noffs;
  size_t offs_cap;
} DblRef;

// v1.3.0 全局变量引用——`[rip+disp32]` 指向 .data 内某全局变量的 disp32 待回填。
//   与 DblRef 分开的理由：目标地址是 **DATA_RVA + globals[gi].doff**（节内偏移），
//   而 DblRef 的目标是「拼接后 code 尾部」的偏移——两套基准，混在一起回填必错。
//   gi 在生成期就已知（parse 定的），所以一条记录只需 (site, gi)，无需去重表。
typedef struct {
  size_t off;   // disp32 在本函数 code 内的偏移
  int gi;       // Program.globals 下标
} GUse;

// v1.4.11（`-debug`）：一条「语句 → 发射字节区间」记录（**必须在 FuncCtx 之前**：FuncCtx 用它）。
//   off/len 是**拼接后** gen->code 内的绝对偏移与字节数（len 由语句发射完回填）。
//   与 DWARF 的分工：标准行表只要 (地址, 文件, 行)；**字节数 / 文件偏移 / 所属节** 是标准不提供的
//   维度，由私有腿 TSV 提供（两腿同源 = 同一张表，避免两套真值）。
typedef struct {
  int file;      // 源文件序号（src_file_index_of；-1 = 反查不到）
  int line;      // 源行号（1 起）
  size_t off;    // 起始偏移（拼接后 code 内）
  size_t len;    // 字节数
} DebugRow;

// v1.4.11：一个函数在拼接后 code 内的区间（DWARF 每个函数发一条独立 sequence）
typedef struct {
  size_t off;    // 函数 code 起点（拼接后）
  size_t len;    // 函数 code 字节数
} DebugFuncSpan;

typedef struct {
  Buf code;            // 本函数代码字节
  Patch *patches;      // 动态：函数内待回填 rel32
  size_t npatches;     // 已记 patch 数
  size_t patches_cap;
  size_t *label_pos;   // 动态：label id → code 内字节位置
  bool *label_set;     // 动态：label 是否已 emit_label
  size_t nlabels;      // 已分配 label 数（含未标记的）
  size_t labels_cap;
  int exit_label_id;   // 本函数统一退出点
  ExtCall *exts;       // 动态：函数间 call 引用（布局后回填）
  size_t nexts;
  size_t exts_cap;
  StrRef *strrefs;     // v0.7.3：本函数内字符串引用（数据段排布后回填）
  size_t nstrrefs;
  size_t strrefs_cap;
  ApiCallRef *apicalls;// v0.8：本函数内 API 调用（IAT 布局后回填）
  size_t napicalls;
  size_t apicalls_cap;
  FuncAddrRef *funcaddrs; // v0.9.3：本函数内 &函数名 引用（布局后回填 lea disp）
  size_t nfuncaddrs;
  size_t funcaddrs_cap;
  DblRef *dblrefs;     // v1.1.0：本函数内 double 常量引用（数据区排布后回填 movsd disp）
  size_t ndblrefs;
  size_t dblrefs_cap;
  GUse *guses;         // v1.3.0：本函数内全局变量引用（disp 由 DATA_RVA+doff 直接算死）
  size_t nguses;
  size_t guses_cap;
  bool is_main;        // main：退出=call ExitProcess；普通函数=leave+ret
  bool ret_char;       // 2026-09-09 语义修正（用户拍板）：char 值返回函数 → 返回处 movzx 截断到 0..255
                       //   （对齐 SPEC 第 165 行与 C 语义；原实现让 300 原样带出，与 SPEC 矛盾）
  bool ret_dbl;        // v1.2.1 double 阶段2：本函数返回 double —— 返回值走 xmm0 直出（**不截断成 int**）、
                       //   自然流到末尾的隐式 return 不能发 `mov eax,0`（会毁掉已在 xmm0 的返回值）
  // v1.4.25（`-strict`）：这两项只给严格档的诊断用（默认关时谁都不读）
  int ret_ty;          // 本函数返回类型（判"地址值经 int 返回被截断"）
  Program *prog;       // 程序表（调用点查被调函数的形参类型/引用标记）
  size_t disp_off;     // main 内 call [rip+disp] 的 disp32 偏移（IAT 回填用）
  int scratch_off;     // v1.0.3：帧底部暂存槽偏移（间接赋值 rhs 先存槽再算地址——防跨 call 压栈错位）
  // v1.2.0 循环控制：当前循环上下文栈（break/continue 的目标 label，只管最内层 = C 语义）
  //   v1.3.1：switch 也压栈（break 要跳它）但 **is_switch=true** —— continue 必须穿透到外层真循环
  //   （C 语义：switch 不是循环），所以 cont 对 switch 段无意义（记 -1）。
  struct { int brk; int cont; bool is_switch; } *loops;
  int nloops;
  int loops_cap;
  // v1.4.11（`-debug`）：本函数内**语句级**发射记录（off = 本函数 code 内偏移；
  //   codegen_main 拼接时转成全局偏移再汇总进 GenResult）。
  //   为什么记在这里：函数 code 是各自 Buf，函数在最终 code 里的起点要到 codegen_main 才知道。
  DebugRow *dbg;
  size_t ndbg;
  size_t dbg_cap;
} FuncCtx;

// v1.4.11（`-debug`）：一条「语句 → 发射字节区间」记录。
//   off/len 是**拼接后** gen->code 内的绝对偏移与字节数（len 由语句发射完回填）。
//   与 DWARF 的分工：标准行表只要 (地址, 文件, 行)；**字节数 / 文件偏移 / 所属节** 是标准不提供的
//   维度，由私有腿 TSV 提供（两腿同源 = 同一张表，避免两套真值）。
// 返回 { code, iat_call_disp_off, apis, api_sites }
typedef struct {
  Buf code;              // 全部函数代码（main 开头）+ 字符串区
  size_t disp_off;       // call [rip+disp] 的 disp32 位于 code 内的偏移（ExitProcess IAT）
  ApiDef *apis;          // v0.8：API 表（codegen_main 从 Program 拷入；pe_build 布局导入）
  int napis;
  ApiCallRef *api_sites; // v0.8：API 调用点（off 已转拼接后全局偏移；pe_build 回填 IAT disp）
  size_t napi_sites;
  size_t api_sites_cap;
  // v1.3.0：全局变量表 + .data 节大小（pe_build 用它铺 .data 节、并算 .data 的 RVA）
  GlobalVar *globals;
  int nglobals;
  int data_size;
  // v1.3.0：全局变量引用的回填表（**拼接后全局偏移** + globals 下标）。
  //   为什么要带出来：`.data` 的 RVA 取决于 `.text` 实际大小（两节必须虚拟地址连续，见 flint.h 顶部），
  //   所以 `[rip+disp32]` 只能在 pe_build 里算完 .text 大小之后回填 —— codegen 阶段算不出来。
  //   （这与 api_sites 同一套路：生成期记位置，打包期布局定了再补。）
  GUse *guses;
  size_t nguses;
  size_t guses_cap;
  // v1.4.6（`-admin`）：产物形态开关 —— 非 0 时内嵌 RT_MANIFEST 资源、声明 requireAdministrator。
  //   为什么放在 GenResult 而不是给 pe_build 加参数：pe_build 只有一个调用点，但「产物形态开关」
  //   将来会长成一族（`-gui` 子系统 / `-icon` 图标 …），挂在同一个结构上比反复改签名便宜。
  //   默认 0 ⇒ 既有产物形态**逐字节不变**（回归里靠默认产物字节比对守着）。
  int want_admin;
  // v1.4.28（`-gui`，卡 T-20260927-212533 第一刀）：产物子系统 = **2 (WINDOWS_GUI)** 而不是默认 3 (CONSOLE)。
  //   动机 = SPEC 门面验收第 1 条「不弹黑窗」：控制台子系统的产物双击时先弹一个黑窗。
  //   只改可选头 `Subsystem` 一个字（文件偏移 = e_lfanew+4+20+0x44），别的字段一个字节不动
  //   ⇒ 同一样本加/不加 `-gui` 的产物应当**只差这一个字节**（`test\wx-verify.ps1` [8] 把这条钉成判据，
  //   同"改 ImageBase 只差 1 字节"那一招）。
  //   默认 0 ⇒ 既有产物形态**逐字节不变**。
  int want_gui;
  // v1.4.11（`-debug`，任务卡 T-20260917-223210）：产物携带「源码行 → 机器码地址」对照 —— 标准腿 = DWARF5
  //   行表（`.debug_line` + 最小 CU 的 `.debug_info`/`.debug_abbrev`）+ PE 长节名机制（`/nnn` + 字符串表），
  //   私有腿 = 同源的 TSV（含标准不提供的「字节区间 / 文件偏移 / 所属节」三维）。
  //   默认 0 ⇒ 既有产物形态**逐字节不变**（回归里靠"关开关产物 SHA256 相同"守着）。
  //   ⚠️ 这三个 `.debug_*` 节是 `MEM_DISCARDABLE`、**不参与加载**，所以 I1 的扫描域必须排除它们
  //   （DWARF 里 `DW_LNE_set_address` 写的**就是**绝对地址 —— 见 pe.c 的 I1 块）。
  int want_debug;
  // v1.4.11（-debug）：语句级记录（**拼接后全局偏移**）+ 各函数区间（DWARF 按函数发 sequence）。
  //   开关关时两者都是 NULL/0 ⇒ pe_build 与既有路径完全不走这些分支。
  DebugRow *dbg_rows;
  size_t ndbg_rows;
  size_t dbg_rows_cap;
  DebugFuncSpan *dbg_funcs;
  int ndbg_funcs;
  size_t dbg_funcs_cap;
} GenResult;

// ========== v1.4.11 可审计发射层（`-debug`，src/debug.c）==========
// 标准腿 = DWARF5：三个节（`.debug_line` + 最小 CU 的 `.debug_info` + `.debug_abbrev`）。
//   最小集由受控删改变体实验定案（`调研②-DWARF最小集实测.md`）：三者缺一，gdb/addr2line 就拿不到行号；
//   而 `.debug_str` / `.debug_line_str` **不要**（目录/文件表用内联 `DW_FORM_string`）。
// 私有腿 = TSV：补标准不提供的「字节区间 / 文件偏移 / 所属节」三维，与标准腿**同源**（同一张表）。
// 参数：text_rva = .text 的 RVA（行表里 set_address 要写绝对地址 = IMAGE_BASE + RVA）。
void debug_build_line(GenResult *gen, uint32_t text_rva, Buf *out);
void debug_build_info(GenResult *gen, uint32_t text_rva, uint32_t line_sec_off, Buf *out);
void debug_build_abbrev(Buf *out);
void debug_build_tsv(GenResult *gen, uint32_t text_rva, uint32_t text_raw_ptr,
                     const char *exe_name, Buf *out);

// 生成整个程序：
//   布局：main 的 code 放最前（PE 入口 = 代码开头，pe.c 零改动），其余按源序随后；
//   函数内跳转各自 resolve；函数间 call 按布局偏移二次回填；
//   各函数 code 依次拼接成一块返回。disp_off 指向 main 内 call ExitProcess 的 disp。
GenResult codegen_main(Program prog); // 签名保持（main.c 零改动）

// ========== PE 打包（自写最小 PE 头，不借链接器）==========
// 把「代码 + 字符串/常量区 + 导入表 + 全局变量初值」打包成最小 x64 控制台 exe。
// v1.3.0：产物由**两节**组成（.text 可执行 / .data 可写，两节虚拟地址必须连续）。
//   · gen->disp_off（ExitProcess）与 gen->api_sites 的 IAT disp 由本函数回填；
//   · gen->guses（全局变量 `[rip+disp32]`）也在这里回填 —— 因为 .data 的 RVA 取决于
//     .text 的实际虚拟大小（见 flint.h 顶部「两节必须连续」），只有本函数算得出。
// 成功返回 0 并把完整 exe 写进 out；失败返回 -1 并置 *err。
//   ⚠️ 签名原为 `Buf pe_build(...)`：Buf 是 24 字节结构体，按值返回要整块 memcpy
//   （「参数/返回值传大结构体」是 FLINT 自身的已知低效点，这里顺手避免）。
int pe_build(GenResult *gen, Buf *out, char **err);
#endif
