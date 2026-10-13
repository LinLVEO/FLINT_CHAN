# 边界探针.ps1 — FLINT「语言边界表」的**真值源**（一键跑，逐条给"能编 / 报什么错"）
#
# 用法（任意目录）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\边界探针.ps1
#   powershell ... -File test\边界探针.ps1 -Only struct,param     # 只跑名字含这些子串的用例
#
# 为什么有它（2026-09-19 立，卡 T-20260919-224948）：记忆与 SPEC 里的「FLINT 语言边界表」是**人手维护的**，
#   而编译器长得很快 —— 当天实测就抓到两行已经过期（表说"struct 字段不能是数组 / 字段上限 32"，
#   实测**数组字段能编能跑、40 字段能编、上限其实是 64**）。⇒ 把边界**变成能跑的探针**：
#   表只写结论，结论的真值以本脚本为准；哪条边界变了，这里会红。
#
# 三类用例（每条都必须有**实质断言**，不是"编译成功就算过"）：
#   ok   —— 语言**支持**：必须编过，且产物**退出码 == 期望值**（支持这件事也得行为对）
#   wall —— 明确挡住的墙：必须**编译失败**，且错误文案里含关键词
#   gap  —— 已知的**静默缺口**：必须能编过（**一旦有人修好它，这条会红 ⇒ 提醒去订正边界表**）
#
# 退出码：全绿 0；任一条不符 1。

param(
  [string[]]$Only = @()
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$test  = $PSScriptRoot
$root  = Split-Path $test -Parent
$flint = Join-Path $root 'flint.exe'
$work  = Join-Path $test 'tmp\边界探针'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not (Test-Path -LiteralPath $flint)) { Write-Host "!! 找不到编译器: $flint"; exit 2 }

function GenFields([int]$n) { (1..$n | ForEach-Object { "  int f$_;" }) -join "`n" }

# v1.4.26：生成 N 个参数的函数 + 主调（权重 = 位置号，全传 1 ⇒ 和 = 1+2+…+N，错槽/错序必算错）
function GenParams([int]$n) {
  $decl = (1..$n | ForEach-Object { "int p$_" }) -join ', '
  $sum  = (1..$n | ForEach-Object { "p$_ * $_" }) -join ' + '
  $call = (1..$n | ForEach-Object { '1' }) -join ', '
  $want = $n * ($n + 1) / 2
  'int pn(' + $decl + ') { return ' + $sum + '; }' + "`n" +
  'int main() { if (pn(' + $call + ') == ' + $want + ') { return 42; } return 7; }'
}

