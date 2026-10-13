# filecount — 读文件、数行数/字节数、写一份副本

## 这是什么
一个真实小工具要碰的第一件事：**文件 I/O**。

```
filecount.exe <in.txt>
  -> 读 <in.txt>，数字节数与行数，把原文逐字节写回 <in.txt>.copy
  -> 打印 in=<路径> bytes=<n> lines=<m> out=<路径>
  -> 退出码 = 行数 & 255（读不了 254；写不了 253；没给参数 255）
```

文件 I/O 在 FLINT 里就是一次 `include "io_lib.fl"`（`std::file_read` / `std::file_write`）：
整个文件一次读完（没有流式句柄），读回来的**不带结尾 0**（只给字节数，所以二进制安全）。

## 怎么跑
```powershell
# 一条命令 = 编译 + 把样本拷进 tmp\ + 跑 + 断退出码 + 断 stdout 字节 + 断副本与原文逐字节相同
powershell -NoProfile -ExecutionPolicy Bypass -File examples\filecount\build.ps1
# 手动跑（相对路径按"当前工作目录"解析，不按 exe 所在目录）
.\flint.exe examples\filecount\main.fl -o examples\filecount\filecount.exe
.\examples\filecount\filecount.exe examples\filecount\sample.txt
```

## 学到什么
- **行数是数出来的**：数 `0x0A`，最后一行没有换行就再加 1。
- **副本是字节副本**：`0x0D` 原样留着（`sample.txt` 是 CRLF）；想改成 LF 就是"重写内容"，字节数会跟着变。
- **独立裁判读的是原始字节**：`build.ps1` 自己 `ReadAllBytes` 走一遍同样的规则算 `bytes/lines`，
  再用 `Get-FileHash -Algorithm SHA256` 证明副本与原文一字不差 —— 不拿程序自己的输出当期望。
- **`std::strcpy` / `std::strcat` 在 `str_lib.fl` 里**：`<in.txt>` → `<in.txt>.copy` 就是这么拼的。

## 坑在哪
- **没有 `argv`**（同 `examples\exitcode`）：路径要从 `GetCommandLineA()` 里抠，还要放进全局缓冲。
- **相对路径按进程的当前工作目录解析**，不按 exe 所在目录 —— 换个目录跑同一个命令就找不到文件（`build.ps1` 一律传绝对路径）。
- **参数按空白切分、不处理引号** ⇒ **路径里有空格就废**。
- **一次读完，缓冲定长**：`char fc_data[4096]` 与 `file_read(..., 4096)` 是**手写的一对**，改一个必须改另一个 —— 没有 `sizeof`，也没有"读多少长多大"的容器（动态数组要自己用 `vec_lib.fl` 那套）。
- **没有错误码体系**：读失败 `-1` / 写失败 `0` 是库的约定（`lib\io_lib.fl` 文件头）；254/253/255 是**本示例自己定的**，不是语言给的。
