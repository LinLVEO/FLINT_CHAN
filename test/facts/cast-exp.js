// exp.js -- independent judge for the v1.8.0 C-style cast facts probes.
// Computes the expected values with JavaScript BigInt + the x86 rules that the FLINT
// codegen uses (mov eax,eax / movsxd / movzx al / cvttsd2si / cvtsi2sd), so no expected
// value in test\facts\f042..f047 is hand-typed. Run:  node test\facts\cast-exp.js
"use strict";

const I32_MIN = -2147483648n, I32_MAX = 2147483647n;
const I64_MIN = -(2n ** 63n), I64_MAX = 2n ** 63n - 1n;
const asI32 = (v) => BigInt.asIntN(32, v);            // (int)x from int_64: mov eax,eax
const asI64 = (v) => BigInt.asIntN(64, v);
const charOf = (v) => ((v % 256n) + 256n) % 256n;     // (char)x: movzx al (mod 256, 0..255)
// cvttsd2si eax: out of [I32_MIN, I32_MAX] (or NaN) -> 0x80000000
const d2i32 = (d) => (Number.isNaN(d) || d < Number(I32_MIN) || d > Number(I32_MAX)) ? I32_MIN : BigInt(Math.trunc(d));
// cvttsd2si rax: out of [I64_MIN, I64_MAX] -> 0x8000000000000000
const d2i64 = (d) => (Number.isNaN(d) || d < -9223372036854775808 || d >= 9223372036854775808) ? I64_MIN : BigInt(Math.trunc(d));

function row(tag, val) { console.log(`  ${String(tag).padEnd(28)} -> ${val}`); }

console.log("== f042  (int)x where x is int_64  [mov eax,eax = low 32 bits]");
for (const v of [4294967296n, 8589934597n, -1n, 4294967295n, 9223372036854775807n,
                 -9223372036854775807n - 1n, 1234567890123n, -4294967297n, 2147483648n, 4294967294n])
  row(v, asI32(v));

console.log("== f043  (int)x where x is double  [cvttsd2si eax; trunc; OOR -> 0x80000000]");
for (const d of [3.9, -3.9, 0.5, -0.5, 2147483647.0, 2147483648.0, -2147483648.0, -2147483649.0, 1.0, 1000000.75])
  row(d, d2i32(d));

console.log("== f044  (int_64)x where x is int/char (sign extend) and double (cvttsd2si rax)");
for (const v of [-5n, 2147483647n]) row(`int ${v}`, asI64(v));
row("char 200", 200n);
for (const d of [3.9, -3.9, 1234567890123.0, 4294967296.0 * 4294967296.0,
                 4294967296.0 * 1073741824.0, -4294967296.0 * 4294967296.0])
  row(d, d2i64(d));

console.log("== f045  (char)x  [movzx al = mod 256 in 0..255]");
for (const v of [300n, -1n, 256n, 255n, -300n, 0n]) row(`int ${v}`, charOf(v));
row("int_64 4294967361", charOf(4294967361n));
row("int_64 -4294967296", charOf(-4294967296n));
row("char 200", charOf(200n));
row("int_64 4294967295", charOf(4294967295n));

console.log("== f046  (double)x for x int/char/int_64  [cvtsi2sd], judged by round-trip (int_64)(double)x");
for (const v of [7n, -5n, 200n, 1234567890123n, 4294967296n, -1n,
                 9007199254740993n, 9223372036854775807n])
  row(v, d2i64(Number(v)));
row("(double)7 * 0.5", 7 * 0.5);

console.log("== f047  identity rows");
row("(int)42", 42n);
row("(int_64)8589934597", 8589934597n);
row("(double)2.5 == 2.5", 2.5);
row("(char)200", charOf(200n));
row("(int)(char)200", charOf(200n));
