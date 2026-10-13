// main.c — FLINT 编译器驱动（v0.2 野路子：源码 → 自产机器码 exe）
// 用法：
//   flint.exe -t <源文件>            词法分析，打印 token 流
//   flint.exe <源文件>               编译成 exe（输出：同目录同名 .exe）
//   flint.exe [-o 输出.exe] 文件1.fl [文件2.fl ...]   多文件编译（v1.0.3）
//   flint.exe -safe <源>             安全模式（v0.9）：内存所有权强制——new 必须由 own/share 接管
//   flint.exe --help                 用法
//
// v1.0.3 多文件编译 / include：
//   - 命令行可传多个 .fl 文件，按序合并成一个编译单元（函数可跨文件调用/前向调用；
//     结构体须在使用前定义——把共享定义放最前的文件）。
//   - 源文件顶部可用 `include "路径.fl"` 指令文本级拼接另一个文件（相对本文件目录解析；
//     支持嵌套；循环 include 报错）。include 的内容与命令行文件等同参与合并。
//   - api 声明可出现在任意文件的顶层任意位置：驱动会把所有 `api 模块 返回 名(...);`
//     声明统一前移到编译单元头部（collect_apis 只扫头部 + 语法要求 api 在 struct/函数前），
//     其余顶层元素保持源序。
//   - 报错定位：每个文件的 token 自带来源缓冲，错误按行/列归到正确文件（tokenize.c 登记表）。

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flint.h"

// 读整个文件到字符串。失败返回 NULL。
static char *read_file(char *path) {
  FILE *fp = fopen(path, "rb");
  if (!fp) return NULL;

  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);

  char *buf = malloc((size_t)size + 2);
  size_t n = fread(buf, 1, (size_t)size, fp);
  fclose(fp);

  // 统一去掉 \r（CRLF→LF），以 \n\0 收尾
  size_t w = 0;
  for (size_t i = 0; i < n; i++)
    if (buf[i] != '\r') buf[w++] = buf[i];
  buf[w] = '\n';
  buf[w + 1] = '\0';
  return buf;
}

// 打印 token 流（测试比对用的稳定格式）
static void print_tokens(Token *tok) {
  for (; tok->kind != TK_EOF; tok = tok->next) {
    switch (tok->kind) {
      case TK_IDENT: printf("IDENT  %.*s\n", tok->len, tok->loc); break;
      case TK_NUM:   printf("NUM    %d\n", tok->val); break;
      case TK_STR:   printf("STR    %.*s\n", tok->slen, tok->sval); break; // v0.7.3
      case TK_DBL:   printf("DBL    %.17g\n", tok->dval); break;  // v1.1.0 浮点字面量
      case TK_PUNCT: printf("PUNCT  %.*s\n", tok->len, tok->loc); break;
      case TK_EOF:   break;
    }
  }
  printf("EOF\n");
}

// 写文件
static int write_file(char *path, const uint8_t *data, size_t len) {
  FILE *fp = fopen(path, "wb");
  if (!fp) return 0;
  size_t n = fwrite(data, 1, len, fp);
  fclose(fp);
  return n == len;
}

// 默认输出路径：第一个源文件去扩展名 + .exe
static char *default_out(char *src_path) {
  static char out[1024];
  snprintf(out, sizeof(out), "%s", src_path);
  char *dot = strrchr(out, '.');
  if (dot && dot != out) *dot = '\0';
  strncat(out, ".exe", sizeof(out) - strlen(out) - 1);
  return out;
}

