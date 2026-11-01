# FLINT Studio · IDE 功能清单与验收标准

> 📸 快照：2026-10-28 —— 本文件里的数字是**那一天**的值，不是现行值；现行数字见 `docs\数字台账.md`（取数器 `tools\文档事实.ps1`）。
> 基线：分支 `int4-abi` / `ffbf277`（2026-10-26）。所有「现状」都来自代码实读，
> 主要依据 `apps\studio_native\studio_win.fl`（下称 `sw`）与 `lib\flgui_win32.fl`（下称 `flgui`）。
> 目标：给后续开发一张可执行的需求底账 —— **功能 → 现状 → 缺口 → 验收判据**，
> 能自动化的判据一律写成探针或命令，不靠"看着差不多"。

## 0. 怎么用这份清单 / 怎么验收

```powershell
# 前置：先编译（exe 不入库）
cd <repo>; .\hlc.exe apps\studio_native\studio_win.fl

# 已入库探针（都在 tmp\ 下，可反复跑）
pwsh -NoProfile -File tmp\probe-ide-render.ps1   # 渲染 / 高亮 / 行号 / 状态栏 / 重画 / idle
pwsh -NoProfile -File tmp\probe-ide-scroll.ps1   # 滚动条像素 + 滚轮 + PageDown
pwsh -NoProfile -File tmp\probe-ide-find.ps1     # Ctrl+F；没实现时明确 SKIP
pwsh -NoProfile -File tmp\probe-ide-diag.ps1     # 编译诊断：错误行配色 + 点行跳转到源码行列
pwsh -NoProfile -File tmp\probe-ide-settings.ps1 # 设置页：开关卡 / 选中行 / ←→ 改字体字号并落盘 / 不开面板时不许改正文
pwsh -NoProfile -File tmp\probe-ide-tree.ps1     # 文件树：展开/打开/滚轮 + 切文件自动存盘（改动不丢）
pwsh -NoProfile -File tmp\probe-ide-ws.ps1       # 工作区：cfg ws= 生效 / 文件夹图标弹选择框 / 设置页值列不被裁
pwsh -NoProfile -File tmp\probe-ide-wrap-hl.ps1  # 折行后注释仍是注释色（第二显示行绿字占比）
pwsh -NoProfile -File tmp\probe-ide-menu.ps1     # 顶栏菜单 / Ctrl+N 新建 / 未命名另存 / 内置终端 / 运行 / 外部 CMD
pwsh -NoProfile -File tmp\probe-ide-edit2.ps1    # 自动缩进 / 括号引号配对 / 跨过收尾符
pwsh -NoProfile -File tmp\probe-ide-cfg.ps1      # config v2：退出写 cfg / 窗口几何 / 上次文件 / 光标与滚轮位置恢复 / F11-Esc 往返
pwsh -NoProfile -File tmp\probe-ide-dlgdir.ps1   # 三个资源管理器对话框共用一条 dlgdir（上次位置）
pwsh -NoProfile -File tmp\probe-ide-term.ps1     # 内置终端 = 持久 shell（cd 保持 / 输出流式 / ↑↓ 历史）
pwsh -NoProfile -File tmp\probe-ide-repeat.ps1   # 按住方向键连续移动（轻点 = 一格）
pwsh -NoProfile -File tmp\probe-ide-ime.ps1      # 输入法合成中退格：正文里那个字母一起撤
pwsh -NoProfile -File tmp\probe-ide-cjksize.ps1  # 中文字号轮两圈 + 48 次换字体字号：正文不许消失（字体格式表不泄漏）
# 一把梭（顺序跑，记日志）：21 个探针
pwsh -NoProfile -File tmp\run-ide-probes.ps1
```

探针约定（三个脚本一致）：

| 约定 | 说明 |
|---|---|
| 截图 | `PrintWindow(hwnd, dc, 2)` 进 32bpp DIB，**不依赖桌面绝对坐标** |
| 输入 | 客户区坐标 → `ClientToScreen`；按键走 `SendInput`，焦点被抢会重试 |
| 进程 | 只杀 `$Root\` 下的 `studio_win` / `studio_server`，不误杀同机其它 worktree 的实例 |
| 退出码 | `0` = PASS，`1` = FAIL，`2` = SKIP（功能未实现 / 环境争用） |
| 争用 | 同机可能有两个代理同时跑 app：窗口会停到屏幕右侧（避开默认 120,90 的点击区），失焦/超时输出 `SKIP(env-contention)` 而不是 FAIL |
| 输出 | 每个探针最后一行统一 `RESULT ...`，前面每项一行数字 |

**当前基线（2026-10-26 20:4x 实跑，exe 284,160 B）**：`probe-ide-render`／`probe-ide-scroll`／
`probe-ide-find`／`probe-ide-wrap`／`probe-ide-sel`／`probe-ide-resize`／`probe-ide-diag` = **全 PASS**
（scroll 的 `slider_rows=16`、`wheel_shift=153`、`find` 的 `cur=101/115`、`sel_bg=8738` 都在下面 §0.5/§0.6 记了）。

---

## 0.5 本轮已落地（2026-10-26 01:30，主树实跑数字）

清单写在前面，是**这一版与上面表格的差异**；下表的"现状"列按**写表那一刻的代码**，别当现值读。

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 软换行（视觉折行） | 源码行 → 显示行表（`g_vb/g_ve/g_lrow`，上限 4096 格）；`Alt+Z` 开关，`studio.cfg` 的 `wrap=` 持久化 | 209 字节长行折成 3 格、行号只标第一格；中文注释折行正常；`nlines=987 → nrows=1005`；短行不量宽（每字节下界 `(px+4)/3`） |
| 鼠标滚轮 | `in.wheel`（单位 = **格**，泵层已除 120）× 3 行/格；`Ctrl+滚轮` = 字号缩放 | `shift_px=153` = 9 行 × 17px（3 格） |
| 选区 | 拖选 / `Shift+方向键` / `Shift+点` / `Ctrl+A`；选区底色 `#264F78`（VS Code `editor.selectionBackground`） | 拖选后 `selon=1`，选区底色 8693 px；`Ctrl+A` 后 `cur == srclen` |
| 复制 / 剪切 / 粘贴 | 走 **Windows 剪贴板**（`studio_text.dll` 的 `tx_clip_put/get`），跨程序可用 | 复制出去 `Get-Clipboard` = 33516 字符；从外部粘贴 25 字符 → `srclen` +25 字节整 |
| 撤销 / 重做 | 整缓冲快照 24 槽 × 256KB（`VirtualAlloc`），400ms 内连续编辑合并成一步；`Ctrl+Z` / `Ctrl+Y` / `Ctrl+Shift+Z` | 粘贴后 36699 → 撤销回 36674（逐字节等于原文件长度） |
| Ctrl+F 查找 | 顶部 26px 查找条；大小写不敏感 ASCII 子串；命中即选中并滚进可视区；`F3` 下一个；`Esc` 关闭 | `Enter` 后 `cur=26`、`selon=1`，状态栏 `find: 235 hits`；关闭后查找条底色 19813 → 138 px |
| 打开文件（资源管理器对话框） | `Ctrl+O` → `GetOpenFileNameW`（垫片 `tx_dlg_open`），选中即载入 | 对话框窗口类 `#32770` 出现 → WM_CLOSE 关闭 → 进程存活；"打开已取消"状态 |
| 另存为 | `Ctrl+Shift+S` → `GetSaveFileNameW`（`tx_dlg_save`），之后保存写新路径 | 与打开同一代码路径（探针 `probe-shim` 覆盖对话框本身） |
| 边框缩放窗口 | 四边 5px 内按下拖动（自绘，`set_winmode` 之外新增），最小 620×420；边框区光标换 `IDC_SIZEWE/SIZENS/NWSE/NESW`（垫片 `tx_edge_hook` 子类化 WM_SETCURSOR） | 1000→**1120** 宽（拖右边缘 +120）；新露出的编辑区 32233 个 `#1E1E1E` 像素（真重画）；再往左拖被夹到 **620**；边缘光标句柄 = `LoadCursor(0,32644)` |
| 品牌字距 | 标题栏 / 状态栏的 "FLINT" 逐字加 2px 字距 | I→N 字形间隙 1 → **2** px（其余字母间隙 3） |
| 顺带 | `Delete` 删后一码点、`Tab` 插两空格、`Home/End`（Ctrl = 文件首尾）、光标自动滚进可视区、撤销历史与剪贴板引入 | 见 `PROGRESS.md` 交接块 |

