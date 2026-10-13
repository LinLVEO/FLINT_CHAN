/* bench_one.c —— C 侧"单核"宿主（与 bench_one.fl 逐字对应）
 * 立卡：T-20260919-010437（周期0「尺子与账本」）
 *
 * 编译：gcc -O1 -o bench_one_O1.exe bench_one.c   /   gcc -O2 -o bench_one_O2.exe bench_one.c
 * 用法：bench_one_O2.exe <核号 1|2|3> [测几遍，默认 5]
 *
 * 输出同 FLINT 侧：
 *   impl=c kernel=<k> n=<轮数> iters=<遍数> qpf=<频率> qpcraw=<背靠背 QPC 差>
 *   result=<核的返回值> ticks=<累计时钟刻度>
 */

#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#include "bench_core.c"
#include "bench_counts.h"

int main(int argc, char **argv) {
  int k = (argc > 1) ? (int)strtoll(argv[1], NULL, 10) : 1;
  long long iters = (argc > 2) ? strtoll(argv[2], NULL, 10) : 5;
  if (iters <= 0) { iters = 5; }
  long long n = BC_N;

  LARGE_INTEGER qf, a, b;
  if (!QueryPerformanceFrequency(&qf) || qf.QuadPart <= 0) { printf("qpf=0\n"); return 3; }
  QueryPerformanceCounter(&a);
  QueryPerformanceCounter(&b);
  long long qraw = (long long)(b.QuadPart - a.QuadPart);
  if (qraw < 0) { qraw = -qraw; }

  long long r = 0, ticks = 0, acc = 0;
  for (long long rep = 0; rep < iters; rep++) {
    LARGE_INTEGER s, e;
    QueryPerformanceCounter(&s);
    if (k == 1) { r = bc_k1(n); }
    else if (k == 2) { r = bc_k2(n); }
    else if (k == 3) { r = bc_k3(n); }
    QueryPerformanceCounter(&e);
    ticks += (long long)(e.QuadPart - s.QuadPart);
    acc += r;
  }

  printf("impl=c kernel=%d n=%lld iters=%lld qpf=%lld qpcraw=%lld\n",
         k, n, iters, (long long)qf.QuadPart, qraw);
  printf("result=%lld ticks=%lld absorb=%lld\n", r, ticks, acc);
  return (int)(r & 0xFF);
}
