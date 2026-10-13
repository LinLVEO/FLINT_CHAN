# 🪟 浮窗规格圣经 —— 对 C# 版逐细节还原（FLINT 目标 A）

> **权威来源**：`E:\HardwareMonitor\MonitorForm.cs`（1250 行，2026-09-01 00:26）+ `GdiCache.cs` + `AppConfig.cs` + `发布\config.json`
> **本文件性质**：**验收基线**。FLINT 版每实现一项，就按本表逐条对照；对不上的地方必须写清「为什么不同」。
> **当前状态**：规格圣经已成型（§1~§6 逐条带行号）；**第 1 步字形层 ✅（v1.4.0）＋ 第 3 步图层表面 ✅（v1.4.1）
> ＋ 第 4 步行构建器 ✅（v1.4.2）已落地**
> （8 行结构 + 三档配色 + 全部格式化规则 → `apps\m2_float\float_rows.fl`；回归 747/747）；
> 下一步 = **第 5 步数据源（8080 JSON：补 HTTP + JSON 两个语言特性）**。任务卡 `T-20260915-232845`（已完成）
> **⚠️ 对标前提**：C# 版需**在跑**（`E:\HardwareMonitor\发布\HardwareMonitor.exe`）。
> 实测 2026-09-15 23:02：**已启动**，8080 `HTTP 200`，窗口 `(184,199) 207×130`；现场读数 6 行（FPS/CPU/GPU/RAM/NET/功耗）。
> ⚠️ 两个浮窗会**互相重叠**（C# 在 (184,199)，FLINT 默认 (300,180)）→ 抓屏对照前先把其中一个挪开。

---

## 一、窗口本体（逐字段）

| 项 | 值 | 源码位置 |
|---|---|---|
| 边框 | `FormBorderStyle.None`（无边框） | `MonitorForm.cs:185` |
| 置顶 | `TopMost = true`，**每 ≥2 秒** `SetWindowPos(HWND_TOPMOST, NOSIZE\|NOMOVE\|NOACTIVATE)` 钉回一次 | `:186`、`:1095-1098`、`:1114-1118` |
| 任务栏 | `ShowInTaskbar = false` | `:187` |
| 初始尺寸 | `184 × 199`（来自 config X/Y 与上次尺寸） | `发布\config.json:2,3` |
| 不透明度 | `Opacity = clamp(OpacityPercent,20,100)/100` → config=60 → **0.60** | `:191`；config `OpacityPercent:60` |
| 字体 | **Consolas, 16, GraphicsUnit.Pixel** | `:192`、`:416`；`GdiCache.cs:24` |
| 最小尺寸 | `MiniBoxSize = 34`（`WM_GETMINMAXINFO` → `ptMinTrackSize=(34,34)`） | `:1142`、`:593` |
| 小窗模式 | `MiniMode` 时 `Size = 34×34` | `:101`、`:1129-1131` |
| 擦除背景 | 自绘（`OnPaint` 内完成，双缓冲由 WinForms 提供） | `:960-1013` |
| 光标 | 类光标 **IDC_ARROW**（记忆入档的坑：不设会一直转圈） | 见 `记忆.md` |

## 二、绘制（像素级）

