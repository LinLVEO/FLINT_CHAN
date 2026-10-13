# boot/verify.ps1 — FLINT 自举 boot 编译器验证（B2b/B2c 固化；Agent 维护）
# 用法：powershell -ExecutionPolicy Bypass -File E:\FLINT\boot\verify.ps1
# 步骤：① 真 flint 重建 b1_emit.exe / b1_parse.exe
#       ② parser 自测（b1_parse.exe，退出码 0 = 全过）
#       ③ 正向样本：boot 编译 samples\<名>.fl → 运行产物 → 比对退出码
#       ④ 负例样本：boot 必须编译失败（非 0 退出）
#       ⑤ 自举闭环（boot 编译自身 → 第二代）
#       ⑥ 差分对照（同源 boot/真 flint 各编译一次 → 产物退出码必须一致）
#       ⑦ B2k/B2l：带 UTF-8 BOM 的源文件必须能编译（现场生成，不进仓库）；取模 % / %= 差分
#       ⑧ B2n：&函数名（函数地址，回调地基）正例 + 负例（未定义函数 / &f(1)）+ 差分
#       ⑨ B2o：真实应用 hw.fl 读数路径（内存/磁盘/CPU，不依赖 WinRing0）正例 + 差分
#       ⑩ B2p：托管变量（own/share）禁止嵌套块内声明（对齐真 flint 决策 20）负例 nb19/nb20
#       ⑪ B2q：标准库 lib/str_lib.fl（字符串）boot 侧编译 + 差分 b2q1
#       ⑫ B2u：含空格/带引号路径的实参（PowerShell 自动加引号）
#       ⑬ B2v：include 去重（同写法/不同写法/菱形依赖只展开一次）+ 循环 include 负例 nb21
#       ⑭ B2w：重复定义检查（重复函数 nb22 / 重复 struct nb23 / 重复 main nb24 必须报错）
#       ⑮ B2x：include 免相对路径（回退 <exe目录>..\lib\）正例 b2x1 + 差分
#       ⑯ io 前置：库带 api 声明且 include 在函数定义之后（b2y0）正例 + 差分
#       ⑰ B2y：标准库 io_lib.fl（整文件读写）正例 b2y1 + 差分
#       ⑱ B2z：流式 io（open/close/read/write/seek/tell/eof）正例 b2y2 + 差分
#       ⑲ B3a/B3b：同名遮蔽（嵌套块可遮蔽，同作用域/形参不可）+ 函数返回指针（int*/char*/struct*）
#          正例 b3a1/b3a2/b3b1 + 差分 + 负例 nb25..nb28
#       ⑳ B4a：for 语句（init 一次 → cond 判 → body → inc → 回判；三段可空）
#          正例 b4a1/b4a2/b4a3/b4a4 + 差分 + 负例 nb29..nb32
#       ㉑ B4b：boot 对齐真 flint 剩余差异——char 值返回（ret=4，返回值不截断）+ char 值形参 +
#          struct 字段数上限 32。正例 b4b1（不截断/截断只在 char 目标）、b4b2（print 段按返回类型
#          分派，比对 stdout 不只比对退出码）、b4b3（char 目标：字段/数组/裸指针/形参）+ 差分 +
#          负例 nb33（33 字段 struct）—— ⚠️ 2026-09-19 更新：**字段上限已随真 flint 提到 64**（见 ㉖），
#          nb33 转正例 `b6b1` 并删除，新上限由负例 nb35 钉住（2026-09-19 版 = 65 字段；⚠️ 2026-09-27
#          上限 64 → 128 后本样本**同步抬到 129 字段**，新正例 = b6b2（128 字段，见 ㉞））。nb26 已转正例 → 删除。
#       ㉒ B5a：通用容器 lib\vec_lib.fl（路线 V1「8 字节槽 + 取地址传值」）boot 侧正例 b5a1
#          （int 往返 / 扩容后旧元素存活 / 指针往返 / 越界与负下标返回 0 / 长度口径）+ 差分。
#          样本不含 double：boot 侧浮点未接（已知边界），double 仓只由真 flint 侧样本覆盖。
#       ㉓ B5b：`samples\b5b1.fl` 拿抽到库层的 `lib\ui_lib.fl` 做 boot 侧冒烟（**组件层的 boot 双端覆盖**）。
#          2026-09-17 曾留证不注册：boot 编不过，卡在 `ui_lib.fl` 的 `CreateFontA`（**14 个实参**），
#          报 `parse err=-175`。根因 = 真 flint 的 API 实参上限 v1.4.0 已提到 16（`flint.h:246`
#          `API_MAX_ARGS`），boot 侧仍写死 12。
#          **同日修复**（任务卡 T-20260917-215230）：`lib_parse.fl` 的 `argc > 12` → `argc > 16`，
#          一个常量、零其它改动（发射器本就把第 5 个起的实参按 Win64 放到 `[rsp+32+8k]`，无需改）。
#          ⇒ b5b1 已**转正**：进 $pos（产物退出码 42）+ $diff（boot 与真 flint 同为 42）。
#       ㉔ b2k5：**指针经 ++/-- 不得被截断**（任务卡 T-20260918-005227 的回归样本）——
#          开 ASLR（DYNAMIC_BASE|HIGH_ENTROPY_VA=0x0160）后基址在 0x7FF6xxxxxxxx，被零扩展砍掉高 32 位的
#          地址会解引用垃圾或直接崩（0xC0000005）。正例 b2k5 + 差分（boot 与真 flint 同 42）。
#          ⚠️ boot 产物自 v1.4.15 起**自带 0x0160** ⇒ 本脚本全部"正例/差分"同时变成 **ASLR 行为测试**
#          （此前 boot 产物 DllCharacteristics=0，ASLR 路径在 boot 侧根本没被测过 —— 这正是本条缺陷潜伏的原因）。
#       ㉕ B6a：**指针目标值门槛**（卡 T-20260918-014653；v1.4.31）——`int n = 5; int *p = n;` 这类
#          「指针目标接纯 int 值」真 flint 一直拒（T1 ④ `check_ptr_target`），boot 修复前**静默产出截断指针**。
#          负例 nb34（boot 必须报错）+ ④b 的「真 flint 侧同样拒绝」差分断言；落地口径覆盖**指针声明 /
#          指针赋值 / 指针字段写**，白名单 = 地址类值 / 显式常量 / API 或指针返回的调用 / new /
#          「装过地址的 int」变量 —— 后者的正例就是 `test/samples/rev4.fl`（`int s = "AB"; char *q = s;`）。
#       ㉖ B6b：**struct 字段上限 32 → 64**（v1.4.31；与 ㉕ 同轮落地，起因 = 给 `struct Parse` 加一个字段
#          把它顶成 33 字段、被 boot 自己的 -197 拦住）。真 flint 的上限**早就是 64**（2026-09-19 边界探针
#          `fields_65` 实测），boot 写死 32 ⇒ **boot 比真 flint 窄 = 真双端断点**（真 flint 能编 33 字段、
#          boot 报错）。改法 = 一个常量。样本：正例 b6b1（33 字段，原负例 nb33 转正）+ 负例 nb35（65 字段）
#          + ④b 的「真 flint 侧同样拒绝」差分。布局侧无 32 假设（`fld_off` 只用低 3 位存字节偏移）。
#       ㉞ 2026-09-27（卡 T-20260927-212533 的后续刀）：**struct 字段上限 64 → 128** —— 起因 = FLGUI 的
#          `GuiCtx` 已 **64/64 满**（面板要加的阴影强度 / 二级色 / 焦点圈没地方放）；真 flint 与 boot
#          **同一轮**改（`src\parse.c` 的 `>= 128` ＋ `lib_parse.fl` 的 `>= 128`）。同轮顺带修掉一处
#          **字段区容量与守卫不一致**：`st_add_field` 的守卫写 16384，而解析侧栈数组只有 1024
#          （字段区 514 起 ⇒ 仅 102 项）⇒ 超过 102 个字段就**静默越界写**；现守卫与 `int sflat[4096]`
#          （`b1_parse.fl` / `samples\real2.fl`）对齐。样本：正例 **b6b2**（128 字段，断言偏移
#          4 / 252 / 508 三处相加 = 42）+ 负例 **nb35**（129 字段）+ ④b 的「真 flint 侧同样拒绝」差分。
#       ㉗ 2026-09-21（卡 T-20260921-215305 第 3 档·第一刀）：**二元运算右值直寻址档**样本 ——
#          dir1a（右值 = 本地 int 标量：add/sub/imul/and/xor/or 六型 ＋ 左值立即数两型，位掩码 255）／
#          dir1b（右值 = 立即数：累加器形态四型 ＋ 左值立即数两型 ＋ 老路负对照两条，位掩码 255）。
#          两样本同时进 $pos（boot 侧退出码 = 255）与 $diff（真 flint 侧同为 255）⇒ 钉住这一刀的双端口径；
#          凡后续再动 `gen_expr` 的二元运算发射路径，这两条就是"方向 / 宽度 / 寄存器约定"的哨兵。
#       ㉘ 2026-09-21（卡 T-20260921-215305 第二刀）：**比较 → 标志位**样本 ——
#          dir2（六个比较算子 × if / else 假分支 / while / for 四种条件位置；含 `while (b < a)` 条件为假的
#          反向对照 —— 反面条件码写反就会掉位），位掩码全亮才 42；同样同时进 $pos 与 $diff。
#       ㉙ 2026-09-21（卡 T-20260921-215305 第三刀）：**单实参 int 小函数内联**样本 ——
#          dir3（`return x ± 常量` / `return x;` 两种体形态 × 常量实参 / 循环内 / for 内 / 嵌套调用 /
#          表达式内五种位置 ＋ 两条老路负对照：两形参函数不在白名单），位掩码全亮才 42；进 $pos 与 $diff。
#       ㉚ 2026-09-21（卡 T-20260921-232138 第四刀 A1）：**局部 int 标量进寄存器**样本 ——
#          reg1（基础形态：循环累加/计数/条件读 ＋ 多变量共存 ＋ 跨调用存活 ＋ 形参混用 ＋ 数组混用）／
#          reg2（**负对照**：`&x` ／ `x++` ／ `x += e` ／ for 头表达式位赋值 的变量**不许提升**，
#                 外加 char/指针/struct/数组混在同一函数）／
#          reg3（callee-saved 跨调用存活：嵌套调用 ＋ 递归 ＋ 循环内调用 ＋ API 调用 ＋ if/else 两分支）／
#          reg4（**大帧**：帧 ≥ 128 ⇒ 序言逐页探测路径 ＋ 保存区 disp32 偏移）／
#          reg5（**块作用域槽复用**：同槽邻居是数组/指针/取址变量时整槽不提升，值仍须全对）。
#          五条都是 8 位位掩码、全亮才 42，**同时进 $pos 与 $diff** ⇒ 钉住这一刀的双端口径；
#          凡后续再动「变量读/写发射点」或寄存器池，这五条就是哨兵。
#       ㊷ v1.4.28（B1-3，2026-10-13）：**导入模块名（写出名）63 字节上限** —— 真因 = 真 flint 写出端
#          `ImpGroup.dll` 是 `char[64]`，超长被 snprintf 静默截断成"半个路径"的导入表（编译 exit 0、
#          进程启动期 0xC0000135；实测 70 个 'A' 的模块名产物里只剩 63 个 'A'）。真 flint 侧改成
#          **默认档编译期硬错**（`src\parse.c` ＋ `src\pe.c` 的单点 `pe_import_module_name_len`），
#          boot 侧 `parse_apis` 同口径硬错（错误码 **-189**）。样本：正例 **b1c1**（写出名恰好 63 字节，
#          $pos ＋ $diff）+ 负例 **nb38**（74 字节裸短名，④ 负例 ＋ ④b 的「真 flint 侧同样拒绝」差分）。
#          判据同源 = `test\边界探针.ps1` 的 api_modname_63_ok / api_modname_over63 / api_modname_path64。
#       ㊸ v1.4.28（B1-5 ＋ B1-4，2026-10-13）：**全局初值尾巴** ＋ **字符串模块名被注入库挡住** ——
#          B1-5：真 flint 的 `parse_global_init` 只吃一个字面量、随后**静默跳到 ','/';'**（`int g = 0 - 1;`
#          编译 exit 0 而 g == 0；`int g = 1 + x;` 连"初值必须是编译期常量"都绕过）⇒ 真 flint 改成
#          **默认档硬错**，boot 侧 `parse_globals` 从**通用 -47** 换成**专码 -213**（结论相同、码分得清）。
#          样本：负例 **nb39**（④ ＋ ④b）；判据同源 = 探针的 global_init_expr / global_init_var /
#          global_init_garbage ＋ global_init_neglit_ok（上限内侧不许误伤）。
#          B1-4：`is_api_decl_start()` 不认字符串模块名 ⇒ 声明不被 `hoist_apis` 前移、被注入的
#          `lib_print.fl` 挡在身后，报「api 声明必须放在文件最顶部」且**位置指向用户真·顶部那一行**
#          （假拒绝；boot 侧本来就能编 ⇒ 真 flint 比 boot 窄）。修法 = 谓词接受 `TK_STR`（1 行）。
#          样本：正例 **b1c2**（$pos ＋ $diff）；判据同源 = 探针的 api_str_modname_print。
# 退出码：0 = 全部通过；1 = 有失败

