/* bench_core.c —— 不可折叠基准组（C 侧；与 bench_core.fl 形状逐字对应）
 * 立卡：T-20260919-010437（周期0「尺子与账本」）
 *
 * 纪律（照抄 bench_core.fl 顶部说明）：
 *   ① 三个核都设计成"编译器折不掉"：依赖链 / 数据决定下标 / 每轮真 call
 *   ② 收尾归一化**三份实现逐位相同**：统一 `x & (n-1)`（不用 %）——
 *      FLINT 侧没有 %（软件除法会污染被测形状），故 C 侧也走 &；
 *      这要求 n 是 **2 的幂**（此时 x & (n-1) ≡ x % n，非负 x 下恒等）。
 *      ⚠️ 首次跑用 n=2000000（非 2 的幂）踩过：两边归一化不等 → 误判"FLINT 算错"，
 *      逐步探针 probe_k2.fl 证明 FLINT 侧是对的。判定归一口径 = 组的一部分。
 *   ③ 两侧都不用 % 与 /（FLINT 侧除法是软件实现）→ 只用 & 与加法
 *   ④ C 侧用 long long 防 64 位溢出；FLINT 侧变量是 8 字节槽、算术按 32 位走，
 *      但本组测试的累加值远小于 2^31，故两侧逐位相同（差异一旦出现即是真问题）。
 */

long long bc_inc(long long x) { return x + 3; }

long long bc_k1(long long n) {
  long long x = 0;
  long long j = 0;
  while (j < n) {
    x = (x + j) & 0x3FFFFFFF;
    j = j + 1;
  }
  return x & (n - 1);
}

long long bc_k2(long long n) {
  long long a[4];
  long long i = 0;
  long long j = 0;
  long long s = 0;
  a[0] = 0; a[1] = 0; a[2] = 0; a[3] = 0;
  while (i < n) {
    a[j & 3] = a[j & 3] + i;
    s = s + a[(j + 1) & 3];
    j = j + 1;
    i = i + 1;
  }
  return s & (n - 1);
}

long long bc_k3(long long n) {
  long long a = 0;
  long long i = 0;
  while (i < n) {
    a = bc_inc(a + i);
    i = i + 1;
  }
  return a & (n - 1);
}
