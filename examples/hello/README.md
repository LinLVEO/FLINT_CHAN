# hello — 最小闭环（13 行）

## 这是什么
仓库里最小的 FLINT 程序：`hello.fl`（13 行）打印两行，`main` 返回 0。它钉着两件"第一次写 FLINT 一定撞上"的事：
1. `print` 吃的是**数组**，不是 C 的格式串：`print(["text", 2 + 3, "\n"]);`
2. **产物的退出码 = `main` 的返回值** —— "跑一遍看退出码"就够做断言（本仓所有门都这么做）。

## 怎么跑
```powershell
# 0) 在仓库根目录建编译器（约 9 秒；flint.exe 不入库）
cmd /c "gcc -O2 src\*.c -o flint.exe"
# 1) 一条命令 = 编译 + 跑 + 断言退出码与输出字节
powershell -NoProfile -ExecutionPolicy Bypass -File examples\hello\build.ps1
# 2) 手动两步
.\flint.exe examples\hello\hello.fl
.\examples\hello\hello.exe
```

## 学到什么
- **产物是单文件 PE**：无 CRT、无运行时、无安装器，`hello.exe` 只有 3,072 字节。
- **期望值由独立裁判现算**：`build.ps1` 里的 `2 + 3` 是 PowerShell 加出来的，再与 stdout **逐字节**比
  （拿程序自己的输出当期望，只能证明它跟自己一致）。
- **一条命令跑完**是这族示例的硬要求：失败 `exit 1`，能直接进 CI 与汇总入口 `examples\run-all.ps1`。

## 坑在哪
- `gcc src\*.c` **不能在 PowerShell 里直接写**：PS 不给原生程序展开通配符，报 `cc1.exe: too many filenames given`；用 `cmd /c` 或列全 7 个 `.c`。
- **编译器要放仓库根目录**：`include` 的解析顺序是「本文件目录 → 编译器 exe 所在目录的 `lib\`」。
- **别用文件哈希判断 gcc 编译成功** —— 直接看退出码与产物大小。
- `.fl` 源文件里**不许出现非 ASCII 字节**（原因见 `examples\cn-print\`）：所以示例注释是英文、README 是中文。
