# What Go's SIMD experiment gave Mere

In September 2026 the Go team wrote up their SIMD experiment
(<https://go.dev/blog/simd-experiment>): Go 1.26 shipped architecture-specific
SIMD for amd64 behind `GOEXPERIMENT=simd`, and Go 1.27 turned it into a
platform-independent `simd` package covering amd64, arm64 NEON and WebAssembly.
Mere already had SIMD by then -- range-check versioning and the `f64x2` /
`f32x4` / `u8x16` types, described in [simd.md](simd.md) -- so the question was
not "should Mere have SIMD" but "which of Go's design decisions would make
Mere's better".

This page is the record of that comparison: what was taken, what it measured
to be worth, what was not taken and why, and what turned up along the way. Every
number was measured on arm64 (Apple clang 21, node 24) unless it says otherwise.

## The answer in one table

| Go's feature | Mere's decision | The deciding measurement |
|---|---|---|
| `MulAdd` (fused multiply-add) | **Taken** as `fma` and `f64x2_fma` (v0.1.534) | `mat4xvec4` in lanes: 140 ms -> 100 ms through C |
| `LoadVPart` / `StorePart` (loop tails) | Not taken | Upper bound on the one consumer that needs it: 0.16 s -> 0.15 s |
| A mask type per element width, `IfElse` | Not taken yet | No consumer needs a select; the extra instructions can be removed without a new type |
| Full emulation, so the code "always runs" | Not taken as a rule | Mere computes in software what it can reproduce exactly, and refuses the rest; so far that means fma on Wasm |
| Vector width removed from the type (`Float32s`, `Len()`) | Not taken | Every Mere target is 128-bit wide |
| Feature variants (Go 1.28, planned) | Not taken | A problem of runtime CPU detection, which an ahead-of-time Mere build does not have |
| Reductions (`ReduceSum`, missing in Go 1.27) | Already present | `f64x2_reduce_add`, `u8x16_reduce_add`, `u8x16_any_true`, `u8x16_first_true` |

## Taken: `fma` and `f64x2_fma`

### What they are

`fma a b c` is `a * b + c` rounded **once**; `f64x2_fma` does the same in each
lane. Written out, `a * b + c` rounds twice: once for the product and once for
the sum. The two answers can differ in the last bits, and differ most when the
product and `c` nearly cancel -- `fma 0.1 10.0 (0.0 - 1.0)` is
`5.551115123125783e-17`, where `0.1 * 10.0 - 1.0` is `0.0`.

### Why Mere did not already have it

The C backend has emitted `#pragma STDC FP_CONTRACT OFF` since v0.1.315. clang
on arm64 fuses `a * b + c` into an fma instruction at `-O2` by default, and a
dense dot product then printed different bits under `mere run` and under the
native binary. Mere's rule is that the optimizer may not change the answer, so
fusing was switched off -- and with it, the one instruction that makes a
multiply-add chain fast.

The question the Go article raised was whether a program should be able to ask
for the fused answer **by name**. That keeps the rule intact: `a * b + c` still
means two roundings everywhere, and `fma` means one rounding everywhere.

### What it is worth

The kernel is `mat4xvec4` (see [benchmarks/](../benchmarks/)): 20,000 vertices
through a 4x4 matrix, 5,000 passes, with the four components in `f64x2` lanes.

| | `f64x2_mul` + `f64x2_add` | `f64x2_fma` |
|---|---|---|
| C backend, clang `-O2` | 0.14 s | **0.10 s** |
| LLVM backend | 0.75 s | 0.72 s |

On C, clang folds each pair of lane fmas into one `fmla.2d`. The LLVM row is
slow for reasons unrelated to fma; the change there is within noise. Before the
builtin existed, the same effect was measured by turning the pragma on in the
emitted C: 0.20 s -> 0.15 s for the scalar kernel (348 fused instructions
appeared) and 0.14 s -> 0.10 s for the lane kernel (72). The fused scalar and
fused lane programs printed the same bits as each other, which is what makes a
fused answer definable: fma is deterministic.

It is not a benchmark row. The row's claim is that the scalar and lane
programs print the same bytes, and a fused lane program against an unfused
scalar one would not.

### Lowering

| Backend | `fma` | `f64x2_fma` |
|---|---|---|
| interpreter | OCaml `Float.fma` | per lane |
| C | `fma(3)` | `fma(3)` per lane (one `fmla.2d` on arm64) |
| LLVM | `llvm.fma.f64` | `llvm.fma.v2f64` |
| Wasm | `$__lang_fma`, in software | `$__lang_fma` per lane |
| RV32IM / RV64IM | refused by name | refused (as all of `f64x2` is) |

### Wasm: refuse, or compute it in software?

Wasm has no fma instruction, and the host's `Math` has no `fma` either. The
two options were to refuse the builtin on that backend, as Mere does for
operations a backend cannot lower, or to compute it in software, as Go does for
everything its hardware lacks.

Software won, for one reason: fma is one of the operations IEEE-754 requires to
be **correctly rounded**, like `+ - * /` and `sqrt`, so it can be reproduced
exactly. A refusal would not have helped anyone: a program that wanted fma
would write `a * b + c` for the Wasm build and get a different answer there --
the thing the pragma exists to prevent. m3d's linear-algebra module checks that
the four backends print the same bits for everything built from correctly
rounded operations; fma can join that set only if Wasm computes it too.

The first attempt, written in Mere (a double-double product, then rounding to
odd, after Boldo and Melquiond), matched the hardware on 30,000 cases on all
four backends, but it holds only while nothing in the middle overflows or
underflows (it had been checked on operands between about 2^-100 and 2^100
and nowhere else), and on Wasm it allocated a box per call and ran out of
memory at about two million calls. What shipped is an integer implementation in the Wasm runtime
itself, with the structure of musl's `fma.c`:

1. NaN, infinity and zero operands are handled first. When `c` is zero the
   answer is `a * b`, not `a * b + c`, so that a product that underflows to
   zero keeps its sign.
2. The three significands are normalized to 54 bits with bit 0 clear.
3. The 108-bit product is built from 32-bit halves, because Wasm has no
   64x64->128 multiply.
4. `c` is aligned against the product. Whatever is shifted out becomes a
   sticky bit.
5. One add or subtract.
6. One rounding: the conversion of the top 63 bits to f64. A result that will be
   subnormal is first pre-rounded at the subnormal's last place, so the final
   scaling does not round a second time.

It costs about 12 ns a call on node 24: eight nested `fma` per iteration over a
million iterations took 130 ms where the unfused expression took 30 ms. In a
loop that already allocates a float per iteration the difference is not
visible (0.24 s against 0.22 s).

### How it was checked

The algorithm was written in C first and compared with the hardware fma on
**250 million** cases, drawn from special values, subnormals, the edges of the
exponent range, cancellation, and ties -- zero mismatches. Then each branch was
broken on purpose. Eight of ten mutations produced mismatches. The other two
(the sticky bit when the *product* is shifted right, or out entirely, against a
much larger `c`) could not be made to change any answer, and they are argued
unobservable rather than tested: that would need a 53-bit by 53-bit product with
64 zero bits between two set ones, which does not exist.

The WAT was then cut out of an emitted module and run under node against the
hardware results for **50 million** further cases -- zero mismatches -- and
the node harness was itself checked by breaking the WAT.

⚠ **Random inputs do not find ties.** Dropping the sticky bit of a shifted-out
`c` passed 20 million random cases and failed 10,272 of 20 million once a
family of constructed ties was added: an odd 54-bit exact product, which rounds
at exactly half, with a tiny `c` far below it deciding the direction.

The gate that stays is `scripts/fma_check.sh` (CI). It runs six input families
-- every triple of 22 special values, fully random bit patterns, products at the
edges of the exponent range, exact cancellation, near cancellation, and ties --
on the interpreter, C at `-O0` and `-O2`, LLVM and Wasm, against the C library's
`fma(3)`, bit for bit. Its poison redefines `fma` as `a * b + c` and must not
match (it differs in all six families). Removing the sticky bit from the Wasm
runtime makes it fail, naming the family: `Wasm differs from fma(3) in: ties`.

### Not included

- **`f32x4_fma`.** An f32 fma computed through doubles rounds twice, so it
  would need its own software path. It waits for a consumer.
- **A consumer.** `fma` has no user in the tree yet beyond the tests and the
  measurement above. The natural one is m3d's linear algebra.

## Not taken, and when to look again

### Partial loads (`LoadVPart` / `StorePart`)

Go's `LoadFloat32sPart(x[i:])` loads the last partial vector of a loop,
zero-filled, and returns how many elements it read, so the tail can stay in
lanes. The expectation was that Mere's byte-lane programs duplicate their loops
in scalar code for the tail. **That was checked before anything was built, and
it was wrong.** The UTF-8 validator (`benchmarks/utf8valid_simd`) already pads
its tail into one zero-filled block in user code. Zero is ASCII, so it is
neutral. Only one consumer, mgrep's literal prefilter, handles the tail and
lines shorter than 16 bytes in scalar code.

The measurement ran on mgrep over 81 MB of source-code lines (1.69 million
lines, averaging 49 bytes). 14% of the bytes go through the scalar path.

| Variant | Rare first byte | Common first byte |
|---|---|---|
| as shipped (scalar tail) | 0.16 s | 0.31 s |
| tail padded in user code | 0.26 s | 0.38 s |
| tail skipped entirely (upper bound, wrong answers) | 0.15 s | 0.27 s |

A builtin partial load could at best reach the last row, and that row
over-states the gain because it also skips the matches in the tail. Padding in
user code is 60% *slower*, because of three extra allocations per line.

**Look again when** a consumer processes many short buffers, where that 60% is
the cost it pays. What mgrep actually loses is elsewhere: `u8x16_load` reads
`bytes` and a line is a `str`, so each line is copied, which is about 40% of the
available gain at ordinary line lengths (Q-117). That is Mere's own problem, not
Go's.

### A mask type and `IfElse`

In Mere, `u8x16_eq` returns an ordinary `u8x16` with 0xFF lanes -- the NEON and
Wasm convention -- and that costs a little where the target's native mask is a
different shape:

- **RISC-V:** `vmseq` produces a bit mask in `v0`, and turning it back into
  bytes costs `vmv.v.i` + `vmerge`. That is two extra instructions per `eq`.
- **Wasm:** `u8x16_first_true` builds its mask from "lane == 0" and inverts it,
  because `i8x16.bitmask` reads the high bit. That is two extra instructions
  for `first_true (u8x16_eq a b)`.

Against that, the UTF-8 validator uses a comparison **as data** --
`u8x16_and (u8x16_eq ...) one` counts continuation bytes -- so a separate mask
type would need conversions. No consumer uses a select. The common shapes can
be pattern-matched in the backends without changing any type.

**Look again when** a JSON scanner or a base64 codec needs a select.

### Emulation so that code always runs

Go emulates every SIMD operation on platforms without the hardware, so a Go
program using `simd` runs everywhere. Mere refuses an operation by name on a
backend that cannot lower it: `f64x2` and `f32x4` on RISC-V, and
`u8x16_first_true` there too. Mere also has what Go's `GODEBUG=simd=0` is for
-- an interpreter that every compiled backend is compared against -- so
emulation is worth less to it as a testing tool.

The rule Mere follows is per operation, not global: an operation that is
correctly rounded can be reproduced exactly, so it is computed in software; the
rest is refused. fma on Wasm is the first operation to which the first half
applied.

**Look again when** Mere targets a real RISC-V core without the V extension.

### Width-agnostic types and feature variants

`simd.Float32s` has no fixed length, so the same code uses AVX-512 where it
exists. Every Mere target is 128-bit: arm64 NEON, Wasm `v128`, and the RVV
configuration Mere emits (VLEN 128, `vl` fixed at 16 bytes). The same reasoning
already kept RVV's LMUL > 1 out. Feature variants (planned for Go 1.28) choose
among implementations at run time by CPU feature; an ahead-of-time Mere build
has no such choice to make.

## What turned up along the way

The comparison and the gate it produced found defects that had nothing to do
with fma:

- **LLVM: `x != x` said a NaN was not a NaN.** Float `!=` was the ordered
  `fcmp one`, which is false with a NaN on either side, while the interpreter,
  C and Wasm answer true. The fma gate folds NaN results with exactly that test,
  and the LLVM leg alone disagreed, on the one family that produces NaNs. Fixed
  in v0.1.534. `test/parity/float_edges.mere` had asked `==`, `<` and `>` of a
  NaN, but never `!=`.
- **LLVM: a local binding of a builtin's name leaked into `main`.** `main` was
  emitted with the inner-function table of whichever function had been emitted
  last, so `let atan2 = ...` inside one function made `atan2 1.0 1.0` in `main`
  print 2.0. Found by the fma parity case, which binds a local `fma`. Fixed in
  v0.1.534. ⚠ The first regression test passed with the bug in place, because
  only the last host's table leaked.
- **`f_min` / `f_max` with a NaN.** The interpreter and Wasm returned NaN. C
  and LLVM returned the other operand, depending on argument order. Seen while
  fixing `!=`, recorded as Q-177, and fixed in v0.1.538 by transcribing OCaml's
  `Float.min` / `Float.max` into every backend, down to which NaN comes back.
- **CI had been red for four versions**, on two checks unrelated to SIMD, and
  the new `fma_check` was red on its first run: its LLVM leg compiled IR with
  `cc`, which is gcc on the Ubuntu runner. That was fixed in v0.1.535 and
  v0.1.536. The lesson is recorded there: a local run of every gate is not a run
  on the runner.

## Measurement conditions

Unless stated, arm64 macOS, Apple clang 21, node 24, and the median or best of
five runs, with timer resolution around 10 ms. The mgrep corpus is Mere's own
`lib/*.ml` and `docs/*.md`, repeated to 81 MB. The Linux checks of
`fma_check.sh` ran on x86-64 Ubuntu 24.04 (gcc 13 at `-O0` and `-O2`, clang 18,
glibc's `fma`) and on arm64 Ubuntu under dash.