static void usage(void) {
  fprintf(stderr, "用法: flint [-t] [-safe] [-o 输出.exe] <源文件> [源文件...]\n");
  fprintf(stderr, "  -t         只做词法分析，打印 token 流\n");
  fprintf(stderr, "  -safe      安全模式（v0.9）：内存所有权强制——new 结果必须由 own/share 接管\n");
  fprintf(stderr, "  -o <路径>  指定输出 exe 路径\n");
  fprintf(stderr, "  -admin     产物内嵌 manifest（requireAdministrator）：双击即请求管理员权限（v1.4.6，用于读 MSR 这类要提权的程序）\n");
  fprintf(stderr, "  -gui       产物为 GUI 子系统（Subsystem=2，v1.4.28）：双击不弹控制台黑窗（门面验收第 1 条）；默认 3=CONSOLE\n");
  fprintf(stderr, "  -stats     打印按函数的发射统计（账本：指令数/栈槽访问/调用；不改产物）\n");
  fprintf(stderr, "  -strict    严格诊断档（v1.4.25）：把四类「静默」当编译错误拦下——\n");
  fprintf(stderr, "             ① int 值传给 int* 形参（E-T1-INTTOPTR）\n");
  fprintf(stderr, "             ② 读一个从没赋过值的局部量（E-STRICT-UNINIT）\n");
  fprintf(stderr, "             ③ 地址值(64位)经 int 形参/int 返回值被截断（E-STRICT-WIDTH）\n");
  fprintf(stderr, "             ④ 常量下标越界（E-STRICT-BOUNDS）\n");
  fprintf(stderr, "             默认关：不加这个开关，产物与从前逐字节相同。\n");
  fprintf(stderr, "  -debug     产物携带「源码行 → 机器码地址」对照（v1.4.11）：\n");
  fprintf(stderr, "             ① 标准腿 = 三个 DWARF5 节（.debug_line + 最小 CU 的 .debug_info/.debug_abbrev）\n");
  fprintf(stderr, "                → objdump --dwarf=decodedline / addr2line / gdb 直接能读；\n");
  fprintf(stderr, "             ② 私有腿 = 同源的 <输出>.tsv（补标准不提供的「字节区间 / 文件偏移 / 所属节」）。\n");
  fprintf(stderr, "             默认关：不加节，产物与现在逐字节相同。\n");
  fprintf(stderr, "  多文件     多个 .fl 合并编译（v1.0.3）；源文件可用 include \"路径.fl\" 拼接（相对本文件目录）\n");
}

// ========== v1.0.3 多文件 / include 工具 ==========

static bool is_punct_tok(Token *tok, char op) {
  return tok->kind == TK_PUNCT && tok->len == 1 && tok->loc[0] == op;
}
static bool is_ident_tok(Token *tok, char *s) {
  return tok->kind == TK_IDENT && (int)strlen(s) == tok->len && strncmp(tok->loc, s, tok->len) == 0;
}

// 单节点追加到链表（重建用：会改写 t->next，调用方须先保存后继）
static void lst_push(Token **head, Token **tail, Token *t) {
  t->next = NULL;
  if (*head) { (*tail)->next = t; *tail = t; }
  else { *head = t; *tail = t; }
}

// 取路径的目录部分（含尾分隔符；无目录返回 ""）
static char *dir_of(const char *path) {
  static char dir[1024];
  dir[0] = '\0';
  const char *slash = strrchr(path, '\\');
  const char *fslash = strrchr(path, '/');
  const char *last = (slash && fslash) ? (slash > fslash ? slash : fslash)
                 : (slash ? slash : fslash);
  if (!last) return dir;   // 无目录 → ""（相对当前工作目录）
  size_t n = (size_t)(last - path) + 1;
  if (n >= sizeof(dir)) n = sizeof(dir) - 1;
  memcpy(dir, path, n);
  dir[n] = '\0';
  return dir;
}

// 目录 + 文件名 → 新路径（malloc）
static char *cat_path(const char *dir, const char *name) {
  size_t dl = strlen(dir), nl = strlen(name);
  char *out = malloc(dl + 1 + nl + 1);
  memcpy(out, dir, dl);
  size_t o = dl;
  if (dl > 0 && out[dl - 1] != '\\' && out[dl - 1] != '/') out[o++] = '\\';
  memcpy(out + o, name, nl);
  out[o + nl] = '\0';
  return out;
}

// ========== B2x：include 搜索路径 ==========
// 候选顺序：① 相对本文件目录（原有行为）② <编译器目录>lib\ ③ <编译器目录>..\lib\
// ②③ 让 `include "num_lib.fl"` 免写 ../../；boot 用同一套顺序（<exe目录> 对应编译器目录）。
static char *compiler_dir = NULL;   // 编译器 exe 所在目录（含尾分隔符；main 初始化）

static bool file_exists(const char *p) {
  FILE *fp = fopen(p, "rb");
  if (!fp) return false;
  fclose(fp);
  return true;
}

// 解析 include 路径：返回首个存在的候选（malloc）；都不存在返回首选路径（供报错）
static char *resolve_include(const char *dir, const char *name) {
  char *p1 = cat_path(dir, name);
  if (file_exists(p1)) return p1;
  if (compiler_dir) {
    char buf[1024];
    snprintf(buf, sizeof(buf), "%slib\\%s", compiler_dir, name);
    if (file_exists(buf)) return strdup(buf);
    snprintf(buf, sizeof(buf), "%s..\\lib\\%s", compiler_dir, name);
    if (file_exists(buf)) return strdup(buf);
  }
  return p1;
}