$ErrorActionPreference = 'Stop'
$bootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $bootDir
$flint = Join-Path $root 'flint.exe'
$boot = Join-Path $bootDir 'b1_emit.exe'
$parseExe = Join-Path $bootDir 'b1_parse.exe'
$samples = Join-Path $bootDir 'samples'
# io 样本（b2y1/b2y2）读写 E:\FLINT\test\tmp —— 目录不存在时先建（否则 4 项差分假红）
New-Item -ItemType Directory -Force -Path (Join-Path $root 'test\tmp') | Out-Null

$pass = 0; $fail = 0
function Ok($msg) { Write-Host "  OK   $msg"; $script:pass++ }
function Bad($msg) { Write-Host "  FAIL $msg"; $script:fail++ }

# ① 重建
foreach ($src in @('b1_emit.fl', 'b1_parse.fl')) {
  & $flint (Join-Path $bootDir $src) | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "编译 $src"; } else { Ok "编译 $src" }
}
if ($fail -gt 0) { Write-Host "重建失败，中止"; exit 1 }

# ② parser 自测
& $parseExe
if ($LASTEXITCODE -eq 0) { Ok 'parser 自测（全部断言通过）' } else { Bad "parser 自测 exit=$LASTEXITCODE" }

# ③ 正向样本（B1/B2a 单函数 + B2c 多函数 + B2d 控制流 + B2e 数组 + B2f struct/指针 + B2g include/api/print/真实库）
$pos = [ordered]@{
  s1 = 42; s2 = 7; s3 = 9; s4 = 3; s5 = -3; s6 = 6
  s7 = 42; s8 = 12; s9 = 6; s10 = 15; s11 = 5; s12 = 10
  f1 = 42; f2 = 42; f3 = 42; f4 = 42; f5 = 42; f6 = 42; f7 = 42
  w1 = 45; w2 = 55; w3 = 42; w4 = 42; w5 = 15; w6 = 42; w7 = 42; w8 = 42; w9 = 42
  a1 = 42; a2 = 42; a3 = 42; a4 = 42; a5 = 42; a6 = 42; a7 = 55; a8 = 42; a9 = 42
  st1 = 42; st2 = 42; st3 = 42; st4 = 42; st5 = 42; st6 = 42; st7 = 42; st8 = 42
  inc1 = 42; ap1 = 42; pr1 = 42; real1 = 42
  real2 = 0; real3 = 42; api2 = 42
  t_bit = 23; t_addr = 42; t_callstmt = 42
  t_arr2 = 42; t_ptr2 = 42; t_str2 = 42
  b2j1 = 42; b2j2 = 42; b2j3 = 42; b2j4 = 42; b2j5 = 42; b2j6 = 42; b2j7 = 42
  b2k1 = 42; b2k2 = 42; b2k3 = 42; b2k4 = 42; b2k5 = 42
  b2l1 = 42; b2l2 = 42; b2l3 = 42; b2l4 = 42; b2l5 = 42; b2l6 = 42
  b2m1 = 42
  b2n1 = 42; b2n2 = 42
  b2o1 = 42
  b2p1 = 42
  b2q1 = 42
  b2q2 = 42
  b2r1 = 42
  b2s1 = 42
  b2v1 = 42
  b2x1 = 42
  b2y0 = 42
  b2y1 = 42
  b2y2 = 42
  b3a1 = 42; b3a2 = 42; b3b1 = 42
  b4a1 = 42; b4a2 = 42; b4a3 = 42; b4a4 = 42
  b4b1 = 42; b4b2 = 42; b4b3 = 42
  b5a1 = 42
  b5b1 = 42
  sarp1 = 18337                                    # 2026-09-22：局部 struct ＋ 定长数组字段的帧尺寸（卡 T-20260922-201154）
  b6b1 = 42; b6b2 = 42
  #     dir1b 右值=立即数 —— 两条都做 8 位位掩码，**全亮才返回 42**（$diff 的硬口径是"双端同为 42"；
  #     没全亮时退出码就是未亮的位掩码，FAIL 消息里直接看得出缺哪一位）
  dir1a = 42; dir1b = 42
  #   ㉘ 2026-09-21 第二刀（比较 → 标志位）哨兵：dir2（六算子 × if/else/while/for 条件）
  dir2 = 42
  #   ㉙ 2026-09-21 第三刀（单实参 int 小函数内联）哨兵：dir3
  dir3 = 42
  #   ㉚ 2026-09-21 第四刀 A1（局部 int 标量进寄存器）哨兵：reg1~reg5（基础 / 负对照 / 跨调用存活 /
  #      大帧 / 块作用域槽复用 —— 都是 8 位位掩码，全亮才 42）
  reg1 = 42; reg2 = 42; reg3 = 42; reg4 = 42; reg5 = 42
  #   ㉛ 2026-09-22 第四刀 A2（就地融合 · 左脊柱）哨兵：fus1（四种发射形态：rr / imm8 / imm32 / acc
  #      ＋ 两层脊柱 ＋ 减乘位运算同族）、fus2（**负例与毒形态**：脊柱底读本槽（该融合）／外层读本槽
  #      （必须退老路）／外层右值含本槽／形参目标／数组元素目标／指针算术／三层脊柱／循环累加）
  fus1 = 42; fus2 = 42
  #   ㉜ 2026-09-22 第四刀 A2 **回归哨兵**：fus3（**发射器能力表**逐格覆盖 —— 尤其
  #      `m = m * 2` 在「只有 2 个局部量」的循环函数里：imul+imm 必须退老路。A2 第一版正是
  #      把这条排除项写在"外层"分支里、被脊柱底的早返回跳过 ⇒ 整条语句被静默吞掉，
  #      样本门/回归/差分门/等价门全绿，只有真应用冒烟门抓到）
  fus3 = 42
  #   ㉝ 2026-09-22 第四刀 A3-①（**比较的寄存器感知档**）哨兵：cmp1 —— 按「形态 × 靶子 × **前提**」列格子：
  #      REG←REG ／ REG←帧槽 ／ 帧槽←REG ／ REG←imm（含**负 imm8**）／ 帧槽←imm ／ 六算子方向敏感（含 for）／
  #      **地址类比较必须退老路**（64 位 cmp）／ 比较结果**当值用**（setcc 路径不碰）。
  #      ⚠️ 位 2/8/16 的**前提 = 池只有 4**（第 5 个局部量留在帧里）⇒ 将来扩池到 7 必须回来重列这几格。
  cmp1 = 42
  #   ㉞ 2026-09-22 第四刀 A3-②（**形参进池**）哨兵：par1 —— 序言写槽之后顺手把形参装进它的寄存器
  #      （em_preg_load32，32 位 ⇒ 不带槽里高 4 字节的残渣）：形参作循环上界 ／ 4 个形参参与算术 ／
  #      形参**被赋值** ／ 形参当实参传出（被调函数自己的形参也进池）／ 循环里跨调用存活 ／
  #      **负例 = char 形参 ＋ 指针形参不许进池** ／ 大帧（disp32）／ 递归。
  par1 = 42
  #   ㉟ 2026-09-22 第三刀（**消真应用 xchg** 第一族 = 比较 · **累加器档**）哨兵：cmp2 ——
  #      左值 = 任意表达式（照旧求值到 eax）、右值 = 叶子（立即数／帧槽／池寄存器）⇒ 一条 `cmp eax,<rv>`。
  #      格子：rv=imm8 ／ rv=**负立即数**（一元负号＋字面量，条件＋值两条路径）／ rv=imm32 **双向出带** ／
  #      rv=**帧槽**（第 5 个局部量 ＋ 取址保底不提升）／ rv=**池寄存器**（含 REX.B 那一路）／
  #      六算子方向敏感 ／ **值路径**（setcc —— 本刀才接上总入口的那半边）／
  #      **负对照三条**：地址类比较（必须留 64 位老路）／ 右值非叶子（必须退老路、顺序不变）／
  #      两侧都是帧槽（x86 没有 mem,mem）。
  #      ⚠️ 位 8 的前提 = 「池只有 4 且取址变量不进池」⇒ 将来扩池到 7 时回来重列这一格。
  #      📌 配套形态核对（本刀新纪律）：boot 产物必须是 `cmp eax,imm32` / `cmp eax,[rbp-off]` /
  #      `cmp eax,rXd` 三种形态，且**只剩 3 个 xchg = 那三条负对照**（退出码哨兵证明不了"发的是哪条指令"）。
  cmp2 = 42
  #   ㊱ 2026-09-22 第三刀第二族（**除数进 ecx**：/ 与 % 且除数是叶子）哨兵：div1 ——
  #      被除数照旧求值到 eax、除数**直接从叶子搬进 ecx** ⇒ cdq ＋ idiv ecx（取模补 mov eax,edx）。
  #      格子：除数 = imm（整除／取模）／ 除数 = **池寄存器**（第 3 个声明的局部量 ⇒ 高位寄存器、走 REX.R）／
  #      除数 = **帧槽且偏移过 128 字节**（pad[20] 顶到后面 ⇒ 证明 disp32 那一路）／
  #      **负被除数 ＋ 负除数**（一元负号＋字面量、负局部量 —— 向零截断必须与老路逐位一致）／
  #      被除数 = 非叶子多种形态（数组元素、函数调用结果）／ **复合赋值**（`x /= c`、`x %= c` —— 另一条发射路径）／
  #      **负对照**：除数是表达式（必须退老路、求值顺序不变）。
  #      ⚠️ 位 8 的前提 = 「池只有 4 且取址变量不进池」。
  #      📌 配套形态核对：boot 产物必须是 `mov ecx,imm32`（含 `0xfffffff9` 这类负值）／
  #      `mov ecx,DWORD PTR [rbp-0xd8]`（disp32）／ `mov ecx,ebx` 与 `mov ecx,r13d`（两种 REX）／ `idiv ecx`，
  #      且 **`xchg eax,ecx` 只剩 2 条 = 那两条负对照**。
  div1 = 42
  #   ㊲ 2026-09-22 第三刀第三族（**移位计数直搬**：常量 ⇒ `C1 /4|/7 ib` ／ 叶子 ⇒ `mov ecx,<叶子>` ＋ `D3` ／
  #      内存 ⇒ `mov ecx,[rbp-d]` 或 `mov rcx,[rbp-off]`＋`mov ecx,[rcx+disp]` ＋ `D3`）哨兵：shf1 ——
  #      格子：常量 `>>`（含负被移值）／ 常量 `<<` **掩码边界**（0 ／ 31 ／ 32 ／ 33 ／ 300 ／ -1 —— 硬件对
  #      imm8 与 cl 同样只取低 5 位 ⇒ 必须与老路逐位一致）／ 计数 = **池寄存器**（两种 REX）／
  #      计数 = **帧槽且过 128 字节**（disp32）／ 计数 = **指针 → int 字段**（form 2）／ 计数 = **本地 struct
  #      字段**（合成地址 [rbp-d]）／ 被移值非叶子 ＋ `>>=` 复合赋值 ／ **负对照 = 计数是表达式**。
  #      ⚠️ 前提 = 「池只有 4 且取址变量不进池」（将来扩池要回来重列那几格）。
  #      📌 形态核对：产物里读到的计数装载 = `mov ecx,r13d`／`mov ecx,ebx`（池寄存器）／
  #      `mov ecx,DWORD PTR [rbp-0xb0]`（帧槽 disp32）／ `mov ecx,DWORD PTR [rcx+0x4]`（指针字段）／
  #      `mov ecx,DWORD PTR [rbp-0xc]`（struct 字段合成，0xc = 基址 0x10 − 字段偏移 4），
  #      常量移位 = `shl|sar eax,imm8`（含 `0x0/0x1f/0x21/0x2c/0xff` 这些掩码边界值），
  #      且 **`xchg eax,ecx` 只剩 3 条 = `s1_neg` 那 3 处负对照**。
  shf1 = 42
  #   ㊳ 2026-09-22 第三刀第四族（**右值 = 直接内存操作数**：本地 struct int 字段 ⇒ `<op> eax,[rbp-d]` ／
  #      指针 → int 字段 ⇒ 保留 `mov rcx,[rbp-off]` ＋ `<op> eax,[rcx+disp]`）哨兵：mem1 ——
  #      格子：减法（方向敏感 lv - mem）／ 交换律一族 `+ * & | ^`（老路算的是 `rv op lv`）／
  #      **两种形态的 disp32**（合成偏移过 128 ／ 字段偏移 128）／ 复合赋值并存 ／ 左值非叶子（数组元素、
  #      调用结果）／ **负对照两条**：char 宽度（ty != 0，字节读是 movzx）必须退老路、右值是表达式必须退老路。
  #      ⚠️ **前提（实测，A2 那条教训）**：本档只在「左值 = 字面量／未提升变量／非叶子表达式」时生效 ——
  #      左值若是**被提升的变量**（`s = s - v.a`），A2 就地融合档先接管（rv 落 eax、`sub rXd,eax`），
  #      本档看不到；所以每格故意把字面量放左边，样本头里也写明了这一条。
  #      📌 形态核对：产物里新档形态 = `sub eax,[rbp-0xc]`／`[rbp-0x1fc]`（合成 disp8＋disp32）、
  #      `sub eax,[rcx+0x4]`／`[rcx+0x80]`（form 2 disp8＋disp32）、`add|imul|or|xor|and eax,[rbp-...]`，
  #      且 **`xchg eax,ecx` 只剩 3 条 = 2 处 char 负对照 ＋ 1 处表达式负对照**。
  mem1 = 42
  #   ㊴ 2026-09-22 第五刀 A1（**数组寻址：SIB 缩放寻址** —— 本地数组 `<op> eax,[rbp+idx*8-off]` ／ 指针数组
  #      `<op> eax,[rcx+idx*8]`；老路每处白付 `shl eax,3` ＋ `lea rcx,[rbp-基址]`，写路径还要压已缩放的偏移）哨兵：sib1 ——
  #      格子：本地 int 数组 变量下标 读+写（k2 形态）／ 常量下标 ／ **下标是表达式** ／ **指针数组** 读+写 ／
  #      本地 char 数组（scale 1）读+写 ／ **char 形参指针** 读+写（老路不变，回归格）／ **大帧 disp32** ／
  #      **负对照 = 地址类下标 `a[p]`**（老路 32 位 shl 会截断 64 位地址 ⇒ 必须退老路；该语句放在运行时为假的
  #      条件里：**发出来但不执行** ⇒ 判据是「产物里仍有老路字节」而不是取值）。
  #      📌 形态核对：产物新形态 = `mov DWORD PTR [rbp+rdx*8-off],eax`（22）／`mov eax,DWORD PTR [rbp+rax*8-off]`（16）／
  #      `mov BYTE PTR [rbp+rdx*1-off],al`（5）／`movzx eax,BYTE PTR [rbp+rax*1-off]`（1）／
  #      `mov DWORD PTR [rcx+rdx*8],eax`（1）／`mov eax,DWORD PTR [rcx+rax*8]`（1），
  #      且 **老路形态恰剩 1 处 `shl eax,0x3` ＋ 1 处 `lea rcx,[rbp-…]` = 那一条负对照**。
  sib1 = 42
  #   ㊵ 2026-09-22 第五刀 B（**内存目标就地运算**：`a[idx] = a[idx] <op> v` 折成一条 `<op> [rbp+rax*8-off], v`）哨兵：acc1 ——
  #      老路那条语句要 **10 条**（下标算两遍 ＋ push/pop ＋ 读-算-写分开），真 flint 只要 3 条。
  #      格子：k2 形态（源 = 提升变量 ⇒ 寄存器源）／ 立即数源（imm8 ／ **负 imm8** ／ imm32）／
  #      **其余四算子**（`-` 方向敏感 ／ `&` ／ `|` ／ `^`）／ **下标是表达式且两侧结构相同** ／
  #      **源 = 未提升的槽**（取址保底 ⇒ `mov ecx,[rbp-off]` 再当源）／ **大帧 disp32** ／
  #      **负对照三条**（下标不同 `a[i] = a[i+1] + 1` ／ 读在右边 `a[0] = v + a[0]` ／ imul 没有内存目标形态）／
  #      **负对照：下标带副作用**（`a[f()] = a[f()] + 5` —— 老路求值两遍、折成一遍会少一次调用；
  #      该格断言 `a[0]*10 + 调用次数 == 62`，若被误折就是 61）。
  #      📌 形态核对：新产物 = `add/or/xor/sub/and DWORD PTR [rbp+rax*8-off], <imm|ebx|ecx>` **11 处**
  #      （＝样本里 11 条可折语句，逐条对上），而**旧产物同形态 0 处**（正向对照）。
  acc1 = 42
  #   ㊶ 2026-09-22 第六刀 A2（卡 T-20260922-033446）**融合档吃「数组元素右值」—— ⚠️ 实测负结果，已撤销**：
  #      该档把 `s = s <op> a[idx]` 从"`mov eax,[rbp+rax*8-off]` ＋ `<op> rXd,eax`"折成**一条**
  #      `<op> rXd,[rbp+rax*8-off]` ⇒ 尺子 k2 循环体 **13 → 12 条**（与真 flint 齐平），
  #      但 **k2 反而慢 14%**（boot 208232 → 237691 ticks；同会话交替 A/B、b1_emit 哈希钉住：
  #      prev 0672384B = 208595 ／ new 2766F1C1 = 237685 与 244041），而**真应用 m2_float 产物逐字节不变**
  #      （那儿根本没有这个惯用法 ⇒ 收益为零）。LCS 对差证明**全产物只差那两条指令** ⇒ 慢就是"融合"本身带来的
  #      （怀疑 = load-op 融进循环依赖链、与第五刀 B 刚写过的槽撞 store-to-load forwarding；**未定论，记为假设**）。
  #      ⇒ 发射器改动已 `git checkout` 撤销；**本样本保留并注册**，改当"这些形态取值正确"的普通回归样本：
  #      格子：k2 形态（下标是表达式、跨提升变量）／ 三种下标形态（字面量 ／ 提升变量 ／ 表达式）／
  #      **五算子**（`-` 方向敏感 ／ `*` 走 `0F AF /r` 内存形态 ／ `&` ／ `|` ／ `^`）／ **大帧 disp32** ／
  #      **指针数组 rhs** ＋ **地址类下标 `a[p]`**（放在运行时为假的条件里：发出来但不执行 ⇒
  #      形态核对可数"老路 `shl eax,0x3` 字节仍在"）／ **数组读在左边**（`s = a[(i+1)&3] + s`）／
  #      **rhs = struct 字段读**（kind 30）／ **下标带调用**（断言 `s*10 + 调用次数 == 91`，恰好一次）。
  acc2 = 42
  me1 = 42; me2 = 42; me3 = 42; me4 = 42       # 2026-09-20（卡 T-20260920-144154）多重声明家族
  #   ㊷ v1.4.28（B1-3）：**导入模块名（写出名）63 字节上限的两侧** —— b1c1 = 上限**内侧**（恰好 63 字节：
  #      `C:/Windows/System32//` ＋ 17×`./` ＋ `kernel32`，含 `/` ⇒ 不补 `.dll`）⇒ boot 必须编过**且产物能跑 42**；
  #      外侧 1 字节 = 负例 nb38.fl（74 字节裸短名，两端都硬错）。b1c1 进 $pos **与** $diff
  #      ⇒ 双向守门：boot 既不许比真 flint 宽（nb38），也不许比真 flint 窄（b1c1）。
  b1c1 = 42
  #   ㊸ v1.4.28（B1-4）：**字符串模块名 ＋ 同文件 print(...)** —— b1c2 必须能编、产物跑 42
  #      （改前真 flint 报「api 声明必须放在文件最顶部」并指向第 1 行第 1 列 = 假拒绝；boot 侧本来就能编
  #      ⇒ 真 flint 比 boot 窄）。进 $pos ＋ $diff ⇒ 双端同结论。
  b1c2 = 42
}
# 2026-09-20（卡 T-20260920-001345）自举缺口收敛第一疗程**转正**的样本（原来 boot 编不过，
# 现在 boot 与真 flint 都能编且产物退出码相同）。样本实体在 test\samples\（不是 boot\samples\），
# 所以单独一个循环、按 test\samples 路径编。
#   A 类「void 返回类型」：arr3 / char7 / ptr2 / st2 / st7
#   C 类「for 头赋值 init」：ctrl4 / ctrl5 / dbgcond / fn9
#   J 类「struct 定长数组字段」（2026-09-20 卡 T-20260920-141033 收口）：sarr1（7 项位掩码 = 59）／
#     sarr3（布局位掩码 = 15）—— 读路径根因修好后，boot 与真 flint 的产物退出码逐条相同。
#   K 类零散（2026-09-20 卡 T-20260920-142654 收口）：sfield1（指针字段元素取址 `&s.arr[3]` = 63）
#   E 类「多重声明家族」（2026-09-20 卡 T-20260920-144154 收口）：decl1（`int a=1, b, c=3;` = 6）／
#     multi_init（`int x=2, y=3, z=x*y;` = 6）—— 旧版语句位置只解析一个声明符 ⇒ `,` 处报 -51。
$samplesDir = Join-Path $root 'test\samples'
$posSamples = [ordered]@{
  ctrl4 = 5050; ctrl5 = 285; dbgcond = 6; fn9 = 10
  arr3 = 21; char7 = 8866; ptr2 = 99; st2 = 80; st7 = 5
  sarr1 = 59; sarr3 = 15
  sfield1 = 63
  decl1 = 6; multi_init = 6
  #   F 类「全局变量」（2026-09-21 卡 T-20260921-194703 收口）：global1（int 标量/数组/复合赋值/
  #     ++--/跨函数可见/局部遮蔽，位掩码 255）—— boot 侧新增 `.data` 节 + `[rip+disp32]` 取址后转正。
  #     ⚠️ global2（char/double 类型分支）**暂不转正**：它用到 double，而 boot 完全不支持 double
  #     （B 类特性，另立卡）；fnptr1 同理。
  global1 = 255
  #   I 类「break/continue」（2026-09-21 同卡一并收口）：loopctl1（8 项位掩码，含嵌套/for 增量语义）= 255
  loopctl1 = 255
  #   2026-09-21 第二轮补的两条"真实应用回归"样本（都是"编译过、产物跑不起来"的形态）：
  #     apimod2 = 带点模块名 + 裸模块名混用（导入表 DLL 名的布局预留必须与写出端判据一致，
  #               否则名字被从头截 4 字节 ⇒ 启动 0xC0000135 STATUS_DLL_NOT_FOUND）
  #     bigarr1 = char[2048] 大数组（长度只取低 3 位 ⇒ 帧少分配 ⇒ 越界写帧外 ⇒ 0xC0000005）
  apimod2 = 42; bigarr1 = 42
  #   2026-09-22（卡 T-20260922-042229）FLGUI 内核 M1 无头回归：flgui1.fl —— 不建窗，
  #     合成输入喂 gui_begin，22 项位掩码全亮才 42；boot 侧要能编"ctx 纯标量 + 大容量载体全走全局数组"
  #     这一形态（该形态正是被 §2.4 那条 boot 帧尺寸缺陷逼出来的）。双端 dump 对账见 test\flgui-verify.ps1。
  flgui1 = 42
  #   2026-09-22（同卡）FLGUI 控件层 M2 无头成绩单①：flgui2.fl —— 分隔线/滑块/进度条/只读文本域，
  #     26 项位掩码全亮才 42（命令序是契约，按下标断言 kind 与矩形）。
  flgui2 = 42
  #   2026-09-22（同卡）FLGUI M2 成绩单②：flgui3.fl —— 滚动视图（滚轮/夹取/滚动条）+ 弹层菜单，26 项位掩码。
  flgui3 = 42
}
Push-Location $bootDir
foreach ($k in $posSamples.Keys) {
  Remove-Item (Join-Path $samplesDir "$k.exe") -ErrorAction SilentlyContinue
  & $boot (Join-Path $samplesDir "$k.fl") | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "boot 编译 $k（exit=$LASTEXITCODE）"; continue }
  & (Join-Path $samplesDir "$k.exe")
  if ($LASTEXITCODE -eq $posSamples[$k]) { Ok "$k 产物退出码 $($posSamples[$k])" }
  else { Bad "$k 产物退出码 $LASTEXITCODE 期望 $($posSamples[$k])" }
}
Pop-Location
Push-Location $bootDir
foreach ($k in $pos.Keys) {
  & $boot "samples\$k.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "boot 编译 $k（exit=$LASTEXITCODE）"; continue }
  & "samples\$k.exe"
  if ($LASTEXITCODE -eq $pos[$k]) { Ok "$k 产物退出码 $($pos[$k])" }
  else { Bad "$k 产物退出码 $LASTEXITCODE 期望 $($pos[$k])" }
}