新探针（本轮入库）：`probe-ide-wrap` / `probe-ide-sel` / `probe-ide-find`（升级版）/ `probe-ide-resize` /
`probe-shim`，以及一次性取证脚本 `tmp\probe-stage2.ps1`（剪贴板+对话框）、`tmp\probe-resize.ps1`、
`tmp\probe-latency.ps1`（按键→重画延迟 A/B）、`tmp\probe-logo.ps1`（字距）。

---

## 0.6 本轮已落地（2026-10-26 20:4x，主树实跑 —— **编译诊断闭环**，exe 279,552 → 284,160 B）

| 功能 | 落地形态（代码位置） | 实测判据 |
|---|---|---|
| 诊断解析 | 新增 `b3is` / `diag_at`：认 `hlc 编译错误（路径 第 N 行第 M 列）` 这一种中文格式（按 UTF-8 字节模式匹配，不用正则）；`diag_jump` 把 1-based 行列换成字节偏移（按**码点**走，汉字不偏） | 沙箱源第 5 行第 16 列 → 点击后 `ai.state` = `line=4 col=15`（0-based，与日志逐位 −1） |
| 错误行配色 | 诊断行与标题提示用 `#F48771`（VS Code `editorError.foreground`；COLORREF `0x007187F4`） | `title_red=117 px` / `row0_red=589 px` / **其余行 `0 px`**（不会整片红） |
| 面板标题计数 | 标题后跟 `N 条诊断 · 点行跳转`；`do_compile` 数完写 `g_nerr`，状态栏同时显示 `compile FAILED · N err` | 计数串与标题同色同区，随 `g_nerr` 进脏签名（`+ g_nerr*71`） |
| 点击跳转 | 面板正文命中区 `y = edb+26`、行高 16；点中诊断行 → 光标落点 + 布局块自动把它滚进可视区；点说明行/源码回显行**不动**（与 VS Code 一致） | 点诊断行 → `line=4 col=15`；点回显行 → `line` 保持 4（探针 `NOCLICK` 项） |
| 边界（v1，已写进交接块） | 只跳**当前缓冲**：编译写的是 `apps\studio_native\_studio_edit.fl`（内容 = 缓冲），诊断指到别的文件时只把状态栏改成 `diag: other file`，**不换缓冲**；不认 `file:line:col` 英文格式 ⇒ 认不出就不高亮 | 探针 SKIP 分支写明"日志里没诊断就 SKIP"的前提 |
| 为什么没做面板滚动 | 168px 面板一次放 8 行，而单次编译日志实测 ≤6 行（`hlc` 首个错就停）⇒ 这一刀加滚动等于无输入可测；留给"多诊断/批量编译"那轮 | `log_lines=5`（`probe-ide-diag` 打印） |

探针 `tmp\probe-ide-diag.ps1`：期望值从沙箱里**真实写出的** `tmp\studio_win_edit.log` 用
`第 (\d+) 行第 (\d+) 列`（char 码拼出来，脚本保持纯 ASCII）抠，不写死数字；判据 = `RESULT diag=PASS`。

---

## 0.7 本轮已落地（2026-10-26 21:2x —— **设置页：字体/字号/换行搬进来**，exe 284,160 → 292,352 B）

| 功能 | 落地形态（代码位置） | 实测判据 |
|---|---|---|
| 入口 | 标题栏新增**滑杆图标**按钮（`W-136..W-102`，`glyph_sliders`）；**F9 改成打开设置页**（原来盲轮 6 档、看不到当前值） | `probe-ide-settings` 的 `OPEN` / `F9KEY`：卡片底色像素 `>20000` 才算开 |
| 卡片 | 520×366 居中卡片（`#303236` 底 ＋ `#3C3C3C` 头 ＋ 1px 描边），五行设置项；选中行 `#2A2D2E` ＋ 左侧 2px 蓝条 | `card_px=140599`、`header=#3C3C3C`、`row0_selected_px=21408` |
| 五行设置项 | 代码字体 / 字号（10~26）/ 中文字体 / 中文号（自动 → 12…24）/ 自动换行；←→ 调值、↑↓ 选行、Enter 切开关、Esc 或 × 关 | 字体 `font (none) → Noto Sans SC Bold` 落盘；字号 `size 14 → 15` |
| 落盘 | 每次改动 `set_font` ＋ `save_cfg`（`studio.cfg` 的 `font/size/weight/cjk/cjksize/wrap` 一套键，与老 F9 路径同源） | 探针直接读沙箱 `studio.cfg` 的 `font=` / `size=`，**不认 UI 文案** |
| 模态保证 | 面板开着时**整段键盘处理被跳过**（编辑区 20 多条按键路径一次性隔离），IME 待上屏字母直接丢弃 | 面板里按 `Z` ⇒ `ai.state` `srclen 27 → 27`（正文一字未动） |
| 边界（v1） | 面板里没有主题/缩进/编码项（这些能力还没实现）；卡片尺寸写死 520×366，窗口小于约 560×420 会贴边；无滚动（五行刚好放得下） | 见 `set_adjust` 与交接块 |

图标设计稿（同一轮"先拿 skill 试试画图案"的产物）：

- `apps\studio_native\design\icons-candidates.png` — 4 版 logo ＋ 3 版设置图标的对比表（每版给 16/24/32/64 四档）
- `apps\studio_native\design\flc-mark-64.png` ／ `-256.png` — 选中的 **FLC 标记**：四角星火花 ＋ 扁平刃口钢条（"火镰击石"）；16px 下仍读得出"星 + 短杠"
- `apps\studio_native\design\settings-gear-64.png` — 齿轮候选（实心 ＋ 橙色中心）；**实际进 UI 的是滑杆**（同尺寸下更好认，见 `glyph_sliders`）
- `apps\studio_native\design\hero.png` — 1280×420 启动横幅（PIL 排版 ＋ ffmpeg `vignette=PI/6,noise=alls=5:allf=u`，即 `video-effects` skill 的配方）
- 程序内画法：`glyph_spark`（竖菱形 ＋ 横菱形）与 `glyph_sliders`（三条轨道 ＋ 三个旋钮）都是**纯 `fill_rect`**，不引新 API、不带位图资源（FLINT 侧没有图片解码）。

---


## 0.8 本轮已落地（2026-10-26 22:2x —— **"能用版"**，exe 292,352 → 376,320 B）

| 功能 | 落地形态（代码位置） | 实测判据 |
|---|---|---|
| 文件树 | `tree_scan` 递归（只列目录 ＋ `.fl`，跳过 `tmp`/`.git`/`_studio_edit.fl`；400 行/64 展开/4 层）；目录点一下展开折叠（`g_dopen` 记住状态），文件点一下打开；侧栏滚轮滚动；当前文件高亮并自动 reveal | `probe-ide-tree`：点 `alpha.fl` → `srclen=43`；点 `beta.fl` → `srclen=65`；滚轮后侧栏指纹变化 |
| 防丢改动 | `g_dirty`（`undo_push` 置位、`do_save` 清零）；**切文件/点 × 先存盘**；标题栏圆点提示 | 改一字后点另一个文件 ⇒ 原文件磁盘 +1 字节 |
| 界面字号可配 | `studio.cfg` 的 `ui=`（12..22，默认 16）＋ 设置页第 6 行；`set_ui()` 唯一入口 | 设置页 ←→ 改 `ui=`，标题栏/侧栏/状态栏同步变大 |
| 输出面板滚动 | `g_oscroll`；鼠标在面板上滚轮滚日志，新编译归零 | 长日志可滚到末尾（后面做批量编译时才有 8 行以上的日志） |
| 统一打开路径 | `tree_open()` = 展开父目录 ＋ `open_file` ＋ `tree_build` ＋ `tree_reveal`；侧栏 / `Ctrl+O` / `Ctrl+1..9` 同源 | 三条入口打开深层文件后，树里都会定位到它 |
| 边界 | 树只列 `.fl`；无 Ctrl+R 刷新；**无标签页**（切走即存盘）；单文件 250 KB；树基于 CWD | 见交接块 |