| 项 | 值 | 位置 |
|---|---|---|
| 抗锯齿 | `SmoothingMode.AntiAlias`（圆角用 GDI+ 平滑） | `:964` |
| 文字渲染 | `TextRenderingHint.ClearTypeGridFit` | `:965` |
| 背景圆角矩形 | `Rectangle(1,1,Width-2,Height-2)`，圆角半径 **6** | `:982-983` |
| 背景填充色 | `ARGB(200, 16, 16, 18)` | `:984` |
| 边框描边 | `ARGB(70, 130, 200, 255)`，宽 **1** | `:985` |
| 段落文字 | 逐段 `DrawString`，x 起步 `Pad=8`，**每段后 `x += ceil(MeasureString(段).Width) + 3`** | `:988-998` |
| 行间距 | `LineHeight = FontSize + RowGap = 16 + 3 = 19` | `:52-53` |
| 行 y 起步 | `y = Pad = 8`，每行 `y += 19` | `:988-999` |
| 窗口高度算法 | `h = Pad*2 + rows*19`（**与 C# 行高无关**，纯整数） | `:786,793` |
| 窗口宽度算法 | `w = Pad*2 + max_rows( Pad + Σ(ceil(Measure(段).Width)+3) )` | `:786-792` |
| 尺寸重算时机 | **仅当行文本签名变化**（`BuildRowsKey`）→ 避免每 tick 抖动 | `:775-782` |
| 小窗绘制 | 圆角矩形 `Rectangle(1,1,W-2,H-2)` 半径 6，填充 `ARGB(215,16,16,18)`、描边 `ARGB(90,130,200,255)`；中心画 `CPU占用%`（字体 12px）：文本量宽后居中 `(W-w)/2, (H-h)/2 - 1` | `:968-979` |
| 底部状态条 | 字体 11px，颜色 `ARGB(255,210,150)`，位置 `(Pad, Height-15)`，超宽则从尾部逐字截断 | `:1003-1012` |

### 2.1 三档颜色（**温度与占用阈值不同，别混**）

| 用途 | 阈值 | 颜色 |
|---|---|---|
| 温度 `TempColor` | ≥80 → 红 | `ARGB(255, 90, 90)` |
| | ≥60 → 橙 | `ARGB(255, 170, 60)` |
| | 其余 → 白 | `ARGB(235, 235, 235)` |
| | 无值 → 灰 | `ARGB(170, 170, 170)` |
| 占用 `LoadColor` | ≥90 → 红 | `ARGB(255, 90, 90)` |
| | ≥70 → 橙 | `ARGB(255, 170, 60)` |
| | 其余 → 白 | `ARGB(235, 235, 235)` |
| 标签文字 | 恒 `TextMain` | `ARGB(235, 235, 235)` |
| 次要文字 | 恒 `TextDim` | `ARGB(170, 170, 170)` |

（`MonitorForm.cs:65-66`、`:943-957`）

## 三、数据与格式化（逐函数）

| 项 | 规则 | 位置 |
|---|---|---|
| 数据来源 | **LibreHardwareMonitor 库 in-process + 8080 数据接口**（C# 侧自采） | `HardwareReader.cs`、`DataApi.cs` |
| 刷新周期 | `Timer.Interval = 500ms` | `:17` |
| CPU 温度校准 | `ApplyCpuOffset = 温度 + CpuTempOffset`（本机 **-11**，自动识别 Xeon E5 v1 的 TjMax 91 vs 库按 102） | `:902`、`:447-461`；config `CpuTempOffset:-11` |
| 温度格式 | `F0` + `°C`（如 `45°C`），无值 `--` | `:914` |
| 百分比格式 | `F0` + `%`，无值 `--` | `:915` |
| 频率格式 | ≥1000 → `{mhz/1000:F1}G`；否则 `{mhz:F0}M` | `:916` |
| 内存对 | `{used:F1}/{total:F1}G`；只有 used → `{used:F1}G`；used≤0 → `--` | `:918-924` |
| 网速 | ≥1024 → `{k/1024:F1}M`；否则 `{k:F0}K` | `:927-932` |
| 显存 | `{used/1024:F1}/{total/1024:F1}G` | `:934-941` |
| 整机功耗 | `EstimateSystemPower = (CPU瓦 + GPU瓦) + PowerBaseWatts`（底噪常数 **45**）；无任何部件值 → 不显示该行 | `:904-912`；config `PowerBaseWatts:45` |

## 四、行构建顺序（`BuildRows`，`:811-899`）