# ④ 负例（boot 必须报错退出）
foreach ($n in @('bad', 'nf1', 'nf2', 'nf3', 'nf4', 'nf5', 'nw1', 'nw2', 'nw3', 'nw4',
                 'na1', 'na2', 'na3', 'na4', 'na5',
                 'ns1', 'ns2', 'ns3', 'ns4', 'ns5', 'ns6', 'ns7',
                 'nb1', 'nb2', 'nb3', 'nb5', 'nb6', 'nb7', 'nb8', 'nb9',
                 'nb10', 'nb11', 'nb12', 'nb13', 'nb14', 'nb15', 'nb16', 'nb17', 'nb18', 'nb19', 'nb20', 'nb21',
                 'nb22', 'nb23', 'nb24', 'nb25', 'nb27', 'nb28',
                 'nb29', 'nb30', 'nb31', 'nb32', 'nb34', 'nb35', 'nb36', 'nb37', 'nb38', 'nb39')) {
  & $boot "samples\$n.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Ok "负例 $n 正确报错（exit=$LASTEXITCODE）" }
  else { Bad "负例 $n 竟然编译成功" }
}
Pop-Location

# ④b v1.4.31（卡 T-20260918-014653）：**双端口径一致的负例**差分 —— 真 flint 必须同样拒绝
#     nb34 = 指针目标接纯 int 值（T1 ④ 门槛）；nb35 = struct 字段 129（真 flint 上限 128；2026-09-27 由 64 抬到 128）
#     2026-09-20（卡 T-20260920-144154）扩两条多重声明家族的：nb36 = `struct P s, t;`（真 flint 报「期望 ';'」）；
#     nb37 = `struct P *a, *b;`（真 flint 报「期望变量名」）—— 只有 int/char 基础类型才放行后续声明符的 `*`。
#     v1.4.28（B1-3）加 nb38 = 导入模块名写出名 74 字节（真 flint 报「导入模块名过长：写出名最长 63 字节，现在 74 字节」）
#     v1.4.28（B1-5）加 nb39 = 全局标量初值后面还有 token（真 flint 报「全局变量初值只支持一个字面量」；boot 报专码 -213）
#     （只对这几条断言：别的负例里有的本来就该是「boot 比真 flint 严」的双端断点，不能一刀切）
foreach ($n in @('nb34', 'nb35', 'nb36', 'nb37', 'nb38', 'nb39')) {
  & $flint (Join-Path $bootDir "samples\$n.fl") | Out-Null
  if ($LASTEXITCODE -ne 0) { Ok "$n 真 flint 侧同样拒绝（双端口径一致）" }
  else { Bad "$n 真 flint 侧竟然编译通过 —— 口径不一致" }
}

