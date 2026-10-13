// bench_runner.js —— 不可折叠基准组的**第三方权威**（Node 实现，独立于 gcc / FLINT）
// 立卡：T-20260919-010437（周期0「尺子与账本」）
//
// 作用：gcc 侧与 FLINT 侧都报"自己的结果"，一旦两边一致就没人对账了（可能一起错）。
// 本文件是**独立第三实现**：口径最小、无优化干扰，用来裁定"标准答案"。
//
// ⚠️ 归一化口径（2026-09-19 定，踩坑记录）：收尾**三份实现必须逐位相同**——
//    FLINT 侧没有 `%`（用软件除法会污染被测形状），故统一写 `x & (n-1)`。
//    这要求 **n 必须是 2 的幂**：此时 `x & (n-1)` ≡ `x % n`（非负 x 下恒等），
//    三份实现才可比。**n 不是 2 的幂时，本组结果对账不成立**（第一次跑就踩了：
//    FLINT 用 & (n-1)、C/Node 用 % n，n=2000000 不是 2 的幂 → 三方必不相等，
//    误判成"FLINT 算错"；逐步探针 probe_k2.fl 证明 FLINT 算得对）。
//
// 用法：node bench_runner.js 2097152
// 输出：k1=<值> k2=<值> k3=<值>（与两侧同格式，便于脚本逐值对账）

const n = BigInt(process.argv[2] || '2097152');
if (n <= 0n) { console.error('n must be > 0'); process.exit(2); }
const MASK30 = 0x3FFFFFFFn;
const NORM = n - 1n;                    // 统一口径：x & (n-1)（n 为 2 的幂时 ≡ x % n）

function bc_inc(x) { return x + 3n; }

function bc_k1(n) {
  let x = 0n, j = 0n;
  while (j < n) { x = (x + j) & MASK30; j = j + 1n; }
  return x & NORM;
}

function bc_k2(n) {
  const a = [0n, 0n, 0n, 0n];
  let i = 0n, j = 0n, s = 0n;
  while (i < n) {
    a[Number(j & 3n)] = a[Number(j & 3n)] + i;
    s = s + a[Number((j + 1n) & 3n)];
    j = j + 1n; i = i + 1n;
  }
  return s & NORM;
}

function bc_k3(n) {
  let a = 0n, i = 0n;
  while (i < n) { a = bc_inc(a + i); i = i + 1n; }
  return a & NORM;
}

const pow2 = (n & (n - 1n)) === 0n;
console.log(`k1=${bc_k1(n)} k2=${bc_k2(n)} k3=${bc_k3(n)}`);
if (!pow2) {
  console.log(`[!] n=${n} 不是 2 的幂：本组口径 x & (n-1) 与 x % n 不等，结果对账仅在 2 的幂时成立`);
}
