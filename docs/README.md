# FLINT 技术文档

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`（本文数字都是事实标记，值现算）
> 引用我=`README.md` ｜ 我引用=`docs\快速上手.md`、`docs\语言参考.md`、`docs\标准库.md`、`docs\FLGUI.md` ｜ 最后复核=2026-10-19 `test\docgate.mjs`

这里讲**怎么用 FLINT**，不讲项目怎么演进。项目是什么、现在到哪了，见仓库根 `README.md`。

## Abstract (English)

This is the technical-documentation entry point. It maps four documents: a getting-started
walkthrough (environment, build, first program, gates, traps), a language reference
(types, statements, functions, structs, pointers, API declarations, compile-time
limits), a standard-library guide (the `.fl` modules under `lib/`), and a GUI guide for
FLGUI. Every number in these pages is a fact marker computed from the source tree, so the
docs cannot silently drift from the compiler. When a page and the boundary probes
disagree, the probes win.

## 阅读顺序

| 顺序 | 文档 | 适合谁 | 读完能做什么 |
|---|---|---|---|
| 1 | [`快速上手.md`](快速上手.md) | 会一点 C、第一次碰 FLINT | 构建编译器、跑通 hello、自己跑门 |
| 2 | [`语言参考.md`](语言参考.md) | 要写程序的人 | 知道类型怎么布、函数/结构体/指针能写到哪一步、哪里会撞墙 |
| 3 | [`标准库.md`](标准库.md) | 要少造轮子的人 | 找到字符串/容器/文件/数学对应的模块与入口 |
| 4 | [`FLGUI.md`](FLGUI.md) | 要做 Windows 界面的人 | 写一个立即模式窗口、用控件、知道限制 |

## 数字从哪来

- 文中数字一律写成**事实标记**（一种机检注释），值不是手写的，由 `tools\文档事实.ps1` 从源码现算；
- 改完代码跑一遍 `node test\docgate.mjs`：任何数字漂移都会变红，**红了是文档错，不是门错**；
- 语言边界以 `test\边界探针.ps1` 的 <!--fact:probe-cases-->44<!--/fact--> 条用例为唯一真值源（`ok` = 必须编过／`wall` = 必须硬错／`gap` = 仍然编得过但已知）。

## 这份文档的边界

- **完整 API 签名还没逐条重写**：`lib\*.fl` 与 `src\` 的源码是唯一权威，本文只保证"说法与实现一致、数字可机检"；
- **错误文案**已经先做成机器台账：`tools\错误台账.md` 由 `tools\错误台账.mjs` 从 `src\*.c` 扫出全部报错点（新增/删除/改一个字都会让文档门变红），等措辞定稿后再改写成对外的一节；
- 计划中的补充：逐模块函数签名、性能基线。没写的不装写。