# ⑤ B2i 自举闭环：boot 编译自身源码 → 自产编译器 → 再编译样本 / 再编译自身（第二代）
#    （放在 boot/ 下编译，exe_dir = boot/ 才能找到 lib_print.fl；第二代用 self2.fl 避免覆盖运行中的 exe）
#    v1.0.12（评审清单【7】）：self1.fl / self2.fl 都是 b1_emit.fl 的**同一份副本**（同一源码、两个文件名），
#    真正的"两代"是**产出物**：self1.exe = boot 产出，self2.exe = self1.exe 产出 → 两者应字节相同（不动点）。
Copy-Item (Join-Path $bootDir 'b1_emit.fl') (Join-Path $bootDir 'self1.fl') -Force
Copy-Item (Join-Path $bootDir 'b1_emit.fl') (Join-Path $bootDir 'self2.fl') -Force
Push-Location $bootDir
& $boot "self1.fl" | Out-Null
if ($LASTEXITCODE -ne 0) { Bad "boot 编译自身源码（self1.fl）" }
else {
  Ok 'boot 编译自身源码（self1.exe）'
  & ".\self1.exe" "samples\s1.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "自产编译器编译 s1.fl" }
  else {
    & "samples\s1.exe"
    if ($LASTEXITCODE -eq 42) { Ok '自产编译器产物 s1.exe 退出码 42' }
    else { Bad "自产编译器产物 s1.exe 退出码 $LASTEXITCODE" }
  }
  & ".\self1.exe" "self2.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "自产编译器编译自身（第二代）" }
  else {
    Ok '自产编译器编译自身（self2 第二代）'
    # v1.0.12（评审清单【7】）：补「不动点」断言——原来的判断只看"编译成功"，而最强证据是
    # 两代产物字节完全相同（boot 与 self1.exe 发射结果一致 → 自举已收敛）。原脚本对此零断言。
    $h1 = (Get-FileHash (Join-Path $bootDir 'self1.exe') -Algorithm SHA256).Hash
    $h2 = (Get-FileHash (Join-Path $bootDir 'self2.exe') -Algorithm SHA256).Hash
    if ($h1 -eq $h2) { Ok "自举不动点：self1.exe 与 self2.exe 字节相同（SHA256 $($h1.Substring(0,16))…）" }
    else { Bad "自举不动点破裂：self1.exe=$h1 vs self2.exe=$h2（两代发射结果不一致）" }
  }
}
Pop-Location

