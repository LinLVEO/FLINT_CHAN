# FLINT明细.md — 技术借用 / 参考台账

> **为什么有这份**：FLINT 的路子之一是「**多语言交火**」——自己搓不出来的就用现成的，谁擅长什么就上什么（2026-09-16 用户提出）。
> **两本账分开记**（这是纪律，别混）：
> - **本文件 = 借用账**：借来的轮子（谁提供 / 版本 / 许可 / 怎么用 / **为什么不自己搓** / 回退兜底）
> - **语言账在 `SPEC.md`**：FLINT 自己的语言能力**不因"别人已经有好用的了"而砍**——借用只发生在**产品/工具层**，语言该长的照长
>
> **四条纪律**：① 交火面必须是**可替换的窄接口**（接别人 / 自研两条路能互换 = 可回退）② 每条借用必须写清**许可**（静态缝合 GPL 系会传染产物）③ 借来的火力点必须有**降级兜底**（崩了不拖垮主程序）④ 判据：**这里 FLINT 独有的贡献是什么**——答不出来就是退化成外壳
>
> 🔒 **硬性规则（2026-09-16 用户定，长期有效）**：**以后凡「借用」或「参考」——不分层（构建期工具 / 运行期库 / 命令行工具 / 只读抄口径 / 抄别人的算法）——一律记进本文件。**
> 没有记进来的借用，视为**没发生**（下次会话查不到 = 不知道有这回事）。借了新的、换了版本、发现更好的替代、许可有变，都要回来改这里。
>
> **建档**：2026-09-16（任务卡 `T-20260916-033721`）｜**维护**：借了新的/换了版本就补一行；许可以"上手前逐条查证"为准。

---

## 一、已实测借用 —— 零微软工具把 C# 编成原生 DLL（2026-09-16 野路子）

> **目标**：C# 侧（AOT 友好的小库）导出 **C ABI** 函数 → FLINT 在**编译期**把 `模块!函数` 写进 PE 导入表 → 运行期一次 `call`，**零查表、零 JSON 解析**。
> **为什么借**：NativeAOT 官方要求装 VS 的 C++ 工作负载；本机没有、也不想装 → 全线改走 NuGet ＋ 现成工具。

| # | 借什么 | 提供方 | 版本 | 许可（**待逐条核条款**） | 干什么用 | 为什么不自己搓 |
|---|---|---|---|---|---|---|
| **B1** | `Microsoft.DotNet.ILCompiler` | 微软 dotnet/runtime | 8.0.30 | MIT | `ilc`：C# → 原生 COFF | 自研 IL→机器码是另一个工程 |
| **B2** | `runtime.win-x64.Microsoft.DotNet.ILCompiler` | 同上 | 8.0.30 | MIT | 原生 AOT 运行时静态库（GC 等 **14 个 `.lib`**，含 `Runtime.WorkstationGC.lib` 5.2MB） | 同上（GC 更不可能自搓） |
| **B3** | `LLD.Link.Toolsets.win-x64` | LLVM Project / DotNet-AGPL | 22.1.8.7 | **MIT 或 AGPL-3.0-or-later**；内含 `lld-link` 本体 = Apache-2.0 WITH LLVM-exception | **替代 VS 的 `link.exe`**（MSVC 兼容 COFF 链接器） | 自己写 COFF 链接器 = 究极形态（P2），现在不做 |
| **B4** | `Microsoft.Windows.SDK.CPP.x64` | 微软 | 10.0.28000.2705 | 微软 SDK 许可（**用前必核**） | Windows SDK 的 **461 个 `.lib`**（`kernel32/advapi32/ole32/…/ucrt`） | 就是系统头/库的官方分发，无自搓意义 |
| **B5** | MinGW-w64 导入库 `lib*.a` | MinGW-w64（本机 gcc 16.1） | 随 GCC 16.1 | MinGW-w64 运行时属宽松许可；GCC 部分 GPLv3 **带运行时例外** | ① 缺的系统导入库顶上（改名成 `<name>.lib`）② 缺的 C 函数（`memcmp/strstr/malloc`） | 已有现成，改个名的事 |
| **B6** | `crtshim`（**不借，自己补**） | 本工程 | — | 自有 | 补 MSVC 静态 CRT 最后的 10 个符号（见附录） | 只有 10 个符号，自己写比找库快 |

**关键"借用点"（不是破解点）**：官方 targets 自己留了后门 —— `IlcUseEnvironmentalTools=true` 会让它**跳过找 VS**（`Microsoft.NETCore.Native.Windows.targets` 第 107 行），此时链接器取默认名 `link`，可用命令行属性 `-p:CppLinker=<全路径>` **整体换成任何兼容链接器**（MSBuild 全局属性项目文件覆盖不了）。

### ⚠️ 还没跨过去的那一步（诚实标注）

**编译半程已实测走通**（`ilc` 产出 3.4MB 原生 COFF，零微软工具）；
**链接半程卡在最后 10 个符号**（全在 VS 专有的 MSVC 静态 CRT `libcmt/libcpmt` 里）。精确修饰名已用 `nm` 从运行时库挖出（见附录），**下一轮就补垫片**。
链出来 ≠ 跑得起来：TLS 目录、`.CRT$XCU` 静态初始化、GC 初始化时序都还要验。

---

## 二、现成火力点（在用的"别人的轮子"）

| 火力 | 提供方 | 许可（待核） | 用途 | 状态 / 降级 |
|---|---|---|---|---|
| **LibreHardwareMonitor** | LHM 项目 | MPL-2.0（待核） | 硬件读数（CPU/GPU/RAM/磁盘/网速/温度/功耗） | 在用（经 C# 侧 8080 转发）｜降级：本地直读（已知偏差） |
| **C# 浮窗 8080 JSON 接口** | 本工程 | 自有 | 浮窗数据源 | 在用（`tmp\row-probe\http.on`）｜降级：本地直读 |
| **WinRing0（改名 `HardwareMonitor.sys`）** | 第三方 | ⚠️ **已被微软列入漏洞驱动黑名单** | 驱动级读 MSR | 在用（LHM 同款）｜风险自负，优先别自造 |
| **PresentMon** | Intel | **MIT**（`PresentMon.exe` 随产物分发；版本见下） | FPS（ETW，不注入；含 1% low 与来源进程名） | **在用**（2026-09-17 接入：桥内起子进程 + 解析 stdout CSV）｜降级：RTSS 共享内存 → `--` |

> **PresentMon 借用台账**（2026-09-17 登记；铁律：没记 = 没发生）
> - **文件**：`PresentMon.exe`，421,312 字节，文件时间 2026-08-30 14:14
> - **来源**：本机既有副本 `E:\HardwareMonitor\PresentMon\PresentMon.exe`（C# 参考版 8080 用的同一份），构建脚本会比对哈希后复制到交付目录
> - **登记版本线索**：该副本随 C# 参考版于 2026-08-30 引入；参数面已实测（`--output_stdout` / `--session_name` / `--stop_existing_session`；`--no_csv` 与 `--output_stdout` 互斥）
> - **许可**：Intel PresentMon = MIT（上游仓库声明）
> - **用法**：桥内以子进程运行，`--output_stdout --session_name PresentMonHWBRIDGE<PID>_<tick>`（唯一名，避免与参考版/自身残留抢会话）；子进程随宿主退出，被强杀时下次启动清扫孤儿
> - **成本实测**：CPU 0.0488% / 12.5 MB（20 秒窗口）

---

## 三、只读参考（抄口径/做法，不链接、不引入依赖）

