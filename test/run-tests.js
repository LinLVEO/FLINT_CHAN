// run-tests.js — FLINT 测试驱动（v0.7.1 野路子：编译→运行→退出码闭环）
// 用法：node test\run-tests.js   （需先编译 hlc.exe）
// 覆盖：tokenizer 词法 + 表达式编译成自产 exe + 退出码验证 + 语法错误定位

"use strict";

const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const FLINT = path.join(__dirname, "..", "hlc.exe");
const SAMPLES = path.join(__dirname, "samples");
const TMP = path.join(__dirname, "tmp");

let pass = 0, fail = 0;
const results = [];

function check(name, cond, extra = "") {
  if (cond) { pass++; results.push(`  ✅ ${name}`); }
  else { fail++; results.push(`  ❌ ${name} ${extra}`); }
}

function run(args) {
  try {
    return { ok: true, out: execFileSync(FLINT, args, { encoding: "utf8", timeout: 15000, windowsHide: true }) };
  } catch (e) {
    return { ok: false, code: e.status, stderr: (e.stderr || "").toString(), stdout: (e.stdout || "").toString() };
  }
}

// v1.10.5：在指定工作目录跑（给 build/run 子命令的 build\ 目录用，免得污染仓库根）
function runIn(cwd, args) {
  try {
    return { ok: true, out: execFileSync(FLINT, args, { cwd, encoding: "utf8", timeout: 15000, windowsHide: true }) };
  } catch (e) {
    return { ok: false, code: e.status, stderr: (e.stderr || "").toString(), stdout: (e.stdout || "").toString() };
  }
}

// v1.0.12（评审清单【6】）：超时/被杀/启动失败 必须与「干净退出 0」区分开——
// 原实现 `e.status === null ? 0 : e.status` 把 execFileSync 超时杀掉映射成退出码 0，
// 于是「期望值为 0」的用例区分不了「干净退出」与「死循环被超时杀掉」（系统性假绿）。
// 修法：超时、signal 非空、spawn 失败 → 返回哨兵字符串（永不 === 任何数字期望值 → 判失败）。
const RUN_TIMEOUT = 15000;
const TIMEOUT_SENTINEL = "<超时/被杀>";
const _runExeTimed = function (exe, timeoutMs, captureOut) {
  try {
    const out = execFileSync(exe, [], captureOut ? { encoding: "utf8", timeout: timeoutMs, windowsHide: true } : { timeout: timeoutMs, windowsHide: true });
    return { code: 0, out: captureOut ? out : undefined };
  } catch (e) {
    const out = captureOut ? (e.stdout || "").toString() : undefined;
    if (e.status === null || e.status === undefined || e.signal)
      return { code: TIMEOUT_SENTINEL, out: out };
    // node 在 Windows 上报无符号 32 位退出码，转成有符号（负数程序退出码）
    let code = e.status;
    if (code > 0x7fffffff) code -= 0x100000000;
    return { code: code, out: out };
  }
};

function runExe(exe) {
  return _runExeTimed(exe, RUN_TIMEOUT, false).code;
}

// v1.0.7 console 库：捕获 stdout 的 runExe（退出码 + 输出都验）
function runExeOut(exe) {
  const r = _runExeTimed(exe, RUN_TIMEOUT, true);
  return { code: r.code, out: r.out };
}

// 带命令行参数的可执行文件（jsonq 这类真工具需要 argv；FLINT 从 GetCommandLineA 自己抠）。
// 超时/被杀与干净退出仍用同一套哨兵口径，别让"被超时杀掉"混成退出码 0。
function runExeArgsOut(exe, args) {
  try {
    const out = execFileSync(exe, args, { encoding: "utf8", timeout: RUN_TIMEOUT, windowsHide: true });
    return { code: 0, out: out };
  } catch (e) {
    const out = (e.stdout || "").toString();
    if (e.status === null || e.status === undefined || e.signal)
      return { code: TIMEOUT_SENTINEL, out: out };
    let code = e.status;
    if (code > 0x7fffffff) code -= 0x100000000;
    return { code: code, out: out };
  }
}

// —— 1. tokenizer 冒烟（v0.1 保留）——
{
  const r = run(["-t", path.join(SAMPLES, "sample1.fl")]);
  check("tokenizer: sample1 正常", r.ok && r.out.includes("EOF"));
  check("tokenizer: sample1 含 NUM 42", r.ok && r.out.includes("NUM    42"));
}

// —— 2. 编译→运行→退出码 闭环（核心！）——
// 样本: 期望退出码
const compileCases = [
  ["smoke1.fl", 42],      // return 42
  ["arith1.fl", 7],       // 1+2*3
  ["arith2.fl", 9],       // (1+2)*3
  ["arith3.fl", -3],      // -10/3
  ["arith4.fl", -1],      // -10%3
  ["edge1.fl", 10],       // 2*(3+4)-10/2+1
  ["edge2.fl", -16],      // -((5+3)*2)
  ["edge3.fl", 16],       // 17%5 + 100/7
  ["edge4.fl", 6],        // +5 - -3 + -2
  ["edge5.fl", 83810205], // 12345*6789（32位完整性）
  // —— v0.3 变量与语句 ——
  ["var1.fl", 12],        // int a=3; int b=4; a*b
  ["var2.fl", 20],        // 先声明后赋值+自增序列
  ["var3.fl", 13],        // 手写斐波那契两轮
  ["var4.fl", 7],         // a=(b=5)+2 链式赋值
  ["var5.fl", 50],        // 变量交换
  // —— v0.4 控制流 ——
  ["ctrl1.fl", 1],        // if/else 走 then
  ["ctrl2.fl", 2],        // if/else 走 else
  ["ctrl3.fl", 55],       // while 1..10
  ["ctrl4.fl", 5050],     // for 1..100
  ["ctrl5.fl", 285],      // 嵌套循环 9x9 对角线
  ["ctrl6.fl", 5],        // && 短路副效应
  ["ctrl7.fl", 1],        // || 短路
  ["ctrl8.fl", 1],        // 比较链 + !
  ["ctrl9.fl", 7],        // 条件 return
  ["ctrl10.fl", 1],       // 质数判断（除法+循环）
  // —— v0.4.1 多重声明 / for 内声明 / 作用域 ——
  ["decl1.fl", 6],        // int a=1, b, c=3; 多重声明
  ["fordecl1.fl", 670],   // 两个 for 各 int i（作用域隔离）
  ["scopedecl1.fl", 1],   // 块内遮蔽外层变量
  ["multi_init.fl", 6],   // 多重声明全初始化且引用先前变量
  // —— v0.4.2 ++/-- ——
  ["inc1.fl", 5],         // return x++ 旧值
  ["inc2.fl", 6],         // return ++x 新值
  ["inc3.fl", 8],         // x++ ×3
  ["inc4.fl", 3],         // y-- ×2
  ["inc5.fl", 55],        // for i++
  ["inc6.fl", 12],        // x++ + ++x = 旧5 + 新7
  // —— v0.4.3 复合赋值 ——
  ["comp1.fl", 55],       // sum += i 累加
  ["comp2.fl", 1],        // 五种复合赋值链
  ["comp3.fl", 8],        // return a += 3 值=新值
  ["comp4.fl", 9],        // a += b += 4 右结合
  ["comp5.fl", -3],       // a /= 3 负数
  // —— v0.5 函数调用 ——
  ["fn1.fl", 5],          // add(2,3) 基础调用
  ["fn2.fl", 5],          // sub3(10,3,2) 三参数
  ["fn3.fl", 120],        // fact(5) 递归阶乘
  ["fn4.fl", 10],         // add(add(1,2),add(3,4)) 嵌套调用
  ["fn5.fl", 42],         // 前向调用（main 先定义）+ 函数内局部变量
  ["fn6.fl", 9],          // max4(3,9,5,7) 四参数 + if
  ["fn7.fl", 55],         // fib(10) 双路递归
  ["fn8.fl", 33],         // inc 嵌套 + 返回值继续算术
  ["fn9.fl", 10],         // 无参函数 × for 循环累加
  // —— v0.6 引用 + void ——
  ["ref1.fl", 7],         // int &r = x; r=7 改的是 x
  ["ref2.fl", 42],        // 读引用值 b = r*2
  ["swap.fl", 83],        // void swap(int&,int&) 交换调用方变量
  ["ref3.fl", 8],         // 引用上 += *= ++ 复合
  ["ref4.fl", 42],        // 引用传引用 bump(r)
  ["voidfn.fl", 20],      // void 函数 + return; + 落尾 + 空函数
  ["ref5.fl", 24],        // void 嵌套调用 + 引用链传递
  // —— v0.7 指针 + 数组 ——
  ["ptr1.fl", 42],        // int *p = &x; *p=42 改 x
  ["ptr2.fl", 99],        // set(&a, 99) 指针形参改值
  ["arr1.fl", 30],        // a[5] 下标写读求和（0+1+4+9+16）
  ["arr2.fl", 10],        // sum_arr(a,4) 数组名退化传指针 + p[i]
  ["arr3.fl", 21],        // inc_all(a,3) 指针 +1 每元素
  ["arr4.fl", 30],        // p = a 退化 + *p 步进遍历（2+4+6+8+10）
  // —— v0.7.x 结构体 ——
  ["st1.fl", 34],         // p.x/p.y 字段读写
  ["st2.fl", 80],         // struct 指针形参 swap_xy（p->x 交换）
  ["st3.fl", 42],         // 字段复合/++/&c.n 取址改值
  ["st4.fl", 24],         // struct 引用形参（v.a 自动解引用）
  ["st5.fl", 5000],       // Rect 面积（API 数据结构演练）
  ["st6.fl", 1118],       // 多 struct 变量字段算术
  ["st7.fl", 5],          // &c->n 字段取址
  // —— v0.7.2 位运算 ——
  ["bit1.fl", 12],        // 60 & 13 位与
  ["bit2.fl", 61],        // 60 | 13 位或
  ["bit3.fl", 49],        // 60 ^ 13 位异或
  ["bit4.fl", 1024],      // 1 << 10 左移
  ["bit5.fl", -16],       // -256 >> 4 算术右移保符号
  ["bit6.fl", -262],      // ~5 + ~0xFF 按位取反（-6 + -256）
  ["bit7.fl", 3],         // 2 | 3 & 5 优先级 & 高于 |
  ["bit8.fl", 8],         // 1 << 2+1 优先级 + 高于 <<
  ["bit9.fl", 2],         // 2 | 1 ^ 3 优先级 ^ 高于 |
  ["bit10.fl", 30],       // 位复合赋值链 &= |= ^=（含 0x 字面量）
  ["bit11.fl", 6],        // <<= >>= 移位复合
  ["bit12.fl", 4],        // 引用上间接位复合 r &= 5
  ["bit13.fl", 14],       // 指针上间接位复合 *p |= ^=
  ["bit14.fl", 49],       // 数组元素位复合 a[0] ^= 13
  ["bit15.fl", 2],        // 位测试做条件（Win32 flag 检测演练）
  ["bit16.fl", 14],       // 0x 字面量 + 清位 f & ~0x01
  // —— v0.7.3 字符串/字符字面量 ——
  ["str1.fl", 3],         // 相邻排布地址差（"AB" 3B → b-a=3）
  ["str2.fl", 52],        // 多串连续排布（5*10+2）
  ["str3.fl", 4],         // 转义字符串长度（"A\nB" 4B → b-a=4）
  ["str4.fl", 261],       // 字符字面量 + 转义（25*10+1+10）
  ["str5.fl", 2],         // 子函数字符串跨 ctx 排布（main 先 foo 后）
  ["str6.fl", 12],        // 空串+引号/反斜杠转义（""=1B "\""=2B "\\"=2B → 1*10+2）
  // —— v0.8 API 调用（kernel32 非阻塞可自动跑）——
  ["api2.fl", 1],         // GetTickCount() 返回系统 uptime >0（API 声明墙运行级实证）
  // —— v0.8.1 窗口创建链（12 参栈传参；1.5s 自动退出不阻塞）——
  ["api3.fl", 0],         // CreateWindowExA 12 参 + ShowWindow + 消息循环，EXIT=0
  // —— v0.9.1 S1 回归：跨 DLL 交错声明 IAT 槽序（修复前静默调错函数）——
  ["s1_probe.fl", 0],     // user32 声明在 kernel32 前：修复前 GS→GT 错路由 exit 99
  ["s1b_probe.fl", 0],    // kernel32 夹 user32 中间三路交错：修复前 GS↔GT 互换
  // —— v0.9.2 类型层（S2 关闭）：指针字段 64 位读写 + ptr 返回 API ——
  ["s2_probe.fl", 0],     // struct int/ptr 字段：64 位写读 + C 布局（p@16-a@0=16）
  ["s2b_probe.fl", 0],    // ptr 返回 API 直入 struct 指针字段（int 声明会截断）
  ["s3_frame.fl", 0],     // 帧块布局修正：普通函数 struct 局部 + 数组/标量共存不重叠
  // —— v1.0.4.1 S2 补漏：ptr 字段赋整数字面量（清零）必须 64 位写（32 位写残留高 4 字节）——
  ["s2c_probe.fl", 0],    // >4GB 指针存字段后 s.p=0 清零，读回必须 0（修前残留巨值）
  // —— v0.8 64 位地址链 ——
  ["str7.fl", 65],        // 字符串(数据段>4GB)解引用读首字节 = 'A'（32 位时代做不到）
  // —— v0.9 64 位地址算术墙（决策 17 未竟边界拆除）——
  ["ptr64a.fl", 0],       // VirtualAlloc TOP_DOWN >4GB：p+8/链式加/复合加不截断（截断=解引用崩溃）
  ["ptr64b.fl", 0],       // 数据段(>4GB)字符串地址 比较/差/偏移链 64 位语义一致
  // —— v0.9 new + own 内存管理 ——
  ["new1.fl", 0],         // new int 堆对象读写 + own 出口自动释放（编译级含 VirtualFree）
  ["new2.fl", 77],        // 声明前提前 return：own 槽清零防线（清理跳过 0 槽）
  ["new3.fl", 0],         // 裸 new 手动 VirtualFree(p-8)（头部布局 + 64 位减法）
  ["new4.fl", 0],         // 非 main 函数 own：出口清理 + eax 返回值保护
  // —— v0.9 share 引用计数 ——
  ["sh1.fl", 0],          // new 起点1 → 拷贝+1 → 共享读写；出口 -1 归零释放
  ["sh2.fl", 0],          // share 拷贝链计数逐级验证 + own/share 并存互不干扰
  ["sh3.fl", 66],         // share 槽清零防线：声明前提前 return
  // —— v0.9.3 回调机制：&函数名 = ND_FUNC_ADDR + 真实 WNDPROC 回调 ——
  ["fa_probe.fl", 0],     // &函数名：地址非 0/两函数互异/struct ptr 字段 64 位往返
  ["wndproc_probe.fl", 42], // 回调全链：WNDCLASS.lpfnWndProc=FLINT 函数；注册+创建+PostQuitMessage(42)+消息循环
  // —— v0.8.2 自绘窗口 / FLINT-UI v0.1 ——
  ["ui1.fl", 7],         // 自绘窗口：自写 WNDPROC + PeekMessage 主循环 + GetDC/TextOutA 每帧自绘（自动退）
  ["ui2.fl", 7],         // UI 元素：FillRect 白底/灰按钮 + 文字 + hit_rect 命中自测 5 断言（自动退）
  // —— v1.0.3 间接赋值 = API 调用结果（帧底暂存槽防 rsp 错位；修前 CreateWindowExA 崩）——
  ["align_probe.fl", 0], // 工厂函数把 CreateWindowExA 句柄写进 struct 字段（间接写）+ 消息泵自退
  // —— v1.0.4.1 API 在「外层压栈未消费」位置（二元 rhs / 后求值参数）仍须 rsp≡0 ——
  ["align2_probe.fl", 0], // CreateWindowExA 作 0+x 的右操作数（左值压栈 → 修前 FF15 ≡8 崩）
  // —— v1.0.5 B 档 char 类型 + 字节读写（movzx 字节读/88 字节写；样本见 char1~char10）——
  ["char1.fl", 131],      // char 变量赋值/初始化/读：'A'(65)+'B'(66)
  ["char2.fl", 200],      // 高位值不符号扩展（movzx 零扩展 0..255）
  ["char3.fl", 255],      // 负值赋 char → 无符号字节（-1 → 0xFF = 255）
  ["char4.fl", 300],      // char 提升参与 int 运算不截断（200+100）
  ["char5.fl", 86],       // char 数组：字节写不污染邻字节 + 复合赋值回绕 + ++/--（防 32 位写 bug）
  ["char6.fl", 237],      // struct char 字段：1B 布局 + 字节写隔离 + 字节 ++
  ["char7.fl", 8866],     // char* 指针下标（元素宽 1B）+ char* 形参字节缓冲函数
  ["char8.fl", 200],      // char 函数返回 + char 形参（0..255 寄存器传递）
  ["char9.fl", 42],       // char 比较/条件赋值/for 头 char 声明 + 后置 ++
  ["char10.fl", 15],      // char >>= 复合移位（movzx 读后 sar，255>>4=15）
  // —— v1.0.5 char 应用消化：数字→文本缓冲库（include + char* 跨函数字节写）——
  ["char_itotest.fl", 0], // itoa(n,char*)：12345/0/-42/7/-2147483647 逐字节断言（负号/0/多位）
  ["ui_text.fl", 7],      // UI dogfood：itoa → char 缓冲 → TextOutA 整串一次画（替代 putnum 逐位）
  ["ui_seg.fl", 7],       // flint_ui 整串原语回归：Seg/ui_text/itoa 版 ui_num 窗内量宽推进断言（补盲）
  // —— v1.0.6 函数返回指针（自举前哨）：int*/char*/可空工厂/struct* ——
  ["rtptr1.fl", 42],      // int* 直返 + 穿透写 + 链式返回 + 64 位地址比较
  ["rtptr2.fl", 138],     // char* 返回（数据段字符串）：字节下标/*s 读 + 同地址性
  ["rtptr3.fl", 5],       // 可空工厂 maybe(flag,t)：返回 0 判真 + 地址往返
  ["rtptr4.fl", 5],       // struct* 返回 + 调用链直接 -> 读写穿透
  ["rtptr5.fl", 7],       // 真实句柄工厂直返：make_window() 返 CreateWindowExA 句柄 + NULL 判真
  // —— v1.0.6.1 盲区审计（补零测试路径；A1 修复真 bug）——
  ["audit1.fl", 0],       // A1：指针 ++/-- 前后缀 64 位值语义（>4GB 数据段目标；修前 0xC0000005）
  // —— v1.0.6.2 盲区审计 A2 ——
  ["audit2.fl", 0],       // A2：char 直接变量前后缀/位反 + 赋值·复合赋值表达式值截断（v1.0.6.2 修表达式值=存储字节）
  // —— v1.0.6.2 盲区审计 A3 ——
  ["audit3.fl", 0],       // A3：指针返回 + 函数内 own/share 出口清理不毁 64 位返回值（清理段 rax 保护）
  // —— v1.0.6.2 盲区审计 A4 ——
  ["audit4.fl", 0],       // A4：char 数组+struct char 字段+int 混合帧会 return 普通函数（大帧 300 + 跨函数 struct 指针）
  // —— v1.0.6.2 盲区审计 A5 ——
  ["audit5.fl", 0],       // A5：字符串 \xNN/内嵌 \0/大写 0X 解析字节实证（1-2 位 hex/大小写字母/相邻字面量隔离）
  // —— v1.0.6.2 盲区审计 A7 ——
  ["audit7.fl", 0],       // A7：&a[i] 元素取址 + 指针链 + 负偏移 movsxd 修复（裸指针算术=字节单位语义）
  // —— v1.0.6.2 盲区审计 A8 ——
  ["audit8.fl", 0],       // A8：嵌套作用域 char 遮蔽 + 块内 char 数组 + 跨类型遮蔽（无新 bug）
  // —— v1.0.6.2 盲区审计 A9 ——
  ["audit9.fl", 0],       // A9：ptr 返回调用作 API 实参（>4GB 数据段地址 64 位完整）+ 丢弃语句
  // —— v1.0.7/1.0.8 console 输出（stdout 捕获断言，第三位 = 期望 stdout）——
  // v1.0.8 起 print 是语言内建（段列表形态），console1/print1 不再 include 库
  ["console1.fl", 0, "start\nv=42\n-7|0\ndone\n2147483647\n"], // print 内建：段拼接/负数/0/\n/INT32_MAX
  ["print1.fl", 0, "i=3 c=A done\n123|-7|0\nno-nl42|end\nsum=15\nhello world\n"], // 类型自适应/cout 不换行/表达式/char* 段
  // —— v1.0.8.2 大帧栈探测（决策 41：B2b 撞墙——帧超提交栈时跳过守护页 → 0xC0000005）——
  ["stack1.fl", 42, "big frame ok\n"],   // 25.6KB 帧 + print 的 push 写帧底（修前 AV）
  ["stack2.fl", 42, "huge frame ok\n"],  // 128KB 帧（探测循环 31 轮）+ 帧两端元素读写
  // —— v1.0.9 结构体指针字段直接下标（真 flint；boot 同步 B2m）——
  ["sfield1.fl", 63],     // 位掩码六项：. 形态读 / -> 形态读 / 写穿透 / += / &s.arr[i] / 与局部化等价
  // —— v1.4.4 结构体「固定长度数组字段」（char 1B / int·double 8B 槽；C 布局）——
  ["sarr1.fl", 59],       // 位掩码七项：写/读/当实参传/char 数组/取元素地址/与标量混排/(相邻元素独立性)
  ["sarr3.fl", 15],       // 布局规则四项：char[8]+int+int ⇒ b@8 / c@16 / 两实例互不重叠
  // —— B2q 标准库第一批：lib/str_lib.fl（字符串；跨目录 include + char* 缓冲）——
  ["strlib1.fl", 42],     // str_len/eq/compare/copy/append/find/has_prefix 共 18 项位掩码断言
  ["numlib1.fl", 42],     // num_to_text/from_text/to_hex/digit_count（往返 + 十六进制 + 边界）
  ["memlib1.fl", 42],     // mem_copy/set/eq（n=0 + 未触碰字节隔离）
  ["chrlib1.fl", 42],     // chr_is_digit/alpha/space/upper/lower
  // —— B2r 命名空间（轻量：名字含 :: 限定段）——
  ["nsname1.fl", 42],     // 定义/调用/前向调用 + 全局同名函数与 my::add 互不干扰
  // —— B2s 标准库第二批：fmt（拼缓冲）/ math（整数数学）——
  ["fmtlib1.fl", 42],     // std::fmt_str/int/hex/char/end（位置游标 + 与 str 库共存）
  ["mathlib1.fl", 42],    // std::abs/min/max/clamp/percent
  // —— B2v include 去重（同一文件只展开一次：不同写法 / 菱形依赖）——
  ["incdup_main.fl", 42],   // 同一文件两种写法（"x.fl" + "./x.fl"）
  ["incdup_main2.fl", 42],  // 菱形：b 经 a 间接 include + 直接 include 各一次
  // —— B2x include 搜索路径（免相对路径 → 编译器自带 lib 目录）——
  ["libpath1.fl", 42],      // include "num_lib.fl" / "fmt_lib.fl"（本目录没有，回退 lib\）
  // —— io 库前置条件：库带 api 声明且 include 在函数定义之后（位置冲突不存在）——
  ["io_api_main.fl", 42],
  // —— B2y 标准库第三批：io（整文件读写，用户拍板方案 A）——
  ["iolib1.fl", 42],        // file_write/exists/size/read 八项位掩码 255（含不存在/读失败负例）
  ["iolib2.fl", 42],        // B2z 流式：open/write/close/read/tell/seek/eof 二十项位掩码 1048575
  // —— v1.0.11 ^^ 幂运算符（决策 49：右结合 / 高于一元负号与乘法 / 0^^0=1 / 负指数=0 / 32 位回绕）——
  ["pow1.fl", 4095],        // 12 项位掩码：2^^10 / 右结合 / -2^^2 / 0^^0 / 3*2^^3 / 2^^0 / 1^^100 / (-2)^^3 / 2^^-1 / 2^^31 / 括号 / 5^^3
  // —— v1.2.3 浮点打印（`print([d])`）+ 浮点比较修正（`!=` 曾与 `==` 同义）——
  ["dblcmp1.fl", 65536],   // 16 项位掩码 65535（真/假两侧 + NaN 六项）+ 比较结果当值用 +1；旧实现丢 12324
  ["dblprint1.fl", 15, "basic: 1.500000 -2.250000 0.000000\nround: 1.000000 0.666667\n"
    + "big: 123456.789000 neg: -0.500000\ncall: 2.500000 expr: 3.500000 end\n"
    + "guard: <dbl-out-of-range>|<dbl-nan>\nr=15\n"],   // 定点 6 位 + 进位 + Inf/NaN 守卫
  // —— v1.2.4 浮点阶段2 收尾（双重复合赋值 / double 数组 / 结构体 double 字段）——
  ["dblcompound1.fl", 511, "d=4.000000 a=3.000000,3.000000,3.750000 half=1.875000 r=511\n"],
  ["dblfield1.fl", 511, "p=(5.000000,7.500000) c=A tag=7 r=511\n"],
  // —— v1.2.5 double 指针 / 引用（&d 取址、*p 读写、p[i]、裸指针字节步进、double* 形参与返回、
  //    结构体 double* 字段、double& 引用）：16 项位掩码 = 8191。main 故意写在前 —— 前向调用要考
  //    预扫描有没有把「指向类型 ret_elem」与「double* 形参走 GP 而非 XMM」两件事落表（变体实测崩）——
  ["dblptr1.fl", 131071],
  // —— v1.3.0 全局变量（PE 第二节 .data：int/char/double 标量 + 数组，读写/复合/自增减/
  //    跨函数可见/遮蔽/前向引用）—— 每组 8 项位掩码 = 255。这两条样本是本项工程的"成绩单"：
  //    途中三个静默错值 bug（下方负例区有说明）全靠它们从 191/16 逐步逼到 255。
  ["global1.fl", 255],     // 核心通路：未初始化=0 / 常量初值 / 写读闭环 / 数组下标 / 复合赋值 /
                           //   前后缀 ++-- 语义 / 跨函数写全局 / 局部遮蔽同名全局
  ["global2.fl", 255],     // 类型分支：char 字节读与回绕 / char++ / double 全局读（含"占位值防残值"）/
                           //   double 复合赋值 / double 乘算赋回 / 逗号声明表 / 前向引用 + 未初始化
];