# ⑥ B2j 差分对照：同一源文件 boot 与真 flint 各自编译 → 产物退出码必须一致
#    （语义对齐的硬证据：结构体 C 布局 / 指针算术 / 解引用宽度任一处偏差都会露馅）
$diff = @('b2j1', 'b2j2', 'b2j3', 'b2j4', 'b2j5', 'b2j6', 'b2j7', 't_arr2', 't_ptr2', 'st6',
          'b2k1', 'b2k2', 'b2k3', 'b2k4', 'b2k5', 'b2l1', 'b2l2', 'b2l3', 'b2l4', 'b2l5', 'b2l6', 'b2m1',
          'b2n1', 'b2n2', 'b2o1', 'b2p1', 'b2q1', 'b2q2', 'b2r1', 'b2s1', 'b2v1', 'b2x1', 'b2y0', 'b2y1', 'b2y2',
          'b3a1', 'b3a2', 'b3b1',
          'b4a1', 'b4a2', 'b4a3', 'b4a4',
          'b4b1', 'b4b2', 'b4b3', 'rev5b',
          'b5a1', 'b5b1',
          'me1', 'me2', 'me3', 'me4',          # 2026-09-20：多重声明家族（双端产物退出码对照）
          'sarp1',                              # 2026-09-22：局部 struct ＋ 定长数组字段的帧尺寸（卡 T-20260922-201154）
          'b6b2',                               # 2026-09-27：struct 字段上限 64 → 128（128 字段正例，双端同 42）
          'dir1a', 'dir1b', 'dir2', 'dir3',      # 2026-09-21：第一刀（右值直寻址）＋ 第二刀（比较→标志位）＋ 第三刀（内联）哨兵
          'reg1', 'reg2', 'reg3', 'reg4', 'reg5',  # 2026-09-21：第四刀 A1（局部 int 标量进寄存器）哨兵
          'fus1', 'fus2', 'fus3',                             # 2026-09-22：第四刀 A2（就地融合 · 左脊柱）哨兵
          'cmp1',                                             # 2026-09-22：第四刀 A3-①（比较的寄存器感知档）哨兵
          'par1',                                             # 2026-09-22：第四刀 A3-②（形参进池）哨兵
          'cmp2',                                             # 2026-09-22：第三刀第一族（消 xchg · 比较累加器档）哨兵
          'div1',                                             # 2026-09-22：第三刀第二族（消 xchg · 除数进 ecx）哨兵
          'shf1',                                             # 2026-09-22：第三刀第三族（消 xchg · 移位计数直搬）哨兵
          'mem1',                                             # 2026-09-22：第三刀第四族（消 xchg · 右值直接内存操作数）哨兵
          'sib1',                                             # 2026-09-22：第五刀 A1（数组寻址 · SIB 缩放寻址）哨兵
          'acc1',                                             # 2026-09-22：第五刀 B（数组就地更新 · 内存目标运算）哨兵
          'b1c1',                                             # v1.4.28（B1-3）：导入模块名写出名**恰好 63 字节**（上限内侧）⇒ 双端同 42
          'b1c2',                                             # v1.4.28（B1-4）：字符串模块名 ＋ 同文件 print(...) ⇒ 双端同 42
          'acc2')                                             # 2026-09-22：第六刀 A2（融合档吃数组元素右值）哨兵