// ========== B2v：include 去重 ==========
// 规范化路径：绝对路径 + 解析 . / .. + 统一分隔符（同一文件的不同写法可比）。
// _fullpath 为 MinGW/MSVC 扩展（stdlib.h）；失败退化为原串副本——宁可重复展开也不误跳过。
static char *canon_path(const char *p) {
  char buf[1024];
  if (_fullpath(buf, p, sizeof(buf)) == NULL) return strdup(p);
  return strdup(buf);
}
// 路径相等（Windows 大小写不敏感；分隔符已由 canon_path 统一）
static int path_eq(const char *a, const char *b) {
  while (*a && *b) {
    char ca = *a, cb = *b;
    if (ca >= 'A' && ca <= 'Z') ca = (char)(ca + 32);
    if (cb >= 'A' && cb <= 'Z') cb = (char)(cb + 32);
    if (ca != cb) return 0;
    a++; b++;
  }
  return *a == *b;
}

// include 指令 = 标识符 include 后紧跟字符串字面量
static bool is_include_dir(Token *t) {
  return is_ident_tok(t, "include") && t->next && t->next->kind == TK_STR;
}
// api 声明起点 = 标识符 api 后跟标识符（模块短名）——decl 到 ';' 结束
static bool is_api_decl_start(Token *t) {
  return is_ident_tok(t, "api") && t->next && t->next->kind == TK_IDENT;
}

// ========== v1.0.8 print 内建：内置输出库（源里用到 print([...]) 才注入）==========
// 隐藏函数 _flint_ 前缀防撞（用户标识符保留区，文档记）；逻辑与退役的 lib/console.fl 同源：
// 机器层 = kernel32 GetStdHandle(-11=STD_OUTPUT_HANDLE) + WriteFile 直写 stdout；
// FLINT 无用户态缓冲（WriteFile 即写即达）。换行字节 \n(0x0A)：控制台换行实测可行，
// 重定向文件字节原样。注入源码的 api 声明在最前 → collect_apis 扫头部可见。
static const char *PRINT_LIB_SRC =
  "api kernel32 ptr GetStdHandle(int);\n"
  "api kernel32 int WriteFile(int, int, int, int, int);\n"
  "int _flint_out_bytes(char *s, int len) {\n"
  "  int *h = GetStdHandle(-11);\n"
  "  if (h == 0) { return 0; }\n"
  "  int w = 0;\n"
  "  return WriteFile(h, s, len, &w, 0);\n"
  "}\n"
  "int _flint_out_str(char *s) {\n"
  "  int n = 0;\n"
  "  while (s[n] != 0) { n = n + 1; }\n"
  "  return _flint_out_bytes(s, n);\n"
  "}\n"
  "int _flint_out_int(int n) {\n"
  "  char tmp[12];\n"
  "  char out[12];\n"
  "  int i = 0;\n"
  "  int j = 0;\n"
  "  int neg = 0;\n"
  "  if (n < 0) { neg = 1; n = -n; }\n"
  "  if (n == 0) { tmp[0] = '0'; i = 1; }\n"
  "  while (n != 0) { tmp[i] = '0' + n % 10; n = n / 10; i = i + 1; }\n"
  "  if (neg != 0) { out[0] = '-'; j = 1; }\n"
  "  while (i > 0) { i = i - 1; out[j] = tmp[i]; j = j + 1; }\n"
  "  return _flint_out_bytes(out, j);\n"
  "}\n"
  "int _flint_out_char(int c) {\n"
  "  char b[1];\n"
  "  b[0] = c;\n"
  "  return _flint_out_bytes(b, 1);\n"
  "}\n"
  // v1.2.3 浮点打印（SPEC 首选路线：**纯 FLINT 自己写 double→字符串**，零 PE 改动、不需要 `_fltused`；
  //   它敢这么写，是因为 v1.2.2 刚打通「函数形参 double」——double 值能直接当一个实参传进来了）。
  //   口径：固定 6 位小数 + 四舍五入（先加半个最低位 5e-7，进位自然落到整数部分：
  //   0.9999999 → 1.000000）；负数先出 '-' 再取绝对值；-0.0 按 0.000000 打（IEEE 的 -0.0 < 0.0 为假）。
  //   ⚠️ 两条**不静默**的边界守卫：NaN 与 |v| ≳ 2^31（to_int 会溢出成 0x80000000）→ 打标记串，不打错数字。
  "int _flint_out_dbl(double v) {\n"
  "  if (v != v) { return _flint_out_str(\"<dbl-nan>\"); }\n"
  "  if (v > 2147483000.0 || v < -2147483000.0) { return _flint_out_str(\"<dbl-out-of-range>\"); }\n"
  "  if (v < 0.0) { _flint_out_char('-'); v = 0.0 - v; }\n"
  "  v = v + 0.0000005;\n"
  "  int ip = to_int(v);\n"
  "  double d = ip;\n"
  "  double frac = v - d;\n"
  "  _flint_out_int(ip);\n"
  "  _flint_out_char('.');\n"
  "  int i = 0;\n"
  "  while (i < 6) {\n"
  "    frac = frac * 10.0;\n"
  "    int dig = to_int(frac);\n"
  "    if (dig > 9) { dig = 9; }\n"
  "    _flint_out_char('0' + dig);\n"
  "    frac = frac - dig;\n"
  "    i = i + 1;\n"
  "  }\n"
  "  return 0;\n"
  "}\n";