| 参考什么 | 来源 | 抄到了什么 |
|---|---|---|
| LHM `AmdGpu.cs` | 源码 | GPU 功耗口径 `powerOf8 >> 8`（低 8 位是小数）——"单位换算照抄源码，别自己猜"的范本 |
| MSDN PE 规范 | 官方文档 | **must** 清单（`SizeOfImage` 必须是 `SectionAlignment` 整数倍 → 抓到 9/69 违规） |
| **DWARF 5 / 4 规范** | 官方标准 | **行号表最小集与常量口径**：头字段顺序、`line_base=-5 / line_range=14 / opcode_base=13`、标准操作码参数表；**`file` 寄存器初值是 1** ⇒ `file[0]` 与 `file[1]` 都要放主源文件（否则未显式 `set_file` 的行会越界）。落点 `src/debug.c` |
| **GCC 16 / binutils 2.46 的真实 PE 产物** | 本机 `E:\mingw64`（读字节，非引用代码） | **DWARF 在 PE 里的落地形态**：`/nnn` 长节名 + COFF 字符串表（`[u32 总长][名字\0…]`，首个名字在偏移 4）、`.debug_*` 节特征位 `0x42000040`、单位置 CU 也要 `DW_AT_low_pc/high_pc` 才对 gdb 生效、`comp_dir` 必须写**绝对路径** |
| **`ld.bfd(1)` 手册** | binutils 文档 | 原话 *"GDB relies on the use of PE long section names to find Dwarf-2 debug information sections in an executable image at runtime"* ⇒ 镜像里的"长节名 + 字符串表"是**明知故犯**（规范说镜像不该有符号表），我们不发明、照抄 |
| **TinyCC `tccdbg.c` / `tccpe.c`** | 源码（只读） | 「自产 PE + 自产 DWARF」的**公开先例**（它同样要造 `.coffsym`/`.coffstr`）；本轮只借它的**结论**（这条路走得通、要处理 COFF 字符串表），未抄任何代码 |
| **objdump / addr2line / gdb** | 本机工具链（binutils 2.46 / gdb 17.2） | **验证期工具**：可审计发射层的三通道验收（`test\debug-verify.ps1`）靠它们做机器比对。**不在构建链里、不进产物、不随产物分发** |
| `dotnet/runtime` 的 NativeAOT targets/issue | 源码 + issue | 链接器可替换（`CppCompilerAndLinker` 用系统链接器是已知议题） |
| `MichalStrehovsky/PublishAotCross`、`xljiulang/PublishAotClang` | 开源项目 | "不用 VS 做 AOT"的先例（别人也在这条路上摸索） |
| **MSDN PE Format：数据目录 12（IAT）/ DEP / 节权限位** | 官方文档（本轮**自己抓原文**核对，不是二手转述） | **"哪些是 must、哪些不是"**：IAT 目录规范只写"地址与大小"、**没有 must**（订正了调研期那句"只读节里放 IAT 必须给 index 12"）；DEP 文档才给"代码节必须显式标 X"；**RWX 的唯一官方 normative 禁止来自 UEFI CA 签名要求，不是 PE 规范** —— 所以我们禁 RWX 是**自己的硬化子集策略**，必须如实这么表述。落点 `开工简报-可审计发射层.md` §3.1 / §3.3 订正块 |
| **本机 GNU ld 产物（MinGW，读字节）** | 本机 `E:\mingw64` | 节权限先例：`.text`=R\|X、`.data`=W、`.rdata`=R、`.idata` 独立成节；**数据目录 12 会写**（实测 `0x0000b2c8 / 0x200`）；`DllCharacteristics=0x0160`（`DYNAMIC_BASE`\|`HIGH_ENTROPY_VA`\|`NX_COMPAT`）= 第三步第二项（ASLR）可直接对标 —— **已落地**（v1.4.14：我们的产物现在也是 `0x0160`）；✅ **订正（2026-09-18）**：原文此处写"顺带量到一处头布局差异 —— 我们的产物少了 OS/Image/Subsystem 版本那一块（0x18 字节）"，**实测不成立**：我们的产物**写了**版本块（`opt+0x28/0x2C/0x30/0x34`），且 `Subsystem(0x44)`／`DllCharacteristics(0x46)` 等全在 **PE32+ 规范位置**（文件偏移 `0x9E` = `opt+0x46` 就是规范位置；本机 ld 产物 `opt=0x98` → `0xDE`，同一公式；4 种产物形态 ＋ `objdump -p` 独立复核）。真实情况 = 当时把**自己写错的偏移**当成了规范偏移 ⇒ 无需补任何字段；已加布局钉子（门 `test\wx-verify.ps1` 第 [7a] 节）防复活 |
| **`libcs\aslrprobe\`（自产只读探针，v1.4.14）** | Windows API（`CreateProcess(CREATE_SUSPENDED)` → 读**子进程 PEB.ImageBaseAddress** → 与镜像自己写的 PreferredBase 比对） | **「loader 到底把镜像放哪了」的唯一直接证据**：判据 = `loaded ≠ preferred`（不是"跑 N 次地址不同"的概率论证）。配方与实测见 `PROGRESS.md` 本轮记录 ＋ 门 `test\wx-verify.ps1` 第 [7] 项 |
| **`CreateProcess(CREATE_SUSPENDED)` + `NtQueryInformationProcess` + `ReadProcessMemory` + `VirtualQueryEx`** | Windows API（**只读**查询：不改目标内存、不注入、不挂钩子） | **运行时「实际」保护级别**（声明位 ≠ 实际保护）。落地 = 自产探针 `libcs\wxprobe\`（两个采样时刻 A/B ＋ 启动窗口 20 万次/秒级密集采样）；配方与实测结果见 `PROGRESS.md` 本轮状态记录 ＋ `测试门 test\wx-verify.ps1` 第 [3] 项 |
| **Dear ImGui**（C++，MIT） | 上游项目**设计**（不是二进制） | **只抄它的「immediate-mode」理念 ＋ "GUI 可以极小、无依赖"这个证明**，**绝不引它的 C++ 实现**（会把 C++ 运行时／链接器／庞大依赖拖进来 → 破"零垫层"守门线）。落地 = 自产的 **FLINT-UI v0.1**（v1.0 定版：`FillRect`/`TextOutA`/`hit_rect`/鼠标 lParam 解析，demo 双按钮+计数条实证）；书面记录见 `SPEC.md` 第 27 行 —— **这就是"参考"（抄设计不抄实现）的样板**，也是「**门面不能建在别人的二进制上**」这条纪律的由来 |

---

## 四、已知缺口（**借不到、只能自己长**——记在语言账上）

| 缺什么 | 为什么要 | 属于 |
|---|---|---|
| FLINT 侧**导入表支持任意 DLL 名** | 编译期缝合的前提（`pe.c` 现在只把 `kernel32/user32/gdi32` 短名映射成 `xxx.dll`，其余全特判） | 编译器能力 |
| **导出表 ＋ `IMAGE_FILE_DLL`** | 让 FLINT 从"借用者"变"供给者"（别人能调 FLINT 编的 DLL） | 编译器能力 |
| **COFF / `.lib` 静态缝合** | 究极形态（P2）：把别人的库**吃进产物**，更小更快 | 编译器能力（最重） |
| 回调可用性验证（把自己的函数指针交给别人的库） | 用 `EnumWindows` 一类回调式 API | 待验证（零件已有：函数指针对 + `&函数名`） |

---

## 四·五、FLGUI（UI 库）的借用 / 参考（2026-09-22 规划阶段，**只登记、尚未动手**）

> 立卡 `T-20260922-040804`；计划见 `FLGUI-计划.md`；规则照旧：**没记 = 没发生**，改动前回来看这一节。
> 均属**只读参考／算法蓝本**（不链接、不引入依赖、不复制粘贴 C 源），与 SPEC 原则 8/9/10 的守门线一致。

| 谁提供 | 版本 | LICENCE | 怎么用 | 为什么不自己搓 | 回退兜底 |
|---|---|---|---|---|---|
| **rxi/microui**（`rxi/microui`，GitHub） | `MU_VERSION "2.02"`；实测 `microui.c` **1209 行 / 37,707 B**、`microui.h` **297 行 / 9,644 B** | **MIT**（`Copyright (c) 2024 rxi`，LICENSE 原文）—— 翻译/改写/闭源均可，**须保留版权与许可声明** | **算法蓝本 ＋ 逐函数语义对照**（命令流 ＋ `MU_COMMAND_JUMP` 重连做裁剪／FNV-1a `mu_get_id` ＋ `mu_push_id` 索引混入／`mu_Layout` 负宽度行布局／`mu_update_control` 的 hover+focus／池化保留态）。★ **官方 demo 只有 SDL2+OpenGL，没有 Win32/GDI 后端**（GitHub API 实测） | 这五块是 1209 行成熟设计、被 Zig 与 APL 各再实现过一次；在"1100 行预算"里自己重发明是纯浪费 | 命令表若"字节流 + 指针步进"不可行 ⇒ 退"**定长并列数组 + 文本 arena**"（本仓已实测可行，见 `FLGUI-计划.md` §2） |
| **Immediate-Mode-UI/Nuklear** 的 GDI 后端（`demo/gdi/nuklear_gdi.h`） | 库内 `VERSION v4.13.3`；后端文件头部写 1.32.0（**版本号不一致，以文件为准**）；后端实测 **1091 行 / 32,173 B** | 库本体 **MIT 或 public domain 二选一**（LICENSE 原文）；GDI 后端文件自述 public domain。⚠️ GitHub API 报 `NOASSERTION`（双许可无法归类）⇒ **登记以 LICENSE 文件原文为准** | **只借 Win32 骨架**：`CreateCompatibleBitmap` + `BitBlt` 双缓冲、`WM_PAINT/WM_CHAR/WM_MOUSEMOVE/WM_SIZE` 的 switch 结构、`SetCapture`、`IntersectClipRect` 裁剪、`ExtTextOutW(ETO_OPAQUE)` 填色、`RoundRect` 圆角、`CreateFontA` 14 参取值 | 这些是 Win32 既定机械动作，自己重推只会重踩同样的坑；它也是"**纯 GDI 无 GL/D2D 的 IMGUI 可行**"的存在性证据 | 若嫌许可不够干净 ⇒ 按 Microsoft Learn 官方 API 文档 + 社区双缓冲教程自写骨架（同属"照抄级"机械劳动） |
| **raysan5/raygui** | `src/raygui.h` 实测 **6465 行 / 311,668 B** | **zlib/libpng**（`Copyright (c) 2014-2026 Ramon Santamaria`） | **不借实现**；只参考它的**图标打包法**（512 个 16×16 的 1-bit 图标共 **4096 字节** 数组 ＋ `#iconId#` 文本前缀语法），比 microui 的 4 个手绘图标更省事 | 实现依赖 raylib 的绘制原语，在"零第三方运行时"下要另写兼容层 ⇒ 比写 FLGUI 还贵 | 图标自己画（101 行数据级） |
| **Mints97/tinyGUI** | — | ⚠️ **仓库根目录无 LICENSE 文件（实测 404）** | **不可借用**（仅可作"Win32 小 GUI 库长什么样"的阅读参考） | 无许可 ⇒ 无授权来源 | — |
| **ocornut/Dear ImGui** | core 四文件 ≈ **41k 行**（`imgui.cpp` 18,700 行 ／ `imgui.h` 4,325 ／ `imgui_widgets.cpp` 11,163 ／ `imgui_draw.cpp` 6,833；`backends/imgui_impl_win32.cpp` 1,009） | **MIT** | **只作"文档引用"**：把 FAQ／PROGRAMMER GUIDE 当设计判据的权威出处（ID 栈与"同一 label 同一 ID 是最常见错误"、`WantCapture*` 的用法、ClipRect 是 `x1y1x2y2` 不是 `wh`、DPI 要显式声明） | C++、几万行，与"一个人读得完"冲突（SPEC 已定 **抄架构不抄实现**） | — |

**不借清单（microui 尺度上明确不做，写进 FLGUI 文档免得被当漏项）**：剪贴板（要后端接 OS）、可编辑文本框的光标/选区/undo、中文输入法 IME、键盘导航/Tab 序、下拉框/菜单栏/多窗口停靠、tooltip 闪烁类重叠交互、无障碍。依据：microui 本体就没有这些；ImGui 的官方文档亦自认 **"full internationalization … and accessibility features are not supported"**。

---

## 附录 A · 本次实测配方（可复现）

```powershell
# 1) 拉包（全走 NuGet，零微软工具）
#    Microsoft.DotNet.ILCompiler 8.0.30（publish 时自动还原，含 RID 包 14 个 .lib）
#    LLD.Link.Toolsets.win-x64 22.1.8.7        -> tools\lld-link.exe
#    Microsoft.Windows.SDK.CPP.x64 10.0.28000.2705 -> c\ucrt\x64 + c\um\x64（461 个 .lib）

# 2) 用后门属性 + 换链接器（csproj 里再补 /LIBPATH 与额外输入）
dotnet publish CsLib.csproj -c Release -r win-x64 -o out `
  -p:IlcUseEnvironmentalTools=true -p:CppLinker="<...>\lld-link.exe"

# 3) csproj 里注入的 LinkerArg（关键几条）
#    /LIBPATH:<sdk>\ucrt\x64 ; /LIBPATH:<sdk>\um\x64 ; /LIBPATH:<MinGW 映射目录>
#    <crtshim.obj> ; <MinGW>\libmsvcrt.a ; <MinGW>\libmingwex.a
#    /NODEFAULTLIB:LIBCMT ; /NODEFAULTLIB:OLDNAMES ; /NODEFAULTLIB:libcpmt
```

**MinGW 导入库映射手法**：把 `libkernel32.a` 等**改名为** `kernel32.lib` 放进一个目录并 `/LIBPATH` 指过去（lld-link 按 `<名字>.lib` 找）。

## 附录 B · 最后 10 个符号（`nm` 挖出的**精确修饰名**，下一轮垫片就补这些）

```
C++ 运算符/对象：??2@YAPEAX_KAEBUnothrow_t@std@@@Z   (nothrow new)
                ??_U@YAPEAX_KAEBUnothrow_t@std@@@Z  (new[])
                ??3@YAXPEAX_K@Z                      (delete)
                ??_V@YAXPEAX@Z                       (delete[])
                ?nothrow@std@@3Unothrow_t@1@B        (std::nothrow 对象)
