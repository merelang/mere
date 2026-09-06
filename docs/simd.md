# SIMD in Mere

Mere has two mechanisms that end in SIMD instructions, and they answer
different questions. Neither picks an algorithm for you: the compiler never
turns a scalar UTF-8 validator into a vector one. What it does is make the
loop you wrote vectorizable (the first path), or give you the 128-bit values
to write a lane algorithm yourself (the second).

The numbers behind every claim on this page are in
[benchmarks/README.md](../benchmarks/README.md), section "The SIMD rows".

## 1. The automatic path: range-check versioning

Every `vec_get`, `vec_set` and `bytes_get` carries a bounds check, and a
check is an early exit out of the loop. Three of them in a loop body are
what stopped clang from vectorizing `axpy`: it could not prove the exits
never fire, and the reloads of the Vec's length and data pointer after each
exit could not be hoisted. Mere at v0.1.415 ran that loop at 2.8x
hand-written C, and only 1.3-1.4x of that was SIMD; the rest was the shape
of the check.

Range-check versioning (v0.1.420) is an AST pass that runs before every
backend. For a loop of the shape

```
let rec f = fn (i: int) -> ... ->
  if <exit on i> then <base> else <step that reads/writes containers at i and calls f (i + c)>
```

it adds a sibling `f__rvfast` whose accesses are the unchecked twins
(`__vec_get_unchecked`, `__bytes_get_unchecked`, `__u8x16_load_unchecked`,
...) and rewrites each saturated call site `f i0 ...` into

```
if i0 >= 0 && i0 <= N && N - 1 + w <= len(v) && ... then f__rvfast i0 ... else f i0 ...
```

so the whole index range is checked once, before the loop, and the loop body
has no exit left. Only the step branch is rewritten; the exit branch keeps
its checks (an access on the exit path reads `v[n]`, which is out of range).

What qualifies:

- the loop is a `let rec` function whose first parameter is the index,
  tail-recursive with stride `i + c` for a literal `c >= 1`;
- the exit compares `i` (or `i + c`) with a loop-invariant bound using any of
  `==`, `!=`, `<`, `<=`, `>`, `>=`; an equality exit with `c > 1` also gets a
  landing guard `(N - i0) % c == 0`;
- every index is `i` itself, or monotonic in `i` (`+`, `-`, `*` and unary `-`
  with `i` appearing once and everything else invariant; `%` is not monotonic
  and `/` is refused because the guard would divide by zero before the loop's
  own side effects do);
- the containers are bound outside the loop (a Vec passed as the loop
  function's own parameter stays checked);
- the body changes no length (`vec_push` and friends disqualify the loop) and
  calls only builtins, or top-level and local functions that are transitively
  as safe;
- the call site's arguments are atoms (variables or literals), so the guard
  can name them.

Every backend runs the checked-once copy, so the interpreter, Wasm and the
RISC-V backends skip the per-element checks too. Only the C and LLVM backends
get *vectorized*, because clang is what vectorizes; the Wasm text is run as
written and the RISC-V backend emits scalar code. And clang vectorizes only
what is vectorizable: element-wise loops (`axpy`, `bytecount`), not a state
machine and not a floating-point reduction without fast-math (`matmul` is
unchanged by this pass; see section 3).

To see the pass work, or to turn it off:

```
MERE_RANGE_VERSION_LOG=1 mere -c prog.mere   # prints "range-version: f" and "range-version: f @call"
MERE_NO_RANGE_VERSION=1  mere -c prog.mere   # the checked loop, for comparison
```

`scripts/range_version_check.sh` is the gate: every program under
`test/range_version/` must print the same with the pass on and off on the
interpreter, C, LLVM and Wasm, and the set of planned loops must match the
`// range-version:` header of the file. `scripts/vectorize_check.sh` asks
clang for its vectorization remarks on the emitted C of `axpy` and requires
vector arithmetic reachable from `main` with the pass on and none with it off.

## 2. The explicit path: `f64x2` and `u8x16`

Two 128-bit value types (v0.1.422-425): `f64x2` is two doubles, `u8x16` is
sixteen bytes. They are ordinary values -- let-bound, passed, returned,
captured, put in records -- and every operation on them is a builtin. There
are no operators: `f64x2_add a b`, not `a + b`. `==` and `<` on a SIMD value
are refused by the type checker; `show` and `to_json` work
(`f64x2(1.5, 2.0)`, `u8x16[00ff...]`).

The builtins, with signatures and lane semantics, are tabled in
[stdlib-reference.md](stdlib-reference.md) under "the 128-bit SIMD types":
for `f64x2` splat / make / extract / add / sub / mul / div / reduce_add /
load / store; for `u8x16` splat / extract / from_bytes / load / and / or /
xor / sub_sat / eq / swizzle / shr / shift_in / any_true / reduce_add. The
loads are bounds-checked like `vec_get` (`u8x16_load b i` needs `[i, i+16)`
inside `b`), and inside a versioned loop they become the unchecked twins like
every other access. `u8x16_swizzle` is the one operation with no portable
spelling: it is `pshufb` on x86, `tbl` on arm64, `i8x16.swizzle` on Wasm and
`vrgather` on RISC-V, and Mere fixes the semantics to Wasm's (an index above
15 yields 0).

A fragment of the UTF-8 validator (Keiser-Lemire), sixteen bytes per step:

```
let m80 = u8x16_splat 128 in
let input = u8x16_load buf i in
if u8x16_any_true (u8x16_and input m80) then
  let prev1 = u8x16_shift_in prev input 1 in
  let sc = u8x16_and
             (u8x16_and (u8x16_swizzle t_high1 (u8x16_shr prev1 4))
                        (u8x16_swizzle t_low1 (u8x16_and prev1 m0f)))
             (u8x16_swizzle t_high2 (u8x16_shr input 4)) in
  ...
```