---
## 0.9 本轮已落地（2026-10-26 23:0x —— **工作区（打开文件夹）＋ 折行注释高亮 ＋ 设置页裁剪**，exe 376,320 → 379,392 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 工作区（打开文件夹） | `g_ws` ＋ `studio.cfg` 的 `ws=`（空 = 跟随 CWD）；`tree_scan` 根 = `g_ws`，条目路径带前缀（`tree_mkfull`）⇒ 点开即可读盘；入口 = **侧栏头文件夹图标**（`glyph_folder`，28px 高整条热区）或 `Ctrl+Shift+O`；shim 新增 `tx_dlg_folder`（`SHBrowseForFolderW`，DLL 63,912 → 65,754 B） | `probe-ide-ws`：`ws=` 指向 `sub` 时 row0→43B、row1→65B；点图标弹出 `#32770` 选择框 |
| 折行注释高亮 | 新增 `hl_state_at(line, b0)`：从源码行首扫到显示行起点，判"在 `//` / `"` / `'` 里"，续行带 `carry` 状态继续上色 | `probe-ide-wrap-hl`：165B 长注释折行后，第二显示行绿字 1670px = 该行墨迹 2274px 的 73%（修前≈0） |
| 设置页值列裁剪 | 值列 `draw_clip` 上沿 ry-6、下沿 ry+36（原 ry..ry+22 把 16px 字的下半截切掉） | `probe-ide-ws` 的 `CLIP` 项：拉丁值墨高 8px、中文标签 11px，下沿各留 ≥4px 空气 |
| 边界 | 树只列 `.fl`；换工作区清空展开状态、不自动重开当前文件；`ws=` 是绝对路径；折行状态不认 `/* */` | 见交接块 |

---
## 0.10 本轮已落地（2026-10-26 23:3x —— **顶栏菜单 ＋ 新建文件 ＋ 内置终端 / 外部 CMD**，exe 379,392 → 394,752 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 顶栏菜单条 | 标题栏下面 26px：文件 / 编辑 / 运行 / 视图；点标题开下拉、再点关闭、点别处关闭；hover 行高亮；每项右侧标快捷键（`menu_title/count/label/keys/act`） | `probe-ide-menu`：`dropdown_px=35381`（>3000 才算真的画出来） |
| 动作统一 | 菜单点击与快捷键**都只设 `act` 码**，main 一处执行（1 新建 … 22 清空输出） | 同一条路径 ⇒ 菜单与快捷键不会行为不一致 |
| 新建文件 | `Ctrl+N` → `untitled.fl` 空缓冲 ＋ 未保存点；`Ctrl+S` 先弹**另存为**（不再往 `untitled.fl` 写假文件） | `srclen=0 / nlines=1`；`Ctrl+S` 弹出 `#32770` |
| 快捷键 | `Ctrl+N/O/Shift+O/S/Shift+S/Z/Y/F/A`、`Ctrl+Enter` 编译、`Ctrl+`` ` `` 终端、`Alt+Z` 换行、`F9` 设置 | 探针逐项覆盖（菜单探针 + 既有探针） |
| 内置终端 | `Ctrl+`` ` `` 开底部 200px 面板；命令 → `cmd /c ... > tmp\studio_term.log 2>&1`，输出追加；`Esc` 回编辑区。**不是真 TTY**（`cd` 不跨命令、无交互程序） | 面板 `133347 px`；`echo hi` 后终端墨迹 686→814，而**正文 srclen 仍 0** |
| 外部 CMD | 菜单 运行 → 外部 CMD 窗口 ⇒ `cmd.exe /k cd /d <工作区>` | 探针看到新的 `cmd` 进程（并杀掉了） |
| 运行（编译并执行） | 菜单 运行 第一项 / `F5` / 标题栏 **▶ 按钮**：当前缓冲 → `tmp\studio_run.exe` → `cmd /k` 开窗口跑；编译失败灌输出面板 + `run FAILED` | `probe-ide-menu`：`F5 -> new cmd pids=[2624]`（真实起了窗口） |
| 边界 | 终端只有一次性的 `cmd /c`；菜单无键盘导航（`Alt+F` 未做）；终端与输出面板只显示一个 | 见交接块 |

---
## 0.11 本轮已落地（2026-10-27 01:1x —— **两种运行途径 ＋ 自动缩进/括号配对/括号匹配**，exe 397,312 → 401,408 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 运行（两条途径） | `do_run(mode)`：mode 0 = `cmd /k tmp\studio_run.exe`（`F5` / 标题栏 ▶）；mode 1 = **内置终端面板里跑**（`Shift+F5` / 菜单第二项） | `probe-ide-menu`：`F5 -> new cmd pids=[…]`；终端途径输出落在面板 |
| 自动缩进 | 回车沿用当前行前导空白；光标正对 `}` 时减一档（2 空格） | `probe-ide-edit2`：回车 +3 字节（LF+2 空格）；`}` 前回车 +1 |
| 括号/引号配对 | `(` `[` `{` `"` `'` 成对插入、光标居中；光标右边是同一收尾符时跨过去 | 同探针：`[` 配对 +2、光标居中；再按 `]` srclen 不变、光标 +1 |
| 括号匹配高亮 | `br_match()` 数嵌套，两端各画 2px `#D7BA7D` 下划线（COLORREF `0x007DBAD7`） | Ctrl+End 贴 `}` 时屏幕 `#D7BA7D` 像素 30 px（两处端点） |
| 语言事实 | `print` 收**段列表**：`print(["Hello", "\nWorld!"]);`（用户写 `print(("Hello","\nWorld!"));` 会报未声明变量 `print`） | `hlc` 实测报错/通过各一次 |
| 边界 | 配对准入不判上下文（字符串里打引号也会配）；`/* */` 不参与；缩进单位固定 2 空格 | 见交接块 |

---
## 0.12 本轮已落地（2026-10-27 02:0x —— **config v2：设置 ＋ 会话状态（滚轮位置 / 窗口几何 / 上次文件）**，exe 401,408 → 416,256 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| cfg v2 结构 | `studio.cfg` 一个纯文本 key=value：**设置段** `font/size/weight/cjk/cjksize/wrap/ui/ws` ＋ **状态段** `winx/winy/winw/winh/winmax/tree/file` ＋ 每文件视图 `vf=<路径>\|<光标字节>\|<首行源码行号>`（最多 12 条）；认不出的键一律忽略（新旧版本互读都不炸） | 沙箱 `tmp\ide-cfg` 逐键读回；`cfg_line` 现在也认前导 `-`（副屏/贴边时窗口坐标可为负） |
| 落盘时机 | **只在正常退出**（标题栏 × / 菜单 退出 / WM_QUIT）＋ 改设置 / 换工作区时写；`save_cfg` 内部先 `session_capture()`，再用 `GetWindowRect` 实测几何（不靠"拖动时维护坐标"） | `probe-ide-cfg`：× 关闭后 cfg 出现，`winx/winy/winw/winh` 与关闭前 `GetWindowRect` 逐值相等；强杀（探针 `Stop-Process`）不写 ⇒ 沙箱不被上一轮残留污染 |
| 启动恢复 | 窗口几何（越界夹回屏内）、`winmax=1` → 窗口全屏档、上次文件（文件没了就退回 `apps/studio_native/main.fl`）、该文件的光标＋首行、文件树滚动（若会把当前文件顶出可视区则让位给 reveal） | 手写 cfg `900x600@200,150` → 窗口逐值还原；`file=restore.fl` ＋ `vf=restore.fl\|640\|40` → `srclen=1920`、`ST cur=640 line=40`、`SC top=40` |
| 每文件视图 | `open_file` 先 `session_capture()` 记旧文件、再 `view_apply()` 恢复新文件；首行**按源码行号**记，显示行由 main 在 `wrap_build` 之后换算（窗口宽度/wrap 改了也不会落错地方） | 同沙箱连开两个文件后 cfg 里两条 `vf=` 并存；`PERSISTVF` 检查旧条目没被覆盖 |
| 窗口模式修正 | `set_winmode(0)` 不再写死 `1000×700@120,90`：离开普通档前实测矩形存 `g_win*`，`Esc` / □ 回到用户自己的框 | `probe-ide-cfg`：880×620@160,120 → F11（1920×1040）→ Esc 回 **880×620**（改前会弹回 1000×700） |
| 探针通道 | `ai.state` 新增一行 `SC <首行源码行号> <首显示行> <待恢复行>`（只在变化时追加；`ST` 的 7 字段契约不动） | 滚动/恢复直接对数字，不用像素相关系数反推 |
| 边界 | 无 UI 版"最近文件"列表（cfg 里只记 12 条视图）；无多标签；`untitled.fl` 不记；真全屏(fs=2)退出不记几何（下次回到普通档最后矩形）；`studio.cfg` 已进 `.gitignore`（本机用户数据） | 见 `PROGRESS.md` 交接块 |