DLL 入口：      _DllMainCRTStartup
TLS：           _tls_index
栈保护：        __security_cookie / __security_check_cookie / __GSHandlerCheck
```
> ⚠️ **踩过的坑**：美化后的名字（如报错信息里的 `operator new(unsigned __int64, struct std::nothrow_t const &)`）**不能拿来当符号名用**——必须用 `nm` 从 `.lib` 里挖**真修饰名**（我第一版把 `AEBU` 猜成 `PEBU`，`/alternatename` 静默失效）。
>
> **2026-09-16 补两点（同族，都是"猜名字"的坑）**：
> ① **修饰名里紧跟在 `??N@` 后面的第 4 位是返回类型码** —— `YAX` = 返回 **void**、`YEAX` = 返回**非 void**；
>    我按 `YEAX` 去猜两个 `operator delete` 的名字 → `/alternatename` **静默失效**（不报错、只在链接期表现为符号仍缺），
>    而链接器报错只打**去修饰名**（`void __cdecl operator delete(void*)`）、**看不到真修饰名** → 只能 `nm` 挖。
> ② `?InitializeRuntime@@YAHXZ` 在 obj 里是 **`t`（static 局部符号）**，**外部引用不到** —— 写进 `/INCLUDE` 照样报 undefined symbol。
> ⇒ **判据：补符号前一律 `nm` 挖真名，别按美化名 / 报错文案猜。**

## 附录 C · 现场与回退

- 探针现场：`E:\FLINT-lab\tmp\cs-aot-probe\`（lld 70MB ＋ SDK 192MB，**约 300MB，可整删**）
- 回退：删该目录即回到起点；**不涉及任何系统级安装/注册表/PATH 改动**
- 相关卡：`T-20260916-033721`

---

# 二、已实测借用 —— 纯原生 C 桥接 DLL（2026-09-16，路线 B 先打通）

> **为什么先做这条**：C# 侧还卡在 10 个 CRT 符号，而"编译期缝合"这条链路的**能力缺口在 FLINT 侧**
> 与"用谁编库"无关 → 先用 gcc 编一个**零依赖**的 C 桥接 DLL 把链路走通，接口不变，日后换上 C# 是零改动。
> **副产品（更值钱）**：C 桥接是纯原生 → 它就是**性能基线**，之后 C#/AOT 版跑同一套测速，差值 = 把运行时拖进来的代价。

| # | 借什么 | 提供方 | 版本 | 许可 | 干什么用 | 为什么不自己搓 |
|---|---|---|---|---|---|---|
| **B7** | MinGW-w64 gcc + 导入库 `libkernel32.a` | MinGW-w64（本机） | 16.1.0 | GPLv3 **带运行时例外**；导入库随发行版 | 编纯原生 C ABI DLL（`-shared -nostdlib -nostartfiles -nodefaultlibs`） | 已有编译器，无自搓意义 |
| **B8** | `objdump` / `nm` | GNU binutils | 随 MinGW | GPLv3 | 反汇编 FLINT 产物定位代码生成问题；`nm` 挖符号真名 | 同上 |

## 实测结论（全部有原始输出）

**① 链路打通**：FLINT 侧 `api cabridge int cs_add(int,int);` → 编译期把 `cabridge.dll!cs_add` 写进 PE 导入表
→ 运行期直调 **`cs_add(2,3) = 5`** ✓（`probe1.fl`／exe 1536 字节）。ptr 返回、缓冲区传参均通。
> **修正上一轮的结论**：所谓"FLINT 只认 kernel32/user32/gdi32"是**软限制**——`pe.c:250` 兜底分支
> `snprintf(fn, "%s.dll", a->dll)` 本来就会补 `.dll`，写 `api cabridge` 即可。
> **真正的硬限制**在词法层：标识符不吃 `.`（`is_ident2` 只认字母/数字/下划线）→ **带点的全名/带路径的模块名无法表达**
> （实测 `api cabridge.dll` 报"api 返回类型须为 int / void / ptr / double"）。要支持全名得改 `tokenize.c`＋`parse.c`
> （接受字符串字面量形式的模块名，`pe.c` 只在无 `.` 时补 `.dll`）。**本轮未改编译器**（一行未动，回归不退化）。

**② 性能基线（C 桥接 = 纯原生，即跨库调用开销的物理下限）**

| 量什么 | 做法 | 结果 |
|---|---|---|
| 纯调用开销 | `cs_slope(n,0)`：调用里循环体空 → 只含"调用 + k 递增 + 循环判" | 2000 万轮 **6,501,600 ns** = **0.33 ns/轮** |
| 调用 + n 次依赖加法 | `cs_hot_ptr(n)`（gcc -O2，含依赖链） | 2000 万轮 **9,731,100 ns** = **0.49 ns/轮** |
| FLINT 本地同语义循环 | `while (i<n) { a=a+3; i=i+1; }` 夹 `cs_now_ns()` | 2000 万轮 **83,172,100 ns** = **4.16 ns/轮** |
| 斜率法（分离开销与计算） | `cs_slope(n, ops)`，ops=1/2/4/8/16 | 每 op ≈ **2.1 ns**（依赖加法链），**外推 ops=0 截距 ≈ 0.1~0.5 ns** |
| 运行时查表（对照） | `GetProcAddress` 每次重查 | **80 ns/次** |

> **结论：C ABI 跨库调用 ≈ 0.3~0.5 ns/次，比"运行时查表"省约 200 倍，且被调函数只要做一点点实事
> 这次调用成本就完全被淹没。**"C ABI 性能不够强"的说法在这条链路上**不成立**（那是 COM/P-Invoke marshal 的名声）。
> ⚠️ 诚实标注：QPC 在 10MHz 下**分辨率 100ns**，单次调用 <1ns → 单点测量有量化误差；
> 但"2000 万轮总耗时"进 100ns 分度后误差 ±0.005 ns/轮，**结论稳健**（run1/run2 两次 9,731,100 / 9,729,400 ns 复现）。
> **顺带发现（与本研究目的无关但值得记）**：FLINT 本地 `while` 循环（一次加法 + 一次自增 + 判）跑 **4.16 ns/轮**
> → 这是 FLINT **codegen 优化空间**的第一份量化证据，不是本次要修的东西（**同侧实测；跨编译器倍数一律不报**，见 §4.4 / §4.10）。

**③ 跨语言接口纪律（本轮踩到、必须写死）**

| 纪律 | 实测证据 | 为什么 |
|---|---|---|
| **缓冲区类型必须两边都是 8 字节** | FLINT `int a[4]` 被 C 的 `void cs_fill(int*,int,int)` 填 → 只 `a[0]/a[1]` 变、`a[2]/a[3]` 不动；`cs_fill64(long long*,…)` → `7 7 7 7 7 7 7 7` ✓、`sum=56` ✓、交错值 `140` ✓ | **FLINT 的 `int` 是 8 字节槽**（`parse.c:1534`，语言语义，不是 C 的 `sizeof`）→ C 的 4 字节 `int` 必然错格 |
| **out 参数必须给真指针变量** | FLINT 里 `QueryPerformanceFrequency(0)` → **exit 0xC0000005**；而 `QueryPerformanceCounter(0)` 侥幸不崩 | `0` 被当 out 指针真解引用 → AV。同族 API 行为不一致，**别拿一个当前例** |
| **`&外部API名` 不支持** | `cs_bench_qpc(n, &cs_add)` 报「API 'cs_add' 需带括号调用」 | 传函数指针进库要改形态：库里按 id／选择器分派 |
| **64 位值用 `int *` 变量当容器** | `long long` 变量 → 「使用了未声明的变量 'long'」；`ptr qpf;` → 「意外的关键字 'ptr'」 | `ptr` 只能作 api 返回类型；无 64 位整数类型 |
| **api 返回类型只有 int/void/ptr/double** | —— | 64 位返回会被按 int 截断 → 让 DLL 直接回"微秒/纳秒"这类小量 |

**④ 现场与回退**：探针全在 `E:\FLINT-lab\tmp\cabridge\`（约 100KB，可整删）；`git` 干净；
`cabridge.dll` 10,354 字节、**唯一依赖 KERNEL32**、零 CRT、零运行时。

---

# 三、v1.4.8：把「导入表支持任意 DLL 名」这颗能力缺口收口

> **上一轮我先把这条结论修正过**：「只认 kernel32/user32/gdi32」是**软限制**（`pe.c` 兜底分支本就补 `.dll`），
> 真正卡住的是**词法层**——标识符不吃 `.`，`api cabridge.dll` 写不出来。本节 = 把这条填掉。

## 改了什么（两个文件，都很小）

| 文件 | 改动 | 行为 |
|---|---|---|
| `src/parse.c` | `collect_apis` 的模块名位置接受 **`TK_IDENT`（裸短名，行为不变）或 `TK_STR`（字面量全名/路径）**；空串报错 | `api "cabridge.dll"` / `api "E:/x/y/z.dll"` 可用 |
| `src/pe.c` | 模块名含 **`.` / `\` / `/`** → **原样**写进导入表；否则补 `.dll` | 裸短名（`user32`）一字不变 |

**四种形态实测**（`objdump -p` 读回导入表 + 真实运行）：

| 源码写法 | 导入表里写的 | 运行 |
|---|---|---|
| `api cabridge` | `cabridge.dll` | exit 5 = `cs_add(2,3)` ✓ |
| `api "cabridge.dll"` | `cabridge.dll`（**未双补**）✓ | exit 5 ✓ |
| `api "E:/FLINT-lab/tmp/cabridge/cabridge.dll"` | `E:/FLINT-lab/tmp/cabridge/cabridge.dll` | exit 42 ✓ |
| `api 123`（负例） | 编译期报错「api 后需跟模块名…」 | 无产物 ✓ |

## 不退化证据（**两条独立判据**）

1. **回归 764/764 失败 0**（原 753 项零退化 ＋ 11 项新用例：4 项端到端/字节级 + 6 项导入表字节断言 + 1 条负例）。
   新样本 `test\samples\apimod1.fl` 用**系统自带 msvcrt.dll** 做离线闭环——若被错误地再补一次 `.dll`，
   会去找 `msvcrt.dll.dll` → **进程启动即 STATUS_DLL_NOT_FOUND**，退出码直接红（不引入任何自制二进制依赖）。
2. **192 个既有样本产物逐字节一致**（改动前后的编译器**放在同一目录**做 A/B，SHA256 全等、0 个不同、0 个"仅单方能编"）。

> ⚠️ **方法学坑（我自己踩的，值得记）**：第一次做"逐个字节对照"时，我把旧编译器备份放到了 `tmp\cabridge\flint_before.exe`——
> 而 `flint.exe` 是**按自身所在目录**找 `lib\`（`main.c:152` 的 `"%slib\%s"`）→ 旧编译器找不到 `lib\`，
> **212 个样本一个都没编出来**，于是"差异数 0"是个**空集对空集的假结果**；随后换回仓库根目录又误判成"新版多编出 4 个"。
> **教训**：凡"A/B 对照类"实验，**必须让两个被测对象处在完全相同的环境**（同目录、同 PATH、同 CWD），
> 否则差异来自环境而非被测对象；且**"0 个不同"要先确认两边都真的产出了东西**（拒绝空集假绿）。

## 附带发现的语言边界（本轮撞到的，已可写进「⛔ FLINT 语言边界」）

- **字符串转义只认少数几个**：路径里写 `\F`（如 `"E:\FLINT-lab\..."`）直接报「未知转义 '\F'」→
  **路径形态必须用 `/`**（实测 `E:/FLINT-lab/tmp/cabridge/cabridge.dll` 导入表原样写入、运行通过）。
- `ImpGroup.dll` 是 `char[64]` → **模块名（含路径）上限 63 字节**；模块数 `MAX_GROUPS=8`；导入函数 `MAX_IMPORTS=96`。
- 完整路径写进导入表是可行的（Windows loader 接受），但**路径会烧进产物** → 换目录/换机器即失效；
  生产用法应写裸名（靠 loader 搜索路径），**路径形态只适合当调试手段**。

---

# 四、C# / NativeAOT 侧：已链出可用的原生 DLL ＋ AOT 边界代价实测

> **状态（诚实标注）**：**C# 侧编出原生 DLL 这条路已经通了**（零 VS、零 Windows SDK 安装），
> 导出函数在 **.NET 宿主**里实测可用；但**用 FLINT 的导入表去调它仍崩**（未收口，见 §4.3）。
> 目标③的性能对照已用「.NET 宿主 + 同一套基准函数」完成，见 §4.2。

## 4.1 配方（可复现；一条命令 8 秒）

```powershell
# 1) 依赖（全 NuGet，零微软工具）
#    Microsoft.DotNet.ILCompiler 8.0.30 / runtime.win-x64.Microsoft.DotNet.ILCompiler 8.0.30
#    LLD.Link.Toolsets.win-x64 22.1.8.7          -> lld-link.exe（替代 VS 的 link.exe）
#    Microsoft.Windows.SDK.CPP.x64 10.0.28000.2705 -> 461 个 .lib
# 2) 垫片（本工程自产，补 MSVC 静态 CRT 的缺失符号）
gcc -O2 -c shim\crtshim.c -o shim\crtshim.obj
pwsh -File tools\gen-altnames.ps1        # 生成 shim\altnames.rsp（修饰名挂接表）
# 3) 发布（ilc 走官方后门跳过找 VS；链接器换成 lld-link）
dotnet publish CsLib.csproj -c Release -r win-x64 -o out `
  -p:IlcUseEnvironmentalTools=true -p:CppLinker="<...>\shim\link.exe"
# ⚠️ **改动垫片/链接参数后必须删掉产物再 publish**：MSBuild 增量判断只看 C# 源，
#    改 .obj／csproj 的 LinkerArg 不会触发重链接（实测：DLL 时间戳不变、跑的还是旧二进制，
#    把我误导了一轮）。
```

**产物**：`CsLib.dll` = **1,115,136 字节**（vs C 桥接 11,587 字节，**约 96 倍**），
导出 `cs_add` 等，依赖仅 `api-ms-win-crt-*` / `bcrypt` / `ole32` / `advapi32` / `KERNEL32`，
**不依赖任何 .NET 运行时**。

## 4.2 AOT 边界代价（实测，同一进程、同一套函数、时钟在被测库内部取）

| 指标（N = 2000 万轮） | C 桥接（纯原生） | C# / NativeAOT | 结论 |
|---|---|---|---|
| `NativeLibrary.Load` | **305 us** | **404 us** | 固定成本 +99 us |
| 文件大小 | 11,587 B | 1,115,136 B | **约 96×** |
| **真实访问循环**（`cs_take`：读调用方缓冲区） | 19,725 us | **19,450 us** | **无差异**（AOT 甚至快 1.4%） |
| **跨库调用 + 一次加法**（每轮） | **0.485 ns** | **2.268 ns** | AOT 慢 **4.7×** |
| 热路径 + 选择器 + 消费结果（每轮） | **0.971 ns** | **2.914 ns** | AOT 慢 **3.0×** |
| 斜率法 ops=0（纯固定开销，每轮） | **0.324 ns** | **0.647 ns** | AOT 慢 **2.0×** |
| 斜率法 ops=4（固定 + 4 次依赖加法） | 1.944 ns | 2.579 ns | 差 0.64 ns |
| 斜率法回归：每 op 成本 | ≈ 0.42 ns | ≈ 0.48 ns | **基本相同** |

**读法（这才是结论）**：
1. **AOT 边界确实有代价，但只在"跨库调用的固定开销"上**：约 **0.3 ns → 0.65 ns**（每次多约 **0.3 ns**）。
2. **一旦被调函数做真活，这点差异就淹没了**：真实内存访问循环两边**逐微秒一致**。
3. 与"运行时查表"对照（`GetProcAddress` **80 ns/次**）→ **AOT 的 2.3 ns 仍快约 35 倍**。
   ⇒ **多语言交火这条路在性能上站得住**；"C ABI/跨语言调用慢"的说法在本框架下**不成立**。
