# FLGUI — FLINT 的 immediate-mode GUI 库

> 🧭 元信息（机检）：类型=对外 ｜ 快照=否
> 真值源=`docs\数字台账.md` ｜ 取数器=`tools\文档事实.ps1`
> 引用我=`docs\README.md` ｜ 我引用=`lib\flgui*.fl`、`test\flgui-verify.ps1` ｜ 最后复核=2026-10-19 `test\docgate.mjs`

FLGUI 是 FLINT 自己的界面库，**immediate-mode**：没有保留的控件树，也没有回调注册。
每一帧程序按顺序调用控件函数，控件当场读输入、改自己的状态、往一条命令表里追加绘制命令；
帧末由平台层把命令表解释成像素。跨帧要活下来的量（勾选态、滚动偏移、焦点、动画起点）
放在库内一个按 ID 索引的状态池里，而不是放在控件对象里。

四层都是纯 FLINT，不含 C，也不借用外部 UI 框架：

```
lib\flgui.fl          内核：ID / 状态池 / 布局游标 / 命令表 / 裁剪·透明度·字体档栈 / 主题 / 动画
      ↑
lib\flgui_widgets.fl  控件：label / button / checkbox / radio / slider / scroll / popup …（并 include 编辑层）
      ↑
lib\flgui_edit.fl     文本编辑：文本槽、聚焦、打字、退格、确认、取消、光标条
      ↑
lib\flgui_win32.fl    平台层：建窗 / 消息泵 / 输入采集 / 字体 / DPI / 命令表渲染 / ULW 上屏
```

`flgui_win32.fl` 会 include `ui_lib.fl` 与 `flgui_widgets.fl`，所以应用通常只写一行
`include "flgui_win32.fl"`。库的解析顺序是“当前文件目录 → 编译器 exe 目录的 `lib\`”。

## Abstract (English)

This document describes FLGUI, FLINT's immediate-mode GUI library, layered from the core
command buffer and state pool, through widgets and text editing, down to the Win32
window, input and software-rendering platform layer. It gives a complete minimal window
program, a table of available widgets and their entry points, and the real semantics of
input, event state, keyboard focus and font tiers. It also states the implementation's
known limits: approximate text measurement, single-context windows, polling input, IME
boundaries, fixed-capacity buffers and software blending costs. The verification gate
and its current check count are taken from the project meter.

## 最小可跑程序

```fl
// flgui_demo_min.fl —— 一个窗、一个标签、一个按钮
include "flgui_win32.fl"        // 平台层把内核、控件、编辑层一起带进来

