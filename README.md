# FLINT_CHAN

> 名字：**FLINT_CHAN**（叫法：**FLINT**，简称 **FL**）

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`（本文数字都是「事实标记」，值由取数器现算，不手抄）
> 引用我=—（本文是入口） ｜ 我引用=`docs\README.md`、`docs\快速上手.md`、`docs\语言参考.md`、`docs\标准库.md`、`docs\FLGUI.md`、`test\verify-all.ps1` ｜ 最后复核=2026-10-19 `test\docgate.mjs`

> **一句话**：**暂时以 Windows 桌面开发为核心的发展中语言，目标是 Zig / C++ / Rust。**
>
> 现在的读法：**一个自己写机器码的 Windows x64 编译器 ＋ 一个自绘 GUI 库（FLGUI）**。
> 从源码到 PE 的每一步都自己做 —— 不借 LLVM、不借汇编器、不借链接器、不借 C 运行时。

| 事实 | 数字 / 说明 |
|---|---|
| 编译器版本 | v<!--fact:version-->1.7.0<!--/fact--> |
| 产物 | 纯自产机器码 PE，无 CRT ／ 无运行时依赖；`hello` = <!--fact:product-hello-->3072<!--/fact--> B |
| 自举 | `boot\` 里的自举编译器已达**不动点**（boot 编自己，产物与真 flint 逐字节一致） |
| 门（可自己跑） | 总门 <!--fact:gate-steps-->14<!--/fact--> 步 ｜ 语言边界探针 <!--fact:probe-cases-->44<!--/fact--> 条 ｜ FLGUI 门 <!--fact:flgui-checks-->210/210<!--/fact--> |
| 平台 | Windows 10 x64（明确放弃 Win7）；单目标、单平台 |
| 参与方式 | **暂时只收工单（issue），不接受外部 PR** —— 语言大到能给别人开口子之前，方向不摊开 |
| 许可 | 源码 **MIT**（`LICENSE`）；文档 **CC BY 4.0** |
| AI 参与 | 代码主要由 AI 编写，所有者定方向与验收（如实披露，不淡化） |

## Abstract (English)

FLINT_CHAN, called FLINT for short, is an in-development language that is, for now,
centered on Windows desktop development, aiming at Zig, C++, and Rust. Today it is a
compiler that emits raw x86-64 machine code and PE files by itself — no LLVM, no
assembler, no linker, no C runtime — plus FLGUI, an immediate-mode GUI library drawn by
the language itself. This page is the front door: what the project is, the three
commands that build it, the repository layout, and an honest list of what it cannot do
yet. Technical docs live in `docs/`; process notes are not published.

---

## 30 秒构建

前置：Windows 10 x64、MinGW-w64 的 `gcc`、PowerShell。**在仓库根目录**执行：

```cmd
:: 1) 构建编译器（约 9 秒）
cmd /c "gcc -O2 src\*.c -o flint.exe"

:: 2) 编译并运行第一个程序
.\flint.exe examples\hello\hello.fl
.\examples\hello\hello.exe
```

```powershell
# 3) 自己验一遍"边界表说的是真的"（44 条语言边界用例，全绿 = 与文档一致）
powershell -NoProfile -ExecutionPolicy Bypass -File test\边界探针.ps1
```

⚠️ **两个必踩的坑**（我们先替你踩了）：
1. **别在 PowerShell 里直接写 `gcc src\*.c`** —— PowerShell 不给原生程序展开通配符，会报 `cc1.exe: too many filenames given`。用上面的 `cmd /c`，或显式列出 `.c` 文件。
2. **编译器要放仓库根目录**（或别处但同目录要有 `lib\`）—— `include` 的解析顺序是「本文件目录 → **编译器 exe 所在目录的 `lib\`**」。

最小可跑程序（注意 `print` 吃的是**数组**，不是普通函数调用）：

```
int main() {
  print(["hello, flint\n"]);
  return 0;
}
```

## 仓库结构

| 路径 | 是什么 |
|---|---|
| `src\` | 编译器本体（C）：词法 / 语法 / 代码生成 / PE 写出；<!--fact:src-files-->9<!--/fact--> 个源文件（7 `.c` ＋ 2 `.h`）／<!--fact:src-loc-->11937<!--/fact--> 行 |
| `lib\` | FLINT 标准库（`.fl` 源码库）：字符串 / 数字 / 容器 / 文件 / 数学 / FLGUI |
| `apps\` | 用 FLINT 写的真实程序：`winpanel`（工具面板）、`m2_float`（硬件浮窗）、`ui_gallery`（控件画廊） |
| `examples\` | 五个能抄的示例：hello / 中文打印 / 退出码 / 文件 I/O / 最小窗口（`examples\run-all.ps1`） |
| `boot\` | 自举编译器（用 FLINT 写的 FLINT）＋ `verify.ps1` |
| `test\` | 门与判据：总门 `verify-all.ps1`（<!--fact:gate-steps-->14<!--/fact--> 步）／边界探针／FLGUI 门 |
| `tools\` | 仪器：预算 / 余量 / 边界对账 / 文档事实取数 |
| `docs\` | **技术文档（重写版）**，入口 [`docs\README.md`](docs/README.md) |

## 技术文档

本仓库**只公开源代码 ＋ 重写过的技术文档**；过程记录、设计讨论、台账不对外。

| 文档 | 讲什么 |
|---|---|
| [`docs\README.md`](docs/README.md) | 技术文档入口：阅读顺序、数字怎么来的 |
| [`docs\快速上手.md`](docs/快速上手.md) | 环境、构建、第一个程序、跑门、常见坑 |
| [`docs\语言参考.md`](docs/语言参考.md) | 类型 / 语句 / 函数 / 结构体 / 指针 / API 声明 / 编期限制 |
| [`docs\标准库.md`](docs/标准库.md) | `lib\*.fl` 每个模块的用途与入口 |
| [`docs\FLGUI.md`](docs/FLGUI.md) | 立即模式 GUI 库：层次、控件、输入、限制 |

## 现在能做什么 / 还不能做什么

**能做**（都有跑通的真实产物）
- 控制台工具、系统工具：按 `api` 声明直调 Windows DLL（导入表硬上限 <!--fact:limit-imports-->96<!--/fact--> 条 API / <!--fact:limit-groups-->8<!--/fact--> 个 DLL）
- **桌面 GUI**：FLGUI 是立即模式库（自绘 ＋ 分层窗口），控件、焦点链、多字体档、透明/圆角/投影都在真实项目里用着
- 一键出**单文件 exe**：无安装器、无运行时依赖、冷启动无初始化

**不能做 / 还没有**（诚实账）
- 语言层：无泛型、无无符号整型、无异常、无 `sizeof`、无 C 风格转型
- 平台层：只有 Windows x64；无多窗口、无高 DPI、IME 只"绕过"未"支持"
- 生态层：无包管理、无第三方库（只能直调 DLL）、无 LSP / 格式化工具
- 边界与坑：以 `docs\语言参考.md` 和 44 条探针为准 —— **文档与探针打架时，信探针**

## 参与

**提一条判据，就是一次贡献。** 本项目最看重把"必须靠人记住的规则"变成"机器能替你检查"：

- 发现 bug → 给 **命令 ＋ 实际输出 ＋ 期望输出**（最好带最小可复现样本）
- 提规则 → 直接给一条探针用例（`test\边界探针.ps1` 的 `ok` / `wall` / `gap` 三类）
- 提特性 → 先开 issue 说清动机与判据；语言层面的取舍由所有者拍板

## 许可

源码 **MIT**（见 `LICENSE`）；文档 **CC BY 4.0**。