4. 真正的固定代价是**体积与加载**（96 倍体积、+99 us 加载），不是调用。

> ⚠️ **两个反面样本必须记**（否则会得出错误结论）：
> ① `i = i + a` 这种"循环体与下标无关"的形状，**C 与 AOT 都被常量折叠**（两边都恰好 60,000,000 ns/2000 万轮）
>    → 拿它当基准 = 测空气。真正可比的是**读调用方缓冲区**的 `cs_take`。
> ② C# 侧**不能用 `System.Diagnostics.Stopwatch`**：手链的 AOT 镜像里它的静态 `Frequency` 是 **0**
>    （实测 `cs_freq_mhz` 返回 0、所有除法抛 DivideByZeroException）→ 必须直调 `QueryPerformanceCounter`
>    （顺带让两侧时钟同源）。

## 4.3 ⛔ 未收口：FLINT 导入表调 C# DLL 会崩（卡点与已排除项）

**现象**：`api "CsLib" int cs_add(int,int);` 编译成功、导入表正确（`CsLib.dll!cs_add`），
但运行期 **AV 0xC0000005**，故障模块 = `CsLib.dll`，偏移 `+0x3e30`（反汇编是**函数收尾**的
`mov 0x30(%rsp),%rbx; add $0x20,%rsp; pop %rdi; ret` → 收尾时 rsp 已不对）。

**已排除（都有实测）**：
| 怀疑点 | 实测结果 |
|---|---|
| 导入表写错（模块名/函数名/hint） | 用自写 `peimp.exe` 读回：模块名、函数名正确（hint=0 vs gcc 的 1 不影响正确性） |
| 加载路由（LoadLibrary vs 导入表） | 用 gcc 编的**同形状 C 宿主**（也走导入表）调用同一 DLL → **正常返回 5** |
| 最小 PE 结构问题 | FLINT 产物用同一导入表**只导入不调用** → 正常退出（说明加载与重定位没问题） |
| FLINT 传参/栈纪律 | 反汇编 FLINT 调用点：`sub rsp,0x20`（shadow 32B）、`rcx=2`、`rdx=3`、call 时 rsp≡0 —— **符合 Win64 ABI** |
| DLL 未初始化 | 给 DLL 加 `/ENTRY:DllMainCRTStartup` + 落盘 trace → 入口**确实被调用**；但**两种加载路由都变成 STATUS_DLL_INIT_FAILED(0xC0000142)** |

**已确认是"自己作出来的病"、并已回退的三项**（写在这里防止下次再撞）：
① `/ENTRY:DllMainCRTStartup`（连"最小 return 1"版本）→ DLL 直接加载失败；
② 入口里调 `RhInitialize()` → 同样 0xC0000142（`.CRT$XCU` 里已注册过运行时初始化，属重复初始化）；
③ `/INCLUDE:RhInitialize` 强行保留符号 → 首次调用即 AV。
**当前 csproj 已回到"不指定 /ENTRY、不调 RhInitialize"** —— 这个形态下 **.NET 宿主可用**。

**下一步建议（未做）**：既然 `hostimp.exe`（gcc 产物、走导入表）能正常调用同一个 DLL，
而 FLINT 产物崩在**被调函数的收尾**，最值得查的是**两者栈/异常处理元数据的差异**：
FLINT 产物**没有 `.pdata`/`.xdata`**（无 SEH 元数据），而 NativeAOT 代码在首次调用时会做
**栈帧/异常处理相关的初始化**（`AppendExceptionStackFrame` 等符号就在 bootstrapperdll.obj 里）。
**判据**：给 FLINT 产物补一节 `.pdata` 后再试；或先用 `cdb`/最小转储拿到故障点寄存器。

### 4.3.1 第二轮追查：`.pdata` 假设**已被证伪**，但把范围收窄了一大截

**新增工具（可复用）**：
- `tmp\cabridge\peimp.c` → `peimp.exe`：**自写 PE 导入表读取器**（不依赖任何工具，直接打印每个模块名+函数名），
  用来核对"编译器到底往导入表里写了什么"。
- `tmp\cabridge\patchcall.py`：**模板式 PE 补丁器** —— 拿 FLINT 已知可运行的产物当模板，
  只替换代码区与导入表，产出"只有 `.pdata` 有无之差"的两个变体（手工写 PE 头两次都被 loader 拒绝，
  模板法把"头部细节"这一整类错误排除掉）。

**决定性实验 + 结果**：
| 变体 | 结构 | 结果 |
|---|---|---|
| `pt_nopd.exe` | 模板补丁：调 `CsLib.dll!cs_add(2,3)` → `ExitProcess`，**无异常目录** | **AV 0xC0000005** |
| `pt_pd.exe` | 同上，**加了 `.pdata`（RUNTIME_FUNCTION 表）+ DataDirectory[3]** | **AV 0xC0000005（完全相同）** |
⇒ **`.pdata` 不是原因**（假设被实测证伪，省掉后续在这条线上的投入）。

**同时把"宿主特性"排除掉**：编了一个**形状与 FLINT 产物一致**的最小宿主
（`tmp\cs-aot-probe\out\hostmini.c`：`-nostdlib -nostartfiles -nodefaultlibs`、自有入口、
只导入 `CsLib.dll`+`kernel32`）→ **同样 AV**。
说明问题**不在"FLINT 产物特性"**（无 CRT / 最小导入 / 单段都不能解释）。

**已实测的配置矩阵（垫片/链接开关；每行都是真跑过的构建）**：
| 配置 | 结果 |
|---|---|
| 完整垫片符号 + 入口桩 + **不加** `/ENTRY`、**不加** `/INCLUDE` | 链接成功，**`.NET` 宿主可加载并调用** |
| `+ /ENTRY:DllMainCRTStartup`（连 `return 1` 的最小函数体） | `0xC0000142`（DLL 初始化失败） |
| 入口里调 `RhInitialize()` | `0xC0000142` |
| `+ /INCLUDE:RhInitialize` | 首次调用即 AV |
| 入口里遍历 `.CRT$XCU` | `0xC0000142` |
| 去掉入口桩 | **链接失败**：`undefined symbol: _DllMainCRTStartup`（lld-link 要求该符号存在） |
| `_tls_index` 换成"真 TLS"（TlsAlloc + 惰性块） | 原生宿主调用 AV（已回退） |

**当前状态（诚实标注）**：
- ✅ **.NET 宿主**（`NativeLibrary.Load` + 直调）：`cs_add(2,3)=5`、`cs_add(100,200)=300`，**稳定可用**。
- ⛔ **任何原生宿主**（完整 CRT 的 gcc 宿主 / 无 CRT 最小宿主 / FLINT 产物 / 模板补丁产物）调用同一 DLL
  → **全部 AV 0xC0000005**。
- ⇒ 卡点可以精确表述为一个问题：**"同一份 DLL，为什么 .NET 宿主能调，原生宿主不能？"**
  下一步最值得查的方向（未做）：① 用 `gflags`/`cdb` 抓故障点寄存器（本机无 cdb，可先装调试工具或写
  VEH 钩子）；② 核对 NativeAOT 导出桩是否依赖 `.NET` 宿主特有的加载步骤
  （如 `DotNetRuntimeDebugHeader` 目录、`RhRegisterOSModule`）；③ 试 **`NativeLib=Static`**
  把 C# 编成静态库、由 C 侧写导出壳（绕开 DLL 入口整条链）。

### 4.3.2 第三轮追查：**静态库路线走通了一半**（C 宿主可用），并挖出一条机制事实