int main() {
  struct GuiCtx c;              // 界面状态：局部量；跨帧量住库内状态池
  struct GuiInput in;           // 每帧输入
  struct GuiWin g;              // 窗口
  struct Surf sf;               // 画布表面（ULW 逐像素上屏）
  int *hf = 0;                  // 字体句柄必须留在局部 int* 里
  int n = 0;

  gui_init(&c);                 // 一次：默认主题、默认布局、清空状态池
  c.lay_w = 220; c.lay_h = 96;
  hf = gui_win_font_init(14);   // 建一次；不要每帧建

  g.cls = "FLGUI_DEMO";         // 类名每进程只注册成功一次：每个窗口用不同类名
  g.x = 300; g.y = 200; g.w = 220; g.h = 96; g.alpha = 235;
  if (!gui_win_make(&g)) { return 90; }
  if (!gui_win_surf(&sf, &g, 6)) { return 91; }
  gui_win_dpi_apply(&c);        // 读回 DPI 写进 ctx

  while (1) {
    if (gui_win_pump(&g, &in) == 0) { return 0; }   // 收到 WM_QUIT
    gui_win_input(&g, &in);                          // 光标、左键、本帧时间戳
    gui_begin(&c, &in);                              // 帧开始：清每帧态、消费 Tab
    gui_label(&c, "FLGUI");
    if (gui_button(&c, "click") == 1) { n = n + 1; }
    gui_end(&c);                                     // 帧结束：收尾焦点、返回命令数
    gui_win_render(&sf, &c, hf);                     // 命令表 → 表面
    gui_win_show(&sf);                               // 上屏（UpdateLayeredWindow）
  }
  return 0;
}
```

**帧协议**：`gui_init` 一次 → 每帧 `gui_begin` → 控件/自定义绘制 → `gui_end` → 平台层
`gui_win_render` ＋ `gui_win_show`。窗口相关的调用（建窗、泵消息、输入、上屏）只在
平台层；内核与控件层不调用任何 Win32 API。

**无头运行**：不建窗，直接把合成输入填进 `struct GuiInput` 喂给 `gui_begin`，再用
`gui_dump(&c)` 把命令表、游标、状态池打成文本。`test\flgui-verify.ps1` 就是靠这条路
逐字节对账；它不需要窗口，也不依赖 GDI 字体。

## 控件表

控件函数的返回值和“点中”语义都是帧内的，不是持久对象。

| 控件 | 一句话 | 关键函数 |
|---|---|---|
| 标签 | 只读文字，不进 hot/active，不可聚焦 | `gui_label` |
| 按钮 | 按下当帧不算、抬起且仍悬停才算点击 | `gui_button` |
| 分隔线 | 占满容器宽的一条横线 | `gui_separator` |
| 滑块 | 拖动跟手、点轨道也生效，越界夹到合法区间 | `gui_slider` |
| 进度条 | 只读填充条；值不合法时不溢出 | `gui_progressbar` |
| 只读文本域 | 按盒宽截断的展示框，不可编辑 | `gui_textfield` |
| 可编辑文本域 | 点进去打字，回车确认、Esc 取消、点外面失焦 | `gui_textfield_edit`、`gui_edit_text`、`gui_edit_init`、`gui_edit_setmax` |
| 勾选框 | 勾选态住状态池，跨帧存活 | `gui_checkbox` |
| 单选钮 | 同组互斥；默认组与显式分组是两个入口 | `gui_radio`、`gui_radio_g` |
| 滚动视口 | 内容高于视口时按 ID 存偏移并画滚动条 | `gui_scroll_begin`、`gui_scroll_end` |
| 弹层/右键菜单 | 开、画面板、逐项、点外面关 | `gui_popup_open`、`gui_popup_begin`、`gui_popup_item`、`gui_popup_end` |

控件的固定顺序：文本进 arena → 定矩形并推进布局游标 → 走 hot/active 状态机 →
发绘制命令。布局默认单列；`gui_same_line`、`gui_spacing`、`gui_next_rect`、
`gui_item_rect` 用来改游标或精确指定矩形。

### 文本编辑层

可编辑文本不在 `GuiCtx` 里，而在 `flgui_edit.fl` 的固定文本槽里：每个槽有实时区与
基线备份区，槽数、每槽字节数和单次输入上限都是文件头的编译期常量。编辑状态机：

- **点进盒子 = 聚焦**，光标在末尾；**点盒子外 = 失焦**，已输入内容保留。
- **打字 = 末尾追加**；**退格 = 删最后一个字符**，GBK 双字节整删，不会切半个字。
- **回车 = 确认**：内容固化成新基线，控件返回 1，并失焦。
- **Esc = 取消**：回滚到基线，控件返回 2，并失焦。
- **满了 = 静默丢弃整字**：不越界、不切半个 GBK。`maxlen` 每帧重新钉进槽。

文本指针用 `gui_edit_text(slot)` **现取现用**，不要存进全局 `int`（语言硬规则：地址值
不能装进全局 `int`）。

## 输入、事件与焦点

### 输入

`struct GuiInput` 的字段是：`mx`、`my`、`down`、`pressed`、`released`、`wheel`、`key`、
`ms`。平台层负责填：

- `gui_win_pump` 泵一步消息，返回 0 表示收到 `WM_QUIT`；滚轮增量在这里清零并累加。
- `gui_win_input` 每帧采一次客户区光标与左键状态，并填本帧时间戳 `ms`（全库唯一取时点）。
- `gui_win_frame_wait` 是“等完这一帧”的唯一入口，按 `c.frame_fps` 档位限速；应用不要
  自己写死固定等待。

**输入是轮询式**：光标与左键每帧采一次，短于一帧的按下—抬起理论上会丢。悬停和按下
状态每帧重新命中，不靠 `WM_MOUSELEAVE` 维持，所以库不补 `TrackMouseEvent`。

**键盘有两个档**：

- **默认档**（`gui_win_make`）：靠 `TranslateMessage` 生成 `WM_CHAR`。中文输入法接管时
  `WM_KEYDOWN` 的 `wParam` 可能是 `VK_PROCESSKEY`，这条路会整体失灵。
- **键盘档**（`gui_win_make_kbd`）：建窗时不带 `WS_EX_NOACTIVATE`，真点击由系统完成激活；
  字符翻译**不依赖系统 VK/IME**，而是用扫描码反查虚拟键、再查库内 US 布局表，上档符号
  用 Shift/CapsLock 态判。可编辑文本域应当用这一档。US 布局之外的换位布局（德/法）
  会打错；**中文/IME 组合输入仍未做**。

`GuiInput.key` 不是“每帧清零”的量，而是**待消费槽**：一次泵可能产出多条字符，界面一帧
只消费一个，消费方取走后置 0。Tab / Shift+Tab 在 `gui_begin` 里被消费，不会漏给文本域
当字符。

### 事件状态机

每个交互控件每帧按 ID 走同一套 hot/active 状态机：光标在控件上 = hot；按下时把 active
令牌交给该 ID，抬起时若仍悬停才算一次点击。控件本身不保存“我正被按着”，这个状态在
`GuiCtx` 的每帧字段里，帧结束自然失效。

### 焦点链

焦点是**本帧第几个被登记的可聚焦控件**（序号），不是控件 ID：immediate-mode 下“下一个
是谁”只有按本帧绘制顺序数才成立。每个可聚焦控件每帧调用 `gui_focus_reg` 登记一次；
命中当前序号的那个就是焦点。

- 可聚焦：按钮、勾选框、单选钮、滑块、**可编辑**文本域。
- 不可聚焦：标签、分隔线、进度条、只读文本域、滚动视口本身（视口里的控件各自算）。
- `gui_focus_next` / `gui_focus_prev` 前进/后退并两端回绕；`gui_begin` 消费 Tab 与
  Shift+Tab，焦点圈本帧就画在新控件上。`gui_focus_get` 返回焦点控件 ID（0 = 没有）。
- 可编辑文本域把“链焦点”和“编辑焦点（`c.edit_slot`）”对齐：链焦点落在它身上就聚焦，
  链焦点在别人身上就收回；鼠标点进/点出两个一起变；回车确认或 Esc 取消后链焦点也收回。
- **焦点可见性**：`gui_focus_reg` 登记前先算控件矩形与最近一层裁剪的相交面积；露出不足
  一半的控件本帧不登记，因此滚出视口的控件不会白占序号。没有裁剪栈时恒可见；全部不可见
  时帧末收回焦点，不留悬空焦点。

焦点圈只是命令流里的标记：可编辑文本域走已有的盒＋光标条命令，其余可聚焦控件发一条
`kind 16` 的矩形标记，渲染端按主题色只画外沿、不填充；没有焦点时一条都不发。

## 字体档与文本

FLGUI 有标题 / 正文 / 说明三档，档号是整数 `0` / `1` / `2`。档是**栈式**的，可嵌套：

```fl
int *hf0 = gui_win_font_tier(&c, 14, 0);   // 标题档：建字体并登记该档实测字宽
int *hf1 = gui_win_font_tier(&c, 14, 1);   // 正文档（= 基准）
int *hf2 = gui_win_font_tier(&c, 14, 2);   // 说明档
sf.ft0 = hf0; sf.ft1 = hf1; sf.ft2 = hf2;  // 句柄挂在表面上，不进全局