# ---------------------------------------------------------------- 用例表
$cases = @(
  # ---------- ok：语言支持（断言产物退出码）----------
  @{ n='struct_arr_field'; kind='ok';  code=80; note='struct 里的固定长度数组字段（v1.4.4）';
     src='struct S { int buf[4]; char nm[8]; }' + "`n" +
         'int main() { struct S s; s.buf[0] = 7; s.buf[3] = 8; s.nm[0] = 65; return s.buf[0] + s.buf[3] + s.nm[0]; }' }
  @{ n='struct_40fields';  kind='ok';  code=42; note='struct 40 字段（表里旧写 32，实际 64）';
     src=('struct Big {' + "`n" + (GenFields 40) + "`n}" + "`n" + 'int main() { struct Big b; b.f40 = 42; return b.f40; }') }
  @{ n='struct_128fields'; kind='ok';  code=42; note='struct **128** 字段（上限内侧；2026-09-27 由 64 抬到 128）—— 断言三处偏移 4/252/508';
     src=('struct Big {' + "`n" + (GenFields 128) + "`n}" + "`n" + 'int main() { struct Big b; b.f1 = 20; b.f64 = 8; b.f128 = 14; return b.f1 + b.f64 + b.f128; }') }
  @{ n='struct_c_layout';  kind='ok';  code=42; note='struct 真实 C 布局（字段可读写）';
     src='struct S { int a; int b; }' + "`n" + 'int main() { struct S s; s.a = 40; s.b = 2; return s.a + s.b; }' }
  @{ n='ptr_arith_deref';  kind='ok';  code=42; note='指针算术 + 解引用（64 位）';
     src='int main() { int g2[3]; int *p = &g2[0]; int *q = p + 2; *q = 9; return *q + 33; }' }
  @{ n='global_scalar_array'; kind='ok'; code=42; note='全局变量：int 标量与数组';
     src='int g[4];' + "`n" + 'int main() { g[0] = 7; g[3] = 35; return g[0] + g[3]; }' }
  @{ n='api_ptr_return';   kind='ok';  code=42; note='api 返回类型 ptr（64 位句柄/指针）⇒ 用 char*/int* 接';
     src='api kernel32 ptr GetCommandLineA();' + "`n" + 'int main() { char *p = GetCommandLineA(); if (p == 0) { return 1; } return 42; }' }
  @{ n='ptr_local_var';    kind='wall'; err="意外的关键字 'ptr'"; note='⚠️ ptr 只是 api 返回类型的关键字，**不能当变量类型**（要接就用 char* / int*）—— 本轮探针实测新发现';
     src='api kernel32 ptr GetCommandLineA();' + "`n" + 'int main() { ptr p = GetCommandLineA(); if (p == 0) { return 1; } return 42; }' }
  @{ n='param_four';       kind='ok';  code=42; note='内部函数参数 4 个（前 4 个走寄存器 rcx/rdx/r8/r9）';
     src='int four(int a, int b, int c, int d) { return a + b + c + d; }' + "`n" + 'int main() { return four(10, 11, 12, 9); }' }
  @{ n='param_six';        kind='ok';  code=42; note='内部函数参数 6 个 ⇒ 第 5、6 个走**栈参**（v1.4.26 由 4 抬到 32，规范 = MSDN x64 ABI）';
     src='int six(int a, int b, int c, int d, int e, int f) { return a * 1 + b * 2 + c * 4 + d * 8 + e * 16 + f * 32; }' + "`n" + 'int main() { if (six(1, 2, 3, 4, 5, 6) == 321) { return 42; } return 7; }' }
  @{ n='param_order';      kind='ok';  code=42; note='多参**求值顺序 = 右→左**（规范原文；计数器实参钉住：右→左得 54321）';
     src='int n;' + "`n" + 'int tick() { n = n + 1; return n; }' + "`n" + 'int ord(int a, int b, int c, int d, int e) { return a * 10000 + b * 1000 + c * 100 + d * 10 + e; }' + "`n" + 'int main() { if (ord(tick(), tick(), tick(), tick(), tick()) == 54321) { return 42; } return 7; }' }
  @{ n='param_dbl_stack';  kind='ok';  code=42; note='double 落在**栈参**上（第 8 个位置；规范：浮点第 5 个起也落栈）';
     src='int d8(int a, int b, int c, int d, int e, int f, int g, double h) { if (h > 3.0) { if (h < 3.5) { return 42; } } return 7; }' + "`n" + 'int main() { return d8(1, 2, 3, 4, 5, 6, 7, 3.25); }' }
  @{ n='param_32';         kind='ok';  code=42; note='上限**内侧**：32 个参数（28 个栈参 ⇒ 栈偏移到 248，逼出 disp32 形态）';
     src=(GenParams 32) }
  @{ n='func_ptr_local';   kind='ok';  code=42; note='函数指针（本地声明 + 间接调用）';
     src='int inc(int x) { return x + 1; }' + "`n" + 'int main() { int (*fp)(int); fp = &inc; return fp(41); }' }

  # ---------- （2026-10-13 补齐「疑似未覆盖」6 条里的 4 条：字符串模块名 / 转义 / 拆字节 / 容器 ----------
  @{ n='api_str_modname_autoext'; kind='ok'; code=42; note='**字符串模块名**（`api "名字"`）：名字不含 `/` 时出端自动补 `.dll`（实测产物**导入**名 = `kernel32.dll`）；同族实测：写 `"kernel32.dll"` 不会补成 `.dll.dll`';
     src='api "kernel32" int GetTickCount();' + "`n" + 'int main() { if (GetTickCount() > 0) { return 42; } return 7; }' }
  @{ n='api_str_abs_path';  kind='ok';  code=42; note='字符串**模块名**写完整路径（含 `/`）⇒ **不补** `.dll`，由 loader 自己补后缀（实测能跑）；⚠️ 路径原样烧进产物（换机即失效）⇒ 生产写裸名';
     src='api "C:/Windows/System32/kernel32" int GetTickCount();' + "`n" + 'int main() { if (GetTickCount() > 0) { return 42; } return 7; }' }
  @{ n='slot_byte_split_mod256'; kind='ok'; code=42; note='`int` 是 8 字节**有符号**槽（语言里没有**无符号**整型）⇒ 拆字节一律 `% 256` **取模** ＋ **负数兜底**（实测裸 `%` 对 −31 给 −31，兜底后 225；断言 193 与 −31 两格）';
     src='int main() { int a = 193; int b = 0 - 31; int x = a % 256; if (x < 0) { x = x + 256; } int y = b % 256; if (y < 0) { y = y + 256; } if (x == 193) { if (y == 225) { return 42; } } return 7; }' }
  @{ n='vec_slot_roundtrip'; kind='ok'; code=193; note='通用容器在**无泛型**语言里的现实形态 = **8 字节槽 ＋ 取地址传值**（`lib\vec_lib.fl`）：`vec_push(v,&a)` 把 193 的 8 字节拷进槽、`vec_get` 取回原值（退出码 = 原值 193）';
     src='include "vec_lib.fl"' + "`n" + 'int main() { char *v = std::vec_new(4); int a = 193; v = std::vec_push(v, &a); if (std::vec_len(v) == 1) { int *q = std::vec_get(v, 0); return *q; } return 7; }' }

  # ---------- wall：明确挡住的墙（断言错误关键词）----------
  @{ n='param_33';         kind='wall'; err='参数最多 32 个';    note='内部函数参数 **33**（越过 v1.4.26 新上限 32；旧口径 4 见本文件历史）';
     src=(GenParams 33) }
  @{ n='global_ptr_var';   kind='wall'; err='指针类型的全局变量';  note='全局变量不能是指针';
     src='int *gp;' + "`n" + 'int main() { int x = 5; gp = &x; return 42; }' }
  @{ n='global_struct';    kind='wall'; err='struct 全局变量';     note='struct 不能当全局变量';
     src='struct S { int a; }' + "`n" + 'struct S gs;' + "`n" + 'int main() { return 42; }' }
  @{ n='global_struct_ptr'; kind='wall'; err='struct 全局变量';    note='⚠️ 连"全局 struct 指针"也拒（可 global_struct 的报错文案却建议用它 —— 文案误导）';
     src='struct S { int a; }' + "`n" + 'struct S *gsp;' + "`n" + 'int main() { return 42; }' }
  @{ n='char_array_init';  kind='wall'; err='数组暂不支持整体初始化'; note='char 数组不能整体初始化';
     src='int main() { char s[4] = "abc"; return s[0]; }' }
  @{ n='adjacent_strings'; kind='wall'; err="期望 ';'";           note='相邻字符串字面量不拼接';
     src='int main() { char *s = "ab" "cd"; return 42; }' }
  @{ n='sizeof';           kind='wall'; err="未声明的变量 'sizeof'"; note='没有 sizeof';
     src='int main() { int x = 4; return sizeof(x); }' }
  @{ n='c_cast';           kind='wall'; err='意外的关键字';        note='没有 C 风格转型（(int)d）';
     src='int main() { double d = 3.9; int x = (int)d; return x; }' }
  @{ n='long_long';        kind='wall'; err="未声明的变量 'long'";  note='没有 64 位整数类型（long long / int64）';
     src='int main() { long long x = 5; return 42; }' }
  @{ n='amp_api';          kind='wall'; err='需带括号调用';        note='&外部API名 不支持（要回调 → 库侧按 id 分派）';
     src='api kernel32 int GetTickCount();' + "`n" + 'int main() { int *p = &GetTickCount; return 42; }' }
  @{ n='fields_129';       kind='wall'; err='结构体字段上限 128';  note='struct 字段上限 128（2026-09-27 由 64 抬到 128；更早旧写 32）';
     src=('struct Big {' + "`n" + (GenFields 129) + "`n}" + "`n" + 'int main() { struct Big b; b.f129 = 42; return b.f129; }') }

  @{ n='str_escape_unknown'; kind='wall'; err='未知转义'; note='字符串**转义**只认少数几个 ⇒ 路径写 `"E:\FLINT-lab"` 报「未知转义」（Windows 路径必须写 `/`；`\q` 这类也拒）';
     src='int main() { char *s = "E:\FLINT-lab"; return 42; }' }
  @{ n='api_ret_type_char'; kind='wall'; err='api 返回类型须为 int / void / ptr / double'; note='api 返回类型只有 int / void / ptr / double（`char` / `long` 都拒；`double` 能编）';
     src='api kernel32 char GetTickCount();' + "`n" + 'int main() { return 42; }' }
  @{ n='api_modname_dot'; kind='wall'; err='api 返回类型须为 int / void / ptr / double'; note='**裸模块名不吃 `.`**：写 `api kernel32.dll` 被读成「模块名 kernel32 ＋ 返回类型 dll」⇒ 报的是返回类型那句（**文案指错方向**，报错列落在 `.` 之后）；要带 `.dll` 得用字符串形式';
     src='api kernel32.dll int GetTickCount();' + "`n" + 'int main() { return 42; }' }
  @{ n='api_double_param'; kind='wall'; err="api 声明期望 ')'"; note='**api 形参只能是 int**：写 `double x` 直接报语法错（同族：`POINT` 这类按值 8 字节结构也传不了）';
     src='api msvcrt double sqrt(double x);' + "`n" + 'int main() { return 42; }' }

  # ---------- （2026-10-12 v1.4.27 起本类**清零**：最后两条 T1 双向缺口已收成 wall）----------
  # gap 机制保留：kind='gap' = 已知静默缺口（能编过才算过 ⇒ 一旦修好它这条会红、提醒订正边界表）。
  # 2026-10-13（B1-3）**本类清零**：唯一那条 gap（模块名 63 字节静默截断）已收成下面的 wall。
  # 一旦将来又发现静默缺口，照旧加 gap 用例（这条注释就是"当前 gap 条数 = 0"的真值源）。
  @{ n='api_modname_over63'; kind='wall'; err='导入模块名过长：写出名最长 63 字节，现在 74 字节'; note='（B1-3 修好，原 gap）**模块名写出名硬上限 63 字节**：裸短名会自动补 `.dll`，那 4 个字节**也算在内** ⇒ 70 个 `A` = 74 字节。改前是**静默截断**（编译 exit 0、产物文件里只剩 63 个 `A`、启动期 0xC0000135）；现在默认档编译期硬错，文案给"最长 63 字节 / 现在 74 字节"';
     src='api "' + ('A'*70) + '" int GetTickCount();' + "`n" + 'int main() { return 42; }' }
  # 两条 T1 缺口（值→int* 形参 / 指针→int 形参）已由卡 T-20261012-210751 改成默认档编译期硬错，
  # 已按规矩同轮搬进下面的 wall 段（否则本脚本会以"gap 竟然被拦了"变红）。
  @{ n='int_arg_to_ptr_param'; kind='wall'; err='地址形参需要指针'; note='v1.4.27（卡 T-20261012-210751）**本刀修好**：值（int 变量/字面量/算术结果）→ int*/char*/struct* 形参，默认档即编译期硬错。旧文案是 kind=gap（静默通过，实测退出码 1）；真 flint 与 boot 双端同口径';
     src='int f(int *p) { return 1; }' + "`n" + 'int main() { int x = 5; return f(x); }' }
  @{ n='ptr_arg_to_int_param'; kind='wall'; err='地址值不能装进 int 形参'; note='v1.4.27（卡 T-20261012-210751）**本刀修好**：指针/取址/数组名/字符串/new → int 形参，默认档即编译期硬错。旧文案是 kind=gap（静默截断，实测退出码是垃圾值：本轮 -962725512、工单记 1242561464，每次不同 ⇒ 正是"栈上残渣"）；双端同口径';
     src='int f(int n) { return n; }' + "`n" + 'int main() { int x = 5; int *p = &x; return f(p); }' }

  # ---------- 2026-10-13（B1-3）：模块名 63 字节上限的**两侧**（上限内侧 1 条 ok ＋ 外侧 1 条 wall）----------
  #   · 内侧 = 63 字节**整**：用一条真路径把它撑满（`C:/Windows/System32//` ＋ 17 组 `./` ⇒ 63 字节，
  #     末段仍是 `kernel32`）—— 这类名字含 `/` ⇒ 出端**不补** `.dll`。产物必须真能加载并跑出 42，
  #     否则"上限是 63"就只是嘴上说（本机实测：63 能跑、64 编译期被拒）。
  #   · 外侧 = 64 字节：改前**编译 exit 0**、产物里是"半个路径"、启动期 0xC0000135（这就是工单说的
  #     "半个路径导入表"的真实形态；`"改前会红"取证`：拿本刀之前的 flint.exe 跑本用例 ⇒ 会红成"竟然编译通过了"）。
  #   · ⚠️ 本用例的路径是本机 `C:/Windows/System32`（与 api_str_abs_path 同族假设：Windows 装在 C:）。
  @{ n='api_modname_63_ok'; kind='ok'; code=42; note='模块名写出名 **63 字节**（上限内侧）必须编过**且产物能加载**：`C:/Windows/System32//` ＋ 17×`./` ＋ `kernel32` = 63 字节（含 `/` ⇒ 不补后缀），导入名原样烧进产物、由 loader 解析';
     src='api "C:/Windows/System32//' + ('./'*17) + 'kernel32" int GetTickCount();' + "`n" + 'int main() { if (GetTickCount() > 0) { return 42; } return 7; }' }
  @{ n='api_modname_path64'; kind='wall'; err='导入模块名过长：写出名最长 63 字节，现在 64 字节'; note='同族路径的**外侧 1 字节**（单斜杠基址 `C:/Windows/System32/` ＋ 18×`./` ＋ `kernel32`）= 64 字节 ⇒ 默认档编译期硬错（改前：编译 exit 0、产物导入名被从尾部砍成 63 字节的"半个路径"、启动期 0xC0000135 —— 本刀实测过）';
     src='api "C:/Windows/System32/' + ('./'*18) + 'kernel32" int GetTickCount();' + "`n" + 'int main() { return 42; }' }
)

