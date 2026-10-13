/* bench_c.c —— C 侧基准宿主（gcc 侧同工具计时；与 bench_flint.fl 同输出格式）
 * 立卡：T-20260919-010437（周期0「尺子与账本」）
 *
 * 编译（三档都编，用来把"同侧前后对比"与"跨编译器倍数"分开报）：
 *   gcc -O0 -o bench_c_O0.exe bench_c.c
 *   gcc -O1 -o bench_c_O1.exe bench_c.c
 *   gcc -O2 -o bench_c_O2.exe bench_c.c
 *
 * 用法：bench_c_O2.exe 2000000 [iters]
 *   n（每核轮数）从命令行拿 —— 这是**故意的**：轮数编译期不可知，
 *   gcc 无法用"循环终值替换"把循环折掉（§4.10 那次折叠就是常量轮数造成的）。
 *   iters 默认 3（与 FLINT 侧 consts.fl 的 ITERS 对齐）。
 *
 * ⚠️ 计时口径：QueryPerformanceCounter 取**完整 64 位**（FLINT 侧只声明到 int，
 *    只用低 32 位；故两侧绝对数字不可直接比，用时统一用 对账.ps1 归一化后再比）。
 */

#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#include "bench_core.c"

static LARGE_INTEGER g_freq;

static long long now_ticks(void) {
  LARGE_INTEGER c;
  QueryPerformanceCounter(&c);
  return (long long)c.QuadPart;
}

int main(int argc, char **argv) {
  long long n = (argc > 1) ? strtoll(argv[1], NULL, 10) : 2000000;
  long long iters = (argc > 2) ? strtoll(argv[2], NULL, 10) : 10;
  if (n <= 0) { printf("n must be > 0\n"); return 2; }

  LARGE_INTEGER freq;
  LARGE_INTEGER a, b;
  if (!QueryPerformanceFrequency(&freq) || freq.QuadPart <= 0) {
    printf("qpf=0\n"); return 3;
  }
  QueryPerformanceCounter(&a);
  for (volatile int z = 0; z < 1000; z++) { }
  QueryPerformanceCounter(&b);
  long long qraw = (long long)(b.QuadPart - a.QuadPart);
  long long qpcns = (long long)((double)qraw * 1e9 / (double)freq.QuadPart);

  long long t1 = 0, t2 = 0, t3 = 0;
  long long r1 = 0, r2 = 0, r3 = 0;
  long long u = 0, v = 0;
  for (long long it = 0; it < iters; it++) {
    long long s, e;
    s = now_ticks(); r1 = bc_k1(n); e = now_ticks(); t1 += (e - s);
    s = now_ticks(); r2 = bc_k2(n); e = now_ticks(); t2 += (e - s);
    s = now_ticks(); r3 = bc_k3(n); e = now_ticks(); t3 += (e - s);
    u += r1; v += r2;
  }

  printf("impl=c\n");
  printf("qpf=%lld qpcraw=%lld qpcns=%lld\n", (long long)freq.QuadPart, qraw, qpcns);
  printf("n=%lld i=%lld\n", n, iters);
  printf("k1=%lld t1=%lld\n", r1, t1);
  printf("k2=%lld t2=%lld\n", r2, t2);
  printf("k3=%lld t3=%lld\n", r3, t3);
  return (int)((u + v + r3) & 0xFF);
}
