// tokenize.c — FLINT 词法分析器（阶段1）
// 输入：源码文本（C 子集语法）→ 输出：token 链表。
// 思路（chibicc 同款）：源码复制到可写内存，直接在串上切 token；
// 关键字不单独成类，一律按 TK_IDENT 切，交给语法分析阶段判断。
//
// 跳过：空白、// 行注释、/* 块注释 */
// 切分：标识符、十进制整数、运算符/分隔符（== != <= >= && || 双字符优先）

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flint.h"

// —— 全局：源码首地址 + 当前行号 + 源文件名（报错定位用）——
static char *current_input;
static int current_line;
static char *current_file;   // v0.9.1：源文件名（报错头显示；可 NULL）

// —— v1.0.3 多文件：每次 tokenize 登记一个源码缓冲区间（loc → 所属文件反查用）——
// 单文件时代 current_input/current_file 全局够用；多文件/多 tokenize 调用后，
// 报错定位必须按 loc 落在哪个缓冲反查文件名（parse 阶段错误可能来自任意文件）。
typedef struct { char *start; char *end; char *file; } SrcSpan;
static SrcSpan src_spans[64];
static int n_src_spans = 0;

// —— v1.4.11（可审计发射层）：由源码位置反查「文件 + 行号」 ——
// 与报错定位**同源**（同一张 src_spans 表）⇒ 调试信息里的 `file:line` 与编译器报错口径一致，
// 不会出现"编译器说第 12 行、调试器说第 3 行"这种两套真值。
// 落不进任何区间（第 64 个文件之后 / 人为构造的位置）时按"反查不到"处理，绝不返回野指针。
static int span_of(char *loc) {
  if (!loc) return -1;
  for (int i = 0; i < n_src_spans; i++)
    if (loc >= src_spans[i].start && loc < src_spans[i].end) return i;
  return -1;
}

int src_file_index_of(char *loc) { return span_of(loc); }

int src_line_of(char *loc) {
  int si = span_of(loc);
  if (si < 0) return 1;                     // 反查不到 → 退化为第 1 行（不猜、不炸）
  char *base = src_spans[si].start;
  if (loc < base) return 1;
  int line = 1;
  for (char *p = base; p < loc; p++)
    if (*p == '\n') line++;
  return line;
}

int src_file_count(void) { return n_src_spans; }

char *src_file_name(int i) {
  if (i < 0 || i >= n_src_spans) return NULL;
  return src_spans[i].file;
}


// —— 报错：指出源码具体位置 ——
static void verror_at(char *loc, char *fmt, va_list ap) {
  // 从出错位置反查：loc 属于哪个已登记源码缓冲（默认退回当前全局）
  char *input = current_input;
  char *file = current_file;
  for (int i = 0; i < n_src_spans; i++) {
    if (loc >= src_spans[i].start && loc < src_spans[i].end) {
      input = src_spans[i].start;
      file = src_spans[i].file;
      break;
    }
  }

  // 行首（往前找 \n）、行尾（往后找 \n）
  char *line_start = loc;
  while (line_start > input && line_start[-1] != '\n') line_start--;
  char *line_end = loc;
  while (*line_end && *line_end != '\n') line_end++;

  int line_no = 1;
  for (char *p = input; p < line_start; p++)
    if (*p == '\n') line_no++;
  int col = (int)(loc - line_start) + 1;   // v0.9.1：列号（1 起，与 ^ 指位对应）

  // v0.9.1：报错头带文件名 + 列号（原先只有行号、^ 前只有空格没有数字列）
  if (file)
    fprintf(stderr, "FLINT 编译错误（%s 第 %d 行第 %d 列）:\n", file, line_no, col);
  else
    fprintf(stderr, "FLINT 编译错误（第 %d 行第 %d 列）:\n", line_no, col);
  fprintf(stderr, "  %.*s\n", (int)(line_end - line_start), line_start);
  fprintf(stderr, "  %*s^\n", (int)(loc - line_start), "");
  fprintf(stderr, "  ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  exit(1);
}

void error_at(char *loc, char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  verror_at(loc, fmt, ap);
  va_end(ap);
}

void error(char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "FLINT 错误: ");
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  exit(1);
}