---
## 0.13 本轮已落地（2026-10-27 02:2x —— **三个资源管理器对话框各自记住上次位置**，exe 416,256 → 418,304 B；`studio_text.dll` 65,754 → 67,229 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 垫片 v1.2（起始目录） | `studio_text.c` 新增 `tx_dlg_open2 / tx_dlg_save2 / tx_dlg_folder2`（末位参数 = 起始文件夹，UTF-8）；旧导出 `tx_dlg_open/save/folder` **原样保留**（转调新实现、传 NULL = 老行为）⇒ 已编好的 exe / 探针不受影响。打开/另存为走 `lpstrInitialDir`；文件夹选择框走 `BFFM_INITIALIZED` + `BFFM_SETSELECTION` 回调 | 旧导出 `GetProcAddress` 仍非零（`probe-shim` PASS）；4 个新导出全非零 |
| cfg 三个独立键 | `dopen=` / `dsave=` / `dfolder=` —— 打开文件 / 另存为 / 打开文件夹**各记各的**，互不覆盖 | `probe-ide-dlgdir`：另存为之后 `dopen` 仍是 `dirA`；选完文件夹之后 `dopen` 仍是 `dirA` |
| 打开文件 | `Ctrl+O` 起点 = 上次"打开"用过的目录；选完把新目录写回 `dopen` | 种子 `dopen=dirA`，对话框里只打**裸名** `target.fl` + 确定 → 载入 `dirA\target.fl`（`srclen=30`） |
| 另存为 | `Ctrl+Shift+S` 起点 = 上次另存为的目录；**默认文件名改成基名**（旧版传整条路径，垫片为防注入把 `/` `:` 换成 `_` ⇒ 对话框里出现 `apps_studio_native_main.fl` 这种怪名字） | 种子 `dsave=dirB`，默认名 + 确定 → 落盘 `dirB\target.fl`（名字里没有路径 ⇒ 只能解析到对话框起点） |
| 打开文件夹 | `Ctrl+Shift+O` 起点 = 上次选工作区的位置；选择框里**预选**这个目录 | 种子 `dfolder=dirC`，直接确定 → `ws=dirC`（改前起点是系统默认，确定会落到别的目录） |
| 首次使用回退 | cfg 还没有这些键时：打开 / 另存为回退到"当前文件所在目录"，文件夹选择回退到当前工作区 | 新沙箱（无 cfg）里三个对话框照常弹出（`probe-ide-menu` / `probe-ide-ws` 全绿） |
| 落盘时机 | 三个对话框**选完立刻** `save_cfg_now()`（不等退出）；`set_font` 同步 `g_curface / g_fontpx`，让对话框函数不用拿 main 的局部量 | 探针在对话框关闭后 5 s 内读到 cfg 的新 `dopen / dsave / dfolder` |
| 边界 | 目录按用户选的**原样字符串**存，不规范化（`..` / 尾部斜杠不折叠）；目录被删/移走时对话框退回系统默认；`untitled.fl` 的另存为默认名就是 `untitled.fl` | 见 `PROGRESS.md` 交接块 |

---
## 0.14 本轮已落地（2026-10-27 10:3x —— **内置终端改持久 shell ＋ 方向键连发 ＋ IME 退格 ＋ 启动首帧**，exe 418,304 → 421,888 B；`studio_text.dll` 67,229 → 71,338 B）

