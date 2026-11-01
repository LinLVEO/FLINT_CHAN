// uint-exp.js -- independent judge for the v1.9.0 unsigned-integer facts probes.
// Computes every expected value with JavaScript BigInt under the C11 rules that FLINT's
// codegen implements (integer promotion, usual arithmetic conversions, mod-2^N wraparound,
// unsigned division/modulo/shift/comparison), so no expected value in
// test\facts\f048..f052 is hand-typed. Run:  node test\facts\uint-exp.js
"use strict";

const U8 = 2n ** 8n, U32 = 2n ** 32n, U64 = 2n ** 64n;
const u8of = (v) => ((v % U8) + U8) % U8;                 // uint_8: mod 256, 0..255
const u32of = (v) => ((v % U32) + U32) % U32;             // uint_32: mod 2^32, 0..2^32-1
const u64of = (v) => ((v % U64) + U64) % U64;             // uint_64: mod 2^64, 0..2^64-1
const s32of = (v) => BigInt.asIntN(32, v);                // int: low 32 bits, signed
const s64of = (v) => BigInt.asIntN(64, v);                // int_64: low 64 bits, signed
// C11 integer promotion: uint_8 (0..255) always fits in int -> promoted to int.
const promote = (t, v) => (t === "u8" ? s32of(v) : v);
// unsigned div/mod = floor division (JS BigInt / and % on non-negative operands already are)
const udiv = (a, b) => a / b;
const umod = (a, b) => a % b;

function row(tag, val) { console.log(`  ${String(tag).padEnd(34)} -> ${val}`); }

// ---------------------------------------------------------------- f048: uint_32 core ops
console.log("== f048  uint_32: wrap / unsigned div,mod / logical shr / unsigned cmp");
const A = u32of(-1n);                                     // (uint_32)0 - 1
const f048 = {
  a: A,
  a_plus_1: u32of(A + 1n),                                // + - * wrap mod 2^32
  a_times_2: u32of(A * 2n),
  a_div_2: udiv(A, 2n),
  a_div_3: udiv(A, 3n),
  a_mod_10: umod(A, 10n),
  a_shr_1: A >> 1n,                                       // logical (unsigned) shift
  a_gt_1: A > 1n ? 1n : 0n,                               // unsigned compare
  a_lt_1: A < 1n ? 1n : 0n,
  a_and_255: A & 255n,
  a_not: u32of(~A),                                       // ~ wraps back into the type
  a_eq_self: A === u32of(-1n) ? 1n : 0n,
};
for (const [k, v] of Object.entries(f048)) row(k, v);

// ---------------------------------------------------------------- f049: uint_64 core ops
console.log("== f049  uint_64: wrap / unsigned div,mod / logical shr / unsigned cmp");
const B = u64of(-1n);                                     // (uint_64)0 - 1
const f049 = {
  b: B,
  b_plus_1: u64of(B + 1n),
  b_times_2: u64of(B * 2n),
  b_div_3: udiv(B, 3n),
  b_div_10: udiv(B, 10n),
  b_mod_3: umod(B, 3n),
  b_mod_10: umod(B, 10n),
  b_shr_1: B >> 1n,
  b_gt_1: B > 1n ? 1n : 0n,
  b_lt_1: B < 1n ? 1n : 0n,
  b_and_u32max: B & u32of(-1n),
  b_eq_self: B === u64of(-1n) ? 1n : 0n,
};
for (const [k, v] of Object.entries(f049)) row(k, v);