// 探测：是否用了内建 print 形态（print ( [ ）——普通 print 函数调用/变量不触发注入
static bool uses_print(Token *head) {
  for (Token *t = head; t->kind != TK_EOF; t = t->next) {
    if (is_ident_tok(t, "print") && t->next && is_punct_tok(t->next, '(')
        && t->next->next && is_punct_tok(t->next->next, '['))
      return true;
  }
  return false;
}

// 注入：把内置输出库源码 token 化后插到 token 流头部。
// collect_funcs 预扫即登记 _flint_out_*（print 展开的 ND_CALL 能找到）；
// api 声明在注入源码最前，collect_apis 扫头部可见。
static Token *inject_print_lib(Token *head) {
  Token *lib = tokenize(strdup(PRINT_LIB_SRC), "<builtin print>");
  Token *tail = lib;
  while (tail->next->kind != TK_EOF) tail = tail->next;   // tail = EOF 前一节点
  tail->next = head;      // 内置库（去 EOF）接原流（原流以 EOF 收尾）
  return lib;
}

// include 展开栈（防循环）+ 已展开文件集（B2v 去重：同一文件只展开一次）
typedef struct { char *paths[64]; int n; char *seen[128]; int nseen; } IncStack;

// 展开一个文件里的 include（token 级拼接），返回真实 token 链（不含 EOF）。
// path = 本文件路径（include 相对它解析）；原 token 链被改写消耗。
static Token *expand_includes(Token *head, const char *path, IncStack *st, int depth) {
  if (depth > 32)
    error("include 嵌套超过 32 层（疑似循环 include）");
  Token *out = NULL, *out_tail = NULL;

  Token *t = head;
  while (t->kind != TK_EOF) {
    if (is_include_dir(t)) {
      Token *strtok = t->next;
      char *name = malloc((size_t)strtok->slen + 1);
      memcpy(name, strtok->sval, (size_t)strtok->slen);
      name[strtok->slen] = '\0';
      char *inc_path = resolve_include(dir_of(path), name);   // B2x：本文件目录 → 编译器 lib
      char *cpath = canon_path(inc_path);      // B2v：规范化后再比（同文件不同写法等价）

      for (int i = 0; i < st->n; i++)
        if (path_eq(st->paths[i], cpath))
          error_at(t->loc, "include 循环引用: %s", inc_path);

      // B2v 去重：已展开过的文件不再展开（库互相 include / 重复 include 不再重复定义）
      int dup = 0;
      for (int i = 0; i < st->nseen; i++)
        if (path_eq(st->seen[i], cpath)) { dup = 1; break; }
      if (dup) { t = strtok->next; continue; }

      char *src = read_file(inc_path);
      if (!src) error_at(t->loc, "include 文件不存在: %s", inc_path);
      Token *inc = tokenize(src, inc_path);          // 登记进报错表（tokenize.c）
      if (st->nseen < 128) st->seen[st->nseen++] = cpath;
      st->paths[st->n++] = cpath;
      Token *exp = expand_includes(inc, inc_path, st, depth + 1);
      st->n--;

      // 拼接被包含文件内容（exp 不含 EOF）
      for (Token *q = exp; q; ) {
        Token *nxt = q->next;
        lst_push(&out, &out_tail, q);
        q = nxt;
      }

      t = strtok->next;   // 跳过 include + 字符串两个 token
      continue;
    }
    Token *nxt = t->next;
    lst_push(&out, &out_tail, t);
    t = nxt;
  }
  return out;
}