**做了什么**：新建独立项目 `tmp\cs-aot-probe\static\`，把同一份 C# 用 **`NativeLib=Static`** 编成
**原生静态库**，再由 **C 侧写导出壳**（`cshell.c`）并提供自己的 DLL 入口（`entry.c`）。

**关键发现（这才是静态路线的价值）**：
- `NativeLib=Static` 时 ilc 会产出 `CsStatic.obj`（**3,551,570 字节**原生 obj；最后一步 `lib` 打包失败，
  因为本机没有 VS 的 `lib.exe` —— 但 **obj 可以直接喂 lld-link**，我用 `CsLib` 那份已验证可用的 `link.rsp`
  当模板、只替换 obj 就链成功了（`ShellCs.dll` 1,112,576 字节）。
- **直接链会得到一句极有信息量的报错**：加载时 `Fatal error. Invalid Program: attempted to call a
  UnmanagedCallersOnly method from managed code`。根因 = **`bootstrapper.obj` 定义了 `wmain`（托管入口），
  链接器把它当成了 DLL 入口**（`nm bootstrapper.obj` → `T wmain`；`bootstrapperdll.obj` → `U __managed__Startup`）。
  **修法 = 用 `/ENTRY:_EntryPoint` 把我们自己的入口顶上去**，让 `wmain` 永不被当入口。
  我们入口要做的：跑 `.CRT$XCU` 里的静态初始化器（NativeAOT 的 runtime pointer helper 就在里面）+ 返回 TRUE。

**实测矩阵（新增）**：
| 配置 | 结果 |
|---|---|
| 静态库 + C 壳，**不指定** `/ENTRY`（`wmain` 被当入口） | 加载即 `Fatal error: attempted to call a UOC method from managed code`（0xC0000122 一类） |
| 静态库 + C 壳 + **`/ENTRY:_EntryPoint`（自有入口）** | **C 宿主：`sh_add(2,3) = 5`、exit 42 ✅**；入口 trace 正常（`ctor count=16`） |
| 同上，**FLINT 产物走导入表**调用 | ❌ `STATUS_DLL_INIT_FAILED`（0xC0000142）—— 注意：入口**已完整跑完** |

**机制事实（本轮最硬的产出）——"加载方式"本身会决定后续能否成功加载 AOT 库**：
| 谁去加载 `ShellCs.dll` | 加载方式 | 结果 |
|---|---|---|
| C 宿主 `t_bridge`：`LoadLibraryA`（**运行期**） | 动态 | ✅ `cacslink_add(2,3) = 5`、exit 42 |
| C 宿主 `t_bridgeimp`：**桥接走导入表** + 桥接再 `LoadLibraryA` | 混合 | ❌ `0xC0000142` |
| FLINT 产物 `bridgecall.exe`：同上（桥接走导入表） | 混合 | ❌ `0xC0000142` |
⇒ **导入式加载某 DLL 的进程，之后再运行期加载这份 AOT 库会失败；纯运行期加载的进程则成功。**
与"宿主是不是 FLINT"**无关**（C 宿主走导入表一样失败）。

**当前可用的两条路（都给出来了）**：
1. **AOT 库作为共享库 + `.NET` 宿主**：`cs_add(2,3)=5` ✓（验收判据达成，性能对照也用它跑）。
2. **AOT 库作为静态库 + C 壳（自有 `/ENTRY`）**：**任何完整 CRT 宿主可正常调用** ✓ —— 这是一条真实的
   进展：C 侧接口 `sh_add` 与 C 桥接同名同形，**FLINT 侧接口不需要改**，日后只差"谁能加载它"。
⛔ 仍未打通的组合：**由 FLINT 产物直接加载这份 AOT 库**（导入表或运行期桥接都失败，`0xC0000142`）。
**下一步建议**：① 抓 `0xC0000142` 的**具体失败点**（DLL 已 ATTACH 完成却仍报初始化失败，怀疑与
"进程启动期加载了带 TLS 的 DLL"或 .NET 运行时的 OS 模块注册顺序有关）；② 让桥接 DLL 换成**完整 gcc 运行期**
构建（`cacslink.dll` 目前是 `-nostdlib` 极简构建，可能与 AOT 运行时的加载互相干扰）—— **这条最省的验证**；
③ 或改走"FLINT 调用一个宿主 exe（子进程）"的形态，彻底绕开同进程加载。

### 4.3.3 ⚠️ 重要修正：**同一二进制结果不稳定（间歇性）** —— 之前几轮的"部分成功"都是这个原因

线索②已验证：桥接换成**完整 gcc 运行期**构建（48,252 字节）后，导入表式宿主**直接挂住（>120 秒无返回）**，
比极简构建更糟 ⇒ **不是桥接构建风格的问题**（已还原极简版）。

**更关键的发现（会改变对前面所有结果的解读）**：
`t_bridge.exe`（**同一二进制、同一 DLL、同一目录**）连续运行 **两次，结果不同**：
一次 `exit = -1073741819`（AV 0xC0000005），一次 `exit = 42`（**成功**）。
⇒ **这份 AOT 库的加载/初始化是"间歇性"的**，不是稳定失败也不是稳定成功。

**这把前面几轮的现象一次解释清了**（也说明当时的"部分成功"记录不是看错）：
- 时而成功时而 AV  ⇒ 早期那次"3 参数 FLINT 探针也退出 5"很可能**是真的成功过一次**（竞态撞对了）；
- 后来一直失败    ⇒ 只是竞态没撞上。
**结论：这个问题的性质是"竞态/时序"，不是"确定性的结构错误"** —— 这也意味着**"补 `.pdata` / 换首部结构 /
换入口"这类确定性修法本来就不可能稳定修好它**（与实测相符：`/ENTRY`、`/INCLUDE`、`.pdata` 全都无效）。

**建议的下一步（性质变了）**：① **重复运行 N 次统计成功率**（先把"间歇"量化，例：跑 50 次记成功/失败比），
不要再用单次结果下结论；② 抓失败那一次的现场（VEH 钩子宿主或装 cdb），看崩在哪个初始化阶段；
③ 已知最稳的可用形态 = **AOT 共享库 + .NET 宿主**（验收判据与性能对照都基于它）。

### 4.3.4 间歇性已量化 ＋ 目标③最后一块（启动/内存固定成本）

**① 成功率实测（同一二进制、同一目录，各跑 60 次）**：

| 被测 | 成功 | 失败码 |
|---|---|---|
| **C# / NativeAOT 库**（`t_bridge.exe` 运行期加载） | **44 / 60（73%）** | `0xC0000005` ×16 |
| **纯 C 桥接**（对照，不含 AOT） | **60 / 60（100%）** | —— |

⇒ 间歇性**确证且量化**：约 **1/4 的启动会失败**。这就是前几轮"时而成功时而失败"的全部来源；
也解释了为什么补 `.pdata`／改 `/ENTRY`／`/INCLUDE` 这类**确定性修法**都不可能稳定修好它。

本轮还踩到一个**测量陷阱**（值得记）：`Start-Process -Wait` 跑 `hostcs.exe` 时"挂住 5 分钟"，
其实**目标进程早已完成**（结果文件已写好 `sum=5`），卡住的是**输出重定向/隐藏窗口的控制台句柄**。
⇒ **判"挂住"之前先看它的产物文件**，别只看进程不退出。

**② 启动 + 内存固定成本（目标③的最后一块，`memprobe.exe` 实测）**：

| 指标 | C# / NativeAOT（`CsLib.dll`） | 纯 C 桥接（`cabridge.dll`） |
|---|---|---|
| `LoadLibrary` | **43,014 us** | 20,747 us |
| 工作集增量（加载后） | **+2,032 KB** | +40 KB |
| 私有字节增量（加载后） | **+740 KB** | +12 KB |
| 首次调用 | 15 us | 5 us |
| 加载并调用后**再**跑 100 万次 | 工作集只再涨 +36 KB（**不再增长**） | +40 KB |

⇒ **AOT 的固定成本是"一次性"的：约 2 MB 工作集 + 43 ms 加载**；此后调用不再有内存增长。
**判据**：常驻进程（浮窗这类）**完全无所谓**；"每次启动一个新进程、只调几次"的用法**会被这 43ms 主导**。
（注：本次 `LoadLibrary` 耗时含进程首个 DLL 加载的开销，两行不完全同口径；量级关系可靠。）

**③ 跨库调用开销的第二组独立测量（100 万次、经函数指针、同一宿主）**：
C# AOT **10.17 ns/次** vs 纯 C 桥接 **1.95 ns/次**（约 5.2×，与前文斜率法的量级结论一致：
差额主要是宿主侧间接调用/委托成本，不是 AOT 侧本身）。

**④ 交付形态结论（本轮定的方向 B）**：用**进程外宿主**（`hostcs2.exe`：加载 DLL → 调用 → 结果写文件 + 退出码）
把 C# 能力交给别的程序，是**目前唯一可复现**的集成方式；实测 5 次里前 1 次成功、其余受同一间歇性影响
（`CsLib.dll` 在本轮 5 次里 1 次成功，与此前 73%/74% 的区间一致）—— **间歇性不解决，"可复现交付"就无从谈起**。

## 4.4 顺带发现：瓶颈在「我方生成的代码」上，不在缝合上（**同侧实测；跨编译器倍数不报**）

同一件事（`while` 循环里做一次加法 + 一次自增 + 判），在 **FLINT 自己 codegen 的循环**上实测 **4.16 ns/轮**
（2000 万轮 `83,172,100` / `82,906,000` ns，两轮复现；样本 `tmp\cabridge\bench4.fl`）。

⇒ **瓶颈在"我方生成的代码"上，不在缝合上**（跨界调用本身只要 0.33 ns/次，见 §4.2）。
**意义**：以后凡谈 FLINT 性能，先分清**"是缝合贵"还是"我方 codegen 慢"** —— 这次量出来是后者。
**处置**：**先只记录，不动 codegen**（属独立工程，真要开优化时另行立卡 + 先查资料，别顺手改）。
> ✅ **2026-09-17 已动（用户拍板折中：只做纯窥孔，不碰寄存器分配）→ 结果见 §4.10**：空循环 **3.97 → 2.28 ns/轮**，
> `m2_float.exe` 154,112 → **125,952 B（−18.3%）**，回归 764/764。**定性方向仍然有效**（慢的确实是我方生成的代码、
> 且病根是"每步都过内存/过栈"），窥孔只治"每步都过内存/过栈"的**指令数**，
> 治不了"局部变量一个都不在寄存器里"（那是寄存器分配，未动）。
> ⚠️ **本条只与自家前后比、不报跨编译器倍数** —— 两侧循环形状不同，且 **gcc `-O2` 会把这类玩具循环整体折叠**
> （实测那一侧一圈都没跑），证据与判据见 §4.10「与 gcc 的倍数：本档报不了」。

## 4.5 跨语言接口纪律（缝合前必看）

- **元素宽度先对齐**：**FLINT 的 `int` 是 8 字节槽**（`parse.c:1534` 明写"不是与 C 的 `sizeof` 一致"），
  C 的 `int` 是 4 字节 → 用 C 的 `void f(int*, int n, int v)` 填 FLINT 的 `int a[4]` **只生效两格**（`7 7 0 0`）、
  换 `long long` 才严丝合缝（`7 7 7 7 7 7 7 7`、`sum=56`；FLINT 内部读写都 ×8 完全自洽，**是口径冲突不是 bug**）。
  排查路径：现象像"库只填了一半" → 先怀疑编译器 → `objdump` 看**步长 ×8** → 查源码才知是语言语义。
- **out 参数一律给真变量取地址**：`QueryPerformanceFrequency(0)` 当场 `0xC0000005`，而 `QueryPerformanceCounter(0)`
  侥幸不报错 ⇒ **"同族调用侥幸能过"是假绿**；崩溃只表现为"退出码 -1073741819 + 零输出"（stdout 未刷），**先看退出码**。
- **时钟在被测库内部取**（两侧同源），别跨侧传时间戳；手链 AOT 镜像里**别用 `Stopwatch`**（`Frequency` = 0，见 §4.2 反面样本②）。
- **api 声明**：返回类型只有 `int`/`void`/`ptr`/`double`；模块名不吃 `.`、含路径上限 63 字节（超长**静默截断**）；
  Windows 路径要写 `/`（`\F` 会被当未知转义）；**完整路径会烧进产物** → 生产写裸名。（全表 → 记忆归档 `FLINT编译器.md`「⛔ FLINT 语言边界」v1.4.8）

## 4.6 ⛔ 已定位：原生宿主调用 C# DLL 间歇 AV 的**真根因**（2026-09-16 21:1x 实测）

**现象**：同一份 `CsLib.dll`（NativeAOT `Shared`），.NET 宿主 `cs_add(2,3)=5` ✓，
任何原生宿主调用**间歇** `0xC0000005`（随宿主形态 44/60 或 60/60；崩溃点 `CsLib+0x3da0` = `mov (%rcx),%rax; ret`，读地址 0）。

**根因①：缺 TLS 目录 ⇒ 线程静态量索引是假 0**
- 运行时访问序列：`mov rax, gs:[58h]`（TEB → `ThreadLocalStoragePointer`）→ `mov ecx, <_tls_index>` → `mov rax, [rax+rcx*8]`
  （`<_tls_index>` 实测在 `.data` 的**零填充 BSS** 里，如 RVA 0xb5730）。
- 镜像 **`DataDirectory[9]`（TLS 目录）为空**（`.tls` 段有、目录没有）⇒ loader 从不分配索引、
  也从不回写 `_tls_index` ⇒ 垫片里那句 `unsigned int _tls_index = 0;` **恒为 0**
  ⇒ **TLS 数组[0] = 别的模块（宿主/CLR）的 TLS 块** ⇒ 读出来的"当前线程对象"时好时坏 ⇒ 间歇 AV。
- ⚠️ **.NET 宿主"能用"是巧合**：槽 0 恰好是 CLR 自己的 TLS 块，那个**假**线程对象凑巧满足 `+0x38` 标志位检查，
  于是走了"已初始化"快路径。**别把当时的 73% 当成可用性。**

**根因②：CRT 初始化从未跑 ⇒ 运行时从未初始化**
- DLL 入口点 = `mov eax,1; ret`，正是垫片 `_DllMainCRTStartup` 的编译产物（lld-link 拿它当 DLL 入口）；
- 而 `bootstrapperdll.obj` 把 `?InitializeRuntime@@YAHXZ` 挂在 **`.CRT$XCU`** 初始化表里 ⇒ **没人遍历该表**
  ⇒ `0x180003f80` 读的那个单例全局（`.data` RVA 0xb77c0）永远是 0 ⇒ 首次导出调用走到初始化分支即空指针。
- 旁证：加载后**等 3.1 秒**再调用，两种结局下该全局**始终为 0**（延时不解决问题，时序假设已证伪）。

**修法（两条都要，仅动 `tmp` 探针的垫片与 csproj，FLINT 编译器一行未改）**
1. 垫片定义 **`_tls_used`**（含 `AddressOfIndex = &_tls_index` + 0x1000 零模板）。
   **验证**：`objdump -p` 出现 `Entry 9 … Thread Storage Directory [.tls]`（RVA 0x9c420、`.tls` 0x100→0x1100）；
   宿主里读 `AddressOfIndex` 指向的 32 位变量得 **`INDEX=5`** ⇒ loader 确实回写了真索引 ✓。
   **效应量（同一宿主二进制、每轮交替跑旧/新 DLL 各 40 次）**：旧 **0/40**（全 AV）→ 新 **16/40** 成功。
   ⚠️ 附带事实：**`_tls_used` 的字段其实由 lld-link 说了算** —— 我们写的 `AddressOfCallBacks` 在产物里被**清零**
   （本想用 TLS 回调挂初始化，此路不通，已实测）。
2. **让运行时初始化真的跑起来**：`csproj` 加 **`/ENTRY:_DllMainCRTStartup`**（否则入口点是 lld-link 的桩
   `mov eax,1; ret`，垫片里的初始化**压根不被调用**）。加完之后垫片的轨迹自证：
   `xcu_entries_seen=16`、**`xcu_called=16`**、**`RhInitialize` 返回 al=1**、`attach reason=1/2` 全到 ⇒ **AV 归零**。
   ⚠️ **自我纠错留档**：先前按 `SHIM_INIT_MODE` 0/1/2/3 测出 1–2/40、9/20、13/20、13/30 并写成"模式提升成功率"，
   后来查 `AddressOfEntryPoint` 发现**入口是桩、那几个模式全是空跑**；同宿主对照（模式 0 = 14/30 vs 模式 2 = 17/30）
   证明**无显著差异**，该结论作废。**教训：改配置后先自证"这段代码真的被执行了"**（本轮靠"往文件写轨迹"自证）。

**仍未收口**：残余失败已换形态 —— 主线程调用多为运行时致命错误
`attempted to call a UnmanagedCallersOnly method from managed code`（14/20）；在工作线程上调用出现过
「**先拿到 r=5、随后迟发 AV**」（AV 不在 CsLib 内）。⇒ 剩下的是**运行时初始化后的调用状态/线程状态**问题，
已不是"缺 TLS 索引"那个根因。
**工具（可复用，全在 `tmp\race-probe\`）**：`vehhost.c`（VEH 抓 AV 现场＋全寄存器＋栈快照）、
`vehsample.c`（按时间采样全局变量）、`tlscheck.c`（读内存里 PE 的 TLS 目录＋索引并验证调用）、
`thrcheck.c`（在工作线程上调用）、`try-mode.ps1`（重建垫片→publish→批量统计成功率）。


## 4.7 ✅ 收口：残余失败（致命错误 / 随机 AV）的真根因 = **TLS 布局两侧错位**（2026-09-16 22:1x 实测，40/40 稳定）

**结论先行**：同一份 `CsLib.dll` 现在由原生宿主调用 **40/40 成功、0 致命错误、0 AV**，并且判据证明**每一次都是真初始化**（不是"侥幸返回 5"）。

### 判据（比"返回 5"强得多，以后就用这个）
- 读 **`g_RuntimeInitializationCallback`**（RVA 0xb57b8；从 `RhSetRuntimeInitializationCallback` 的体 `mov [rip+..],rcx; ret` 反查得来）：
  - 调用前 = `InitializeRuntime`（镜像内 0x1fe0）⇒ `.CRT$XCU` 的登记跑过了；
  - **调用后必须 = NULL**（`EnsureRuntimeInitialized` 跑完会清它）⇒ 运行时**真的**初始化过。
- 读 TLS 块 **+0x1020** 处的 Thread 对象：调用后应 **`flags=0x1`（TSF_Attached）／`frame=0xffff…ff`（TOP_OF_STACK_MARKER，抢占模式）**。
- ⚠️ **反例记牢**：早前几轮的"成功"（44/60、14/40、11/20）**全是假成功**——回调全局一直没被消费 = 运行时从未初始化，而 `cs_add(2,3)` 这种纯整数运算照样返回 5。**"调用返回了正确值"根本不是判据。**

### 三个必须同时满足的条件（缺一个就回到间歇崩）
1. **必须有 TLS 目录**（ILC 只放 `.tls` 段、不放数据目录[9]）⇒ 垫片给 `_tls_used`（lld-link 见到它才写目录），`AddressOfIndex` 指向垫片的 `_tls_index`，加载期由 loader 回写真索引（实测 `INDEX=5`）。
2. **目录的 raw 范围必须真的覆盖 Thread 对象**：`tls_CurrentThread`（`threadstore.cpp`：`__thread ThreadBuffer tls_CurrentThread;`）就在 **TLS 块 +0x1020**，`sizeof(Thread) ≈ 0x70`。
   ⚠️ **`SizeOfZeroFill` 靠不住**：本机实测声明 raw 0x1000 ＋ 零填充 0x2000，块外仍是堆垃圾（+0x3000 那一页有 1700+ 非零字节）⇒ **必须把这块内存放进 raw 数据**。
3. **前置块大小必须保持 0x1000 —— 这是本轮的真根因（两侧偏移对齐）**：
   - 托管侧：ILC 把 Thread 地址写成**常数 0x1020**（导出入口前那条 reverse-pinvoke 序里就是 `mov r8d,0x1020; add rdx,r8`）；
   - 原生侧：运行时预编译库（`ThreadStore::AttachCurrentThread`、`Thread::InlinePInvoke` 等）的偏移是**链接期**算出来的，=「排在它前面的 `.tls` 数据总长 ＋ 0x20」；
   - 实测：前置块 **0x1000 ⇒ 两侧都算成 0x1020（对齐 ✓）**；前置块 **0x3000 ⇒ 原生侧变 0x3020、托管侧仍是 0x1020** ⇒ **两侧各认一个 Thread 对象** ⇒ 现象正是那条致命错误 `attempted to call a UnmanagedCallersOnly method from managed code` ＋ 随机 AV。
   - ⇒ **要撑大 TLS 块，只能往 `.tls` 尾部加**（垫片用 `.tls$ZZZ` 放一块 0x1000 填充），**绝不能改前置块大小**。

### 初始化通道（官方姿势，别自己造）
`Bootstrap/main.cpp` 的 `NATIVEAOT_DLL` 分支（实测读到的源码）里，`.CRT$XCU` 那个静态初始化器**只做登记**：
`RhSetRuntimeInitializationCallback(&InitializeRuntime)`；真正的初始化（`RhInitialize(true)` ＋ `RhRegisterOSModule` ＋ `InitializeModules` ＋ `__managed__Startup()`）由**运行时自己在第一次 reverse pinvoke 时**调用（`Thread::ReversePInvokeAttachOrTrapThread` → `EnsureRuntimeInitialized`）。
- ⇒ 垫片要做的只有一件事：**遍历 `.CRT$XCU` 登记回调**——这要求入口真是 `_DllMainCRTStartup`，即 csproj 必须留 **`/ENTRY:_DllMainCRTStartup`**；
- ⇒ **绝不要自己调 `RhInitialize`**：真签名是 `bool RhInitialize(bool isDll)`（`startup.cpp`）；早前按 `int RhInitialize(void)` 调，实参是寄存器垃圾、返回值也读错（实测 `rc=-1151760127`），且等于重复初始化。

### 顺带纠正两条旧结论（已就地写进产物注释留痕）
- csproj 里"**不要加 `/ENTRY`**（一律 0xC0000142）"**作废**：那批 0xC0000142 是在 TLS 布局坏掉时量的；现在 `/ENTRY` 是**必需**的。
- 垫片头注释里"块 0x1000 就够（线程静态偏移最大 0x290）"**作废**：Thread 对象在 0x1020。

### 工具与配方（全在 `tmp\` 下，可复用）
- `tmp\race-probe\statecheck.c`（**本轮主力**：读初始化回调全局 ＋ TLS 页视图 ＋ Thread 现场；带第 4 个参数 `init` 可主动跑官方初始化回调做对照）、`peinspect.mjs`（段表 / TLS 目录 / 导出表）、`scan2.mjs`（解 `.CRT` 初始化器表、定位字符串引用）、`perrun.mjs`（按 tag 汇总"这一轮走到哪一步"）；另有早前的 `vehhost.c` / `tlscheck.c` / `thrcheck.c` / `try-mode.ps1`。
- 配方：`gcc -O2 -DSHIM_INIT_MODE=4 -c shim\crtshim.c -o shim\crtshim.obj` → **删 `obj\Release\net8.0\win-x64\native\*`**（MSBuild 增量不重链接，本轮又踩一次：产物 DLL 的时间戳比 obj 还早）→ `dotnet publish … -p:IlcUseEnvironmentalTools=true -p:CppLinker=<shim\link.exe>`。
- 日志：`tmp\race-probe\align.log`（20/20）、`align40.log`（40/40，含"真初始化"判据逐条）。


## 4.8 ✅ 缝合用在真项目上：FLINT 浮窗把 C# LHM **同进程**缝进来当数据源（2026-09-16 22:4x）

**目标（用户口径）**：浮窗不再依赖外部 C# 版进程 / 8080 —— CPU 温度/功耗、GPU、FPS 自己拿。**这条就是"编译期缝合"的第一次真实交付。**

**工程**：`E:\FLINT-lab\libcs\hwbridge\`（`HwBridge.csproj` + `HwBridge.cs`），配方完全复用 §4.1/§4.7：
NativeAOT `Shared` ＋ 自造 CRT 垫片 ＋ lld-link ＋ `/ENTRY:_DllMainCRTStartup` ＋ **TLS 对齐（前置块 0x1000 不动）**。
依赖 **LibreHardwareMonitorLib 0.9.2**（NuGet，本机缓存已有；AOT 把它一起编进去，产物 **5.7 MB**）。

**导出面（给 FLINT 的 C ABI）**
- `int hw_init()` → 状态位：bit0 init ok ／ bit1 找到 CPU ／ bit2 找到 GPU ／ bit3 RTSS 可读
- `int hw_snap(int *buf)` → **24 个 ×1000 定点 int**（与 JSON 取值层同口径，FLINT 侧 `int` 只有 4 字节正好装得下）：
  `cpu_temp/load/clock/power`、`gpu_temp/load/mem_used/mem_total/power`、`fps/fps_low`、`sys_power/base_power`、
  `buf[22]` = 有效位掩码、`buf[23]` = 状态位 ＋ 采样序号。
- **分工原则（比"全搬过来"更重要）**：桥只给 **FLINT 自己拿不到的那几项**（CPU MSR 三项 ＋ GPU 显存 ＋ FPS）；
  **内存/磁盘/网速仍走 FLINT 本地直读**（那些字段 `v_=0` ⇒ `api_to_rows` 会跳过、保留本地值）。

**FLINT 侧**：新增 `apps\m2_float\stitch.fl`（缝合层）＋ 开关 `tmp\row-probe\stitch.on`
（优先级 **demo > stitch > http(8080) > 本地直读**）；app 用 **`flint -admin`** 构建（桥内部是 LHM 的 Ring0 读 MSR，
要管理员；本机 UAC 静默提权，不会弹窗）；**产物目录必须有 `HwBridge.dll`**（导入表在启动时解析，缺了起不来）。

**实测证据（全部有输出）**
- 宿主探针 `libcs\hwbridge\hwcheck.exe`：**非提权** → GPU `39°C/26%/0.498G/12W` 有值、CPU 三项无值（预期）；
  **提权** → CPU `58°C / 9.0% / 3093 MHz / 56.3W` 全活、整机 `114.3W`；调用后 `Thread@+0x1020 flags=0x1`（Attached）
  —— 与 §4.7 同一套**真初始化判据**。
- 浮窗本体（提权 /**8080 关掉**/`stitch.on`）**连跑 10 次全绿**：`rd=…tv1`（温度有效）、`CPU|47~52°C|6~10%|3.1G|`、
  `功耗≈111W CPU54 GPU12|`；同刻 C# 版 8080 报 `49°C / 3093MHz / 73W`（同量级，采样时刻不同）。

**两个坑（都值得记）**
1. **FLINT 的 `api` 声明必须落在「合并后 token 流最开头连续的一段」** —— 写在被 `include` 的文件里（哪怕是那个文件的顶部）
   会报「api 声明必须放在文件最顶部」；正解 = 放在**主文件绝对顶部、任何 `include` 之前**（见 `main.fl` 顶部那两条）。
2. **带 admin 清单的产物不能用 `& exe` 直接起**（PowerShell：`The requested operation requires elevation`）→ 用 `Start-Process -Verb RunAs`。

**另一个坑（AOT 侧）**：缝合一个内部用 gzip 的库（LHM 要解它内嵌的驱动）会拖进 `System.IO.Compression.Native`(zlib)，
zlib 的 `inftrees.c` 引用 MSVC 的 `__report_rangecheckfailure` ⇒ 链接期 `undefined symbol`；
已在 `shim\crtshim.c` 补了最小实现（真行为是 fastfail，生产该改）。

**FPS 的诚实状态**：桥里实现了 **RTSS 共享内存**读取（口径抄本项目 C# 版 `E:\HardwareMonitor\RtssReader.cs`），
实测**通道本身正确**（`RTSSSharedMemoryV2` 可读、签名 `0x52545353`、`entrySize=12416 / arrOffset / arrSize=256` 全对），
但**当前没有任何应用被 RTSS 钩住**（entry[0] `flags=0x10000` = 未检测到图形 API）⇒ 拿不到 FPS；
而 C# 版 config 是 `FpsMode=presentmon`（走 PresentMon/ETW）所以它有数。**要不要在桥里跟 PresentMon，待拍板。**

**回退**：`apps\m2_float\*.bak-*`；或删 `stitch.on` 即退回 8080/本地直读；`libcs\` 可整删（与编译器无关）。

### 4.8.1 ⚠️ 更正 + 补测（2026-09-16 22:5x）：**槽宽不一致**才是"FPS 读不到"的真原因

**上面那段"连跑 10 次全绿"要重新解读**：那 10 次里 CPU 温度确实来自桥（碰巧对），
但**掩码（`buf[22]`）整个读错了** —— 所以 load/clock 等字段其实是**本地直读值**，FPS 位恒为 0。
根源是记忆里记过的老坑**复发**：**FLINT 的 `int` 是 8 字节槽，C 的 `int` 是 4 字节**，
而 `hw_snap` 是按 24×4 字节写的 ⇒ 缓冲区整体错位（实测 `int b[j]` 落在字节偏移 `8*j`，
于是 `b[2]` 读到的是桥的第 4 槽）。**现象极阴险**：低位几个槽"看着对"，高位的掩码位恒为 0。

**修法（已落地）**：桥多导出一个 **`hw_snap64(long long*)`**（写 8 字节槽），FLINT 侧改用它；
`hw_snap`（4 字节槽）保留给 C 宿主/探针。**判据**：让宿主把每个槽读回来逐槽对位 ——
实测（非提权）`b1=14822`(CPU 占用) ／ `b4=40000`(GPU 温度) ／ `b6=494`(显存 MB→ 494) ／
`b8=12000`(GPU 功耗) ／ `b20=57000`(整机) ／ **`b13=120005`(FPS)** ／ `b22=3154290`(掩码) ／ `b23=15`(状态位全置) ✓。

**FPS 端到端证明**（受控样本法）：桥里 RTSS 读取支持用 `HWBRIDGE_RTSS_MAP` 环境变量
**或**与 DLL 同目录的 `HwBridge.rtssmap.txt` 指向"另一张同布局的共享内存"，
于是可以**造一张 120fps 的假 RTSS** 来验：提权宿主 ✅ 读回 `fps=120005`（`FLINT明细` 判据位 `rfl=1111`）、
**浮窗里 FPS 行真的渲染出来了（`FPS|120|`，rows 5→6）** ✓。
（真实 RTSS 当前没有被钩住的应用 ⇒ 显示"--"；C# 版默认走 `FpsMode=presentmon`，要不要跟仍待拍板。）

**顺带**：本机 Defender 会把自造 PE（手链 AOT DLL / FLINT 产物 / 读 MSR 的探针）归因成
`VulnerableDriver:WinNT/Winring0`（连"只是打开那个驱动的进程"也算）⇒ 已按老规矩加**目录级**排除
`E:\FLINT-lab`（文件级无效）；加完重跑，检测数不再增长。

**修好槽宽后的稳定性复核（10 次 · 提权 · **无 8080** · 带受控 RTSS 样本）**：**10 / 10 全绿**。
判据三条同时成立：① `rd=…tv1`（CPU 温度有效）② 快照掩码 `fps=1`（bit13 有效位）③ **FPS 行渲染出来**。
逐次实测：`CPU|58~63°C|8~10%|3.1G|`、`FPS|120|`（受控样本的 120fps）、`功耗≈111~120W`。
⇒ **浮窗在"没有 C# 版进程、没有 8080"的条件下，靠缝合进来的 C# 库把 CPU 温度/频率/功耗、GPU、FPS 全拿到了。**

### 宿主无差别验证（本轮补测，含一条自我纠错）
- **`static\out\hostimp.exe`（导入表形态宿主、无 CRT、单段，形状最接近 FLINT 产物）× 60 = 60/60** ✓
  （`CsLib.dll` 已换成新版；`cs_add(2,3)=5`，退出码 42）。
- ⚠️ **一条无效的 A/B，记下来别重犯**：我本想"拿 `static\out` 里那份旧 `CsLib.dll` 当对照再跑 60 次"，结果旧版也 60/60 ——
  因为那份旧产物是**静态库路线**（`静态库＋C 壳＋自有 /ENTRY`，§4.3.2 里"已验证可用"的那条）的构建，
  **不是同一条链路的"修复前"版本** ⇒ 该对照**不成立**。**有效对照**只能是：同一条链路、只改动因（前置块大小/TLS 布局），
  即 §4.7 里 0x3000 变体 **4/20**（且多为致命错误）vs 对齐版 **40/40（逐条真初始化）**。
- ⏳ **仍未做的验收**：`probe1_new.exe`（FLINT 产物）走的是 `cabridge.dll`（纯 C 实现，`cs_add` 就是 C 加法），
  其 60/60 **只是基线、与 C# 库无关**。

### ✅ 真验收通过：FLINT 产物**导入表直调** `CsLib.dll`（2026-09-16 22:3x）
- 源码/产物：`tmp\race-probe\t_cslib.fl` → `t_cslib.exe`（**1024 字节纯自产机器码 PE**，未借汇编器/链接器），
  声明 `api "CsLib.dll" int cs_add(int, int);`（v1.4.8 的字面量全名），同目录放 `CsLib.dll` 即可运行。
- **对照（同一宿主、同一源码，只差 DLL 版本）**：
  | 版本 | 结果 |
  |---|---|
  | **修复前**（`CsLib-notlsdir.dll`，无 TLS 目录的旧构建） | **5 次：1 次卡死(>3s，疑 WER 弹窗) ＋ 4 次 `0xC0000005`** |
  | **修复后**（前置 0x1000 ＋ 尾部填充、两侧偏移对齐） | **60 / 60 成功**（`cs_add(2,3)=5`，退出码 42） |
- ⇒ 这条同时**复测并推翻**了 §4.3 里的旧结论「FLINT 产物走导入表调用 ❌ `STATUS_DLL_INIT_FAILED`(0xC0000142)」：
  现在**通过**。**卡点从头到尾都不在 FLINT 侧**，而是镜像的 TLS 布局（§4.7 三条件）。
- 附带一条观察：修复前那次「卡住 >3s」不是程序在算，更像**错误弹窗在等用户点**（同族于「判'挂住'前先看产物文件」）。

### ▶ 剩下可选的两件事（都不阻塞"可用"结论）
1. **固化进 FLINT 用法/文档**：目前"导入表任意 DLL 名"只验证了 `api "CsLib.dll"` 这一形态，
   §4.3 的 `api` 用法/错误提示可以顺手补一句"外部 DLL 必须自带 TLS 目录（或缺了要补）"——**这是对方镜像的事，不是 FLINT 的事**。
2. **静态库路线（`静态库＋C 壳＋自有 /ENTRY`，即 `cacslink`）**是否也要按 §4.7 的三条件对齐一遍 TLS 布局（那条本轮未动、也没复测）。

## 4.9 🔧 工程化收尾（2026-09-16 22:5x–23:xx，任务卡 T-20260916-224506）

**① 一键构建脚本（把 §4.1/§4.7 的配方固化成一条命令）**：`libcs\hwbridge\一键构建.ps1`
（**纯 ASCII 源**：PS 5.1 读无 BOM 的 .ps1 按 GBK 解码，中文会炸成假语法错——这是本仓库的老坑）。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\FLINT-lab\libcs\hwbridge\一键构建.ps1"            # 全量：编译+部署
powershell ... -File 一键构建.ps1 -NoDeploy    # 窗口在跑（DLL 被占用）时只编译
powershell ... -File 一键构建.ps1 -Verify      # 再加"起不起得来"的正反判据
```