| # | 行 | 段（颜色） | 显示条件 |
|---|---|---|---|
| 1 | **FPS** | `FPS`(main) `{fps:F0}`(main) `1% {low:F0}`(dim) `·{来源}`(dim) | `ShowFps` 且 fps>0；fps 无但 low 有 → `FPS`(main) `--`(dim) `1% xx`(dim) |
| 2 | **CPU** | `CPU`(main) `{温度°C}`(温度色) `{占用%}`(占用色) `{频率}`(dim) | `ShowCpuTemp \|\| ShowCpuLoad`；频率段仅当 `CpuClock>0` |
| 3 | **GPU** | `GPU`(main) `{温度°C}`(温度色) `{占用%}`(占用色) `{显存}`(dim) | `ShowGpuTemp \|\| ShowGpuLoad \|\| ShowGpuMem` |
| 4 | **RAM** | `RAM`(main) `{used/total}G`(main) `{占用%}`(占用色) | `ShowRam` 且 total>0 |
| 5 | **DISK** | `DISK`(main) `{占用%}`(占用色) `{used/total}G`(dim) | `ShowDisk` 且 DiskLoad 有值 |
| 6 | **NET** | `NET`(main) `↓{速度}`(main) `↑{速度}`(dim) | `ShowNet` 且任一方向有值 |
| 7 | **FAN** | `FAN`(main) `{rpm:F0} RPM`(dim) | `ShowFan` 且 rpm>0 |
| 8 | **功耗** | `功耗≈{sys:F0}W`(main) `CPU{x} GPU{y}`(dim) | `ShowPower` 且 sys 有值；明细段仅当 `ShowPowerDetail` |
| — | **兜底** | `CPU {温度°C}`(温度色) | 一行都没有时 |

> **CUDA 行序要点**：FPS 在**最前**（最显眼）；NET 的 ↓ 用 main 色、↑ 用 dim 色；DISK 的百分比在前、容量在后（且是 dim）。

## 五、交互（`:1016-1093`）

| 操作 | 行为 | 位置 |
|---|---|---|
| 左键按下 | 未锁定 → 开始拖动，记 `_dragOffset = e.Location` | `:1016-1026` |
| 拖动 | 跟光标移动窗口（`SetCapture` 语义，见记忆坑） | `:1028+` |
| 拖动结束 | 存 config（X/Y） | `:1080+` |
| 右键 | 弹出上下文菜单（**中文项**）：显示项勾选（CPU 温度/CPU 占用/GPU 温度/GPU 占用/…）、不透明度（60/80/100%）、字号、`CPU温度校准`（不校准/±档位）、小窗模式、趋势图、极值、锁定、退出 | `:239-408` |
| 截图 | 热键 **F12**，格式 png，隐藏自身，JPEG 质量 90 | config `ShotHotkey/ShotFormat/ShotHideSelf/ShotJpegQuality` |
| 自动校准 | 识别 `Xeon E5`（非 v2/v3/v4）→ `CpuTempOffset = -11` 并落盘 | `:447-461` |
| 置顶钉回 | 每 ≥2s 一次 | `:1114-1118` |

## 六、config.json 全字段（`发布\config.json`）

`X=184` `Y=199` `FontSize=16` `OpacityPercent=60` `Locked=false` ·
显隐：`ShowCpuTemp/ShowCpuLoad/ShowGpuTemp/ShowGpuLoad/ShowGpuMem/ShowRam/Fan/Fps/Power/PowerDetail/Disk/Net`（Disk=false，其余 true）·
`MiniMode=false` `ShowTrend=true` `ShowExtremes=true` `AutoStartDelaySeconds=10` `HistoryLog=false` ·
`TrendFontSize=14` `ExtremesFontSize=14` `TrendOpacity=100` `ExtremesOpacity=100` ·
`FpsMode="presentmon"` `ShowFpsSource=true` `PowerBaseWatts=45` `CpuTempOffset=-11` `Calibrated=true` ·
`AutoStart=false` `ShotHotkey="F12"` `ShotFormat="png"` `ShotHideSelf=true` `ShotJpegQuality=90` `ShotDir=""`

**→ 按当前配置，C# 浮窗应显示的完整内容**（FPS 无数据时省略首行）：

```
FPS 60 1% 48 ·{进程名}          ← ShowFps + 有数据
CPU 45°C 12% 3.1G
GPU 62°C 7% 1.2/4.0G
RAM 9.8/15.9G 62%
FAN 1450 RPM
功耗≈120W CPU85 GPU35          ← ShowPower + ShowPowerDetail
NET ↓12K ↑3K
```
（`ShowDisk=false` 故无 DISK 行；行序固定为 FPS→CPU→GPU→RAM→DISK→NET→FAN→功耗）

