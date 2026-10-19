# FLINT_CHAN

> 名字：**FLINT_CHAN**（叫法：**FLINT**，简称 **FL**）

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`（**数字不许手抄**：值当场取自取数器，写成「事实标记」——标记写法与全部键名见 `docs\数字台账.md` 头部）
> 引用我=`docs\索引.md`、`docs\协作协议.md`、`docs\设计决策.md`、`docs\语言边界.md`、`docs\快速上手-真实项目.md`、`docs\真实项目.md` ｜ 我引用=`docs\数字台账.md`（取数器）、`test\verify-all.ps1`、`test\边界探针.ps1`、`test\flgui-verify.ps1`、`tools\导入预算.ps1`、`tools\boot余量.ps1` ｜ 最后复核=2026-10-15 `test\docgate.mjs`

> **一句话**：**以 Windows 桌面开发为核心的发展中语言，目标是 Zig / C++ / Rust。**
>
> 现在可以先读成事实版：**一个自己写机器码的 Windows x64 编译器 ＋ 一个自绘 GUI 库（FLGUI）**。
> 从源码到 PE 的每一步都自己做：不借 LLVM、不借汇编器、不借链接器、不借 C 运行时。

| 事实 | 数字 / 出处 |
|---|---|
| 编译器版本 | v<!--fact:version-->1.7.0<!--/fact--> |
| 产物 | 纯自产机器码 PE，无 CRT / 无运行时；`hello`（含打印） = **<!--fact:product-hello-->3072<!--/fact--> B**，浮窗 app（`apps\m2_float\m2_float.exe`） = **<!--fact:product-m2float-->241664<!--/fact--> B**，真实工具 `winpanel.exe` = **<!--fact:product-winpanel-->353792<!--/fact--> B** |
| 自举 | `boot\` 里的自举编译器已达**不动点**（boot 编自己、产物与真 flint 逐字节一致） |
| 门（可自己跑） | 总门 **<!--fact:gate-steps-->14<!--/fact--> 步**（`test\verify-all.ps1`）｜语言边界探针 **<!--fact:probe-cases-->44<!--/fact--> 条**（`test\边界探针.ps1`）｜FLGUI 门 **<!--fact:flgui-checks-->199/199<!--/fact-->** |
| 平台 | Windows 10 x64（明确放弃 Win7）；单目标、单平台 |
| 对外语言 | 中英双语：中文正文 ＋ 英文摘要（2026-10-19 所有者拍板） |
| 参与方式 | **暂时只收工单（issue），不接受外部 PR**（目标在语言做大之前不明确，避免被打乱） |
| 许可 | 源码 **MIT**（`LICENSE`）；文档 **CC BY 4.0** |
| AI 参与 | 代码主要由 AI 编写，所有者定方向与验收（如实披露，见 `docs\协作协议.md` §6） |

## Abstract (English)

FLINT_CHAN, called FLINT for short, is an in-development language centered on Windows
desktop development, aiming at Zig, C++, and Rust. This page is the project's front
door: it states what the compiler and its GUI library are today, and it is just as
explicit about what they are not. It covers the shortest path to a working build, the
traps we have already hit, a map of the repository, the honest account of current
abilities and gaps, the participation rules, and the license split between source and
documentation. Read it first, then follow its links into the other outward documents
when you need depth.

---

## 1. 30 秒跑起来（这三条我实测过，照抄即可）

前置：`gcc`（MinGW-w64 即可）、PowerShell；跑总门还需要 `objdump`（MinGW-w64 自带）。**在仓库根目录**执行：

```cmd
:: 1) 构建编译器（约 9 秒，产出 <!--fact:product-flint-->276414<!--/fact--> 字节的 flint.exe）
cmd /c "gcc -O2 src\*.c -o flint.exe"
```
```powershell
# 2) 编译并运行第一个程序
.\flint.exe examples\hello\hello.fl
.\examples\hello\hello.exe