它按顺序做六件事，每步都有输出/退出码：**先决条件 → 重建 `crtshim.obj`（`-DSHIM_INIT_MODE=4`）＋重生成 `altnames.rsp`
→ 清 `obj\…\native` / `out` / `bin`（MSBuild 增量**不会**因改垫片或链接参数而重链接）→ `dotnet publish`
→ 产物断言 → 部署（SHA256 比对）**。

- **本次实测（从"干净目录"起跑）**：publish **30 s**、产物 `out\HwBridge.dll` **5,715,456 字节**、
  断言 **`hw_*` 导出 6 条齐全** ＋ **TLS 数据目录存在**（`Entry 9 … Thread Storage Directory [.tls]`）＋ **产物新于 `crtshim.obj`**（证明真重链接过）⇒ 全绿退出码 0。
- **踩到的第一个坑（值得记）**：脚本第一版用 `PATH` 上的 `dotnet` → 报 **`No .NET SDKs were found`**。
  根因：**本机 `PATH` 上是 `C:\Program Files\dotnet\dotnet.exe`（只有运行时、没有 SDK），SDK 装在 `E:\dotnet`（8.0.424）**。
  修法 = 脚本自己按候选列表挑**能 `--list-sdks` 出结果**的那个，并顺手设 `DOTNET_ROOT`。
  ⇒ 判据：**"dotnet 命令能跑" ≠ "有 SDK"**，自动化脚本必须显式解析 SDK 位置。
