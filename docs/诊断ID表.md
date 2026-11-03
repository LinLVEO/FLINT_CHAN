# 诊断 ID 表（机器生成 · 勿手改）

> 生成器：`tools\诊断ID.mjs` ｜ 重生成：`node tools\诊断ID.mjs --gen` ｜ 校验：`node tools\诊断ID.mjs --check`
> 自动 ID **393** 条（SEM 95 ｜ SYN 39 ｜ LIM 82 ｜ GEN 177）｜ 手工码 **11** 处（保持原样，不进本表）｜ 动态文案 **2** 处｜ 三目分支 **4** 处（已逐分支收录）。

ID 的哈希位 = 该条文案字符串的 SHA1 前 4 位（大写十六进制）⇒ **只跟文案走**：新增/删除别的错误，已有 ID 不变。
类别：`SEM` 语义 ｜ `SYN` 语法 ｜ `LIM` 限制 ｜ `GEN` 其他。

| ID | 类 | 文案 | 出现文件 |
|---|---|---|---|
| `[E-GEN-0042]` | GEN | 函数指针数组初值元素比声明长度多（声明 %d 个） | `src/parse.c` |
| `[E-GEN-0098]` | GEN | 全局数组长度必须为正（得到 %lld） | `src/parse.c` |
| `[E-GEN-00E6]` | GEN | 浮点阶段1：double 实参只支持前 4 个（XMM0-3）——第 %d 个 double 参数暂未支持（栈上浮点参数 = 阶段2） | `src/codegen.c` |
| `[E-GEN-03E0]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（for 增量泄漏） | `src/parse.c` |
| `[E-GEN-04D8]` | GEN | switch 里 case/default 之前的语句永远执行不到——编译器不替你猜它属于哪一段（请把它移到某个 case 之后） | `src/parse.c` |
| `[E-GEN-052B]` | GEN | 映射层不变量违规：槽 off=%d 被取过地址却仍被选成寄存器槽（生成层申报漏了 SF_NOREG）—— 取址的槽必须全程在内存，否则别的路径会读到没初始化的内存槽（见 sl_demote 说明） | `src/slotmap.c` |
| `[E-GEN-055A]` | GEN | 二维数组的列数须为数字常量（字面量 / enum 常量 / 常量表达式）——变量、函数调用、运行期量都不行（帧槽在 parse 期就得算死） | `src/parse.c` |
| `[E-GEN-0951]` | GEN | 函数指针签名不一致：右边的函数指针与左边 '%.*s' 声明的 %s 不是同一套签名 | `src/parse.c` |
| `[E-GEN-0A06]` | GEN | print 段之间用 ',' 分隔，段列表以 ']' 结束 | `src/parse.c` |
| `[E-GEN-0A9A]` | GEN | 数组字段长度须为正整数常量（得到 %lld） | `src/parse.c` |
| `[E-GEN-0AEE]` | GEN | struct 按值返回的函数最多 %d 个用户参数（第 1 个整型参数 rcx 被隐藏的返回缓冲指针占用；其余函数仍是 %d 个） | `src/parse.c` |
| `[E-GEN-0D44]` | GEN | case 常量 %d 重复（同一个值写两次，先写的那段永远不会被选中） | `src/parse.c` |
| `[E-GEN-0E24]` | GEN | struct 数组长度须为正数（得到 %lld） | `src/parse.c` |
| `[E-GEN-0EDC]` | GEN | 这个形参是 int——double 实参请写 to_int(值) 显式转换（不静默截断小数），或把形参也改成 double | `src/parse.c` |
| `[E-GEN-0F5A]` | GEN | API '%.*s' 与本地函数重名 | `src/parse.c` |
| `[E-GEN-12A0]` | GEN | 下标对象须为数组或指针 | `src/parse.c` |
| `[E-GEN-146D]` | GEN | 数组字段长度须为正整数常量（字面量 / enum 常量 / 常量表达式）——变量、函数调用、运行期量都不行（布局在 parse 期就得算死） | `src/parse.c` |
| `[E-GEN-180A]` | GEN | 这个地址是 int 变量参与算术/中转算出来的（按 32 位算，高半已截断）——请把地址先放进 int * 变量再做指针算术（例：int *t = s; t + 8） | `src/codegen.c` |
| `[E-GEN-18FD]` | GEN | 字段 '%.*s' 重复 | `src/parse.c` |
| `[E-GEN-1951]` | GEN | 这个 API 参数声明的是 int——double 实参会走 XMM 通道，声明与实参必须一致 | `src/parse.c` |
| `[E-GEN-1C32]` | GEN | 实参函数 '&%s' 的签名与该形参不一致（需要 %s） | `src/parse.c` |
| `[E-GEN-1CF7]` | GEN | 函数指针数组长度须为正数（这里写了 %d） | `src/parse.c` |
| `[E-GEN-1D63]` | GEN | 导入模块名过长：写出名最长 63 字节，现在 %d 字节（%s）——名字会被截断成半个路径、进程启动期才报错，请缩短模块名 | `src/parse.c` |
| `[E-GEN-1E81]` | GEN | api 声明必须放在文件最顶部（任何 struct/函数之前） | `src/parse.c` |
| `[E-GEN-1EF0]` | GEN | 方法糖 'recv.%.*s(...)' 找到的 '%s' 一个形参都没有——方法的首参必须是接收者（struct %s *self） | `src/parse.c` |
| `[E-GEN-2006]` | GEN | main 函数重复定义 | `src/parse.c` |
| `[E-GEN-2334]` | GEN | try 的形态是 `try <变量> = <表达式>;`（try 后必须是变量名） | `src/parse.c` |
| `[E-GEN-286D]` | GEN | share 指针只能由 new 或 share 变量初始化（拷贝需共享所有权） | `src/parse.c` |
| `[E-GEN-287E]` | GEN | \x 后需跟 1-2 位十六进制数字 | `src/tokenize.c` |
| `[E-GEN-28C8]` | GEN | 枚举常量 '%.*s' 与全局变量同名 | `src/parse.c` |
| `[E-GEN-2906]` | GEN | & 需要变量/数组名/字段/函数名（&x &a &p.x &a[i] &f） | `src/parse.c` |
| `[E-GEN-2BBC]` | GEN | 引用形参需要变量实参（如 swap(a, b)） | `src/parse.c` |
| `[E-GEN-2CAA]` | GEN | 数组长度须为数字常量（字面量 / enum 常量 / 常量表达式）——变量、函数调用、运行期量都不行（帧槽在 parse 期就得算死） | `src/parse.c` |
| `[E-GEN-2E88]` | GEN | double 全局变量的初值必须是浮点字面量（如 1.5，而不是 1）——写成整数会被当成整数位型读成 5e-324 | `src/parse.c` |
| `[E-GEN-3083]` | GEN | double 引用只能绑定 double 变量（int 槽只有 4 字节 → 按 double 读 8 字节会读到别的位型） | `src/parse.c` |
| `[E-GEN-3256]` | GEN | 函数指针数组 '%s' 的常量下标 %d 越界（合法下标 0..%d） | `src/parse.c` |
| `[E-GEN-335D]` | GEN | 参数需以 'int'/'int_64'/'char'/'double'/'struct' 开头 | `src/parse.c` |
| `[E-GEN-347C]` | GEN | %s | `src/codegen.c` |
| `[E-GEN-36D2]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（switch 条件里泄漏） | `src/parse.c` |
| `[E-GEN-37CF]` | GEN | 0x 后需跟十六进制数字 | `src/tokenize.c` |
| `[E-GEN-3A6F]` | GEN | 地址值是 64 位，装不进 4 字节的 int/uint_32 / 1 字节的 char/uint_8 目标（数组元素、结构体字段、解引用都只有这么宽）——请把目标声明成 int *（或先存进一个 int * 变量再整体赋值） | `src/codegen.c` |
| `[E-GEN-3AFC]` | GEN | 内部 rsp 状态异常（多参调用入口 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen | `src/codegen.c` |
| `[E-GEN-3C8E]` | GEN | 函数指针数组的元素签名不一致：右边这个函数指针与数组元素声明的 %s 不是同一套签名 | `src/parse.c` |
| `[E-GEN-3D81]` | GEN | 内存不足（全局变量表） | `src/parse.c` |
| `[E-GEN-3E61]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（此处丢弃会泄漏） | `src/parse.c` |
| `[E-GEN-3E7F]` | GEN | 全局变量 '%.*s' 与同名函数冲突（读变量和调函数会分不清） | `src/parse.c` |
| `[E-GEN-415B]` | GEN | 内部错误：函数地址下标越界（%d） | `src/parse.c` |
| `[E-GEN-46F8]` | GEN | try 的目标变量必须是 32 位整数（int / int_32 / char / uint_8 / uint_32；错误码是 int，不接受 %s —— 64 位值 return 给 int 函数会静默截断） | `src/parse.c` |
| `[E-GEN-49A2]` | GEN | struct 数组长度须为数字常量（与 int a[N] 同口径；字面量 / enum 常量 / 常量表达式）——变量、函数调用都不行 | `src/parse.c` |
| `[E-GEN-4A60]` | GEN | continue 只能用在循环里（while / for 内；编译器不会替你猜跳哪里） | `src/parse.c` |
| `[E-GEN-4ADE]` | GEN | 接收者是**表达式结果**而不是变量：'.' 形式的方法调用点糖要取接收者的地址（糖摊平后首参 = &recv），对 f()/(a+b) 这类临时量取地址是错的——指针接收者请写 recv->%.*s(...)（f()->g(...) 合法；f().g(...) 是编译期错误） | `src/parse.c` |
| `[E-GEN-4C6F]` | GEN | continue 在 switch 里没有意义（switch 不是循环——它跳的是外层循环，这里没有外层循环； | `src/parse.c` |
| `[E-GEN-4CFF]` | GEN | 实参 '&%s' 的签名与形参不一致（需要 %s） | `src/parse.c` |
| `[E-GEN-4D7E]` | GEN | 内部错误：SIB 步长只支持 1/2/4/8（收到 %d） | `src/slotmap.c` |
| `[E-GEN-4DBA]` | GEN | 赋值左边必须是变量或 *p/a[i] | `src/parse.c` |
| `[E-GEN-4E0E]` | GEN | '.' 左侧须为结构体变量 | `src/parse.c` |
| `[E-GEN-511D]` | GEN | 数组长度常量表达式的位移位数须在 0..63（得到 %lld） | `src/parse.c` |
| `[E-GEN-5313]` | GEN | 函数指针声明要写成「(*名字)(参数表)」：int (*fp)(int) | `src/parse.c` |
| `[E-GEN-5329]` | GEN | include 循环引用: %s | `src/main.c` |
| `[E-GEN-53AF]` | GEN | share 指针必须初始化（int *share p = new int; 或 = share 变量） | `src/parse.c` |
| `[E-GEN-53D3]` | GEN | 参数需为变量名 | `src/parse.c` |
| `[E-GEN-5574]` | GEN | 内部 rsp 对齐违规（%s 前 rsp≡%d，应 ≡0）——压栈未配对或帧未 16 对齐，改 codegen | `src/codegen.c` |
| `[E-GEN-5603]` | GEN | 引用只能绑定变量（int &r = x; / double &r = d;） | `src/parse.c` |
| `[E-GEN-5815]` | GEN | 二维数组 '%s' 需要两个下标（m[行][列]）——只写一维会静默读到别的行 | `src/parse.c` |
| `[E-GEN-595D]` | GEN | own 指针只能由 new 初始化（独占所有权，禁止拷贝） | `src/parse.c` |
| `[E-GEN-5992]` | GEN | 映射层不变量违规：寄存器槽 off=%d 在函数体发射中途被要求降级回内存（跨路径不可能一致 ⇒ 会静默错值）。修法：取址类把它静态钉死（SF_ADDRESSED），形态类给对应访问器补寄存器路径 —— 别恢复「先 flush 再降级」的老做法 | `src/slotmap.c` |
| `[E-GEN-5A3F]` | GEN | enum '%.*s' 里至少要有一个常量 | `src/parse.c` |
| `[E-GEN-5BCC]` | GEN | 实参个数超过函数 '%s' 的形参个数（%d 个） | `src/parse.c` |
| `[E-GEN-5D09]` | GEN | 内部错误：print 需要内置输出函数 %s（编译器注入缺失） | `src/parse.c` |
| `[E-GEN-5E34]` | GEN | API '%.*s' 重复声明但签名不一致（已声明 %d 参 %s） | `src/parse.c` |
| `[E-GEN-5F07]` | GEN | 未知转义 '\%c' | `src/tokenize.c` |
| `[E-GEN-5FCF]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（条件里泄漏） | `src/parse.c` |
| `[E-GEN-5FDA]` | GEN | 意外的关键字 '%.*s' | `src/parse.c` |
| `[E-GEN-61DB]` | GEN | 函数参数最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参，v1.4.26） | `src/parse.c` |
| `[E-GEN-6332]` | GEN | 实参的函数指针签名与该形参不一致（形参需要 %s）——右边这个函数指针是另一套签名 | `src/parse.c` |
| `[E-GEN-63F6]` | GEN | 二维数组的列数须为正数（得到 %lld） | `src/parse.c` |
| `[E-GEN-6B5E]` | GEN | 这个形参收的是函数指针——请传「&函数名」或函数指针变量 | `src/parse.c` |
| `[E-GEN-6D26]` | GEN | own 指针必须由 new 初始化（int *own p = new int;） | `src/parse.c` |
| `[E-GEN-7379]` | GEN | 函数指针声明需要变量名：int (*fp)(int) | `src/parse.c` |
| `[E-GEN-7541]` | GEN | 内部错误：print 换行需要内置输出函数 _flint_out_str | `src/parse.c` |
| `[E-GEN-7980]` | GEN | 函数指针只能接「&函数名」或另一个函数指针（整数/普通指针/函数调用结果都接不了——C 里裸函数名会退化，FLINT 要求显式写 &） | `src/parse.c` |
| `[E-GEN-79CD]` | GEN | 函数指针数组的元素签名不一致：'%s' 与数组元素声明的 %s 不是同一套签名 | `src/parse.c` |
| `[E-GEN-7A54]` | GEN | 数组长度须为正数（得到 %lld） | `src/parse.c` |
| `[E-GEN-7BA3]` | GEN | case/default 标签后应为 ':'——case 只能跟一个**整型常量**（case 1 + 1: / case n: 这类都不行，编译期要按常量发比较指令） | `src/parse.c` |
| `[E-GEN-7CA0]` | GEN | 实参最多 %d 个（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参；v1.4.26 由 4 抬到 %d） | `src/parse.c` |
| `[E-GEN-7CF3]` | GEN | break 只能用在循环（while / for）或 switch 里（编译器不会替你猜跳哪里） | `src/parse.c` |
| `[E-GEN-7D1E]` | GEN | 函数 '%.*s' 与同名全局变量冲突（读变量和调函数会分不清） | `src/parse.c` |
| `[E-GEN-7D56]` | GEN | 方法糖 'recv.%.*s(...)' 找到的 '%s' 首参不是接收者指针/引用（收的是值形参）——糖摊平后要传的是接收者地址，首参请写 struct %s *self | `src/parse.c` |
| `[E-GEN-7FA6]` | GEN | 安全模式（-safe）：三元分支里的 new 必须由 own/share 接管（此处丢弃会泄漏） | `src/parse.c` |
| `[E-GEN-85D9]` | GEN | 函数 '%.*s' 重复定义 | `src/parse.c` |
| `[E-GEN-85FC]` | GEN | 这个形参是 int——double 实参请写 to_int(值) 显式转换（不静默截断小数） | `src/parse.c` |
| `[E-GEN-86C9]` | GEN | 内部错误：函数指针数组的间接调用出现在函数体外 | `src/parse.c` |
| `[E-GEN-870A]` | GEN | 要跳出 switch 用 break） | `src/parse.c` |
| `[E-GEN-8713]` | GEN | 函数指针签名不一致：'%s' 与左侧声明的 %s 不是同一套签名 | `src/parse.c` |
| `[E-GEN-87A8]` | GEN | 结构体参数要写成指针（struct S *p） | `src/parse.c` |
| `[E-GEN-8902]` | GEN | 内部错误：str 需要内置缓冲函数 %s（编译器注入缺失） | `src/parse.c` |
| `[E-GEN-8BAE]` | GEN | struct 数组字段长度须为正整数常量（字面量 / enum 常量 / 常量表达式）——变量、函数调用、运行期量都不行（布局在 parse 期就得算死） | `src/parse.c` |
| `[E-GEN-8CF7]` | GEN | ++ 需要可修改的变量或 *p（左值） | `src/parse.c` |
| `[E-GEN-8D2C]` | GEN | 内部错误：函数指针声明符应以 '(' 开头 | `src/parse.c` |
| `[E-GEN-8F28]` | GEN | 实参个数超过这个函数指针的形参个数（%d 个） | `src/parse.c` |
| `[E-GEN-910B]` | GEN | 全局变量 '%.*s' 不可调用 | `src/parse.c` |
| `[E-GEN-928C]` | GEN | 'own'/'share' 只能修饰 int*（%s 无堆所有权语义） | `src/parse.c` |
| `[E-GEN-9569]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（for 初始化泄漏） | `src/parse.c` |
| `[E-GEN-9633]` | GEN | 内存不足：枚举常量表扩容失败 | `src/parse.c` |
| `[E-GEN-9820]` | GEN | str([...]) 不接受 print 的第二参（换行标志 0\|1）——要换行请用 print([...], 1)；str 的产物是 char*，本身没有'换行'这回事 | `src/parse.c` |
| `[E-GEN-99D3]` | GEN | 函数指针数组初值需要正好 %d 个元素（这里给了 %d 个）——不补零、不省略长度 | `src/parse.c` |
| `[E-GEN-9FA1]` | GEN | 下标需要数组名或指针变量 | `src/parse.c` |
| `[E-GEN-A04C]` | GEN | 内部错误：未知的 callee-saved 寄存器号 %d | `src/codegen.c` |
| `[E-GEN-A211]` | GEN | 方法名过长（%d 字节） | `src/parse.c` |
| `[E-GEN-A253]` | GEN | 变量 '%.*s' 不可调用（它不是函数指针；函数指针用 int (*fp)(int) 声明） | `src/parse.c` |
| `[E-GEN-A314]` | GEN | 全局数组初值元素比声明长度多（声明 %d 个） | `src/parse.c` |
| `[E-GEN-A4F0]` | GEN | 二维数组暂只支持 int（%s 不做——char/double 的整块布局还没定） | `src/parse.c` |
| `[E-GEN-A6F8]` | GEN | struct 数组字段长度须为正整数常量（得到 %lld） | `src/parse.c` |
| `[E-GEN-A752]` | GEN | 空初始化列表 {} 不接受——C 的 {0} 才表示「全字段清零」，请写 {0} | `src/parse.c` |
| `[E-GEN-A766]` | GEN | 内部错误：找不到函数指针数组 '%s' 的声明信息 | `src/parse.c` |
| `[E-GEN-AC36]` | GEN | 字符字面量只能含一个字符 | `src/tokenize.c` |
| `[E-GEN-ACCA]` | GEN | 内存不足（函数指针签名表） | `src/parse.c` |
| `[E-GEN-AEAC]` | GEN | try 只能用在返回 int 的函数里（本函数返回 %s；错误码约定是 int） | `src/parse.c` |
| `[E-GEN-AFD2]` | GEN | str 段之间用 ',' 分隔，段列表以 ']' 结束 | `src/parse.c` |
| `[E-GEN-B123]` | GEN | 'own'/'share' 只能修饰指针（int *own/share p = new int;） | `src/parse.c` |
| `[E-GEN-B224]` | GEN | 内部错误：'new' 需要内置 VirtualAlloc 登记 | `src/parse.c` |
| `[E-GEN-B37C]` | GEN | 结构体 %s 无字段 '%.*s' | `src/parse.c` |
| `[E-GEN-B3C2]` | GEN | 数组初值元素比声明长度多（声明 %d 个） | `src/parse.c` |
| `[E-GEN-B41F]` | GEN | 内部错误：str 需要内置缓冲函数 _flint_str_begin（编译器注入缺失） | `src/parse.c` |
| `[E-GEN-B5D2]` | GEN | return 的调用结果不是**按值返回 struct** 的函数（只有 struct S f() 形态能把返回值直接转交给调用者的缓冲） | `src/parse.c` |
| `[E-GEN-B6DC]` | GEN | 函数 '%.*s' 需带括号调用 | `src/parse.c` |
| `[E-GEN-B8BB]` | GEN | 实参函数指针的签名与形参不一致（形参需要 %s）——右边这个函数指针是另一套签名 | `src/parse.c` |
| `[E-GEN-BA65]` | GEN | '%.*s' 是结构体 %s 的**字段**，不是方法——FLINT 用括号区分：不带括号 recv.%.*s 读字段，带括号 recv.%.*s(...) 才是方法糖（糖摊平后要找的自由函数是 '%s_%.*s'）；字段不可调用 | `src/parse.c` |
| `[E-GEN-BDCB]` | GEN | 全局变量 '%.*s' 重复声明 | `src/parse.c` |
| `[E-GEN-BE4B]` | GEN | void 只能单独写成「无参」：(void) | `src/parse.c` |
| `[E-GEN-BEAB]` | GEN | 变量 '%.*s' 重复声明 | `src/parse.c` |
| `[E-GEN-BFD7]` | GEN | include 文件不存在: %s | `src/main.c` |
| `[E-GEN-C034]` | GEN | 声明后需跟变量名 | `src/parse.c` |
| `[E-GEN-C089]` | GEN | 全局变量初值只支持一个字面量（可带正负号）——这里多出来的 token 会被丢弃、初值就是错的（表达式不会被求值）；要算表达式请挪进 main 里赋值（全局只写 int g; 再在 main 里 g = 0 - 1;） | `src/parse.c` |
| `[E-GEN-C1BE]` | GEN | 内部错误：函数解析数与预扫描不一致 | `src/parse.c` |
| `[E-GEN-C43C]` | GEN | 枚举常量 '%.*s' 与函数同名 | `src/parse.c` |
| `[E-GEN-C4EE]` | GEN | api 后需跟模块名（裸短名如 user32，或字符串字面量如 "cabridge.dll"） | `src/parse.c` |
| `[E-GEN-C56A]` | GEN | case 标签必须是整型常量（case 3: / case -1: / case 'a': / case 枚举常量:）——变量、函数调用、case 1 + 1 这类表达式都不行（switch 要在编译期排跳转表） | `src/parse.c` |
| `[E-GEN-C8CF]` | GEN | 'new' 暂支持 'new int'（结构体/数组 new 后续版本） | `src/parse.c` |
| `[E-GEN-CF34]` | GEN | 全局数组长度必须是正整数常量（字面量 / enum 常量 / 常量表达式）——全局数组在 .data 里，长度编译期就得定；变量、函数调用都不行 | `src/parse.c` |
| `[E-GEN-CF43]` | GEN | '.' 左侧是指向结构体的指针：**字段**访问请写 '->'（p->x）；只有方法调用点 p.%.*s(...) 才允许用 '.' | `src/parse.c` |
| `[E-GEN-CF71]` | GEN | 内部错误：double 复合赋值只支持 += -= *= /=（parse 应已拦下） | `src/codegen.c` |
| `[E-GEN-CFBE]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（裸指针持有会泄漏） | `src/parse.c` |
| `[E-GEN-D0C1]` | GEN | as 后需跟 DLL 里的真实函数名字符串（as "_printf"） | `src/parse.c` |
| `[E-GEN-D432]` | GEN | main 函数不需要参数 | `src/parse.c` |
| `[E-GEN-D518]` | GEN | 'return;' 只能用在 void 函数 | `src/parse.c` |
| `[E-GEN-D55C]` | GEN | hlc: 无法打开文件 %s | `src/main.c` |
| `[E-GEN-D59B]` | GEN | 内部 rsp 状态异常（API 调用入口 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen | `src/codegen.c` |
| `[E-GEN-D638]` | GEN | 实参个数超过 API 声明（%d 个） | `src/parse.c` |
| `[E-GEN-D743]` | GEN | 引用必须初始化（int &r = x;） | `src/parse.c` |
| `[E-GEN-DC26]` | GEN | 函数指针签名不一致：右侧的函数指针与左侧声明的 %s 不是同一套签名 | `src/parse.c` |
| `[E-GEN-DC3A]` | GEN | 无法识别的字符 '%c' (0x%02x) | `src/tokenize.c` |
| `[E-GEN-DCA5]` | GEN | enum 常量赋值只认整数字面量或已登记的枚举常量 | `src/parse.c` |
| `[E-GEN-E054]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（return 直接泄漏） | `src/parse.c` |
| `[E-GEN-E123]` | GEN | include 嵌套超过 32 层（疑似循环 include） | `src/main.c` |
| `[E-GEN-E24C]` | GEN | str([...]) 只能赋给 char*/int* 指针变量（'%.*s' 不是指针）——它只在 ① 指针变量声明初始化 ② 赋值语句右值 ③ 指针返回函数的 return 值 可用 | `src/parse.c` |
| `[E-GEN-E263]` | GEN | 方法糖 'recv.%.*s(...)' 找到的 '%s' 首参是引用形参（struct %s &self）——引用形参只适用于结构体**值**接收者（m.f(...)）；指针接收者请把首参写成 struct %s *self | `src/parse.c` |
| `[E-GEN-E2DF]` | GEN | to_int32(...) 只用于 64 位整数（int_64/uint_64）→ int 的显式收窄（实参已经是 32 位：不必转） | `src/parse.c` |
| `[E-GEN-E350]` | GEN | 函数 '%s' 需要 %d 个实参，这里只给了 %d 个（FLINT 没有默认实参） | `src/parse.c` |
| `[E-GEN-E702]` | GEN | 内部错误：槽 %d 不是寄存器槽（融合路径只能用在寄存器槽上） | `src/slotmap.c` |
| `[E-GEN-E772]` | GEN | 函数 '%s' 的第 %d 个形参收的是函数指针——请传「&函数名」或函数指针变量 | `src/parse.c` |
| `[E-GEN-E78E]` | GEN | 安全模式（-safe）：new 结果必须由 own/share 接管（for 条件泄漏） | `src/parse.c` |
| `[E-GEN-E999]` | GEN | -- 需要可修改的变量或 *p（左值） | `src/parse.c` |
| `[E-GEN-EA6F]` | GEN | '->' 左侧须为指向结构体的指针 | `src/parse.c` |
| `[E-GEN-EB72]` | GEN | 内部 rsp 状态异常（FLINT 函数调用点 rsp≡%d，应 0 或 8）——压栈未配对，改 codegen | `src/codegen.c` |
| `[E-GEN-EC02]` | GEN | 枚举常量 '%.*s' 重复声明 | `src/parse.c` |
| `[E-GEN-EE16]` | GEN | API 参数最多 %d 个（4 寄存器 + %d 栈参，v1.4.0 由 12 提到 16：CreateFontA 14 参） | `src/parse.c` |
| `[E-GEN-EF39]` | GEN | switch 里只能有一个 default | `src/parse.c` |
| `[E-GEN-EF3B]` | GEN | print 换行参数须为 0/1 常量（1 = 换行）；省略 = 不换行 | `src/parse.c` |
| `[E-GEN-F08E]` | GEN | main 必须返回 int（退出码 = main 返回值） | `src/parse.c` |
| `[E-GEN-F580]` | GEN | API '%.*s' 需带括号调用 | `src/parse.c` |
| `[E-GEN-F71D]` | GEN | 这个函数指针需要 %d 个实参，这里只给了 %d 个 | `src/parse.c` |
| `[E-GEN-F7F4]` | GEN | 安全模式（-safe）：print 段内 new 会泄漏（先由 own/share 接管再打印） | `src/parse.c` |
| `[E-GEN-FB10]` | GEN | 块注释未闭合 | `src/tokenize.c` |
| `[E-GEN-FC4C]` | GEN | double 只支持 += -= *= /=（%%= 与位运算/移位是整数运算，请写 d = d * 2.0 这类形式） | `src/parse.c` |
| `[E-GEN-FD3C]` | GEN | str_into(dst, [...]) 的 dst 必须是本函数里声明的数组（char buf[N];）—— dst 是指针或表达式时请用三参数形态 str_into(dst, cap, [...]) | `src/parse.c` |
| `[E-GEN-FE09]` | GEN | 安全模式（-safe）：str 段内 new 会泄漏（先由 own/share 接管再拼） | `src/parse.c` |
| `[E-LIM-00C1]` | LIM | 这个形参是 %s——double 实参不支持（两者互转只走显式转型），请先 (int)值 再 (…) | `src/parse.c` |
| `[E-LIM-01AB]` | LIM | 结构体整体初始化只支持 {0}（全字段清零）——{v0, v1, ...} 这种通用初始化列表暂不支持，请声明后逐字段赋值 | `src/parse.c` |
| `[E-LIM-0901]` | LIM | struct 按值返回调用出现在不支持的位置（见上一条） | `src/parse.c` |
| `[E-LIM-0A5B]` | LIM | 指针数组的下标只支持局部数组变量形态 names[i]（v2.12 边界：全局/结构体字段/表达式结果下标暂不支持） | `src/parse.c` |
| `[E-LIM-0B6B]` | LIM | double 的 ++/-- 暂不支持（请写 d += 1.0 或 d = d + 1.0） | `src/parse.c` |
| `[E-LIM-0B93]` | LIM | 三维数组暂不支持（只开二维 int m[行][列]） | `src/parse.c` |
| `[E-LIM-0F7D]` | LIM | 这个形参是 %s——double 实参不支持（两者互转只走显式转型） | `src/parse.c` |
| `[E-LIM-1C20]` | LIM | struct 不支持复合赋值（结构体只支持整体拷贝 b = a; 与 {0} 零初始化） | `src/parse.c` |
| `[E-LIM-1C67]` | LIM | 函数指针的参数不支持引用（int&）——请写成指针 | `src/parse.c` |
| `[E-LIM-1DAD]` | LIM | struct 数组字段只支持一维（`struct E es[N]`）——二维 `struct E es[2][3]` 暂不支持；要二维请声明成一维 `es[2*3]` 自己算下标 | `src/parse.c` |
| `[E-LIM-1EB5]` | LIM | str([...]) 的段全是字面量、总长 %d 字节 > 缓冲上限 %d 字节 —— 编译期直接拦下（运行期超限同样是响亮失败：str() 返回 0，绝不静默截断） | `src/parse.c` |
| `[E-LIM-2143]` | LIM | 全局变量过大（%lld 字节）——.data 单节上限 %d 字节 | `src/parse.c` |
| `[E-LIM-22D6]` | LIM | 指针全局不支持数组形式（`int *g[4]` 是「4 个指针」——数组元素是指针的全局还没开） | `src/parse.c` |
| `[E-LIM-2A8B]` | LIM | 函数指针的参数不支持数组，请用指针 | `src/parse.c` |
| `[E-LIM-2D4A]` | LIM | 浮点字面量超出 double 范围 | `src/tokenize.c` |
| `[E-LIM-3D62]` | LIM | 十进制整数字面量超出 64 位有符号范围（INT64_MAX = 9223372036854775807；写 INT64_MIN 请写 -9223372036854775807 - 1） | `src/tokenize.c` |
| `[E-LIM-441F]` | LIM | 这个全局变量是 %s，初值却是 64 位字面量（会静默截断高 32 位：值超出范围的部分丢掉）——请把全局变量声明成 int_64 / uint_64 | `src/parse.c` |
| `[E-LIM-460F]` | LIM | 'new %s' 暂不支持（v1.7.0 P0 边界）——堆上要 64 位可以 new int（负载 8 字节）再用 %s * 承接 | `src/parse.c` |
| `[E-LIM-51D8]` | LIM | 函数指针数组的下标只支持局部数组变量形态 ops[i]（v2.6.0 边界：全局/表达式结果下标暂不支持） | `src/parse.c` |
| `[E-LIM-555A]` | LIM | 结构体数组总长过大（帧槽累计超 2GB 上限） | `src/parse.c` |
| `[E-LIM-57A1]` | LIM | %s 引用形参暂不支持（引用读是 32 位解引用，会静默截断）——请用 %s *p 显式指针 | `src/parse.c` |
| `[E-LIM-5D9A]` | LIM | struct 数组只支持一维下标（二维 `es[i][j]` 暂不支持）——要二维请写一维 `es[i*cols + j]` 自己算 | `src/parse.c` |
| `[E-LIM-67EB]` | LIM | 全局变量初值过长（%d 字节，上限 %d） | `src/parse.c` |
| `[E-LIM-6982]` | LIM | struct 指针字段暂不支持数组形态（v2.3 边界） | `src/parse.c` |
| `[E-LIM-6A6F]` | LIM | 数组字段长度过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-6EB1]` | LIM | 三元的函数指针分支暂不支持（v1.3.2 边界：签名会被丢掉）——请用 if/else 给函数指针变量赋值 | `src/parse.c` |
| `[E-LIM-6EC9]` | LIM | ~ 不支持 double（位运算只对整数） | `src/parse.c` |
| `[E-LIM-705E]` | LIM | 全局数组长度过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-7227]` | LIM | 数组暂不支持整体初始化（只开了局部 int 数组；%s 数组的整块布局未定） | `src/parse.c` |
| `[E-LIM-72F1]` | LIM | 嵌套过深（上限 %d 层）：括号或语句块套得太深，请拆成变量/函数 | `src/parse.c` |
| `[E-LIM-742C]` | LIM | 不支持 (void) 转型：FLINT 没有 void 值（要丢弃结果就写成表达式语句） | `src/parse.c` |
| `[E-LIM-7488]` | LIM | 十六进制字面量超出 64 位范围（最多 16 位十六进制数字） | `src/tokenize.c` |
| `[E-LIM-76EF]` | LIM | 指针字段暂不支持 ++/--/复合赋值（v0.9.2 边界；用 s.f = s.f ± n 整体赋值） | `src/parse.c` |
| `[E-LIM-77BA]` | LIM | 数组 new 暂不支持（v0.9 单对象 new int） | `src/parse.c` |
| `[E-LIM-7A77]` | LIM | %s 引用暂不支持（引用读是 32 位解引用，会静默截断）——请用 %s *p = &x; 显式指针 | `src/parse.c` |
| `[E-LIM-7BBF]` | LIM | 指针转型结果暂不支持直接打印（仅 char* 串可用） | `src/parse.c` |
| `[E-LIM-7DCE]` | LIM | 全局变量总量超出 .data 单节上限（%d 字节）——第一版不开放多节 .data | `src/parse.c` |
| `[E-LIM-8394]` | LIM | switch 的 case 分支上限 64（v1.3.1 边界） | `src/parse.c` |
| `[E-LIM-83C4]` | LIM | 结构体整体初始化只支持**恰好一个 0** 的 {0}——通用初始化列表暂不支持，请声明后逐字段赋值 | `src/parse.c` |
| `[E-LIM-8474]` | LIM | 函数指针数组的长度须为数字常量（不支持省略长度 `(*ops[])`，也不是变量/表达式） | `src/parse.c` |
| `[E-LIM-90D2]` | LIM | 函数指针的签名里暂不支持 %s（v1.7.0 P0 边界：FuncSig.param_ty 还没有这一档）——请改成 int 形参，或先用普通函数接住 | `src/parse.c` |
| `[E-LIM-93F5]` | LIM | 该指针返回暂不支持直接打印（仅 char* 串可用） | `src/parse.c` |
| `[E-LIM-9A22]` | LIM | struct 数组字段长度过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-9B92]` | LIM | 不支持 (%s)double：v1 的 double 截断只有 (int) / (int_64) / (uint_32) / (uint_64)（越界 = 0x80000000，同 C）。请写 (%s)(int)值，把两步写清 | `src/parse.c` |
| `[E-LIM-9BA2]` | LIM | 结构体暂不支持函数指针字段（v1.3.2 边界）——回调请存成局部函数指针变量，或把一个整数/地址字段 + 间接调用拆开写 | `src/parse.c` |
| `[E-LIM-9CEC]` | LIM | 该指针暂不支持直接打印（仅 char* 串可用；int*/struct* = 已知边界） | `src/parse.c` |
| `[E-LIM-A112]` | LIM | %s 引用形参暂不支持（v1.0.5：用 %s* 指针） | `src/parse.c` |
| `[E-LIM-A845]` | LIM | 暂不支持全局函数指针（v1.3.2 边界：只开局部函数指针变量）——请在函数里声明 int (*fp)(int)，或用函数名直接调用 | `src/parse.c` |
| `[E-LIM-AC9C]` | LIM | 地址值（&x）暂不支持直接打印（64 位，起步边界） | `src/parse.c` |
| `[E-LIM-B121]` | LIM | to_int64(...) 不支持 double（两者互转只走显式转型） | `src/parse.c` |
| `[E-LIM-BB1F]` | LIM | 这个运算符不支持 double（位运算/移位/取模只对整数） | `src/parse.c` |
| `[E-LIM-BB4F]` | LIM | 指针字段/指针解引用结果暂不支持直接打印 | `src/parse.c` |
| `[E-LIM-BCEF]` | LIM | 指针数组暂不支持二维（v2.12 边界：只开一维 char *a[N] / int *a[N]） | `src/parse.c` |
| `[E-LIM-C340]` | LIM | 数组形参暂不支持，请用指针（int *p / char *p / double *p） | `src/parse.c` |
| `[E-LIM-C35D]` | LIM | %s 引用暂不支持（可用 %s* 指针或 &c 取址） | `src/parse.c` |
| `[E-LIM-C576]` | LIM | struct 全局变量暂不支持整体初始化（`struct E g = {...}`）——全局 struct 只有 .bss 语义（全零）；要初值请在 main 里逐字段赋值，或用局部 struct 造好后整体拷贝 g = 局部值 | `src/parse.c` |
| `[E-LIM-C5FE]` | LIM | 结构体按值传参暂不支持，用指针/引用（struct S *p 或 struct S &r） | `src/parse.c` |
| `[E-LIM-C8D5]` | LIM | switch 的条件暂不支持 64 位整数（int_64/uint_64；v1.7.0 P0 边界：跳转表是 32 位比较）——请先显式收窄，或改写成 if/else 链 | `src/parse.c` |
| `[E-LIM-CADF]` | LIM | 函数指针数组作函数形参暂不支持（v2.6.0 边界）——请传单个函数指针，或在函数内声明数组后逐个赋值 | `src/parse.c` |
| `[E-LIM-CEDA]` | LIM | 数组长度过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-D032]` | LIM | switch 的条件不支持 double（相等比较要按位型，浮点不行）——请用整数，或先 to_int(值)（注意那是截断取整） | `src/parse.c` |
| `[E-LIM-D1EA]` | LIM | 指针全局暂不支持初值——请在函数里赋值（例如 g = 0; 或 g = new ...），避免把 4 字节常量写进 8 字节指针槽 | `src/parse.c` |
| `[E-LIM-D284]` | LIM | 函数指针的参数上限 %d 个（前 4 个走 rcx/rdx/r8/r9，第 5 个起走栈参，v1.4.26） | `src/parse.c` |
| `[E-LIM-D6A3]` | LIM | 函数指针数组暂只支持函数顶层作用域声明（块/循环内 = v2.6.0 边界） | `src/parse.c` |
| `[E-LIM-D781]` | LIM | 结构体字段上限 128 | `src/parse.c` |
| `[E-LIM-DA35]` | LIM | own/share 指针暂只支持函数顶层作用域声明（块/循环内 = 已知边界 v0.9） | `src/parse.c` |
| `[E-LIM-DEBD]` | LIM | struct 数组长度过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-DF71]` | LIM | 二维数组总长过大（行×列 = %lld）——帧槽累计超 2GB 上限 | `src/parse.c` |
| `[E-LIM-E34A]` | LIM | 这个形参是 %s——%s 实参会被静默截断高 32 位（超出范围的部分丢掉），请显式转型（或把形参声明成 %s） | `src/parse.c` |
| `[E-LIM-E38F]` | LIM | ^^ 暂不支持 64 位整数（int_64/uint_64；快速幂是 32 位累加器，会静默截断高 32 位）——请改成连乘/循环，或先显式收窄 | `src/parse.c` |
| `[E-LIM-E52F]` | LIM | 函数指针暂只支持函数顶层作用域声明（块/循环内 = v1.3.2 边界） | `src/parse.c` |
| `[E-LIM-E7C0]` | LIM | 二维数组的列数过大（%lld；上限 2147483647） | `src/parse.c` |
| `[E-LIM-EEF8]` | LIM | 不支持数组转型：数组没有整体值语义 —— 要字节视图请用 char* | `src/parse.c` |
| `[E-LIM-F040]` | LIM | ^^ 暂不支持 double（阶段1：幂只有整数版）——请写 d = d * d * d 或等阶段2 的浮点幂 | `src/parse.c` |
| `[E-LIM-F0AB]` | LIM | struct 数组暂不支持整体初始化（逐元素 a[i].字段 = 值） | `src/parse.c` |
| `[E-LIM-F546]` | LIM | '%.*s' 不是结构体 %s 的字段，但存在自由函数 '%s'——方法调用点糖**必须带括号**：写 recv.%.*s(实参)（糖摊平后要找的是 '%s_%.*s'；不带括号当值用不支持） | `src/parse.c` |
| `[E-LIM-F6EA]` | LIM | int_64 的复合赋值只能出现在函数体内（v1.7.0 P2 边界） | `src/parse.c` |
| `[E-LIM-FA63]` | LIM | 多维函数指针数组暂不支持（v2.6.0 边界：只开一维 `(*ops[N])(...)`） | `src/parse.c` |
| `[E-LIM-FB4B]` | LIM | struct 指针全局暂不支持初值——请在函数里赋值（例如 gp = &g; 或 gp = 0;） | `src/parse.c` |
| `[E-LIM-FD73]` | LIM | 变量/数组/结构体总长过大（帧槽累计超 2GB 上限） | `src/parse.c` |
| `[E-LIM-FDB8]` | LIM | ! 不支持 double（先比较：d != 0.0） | `src/parse.c` |
| `[E-LIM-FED0]` | LIM | 全局二维数组暂不支持（只开局部 int m[行][列]；全局要二维请用一维 g[行*列] 自己算下标） | `src/parse.c` |
| `[E-SEM-0058]` | SEM | own/share 指针不能拷贝给裸指针（请用 int *own/share q = p; 声明接管） | `src/parse.c` |
| `[E-SEM-0059]` | SEM | struct 整体赋值右边必须是**同一个 struct 类型**的值（这里给的是 %s）——结构体没有整体值语义，只有同类型逐字节拷贝 | `src/parse.c` |
| `[E-SEM-0449]` | SEM | 结构体不能把自身作为值字段（`struct %s { struct %s ... }` 尺寸无穷）——数组形态 `struct %s a[N]` 同样不行；自引用请写指针形态 `struct %s *next;` | `src/parse.c` |
| `[E-SEM-092E]` | SEM | 这里不能下标（struct 数组下标只支持局部变量形态 a[i]，二维 a[i][j] 与表达式结果下标都不支持） | `src/parse.c` |
| `[E-SEM-09EC]` | SEM | 不能把 %s 值 return 给 %s 返回函数（会静默截断高 32 位：值超出范围的部分丢掉）——请显式转型，或把返回类型改成 %s | `src/parse.c` |
| `[E-SEM-0F13]` | SEM | 转型写法是 (类型)表达式 —— 期望 ')'（类型可写 int / int_32 / int_64 / char / double / uint_8 / uint_32 / uint_64，或它们加 * 的指针类型） | `src/parse.c` |
| `[E-SEM-0F98]` | SEM | 结构体变量 '%s' 不是数组，不能下标（要写 a[i] 得先声明成 struct 类型名 %s[N];） | `src/parse.c` |
| `[E-SEM-1248]` | SEM | 不能把 double 赋给 int / 整数类型（此处是 %s，会静默截断小数）——请显式写 (int)值，或把左值声明成 double | `src/parse.c` |
| `[E-SEM-12DE]` | SEM | int 引用不能绑定 double 变量（会静默按 32 位读错值）——请写 double &r = 那个变量; | `src/parse.c` |
| `[E-SEM-16D8]` | SEM | 三元两分支类型不一致：一边是地址（指针/数组/&x/字符串），一边是整数——请显式统一（如 to_int(值)，或先用指针变量承接地址） | `src/parse.c` |
| `[E-SEM-1CD7]` | SEM | api 返回类型须为 int / void / ptr / double（int_64 / uint_64 暂不支持：v1.7.0 P0 边界，64 位返回值请用 ptr 承接） | `src/parse.c` |
| `[E-SEM-1EC5]` | SEM | 无符号整数不能隐式转 double（要先写显式转型，如 (double)u）——或者改用整数值 | `src/parse.c` |
| `[E-SEM-21DE]` | SEM | 函数指针不能解引用：要调用就写 fp(实参)（间接调用），要存地址就写 &函数名 | `src/parse.c` |
| `[E-SEM-24E7]` | SEM | 三元两分支的指针指向类型不一致（如 int* 与 char*）——解引用宽度不同，编译器不替你猜 | `src/parse.c` |
| `[E-SEM-2A29]` | SEM | double 字面量不能作为整数全局变量的初值（会静默截断小数）——请把全局变量声明成 double | `src/parse.c` |
| `[E-SEM-2A96]` | SEM | struct 变量不能整体打印（逐字段 print([s.x])） | `src/parse.c` |
| `[E-SEM-2B91]` | SEM | own/share 指针不能重新赋值（所有权由声明初始化 + 出口自动释放管理） | `src/parse.c` |
| `[E-SEM-30B8]` | SEM | 结构体字段 '%s' 过大（%d 个元素 × %d 字节）——结构体总长不能超过 2GB | `src/parse.c` |
| `[E-SEM-327E]` | SEM | 地址值（64 位）不能转成 %s —— 转型不提供「地址 ↔ 整数」通道（T1 边界：地址值不能装进 int，反向同理）。要地址请用指针变量承接，要数值请从字段/字节取出 | `src/parse.c` |
| `[E-SEM-341A]` | SEM | 函数返回类型须为 int / int_64 / char / double / uint_8 / uint_32 / uint_64 / void / struct 名（指针返回加 *） | `src/parse.c` |
| `[E-SEM-345A]` | SEM | struct 按值返回的函数 '%s' 的调用只能出现在两个位置：① `struct %s v = %s(...);` / `v = %s(...);` 的右值；② 按值返回 struct 的函数里的 `return %s(...);`。不能把结果塞进任意表达式（`%s(...).x` / f(%s(...)) / 参与运算 / 丢弃结果）——本语言没有 struct 整体值语义；请先赋给同类型 struct 变量再逐字段用 | `src/parse.c` |
| `[E-SEM-3488]` | SEM | 数组长度常量表达式里不能除以 0 | `src/parse.c` |
| `[E-SEM-3AE6]` | SEM | void 函数调用不能用于表达式或参数 | `src/parse.c` |
| `[E-SEM-3C38]` | SEM | own/share 指针不能复合赋值（所有权由声明初始化 + 出口自动释放管理） | `src/parse.c` |
| `[E-SEM-3D2E]` | SEM | 接收者的类型不是结构体（这是方法调用点糖 'recv.%.*s(...)' 的形态，糖摊平后 = 类型名_%.*s(&recv, ...)）——接收者须是 struct 变量 / 指向 struct 的变量 / 解引用链 (*p) | `src/parse.c` |
| `[E-SEM-3D6A]` | SEM | 函数指针数组的初值只能是「&函数名」/ 裸函数名 / 函数指针变量（不能接整数、普通指针、函数调用结果） | `src/parse.c` |
| `[E-SEM-3F20]` | SEM | '%.*s' 不能作变量名 | `src/parse.c` |
| `[E-SEM-4047]` | SEM | void 函数不能 return 表达式 | `src/parse.c` |
| `[E-SEM-4270]` | SEM | 数组初值不能是空 {}（至少写一个元素；全零请写 {0}） | `src/parse.c` |
| `[E-SEM-49CC]` | SEM | str([...]) 只在 ① 指针变量声明初始化（char *s = str([...]);）② 赋值语句右值（s = str([...]);）③ **指针返回函数**的 return 值 —— 这 3 个位置可用；本函数的返回类型不是 char*/int*（return str([...]) 不成立：那是地址，不是数值） | `src/parse.c` |
| `[E-SEM-4D36]` | SEM | int_64/uint_64 与 double 不能混算（两者互转只走显式转型）——请先把一侧显式转成另一类（(int)… / (double)…） | `src/parse.c` |
| `[E-SEM-54C8]` | SEM | own/share 指针不能作实参（所有权语义，拷贝初始化专属 v0.9） | `src/parse.c` |
| `[E-SEM-5751]` | SEM | 引用与指针不能组合（v0.7 单修饰符） | `src/parse.c` |
| `[E-SEM-59B0]` | SEM | 不能把 double 值 return 给 int 返回函数（会静默截断小数）——请显式写 to_int(值)，或把函数返回类型改成 double | `src/parse.c` |
| `[E-SEM-5C80]` | SEM | 函数指针不能直接打印（它存的是代码地址，不是可显示的数值） | `src/parse.c` |
| `[E-SEM-5FD1]` | SEM | 使用了未声明的变量 '%.*s' | `src/parse.c` |
| `[E-SEM-64CB]` | SEM | 地址值不能装进 int 形参——函数 '%s' 的第 %d 个形参是值类型（int/char/int_64/uint_*/double），实参却是指针/地址（请先解引用 *p，或把形参改成指针类型） | `src/codegen.c` |
| `[E-SEM-683B]` | SEM | void 不能返回指针 | `src/parse.c` |
| `[E-SEM-739E]` | SEM | 函数指针不能转型（代码地址带签名，转成数据指针会丢签名）——要调用就写 int (*fp)(...)，要地址就写 &函数名 | `src/parse.c` |
| `[E-SEM-7453]` | SEM | 函数指针只能由「&函数名」或另一个函数指针初始化（不能接整数 / 普通指针 / 结构体字段 / 函数调用结果） | `src/parse.c` |
| `[E-SEM-7961]` | SEM | 指针数组请用下标访问（`char *a[N]` 的 a[i]）——`*a` / `*(a+i)` 暂不支持（本版拿不到元素的指向类型，按 32 位读半个指针会静默错值） | `src/parse.c` |
| `[E-SEM-796D]` | SEM | 不支持 struct 转型：struct 没有整体值语义 —— 要换类型请声明一个 struct 指针变量（v1.8.0 边界，见 SPEC） | `src/parse.c` |
| `[E-SEM-7E90]` | SEM | 64 位整数（int_64/uint_64）实参不能直接传给 api 函数（v1.7.0 P0 边界：api 声明没有 64 位参数档，会按 32 位传）——请先显式收窄 | `src/parse.c` |
| `[E-SEM-7F78]` | SEM | try 的目标变量 '%.*s' 未声明（先在本函数里声明，如 int err = 0;） | `src/parse.c` |
| `[E-SEM-86F7]` | SEM | 不能把 %s 赋给 %s（会静默截断高 32 位：值超出范围的部分丢掉）——请显式写 (%s)值，或把左值声明成 %s | `src/parse.c` |
| `[E-SEM-89A2]` | SEM | 函数指针不支持 ++/--/复合赋值（代码地址不能参与整数运算） | `src/parse.c` |
| `[E-SEM-8B04]` | SEM | 函数指针数组初值不能是空 {}（每个元素都要给一个函数） | `src/parse.c` |
| `[E-SEM-8E7A]` | SEM | 结构体初始化右边必须是**同一个 struct 类型**的值（这里给的是 %s）——全零请写 {0}；要搬字段请声明后逐字段赋值 | `src/parse.c` |
| `[E-SEM-8FD2]` | SEM | 结构体字段类型支持 char / int / int_64 / double / uint_8 / uint_32 / uint_64 / int* / char* / double* / 已定义 struct 的值或指针（v2.12） | `src/parse.c` |
| `[E-SEM-9077]` | SEM | int 数组不能整体打印（逐元素 print([a[i]])） | `src/parse.c` |
| `[E-SEM-924E]` | SEM | 字符串未闭合（字符串不能跨行） | `src/tokenize.c` |
| `[E-SEM-92B9]` | SEM | struct 整体赋值要求两边是**同一个 struct 类型**（不同 struct 的布局/字段不同，不能逐字节搬）——请逐字段赋值 | `src/parse.c` |
| `[E-SEM-9344]` | SEM | 未定义的结构体类型 '%.*s' | `src/parse.c` |
| `[E-SEM-96AE]` | SEM | 浮点字面量后不能直接跟标识符或小数点 | `src/tokenize.c` |
| `[E-SEM-9701]` | SEM | 不能把 %s 赋给 double（两者互转只走显式转型）——请先显式 (int)值 再赋，或把左值声明成 %s | `src/parse.c` |
| `[E-SEM-9E9F]` | SEM | 不能把 double 值 return 给 %s 返回函数（两者互转只走显式转型） | `src/parse.c` |
| `[E-SEM-A2DC]` | SEM | own 指针不能作 return 值（出口自动释放 → 悬垂；所有权转移特性 = 已知边界） | `src/parse.c` |
| `[E-SEM-A6ED]` | SEM | void 不能作参数类型（无参函数直接写 f()） | `src/parse.c` |
| `[E-SEM-A8CC]` | SEM | 不支持 (ptr) 转型：ptr 只是 api 返回类型的关键字，指针类型请写 int* / char* / double* / int_64* / uint_32* | `src/parse.c` |
| `[E-SEM-AB06]` | SEM | 方法糖 'recv.%.*s(...)'（%s）摊平后要找的自由函数名有歧义：'%s' 与「忽略大小写的类型名段」都能匹配到多个函数——请把类型名段的大小写写准（命名约定 = 结构体名_方法名，精确名 '%s'） | `src/parse.c` |
| `[E-SEM-AB48]` | SEM | struct 按值返回的函数必须 `return <同类型 struct 值>;`（`return;` 只能用在 void 函数） | `src/parse.c` |
| `[E-SEM-ABD7]` | SEM | struct 数组元素上的方法调用点糖暂不支持（a[i].%.*s(...)）——请手写自由函数形式：类型名_%.*s(&a[i], ...) | `src/parse.c` |
| `[E-SEM-B292]` | SEM | api 参数类型只能是 int / double / ptr（ptr = 64 位句柄/指针；double = XMM 通道；int_64 实参暂不支持：v1.7.0 P0 边界，请先 to_int32(...)） | `src/parse.c` |
| `[E-SEM-B5F2]` | SEM | 函数指针的参数类型需是 int / char / double / struct S *（要收函数指针请先用变量承接：这类嵌套签名暂不支持） | `src/parse.c` |
| `[E-SEM-B9DA]` | SEM | %s 全局变量初值 %lld 超出 0..255（字节类型） | `src/parse.c` |
| `[E-SEM-BD93]` | SEM | 指针转型的源必须是地址值（指针 / 数组名 / &x / 字符串 / new）——整数不能转指针（T1 边界：地址值与 int 不能互相装；空指针请写 int *p = 0;） | `src/parse.c` |
| `[E-SEM-C65D]` | SEM | 地址值（64 位）不能装进全局 int / char / uint_8 / uint_32 变量——全局变量会被按 4/1 字节写回，高 32 位必然丢失（不静默截断）。请把地址存在**局部** int * 变量里，或用局部变量接收后再逐值算出所需整数 | `src/codegen.c` |
| `[E-SEM-C6B1]` | SEM | struct 按值返回的 return 只支持「return <struct 变量/字段/数组元素>;」或「return <同类型按值返回函数调用>;」——`return (a = b);` / `return *sp;` / `return f().x;` 这类形态暂不支持，请先赋给变量再 return | `src/parse.c` |
| `[E-SEM-C85A]` | SEM | 函数指针不能赋给非函数指针变量（要存就声明成 int (*fp)(...)） | `src/parse.c` |
| `[E-SEM-C8CA]` | SEM | api 的模块名字符串不能为空 | `src/parse.c` |
| `[E-SEM-C9AF]` | SEM | str([...]) 只在 ① 指针变量声明初始化（char *s = str([...]);）② 赋值语句右值（s = str([...]);，左值是 char*/int* 变量）③ 指针返回函数的 return 值 —— 这 3 个位置、且作整个右值可用；本处不支持（不能作 print 段/实参/条件/算术的一部分，不能嵌套，也不能当语句丢弃） | `src/parse.c` |
| `[E-SEM-CBE4]` | SEM | str([...]) 的赋值左值 '%.*s' 未声明——要先声明指针（char *s;）再 s = str([...]); | `src/parse.c` |
| `[E-SEM-CDBE]` | SEM | 数组暂不能与 &/* 组合（v0.7 单修饰符） | `src/parse.c` |
| `[E-SEM-D383]` | SEM | own/share 指针不能拷贝给其他变量（share 拷贝请用 int *share q = p; 初始化） | `src/parse.c` |
| `[E-SEM-D3AE]` | SEM | 不能把 double 赋给 %s（只有显式转型能跨浮点/整数）——请写 (%s)值，或改用整数值 | `src/parse.c` |
| `[E-SEM-D51C]` | SEM | struct 指针的初值必须是地址值（&变量 / &a[i] / 指针变量 / new / 字符串）——T1 口径：地址值与 int 不能互相装 | `src/parse.c` |
| `[E-SEM-D606]` | SEM | 未定义的结构体类型 '%.*s'（struct 须先定义后使用） | `src/parse.c` |
| `[E-SEM-DC6F]` | SEM | 结构体不能为空 | `src/parse.c` |
| `[E-SEM-DCFA]` | SEM | share 指针不能作 return 值（引用计数随函数出口管理，caller 无 +1 → 悬垂；return 转移特性 = 已知边界） | `src/parse.c` |
| `[E-SEM-DD13]` | SEM | new 地址不能直接打印（先由 own/share 接管或存变量） | `src/parse.c` |
| `[E-SEM-DD18]` | SEM | 全局变量初值必须是编译期常量（只支持一个字面量，可带正负号）——全局变量在程序启动前就写进 .data，不能依赖运行时才有的值 | `src/parse.c` |
| `[E-SEM-DD94]` | SEM | struct 后需跟类型名 | `src/parse.c` |
| `[E-SEM-DF9E]` | SEM | 指针目标只能接「地址表达式」（&x / 字符串 / 指针变量 / 数组名 / new / 指针返回函数 / API 返回值 / 地址链）、显式常量、或一个装过地址的 int 变量——这里的值只有 32 位，当指针用会指向错地方（int 形参、int 返回值、4 字节的 int 字段/元素里都装不下地址，请把类型声明成 int * 或 ptr） | `src/codegen.c` |
| `[E-SEM-DFFF]` | SEM | 未定义的结构体类型 '%.*s'（struct 须先定义后使用；嵌套值字段不做前向引用——请把内层定义挪到外层之前） | `src/parse.c` |
| `[E-SEM-E3DE]` | SEM | 方法糖 'recv.%.*s(...)'（%s）摊平后要找的自由函数 '%s' 不存在——方法就是普通自由函数：定义 int %s(struct %s *self, ...)，首参由调用方自动补 &recv（命名约定 = 类型名_函数名） | `src/parse.c` |
| `[E-SEM-EAE5]` | SEM | void 函数里不能用 try（没有返回值可带错误码） | `src/parse.c` |
| `[E-SEM-EB30]` | SEM | 结构体类型 '%.*s' 重复定义 | `src/parse.c` |
| `[E-SEM-EDD3]` | SEM | struct 按值返回要求 return 的值是 struct %s 类型（这里给的是 %s） | `src/parse.c` |
| `[E-SEM-F076]` | SEM | 结构体整体拷贝要求两边是**同一个 struct 类型**（不同 struct 的布局/字段不同，不能逐字节搬）——请逐字段赋值 | `src/parse.c` |
| `[E-SEM-F16C]` | SEM | try 的形态是 `try <变量> = <表达式>;`（左值只能是单个变量，不能是 a[i] / s.x —— 那样会被求值两次） | `src/parse.c` |
| `[E-SEM-F7FA]` | SEM | struct 按值返回要求 return **同一个** struct 类型（本函数返回 struct %s，这里给的是 struct %s）——不同类型布局不同，不能逐字节搬 | `src/parse.c` |
| `[E-SEM-F927]` | SEM | 顶层只允许 struct 定义、函数定义或全局变量声明（int/int_64/char/double/uint_8/uint_32/uint_64/void 名称(...) 或同组类型 名称[= 常量];） | `src/parse.c` |
| `[E-SEM-FAC8]` | SEM | 地址形参需要指针——函数 '%s' 的第 %d 个形参收地址，实参却是整数/值（要传地址请写 &x，或把形参改成值类型） | `src/codegen.c` |
| `[E-SEM-FD02]` | SEM | 64 位整数（int_64/uint_64）不能隐式转 double（两者互转只走显式转型）——请先显式收窄再转，或改用整数值 | `src/parse.c` |
| `[E-SEM-FDDF]` | SEM | 函数指针签名不一致：'%s' 的类型是 %s，而 '%.*s' 是另一套签名 | `src/parse.c` |
| `[E-SYN-052D]` | SYN | 全局数组初值里期望 ','（在元素 %d 之后） | `src/parse.c` |
| `[E-SYN-0A9A]` | SYN | 结构体缺少右花括号 '}' | `src/parse.c` |
| `[E-SYN-1E6E]` | SYN | 函数指针数组的初始化必须写成 {&函数名, ...}（长度由声明给出，不支持单个标量初值，也不支持省略长度） | `src/parse.c` |
| `[E-SYN-30D3]` | SYN | 内部错误：struct 数组缺少结构体下标（parse 应已带上） | `src/parse.c` |
| `[E-SYN-3265]` | SYN | 期望函数名 | `src/parse.c` |
| `[E-SYN-3A30]` | SYN | 期望 '%c' | `src/parse.c` |
| `[E-SYN-3C60]` | SYN | 块缺少右花括号 '}' | `src/parse.c` |
| `[E-SYN-3FE3]` | SYN | api 声明期望函数名 | `src/parse.c` |
| `[E-SYN-4678]` | SYN | 全局数组声明缺少长度 | `src/parse.c` |
| `[E-SYN-53ED]` | SYN | 缺少 main 函数（程序入口） | `src/parse.c` |
| `[E-SYN-548B]` | SYN | api 声明期望 ';' | `src/parse.c` |
| `[E-SYN-5638]` | SYN | api 声明期望 ')' | `src/parse.c` |
| `[E-SYN-5697]` | SYN | enum 缺少右花括号 '}' | `src/parse.c` |
| `[E-SYN-613A]` | SYN | str 段列表缺少 ']' | `src/parse.c` |
| `[E-SYN-6853]` | SYN | 函数缺少右花括号 '}' | `src/parse.c` |
| `[E-SYN-6B9D]` | SYN | 内部错误：间接调用节点缺少函数指针目标（既不是变量也没有暂存槽） | `src/codegen.c` |
| `[E-SYN-70D3]` | SYN | int 数组整体初始化必须写成 {v0, v1, ...}（数组没有标量初值语义） | `src/parse.c` |
| `[E-SYN-7333]` | SYN | 函数指针声明缺少参数表：int (*fp)(int) | `src/parse.c` |
| `[E-SYN-74E1]` | SYN | 内部错误：struct 按值返回函数缺少隐藏返回缓冲槽（parse_funcdef 未分配） | `src/parse.c` |
| `[E-SYN-7F9C]` | SYN | 期望变量名（struct 指针请写 struct S *p;） | `src/parse.c` |
| `[E-SYN-8B8F]` | SYN | 指针数组整体初始化必须写成 {"串", &x, ...}（数组没有标量初值语义） | `src/parse.c` |
| `[E-SYN-8BDF]` | SYN | 字符字面量缺少内容 | `src/tokenize.c` |
| `[E-SYN-A239]` | SYN | 内部错误：函数指针表达式缺少签名（取元素时应已从声明带上来） | `src/parse.c` |
| `[E-SYN-A974]` | SYN | 三元 ?: 缺少 ':'（写法：条件 ? 真值 : 假值） | `src/parse.c` |
| `[E-SYN-CD06]` | SYN | 全局 struct 声明缺少 ';' | `src/parse.c` |
| `[E-SYN-D0D3]` | SYN | enum 里期望常量名，得到 '%.*s' | `src/parse.c` |
| `[E-SYN-D0D6]` | SYN | 函数指针数组长度缺少 ']'（写法：int (*ops[2])(int, int)） | `src/parse.c` |
| `[E-SYN-D6F9]` | SYN | 函数指针声明缺少 ')'（要写成 (*名字) 或 (*名字[N])） | `src/parse.c` |
| `[E-SYN-DCAE]` | SYN | enum 后需要名字（写法：enum Name { A, B }） | `src/parse.c` |
| `[E-SYN-DDF7]` | SYN | 期望变量名 | `src/parse.c` |
| `[E-SYN-DE95]` | SYN | print 段列表缺少 ']' | `src/parse.c` |
| `[E-SYN-E101]` | SYN | 期望数字/变量/'('，得到 '%.*s' | `src/parse.c` |
| `[E-SYN-EB78]` | SYN | 期望字段名 | `src/parse.c` |
| `[E-SYN-EBAF]` | SYN | 全局数组声明期望 ']' | `src/parse.c` |
| `[E-SYN-F24D]` | SYN | api 声明期望 '(' | `src/parse.c` |
| `[E-SYN-F7BC]` | SYN | switch 缺少右花括号 '}' | `src/parse.c` |
| `[E-SYN-F910]` | SYN | 函数指针的参数表缺少 ')' | `src/parse.c` |
| `[E-SYN-FCE4]` | SYN | 内部错误：间接调用节点缺少函数指针目标 | `src/codegen.c` |
| `[E-SYN-FDD8]` | SYN | 内部错误：转型缺少操作数 | `src/parse.c` |

## 提取不到的文案（fmt 经变量传入 —— 运行时按变量里的字符串查表，命中不到就不追加 ID）

| 位置 | 入口 | 表达式 |
|---|---|---|
| `src/codegen.c:1249` | `error` | (char *)msg |
| `src/codegen.c:1260` | `error_at_node` | buf |

## 三目/字符串选择的 fmt（已把每个分支逐条收录进上表）

| 位置 | 入口 | 选择表达式 |
|---|---|---|
| `src/parse.c:1139` | `error_at` | arr_len > 0 ? "函数指针数组暂只支持函数顶层作用域声明（块/循环内 = v2.6.0 边界）" : "函数指针暂只支持函数顶层作用域声明（块/循环内 = v1.3.2 边界）" |
| `src/parse.c:1460` | `error_at` | is_ptr_arr ? "指针数组整体初始化必须写成 {"串", &x, ...}（数组没有标量初值语义）" : "int 数组整体初始化必须写成 {v0, v1, ...}（数组没有标量初值语义）" |
| `src/parse.c:1633` | `error_at` | e->is_own ? "own 指针不能作 return 值（出口自动释放 → 悬垂；所有权转移特性 = 已知边界）" : "share 指针不能作 return 值（引用计数随函数出口管理，caller 无 +1 → 悬垂；return |
| `src/parse.c:1689` | `error_at` | p->switch_nest > 0 ? "continue 在 switch 里没有意义（switch 不是循环——它跳的是外层循环，这里没有外层循环；" "要跳出 switch 用 break）" : "continue 只能用在循环里 |
