# benchmarks

The same program, written in Mere and in several other languages, measured the
same way, with every implementation's name and version printed next to its
number.

```sh
dune build                              # the suite refuses a stale binary
python3 benchmarks/run.py               # the whole record
python3 benchmarks/run.py crc32         # one benchmark
python3 benchmarks/run.py --sweep       # plus the scaling sweeps
python3 benchmarks/run.py --verify-only # the deterministic half (what CI runs)
```

`scripts/bench_check.sh` is the CI gate and runs the last of those.

## What this is, and what it is not

It is a **record**, not a verdict. Nothing here fails because a number moved,
and nothing here is a claim that Mere is fast. It exists because the numbers
this project used to quote came from one-off runs in a scratch directory, and a
measurement that only exists in `/tmp` is not a measurement — it cannot be
re-run, it cannot be regressed against, and by the time anyone repeats it the
compiler has moved 200 versions.

Three properties are load-bearing.

**Every implementation prints the same bytes, and that is checked before any
timing is believed.** A benchmark whose implementations disagree is timing two
different programs, and the disagreement always surfaces as a flattering number
for whichever one is doing less work. A mismatch is printed loudly and the row
is dropped from the timing table — never normalized away, because normalizing
is where a gate stops looking.

**Numbers are reported as bands.** Wall clock is a median plus its range. Peak
RSS is a band for a harder reason: it is quantized (the region allocator
doubles) and above a few GB it stops reproducing at all — the same binary on
the same input has read 6.2 GB and 15.8 GB on consecutive runs.

**A deterministic column sits next to the non-deterministic one.** For Mere,
`default-region alloc` is the region allocator's cumulative byte count from
`MERE_REGION_STATS`, and it is a function of the program rather than of the
machine. When it and peak RSS disagree about whether something changed, it is
the one to believe. It is also the only number here that CI is allowed to
gate on.

That is measured, not assumed. The first CI run of this suite read, against
a development machine on macOS/arm64 with Apple clang 21:

| benchmark | macOS arm64, clang 21 | Linux x86_64, gcc 13.3 |
|---|---|---|
| `churn` | 43,298,448 | 43,298,448 |
| `crc32` (vecint) | 67,109,088 | 67,109,072 |
| `wordfreq` | 27,334,712 | 27,334,696 |

Different architecture, different OS, different C compiler, and `churn` — the
only one of the three that takes no file path — agrees to the byte. The other
two differ by 16 bytes, which is **not** platform noise: `alloc_total` counts
the argv strings too, and the two checkouts live at paths of different
lengths. Lengthening the path by 31 characters moves the number by 32 (the
allocator rounds to 8), which is how that was confirmed rather than assumed.

So the number is a pure function of the program *and its literal inputs*. Keep
enough headroom in a bound to absorb a path — the bands here have megabytes of
it, against tens of bytes of variation.

**Absent toolchains are skipped out loud.** A suite that quietly omits the fast
competitor reads as a win.

## The MoonBit row

Every other implementation here is either a systems language with manual or
ownership-based memory (C, Rust), a garbage-collected static language with a
mature runtime (Go), or a dynamic runtime (Node, Ruby, Python). None of them is
what Mere actually is: **a young statically-typed ML-family language that
compiles to native and to Wasm**. MoonBit is, which makes it the most direct
comparison in the table — and its native backend lowers to C, so a gap against
it is a codegen or representation difference rather than an optimizer one.

It is built `--release --target native`. The default is a debug build, and a
debug build in a performance table measures the wrong artifact while looking
exactly like the right one.

MoonBit builds a *project* — a `moon.mod`, a package declaring itself
executable, and the source under `cmd/main`. Every other row here is one file
and one command, and keeping that true for a reader is worth more than matching
the toolchain's shape, so `ref.mbt` is one file and the runner writes the
project around it. `mbt_imports` in the MANIFEST names the core packages that
file needs.

**Three workloads have no MoonBit row yet.** `crc32`, `wordfreq` and `json`
read a file, and MoonBit's core library has no file I/O — that lives in
`moonbitlang/x`, a separate dependency this suite does not fetch. Adding it is
the next step if those rows are wanted; until then their absence is stated
here rather than left to be noticed.

The toolchain is not installed on CI, so the MoonBit rows skip there and the
record says so. A skipped row is a comparison not made — the same-answer count
drops from 9 to 8 on `binarytrees`, visibly.

## Naming the other side

