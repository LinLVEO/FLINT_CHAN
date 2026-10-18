# FLGUI — FLINT 的 immediate-mode GUI 库（API 文档 · M4q）

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`（**数字不许手抄**：值当场取自取数器，写成「事实标记」——标记写法与全部键名见 `docs\数字台账.md` 头部）
> 引用我=`开源前-人类可用性缺口.md`、`docs\真实项目.md` ｜ 我引用=`docs\数字台账.md`（取数器）、`test\flgui-verify.ps1`、`test\verify-all.ps1`、`src\pe.c`、`tools\导入预算.ps1` ｜ 最后复核=2026-10-15 `test\docgate.mjs`

> **定位**：FLINT（FL）自己的界面库，**私人工具用**（不外供、不追生态；对外的面孔是"用它做的工具"）。
> ⚠️ **2026-10-15 订正（原文留档）**：上面那句「**私人工具用**（不外供、不追生态；对外的面孔是“用它做的工具”）」**已于 2026-10-13 由所有者明令作废**（原话：「作为私人的东西这条过期了 必须在未来真的有一席之地 像zig一样」）⇒ 现行定位 = **面向 Windows 小工具/面板的界面库**（口径见 `SPEC.md` §现行定位、`方向-对外一席之地（2026-10-13 用户口径变更）.md`、`docs\设计决策.md` **D7**）。
> 三层全纯 FLINT，**不含 C**：内核 `lib\flgui.fl` ／ 控件 `lib\flgui_widgets.fl` ／ 平台 `lib\flgui_win32.fl`。
> **本文档的硬要求**：每个示例**都能编、都能跑**（真 flint 与 boot 双端；退出码就是文里写的那个值）——
> 这些示例同时就是回归样本（`test\samples\flgui*.fl`，由 `test\flgui-verify.ps1` 双端对账）。

---

## 0. 五分钟上手（最小可跑程序）

```fl
// demo_min.fl — 建一个窗、放一个按钮、点它累加计数（真窗模式）
include "flgui_win32.fl"          // 平台层会把内核与控件层一起带进来