Push-Location $bootDir
foreach ($k in $diff) {
  Remove-Item "samples\$k.exe" -ErrorAction SilentlyContinue
  & $boot "samples\$k.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "差分 $k：boot 编译失败（exit=$LASTEXITCODE）"; continue }
  & "samples\$k.exe" | Out-Null
  $rb = $LASTEXITCODE
  Remove-Item "samples\$k.exe" -ErrorAction SilentlyContinue
  & $flint "samples\$k.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "差分 $k：真 flint 编译失败（exit=$LASTEXITCODE）"; continue }
  & "samples\$k.exe" | Out-Null
  $rf = $LASTEXITCODE
  Remove-Item "samples\$k.exe" -ErrorAction SilentlyContinue
  if ($rb -eq $rf) { Ok "差分 $k boot=$rb flint=$rf" }
  else { Bad "差分 $k boot=$rb flint=$rf（双端必须一致）" }
}
Pop-Location

# ⑦ B2k：UTF-8 BOM 跳过（真 flint 跳、boot 原报 parse err=-80）——现场生成带 BOM 样本，不进仓库
$bomdir = Join-Path $env:TEMP 'flint-bom'
New-Item -ItemType Directory -Force -Path $bomdir | Out-Null
$bomsrc = Join-Path $bomdir 'bom1.fl'
[IO.File]::WriteAllBytes($bomsrc, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("int main() { return 42; }`n")))
Push-Location $bootDir
& $boot $bomsrc | Out-Null
if ($LASTEXITCODE -ne 0) { Bad "BOM 样本 boot 编译失败（exit=$LASTEXITCODE）" }
else {
  & (Join-Path $bomdir 'bom1.exe') | Out-Null
  if ($LASTEXITCODE -eq 42) { Ok 'BOM 样本（EF BB BF 开头）编译并运行 42' }
  else { Bad "BOM 样本运行 $LASTEXITCODE" }
}
Pop-Location