// 加载一个编译单元（读文件 → 词法 → include 展开 → 末尾补 EOF 节点）
static Token *load_unit(const char *path, IncStack *st) {
  char *src = read_file((char *)path);
  if (!src) error("FLINT: 无法打开文件 %s", path);
  Token *tok = tokenize(src, (char *)path);

  // 先取原链末尾 EOF 节点（expand_includes 会改写/重建链，须在展开前定位）
  Token *eof = tok;
  while (eof->kind != TK_EOF) eof = eof->next;

  // B2v：顶层文件也压进循环栈（被自己 include 时算循环报错，而不是被去重静默跳过）
  st->paths[st->n++] = canon_path(path);
  Token *exp = expand_includes(tok, path, st, 0);
  st->n--;
  if (!exp) return eof;               // 空文件：只有 EOF
  Token *tail = exp;
  while (tail->next) tail = tail->next;
  tail->next = eof;
  return exp;
}

// api 声明统一前移到编译单元头部（保持声明相对顺序；其余元素保持原序）。
// 原因：collect_apis/语法只认头部 api——多文件里后文件的 api 声明原本会落到
// struct/函数之后被拒；前移后单遍合并即可，parse.c 零改动。
static Token *hoist_apis(Token *head) {
  Token *api = NULL, *api_tail = NULL;
  Token *oth = NULL, *oth_tail = NULL;

  // 先取末尾 EOF（循环里 lst_push 会改写链）
  Token *eof = head;
  while (eof->kind != TK_EOF) eof = eof->next;

  Token *t = head;
  while (t->kind != TK_EOF) {
    if (is_api_decl_start(t)) {
      // 找声明结束 ';'（未闭合 → 按普通 token 处理，交 parser 报错）
      Token *e = t;
      while (e->kind != TK_EOF && !is_punct_tok(e, ';')) e = e->next;
      if (e->kind == TK_EOF) {
        Token *nxt = t->next;
        lst_push(&oth, &oth_tail, t);
        t = nxt;
        continue;
      }
      while (true) {
        Token *nxt = t->next;      // lst_push 会置空 next，先保存后继
        lst_push(&api, &api_tail, t);
        if (t == e) { t = nxt; break; }
        t = nxt;
      }
      continue;
    }
    Token *nxt = t->next;
    lst_push(&oth, &oth_tail, t);
    t = nxt;
  }
  // 接回 EOF（保证返回链以 TK_EOF 收尾）
  if (oth_tail) lst_push(&oth, &oth_tail, eof);
  else lst_push(&api, &api_tail, eof);
  if (api_tail) { api_tail->next = oth; return api; }
  return oth;
}