| 功能 | 落地形态 | 实测判据 |
|---|---|---|
| 内置终端（持久 shell） | 垫片 v1.3 新增 `tx_sh_start/write/read/alive/stop`：**一个 cmd.exe 一直活着**（两组管道 + `PeekNamedPipe` 非阻塞读，启动 `chcp 65001` 让输出是 UTF-8）。命令回显自己写进缓冲区；`cd` / 环境变量 / 内建命令都保持；`exit` 后自动失效、下次输入重开 | `probe-ide-term`：`cd sub` 之后 `md marker` **真的在 `sub\` 下建出目录**（cwd 保持了）；TS 通道显示输出字节数随命令增长；↑+Enter 复跑上一条 |
| 终端细节 | ↑↓ 历史（12 条环形）、`cls`/`clear` 本地清屏、ANSI/VT 序列剥掉、CRLF→LF、缓冲满了砍前一半（不是清空） | 同探针；面板标题改「持久 cmd（cd 保持）· ↑↓ 历史」 |
| 方向键连发 | 新增 `rep()`：按下沿立刻动一格，按住 **250ms 后每 45ms 一格**；方向键 / PageUp / PageDown / Delete 改走它（`edge()` 只认边沿 ⇒ 按住只走一格，这是"连续方向键没反应"的根因） | `probe-ide-repeat`：轻点 = 1 格；按住 700ms ≥ 5 格；松手立刻停 |
| IME 退格 | `flgui_win32.fl` 的 auto 档：合成中按退格（`VK_PROCESSKEY` + 扫描码 8）时，**把已经插进正文的那个字母一起撤回**（台账减一 + 记 rbuf，app 侧还是逐字节核对后才删） | `probe-ide-ime`：2 个 IME 字母 → +2；退格 → **−1**（改前纹丝不动）；之后再打字照常 +1 |
| 启动首帧 | 启动编译从"进循环前同步跑"挪到**第一帧上屏之后**（`firstdone`）⇒ 窗口先出画面，再跑 `hlc` | 时序：不再先出现"只有行号没有文本"的空白窗口（用户报的"刚进入时文本栏不刷新"） |
| 对话框位置合并 | 三个对话框**共用 `dlgdir=` 一条**（用户拍板"放一起，能分清就行"）；老的 `dopen/dsave/dfolder` 只做迁移读取 | `probe-ide-dlgdir`：打开 → `dlgdir=dirA`；另存为**从 dirA 起步**（证明跟的是同一条）；选文件夹 → `dlgdir=dirC` |
| 探针通道 | `ai.state` 再加一行 `TS <shell 在跑> <终端字节数> <命令行长度>`（只在变化时写） | `probe-ide-term` 直接读数字判断"输出有没有流" |
| 边界 | 不是真 TTY：无光标寻址/颜色、Ctrl+C 不打断（要停就 `exit`）、交互式程序体验有限；终端面板仍与输出面板互斥 | 见 `PROGRESS.md` 交接块 |

---

## 0.18 本轮已落地（2026-10-28 15:5x —— **Ctrl+H 替换**（查找条两行版），exe 428,032 → 431,616 B）

| 项 | 落地形态 | 判据 |
|---|---|---|
| 入口 | `Ctrl+H` 打开替换条（在 Ctrl+F 那条上多一行"替换:"）；`Ctrl+F` 仍是单行查找。有选区时照样预填查找串 | `probe-ide-replace`：条高 52（单行是 26）、首行正文下移 **+52**（单行 +26） |
| 键盘 | `Tab` 在"查找框 / 替换框"之间切焦点（光标跟着走）；`Enter` = 查找下一个（焦点在替换框时 = **替换这一个**）；`Ctrl+Enter` = **全部替换**；`Esc` 关。Enter 仍走物理 `edge(0x0D)`（IME 合成中是"上屏"，两条路只能这么统一） | 探针用 Ctrl+S 后**读盘数 token**：`int` 4→3、`float` 0→1（替换一个）；再 `int`→0、`float`→4（全部替换） |
| 实现 | 新增 `g_rep[64]/g_replen/g_findrep/g_repf/g_fmax`；`find_open_rep()`（复用 `find_open` 再切替换模式）；`replace_one()` / `replace_all()`（各 `undo_push` 一次，`del_range`+`ins_byte`；插入串不参与再匹配）；`findbar_h()` 把正文 `top` 下移 0/26/52；`paint_findbar` 两行、颜色只切两次 | 像素+文件双判据，见探针 |
| 探针 | 新增 `tools\probes\probe-ide-replace.ps1`（7 个检查点：两行条 / +52 / 替换行输入 / 替换一个 / 全部替换 / Esc 还原），已加进 `run-ide-probes.ps1`；`-Touched input` 的 Quick 门从 6 个探针变 7 个 | `SUITE pass=7 fail=0` |
| 门 | Quick(input) **GREEN**；G4 静态：`magic 60` **10→8**（用 `g_fmax` 收口）⇒ 基线自动收紧；`fileLines` 硬上限 5200 → **5250**（本功能 +131 行，只抬到刚好够，下一刀拆输入侧时回落） | `gate.ps1 -Quick -Touched input` |

**踩到的两个坑（都实发过）**：

1. **`find_open_rep()` 里"先设 `g_findrep=1` 再调 `find_open()`"是错的** —— `find_open()` 会把 `g_findrep/g_repf` 清零（它是 Ctrl+F 的公共入口）⇒ 现象是"Ctrl+H 只出一行、Enter 变成下一个、替换一个都没发生"，而条的颜色/几何全都对，肉眼很难看出。正解：先 `find_open()`，再切替换模式。
2. **判据区要避开第二行的提示文字**：替换行的提示（"Enter 替换 · Ctrl+Enter 全部 · …"）从 x=420 起、能伸到 x 700..860 的 y 67..105 区间，探针按"x700..860 首个墨点"找正文首行时会把它当成正文 ⇒ 假 FAIL（`row1_y=-1`）。探针改为从 y=110 起扫，并注释写明原因。

**边界**：替换串最长 60 字节（`g_fmax`，数组 64）；全部替换一次 `undo_push`（一次撤销回滚全部，与 VS Code 的"一个事务"一致）；面板上的按钮还没做（纯键盘）。

---

## 0.17 本轮已落地（2026-10-27 20:0x —— **"字不清晰"：抗锯齿改 ClearType ＋ 字号按墨高重标定**，exe 422,400 B 不变；`studio_text.dll` 73,290 → 73,390 B）

用户第三次报"字不清晰"。这次先量后改，**中间还试错了一版并回退**，两件事都写下来：

| 项 | 之前 | 现在 | 依据 |
|---|---|---|---|
| 抗锯齿 | 全是**灰度 AA**（当年为躲深底彩边定的） | 默认 **ClearType**（`studio_text.c` v1.5：`tx_aa(1)`，D2D 目标改 `ALPHA_MODE_IGNORE`）；**cfg 新增 `aa=0/1`**，嫌彩边的改 0 回灰度。GDI 与 D2D 两套引擎都跟这个开关 | 灰度在 cell 15 上边缘 3~4px 过渡；ClearType 主干有 1px 硬芯（`tmp\gdi-ct-tree.png` vs `tmp\d2d2-tree.png`） |
| 字号标定 | 按"单元格高度"瞎给（GDI `CreateFontA` 正高度 = 字符单元高，不是 em） | 先量墨高：Consolas cell 15 的 'H' 只有 **6×8px**、cell 19 才 8×10；YaHei cell 16 汉字只有 **10px** 宽、cell 19 才 13.5。⇒ `ui=19`（汉字 13.5 / 墨高 10，对齐正文）、行号 `px-3`→`px`（墨高 6→8）、状态栏 16、终端行距 15→17 | `tmp\font-ink-probe.ps1`（各字号真实墨迹）、`tmp\look-boxes.ps1`（墨迹盒对齐到 ±1px） |
| **试过又回退**：界面文字整体挪 D2D | — | 写了 `ui_pass`（所有 GDI 填充之后开一趟 `tx_begin/tx_end` 统一画界面文字）。**视觉差别不大，但 repaint CPU 从 20ms/帧 涨到 58ms/帧**（`tmp\perf-frame.ps1`：60 次重画的进程 CPU）⇒ **已回退**，界面文字继续用 GDI+ClearType。代码留在 `d3be9d8` 里，将来真要合并两套引擎可以捡回来（先解决性能） | 见下表 |

**性能实测（同一脚本、同一 200 行样本、1000×700，60 次方向键重画）**：

| 版本 | 每次重画 CPU | 备注 |
|---|---|---|
| GDI 界面 + 灰度 AA（上一版） | 24.5 ms | 基线 |
| **GDI 界面 + ClearType（本版）** | **20.1 ms** | 更锐且不更贵 |
| D2D `ui_pass` + ClearType（已回退） | **58.3 ms** | 2.9 倍，不可接受 |

**踩到/修掉的坑**：
- D2D 的 DC render target **alphaMode 不可改** ⇒ 切 `aa` 必须释放 `g_dcrt` 重建（`tx_aa` 里就这么做）。
- 探针判据要跟着换：行号判据从"精确 #858585"改成**墨迹亮度计数**（ClearType 彩边把颜色摊开，精确命中 178→85 会假 FAIL）；状态栏深底阈值 20000→15000（字变大占了面积）。

**门**：21 个探针全绿（`tmp\probe-suite-20261027-200218.log`）。

**边界**：ClearType 在 6× 放大下能看到橙/蓝彩边（1× 是 Windows 全系统的默认观感）；不接受就把 `studio.cfg` 的 `aa=1` 改成 `aa=0`。

---

## 0.16 本轮已落地（2026-10-27 17:xx —— **界面"廉价感"专项**：字号比例 / 图标字体 / 行距 / 状态栏，exe 421,888 → 422,400 B）

用户："UI 感觉有点廉价"。量了一遍，廉价感不是配色问题，是**比例 + 图标 + 行距**：

| 项 | 之前 | 现在 | 为什么 |
|---|---|---|---|
| 界面字号 | `ui=20`（GDI 正高度 = 字符单元高，20 ⇒ 字形 em≈15，比正文 15px 的 em≈11 还大） | `ui=16`（em≈12，墨高 9px ≈ VS Code 的 Segoe 13px） | 界面字**必须小于正文**；倒挂 = "放大截图" |
| 正文字号/行高 | 15px / **18px**（1.2×） | 15px / **21px**（1.4×） | 1.2 倍是"灰墙"，没有呼吸；VS Code 默认 ≈1.5× |
| 图标 | 窗口按钮是**字符** `□ – ×`；目录箭头是字母 `v` / `>`；▶ 是 fill_rect 拼的（斜边锯齿）；设置是三条滑杆 | 全部换 **Segoe MDL2 Assets 图标字体**：`E921/E922/E8BB`（最小化/最大化/关闭）、`E768`（运行）、`E713`（设置齿轮）、`E8B7`（文件夹）、`E70D/E76C`（树箭头）、`E76B/E76C`（设置页 ‹›） | 图标字体同一套网格/笔宽 + hinting，斜边不再是台阶 |
| 状态栏 | 整条 `#007ACC` 蓝底 + 20px 白字（Dark+ 十年前的样子） | `#181818` 深底 + **顶部 1px 蓝线**，字降一档到 14px，"FLINT" 用粗体 | 底部不再压秤；深底 + 强调线是现代主题的做法 |
| 侧栏树 | 行高 22、缩进 12、`v`/`>` 字符箭头 | 行高 **26**、缩进 **16**、图标箭头、**缩进参考线**（`#373737`，对齐父级箭头中心） | 树"整齐"靠这三样 |
| 标题栏 | 雅黑 Bold 20px + 2px 字距（"FLINT Studio" 看着像 demo logo） | **Segoe UI Semibold 13px**、无字距；路径用 14px 次级灰 | 拉丁小字用系统 UI 字体最锐 |
| 菜单条 | 16→20px 字、无 hover | 16px 字（`tbh+5` 垂直居中）、**hover 高亮** `#303030` | 有反馈才"活" |

**过程证据（探针 + 像素测量）**：
- 先量：`ui=12/14/16/18/20` 五档的墨高 = 7/8/**9**/11/14 px ⇒ 选 16（对齐 Segoe 13 的 9px），不是拍脑袋。
- 标题/菜单/状态栏/树/行号的墨迹中心逐项量到 **±1px** 与栏位中心重合（`tmp\look-boxes.ps1`）。
- 抓到一个真 bug：`draw_ico` 会把 DC 字体换成图标字体，**后面画文字忘了换回来** ⇒ 设置页的值变成"图标字体里没有的拉丁字母"、墨高只有 6px。`probe-ide-ws` 的 CLIP 项直接抓出来（值墨高 6 < 8），修复后 PASS。