- **第二个坑**：`& dotnet … 2>&1 | ForEach-Object {…}` 把原生命令的 stderr 包成管道 → 退出码/报错都被搅乱（老坑再现）。
  修法 = **重定向写在调用上**（`*> $log`）且调用前后把 `$ErrorActionPreference` 临时置 `Continue`，只认 `$LASTEXITCODE`。

**② 部署说明**：`libcs\hwbridge\部署说明.md` —— 三步跑起来（产物目录必须同时有 `m2_float.exe`（`flint -admin` 构建）＋ `HwBridge.dll`）、
**缺 DLL 直接起不来**（导入表在启动期解析）、三条绝不能碰的红线（前置 TLS 块 0x1000 / 必须有 TLS 目录 / 别自己调 `RhInitialize`）、回退与已知边界。

**③ FPS 决策（用户 22:5x 拍板选 B）**：桥的 RTSS 通道本身已验证正确（受控样本 120fps 验过），
但**真实 RTSS 当前没钩住任何应用** ⇒ 浮窗显示 `--`；而 C# 参考版走 **PresentMon**（起外部 `PresentMon.exe` + 解析其输出），
本次同刻读到 **69.9 fps / 1% low 18.6** ⇒ 属**用户看得见的差异**，不只记边界 ⇒ **新开任务卡 `T-20260916-225704`**
（桥内置 PresentMon 采集：起子进程 + 解析帧输出，RTSS 保留为回退；含"无 exe / 进程被杀时降级不崩"的验收）。

**④ 自检开关隔离（用户 22:5x 拍板选 A）**：`dump.on` / `demo.on` 的探测路径从 `tmp\row-probe\` **挪进 `tmp\row-probe\selfcheck\`**
（`main.fl` 两处常量 + 文件头注释同步）——自检开关与**运行**开关（`http.on` / `stitch.on`）**物理分开**，交付/演示时不会误留。
目录不存在 ⇒ `CreateFileA` 失败 ⇒ 开关不生效，属预期（不需要预先建目录）。**正反判据实测通过**：
新路径放开关 → 真 dump 后自退（exit=0、`rows-dump.txt` 23 行含 CPU 行）；只在**老路径**放开关 → **被忽略**（窗口照常起来、无 dump）。
⚠️ 消费点要一起改：`test\cfg-probe.ps1` 引用 dump 路径（已同步，注意该文件带 BOM，edit 后必须补回）。

**⑤ 逐条验收成绩单**（`apps\m2_float\验收成绩单-缝合态.md`）——对 C# 参考版 `浮窗规格-对C#逐细节.md` §1~§6 逐条给系统视角证据。
**一致项**：无边框/置顶/任务栏/尺寸公式（5 行→111px、6 行→130px **双向吻合**）/字体/最小尺寸/面板与描边**源色逐值**/
三档阈值与 4 个色值**逐值**/格式化口径/行序与显示条件/config **37 键集完全一致（双向差集 0）**/菜单结构与勾选态（提权后系统视角读回 `#32768`）。

**🔧 新查出的 4 处真差异（全部有根因、已修，等复测）**

| # | 差异（用户可见） | **根因（实测 + 源码定案）** | 修法 |
|---|---|---|---|
| ① | CPU 温度偏高 ~11°C（58~62 vs 参考 49~52） | **两层都错**：① 桥给的是 **LHM 原始读数**，而 **C# 是在快照层才套 `ApplyCpuOffset`**（`MonitorForm.cs:148`）⇒ 它的 8080 接口给的是**校准后**的值（50 = 61−11 ✓）；② **传感器口径不同**：参考取 `max(Package/TjMax/Core)`（`HardwareReader.cs:82`），桥只取 `package`（`lhmprobe` 全表实测：Core #1~#8 = 57~61、Package 62、Core Max 61） | ① 只在**缝合路径**补 `cfg.cpu_offset`（带 `v_cpu_temp==1` 守卫）；**8080 路径绝不能补**，否则双重校准 ② 桥新增 `MaxSensByName(...,"package","tjmax","core")` 与参考同口径。**复测：同刻 46 vs 参考 44 ✓** |
| ② | 面板透明度 0.47 vs 参考 0.60 | 参考面板像素的表面 α 实为 **255**（GDI+ 在**不透明表面**作画，0.6 只乘一次）；我们是掩码 200/255 × 0.6 = **0.471**（三底法：黑/白/灰三底、三通道全一致） | `surf.fill_a` 200 → **255** |
| ③ | 描边比参考亮得多（黑底 (78,120,153) vs ≈(21,33,42)） | **不是 α 的错**：我们描边 α_eff = **0.165** 与参考 0.18 **本来就一致**（`out(B)=C+B(1−A)` 三底联解）。真根因 = **ULW 源位图没有预乘** ⇒ `AC_SRC_ALPHA` 下 Windows 按"源已预乘"解释，源色按**整份常量**加上去 | `surf_alpha` 写完 α 后**按 a/255 预乘 RGB**（a==255 跳过；`% 256` 当无符号字节读） |
| ④ | 缺 `WS_EX_NOACTIVATE`（点浮窗抢焦点） | 建窗 exstyle 0x00080008；参考窗实测 0x08090008 | `ui_make_top` 改 **0x08080008**（只改浮窗在用的那个 helper，`ui_make` 保持原样） |