---

## 七、⚠️ 已实测的「看起来像、其实不一样」（对标时最容易误判）

**C# 用的 `Graphics.MeasureString`（GDI+）与 FLINT 用的 `GetTextExtentPoint32A`（GDI）对同一串给出不同宽度**——
本机实测（Consolas 16px，ClearTypeGridFit，`E:\FLINT-lab\tmp\font-probe\FontProbe.exe`）：

| 文本 | GDI+ ceil(W) | GDI cx | 差值 |
|---|---|---|---|
| `CPU` | 33 | 24 | **+9** |
| `CPU 45C` | 69 | 56 | **+13** |
| `FPS 60 1% 48` | 115 | 96 | **+19** |
| `GPU 62C 37% 1.2/4.0G` | 187 | 160 | **+27** |
| `RAM 9.8/15.9G 62%` | 160 | 136 | **+24** |
| `ABCDEFGHIJ0123456789%/:.C` | 232 | 200 | **+32** |
| 行高 | **21**（`MeasureString().Height`） | **16**（`GetTextExtentPoint32A.cy`） | **+5** |

**含义**：直接换成 GDI 量宽，**窗口会整体缩水约 15%**、行内间距与段起点全部偏移 → 「细节一致」当场不成立。这是必须显式选路的分叉点（见交付方案 §3）。