int main() {
  struct GuiCtx c;                 // 界面状态：**局部**（跨帧要活的量请放状态池，见 §1.2）
  struct GuiInput in;              // 每帧输入
  struct GuiWin g;                 // 窗口
  struct Surf sf;                  // 画布表面（ULW 逐像素上屏）
  int *hf = 0;
  int n = 0;

  gui_init(&c);                    // 一次：默认主题 + 默认尺寸 + 清空状态池
  c.lay_w = 180; c.lay_h = 80;
  hf = gui_win_font_init(14);      // 一次：建字体（句柄必须存在**局部变量**里，见 §3.3）

  g.cls = "MYAPP";                 // ⚠️ 类名每进程只注册成功一次 ⇒ 每窗一个**不同**的类名
  g.x = 300; g.y = 200; g.w = 180; g.h = 80; g.alpha = 235;
  if (!gui_win_make(&g)) { return 90; }
  if (!gui_win_surf(&sf, &g, 6)) { return 91; }
  gui_win_dpi_apply(&c);           // 读回 DPI 写进 ctx（本机 96 ⇒ gui_dpi_scale 恒等）

  while (1) {
    if (gui_win_pump(&g, &in) == 0) { return 0; }   // 泵消息（滚轮在这里累加；WM_QUIT 返回 0）
    gui_win_input(&g, &in);                          // 光标 + 左键（每帧清零/累加都在各自函数里成对）
    gui_begin(&c, &in);                              // 帧开始
    gui_label(&c, "FLGUI");
    if (gui_button(&c, "click") == 1) { n = n + 1; }
    gui_end(&c);                                     // 帧结束
    gui_win_render(&sf, &c, hf);                     // 命令表 → 表面
    gui_win_show(&sf);                               // 上屏（ULW）
  }
  return 0;
}
```

**四步协议**：`gui_init` 一次 → 每帧 `gui_begin` → 控件/自定义绘制 → `gui_end` → 平台层 `gui_win_render` + `gui_win_show`。

✅ **上面这份示例是跑过的**（2026-09-22 M4 实测，源文件 `tmp\m4-doc\demo_min.fl`）：真 flint 与 boot **双端都编过**
（`flint.exe demo_min.fl -o demo_min.exe` ／ `b1_emit.exe demo_min.fl`，退出码都是 0），产物起来后**窗口连跑 3 秒不崩**。
自己复现：把它拷到 `E:\FLINT-lab\` 下建目录 `tmp\m4-doc\` 里（`include` 路径要解析得到 `..\..\lib\`），再跑上面两条命令。

**"无头"（不开窗）跑法**：合成输入当数据喂 `gui_begin`，用 `gui_dump()` 把命令表/游标/状态池打成文本，
双端逐字节对账（`test\flgui-verify.ps1` 就是这么干的；`apps\flgui_demo` 的 `dump.on` 开关让真窗 app 也能无头跑）。

---

## 1. 内核层 `lib\flgui.fl`

### 1.0 全局载体与容量（**单点定义，越界只计数、绝不静默越写**）

| 载体 | 类型 | 容量 | 越界表现 |
|---|---|---|---|
| 命令表 | `gui_cmd_kind/x/y/w/h/toff/tlen/col[]` | 256 条 | `gui_cmd_over > 0`（dump 里可见），多余命令被丢 |
| 状态池 | `gui_pool[]` | 512 组 × 4 字段（`id % 512`） | **会撞位**（不同 ID 落同一组）⇒ 见 §1.2 的纪律 |
| 文本 arena | `char gui_text[4096]` | 4096 字节 | `gui_text_over > 0` |
| 裁剪栈 | `gui_clip_*[]` | 8 层 | `c.err |= 1` |
| **不透明度栈**（M4h） | `gui_alpha_v[]` | 8 层 | 满 ⇒ `c.err \|= 16`；**空栈弹** ⇒ `c.err \|= 32`（都只计数、绝不越写） |
| 滚动/弹层嵌套 | `gui_sc_*[]` | 4 层 | `c.err |= 4` / `|= 8` |

命令 kind 表：`1` 面板填充 ｜ `2` 按钮常态 ｜ `3` 按钮悬停 ｜ `4` 按钮按下 ｜ `5` 文本 ｜ `6` 裁剪压栈 ｜
`7` 裁剪出栈 ｜ `8` 描边 ｜ `9` 勾选框块 ｜ `10` 分隔线 ｜ `11` 滑块/滚动条轨道 ｜ `12` 填充条 ｜
`13` 进度条底 ｜ `14` 文本域盒 ｜ `15` 文本光标条 ｜ **`16` 焦点圈标记（M4o）** ｜
**`20` 不透明度压栈（M4h）｜ `21` 不透明度出栈（M4h）** ｜
**`22` 字体档压栈（M4q）｜ `23` 字体档出栈（M4q）** —— 后两对是**状态命令**（载荷分别写在
`gui_cmd_a` / `gui_cmd_w` 上，见 §1.4.1 与 §2.8）。

### 1.1 ID 系统

| API | 说明 |
|---|---|
| `int gui_id(char *s)` | 字符串 → ID（djb2，`char` 有符号 ⇒ 内部做了负数兜底，中文 label 也稳） |
| `int gui_id_in(char *s, int idx)` | 同名控件在循环里用 ⇒ `idx` 混入，避免同一 ID |

> ID **只由 label 决定** ⇒ 按钮改成"文字变了"就成了另一个控件（勾选态、滚动偏移都会另起一份）。
> 循环里生成控件请用 `gui_id_in("row", i)` 自己算 ID，再配 `gui_next_rect` 精确排版。

### 1.2 状态池（跨帧状态住这里）

| API | 说明 |
|---|---|
| `int gui_pool_get(int id)` | 读该 ID 的**字段 0**（老入口，行为与 M4e 及以前一字不差） |
| `int gui_pool_set(int id, int v)` | 写该 ID 的**字段 0**（返回写入值） |
| `int gui_pool_at(int id, int k)` | **M4f**：读字段 `k`（`k = 0..3`，越界**夹取**，不越写） |
| `int gui_pool_put(int id, int k, int v)` | **M4f**：写字段 `k`（返回写入值；越界夹取） |
| `int gui_pool_sum()` | 池的确定性摘要（dump 用：跨帧存活/串位一眼可见）。⚠️ **只摘字段 0** ⇒ 动画字段不许动老基线 |

**字段图（M4f 一次定死，以后不再动结构）**：`0` = 既有状态（勾选态/滚动偏移/弹层开关…）｜`1` = 动画**起始戳**(ms)｜
`2` = **起点值**（留给"从哪来"式动画）｜`3` = **标志**（M4f 用：`1` = `gui_anim` 已起过一次）。

已有控件用它存：勾选态（`gui_checkbox`）、滚动偏移（`gui_scroll_begin/end`）、弹层开关（`gui_popup_*`）。

⚠️ **槽位是取模的**（512 组）⇒ 别把"大整数状态"往池里塞当万能仓库；要更多槽请显式加容量常量。

### 1.3 文本 arena

| API | 说明 |
|---|---|
| `int gui_text_w(char *s)` | 文本宽度（**布局口径 = 每字节 8px**，见 §5 口径与误差；⚠️ **光标条不走这条** —— 它用实测字宽 `gui_char_adv`） |
| `int gui_text_put(struct GuiCtx *c, char *s)` | 按 NUL 结尾入 arena，记进 ctx 暂存（下一条 `gui_push` 用它） |
| `int gui_text_put_n(struct GuiCtx *c, char *s, int len)` | **按显式长度**入 arena（缓冲不保证有 NUL 时**必须**用它） |
| `int gui_text_put_col(struct GuiCtx *c, char *s, int color)` | 同上 + 显式颜色（`0` = 主题色） |
| `int gui_text_put_col_n(struct GuiCtx *c, char *s, int len, int color)` | 长度 + 颜色 |
| `char *gui_text_at(int off)` | arena 内偏移 → 指针（平台层画字用） |
| `int gui_char_adv` / `int gui_char_adv_ok` | **真实每字符像素宽**（内核层声明；建字体时由平台层 `gui_win_font_init` 调 `ui_font_adv` 用 GDI **量一次**写入）。默认 8 = 兜底值（无头样本不建字体 ⇒ 恒 8，行为与从前逐字节一致）；`_ok=1` = 已实测。**凡"位置类"计算（光标条）必须读它** —— 见下面这条 |

⚠️ **血泪教训**：段缓冲（`rbuf`/`pads` 这类）**不保证有 NUL** ⇒ 用 `gui_text_put` 会把**邻段陈旧字节**一起搬进
arena，画出来是几段字叠在一起；而**文字层判据全绿**（dump 对得上），只有渲染层像素判据抓到（2026-09-22 M3a：17.2% 像素差）。
⇒ **凡"字节段"入 arena，一律用带长度版。**

⚠️ **另一条同族教训（2026-09-23，「同一把尺子」）**：**"算位置的尺子"必须和"画东西的尺子"是同一把。**
可编辑文本域的光标条原按 **8px/字节估算**定位（`n * 8`），而字是 GDI 按**真实字形宽度**画的
（Consolas 14px 实测 **7px/字符**）⇒ **每打一个字，光标就比字尾多偏 1px、逐字累加**
（用户手打描述"打几个字后光标会往后移好几个位置，就是不准"；dump 实测 n=2 光标 x=28 而字尾 26、n=3 时 36 vs 33）。
⇒ 正解 = 建字体时**量一次真字宽**（`ui_font_adv` → `gui_char_adv`），光标读它。
**判据**：门里新增「光标条契约」（**外部裁判 = GDI 量宽**，断言 `光标 x = 文本 x + 真字宽 × 长度`）——
**不能只靠 dump 基线**：基线只会"记住当时的值"，当初那个错值就是被基线一并锁死的（M4c 教训）。

⚠️⚠️ **契约（M4c 第二次栽在同一层，2026-09-23）**：**文本命令的 `text=` 字段必须是"arena 偏移"** ——
渲染器读的是 `gui_text_at(toff)` = `gui_text + toff`。**控件想画自己的缓冲（编辑区、段缓冲、局部数组）时，
必须先把它拷进 arena（`gui_text_put` / `gui_text_put_n`）再 `gui_push(c, 5)`**，绝不能把"另一块缓冲的偏移"
直接塞进 `scratch_off`。
本轮实锤：可编辑文本域写成 `c->scratch_off = gui_edit_offset(slot)`（槽 0 = **128**，这是 `gui_edit_buf` 的偏移）
⇒ 渲染器从 `arena + 128` 读固定垃圾字节 ⇒ **框里出现一个看不懂的字符，且输入什么都一样**；
而"打的字"显示在下面那行标签里（标签走 `gui_label(c, gui_edit_text(0))`，路径是对的）⇒ 用户的原话是
"框里有莫名的字符、我打的字跑到下一行去了"。
**为什么门没拦住（值得记）**：这是一处**跨缓冲的语义错**，`dump` 只把当时的 `text=128,0` 原样记进基线
（**基线会把错值一并锁死**），`flgui6` 的掩码也只钉了 `tlen`（长度）——**文字层判据看得见"长度对"、
看不见"偏移指到哪块缓冲"**，只有真窗像素能看出来（修后：框里的墨迹随内容增长；修前雷打不动 1 段 14 列）。
⇒ **凡"某字段指向哪块内存"的契约，别只靠 dump 基线，要留一条像素/真窗判据。**

### 1.4 命令表

| API | 说明 |
|---|---|
| `int gui_push(struct GuiCtx *c, int kind)` | 用 ctx 的 `cur_i*` 矩形 + 暂存文本/颜色追加一条命令（返回命令数） |

约束与颜色：`gui_cmd_col != 0` 时平台层用它，否则用 `c.theme_text`。**显式颜色是"一次 put 配一次 push"的配对量**
（`gui_push` 之后自动清零，不会漏给后面的命令）。

#### 1.4.1 不透明度：**命令自带生效值 ＋ 状态命令**（M4h，2026-09-27）

```fl
int a = gui_alpha_push(&c, 128);   // 之后画的填充命令都按 128/255 混（kind 20 进命令流）
gui_panel(&c, ...);                // 这一段"半透明"
gui_alpha_pop(&c);                 // 恢复上一层（kind 21）
int cur = gui_alpha_cur(&c);       // 当前生效值（空栈 = 255）
```

| API | 说明 |
|---|---|
| `int gui_alpha_push(struct GuiCtx *c, int a)` | 压一层不透明度（`0..255`，**负值夹 0 / 超 255 夹 255**）；返回压进去的值；8 层满 ⇒ `err \|= 16` 且返回 0（**绝不越写**） |
| `int gui_alpha_pop(struct GuiCtx *c)` | 弹一层；返回**弹出之后**的当前值（空栈 = 255）；**没压过就弹** ⇒ `err \|= 32` 且返回 0 |
| `int gui_alpha_cur(struct GuiCtx *c)` | 当前生效值（`alpha_n == 0` ⇒ 255 = 不透明） |
| 字段 `gui_cmd_a[256]` | **每条命令自带生效不透明度** —— 在 `gui_push` 那一刻从栈顶解析（与 `gui_cmd_col` 同一种"配对量"） |

**形状（本刀定的口径）**：命令流里多一种**状态命令** —— `kind 20` = 压 / `21` = 弹（与裁剪 `6`/`7` **同形**：
8 层、越界只计数、没压过不许弹、每帧 `gui_begin` 归零）。差别只有一处：
**生效值在压栈那一刻解析进每条命令**（`gui_cmd_a`）⇒ 渲染端**不需要维护状态栈**、读路径唯一，
判据能在无头样本里**逐条命令**钉住（样本 `flgui11`）。`kind 20` 的载荷（`gui_cmd_a`）= 压进去的值。
⇒ **20/21 的用处是"在命令流里标出层的边界"**，将来做"层 / 组"（离屏合成）时靠它找边界；本刀渲染端对它们无状态。

**⚠️ 两条语义边界（本刀明确不做，别当 bug）**：
1. **文本不吃 alpha（3 参数版的口径）** —— 文字是 GDI `TextOutA` 直接写进 DIB 的，逐命令混合做不到；`gui_label` 等文本命令在
   `alpha < 255` 时**照常不透明地画**。要让"一整段（含文本）一起淡出" ⇒ 走**离屏层**（M4i 已做，见 §1.4.2：**4 参数版**渲染）。
2. **不是"整窗淡出"** —— 整窗常量 alpha 仍走 `Surf.const_a`（ULW 的 `BLENDFUNCTION`，见 `ui_lib.fl`）；
   本刀管的是**命令级**（"这一个面板 / 这一段"）。

**为什么是软件混合（零新导入）**：最重链（`apps\m2_float\main.fl`）的**导入预算条目 <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->（模块位 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact--> 顶格）**
（`objdump -p tmp\loopcheck\app_flint.exe` 实测 <!--fact:imports-m2float-->90<!--/fact--> 条目 / <!--fact:modules-m2float-->8<!--/fact--> 个 DLL 组；`src\pe.c` 的 `MAX_IMPORTS = <!--fact:limit-imports-->96<!--/fact-->`、`MAX_GROUPS = <!--fact:limit-groups-->8<!--/fact-->`
且判据是 `total >= MAX_IMPORTS`）⇒ 多用**一个**导入名（msimg32 的 `AlphaBlend`、gdi32 未文档的 `GdiAlphaBlend`
都算）今天已**不再**让那条链当场失败（条目还有余量），但**模块位 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact--> 已顶格** ⇒ 加**新的 DLL 模块**会当场撞墙 —— 这才是真正的墙。所以走 `Surf.bits` 直写像素（`surf_alpha` 已在用的通道）。
⚠️ **直写像素吃不到 DC 的裁剪区** ⇒ 渲染端另存一份"与内核同源的裁剪矩形栈"（`gwb_cl*`），混合前先求交。
**代价**（同进程 QPC、40 个面板 × 1200px 的同一份几何，取 3 轮最小）：`a=255` 走 GDI = **155µs**、
`a=128` 走混合 = **1566µs** ⇒ **≈29 ns / 每像素混合**（含同一份 `surf_paint` 的固定开销）；
一屏 184×60 ≈ 11k 像素全混 ≈ **0.32ms**（60fps 的 16ms 预算里占 2%）。

#### 1.4.2 离屏层：`20..21` 之间 = **一个层**（M4i，2026-09-27）

```fl
struct Surf lay;                            // 层表面由**应用持有**（句柄不许进全局 —— 语言硬规则）
gui_win_layer(&lay, &sf);                   // 建一次、每帧复用（几何跟随主表面）
...
gui_alpha_push(&c, 128);                    // 层开始（kind 20）
gui_popup_begin(&c, "menu", 2);             // 层里可以有任意命令：填充 + **文本**
gui_popup_end(&c);
gui_alpha_pop(&c);                          // 层结束（kind 21）
gui_win_render_layered(&sf, &c, hf, &lay);  // **4 参数版 = 启用离屏层**（3 参数版 = 不启用）
```

| API | 说明 |
|---|---|
| `int gui_win_layer(struct Surf *lay, struct Surf *s)` | 应用侧建层表面（几何跟随主表面；**建一次、每帧复用** —— 别每帧 `CreateDIBSection`） |
| `int gui_win_render_layered(struct Surf *s, struct GuiCtx *c, int *hf, struct Surf *lay)` | 4 参数渲染：`kind 20/21` 之间整段先画进离屏 DIB，再整块按层 alpha 混回 |
| `int gui_win_render(struct Surf *s, struct GuiCtx *c, int *hf)` | **3 参数老版**：内部传一个 `bits == 0` 的哑表面 ⇒ **不启用层**，语义与 M4h **逐像素不变** |

**做法**（零新导入，还是 `Surf.bits` 直写那条通道）：① 层内所有命令**先画进离屏 DIB**（GDI 照常用 ⇒ 文本也在里面）；
② 盖层的 alpha **只在合成那一步施加一次**（`(dst*ia + src*a)/255`，B/G/R 各一路）；
③ 层的包围盒 = **层内绘制命令矩形的并集 ∩ 当前裁剪** ⇒ 只处理这一块（层越大代价越大，不是整窗）；
没被层画到的像素"抄一份再混回去" = **恒等变换**（所以不用逐像素跟踪"改过没有"）。

**🔴 关键坑（本刀第一版就踩了）**：层内命令拿到的 `gui_cmd_a` 是**栈顶解析后的绝对值**（M4h 口径），
照它画会把外层 alpha **用两次** —— 实测 a=128 的面板在层里先被混成 `24`、合成时再混一次 ⇒ 出 **20**（不是 24）。
正解 = 层内按 `cmd_a * 255 / layer_a` 还原"**相对本层**的 alpha"（= 255 ⇒ 层内**不透明**、走 GDI 老路，还更快）。

**⛔ 有意变更的语义（M4i 定义）**：`20..配对的 21` 之间 = **一个层 ⇒ 整体只合成一次** —— 层内多次叠加
**不再累积** alpha（M4h 逐命令累加：两块 a=128 得 **28**；层语义得 **24**）。⚠️ 这个变更**只作用于 4 参数版**：
3 参数版（既有 3 个 app 与所有老探针）语义**原样不变**（`blend-probe.fl` case6 的 28 依旧成立）。

**⚠️ 诚实边界**：
1. **只做一层** —— 层内再出现 `kind 20` ⇒ **不新建离屏**（内层走"相对本层 alpha"那条式子，是近似、不是真层栈）。
   真层栈要给**每层**一个离屏表面，而表面里的句柄不许进全局（语言硬规则）⇒ 得给应用一个表面数组 ＋ 层号参数。
2. **不是"整窗淡出"** —— 整窗常量 alpha 仍走 `Surf.const_a`（ULW 的 `BLENDFUNCTION`）。
3. **不透明层（alpha = 255）刻意不走离屏** ⇒ 与改前同路、连一次拷贝都不多花（"不退化"的结构性保证）。

**📊 实测（同进程 QPC、同一份几何 = 40 个面板 × (20×10)、3 轮取最小）**：离屏层 **178µs** vs 逐命令混合 **278µs**
（层内命令是**不透明**的 ⇒ 走 GDI 老路，只有一次整块混合；逐命令则逐面板混像素）⇒ 这条路上"层"反而**更便宜**。
**判据** = 探针 `tmp\layerprobe\layer-probe.fl`（6 位全亮 = 63 → `exit 42`），核心那一条是**文本像素**：
`a=255` ⇒ 文字 = **224**（文本色本身）｜`a=128` ⇒ **同一个像素 = 120**（= `blend(底 16, 文本 224, 128)`）⇒ **字真的跟着淡了**。

### 1.5 裁剪栈

| API | 说明 |
|---|---|
| `int gui_clip_contains(struct GuiCtx *c, int x, int y)` | 点是否在最近一层裁剪内 |
| `int gui_clip_visible(struct GuiCtx *c)` | 当前项矩形是否与裁剪相交（不相交就别发命令） |
| `int gui_clip_push(struct GuiCtx *c, struct GuiRect *r)` | 压栈（与上一层**求交**后存）+ 发一条 kind 6 |
| `int gui_clip_pop(struct GuiCtx *c)` | 出栈 + 发一条 kind 7（**没压过就别 pop** ⇒ `err |= 2`） |

### 1.6 布局游标

| API | 说明 |
|---|---|
| `int gui_layout_init(struct GuiCtx *c, int x, int y)` | 重置游标（`gui_begin` 每帧按 `pad` 调一次） |
| `int gui_same_line(struct GuiCtx *c)` | ⚠️ **给「下一个」项用**：让**下一个**控件留在当前行 |
| `int gui_spacing(struct GuiCtx *c, int px)` | 项间距（默认 4） |
| `int gui_item_rect(struct GuiCtx *c, int w, int h)` | 算当前项矩形并推进游标（每个控件的第一件事） |
| `int gui_next_rect(struct GuiCtx *c, struct GuiRect *r)` | 给**下一个**控件指定矩形（精确排版；会动游标） |
| `int gui_item_at(struct GuiCtx *c, struct GuiRect *r)` | **只钉当前矩形，完全不动布局游标**（逐段自定义绘制的正解） |

⚠️ `gui_same_line` 的方向（2026-09-22 真 bug）：放在**两个项之间**才对——
放在第一个项**之前**会让那一项退回上一行（用 `row_y`）并与上一行叠字；**状态型 dump 看不见**这类错，
判据要用**命令表级坐标**（`test\samples\flgui4.fl` 位 12/13 就是钉这个方向的）。

```
|  A1  A2 |        ← 正确：gui_label("A1"); gui_same_line(&c); gui_label("A2");
|       A2 |        ← 错误：gui_same_line(&c); gui_label("A1"); gui_label("A2");   (A1 退回上一行)
```

#### 1.6.1 动画矩形：**位移 / 缩放**的标准写法（M4g，2026-09-27）

**这一刀零新内核 API** —— "位移/缩放"不是新命令、也不是新函数，而是**把动画值喂进矩形**：

```fl
// ① 两个目标矩形（收起态 / 展开态）② 进度 ③ 每个分量各自 gui_lerp ④ 交给布局原语
int t  = gui_anim(&c, gui_id("panel"), 260);      // 0..256（缓动后）
r.x = gui_lerp(0, 40, t);      // 位移：x
r.y = gui_lerp(80, 120, t);    // 位移：y
r.w = gui_lerp(40, 100, t);    // 缩放：宽
r.h = gui_lerp(10, 50, t);     // 缩放：高
gui_next_rect(&c, &r);         // 下一个控件照这个矩形排（会动游标）
// 或者做"覆盖层"（不参与自动布局）：gui_item_at(&c, &r); gui_text_put(&c, ""); gui_push(&c, KIND);
```

三条纪律（都是从坑里来的）：

1. **同一个进度驱动所有分量** —— 位置与尺寸各写一个 `gui_anim` 会让它们**不同相**（看着像卡顿的错位）；
   一个 `t` 算完再分头 `gui_lerp` 才有"整体滑过去又长大"的感觉（`flgui10` 位 10 就是钉这条：中段的
   `Δx` 与 `Δw` 必须相等）。
2. **"展开/收起"别写 `open ? t : 256−t`** —— 首帧进度还是 0 时，"收起"会被算成 **256**（= 反而全展开）。
   正解 = **从"切换那一刻的显示值"出发**：`g_ph = gui_lerp(g_from_h, 目标高度, t)`，切换时把当前显示值
   存进 `g_from_h`（连点两次也不跳）。
3. **覆盖层用 `gui_item_at`，不用 `gui_next_rect`** —— 前者**完全不动布局游标**，所以覆盖层的显示与否
   不会把后面控件的排布带歪（`flgui10` 位 12/13：游标三项原样 ＋ 有/无覆盖层时"下一个控件"矩形逐字段相同）。

> ⚠️ **真窗动画要挂在 `g_dump == 0` 分支里**（demo 的口径）：无头 dump 与真窗共用同一条 `demo_frame` 路径
> ⇒ 真窗专有的动画必须显式排除，否则**老基线当场变**。M4f/M4g 两刀都靠这条保住了 9 条老基线逐字节不动。

### 1.7 命中与状态机

| API | 说明 |
|---|---|
| `int gui_hit(struct GuiCtx *c)` | 鼠标是否落在当前项矩形内（且未被裁剪） |
| `int gui_control(struct GuiCtx *c, int id)` | hot→active 状态机：返回 1 = **本帧被点击**（"按下当帧不算，抬起且仍悬停才算"） |

语义要点：`active` = "**拥有鼠标直到抬起**"的令牌 —— 拖到窗口外也不丢（滑块/拖滑块靠它）。

### 1.8 帧协议与 dump

| API | 说明 |
|---|---|
| `int gui_init(struct GuiCtx *c)` | 一次：默认主题（`gui_theme_default`）+ 默认尺寸 + 清池 |
| `int gui_begin(struct GuiCtx *c, struct GuiInput *in)` | 每帧开始：搬运输入、清 hot/命令表/arena、重置布局（返回帧号） |
| `int gui_end(struct GuiCtx *c)` | 每帧结束：抬起即收令牌（返回本帧命令数） |
| `int gui_dump(struct GuiCtx *c)` | 纯文本 dump 到 stdout（FRAME 行 + 逐条 CMD + POOLSUM）——**双端逐字节对账的判据载体**；FRAME 行含 `ms=`（本帧注入的时间戳，M4d） |
| `int gui_anim_set(struct GuiCtx *c, int pct)` | **动画时长缩放通道**（M4d 动画地基①）：`0` = 立即完成（=关动画）／`100` = 正常（`gui_init` 的默认值）／`200` = 慢动作；**负值夹到 0、上限 1000**（越界只夹取，不报错） |
| `int gui_ease_out(int t)` | **M4f**：定点缓动曲线（ease-out，先快后慢）。`t = 0..256`（**256 = 1.0**）⇒ 返回 `0..256`；越界夹取。整式 = `t(196608 − 768t + t²)/65536`（即 `1−(1−p)³` 的整数展开）：`e(0)=0`、`e(64)=148`、`e(128)=224`、`e(256)=256`，**全程单调不降且恒 ≥ t**（线性会给 64 ⇒ 形状可判） |
| `int gui_lerp(int a, int b, int t)` | **M4f**：整数插值 `a + (b−a)×t/256`（`t = 0..256` 定点，越界夹取）。截断方向随被除数符号（C 语义）⇒ `lerp(20,10,128)=15`；**双端一致**，本刀不做四舍五入 |
| `int gui_anim(struct GuiCtx *c, int id, int dur_ms)` | **M4f**：**动画进度入口**（唯一"有状态"的动画函数）：按 ID 存起始戳、按**注入时间**算、按 `anim_pct` 缩放时长，返回 `0..256` 的**缓动后**进度（0 = 刚起步、256 = 到位）。用法：`x = gui_lerp(x, target, gui_anim(c, gui_id("sld"), 160));` |

⚠️ **`gui_anim` 的四条纪律（M4f，写动画前先读）**：
1. **除法只出现在这里**（同 `anim_pct` 那条纪律）：两个除零入口 `anim_pct <= 0` / `dur_ms <= 0` 都在函数开头特判返回 `256`（= 立即到位），别的函数一律不除。
2. **"有没有起过"另占**字段 3，**绝不能用"起始戳 == 0"当没起** —— 无头样本第一帧注入的 `ms` 恰好就是 0（M4d 固定序列 `0/16/32/48`）⇒ 用 0 当"没起"会**每帧重盖起始戳、进度永远是 0**（本刀设计时差点踩进去）。
3. **重启动画** = `gui_pool_put(id, 3, 0)`（把标志写回 0）；本刀只做"起一次"，事件触发的**重放**语义留给下一刀。`gui_anim` 因 `anim_pct<=0` / `dur<=0` **提前返回时不许写标志**（否则下次真动画起不来）。
4. **时间只用注入的 `c->ms`**（内核不取时）⇒ 进度按绝对时间算、**掉帧不跑偏**（本刀门里用"两条帧史不同的 ID、同 elapsed 必须同进度"钉住）。

⚠️ **时间注入纪律（M4d 动画地基①，2026-09-26 落地）**：`GuiInput.ms` / `GuiCtx.ms` = **本帧时间戳（毫秒）**，
**只由平台层或样本给** —— 平台层里 `gui_win_input` 的 `GetTickCount()` 是**全库唯一的取时点**。
**内核层绝不许自己取时**：dump 基线是**逐字节**判据，内核一取时，每次跑经过的时间就不同 ⇒ 动画中间值不同
⇒ **基线全红、判据体系当场失效**。无头样本喂**固定序列**（`0/16/32/48`，见 `test\samples\flgui7.fl`）
⇒ dump 照样逐字节确定。进度一律按**绝对时间**算（`(now − 起始戳) / 时长`），**不用帧数当计时器**（掉帧不跑偏）。

### 1.9 主题与 DPI（M4；**M4j 加蓝白预设**）

| API | 说明 |
|---|---|
| `int gui_theme_default(struct GuiCtx *c)` | **主题默认值的唯一权威**（**16 个** `theme_*`）；`gui_init` 调它；也当"复位"用 |
| `int gui_theme_light_blue(struct GuiCtx *c)` | **M4j：现代 UI · 蓝白预设**（用户拍板"要好看点、主题蓝白"）—— 先调 `gui_theme_default` 再覆盖 **15** 个字段 ⇒ **谁调谁变** |
| `int gui_dpi_scale(struct GuiCtx *c, int v)` | 按 `c.dpi`（96 = 100%）**纯整数**缩放：`(v*dpi + 48)/96`，负数对称；`dpi<=0` 视为 96 |
| `int gui_space_snap(int v, int n)` | **M4n：单个值归到 n 的倍数** —— `((v + n/2) / n) * n`（四舍五入，.5 向上），`v > 0` 时结果**至少是 n**；`n <= 0` / `v <= 0` 原样返回 |
| `int gui_space_grid(struct GuiCtx *c, int n)` | **M4n：间距栅格入口** —— 把 `c->pad` / `c->spacing` 归到 n 的倍数（`n <= 0` = 不动）；**只加入口、不改默认值**（默认仍是 `pad 6 / spacing 4`，见 §5 第 12 条） |

主题字段（**16 个**）：`theme_bg` 窗底 ／ `theme_panel` 面板·弹层·默认填充（**M4n 起也是勾色**）／ `theme_btn` 按钮常态（也当进度条底·文本域盒）／
`theme_btn_hot` 悬停 ／ `theme_btn_down` 按下 ／ `theme_border` 描边·分隔线·勾选框未选（**M4n 起也是单选钮圆环色**）／ `theme_text` 文字 ／
`theme_box` 勾选框选中块（**M4n 起单选钮内点的颜色**）／ `theme_track` 轨道 ／ `theme_fill` 填充条（**滑块圆拇指也是它**）／
**M4j 新增** `theme_text_dim` 二级文字 ／ `theme_accent_soft` 淡强调底 ／ `theme_danger` 危险·警示 ／
**M4k** `theme_radius` = **现代档开关**（控件圆角半径 px；**0 = 经典档** = 直角 ＋ 无控件描边）／
**M4l** `theme_shadow` = 盒类投影强度（0 = 关）／
**M4n** `theme_check` = **勾选框打勾的强度**（0..255，**0 = 不画 = 老行为**）＋ `theme_focus` = **焦点圈颜色**（COLORREF，**0 = 不画 = 老行为**）。
颜色一律 **COLORREF = `0x00BBGGRR`**（**低字节才是 R** —— 直写像素时最容易搞反，M4k 轮就修过一笔这种 bug，见 §5 第 9 条）。
**M4n 的两个新开关都是"0 = 关 = 老行为"族**（同 `theme_radius` / `theme_shadow`）：`0` 时渲染端那段函数一次都不进
（判据 = `tmp\artprobe\run-art-classic.ps1`：同一份源码分别用 **865b0ca（M4m）的库**与本刀的库编译，整块表面**逐像素比**）。

```fl
gui_init(&c);                     // 默认（深色）主题
c.theme_bg   = 0x00121010;        // app 只覆盖自己要改的字段（别抄整块常量）
gui_theme_light_blue(&c);         // M4j：整套换成"现代 UI · 蓝白"（**预设函数** ⇒ 不动别的 app）
gui_theme_default(&c);            // 想回默认：调它，别自己抄一遍常量
```

**为什么预设是"函数"而不是改 `gui_theme_default` 的默认值**（用户 2026-09-27 ① 拍板选"加预设"）：
改默认会**影响所有 app**（demo / 画廊 / 浮窗各自的覆盖都要重看、基线要重录）；预设 = **谁调谁变**，
不调的 app **行为与基线零扰动** —— FLGUI 门 13 条 dump 基线在 M4j 之后**仍逐字节一致**，这就是"只换皮"的机械证据
（判据在 `test\samples\flgui12.fl` 位 4：同一帧两套主题下命令表逐字段相同）。

**蓝白色板**（`#RRGGBB` ↔ COLORREF 逐行；对应 `待拍板-面板开工清单.md` 的 C1 表）：
`theme_bg #F3F6FB` ｜ `theme_panel #FFFFFF` ｜ `theme_btn #FFFFFF` ｜ `theme_btn_hot #EAF2FE` ｜
`theme_btn_down #D8E8FB` ｜ `theme_border #D6DEE8` ｜ `theme_text #1B1F24` ｜
`theme_box` / `theme_fill` = 强调蓝 `#2563EB` ｜ `theme_track #E3E9F1` ｜
`theme_text_dim #5A6472` ｜ `theme_accent_soft #EAF2FE` ｜ `theme_danger #D64545` ｜
**M4n** `theme_check = 255`（勾满强度；勾色走 `theme_panel` = `#FFFFFF`）｜ `theme_focus = #2563EB`（**与 `theme_box` 同值** —— M4j 当时的原话"焦点圈复用 `theme_box`"，现在它有了自己的字段，要分开的 app 只改这一个）。

**⚠️ 两条诚实的现状（读之前先看）**：
1. **`GuiCtx` 字段 = 69 / 上限 128**（M4n 实点：M4l 后 65、M4m 的 `wheel_step`/`drag_scale` ＋2 = 67、M4n 的
   `theme_check`/`theme_focus` ＋2 = **69**）。历史：M4j 时**满格 64/64**（清单 C1 里写的"43 个 / 64 有余量"
   是**过时的数**）⇒ 当时焦点圈复用 `theme_box`；🆕 上限 2026-09-27 23:5x 抬到 **128**（真 flint ＋ boot 同轮同改），
   M4l 的 `theme_shadow` 与 **M4n 的 `theme_check`/`theme_focus` 就是这么进来的**；判据见
   `待拍板-面板开工清单.md` 顶部 🆕 条（边界探针 `struct_128fields` 正例 / `fields_129` 负例 ＋ boot `b6b2` / `nb35`）。
   ⚠️⚠️ **加全局变量的坑（M4n 实测踩到，务必先读）**：真 flint 的 T1 分析里 `is_addr_value()` 对全局 `int` 查的是
   `slot_marked(n->offset)`，而 `offset` 对**全局**是"全局表下标"、对**局部**是"帧槽偏移"，两者同处一张正整数表
   ⇒ **新加全局变量会挪动后面所有全局的下标，撞上某个"装地址的局部槽"的号就误报**
   「地址值（64 位）不能装进全局 int」并打断编译（本刀实测：在 `flgui.fl` 里加 19 个全局后，
   `flgui_win32.fl` 的 `gui_key_tr_n` 当场报错 —— 它只是 `= gui_key_tr_n + 1`）。
   ⇒ 本刀在 `flgui.fl` **一个全局槽都不加**（形状标记走**函数** `gui_shape_circle()`、单选钮组态走**状态池**）。
   要加全局时请**一个槽一个槽地试**，别一次加一批。（属**编译器层**的既有缺陷，另立卡，见 §5 第 13 条。）
