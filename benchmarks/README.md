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
| `churn` | a long-lived table under insert/delete churn, bounded live set | The shape Mere is structurally **bad** at, kept for that reason. `bench_regionloop.mere` is the language's answer, in the table next to the naive version. |

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

Reference implementations are found by filename: `ref.c`, `ref.rs`, `ref.go`,
`ref.js`, `ref.rb`, `ref.py`. Extra Mere variants are `bench_<name>.mere` and
appear as their own rows — that is how `churn` shows the naive program and the
region-loop program side by side.

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
