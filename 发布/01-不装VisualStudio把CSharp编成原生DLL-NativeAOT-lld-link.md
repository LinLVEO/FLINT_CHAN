> ⚠️ **仅供参考**：本文是我们在一台**没有 Visual Studio** 的 Win10 x64 机器上的**实测记录**，既不是官方文档、
> 也不代表 .NET 官方支持的路径。按本文操作请自行评估风险并做好备份，**因照此操作造成的任何后果由操作者自负**。

# 不装 Visual Studio，用 NuGet 把 C# 编成原生 DLL（.NET 8 / NativeAOT / lld-link 实测）

> `_Lin_chan` 主创 + DeepSeek AI 协作　｜　2026-09-18

## 结论（先给答案）

.NET 9 及更早版本，官方路径**要求机器上装 Visual Studio 2022**（[Native AOT deployment overview](https://learn.microsoft.com/dotnet/core/deploying/native-aot/)；
这条限制本身就是 [dotnet/docs#50829](https://github.com/dotnet/docs/issues/50829) 的标题）。
但那条要求实际只是为了拿两样东西：**链接器**和 **MSVC 导入库** —— 而这两样**都能从 NuGet 拿到**。

⇒ **可以不装 Visual Studio**，把 C# 编成原生 DLL，并让它被一个**手写 PE 的原生宿主导入表直调**。

我们实测 **60/60** 成功（修好之前，同一批 5 次里 **4 次 Access Violation ＋ 1 次卡死**）。

---

## 配方（一条命令，约 8 秒）

三样依赖，全走 NuGet：

```
Microsoft.DotNet.ILCompiler                 8.0.30          → ilc 本体
LLD.Link.Toolsets.win-x64                   22.1.8.7        → lld-link.exe（替代 VS 的 link.exe）
Microsoft.Windows.SDK.CPP.x64               10.0.28000.2705 → 461 个 .lib（ucrt\x64 + um\x64）
```

`csproj` 里注入官方后门属性（跳过"去找 Visual Studio"那一步）：

```xml
<IlcUseEnvironmentalTools>true</IlcUseEnvironmentalTools>
```

发布命令，把 C++ 链接器换成 lld-link 的包装器：

```powershell
dotnet publish -c Release -r win-x64 -p:CppLinker=<包装器：指向 lld-link.exe>
```

`LinkerArg` 关键几条：

```
/LIBPATH:<sdk>\ucrt\x64 ; /LIBPATH:<sdk>\um\x64 ; /LIBPATH:<MinGW 导入库映射目录>
<crtshim.obj> ; <MinGW>\libmsvcrt.a ; <MinGW>\libmingwex.a
/NODEFAULTLIB:LIBCMT ; /NODEFAULTLIB:OLDNAMES ; /NODEFAULTLIB:libcpmt
```

**MinGW 导入库映射手法**：lld-link 只按 `<名字>.lib` 去找 ⇒ 把 `libkernel32.a` 这类**改名**成
`kernel32.lib` 放进一个目录，再用 `/LIBPATH` 指过去即可。

**垫片 `crtshim.c`**：补掉链接期缺的 MSVC 符号（我们缺的是 `/GS` 范围检查回调
`__report_rangecheckfailure`，它的真行为就是 `__fastfail(FAST_FAIL_RANGE_CHECK_FAILURE)`）。
（依赖链是这样的：目标库内部用 gzip → 拖进 zlib → zlib 引用了这个 MSVC 回调。）

⚠️ **符号名一律 `nm` 从 `.lib` 里挖真修饰名，别猜**：`??N@` 后**第 4 位是返回类型码**
（`YAX` vs `YEAX`），猜错时 `/alternatename` **静默失效** —— 不报错，只在链接期表现为"符号仍然缺"。

---

## 三个配套坑（真正花时间的部分）

### 坑 1 · TLS 偏移有"两套算法" ⇒ 间歇崩

- **症状**：致命错误 `attempted to call a UnmanagedCallersOnly method from managed code`，
  外加随机 `0xC0000005`；**同一个二进制一会儿成功一会儿失败**。
- **机制**：托管侧用的是 ILC 编译期常数（`0x1020`）；原生侧用的是**链接期算出来的**
  "排在它前面的 `.tls` 数据总长 ＋ `0x20`"。**动 `.tls` 前置块的大小 ⇒ 两侧各认一个 Thread 对象。**
- **修法**：**前置块保持 `0x1000` 不动，只往 `.tls` 尾部加填充**（`.tls$ZZZ`）。
- **效应量**：错位变体 **4/20** → 对齐后 **40/40，且逐条真初始化**。

### 坑 2 · Windows loader 不认 TLS 目录的 `SizeOfZeroFill`

声明 `0x2000` 零填充，实测**块外仍是 1700+ 个非零字节**的堆垃圾
⇒ **运行时要用的内存必须真的写进 raw 数据**，别指望 loader 替你清零。

### 坑 3 · lld-link 生成的 DLL，入口点默认是它自己的桩

- **症状**：垫片里写的 `_DllMainCRTStartup` **根本没被执行**。
  （我们一度靠"成功率变了"反推 —— 结果那点差异是噪声：模式 0 = **14/30** vs 模式 2 = **17/30**，**无显著差异**。）
- **机制**：lld-link 默认入口是它自带的桩 `mov eax,1; ret`。
- **修法**：`csproj` 里显式 `/ENTRY:_DllMainCRTStartup`，**然后让被改的代码自己留痕自证被执行**
  （我们打的是 `xcu_called=16`）。
- **初始化姿势**：`.CRT$XCU` **只登记回调**，真正的初始化由运行时在**第一次 reverse pinvoke** 时自己跑；
  **别自己调 `RhInitialize`**（真签名是 `bool RhInitialize(bool isDll)` —— 早前按 `int(void)` 调，
  实参是垃圾、返回值也读错）。

---

## 两条判据教训（比配方更值钱）

1. **"函数返回正确值" ≠ "系统真的就绪"** —— 运行时从未初始化也照样返回 5，于是
   **44/60、14/40、11/20 全是假成功**。真判据换成：**初始化回调被消费成 NULL** ＋
   Thread `flags=0x1` / `frame=-1`。
2. **TLS 目录自查**：`objdump -p <dll> | findstr "Thread Storage"` 看数据目录[9] 是否非零；
   装载后读 TLS 目录 `AddressOfIndex` 指向的那个 32 位变量，**必须非 0**（修好后实测 = 5）。

## 另一个坑：改了不重链接

`LinkerArg` / `.obj` 都属于**链接期输入**，而 MSBuild 增量判断**只看 C# 源**
⇒ 改完会发现 DLL 时间戳没变、**跑的还是旧二进制**（我们为此白排查一轮）。
正解：**删掉 `obj\Release\<tfm>\<rid>\native\*` 再 publish**。

---

## 验收（数字）

| 宿主形态 | 结果 |
|---|---|
| 原生宿主直载 DLL | **40/40** |
| 导入表形态的最小宿主 | **60/60** |
| 手写 PE 的原生产物**导入表直调** C# DLL | **60/60**（修前 5 次：4 次 AV ＋ 1 次卡死） |

---

## 你可能在搜（短答）

- **不装 Visual Studio 能 PublishAot 吗？** 能。需要 NuGet 的 ILC ＋ lld-link ＋ Windows SDK 的 `.lib`，
  用 `IlcUseEnvironmentalTools` 跳过"找 VS"。
- **报找不到 `link.exe` / 要求 VS2022 怎么办？** 同上 —— 把链接器换成 lld-link（`-p:CppLinker=`）。
- **C# 怎么编成 DLL 给别人（C/C++）调用？** NativeAOT 编出的原生 DLL，导出函数配
  `UnmanagedCallersOnly`；宿主侧按**导入表**直接 `call`，不需要 CLR。
- **NativeAOT 加载后间歇性 `0xC0000005`？** 先查 **TLS**：数据目录[9] 是否为空、`.tls` 前置块是否被动过。
- **NativeAOT 报 `attempted to call a UnmanagedCallersOnly method from managed code`？** 同上，
  几乎都是 TLS 布局两侧错位。
- **改了 `.obj` / 链接参数不生效？** MSBuild 增量不重链接，删 native 目录再 publish。
- **垫片里的 DLL 初始化代码没跑？** 查产物入口点是不是 lld-link 的默认桩。

## 关键词

NativeAOT、PublishAot、.NET 8、C#、ilc、ILCompiler、IlcUseEnvironmentalTools、lld-link、
LLD.Link.Toolsets、CppLinker、不装 Visual Studio、无 VS2022、MSVC、MSVC CRT、MSVC 导入库、ucrt、
Microsoft.Windows.SDK.CPP、NuGet、crtshim、垫片、MinGW、libmsvcrt.a、libmingwex.a、kernel32.lib、
link.exe、链接器、静态链接、`__report_rangecheckfailure`、`__fastfail`、FAST_FAIL_RANGE_CHECK_FAILURE、
alternatename、MSVC 修饰名、`??N@`、手写 PE、裸 PE、导入表、IAT、导出表、UnmanagedCallersOnly、
reverse pinvoke、RhInitialize、`.CRT$XCU`、TLS、`_tls_index`、`_tls_used`、SizeOfZeroFill、
Thread Storage、AddressOfIndex、`0xC0000005`、Access Violation、间歇性崩溃、竞态、objdump、
MSBuild 增量、不重链接、跨语言调用、C# 编成原生 DLL、原生宿主、零运行时、冷启动零初始化。

## 边界（诚实标注）

- **版本相关**：.NET 8 / ILCompiler **8.0.30** / SDK.CPP **10.0.28000.2705** —— 换版本要重测。
- 只在 **Win10 x64 ＋ 无 VS** 这一形态实测；有 VS 的机器直接走官方路径大概率更省事。
- 用途是**把 C# 能力缝进一个不背运行时的原生产物**；如果你的宿主本来就是 .NET，没必要这么折腾。
- 本文的实测来自我们自己的语言工程 **FLINT**（自产机器码 PE、不借汇编器/链接器）的跨语言缝合环节 ——
  需要"零工具链 ＋ 零运行时"才走了这条路。

## 声明

> ⚠️ **仅供参考**：本文是实测记录，不是官方文档，也不代表 .NET 官方支持的路径。
> 按本文操作请自行评估风险并做好备份，**因照此操作造成的任何后果由操作者自负**。