**探针适配**（设计变了，判据跟着变，不是放水）：
- `probe-ide-render` 的 STATUS 改成新口径：顶部蓝线 ≥400px、蓝面积 <4000px（不再是蓝板）、`#181818` 底 ≥20000px、浅色文字 ≥100px。
- `probe-ide-scroll` / `probe-ide-wrap` / `probe-ide-wrap-hl` 的 `lh` 由 `fsz+3` 改 `fsz+6`；`probe-ide-tree` 的行高 22→26；`probe-ide-menu` 点"运行"的 x 由 108 → 120（菜单项宽度 = 文字+24，ui 变小后整体左移）。
- 全套 **21 个探针全绿**（`tmp\run-ide-probes.ps1`）。

**边界（没做/做不成）**：
- **窗口圆角/阴影**：试过 `DwmSetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE)`，本机对无边框 `WS_POPUP` 返回 `E_INVALIDARG`、拿不到效果，已回退（代码里没留死 API）。真要做需要给窗口加 `WS_THICKFRAME` + `WM_NCCALCSIZE`，属于另一笔工程。
- 设置卡仍是 520×410、固定行高 44（`probe-ide-settings`/`probe-ide-ws` 按这套几何验收）；ui=16 下卡片留白偏多，要不要收紧是下一个决定。
- 状态栏左侧仍显示 `· FLGUI · 8899 · srv N`（调试信息），只是压成了 14px 次灰。

---

## 0.15 本轮已落地（2026-10-27 16:5x —— **中文字号轮一圈就"正文消失"**：垫片字体格式表撑满，exe 421,888 B 不变；`studio_text.dll` 71,338 → 73,290 B）

用户报："设置那个中文字号换了一个轮回之后 程序就不显示文件文本了"（行号还在）。

| 项 | 根因 / 落地形态 | 实测判据 |
|---|---|---|
| 根因 | `studio_text.c` 的 DirectWrite 字体格式表是 **16 格固定数组、只增不减**；`set_font` 每改一次字号要建 **2 个**（代码字体 + 中文）。一轮中文号 = 8 次 = 16 个 ⇒ 表满，`tx_font` 之后**永远返回 0** ⇒ 正文 `tx_text(id=0)` 直接 `return 1` 什么都不画，量宽也返回 0。行号走 GDI 那一层，所以"行号还在、文字没了"，而且**轮回去也不会自己好**（表只增不减） | 改前 `probe-ide-cjksize`：`AFTER present=0`（6 种语法色全归零），`GUTTER dim_px=178`（行号照旧）；改后同样操作 `present=5`，5 种颜色像素**逐项与基线相同**（106/120/161/304/250） |
| 垫片修法（v1.4） | 表扩到 64 格并**按 (face, px, weight) 去重复用**；表满时淘汰**最久没被画过**的一格（age 在 `tx_font/tx_text/tx_measure` 里刷新 ⇒ 正在用的两个 id 最热），淘汰时**连带清掉引用该 id 的排版缓存**（同一 id 换了字体，缓存里的 layout 还是旧字体）。建新格式失败就继续用旧的（有字总比没字强） | `probe-ide-cjksize` 的 STRESS 段：3 个字体族 × 字号来回扫 = 48 次换字，请求的格式数 **> 64**（必然触发淘汰），正文与中文注释/字符串照常（截图里"注释 comment 中文""字符串 string 中文"都在） |
| app 侧保险 | 新增 `g_txready`（= 垫片在 **且** 两个字体 id 都拿到了）才让正文走 D2D（`tx_begin/tx_end` + 分段绘制/量宽全改用它的判据）；`set_font` 只在**真拿到 id** 时才覆盖旧的（`tx_fontA` 返回 0 不再把可用 id 抹成 0），拿不到就整段退回 GDI 绘制 ⇒ 最坏情况是字丑，不会是空白 | 同探针；`draw_line_hl` 的 GDI 分支在 Begin/End 之外也能正常出字 |
| 探针 | 新增 `tmp\probe-ide-cjksize.ps1`：基线 → F9 进设置 → 走到「中文号」→ **Right×16（两整轮，最终 `cjksize=0`）** → 正文必须还在 + 行号还在 + 还能打字 → 再扫 48 次字体/字号（超表容量）→ 正文仍在 | 改前 FAIL（`text=False`）、改后 PASS；另加 `tmp\run-ide-probes.ps1` 顺序跑全套 21 个探针并写日志 |
| 顺带 | `tx_nfmt()` 导出（查"表里到底堆了几个格式"，排障用）；`studio.cfg` 里没有新增键 —— 这是纯渲染层修复 | — |

已知边界：64 格仍是有限容量（6 字体 × 17 号 = 102 种组合就能超），超了靠 LRU 淘汰；只要"正在画的 id"每帧都在刷新，就不会被淘汰到。真正的根治是给每个字体建完就不再变（或直接改成 DWrite 的字体集 + 复用），本轮没做到那一步。

---
## 1. 编辑

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据（可自动化优先） |
|---|---|---|---|---|
| 垂直滚动条 | **没有绘制**。`g_scroll` 只在 PageUp/PageDown 时改（`sw:1230-1234`）；全文件无滚动条绘制代码，右边缘是纯背景 | 无滑块/轨道/点击拖动；看不出文档位置 | **P0** | `probe-ide-scroll.ps1`：右边缘 14px 带内应找到连续 ≥20px 的滑块；PageDown 后滑块 y 变化 ≥2px；无实现时脚本输出 `slider=false` 并 SKIP |
| 鼠标滚轮 | `flgui` 泵层已把滚轮记进 `in.wheel`（`flgui:580-585`），但 `sw` **从未消费 `in.wheel`** | 滚轮完全无效（实测 `wheel_shift=0`） | **P0** | 同上：编辑器中央注入 3 格滚轮，内容应上移 ≈3×行高（51px）；数字由 `BestShiftInk` 量 |
| 光标可见性跟随 | 输入/方向键改 `g_cur` 后**不调整 `g_scroll`**（`sw:1131-1223`） | 光标走出可视区就看不见；点不到、也回不来 | **P0** | 新探针 `probe-ide-caret.ps1`（待写）：连按 ↓ 超过一屏后，光标像素仍在编辑区内；状态栏 Ln 与可见首行差 < 可见行数 |
| 行号列宽 | 固定右边界 240（`sw:1420` `draw_num_r(&sf, 240, ...)`）；侧栏到 220、正文 x=268 | 列宽不随行数/字号自适应；行表上限 399 行（`sw:151`）暂时掩盖了 4 位数溢出，一旦放开就压到侧栏 | **P1** | 用 1200 行样本打开 → 4 位行号最左像素 ≥222（不越过 220）；字号 26 时仍不重叠；`probe-ide-render` 的 GUTTER 项回归 |
| 缩进参考线 | **没有**（编辑器只画当前行底色、行号、正文、光标） | 无 indent guide | **P1** | 像素判据：在缩进列 x=268+n·字宽处出现 1px 竖线（颜色≈#404040），连续 ≥10 行；随 `g_scroll` 滚动 |
| 选区 / 复制粘贴 | **没有选区状态**（`c_sel` 只用于侧栏当前文件 `sw:1391`）；未导入任何剪贴板 API | 不能框选、不能 Ctrl+C/X/V/A，只能整文件 `Ctrl+S` | **P0** | 拖选后编辑区出现选中底色（VS Code #264F78，容差 20）≥200px；`Ctrl+C` 后 PowerShell `Get-Clipboard` 内容等于选中文本；`Ctrl+V` 后 `Ctrl+S` 落盘字节包含粘贴串 |
| 撤销 / 重做 | **没有**（无历史栈；每次插入/删除直接改 `g_src`） | 误删不可恢复 | **P0** | 隔离副本：打 `abc` → `Ctrl+Z` → 保存 → 字节回到原文；`Ctrl+Y` 再回到 `abc`；连续 20 次撤销不崩 |
| Tab 缩进 | Tab=0x09 走不进任何分支（`sw:1150` 只收 `in.key >= 32`，且 Tab 不是可打印字符） | Tab 键无反应；无 Shift+Tab 反缩进 | **P1** | 行首按 Tab → 保存字节为 4 空格（或制表符，口径写死）；Shift+Tab 回收；`probe-ide-edit.ps1`（待写） |
| 多文件 / 标签页 | **单缓冲区**：`g_src` 一份，`open_file()` 直接替换（`sw:862-873`）；Ctrl+1..9 打开左栏第 N 个（`sw:1309-1320`） | 无标签页、无未保存标记；切文件即丢未保存修改 | **P2**（P1 的"多文件打开"已由侧栏覆盖） | 打开 A 改一处 → 打开 B → 切回 A，修改仍在；标题栏显示当前文件名；至少 2 个标签可见 |
| 括号匹配 | **没有**（无配对扫描，无高亮） | 光标在 `{}`/`()` 旁无提示 | **P1** | 光标置于 `{` 右侧 → 该 `{` 与配对 `}` 同时变色（新增颜色像素 ≥20）；不配对的括号不变色 |
| 自动缩进 | **没有**：回车只插 1 字节 LF（`sw:1142-1149`） | 在 `{` 后回车不承继缩进 | **P1** | 在 `{` 行末回车 → 新行行首缩进 = 上一行 + 4；保存字节逐字节比对；`}` 自动回退一档 |