// —— v1.3.2 函数指针（C 风格语法 int (*fp)(int)）——
// 16 项位掩码 65535，覆盖：间接调用基本/换目标/参数顺序/4 参 GP 全用/double 双通道（GP+XMM 并行计数）/
// 指针返回/void 返回/char 形参与返回/结构体指针形参/判空与比较/变量互赋/**函数指针形参**（回调注册）
// 并在被调方通过形参间接调用。**鉴别力用变体证伪过**（临时副本编译，见 PROGRESS 状态记录）：
//   槽按 32 位写 → 崩 ｜ 目标地址先装 rax 再算实参 → 崩 ｜ 形参按 32 位落槽 → 崩。
compileCases.push(
  ["fnptr1.fl", 65535],
);

// —— v1.3.1 三元 ?: 与 switch/case/default ——
// ⚠️ 新样本用 **push 追加**，不去改上面那个数组字面量的收尾：2026-09-13 的坑就是「old_string 包住
//    最后一项 + `];`」把最后一项静默吃掉（通过数只涨 3，没人注意）。追加式改动天然没这个风险。
// 两条样本的鉴别力都用「故意做坏的变体编译器」实测过（tmp\v*.exe，见 PROGRESS 状态记录）：
//   三元选错分支 → 0 ｜ 三元两支都求值 → 26 ｜ switch 不贯穿 → 245 ｜ break 误跳外层 → 223 ｜
//   continue 不穿透 switch → 崩溃（0xC0000005）。**样本自己没被证伪过，就不算有鉴别力。**
compileCases.push(
  ["tern1.fl", 255],   // 8 项位掩码：条件真/假两侧 / 只求值被选中那一支（副作用计数反证）/
                       //   右结合 / 当实参与条件 / 结果参与二元运算 / double 分支的 int→double 提升
  ["sw1.fl", 255],     // 8 项位掩码：命中与未命中 / 空 case 与段间贯穿 / 负号与字符常量 /
                       //   break 归属最内层 / 循环里的 switch（continue 穿透到外层 while）/
                       //   段内块作用域 / 嵌套 switch / switch 条件用三元
);

// —— v1.4.0 API 实参上限 12 → 16（4 寄存器 + 12 栈参；动机 = CreateFontA 是 14 参，字形层卡在这）——
// 鉴别力口径：两条样本都**读回实参落地值**，不是"编译过 / 没崩"——
//   apiarg16.fl：msvcrt printf 把第 5..16 实参（= 栈上 12 个槽）逐位打印，比 stdout（错位/垃圾即红）；
//   apifont1.fl：14 参建 Consolas 字后 GetObjectA/GetTextFaceA 读回第 1/5/9/12/14 参逐字段比对。
// 负侧在下方负例区（17 参必须编译期报错，不是静默截断/静默忽略）。
//   ⚠️ 期望串用 \r\n：msvcrt 的 printf 走文本模式会把 \n 翻成 \r\n（FLINT 自带 print 是原样字节，
//   所以别照抄 console1/print1 那批的 "\n" 口径——实测踩过：写成 \n 会红，实际是 "…15\r\n"）。
compileCases.push(
  ["apiarg16.fl", 42, "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15\r\n"],
  ["apifont1.fl", 127],
);

// —— v1.4.8 api 模块名支持**字符串字面量**（带点全名 / 带路径）——
// 动机：标识符词法不吃 '.'（is_ident2 只认字母/数字/下划线）→ `api cabridge.dll` 写不出来，
//   而"多语言交火·编译期缝合"必须能指名全名。口径：模块名含 '.'/'\'/'/' → 原样写进导入表；
//   否则补 ".dll"（裸短名行为一字不变）。
// 鉴别力（**不是"编译过就算"**）：
//   ① 端到端：apimod1.fl 用 `api "msvcrt.dll"` 调系统 printf —— 若错误地再补一次 .dll
//      就会去找 msvcrt.dll.dll → **进程启动即 STATUS_DLL_NOT_FOUND**，退出码直接红；
//   ② 导入表字节级断言在主循环之后（需 TMP 已建）：源码里写什么全名，产物里就必须**恰好是**那个串。
// 追加式改动（见 v1.3.1 那条注释的教训：别把 old_string 包住数组收尾）。
compileCases.push(
  ["apimod1.fl", 42, "apimod ok 7\r\n"],   // 字面量带点全名 → 原样用，不双补
);

// —— lib\vec_lib.fl：通用容器（路线 V1「8 字节槽 + 取地址传值」，任务 T-20260917-201506）——
// 10 项位掩码 = 1023：int 往返 / 容量 1→2→4 扩容两次后旧元素逐字节存活 / double 位模式往返 /
//   指针往返（MEM_TOP_DOWN 高地址 → 高 32 位不丢）/ 越界与负下标返回 0 / 长度口径 /
//   **int 槽字节审计**（&a 的 8 字节必须是符号扩展的干净值，不是"低 4 字节对就算过"）。
// 追加式改动（见上一条注释的教训：别让 old_string 包住数组收尾）。
compileCases.push(
  ["vec1.fl", 1023],
);

// —— vec_lib 扩容压力：从 cap 1 连推 1000 个元素（9 次搬块），再逐个读回校验 ——
// 专抓「搬块时少拷字节 / 丢尾巴」这类只在多次搬块后才暴露的错；退出码 42 = 全部对位。
compileCases.push(
  ["vec_big.fl", 42],
);

// —— ui_lib 即时模式组件层（ui_button / ui_check / ui_scroll / 裁剪）——
// 17 项位掩码 = 131071：命中测试 / 按钮三态与点击 / 悬停底像素 / 勾选切换与内块像素 /
//   拖滑块与点轨道 / 裁剪（盒内涂上、盒外不动、pop 后解除）＋ 裁剪区非空。
// ⚠️ 两条已实测的断言纪律（写样本时踩过，别再犯）：① 像素断言用**离屏 DIB 表面**（surf_init），
//   不要建窗读窗口 DC —— 窗口 DC 带可见区裁剪，被遮挡处读到未定义内容（实测 0x0F423F 假红）；
//   ② **裁剪区外不要用 GetPixel**（实测返回 0xFFFFFF 假白）→ 直读 `surf.bits` 缓冲取地面真相。
// 追加式改动（见上条注释的教训）。
compileCases.push(
  ["ui_widgets.fl", 131071],
);

// —— FLGUI 内核（M1 无头回归：flgui1.fl，卡 T-20260922-042229）——
// **不建窗**：合成输入当数据喂 gui_begin，布局/游标/命令表/状态池 dump 成文本走 stdout。
// 22 项位掩码全亮才 return 42：①模拟点击计数（按下当帧不算/抬起且仍悬停才算/未悬停不触发）
//   ②布局游标关系（首项落 pad、换行回列首、列推进 = 上行高 + 间距）③状态池跨帧存活且不串位
//   ④守卫（命令表 256 截断计数、文本 arena 4096 溢出计数、裁剪栈配平、被裁掉的不发命令）。
// ⚠️ 配套的"双端 dump 逐字节对账 + 基线"在 `test\flgui-verify.ps1`（总门这里只查退出码）。
compileCases.push(
  ["flgui1.fl", 42],
);

// —— FLGUI 控件层（M2 无头行为成绩单①：flgui2.fl，卡 T-20260922-042229）——
// 分隔线 / 滑块 / 进度条 / 只读文本域：26 项位掩码全亮才 42（命令序是契约，按下标断言 kind 与矩形）。
// 重点钉住的语义：滑块"点轨道即生效 + 按住跟手（拖出控件也不丢）+ 越界夹到 [0,max] + 抬手令牌交回"、
//   进度条"0 不发填充命令 / 100 填满 / >max 不溢出"、文本域"按盒宽截断 + 左内边距"。
// 双端 dump 逐字节对账同样在 `test\flgui-verify.ps1`。
compileCases.push(
  ["flgui2.fl", 42],
);

// —— FLGUI 控件层（M2 成绩单②：flgui3.fl）——
// 滚动视图（滚轮 + 内容高夹取 + 滚动条几何 + 内容短于视口不发滚动条）＋ 弹层菜单（开/点条目关闭/点外面关闭）。
// 26 项位掩码全亮才 42；双端 dump 对账在 test\flgui-verify.ps1。
compileCases.push(
  ["flgui3.fl", 42],
);

// —— v1.8.0：C 风格转型 `(type)expr` ——
// 双端共用的类型宇宙子集（int / char / 指针）；数值行的 double / int_64 行由
// test\facts\f042..f047 做独立裁判（boot 没有 double / int_64 这两个类型，属既有缺口）。
compileCases.push(
  ["cast1.fl", 42],
);

// —— v1.9.0：三种无符号整数 uint_8 / uint_32 / uint_64 ——
// 只跑真 flint：boot 的类型宇宙没有 uint_*（既有类型缺口，同 double / int_64）⇒ 差分门里
// uint* 样本落 BOOT_FAIL，不是分歧。数值行的独立裁判 = test\facts\f048..f052（uint-exp.js 现算）。
//   uint1.fl     位掩码 8 位全亮 → 退出码 42（回绕/无符号除模/逻辑右移/无符号比较/混合提升）
//   uintprint.fl print 与 str 两条打印腿的**无符号十进制**整串比对（期望串由裁判现算）
compileCases.push(
  ["uint1.fl", 42],
  ["uintprint.fl", 0,
   "A4294967295B18446744073709551615C44D\n[4294967295|18446744073709551615|44]\n"],
);

// —— v2.0.0：try 错误传播糖 ——
//   try1.fl = 三层函数，错误码从最内层一路 return 到 main（stdout 与退出码双判据）。
//   数值层的独立裁判 = test\facts\f053_errprop.fl（8 位掩码全亮 → 退 42）。
//   boot 侧暂不支持 try（见 PROGRESS 的双端缺口登记）⇒ 本样本不进差分门。
compileCases.push(
  ["try1.fl", 42, "ok=0 bad=-7\n"],
);

fs.mkdirSync(TMP, { recursive: true });
for (const [sample, expect, expectOut] of compileCases) {
  const src = path.join(SAMPLES, sample);
  const exe = path.join(TMP, sample.replace(/\.fl$/, ".exe"));
  const r = run(["-o", exe, src]);
  const label = `${sample} → ${expect}`;
  if (!r.ok) {
    check(`compile ${label}`, false, r.stderr.trim().slice(0, 120));
    continue;
  }
  check(`compile ${label}`, fs.existsSync(exe) && fs.statSync(exe).size > 0);
  if (!fs.existsSync(exe)) continue;

  // PE 头检查：MZ 魔数
  const head = fs.readFileSync(exe).slice(0, 2);
  check(`pe ${label} 是 MZ 头`, head[0] === 0x4D && head[1] === 0x5A);

  // 运行验证退出码（+ console 库样本验证 stdout）
  const res = runExeOut(exe);
  const got = res.code;
  check(`run ${label} 退出码`, got === expect, `实际 ${got}`);
  if (expectOut !== undefined) {
    check(`out ${label} stdout`, res.out === expectOut, `实际 ${JSON.stringify(res.out)}`);
  }
}