2. **浅色主题下"白按钮压白卡片"看不见** —— 控件层**不发描边命令**（§5 第 5 条），蓝白色板里 `theme_btn` 与
   `theme_panel` 同为 `#FFFFFF` 时，按钮只能靠**位置与文字**区分。⇒ **控件描边 ＋ 圆角是这条主题的必需项**
   （M4k 已落地：渲染端画，命令流一个字节没动）。

---

## 2. 控件层 `lib\flgui_widgets.fl`

每个控件的固定四步：① 文本入 arena → ② `gui_item_rect` 定矩形并推进游标 → ③ `gui_control` 走状态机 → ④ 发命令。

| API | 返回 | 说明 |
|---|---|---|
| `int gui_label(struct GuiCtx *c, char *s)` | 0 | 只读标签（无交互、不进 hot/active、**不聚焦**） |
| `int gui_button(struct GuiCtx *c, char *s)` | 1 = 本帧被点击 | 按钮（按下当帧不算、抬起且仍悬停才算）。**M4o：可聚焦** |
| `int gui_separator(struct GuiCtx *c)` | 0 | 1px 横线，占满容器宽 |
| `int gui_slider(struct GuiCtx *c, char *s, int value, int max)` | 新值 | 拖动跟手；点轨道也生效；越界夹到 `[0,max]`。**M4m：拖动倍率** `c.drag_scale`（%）：按下那一帧记锚点，拖动时 `虚拟光标 = 锚点 + (真光标 − 锚点) × drag_scale / 100`；**100 = 1:1 = 与 M4l 及以前逐像素相同**，50 半速 / 200 双倍。锚点住**状态池字段 k=2**（`gui_pool_sum` 只摘 k=0 ⇒ 老 dump 基线零扰动）。**M4o：可聚焦** |
| `int gui_progressbar(struct GuiCtx *c, char *s, int value, int max)` | 0 | 只读进度条（`0` 不发填充命令、`>max` 不溢出） |
| `int gui_textfield(struct GuiCtx *c, char *s)` | 0 | **只读**文本域（按盒宽截断） |
| `int gui_textfield_edit(struct GuiCtx *c, int slot, int maxlen)` | 1 = 回车确认 ｜ 2 = Esc 取消 ｜ 0 = 其它 | **可编辑**文本域（点进去打字；见下）。**M4o：可聚焦**（被 Tab 聚焦 ⇒ 编辑焦点跟上；离开 ⇒ 收回） |
| `int gui_checkbox(struct GuiCtx *c, char *s)` | 勾选态 0/1 | 状态住**状态池**（跨帧存活）。**M4n：`theme_check > 0` 时渲染端在选中块里逐像素画 ✓**（两段 2px 线，色 = `theme_panel`；命令流一字未动）。**M4o：可聚焦** |
| `int gui_radio(struct GuiCtx *c, char *s)` | 选中态 0/1 | **M4n 新增：单选钮（默认组 `""`）** —— 圆环 `kind 8` + 选中内点 `kind 9`（**零新 kind**）；组语义见下。**M4o：可聚焦** |
| `int gui_radio_g(struct GuiCtx *c, char *g, char *s)` | 选中态 0/1 | **M4n：显式分组的单选钮**（`g` = 组名；同组互斥）。FLINT 没有默认参数 ⇒ 与 `gui_radio` 是两个入口 |
| `int gui_scroll_begin(struct GuiCtx *c, char *s, int view_h)` | 0 | 开滚动视口（偏移按 ID 存池；滚轮只在光标悬停于视口内时被消费）。**M4m：滚轮步长 = `c.wheel_step`**（默认 60 = 3 行/格；设 0 = 滚轮不动） |
| `int gui_scroll_end(struct GuiCtx *c)` | `maxoff` | 收尾：算内容高、夹偏移、内容超出时画滚动条（轨道 + 滑块，**拖滑块**也支持）。**M4m：命中区从绘制的 4px 放宽到 12px（`[tx−8, tx+4)`，向左多 8px，绘制一字未动）** ＋ 拖动同样吃 `c.drag_scale` |
| `int gui_popup_open(struct GuiCtx *c, char *s, int x, int y)` | 1 | 开弹层（通常是右键菜单），状态写池 |
| `int gui_popup_begin(struct GuiCtx *c, char *s, int n_items)` | 1 = 本帧显示 | 画面板底并进裁剪/布局 |
| `int gui_popup_item(struct GuiCtx *c, char *s)` | 1 = 被点中 | 菜单项（复用按钮语义；点中即关） |
| `int gui_popup_end(struct GuiCtx *c)` | 0 | 收尾：点在弹层外 ⇒ 关（**begin 返回 0 时不会 pop**，栈不会失衡） |

滚动视图用法（滚轮一格 = `c.wheel_step` px，默认 **60**；视口偏移进池，跨帧存活）：

```fl
gui_scroll_begin(&c, "list", 40);      // 视口高 40
i = 0;
while (i < 12) { gui_label(&c, "row"); i = i + 1; }
maxoff = gui_scroll_end(&c);           // 收尾自动夹取 + 画滚动条
```

**单选钮（M4n）的组语义（本刀定的口径，样本 `flgui14` 与门里的外部裁判按这个判）**：
1. **一个"单选组" = 一个组名（字符串）**。`gui_radio(c, "OPT-A")` 用**默认组 `""`**；要显式分组用
   `gui_radio_g(c, "g1", "标签")`（FLINT 没有默认参数 ⇒ 两个入口，不是可选参数，见 §5 第 11 条）。
2. **组内互斥**：任一时刻组里最多一个被选中。实现**不是**"点击时扫一圈清别人"，而是
   **组槽里存"本组当前选中的控件 id ＋ 1"**，某个钮的 `on` 就定义为"组槽 == 我 id+1"
   ⇒ **互斥由构造保证**（与"谁先画、谁后画"无关，跨帧也自然成立）。
3. **状态全住状态池**（与勾选框同一族载体）：自己 → `gui_pool_set(id, on)`（**k = 0**）；
   本组选中的控件 → `gui_pool_put(组槽键, 3, id + 1)`。组槽键 = `gui_hash(组名) ^ 0x2C1B3D4F`
   （异或一个常量，把"组名"与"控件标签"两套 key 分开；不同组名之间仍按既有 `id % 512` 口径接受碰撞，
   见 §5 第 13 条的诚实边界）。**组表容量问题因此不存在**（写的就是池那张 512 槽表，`gui_init` 已经清过）。
4. 命令流形状（**零新 kind、零新导入**）：未选 = `kind 8` + `kind 5`；选中 = `kind 8` + `kind 9` + `kind 5`；
   圆环 = `box_w × box_w`、圆点 = `box_w/2` 居中、标签 x = `box_w + spacing`。
5. ⚠️ **形状通道**：勾选框未选也发 `kind 8`（同尺寸）、选中也发 `kind 9`（同尺寸）⇒ 与单选钮**逐字段完全相同**，
   渲染端无从判断"画方还是画圆"。⇒ 单选钮的两条命令带 **`gui_cmd_col` = `gui_shape_circle()`**
   （`0x43495243`；这个字段在填充类命令上本来没人读，只有文本命令 `kind 5` 读它当显式文字色）：
   `0` = 矩形 / 圆角盒（与 M4k 及以前逐像素同形），非 0 = 圆（`kind 8` = 1px 圆环、`kind 9` = 实心圆盘）。
   ⚠️ 形状通道**不随 `theme_radius` 开关**（新控件的形状是它自己的语义，不是"现代档装饰"）。
6. ⚠️ **点击那一帧的绘制顺序**（诚实边界）：组槽在**点击那一刻**更新，而"画在它前面"的钮在**同一帧**里
   已经读过旧组值（它的 `on` 与池里的 k=0 要到**下一帧**才归 0）。60fps 下 = 一帧 ≈16ms 的延迟，
   视觉上看不出来；判据（`flgui14` bit 16 与门里那条）是**点击后下一帧**读的。

弹层用法（右键 → 在光标处开菜单，点条目/点外面关）：

```fl
if ((GetAsyncKeyState(2) & 0x8000) != 0) { gui_popup_open(&c, "menu", in.mx, in.my); }
gui_begin(&c, &in);
if (gui_popup_begin(&c, "menu", 2) == 1) {
  if (gui_popup_item(&c, "reset") == 1) { /* ... */ }
  if (gui_popup_item(&c, "quit") == 1) { g_quit = 1; }
}
gui_popup_end(&c);
gui_end(&c);
```

---

## 2.5 可编辑文本域（`lib\flgui_edit.fl`，M4b 新增）

**语义（契约）**：点进盒子 = 聚焦（光标在末尾）｜打字 = 末尾追加｜退格 = 删一个字符（**GBK 双字节整删**）｜
**回车 = 确认**（把当前内容固化成新基线、失焦、控件返回 1）｜**Esc = 取消**（回滚到基线、失焦、返回 2）｜
点盒子外 = 失焦（**保留**已输入内容）｜满了 = 静默丢弃（不会写越界、也不会切半个 GBK）。

| API | 说明 |
|---|---|
| `int gui_textfield_edit(struct GuiCtx *c, int slot, int maxlen)` | 可编辑文本域（控件层）；`slot` = 全局文本槽 0..7，`maxlen` = 字节上限（夹到 127） |
| `char *gui_edit_text(int slot)` | 取该槽文本指针（**现取现用**，别存进全局 int） |
| `int gui_edit_size(int slot)` | 该槽当前字节数 |
| `int gui_edit_init(int slot, char *init, int maxlen)` | 绑定/重置（按字符边界截断，不切半个 GBK） |
| `int gui_edit_setmax(int slot, int maxlen)` | 只改上限（**每帧都可调**；改小会按字符边界裁） |
| `int gui_edit_put(int slot, int key)` / `int gui_edit_puts(int slot, char *s)` | 追加一个字符 / 一整串（程序化填写用） |
| `int gui_edit_backspace(int slot)` / `int gui_edit_rollback(int slot)` / `int gui_edit_commit(int slot)` | 退格 / 回滚到基线 / 把当前内容固化成基线 |
| `int gui_edit_focused(struct GuiCtx *c)` / `gui_edit_focus` / `gui_edit_blur` | 当前焦点槽（**-1 = 无焦点**）／设焦点／失焦 |
| `int gui_edit_key(struct GuiCtx *c)` | 本帧键盘动作（**只在"自己是焦点"时由控件调用**）：0 无 ／ 1 回车确认 ／ 2 Esc 取消 |

**载体与容量**：文本住 `flgui_edit.fl` 的**全局 char 缓冲**（8 槽 × 256 字节：低 128 = 基线备份、高 128 = 实时文本）。
`struct GuiCtx` 只加两个标量字段（`key`、`edit_slot`）—— **不要**把文本塞进 ctx（struct 定长数组字段是 boot 的雷）。
光标条 = 新命令 **kind 15**（纯增量：老基线的命令流一字不动）。
⚠️ **光标 x 的口径（2026-09-23 修）**：`cx = 盒 x + pad + 字节数 × gui_char_adv`，其中 `gui_char_adv` 是
**建字体时用 GDI 量出来的真字宽**（Consolas 14px = 7px/字符）。原写法用 8px/字节估算 ⇒
**每打一个字光标比字尾多偏 1px、逐字累加**（用户手打抓到）；判据见 §6 的「光标条契约」（外部裁判）。

🔴 **同一个症状的"真因"（2026-09-23 二轮定案，比上面那条更根本）**：`apps\flgui_demo\main.fl` 把
`gui_win_font_init(14)` 的**返回值丢掉了**（`int *hf;` 从未赋值），真窗渲染却把未初始化的 `hf` 交给
`gui_win_render` ⇒ **DC 回落到默认 stock 比例字体** ⇒ 字是**比例宽度**（真 DC 实测逐字增量
8,10,8,5,4,8,8,4…），而光标按"等宽 7px/字符"算 ⇒ 模型怎么改都对不上（8px 偏右、7px 偏左 —— 用户两次
反馈的方向翻转就是这个）。⇒ **app 必须 `hf = gui_win_font_init(px);` 接住句柄**（`ui_gallery` 是对的）。
判据 = 真窗诊断行 `CV … ext=… delta=…`（用 surf 真 DC ＋ 真字体量"该文本命令实际要画的那段"再与命令表对账；
修好后 `ext` 恒 = 7×字符数、`delta` 恒 0）。**教训：dump/命令表全绿证明不了"画的时候用了哪个字体"。**

**键盘从哪来（平台层口径；M4b 定下，M4c 两轮更正后定稿）**：

> 🔴 **先看这条（M4c 的血泪口径）：IME 接管时 `WM_KEYDOWN` 的 `wParam` 变成 `VK_PROCESSKEY = 0xE5`。**
> 系统输入语言是中文（微软拼音在跑）时，字母键先交给 IME ⇒ 我们收到的是"已处理"标记而不是真实 VK，
> `TranslateMessage` **一个 `WM_CHAR` 都不产生**、`ToAscii(0xE5, …)` **恒返回 0**；而 `lParam` 里的
> **扫描码始终正确**（'K'=0x25、退格=0x0E）。⇒ **凡依赖 VK 的键盘处理，在中文输入法下会整个失灵**；
> 同一台机器、同一个产物，切到 en-US 又能用 —— 这就是本次"时好时坏"的真因（不是焦点、不是布局没点亮）。

1. **默认档（纯后台）**：`gui_win_pump` 里调 `TranslateMessage` —— `WM_CHAR` 不是系统主动投递的，
   是它把 `WM_KEYDOWN` 翻译出来的（不调 ⇒ 一个字符都进不来，实测 `keydown=6 / keychar=0`）。
2. **键盘档（要真打字就用它）**：**不依赖系统翻译**，走平台层**库内 US 表**：
   `MapVirtualKeyA(扫描码, MAPVK_VSC_TO_VK=1)` 把**扫描码反查成 VK**，再查库内表得到 ASCII，
   上档符号/大小写用 `GetAsyncKeyState`（Shift=16、CapsLock=20）判。**输入语言、IME 都影响不到它**。
   ⚠️ 口径边界：**US 布局**（zh-CN 底层也是 US，符号位置一致）；只认可打印 ASCII 32..126；
   **中文/IME 组合输入仍未做**（要 `WM_IME_*` ＋ `ImmGetContext` 一族，另开卡）。
3. `in->key` **不是"每帧清零"的量**（和滚轮相反）：一次按键序列会在**同一个 pump** 里产出多条字符，而界面
   **一帧只消费一个字符** ⇒ 口径 = `in->key` 是**待消费槽**（消费方取走后置 0），`gui_key_pending` 记"还剩几个"，
   平台层每帧开头把未消费的那个端过来。
4. 退格/回车/Esc 走 `WM_KEYDOWN`。**VK 也一律从扫描码反查**（IME 下 `wParam` 不可信，见上）；
   `GetAsyncKeyState` 的**按下沿兜底轮询只给默认档用** —— **键盘档必须关掉它**：IME 会把控制键的
   `WM_KEYDOWN` **推迟一帧**，兜底先算一次、迟到的消息再算一次 ⇒ **同一个退格删两个字符**（账本实测
   `L=2→1→0`）。这条是"兜底与消息对同一次按键各算一次"的典型坑。
5. **字符没法用轮询兜**（要键盘布局 + 大小写 + IME）⇒ 真打字走第 2 条那条表。

```fl
// 可编辑文本域的最小用法（真窗：点进去打字、回车确认）
r = gui_textfield_edit(&c, 0, 16);
if (r == 1) { /* 回车确认：内容已固化，可读 gui_edit_text(0) 拿走 */ }
if (r == 2) { /* Esc 取消：内容已回滚到基线 */ }
```

**判据**：`test\samples\flgui6.fl`（无头、合成输入、双端逐字节对账，**20 位全亮 = 1048575**：聚焦/打字/退格/回车/ Esc/
点外面失焦/未聚焦打字被忽略/满上限拒绝，逐条都有）。

---

## 2.6 键盘焦点链（Tab 导航，M4o · 2026-09-28）

**要补的缺口**（M4n 诚实边界②的原话）：焦点圈 `theme_focus` 与渲染端画法 M4n 已经落好，但"谁是焦点"只有一个来源
= **点进可编辑文本域** —— 键盘 Tab 导航没做。本节就是那条链。

| API | 返回 | 说明 |
|---|---|---|
| `int gui_focus_next(struct GuiCtx *c)` | 新序号 + 1（0 = 没有可聚焦控件） | 焦点**前进**一格（末尾回绕到第 0 个） |
| `int gui_focus_prev(struct GuiCtx *c)` | 同上 | 焦点**后退**一格（开头回绕到最后一个） |
| `int gui_focus_get(struct GuiCtx *c)` | 焦点控件的 id（0 = 没有） | 焦点控件的 id（由命中的那个控件在本帧登记时写入） |
| `int gui_focus_reg(struct GuiCtx *c, int id)` | 1 = 它**就是**当前焦点 | **控件层每帧自己登记**（按绘制顺序）；内核层不调它 |
| `int gui_focus_key()` | 焦点态那个"伪 key" | 焦点态在状态池里占的槽键（见下第 6 条的载体口径） |

**焦点序号与清单数不另立 getter，直接读池**（省函数，见下面第 8 条）：
序号 = `gui_pool_at(gui_focus_key(), 1) - 1`（**-1 = 没有焦点**）｜清单数 = `gui_pool_at(gui_focus_key(), 2)`。
**键码也不另立常量**（写 `9` / `0x0109` 两个字面量）：`9` = VK_TAB（前进）｜`0x0109` = 0x100（Shift 修饰位）| VK_TAB（后退）。

**口径（本刀定的契约，样本 `flgui15` 与门里的外部裁判按这个判）**：

1. **焦点 = 一个"序号"**（本帧第几个**可聚焦控件**，0 基），**不是 id**：immediate-mode 下"下一个是谁"
   只有按**本帧绘制顺序**数才成立 ⇒ 每个可聚焦控件每帧自己 `gui_focus_reg` 一次，命中"焦点序号"的那个就是焦点。
2. **可聚焦清单**（本刀定的）：按钮 / 勾选框 / 单选钮 / 滑块 / **可编辑**文本域。
   **不可聚焦**：标签 / 分隔线 / 进度条 / **只读**文本域 / 滚动视口本身（视口里的控件各自算）。