int main(int argc, char **argv) {
  if (argc < 2) { usage(); return 1; }

  bool tok_only = false;
  bool mode_safe = false;
  bool want_admin = false;   // v1.4.6：-admin → 产物内嵌 requireAdministrator 清单
  bool want_gui = false;     // v1.4.28：-gui → 产物子系统 = 2 (WINDOWS_GUI)，双击不弹控制台黑窗
  bool want_debug = false;   // v1.4.11：-debug → 产物携带 DWARF5 行表 + 同源 TSV
  bool want_stats = false;   // v1.4.19：-stats → 打印按函数的发射统计（账本；不改产物）
  char *files[32];
  int nfiles = 0;
  char *out_path = NULL;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-t") == 0) tok_only = true;
    else if (strcmp(argv[i], "-safe") == 0) mode_safe = true;
    else if (strcmp(argv[i], "-admin") == 0) want_admin = true;
    else if (strcmp(argv[i], "-gui") == 0) want_gui = true;
    else if (strcmp(argv[i], "-debug") == 0) want_debug = true;
    else if (strcmp(argv[i], "-stats") == 0) { want_stats = true; flint_stats = true; }
    // v1.4.25：-strict 严格诊断档——把四类"静默"当编译错误拦下；默认关（关着时产物逐字节不变）
    else if (strcmp(argv[i], "-strict") == 0) flint_strict = true;
    else if (strcmp(argv[i], "-mode") == 0 && i + 1 < argc) {
      if (strcmp(argv[++i], "safe") == 0) mode_safe = true;
      else { fprintf(stderr, "FLINT: 未知模式 %s（v0.9 支持 safe）\n", argv[i]); return 1; }
    }
    else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out_path = argv[++i];
    else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) { usage(); return 0; }
    else {
      if (nfiles >= 32) { fprintf(stderr, "FLINT: 源文件最多 32 个\n"); return 1; }
      files[nfiles++] = argv[i];
    }
  }
  if (nfiles == 0) { usage(); return 1; }

  // B2x：编译器自带库目录 = flint.exe 所在目录（include 找不到相对路径时回退到这里）
  compiler_dir = strdup(dir_of(argv[0]));

  // —— 阶段 1：逐文件加载（词法 + include 展开），合并成一个 token 流 ——
  IncStack incst = { {0}, 0 };
  Token *all = NULL, *all_tail = NULL;
  Token *last_eof = NULL;
  for (int i = 0; i < nfiles; i++) {
    Token *unit = load_unit(files[i], &incst);
    Token *q = unit;
    while (q->kind != TK_EOF) {
      Token *nxt = q->next;
      lst_push(&all, &all_tail, q);
      q = nxt;
    }
    last_eof = q;   // 本单元 EOF 节点（最后单元的 EOF 作整体 EOF）
  }
  if (all_tail) { all_tail->next = last_eof; all = all ? all : last_eof; }
  else all = last_eof;

  // —— v1.0.8：print 内建——源里用到 print([...]) 才注入内置输出库 ——
  // 必须放 hoist_apis 之前：注入源码自带 api 声明（GetStdHandle/WriteFile），若在 hoist 后注入，
  // 注入的函数定义会把用户源码自己的 api 声明（如 CreateFileA）隔到"函数之后"→ parse 报
  // "api 声明必须放在文件最顶部"。hoist 前注入则注入 api 与用户 api 一起被前移。
  if (uses_print(all)) all = inject_print_lib(all);

  // api 声明统一前移（多文件合并后 parse 前置条件）
  all = hoist_apis(all);

  if (tok_only) { print_tokens(all); return 0; }


  // —— 阶段 2：语法（-safe 置位后 parse 做所有权强制检查）——
  flint_safe_mode = mode_safe;
  // v1.4.11：可审计发射层开关必须在 codegen **之前**置位（codegen 是"记录方"，拿不到 GenResult）
  flint_debug_info = want_debug;
  Program prog = parse(all);

  // —— 阶段 3：代码生成（自写机器码编码器）——
  GenResult gen = codegen_main(prog);

  // v1.4.6：命令行开关 → 产物形态（显式赋值，不依赖 codegen 是否清零该字段）
  gen.want_admin = want_admin ? 1 : 0;
  gen.want_gui = want_gui ? 1 : 0;   // v1.4.28：-gui → 只改可选头 Subsystem 一个字（opt+0x44）
  gen.want_debug = want_debug ? 1 : 0;   // v1.4.11：-debug → 发三个 DWARF 节 + 字符串表

  // —— 阶段 4：PE 打包（自写链接器替代品）——
  // v1.3.0：签名改为「输出参数」形式（Buf 是 24 字节结构，按值返回要整块拷贝）
  char *err = NULL;
  Buf exe;
  if (pe_build(&gen, &exe, &err) != 0) {
    fprintf(stderr, "FLINT: PE 打包失败: %s\n", err ? err : "未知原因");
    return 1;
  }

  char *out = out_path ? out_path : default_out(files[0]);
  if (!write_file(out, exe.data, exe.len)) {
    fprintf(stderr, "FLINT: 无法写入 %s\n", out);
    return 1;
  }

  // v1.4.11（`-debug`）：私有腿 —— 与产物内 DWARF 行表**同源**的 TSV
  //   （补标准不提供的三个维度：字节区间 / 文件偏移 / 所属节；两腿同一张表 ⇒ 不会出现两套真值）
  if (want_stats) flint_stats_dump();
  if (want_debug) {
    Buf tsv;
    char tpath[1024];
    snprintf(tpath, sizeof(tpath), "%s.tsv", out);
    debug_build_tsv(&gen, FLINT_TEXT_RVA,
                    pe_headers_size(pe_nsec_all(gen.data_size > 0 ? 1 : 0,
                                                gen.want_admin != 0, gen.want_debug != 0)),
                    out, &tsv);
    if (!write_file(tpath, tsv.data, tsv.len)) {
      fprintf(stderr, "FLINT: 无法写入 %s\n", tpath);
      return 1;
    }
    printf("   行对照表 → %s （%zu 条语句记录）\n", tpath, gen.ndbg_rows);
  }

  printf("✅");
  for (int i = 0; i < nfiles; i++) printf(" %s", files[i]);
  printf(" → %s （%zu 字节，纯自产机器码 PE，未借汇编器/链接器）\n", out, exe.len);
  return 0;
}
