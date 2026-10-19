# diag -- FLINT 程序的崩溃现场工具（C 实现，零依赖）

> 定位：给 FLINT 编出来的程序装一个「崩溃时留现场」的小工具。
> FLINT 的产物是不带运行时的裸 PE，崩了只有一个退出码（如 `0xC0000005`）；
> 这里把退出码变成 **模块+偏移 / 寄存器 / 栈 / 最后检查点**，用户可以直接提交，我们照着定位。

## 两个东西

| 文件 | 是什么 | 用在哪 |
|---|---|---|
| `fltdiag.dll` + `diag.h` | 进程内崩溃捕获 + 错误登记 | 程序里调 `flt_diag_init()`，崩了自动写报告 |
| `fltdiag.exe` | 进程外诊断（调试器式，**experimental**） | `fltdiag run 你的程序.exe`，不用改程序 |

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File diag\build.ps1
```

需要 MinGW-w64 的 `gcc`（本机 `gcc 16.1.0` 实测）。产物：`diag\fltdiag.dll`、`diag\fltdiag.exe`、`diag\test\*.exe`（都不入库）。

## 用法一：C / C++ 程序

```c
#include "diag.h"

int main(void) {
    flt_diag_init("myapp");                 // 装捕获器（一次）
    flt_checkpoint("打开配置文件");          // 可选：崩了能看到最后走到哪
    flt_err_set(1001, "配置文件不存在");     // 可选：预期内的错误
    ...
}
```

崩了会在 **exe 同目录的 `fltdiag\`** 下写三个文件：

| 文件 | 内容 |
|---|---|
| `crash-<时间>.txt` | 人读：异常码/地址、模块+偏移、寄存器、栈扫描、最后错误/检查点 |
| `crash-<时间>.json` | 机器读：同样的字段（UTF-8） |
| `crash-<时间>.dmp` | minidump，可用 WinDbg/VS 打开看完整现场（拿不到 dbghelp 时跳过） |

## 用法二：FLINT 程序

`api` 声明**只写类型、不写参数名**，参数类型只能 `int`/`double`（指针用 `int` 承接）：

```flint
api fltdiag int flt_diag_init(int);
api fltdiag int flt_checkpoint(int);
api fltdiag int flt_err_set(int, int);

int main() {
  flt_diag_init("myapp");
  flt_checkpoint("准备读文件");
  ...
}
```

把 `fltdiag.dll` 放到编出来的 exe 同目录即可（`diag\test\crash_flint.fl` 是可跑的自测样例）。

## 用法三：外部工具（experimental）

```powershell
diag\fltdiag.exe run 你的程序.exe 参数...
```

- 崩溃或退出码非 0 ⇒ 在目标目录 `fltdiag\` 写 `run-<时间>.txt/.json/.dmp`；
- 正常退出 0 ⇒ 不写；
- 退出码：目标正常 0 ⇒ 0，其余 ⇒ 1；stdout 里会打 `REPORT <路径>`。

## 报告里有啥 / 怎么读

- **异常地址 = 模块基址 + 偏移**（例：`0x...107C 在 myapp.exe + 0x107C`），换机器也能对；
- `最后错误` / `最后检查点` 是程序自己登记的，定位"崩之前走到哪"最有用；
- 栈扫描只列**落在模块里的 8 字节值**（粗栈回溯；没有符号化）；
- `.dmp` 交给 WinDbg/VS 才有完整调用栈与局部变量。

## 已知限制（实测出来的，不是猜的）

1. **FLINT 的 PE 没有 `.pdata`、没有 CRT ⇒ `SetUnhandledExceptionFilter` 不会被调用**（2026-10-20 实测：FLINT 程序空指针写时过滤器没触发）。所以库里同时装了 **VEH（向量化异常处理器）**，对"必死"的异常码落盘；两层用同一份报告逻辑、只写一次。
2. 报告由**崩溃进程自己写**：如果崩溃时堆/栈已彻底损坏或磁盘不可写，可能写不出来 —— 这种极端情况才需要外部工具或 Windows 自带的 WER（`LocalDumps`）。
3. **不做符号化**：只有模块+偏移；要函数名/行号得用 `objdump -d` 或调试器。
4. 只支持 **Windows x64**（FLINT 的唯一目标）。
5. 外部工具：抓完会**终止目标进程**（否则同一条指令会反复触发、每秒一份报告——踩过）；不做自动分析。

## 自测

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File diag\build.ps1
# 输出 all smoke tests passed = DLL 抓到了崩溃、外部工具认出了退出码 3
```
