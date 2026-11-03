# FLINT_CHAN

> ⚠️ **现行结论见 [`docs\现状.md`](docs/现状.md)**（唯一结论页）：**成功判据 = 被参考**；位置不变、不做生态；主线 = 游戏。

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`
> 引用我=—（本文是入口） ｜ 我引用=`docs\现状.md`、`docs\README.md`、`docs\快速上手.md`、`docs\语言参考.md`、`docs\标准库.md`、`docs\FLGUI.md` ｜ 最后复核=2026-11-04 `test\docgate.mjs`

| 名字 | 是什么 |
|---|---|
| **FLINT_CHAN** | 全名（缩写 FLC） |
| **打火石** | 中文名 |
| **hlc**（火镰） | 编译器 |
| `.fl` | 源码后缀 |

## 这是什么

一个**自己写 x86-64 机器码、自己写 PE** 的 Windows 编译器，加一套纯源码级标准库和自绘 GUI 库。
不借 LLVM，不借汇编器，不借链接器，不背 C 运行时。

- **产物**：单文件 exe，带完整界面的工具也只有几百 KB，零依赖、双击就跑
- **自举**：编译器能用自己编译自己（`hlc` 与 `boot` 两套实现逐字节对撞）
- **标准库**：字符串 / 容器 / JSON / HTTP(S) / TCP·UDP / PNG 解码 / 剪贴板 / 注册表 / 哈希 / 日期
- **界面**：FLGUI（立即模式），窗口、按钮、文字全部自绘

## 快速上手

```bash
hlc hello.fl          # 编译 -> hello.exe
hlc build hello.fl    # 编译 -> build\hello.exe
hlc run hello.fl      # 编译并运行，退出码就是 main 的返回值
```

## 现在缺什么

- 只有 **Windows x64**，没有跨平台
- 标准库薄：写正经东西还得自己造轮子
- 没有包管理器、没有生态：用一个库 = 复制一份源码
- 报错与文档只能算及格

## 文档

| 文档 | 讲什么 |
|---|---|
| [`docs\现状.md`](docs/现状.md) | **现在是什么 / 下一步**（唯一结论页） |
| [`docs\README.md`](docs/README.md) | 入口：阅读顺序、数字怎么来的 |
| [`docs\快速上手.md`](docs/快速上手.md) | 环境、构建、第一个程序、跑门、常见坑 |
| [`docs\语言参考.md`](docs/语言参考.md) | 类型 / 语句 / 函数 / 结构体 / 指针 / API / 编译期限制 |
| [`docs\标准库.md`](docs/标准库.md) | 每个 `lib\*.fl` 模块的用途与入口 |
| [`docs\FLGUI.md`](docs/FLGUI.md) | 立即模式 GUI 库 |

## 介绍视频

`art\FLC-intro-v5.mp4`：约两分钟，讲优点、缺点、真实游戏操作和源码。

## 许可

源码 **MIT**（`LICENSE`）；文档 **CC BY 4.0**。
