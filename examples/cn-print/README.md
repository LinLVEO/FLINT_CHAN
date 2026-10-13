# cn-print — 打印 `温度: 56 C`（中文 + 数字）

## 这是什么
一个**故意不粉饰**的示例：打印 `温度: 56 C`，而"温度"两个汉字**不在源码里**。
FLINT 没有真正的字符串类型（`char*` = 以 0 结尾的字节串）、没有 UTF-8 运行时、**源文件不许出现非 ASCII 字节** ⇒
中文只能来自一张从 UTF-8 文本源生成的 **GBK(936) 逐字节十六进制表**。链条三件（每加一个中文标签 = 走一遍）：

- `text.txt` —— 唯一文本源（UTF-8，`<函数名>` TAB `<文本>`）：改中文只改这里
- `gen-gbk.ps1` —— 生成器：UTF-8 → GBK → `"\xCE\xC2\xB6\xC8"` 形式的字面量，写完自证
- `cn_gen.fl` —— 生成物，**纯 ASCII**，由 `main.fl` `include`

## 怎么跑
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File examples\cn-print\build.ps1    # 生成 + 编译 + 跑 + 断言
powershell -NoProfile -ExecutionPolicy Bypass -File examples\cn-print\gen-gbk.ps1   # 只重新生成
```
产物 `cn-print.exe` 往 stdout 吐 GBK 字节（`chcp 936` 的控制台里能看见汉字）。

## 学到什么
- **中文标签 = 一张字节表**：`"\xCE\xC2\xB6\xC8"` 就是 GBK 的"温度"。
- **自证才有说服力**：生成器写完立刻数"文件里 >127 的字节数"，不是 0 就抛错；`build.ps1` 再独立数一遍两个 `.fl`，都得是 0。
- **期望输出由独立裁判现算**：`build.ps1` 用 .NET 的 GBK 编码器把 `text.txt` 重新编码、拼上 ASCII 外壳，再与 stdout **逐字节**比
  （实测 `CE C2 B6 C8 3A 20 35 36 20 43 0A`）。
- **数字照常是数字**：`56` 走语言内建的 `print`（按段类型分派，没有 C 的格式占位符）。

## 坑在哪
- **中文写不进源码**：`main.fl` 里写一个汉字，编译直接坏 —— 本刀不许改编译器，所以只能生成。
- **生成器自己带中文注释 ⇒ 必须带 UTF-8 BOM**：PS 5.1 读无 BOM 文件按 GBK 解码，中文注释会被撕开、报一堆指向无辜行的假语法错；用 `edit` 改完 `.ps1` 会丢 BOM，要立刻补回来。
- **编码口径是 GBK(936)，不是 UTF-8**：拿到 UTF-8 控制台里看就是乱码。
- 这几条就是 `开源前-人类可用性缺口.md` §3-B2「打印一行中文」那一行的实测形态。