已知硬上限（会直接影响上述功能的验收样本）：行表 **399 行**（`sw:151`）、打开文件 **250000 B**（`sw:865,936`）、插入上限 250000（`sw:546`）、编译日志 **16000 B**（`sw:802`）。

## 2. 查找

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据 |
|---|---|---|---|---|
| Ctrl+F 搜索 | **没有**：按键处理只有 S / Enter / F11 / Esc / Ctrl+±0 / F9 / Ctrl+1..9（`sw:1224-1320`），没有 `edge(0x46)` | 无查找条、无匹配高亮、无"第 n/m 个" | **P0** | `probe-ide-find.ps1`：Ctrl+F 后 `ui_diff_px ≥ 20`，输入关键字后 `keyword_diff_px ≥ 20` → PASS；当前实跑 `ctrl_f_diff_px=0` → `SKIP(not implemented)` |
| 替换 | **没有** | 无 Ctrl+H、无单次/全部替换 | **P1** | 打开 `probe-ide-find.ps1 -Mode replace`（待加）：替换 1 处后保存字节只变目标串；全部替换后计数与出现次数一致 |
| 跳转行 | **没有**（无 Ctrl+G，无行号输入框） | 大文件无法定位 | **P1** | `probe-ide-goto.ps1`（待写）：Ctrl+G 输 `200` → 状态栏 `Ln 200` 且可视首行 ≤200；光标像素在编辑区内 |

> 说明：查找/替换/跳转三者共用"选区 + 滚动跟随"能力 —— 这就是为什么它们排在 P0/P1 而非 P2。

## 3. 外观

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据 |
|---|---|---|---|---|
| 主题切换（深/浅） | **没有**。10 个 + 6 个高亮色全是 `main()` 里的局部字面量（`sw:879-897`），`studio.cfg` 只认 `font/size/weight/cjk/cjksize`（`sw:696-700`） | 只能深色；无 `theme=` 配置、无切换快捷键 | **P1** | 浅色主题下 `(600,100)=#FFFFFF`、侧栏 `#F3F3F3`、状态栏 `#007ACC`；写 `studio.cfg: theme=light` 重启仍生效；`probe-ide-render` 增加 `-Theme light` 分支 |
| 字号 / 字体 | **已有 ＋ 已搬进设置页**（2026-10-26 21:2x）：标题栏滑杆图标 / `F9` 打开设置卡片，五行 = 代码字体・字号・中文字体・中文号・自动换行（`set_adjust` → `set_font` ＋ `save_cfg`）；`Ctrl+=` / `Ctrl+-` / `Ctrl+0` 仍保留快捷缩放，10..26 夹紧。行高 `lh=px+3`。**界面字（标题栏/侧栏/状态栏/卡片）= `Microsoft YaHei UI` **16** 灰度 AA**（2026-10-26：先换 YaHei 治中文回退宋体，再按"墨高对齐"把 13→16 —— YaHei13 的 CJK 墨高只有 8px，比旧 Segoe13 的 11px 小 27%，用户当场报"字小的离谱"；`mk_font_q` 留了 ClearType 档但深底有彩边不用；标题栏路径起点随品牌变宽挪到 x=182） | UI 字号不随 DPI 二次缩放（仅 `gui_win_dpi_apply`）；**设置页无"主题/缩进/编码"项**（能力未实现）；UI 文本仍走 GDI（DirectWrite 只覆盖正文） | 已实现（P0 无需再做；根治见"UI 全量 DWrite"候选） | `tmp\probe-ide-settings.ps1`：卡片 `card_px>20000`、选中行 >1000 px、←→ 后 `studio.cfg` 的 `font=` / `size=` 变化、面板开着打字 `srclen` 不变。⚠️ `tmp\probe-font2.ps1` 是**旧 F9 时代的观察脚本**（无断言、恒 exit 0），F9 语义变了以后别再拿它当判据 |
| 窗口全屏 | **已有 ＋ 已持久化**（2026-10-27）：F11 = 窗口全屏（1920×1040）、Ctrl+F11 = 真全屏（1920×1080，藏标题/状态栏）、Esc 退出；标题栏 □ 按钮同理；`studio.cfg` 的 `winmax=1` 让下次启动直接回到窗口全屏；**Esc/□ 回普通档时回到用户自己的矩形**（`set_winmode(0)` 不再写死 1000×700@120,90） | 真全屏(fs=2)不持久化（它不是常用状态，退出后回普通档最后矩形）；真全屏内无按钮 | 已实现（P0 完成） | `probe-ide-cfg.ps1`：`winmax=1` → 1920×1040（= 工作区）；880×620@160,120 → F11 → Esc 回 **880×620**（旧验收 `tmp\probe-fs.ps1` 的 rect 序列只剩真全屏一段没进自动探针） |
| 缩放（UI 整体） | 只有**字号缩放**（`lh=px+3` 跟着变），侧栏/状态栏/输出面板字体不缩放 | 无"整体缩放/缩放因子"概念 | **P2** | 若实现 `zoom=`：编辑器、行号、侧栏、状态栏像素高度同比变化（±1px）；字号缩放已有验收 |
| 窗口尺寸 | **已有 ＋ 已持久化**（2026-10-27）：边框 5px 拖拽（最小 620×420）；`studio.cfg` 的 `winx/winy/winw/winh` 退出时按 `GetWindowRect` 实测记录、启动按值恢复（越界夹回屏内） | 无 WM_SIZE 处理（外部 SetWindowPos 改尺寸时布局仍按自己的 W/H）；无"记住多显示器"的 DPI 口径 | 已实现（P0 完成） | `probe-ide-cfg.ps1`：手写 `900x600@200,150` → 窗口逐值还原；`probe-ide-resize.ps1`：1000→1120 重画、最小 620 |

## 4. 文件

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据 |
|---|---|---|---|---|
| 文件树 / 侧栏列表 | **已有：可展开目录树**（2026-10-26 能用版）：`tree_scan` 递归、只列目录 ＋ `.fl`（跳过 `tmp`/`.git`/`_studio_edit.fl`），上限 400 行/64 展开/4 层；点目录展开/折叠（状态存 `g_dopen`），点文件打开，滚轮滚动，当前文件高亮并自动 reveal；打开统一走 `tree_open()`（展开父目录＋重建＋reveal） | 无 Ctrl+R 手动刷新（新建/删除文件后要重开窗口）；无新建/重命名/删除；只认 `.fl`（其它文件用 `Ctrl+O`） | ✅ 已实现（P0 完成） | `tmp\probe-ide-tree.ps1`：树有墨迹、点 `alpha.fl` 后 `srclen=43`、点 `beta.fl` 后 `srclen=65`、滚轮后侧栏指纹变化 |
| 新建 / 打开 / 另存 | **已有**：`Ctrl+N` 新建空缓冲、`Ctrl+S` 原地保存、`Ctrl+O` 打开、`Ctrl+Shift+S` 另存为；**启动恢复上次文件**（`studio.cfg` 的 `file=`，文件没了退回 `apps/studio_native/main.fl`）；**三个对话框各自记住上次目录**（`dopen`/`dsave`/`dfolder`，见 §0.13）；**切文件/关窗时先自动存盘**（`g_dirty`），标题栏有未保存圆点 | 无"文件已修改→是否保存"询问（静默自动保存）；另存后旧路径的 `vf=` 条目不会自动改名 | **P0（完成）** | `probe-ide-cfg.ps1`：手写 `file=restore.fl` → 启动即载入（`srclen` 等于该文件字节）；`probe-ide-dlgdir.ps1`：三个对话框分别按 `dopen/dsave/dfolder` 打开；`probe-ide-tree.ps1`：改一字后点另一个文件 ⇒ 原文件磁盘长度 +1（改动没丢） |
| 最近文件 | **部分有**（2026-10-27）：cfg 里记 `file=`（上次文件）＋ 每文件 `vf=` 视图（路径/光标字节/首行，最多 12 条）⇒ 重启 / 切回来都回到原处；**没有**菜单或列表 UI | 没有"最近打开"下拉/欢迎页；没有 MRU 排序（`vf` 是"最近 12 个别丢"不是有序列表） | **P2（数据层已完成，只差 UI）** | `probe-ide-cfg.ps1`：`PERSISTVF` 检查连开两个文件后两条 `vf=` 并存；重启后 `cur/line/top` 逐值还原 |