// ---------------------------------------------------------------- f050: uint_8 + cast chains
console.log("== f050  uint_8 wrap (store truncation) + cast chains");
const f050 = {
  u8_300: u8of(300n),                                     // (uint_8)300 = 44
  u8_store_wrap: u8of(u8of(255n) + 1n),                   // uint_8 x = 255; x = x + 1; -> 0
  u64_from_int_neg1: u64of(-1n),                          // (uint_64)(int)-1 = 2^64-1 (**sign**-extend, C11 6.3.1.3)
  u32_from_i64_neg1: u32of(-1n),                          // (uint_32)(int_64)-1 = 4294967295
  int_from_u32_neg1: s32of(u32of(-1n)),                   // (int)(uint_32)-1 = -1
  u32_from_u64_neg1: u32of(u64of(-1n)),                   // (uint_32)(uint_64)-1 = 4294967295
  u8_256: u8of(256n),                                     // 0
  u8_neg1: u8of(-1n),                                     // 255
  u64_identity: 4294967296n,                              // (uint_64)4294967296 = identity
  u8_promoted_sum: promote("u8", u8of(255n)) + 1n,         // (uint_8)255 + 1 = **256** (integer promotion!)
};
for (const [k, v] of Object.entries(f050)) row(k, v);

// ---------------------------------------------------------------- f051: usual arithmetic conversions
console.log("== f051  mixed arithmetic: result *type* judged through value/high-half behaviour");
const u32max = u32of(-1n), iNeg1 = -1n, u64neg2 = u64of(-2n);
const f051 = {
  u32_plus_int: u32of(u32max + iNeg1),          // uint_32 + int        -> uint_32  4294967294
  u32_plus_i64: u32max + iNeg1,                 // uint_32 + int_64     -> int_64   4294967294 (>0)
  u32_plus_i64_is_pos: (u32max + iNeg1) > 0n ? 1n : 0n,
  i64_plus_u64: u64of(iNeg1 + u64neg2),         // int_64 + uint_64     -> uint_64  2^64-3 (huge, >0)
  i64_plus_u64_is_pos: u64of(iNeg1 + u64neg2) > 0n ? 1n : 0n,
  u32_div_int_neg1: udiv(u32max, u32of(iNeg1)), // uint_32 / int(-1) -> uint_32 => 1 (unsigned division)
  i64_from_u32: u32max,                         // (int_64)uint_32 value-preserving zero extension
  u8_plus_int: promote("u8", u8of(255n)) + iNeg1, // uint_8 + int -> int => 254
};
for (const [k, v] of Object.entries(f051)) row(k, v);

// ---------------------------------------------------------------- f052: layout / ABI (value-level)
console.log("== f052  layout (struct fields, array stride) + params/returns: expected values");
const f052 = {
  s_f_neg1: u64of(-1n),                         // struct {uint_64 f;} s.f = -1 -> 2^64-1
  s_w_neg1: u32of(-1n),                         // struct {uint_32 w;} s.w = -1 -> 2^32-1
  s_buf3: 7n,                                   // uint_8 buf[4]; buf[3] = 7
  arr_u64_stride8_byte8: 5n,                    // uint_64 a[2]; a[1]=5 -> ((char*)a)[8] == 5
  arr_u32_stride4_byte4: 5n,                    // uint_32 a[2]; a[1]=5 -> ((char*)a)[4] == 5
  arr_u8_stride1_byte1: 5n,                     // uint_8 a[2]; a[1]=5 -> ((char*)a)[1] == 5
  param_ret_u64_wrap: u64of(u64of(-1n) + 1n),   // uint_64 big(uint_64 x){return x+1;} big(-1) -> 0
  param_ret_u32: u32of(u32of(-1n) + 1n),        // uint_32 add1(uint_32 x){return x+1;} add1(-1) -> 0
  ptr_u64_deref: 42n,                           // uint_64 *p = &x; *p
  global_u32_wrap: u32of(u32of(7n) - 8n),       // uint_32 g = 7; g = g - 8 -> 2^32-1
};
for (const [k, v] of Object.entries(f052)) row(k, v);

// ---------------------------------------------------------------- print strings (exact bytes)
console.log("== print/str: exact decimal strings (no leading zeros, unsigned)");
const printCase = `A${u32of(-1n)}B${u64of(-1n)}C${u8of(300n)}D`;
console.log(`  print  -> ${printCase}`);
console.log(`  str    -> [${u32of(-1n)}|${u64of(-1n)}|${u8of(300n)}]`);
console.log(`  RESULT OK (${Object.keys(f048).length + Object.keys(f049).length
  + Object.keys(f050).length + Object.keys(f051).length + Object.keys(f052).length} expected values)`);