// —— 小工具 ——
static bool startswith(char *p, char *q) {
  return strncmp(p, q, strlen(q)) == 0;
}

// 标识符首字符：字母或 _
static bool is_ident1(char c) {
  return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || c == '_';
}
// 标识符后续字符：首字符基础上加数字
static bool is_ident2(char c) {
  return is_ident1(c) || ('0' <= c && c <= '9');
}

static Token *new_token(TokenKind kind, char *start, char *end) {
  Token *tok = calloc(1, sizeof(Token));
  tok->kind = kind;
  tok->loc = start;
  tok->len = (int)(end - start);
  tok->line = current_line; // 生成时当前行号（\n 在跳过前已计数）
  return tok;
}

// —— v0.7.3 转义解析：buf 指向 '\' 本身 → 解码一个字节；成功返回后续指针，否则 error_at ——
static char *parse_escape(char *loc, char *buf, unsigned char *out) {
  char c = buf[1];
  buf += 2;
  switch (c) {
    case 'n': *out = '\n'; return buf;
    case 't': *out = '\t'; return buf;
    case 'r': *out = '\r'; return buf;
    case '0': *out = '\0'; return buf;
    case '\\': *out = '\\'; return buf;
    case '\'': *out = '\''; return buf;
    case '"': *out = '"'; return buf;
    case 'x': {
      int v = 0, n = 0;
      while (n < 2 && isxdigit((unsigned char)*buf)) {
        unsigned char h = (unsigned char)*buf++;
        v = v * 16 + (isdigit(h) ? h - '0' : (h | 0x20) - 'a' + 10);
        n++;
      }
      if (n == 0) error_at(buf - 1, "\\x 后需跟 1-2 位十六进制数字");
      *out = (unsigned char)v;
      return buf;
    }
    default:
      error_at(loc, "未知转义 '\\%c'", c);
  }
  return buf;
}

