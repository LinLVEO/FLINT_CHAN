# 映射层审计.ps1 — 断言"帧槽访问只有一个出口"（IR 重构 M1/M2/M3 纪律，机器可验）
#
# 为什么要它：寄存器分配（M4）一旦漏掉某个槽访问点，"忘刷 / 忘失效"就漏网 ⇒ 编译过、静默错值。
#   靠人工 review「生成层有没有直接写帧槽寻址」迟早会漏（本仓"漏过一道处理"家族已复发 4 次）。
#   把纪律变成可执行断言：
#     [1] 帧槽偏移的编码（-off 掩码 / disp32 分支）只允许出现在 src\slotmap.c
#     [2] codegen.c 里不许再出现被归口的旧发射器名（emit_*_var / emit_inc_mem / emit_dec_mem …）
#     [3] codegen.c 调用的每个 slot_* 都必须在 slotmap.h 里声明（防"自己又写一个 static 版"）
#     [4] 映射层不许理解 AST（slotmap.c 里不许出现 Node / ND_ 字样）
#     [5] 映射层的申报接口在 codegen.c 里真的被调用（begin / declare / note_call / bb_boundary / stats 桥）
#
# 用法: ... -File test\映射层审计.ps1
# 退出码：0 = 全过；1 = 有失败项
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'
$codegen = Join-Path $srcDir 'codegen.c'
$slotmapC = Join-Path $srcDir 'slotmap.c'
$slotmapH = Join-Path $srcDir 'slotmap.h'

$fail = 0
function Ok($msg)   { Write-Host "  OK   $msg" }
function Bad($msg)  { Write-Host "  FAIL $msg"; $script:fail++ }

Write-Host ''
Write-Host '===== 映射层审计（帧槽访问的唯一出口）====='
Write-Host ("文件: {0} / {1}" -f $slotmapC, $slotmapH)

# [1] 帧槽偏移编码只允许在 slotmap.c
$encPat = '-off & 0xFF|\(uint32_t\)\(-off\)'
$cHits = @(Select-String -Path $codegen -Pattern $encPat)
$sHits = @(Select-String -Path $slotmapC -Pattern $encPat)
if ($cHits.Count -eq 0 -and $sHits.Count -gt 0) { Ok ("[1] 帧槽编码只在映射层（codegen.c 0 处，slotmap.c {0} 处）" -f $sHits.Count) }
else { Bad ("[1] 帧槽编码泄漏：codegen.c {0} 处、slotmap.c {1} 处（期望 0 / >0）" -f $cHits.Count, $sHits.Count) }

# [2] 被归口的旧发射器名不许再出现在 codegen.c
$oldNames = @('emit_inc_byte_var','emit_dec_byte_var','emit_inc_mem(','emit_dec_mem(',
              'emit_store_rcx_var64','emit_store_rdx_var64','emit_store_r8_var64','emit_store_r9_var64',
              'emit_store_ecx_var','emit_store_edx_var','emit_store_r8d_var','emit_store_r9d_var',
              'emit_movsxd_rcx_var')
$left = @()
foreach ($n in $oldNames) {
    $h = @(Select-String -Path $codegen -Pattern ([regex]::Escape($n)) -CaseSensitive)
    if ($h.Count -gt 0) { $left += ("{0}({1})" -f $n, $h.Count) }
}
if ($left.Count -eq 0) { Ok ("[2] 旧发射器名无残留（查了 {0} 个）" -f $oldNames.Count) }
else { Bad ("[2] codegen.c 仍有旧发射器调用: " + ($left -join ', ')) }

# [3] codegen.c 用到的每个 slot_* 都要在 slotmap.h 声明（T1 的 slot_marked 不属映射层，排除）
$hText = Get-Content -Raw $slotmapH
$called = @(Select-String -Path $codegen -Pattern 'slot_[a-z0-9_]+\s*\(' -AllMatches -CaseSensitive |
            ForEach-Object { $_.Matches } | ForEach-Object { ($_.Value -replace '\s*\($','') } |
            Sort-Object -Unique | Where-Object { $_ -ne 'slot_marked' })
$undeclared = @($called | Where-Object { $hText -notmatch ("\b{0}\b" -f [regex]::Escape($_)) })
if ($undeclared.Count -eq 0) { Ok ("[3] codegen.c 调用的 slot_* 全部在 slotmap.h 声明（{0} 个）" -f $called.Count) }
else { Bad ("[3] 未声明就调用: " + ($undeclared -join ', ')) }

# [4] 映射层不许理解 AST
#   ⚠️ 必须 -CaseSensitive：Select-String 默认**忽略大小写**，`ND_[A-Z]` 会撞上小写标识符里的 `nd_b`
#      （2026-09-19 实测：`cand_block` 被当成 AST 字样报假红——审计工具自己的坑，已在候选里记下）
$astHits = @(Select-String -Path $slotmapC -Pattern '\bNode\b|ND_[A-Z]' -CaseSensitive)
if ($astHits.Count -eq 0) { Ok '[4] 映射层不含 AST 字样（Node / ND_*；大小写敏感匹配）' }
else { Bad ("[4] 映射层出现 AST 字样 {0} 处（槽属性必须由生成层用 slotmap_declare 申报）" -f $astHits.Count) }

# [5] 申报接口在生成层真的被调用
$need = @('slotmap_begin_function(','slotmap_declare(','slotmap_note_call(','slotmap_bb_boundary(','slotmap_stats_access(')
$missing = @()
foreach ($n in $need) {
    $h = @(Select-String -Path $codegen -Pattern ([regex]::Escape($n)) -CaseSensitive)
    if ($h.Count -eq 0) { $missing += $n }
}
if ($missing.Count -eq 0) { Ok '[5] 申报接口五件套都在生成层被调用（begin / declare / note_call / bb_boundary / stats 桥）' }
else { Bad ("[5] 生成层未调用: " + ($missing -join ', ')) }

Write-Host ''
$total = 5
if ($fail -eq 0) { Write-Host ("AUDIT PASS -- 映射层纪律符合 {0} / {1}" -f $total, $total); exit 0 }
else { Write-Host ("映射层纪律不符合 {0} / {1}" -f ($total - $fail), $total); exit 1 }