# 3) 自己验一遍"说明书说的是真的"（<!--fact:probe-cases-->44<!--/fact--> 条语言边界用例，全绿 = 与边界表一致）
powershell -NoProfile -ExecutionPolicy Bypass -File test\边界探针.ps1
```

⚠️ **两个必踩的坑**（我们踩过了，先告诉你）：
1. **别在 PowerShell 里直接写 `gcc src\*.c`** —— PowerShell 不给原生程序展开通配符，会报 `cc1.exe: too many filenames given`。用上面的 `cmd /c`，或显式列出 `.c` 文件。
2. **编译器必须放在仓库根目录**（或别处但同目录要有 `lib\`）——`include` 的解析顺序是「本文件目录 → **编译器 exe 所在目录的 `lib\`**」。

最小可跑程序长这样（注意 `print` 吃的是**数组**，不是普通函数调用）：

```
int main() {
  print(["hello, flint\n"]);
  return 0;
}
```

## 2. 现在能做什么 / 现在不能做什么

**能做**（都有跑通的真实产物）
- 控制台程序、系统工具：直接按 `api` 声明调 Windows DLL（导入表预算硬上限 <!--fact:limit-imports-->96<!--/fact--> 条 API / <!--fact:limit-groups-->8<!--/fact--> 个 DLL）
- **桌面面板类 GUI**：`FLGUI` 是立即模式库（自绘 + 分层窗口），已有标签/按钮/勾选/单选/滑块/进度条/文本域/滚动/弹层/主题/圆角/投影/离屏透明/键盘焦点链/多字体档/窗口拖动 —— 真实项目 `apps\winpanel`（源码 <!--fact:app-winpanel-mainfl-->5247/266532<!--/fact-->（行/字节）／<!--fact:checks-panel-->116/114<!--/fact--> 条真鼠标判据（调用处/编号））
- 一键出**单文件 exe**：没有安装器、没有运行时依赖、冷启动无初始化

**不能做 / 还没有**（诚实账，全文见 `开源前-人类可用性缺口.md`）
- 语言层：无泛型、无无符号整型、无异常、无 `sizeof`、无 C 风格转型；`int` 是 4 字节元素（v1.7.0 起与 C 的 `int` 同宽），另有 `int_32`（别名）与 `int_64`（64 位有符号整数）
- 平台层：只有 Windows x64；**无多窗口**、无 DPI≠96 档、IME 只"绕过"未"支持"
- 预算层：**导入表 <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact--> 条、DLL 分组 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact--> 已顶格**（浮窗链）、**boot 函数表 <!--fact:boot-occupied-->507<!--/fact-->/<!--fact:boot-limit-->512<!--/fact-->（余 <!--fact:boot-headroom-->5<!--/fact-->）** ⇒ 加 API / 加库函数之前要先腾挪（实测 2026-10-15：`tools\导入预算.ps1` / `tools\boot余量.ps1`）
- 生态层：无包管理、无第三方库（只能直调 DLL）、无 LSP / 格式化工具、文档以中文为主
- 诊断层：那 3 条"写错了却不报错 / 指错方向"的已知缺陷**已于 2026-10-13 清零**（模块名 >63 字节静默截断 ／ 全局初值尾巴静默丢值 ／ 字符串模块名被注入库挡住 = 假拒绝）—— 全部改成**默认档硬错**并各配探针 `wall` 用例；剩余缺口见 `开源前-人类可用性缺口.md` §3-B1

## 3. 目录导航

| 路径 | 是什么 |
|---|---|
| `src\` | 编译器本体（C，**<!--fact:src-files-->9<!--/fact--> 个源文件（7 个 `.c` ＋ 2 个 `.h`）／<!--fact:src-loc-->11937<!--/fact--> 行**，英文注释）：词法/语法/代码生成/PE 写出 |
| `lib\` | FLINT 标准库（`.fl`）：`str/num/fmt/mem/vec/io/http/math/chr` ＋ **FLGUI**（`flgui*.fl`） |
| `apps\` | 真实项目：`winpanel`（旗舰工具）/ `m2_float`（硬件浮窗）/ `ui_gallery`（控件画廊）/ `student`（最小示例） |
| `examples\` | **五个能抄的示例**：hello / 中文打印 / 退出码当输出 / 文件 I/O / 最小窗口 —— 每个一条 `build.ps1`，`examples\run-all.ps1` = **<!--fact:examples-passed-->5/5<!--/fact--> passed** |
| `boot\` | 自举编译器（用 FLINT 写的 FLINT）＋ `verify.ps1`（**<!--fact:boot-verify-->304/304<!--/fact-->**，含不动点） |
| `test\` | 门与判据：`verify-all.ps1`（总门 <!--fact:gate-steps-->14<!--/fact--> 步）/ 各专项门 / **<!--fact:test-corpus-->305<!--/fact--> 个 `.fl` 语料** / **`边界探针.ps1`** |
| `tools\` | 仪器：边界覆盖对账 / 导入预算 / boot 余量 / 预算基线门 |
| `docs\` | 对外文档（**协作协议从这里开始**） |
| `SPEC.md` | 语言设计原则 1~<!--fact:spec-principles-->11<!--/fact--> 与长期目标（权威） |
| `PROGRESS.md` | 工程进度档案（"做到哪了"，头部交接块） |

## 4. 怎么参与

**提一条判据，就是一次贡献。** 本项目最看重的东西是把"必须靠人记住的规则"变成"机器能替你检查"：

- 发现 bug → 给 **命令 + 实际输出 + 期望输出**（可复现的最小样本最好）
- 提规则 → 直接给一条探针用例（`test\边界探针.ps1` 的三类：`ok` 断退出码 / `wall` 断报错关键词 / `gap` 断"仍然编得过"）
- 提特性 / 改语言 → 走 `SPEC.md` 设计原则 ＋ **命名必须先给候选、由所有者拍板**（原则 7）

完整的"怎么和我们一起干活"（包括这个项目是 **AI 主力开发、人做拍板**这件事怎么协作）→ **`docs\协作协议.md`**。

## 5. 状态

- 这是**每天在动**的项目：版本、门数、缺口都在变 —— 数字以上面那把"可跑的门"为准，不以文档为准
- 回退与留底：每个改动都有 commit ＋ 留底；`PROGRESS.md` 头部写着当前交接点与回退点
- 许可：**MIT**（`LICENSE`，2026-10-13 入库）；文档 **CC BY 4.0**（2026-10-19 已定，见 `docs\协作协议.md` §7 第 6 项）