// —— jsonq：第 0 号真工具（apps\jsonq\jsonq.fl，工单-JSON查询器-jsonq.md §3）——
//   判据 = 退出码 + stdout 双判；期望值由 node 读同一份 JSON **现算**（不手写期望串）。
//   退出码口径：0 = 取到；1 = 路径不存在且无 stdout；2 = 语法错误 + "行:列 原因"。
{
  const SRC = path.join(__dirname, "..", "apps", "jsonq", "jsonq.fl");
  const exe = path.join(TMP, "jsonq.exe");
  const build = run(["-o", exe, SRC]);
  check("jsonq: 编译", build.ok && fs.existsSync(exe),
    build.ok ? "" : (build.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const SAMPLE = path.join(SAMPLES, "json1.json");
    const doc = JSON.parse(fs.readFileSync(SAMPLE, "utf8"));
    // jsonq prints ASCII control bytes as \xNN (one value stays on one line); mirror that.
    const show = (s) => String(s).replace(/[\x00-\x1f\x7f]/g,
      (c) => "\\x" + c.charCodeAt(0).toString(16).padStart(2, "0"));
    const cases = [
      [".cpu.temp", 0, show(doc.cpu.temp)],
      [".cpu.load", 0, show(doc.cpu.load)],
      [".items[0].name", 0, show(doc.items[0].name)],
      [".items[1].name", 0, show(doc.items[1].name)],
      [".items[1].n", 0, show(doc.items[1].n)],
      [".esc", 0, show(doc.esc)],
      [".flag", 0, show(doc.flag)],
      [".nil", 0, show(doc.nil)],
      [".no.such", 1, ""],
      [".items[9]", 1, ""],
      [".cpu.temp.deeper", 1, ""],
    ];
    for (const [p, wantCode, wantOut] of cases) {
      const r = runExeArgsOut(exe, [SAMPLE, p]);
      check(`jsonq ${p} 退出码`, r.code === wantCode, `实际 ${r.code}`);
      const want = wantOut === "" ? "" : wantOut + "\n";
      check(`jsonq ${p} stdout`, r.out === want, `实际 ${JSON.stringify(r.out)}`);
    }
    const bad = runExeArgsOut(exe, [path.join(SAMPLES, "jsonbad.json"), ".a"]);
    check("jsonq 坏 JSON 退出码", bad.code === 2, `实际 ${bad.code}`);
    check("jsonq 坏 JSON 报位置", /^\d+:\d+ /.test(bad.out), `实际 ${JSON.stringify(bad.out)}`);
    const noarg = runExeArgsOut(exe, []);
    check("jsonq 缺参数 退出码", noarg.code === 2, `实际 ${noarg.code}`);
  }
}

// —— v2.3.0：str_into(dst, cap, [...]) —— 调用方给缓冲的字符串拼接 ——
//   判据 = test\facts\f055_str_into.fl（8 位掩码全亮 → 退 42）。
//   为什么要它：str() 的产物指向唯一一块静态缓冲，begin 会先清零 ⇒ `b = str(["X", a])`
//   里 a 指向的内容当场没了（SPEC 的别名语义）。str_into 把拼接结果拷进调用方缓冲，从根上没有别名。
//   boot 侧是已知缺口（lib_parse.fl 报 -250），本探针只在真 flint 侧跑。
{
  const src = path.join(__dirname, "facts", "f055_str_into.fl");
  const exe = path.join(TMP, "f055_str_into.exe");
  const r = run(["-o", exe, src]);
  check("str_into 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("str_into 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M0（2026-10-30）：像素层 lib\gfx.fl ——
//   判据 = test\facts\f070_gfx_dib.fl（8 位掩码全亮 → 退 42）。
//   钉三件事：① stride = DIB 位图宽 bw（不是逻辑宽 w）；② DIB 字节序 B,G,R,A；
//   ③ 越界写被丢 / 矩形裁剪。游戏帧缓冲全靠这条直写通道（零新增 api：借 Surf.bits）。
{
  const src = path.join(__dirname, "facts", "f070_gfx_dib.fl");
  const exe = path.join(TMP, "f070_gfx_dib.exe");
  const r = run(["-o", exe, src]);
  check("gfx 像素层探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("gfx 像素层探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M1（2026-10-31）：滚屏 lib\grid.fl ——
//   判据 = test\facts\f071_grid_scroll.fl（8 位掩码全亮 → 退 42）。
//   钉四件事：① 二维索引 m[y*w+x]；② camera 平移 + 只遍历可见 tile；
//   ③ 部分越界 tile 的裁剪计数；④ 两端 camera 全屏外 = 0 绘制（不越界不崩）。
{
  const src = path.join(__dirname, "facts", "f071_grid_scroll.fl");
  const exe = path.join(TMP, "f071_grid_scroll.exe");
  const r = run(["-o", exe, src]);
  check("grid 滚屏探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("grid 滚屏探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M1 文件管线（2026-10-31）：ASCII 地图读取 lib\mapload.fl ——
//   判据 = test\facts\f072_grid_load.fl（8 位掩码全亮 → 退 42）。
//   钉：基本读入 / '.'→0 / '\r\n' / 多余行丢弃 / 短行不崩 / 空文件 / 文件不存在 / 真实 32x17 地图。
{
  const src = path.join(__dirname, "facts", "f072_grid_load.fl");
  const exe = path.join(TMP, "f072_grid_load.exe");
  const r = run(["-o", exe, src]);
  check("grid 地图文件探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("grid 地图文件探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M2（2026-10-31）：精灵绘制 lib\sprite.fl（调色板索引 -> GfxBuf）——
//   判据 = test\facts\f073_sprite.fl（8 位掩码全亮 → 退 42）。
//   钉：透明跳过 / 帧切换 / 越界不崩 / ncol 截断。
{
  const src = path.join(__dirname, "facts", "f073_sprite.fl");
  const exe = path.join(TMP, "f073_sprite.exe");
  const r = run(["-o", exe, src]);
  check("sprite 精灵探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sprite 精灵探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M2 状态机（2026-10-31）：lib\actor.fl（站/走帧号）——
//   判据 = test\facts\f074_actor.fl（8 位掩码全亮 → 退 42）。
//   钉：站恒帧 0 / 走按 8 tick 在帧 1、2 间交替 / 跨轮不漂 / 攻占位回 0 / moving 非 0 即走。
{
  const src = path.join(__dirname, "facts", "f074_actor.fl");
  const exe = path.join(TMP, "f074_actor.exe");
  const r = run(["-o", exe, src]);
  check("actor 状态机探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("actor 状态机探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M3（2026-10-31）：定点数 16.16 + AABB + 落地 lib\phys.fl ——
//   判据 = test\facts\f075_phys.fl（8 位掩码全亮 → 退 42）。
//   钉：int/16.16 往返（含负数）/ fx_mul 口径 / AABB 相交与贴边 / 落地归零 / 同序列确定性。
{
  const src = path.join(__dirname, "facts", "f075_phys.fl");
  const exe = path.join(TMP, "f075_phys.exe");
  const r = run(["-o", exe, src]);
  check("phys 物理探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("phys 物理探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M3 第二刀（2026-10-31）：刚体 + tile 碰撞 lib\body.fl ——
//   判据 = test\facts\f076_body.fl（8 位掩码全亮 → 退 42）。
//   钉：空地/实心 AABB、重力下落、落地 onground + vy 归零、落地稳定、撞墙停住、同序列落点确定。
{
  const src = path.join(__dirname, "facts", "f076_body.fl");
  const exe = path.join(TMP, "f076_body.exe");
  const r = run(["-o", exe, src]);
  check("body 刚体探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("body 刚体探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M3 第三刀（2026-10-31）：像素级贴边 + 跳跃 ——
//   判据 = test\facts\f077_body_edge.fl（8 位掩码全亮 → 退 42）。
//   钉：贴左/右墙的精确 x、贴地精确 y、起跳上升、落地回原 y、空中 onground=0、vx=0 不动、同序列确定。
{
  const src = path.join(__dirname, "facts", "f077_body_edge.fl");
  const exe = path.join(TMP, "f077_body_edge.exe");
  const r = run(["-o", exe, src]);
  check("body 贴边跳跃探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("body 贴边跳跃探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4（2026-10-31）：打击感状态机 lib\hitfx.fl ——
//   判据 = test\facts\f078_hitfx.fl（8 位掩码全亮 → 退 42）。
//   钉：freeze/flash 递减并停在 0、震屏偏移在 [-shake,shake]、同 seed 序列确定、start 重置、shake=0 恒 0。
{
  const src = path.join(__dirname, "facts", "f078_hitfx.fl");
  const exe = path.join(TMP, "f078_hitfx.exe");
  const r = run(["-o", exe, src]);
  check("hitfx 打击感探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("hitfx 打击感探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第二刀（2026-10-31）：攻击盒 + 三段连击 + 输入缓冲 lib\attack.fl ——
//   判据 = test\facts\f079_attack.fl（8 位掩码全亮 → 退 42）。
//   钉：左右攻击盒命中/不命中、一段 step/timer、三段、窗口过期归零、超三段不再加、序列确定。
{
  const src = path.join(__dirname, "facts", "f079_attack.fl");
  const exe = path.join(TMP, "f079_attack.exe");
  const r = run(["-o", exe, src]);
  check("attack 攻击连击探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("attack 攻击连击探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M5（2026-10-31）：定长对象池 lib\pool.fl ——
//   判据 = test\facts\f080_pool.fl（8 位掩码全亮 → 退 42）。
//   钉：init 栈满、LIFO 分配、用尽 -1、回收复用、1000 轮无泄漏、字段写读、越界 free 拒绝。
{
  const src = path.join(__dirname, "facts", "f080_pool.fl");
  const exe = path.join(TMP, "f080_pool.exe");
  const r = run(["-o", exe, src]);
  check("pool 对象池探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("pool 对象池探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M5 第二刀（2026-10-31）：敌人 AI 状态机 lib\enemy.fl ——
//   判据 = test\facts\f081_enemy.fl（8 位掩码全亮 → 退 42）。
//   钉：三档距离（巡逻/追击/攻击）、边界 16/48、死亡不可逆、巡逻折返、序列确定。
{
  const src = path.join(__dirname, "facts", "f081_enemy.fl");
  const exe = path.join(TMP, "f081_enemy.exe");
  const r = run(["-o", exe, src]);
  check("enemy AI 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("enemy AI 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M7（2026-10-31）：存档二进制序列化 lib\save.fl ——
//   判据 = test\facts\f082_save.fl（8 位掩码全亮 → 退 42）。
//   钉：pack 字节数、unpack 往返、魔数/版本/长度拒绝、cap 不够、负数小端、文件往返。
{
  const src = path.join(__dirname, "facts", "f082_save.fl");
  const exe = path.join(TMP, "f082_save.exe");
  const r = run(["-o", exe, src]);
  check("save 存档探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("save 存档探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M3 第四刀（2026-10-31）：单向平台（tile 9）——
//   判据 = test\facts\f083_oneway.fl（8 位掩码全亮 → 退 42）。
//   钉：从上落下停在平台顶、从下上跳穿过、body_hit_solid 不算 9、横向真墙仍挡、落地稳定、序列确定。
{
  const src = path.join(__dirname, "facts", "f083_oneway.fl");
  const exe = path.join(TMP, "f083_oneway.exe");
  const r = run(["-o", exe, src]);
  check("oneway 单向平台探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("oneway 单向平台探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M6（2026-10-31）：音频 lib\audio.fl（PlaySoundA 异步）——
//   判据 = test\facts\f084_audio.fl（8 位掩码全亮 → 退 42）。
//   钉：stop 非 0、不存在文件异步提交不崩、真 WAV 播放 1、调用 <100ms、NULL 返回 0、
//       连播不崩、stop 后再播、两次 stop 确定。
{
  const src = path.join(__dirname, "facts", "f084_audio.fl");
  const exe = path.join(TMP, "f084_audio.exe");
  const r = run(["-o", exe, src]);
  check("audio 音频探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("audio 音频探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M5 第三刀（2026-10-31）：第二种精灵表（敌人 12x12）与共存 ——
//   判据 = test\facts\f085_enemy_sprite.fl（8 位掩码全亮 → 退 42）。
//   钉：尺寸/帧数、load 数据抽查、帧 1 脚部不同、blit 像素色。
{
  const src = path.join(__dirname, "facts", "f085_enemy_sprite.fl");
  const exe = path.join(TMP, "f085_enemy_sprite.exe");
  const r = run(["-o", exe, src]);
  check("enemy_sprite 敌人图探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("enemy_sprite 敌人图探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第三刀（2026-10-31）：闪白叠白不抹画面 gfx_flash ——
//   判据 = test\facts\f086_flash.fl（8 位掩码全亮 → 退 42）。
//   钉：黑底 50% 叠白、alpha=0/255/越界、白底不变、纯红叠白、负 alpha 拒绝、零尺寸不崩。
{
  const src = path.join(__dirname, "facts", "f086_flash.fl");
  const exe = path.join(TMP, "f086_flash.exe");
  const r = run(["-o", exe, src]);
  check("flash 闪白探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("flash 闪白探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M6 第二刀（2026-10-31）：BGM 循环 audio_play_loop ——
//   判据 = test\facts\f087_bgm.fl（8 位掩码全亮 → 退 42）。
//   钉：循环播放 1、调用 <100ms、stop、NULL 拒绝、不存在文件不崩、连播、停后普通播、序列确定。
{
  const src = path.join(__dirname, "facts", "f087_bgm.fl");
  const exe = path.join(TMP, "f087_bgm.exe");
  const r = run(["-o", exe, src]);
  check("bgm 循环探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("bgm 循环探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M5 第四刀（2026-10-31）：敌人池 + AI 更新循环（无渲染汇合）——
//   判据 = test\facts\f088_enemy_pool.fl（8 位掩码全亮 → 退 42）。
//   钉：8 个池满、第 9 个 -1、1000 帧 AI、无泄漏、回收复用、top 计数、回收不擦字段、序列确定。
{
  const src = path.join(__dirname, "facts", "f088_enemy_pool.fl");
  const exe = path.join(TMP, "f088_enemy_pool.exe");
  const r = run(["-o", exe, src]);
  check("enemy_pool 敌人池探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("enemy_pool 敌人池探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M2 第四刀（2026-10-31）：精灵整数放大 sprite_blit_scale ——
//   判据 = test\facts\f089_sprite_scale.fl（8 位掩码全亮 → 退 42）。
//   钉：scale=1 等价、scale=2 像素数、放大块颜色、透明不放大、scale=0 拒绝、kaguya 素材。
{
  const src = path.join(__dirname, "facts", "f089_sprite_scale.fl");
  const exe = path.join(TMP, "f089_sprite_scale.exe");
  const r = run(["-o", exe, src]);
  check("sprite_scale 放大探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sprite_scale 放大探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 残影修复（2026-10-31）：gfx_clear / gfx_flash 必须按 stride 逐行 ——
//   判据 = test\facts\f090_clear_stride.fl（8 位掩码全亮 → 退 42）。
//   钉：stride>w 时逻辑区全清、DIB 留白不被误清、flash 同样按 stride、零尺寸不崩。
{
  const src = path.join(__dirname, "facts", "f090_clear_stride.fl");
  const exe = path.join(TMP, "f090_clear_stride.exe");
  const r = run(["-o", exe, src]);
  check("clear_stride 残影探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("clear_stride 残影探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第三刀（2026-10-31）：粒子 + 月牙 lib\fx.fl ——
//   判据 = test\facts\f091_fx.fl（8 位掩码全亮 → 退 42）。
//   钉：空池发射、槽位顺序、粒子坐标、update 位移/寿命、到期复用、满池 -1、月牙像素数。
{
  const src = path.join(__dirname, "facts", "f091_fx.fl");
  const exe = path.join(TMP, "f091_fx.exe");
  const r = run(["-o", exe, src]);
  check("fx 特效探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("fx 特效探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 平走走出平台必须掉下去（2026-10-31，修"悬空"）——
//   判据 = test\facts\f092_walk_off.fl（8 位掩码全亮 → 退 42）。
//   钉：落地、走到平台边缘外、继续下落（不是卡在边缘）、onground 归 0、边缘仍算站着、序列确定。
{
  const src = path.join(__dirname, "facts", "f092_walk_off.fl");
  const exe = path.join(TMP, "f092_walk_off.exe");
  const r = run(["-o", exe, src]);
  check("walk_off 走落探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("walk_off 走落探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第四刀（2026-10-31）：贝塞尔刀光弧 + 沿弧粒子 ——
//   判据 = test\facts\f093_slash_arc.fl（8 位掩码全亮 → 退 42）。
//   钉：弧像素数（16 点 × w²）、半程、t=0、w=1、发射 14 个、粒子存活、起点墨、确定性。
{
  const src = path.join(__dirname, "facts", "f093_slash_arc.fl");
  const exe = path.join(TMP, "f093_slash_arc.exe");
  const r = run(["-o", exe, src]);
  check("slash_arc 刀光探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("slash_arc 刀光探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第五刀（2026-10-31）：SDF 半圆弧刀光（逐像素判距离，不断线）——
//   判据 = test\facts\f094_slash_sdf.fl（8 位掩码全亮 → 退 42）。
//   钉：整数 sqrt 五档、右半圆有墨、左半不画、y 限制、确定性。
{
  const src = path.join(__dirname, "facts", "f094_slash_sdf.fl");
  const exe = path.join(TMP, "f094_slash_sdf.exe");
  const r = run(["-o", exe, src]);
  check("slash_sdf 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("slash_sdf 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第六刀（2026-11-01）：3D 弧面刀光细线 + 粒子向上飘 ——
//   判据 = test\facts\f095_s3_arc.fl（8 位掩码全亮 → 退 42）。
//   钉：97 个采样点回吐、细线宽度 1..4px、s3_emit_arc 发射数、vy 向上、fx_update_rise 上飘且收敛。
{
  const src = path.join(__dirname, "facts", "f095_s3_arc.fl");
  const exe = path.join(TMP, "f095_s3_arc.exe");
  const r = run(["-o", exe, src]);
  check("s3_arc 3D 刀光探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("s3_arc 3D 刀光探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M4 第七刀（2026-11-01）：刀光特效池（多实例、0.1s 连发、非纯加速）——
//   判据 = test\facts\f096_slashfx.fl（8 位掩码全亮 → 退 42）。
//   钉：寿命 12 帧、空槽启动、池满顶掉 0 号、tick 全减一、st=1 只白弧、st=2 白+青、face=0 镜像。
{
  const src = path.join(__dirname, "facts", "f096_slashfx.fl");
  const exe = path.join(TMP, "f096_slashfx.exe");
  const r = run(["-o", exe, src]);
  check("slashfx 特效池探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("slashfx 特效池探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 游戏 M6 第一刀（2026-11-01）：受击反应（硬直 + 击退）——
//   判据 = test\facts\f097_hitstun.fl（8 位掩码全亮 → 退 42）。
//   钉：face 方向、初始硬直 10、tick 递减、击退 ×3/4 衰减、10 帧后解除、速度趋 0。
{
  const src = path.join(__dirname, "facts", "f097_hitstun.fl");
  const exe = path.join(TMP, "f097_hitstun.exe");
  const r = run(["-o", exe, src]);
  check("受击反应探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("受击反应探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 语言 v2.1.0 第一刀（2026-11-01）：enum 具名整数常量 ——
//   判据 = test\facts\f098_enum.fl（8 位掩码全亮 → 退 42）。
//   钉：首项 0、自增、显式赋值、多 enum 并存、常量参与算式、局部变量遮蔽常量、循环上界。
//   ⚠️ boot 端暂不支持 enum（boot 源码不用、samples 不用 ⇒ 自举与差分门不受影响）。
{
  const src = path.join(__dirname, "facts", "f098_enum.fl");
  const exe = path.join(TMP, "f098_enum.exe");
  const r = run(["-o", exe, src]);
  check("enum 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("enum 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 语言 v2.2.0（2026-11-01）：二维数组 `int m[32][17]`（最小形态）——
//   判据 = test\facts\f099_2darr.fl（8 位掩码全亮 → 退 42）。
//   钉：基本写读 / 行列不混 / row-major 布局（&m[0][0] 一维别名做独立裁判）/ 表达式下标 /
//       首末边界 / 与一维数组并存 / 行边界不串 / 全量填充校验和 + 哨兵不被写坏。
//   boot 端同步支持（规格 ty=7，见 boot\lib_parse.fl）。
{
  const src = path.join(__dirname, "facts", "f099_2darr.fl");
  const exe = path.join(TMP, "f099_2darr.exe");
  const r = run(["-o", exe, src]);
  check("二维数组探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("二维数组探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— v2.2.0：二维数组的禁区（五条全是编译期硬错，绝不静默）——
//   为什么必须是硬错：char/double 的整块布局没定；三维/变量列数会让帧槽算错；只写一维下标
//   若静默按一维展开会读到别的行；全局二维的 .data 行列布局与初始化都没定。
{
  const cases = [
    ["d2_bad_char.fl", "int main() { char c[4][5]; return 0; }\n",
      /二维数组暂只支持 int/, "char 二维 → 编译期硬错（只开 int）"],
    ["d2_bad_3d.fl", "int main() { int t[2][3][4]; return 0; }\n",
      /三维数组暂不支持/, "三维 → 编译期硬错"],
    ["d2_bad_colvar.fl", "int main() { int n = 5; int m[4][n]; return 0; }\n",
      /列数须为数字常量/, "变量列数 → 编译期硬错（帧槽必须在编译期算死）"],
    ["d2_bad_onesub.fl", "int main() { int m[4][5]; m[2] = 9; return 0; }\n",
      /需要两个下标/, "只写一维下标 → 编译期硬错（不静默读错行）"],
    ["d2_bad_global.fl", "int g[4][5];\nint main() { return 0; }\n",
      /全局二维数组暂不支持/, "全局二维 → 编译期硬错（只开局部）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`二维数组负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
  // -strict 的常量**列**下标越界（行下标沿用既有数组口）——加了检查就得有反证用例
  const d2o = path.join(TMP, "d2_strict_oob.fl");
  fs.writeFileSync(d2o, "int main() { int m[4][5]; m[1][20] = 1; return m[1][0]; }\n");
  const rd1 = run(["-strict", "-o", path.join(TMP, "d2_strict_oob.exe"), d2o]);
  check("二维数组负例：-strict 常量列下标越界被拦（E-STRICT-BOUNDS）",
    !rd1.ok && /E-STRICT-BOUNDS/.test(rd1.stderr || ""), (rd1.stderr || "").trim().slice(0, 160));
  const rd0 = run(["-o", path.join(TMP, "d2_strict_ok.exe"), d2o]);
  check("二维数组负例：不带 -strict 时同一文件照常编译（「默认静默」的定义）", rd0.ok,
    (rd0.stderr || "").trim().slice(0, 160));
}

// —— 语言 v2.4.0（2026-11-01）：struct 嵌套 struct **值字段**（内层必须已定义） ——
//   判据 = test\facts\f100_nested_struct.fl（8 位掩码全亮 → 退 42）。
//   钉：基本写读 / 两级字段互不串 / **C 布局字节（int* 别名独立裁判 ⇒ v@0、b.x@4、b.y@8）** /
//       连续两次读写 / 与普通字段共存 / &a.b 传 struct B* 形参 / 两个外层实例独立 / p->b.x 两级指针。
//   boot 端同步支持（字段类型码 5 = struct 值字段，见 boot\lib_parse.fl 的 fld_ty / st_align_of）。
{
  const src = path.join(__dirname, "facts", "f100_nested_struct.fl");
  const exe = path.join(TMP, "f100_nested_struct.exe");
  const r = run(["-o", exe, src]);
  check("嵌套 struct 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("嵌套 struct 探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— v2.4.0：struct 嵌套的禁区（三条全是编译期硬错；boot 侧同结论，专码 -135 / -242 / -200）——
//   为什么必须硬错：自嵌套值字段尺寸无穷（指针形态 `struct A *next;` 仍合法）；前向/互相嵌套会
//   撕开「内层必须已定义」这条唯一性判据。
//   v2.13.0（struct 值语义第三刀）改判：**一维嵌套数组字段**已开放（`struct E es[2];` 合法，
//   布局/下标见 src\parse.c 的 parse_structdef 与 postfix），旧的 ns_bad_arr 负例随之换成
//   同族里**仍然成立**的边界 = 二维 `struct E es[2][3]`（明确不做，响亮报错）。
{
  const cases = [
    ["ns_bad_undef.fl", "struct A { struct B b; }\nint main() { struct A a; a.b.x = 1; return 0; }\n",
      /未定义的结构体类型 'B'/, "内层未定义 → 编译期硬错"],
    ["ns_bad_self.fl", "struct A { int v; struct A a; }\nint main() { return 0; }\n",
      /不能把自身作为值字段/, "自嵌套值字段 → 编译期硬错（指针形态仍合法）"],
    ["ns_bad_arr2d.fl", "struct B { int x; }\nstruct A { struct B b[2][3]; }\nint main() { return 0; }\n",
      /只支持一维/, "二维 struct 数组字段 → 编译期硬错（一维 es[N] 已开放）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`嵌套 struct 负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
}

// —— 语言 v2.5.0（2026-11-01）：局部 int 数组整体初始化 `int a[N] = {v0, ...};` ——
//   判据 = test\facts\f101_array_init.fl（8 位掩码全亮 → 退 42）。
//   钉：基本形态 / 不足补 0 / 负值 / enum 常量作元素 / 表达式元素 / 与逐元素赋值同结果（独立裁判）/
//       二维 row-major 填充 / 长度 1。
//   ⚠️ boot 端暂未支持（boot 源码不用、samples 不用 ⇒ 自举与差分门不受影响）。
{
  const src = path.join(__dirname, "facts", "f101_array_init.fl");
  const exe = path.join(TMP, "f101_array_init.exe");
  const r = run(["-o", exe, src]);
  check("数组整体初始化探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("数组整体初始化探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 语言 v2.6.0（2026-11-01）：函数指针数组 `int (*ops[N])(T, T)` ——
//   判据 = test\facts\f102_funcptr_array.fl（8 位掩码全亮 → 退 42）。
//   钉：整体初始化 / 下标间接调用 / 运行时按下标赋值 / 元素顺序（不是反的）/ 参数传参 /
//       与直接调用同一函数同结果（独立裁判）/ 长度 3 取中间元素 / 写后元素互不踩坏。
//   ⚠️ boot 端暂未支持（boot 连函数指针单变量都没有）⇒ 自举与差分门不受影响。
{
  const src = path.join(__dirname, "facts", "f102_funcptr_array.fl");
  const exe = path.join(TMP, "f102_funcptr_array.exe");
  const r = run(["-o", exe, src]);
  check("函数指针数组探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("函数指针数组探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：像素 HUD 文字（5x7 点阵）——
//   判据 = test\facts\f103_hud.fl（8 位掩码全亮 → 退 42）。
//   钉：字库表 / 前景像素位置 / 背景透明 / 越界不写 / 笔位推进 / 数字形状 / scale 放大 / 宽度与小写映射。
//   ⚠️ boot 端不涉及（lib\hud.fl 是新库，boot 不用）。
{
  const src = path.join(__dirname, "facts", "f103_hud.fl");
  const exe = path.join(TMP, "f103_hud.exe");
  const r = run(["-o", exe, src]);
  check("HUD 文字探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("HUD 文字探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：相机（死区跟随 + 世界边界 clamp）——
//   判据 = test\facts\f104_camera.fl（8 位掩码全亮 → 退 42）。
//   钉：非法参数 / 死区内不跟 / 四向越界跟 / 四向 clamp / 世界小于视口 / 多步序列确定。
//   ⚠️ boot 端不涉及（新库不进 boot）。
{
  const src = path.join(__dirname, "facts", "f104_camera.fl");
  const exe = path.join(TMP, "f104_camera.exe");
  const r = run(["-o", exe, src]);
  check("相机探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("相机探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：敌人系统（实体池 + 生成/回收 + 每帧 AI/物理）——
//   判据 = test\facts\f105_enemy_pool.fl（8 位掩码全亮 → 退 42）。
//   钉：池满 / 回收复用同槽 / 三档状态推进 / 物理撞墙折返 / 同池互不踩坏 / 命中掩码。
//   ⚠️ boot 端不涉及（新库不进 boot）。
{
  const src = path.join(__dirname, "facts", "f105_enemy_pool.fl");
  const exe = path.join(TMP, "f105_enemy_pool.exe");
  const r = run(["-o", exe, src]);
  check("敌人系统探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("敌人系统探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— v2.15.0（2026-11-02）：编译期常量（G5/G7）——
//   判据 = test\facts\f106_const_case.fl（8 位掩码全亮 → 退 42）。
//   钉：enum 当 case 标签 / default / 不命中 / 常量表达式数组长度（局部/二维/struct 数组/数组字段/全局）。
//   ⚠️ boot 端不涉及（enum case 与常量长度只做 flint 端）。
{
  const src = path.join(__dirname, "facts", "f106_const_case.fl");
  const exe = path.join(TMP, "f106_const_case.exe");
  const r = run(["-o", exe, src]);
  check("编译期常量探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("编译期常量探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：敌人类型参数化（地面 / 飞行）——
//   判据 = test\facts\f107_enemy_kind.fl（8 位掩码全亮 → 退 42）。
//   钉：spawn_ex 参数 / 飞行浮动与换向 / 地面落地 / 飞行追击 / 旧 spawn 兼容 / 同池混合 / 飞行攻击掩码。
//   ⚠️ boot 端不涉及（新库不进 boot）。
{
  const src = path.join(__dirname, "facts", "f107_enemy_kind.fl");
  const exe = path.join(TMP, "f107_enemy_kind.exe");
  const r = run(["-o", exe, src]);
  check("敌人类型探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("敌人类型探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：BGM（8-bit 循环，12s A 小调）——
//   判据 = test\facts\f109_bgm.fl（8 位掩码全亮 → 退 42）。
//   钉：播放/停止/playing 状态 / 不存在文件不崩且不置 1 / 重复播 / stop 后再播 / 两次 stop。
//   ⚠️ 探针用仓库相对路径 games/huiye/bgm.wav（cwd = 仓库根）。
{
  const src = path.join(__dirname, "facts", "f109_bgm.fl");
  const exe = path.join(TMP, "f109_bgm.exe");
  const r = run(["-o", exe, src]);
  check("BGM 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("BGM 探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：场景 / 塔层切换（两层往返）——
//   判据 = test\facts\f110_scene.fl（8 位掩码全亮 → 退 42）。
//   钉：加载/尺寸/地板格值 / 切层与地图变化 / 不存在的层 / 传送门 / 出生点(7) / 越界不崩。
//   ⚠️ 地图是相对路径（apps/tower/map.txt、games/huiye/floor2.txt），cwd = 仓库根。
{
  const src = path.join(__dirname, "facts", "f110_scene.fl");
  const exe = path.join(TMP, "f110_scene.exe");
  const r = run(["-o", exe, src]);
  check("场景探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("场景探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：第 2 个可玩角色（hero2：3 帧动画）——
//   判据 = test\facts\f111_actor2.fl（8 位掩码全亮 → 退 42）。
//   钉：sprite 尺寸/帧数 / 透明与配色像素 / 站帧 / 走帧 / 攻击帧 / 状态切换 / 大 tick 回绕。
{
  const src = path.join(__dirname, "facts", "f111_actor2.fl");
  const exe = path.join(TMP, "f111_actor2.exe");
  const r = run(["-o", exe, src]);
  check("第 2 角色探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("第 2 角色探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：中文 HUD（16x16 GBK 字库）——
//   判据 = test\facts\f108_hud_cn.fl（8 位掩码全亮 → 退 42）。
//   钉：字库表 / 前景位置 / 背景透明 / GBK 双字节拼字 / 0 结尾 / scale=2 / 越界 / 未收录字。
{
  const src = path.join(__dirname, "facts", "f108_hud_cn.fl");
  const exe = path.join(TMP, "f108_hud_cn.exe");
  const r = run(["-o", exe, src]);
  check("中文 HUD 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("中文 HUD 探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— FLGUI 帧限速（2026-11-02）：持续输入信号下不变速 ——
//   判据 = test\facts\f112_flgui_pace.fl（8 位掩码全亮 → 退 42）。
//   钉：周期换算 / 无消息帧长 / 上限 / **有消息不截短** / A-B 均衡 / 不限速档 / 确定性 / 返回值。
//   ⚠️ 用 PostThreadMessage 灌消息模拟持续输入，不建窗；修复前这里会红（实测 exit 167）。
{
  const src = path.join(__dirname, "facts", "f112_flgui_pace.fl");
  const exe = path.join(TMP, "f112_flgui_pace.exe");
  const r = run(["-o", exe, src]);
  check("帧限速探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("帧限速探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：七彩冲击波（蓄力 -> 环扩散）——
//   判据 = test\facts\f113_shockwave.fl（8 位掩码全亮 → 退 42）。
//   钉：start 参数 / 二次缓出半径 / power 最大半径 / 生命周期 / 环带命中 / 色相 / 蓄力映射 / draw+确定性。
{
  const src = path.join(__dirname, "facts", "f113_shockwave.fl");
  const exe = path.join(TMP, "f113_shockwave.exe");
  const r = run(["-o", exe, src]);
  check("冲击波探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("冲击波探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 游戏引擎 v1（2026-11-02）：图层（z 序 + 分数缩放 + 层内偏移）——
//   判据 = test\facts\f114_layer.fl（8 位掩码全亮 → 退 42）。
//   钉：start 清零 / add 顺序 / 坐标=x+ox / pose 改偏移 / scale 生效且非法拒绝 / z 序 / 满 16 层 / frac 3/4 缩放 36 像素。
{
  const src = path.join(__dirname, "facts", "f114_layer.fl");
  const exe = path.join(TMP, "f114_layer.exe");
  const r = run(["-o", exe, src]);
  check("图层探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("图层探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 2026-11-03（int4-abi）：全局大数组初值进 PE .data（解除「全局初值 64 字节」上限）——
//   判据 = test\facts\f115_dataseg.fl（8 位掩码全亮 → 退 42）。
//   钉：4096 个常量初值 / i%7 混合值（4096 项全扫描）/ 小初值老能力（char·int_64·double）/
//       局部数组字面量回归 / 旧 64 字节边界 / 两大数组互不覆盖 + 其后小全局偏移正确 / .data 可写。
{
  const src = path.join(__dirname, "facts", "f115_dataseg.fl");
  const exe = path.join(TMP, "f115_dataseg.exe");
  const r = run(["-o", exe, src]);
  check("全局大初值探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("全局大初值探针：8 位掩码全亮", res.code === 42, "实际 " + res.code);
  }
}

// —— 尺寸判据（本活的验收核心）：初值进 .data ⇒ 产物里是 16 KiB 静态字节，不是 4096 条 mov ——
//   为什么这么量：同一份逻辑（g[i] = i%7，4096 项）写两遍 ——
//     ① 靠全局初值直接躺在 .data（本活新开的路）；
//     ② 声明 + 逐元素赋值（这条路之前**唯一能用**，也是 64 字节上限逼出来的写法）。
//   两者都必须退 42（行为等价），差的只是体积。阈值取「数量级」（< 40000 字节且至少小 4 倍），
//   不是 5% 那种噪声；实测见 check 的 extra 串（改前逐元素约 190 KiB，改后约 17 KiB）。
{
  const n = 4096;
  const vals = Array.from({ length: n }, (_, i) => i % 7);
  const tail =
    "  if (g[0] != 0) { return 1; }\n" +
    "  if (g[2048] != 4) { return 1; }\n" +
    "  if (g[4095] != 0) { return 1; }\n";
  const staticSrc = path.join(TMP, "dataseg_static.fl");
  const assignSrc = path.join(TMP, "dataseg_assign.fl");
  fs.writeFileSync(staticSrc, `int g[${n}] = {${vals.join(",")}};\nint main() {\n${tail}  return 42;\n}\n`);
  let a = `int g[${n}];\nint main() {\n`;
  for (let i = 0; i < n; i++) a += `  g[${i}] = ${vals[i]};\n`;
  a += tail + "  return 42;\n}\n";
  fs.writeFileSync(assignSrc, a);
  const staticExe = path.join(TMP, "dataseg_static.exe");
  const assignExe = path.join(TMP, "dataseg_assign.exe");
  const rs = run(["-o", staticExe, staticSrc]);
  const ra = run(["-o", assignExe, assignSrc]);
  const szS = rs.ok && fs.existsSync(staticExe) ? fs.statSync(staticExe).size : -1;
  const szA = ra.ok && fs.existsSync(assignExe) ? fs.statSync(assignExe).size : -1;
  const cS = szS > 0 ? runExe(staticExe) : null;
  const cA = szA > 0 ? runExe(assignExe) : null;
  check("尺寸判据：4096 元素全局初值进 .data（<40000 字节且至少小 4 倍）",
    szS > 0 && szA > 0 && cS === 42 && cA === 42 && szS < 40000 && szS * 4 < szA,
    `静态 ${szS} 字节(退 ${cS}) / 逐元素赋值 ${szA} 字节(退 ${cA})`);
}

// —— v2.7.0（2026-11-02）：解析器嵌套深度保护 ——
//   为什么：2000 层括号曾让 hlc 栈溢出（0xC00000FD）静默崩掉，用户只看到"编译器死了"。
//   判据：300 层编得过（上限内不误伤）、600 层响亮报错（不是崩）。
{
  const mk = (n) => "int main() { return " + "(".repeat(n) + "1" + ")".repeat(n) + "; }\n";
  const deep = path.join(TMP, "depth600.fl");
  fs.writeFileSync(deep, mk(600));
  const r = run([deep]);
  check("嵌套深度：600 层响亮报错（不崩）", !r.ok && /嵌套过深/.test(r.stderr || ""),
    (r.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  const ok = path.join(TMP, "depth300.fl");
  fs.writeFileSync(ok, mk(300));
  const r2 = run([ok]);
  check("嵌套深度：300 层仍能编译（上限内不误伤）", r2.ok, r2.ok ? "" : (r2.stderr || "").trim().slice(0, 120));
}

// —— v2.7.0 追加：无花括号的语句链也走递归 ——
//   为什么：原先只在 stmt_inner 的 '{' 分支计数 ⇒ `if (1) if (1) ...` 2000 层照样 0xC00000FD。
//   判据：2000 层 if 链必须响亮报错（守卫在 stmt() 包装层，块/if/while 全经它）。
{
  const ifDeep = path.join(TMP, "if2000.fl");
  fs.writeFileSync(ifDeep, "int main() { " + "if (1) ".repeat(2000) + "return 0; }\n");
  const ri = run([ifDeep]);
  check("嵌套深度：2000 层 if 链响亮报错（不崩）", !ri.ok && /嵌套过深/.test(ri.stderr || ""),
    (ri.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
}

// —— 函数指针数组的边界必须响亮报错（v2.6.0）—— 三条负例各自钉一种静默风险
{
  const cases = [
    ["fp_neg_sig.fl",
      "int add(int a,int b){return a+b;}\nint one(int a){return a;}\nint main(){ int (*ops[2])(int,int) = {&add,&one}; return 0; }\n",
      /元素签名不一致/, "元素签名与数组声明不同 → 编译期硬错"],
    ["fp_neg_val.fl",
      "int add(int a,int b){return a+b;}\nint main(){ int (*ops[2])(int,int) = {&add,5}; return 0; }\n",
      /初值只能是/, "整数作元素初值 → 编译期硬错"],
    ["fp_neg_oob.fl",
      "int add(int a,int b){return a+b;}\nint main(){ int (*ops[2])(int,int) = {&add,&add}; return ops[5](1,2); }\n",
      /常量下标 5 越界/, "常量下标越界 → 编译期硬错（不许静默读野地址）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`函数指针数组负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
}

// —— v1.9.0：无符号类型的**禁区**（全是编译期硬错：不允许静默截断 / 静默跨浮点）——
// 与 int_64 的既有口径逐条同形（拓宽隐式、收窄必须显式、跨浮点只走显式转型）。
{
  const cases = [
    ["nu_narrow.fl", "int main() { uint_64 u = 0 - 1; int i = u; return i; }\n",
      /不能把 uint_64 赋给 int/, "uint_64 → int 隐式收窄 → 编译期硬错"],
    ["nu_dblasgn.fl", "int main() { double d = 1.5; uint_32 u = d; return u; }\n",
      /不能把 double 赋给 uint_32/, "double → uint_32 隐式转换 → 编译期硬错（只走显式转型）"],
    ["nu_dblarg.fl", "int f(uint_32 x) { return x; }\nint main() { double d = 1.5; return f(d); }\n",
      /double 实参不支持/, "double 实参传给 uint_32 形参 → 编译期硬错"],
    ["nu_dblmix.fl", "int main() { uint_32 u = 1; double d = 2.0; return (u + d); }\n",
      /不能隐式转 double|不支持 double/, "uint_32 与 double 混算 → 编译期硬错"],
    ["nu_ref.fl", "int main() { uint_64 u = 1; uint_64 &r = u; return 0; }\n",
      /引用暂不支持/, "uint_64 引用 → 编译期硬错（引用读是 32 位解引用）"],
    ["nu_new.fl", "int main() { uint_64 *p = new uint_64; return 0; }\n",
      /new uint_64.*暂不支持|堆上要 64 位/, "new uint_64 → 编译期硬错（堆负载按类型分派未做）"],
    ["nu_switch.fl", "int main() { uint_64 u = 1; switch (u) { case 1: return 1; } return 0; }\n",
      /switch 的条件暂不支持 64 位/, "switch 条件是 uint_64 → 编译期硬错（跳转表 32 位）"],
    ["nu_pow.fl", "int main() { uint_64 u = 2; uint_64 v = u ^^ 3; return v; }\n",
      /\^\^ 暂不支持 64 位/, "uint_64 的 ^^ → 编译期硬错（快速幂是 32 位累加器）"],
    ["nu_apiarg.fl",
      "api user32 int MessageBoxA(int, int, int, int);\nint main() { uint_64 u = 1; return MessageBoxA(0, 0, 0, u); }\n",
      /声明的是 int.*显式收窄/, "uint_64 实参传给 int 形参的 api → 编译期硬错（v1.11.0 起按声明类型判，文案指向显式收窄）"],
    ["nu_apiarg64.fl",
      "api user32 int MessageBoxA(int, int, int, int);\nint main() { int_64 x = 1; return MessageBoxA(0, 0, 0, x); }\n",
      /声明的是 int.*显式收窄/, "int_64 实参传给 int 形参的 api → 编译期硬错（不再笼统说'暂不支持'）"],
    ["nu_apiptr.fl",
      "api kernel32 int GetModuleHandleA(ptr);\nint main() { int_64 x = 1; return GetModuleHandleA(x); }\n",
      /地址 ≠ 整数/, "64 位整数实参传给 ptr 形参的 api → 编译期硬错（地址 ≠ 整数）"],
    ["nu_apidbl.fl",
      "api msvcrt int printf(int, double);\nint main() { int_64 x = 1; return printf(0, x); }\n",
      /不能隐式转 double/, "int_64 实参传给 double 形参的 api → 编译期硬错（跨浮点只走显式转型）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`无符号负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
}

// —— v1.8.0：C 风格转型 `(type)expr` 的**禁区**（全是编译期硬错，绝不允许静默退化）——
// 语义表见 SPEC「C 风格转型」节。正例矩阵项 = cast1.fl（int/char/指针，双端共用子集），
// 数值行的独立裁判在 test\facts\f042..f047。这里钉的是"不许猜"的那一侧：
//   struct / void / 数组 没有整体值语义；(char)double 未列入 v1 口径；
//   int ↔ 指针 是 T1 边界（地址值不能装进 int，反向同理）；函数指针带签名，转成数据指针会丢。
{
  const cases = [
    ["nc_struct.fl", "struct S { int a; }\nint main() { struct S s; s.a = 1; return (struct S)s; }\n",
      /不支持 struct 转型/, "(struct S)值 → 编译期硬错"],
    ["nc_void.fl", "int main() { int x = 5; return (void)x; }\n",
      /不支持 \(void\) 转型/, "(void)值 → 编译期硬错（没有 void 值）"],
    ["nc_addr2int.fl", "int main() { int x = 5; int *p = &x; return (int)p; }\n",
      /地址值不能装进 int/, "(int)指针 → 编译期硬错（T1：地址值不能装进 int）"],
    ["nc_int2ptr.fl", "int main() { int x = 5; int *q = (int*)x; return *q; }\n",
      /整数不能转指针/, "(int*)整数 → 编译期硬错（T1 的反向）"],
    ["nc_arrcast.fl", "int main() { int a[3]; return (int[3])a; }\n",
      /不支持数组转型/, "(int[3])值 → 编译期硬错（数组没有整体值语义）"],
    ["nc_chardbl.fl", "int main() { return (char)1.5; }\n",
      /不支持 \(char\)double/, "(char)double → 编译期硬错（v1 未列入，要求两步写清）"],
    ["nc_funcptr.fl", "int f(int a) { return a; }\nint main() { int (*fp)(int) = &f; int *p = (int*)fp; return 0; }\n",
      /函数指针不能转型/, "函数指针转型 → 编译期硬错（代码地址带签名，转成数据指针会丢）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const r = run([path.join(TMP, name)]);
    check(`负例：${label}`, !r.ok && re.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");
  }
}

// —— v1.4.8（续）：api 模块名字面量形态的**导入表字节级断言** ——
// 放在主循环之后（TMP 此时已建）。覆盖三种形态：字面量全名 / 带路径 / 裸短名；
// 判据 = 产物原始字节里**含且仅含**期望的模块串（"未双补 .dll"即排除 msvcrt.dll.dll 那类错误）。
{
  const modCases = [
    ["apimod_lit.fl", 'api "cabridge.dll" int cs_add(int, int);\nint main() { return cs_add(2, 3); }\n', "cabridge.dll"],
    ["apimod_path.fl", 'api "E:/x/y/cabridge.dll" int cs_add(int, int);\nint main() { return cs_add(2, 3); }\n', "E:/x/y/cabridge.dll"],
    ["apimod_bare.fl", "api cabridge int cs_add(int, int);\nint main() { return cs_add(2, 3); }\n", "cabridge.dll"],
  ];
  for (const [sample, src, wantMod] of modCases) {
    const srcPath = path.join(TMP, sample);
    fs.writeFileSync(srcPath, src);
    const exe = path.join(TMP, sample.replace(/\.fl$/, ".exe"));
    const r = run(["-o", exe, srcPath]);
    const label = `apimod ${sample}`;
    if (!r.ok) { check(label, false, r.stderr.trim().slice(0, 120)); continue; }
    // latin1 = 字节透明读 → 可直接在原始字节里找模块名（不依赖任何外部工具）
    const bytes = fs.readFileSync(exe).toString("latin1");
    check(`${label} 导入表含 "${wantMod}"`, bytes.includes(wantMod));
    check(`${label} 未双补 .dll`, !bytes.includes(wantMod + ".dll"));
  }
  // 负例：模块名既不是标识符也不是字符串 → 必须编译期报错（不静默当成默认 DLL）
  const badSrc = path.join(TMP, "apimod_bad.fl");
  fs.writeFileSync(badSrc, "api 123 int f(int);\nint main() { return 0; }\n");
  const rb = run([badSrc]);
  check("负例：api 后跟数字被拒", !rb.ok && /模块名/.test(rb.stderr || ""));
}

// —— 3. 语法错误定位 ——
{
  // 未闭合括号
  fs.writeFileSync(path.join(TMP, "syn1.fl"), "int main() {\n  return (1 + 2;\n}\n");
  let r = run([path.join(TMP, "syn1.fl")]);
  check("语法错误: 未闭合括号报错", !r.ok);
  check("语法错误: 定位第 2 行", !r.ok && /第 2 行/.test(r.stderr), r.stderr);
  check("语法错误: 报错头含列号", !r.ok && /第 2 行第 \d+ 列/.test(r.stderr), r.stderr);
  check("语法错误: 报错头含文件名", !r.ok && /syn1\.fl/.test(r.stderr), r.stderr);

  // v0.5：main 后跟其他函数 = 合法多函数
  fs.writeFileSync(path.join(TMP, "syn2.fl"), "int main() {\n  return 1;\n}\nint foo() { return 0; }\n");
  r = run(["-o", path.join(TMP, "syn2.exe"), path.join(TMP, "syn2.fl")]);
  check("多函数: main 后可跟其他函数", r.ok);
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn2.exe"));
    check("多函数: main 返回值 1", got === 1, `实际 ${got}`);
  }

  // 无 main 函数
  fs.writeFileSync(path.join(TMP, "syn3.fl"), "int foo() {\n  return 1;\n}\n");
  r = run([path.join(TMP, "syn3.fl")]);
  check("语法错误: 缺少 main 函数被拒", !r.ok && /缺少 main/.test(r.stderr), r.stderr);

  // —— v0.3 错误场景 ——
  // 未声明变量
  fs.writeFileSync(path.join(TMP, "syn4.fl"), "int main() {\n  a = 5;\n  return 1;\n}\n");
  r = run([path.join(TMP, "syn4.fl")]);
  check("语法错误: 未声明变量被拒", !r.ok && /未声明/.test(r.stderr), r.stderr);

  // 重复声明
  fs.writeFileSync(path.join(TMP, "syn5.fl"), "int main() {\n  int a = 1;\n  int a = 2;\n  return a;\n}\n");
  r = run([path.join(TMP, "syn5.fl")]);
  check("语法错误: 重复声明被拒", !r.ok && /重复声明/.test(r.stderr), r.stderr);

  // 赋值左边不是变量
  fs.writeFileSync(path.join(TMP, "syn6.fl"), "int main() {\n  (1 + 2) = 5;\n  return 1;\n}\n");
  r = run([path.join(TMP, "syn6.fl")]);
  check("语法错误: 赋值左值非法被拒", !r.ok && /赋值左边/.test(r.stderr), r.stderr);

  // 无 return → 隐式 0
  fs.writeFileSync(path.join(TMP, "syn7.fl"), "int main() {\n  int a = 5;\n}\n");
  r = run(["-o", path.join(TMP, "syn7.exe"), path.join(TMP, "syn7.fl")]);
  check("语法: 无 return 编译成功", r.ok);
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn7.exe"));
    check("语法: 无 return 隐式退出码 0", got === 0, `实际 ${got}`);
  }

  // —— v0.5 函数错误场景 ——
  // v1.4.26：**函数参数上限 4 → 32**（前 4 个走 rcx/rdx/r8/r9、第 5 个起走栈参；规范 = MSDN x64 ABI）。
  //   ① 正例（新能力必须进正例表，不能只留负例）：6 个参数能编、且传参正确（哨兵权重和 = 321 ⇒ 退 42）
  fs.writeFileSync(path.join(TMP, "syn8.fl"),
    "int six(int a, int b, int c, int d, int e, int f) { return a * 1 + b * 2 + c * 4 + d * 8 + e * 16 + f * 32; }\n" +
    "int main() { if (six(1, 2, 3, 4, 5, 6) == 321) { return 42; } return 7; }\n");
  r = run([path.join(TMP, "syn8.fl")]);
  check("语法: 6 参数可编译（第 5/6 个走栈参）", r.ok, r.stderr);
  if (r.ok) {
    const got6 = runExe(path.join(TMP, "syn8.exe"));
    check("运行: 6 参数传参正确（哨兵权重和 321 ⇒ 退 42）", got6 === 42, `实际 ${got6}`);
  }
  //   ② 负例：33 个参数被拒（越过新上限 32）
  fs.writeFileSync(path.join(TMP, "syn8b.fl"),
    "int f(" + Array.from({ length: 33 }, (_, i) => `int p${i + 1}`).join(", ") + ") { return 0; }\nint main() { return 1; }\n");
  r = run([path.join(TMP, "syn8b.fl")]);
  check("语法错误: 33 参数被拒（上限 32）", !r.ok && /参数最多 32 个/.test(r.stderr), r.stderr);

  // main 带参
  fs.writeFileSync(path.join(TMP, "syn9.fl"), "int main(int x) { return 1; }\n");
  r = run([path.join(TMP, "syn9.fl")]);
  check("语法错误: main 带参数被拒", !r.ok && /main 函数不需要参数/.test(r.stderr), r.stderr);

  // 调用未定义函数
  fs.writeFileSync(path.join(TMP, "syn10.fl"), "int main() { return nosuch(1); }\n");
  r = run([path.join(TMP, "syn10.fl")]);
  check("语法错误: 未定义函数调用被拒", !r.ok && /未声明/.test(r.stderr), r.stderr);

  // 变量不可调用
  fs.writeFileSync(path.join(TMP, "syn11.fl"), "int main() { int a = 1; return a(); }\n");
  r = run([path.join(TMP, "syn11.fl")]);
  check("语法错误: 变量不可调用", !r.ok && /不可调用/.test(r.stderr), r.stderr);

  // 函数名不带括号
  fs.writeFileSync(path.join(TMP, "syn12.fl"), "int f() { return 1; }\nint main() { return f; }\n");
  r = run([path.join(TMP, "syn12.fl")]);
  check("语法错误: 函数名需带括号", !r.ok && /需带括号/.test(r.stderr), r.stderr);

  // —— v0.6 引用/void 错误场景 ——
  // void 函数 return 表达式
  fs.writeFileSync(path.join(TMP, "syn13.fl"), "void f() { return 1; }\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn13.fl")]);
  check("语法错误: void 函数 return 表达式被拒", !r.ok && /void 函数不能 return/.test(r.stderr), r.stderr);

  // void 调用用于表达式（return 位置）
  fs.writeFileSync(path.join(TMP, "syn14.fl"), "void f() { }\nint main() { return f(); }\n");
  r = run([path.join(TMP, "syn14.fl")]);
  check("语法错误: void 调用用于表达式被拒", !r.ok && /void 函数调用不能用于表达式/.test(r.stderr), r.stderr);

  // int 函数 return;
  fs.writeFileSync(path.join(TMP, "syn15.fl"), "int main() { return; }\n");
  r = run([path.join(TMP, "syn15.fl")]);
  check("语法错误: int 函数 return; 被拒", !r.ok && /只能用在 void/.test(r.stderr), r.stderr);

  // 引用未初始化
  fs.writeFileSync(path.join(TMP, "syn16.fl"), "int main() { int x = 1; int &r; return x; }\n");
  r = run([path.join(TMP, "syn16.fl")]);
  check("语法错误: 引用未初始化被拒", !r.ok && /引用必须初始化/.test(r.stderr), r.stderr);

  // 引用绑定非变量
  fs.writeFileSync(path.join(TMP, "syn17.fl"), "int main() { int x = 1; int &r = x + 1; return x; }\n");
  r = run([path.join(TMP, "syn17.fl")]);
  check("语法错误: 引用绑定非变量被拒", !r.ok && /引用只能绑定变量/.test(r.stderr), r.stderr);

  // void 参数
  fs.writeFileSync(path.join(TMP, "syn18.fl"), "void f(void a) { }\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn18.fl")]);
  check("语法错误: void 参数被拒", !r.ok && /void 不能作参数/.test(r.stderr), r.stderr);

  // 引用形参实参非变量
  fs.writeFileSync(path.join(TMP, "syn19.fl"), "void f(int &a) { }\nint main() { f(5); return 0; }\n");
  r = run([path.join(TMP, "syn19.fl")]);
  check("语法错误: 引用形参实参非变量被拒", !r.ok && /引用形参需要变量实参/.test(r.stderr), r.stderr);

  // void main
  fs.writeFileSync(path.join(TMP, "syn20.fl"), "void main() { }\n");
  r = run([path.join(TMP, "syn20.fl")]);
  check("语法错误: void main 被拒", !r.ok && /main 必须返回 int/.test(r.stderr), r.stderr);

  // —— v0.7 指针/数组错误场景 ——
  // & 非变量
  fs.writeFileSync(path.join(TMP, "syn21.fl"), "int main() { int *p; p = &(1 + 2); return 0; }\n");
  r = run([path.join(TMP, "syn21.fl")]);
  check("语法错误: & 非变量被拒", !r.ok && /& 需要变量/.test(r.stderr), r.stderr);

  // 下标对象非数组/指针
  fs.writeFileSync(path.join(TMP, "syn22.fl"), "int main() { int x; x = 5; return x[0]; }\n");
  r = run([path.join(TMP, "syn22.fl")]);
  check("语法错误: int 变量下标被拒", !r.ok && /下标对象须为数组或指针/.test(r.stderr), r.stderr);

  // 数组整体初始化：标量初值仍被拒（v2.5.0 起 `= {…}` 合法，`= 1` 不合法）
  fs.writeFileSync(path.join(TMP, "syn23.fl"), "int main() { int a[3] = 1; return 0; }\n");
  r = run([path.join(TMP, "syn23.fl")]);
  check("语法错误: 数组标量初值被拒", !r.ok && /整体初始化必须写成/.test(r.stderr), r.stderr);

  // 数组名赋值
  fs.writeFileSync(path.join(TMP, "syn24.fl"), "int main() { int a[3]; a = 1; return 0; }\n");
  r = run([path.join(TMP, "syn24.fl")]);
  check("语法错误: 数组名赋值被拒", !r.ok && /赋值左边必须/.test(r.stderr), r.stderr);

  // 数组长度非数字
  fs.writeFileSync(path.join(TMP, "syn25.fl"), "int main() { int a[]; return 0; }\n");
  r = run([path.join(TMP, "syn25.fl")]);
  check("语法错误: 数组长度非法被拒", !r.ok && /数组长度须为数字常量/.test(r.stderr), r.stderr);

  // 引用与指针组合
  fs.writeFileSync(path.join(TMP, "syn26.fl"), "int main() { int &*x; return 0; }\n");
  r = run([path.join(TMP, "syn26.fl")]);
  check("语法错误: &* 组合被拒", !r.ok && /引用与指针不能组合/.test(r.stderr), r.stderr);

  // —— v0.7.x 结构体错误场景 ——
  // '.' 左非结构体
  fs.writeFileSync(path.join(TMP, "syn27.fl"), "int main() { int a; a = 1; return a.x; }\n");
  r = run([path.join(TMP, "syn27.fl")]);
  check("语法错误: int 变量 . 字段被拒", !r.ok && /'[.]' 左侧须为结构体变量/.test(r.stderr), r.stderr);

  // '->' 左非指针
  fs.writeFileSync(path.join(TMP, "syn28.fl"), "int main() { int a; a = 1; return a->x; }\n");
  r = run([path.join(TMP, "syn28.fl")]);
  check("语法错误: int 变量 -> 被拒", !r.ok && /'->' 左侧须为指向结构体的指针/.test(r.stderr), r.stderr);

  // 无此字段
  fs.writeFileSync(path.join(TMP, "syn29.fl"), "struct P { int x; }\nint main() { struct P p; return p.y; }\n");
  r = run([path.join(TMP, "syn29.fl")]);
  check("语法错误: 无此字段被拒", !r.ok && /无字段/.test(r.stderr), r.stderr);

  // struct 按值传参
  fs.writeFileSync(path.join(TMP, "syn30.fl"), "struct P { int x; }\nvoid f(struct P p) { }\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn30.fl")]);
  check("语法错误: struct 值传参被拒", !r.ok && /按值传参暂不支持/.test(r.stderr), r.stderr);

  // struct 重复定义
  fs.writeFileSync(path.join(TMP, "syn31.fl"), "struct P { int x; }\nstruct P { int y; }\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn31.fl")]);
  check("语法错误: struct 重复定义被拒", !r.ok && /重复定义/.test(r.stderr), r.stderr);

  // 未定义 struct 类型
  fs.writeFileSync(path.join(TMP, "syn32.fl"), "int main() { struct Q p; return 0; }\n");
  r = run([path.join(TMP, "syn32.fl")]);
  check("语法错误: 未定义 struct 被拒", !r.ok && /未定义的结构体类型/.test(r.stderr), r.stderr);

  // 嵌套字段（p.x 是 int，不能再 .）
  fs.writeFileSync(path.join(TMP, "syn33.fl"), "struct P { int x; }\nint main() { struct P p; return p.x.z; }\n");
  r = run([path.join(TMP, "syn33.fl")]);
  check("语法错误: 嵌套字段被拒", !r.ok && /'[.]' 左侧须为结构体变量/.test(r.stderr), r.stderr);

  // ===== v2.9.0（struct 值语义第一刀）：同类型整体赋值 / {0} 零初始化**通过**；
  //   通用初始化列表 {1,2} 与跨类型整体赋值**仍硬错**（本刀只开这两条，其余留后续刀）。
  //   （原来的「struct 整体赋值被拒」负例在这里改判：p = q 现在合法。）
  const syn34a = path.join(TMP, "syn34a.fl");
  const syn34aExe = path.join(TMP, "syn34a.exe");
  fs.writeFileSync(syn34a, "struct P { int x; }\nint main() { struct P p; struct P q; q.x = 7; p = q; return p.x; }\n");
  const r34a = run(["-o", syn34aExe, syn34a]);
  const r34aRun = r34a.ok ? runExe(syn34aExe) : "<编译失败>";
  fs.writeFileSync(path.join(TMP, "syn34b.fl"),
    "struct A { int a; }\nstruct B { int b; }\nint main() { struct A x; x.a = 1; struct B y = x; return 0; }\n");
  const r34b = run([path.join(TMP, "syn34b.fl")]);
  fs.writeFileSync(path.join(TMP, "syn34c.fl"),
    "struct P { int x; }\nint main() { struct P q = {1, 2}; return q.x; }\n");
  const r34c = run([path.join(TMP, "syn34c.fl")]);
  fs.writeFileSync(path.join(TMP, "syn34d.fl"),
    "struct P { int x; int y; }\nint main() { struct P p = {0}; return p.x + p.y; }\n");
  const r34d = run([path.join(TMP, "syn34d.fl")]);
  check("struct 值语义：同类型整体赋值 / {0} 通过，跨类型 / {1,2} 被拒",
    r34a.ok && r34aRun === 7 && r34d.ok
      && !r34b.ok && /同一个 struct 类型/.test(r34b.stderr || "")
      && !r34c.ok && /只支持 \{0\}/.test(r34c.stderr || ""),
    `assign=${r34a.ok}/${r34aRun} zero=${r34d.ok} cross=${r34b.ok} list=${r34c.ok}`);

  // —— v0.7.3 字符串错误场景 ——
  // 字符串未闭合
  fs.writeFileSync(path.join(TMP, "syn35.fl"), "int main() { return \"abc; }\n");
  r = run([path.join(TMP, "syn35.fl")]);
  check("语法错误: 字符串未闭合被拒", !r.ok && /字符串未闭合/.test(r.stderr), r.stderr);

  // 字符字面量多字符
  fs.writeFileSync(path.join(TMP, "syn36.fl"), "int main() { return 'ab'; }\n");
  r = run([path.join(TMP, "syn36.fl")]);
  check("语法错误: 字符字面量多字符被拒", !r.ok && /只能含一个字符/.test(r.stderr), r.stderr);

  // 未知转义
  fs.writeFileSync(path.join(TMP, "syn37.fl"), "int main() { return \"a\\qb\"; }\n");
  r = run([path.join(TMP, "syn37.fl")]);
  check("语法错误: 未知转义被拒", !r.ok && /未知转义/.test(r.stderr), r.stderr);

  // —— v0.9 own/new 错误场景 ——
  // own 拷贝初始化
  fs.writeFileSync(path.join(TMP, "syn38.fl"), "int main() {\n  int *own p = new int;\n  int *own q = p;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn38.fl")]);
  check("语法错误: own 拷贝初始化被拒", !r.ok && /禁止拷贝/.test(r.stderr), r.stderr);

  // own 重新赋值
  fs.writeFileSync(path.join(TMP, "syn39.fl"), "int main() {\n  int *own p = new int;\n  p = 0;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn39.fl")]);
  check("语法错误: own 重新赋值被拒", !r.ok && /不能重新赋值/.test(r.stderr), r.stderr);

  // own 非 new 初始化
  fs.writeFileSync(path.join(TMP, "syn40.fl"), "int main() {\n  int x = 1;\n  int *own p = &x;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn40.fl")]);
  check("语法错误: own 非 new 初始化被拒", !r.ok && /只能由 new 初始化/.test(r.stderr), r.stderr);

  // own 无初始化
  fs.writeFileSync(path.join(TMP, "syn41.fl"), "int main() {\n  int *own p;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn41.fl")]);
  check("语法错误: own 无初始化被拒", !r.ok && /必须由 new 初始化/.test(r.stderr), r.stderr);

  // 嵌套作用域 own
  fs.writeFileSync(path.join(TMP, "syn42.fl"), "int main() {\n  if (1) {\n    int *own p = new int;\n  }\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn42.fl")]);
  check("语法错误: 嵌套作用域 own 被拒", !r.ok && /函数顶层作用域/.test(r.stderr), r.stderr);

  // 数组 new
  fs.writeFileSync(path.join(TMP, "syn43.fl"), "int main() {\n  int *p = new int[2];\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn43.fl")]);
  check("语法错误: 数组 new 被拒", !r.ok && /数组 new 暂不支持/.test(r.stderr), r.stderr);

  // own 作实参
  fs.writeFileSync(path.join(TMP, "syn44.fl"), "int f(int *q) { return 0; }\nint main() {\n  int *own p = new int;\n  return f(p);\n}\n");
  r = run([path.join(TMP, "syn44.fl")]);
  check("语法错误: own 作实参被拒", !r.ok && /不能作实参/.test(r.stderr), r.stderr);

  // —— v0.9 share 错误场景 ——
  // share 从裸变量/取址初始化
  fs.writeFileSync(path.join(TMP, "syn45.fl"), "int main() {\n  int x = 1;\n  int *share p = &x;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn45.fl")]);
  check("语法错误: share 非 new/share 初始化被拒", !r.ok && /只能由 new 或 share/.test(r.stderr), r.stderr);

  // share 无初始化
  fs.writeFileSync(path.join(TMP, "syn46.fl"), "int main() {\n  int *share p;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn46.fl")]);
  check("语法错误: share 无初始化被拒", !r.ok && /必须初始化/.test(r.stderr), r.stderr);

  // 嵌套作用域 share
  fs.writeFileSync(path.join(TMP, "syn47.fl"), "int main() {\n  if (1) {\n    int *share p = new int;\n  }\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn47.fl")]);
  check("语法错误: 嵌套作用域 share 被拒", !r.ok && /函数顶层作用域/.test(r.stderr), r.stderr);

  // share 重新赋值
  fs.writeFileSync(path.join(TMP, "syn48.fl"), "int main() {\n  int *share p = new int;\n  p = 0;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn48.fl")]);
  check("语法错误: share 重新赋值被拒", !r.ok && /不能重新赋值/.test(r.stderr), r.stderr);

  // share 作实参
  fs.writeFileSync(path.join(TMP, "syn49.fl"), "int f(int *q) { return 0; }\nint main() {\n  int *share p = new int;\n  return f(p);\n}\n");
  r = run([path.join(TMP, "syn49.fl")]);
  check("语法错误: share 作实参被拒", !r.ok && /不能作实参/.test(r.stderr), r.stderr);

  // 裸变量 = share（拷贝到裸指针）
  fs.writeFileSync(path.join(TMP, "syn50.fl"), "int main() {\n  int *share p = new int;\n  int *q = p;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn50.fl")]);
  check("语法错误: share 拷贝给裸指针被拒", !r.ok && /不能拷贝给裸指针/.test(r.stderr), r.stderr);

  // —— v0.9 -safe 安全模式（内存所有权强制）——
  // 合法：new 全由 own/share 接管
  fs.writeFileSync(path.join(TMP, "syn51.fl"), "int main() {\n  int *own p = new int;\n  int *share q = new int;\n  *(p) = 1;\n  *(q) = 2;\n  if (*(p) != 1) return 1;\n  if (*(q) != 2) return 2;\n  return 0;\n}\n");
  r = run(["-safe", "-o", path.join(TMP, "syn51.exe"), path.join(TMP, "syn51.fl")]);
  check("safe 模式: own/share 接管 new 编译成功", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn51.exe"));
    check("safe 模式: 合法程序运行 EXIT=0", got === 0, `实际 ${got}`);
  }

  // 裸声明持有 new
  fs.writeFileSync(path.join(TMP, "syn52.fl"), "int main() {\n  int *p = new int;\n  return 0;\n}\n");
  r = run(["-safe", path.join(TMP, "syn52.fl")]);
  check("safe 模式: 裸声明持 new 被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  // 裸赋值持有 new
  fs.writeFileSync(path.join(TMP, "syn53.fl"), "int main() {\n  int *p;\n  p = new int;\n  return 0;\n}\n");
  r = run(["-safe", path.join(TMP, "syn53.fl")]);
  check("safe 模式: 裸赋值持 new 被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  // new 结果丢弃
  fs.writeFileSync(path.join(TMP, "syn54.fl"), "int main() {\n  new int;\n  return 0;\n}\n");
  r = run(["-safe", path.join(TMP, "syn54.fl")]);
  check("safe 模式: new 丢弃被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  // 默认模式仍允许裸 new（手动管理，见 new3 样本）
  fs.writeFileSync(path.join(TMP, "syn55.fl"), "int main() {\n  int *p = new int;\n  *(p) = 3;\n  return 0;\n}\n");
  r = run(["-o", path.join(TMP, "syn55.exe"), path.join(TMP, "syn55.fl")]);
  check("默认模式: 裸 new 仍允许（手动管理）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn55.exe"));
    check("默认模式: 裸 new 程序运行 EXIT=0", got === 0, `实际 ${got}`);
  }

  // —— v0.9.1 S5 字面量范围（十进制 ≤ INT32_MAX；十六进制 ≤ 0xFFFFFFFF 位型）——
  fs.writeFileSync(path.join(TMP, "syn56.fl"), "int main() {\n  return 99999999999;\n}\n");
  r = run([path.join(TMP, "syn56.fl")]);
  check("语法错误: 十进制溢出被拒（不再静默饱和）", !r.ok && /超出/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn57.fl"), "int main() {\n  return 2147483647;\n}\n");
  r = run(["-o", path.join(TMP, "syn57.exe"), path.join(TMP, "syn57.fl")]);
  check("边界: 十进制 INT32_MAX 编译成功", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn57.exe"));
    check("边界: 十进制 INT32_MAX 退出码 2147483647", got === 2147483647, `实际 ${got}`);
  }

  fs.writeFileSync(path.join(TMP, "syn58.fl"), "int main() {\n  return 0xFFFFFFFF;\n}\n");
  r = run(["-o", path.join(TMP, "syn58.exe"), path.join(TMP, "syn58.fl")]);
  check("边界: 十六进制 0xFFFFFFFF（32 位位型 -1）编译成功", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn58.exe"));
    check("边界: 十六进制 0xFFFFFFFF 退出码 -1", got === -1, `实际 ${got}`);
  }

  fs.writeFileSync(path.join(TMP, "syn59.fl"), "int main() {\n  return 0x100000000;\n}\n");
  r = run([path.join(TMP, "syn59.fl")]);
  check("语法错误: 十六进制超 32 位被拒", !r.ok && /超出/.test(r.stderr), r.stderr);

  // —— v0.9.1 S4 -safe 漏检修复（实参/return/条件/for 里的 new 也须被接管）——
  fs.writeFileSync(path.join(TMP, "syn60.fl"), "int f(int *q) { return 0; }\nint main() {\n  return f(new int);\n}\n");
  r = run(["-safe", path.join(TMP, "syn60.fl")]);
  check("safe 模式: f(new int) 实参泄漏被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn61.fl"), "int f() {\n  return new int;\n}\nint main() { return 0; }\n");
  r = run(["-safe", path.join(TMP, "syn61.fl")]);
  check("safe 模式: return new int 泄漏被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn62.fl"), "int main() {\n  if (new int) return 1;\n  return 0;\n}\n");
  r = run(["-safe", path.join(TMP, "syn62.fl")]);
  check("safe 模式: if 条件里 new 泄漏被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn63.fl"), "int main() {\n  for (new int; 1; ) return 1;\n  return 0;\n}\n");
  r = run(["-safe", path.join(TMP, "syn63.fl")]);
  check("safe 模式: for 初始化里 new 泄漏被拒", !r.ok && /安全模式/.test(r.stderr), r.stderr);

  // 默认模式保持 C 式自由（裸 new 不报错，手动管理）
  fs.writeFileSync(path.join(TMP, "syn64.fl"), "int f(int *q) { return 0; }\nint main() {\n  return f(new int);\n}\n");
  r = run(["-o", path.join(TMP, "syn64.exe"), path.join(TMP, "syn64.fl")]);
  check("默认模式: f(new int) 仍允许（C 式自由）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn64.exe"));
    check("默认模式: f(new int) 程序运行 EXIT=0", got === 0, `实际 ${got}`);
  }

  // —— v0.9.1 报错定位：void 误用（后遍检查）也带行号/列号上下文 ——
  fs.writeFileSync(path.join(TMP, "syn65.fl"), "void f() { }\nint main() {\n  int x = f() + 1;\n  return x;\n}\n");
  r = run([path.join(TMP, "syn65.fl")]);
  check("语法错误: void 误用带行号定位", !r.ok && /第 3 行第 \d+ 列/.test(r.stderr), r.stderr);

  // —— v0.9.2 类型层负向：指针字段禁 ++/复合赋值（32 位路径会截断 64 位字段）——
  fs.writeFileSync(path.join(TMP, "syn66.fl"), "struct S { int a; int *p; }\nint main() {\n  struct S s;\n  s.p++;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn66.fl")]);
  check("语法错误: 指针字段 ++ 被拒", !r.ok && /指针字段暂不支持/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn67.fl"), "struct S { int a; int *p; }\nint main() {\n  struct S s;\n  s.p += 8;\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn67.fl")]);
  check("语法错误: 指针字段复合赋值被拒", !r.ok && /指针字段暂不支持/.test(r.stderr), r.stderr);

  // —— v1.0.9 结构体字段直接下标：只放行「指针字段」，非指针字段/结构体值仍须拒 ——
  fs.writeFileSync(path.join(TMP, "syn68.fl"), "struct S { int n; int *p; }\nint main() {\n  struct S s;\n  return s.n[0];\n}\n");
  r = run([path.join(TMP, "syn68.fl")]);
  check("语法错误: 非指针字段下标被拒", !r.ok && /下标对象须为数组或指针/.test(r.stderr), r.stderr);

  // v2.1.0：struct 数组落地后，**标量** struct 的下标仍须拒 —— 文案改为点名的版本
  //   （旧文案是通用的「下标对象须为数组或指针」，会让人以为"struct 天生不能下标"，
  //    与新增的 a[i] 形态矛盾；这里按新口径重写断言，绝不放松）
  fs.writeFileSync(path.join(TMP, "syn69.fl"), "struct S { int n; int *p; }\nint main() {\n  struct S s;\n  return s[0];\n}\n");
  r = run([path.join(TMP, "syn69.fl")]);
  check("语法错误: 结构体值下标被拒", !r.ok && /不是数组，不能下标/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn70.fl"), "int main() {\n  return 1[0];\n}\n");
  r = run([path.join(TMP, "syn70.fl")]);
  check("语法错误: 字面量下标被拒", !r.ok && /下标需要数组名或指针变量/.test(r.stderr), r.stderr);
}

// —— 3.55 v1.0.5 char 边界负例（B 档：字节对象别名/所有权/入口暂不支持的部分明确报错）——
{
  // char 引用拒绝（&c 取址 + char* 指针已覆盖字节访问）
  fs.writeFileSync(path.join(TMP, "syn_char1.fl"), "int main() { char c = 1; char &r = c; return 0; }\n");
  let r = run([path.join(TMP, "syn_char1.fl")]);
  check("char 引用被拒（B 档边界）", !r.ok && /char 引用暂不支持/.test(r.stderr), r.stderr);

  // char own/share 拒绝（堆对象 new 仅 int）
  fs.writeFileSync(path.join(TMP, "syn_char2.fl"), "int main() { char *own p = new int; return 0; }\n");
  r = run([path.join(TMP, "syn_char2.fl")]);
  check("char own 被拒（所有权只修饰 int*）", !r.ok && /只能修饰 int\*/.test(r.stderr), r.stderr);

  // main 返回 char 拒绝（退出码语义须 int）
  fs.writeFileSync(path.join(TMP, "syn_char3.fl"), "char main() { return 0; }\n");
  r = run([path.join(TMP, "syn_char3.fl")]);
  check("char main 被拒（main 必须 int）", !r.ok && /main 必须返回 int/.test(r.stderr), r.stderr);

  // ===== v2.12.0（S2）：char 指针字段已支持 ⇒ 旧负例必须改判（功能落地后旧负例不许留着假红）=====
  //   改判成一条**正例**（编译 + 运行验值），同时保留一条真边界：指针**数组**字段仍明确拒收
  //   （struct S { char *p[2]; } —— 静默按单指针布局会越界写坏下一个字段）。
  fs.writeFileSync(path.join(TMP, "syn_char4.fl"),
    "struct S { char *p; int n; }\nint main() {\n  struct S s;\n  s.p = \"ok\";\n  s.n = 1;\n"
    + "  if (s.p[0] != 'o') return 2;\n  return s.n;\n}\n");
  const char4exe = path.join(TMP, "syn_char4.exe");
  r = run(["-o", char4exe, path.join(TMP, "syn_char4.fl")]);
  fs.writeFileSync(path.join(TMP, "syn_char4b.fl"), "struct S { char *p[2]; }\nint main() { return 0; }\n");
  let r4b = run([path.join(TMP, "syn_char4b.fl")]);
  check("char 指针字段已支持（v2.12.0：编译 + 字段读；指针数组字段仍被拒）",
        r.ok && runExe(char4exe) === 1
        && !r4b.ok && /struct 指针字段暂不支持数组形态/.test(r4b.stderr),
        r.stderr + r4b.stderr);
}

// —— 3.56 v1.0.6 函数返回指针负例（入口/main、void* 明确拒收）；v2.14.0 起 struct 按值返回为正例 ——
{
  // int* main 拒绝（入口退出码须 int）
  fs.writeFileSync(path.join(TMP, "syn_rt1.fl"), "int *main() { return 0; }\n");
  let r = run([path.join(TMP, "syn_rt1.fl")]);
  check("int* main 被拒（main 必须返回 int）", !r.ok && /main 必须返回 int/.test(r.stderr), r.stderr);

  // v2.14.0：struct 按值返回**已开放**（本项原为「须指针返回」负例，按项目惯例改判成正例）
  fs.writeFileSync(path.join(TMP, "syn_rt2.fl"),
    "struct P { int x; int y; }\nstruct P mk(int a, int b) { struct P p; p.x = a; p.y = b; return p; }\n" +
    "int main() { struct P q = mk(3, 4); if (q.x == 3 && q.y == 4) return 42; return 1; }\n");
  r = run(["-run", "-o", path.join(TMP, "syn_rt2.exe"), path.join(TMP, "syn_rt2.fl")]);
  check("struct 按值返回可编译且值正确（v2.14.0）", !r.ok && r.code === 42, r.stderr || ("exit=" + r.code));

  // void* 拒绝
  fs.writeFileSync(path.join(TMP, "syn_rt3.fl"), "void *f() { }\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn_rt3.fl")]);
  check("void* 返回被拒", !r.ok && /void 不能返回指针/.test(r.stderr), r.stderr);
}

// —— 3.57 v1.0.6.2 盲区审计 A3：return own/share = 所有权逃逸拒收（防悬垂）——
{
  fs.writeFileSync(path.join(TMP, "syn_a3u.fl"), "int *mk() {\n  int *own p = new int;\n  return p;\n}\nint main() { return 0; }\n");
  let r = run([path.join(TMP, "syn_a3u.fl")]);
  check("return own 指针被拒（出口释放 → 悬垂）", !r.ok && /own 指针不能作 return/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn_a3s.fl"), "int *mk() {\n  int *share p = new int;\n  return p;\n}\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn_a3s.fl")]);
  check("return share 指针被拒（caller 无 +1 → 悬垂）", !r.ok && /share 指针不能作 return/.test(r.stderr), r.stderr);
}

// —— 3.58 v1.0.6.2 盲区审计 A6：负/零/巨长数组长拒收（巨长 = 帧槽累计溢出防护）——
{
  fs.writeFileSync(path.join(TMP, "syn_a6z.fl"), "int main() {\n  int a[0];\n  return 0;\n}\n");
  let r = run([path.join(TMP, "syn_a6z.fl")]);
  check("数组长 0 被拒（数组长度须为正数）", !r.ok && /数组长度须为正数/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn_a6n.fl"), "int main() {\n  int a[-3];\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn_a6n.fl")]);
  check("数组长负数被拒（长度须为数字常量）", !r.ok, r.stderr);

  fs.writeFileSync(path.join(TMP, "syn_a6c.fl"), "int main() {\n  char a[0];\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn_a6c.fl")]);
  check("char 数组长 0 被拒", !r.ok && /数组长度须为正数/.test(r.stderr), r.stderr);

  fs.writeFileSync(path.join(TMP, "syn_a6h.fl"), "int main() {\n  int a[2000000000];\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn_a6h.fl")]);
  check("巨长数组被拒（帧槽累计超 2GB 上限）", !r.ok && /总长过大/.test(r.stderr), r.stderr);
}

// —— 3.58 v1.0.11 ^^ 幂运算符负例（^^= 复合赋值未支持 → 语法错）——
{
  fs.writeFileSync(path.join(TMP, "syn_pow1.fl"), "int main() {\n  int x = 2;\n  x ^^= 3;\n  return x;\n}\n");
  const r = run([path.join(TMP, "syn_pow1.fl")]);
  check("^^= 复合赋值未支持被拒（语法错）", !r.ok && /期望数字\/变量/.test(r.stderr), r.stderr);
}

// —— 3.59 v1.0.8 print 内建负例（段类型边界 + 换行参数校验 + 非内建形态不受影响）——
{
  // int 数组整体打印拒绝（逐元素）
  fs.writeFileSync(path.join(TMP, "syn_p1.fl"), "int main() {\n  int a[3];\n  print([a]);\n  return 0;\n}\n");
  let r = run([path.join(TMP, "syn_p1.fl")]);
  check("print: int 数组整体打印被拒", !r.ok && /int 数组不能整体打印/.test(r.stderr), r.stderr);

  // int* 指针直接打印拒绝（仅 char* 串）
  fs.writeFileSync(path.join(TMP, "syn_p2.fl"), "int main() {\n  int x = 5;\n  int *p = &x;\n  print([p]);\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn_p2.fl")]);
  check("print: int* 直接打印被拒", !r.ok && /该指针暂不支持直接打印/.test(r.stderr), r.stderr);

  // 换行第二参须 0/1 常量
  fs.writeFileSync(path.join(TMP, "syn_p3.fl"), "int main() {\n  int k = 1;\n  print([\"x\"], k);\n  return 0;\n}\n");
  r = run([path.join(TMP, "syn_p3.fl")]);
  check("print: 换行参数须 0/1 常量", !r.ok && /换行参数须为 0\/1 常量/.test(r.stderr), r.stderr);

  // 合法：单段/多段/省略换行参数照常（回归 print 主路径）
  fs.writeFileSync(path.join(TMP, "syn_p4.fl"), "int main() {\n  print([\"ok\\n\"]);\n  print([1, 2, 3]);\n  return 0;\n}\n");
  r = run(["-o", path.join(TMP, "syn_p4.exe"), path.join(TMP, "syn_p4.fl")]);
  check("print: 多段编译成功", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
}

// —— 3.60 v1.0.8：API 同名幂等去重 + print 注入与用户 api 共存（boot dogfood 修的两个 bug）——
{
  // api 同名同签名 = 幂等忽略（多文件库各自带 api 声明场景）
  fs.writeFileSync(path.join(TMP, "syn_api1.fl"), "api kernel32 int GetTickCount();\napi kernel32 int GetTickCount();\nint main() { return 0; }\n");
  let r = run(["-o", path.join(TMP, "syn_api1.exe"), path.join(TMP, "syn_api1.fl")]);
  check("api 同名同签名幂等忽略（编译成功）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));

  // api 同名不同签名 = 冲突报错（防静默调错）
  fs.writeFileSync(path.join(TMP, "syn_api2.fl"), "api kernel32 int GetTickCount();\napi kernel32 int GetTickCount(int);\nint main() { return 0; }\n");
  r = run([path.join(TMP, "syn_api2.fl")]);
  check("api 同名不同签名报冲突", !r.ok && /签名不一致/.test(r.stderr), r.stderr);

  // print 懒注入（内置 WriteFile）+ 用户自带同名 api = 共存（boot b1_emit.fl 场景回归）
  fs.writeFileSync(path.join(TMP, "syn_api3.fl"), "api kernel32 int WriteFile(int, int, int, int, int);\nint main() {\n  print([\"x\\n\"]);\n  return 0;\n}\n");
  r = run(["-o", path.join(TMP, "syn_api3.exe"), path.join(TMP, "syn_api3.fl")]);
  check("print 注入与用户自带同名 api 共存（编译成功）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
}

// —— 3.5 多文件编译 + include（v1.0.3）——
{
  // 多文件：跨文件函数调用 / 库文件自带 api / 结构体跨文件（定义放最前的文件）
  const mfCases = [
    { files: ["mf_main.fl", "mf_lib.fl"], expect: 34, note: "跨文件函数调用" },
    { files: ["mf_api_main.fl", "mf_api_lib.fl"], expect: 7, note: "库文件自带 api 声明被前移" },
    { files: ["mf_struct_lib.fl", "mf_struct_main.fl"], expect: 42, note: "结构体定义+使用分文件" },
  ];
  let mi = 0;
  for (const c of mfCases) {
    const exe = path.join(TMP, `mfcase${mi++}.exe`);
    const srcs = c.files.map((f) => path.join(SAMPLES, f));
    const r = run(["-o", exe, ...srcs]);
    const label = c.files.join(" + ");
    check(`多文件编译 ${label}`, r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (!r.ok) continue;
    check(`多文件产物 MZ 头 ${label}`, fs.readFileSync(exe).slice(0, 2)[0] === 0x4d);
    const got = runExe(exe);
    check(`多文件运行 ${c.note} 退出码`, got === c.expect, `实际 ${got}`);
  }

  // include：指令拼接（相对本文件目录解析）+ 库自带 api
  {
    const exe = path.join(TMP, "inc_main.exe");
    const r = run(["-o", exe, path.join(SAMPLES, "inc_main.fl")]);
    check("include 编译成功（inc_lib.fl 被拼接）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (r.ok) {
      const got = runExe(exe);
      check("include 运行退出码 21", got === 21, `实际 ${got}`);
    }
  }

  // include 错误定位：被包含文件内的语法错应报在它自己的文件名上
  {
    const r = run([path.join(SAMPLES, "inc_err_main.fl")]);
    check("include 库内语法错被拒", !r.ok);
    check("include 库内错误定位到 inc_err_lib.fl", !r.ok && /inc_err_lib\.fl/.test(r.stderr), r.stderr);
  }

  // include 缺失文件：报错带 include 指令所在位置
  {
    fs.writeFileSync(path.join(TMP, "inc_missing.fl"), 'include "no_such_lib.fl"\nint main() { return 0; }\n');
    const r = run([path.join(TMP, "inc_missing.fl")]);
    check("include 缺失文件被拒", !r.ok && /include 文件不存在/.test(r.stderr), r.stderr);
    check("include 缺失报错定位到 include 行", !r.ok && /inc_missing\.fl 第 1 行/.test(r.stderr), r.stderr);
  }

  // B2v：循环 include 仍必须报错（去重只跳「已展开完」，不能把循环静默吞掉）
  {
    const r = run([path.join(SAMPLES, "inc_cycle_a.fl")]);
    check("B2v 循环 include 被拒", !r.ok && /循环引用/.test(r.stderr), r.stderr && r.stderr.trim().slice(0, 120));
  }
}

// —— 4. 编译产物独立可执行性（不依赖任何外部工具）——
{
  // 用 edge5（32位）验证：产物 exe 大小合理且头部完整
  const exe = path.join(TMP, "edge5.exe");
  const size = fs.statSync(exe).size;
  check("产物大小合理 (>900B)", size > 900, `实际 ${size}B`);
}

// —— v0.7.3 数据段字节验证（字符串真实落进 PE，外部可读）——
{
  const exe1 = fs.readFileSync(path.join(TMP, "str1.exe"));
  check("数据段含 AB\\0C\\0 序列", exe1.indexOf(Buffer.from([0x41, 0x42, 0, 0x43, 0])) >= 0);
  const exe3 = fs.readFileSync(path.join(TMP, "str3.exe"));
  check("数据段含 A\\nB\\0 序列（转义已解码）", exe3.indexOf(Buffer.from([0x41, 10, 0x42, 0])) >= 0);
}

// —— v0.8 API 声明验证 ——
{
  // api1：MessageBoxA 弹窗样本——只编译 + 结构验证（不自动运行，避免阻塞；手动冒烟看实体）
  const exe1 = path.join(TMP, "api1.exe");
  const r1 = run(["-o", exe1, path.join(SAMPLES, "api1.fl")]);
  check("api1 编译成功（user32!MessageBoxA）", r1.ok, r1.stderr && r1.stderr.trim().slice(0, 120));
  if (r1.ok) {
    const buf1 = fs.readFileSync(exe1).toString("latin1");
    check("api1 导入表含 user32.dll", buf1.includes("user32.dll"));
    check("api1 导入表含 MessageBoxA", buf1.includes("MessageBoxA"));
    check("api1 导入表仍含 ExitProcess", buf1.includes("ExitProcess"));
    check("api1 字符串进数据段", buf1.includes("FLINT v0.8"));
  }
}

// —— v0.9 new/own 产物导入表证据（懒登记 + own 出口清理）——
{
  const exe1 = fs.readFileSync(path.join(TMP, "new1.exe"));
  check("new1 导入表含 VirtualAlloc（new 懒登记）", exe1.toString("latin1").includes("VirtualAlloc"));
  check("new1 导入表含 VirtualFree（own 出口清理）", exe1.toString("latin1").includes("VirtualFree"));
  const exe2 = fs.readFileSync(path.join(TMP, "str7.exe"));
  check("纯算数 exe 不导入堆 API（懒登记零污染）", !exe2.toString("latin1").includes("VirtualAlloc"));
}

// —— v1.0.12 评审清单修复回归（真 bug 1/1b/2 + 假绿自检）——
// 来源：2026-09-10 第三方评审（FLINT-问题清单），三个真 bug 都在测试覆盖不到的角落；
// 本块把复现代码钉成防线，并给「超时假绿」补一条元断言。
{
  // 【1】地址链 int 在左（i + p）——修前 0xC0000005
  {
    const exe = path.join(TMP, "rev1.exe");
    const r = run(["-o", exe, path.join(SAMPLES, "rev1.fl")]);
    check("rev1 编译成功（地址链 int 在左）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (r.ok) {
      const got = runExe(exe);
      check("rev1 退出码 63（6 项地址链符号扩展全对）", got === 63, `实际 ${got}`);
    }
  }
  // 【1b】64 位比较中 int 一侧符号扩展
  {
    const exe = path.join(TMP, "rev2.exe");
    const r = run(["-o", exe, path.join(SAMPLES, "rev2.fl")]);
    check("rev2 编译成功（64 位混合比较）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (r.ok) {
      const got = runExe(exe);
      check("rev2 退出码 7（负 int 与栈地址比较方向正确）", got === 7, `实际 ${got}`);
    }
  }
  // 【2】内部函数调用点 16 字节对齐——字节层断言（v1.4.26 口径更新）
  //   ⚠️ 为什么改口径：M5 ②「放开条件⑤」后，8 字节垫平有了**两种**来源 ——
  //     ① **序言垫**：分配到的 callee-saved 寄存器个数为奇数 ⇒ 整函数补一次（两条指令），
  //        此后函数内每个调用点天然 ≡0；② **每调用点垫**：老的那种（"先 push 再 call"必须补平）。
  //     rev3 里两者都在（1009 序言垫 → call；1012 push rax → 1013 垫平 → call），所以旧断言
  //     "垫平序列恰好 1 次、且紧跟在 call 后回收"会把正确的产物判红（判据过期，不是产物坏了）。
  //   现在的断言保的是**意图**：a) "先压栈再调用"处必须补平；b) 每个垫平都要被回收（不泄漏栈调整）。
  //   ⚠️ 对齐不变式本身由**编译器**在每次编译时断言（codegen 的 g_rspm：每个 call 发射点必须 ≡0，
  //      1009 项回归里任何样本违反都会当场报内部错误）——这里是产物侧的形状旁证。
  {
    const exe = path.join(TMP, "rev3.exe");
    const r = run(["-o", exe, path.join(SAMPLES, "rev3.fl")]);
    check("rev3 编译成功（g() + g()）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (r.ok) {
      const b = fs.readFileSync(exe);
      const countSeq = (seq) => {
        let n = 0;
        for (let i = 0; i + seq.length <= b.length; i++) {
          let hit = true;
          for (let j = 0; j < seq.length; j++) if (b[i + j] !== seq[j]) { hit = false; break; }
          if (hit) n++;
        }
        return n;
      };
      const pushPadCall = [0x50, 0x48, 0x83, 0xec, 0x08, 0xe8];   // push rax → sub rsp,8 → call
      const padSub      = [0x48, 0x83, 0xec, 0x08];               // sub rsp,8
      const padAdd      = [0x48, 0x83, 0xc4, 0x08];               // add rsp,8
      const nPushPad = countSeq(pushPadCall), nSub = countSeq(padSub), nAdd = countSeq(padAdd);
      check("rev3 「先压栈再调用」处有 8 字节垫平（rsp≡0）", nPushPad === 1, `垫平序列 ${nPushPad} 处`);
      check("rev3 8 字节垫平与回收一一配对（不泄漏栈调整）", nSub === nAdd && nSub >= 1, `垫平 ${nSub} / 回收 ${nAdd}`);
      check("rev3 运行退出码 0", runExe(exe) === 0);
    }
  }
  // 【6】假绿自检：死循环必须被判失败，而不是被当成「干净退出 0」
  {
    const src = path.join(TMP, "hang.fl");
    const exe = path.join(TMP, "hang.exe");
    fs.writeFileSync(src, "int main() {\n  int i = 0;\n  while (1) { i = i + 1; }\n  return 0;\n}\n");
    const r = run(["-o", exe, src]);
    check("假绿自检样本编译成功", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
    if (r.ok) {
      const got = _runExeTimed(exe, 1500, false).code;   // 短超时，别拖慢回归
      check("超时被判失败而非退出码 0（假绿防线）", got === TIMEOUT_SENTINEL, `实际 ${got}`);
    }
  }
}

// —— v1.0.13 T1：int 装地址的自动适配（用户拍板「编译器自己判断」）+ 拿不准就报错 ——
{
  // 正面：int 槽装地址 → 8 字节存/读、函数内转手、地址差不标记（位掩码 = 127）
  const exe = path.join(TMP, "rev4.exe");
  const r = run(["-o", exe, path.join(SAMPLES, "rev4.fl")]);
  check("rev4 编译成功（int 装地址自动适配）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(exe);
    check("rev4 退出码 127（存满/读满/转手/符号扩展/地址链/地址差 7 项全对）", got === 127, `实际 ${got}`);
  }
  // 负面：拿不准 / 装不下的写法必须**编译期报错**（不再静默截断或读到残渣）
  const negs = [
    ["间接 int 元素装地址被拒（4 字节装不下）", 'int main() { int a[4]; a[0] = "AB"; return 0; }\n', /装不进 4 字节/],
    ["结构体 int 字段装地址被拒", 'struct S { int f; }\nint main() { struct S s; s.f = "AB"; return 0; }\n', /装不进 4 字节/],
    ["未标记 int 当指针用被拒（会读到残渣）", "int main() { int n = 5; int *p = n; return *p; }\n", /指针目标只能接/],
    ["int 返回函数当指针用被拒（跨函数只有低 32 位）", "int f() { return 5; }\nint main() { int *q = f(); return *q; }\n", /指针目标只能接/],
    // slot4：本地 int 只有 4 字节，地址值根本装不进去（前两条已覆盖）；这一条测「int 值参与算术后当指针用」仍被拦。
    ["int 参与算术的地址链当指针用被拒（按 32 位算）", 'int main() { int s = 0; int *q = s + 8; return *q; }\n', /指针目标只能接/],
  ];
  negs.forEach(([name, src, re], i) => {
    const p = path.join(TMP, `t1neg${i}.fl`);
    fs.writeFileSync(p, src);
    const rr = run([p]);
    check(`T1 负例：${name}`, !rr.ok && re.test(rr.stderr || ""), (rr.stderr || "").split("\n")[1] || "");
  });
}

// —— v1.0.13 新发现真 bug：地址链解引用的读写宽度（char* 链必须按字节）——
// 旧实现 `*(charPtr + n)` 按 int 读 4 字节 / 写 4 字节（读带出邻字节、写踩坏邻字节）
{
  const exe = path.join(TMP, "rev5.exe");
  const r = run(["-o", exe, path.join(SAMPLES, "rev5.fl")]);
  check("rev5 编译成功（地址链解引用宽度）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(exe);
    check("rev5 退出码 255（链上读 1 字节 + 链上写不踩邻居 8 项全对）", got === 255, `实际 ${got}`);
  }
}

// —— v1.1.0 浮点 bug (a)：声明带初始化绕过 double→int 检查（+ 修后必须仍拦得住的反向）——
// 实证（2026-09-12，副本）：`int n = 7.5;` 编译通过 → print 打出 1073745920（0x40000000，
// double 位模式漏进 int 槽）；赋值路径 `int n; n = 7.5;` 拦得住 —— 只差"声明路径没过 asgn_rhs"这一处。
{
  fs.writeFileSync(path.join(TMP, "syn_d1.fl"), "int main() { int n = 7.5; return 0; }\n");
  let r = run([path.join(TMP, "syn_d1.fl")]);
  check("声明带初始化：int n = 7.5; 必须编译期报错（不能静默截断/漏位模式）",
    !r.ok && /不能把 double 赋给 int/.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");

  fs.writeFileSync(path.join(TMP, "syn_d2.fl"), "int main() { char c = 2.5; return 0; }\n");
  r = run([path.join(TMP, "syn_d2.fl")]);
  check("声明带初始化：char c = 2.5; 同样必须报错（同一条路径）",
    !r.ok && /不能把 double 赋给 int/.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");

  // 修完不能误伤合法写法：double 左值接 int 右值 = 自动提升（C 语义）
  fs.writeFileSync(path.join(TMP, "syn_d3.fl"), "int main() { double d = 2; d = d + 1; return to_int(d); }\n");
  r = run(["-o", path.join(TMP, "syn_d3.exe"), path.join(TMP, "syn_d3.fl")]);
  check("反向不误伤：double d = 2; 仍自动提升（编译成功）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(path.join(TMP, "syn_d3.exe"));
    check("反向不误伤：to_int(d) = 3", got === 3, `实际 ${got}`);
  }
}

// —— v1.2.0 循环控制：break / continue（C 语义，只管最内层循环）——
// 样本 loopctl1.fl = 8 项位掩码（break 跳出 / while 里 continue / for 里 continue 必须先走增量 /
//   for 里 break / 嵌套只管最内层 / break 后同块语句不执行 / continue 不影响外层 / 内层 break 外层继续）
{
  const exe = path.join(TMP, "loopctl1.exe");
  const r = run(["-o", exe, path.join(SAMPLES, "loopctl1.fl")]);
  check("loopctl1 编译成功（break/continue）", r.ok, r.stderr && r.stderr.trim().slice(0, 120));
  if (r.ok) {
    const got = runExe(exe);
    check("loopctl1 退出码 255（8 项位掩码全中；含 for 的 continue 走增量、嵌套只管最内层）",
      got === 255, `实际 ${got}`);
  }

  // 负例：循环外使用必须编译期报错（不静默跳到底）
  fs.writeFileSync(path.join(TMP, "nb_break1.fl"), "int main() {\n  break;\n  return 0;\n}\n");
  let rr = run([path.join(TMP, "nb_break1.fl")]);
  check("负例：循环外 break 编译期报错", !rr.ok && /break 只能用在循环/.test(rr.stderr || ""),
    (rr.stderr || "").split("\n")[1] || "");

  fs.writeFileSync(path.join(TMP, "nb_cont1.fl"), "int f() {\n  continue;\n  return 0;\n}\nint main() { return f(); }\n");
  rr = run([path.join(TMP, "nb_cont1.fl")]);
  check("负例：循环外 continue 编译期报错", !rr.ok && /continue 只能用在循环里/.test(rr.stderr || ""),
    (rr.stderr || "").split("\n")[1] || "");

  // 专项：for 的 continue 若错接到循环头（跳过增量）→ i 永为 0 → 死循环（超时哨兵抓）
  fs.writeFileSync(path.join(TMP, "for_cont.fl"),
    "int main() {\n  int s = 0;\n  int i = 0;\n  for (i = 0; i < 6; i = i + 1) {\n    if (i % 2 == 1) continue;\n    s = s + i;\n  }\n  return s;\n}\n");
  const r2 = run(["-o", path.join(TMP, "for_cont.exe"), path.join(TMP, "for_cont.fl")]);
  check("for 里 continue 编译成功", r2.ok, r2.stderr && r2.stderr.trim().slice(0, 120));
  if (r2.ok) {
    const got2 = runExe(path.join(TMP, "for_cont.exe"));   // 死循环会拿到 TIMEOUT_SENTINEL，不是 6
    check("for 里 continue 先执行增量（退出码 6，不是死循环）", got2 === 6, `实际 ${got2}`);
  }
}

// —— v1.2.1 double 阶段2 第一口：函数返回 double（+ 同常量多次出现的回填修复）——
// 样本：dblret1.fl（返回 double 的 6 项位掩码 = 127）、dblconst1.fl（同一 double 常量出现多次 = 127）
{
  const checks = [
    ["dblret1", 127, "函数返回 double：直接返回 / int 自动提升 / 参与算术 / 作实参 / 返回值比较 / 隐式返回 0.0"],
    ["dblconst1", 127, "同一 double 常量出现多次：每处 movsd 的 disp 都要各自回填（曾静默读成 0.0）"],
  ];
  for (const [name, expect, note] of checks) {
    const exe = path.join(TMP, name + ".exe");
    const r = run(["-o", exe, path.join(SAMPLES, name + ".fl")]);
    check(`${name} 编译成功（${note}）`, r.ok, r.stderr && r.stderr.trim().slice(0, 140));
    if (r.ok) {
      const got = runExe(exe);
      check(`${name} 退出码 ${expect}（${note}）`, got === expect, `实际 ${got}`);
    }
  }

  // 负例 1：int 返回函数返回 double 值 → 必须编译期报错（不能静默截断小数）
  fs.writeFileSync(path.join(TMP, "nb_dblret1.fl"), "int f() { return 1.5; }\nint main() { return f(); }\n");
  let rr = run([path.join(TMP, "nb_dblret1.fl")]);
  check("负例：int 返回函数 return double → 编译期报错（不静默截断）",
    !rr.ok && /不能把 double 值 return 给 int 返回函数/.test(rr.stderr || ""),
    (rr.stderr || "").split("\n")[1] || "");

  // 负例 1b：显式 to_int 的写法不能被误伤（合法路径）
  fs.writeFileSync(path.join(TMP, "dblret_ok.fl"),
    "int f() { return to_int(1.5); }\nint main() { return f(); }\n");
  rr = run(["-o", path.join(TMP, "dblret_ok.exe"), path.join(TMP, "dblret_ok.fl")]);
  check("反向不误伤：return to_int(1.5) 编译成功", rr.ok, rr.stderr && rr.stderr.trim().slice(0, 120));
  if (rr.ok) {
    const got = runExe(path.join(TMP, "dblret_ok.exe"));
    check("反向不误伤：to_int(1.5) = 1", got === 1, `实际 ${got}`);
  }

  // —— v1.2.2 double 阶段2 第二步：函数**形参 double**（值走 XMM0-3，与 int 形参的 GP 并行计数）——
  // 样本 dblparam1.fl = 8 项位掩码 255（单参 / int+double 混参 / double 在前 int 在后 /
  //   四个 double 用满 XMM0-3 / 形参转手 / 形参走 double 比较 / int 实参自动提升 / 嵌套调用当实参）
  {
    const exe = path.join(TMP, "dblparam1.exe");
    const r = run(["-o", exe, path.join(SAMPLES, "dblparam1.fl")]);
    check("dblparam1 编译成功（double 形参：值走 XMM0-3，int 形参走 rcx/rdx/r8/r9）", r.ok,
      r.stderr && r.stderr.trim().slice(0, 140));
    if (r.ok) {
      const got = runExe(exe);
      check("dblparam1 退出码 255（8 项位掩码全中）", got === 255, `实际 ${got}`);
    }
  }

  // 前向调用：main 在前、double 形参函数**定义在后** → 预扫描必须记形参类型
  // （漏预扫描时调用点把形参当 int：int 实参不提升 → 走 rax 而值应走 xmm0 → 静默传垃圾）
  fs.writeFileSync(path.join(TMP, "dblparam_fwd.fl"),
    "int main() { return to_int(half(5)); }\ndouble half(double x) { return x / 2.0; }\n");
  rr = run(["-o", path.join(TMP, "dblparam_fwd.exe"), path.join(TMP, "dblparam_fwd.fl")]);
  check("前向调用 double 形参函数：编译成功（预扫描记形参类型）", rr.ok,
    rr.stderr && rr.stderr.trim().slice(0, 140));
  if (rr.ok) {
    const got = runExe(path.join(TMP, "dblparam_fwd.exe"));
    check("前向调用：to_int(half(5)) = 2（形参真拿到 5，不是垃圾）", got === 2, `实际 ${got}`);
  }

  // 负例 2a/2b（**v1.2.5 已转正**）：double* / double& 形参现在是真支持 —— 不能只开语法不给语义，
  //   正例见 test/samples/dblptr1.fl 第 ⑧（double* 形参与返回）、⑬⑭⑮⑯（double& 读/写/复合/当实参）项。
  //   该拦的改在 rc 侧：double* 接 32 位值、double& 绑 int 变量（见下方 v1.2.5 新负例）。

  // 负例 3：double 实参传给 **int** 形参 → 编译期报错（不静默截断小数；红线同 `int n = 7.5`）
  fs.writeFileSync(path.join(TMP, "nb_dblarg2.fl"),
    "int put(int x) { return x; }\nint main() { double d = 1.5; return put(d); }\n");
  rr = run([path.join(TMP, "nb_dblarg2.fl")]);
  check("负例：double 实参传给 int 形参 → 编译期报错（不静默截断）",
    !rr.ok && /这个形参是 int/.test(rr.stderr || ""), (rr.stderr || "").split("\n")[1] || "");

  // 负例 4（v1.2.3 已转正）：double 值直接 print 过去是编译期报错，现在是**真支持**——
  //   正例见 test/samples/dblprint1.fl（stdout 逐字比对 + 退出码 15），此处不再有负例。

  // 负例 5（**v1.2.5 已转正**）：double* 指针返回现在真支持（ret_elem 记 TY_DOUBLE，前向调用也认）——
  //   正例见 dblptr1.fl 第 ⑧⑨ 项（`*pick(a,0)` 与 `double *w = pick(a,2)` 后再解引用）。
}

// —— v1.2.4 浮点阶段2 收尾：复合赋值 / double 数组 / 结构体 double 字段 的负例 ——
// 每条都挑「只有修好才可能过」的观察点：浮点走到整数路径时**不会报错**（静默错值），所以这些负例
// 是把"静默"钉成"编译期报错"的防线；正例见 samples/dblcompound1.fl 与 dblfield1.fl。
{
  const cases = [
    ["nb_dbl_mod.fl", "int main() { double d = 4.0; d %= 2.0; return 0; }\n",
      /double 只支持 \+= -= \*= \//, "double 的 %= → 编译期报错（浮点无取模）"],
    ["nb_dbl_bit.fl", "int main() { double d = 4.0; d &= 2.0; return 0; }\n",
      /double 只支持 \+= -= \*= \//, "double 的 &= → 编译期报错（位运算只对整数）"],
    ["nb_int_dbladd.fl", "int main() { int n = 1; n += 1.5; return n; }\n",
      /不能把 double 赋给 int/, "int 左值复合赋值收 double 右值 → 编译期报错（不静默截断）"],
    ["nb_dbl_inc1.fl", "int main() { double d = 1.0; d++; return 0; }\n",
      /double 的 \+\+\/-- 暂不支持/, "double 变量 ++ → 编译期报错（否则走整数 32 位路径 = 静默错值）"],
    ["nb_dbl_inc2.fl", "int main() { double a[2]; a[0] = 1.0; a[0]++; return 0; }\n",
      /double 的 \+\+\/-- 暂不支持/, "double 数组元素 ++ → 编译期报错"],
    ["nb_dbl_inc3.fl", "struct S { double d; }\nint main() { struct S s; s.d = 1.0; --s.d; return 0; }\n",
      /double 的 \+\+\/-- 暂不支持/, "double 字段 -- → 编译期报错"],
    // —— v1.2.5：double 指针/引用**开放之后**新该拦的（指向类型/别名类型不匹配 = 静默错值）——
    ["nb_dblptr_intvar.fl", "int main() { int n = 0; double *p = n; return 0; }\n",
      /指针目标只能接/, "double* ← int 变量（32 位值当指针）→ 编译期报错"],
    ["nb_dblptr_val.fl", "int main() { double d = 1.5; double *p = d; return 0; }\n",
      /不能把 double 赋给 int|指针目标只能接/, "double* ← double 值（值不是地址）→ 编译期报错"],
    ["nb_dblref_intvar.fl", "int main() { int n = 3; double &r = n; return 0; }\n",
      /double 引用只能绑定 double 变量/, "double& 绑 int 变量（按 8 字节读会读到别的位型）→ 编译期报错"],
    ["nb_intref_dblvar.fl", "int main() { double d = 1.5; int &r = d; return 0; }\n",
      /int 引用不能绑定 double 变量/, "int& 绑 double 变量（按 32 位读错值）→ 编译期报错"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const r = run([path.join(TMP, name)]);
    check(`负例：${label}`, !r.ok && re.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");
  }
}

// —— v1.3.0 全局变量负例 ——
// 每条都钉住「要么明确报错、要么不静默错值」的边界。全局变量的危险在于它落在**另一个节**里：
// 宽度/步长/偏移三样只要有一样与代码侧口径不一致，都是"编译过、静默写坏别处"（本项工程实测踩到三个）。
{
  const cases = [
    ["ng_dup.fl", "int g = 1;\nint g = 2;\nint main() { return g; }\n",
      /全局变量 'g' 重复声明/, "同名全局变量重复声明 → 编译期报错"],
    ["ng_nonconst.fl", "int n = 3;\nint g = n;\nint main() { return g; }\n",
      /初值必须是编译期常量/, "全局初值用变量（运行时才有值）→ 编译期报错"],
    ["ng_call_init.fl", "int f() { return 1; }\nint g = f();\nint main() { return g; }\n",
      /初值必须是编译期常量/, "全局初值用函数调用 → 编译期报错"],
    ["ng_fn_conflict.fl", "int f() { return 1; }\nint f = 2;\nint main() { return f; }\n",
      /与同名全局变量冲突/, "全局变量与同名函数冲突（函数在前）→ 编译期报错"],
    // 反序也必须拦：`int f = 2;` 在前时 collect_globals 看不见后面的函数定义，
    //   检查落在 parse_funcdef 里才拦得住（实测漏网过：两序都编译通过，`return f;` 被当函数调用）
    ["ng_fn_conflict2.fl", "int f = 2;\nint f() { return 1; }\nint main() { return f; }\n",
      /与同名全局变量冲突/, "全局变量与同名函数冲突（变量在前，反序）→ 编译期报错"],
    ["ng_arr_len0.fl", "int a[0];\nint main() { return 0; }\n",
      /长度必须为正/, "全局数组长度为 0 → 编译期报错"],
    ["ng_arr_many.fl", "int a[2] = {1, 2, 3};\nint main() { return a[0]; }\n",
      /初值元素比声明长度多/, "全局数组初值元素多于声明长度 → 编译期报错（不静默丢弃）"],
    // v1.10.0（IDE 服务端）：指针全局已开放 ⇒ 旧的「必须报错」负例失效，
    //   换成同族里**仍然成立**的一条真边界：指针全局不能写成数组（那语义是「4 个指针」）。
    ["ng_ptr_arr.fl", "int *gp[4];\nint main() { return 0; }\n",
      /指针全局不支持数组形式/, "指针全局写成数组形式 → 编译期明确报错"],
    // v2.13.0（S3）：**struct 按值全局变量**已开放（`struct S g;` / 数组 `gs[4]` / 指针 `*gp`）⇒
    //   旧的「暂不支持 struct 按值全局」负例失效，换成同族里**仍然成立**的那条真边界：
    //   struct 全局不做整体初始化（只有 .bss 全零语义；init[64] 装不下一个结构体）。
    ["ng_struct_init.fl", "struct S { int x; }\nstruct S g = {1};\nint main() { return g.x; }\n",
      /struct 全局变量暂不支持整体初始化/, "struct 全局带初值 → 编译期明确报错（只开 .bss 语义）"],
    ["ng_dbl_intinit.fl", "double gd = 1;\nint main() { return 0; }\n",
      /初值必须是浮点字面量/, "int 字面量当 double 全局初值 → 编译期报错（位型会读成 5e-324）"],
    ["ng_len_kw.fl", "int a[n];\nint main() { return 0; }\n",
      /长度必须是正整数常量/, "全局数组长度用变量 → 编译期报错（长度编译期就得定）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const r = run([path.join(TMP, name)]);
    check(`负例：${label}`, !r.ok && re.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");
  }
}

// —— v1.10.0：全局指针（int* / char*）—— 从「必须报错」转成「必须能跑」——
//   语义按决策 40：裸指针 ± 整数是**字节**步进，只有下标才按元素宽缩放。
{
  const src = [
    "int buf[4];",
    "int *gp;",
    "char *gs;",
    "int main() {",
    "  gp = buf;",
    "  gp[1] = 7;",
    "  if (buf[1] != 7) { return 1; }",
    "  gp = buf + 8;",
    "  *gp = 9;",
    "  if (buf[2] != 9) { return 2; }",
    '  gs = "OK";',
    "  if (gs[0] != 79) { return 3; }",
    "  if (gs[1] != 75) { return 4; }",
    "  gp = buf;",
    "  if (gp != &buf[0]) { return 5; }",
    "  return 42;",
    "}",
    "",
  ].join("\n");
  const f = path.join(TMP, "pg_global_ptr.fl");
  fs.writeFileSync(f, src);
  const r = run([f]);
  if (!r.ok) {
    check("正例：全局指针可赋值/下标读写", false, (r.stderr || "").split("\n")[1] || "");
  } else {
    const exe = f.replace(/\.fl$/, ".exe");
    const code = runExe(exe);
    check("正例：全局指针可赋值/下标读写（决策 40 字节步进）", code === 42, "exit=" + code);
  }
}

// —— v1.3.1 三元 ?: / switch 负例 ——
// 这些负例的共同点：**静默实现会让它们全部"编译通过并算错"**，所以每一条都必须编译期报错。
// 反面正例（应当编译通过并算对）在 samples/tern1.fl 与 sw1.fl（含空 case 贯穿、循环里的 break/continue）。
{
  const cases = [
    ["nt_dupcase.fl", "int main() { int n = 1; switch (n) { case 1: return 1; case 1: return 2; } return 0; }\n",
      /case 常量 1 重复/, "同一 case 常量写两次 → 编译期报错（先写的段永远选不中）"],
    ["nt_casevar.fl", "int main() { int n = 1; int k = 1; switch (n) { case k: return 1; } return 0; }\n",
      /case 标签必须是整型常量/, "case 用变量（值运行时才有）→ 编译期报错"],
    ["nt_caseexpr.fl", "int main() { int n = 1; switch (n) { case 1 + 1: return 2; } return 0; }\n",
      /case 只能跟一个\*\*整型常量\*\*/, "case 用表达式 → 编译期报错（编译期要按常量发比较）"],
    ["nt_beforecase.fl", "int main() { int n = 1; switch (n) { n = 5; case 1: return 1; } return 0; }\n",
      /之前的语句永远执行不到/, "case 之前的语句 → 编译期报错（不可达，不静默丢弃也不猜归属）"],
    ["nt_dupdefault.fl", "int main() { int n = 1; switch (n) { default: return 1; default: return 2; } return 0; }\n",
      /switch 里只能有一个 default/, "两个 default → 编译期报错"],
    ["nt_switch_cont.fl", "int main() { int n = 1; switch (n) { case 1: continue; } return 0; }\n",
      /continue 在 switch 里没有意义/, "switch 里的 continue 但没有外层循环 → 编译期报错（不猜跳哪里）"],
    ["nt_switch_dbl.fl", "int main() { double d = 1.0; switch (d) { case 1: return 1; } return 0; }\n",
      /switch 的条件不支持 double/, "switch 条件用 double → 编译期报错（浮点不能按位型判相等）"],
    ["nt_tern_mix.fl", "int main() { int x = 1; int *p = &x; return x ? p : 3; }\n",
      /三元两分支类型不一致/, "三元一支指针一支整数 → 编译期报错（不猜宽度，防 64 位地址被截断）"],
    ["nt_tern_ptrmix.fl",
      "int main() { int x = 1; char c = 'a'; int *p = &x; char *q = &c; return (x ? p : q) == p; }\n",
      /三元两分支的指针指向类型不一致/, "三元两支指针指向类型不同（int* / char*）→ 编译期报错"],
    ["nt_kw_var.fl", "int main() { int switch = 1; return switch; }\n",
      /不能作变量名/, "switch/case/default 已成关键字 → 不能再当变量名"],
    ["nt_tern_nocolon.fl", "int main() { int x = 1; return (x ? 1); }\n",
      /三元 \?: 缺少 ':'/, "三元少了 ':' → 编译期报错（不猜假分支）"],
    ["nt_switch_brace.fl", "int main() { int n = 1; switch (n) { case 1: return 1;\n",
      /switch 缺少右花括号/, "switch 缺右花括号 → 编译期报错"],
    ["nt_case_outside.fl", "int main() { case 1: return 1; }\n",
      /意外的关键字 'case'/, "case 出现在 switch 外 → 编译期报错（标签没有归属）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const r = run([path.join(TMP, name)]);
    check(`负例：${label}`, !r.ok && re.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");
  }
}

// —— v1.3.2 函数指针负例 ——
// 函数指针的危险全在「地址被截断/签名被忽略」这两类**静默**错误上：地址截断 = 跳到野地址，
// 签名忽略 = 实参落错寄存器。下面每条都把一类静默变成编译期报错。
{
  const cases = [
    ["nf_sig_mismatch.fl",
      "double half(double d) { return d / 2.0; }\nint main() { int (*fp)(int) = &half; return 0; }\n",
      /签名不一致/, "初始化时签名不一致（int(int) ← double(double)）→ 编译期报错"],
    ["nf_sig_assign.fl",
      "int dbl(int v) { return v + v; }\ndouble half(double d) { return d / 2.0; }\n"
      + "int main() { int (*fp)(int) = &dbl; fp = &half; return 0; }\n",
      /签名不一致/, "赋值时签名不一致 → 编译期报错"],
    ["nf_arity.fl",
      "int sub(int a, int b) { return a - b; }\nint main() { int (*f)(int, int) = &sub; return f(1); }\n",
      /需要 2 个实参/, "实参个数少于函数指针声明的形参 → 编译期报错"],
    ["nf_arity2.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; return f(1, 2); }\n",
      /实参个数超过这个函数指针/, "实参个数多于函数指针声明的形参 → 编译期报错"],
    ["nf_dblarg.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; return f(1.5); }\n",
      /这个形参是 int/, "double 实参传给 int 形参的函数指针 → 编译期报错（不静默截断）"],
    ["nf_cbparam_sig.fl",
      "double half(double d) { return d / 2.0; }\n"
      + "int apply(int (*cb)(int), int v) { return cb(v); }\n"
      + "int main() { return apply(&half, 3); }\n",
      /签名与形参不一致/, "传给函数指针形参的函数签名不对 → 编译期报错"],
    ["nf_cbparam_int.fl",
      "int apply(int (*cb)(int), int v) { return cb(v); }\nint main() { return apply(3, 1); }\n",
      /收的是函数指针/, "函数指针形参收到整数 → 编译期报错"],
    ["nf_bare_name.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = dbl; return 0; }\n",
      /需带括号调用/, "裸函数名当函数指针（不写 &）→ 编译期报错（FLINT 要求显式 &）"],
    ["nf_to_int.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; int x = f; return x; }\n",
      /函数指针不能赋给非函数指针/, "函数指针赋给 int → 编译期报错（不静默截断地址）"],
    ["nf_deref.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; return *f; }\n",
      /函数指针不能解引用/, "解引用函数指针 → 编译期报错（要调用请写 f(...)）"],
    ["nf_incr.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; f++; return 0; }\n",
      /函数指针不支持 \+\+\/--/, "函数指针 ++ → 编译期报错（地址不能当整数算）"],
    ["nf_field.fl",
      "struct S { int (*cb)(int); }\nint main() { return 0; }\n",
      /结构体暂不支持函数指针字段/, "结构体里的函数指针字段 → 编译期明确报错（第一版边界）"],
    ["nf_global.fl",
      "int (*gp)(int);\nint main() { return 0; }\n",
      /暂不支持全局函数指针/, "全局函数指针 → 编译期明确报错（第一版边界）"],
    ["nf_array.fl",
      "int dbl(int v) { return v + v; }\nvoid run(int (*t[2])(int), int n) { }\nint main() { return 0; }\n",
      /函数指针数组作函数形参暂不支持/, "函数指针数组作形参 → 编译期明确报错（v2.6.0 边界；数组本身已支持，见上面 v2.6.0 正/负例块）"],
    ["nf_tern.fl",
      "int dbl(int v) { return v + v; }\nint triple(int v) { return v * 3; }\n"
      + "int main() { int (*a)(int) = &dbl; int (*b)(int) = &triple; int c = 1; int (*z)(int) = c ? a : b; return 0; }\n",
      /三元的函数指针分支暂不支持/, "三元里的函数指针 → 编译期报错（签名会丢）"],
    ["nf_print.fl",
      "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; print([f]); return 0; }\n",
      /函数指针不能直接打印/, "打印函数指针 → 编译期报错（存的是代码地址）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const r = run([path.join(TMP, name)]);
    check(`负例：${label}`, !r.ok && re.test(r.stderr || ""), (r.stderr || "").split("\n")[1] || "");
  }
}

// —— v1.4.0 API 实参上限（12 → 16）负例 + 上限正侧 ——
// 上限本身是"编译期必须说清楚"的边界：17 参要么报错、要么被静默截断成 16 参调用（后者最危险：
// 编译过、跑起来参数错位）。所以负侧断言报错文本；正侧断言 16 参**能编译过**（上限不是 14/15）。
{
  const p17 = Array(17).fill("int").join(", ");
  const p16 = Array(16).fill("int").join(", ");
  fs.writeFileSync(path.join(TMP, "na_args17.fl"),
    `api kernel32 int GetTickCount(${p17});\nint main() { return 0; }\n`);
  const r17 = run([path.join(TMP, "na_args17.fl")]);
  check("负例：api 声明 17 个参数被拒（上限 16）",
    !r17.ok && /API 参数最多 16 个/.test(r17.stderr || ""), (r17.stderr || "").split("\n")[1] || "");

  fs.writeFileSync(path.join(TMP, "na_args16.fl"),
    `api kernel32 int GetTickCount(${p16});\nint main() { print(["ok\\n"]); return 0; }\n`);
  const r16 = run([path.join(TMP, "na_args16.fl")]);
  check("正侧：api 声明 16 个参数可编译（新上限就是 16）", r16.ok, (r16.stderr || "").trim().slice(0, 120));
}

// ===== v1.4.25：回归扩容（773 → 900+）=====
// ① `-strict` 诊断档（任务卡 T-20260919-010437 剩项①）：每项都断言三件事——
//    默认**静默**（不带开关照常编译）/ 严格档**拦下**（且带稳定错误码）/ 产物**字节不变**。
// ② 「运算 × 操作数形态」矩阵：每格都是**独立编译 + 真跑**，期望值由 JS 侧**独立算出**
//    （口径同 bench：期望来自另一份实现，不是抄被测实现的输出——抄了就等于没测）。
// ③ 控制流 / 内存 / 函数 / 浮点 形态矩阵：挑的是"静默错值"最容易藏身的那些组合。
{
  const SK = path.join(__dirname, "strict-samples");
  let mc = 0;
  const matrixCase = (label, src, want) => {
    const name = `mx${mc++}`;
    const f = path.join(TMP, `${name}.fl`);
    const exe = path.join(TMP, `${name}.exe`);
    fs.writeFileSync(f, src);
    const r = run(["-o", exe, f]);
    check(`矩阵 ${label}：编译通过`, r.ok, (r.stderr || "").trim().slice(0, 140));
    if (!r.ok) return;
    const got = runExe(exe);
    check(`矩阵 ${label}：退出码 ${want}`, got === want, `实际 ${got}`);
  };

  // —— ① -strict 诊断档 ——
  const strictNeg = [
    ["neg-inttoptr.fl", "E-T1-INTTOPTR"],
    ["neg-uninit.fl", "E-STRICT-UNINIT"],
    ["neg-width-arg.fl", "E-STRICT-WIDTH"],
    ["neg-width-ret.fl", "E-STRICT-WIDTH"],
    ["neg-bounds-local.fl", "E-STRICT-BOUNDS"],
    ["neg-bounds-global.fl", "E-STRICT-BOUNDS"],
    // v1.6.4 第五类：裸 ± 用在非 1 字节元素指针上（int* = 8 字节槽）——默认档静默（决策 40
    // 的字节步进语义），-strict 才拦。默认档必须照常编译（不在 defaultClosed 里）。
    ["neg-ptrstep.fl", "E-STRICT-PTRSTEP"],
  ];
  // v1.4.27（卡 T-20261012-210751）：这两条方向**不再"默认静默"** —— 默认档现在也拦，
  //   那正是本刀的目的。它们在上面的 -strict 断言里照旧带自己的稳定码；下面把
  //   "不带开关照常编译"换成"不带开关**也必须被拦**，且文案含新的默认关键词"。
  //   （默认口径的逐字文案由 test\边界探针.ps1 的 wall 用例 int_arg_to_ptr_param /
  //   ptr_arg_to_int_param 钉住，两处是同一份判据。）
  const defaultClosed = {
    "neg-inttoptr.fl": "地址形参需要指针",
    "neg-width-arg.fl": "地址值不能装进 int 形参",
  };
  for (const [f, code] of strictNeg) {
    const src = path.join(SK, f);
    const rs = run(["-strict", "-o", path.join(TMP, `sn_${f}.exe`), src]);
    check(`-strict 负例：${f} 被拦下（${code}）`,
      !rs.ok && (rs.stderr || "").includes(code), (rs.stderr || "").split("\n")[1] || "");
    const rp = run(["-o", path.join(TMP, `sp_${f}.exe`), src]);
    const kw = defaultClosed[f];
    if (kw) {
      check(`v1.4.27 默认档硬错：${f} 不带开关也被拦（文案含「${kw}」）`,
        !rp.ok && (rp.stderr || "").includes(kw), (rp.stderr || "").trim().slice(0, 140));
    } else {
      check(`-strict 负例：${f} 不带开关照常编译（"默认静默"的定义）`,
        rp.ok, (rp.stderr || "").trim().slice(0, 140));
    }
  }
  // v1.6.4：pos-share.fl **移出**本表 —— 它读 share 引用计数头 `*(a - 8)`，那是决策 40 记录在案的
  //   p-8 块头约定（故意的字节步进，不是元素访问）⇒ 它是第五类 E-STRICT-PTRSTEP 的**真阳性**，
  //   不可能再"在 -strict 下无告警编译"。它仍留在 test\strict-samples\ 里给前四类用；这里把
  //   "第五类必须拦下它"单独记一条判据（见下面的例外块），不静默丢样本。
  const strictPos = ["pos-basic.fl", "pos-outparam.fl", "pos-mainptr.fl",
                     "pos-apiaddr.fl", "pos-t1int.fl", "pos-loopwrite.fl",
                     "pos-ptrstep-elem.fl", "pos-ptrstep-char.fl"];
  {
    const src = path.join(SK, "pos-share.fl");
    const rs = run(["-strict", "-o", path.join(TMP, "pp_share.exe"), src]);
    check("-strict 第五类例外：pos-share.fl 被拦下（share 头 *(a-8) = 决策 40 字节步进，真阳性）",
      !rs.ok && (rs.stderr || "").includes("E-STRICT-PTRSTEP"), (rs.stderr || "").trim().slice(0, 140));
  }
  for (const f of strictPos) {
    const src = path.join(SK, f);
    const pa = path.join(TMP, `q_${f}.exe`);
    const pb = path.join(TMP, `qt_${f}.exe`);
    const ra = run(["-o", pa, src]);
    const rb = run(["-strict", "-o", pb, src]);
    check(`-strict 正例：${f} 在 -strict 下无告警编译（不误报）`,
      ra.ok && rb.ok, (rb.stderr || "").trim().slice(0, 140));
    if (ra.ok && rb.ok) {
      const same = fs.readFileSync(pa).equals(fs.readFileSync(pb));
      check(`-strict 正例：${f} 开关开/关产物逐字节相同（诊断档不改产物）`, same);
    }
  }

  // —— ② 二元运算 × 操作数形态（a=17 b=5；期望值 = JS 独立算出） ——
  const BIN = [["+", (a, b) => a + b], ["-", (a, b) => a - b], ["*", (a, b) => a * b],
               ["/", (a, b) => Math.trunc(a / b)], ["%", (a, b) => a % b],
               ["&", (a, b) => a & b], ["|", (a, b) => a | b], ["^", (a, b) => a ^ b],
               ["<<", (a, b) => a << b], [">>", (a, b) => a >> b]];
  for (const [op, fn] of BIN) {
    const want = fn(17, 5) & 255;
    matrixCase(`17 ${op} 5（变量,变量）`,
      `int main() { int a = 17; int b = 5; return (a ${op} b) & 255; }\n`, want);
    matrixCase(`17 ${op} 5（变量,常量）`,
      `int main() { int a = 17; return (a ${op} 5) & 255; }\n`, want);
    matrixCase(`17 ${op} 5（常量,常量）`,
      `int main() { return (17 ${op} 5) & 255; }\n`, want);
  }
  // 幂（^^ 快速幂通路）+ 负数侧
  matrixCase("3 ^^ 4", "int main() { return 3 ^^ 4; }\n", 81);
  matrixCase("2 ^^ 10", "int main() { return (2 ^^ 10) & 255; }\n", 1024 & 255);
  matrixCase("5 - 17（负数 & 255）", "int main() { return (5 - 17) & 255; }\n", (5 - 17) & 255);
  matrixCase("-17 取模 5", "int main() { return (-17 % 5) & 255; }\n", (-17 % 5) & 255);
  matrixCase("-17 整除 5（向零截断）", "int main() { return (-17 / 5) & 255; }\n", (Math.trunc(-17 / 5)) & 255);

  // —— ③ 比较 / 逻辑 / 复合赋值 / 自增自减 ——
  const CMP = [["==", (a, b) => a === b], ["!=", (a, b) => a !== b], ["<", (a, b) => a < b],
               ["<=", (a, b) => a <= b], [">", (a, b) => a > b], [">=", (a, b) => a >= b]];
  for (const [op, fn] of CMP) {
    matrixCase(`17 ${op} 5`, `int main() { return (17 ${op} 5) ? 1 : 0; }\n`, fn(17, 5) ? 1 : 0);
    matrixCase(`5 ${op} 17`, `int main() { return (5 ${op} 17) ? 1 : 0; }\n`, fn(5, 17) ? 1 : 0);
  }
  matrixCase("逻辑与 1&&0", "int main() { return (1 && 0) ? 1 : 0; }\n", 0);
  matrixCase("逻辑或 1||0", "int main() { return (1 || 0) ? 1 : 0; }\n", 1);
  matrixCase("逻辑非 !0", "int main() { return (!0) ? 1 : 0; }\n", 1);
  matrixCase("逻辑非 !5", "int main() { return (!5) ? 1 : 0; }\n", 0);
  matrixCase("短路求值（&& 右侧不求值）",
    "int main() { int c = 0; int r = (0 && (c = 1)); return c + r; }\n", 0);
  matrixCase("短路求值（|| 右侧不求值）",
    "int main() { int c = 0; int r = (1 || (c = 1)); return c + r; }\n", 1);
  const CMPD = [["+=", (a, b) => a + b], ["-=", (a, b) => a - b], ["*=", (a, b) => a * b],
                ["/=", (a, b) => Math.trunc(a / b)], ["%=", (a, b) => a % b],
                ["&=", (a, b) => a & b], ["|=", (a, b) => a | b], ["^=", (a, b) => a ^ b],
                ["<<=", (a, b) => a << b], [">>=", (a, b) => a >> b]];
  for (const [op, fn] of CMPD) {
    matrixCase(`a ${op} 5`, `int main() { int a = 17; a ${op} 5; return a & 255; }\n`, fn(17, 5) & 255);
  }
  matrixCase("后缀 x++ 值 = 旧", "int main() { int x = 5; int y = x++; return y * 10 + x; }\n", 56);
  matrixCase("前缀 ++x 值 = 新", "int main() { int x = 5; int y = ++x; return y * 10 + x; }\n", 66);
  matrixCase("后缀 x-- 值 = 旧", "int main() { int x = 5; int y = x--; return y * 10 + x; }\n", 54);
  matrixCase("前缀 --x 值 = 新", "int main() { int x = 5; int y = --x; return y * 10 + x; }\n", 44);

  // —— ④ 控制流 ——
  matrixCase("while 累加 1..10",
    "int main() { int i = 1; int s = 0; while (i <= 10) { s = s + i; i = i + 1; } return s; }\n", 55);
  matrixCase("for 累加 1..100（&255）",
    "int main() { int s = 0; for (int i = 1; i <= 100; i = i + 1) { s = s + i; } return s & 255; }\n", 5050 & 255);
  matrixCase("嵌套 for 9 格",
    "int main() { int s = 0; for (int i = 1; i <= 3; i = i + 1) { for (int j = 1; j <= 3; j = j + 1) { s = s + i * j; } } return s; }\n", 36);
  matrixCase("break 跳出 while",
    "int main() { int i = 0; while (1) { i = i + 1; if (i == 7) break; } return i; }\n", 7);
  matrixCase("continue 跳过偶数",
    "int main() { int s = 0; for (int i = 1; i <= 9; i = i + 1) { if (i % 2 == 0) continue; s = s + i; } return s; }\n", 25);
  matrixCase("switch fallthrough",
    "int main() { int r = 0; switch (2) { case 1: r = 1; case 2: r = 2; case 3: r = 3; break; default: r = 9; } return r; }\n", 3);
  matrixCase("switch default", "int main() { int r = 0; switch (7) { case 1: r = 1; break; default: r = 9; } return r; }\n", 9);
  matrixCase("if/else 链",
    "int main() { int x = 7; if (x < 3) { return 1; } else if (x < 6) { return 2; } else { return 3; } }\n", 3);
  matrixCase("嵌套三元",
    "int main() { int x = 5; return (x > 3 ? (x > 4 ? 41 : 42) : 43); }\n", 41);
  matrixCase("递归 fact(5)",
    "int fact(int n) { if (n <= 1) { return 1; } return n * fact(n - 1); }\nint main() { return fact(5); }\n", 120);

  // —— ⑤ 内存 / 数据形态 ——
  matrixCase("数组写读", "int main() { int a[4]; a[2] = 7; return a[2]; }\n", 7);
  matrixCase("数组求和",
    "int main() { int a[5]; a[0]=1; a[1]=2; a[2]=3; a[3]=4; a[4]=5; int s=0; for (int i=0;i<5;i=i+1){ s=s+a[i]; } return s; }\n", 15);
  matrixCase("指针解引用写",
    "int main() { int x = 9; int *p = &x; *p = 12; return x; }\n", 12);
  matrixCase("struct 字段读写（int+char）",
    "struct S { int n; char c; }\nint main() { struct S s; s.n = 300; s.c = 65; return (s.n + s.c) & 255; }\n", (300 + 65) & 255);
  matrixCase("struct 数组字段",
    "struct S { int buf[3]; }\nint main() { struct S s; s.buf[1] = 5; return s.buf[1]; }\n", 5);
  // v2.1.0：局部 struct 数组（元素步长 = 8*ceil(size/8)；Pair 8B→8，Three 12B→16）
  matrixCase("struct 数组写读",
    "struct S { int n; int m; }\nint main() { struct S a[3]; a[1].n = 7; a[2].m = 5; return a[1].n + a[2].m; }\n", 12);
  matrixCase("struct 数组循环填读（12B 元素 = 16B 步长）",
    "struct S { int x; int y; int z; }\nint main() { struct S a[4]; int s = 0;"
    + " for (int i = 0; i < 4; i = i + 1) { a[i].z = i * 2; }"
    + " for (int i = 0; i < 4; i = i + 1) { s = s + a[i].z; } return s; }\n", 12);
  matrixCase("struct 指针形参 p->n",
    "struct S { int n; }\nint get(struct S *p) { return p->n; }\nint main() { struct S s; s.n = 33; return get(&s); }\n", 33);
  matrixCase("char 数组逐字节",
    "int main() { char b[4]; b[0] = 65; b[1] = 66; return b[0] + b[1]; }\n", 131);
  matrixCase("全局 int 变量",
    "int g = 7;\nint main() { g = g + 1; return g; }\n", 8);
  matrixCase("全局 int 数组初值",
    "int g[3] = {1, 2, 3};\nint main() { return g[0] + g[1] + g[2]; }\n", 6);
  matrixCase("全局 char 数组初值",
    "char s[4] = {70, 76, 78, 84};\nint main() { return (s[0] + s[1] + s[2] + s[3]) & 255; }\n", 308 & 255);
  matrixCase("全局 double 变量",
    "double d = 2.5;\nint main() { return to_int(d * 2.0); }\n", 5);
  matrixCase("全局数组运行时累加",
    "int g[4];\nint main() { for (int i = 0; i < 4; i = i + 1) { g[i] = i * 2; } return g[3]; }\n", 6);

  // —— ⑥ 函数形态 ——
  matrixCase("函数指针间接调用",
    "int dbl(int v) { return v + v; }\nint main() { int (*f)(int) = &dbl; return f(6); }\n", 12);
  matrixCase("引用形参 swap",
    "void swap(int &a, int &b) { int t = a; a = b; b = t; }\nint main() { int x = 3; int y = 9; swap(x, y); return x * 10 + y; }\n", 93);
  matrixCase("4 个形参",
    "int add4(int a, int b, int c, int d) { return a + b + c + d; }\nint main() { return add4(1, 2, 3, 4); }\n", 10);
  matrixCase("指针 out 形参",
    "void set(int *p) { *p = 44; }\nint main() { int v = 0; set(&v); return v; }\n", 44);
  matrixCase("嵌套调用做实参",
    "int dbl(int v) { return v + v; }\nint add4(int a, int b, int c, int d) { return a + b + c + d; }\nint main() { return add4(dbl(1), 2, 3, 4); }\n", 11);
  matrixCase("void 函数 + 全局副作用",
    "int g = 0;\nvoid bump() { g = g + 5; }\nint main() { bump(); bump(); return g; }\n", 10);
  matrixCase("char 返回截断到 0..255",
    "char cr() { return 300; }\nint main() { return cr(); }\n", 300 & 255);
  matrixCase("前向调用（先调用后定义）",
    "int main() { return later(5); }\nint later(int v) { return v + 1; }\n", 6);

  // —— ⑦ 浮点（double）——
  matrixCase("double 加法 + to_int", "int main() { return to_int(7.5 + 2.5); }\n", 10);
  matrixCase("double 乘除", "int main() { return to_int(1.0 / 4.0 * 8.0); }\n", 2);
  matrixCase("double 比较", "int main() { double d = 3.5; return (d > 3.0) ? 1 : 0; }\n", 1);
  matrixCase("double 形参", "int f(double d) { return to_int(d * 2.0); }\nint main() { return f(3.5); }\n", 7);
  matrixCase("int→double 自动提升",
    "int main() { double d = 3.0; int n = 2; return to_int(d * n); }\n", 6);
  matrixCase("double 数组元素",
    "int main() { double a[2]; a[0] = 1.5; a[1] = 2.5; return to_int(a[0] + a[1]); }\n", 4);
  matrixCase("double struct 字段",
    "struct S { double d; }\nint main() { struct S s; s.d = 2.25; return to_int(s.d * 4.0); }\n", 9);
  matrixCase("double 负数截断（向零）",
    "int main() { return to_int(-2.5); }\n", -2);

  console.log(`矩阵与 -strict 家族合计 ${mc} 个编译样本`);
}

// —— v2.0.0：try 错误传播糖的禁区（五条全是编译期硬错，绝不静默）——
{
  const cases = [
    ["try_bad_lhs.fl", "int main() { int e = 0; int a[2]; try a[0] = e; return 0; }\n",
      /左值只能是单个变量/, "左值是数组元素 → 编译期硬错（展开会把它求值两次）"],
    ["try_bad_void.fl", "void f() { int e = 0; try e = 1; }\nint main() { return 0; }\n",
      /void 函数里不能用 try/, "void 函数 → 编译期硬错（没有返回值可带错误码）"],
    ["try_bad_ret.fl", "int *f() { int e = 0; try e = 1; return 0; }\nint main() { return 0; }\n",
      /只能用在返回 int 的函数/, "返回指针的函数 → 编译期硬错（错误码约定是 int）"],
    ["try_bad_undecl.fl", "int main() { try zz = 1; return 0; }\n",
      /未声明/, "目标变量未声明 → 编译期硬错"],
    ["try_bad_64.fl", "int main() { int_64 e = 0; try e = 1; return 0; }\n",
      /32 位整数/, "64 位目标变量 → 编译期硬错（return 给 int 函数会静默截断）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`try 负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
}

// —— v2.1.0：局部 struct 数组 `struct S a[N];` ——
//   starr1.fl = 8 位掩码全亮 → 退 42（字段写读 / 循环填读 / 元素步长精确钉死 / 指针字段元素 /
//   &a[i] 与数组名作 struct S * 实参 / char 字段 / 元素内定长数组字段双下标）。
//   数值层的独立裁判 = test\facts\f054_structarr.fl（同一套判据的探针形态，另加 -strict 越界负例）。
//   boot 侧不支持（要动变量规格编码 + 新发射档）⇒ 差分门记 BOOT_FAIL，见 PROGRESS 的缺口登记。
compileCases.push(
  ["starr1.fl", 42],
);

// —— v2.1.0：struct 数组的禁区（六条全是编译期硬错，绝不静默）——
//   为什么必须是硬错：长度 0 / 变量长度会让帧槽算错（静默越界）；整体初始化/整体赋值会让
//   "struct 值语义"凭空出现（FLINT 没有）；`s[0]`（标量 struct 下标）若静默按 int 读会读错宽度。
{
  const cases = [
    ["starr_bad_len0.fl", "struct S { int n; }\nint main() { struct S a[0]; return 0; }\n",
      /struct 数组长度须为正数/, "长度 0 → 编译期硬错"],
    ["starr_bad_lenvar.fl", "struct S { int n; }\nint main() { int n = 3; struct S a[n]; return 0; }\n",
      /struct 数组长度须为数字常量/, "非常量长度 → 编译期硬错（帧槽必须在编译期算死）"],
    ["starr_bad_scalar.fl", "struct S { int n; }\nint main() { struct S s; s[0].n = 1; return 0; }\n",
      /不是数组，不能下标/, "标量 struct 下标 → 编译期硬错（文案点名「不是数组」）"],
    ["starr_bad_init.fl", "struct S { int n; }\nint main() { struct S a[2] = 1; return 0; }\n",
      /struct 数组暂不支持整体初始化/, "struct 数组整体初始化 → 编译期硬错"],
    ["starr_bad_assign.fl", "struct S { int n; }\nint main() { struct S a[2]; struct S b; a[0] = b; return 0; }\n",
      /赋值左边必须是变量或/, "元素整体赋值 → 编译期硬错（struct 没有整体值语义）"],
    ["starr_bad_method.fl", "struct S { int n; }\nint S_go(struct S *p) { return p->n; }\n"
      + "int main() { struct S a[2]; a[0].n = 1; return a[0].go(); }\n",
      /方法调用点糖暂不支持/, "元素上的方法调用点糖 → 编译期硬错（手写 S_go(&a[0]) 等价）"],
  ];
  for (const [name, src, re, label] of cases) {
    fs.writeFileSync(path.join(TMP, name), src);
    const rr = run([path.join(TMP, name)]);
    check(`struct 数组负例：${label}`, !rr.ok && re.test(rr.stderr || ""),
      (rr.stderr || "").split("\n").slice(1, 3).join(" ").slice(0, 160));
  }
  // -strict 的常量下标越界（与 int 数组同一条判据；默认档静默 = 与既有数组口径一致）
  const sbo = path.join(TMP, "starr_oob.fl");
  const sbs = path.join(TMP, "starr_oob.s.exe");
  fs.writeFileSync(sbo, "struct S { int n; }\nint main() { struct S a[2]; a[2].n = 1; return a[0].n; }\n");
  const rs1 = run(["-strict", "-o", sbs, sbo]);
  check("struct 数组负例：-strict 常量下标越界被拦（E-STRICT-BOUNDS）",
    !rs1.ok && /E-STRICT-BOUNDS/.test(rs1.stderr || ""), (rs1.stderr || "").trim().slice(0, 160));
  const rs0 = run(["-o", path.join(TMP, "starr_oob.exe"), sbo]);
  check("struct 数组负例：不带 -strict 时同一文件照常编译（「默认静默」的定义）", rs0.ok,
    (rs0.stderr || "").trim().slice(0, 160));
}

// —— v1.10.2：hlc -run（编译成功后运行产物、返回程序自己的退出码）——
//   判据三条：① 程序退出码原样冒泡；② 编译失败时不运行、退 1；③ 不加 -run 时行为与从前一致（退 0）。
{
  const rf = path.join(TMP, "runflag.fl");
  fs.writeFileSync(rf, "int main() { return 7; }\n");
  const r = run(["-run", "-o", path.join(TMP, "runflag.exe"), rf]);
  check("hlc -run：退出码 = 程序退出码", !r.ok && r.code === 7,
    (r.stderr || "").trim().slice(0, 160));
  const bad = path.join(TMP, "runflag_bad.fl");
  fs.writeFileSync(bad, "int main() { return 0 }\n");
  const rb = run(["-run", "-o", path.join(TMP, "runflag_bad.exe"), bad]);
  check("hlc -run：编译失败不运行（退 1）", !rb.ok && rb.code === 1 && /编译错误/.test(rb.stderr || ""),
    (rb.stderr || "").trim().slice(0, 160));
  const rd = run(["-o", path.join(TMP, "runflag2.exe"), rf]);
  check("hlc 默认档不运行（退 0）", rd.ok, (rd.stderr || "").trim().slice(0, 160));
}

// —— v1.10.5：hlc build / run 子命令（build\ 产物目录；run = build 后立即运行）——
{
  const l = path.join(TMP, "subcmd.fl");
  fs.writeFileSync(l, "int main() { return 5; }\n");
  const r1 = runIn(TMP, ["build", "subcmd.fl"]);
  check("hlc build：产物进 build\\ 目录",
    r1.ok && fs.existsSync(path.join(TMP, "build", "subcmd.exe")),
    (r1.stderr || "").trim().slice(0, 160));
  const r2 = runIn(TMP, ["run", "subcmd.fl"]);
  check("hlc run：返回程序退出码", !r2.ok && r2.code === 5,
    (r2.stderr || "").trim().slice(0, 160));
}

// —— 标准库 base64（2026-11-03）：Base64 编解码 ——
//   判据 = test\facts\f117_base64.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f117_base64.fl");
  const exe = path.join(TMP, "f117_base64.exe");
  const r = run(["-o", exe, src]);
  check("base64 编解码探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("base64 编解码探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 time（2026-11-03）：时间/日期 ——
//   判据 = test\facts\f116_time.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f116_time.fl");
  const exe = path.join(TMP, "f116_time.exe");
  const r = run(["-o", exe, src]);
  check("time 时间探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("time 时间探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 rand（2026-11-03）：伪随机数 ——
//   判据 = test\facts\f118_rand.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f118_rand.fl");
  const exe = path.join(TMP, "f118_rand.exe");
  const r = run(["-o", exe, src]);
  check("rand 随机数探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("rand 随机数探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 env（2026-11-03）：环境变量 + 命令行参数 ——
//   判据 = test\facts\f119_env.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f119_env.fl");
  const exe = path.join(TMP, "f119_env.exe");
  const r = run(["-o", exe, src]);
  check("env 环境变量探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("env 环境变量探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 hash（2026-11-03）：MD5 / SHA1 / SHA256 ——
//   判据 = test\facts\f120_hash.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f120_hash.fl");
  const exe = path.join(TMP, "f120_hash.exe");
  const r = run(["-o", exe, src]);
  check("hash 摘要探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("hash 摘要探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 crc32（2026-11-03）：CRC-32 ——
//   判据 = test\facts\f121_crc32.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f121_crc32.fl");
  const exe = path.join(TMP, "f121_crc32.exe");
  const r = run(["-o", exe, src]);
  check("crc32 校验探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("crc32 校验探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 path（2026-11-03）：路径与目录 ——
//   判据 = test\facts\f122_path.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f122_path.fl");
  const exe = path.join(TMP, "f122_path.exe");
  const r = run(["-o", exe, src]);
  check("path 路径探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("path 路径探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— codec §4 UTF-8 <-> UTF-16（2026-11-03）——
//   判据 = test\facts\f124_utf.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f124_utf.fl");
  const exe = path.join(TMP, "f124_utf.exe");
  const r = run(["-o", exe, src]);
  check("utf 编码转换探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("utf 编码转换探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 image（2026-11-03）：BMP 读写 ——
//   判据 = test\facts\f125_bmp.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f125_bmp.fl");
  const exe = path.join(TMP, "f125_bmp.exe");
  const r = run(["-o", exe, src]);
  check("image BMP 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("image BMP 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— sys §4/§5 目录枚举 + 剪贴板（2026-11-03）——
//   判据 = test\facts\f123_sys.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f123_sys.fl");
  const exe = path.join(TMP, "f123_sys.exe");
  const r = run(["-o", exe, src]);
  check("sys 目录/剪贴板探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sys 目录/剪贴板探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— sys §6 注册表（2026-11-03）——
//   判据 = test\facts\f126_reg.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f126_reg.fl");
  const exe = path.join(TMP, "f126_reg.exe");
  const r = run(["-o", exe, src]);
  check("sys 注册表探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sys 注册表探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 net（2026-11-03）：TCP 客户端 ——
//   判据 = test\facts\f127_tcp.fl（8 位掩码全亮 → 退 42；探针约 2 秒，阻塞 connect 到关闭端口）。
{
  const src = path.join(__dirname, "facts", "f127_tcp.fl");
  const exe = path.join(TMP, "f127_tcp.exe");
  const r = run(["-o", exe, src]);
  check("net TCP 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("net TCP 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— sys §7 进程创建（2026-11-03）——
//   判据 = test\facts\f128_proc.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f128_proc.fl");
  const exe = path.join(TMP, "f128_proc.exe");
  const r = run(["-o", exe, src]);
  check("sys 进程探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sys 进程探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— http §2/§3 POST + 状态码/头解析（2026-11-03）——
//   判据 = test\facts\f130_http.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f130_http.fl");
  const exe = path.join(TMP, "f130_http.exe");
  const r = run(["-o", exe, src]);
  check("http POST/解析探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("http POST/解析探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— net §2/§3 UDP + DNS（2026-11-03）——
//   判据 = test\facts\f129_udp.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f129_udp.fl");
  const exe = path.join(TMP, "f129_udp.exe");
  const r = run(["-o", exe, src]);
  check("net UDP/DNS 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("net UDP/DNS 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— http §4 HTTPS（2026-11-03）：WinHTTP 路线 ——
//   判据 = test\facts\f134_https.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f134_https.fl");
  const exe = path.join(TMP, "f134_https.exe");
  const r = run(["-o", exe, src]);
  check("http HTTPS 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("http HTTPS 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— http_lib + net_lib 同编译单元（2026-11-03）：ws2_32 socket 口径统一 ——
//   判据 = test\facts\f135_both.fl（同单元先 http 后 net；8 位掩码全亮 → 退 42；约 6 秒，含三处阻塞 connect）。
{
  const src = path.join(__dirname, "facts", "f135_both.fl");
  const exe = path.join(TMP, "f135_both.exe");
  const r = run(["-o", exe, src]);
  check("http+net 同单元探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("http+net 同单元探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— sys §8/§9 目录递归删除 + 文件时间（2026-11-03）——
//   判据 = test\facts\f131_sys3.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f131_sys3.fl");
  const exe = path.join(TMP, "f131_sys3.exe");
  const r = run(["-o", exe, src]);
  check("sys 递归删/文件时间探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sys 递归删/文件时间探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— 标准库 json（2026-11-03）：完整 JSON 解析 ——
//   判据 = test\facts\f132_json.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f132_json.fl");
  const exe = path.join(TMP, "f132_json.exe");
  const r = run(["-o", exe, src]);
  check("json 解析探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("json 解析探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— image §2 PNG/GDI+ 解码（2026-11-03）——
//   判据 = test\facts\f133_png.fl（8 位掩码全亮 → 退 42）。
{
  const src = path.join(__dirname, "facts", "f133_png.fl");
  const exe = path.join(TMP, "f133_png.exe");
  const r = run(["-o", exe, src]);
  check("image PNG 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("image PNG 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— sizeof 运算符（2026-11-04）：编译期常量，值宽口径 ——
//   判据 = test\facts\f136_sizeof.fl（8 位掩码全亮 → 退 42）。
//   ⚠️ **只在真 flint 端跑**（不进差分门）：boot 的类型宇宙没有 double / int_64 / uint_*，
//   而且 sizeof 本身也没在 boot 侧实现（仍报「未声明的变量 'sizeof'」）——
//   这是已知的双端缺口，登记方式同 double / int_64 / uint_* 的既有缺口。
{
  const src = path.join(__dirname, "facts", "f136_sizeof.fl");
  const exe = path.join(TMP, "f136_sizeof.exe");
  const r = run(["-o", exe, src]);
  check("sizeof 探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("sizeof 探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// —— api 的 64 位整型通道（2026-11-04）：int_64 / uint_64 作返回值 + 作形参 ——
//   判据 = test\facts\f137_api_i64.fl（8 位掩码全亮 → 退 42）。
//   ⚠️ **只在真 flint 端跑**（不进差分门）：boot 的类型宇宙没有 int_64 / uint_64 / double，
//   api 声明侧也没有这两档 —— 这是已知的双端缺口，登记方式同 f136（sizeof）与 int_64 族既有缺口。
{
  const src = path.join(__dirname, "facts", "f137_api_i64.fl");
  const exe = path.join(TMP, "f137_api_i64.exe");
  const r = run(["-o", exe, src]);
  check("api 64 位通道探针：编译", r.ok, r.ok ? "" : (r.stderr || "").trim().slice(0, 120));
  if (fs.existsSync(exe)) {
    const res = runExeOut(exe);
    check("api 64 位通道探针：8 位掩码全亮", res.code === 42, `实际 ${res.code}`);
  }
}

// 清理产物（保留样本源码）
fs.rmSync(TMP, { recursive: true, force: true });

console.log("==== FLINT v0.9 野路子测试 ====");
console.log(results.join("\n"));
console.log(`----\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail > 0 ? 1 : 0);