**✅ 复测（2026-09-17 00:0x，改完即测，全部有输出）**：① CPU 温度 **46 vs 参考 44**（同刻；修前 58~60 vs 49~52）；
② 面板合成 α **0.600**（三底法：黑 (10,10,11)／白 (112,112,113)／灰 (61,61,62)，理论 111.6、参考 0.607；修前 0.471）；
③ 描边像素黑底 **`(21,32,42)`**／白底 **`(234,245,255)`**（理论 (21,33,42)／(234,246,255)；修前 (78,120,153)）、有效 α 0.165、圆角处 `(0,0,0)` 全透明；
④ exstyle **0x08080008**（`NOACTIVATE=True`；参考 0x08090008 多一个 `WS_EX_CONTROLPARENT`，对无边框弹窗无影响，不追）。
**交互回归**（确认 NOACTIVATE 没把交互改坏）：拖拽探针 **3/3**、右键菜单 **`#32768` 弹出且 13 项子项勾选态全对**。**回归 764/764**。
**长跑定案**：第 1 轮"首末对比" +78% 是暖机虚高 → 改用**稳态（跳过前 5 分钟）**口径，**第 2 轮（最终二进制）稳态 +2.8%**、0 崩 0 WerFault、58 次采样的 `tcp` 恒为 0 ⇒ **达标**。

**方法学产出（值得复用）**：测半透明窗不能拿单底反解（纯红底上**两个窗**的 R 通道都偏，是合成/取色的共同现象）——
改用**三底法**：放黑/白/灰三张纯色底板在窗后，`A = 1 − (out_white − out_black)/255`，
该式**与背景无关、也不假设源色**，再拿灰底当第三点校验线性；判据只看 G/B 两通道。
另：探针**必须与浮窗同权限**（浮窗带 `requireAdministrator` 清单，普通权限探针的 `PostMessage` 被 **UIPI 静默拦截** →
现象是"菜单没弹出来"的**假红**）。

## 4.10 ✅ 收口 §4.4：codegen 折中优化 · 第一档（纯窥孔）—— 空循环 3.97 → 2.28 ns/轮，产物还小了 18%（2026-09-17，任务卡 T-20260917-011322）

> **动机**（用户观察「FLINT 体积很小，但性能开销与 C# 版没太大差距，速度也慢」）⇒ 拆成两件事各自量：
> ① **窗口开销**（任务管理器那个数）＝ `m2_float` 6.17% 单核，C# 参考版同档 ⇒ **这类程序本来就不吃 CPU，两边同档是正常的**；
> ② **代码本身** ＝ 我方生成的代码每步都过内存/过栈（§4.4，**倍数不报**）⇒ **本卡治的是 ②，别指望它在任务管理器里看得见**。
> **用户拍板折中：只做纯窥孔，不碰寄存器分配。**

### 改了什么（`src\codegen.c` 一个文件，`+204 / −31` 行）

| # | 窥孔 | 旧（靶子 = bench4 / regbench 的循环体） | 新 |
|---|---|---|---|
| ① | **比较塌缩** | `cmp eax,ecx` / `setl al` / `movzx eax,al` / `test eax,eax` / `je 目标` —— **五条干一条** | `cmp eax,ecx` / `jge 目标` —— 一条 |
| ② | **去栈往返** | rhs 是变量时：`push rax` / `mov eax,[rbp-n]` / `mov ecx,eax` / `pop rax` | `mov ecx,[rbp-n]`（wide 时 `movsxd rcx,dword [rbp-n]`） |
| ③ | **常量不物化** | `mov eax,3` / `mov ecx,eax` / `push` / `pop` / `add eax,ecx` | `add eax,3`（`83 /0 ib`；够不着 imm8 时 `05 imm32`） |

**落地要点（都是"边界"而不是"技巧"）**：
- ① 与 `gen_cmp` **共用** `gen_cmp_flags`（取值 / 宽度 / 符号扩展只有一份实现），差别只在结尾：作值 → `setcc + movzx`；作条件 → **取反条件码的 jcc**（`jcc = setcc − 0x10`；"假则跳" = 取反：`jl↔jge`、`jle↔jg`、`je↔jne`）。顺带把 `!x` 也塌缩掉（旧路同样 `test + setcc + movzx + test` 白绕三圈）。
- ① **double 比较一律不塌缩** —— NaN 语义（v1.2.3 修好的 `!=` / `<`）是「有序 ∧ 谓词」的多谓词组合，单个条件码表达不了，硬塌缩会把那两个 bug 放回来。
- ② 只认「**普通局部 int**」：全局读走 rip-relative 64 位约定、char 是 `movzx` 字节、double 走 xmm0、数组 / 结构体名是首地址、`is_ref` 要先读地址再解引用、T1 标记槽是 8 字节读 —— 再复刻一份就是"同一规则两处实现"，只做宽度确定的那一档。
- ③ **`and` / `or` / `xor` 的 imm8 只在 `imm ∈ [0,127]` 时可用**（符号扩展会把高位置 1：`and eax,0x80` 写成 imm8 就变成 `and eax,0xFFFFFF80`，静默错值）；`add` / `sub` / `cmp` 的负数符号扩展是**正确语义**，照走 imm8。
- **红线守住**：不动 `.tls` / 入口 / 调用约定；**只删指令**，不靠膨胀换速度。

### 四基准同工具前后对照（`tmp\cabridge\regbench.exe`，2000 万轮，同机同工具）

| 基准 | 改动前（旧编译器） | 改动后（新编译器） | 结论 |
|---|---|---|---|
| **空循环** `while(i<n){i=i+1;}` | **3.97 ~ 3.98 ns/轮**（79.34~79.52 ms） | **2.28 ns/轮**（45.49~46.54 ms，三轮） | ✅ **主判据达标**（卡上目标 ≤2.5） |
| 串联 `a+=3; i=i+1;` | 4.14 ns/轮（82.73~82.79 ms） | **1.96 ~ 2.00 ns/轮**（39.25~40.02 ms） | ✅ 不退化，大幅改善 |
| 三个独立变量 | 4.72 ns/轮（94.44~94.49 ms） | **2.28 ns/轮**（45.52~46.04 ms） | ✅ 不退化，大幅改善 |
| 真实热点 `hw_snap64` | 1.17 ~ 8.03 ms/次（**不可复现**） | 同区间波动 | ⚠️ **只做定性参考、不设阈值**（LHM 采样本身波动一个数量级，codegen 那点成本淹没在噪声里） |

> 读数口径：`ns/轮 = 实测 ns ÷ 20,000,000`；时钟用 `cabridge` 的 `cs_now_ns`（两侧同源）；每项两项编号 = 同进程内两轮。
> **一个反直觉但如实记录的观察**：改动后「空循环」（2.28）反而**慢于**「串联 a+=3」（1.96）——空循环指令最少却最慢，
> 与"指令数越少越快"的朴素预期不符；怀疑与循环体对齐 / 指令条数太少导致前端与分支吞吐成为瓶颈有关，
> 本轮**没有进一步定位**（不影响验收结论：两者都远好于改动前）。

**产物尺寸（同向下降）**：`regbench` 2560 → **2048 B**；`m2_float.exe` 154,112 → **125,952 B（−18.3%）**（卡上预算 ≤174KB 且 ≤现在 ×1.15）。

### 不退化证据（两条独立判据）

1. **回归 764/764（exit=0、0 失败）**；`gcc -O2 -Wall -Wextra` **7 条警告 = 基线，零新增**。
2. **既有产物行为不变**：同一份 `main.fl` 用新旧编译器各出一份 `m2_float.exe`，跑 `dump.on` 自检取「文本成绩单」逐行对账 ——
   **29 行里差异 10 行，全部是实时量**（`tick` 运行计数 / `rd=l007` vs `l009` 读取计数 / CPU 占用 7% vs 9% / GPU 占用 4% vs 0% / 功耗 109W vs 116W），
   **结构性内容 100% 一致**（`rows=6 segs=17` / `sw` / `cfg` 12 项 / `raw23` / `raw22` / `pmsrc` / L0~L5 行标签与格式 / RAM / NET / FPS）。
   另：`realbench` 里 `mask=3154290`、`fps=136705` 新旧**逐位相同** ⇒ ABI / 数据通路一行未动。
   真窗口冒烟（系统视角、非截图）：`FLINTM2` 窗口在位、187×130 可见（130px = 6 行，与规格一致），干净关闭。

### 现场（回退用）

- 编译器留底：`flint.exe.bak-20260917-015019`（改动前，200,366 B）；A/B 用旧编译器副本 `tmp\cabridge\flint_old.exe`。
- 产物留底：`apps\m2_float\m2_float.exe.bak-20260917-020332`（154,112 B）；基准对照产物 `tmp\cabridge\regbench_old.exe` / `regbench_new.exe`。
- 窥孔对照现场：`tmp\peephole\`（`dump_old.txt` / `dump_new.txt` 文本成绩单、`m2_float_prev.exe`）。

### ⚠️ 与 gcc 的倍数：**本档报不了** —— gcc -O2 把这几个玩具循环整体删掉了（2026-09-17 当场实测）

用户问"现在 FLINT 性能如何"，想给一个跨编译器的倍数时，按"同一把尺子"的规矩现造了逐字等价物 `tmp\cabridge\regbench_c.c`
（同三个循环、同一 `cabridge` 时钟、同机同刻），结果**量到的是空气**：

- **第一版**（轮数写死 20000000）：`objdump` 看 `main`，**里面根本没有循环**，只剩两条背靠背的取时钟 ——
  gcc 用「循环终值替换」把三轮循环折成闭式（反汇编里就一条 `mov $0x1312d00,%edx`，即 n 本身）。
- **第二版**（轮数改从 `argv` 拿，编译期不可知）：**照样被删** —— `main` 共 145 条指令、**无一条向后跳转**。
- **实测**：20,000,000 轮的三项分别报 **100 / 0 ns**、**100 / 100 ns**、**0 / 0 ns**，而 sanity 值
  （`x=60000001 y=60000002 z=60000003 a=60000003 i=20000000`）与 FLINT 侧**逐位相同** ⇒ **gcc 那一侧一圈都没跑**。
- ⇒ **两侧数字不可比**（那一侧是另一种循环形状、另一次量的）⇒ **跨编译器倍数一律不报**；
  **凡"FLINT 比 gcc 慢 N 倍"的说法，都必须先证明 gcc 那边真的跑了循环**（同族于「基准测的是空气」）。
- **本档可信的只有同侧前后对比**（同工具、同刻、同一形状）：空循环 3.97 → **2.28**、串联 4.14 → **1.96**、
  独立变量 4.72 → **2.28**（ns/轮）。要一个**可信的跨编译器倍数**，需要一个"两边都不可折叠"的形状
  （每轮有可观测副作用 / 结果逐轮逃逸到内存），**本轮未做**。

### ⚠️ 本轮撞到的两个坑

1. **`try_gen_cmp_branch` 的布尔参数传反**（`jump_if_false` 处传了 `false`）⇒ 所有 `if` / `while` / `for` / 三元的判断**整体翻转**，
   回归当场红 **89 项**（`comp1` 期望 55 实得 0、`ctrl1` 期望 1 实得 2、`ctrl9` 期望 7 实得 99 …）。
   教训：**布尔位置参数的语义在调用点极易传反**（`false` 究竟是"假则跳"还是"不假则跳"从调用点读不出来）——
   机械兜底是**全量回归**（764 项一轮 23 秒就抓住了）；更好的做法是**别用裸 bool**（改枚举 / 具名参数）。**已进记忆候选区。**
2. **A/B 对照的编译器必须放在同一目录**：旧编译器放在 `tmp\cabridge\` 时跑 `main.fl` 直接报 `include 文件不存在: num_lib.fl` ——
   因为 `flint.exe` 按**自身所在目录**找 `lib\`。这与记忆里「A/B 对照必须同环境」是同一坑的又一次现形（目录 / PATH / 依赖搜索路径都算环境）。
   **附带**：`dump.on` 自检模式下 app **写出 `rows-dump.txt` 后并不自退** ⇒ `Start-Process -Wait` 会挂满超时；
   而且它是**提权进程**，普通权限 `Stop-Process` 杀不掉（`Access is denied`）→ 要 `taskkill /F` 配 `RunAs`。
   正解：**轮询产物文件出现即收工**，别等进程退出。**已进记忆候选区。**