3. **Tab 前进 / Shift+Tab 后退、两端回绕**；**本来没有焦点**时：Tab ⇒ 第 0 个（第一帧也能算，不需要上一帧的清单数）、
   Shift+Tab ⇒ 最后一个（**这一条要数得到清单** ⇒ 全新 ctx 的第一帧反向 Tab 不生效，见 §5 第 14 条诚实边界）。
4. **导航在 `gui_begin` 里消费**（内联：`c->key == 9` ⇒ `gui_focus_next`、`== 0x0109` ⇒ `gui_focus_prev`）
   ⇒ 焦点圈**本帧就画在新的焦点控件上**（不像"点击那一帧"那样迟一帧）；
   Tab 被**消费掉**（`c->key` 置 0）⇒ 不会漏给文本域当字符，也**不进 `gui_key_pending`**（它不是待打印字符）。
5. **焦点圈的画法分两条路**（都只是"标记"，形状/颜色在渲染端）：
   · **可编辑文本域**：`kind 14`（盒）＋ `kind 15`（光标条）—— **M4n 的老路，一字未改**（`theme_focus` 非 0 时圈在盒外沿 1px）；
   · **其余可聚焦控件**：**新命令 `kind 16`**（rect = **整个控件矩形**）⇒ 渲染端只画圈、**不填充**。
   没有焦点 ⇒ **一条标记都不发**（老样本命令流逐字节不变）。
6. **载体（三条硬约束一起满足才允许落地）**：
   · **零新增全局槽** —— 焦点态住**状态池**（伪 key `gui_focus_key()` = `gui_hash("__flgui_focus") ^ 0x464F4355`）＋
     `GuiCtx` 的**闲置字段** `kbd`（从 M1 起只被赋值、从没被读过 ⇒ 本刀定成"本帧焦点登记游标"）。
     为什么不能加全局变量：编译器 T1 的既有缺陷（全局槽号与局部帧槽偏移共用一张正整数表 ⇒ 加全局会误报并打断编译）。
   · **不动 `GuiCtx` 结构体**：加字段会让帧槽偏移整体位移（`等价门-指纹` 全批位移，很贵）。
   · **不动老 dump 基线**：焦点序号/计数住池的 **k=1 / k=2 / k=3**（`gui_pool_sum` 只摘 k=0 ⇒ POOLSUM 零扰动）。
7. **焦点链与"编辑焦点"（`c->edit_slot`）是两套状态、由控件层对齐**（三条规则写在 `gui_textfield_edit` 上）：
   链焦点落在文本域 ⇒ `gui_edit_focus` 跟上；链焦点在别人身上 ⇒ 编辑焦点收回；鼠标点进/点出 ⇒ 两个一起变。
8. ⚠️⚠️ **函数预算（本刀实测踩到的硬约束，扩充这个库之前必须读）**：boot 编译器**只有一张 <!--fact:limit-boottable-->512<!--/fact--> 项的函数表**，
   装的是 **api 声明 ＋ 函数定义**（`boot\lib_parse.fl` 的 `if (p->nfuncs >= 512) return -85;`）。
   最重链 `apps\m2_float\main.fl` 把 `ui_lib` ＋ FLGUI 全 include 进来，**实测只剩 8 个新函数的余量**
   （`tmp\m4o\measure-headroom.ps1`：给老库追加 8 个空函数仍能编、9 个就 `parse err=-85`）。
   ⇒ 本刀第一版加了 **17** 个顶层函数，**总门 [11] loop 当场变红**（真 flint 编得过、boot 编不过 ——
   这正是"真应用双端编译"这道门存在的理由）；**收敛到 7 个**（键码用字面量、序号/清单数直接读池、
   收尾写进 `gui_begin`/`gui_end`、`gwb_focus_ring` 的"往前找盒"内联到调用点）。
   ⚠️ 同轮还踩到一条同族限制：**boot 的全局初始化只吃字面量**（`int x = 0 - 2;` ⇒ `parse err=-47`，
   实测把 demo 的 boot 那一端打断）⇒ 新全局一律用字面量初值。
   📊 判据 = 总门 `[11] loop`（`test\loop-verify.ps1`：真应用双端编译 ＋ dump 逐字节对账）。

---

## 2.7 焦点可见性（M4p · 2026-09-28）

**要补的缺口**（M4o 诚实边界⑦的原话）："**滚出视口的控件仍占序号**（`gui_focus_reg` 不看裁剪）⇒
焦点可以落到**看不见的控件**上（那时不发 `kind 16` ⇒ 圈也不见）"。

**做法（一行门槛，零新增顶层函数/全局槽、不动 `GuiCtx`）**：`gui_focus_reg` 在**登记之前**先算
"控件矩形与**最近一层裁剪**的相交面积"，**相交面积 < 控件自身面积的一半 ⇒ 本帧不登记**（不占序号）。

```fl
// 内核里那段（`lib\flgui.fl` 的 gui_focus_reg 开头，纯内联、无新函数）
j = c->clip_n - 1;
if (j >= 0) {
  x0 = c->cur_ix; if (x0 < gui_clip_x0[j]) { x0 = gui_clip_x0[j]; }   // 相交矩形
  y0 = c->cur_iy; if (y0 < gui_clip_y0[j]) { y0 = gui_clip_y0[j]; }
  x1 = c->cur_ix + c->cur_iw; if (x1 > gui_clip_x1[j]) { x1 = gui_clip_x1[j]; }
  y1 = c->cur_iy + c->cur_ih; if (y1 > gui_clip_y1[j]) { y1 = gui_clip_y1[j]; }
  ix = x1 - x0; iy = y1 - y0;
  if (ix <= 0 || iy <= 0) { return 0; }                              // 完全不相交
  if (ix * iy * 2 < c->cur_iw * c->cur_ih) { return 0; }             // 露出不足一半
}
```

**口径（本刀定的契约，样本 `flgui16` 与门里的外部裁判按这个判）**：

1. **"本帧可见" = 与最近一层裁剪的相交面积 ≥ 控件自身面积的一半**（不是"相交一像素就算"）。
   贴着视口边只露出 2px 的控件**不占序号**；露出一半以上的照常进链。
   **没有裁剪栈时恒可见**（`clip_n == 0` ⇒ 直接登记）—— 不打视口的界面行为与 M4o 一字不差。
2. **视口外的"序号空洞"因此消失** ⇒ Tab / Shift+Tab 的回绕只在**可见集合**上算。
3. **全都不可见时（退化档，明写）**：本帧登记数 = 0 ⇒ `gui_end` 那条"序号越界 ⇒ 收回焦点"把它清成
   **-1**（焦点不悬空）；Tab 与 Shift+Tab **都不动**，**一条 `kind 16` 都不发**。
4. **载体与代价**：**零新增顶层函数**（用内核自己的裁剪栈，纯内联算式）、**零新增全局槽**、**`GuiCtx` 一个字没动**；
   老样本（不打视口 / 视口内全可见）的命令流与状态池**逐字节不变**。
5. ⚠️ **诚实边界**：
   · **"可见"是"露够一半"，不是"完整可见"** —— 露出 ≥ 一半的控件照样占序号，它的圈会被渲染端的裁剪
     照常裁掉一部分（例如控件左沿正好压在视口左沿时，圈的左外沿那一列看不见）。
   · **判据只看"最近一层裁剪"**（与 `gui_clip_visible` 同口径）：嵌套裁剪（视口里再开弹层）时以最内层为准。
   · **序号仍是"本帧顺序"的**：焦点控件自身被滚出去时，序号会自动改指到"可见集合里同一格"的另一个控件
     （**"按 id 记住焦点"仍未做** —— 那是 M4o 之后另立的候选）。
   · **焦点圈本身不参与这个判定**：渲染端 `gwb_focus_ring_rect` 不查自己的裁剪栈，靠"内核不发这条命令"
     来保证"看不见的控件没有圈"。
