# window — 最小的 FLGUI 窗口（开窗 + 一行字 + 关闭）

## 这是什么
FLINT **最强那条路**（专业桌面程序方向）的最小样子：开一个 300×120 的窗，画一行字，放一个 `close` 按钮。
窗口天生"阻塞到人来关"，进不了自动门，所以有三种模式（模式词从命令行读，因为没有 `argv`）：

- `window.exe` —— 真窗，等人点 X / 点 `close`（退出码 0）
- `window.exe autoclose` —— 真窗，90 帧后自己关（真窗的自动验收走这条；开窗失败 90 / 表面失败 91）
- `window.exe headless` —— **不开窗**：合成一帧输入 → 打命令表 → 自检四条（退出码 42 = 四条自检位全亮）

## 怎么跑
```powershell
# 一条命令 = 编译 + 无头跑 + 断退出码 42 + 解析 dump 逐字段核对（不开窗、不需要桌面）
powershell -NoProfile -ExecutionPolicy Bypass -File examples\window\build.ps1
# 真窗（弹一个窗口约 2 秒，需要有人在的桌面会话）
powershell -NoProfile -ExecutionPolicy Bypass -File examples\window\build.ps1 -Window
```

## 学到什么
- **四步帧协议**：`gui_init` 一次 → 每帧 `gui_begin` → 控件 → `gui_end` → `gui_win_render` + `gui_win_show`，
  循环末尾调库层**唯一**的限速入口 `gui_win_frame_wait`（默认 60fps；**别在 app 里 `Sleep`**）。
- **立即模式**：界面每帧重建、命令表每帧清零；跨帧状态要自己放"状态池"（勾选态、滚动偏移都住那儿）。
- **无头 dump 是桌面程序进自动门的那条路**：`gui_dump` 把命令表打成文本，合成输入喂同一个帧路径 ⇒
  "窗口画对没有"变成一条逐字节可比、不需要桌面的判据（本仓 FLGUI 的门都这么干）。
- **裁判在源码里**：`build.ps1` 从 `main.fl` 抠出 `char *w_title = "..."` 的字面量算长度，再核对 dump 里的 `text=偏移,长度`。

## 坑在哪
- **窗口阻塞 ⇒ 不能直接进自动门**：`headless` / `autoclose` 就是为这个加的两种模式。
- **字体句柄必须接住**：`hf = gui_win_font_init(14);` 丢掉返回值，渲染端会回落到系统 stock 比例字体（字宽对不上，文字与光标位置全歪）—— 本仓真踩过的 bug。
- **类名每进程只注册成功一次**：第二个窗口要换一个不同的 `g.cls`。
- **产物 141,312 字节**：整个 FLGUI 平台层都链进去了 —— FLINT **不做死代码消除**，用不到的库代码也留在产物里（"零运行时依赖"的另一面）。
- **桌面这层的已知边界**（见 `开源前-人类可用性缺口.md` §3-B5）：无多窗口、无 DPI≠96 档、命令表 256 条/帧、文本 arena 4096 字节、中文 IME 只是"绕过"。