gui_font_push(&c, 0);
gui_label(&c, "标题");
gui_font_push(&c, 2);
gui_label(&c, "说明");
gui_font_pop(&c);                          // 回到标题
gui_font_pop(&c);                          // 回到正文
```

- `gui_font_push` / `gui_font_pop` 只改“渲染用哪块字体”和“光标/位置类字宽”。布局宽度
  （`gui_text_w`、盒内 `fit`）**口径不变**，仍是按字节的估算，不是真实字形宽度。这是
  刻意的窄口径：换真度量会让所有 dump 基线与硬编码坐标整批变化。
- 档号越界按基准档处理并记账；档栈深度有上限；每帧 `gui_begin` 归零，忘了 pop 只影响
  本帧。
- 命令流里用 `kind 22` / `kind 23` 标出压档/弹档，载荷是该命令之后生效的档号（绝对值），
  渲染端不需要维护档栈。
- **不切档就一条状态命令都不发**：老应用、老样本的命令流逐字节不变。
- 只压档、不给 `Surf.ft0/ft1/ft2` 句柄，渲染会回落给 `gui_win_render` 收到的基准字体，
  而光标仍按档走，两边会不一致——库不猜句柄。
- 本机 DPI 为 96 时 `gui_dpi_scale` 恒等；三档字号都过 DPI 换算，但**不做** per-monitor v2、
  不处理 `WM_DPICHANGED`。

文本宽度还有一处已知近似：`gui_text_w` 按每字节固定像素估宽（GBK 汉字按两个字节），
只有可编辑文本域的光标条读建字体时实测的真字宽。需要按真字宽做换行/裁切时，要另立一刀
并重录基线。

## 渲染、裁剪与合成

`gui_push` 把当前项矩形、暂存文本、显式颜色和当前不透明度追加成一条命令。命令表是
固定容量的全局数组，越界只计数（`gui_cmd_over`、`gui_text_over`），命令或字节被丢，
不会越写。

- **裁剪**：`gui_clip_push` / `gui_clip_pop` 压/弹矩形，容量满或空栈弹都记账；渲染端另存
  一份同源裁剪栈（直写像素的那条路吃不到 GDI 裁剪区）。
- **不透明度**：`gui_alpha_push` / `gui_alpha_pop` 是命令级状态栈，每条命令在 `gui_push`
  那一刻带一个生效值。3 参数 `gui_win_render` 下**文本不吃 alpha**（字是 GDI 直接写的，
  没法逐命令混合）；要让一整段（含文本）一起淡出，用 4 参数
  `gui_win_render_layered` ＋ `gui_win_layer` 的离屏层：层内先画进离屏 DIB，再整块按层
  alpha 合成一次，文字也跟着淡。
- **主题**：`gui_theme_default` 是深色默认，`gui_theme_light_blue` 是蓝白预设；颜色是
  `COLORREF`（`0x00BBGGRR`，低字节是 R）。圆角、投影、勾、焦点圈、滑块拇指等都在渲染端
  按主题开关逐像素画；开关为 0 时那段代码不进，命令流与像素都与经典档一致。
- **上屏**：`gui_win_show` 按预乘 alpha 走 `UpdateLayeredWindow`。表面上屏前会把自身尺寸
  同步成窗口当前尺寸，所以窗口被外部改尺寸（最大化/还原）时才画得出来。表面 DIB 按屏幕
  大小留了余量，因而“最大化”能真的铺满；但布局是固定坐标，**内容不会重排**。

## 已知限制

下面每一条都来自实现或源码注释，不是“以后可能会做”的愿望清单。

1. **文本宽度是估算**：布局用 `gui_text_w` 的按字节估宽，不是 GDI 真字宽；只有光标条
   用实测字宽。用比例字体或中文排版时，盒宽裁切与真字宽的偏差会显现。
2. **单窗口/单上下文**：共享一个窗口过程，没有 user data。`RegisterClassA` 的类名每进程
   只注册成功一次，第二个窗口必须换类名；真正的多窗口需要把 ID 池、命令表、输入、
   表面都按窗口分片，当前没做。
3. **输入是轮询式**：短于一帧的点击可能丢失；双击是库内计时判的（窗口类没有
   `CS_DBLCLKS`，收不到 `WM_LBUTTONDBLCLK`），极慢帧下双击可能整个丢失。
4. **键盘/IME**：只认可打印 ASCII；US 布局之外的换位布局会打错；中文/IME 组合输入未做
   （要 `WM_IME_*` ＋ `ImmGetContext` 一族）。中文输入法下默认档会失灵，键盘档靠扫描码
   绕过 IME 取回字符，但输入法的候选窗不归本库管。
5. **焦点链只做了 Tab / Shift+Tab**：方向键、Home/End、空格激活（焦点控件“按回车等于
   点击”）都没做；焦点序号是“本帧顺序”的，“按 ID 恢复焦点”没做；鼠标点击按钮/勾选/滑块
   不会把焦点链挪过去（只有 Tab 与点进可编辑文本域会挪）。
6. **焦点可见性是“露出至少一半”**：露出达到一半的控件照样占序号，它的焦点圈可能被渲染端
   裁剪掉一部分；判断只看最近一层裁剪（嵌套时以最内层为准）。
7. **字体档是窄口径**：只影响渲染字号与光标类字宽，不影响布局宽度；不切档零命令；压档
   必须同时给 `Surf.ft*` 句柄；档宽是平均字宽，换比例字体或中文要另做逐字符宽度表。
8. **固定容量**：命令表、状态池、文本 arena、裁剪栈、不透明度栈、字体档栈、滚动/弹层
   嵌套都有上限。超限只计数不崩，但命令/字节会被丢；`gui_cmd_over`、`gui_text_over` 与
   `c.err` 必须为 0。具体容量见 `lib\flgui.fl` 顶部常量。
9. **不透明度边界**：3 参数渲染下文本不吃 alpha；整窗常量透明度走表面的 `const_a`，
   命令级 alpha 是另一条路。要“整段含文本淡出”只能用离屏层。
10. **布局不自适应**：固定坐标；最大化后内容仍在原位置，不重排。DPI 只做整数换算，不做
    per-monitor v2。
11. **窗口档位在建窗时定死**：默认档不抢焦点（`WS_EX_NOACTIVATE`），键盘档才可被激活；
    运行时用 `SetWindowLongA` 改扩展样式无效。可编辑文本域必须用键盘档。
12. **GDI 纪律**：不每帧 `CreateSolidBrush`；填充走 `DC_BRUSH`，字体建一次、每帧重选。
    违反会累积 GDI 对象（ui_lib 有过真实泄漏事故）。
13. **软件合成有代价**：命令级 alpha 与离屏层都是逐像素软件混合，层越大越贵；表面按屏幕
    大小留 DIB 余量，内存占用也随之变大。
14. **拖动/双击的轮询缺口**：顶栏拖动、双击最大化都靠每帧轮询兜底；“短于一帧的按下—抬起”
    可能漏采，库只保证漏采不会把窗口弄坏，不保证每次双击都被认出。

## 门

改 FLGUI 前后必须跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File test\flgui-verify.ps1
```

它编译并运行 `test\samples\flgui*.fl`（无头、合成输入、双端逐字节对账，老 dump 基线
只许新增不许改动），并跑语义判据（光标条契约、输入灵敏度、UI 美术、焦点链、焦点可见性、
多字体档等）。当前检查数：<!--fact:flgui-checks-->210/210<!--/fact-->。

确认变化有意义之后才重录基线：`... -WriteBaseline`。真输入（真鼠标拖动、真滚轮、真键盘）
另有一组探针，不在无头门里；无头样本钉的是库内契约，真输入探针钉的是平台层，两层各留
一条，不能互相替代。