// —— 主入口：词法分析 ——
Token *tokenize(char *p, char *filename) {
  // 复制到可写内存（调用方可能传只读字面量，且我们要在串上原地操作）
  size_t n = strlen(p) + 1;
  char *buf = malloc(n);
  strcpy(buf, p);

  // v1.0.3：跳过 UTF-8 BOM（EF BB BF）——Windows 记事本/旧版 PS 可能带 BOM 存源文件；
  // 不跳的话首 token 报"无法识别的字符 0xef"（首个真实字符被吞）。include 的文件同样受益。
  bool bom = n >= 4 && (unsigned char)buf[0] == 0xEF && (unsigned char)buf[1] == 0xBB && (unsigned char)buf[2] == 0xBF;
  if (bom) buf += 3;

  current_input = buf;
  current_file = filename;   // v0.9.1：报错头显示源文件名
  current_line = 1;

  // v1.0.3：登记本文件缓冲区间（词法/语法错误按 loc 反查文件名；须在扫描前登记——
  // 本文件 tokenize 期间的词法错误也走 registry 定位）
  if (n_src_spans < 64) {
    src_spans[n_src_spans].start = buf;
    src_spans[n_src_spans].end = buf + (n - (bom ? 3 : 0));   // 含末尾 \0（EOF token loc 指向它）
    src_spans[n_src_spans].file = filename;
    n_src_spans++;
  }

  Token head = {0}; // 哨兵头，尾插链表
  Token *cur = &head;

  while (*buf) {
    // 换行：先计行号再跳过（保证本行 token 的 line 正确）
    if (*buf == '\n') { current_line++; buf++; continue; }

    // 空白（空格/Tab/回车）
    if (isspace((unsigned char)*buf)) { buf++; continue; }

    // 行注释 //
    if (startswith(buf, "//")) {
      buf += 2;
      while (*buf && *buf != '\n') buf++;
      continue;
    }

    // 块注释 /* */
    if (startswith(buf, "/*")) {
      char *q = strstr(buf + 2, "*/");
      if (!q) error_at(buf, "块注释未闭合");
      // 块注释可能跨行，补计行号
      for (char *t = buf; t < q + 2; t++)
        if (*t == '\n') current_line++;
      buf = q + 2;
      continue;
    }

    // 整数（v0.7.2 加十六进制 0x——Win32 flag 常量刚需；十进制同前）
    if (isdigit((unsigned char)*buf)) {
      char *start = buf;
      int base = 10;
      if (buf[0] == '0' && (buf[1] == 'x' || buf[1] == 'X')) {
        buf += 2;
        if (!isxdigit((unsigned char)*buf))
          error_at(start, "0x 后需跟十六进制数字");
        base = 16;
      }
      // S5 修复（v0.9.1）：strtol 是 32 位 long，溢出静默饱和成 2147483647（数据损坏无人知）
      // → 改 strtoll + 显式范围检查报错。语义对齐 C：十进制 ≤ INT32_MAX；十六进制是
      // 32 位位型，允许到 0xFFFFFFFF（高位 1 即负数位型，Win32 flag 刚需：WS_POPUP=0x80000000）。
      long long v = strtoll(buf, &buf, base);
      // v1.1.0 浮点（阶段1）：此前这里直接报「暂不支持浮点数」。现在识别三种形态：
      //   ① 小数点 3.14（要求点后跟数字，避免与字段访问 3.x / a.b 撞车）
      //   ② 指数 3e5 / 3E5（十进制直接跟 e）
      //   ③ 组合 3.14e-2 / 1.0E+3
      // 注意：只走十进制分支（十六进制 0x… 后面跟 e 是合法十六进制数字，别抢）
      bool is_float = false;
      if (base == 10) {
        if (*buf == '.' && isdigit((unsigned char)buf[1])) {
          is_float = true;
        } else if ((*buf == 'e' || *buf == 'E')
                   && (isdigit((unsigned char)buf[1])
                       || ((buf[1] == '+' || buf[1] == '-') && isdigit((unsigned char)buf[2])))) {
          is_float = true;
        }
      }
      if (is_float) {
        buf = start;                                   // 退回字面量起点，交给 strtod 整体解析
        errno = 0;
        double dv = strtod(buf, &buf);
        if (errno == ERANGE) error_at(start, "浮点字面量超出 double 范围");
        // 「1.5abc」「3.1.4」这类不能再跟标识符/数字——否则千分位/单位后缀会被静默吞掉
        if (is_ident2(*buf) || *buf == '.') error_at(start, "浮点字面量后不能直接跟标识符或小数点");
        Token *dtok = new_token(TK_DBL, start, buf);
        dtok->dval = dv;
        cur = cur->next = dtok;
        continue;
      }
      if (v > (base == 16 ? 0xFFFFFFFFLL : 0x7FFFFFFFLL))
        error_at(start, "整数字面量超出 32 位范围（十进制 ≤ 2147483647，十六进制 ≤ 0xFFFFFFFF）");
      Token *tok = new_token(TK_NUM, start, buf);
      tok->val = (int)v;
      cur = cur->next = tok;
      continue;
    }

    // 标识符 / 关键字（关键字由 parser 判定）
    // v1.0.9 命名空间（轻量）：名字可含 '::' 限定段（str::len）——整段切成一个 TK_IDENT，
    //   函数表/调用查找按字符串比对，parser/codegen 零改动；'::' 后必须紧跟标识符首字符。
    if (is_ident1(*buf)) {
      char *start = buf;
      buf++;
      while (is_ident2(*buf)) buf++;
      while (buf[0] == ':' && buf[1] == ':' && is_ident1(buf[2])) {
        buf += 2;
        while (is_ident2(*buf)) buf++;
      }
      cur = cur->next = new_token(TK_IDENT, start, buf);
      continue;
    }

    // 字符串字面量 "..."（v0.7.3：转义解码，单行，收 \0 由数据段统一补）
    if (*buf == '"') {
      char *start = buf;
      buf++;
      size_t cap = 16, len = 0;
      char *s = malloc(cap);
      for (;;) {
        if (*buf == '"') { buf++; break; }
        if (*buf == '\0' || *buf == '\n')
          error_at(start, "字符串未闭合（字符串不能跨行）");
        unsigned char byte;
        if (*buf == '\\') buf = parse_escape(start, buf, &byte);
        else byte = (unsigned char)*buf++;
        if (len + 1 > cap) { cap *= 2; s = realloc(s, cap); }
        s[len++] = (char)byte;
      }
      Token *tok = new_token(TK_STR, start, buf);
      tok->sval = s;
      tok->slen = (int)len;
      cur = cur->next = tok;
      continue;
    }

    // 字符字面量 'x'（v0.7.3：单字符/单转义 → TK_NUM 数值）
    if (*buf == '\'') {
      char *start = buf;
      buf++;
      unsigned char byte;
      if (*buf == '\\') buf = parse_escape(start, buf, &byte);
      else if (*buf == '\'' || *buf == '\0' || *buf == '\n')
        error_at(start, "字符字面量缺少内容");
      else byte = (unsigned char)*buf++;
      if (*buf != '\'')
        error_at(buf, "字符字面量只能含一个字符");
      buf++;
      Token *tok = new_token(TK_NUM, start, buf);
      tok->val = byte;
      cur = cur->next = tok;
      continue;
    }

    // 三字符运算符（先于双字符，避免 <<= 被切成 << + =）
    static char *three_chars[] = { "<<=", ">>=" };
    bool three = false;
    for (int i = 0; i < 2; i++) {
      if (startswith(buf, three_chars[i])) {
        cur = cur->next = new_token(TK_PUNCT, buf, buf + 3);
        buf += 3;
        three = true;
        break;
      }
    }
    if (three) continue;

    // 双字符运算符（长优先，避免把 == 切成 = =；++ -- 同理）
    // v1.0.10：新增 "^^" 幂运算符（用户拍板，2026-09-09）——不抢 "^"（位异或）也不抢 "**"
    //   （双指针心智 / 未来可能支持双指针）；D 语言同款符号。本层只认 token，语法/代码生成后续接。
    static char *two_chars[] = { "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=", "%=", "->", "<<", ">>", "&=", "|=", "^=", "^^" };
    bool two = false;
    for (int i = 0; i < 20; i++) {
      if (startswith(buf, two_chars[i])) {
        cur = cur->next = new_token(TK_PUNCT, buf, buf + 2);
        buf += 2;
        two = true;
        break;
      }
    }
    if (two) continue;

    // 单字符运算符 / 分隔符（v0.7.x 加 '.' 字段访问；v0.7.2 加 ^ ~ | 位运算；
    //   v1.3.1 加 ? : —— 三元 ?: 与 switch 的 case/default 标签都需要）
    // ⚠️ ':' 的加入**不碰** `::` 限定名：`::` 只在标识符扫描里被吃（后续紧跟标识符首字符，
    //   见上方 `while (buf[0]==':' && buf[1]==':' && is_ident1(buf[2]))`），单个 ':' 从来不是名字的一部分。
    static char one_chars[] = "+-*/%(){};,&[]=<>!.^~|?:";
    if (strchr(one_chars, *buf)) {
      cur = cur->next = new_token(TK_PUNCT, buf, buf + 1);
      buf++;
      continue;
    }

    error_at(buf, "无法识别的字符 '%c' (0x%02x)", *buf, (unsigned char)*buf);
  }

  cur->next = new_token(TK_EOF, buf, buf);
  return head.next;
}