## 5. 输出 / 诊断

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据 |
|---|---|---|---|---|
| 编译输出面板 | **已有基础版**：Ctrl+Enter（或启动）跑 `hlc.exe`，日志写 `tmp\studio_win_edit.log`，读前 16000 B 进 `g_out`（`sw:773-807`）；有输出时面板固定高 168px（`sw:1331`） | 只渲染前若干行，**不能滚动**（每次从 `i=0` 画，`sw:1476-1484`）；无复制、无折叠、无清空 | **P1** | 造 60 行编译错误日志：面板可滚轮/拖动查看最后一行；`g_out` 16000 B 上限内不截断显示计数 |
| 错误列表 / 点击跳转 | **已有**（2026-10-26 20:4x，见 §0.6）：`diag_at()` 解析 `hlc 编译错误（路径 第 N 行第 M 列）`，诊断行画 `#F48771`，面板标题 `N 条诊断 · 点行跳转`，点击落到源码行列；状态栏 `compile FAILED · N err` | v1 只跳当前缓冲（诊断指向别的文件时只改状态栏）；无"错误列表面板/按文件分组" | ✅ 已实现 | `probe-ide-diag.ps1`：点击后 `ai.state` line/col = 日志行列 −1（沙箱实测 5:16 → 4:15）；错误行配色 `row0_red>20`、其余行 `<10`；点回显行 line 不变 |
| 编译状态 | `g_status` 中间段显示 `ready/opened/saved/compile OK/compile FAILED`（`sw:768, 805`） | 无错误/警告计数、无耗时 | **P2** | 成功/失败两态文案与像素颜色断言；失败时至少 1 条 error |

## 6. 其他

| 功能 | 现状（代码依据） | 缺口 | 优先级 | 验收判据 |
|---|---|---|---|---|
| 状态栏信息 | 左：品牌 · `FLGUI · 8899 · srv` · server pid；中：`g_status`；右：`Ln n, Col n` / `UTF-8` / `N 行`（`sw:1487-1535`） | `UTF-8` 是**写死字符串**（`sw:1526`），不检测编码；无行尾符（LF/CRLF）指示；无缩进方式指示 | **P1** | 打开 CRLF 文件 → 状态栏出现 `CRLF`；保存后字节仍是 CRLF；打开 LF 文件显示 `LF`；两态状态栏像素差 ≥5px |
| 行尾符 / 编码 | 回车固定插 LF（`sw:1146`）；打开/保存原样读写，不转换、不检测 | 编辑 CRLF 文件会混入 LF；无编码选择（GBK 文件按 UTF-8 解析会乱码） | **P1** | 打开 CRLF + 中文文件，编辑一行保存 → 全文行尾仍 CRLF（逐字节比对）；非 UTF-8 文件提示/可切换编码 |
| 拖拽打开文件 | **没有**（未调用 `DragAcceptFiles`，无 `WM_DROPFILES` 处理） | 从资源管理器拖文件进来无反应 | **P2** | 拖 1 个 `.fl` 进窗口 → 标题栏路径变化、内容 = 该文件；拖多个 → 打开第 1 个或全部标签 |
| 单实例 | **没有**：无互斥体/命名窗口检查，每次启动都是新进程并新拉一个 `studio_server`（`sw:1035-1049`） | 双击两次会起两个实例、两个服务端抢 8899 端口；两个实例共写 `studio.cfg` / `_studio_edit.fl` | **P2** | 连启两次：`studio_win` 进程数 =1（第二次只激活已有窗口）；`studio_server` 数 =1；第二次窗口 rect 与第一次一致 |
| 窗口控制 | 自绘标题栏：拖窗、□ 最大化（工作区）、– 最小化、× 关闭（`sw:1064-1107`） | 无系统菜单/双击标题栏最大化/边缘缩放 | **P2** | 现有 `tmp\probe-win-ctl.ps1`：drag/mini/restore/close + `server_leak=0` |

## 7. 建议实施顺序（基于依赖关系，不是拍脑袋）

1. **滚动条 + 滚轮 + 光标跟随**（P0）：`g_scroll` 已是唯一滚动状态，补"可视行数×比例"的滑块与 `in.wheel` 消费即可；没有它，399 行以上的文件等于不可用。
2. **选区 + 复制/粘贴 + 撤销/重做**（P0）：这三项共用"编辑事务"骨架，是查找替换、Tab、自动缩进、括号匹配的前置；现在误删不可恢复，不能算能用。
3. **打开任意文件 + 新建 + 另存 + 文件树动态**（P0）：目前只能开 9 个固定文件之一，IDE 的价值面被锁死；做完这一刀，其余编辑功能才有真实输入。
4. （紧随其后）**Ctrl+F 查找**（P0）+ 错误行点击跳转（P0）：`probe-ide-find` 已把 SKIP 基线留好，实现后直接变 PASS。
   → **两条都已落地**（2026-10-26 01:30 查找、20:4x 诊断跳转）；下一步按 §7 剩下的 P0/P1 排（文件树动态、替换/Ctrl+G、主题、Tab、括号匹配、自动缩进）。

## 8. 附录：几何常量与探针读取口径（写探针时照这个来）

| 量 | 值 | 来源 |
|---|---|---|
| 普通窗口 | **不固定**：`studio.cfg` 的 `winx/winy/winw/winh` 恢复上次几何；全新（无 cfg）时 1000×700 @ (120,90)；最小 620×420 | `set_winmode` / main 启动段（2026-10-27 起不再写死） |
| 侧栏宽 / 编组线 | 220 / 219..220 | `sw:1353-1355` |
| 行号右边界 / 正文 x | 240 / 268 | `sw:1420, 1429` |
| 标题栏高 / 状态栏高 | 34 / 26（真全屏都是 0） | `sw:1327-1330` |
| 正文首行 y | `tbh + 6` = 40 | `sw:920,1329` |
| 行高 | `fsz + 3`（默认 14 → 17） | `sw:752,898,971` |
| 有输出面板时编辑区下沿 | `sb_top - 168`（默认 506） | `sw:1331` |
| 编辑区底色 / 侧栏 / 标题栏 / 状态栏 | `#1E1E1E` / `#252526` / `#3C3C3C` / `#007ACC` | `sw:879-897` |
| 行号 / 正文 / 当前行 | `#858585` / `#CCCCCC` / `#2A2D2E` | 同上 |
| 高亮六色 | 关键字 `#569CD6`、类型 `#4EC9B0`、控制流 `#C586C0`、字符串 `#CE9178`、注释 `#6A9955`、数字 `#B5CEA8` | `sw:891-897` |
| cfg 项（设置段） | `font` `size` `weight` `cjk` `cjksize` `wrap` `ui` `ws` | 设置页 / `load_cfg` |
| cfg 项（状态段，2026-10-27） | `winx` `winy` `winw` `winh` `winmax` `tree` `file` ＋ 每文件 `vf=<路径>\|<光标字节>\|<首行源码行号>`（×12） | `session_capture` / `save_cfg`（**正常退出**才写） |
| cfg 项（对话框位置，2026-10-27） | `dlgdir`（三个资源管理器对话框**共用**的上次目录；老键 `dopen`/`dsave`/`dfolder` 只做迁移读取） | `dlg_initdir` / `save_cfg_now`（选完立刻写） |

> 维护约定：改 `sw` 的布局常量时，同步改本表 + `tmp\IdeProbe\IdeProbe.ps1` 里的
> `Measure-Slider` / `Get-LineHeight`，再跑三个探针确认基线没漂。