# ⑫ B2u：带引号 / 含空格路径的实参（Windows 上 PowerShell、cmd 都会给含空格路径加引号；
#    旧 take_arg 按空格硬切 → 实参变成 `"E:\a b\x.fl` 被截断且带引号 → CreateFileA 打不开）
$spdir = Join-Path $env:TEMP 'flint b2u'
New-Item -ItemType Directory -Force -Path $spdir | Out-Null
Copy-Item (Join-Path $samples 's1.fl') (Join-Path $spdir 's1.fl') -Force
Copy-Item $boot (Join-Path $spdir 'b1_emit.exe') -Force
$spboot = Join-Path $spdir 'b1_emit.exe'
& $spboot (Join-Path $spdir 's1.fl') | Out-Null
if ($LASTEXITCODE -ne 0) { Bad "含空格路径 boot 编译失败（exit=$LASTEXITCODE）" }
else {
  & (Join-Path $spdir 's1.exe') | Out-Null
  if ($LASTEXITCODE -eq 42) { Ok 'B2u 含空格+引号路径（exe 与源文件同在 "flint b2u"）编译并运行 42' }
  else { Bad "B2u 含空格路径产物退出码 $LASTEXITCODE" }
}

# ㉑ B4b：print 段按返回类型分派——char 值返回必须打成字符段。
#    退出码比对抓不到这种差异（两端都可能 42），故比对 stdout 原文。
Push-Location $bootDir
Remove-Item "samples\b4b2.exe" -ErrorAction SilentlyContinue
& $boot "samples\b4b2.fl" | Out-Null
if ($LASTEXITCODE -ne 0) { Bad "B4b b4b2 boot 编译失败（exit=$LASTEXITCODE）" }
else {
  $ob = (& "samples\b4b2.exe" 2>&1 | Out-String).Trim()
  $cb = $LASTEXITCODE
  Remove-Item "samples\b4b2.exe" -ErrorAction SilentlyContinue
  & $flint "samples\b4b2.fl" | Out-Null
  if ($LASTEXITCODE -ne 0) { Bad "B4b b4b2 真 flint 编译失败（exit=$LASTEXITCODE）" }
  else {
    $of = (& "samples\b4b2.exe" 2>&1 | Out-String).Trim()
    $cf = $LASTEXITCODE
    Remove-Item "samples\b4b2.exe" -ErrorAction SilentlyContinue
    if ($ob -eq $of -and $ob -eq 'AA' -and $cb -eq 42 -and $cf -eq 42) {
      Ok "B4b print char 段双端一致（stdout='AA'，exit=42）"
    } else {
      Bad "B4b print char 段不一致：boot stdout='$ob' exit=$cb / flint stdout='$of' exit=$cf"
    }
  }
}
Pop-Location

Write-Host "----"
Write-Host "通过 $pass / 失败 $fail"
if ($fail -gt 0) { exit 1 }
exit 0