---
*本文件的每一条都可在 `E:\HardwareMonitor\` 的对应行号复核；改 C# 侧行为时本文件必须同步。*

## 八、🚦 断点续接（2026-09-16 01:1x 更新 · **新会话从这里开始**）

> **✅ 最新进展（2026-09-16 01:0x，第 5 步「数据源 = 8080 JSON」打通）**：
> 新增 `E:\FLINT-lab\lib\http_lib.fl`（ws2_32 原生 socket HTTP/1.0 GET ＋ 极简 JSON 取值层 `json_to_snap` → `struct ApiSnap`，全部 ×1000 定点）；
> `main.fl` 主源改 8080 `/api/data`（新开关 `tmp\row-probe\http.on`；无此文件走本地直读回退）；
> **真机 dump 6 行与 8080 同一时刻逐值一致**（`CPU|54°C|16%|3.1G|` 等，明细见「下一步」节）；
> 副产品：**网速/FPS 不必再走 UAC 与手算偏移**（都从 JSON 取）。全量回归 **753/753**。
> 细节与四个坑（out 参数求值顺序 / 取数顺序 / FLINT 三条边界 / 别用 PS 管道改中文 .fl）见 `E:\FLINT-lab\PROGRESS.md` 顶部状态记录。

> **✅ 本轮进展（2026-09-15 22:5x，FLINT v1.4.0）**：
> ① **第 1 步「字形层」已落地**：FLINT 全仓库第一次用真字体——`flint_ui.fl` 新增
>    `ui_font_make(px)`（内部 `CreateFontA(16,0,0,0,400,0,0,0,1,0,0,5,0,"Consolas")`）＋
>    `ui_font_use(dc,hf)`（`SelectObject`）；`main.fl` 建窗后建字、每帧 `GetDC` 后选入 DC。
> ② **为此补了语言特性**（用户口径「缺什么停下来先加」）：`CreateFontA` 是 **14 参**，旧上限是 12 →
>    **v1.4.0 把 API 实参上限提到 16**（单点 `API_MAX_ARGS`，`flint.h`/`parse.c`/`codegen.c` 三处共用）。
>    回归 **738 → 747/747 零退化**、boot 自举 **207/207**；新增样本 `test\samples\apiarg16.fl`
>    （msvcrt printf 把第 5..16 实参=栈上 12 槽逐位打印比 stdout）＋ `apifont1.fl`（14 参建字后逐参读回，位掩码 127）。
>    细节见 `E:\FLINT-lab\PROGRESS.md` 最上面那条状态记录（v1.4.0）。
> ③ **实测证据**（探针 `tmp\font-probe\uifont1.fl`，走库里的真实函数）：选字前 DC 字体名 `System`
>    （= 之前"字不像 C#"的根因），选字后 **`Consolas`**；Consolas 16px 的 GDI 量宽
>    `CPU cx=24 cy=16`、`CPU 45C cx=56` —— **与 §7 表里的 GDI 列逐值吻合**（同一支字体同一档字号，
>    量宽口径一致，后面可直接用 §7 表算排版）。
> ④ **app 侧**：`apps\m2_float\m2_float.exe` 已重建（25600 B）并冒烟通过（窗口句柄非 0、进程存活、已关闭）。
> ⑤ **git**：`E:\FLINT-lab` 两个 commit（`02ab2b9` 上一会话遗留收尾 + `fdf3eed` v1.4.0）。

### ⚖️ 用户口径（2026-09-15 拍板，**优先于下面所有"要不要逐像素"的分叉**）
- 用户原话：「**我说的细节是用户层的 代码结构啥的尽量就行**」→ 不追内部像素级、不要求代码结构逐行对应 C#；
  以「用户看得见的细节」为准：行内容与行序 / 三档颜色与阈值 / Consolas 16px / 字号行距 / 窗口自适应 /
  交互（拖动·锁定·右键菜单·小窗模式）/ config 字段。
- **§7 那个分叉点就此关闭**：量宽原样用 GDI（`GetTextExtentPoint32A`），与 C# 侧 GDI+ `MeasureString`
  的宽度差（窗口约缩 15%）**记为已知边界**，不为它上 GDI+。
- **范围**：本轮只做**主浮窗 `MonitorForm`**；趋势图 / 极值窗 / F12 截图 / 开机自启 **不做**。

### 用户定下的开发方式（本轮明确，别忘）
> **「别硬开发 —— 有需要的特性就停下来加上」**（用户 2026-09-15 原话）。
> 落地成循环：**缺口探测 → 停下补语言特性 → 验证（全量回归 738 + 变体）→ 回到浮窗推进**。
> 禁止为了"先把浮窗跑起来"而绕过缺的能力（那会变成垃圾作品，也失去这次的意义）。

### 已确认的事实（都有出处，别重新测）
1. **规格圣经已成型**（本文件 §1~§6 全部逐条带行号，可直接当验收基线）。
2. **GDI+ 与 GDI 量宽不可互换**（§7 实测表）：换 GDI 会让窗口缩水约 15%。
   **⚠️ 且本轮进一步实测证明「不能用简单公式复刻」**（`E:\FLINT-lab\tmp\font-probe\Q.exe`）：
   | 文本 | GDI+ ceil(W) | 字符 advance 和 | 差值 | 字符数 |
   |---|---|---|---|---|
   | `CPU` | 33 | 24 | 9 | 3 |
   | `CPU 45C` | 69 | 48 | 21 | 7 |
   | `FPS 60 1% 48` | 115 | 73 | 42 | 12 |
   | `ABCDEFGHIJ0123456789%/:.C` | 232 | 183 | 49 | 27 |
   → 差值随字符串**非线性增长**（不是固定 padding、也不是简单 1/6 em），**"用 GDI ABC 宽度复刻 GDI+ 量宽"这条路本轮被实测否掉**。
3. **`Graphics.MeasureString` 的 Width 是带 padding 的**（GDI+ 文档口径），所以**不能把 C# 的宽度当成"真实排版宽度"来抄**。
4. **C# 版当前没在跑**（22:45 实测：8080 未监听、`HardwareMonitor.exe` 无进程）→ **任何"逐像素对照"必须先把 C# 版启起来**（`E:\HardwareMonitor\发布\HardwareMonitor.exe`）。
5. FLINT 侧现有能力盘点（读到源码确认，非猜测）：
   - **已有**：`RegisterClassA/CreateWindowExA(TOPMOST|LAYERED)`、`SetLayeredWindowAttributes(LWA_COLORKEY)`、`GetDC/ReleaseDC`、`FillRect`、`SetTextColor/SetBkMode`、`TextOutA`、`GetTextExtentPoint32A`、`SetCapture/ReleaseCapture`、`PeekMessageA/DispatchMessageA`、`MoveWindow/GetWindowRect`、WinRing0 读 MSR（CPU 温度/占用/频率/RAPL 功耗）、内存/磁盘快照、`std::fmt_*` 拼串、6 个库文件。
   - **缺**:① `CreateFontA` + 选入 DC（当前是 stock font，非 Consolas 16px）② **逐像素 alpha 半透明**（只有 color-key；C# 用 WinForms `Opacity` = `UpdateLayeredWindow`）③ **GDI+ 圆角 + ClearTypeGridFit 量宽**（§7）④ GDI+ 行高 21（对布局无影响，见下）⑤ **本地 HTTP（winhttp/ws2_32）+ JSON 解析**（C# 从 8080 取 GPU/整机功耗/FPS/网速/风扇）⑥ 右键菜单（中文 → `PopupMenuW` 或自绘）⑦ `ShowInTaskbar=false` + 截图热键 F12。

### 下一步（按"缺什么停下来先加"的顺序）
- ~~**第 1 步：字形层**（`CreateFontA` + `SelectObject`）~~ → **✅ 已完成（2026-09-15 22:5x，v1.4.0）**：
  `ui_font_make` / `ui_font_use` 已入 `flint_ui.fl`，实测 DC 字体名 = `Consolas`、量宽与 §7 表 GDI 列逐值吻合。
- ~~**第 2 步：量宽与行高口径（用户二选一）**~~ → **✅ 已关闭**：按用户口径（细节 = 用户层的）原样用 GDI 量宽，
  与 C# 的宽度差记为**已知边界**（见上「用户口径」）。
- ~~**第 3 步：窗口呈现**（`WS_EX_LAYERED` + `UpdateLayeredWindow` 逐像素 alpha + 圆角）~~ → **✅ 已完成（2026-09-15 23:1x，FLINT v1.4.1）**：
  做法 = **纯 GDI + 自己写 alpha 通道**（RGB 由 GDI 画、alpha 按圆角掩码写、ULW 用 `AC_SRC_OVER|AC_SRC_ALPHA`+常量 153 合成），
  库原语 `surf_init/surf_inside/surf_alpha/surf_paint/surf_flush` + `ui_make_top`（⚠️ ULW 与 `SetLayeredWindowAttributes` 互斥）。
  实测证据：掩码 `corner=0/ring=70/inner=200`；视觉子代理独立读图测得圆角 ≈4~5px、行距 **19px**、Pad **≈8px**、
  面板色 **(142,142,144)** = 「ARGB(200,16,16,18)×60% 叠白底」理论值 → 半透明口径与 C# 一致。
- ~~**第 4 步：行构建器**（§4 全 8 行 + §3 格式化）~~ → **✅ 已完成（2026-09-16 00:0x，FLINT v1.4.2）**：
  行构建/配色/格式化全部下沉到 **`float_rows.fl`**（约 500 行）：8 行结构与行序逐条对齐 C# `BuildRows`(811-899)、
  每段独立颜色、`ShowXxx` 开关（位掩码 + `swtest`）、`rows.Count==0` 兜底行；格式化按 C# 914-941
  （°C F0 / xM·x.xG / F1 一位小数 / ≥1024→x.xM / F1 显存 / `EstimateSystemPower`=CPU+GPU+底噪45 / `ApplyCpuOffset`=-11）。
  **自证（无视觉模型环境）**：新增两条文件对账通道 —— `tmp\row-probe\dump.on`（建完第一帧把每行每段文字写进
  `rows-dump.txt` 后退出）与 `demo.on`（用样例数据跑全 8 行）。实测样例成绩单 8/8 行正确：
  `FPS|116|1%|1` ｜ `CPU|53°C|21%|3.1G` ｜ `GPU|41°C|34%|1.2/4.0G` ｜ `RAM|7.9/15.9G|49%` ｜
  `DISK|82%|89.0/108.0G` ｜ `NET|↓20K|↑5K` ｜ `FAN|1450| RPM` ｜ `功耗≈137W CPU74 GPU18`；
  真机 dump 4 行（CPU `-- 0%` / GPU `--` / RAM / DISK，开关 4094 = Disk 开、FPS 关）与 C# 逻辑一致；
  **全量回归 747/747**。途中教训见 PROGRESS.md 顶部状态记录（`CreateFileA` 返回 -1 不是 0；FLINT 语言边界 6 条）。
- ~~**第 5 步：数据源 = 8080 JSON**（HTTP + JSON 两个语言特性）~~ → **✅ 已完成（2026-09-16 01:0x）**：
  **没有新造轮子——用的是 C# 版自带的 8080 `/api/data` 接口**（用户口径：实在不行就把别人成品内置成库；它就在本机跑着）。
  新增 **`E:\FLINT-lab\lib\http_lib.fl`**：
  - `std::http_get(host, port, path, &hb)`：**ws2_32 原生 socket**（WSAStartup → socket → connect → send → recv → closesocket），
    HTTP/1.0 + `Connection: close`（读到对端关闭为止，不解析 Content-Length），剥 `\r\n\r\n` 头后把响应体搬到缓冲开头。
    只支持 IPv4 字面地址（不做 DNS，本地服务够用）。
  - JSON 取值层：`json_find` / `json_obj` / `json_obj_end` / `json_num`（**返回数值×1000** 的整数定点）
    ＋ `json_to_snap(b, n, &snap)` 一次把 20 个字段填进 `struct ApiSnap`（每字段带 `v_xxx` 有效位，`null` → v=0）。
  - **口径**：「先定位所属对象边界，再在段内查键」——`temp`/`load`/`power` 在 cpu/gpu/ram/disk 各出现一次，全局查会串台。
  - app 侧 `main.fl`：`http_pull` → `api_to_rows` → 行构建器；开关 **`tmp\row-probe\http.on`**（存在 = 走 8080；不存在 = 本地直读回退）。
  - **真机证据**：同一次运行的 dump 与 8080 JSON 逐值一致 ——
    `CPU|54°C|16%|3.1G|`｜`GPU|42°C|0%|--|`｜`RAM|7.8/15.9G|49%|`｜`DISK|37%|193.0/518.0G|`｜`NET|↓85K|↑7K|`｜`功耗≈130W CPU67 GPU18|`；
    探针 `tmp\http-probe\http1.fl`（HTTP 200 + 505B 体）、`j4.fl`（22 字段对账）、`j6.fl`（库版等价）留档。
  - **副产品：网速 / FPS 两项不必再走 UAC 与手算偏移**（网速 = JSON `net.downKBs/upKBs`；FPS = JSON `fps.current/onePercentLow`，
    此前 `GetIfTable2` 手算偏移试到上限 5+ 次）。
  - ⚠️ **写 FLINT 代码时的三条边界（本步全撞了一遍）**：`struct` 不能当全局变量；`struct` 字段不能是 `char *`
    （用 `int *` 装地址 + 按字节访问的辅助函数）；函数参数最多 4 个（复杂接口一律结构体 I/O）。
  - ⚠️ **取值顺序**：HTTP 取数必须夹在「本地直读」之后、「建行」之前——放建行之后会被下一轮本地直读整段盖掉
    （现象是"取数看着没生效"，容易误判成解析 bug）。
- **第 5 步之后**：`net.down/up` 已用 JSON 覆盖本地（此前本地恒 -1）。**待用户目视确认**：NET 行箭头（GBK `A1FD`/`A1FC`
  经 `TextOutA`）在窗口里的观感——探针 `glyph.fl` 实测有真实字宽（`A1FD 0K` 与 `?0K` 等宽 24px，非缺字框），
  但 ULW 分层窗抓屏不可靠（`CopyFromScreen` 只得全黑合成中间态），故交用户眼睛定案。
- **第 6 步（进行中 · 用户 2026-09-16 02:27 已拍板范围与四小步）**：交互 = 拖动（已有）/ 右键菜单（中文）/ 锁定 /
  尺寸自适应（已按 §2 两公式）/ 小窗模式 34×34 / **config.json 读写**（含用 `X/Y` 恢复位置——C# 当前 1640,289；`OpacityPercent`=60 已验证一致）。
  - ~~**6a config.json 读写 + 位置恢复**~~ → **✅ 已完成（2026-09-16 02:41）**：新增 `apps\m2_float\config.fl`
    （读 `std::file_read` + 自带最小 JSON 取值；写 = 全文重建**与 C# 同键名同顺序**的 JSON）。
    口径：路径 = 本产物目录一份（与 C# 各自一份、行为等价；**绝不写 C# 那份**）；
    落地 = X/Y 定位 / OpacityPercent→ULW 合成常量 / FontSize / Locked / MiniMode / ShowXxx→sw / CpuTempOffset；
    存盘时机照 C#（拖动结束 · 设置改动 · 退出；dump·demo 自检模式不写）。
    实测：dump 逐项对上（`sw=7679`、`font=13 op=80 ca=204 off=-20 file=1`）；配置 X=300 Y=220 → 窗口落点 **(300,220)**；
    发 WM_CLOSE 退出后 config 回写同一坐标。**为此补的编译器特性 v1.4.7**：`pe.c` 导入上限 64 → 96
    （接 `io_lib` 后该 app 导入声明正好 64 个 + 内置 ExitProcess = 65 撞上限）；回归 753/753 零退化。
  - ~~**6b 锁定 + 置顶钉回**~~ → **✅ 已完成（2026-09-16 02:41）**：`Locked=true` 不启动拖动（对齐 C# `:1021`）；
    每 ≥2s `SetWindowPos(hwnd, -1, 0,0,0,0, 0x13)`（对齐 C# `:1114-1118`）。
    实测（带对照组）：Locked=true 拖拽位移 **0,0** vs Locked=false 位移 **50,35**；两种情况 `WS_EX_TOPMOST` 均已置位。
  - ~~**6c 右键中文菜单**~~ → **✅ 已完成（2026-09-16 02:50）**：`menu.fl`（逻辑）+ `menu_gen.fl`（自动生成的 GBK 字节表/id，
    生成器 `tools\gen-menu.ps1` ← `menu_items.txt`）；结构照 C# BuildMenu，**超范围项不显示**；勾选态 = 当刻 config；
    另加 CS_DBLCLKS 双击锁定。实测：`MN_GETHMENU`+`GetMenuStringA` 从系统视角读回全部 33 项（中文正确）、
    勾选态逐项与 config 一致、顶级项与子菜单项命令都整链落盘。
  - ~~**6d 小窗模式 34×34**~~ → **✅ 已完成（2026-09-16 02:50）**：`WM_GETMINMAXINFO` 放开最小尺寸 + 34×34 +
    小窗绘制（ARGB(215,16,16,18) 填充 / ARGB(90,130,200,255) 描边 / 中心 CPU 占用% 12px）+ 单击恢复。
    实测：菜单切进 34×34（MiniMode=true）→ 单击恢复 187×111（MiniMode=false）。
  - **第 6 步（交互 + config）四小步 6a/6b/6c/6d 全部完成**；探针：`test\cfg-probe.ps1`（config/锁定）、
    `test\menu-probe.ps1`（菜单结构与命令 / 小窗）。回归 753/753。
- **每步验收**：全量回归**不退化**（当前基线 **747/747**；改 `src\` 必须先跑 `node test\run-tests.js`，改完 `src\` 要重建
  `gcc -O2 (Get-ChildItem src\*.c).FullName -o flint.exe` 再跑）+ 浮窗侧与 C# 版并排对照逐条勾 §1~§6。

### 范围（已拍板，2026-09-15 · 不再是"待点头"）
C# 版还有**趋势图 TrendForm / 极值 ExtremesForm / 截图 Screenshot / 开机自启**等外围窗口
（config 里对应 `ShowTrend/ShowExtremes/Shot*/AutoStart*`）。
用户已明确：**本轮只做 `MonitorForm` 主窗**，外围窗口不做；那几个 config 字段可以先读进来但不实现对应窗口。

