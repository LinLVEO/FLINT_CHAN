# exitcode — 退出码当输出（没有 printf 也能验收）

## 这是什么
一个小工具：把一个词喂给它，它把**这个词所有字节之和 & 255** 当**退出码**吐出来，顺带打印一行给人看的字。
`exitcode.exe flint` → 打印 `word=flint len=5 sum=541 exit=29`，退出码 = 29。
为什么做这个：**本仓每一道门断言的都是退出码** —— 产物 exe 后面没有测试框架、没有断言库，
"退出码 = 结果"是最便宜也最可靠的通道（`flint.exe` 自己、每个无头样本、总门都这么干）。

## 怎么跑
```powershell
# 一条命令 = 编译 + 跑 4 个词 + 跑 1 个无参数用例 + 断退出码与输出逐字节
powershell -NoProfile -ExecutionPolicy Bypass -File examples\exitcode\build.ps1
# 手动跑
.\flint.exe examples\exitcode\main.fl -o examples\exitcode\exitcode.exe
.\examples\exitcode\exitcode.exe FLINT-lab
$LASTEXITCODE    # 217
```

## 学到什么
- **退出码 = `main` 的返回值**；`sum & 255` 是取低 8 位的习惯写法（Windows 本身也只保留低 8 位）。
- **期望值必须由独立裁判现算**：`build.ps1` 用 PowerShell 把同一个词重新求一遍字节和（`sum % 256`），
  再用 `Start-Process -PassThru` 拿**真退出码**比对；stdout 另按**字节**比（4 个词 + 无参数用例）。
- **参数要从命令行里抠**：`ec_arg(n)` 取第 n 个空白分隔的词（0 = exe 自身路径）。
- `print` 直接吃 `int`，不需要 C 的格式串（它按段类型分派）。

## 坑在哪
- **FLINT 没有 `argv`**：`main()` 不带参数，参数只能自己从 `GetCommandLineA()` 里抠；抠出来的字符串只能放**全局缓冲** —— 返回局部数组的指针 = 返回一个已经死掉的栈帧。
- **取参是"按空白切分、不处理引号"**：`exitcode.exe "a b"` 会看到两个词，只有第一个算数。exe 路径自带引号，这里能切对纯属路径里没有空格 —— **仓库放到带空格的目录下就会错位**（真边界）。
- **退出码只有 8 位**：不同的词会撞成同一个码（`sum=541` 与 `sum=285` 都给 29）；拿它验收要挑能区分的样本，或另比 stdout。
- **非 ASCII 参数不能喂**：`char` 是有符号字节，UTF-8 参数会让 `sum` 变负，`& 255` 的语义跟着变。