"Faster than Go" is not a statement. "Faster than `go version go1.22.0
darwin/arm64` on this workload" is. The runner prints the version of every
implementation in the header of every report, and the build flags for the
compiled ones, for that reason.

## The workloads

| | shape | why it is here |
|---|---|---|
| `crc32` | compute-bound over a byte stream, almost no allocation | Mere lowers to C and the same clang compiles both, so the honest expectation is a **tie with C**, and it is one. `bench_vecint.mere` is the same algorithm over the other byte API and is 2.7x slower on 12x the memory — the pair of rows is the measurement. |
| `wordfreq` | read text, count words in a hash table, rank, exit | The shape most short-lived programs actually have, and the one the region model should be **good** at: allocate freely, never give anything back, exit. |
| `churn` | a long-lived table under insert/delete churn, bounded live set | Was the shape Mere was structurally **bad** at — `map_delete` was O(live) and this row came out behind Python. Fixed in v0.1.317/320; kept because `bench_regionloop.mere` sits next to the naive version and shows what a region loop costs and buys. |
| `startup` | the smallest useful program: one argument in, one answer out | The **strongest claim**, and the one no other row measures — every other workload here does enough work to bury process startup. What is left is the cost of *being* a program: runtime init, a GC's first heap, an interpreter parsing its own stdlib. |
| `binarytrees` | allocate a great many small nodes, walk them, discard them | The row that **splits**. Bump allocation with no collector to trace should win on time; never handing anything back should lose on footprint. `bench_region.mere` is the language's answer and here it costs nothing — a block copies only its result out. |
| `matmul` | dense double-precision multiply-accumulate, 512x512 | The **floating-point** axis, which nothing else here touches — and the one where getting the implementations to agree was most of the work. Expected to tie C, and exists to notice the day it stops. |
| `json` | parse with the ecosystem's parser, then walk the whole tree | A **different question**: `contrib/json` is written in Mere, and every other row's parser is native code shipped with its runtime. "A language plus what its ecosystem hands you" is a real question, and not the one the rest of the suite answers. Read it twice — subtract startup and the ordering changes. |

Every benchmark's `MANIFEST` carries a `claim` that says what the workload is
supposed to show, including the ones where the answer is unflattering. A suite
that only carries workloads its subject wins is not a measurement.

Where a reference implementation is deliberately absent, the MANIFEST says so
and why — `wordfreq` has no C row because hand-rolling a hash table in C would
compare hash tables rather than languages, and Rust's `HashMap` already answers
the systems-language question.

## Reading a sweep

A single row says how long something took. A sweep says what it is a *function
of*. `churn`'s sweep holds the operation count fixed and doubles the live set;
an implementation whose delete is O(1) draws a flat line and one whose delete
shifts the table draws a doubling one. That is not visible in any single
measurement, however carefully it is banded.

## Adding a benchmark

Create a directory with a `MANIFEST` and at least `bench.mere`:

```
name  = mybench
shape = one line, printed as the section heading
args  = $DATA/something          # $DATA is benchmarks/data
claim = what this workload is supposed to show, including if the answer is bad
alloc_min = ...                  # optional deterministic band, both directions
alloc_max = ...
sweep_axis = what the sweep varies
sweep = 1000 1 | 1000 2 | 1000 4 # optional
```

Reference implementations are found by filename: `ref.c`, `ref.rs`, `ref.mbt`,
`ref.go`, `ref.js`, `ref.rb`, `ref.py`. `cflags` in the MANIFEST is passed to the C row's
compiler (and only to it) — a flag that decides whether the answers match is
part of naming the implementation, so it lives next to the claim. Extra Mere variants are `bench_<name>.mere` and
appear as their own rows — that is how `churn` shows the naive program and the
region-loop program side by side.

**If the answer is a float, expect the same-answer check to be the hard part.**
`a*b + c` may be contracted into one fused multiply-add, which rounds once
instead of twice, and clang does it by default on arm64 while Go's gc does it
on arm64 too. `matmul` pins both — `-ffp-contract=off` for C, the `float64()`
conversion the Go spec names for Go — and both were verified load-bearing
rather than assumed: without them those rows print a checksum 24 ulps off
everyone else. Mere needs neither, because it emits
`#pragma STDC FP_CONTRACT OFF` itself, and the runner deliberately does not
pass the flag to Mere's own cc: the bit-identity is evidence the pragma works,
and only while nothing else is producing it. Print the IEEE-754 bits rather
than a formatted double, and choose inputs that actually round — values that
happen to be exact agree whether or not anything fused, and the check passes
for the wrong reason.

Three things to get right, all of them learned by getting them wrong here:

1. **End the program with `exit 0`.** Mere echoes its final expression and
   `print` evaluates to unit, so without it the process emits a trailing `()`
   that no other implementation emits, and the same-answer check becomes a
   normalization instead of an equality.
2. **Make the answer a function of the data**, not of the loop counter — read
   the structure back at the end. An answer the optimizer can fold is a
   benchmark the optimizer can delete.
3. **Reach for the right builtin, and check that it is the right one.** The
   first `crc32` here used `read_file_bytes`, whose `Vec[R, int]` spends eight
   bytes on every byte, and reported Mere at 2.9x C on 12x the memory. The
   stdlib reference says "prefer `read_bytes`" in that builtin's own table row.
   A benchmark measures whatever it was written against, and an unflattering
   number is not self-evidently the language's fault — check the API before
   filing the finding.
4. **Give inputs a distribution with a shape.** `wordfreq`'s first generator put
   half of 300,000 occurrences on one word and touched 885 of a 5,000-word
   vocabulary; a hash table that small had stopped being part of what was
   measured.

Inputs are generated, not committed: `gen_data.py` builds them from a fixed
seed, so the same bytes appear on every machine. The generator is Python on
purpose — generating the input with Mere would close a loop in which a Mere bug
changes the input and every implementation then agrees on the wrong answer.

`benchmarks/data/` and `benchmarks/.build/` are generated and git-ignored.

## A note on what the rows have cost to get right

Three of the seven workloads were **predicted wrong** before they were run.
`crc32` was written against the wrong byte API and reported Mere at 2.9x C
until that was found. `json` was expected to be an easy loss for a parser
written in Mere and is the fastest row on wall clock. `binarytrees` was
expected to trade time for footprint, and the region-block version turned out
to win both.

That is the argument for the suite existing rather than an embarrassment about
it. Every one of those was a belief held confidently enough to write down, and
the only thing that moved any of them was a number.