6. 📊 **判据**：`test\samples\flgui16.fl`（15 位全亮 = 32767 → `exit 42`，门里 25 条外部裁判用 PowerShell
   现算"该有几个可见"再与库自己登记的个数对拉）＋ 像素探针 `tmp\visprobe\vis-probe.fl`（6 位全亮 = 63）。
   **"改前会红"的取证** = 隔离老库（`tmp\m4p\oldlab\`：老 lib ＋ 同一份样本）实跑 `exit 4102`（`kbd=6`）。

---

## 2.8 多字体档（标题 / 正文 / 说明，M4q · 2026-09-28）

> 卡 `T-20260928-223422`；拍板（用户 2026-09-28 22:34，**四句全选推荐**）＝ ① 三档 ② 栈式切档 ③ 整数档 ④ 窄口径。
> 一句话：**同一窗口里能有大小不同的文本，而从不切档的老 app 逐字节不变。**

| 档 | 名字 | 字号（相对**基准** px） | 渲染用哪块字体 | 光标/位置类字宽 |
|---|---|---|---|---|
| `0` | **标题** | 基准 **+4**（14 ⇒ 18） | `Surf.ft0` | 池 `k=2` 的实测宽 |
| `1` | **正文** | 基准 **+0**（14 ⇒ 14，**= app 现在传的 px**） | `gui_win_render` 收到的那块 `hf` | 全局 `gui_char_adv`（M4c 老路） |
| `2` | **说明** | 基准 **−2**（14 ⇒ 12） | `Surf.ft2` | 池 `k=3` 的实测宽 |

**三档一律过 `gui_dpi_scale`**：96dpi 恒等 ⇒ 本机就是 18 / 14 / 12；非 96 档 = `(基准 px + 档偏移) × dpi / 96`。
`px < 1` 夹到 14、档号越界当基准（与内核 `gui_font_push` 同口径）。

```fl
int *hf0 = gui_win_font_tier(&c, 14, 0);   // 标题：建字体 ＋ **登记该档字宽**（"档 ⇒ px"的单点定义）
int *hf1 = gui_win_font_tier(&c, 14, 1);   // 正文（不切档的 app 仍可走老的 gui_win_font_init(14)）
int *hf2 = gui_win_font_tier(&c, 14, 2);   // 说明
sf.ft0 = hf0; sf.ft1 = hf1; sf.ft2 = hf2;  // 三块句柄挂在**表面**上（字体句柄不许进全局）
...
gui_font_push(&c, 0);                      // 之后的文本按标题档画（kind 22 进命令流）
gui_label(&c, "标题");
gui_font_push(&c, 2);                      // **可嵌套**
gui_label(&c, "说明");
gui_font_pop(&c);                          // 回标题
gui_label(&c, "还是标题");
gui_font_pop(&c);                          // 回正文（基准）
```

| API（内核层 `flgui.fl`） | 说明 |
|---|---|
| `int gui_font_push(struct GuiCtx *c, int tier)` | 压一档（`0/1/2`）；返回压进去的档；**档号越界 ⇒ 当基准档 ＋ `err \|= 64`**；8 层满 ⇒ `err \|= 128` 且**不进栈**（绝不越写） |
| `int gui_font_pop(struct GuiCtx *c)` | 弹一档；返回**弹出之后**的当前档（空栈 = 1 = 基准）；**没压过就弹** ⇒ `err \|= 128` |

**口径（本刀定的契约；窄口径 = 拍板④）**：
1. **档只影响两处**：① **渲染用哪块字体**（字号）；② **光标/位置类字宽**（可编辑文本域的光标条）。
2. **`gui_text_w` 与盒内 `fit` 的布局口径一个字不动**（仍是 8px/字节）—— 老 dump 基线因此零扰动；
   要让布局跟着档走（真字宽排版/裁切）得**另立一刀**（要重录多条基线 ＋ 改三条真窗探针的硬编码坐标）。
3. **不切档 ⇒ 一条状态命令都不发**（`gui_begin` 起的档恒 = 基准）⇒ 老 app 的命令流与像素逐字节不变。
4. **命令流形状**（与不透明度 `20/21` 同族的**第二对状态命令**）：`kind 22` = 档压栈 ｜ `kind 23` = 档出栈；
   **载荷写在 `gui_cmd_w` 上 = 该命令之后生效的档号**（绝对值 ⇒ 渲染端**不需要维护档栈**）。
5. **载体（零新增全局槽）**：档态住**状态池**的伪 key `gui_hash("__flgui_font") ^ 0x464F4E54`（"FONT"）——
   `k=0` 恒 0（`gui_pool_sum` 只摘 k=0 ⇒ **POOLSUM 零扰动**）｜`k=1` = 档栈（`深度×65536 ＋ 低位每级 2 bit 的
   "档号+1"`，8 级上限 = 16 bit 正好一格）｜`k=2` / `k=3` = 标题 / 说明档的**实测字宽**（**0 = 还没量到 ⇒ 回落基准**）。
   **`GuiCtx` 一个字没动**、**零新增顶层函数以外的载体一个字没加**。
6. **每帧归零**：`gui_begin` 清档栈（忘了 pop 只影响本帧、不串到下一帧）；渲染端每帧从基准档起步 —— 两侧同口径。
7. **代价**：切档只是"再建 1~2 块字体（**建一次**，别每帧建）＋ 每帧多一次 `ui_font_use`"；不切档时渲染端
   **一次多余的 `SelectObject` 都不多花**（只在"档变脏"时才重选）。

**⚠️ 诚实边界（逐条，别当 bug）**：
- **`RestoreDC` 会把 DC 的字体一起回滚**（回到 `SaveDC` 那一刻的字体）⇒ 渲染端在**每次裁剪出栈**之后
  重选一次当前档的字体（`fdir` 标记）。这是渲染端**唯一一处"要维护状态"**的地方；判据钉在探针的
  "压档 ＋ 裁剪压栈/出栈 ⇒ 出栈后的文字仍是标题档（与不裁剪那一帧逐像素相同）"那条上，
  负对照（把那行删掉）实测：hash `1419693763 → 977959841`、墨迹宽 `81 → 70`（**掉回基准字体**）。
- **离屏层（`kind 20/21` 之间那一段是递归画的）**：进层时**继承外层当时的档**；递归**不回传**出层时的档
  ⇒ "**在层内 pop 掉层外压的档**"这种**跨层不闭合**写法，层外后续文字仍按进层前的档画
  （正常写法 = 压/弹成对；层内自己压自己弹、层外压层内不动 —— 两种形态都正确）。
- **只压档、不给 `Surf.ft*`** ⇒ 渲染回落基准字体，而光标仍按档走（**字号与光标会不一致**）—— 库不猜句柄。
- **档宽是"平均值"**（`ui_font_adv` 的口径：10 个 `M` 的总宽 / 10）：等宽字体（Consolas）下即精确值；
  换比例字体时"光标 / 裁切 / 换行"要改成**逐字符宽度表**。**中文（GBK 双字节）不适用本模型**。
- **字号判据的两把尺子分辨率不同**（实测）：GDI 的**字宽**在这套映射下**按 2px 台阶量化**
  （Consolas：px=16/17/18 的 10 字符宽全是 80、px=12/13 全是 60）⇒ 只比宽度**分辨不出 17 还是 18**；
  **文本高度 `cy` 与请求 px 一一对应**（12→12 … 18→18）⇒ "三档字号各对"必须靠 `cy` 才钉得死。
  负对照（把标题档 +4 改成 +3）实测：`cy 18 → 17` 当场红，而 `ext` 仍是 80（宽度是瞎的）。
- **无头样本量不到真字宽**（不建字体 ⇒ 池里两档宽度恒 0、光标回落基准 8）：样本 `flgui17` 判的是
  "**按档取尺子**"这条**接线**（池里的宽度由样本**注入**），**真值**由真 GDI 探针 ＋ 门里的外部裁判钉。
- **档号与控件 id 共用 512 槽池** ⇒ 撞槽概率按既有 `id % 512` 口径接受（同 M4o 焦点态那条）。
- **`gui_win_font_tier` 是新 API 名**（拍板那四句只定稿了 `gui_font_push` / `gui_font_pop` ＋ 整数档）
  ⇒ 若要改名：按"纯改名 ＋ 双端复跑 ＋ 基线逐条核"办（改名不改行为，但要重录等价门指纹）。

**📊 判据**：无头样本 `test\samples\flgui17.fl`（22 位全亮 = 4194303 → `exit 42`）＋ 真 GDI 探针
`tmp\m4q\font-tier-probe.fl`（离屏、**不建窗**；`CV … px=… ext=… cy=… delta=…` 三档对账 ＋ `TPX …` 三档
渲染摘要 ＋ 档/裁剪场景）＋ 门第 8 段 **42 条外部裁判**（PowerShell 现算期望 px ＋ **本脚本自己两次
独立 GDI 现量**）＋ "关就是真关" `tmp\m4q\run-font-classic.ps1`（老库 `b610942` vs 新库整块表面逐像素比 **12/12**）
＋ 负对照 `tmp\m4q\run-mutations.ps1`（**6/6**：删掉出栈重选 ⇒ 像素回退，档偏移改 +3 ⇒ `cy` 当场红）。
**"改前会红"取证**：隔离老库（`tmp\m4q\oldlab\`：老 `lib` ＋ **老的 `flint.exe`** ＋ 同一份 `flgui17.fl`）
⇒ **编译期就红**：`使用了未声明的变量 'gui_font_push'`。

---

## 3. 平台层 `lib\flgui_win32.fl`

### 3.1 窗口

| API | 说明 |
|---|---|
| `int gui_win_make(struct GuiWin *g)` | 建窗（ULW 图层路线：`TOPMOST｜LAYERED｜NOACTIVATE` + `WS_POPUP`）；位置/尺寸/alpha 全由调用方填。**默认档 = 纯后台**（不抢焦点），M1~M4b 的老入口，签名与行为一字未动 |
| `int gui_win_make_kbd(struct GuiWin *g)` | **键盘档（M4c 新增）**：建窗**不带 `WS_EX_NOACTIVATE`** ⇒ 真点击时由**系统**完成激活与焦点（实测够用，不必自己抢），真按键才进得来（可编辑文本域必须用这一档） |
| `int gui_win_make_tier(struct GuiWin *g, int kbd)` | 两档共用的实现（`kbd`：0 = 默认档、1 = 键盘档）。**档位走显式参数**：局部 struct 字段**不会被清零**（脏栈探针双端实测读到上一轮残值）⇒ 不允许"忘了填就当默认" |
| `int gui_win_surf(struct Surf *s, struct GuiWin *g, int radius)` | 建画布表面（32bpp DIB + ULW；`radius` = 圆角半径，`0` = 直角） |
| `int gui_win_proc(...)` | 共享窗口过程：只做必须由消息驱动的三件事（WM_PAINT 派发 + ValidateRect ／ WM_ERASEBKGND 返回 1 ／ WM_SETCURSOR） |

`struct GuiWin` 字段：`hwnd`、`cls`（类名）、`x/y/w/h`、`alpha`（整窗常量透明度 0..255）、`down_prev`、`ok`、`frames`、`kbd`（档位，**由建窗函数写死**）。

⚠️ **两档的唯一变量 = 建窗扩展样式**（`0x08080008` 默认档 / `0x00080008` 键盘档）：**必须在建窗时定**
—— 运行时 `SetWindowLongA(hwnd,-20,...)` 改它**无效**（M4c 实测：三个探针变体全白跑）。
⚠️ **键盘档要成事，就两件事**（M4c 实测定稿）：① 建窗不带 `NOACTIVATE`（否则窗口无法激活、真按键进不来
—— 这一条也就替代了"点击自己 `SetForegroundWindow`/`SetFocus`"：真点击时系统会完成激活与焦点）；
② **字符翻译走平台层库内 US 表（按扫描码，不碰 VK/IME）**，见 §2.5 顶部那条红字与 §3.2。
⚠️ **导入预算**（真 flint `MAX_IMPORTS = <!--fact:limit-imports-->96<!--/fact-->`，**含槽 0 `ExitProcess`**；另有一条 `MAX_GROUPS = <!--fact:limit-groups-->8<!--/fact-->` 的 **DLL 组数**上限）：`m2_float` 那条 include 链**最紧**。
- **实测账（`objdump -p` 数产物导入表）**：M4c 加 `MapVirtualKeyA` 后 **94/96**；M4d 加 `GetTickCount` ＋
  `MsgWaitForMultipleObjects` 后 = **95/96**；**M4e 加 `DwmFlush`（`dwmapi.dll`）后 = 96/96 —— 满格**（当轮读数；⚠️ **2026-10-15 复测 = 条目 <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->、模块 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact-->，模块位仍顶格**），
  且 `dwmapi` 占满**第 8 个 DLL 组**（两组上限**同时见底**）。2026-09-27 用户拍板「现在就花」（换"144fps 跟屏"这条通道）。
- 🔎 **对后续开发的影响（2026-09-27 用户问，写在这儿免得重算）**：**再想"多用一个 Windows 函数"或"多用一个 DLL"，
  `m2_float` 这条链就会编不过**（⚠️ **2026-10-15 复测**：条目侧尚有余量 = <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->，**真正顶格的是模块位 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact-->**；症状：`PE 打包失败: 导入函数总数超过上限 96` / `导入模块超过 8 个`；
  注意 `flgui_demo` 链条小、**照样编得过**，别只看 demo 就放心）。三条出路，按代价从低到高：
  ① **腾格子**：删掉链上不再需要的声明（先 `objdump -p <产物>` 数、再看哪些真被调用）——零风险、首选；
  ② **抬上限**：改 `src\pe.c` 的 `MAX_IMPORTS` / `MAX_GROUPS`（**编译器侧改动，要重建 flint.exe 并单独过总门**）；
  ③ **运行时解析**：`GetModuleHandleA` ＋ `GetProcAddress` 各 1 格（现在也没有余量）⇒ 之后任意 DLL/任意函数都不再吃预算
  （代价：调用点自己存函数指针、失去编译期检查）。
  ⚠️ 另一条结构性缓解：**预算是"最终二进制"的账** —— 低频功能放**独立 helper 进程**（架构上的"进程级集成"）
  就各自带一份 96 格；只有"每帧都要用"的才值得静态缝进同一条链。
- 🔬 **同名声明到底占几格（2026-09-26 受控探针订正）**：`tmp\dup_api.fl`（同签名同模块声明两次）产物 = **3 条**
  （ExitProcess + GetTickCount + Sleep）；`tmp\dup_api3.fl`（同签名、**模块名不同**）同样 **3 条**；
  而 `tmp\dup_api2.fl`（同名**签名不同**）**编译期直接报错**（`API 'X' 重复声明但签名不一致`）。
  ⇒ **同一个导入名无论声明几次都只占一格**；⇒ **09-23 那条"导入表按声明条数计、同名不合并"的旧笔记已作废**
  （很可能当时是**签名不同**或**不同名字**的实例被误读了）。真实应用复核：`m2_float` 链里 `GetTickCount`
  被声明 3 处（`main.fl` / `hw.fl` / 本层）⇒ 产物导入表里**只有 1 条**。
  ⇒ **复算预算的姿势 = `objdump -p <产物>` 数条目**，别按"声明条数"心算。
- **顶爆的症状** = `PE 打包失败: 导入函数总数超过上限 96`，而且**只在 `m2_float` 那条链上先炸**
  （`flgui_demo` 链条小、照样编得过 —— 别只看 demo 编过就当没事）。
- ⇒ **以后往 `flgui_win32.fl` 里加 api 声明前先看这个预算**（每加一个**新名字**才是真花一格）。
⚠️ 键盘档窗口**可被激活** ⇒ 是否会进任务栏**未收口**（C# 参考浮窗同样没有 `WS_EX_TOOLWINDOW` 却不上任务栏，机制未定）。

⚠️ **类名每进程只注册成功一次**（`RegisterClassA` 的语义）⇒ 第二个窗口必须换一个类名（各 app 现在靠不同名字躲）。
⚠️ **多窗口/多上下文未做**（M4 拍板推后，见 §5）：现结构是**一个共享 WNDPROC + 无 user data = 单上下文**。

### 3.2 消息泵与输入

| API | 说明 |
|---|---|
| `int gui_win_pump(struct GuiWin *g, struct GuiInput *in)` | 泵一步：返回 0 = 收到 WM_QUIT；**滚轮在这里"清零 + 累加"**（`WM_MOUSEWHEEL` 的高 16 位带符号 ÷120） |
| `int gui_win_input(struct GuiWin *g, struct GuiInput *in)` | 每帧采一次：客户区光标 + 左键 down/pressed/released（轮询 `GetAsyncKeyState`）＋ 键盘三键的**按下沿兜底轮询（仅默认档；键盘档必须关，见 §2.5 第 4 条）**；**M4d：本帧时间戳 `in->ms = GetTickCount()` 也在这里填**（全库唯一取时点） |
| `int gui_win_wait(int ms)` | 底层等待（`MsgWaitForMultipleObjects(0,0,0,ms,QS_ALLINPUT)`）：队列里**没有**输入才等到超时，**有键/鼠标/消息立刻醒**。⚠️ **M4e 起 app 不该直接调它**（固定等待值会在粒度变化时翻车，见下一条）；要"等完这一帧"用 `gui_win_frame_wait` |
| `int gui_win_frame_wait(struct GuiCtx *c)` | **M4e：唯一"等完这一帧"入口**（每帧上屏之后调一次）。按 `c.frame_fps` 档位限速：**0 = 不限速**（立刻返回 0）｜**≤66fps**：现场标定定时器粒度 → 把目标周期折成"几格" → 等 `(格数−1)×格 + 1` ms（返回 1）｜**>66fps**（周期 <15ms）：`DwmFlush()` 跟屏幕合成节拍（返回 2）｜上一帧已晚两格以上：本帧不再补等（返回 3，掉帧不补偿）。全程**不空转**（请求值 ≥1ms） |
| `int gui_win_drag_begin(struct DragSt *d, struct GuiWin *g, int my)` | **M4m：窗口拖动 · 按下**。`my` = 客户区 y（给 `in->my`）。**只在顶栏 `my ∈ [0,24)` 里开拖**（返回 1 = 已拖）；同位置 **400ms 内**第二次按下 ⇒ **双击**（`ShowWindow` 最大化/还原，返回 2，不进拖动）；顶栏之外/参数越界 ⇒ 返回 0（不动 `d`）。拖动用 `ui_lib` 的 `ui_drag_begin`（`SetCapture` ＋ 记光标与窗口原点）⇒ **零新导入** |
| `int gui_win_drag_frame(struct DragSt *d)` | **M4m：窗口拖动 · 每帧**。返回 1 = 本帧真的在拖（`MoveWindow` 跟手）；**每帧查物理左键兜底** ⇒ 一松手立刻 `ui_drag_end`（返回 0）—— 快拖出窗口、松手消息落到别的窗口也**不自走**。**最大化窗口上"按住不动"返回 0 且什么都不做**（见下面那条真缺陷） |
| `int gui_win_drag_end(struct DragSt *d)` | **M4m：窗口拖动 · 抬手**（`in->released == 1` 那一帧调；重复调用安全，只清标志 + `ReleaseCapture`） |

**窗口拖动的主循环口径（M4m，三行，顺序有讲究）**：

```c
if (in.pressed == 1)  { gui_win_drag_begin(&dg, &g, in.my); }   // 只有顶栏里的按下会真的开拖
if (in.released == 1) { gui_win_drag_end(&dg); }               // 抬手先收尾
gui_win_drag_frame(&dg);                                       // 每帧跟手（内含物理左键兜底）
```

⚠️ `struct DragSt dg` 是**局部 struct，不会被清零** ⇒ **循环前必须 `dg.on = 0;`**（脏 `on` 会让每帧乱移窗口）。
⚠️ **拖动不碰 `GuiCtx`**：这组函数只收 `DragSt` ＋ 窗口句柄 ⇒ **命令表一个字节都不动**
（无头机械证据：`test\samples\flgui13.fl` 的"同帧两套拖动状态下命令表逐字段相同"）。
⚠️ **`WM_LBUTTONDBLCLK` 用不上**：FLGUI 的窗口类 `style = 0`（没有 `CS_DBLCLKS`）⇒ 系统压根不发那条消息；
双击是**库内自己计时**判的（400ms ＋ 位移 ≤4px）。连点第三下**不**再判一次双击（双击后清时刻）。
⚠️⚠️ **M4m 复核修掉的两处真缺陷（2026-09-28，独立复核抓到"双击还原 flaky：3 跑 2 败"，已复现＋已修）**：
  根因是**同一个采样缺口的两副面孔** —— `gui_win_input` 的按下/抬起是**每帧采一次**（`GetAsyncKeyState`），
  而最大化之后每帧要处理 2M 像素的 alpha ＋ 推 8MB ULW ⇒ 首帧/过渡帧可以长到几百 ms，
  **一次"按下—抬起"有可能整个落在一个帧里**（那个沿就永远看不见）。于是：
  ① **按住不动也会把最大化窗口拖走**：最大化窗口上按下顶栏会 `ui_drag_begin`，锚点 = 最大化矩形原点 `(0,0)`；
     若这一帧照常 `ui_drag_frame(d)`，`MoveWindow(0+Δx, 0+Δy, 面板宽, 面板高)` 会把窗口**光按住不动**就搬到
     `(0,0)` 并缩回面板尺寸（实测形态 **`0,0 420x260`：尺寸对、位置错**）⇒ 现在的规则：**最大化 ＋ 光标没动 ⇒ 直接返回、什么都不做**。
  ② **双击还原之后残留的拖动令牌会把窗口拉回去**：抬起沿被漏采 ⇒ 上一次拖动的令牌（含 `(0,0)` 锚点）活着；
     双击还原（`SW_RESTORE` ＋ 按自己记的原矩形 `MoveWindow`）之后，残留的 `gui_win_drag_frame` 又把它拖回 `(0,0)`
     ⇒ 现在的规则：**双击分支第一件事就是 `ui_drag_end(d)`**（无论最大化还是还原，都不许再有拖动活着）。
  📊 **取证**：病因帧迹（`tmp\m4m\gal-dbg.exe` 的 `EV` 行）显示 `EV F ... wx=0`（锚点来自最大化窗口）＋
  `EV W rect=0,0,420,260`；定向复现脚本 `tmp\m4m\stale-drag-probe.ps1`：**修前 8 次里 1 次 `BUG -> 0,0 420x260`**、
  **修后 12 次 0 次**（全程只有"保持不变/最大化"两种正确结果）。
  ⚠️ **仍未收口的（诚实边界）**：**轮询模型天生看不见"短于一帧的按下—抬起"** —— 上面两条只保证
  "漏采不会把窗口弄坏"，**不保证**每一次双击都被认出来（极慢帧下双击可能整个丢失）。
  要彻底收口得把双击检测挪到**消息层**（窗口过程收 `WM_LBUTTONDOWN`，并用"同一次 pump 里收到第 2 条"判双击）
  —— 那是**另一张卡**（涉及 `gui_win_proc` 与消息参数取值的语言级纪律）。
⚠️ **判据口径（同日按复核要求改）**：真鼠标拖动不许"跑一次就算过" —— `apps\ui_gallery\drag-probe.ps1` 现在
  **每轮重启 app ＋ 把窗口 `MoveWindow` 复位到本轮自己的起点（每轮不同）＋ 全部检查等状态而不是等固定时间**，
  **验收 = 连跑 5 轮全绿**（实测 35 轮全绿）；另加一条"还原后 +700ms 还停在原矩形（残留拖动不许拉回去）"。

**`TrackMouseEvent` / `WM_MOUSELEAVE` 那条欠账的结论（2026-09-28，M4m 收口，不再两可）：不补，用每帧轮询兜底。**
① 本库的悬停/按下**本来就是每帧轮询重算**的（`gui_begin` 每帧 `hot = 0` 后按 `mx/my` 重新命中）
⇒ 没有"靠消息维持的悬停态"，也就没有 `WM_MOUSELEAVE` 要治的病；
② 拖动的收尾不靠 `WM_LBUTTONUP`（`gui_win_drag_frame` 每帧查物理左键）⇒ 消息丢没丢都不影响结果；
③ **导入预算是硬账**：`m2_float` 链条目 **<!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->**、模块 **<!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact-->（模块位满格）**⇒ 不留着最后一格去买一个**不消费**的消息。

`struct GuiInput`：`mx`、`my`、`down`、`pressed`、`released`、`wheel`、`key`、`ms`（本帧时间戳，毫秒）。

⚠️ **纪律（2026-09-22 真 bug）**：一个"每帧量"的**清零与累加必须在同一个函数里**。
原先"清零"在 `gui_win_input`、"累加"在 `gui_win_pump`，而 app 循环是**先 pump 后 input** ⇒ 累加完立刻被清零
⇒ **真鼠标滚轮从来没生效过**；而门看不见，因为样本走**脚本化输入**、绕过了平台层。
⇒ 两条：① 谁累加谁清零（清零点在累加之前）；② 平台层/外部接口必须另有一条**真输入**判据
（`apps\ui_gallery\wheel-probe.ps1`：真滚轮事件；**M4m 起一格 = `c.wheel_step`，默认 60px**，底部夹到 `maxoff`）。

#### 3.2.1 Shift 态：**消息驱动**，不是"读到 Tab 那一瞬间去轮询"（M4o，2026-09-28）

🔴 **本刀真按键探针抓到的一笔真缺陷（Tab 导航把它暴露出来）**：`gui_win_pump` 是**一批一批**取消息的
（`while (PeekMessageA(...))`）—— 一次 pump 里可能同时拿到「Shift 按下 / **Tab 按下** / Tab 抬起 / Shift 抬起」四条。
若在处理 Tab 那一条时去**轮询物理键态**（`GetAsyncKeyState(16)`），读到的已经是"Shift 早就抬起来了"
（探针实测 `raw=1`：只有"自上次调用后被按过"的低位，**高位 = 0**）⇒ **Shift+Tab 被当成 Tab**
（实测：焦点从 0 **前进**到 1，而期望是反向回绕到 4）。

⇒ **正解：方向从消息流里记**（`struct GuiWin.shift`）：
· `WM_KEYDOWN` 里按扫描码反查 VK，`k == 16 / 160 / 161` ⇒ `g->shift = 1`；
· `WM_KEYUP(0x0101)` 里同样反查，`k == 16 / 160 / 161` ⇒ `g->shift = 0`；
· 判据函数 `gui_shift_down(g)` = **消息流优先 ＋ 物理轮询兜底**（后者只覆盖"起窗那一刻 Shift 就已经按着"）。
⚠️ **同族的第二笔**（探针实测）：`keybd_event` 注入的键**扫描码可以是 0**（本项目账本 `Z=` 栏就数得到），
而 `MapVirtualKeyA(0,1) = 0` ⇒ **清态那一支也必须退回 `m.wparam`**（与 `WM_KEYDOWN` 那两行同一条口径）——
少了它 `g->shift` **永远清不掉**，症状 = 下一次单独的 Tab 又被当成 Shift+Tab（实测 idx 4 → 3，而期望回绕到 0）。
⚠️ 同一处 Shift 判据也用在**键盘档字符翻译**（上档符号/大写）上 —— 那条路原本读的也是 `GetAsyncKeyState(16)`，
**同一个竞态**（批处理把 Shift 抬起也一起取了）⇒ 本刀一并改走 `gui_shift_down`。
📊 判据 = `apps\flgui_demo\tab-probe.ps1`（真按键 9/9 全绿；**改前会红**：Shift+Tab 那两条当场 FAIL）。

### 3.3 字体

| API | 说明 |
|---|---|
| `int *gui_win_font_init(int px)` | 建字体（`CreateFontA`，Consolas）；**句柄由调用方存局部变量**、传进 `gui_win_render`。**不切档的 app 继续走它，行为一字未改** |
| `int *ui_font_use(int *dc, int *hf)` | 把字体选进 DC（每帧都要选一次：**字体是 DC 的状态**，不是进程级） |
| `int *gui_win_font_tier(struct GuiCtx *c, int px, int tier)` | **M4q**：按档建字体（`px` = **基准** px；档偏移 ＋4/＋0/−2 在函数内加、**一律过 `gui_dpi_scale`**）＋ 用 GDI 量一次字宽并**登记**（档 1 ⇒ `gui_char_adv`；档 0/2 ⇒ 状态池 `k=2`/`k=3`）。见 §2.8 |
| 字段 `Surf.ft0 / ft1 / ft2` | **M4q**：三档字体句柄（**0 = 这档没建字体 ⇒ 渲染端回落给 `gui_win_render` 收的 `hf`**）。`surf_init` 显式清 0（局部 struct 字段不清零）；渲染端**只在命令流里出现 `kind 22/23` 时才读它** |

⚠️ **不能把字体句柄缓存在全局**（M4 实测，真 flint 硬拒）：
`int gui_hf = 0; ... gui_hf = ui_font_make(px);` ⇒ 报「**地址值（64 位）不能装进全局 int / char 变量**」
（该标记跨函数传播，抽 helper"洗值"也躲不掉）⇒ 句柄只走**局部 `int *`**。
⚠️ 字体**建一次**就够（反复 `CreateFontA` 不回收会累 GDI 对象 —— ui_lib 那次泄漏真事故的同类风险）。

### 3.4 DPI

| API | 说明 |
|---|---|
| `int gui_win_dpi()` | 读本机 DPI（`GetDeviceCaps(screenDC, LOGPIXELSX)`；失败返回 0） |
| `int gui_win_dpi_apply(struct GuiCtx *c)` | 读回并写进 `c.dpi`（返回写进去的值） |
| `int gui_dpi_scale(struct GuiCtx *c, int v)` | 纯整数换算（内核层，见 §1.9） |

**口径（M4 拍板）**：只做"**纯函数换算 ＋ 96dpi 真窗口对照**"，**不引 per-monitor v2**（不做 manifest、
不处理 `WM_DPICHANGED`）—— 本机 96dpi 下零收益，那套要改窗口创建与消息处理。判据：真窗口读数 = 96 且
`gui_dpi_scale` 恒等（`gui_win_dpi()` 实测 96）；非 96 档的换算由 `test\samples\flgui4.fl` 无头钉住（120/144 两档 + 负数）。

### 3.5 渲染与上屏

| API | 说明 |
|---|---|
| `int gui_win_color(struct GuiCtx *c, int kind)` | 命令 kind → 颜色（`gui_cmd_col != 0` 时文本用显式色） |
| `int gui_win_render(struct Surf *s, struct GuiCtx *c, int *hf)` | 遍历命令表画进内存 DC（填充走 **DC_BRUSH**：`GetStockObject(18)` + `SetDCBrushColor` ⇒ 每帧零对象创建）。**3 参数版 = 不启用离屏层**（语义 = M4h） |
| `int gui_win_layer(struct Surf *lay, struct Surf *s)` | **M4i**：应用侧建"离屏层表面"（几何跟随主表面；建一次每帧复用） |
| `int gui_win_render_layered(struct Surf *s, struct GuiCtx *c, int *hf, struct Surf *lay)` | **M4i**：4 参数渲染 ⇒ **启用离屏层**（`kind 20/21` 之间整段先画进离屏 DIB，再整块按层 alpha 混回，**文本也跟着淡**） |
| `int gui_win_show(struct Surf *s)` | 写 alpha（预乘）→ ULW 上屏。**M4m 起先做一步"表面尺寸同步"**：`GetWindowRect` 读窗口当前尺寸（夹到 `bw/bh`）写回 `cw/ch` ⇒ 窗口被**外部**改尺寸（最大化/还原）时才画得出来；老 app 的窗口尺寸从不被外部改 ⇒ 这一步是**恒等变换、像素逐字节不变** |

⚠️ **表面 DIB 留"屏幕大小"的余量（M4m）**：`gui_win_surf` 现在按 `max(面板尺寸, 主屏分辨率)`
分配 DIB（`cw/ch` 仍是面板尺寸）。**为什么必须留**：`surf_flush` 走 ULW 且 `psize = cw×ch`，
而 **ULW 会按 `psize` 重设窗口尺寸** —— 2026-09-28 实测（`tmp\m4m\winmax-probe.fl`）：
`ShowWindow(SW_MAXIMIZE)` 后窗口 1920×1080，**下一帧 ULW 立刻把它顶回 420×260、只留下位置 (0,0)**
⇒ 表面没有余量，"双击顶栏最大化"根本长不大。代价：本机 1920×1080 ⇒ **≈ 8.3MB/表面**
（DIB 是虚拟内存、按需提交；带离屏层的 app 有两块）。

⚠️ **GDI 纪律**：一律不 `CreateSolidBrush` 每帧建画笔（那会每秒涨几十个对象，窗口活不过两分钟）；
填充用 DC_BRUSH，只读文本字段用 `ui_font_use` 复用同一句柄。

---

## 4. 两个 dogfood（真项目用着它）

| 应用 | 用到的层 | 判据 |
|---|---|---|
| `apps\flgui_demo` | 全三层（label/button/checkbox/slider/scroll/popup/**可编辑文本域**）＋ **M4i 起右键菜单整段淡入（离屏层，真窗专有）** | `test\flgui-verify.ps1` 里 `dump.on` 无头 dump（346 行）+ 真窗人工看 |
| `apps\ui_gallery` | 控件层（换掉老的 `ui_*`）＋ **M4j 起整套现代 UI · 蓝白主题（`gui_theme_light_blue`）** ＋ **M4m 起窗口拖动（顶栏 24px）/ 双击顶栏最大化** ＋ **M4n 起本批美术的可见演示**（勾选框 `box_w = 16` 放大 / 一对单选钮 / 进度条 / 滑块 / 可编辑文本域，都在左列空闲区 `y ≥ 110`，老坐标一字未改） | `apps\ui_gallery\mouse-test.ps1`（真鼠标 4/4）+ `wheel-probe.ps1`（真滚轮 **7/7**，M4m 起一格 = 60px）+ `drag-probe.ps1`（**M4m 新加**：真拖动 5/5，M4n 复跑 **8 轮 64/64**）。**M4n 的观感交用户本人看**：跑起来点勾选框（看 ✓）、拖滑块（看圆形拇指）、点 OPT-A/OPT-B（看圆环与内点、互斥）、点底下的文本框（看点进去后的 1px 焦点圈） |
| `apps\m2_float` | 只换**绘制/容器**层（浮窗行绘制，控件仍走 ui_lib） | `test\loop-verify.ps1`（9/9，dump 逐字节） |

---

## 5. 口径与已知限制（**读之前先读这一节**）

1. **文本宽度是近似**：`gui_text_w` = **每字节 8px**（GBK 汉字 2 字节 ≈ 16px）。
   好处 = **双端逐字节可对账、无浮点、无 GDI 依赖**（无头样本与真窗共用一条布局代码）。
   误差 = 与真字体度量（`GetTextExtentPoint32A`，本层已有该 api）**在字形窄/宽时会有几 px 偏差**；
   **要让布局与真字宽严格一致**，得换成真度量，**代价**：现有 4 条 dump 基线 + 画廊的硬编码坐标全变，
   必须按"口径变更"整批重录 ⇒ **M4 拍板：保留 8px/字节，把误差写清在这里**（等真有中文排版需求再换）。
   **🔸 2026-09-23 分家（本次修）**：**光标条**已改用**实测真字宽** `gui_char_adv` —— 因为上面那点"几 px 偏差"
   在**逐字累加**下会变成用户看得见的"光标不准"（实测每字偏 1px，打满 18 字节偏 ~18px ≈ 2.6 个字位）。
   **布局宽度（`gui_text_w` / 编辑框 `fit`）仍按 8px/字节**（D-d 保留）⇒ "文本裁切 / 盒宽"与真字宽**仍有**
   已知偏差（160 宽盒：模型 18 字符 vs 真实可放 ~21）。要不要**整体换真度量**（代价 = 4 条 dump 基线 +
   画廊硬编码坐标全变）**待拍板**；当前选择 = 只修位置类（光标），基线只差 demo 的两行 `kind=15`。
2. **多窗口/多上下文未做**（M4 拍板**推后**）：现结构是"一个共享 WNDPROC + 无 user data" = **单上下文**；
   `RegisterClassA` 的"每进程每类名只成功一次"意味着第二个窗口必须换类名。
   要做真多窗口，需要动的地方（**不是加个参数就行**）：① ID 池与命令表要么**按窗口分片**、要么带窗口 id；
   ② 消息分发要知道"这条消息属于哪个 ctx"（`GWLP_USERDATA` 是探针验过的门路）；③ 输入/hot-active 要按窗口隔离；
   ④ 每个窗口各自一个 `Surf` 与字体档。**当下 3 个 app 都单窗口 ⇒ 零收益**，故推后。
3. **可编辑文本域已做**（`lib\flgui_edit.fl`，见 §2.5）；**中文 IME 仍未做** —— 现在的口径是：
   只认可打印 ASCII（32..126），字符由**平台层库内 US 表按扫描码**翻出来（键盘档）／系统的 `WM_CHAR`（默认档）。
   ⚠️ **输入语言是中文时（IME 在跑），键盘档反而更可靠**：老路子（`TranslateMessage`/`ToAscii`）在 IME 接管下
   会整个失灵（`wParam` = `VK_PROCESSKEY`），库内表不受影响；见 §2.5 顶部红字。
   ⚠️ **IME 在本窗口里目前是"绕过"而不是"支持"**：键会被 IME 先吃掉（我们靠扫描码把字符救回来），
   输入法自己的组合/候选窗不归我们管。要真支持中文输入，得处理 `WM_IME_*` 那套 + `ImmGetContext` 系列
   （另开卡）；也可以反过来 `ImmAssociateContext(hwnd, 0)` 把 IME 从这个窗口踢开（**用户可见行为，须拍板**）。
   ✅ **真键盘那条路的自动判据已收口（M4c）**：`apps\flgui_demo\kb-probe.ps1` 重写过 —— 账本走 **stdout 追加行**
   （不再"每帧覆写文件"）、判据**等期望状态**而不是单次采样、**按字段名解析**、点击坐标由 app 自打的 `BOX` 行＋
   真窗口矩形算出。判据含"点框聚焦 / 打字 `ok` 进盒子 / 退格删一个 / 回车提交且文本保留"四步，**7/7 全绿**。
   （旧版的坑记一笔：它把 `focus` 编成 `focus+10` 写进定长记录，而探针用 `F=(\d+)` 去抓 ⇒ **focus=0 永远匹配不到**，
   那条判据**结构上不可能通过**。）
4. **输入是轮询式**（光标与左键 `GetAsyncKeyState`，一帧一次）：理论上短于一帧的极快点击会丢（人手点击远长于一帧，
   但这是**口径缺口**）。要有"消息驱动记 down/pressed + 轮询兜底"，得在 `gui_win_proc` 里记状态
   —— 注意：`WM_LBUTTONDOWN` 的参数是"装过地址的值"，**不许落全局 int**（语言硬规则），载体只能走结构体字段/局部。
   （键盘那三个编辑键已经这么做了：消息驱动 + 按下沿轮询兜底，见 §2.5。）
5. **圆角与控件描边（M4k 起，两档）**：① **表面层**圆角 = `gui_win_surf(radius)` 的掩码（M4 老机制，未变）；
   ② **控件层**圆角 ＋ 描边 = **渲染端按 `c.theme_radius` 决定画法** —— `theme_radius > 0` 时"盒类"命令
   （面板/按钮三态/勾选框块/进度条底/文本域盒）走**圆角填充**，其中**按钮三态与文本域盒**再补 **1px `theme_border` 描边**。
   ⚠️ **为什么不是"控件层补发描边命令"**（开工清单原来的写法）：那会让**命令条数与下标全变 ⇒ 11 条 dump 基线整批重录**；
   渲染端做这件事**命令流一个字节没动**（FLGUI 门 56/56 里 13 条 dump 基线全绿就是证据）。让步只有一条：
   **描边/圆角算"渲染风格"，由主题单点管**（不是控件自己发命令）。
   ⚠️ **`theme_radius = 0`（深色默认）= 经典档**：下面那些函数**一次都不进**，与 M4 及以前逐像素同形。
   📊 **实测**（40 个按钮、同进程 QPC、3 轮取最小）：现代档 **771µs** vs 经典档 **151µs**（≈ +15.5µs/按钮 ——
   1px 描边圈 ＋ 4 个角块逐像素）。判据 = `tmp\roundprobe\round-probe.fl`（6 位全亮）。
   ⚠️ **代价的根因**：圆角/描边只能逐像素（零新导入的必然结果 —— GDI 的 `RoundRect` 会让最重链逼近上限：条目 <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->，而模块位 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact--> 已是真正的墙）。
6. **容量上限**（§1.0）：命令表 256 条/帧、状态池 512 槽、arena 4096 字节、裁剪 8 层、滚动/弹层 4 层嵌套。
   超限**只计数不崩**，但命令/字节会被丢 ⇒ dump 里的 `over=` / `textover=` 必须为 0。
7. **时间与帧节拍（M4d 时间注入 ＋ M4e 帧率档位）**：① **时间由平台层注入**（`gui_win_input` 的 `GetTickCount()` 是全库唯一取时点），
   **内核不取时** —— 理由与做法见 §1.8 末的红字；② **"等完这一帧"只有 `gui_win_frame_wait(c)` 一个入口**（M4e）：
   app 里别再用 `Sleep(16)`，也别再写死 `gui_win_wait(16)`；③ **帧率是"档位"不是常数**：`gui_frame_set(c, fps)`
   （**默认 60**／`0` = 不限速／负值夹 0／上限 1000），周期由 `gui_frame_ms(c)` 换算（整数除法：60→16ms、144→6ms）；
   ④ **两种后端**（按目标周期选，这就是"更高帧率留好通道"的那条通道）：**≥15ms（≤66fps，30/60 档）**走
   "**现场标定定时器粒度 → 把目标周期折成几格 → 等 `(格数−1)×格 + 1` 毫秒**"（**零系统副作用、零新导入**）；
   **<15ms（>66fps，90/144 档）**走 `DwmFlush()` **跟屏幕合成节拍**（本机屏 144Hz ⇒ 实测 **6.94ms、抖动 ±0.6ms、CPU 2.3% 单核**）。
   ⑤ ⚠️ **`Sleep`/`MsgWait` 的取整会"多跨一格"**：要 16ms 得到 31.2ms、要 33ms 得到 46.8ms ⇒ 请求值必须写成
   `(k−1)×格 + 1`（实测：写成"目标周期 − 已用时间"时，30fps 档只有 22fps —— 3 格）；
   ⑥ ⚠️ **固定 `wait(1)` 是错的**（2026-09-27 实测：别处把粒度抬到 1ms 时，同一份代码变成 **2.38ms/帧、420fps、26% 单核空转**）
   ⇒ 等待量**永不为 0**（下限 1ms，天生不空转），且**按档位算**、不写死；粒度细到 1ms 时同一个式子自动变精确（60fps ⇒ wait(16)）。
   📊 **实测档位表**（真窗、QPC 计时、每档 300 帧；探针 `tmp\frames\limit-probe.fl`）：`0`→1.25ms（≈798fps，41% 单核）｜
   **`30`→30.8ms（32.5fps）**｜**`60`→15.37ms（65fps）**｜`45`→15.4ms（就近吸附一格）｜`90`→6.94ms（**跟屏 144**）｜`144`→6.94ms（144fps、2.3% 单核）。
   ⚠️ **诚实边界**：15.6ms 粒度下"等待后端"只能给出**格的整数倍**（15.6/31.2/46.8ms ⇒ 64/32/21fps）⇒ 30 档实际 32.5fps、
   90 档在 144Hz 屏上实际按 144 跑；**要"精确 90"只能走 `timeBeginPeriod(1)`**（系统级副作用、+1 导入，**本刀未做**，作为通道留着）。
8. **不透明度（M4h）＋ 离屏层（M4i）**：命令级、**3 参数版只作用于填充类命令** —— ① **文本不吃 alpha**（GDI 写的字没法逐命令混合）；
   ② "整段（含文本）一起淡" ⇒ **M4i 已做离屏层**（§1.4.2，走 **4 参数版**：整段先画进离屏 DIB、再整块按层 alpha 合成一次
   ⇒ **文字跟着淡**；3 参数版仍是本条这个边界）；③ 实现是**软件混合**
   （零新导入 —— 最重链条目 <!--fact:imports-m2float-->90<!--/fact-->/<!--fact:limit-imports-->96<!--/fact-->、模块位 <!--fact:modules-m2float-->8<!--/fact-->/<!--fact:limit-groups-->8<!--/fact--> 已顶格），实测 **≈29 ns/像素混合**；④ `kind 20/21` 已进命令流当
   **层的边界标记**，但渲染端对它们**无状态**（生效值在每条命令的 `gui_cmd_a` 里）。详见 §1.4.1。
9. **⚠️ M4k 轮修掉的一笔真 bug（通道序）**：直写像素那条路（M4h 的 `gui_win_blend` ＋ M4k 的 `gwb_put`）**把 R/B 写反**了 ——
   **COLORREF = `0x00BBGGRR`（低字节才是 R）**，而 **DIB 32bpp = BGRA（低字节是 B）**，原实现把"低字节"直接写进 DIB 的**第一个字节**
   ⇒ **同一个颜色，GDI 路与直写路显示成不同的色**（R/B 对调）。**M4h 起就在，到 M4k 才被抓到** ——
   原因很实在：**既有判据全用灰阶色**（`0x101010` / `0x202020` / `0x404040`），灰阶上 R/B 对调**不可见**。
   判据 = `tmp\chanprobe\chan-probe.fl`（4 位：GDI 路按规范序 / 直写路与 GDI 逐字节相同 / 半透明混合同序 / 描边同序）。
   ⇒ 教训：**"两条写像素的路必须给出同一个颜色"要用三通道互不相等的颜色去测**（灰阶测不出来）。
10. **盒类投影 / 层次（M4l 起，单点 `theme_shadow`）**：`theme_shadow > 0` 时渲染端在**面板/弹层（kind 1）**命令**之前**
    画一圈**按距离分层**的黑色影环（外扩 `blur = 4` px、向下偏 `dy = 2` px、`alpha(d) = theme_shadow × (blur + 1 − d) / blur`）。
    ① **环与环不重叠**（第 d 层 = "外扩 d 的形状" 减 "外扩 d−1 的形状"）⇒ 同一点不会被混合两次（M4k 圆角那条纪律）；
    ② **只给 kind 1（面板/弹层）**：按钮/勾选框逐个投影会让每帧多出几万次逐像素写（40 个按钮实测），而"层次"的观感主要来自卡片/菜单浮起；
    ③ **`theme_shadow == 0`（深色默认）= 关** ⇒ 那段函数**一次都不进**，与 M4 及以前逐像素同形（老 app / 老探针零扰动）；
    ④ 影的 α 与命令 α `a` 相乘（层内淡出时影跟着淡）；裁剪由 `gwb_put` 自己算（直写像素吃不到 DC 裁剪区）；
    ⑤ 影**不依赖圆角**（`theme_radius = 0` 的经典档也吃影，只是环变直角）。
    📊 **实测**（8 个面板、真窗、同进程 QPC、3 轮取最小）：开影 **672µs** vs 关影 **116µs**（≈ **+70µs/面板**；
    同尺子的圆角档对照 = 40 个按钮 **776µs** vs 经典 **152µs**）。判据 = `tmp\shadowprobe\shadow-probe.fl`（6 位全亮）。
11. **输入灵敏度（M4m，两把旋钮 ＋ 一条拖动 ＋ 一条放宽）**：用户 2026-09-28 拍板"全选推荐项"。
    ① **滚轮步长 `c.wheel_step`**：**默认 60 = 3 行/格**（`gui_init` 里给）。只在**一处乘法**里用：
       `off = off − wheel × wheel_step`（M4m 之前写死 20）。`0` = 滚轮不动；负值 = 反向（不夹取，调用方自负）。
       ⚠️ **与拍板措辞的差别（明写，别当成漏做）**：拍板原话是「**3 行/格 = 3 × `line_h`**」，而实现里是
       **常量 `60`**，**不是** `c.line_h * 3`。理由：`gui_init` 的 `line_h = 14` 是 **label 行高**（排版口径），
       拍板时口径里的"20px 一行"是**控件行高**（`btn_h = 20`）—— 两者不是同一个数；`line_h * 3` 会给出 **42**
       而不是拍板写明的 **60**。⇒ 取常量 60 与拍板的数字一致；**要"步长跟 label 行高走"就在 app 里显式写**
       `c.wheel_step = c.line_h * 3`（字段就是那个旋钮，谁调谁变）。
       ⚠️ **改这个默认值会动到两个老样本**：`flgui3` / `flgui5` 的账本写死"一格 = 20px"（`0/20/40/maxoff`），
       所以这两处**显式钉回 `c.wheel_step = 20`**（被测语义一字未变）；**新默认 60 的契约在新样本 `flgui13`**。
       📊 **"改前会红"取证**（去掉那两行钉住 = 走新默认 60）：`flgui3` 退出码 **67106815**、`flgui5` **16241**
       （期望 42），dump 与基线差 **10 / 33 行** ⇒ 那两行是**承重的**，不是为了好看。
    ② **拖动倍率 `c.drag_scale`（%）**：滑块与滚动条共用；按下那一帧记锚点 `p0`（滑块住**状态池字段 k=2**、
       滚动条住 `gui_sc_py[i]`，**k≠0 ⇒ `gui_pool_sum` 与老 dump 基线不受影响**），拖动时
       `虚拟 = p0 + (真 − p0) × drag_scale / 100`。**`100` = 1:1 = 与 M4l 及以前逐像素相同**（硬判据）；
       50 半速 / 200 双倍。整数除法**截断朝零**（20px × 50% = 10、× 200% = 40，本刀用的三段都不带余数）。
    ③ **窗口拖动**：**拖动区 = 顶栏 24px**（`gui_win_drag_begin(d, g, my)` 里的 `my ∈ [0,24)`）；用 `ui_lib` 的
       `ui_drag_*`（`SetCapture` ＋ 每帧查物理左键）⇒ **零新导入**。口径对齐浮窗老判据：**不可拖档位移 `0,0`**、
       可拖档**跟随光标**、**快拖出窗口再松手不自走**。真鼠标判据 = `apps\ui_gallery\drag-probe.ps1`。
    ④ **滚动条可抓区**：绘制**仍是 4px**，命中区放宽到 **12px**（`[tx−8, tx+4)`）—— 只改命中判定。
    ⑤ **双击顶栏 = 最大化/还原**（`ShowWindow` 3/9，`gui_wd_max` 自记状态，不引 `IsZoomed`）。
       ⚠️ **`WM_LBUTTONDBLCLK` 收不到**（窗口类 `style = 0`，没有 `CS_DBLCLKS`）⇒ 双击由库内计时判（400ms ＋ ≤4px）。
       ⚠️ **诚实边界（很重要）**：ULW 每帧按 `cw×ch` 重设窗口尺寸 ⇒ 光调 `ShowWindow` 会被下一帧顶回去
       （实测见 §3.5）；所以本刀同时给**表面 DIB 留屏幕大小的余量** + 让 `gui_win_show` 把 `cw/ch` 同步成窗口尺寸。
       于是"最大化"能真的铺满，但**内容不会重排**（画廊/示例的布局是固定坐标 ⇒ 最大化后面板仍在左上角、
       右下是大片底色）—— **自适应布局是另一张卡**。
       ⚠️ **代价**：表面 DIB 由"面板尺寸"变成"屏幕尺寸"（本机 ≈ **8.3MB/表面**，虚拟内存按需提交）。
    ⑥ ⚠️ **`TrackMouseEvent` / `WM_MOUSELEAVE` 的结论 = 不补**（每帧轮询兜底）—— 三条理由见 §3.2。
12. **⚠️ M4m 顺手改了一处共享上屏路径**（`gui_win_show` 同步 `cw/ch` ＋ `gui_win_surf` 留 DIB 余量）：老 app 的窗口
    尺寸从不被外部改 ⇒ 同步是**恒等变换**，"老路径逐像素零扰动"由四条像素探针（round/chan/blend/layer）复跑同值
    ＋ 13 条 dump 基线逐字节未变来背（见 §6）。
13. **UI 美术第 2 批（M4n，2026-09-28）—— 勾 / 圆拇指 / 圆环+圆点 / 焦点圈 / 圆角端点**：四个开关全部
    "**0 = 关 = 老行为**"（`theme_check` / `theme_focus` / `theme_radius` 的经典档 + 形状通道缺省 0），
    全在**渲染端逐像素**画（`gwb_put` / `gwb_disc` / `gwb_ring` / `gwb_line2`）⇒ **命令流一个字节没动**。
    ① **勾**（`theme_check` 0..255 = 勾的**强度/alpha**）：勾选框的 `kind 9` 方块里两段 2px 线，色 = `theme_panel`；
       几何按盒子**比例**取（12×12 ⇒ (3,6)/(5,8)/(9,3)），盖章钳在盒内 ⇒ 小盒子等比缩小、不越界。
       ⚠️ 拍板原文是"0 = 不画；>0 = 勾的**强度/粗细**" —— 本刀**取强度**（线宽 2px 是同一次拍板写死的常量）。
    ② **滑块拇指**（`theme_radius > 0`）：**圆，直径 = 轨道高**，圆心 = 值点（`x0 + 已选段宽`），夹在轨道矩形内。
       ⚠️ 几何口径：**填充条在拇指左沿处截断**（渲染端临时改那一条的 `w`、画完立刻还原）⇒ 填充与圆相接不重叠，
       "圆的包围盒**四角** = 轨道色"这条判据才成立（是圆不是方）。圆用 **2 倍整数坐标**定圆心/半径 ⇒ 上下左右对称。
       ⚠️ 值 = 0 时控件层**不发 `kind 12`**（`if (fill > 0)`）⇒ 拇指的"预判"挂在**轨道命令（kind 11）**上、
       按"下一条命令"分流（`12` 且同高 = 滑块值 > 0 ／ `5` = 值 0 ／ 其它含"12 但更矮"= 纵向滚动条 ⇒ 不画），
       **画**则等到填充之后（否则填充会盖掉左半个圆）。
    ③ **单选钮**（新 API `gui_radio` / `gui_radio_g`）：见 §2 的组语义；圆环 = `box_w²` 的 **1px 圆环**、
       圆点 = `box_w/2` 的**实心圆盘**，靠 `gui_cmd_col` 的**形状通道**（`gui_shape_circle()`）与勾选框的方/圆角盒区分。
    ④ **焦点圈**（`theme_focus` = COLORREF）：`kind 15`（光标条）往前最多 4 步找到 `kind 14`（可编辑文本域盒）⇒
       在盒子**外沿**画 1px 圈。**没有键盘 Tab 导航**（用户拍板另立卡）⇒ 焦点目前只有"点进可编辑文本域"一个来源。
    ⑤ **进度条圆角端点**：`kind 12`（填充条：进度填充 / 滑块已选段 / 滚动条滑块 —— 三者同族，都用 `theme_fill`）
       加进 `gwb_box_kind` ⇒ `theme_radius > 0` 时走圆角填充；经典档不进那个函数、逐像素同 M4m。
    ⑥ **间距栅格**：`gui_space_snap` / `gui_space_grid`（见 §1.9）；**默认值一个字节没动**（仍是 `pad 6 / spacing 4`），
       app 显式调用才生效 —— 因为动默认值会让 13 条 dump 基线的命令矩形全变（老 app 零扰动优先）。
    📊 **代价**（真窗 + QPC + 3 轮取最小，40 个 12×12 勾盒）：`theme_check` 关 **546µs** vs 开 **628µs**
    ⇒ **≈2µs/勾盒**（+15%；绝对值可忽略，参照 M4k 圆角 +15.5µs/按钮、M4l 影 +70µs/面板）。
    📊 **"关就是真关"的机械证据**（本刀最硬的一条，`tmp\artprobe\run-art-classic.ps1`）：同一份**只能用两边共同
    API** 的源码，分别用 **865b0ca（M4m）的库**与本刀的库编译，整块表面 [0,cw)×[0,ch) 的两个滚动摘要逐值对：
    经典档（含"勾选框已选中"这个会打勾的场景）与"现代档 + 两个新开关为 0"**四条全部相等**；
    而"现代档 + kind 12 填充条"**必须不等**（= 探针不空转、改前会红的取证）。命令条数四跑全同（28/24）。
    ⑦ ⚠️ **本刀踩到的编译器坑（真 flint 的既有缺陷，不是本刀引入）**：加全局变量会挪动后面所有全局的
       "全局表下标"，而 T1 的 `is_addr_value()` 对全局 `int` 查的 `slot_marked(n->offset)` 里，
       全局用下标、局部用帧槽偏移，**同处一张正整数表** ⇒ 撞号即误报「地址值（64 位）不能装进全局 int」。
       本刀实测：`flgui.fl` 里加 19 个全局后 `flgui_win32.fl` 的 `gui_key_tr_n` 当场报错。
       ⇒ 规避 = 本刀在 `flgui.fl` **零新增全局槽**（形状标记走函数、单选钮组态走状态池）；**根治另立卡**。
14. **键盘焦点链（M4o，2026-09-28）** —— 口径与边界全在 §2.6；这里只列**限制与诚实边界**：
    ① **函数预算**（§2.6 第 8 条）：boot 的 512 项表只剩 **8** 格，本刀只新增 **7** 个顶层函数 ⇒
       键码是字面量、序号/清单数直接读池、导航/收尾内联在 `gui_begin`/`gui_end`；
       **再要加库函数就得先给 boot 扩容或给真应用减函数**（这是一条会"当场打断真应用双端编译"的硬墙，
       本刀第一版 17 个函数就是这么被总门 `[11] loop` 抓住的）。
       ⚠️ **2026-10-15 订正（原文保留）**：本行那个「**只剩 8 格**」出自 `tmp\m4o\measure-headroom.ps1` —— 一把**已被证伪的坏量尺**（同族订正见 `docs\索引.md` 与 `可用性路线图-人机两条线.md`）。现行真值 = boot 表 **<!--fact:boot-occupied-->507<!--/fact--> / <!--fact:boot-limit-->512<!--/fact-->**（余 **<!--fact:boot-headroom-->5<!--/fact-->** 格，取数器 `tools\文档事实.ps1` 实测）。
    ② **全新 ctx 的第一帧反向 Tab 不生效**：Shift+Tab 要"最后一个"，而"有几个可聚焦控件"是**上一帧**才知道的
       （正向 Tab 不需要 —— 第 0 个恒是第一个）⇒ 窗口刚起来那一帧就按 Shift+Tab 会什么都不做，下一帧起正常。
    ③ **序号是"本帧顺序"的**：界面控件增删会让序号跟着变（焦点可能落到另一个控件上）⇒ `gui_end` 里有
       "序号越界 ⇒ 收回焦点"的收尾；**"按 id 恢复焦点"没做**（要一张跨帧的 id→序号表，属另一张卡）。
    ④ **只实现了 Tab / Shift+Tab 两个键**：方向键 / Home-End / 空格激活（焦点控件"按回车等于点击"）**都没做**。
    ⑤ **焦点态与控件 id 共用 512 槽池**（伪 key `gui_hash("__flgui_focus") ^ 0x464F4355`）⇒ 与某个
       真的控件 id 撞槽的概率按既有 `id % 512` 口径接受（同 M4n 单选钮组那条诚实边界）。
    ⑥ **平台层的 Shift 态是"消息驱动 ＋ 物理轮询兜底"**（§3.2.1）：正常键盘两种情形都覆盖；
       但"用 `keybd_event` 注入且**一个 Shift 消息都不发**、只靠物理键态"的极端注入会被判成前进。
    ⑦ **鼠标点击按钮/勾选框/滑块不会把焦点链挪过去**（只有 Tab/Shift+Tab 与"点进可编辑文本域"会挪）——
       这是本刀定的口径，不是漏做；要"点谁谁得焦点"得另立一条（涉及点击目标 → 序号的映射）。
    ⑧ **多字体档下的几何没管**：焦点圈画在控件矩形外沿 1px，**不随 DPI/字号缩放**（与 `theme_radius` 等
       渲染端常量同一档口径）。

---

## 6. 判据与门（改 FLGUI 前后必须跑）

| 门 | 命令 | 期望 |
|---|---|---|
| FLGUI 门（无头 dump + 双端对账 + 基线 ＋ **光标条契约** ＋ **M4m 输入灵敏度契约** ＋ **M4n UI 美术契约** ＋ **M4o 焦点链契约** ＋ **M4p 焦点可见性契约** ＋ **M4q 多字体档契约**） | `pwsh -File test\flgui-verify.ps1` | **<!--fact:flgui-checks-->199/199<!--/fact--> 全绿**（flgui1~flgui17 + demo ＋ 3 帧光标契约 ＋ M4m/M4n/M4o/M4p 各段语义判据 ＋ **M4q 的 42 条**；M4d 起 +`flgui7`；M4e 起 +`flgui8`；M4f 起 +`flgui9`；M4g 起 +`flgui10`；M4h 起 +`flgui11`；M4j 起 +`flgui12`；M4m 起 +`flgui13`；M4n 起 +`flgui14`；M4o 起 +`flgui15`；M4p 起 +`flgui16`；**M4q 起 +`flgui17`**）。⚠️ **老 dump 基线一字未动**（逐条 SHA256 对过；M4q 只**新增** `test\flgui-baseline-flgui17.txt`） |
| 重录基线（**只在确认变化有意义之后**） | `pwsh -File test\flgui-verify.ps1 -WriteBaseline` | —— |
| **光标条契约**（语义判据，2026-09-23 加） | 同上（门里自跑，不单独起命令） | 断言 `光标 x = 文本 x + 真字宽 × 字节数`，**字宽由 GDI 现量**（外部裁判，不是库里的值、也不是基线里记住的值） |
| **时间注入 ＋ 动画开关**（无头契约，2026-09-26 M4d 加） | `test\samples\flgui7.fl`（门里自跑） | 固定序列 `0/16/32/48` 逐帧断言 `c.ms` 等于注入值 ＋ 负值原样搬运 ＋ `anim_pct` 默认/夹取/读回（12 位全亮） |
| **帧率档位**（无头契约，2026-09-27 M4e 加） | `test\samples\flgui8.fl`（门里自跑） | 默认 60 ＋ `0` = 不限速 ＋ 夹取（负值→0／5000→1000）＋ `gui_frame_ms` 换算（0/16/6）＋ **档位不进命令表** ＋ 与 `anim_pct` 互不干扰（12 位全亮） |
| **真动画第一刀**（无头契约，2026-09-27 M4f 加） | `test\samples\flgui9.fl`（门里自跑） | 31 位全亮：`gui_ease_out` 端点/形状/夹取 ＋ `gui_lerp` 双向与夹取 ＋ 池字段 `k=0..3` 与**越界夹取**（不许踩字段 0）＋ `anim_pct=0` 立即到位 ＋ **起始戳只盖一次**（跨帧仍是 0）＋ **不同 ID 不串位** ＋ **掉帧不跑偏**（两条帧史不同的 ID 同 elapsed 同进度）＋ 慢动作 `200` ＋ 两个除零特判 ＋ 到点饱和不越界 |
| **动画的真窗代价**（不在门里，探针） | `tmp\animprobe\anim-probe.fl`（真窗 ＋ QPC） | 量动画跑着时的帧周期与单核占用：**2026-09-27 实测 60fps 档 `period≈15.36ms`（≈65fps）、`work≈1.26ms/帧` ⇒ 单核 ≈8%**；`0` = 不限速档 `period≈1.23ms`、work 占满 99% 单核（不限速的定义） |
| **位移/缩放第二刀**（无头契约，2026-09-27 M4g 加） | `test\samples\flgui10.fl`（门里自跑） | 14 位全亮，钉的是**接线**（"动画值 → 布局矩形 → 命令表"）：起步帧/中段/到位三组 rect（`52,115,92,45` 等，**从命令表读回**）＋ 位移与缩放**同源**（Δx == Δw）＋ `anim_pct=0` 时布局侧也立即到位 ＋ `gui_item_at` 不动游标 ＋ 有/无覆盖层时下一个控件矩形逐字段相同 |
| **真应用的帧率账 ＋ 动画开关**（真窗，M4g 加） | `apps\flgui_demo\kb-probe.ps1`（真按键 10/10）＋ `tmp\flgui\noanim.on` 开关 | 真窗每 60 帧打一行 `F <帧号> ms=<注入时间戳>` ⇒ **fps = Δ帧数 / Δms**（**2026-09-27 实测 ≈57.5fps**，动画开/关都是这个数 ⇒ 动画不改节拍）；`noanim.on` 文件存在 = `gui_anim_set(c,0)`（关动画 = 可访问性通道，也是"动画的代价"做 A/B 的入口）。⚠️ **进程级 CPU 采样（`Get-Process`）在这台机器上配对顺序效应可达 ±7 个单核百分点**（同配置三次 13.4%~20.6%）⇒ 它只能当量级参考，**A/B 要用进程内 QPC 的 `work/period`**（实测外部约 14%~18% 单核） |
| **真窗帧率与 CPU**（平台层契约，M4e 起） | 探针 `tmp\frames\limit-probe.fl`（真窗 ＋ **QPC 计时**；`limit-probe.exe <fps> <frames>`） | 各档实测：`60`→15.37ms(65fps)、`144`→6.94ms(144fps、2.3% 单核)、`0`→不限速（⚠️ 量帧周期**别用 `GetTickCount`**：它的刻度就是 15.6ms，会把 6.94ms 读成 0/15 两档 —— 2026-09-27 踩过并作废过一版结论） |
| **不透明度 / 状态栈**（无头契约，2026-09-27 M4h 加） | `test\samples\flgui11.fl`（门里自跑） | 20 位全亮：默认 255 ＋ **每条命令自带生效值**（`gui_cmd_a`）＋ `kind 20` 载荷 = 压进去的值 ＋ **每帧归零**（跨帧不残留）＋ 嵌套与弹出返回值 ＋ 夹取（-5→0 / 300→255）＋ 空栈 pop 响亮报错（`err=32`）＋ 8 层满第 9 次只计数（`err=48`、栈顶不越写）＋ 压弹**不动布局游标** ＋ 命令流里 20-21 条数配对 |
| **主题预设（蓝白）**（无头契约，2026-09-27 M4j 加） | `test\samples\flgui12.fl`（门里自跑） | 4 位全亮（15 → `exit 42`）：**深色默认 13 个 `theme_*` 逐个对**（计数 = 13 ⇒ "不调预设的 app 零扰动"是被数出来的）＋ **蓝白预设 13 个字段逐个对**（计数 = 13）＋ **预设不动 5 个布局字段**（pad/spacing/btn_h/lay_w/lay_h）＋ **同一帧两套主题下命令表逐字段相同**（kind/x/y/w/h/toff/tcol；= "只换皮、不动布局/能力"的机械证据） |
| **圆角 ＋ 控件描边**（真窗 + 离屏 DIB 直读，M4k 加） | 探针 `tmp\roundprobe\round-probe.fl` | 6 位全亮（63 → `exit 42`）：蓝白档 r=4 ⇒ 角外 = 底色 / 角内 = 按钮色 ｜ 上边 1px = `theme_border`、内部 = `theme_btn` ｜ **经典档（`theme_radius=0`）角外也被画 ＋ 无描边**（"经典档零变化"的机械证据）｜ 圆角 ＋ alpha 共存（a=128 内部 = `blend(底,白,128)`、角外 = 底色）｜ 圆角 ＋ 裁剪（区外一个像素没动）｜ 小盒子（3×3、r 夹到 1）不崩。**同轮代价**：40 个按钮 现代档 **771µs** vs 经典档 **151µs** |
| **像素通道序（GDI 路 vs 直写路）**（真窗 + DIB 直读，M4k 加） | 探针 `tmp\chanprobe\chan-probe.fl` | 4 位全亮（15 → `exit 42`）：用一个三通道互不相等的色（`0x00E0A060`）⇒ GDI 路写规范序 `224,160,96` ｜ **直写路逐字节与 GDI 相同** ｜ 半透明混合同序 ｜ 描边同序。⚠️ **必须用非灰阶色**：这条 bug（R/B 对调）在灰阶上完全不可见，才从 M4h 躲到 M4k |
| **盒类投影 / 层次**（真窗 + 离屏 DIB 直读，M4l 加） | 探针 `tmp\shadowprobe\shadow-probe.fl` | 6 位全亮（63 → `exit 42`）：**`theme_shadow = 0` ⇒ 盒下方一像素没动**（= 底色，"关就是真关"的机械证据）｜开影 ⇒ 下方 1px = `blend(底色, 黑, α(1))`｜**随距离递减**（2px 比 1px 淡、且 = α(2)）｜**有界**（外扩 4px 之外 = 底色原样）｜方向性（盒内 = 面板色、**上方同距离比下方淡** —— 光从上方来，dy = 2）｜**经典档 `theme_radius = 0` 也吃影**（影不依赖圆角）。⚠️ 期望值**全部从主题字段现算**（不写死颜色/强度 —— 同族坑 `基线会把旧值锁死`）。**同轮代价**：8 个面板 开影 **672µs** vs 关影 **116µs** |
| **不透明度的渲染层判据**（真窗 + **离屏 DIB 直读**，M4h 加） | 探针 `tmp\blendprobe\blend-probe.fl`（`gui_win_render` 之后、`gui_win_show` **之前**直读 `Surf.bits`） | 6 位全亮、**2026-09-27 实测**：a=255 ⇒ `32,32,32`（GDI 老路）｜a=128 ⇒ `24,24,24`（= 与底色 16 混合）｜a=0 ⇒ `16,16,16`（一像素没动）｜裁剪内 ⇒ `24`｜**裁剪外 ⇒ `16`（直写像素最容易漏的一条）**｜两块 a=128 叠加 ⇒ `28`（混在"当前像素"上、不是覆盖）。⚠️ **不能在 `gui_win_show` 之后读**：`surf_alpha` 会重写 alpha 并按 a/255 预乘 RGB。同轮 QPC 代价：同一份几何 `a=255` **155µs** vs `a=128` **1566µs** ⇒ **≈29 ns/像素混合**（M4i 复跑同值：156µs / 1545µs；M4k 复跑 161/1550）。⚠️ **`28` 这条是 3 参数版的口径**；4 参数离屏层版是 `24`（见下一行） |
| **离屏层（文本跟着淡）**（真窗 + 离屏 DIB 直读，M4i 加） | 探针 `tmp\layerprobe\layer-probe.fl` | 6 位全亮（63 → `exit 42`）：a=255 ⇒ 文本像素 = **224**（= 文本色本身，未启用层的口径）｜**a=128 ⇒ 同一个像素 = 120**（= `blend(底 16, 文本 224, 128)`，**核心那一条：字真的跟着淡**）｜同帧面板 = 24｜**层外 = 16**（一动不动）｜裁剪切层：区内 24 / **区外 16**｜层内两块叠加 = **24**（**整层只合成一次**；M4h 逐命令累加会是 28 —— 有意变更）。**同轮代价**（同进程 QPC、40 面板、3 轮最小）：离屏层 **178µs** vs 逐命令 **278µs** ⇒ 层内命令不透明走 GDI、只有一次整块混合，**反而更便宜** |
| **输入灵敏度**（无头契约，2026-09-28 M4m 加） | `test\samples\flgui13.fl`（门里自跑，**另有外部裁判段**用 PowerShell 现算期望值） | 21 位全亮（2097151 → `exit 42`）：默认 `wheel_step = 60` / `drag_scale = 100` ｜ 滚轮 `0/40/60` 三档喂 ±1/±3 格 ⇒ 偏移变化 = **步长 × 格数**（含累加与反向，`0` = 真的不动）｜ 滑块与滚动条各跑 `100/50/200`，Δ=20px ⇒ 位移 **20/10/40**（`100` 那一档同时断言"按下帧 = 老绝对映射"）｜ 滚动条**可抓区放宽**（在 `tx−6` 处抓到滑块）｜ **拖动 on/off 两帧命令表逐字段相同**（kind/x/y/w/h/toff/tlen/col/a ＋ 条数）｜ 顶栏 24px 之外按下**不开拖** ｜ 顶栏内按下开拖（返回 1、`on=1`）＋ 抬手收尾 ｜ 400ms 内第二次按下 ⇒ **双击分支返回 2** |
| **UI 美术第 2 批**（无头契约，2026-09-28 M4n 加） | `test\samples\flgui14.fl`（门里自跑，**另有外部裁判段**用 PowerShell 现算期望值） | 25 位全亮（33554431 → `exit 42`）：两个新字段的**深色默认 0/0** ＋ **蓝白预设 255 / `#2563EB`**（且 == `theme_box`）｜ **三个开关变化下命令表逐字段相同 ＋ POOLSUM 不动**（"形状全在渲染端"的机械证据；表里真有 kind 8/9/12/15 ⇒ 不是拿空表比空表）｜ `gui_radio` 命令形状（未选 8+5、选中 8+9+5；环 `box_w²`、点 `box_w/2` 居中、标签 x = `box_w+spacing`；**形状通道** col8 = col9 ≠ 0、col5 = 0）｜ 状态池与组语义（跨帧存活 / 同组互斥 / 不同组独立 / 同名组互斥 / 组名与控件名两套 key 不互相顶掉 / 再点保持选中）｜ `gui_space_snap` 与 `gui_space_grid` 的归整值 ＋ **默认值仍是 6/4** |
| **美术形状的像素判据**（真窗 + 离屏 DIB 直读，M4n 加） | 探针 `tmp\artprobe\art-probe.fl` | **24 位全亮（16777215 → `exit 42`）**：勾 = 三个按比例取的种子点是勾色 / 方块**四角**仍是块色 / 块内勾色像素数 23（∈[8,60]，是真形状不是涂满）｜ **`theme_check = 0` ⇒ 块内勾色像素 0（144 格全块色）**、`= 128` ⇒ 勾像素 = `blend(块, 勾色, 128)`（强度是 alpha 旋钮）｜ 拇指**圆心 = 填充色**、包围盒**四角 = 轨道色**（是圆不是方）；`theme_radius = 0` ⇒ 那两角 = 填充色（**无拇指 = 老行为**）｜ 单选钮：环上边中点 = `theme_border`、环内 = 底色（是环不是盘）、选中圆心 = `theme_box`、环内点外 = 底色（点比环小）｜ **焦点圈** 盒外沿 1px = `theme_focus`、再外 2px = 底色（**1px** 细圈）、盒内 = `theme_btn`；`theme_focus = 0` ⇒ 底色（关就是真关）｜ 进度填充的角：圆角档露出底/底色、经典档全是填充色 ｜ 形状通道：20×20 不带通道 = 圆角盒、带通道 = 圆盘 ｜ 小盒子（3×3 勾 / 2×2 环）夹取不崩、**盒外一个像素没被画**。⚠️ 期望值**全部从主题字段现算**（不写死颜色/强度）。**同轮代价**：40 个勾盒 关 **546µs** vs 开 **628µs**（**≈2µs/勾盒**） |
| **键盘焦点链（Tab 导航）**（无头契约，2026-09-28 M4o 加） | `test\samples\flgui15.fl`（门里自跑，**另有外部裁判段**用 PowerShell 现算期望值） | 25 位全亮（33554431 → `exit 42`）：**初始无焦点**（序号 -1）｜可聚焦清单 = 4（**标签/进度条/只读文本域都不登记**；场景把不可聚焦控件**故意夹在可聚焦控件中间**）｜**无焦点时第一下 Tab ⇒ 第 0 个** ＋ 焦点 id 与 `kind 16` 的 rect = 按钮**整个矩形**｜Tab 逐格前进**跳过**夹在中间的 label / 进度条｜第 4 格 = 可编辑文本域（`edit_slot=0` ＋ 出现 `kind 15` = 走 M4n 那条圈）｜**末尾回绕**（3 → 0）＋ **反向回绕**（0 → 3）＋ 后退一格｜**全新 ctx 第一帧**正向 Tab 也生效（不依赖上一帧的清单数）｜`n=1` 回绕不越界、`n=0` 不乱动｜**序号越界 ⇒ 帧末收回焦点**（不留悬空焦点）｜鼠标点进文本域 ⇒ 链焦点跟上、点盒子外 ⇒ 两个一起收回｜`theme_focus` 0/非 0 **命令表逐字段相同 ＋ POOLSUM 不动**（且 POOLSUM 非 0 ⇒ 不是空表比空表）｜焦点态住池 `k=1/k=2/k=3`、**k=0 恒 0**｜**停一帧圈不动、Tab 之后旧控件不再发 `kind 16`**（同帧恒 ≤ 1 条）｜单选钮也在链里（绘制顺序、不是 id 顺序） |
| **焦点圈的像素判据**（真窗 + 离屏 DIB 直读，M4o 加） | 探针 `tmp\tabprobe\tab-probe.fl` | 14 位全亮（16383 → `exit 42`）：焦点按钮的**四条外沿**（上/下/左/右各外扩 1px）= `theme_focus`｜圈**外 2px** = 底色（1px 细圈）｜圈内 = `theme_btn`｜**同帧另一个控件的外沿 = 底色**（只画在焦点那一项）｜**Tab 换人**：新焦点有圈、旧焦点回到底色｜`theme_focus = 0` ⇒ 外沿 = 底色（关就是真关）｜勾选框的圈套住**整个控件**（右端 = `x+w` 也是焦点色 ⇒ 圈住标签那一侧）｜**可编辑文本域那条老路（kind 14/15）圈仍在盒外沿**（M4n 零回归的像素证据） |
| **真按键焦点链**（平台层契约，M4o 加） | `pwsh -File apps\flgui_demo\tab-probe.ps1` | **9/9 全绿**（真 `keybd_event` ＋ 读 app 自己的 `FOC idx= cnt= id= edit= sh=` 账本；**期望值在脚本里现算** `(idx±1+cnt)%cnt`，不抄录制值）：点进可编辑框 ⇒ 链焦点落在**最后一个**可聚焦控件（`idx=cnt-1`）｜**真 VK_TAB** 前进并**回绕**（4 → 0）＋ 编辑焦点收回（KB 账本 `F=-1`）｜**真 Shift+Tab 后退并回绕**（0 → 4）—— **方向真的被解出来了**（若 Shift 没生效这一条当场红）｜连按 `cnt` 次 Tab **每个可聚焦控件各访问一次并回到起点**。⚠️ 探针只认**完整行**（stdout 分块缓冲会把尾巴截半，实测 `FOC idx=0 cnt=` 曾把空字段读成 0 ⇒ 假绿/假红都出现过）｜⚠️ **"改前会红"取证**见 §3.2.1（Tab 方向那一笔真缺陷就是它抓出来的） |
| **"关就是真关"：老库/新库整块表面逐像素比**（M4n 加，M4o 复跑） | `pwsh -File tmp\artprobe\run-art-classic.ps1` | **12/12 全绿**：从 git `865b0ca`（M4m 收尾，`git show` 原样取出、无 BOM）取一套老库，与**同一份只用共同 API 的源码**一起编（`art-classic-old/new.fl`）⇒ 四个场景的整块表面 [0,cw)×[0,ch) 两个滚动摘要逐值对：**经典档 / 现代档（两个新开关为 0）/ 无 kind12 场景 —— 三条新老相等**（含"勾选框已选中"这个会打勾的场景 ⇒ `theme_check = 0` 真的一个勾像素都没画）；**现代档 + kind 12 填充条必须不等**（= 改前会红的取证、探针不空转）；命令条数四跑全同（28/24）。**M4o 复跑仍 12/12** ⇒ 焦点链"没有焦点时零扰动"的机械证据（老库/新库整块表面逐像素相等） |
| **多字体档（标题/正文/说明）**（无头契约，2026-09-28 M4q 加） | `test\samples\flgui17.fl`（门里自跑，**另有外部裁判段**用 PowerShell 现算期望值） | 22 位全亮（4194303 → `exit 42`）：**不压档 ⇒ 0 条 `kind 22/23`、栈深 0** ｜ `push(0)` payload=0 / `push(2)` payload=2 / **嵌套三层 payload 0,2,1** ＋ **pop 逐个恢复 2,0**（恢复的是"被压住的那一档"）＋ 弹空回基准 1 ｜ **每帧归零**（上一帧压了不弹 ⇒ 本帧 `gui_begin` 后栈深 0）｜ **err 位**：档号越界（5 / −1）⇒ `err\|=64` 且当基准档；压满 8 级第 9 次 ⇒ `err\|=128` 且**栈深仍 8**；空栈 pop ⇒ `err\|=128` ｜ **压基准档(1)+弹 ⇒ 绘制类命令逐字段摘要与"完全不压"那一帧相同** ＋ POOLSUM 相同 ｜ **光标按档取尺子**：标题 3×9（池 k=2 注入值）/ 基准 3×8 / 说明 3×5；**该档没量到（k=2=0）⇒ 回落基准 8** ｜ 池 `k=0` 恒 0 |
| **三档字号/字宽的真 GDI 对账**（离屏、**不建窗**，M4q 加） | 探针 `tmp\m4q\font-tier-probe.fl`（门里自跑；期望值由门**现算** ＋ **两次独立 GDI 现量**） | `exit 42`：**字号政策**（基准 14 ＋ 4/0/−2，过 DPI ⇒ 18/14/12）—— 用 **GDI 文本高度 `cy`** 钉（18/14/12 一一对应；⚠️ **字宽按 2px 台阶量化**，px=16/17/18 的 10 字符宽全是 80 ⇒ 宽度**分辨不出 1px 字号差**）｜ `ext` = 本脚本另一次 `GetTextExtentPoint32A`，逐档相等 ｜ **库登记字宽 reg = 单字符实测 adv**（8/7/6，`delta=0`）｜ **三档渲染互不相同**（hash 1419693763 / 977959841 / 1323765113）＋ **墨迹宽严格递减 81 > 70 > 60**（像素级；dump 对字号失明）｜ **压基准档那一帧与完全不压那一帧逐像素相同**（hash 相等；那一帧确实发了 `kind 22`）｜ **压档 ＋ 裁剪压栈/出栈 ⇒ 出栈后仍是标题档**（与不裁剪那一帧逐像素相同 —— 钉 `RestoreDC` 回滚字体那处）｜ 空场景墨迹 = 0（墨迹统计不是瞎数） |
| **多字体档的"关就是真关"＋ 负对照**（M4q 加） | `pwsh -File tmp\m4q\run-font-classic.ps1` ／ `pwsh -File tmp\m4q\run-mutations.ps1` | **12/12**：老库 `b610942`（`git show` 原样取出）vs 新库，**同一份只用共同 API 的源码**三个场景（深色 14px / 蓝白 14px / 深色 12px）整块表面两个滚动摘要**全等**（且 base ≠ small、base ≠ light ⇒ 摘要**看得见字号与主题**，"相等"不是瞎哈希；命令条数同）｜ **负对照 6/6**：① 删掉"裁剪出栈后重选当前档"那一行 ⇒ 出栈后的文字掉回基准字体（hash `1419693763 → 977959841`、墨迹宽 `81 → 70`）② 标题档 `+4` 改 `+3` ⇒ GDI `cy 18 → 17` 当场红（而 `ext` 仍是 80 ⇒ 宽度那把尺子是瞎的） |
| **改前会红（多字体档）** | `tmp\m4q\oldlab\`（老 `lib` ＋ **老的 `flint.exe`** ＋ 同一份 `flgui17.fl`） | **编译期就红**：`使用了未声明的变量 'gui_font_push'` —— 本刀的两个 API 在改前的库里根本不存在（⚠️ 隔离实验**必须连 `flint.exe` 一起复制**：`include` 会回退到"编译器 exe 目录的 `lib\`"，M4p 为此白花过一轮） |
| **真滚轮**（平台层契约） | `pwsh -File apps\ui_gallery\wheel-probe.ps1` | **7/7**（**M4m 改口径：一格 = `wheel_step` = 60px**、视口外忽略、底部夹 maxoff、夹住后再滚**纹丝不动**）。⚠️ 老脚本那条"一格 = 20px"的期望值**已按新默认改写**（同族坑：基线会把旧值锁死）；`-Step 20` 可在不改脚本的前提下按老单位复跑。**M4n 复跑仍 7/7**（画廊加了新控件之后） |
| **真鼠标窗口拖动**（平台层契约，M4m 加） | `pwsh -File apps\ui_gallery\drag-probe.ps1` | **5 轮 × 8 检查 = 40/40 全绿**（可 `-Rounds N` 加轮；真光标 ＋ 真左键；窗口矩形由 PowerShell 直接 `GetWindowRect` 读 = **外部裁判**）：**每轮重启 app ＋ 把窗口复位到本轮自己的起点**（每轮不同 ⇒ "过了"不可能是遗留位置凑巧）｜ 顶栏拖动 **1:1 跟手** ｜ 松手不再移动 ｜ **快拖出窗口再松手不自走** ｜ **顶栏之外按下位移 `0,0`** ｜ **双击顶栏铺满**（>800×600）｜ **再双击还原**回原矩形 ｜ **还原后 +700ms 仍停在原矩形**（残留拖动不许拉回去）。⚠️ **一次运行不算判据**：M4m 复核抓到的"3 跑 2 败"就是被这条多轮口径钉住的（详见 §3.2 那两处真缺陷）。**M4n 复跑 8 轮 × 8 = 64/64 全绿** |
| 真鼠标（画廊控件） | `pwsh -File apps\ui_gallery\mouse-test.ps1` | 4/4（**M4n 复跑仍 4/4** —— 画廊新增的单选钮/滑块/进度条/可编辑框都落在左列空闲区，脚本点的三个老坐标一字未改） |
| **真键盘**（平台层契约） | `pwsh -File apps\flgui_demo\kb-probe.ps1` | **10/10 全绿（M4c 收口；M4d +3 条）**：点框聚焦 / 打字 `ok` 进盒子 / 退格删一个 / 回车提交且文本保留 ＋ **时间通道**（CV 行的 `ms=` 全 >0、单调不后退、一次运行真推进 ≥200ms）；账本走 stdout 追加、按字段名解析 |
| 浮窗冒烟（loop 线） | `pwsh -File test\loop-verify.ps1` | 9/9 |
| 总门 | `pwsh -File test\verify-all.ps1` | ALL GREEN（<!--fact:gate-steps-->14<!--/fact--> 步） |

**两条判据的"层次"别搞混**（这是 M4 学到的）：

- **脚本化输入**（`test\samples\flgui*.fl`）能钉住**库内核的契约**（偏移账本、布局坐标、状态池），
  **看不见平台层缺口**（滚轮那次就是这么漏的）。
- **真输入**（真鼠标/真滚轮探针）能钉住**平台层**，但慢、要开窗、不能进无头 CI。
⇒ 两层各留一条，**别指望一条通吃**。样本 `flgui5` 与 `wheel-probe.ps1` 就是这一对。

> 写入型结论一律**先跑再写**；`-strict` 零误报是收口标准（`test\verify-all.ps1` 的 strict 段）。