Where the types run:

| backend | `f64x2` | `u8x16` | representation |
|---|---|---|---|
| interpreter | yes | yes | the oracle every other backend is compared against |
| C | yes | yes | clang's `vector_size(16)` types; swizzle by `#if` (NEON `vqtbl1q_u8` / SSSE3 `_mm_shuffle_epi8` / scalar) |
| LLVM IR | yes | yes | `<2 x double>` / `<16 x i8>`; vectors through heap memory carry `align 8` (the allocator's guarantee) |
| Wasm | yes | yes | `v128`; a value stays unboxed on the stack and in `v128` locals inside an expression, and is boxed into a 16-byte block only when it escapes (a call argument, a record field, a capture) |
| RISC-V (RV32IM / RV64IM) | refused | yes, RVV 1.0 (`vsetivli`, `vle8`/`vse8`, integer and mask ops, `vrgather`, `vslideup`/`vslidedown`, `vredor`, `vwredsumu`) | an expression tree is evaluated in `v1`..`v7` and boxed once at its root; a let-bound value used only as an operand lives in `v8`..`v15` when no call can run before its last use |

The cost to know about is the box. On Wasm and RISC-V a SIMD value that
crosses a call or a data structure is a heap allocation, and neither backend
reclaims memory, so a long loop that carries a `u8x16` from one iteration to
the next allocates per iteration: on Wasm an in-program validation of 256 KiB
fits and 1 MiB runs out of memory. Within one expression, and for a
let-bound value used only as an operand, there is no box on either backend.

## 3. When lanes pay: four axes

The seven measured rows fall out of four properties of the loop.

**Dependence between iterations.** SIMD is the same operation on independent
elements. `c[i] = c[i] + alpha * a[i]` is independent in `i`; a state machine
`state[i+1] = f(state[i], byte[i])` is a chain, and no vectorizer splits a
chain into lanes. The explicit UTF-8 validator does not put the state machine
on lanes; it is a different algorithm, in which each byte is classified from
the byte before it through three 16-entry tables, so every lane depends on
its neighbours only. `u8x16_shift_in` exists to bring the previous block's
last bytes into the current one. "Vectorizable" means "the dependence has
been made local", and finding that form is the programmer's work.

**How the index is formed.** A contiguous index (`i`) is one vector load. A
data-dependent index (`table[b]`, as in `crc32`) is a gather, which on most
ISAs costs a load per lane; range-check versioning plans `crc32` and its time
does not move. `u8x16_swizzle` is the exception that makes the UTF-8 tables
work: a table of at most sixteen entries is a gather inside a register, one
instruction.

**The kind of operation.** Integer and bit operations reassociate, so the
compiler can reorder them across lanes. Floating-point addition does not,
so a reduction `acc + x[i]` stays serial unless fast-math is on -- `matmul`
is unchanged by versioning for this reason. Branches in the body vectorize
only when they can become masks and selects; a data-dependent early exit
cannot, and the compiler's own bounds checks were three such exits until the
first path hoisted them.

**Lane count and arithmetic density.** The ceiling on the gain is the lane
count: sixteen for bytes, two for doubles. And a memory-bound loop hits the
bandwidth ceiling first: `axpy` is two loads and a store per multiply-add,
and SIMD was worth 1.3-1.4x of its 2.8x gap. The UTF-8 validator does a
dozen table lookups and bit operations per byte, and sixteen lanes turned
into 2.5x. `axpy_simd` loses to the auto-vectorized `axpy` because a
programmer writes two lanes per step where clang unrolls to the equivalent
of eight.

| pays | does not |
|---|---|
| iterations independent, or the dependence made local to a few neighbouring bytes | the previous iteration's result is the next one's input (state machines, recursive reductions) |
| contiguous index; tables of at most 16 entries | data-dependent index into a large table (gather) |
| integer and bit operations; branches expressible as masks | floating-point reductions in a fixed order; data-dependent early exits |
| byte lanes; many operations per byte | two lanes; memory-bound bodies; an allocation or a call inside the loop |

## 4. Measured

The full table with conditions is in
[benchmarks/README.md](../benchmarks/README.md); in one line each:

- `axpy`: 2.8x C with per-element checks; the passes tie C once versioned.
  The 10 ms Mere still carries is building the two Vecs by `vec_push`.
- `bytecount`: ties C (21 ms).
- `matmul`: unchanged (144 ms against 132 ms) -- a floating-point reduction.
- `axpy_simd`: loses to the auto-vectorized `axpy` (0.12 s against 0.08 s).
- `utf8valid` 72 ms, `utf8valid_simd` 29 ms, scalar C 54 ms: 2.5x the scalar
  Mere machine and 1.9x scalar C, about 4 GB/s.
- The same validator on the Mere-written RV32 core (64 KiB, 20 passes, memu):
  2.75 s scalar, 1.85 s with RVV; keeping values in vector registers instead
  of boxes then takes another 10% off.

## 5. Choosing

Write element-wise integer loops plainly; versioning and clang make them tie
C. Floating-point element-wise loops are also served by the automatic path,
and floating-point reductions are served by neither. Reach for `u8x16` when
a byte-processing loop is slow *and* its dependence on the previous byte can
be rewritten as a lookup on the combination of neighbouring bytes -- UTF-8
validation, JSON structural scanning, base64. `f64x2` written by hand pays
only where the auto-vectorizer cannot see the loop at all.