# ---------------------------------------------------------------- 跑
$rows = @(); $bad = 0
foreach ($c in $cases) {
  if ($Only.Count -gt 0) {
    $hit = $false
    foreach ($k in $Only) { if ($c.n -like "*$k*") { $hit = $true } }
    if (-not $hit) { continue }
  }
  $f  = Join-Path $work ($c.n + '.fl')
  $ex = Join-Path $work ($c.n + '.exe')
  Set-Content -LiteralPath $f -Value $c.src -Encoding ASCII
  if (Test-Path -LiteralPath $ex) { Remove-Item -LiteralPath $ex -Force }
  $out = & $flint $f -o $ex 2>&1
  $cc  = $LASTEXITCODE
  $msg = (($out -join ' ') -replace '\s+', ' ')

  $expect = ''; $actual = ''; $okrow = $false
  switch ($c.kind) {
    'ok' {
      $expect = "编译通过 + 退出码 $($c.code)"
      if ($cc -ne 0) { $actual = "编译失败 (exit=$cc)" }
      else {
        & $ex | Out-Null
        $rc = $LASTEXITCODE
        $actual = "退出码 $rc"
        if ($rc -eq $c.code) { $okrow = $true }
      }
    }
    'gap' {
      $expect = '编译通过（已知静默缺口）'
      if ($cc -eq 0) {
        & $ex | Out-Null
        $actual = "编译通过（实测退出码 $LASTEXITCODE）"; $okrow = $true
      } else { $actual = "已经被拦住 (exit=$cc) —— 缺口可能已修，去订正边界表" }
    }
    'wall' {
      $expect = "编译失败 + 文案含「$($c.err)」"
      if ($cc -eq 0) { $actual = '竟然编译通过了' }
      else {
        $has = $msg.Contains($c.err)
        $actual = if ($has) { '已拒绝（文案一致）' } else { '已拒绝但文案不含关键词' }
        $okrow = $has
      }
    }
  }
  if (-not $okrow) { $bad++ }
  $rows += [pscustomobject]@{ 用例 = $c.n; 类型 = $c.kind; 边界 = $c.note; 期望 = $expect; 实测 = $actual; 结果 = if ($okrow) { 'OK' } else { '!! 不符' } }
}

Write-Host ''
Write-Host '===== FLINT 边界探针（真值源）====='
Write-Host ("编译器: " + $flint)
Write-Host ("用例数: " + $rows.Count)
Write-Host ''
$rows | ForEach-Object { "{0,-24} {1,-4} {2,-6} {3}" -f $_.用例, $_.类型, $_.结果, $_.实测 }
Write-Host ''
if ($bad -gt 0) {
  Write-Host "---- 不符的条目（$bad 条）----"
  $rows | Where-Object { $_.结果 -ne 'OK' } | ForEach-Object { "  [{0}] {1}`n      期望: {2}`n      实测: {3}`n      边界: {4}" -f $_.类型, $_.用例, $_.期望, $_.实测, $_.边界 }
  Write-Host ''
  Write-Host "边界探针：$bad 条不符 ⇒ exit 1（要么实现变了、要么边界表该订正）"
  exit 1
}
Write-Host ("边界探针：{0}/{0} 全绿 —— 与记忆/SPEC 的边界表一致" -f $rows.Count)
exit 0
