# Candidate string-root scan scaling

```sh
dune build bin/mere.exe
python3 benchmarks/coro_scan/run.py --reps 9 --output scan-results.json
python3 benchmarks/coro_scan/run.py --verify-only
```

`--mere PATH` selects a compiler for before/after comparisons; `CC` selects
the native C compiler. JSON records the platform, compiler versions, flags,
emitted-C SHA-256 and every sample. No benchmark products are retained unless
an output file is requested.

The workload independently varies 256/1,024/4,096 unused names, one unused
candidate of 16/256/4,096/32,768 bytes, and 1/8/32 suspended coroutines. Every
coroutine retains a list of 64 distinct binary names. The collector constructs
its candidate registry after all workers stop, and checks all 64 live values
after every scan. Each worker also validates its retained data when resumed.
An additional long unused name expands the header-search window without
multiplying every candidate's copy size.

Registry construction, worker creation and result validation are untimed.
Each process scans every worker 32 times: the first pass gathers its pin set,
and the following passes reuse it. Scratch regions enclose each call's copied
candidates, indexes and result map. Processes do not share caches.

The native driver instruments the compiler's emitted C, checking each
substitution marker. Four internal phases are timed separately:

- `index`: candidate copies, hashing and bucket construction.
- `pin`: literal matching, pin gathering or reuse, and allocation-span setup.
- `search`: string-header discovery and candidate matching.
- `callback`: dispatch and insertion into the result map.

`total` surrounds the public call, including list-to-array conversion and
callbacks. It excludes result-map construction and validation. Timers and
probe counters add measurement overhead; compare the same instrumented
workload and compiler flags. Values are microseconds per scan, with the
median and full range across independent process samples. Peak RSS is a
per-process diagnostic, not a scan's allocation count.

## Recorded comparison

On macOS arm64 with Apple clang 21 at O2, nine independent process samples
compare the runtime before this optimization (source `e1fc0548`) with the
same workload using a cursor over sorted pin words. There are 1,024 unused
short names, 64 live binary names, one extra unused candidate and one worker:

| Extra candidate bytes | Total before / after, median [range] µs | Search before / after, median [range] µs | Header probes per scan before / after |
|---|---|---|---|
| 16 | 18.28 [17.38,22.66] / 18.31 [17.09,20.91] | 2.22 [2.12,2.72] / 2.09 [1.84,3.72] | 517 / 383 |
| 256 | 22.88 [21.59,25.03] / 19.22 [18.88,23.19] | 5.97 [5.69,6.84] / 2.56 [2.44,3.22] | 4,315 / 757 |
| 4,096 | 63.69 [61.12,67.53] / 25.00 [22.94,34.94] | 42.75 [41.22,44.72] / 2.62 [2.31,3.03] | 44,037 / 757 |
| 32,768 | 104.41 [101.50,118.25] / 67.88 [62.22,84.06] | 46.91 [45.72,51.91] / 3.25 [2.94,5.03] | 49,466 / 757 |

The 4,096-byte case improves the complete measured call by about 2.5x, rather
than the roughly 16x improvement of its search phase. Copying and indexing
large candidates remain work the API performs. Short-candidate totals have
overlapping ranges; this record does not establish a speedup there. Increasing
the number of workers still repeats the registry's indexing for every call.
Search work saturates when a window reaches the start of the worker's live
allocation span; it does not continue growing indefinitely with candidate
length. Timings describe this workload and machine, not a general throughput
guarantee.

The same emitted C also passed the workload and reference/control checks on
Ubuntu 24.04 amd64 with clang 18 in Docker on an arm64 host. The 4,096-byte
case's header visits fell from 44,551 to 757 there. Those timings include
architecture emulation and are not presented as native Linux performance.

## Deterministic checks

`--verify-only` runs all nine workloads at O2 and under ASan/UBSan, with eight
passes per worker. Every process first compares the optimized walker with
an independent per-word reference on 1,136 cases. These include header,
interior and end references, binary and empty strings, duplicate words,
overlapping windows, invalid addresses, gaps between spans, malformed headers
and unused capacity beyond a current region's top. Match sets must agree.

The synthetic reference fixture also bounds the total header probes by its
allocated search span sizes. Removing the cursor update must violate that
bound; advancing it by two words must lose a reference match. Both mutations
run at O2 and under sanitizers. Each must produce its specific oracle witness;
timeouts, compilation failures and sanitizer failures are not accepted.

The existing required coroutine gate runs these checks alongside the repeated
scan memory bounds and full coroutine poison sweep. Wall-clock values and
RSS do not have pass/fail thresholds in this benchmark.

## Live-allocation snapshot updates

Pin and root scans also consult a sorted snapshot of the live region blocks.
After the first scan, the generated C runtime records up to 64 thread-local
block additions/removals. A scan with an unchanged shared-list generation
applies that short log by binary insertion/removal instead of walking and
sorting every live block again. A full log, a shared-list change, or an
inconsistent delta falls back to the complete locked registry walk and sort.

The log captures block bounds before the block can be freed or reallocated;
replaying an add/remove pair does not dereference its old header. New block
capacity is initialized before registry publication. The bounded log is TLS
storage, and recording starts only after a first scan. Programs without the
coroutine scanner keep the hook unset. Reachability depth, pin decisions,
region retirement and scan callbacks retain their existing semantics.

```sh
python3 scripts/coro_scan_index_check.py
python3 scripts/coro_scan_stability_check.py
sh scripts/coro_check.sh --poison
```

The index contract compares each snapshot with an independently walked live
registry, including local additions/removals, batches of freed/reused blocks,
dedicated-block growth, log overflow, another thread's shared allocations and
TLS isolation. It requires short local updates to avoid full sorting. Both
executable and library runtime modes run at O2 and under ASan/UBSan. Removing
add/remove recording, accepting a stale shared list, accepting a truncated
log, or publishing a resized block before its capacity is ready must produce
the specific count/bounds/performance assertion witness; a crash or
timeout alone is not accepted. CI runs this as its own coroutine gate.

The downstream `mere-ruby` Enumerator workload at source `12ca1df2` was built
at O2 with the parent compiler `b1a49f33` and with this index change. Three
fresh processes per size and compiler, alternating control/candidate, on local
arm64 macOS 26.7.1 with Apple Clang:

| Generators | Control median [range] seconds | Candidate median [range] seconds | Median peak RSS control / candidate MiB |
|---:|---:|---:|---:|
| 1,000 | 1.189 [1.035, 1.244] | 0.535 [0.480, 0.776] | 281.31 / 280.16 |
| 2,000 | 4.750 [4.486, 4.915] | 2.440 [2.438, 2.526] | 340.50 / 340.19 |
| 4,000 | 19.731 [16.707, 21.653] | 9.839 [8.591, 10.519] | 410.61 / 411.09 |

The workload repeatedly steps and drops generators while retaining another
generator across the loop; every result must match Ruby 4.0.9. Times include
startup and still grow faster than linearly: the change reduces snapshot work,
not all coroutine pin/reachability costs. These are local measurements, not an
end-to-end CI speedup. The reproducible workload is
[`bench/enumerator_steps.rb`](https://github.com/284km/mere-ruby/blob/244ca028/bench/enumerator_steps.rb).

## Unsigned pin-word sorting

Large coroutine pin lists now use stable least-significant-byte radix passes
instead of comparison sorting. A pass is skipped when every input has the same
byte. Lists below 256 words keep `qsort`; an unsuccessful scratch allocation
also falls back to `qsort` before changing any input. Scratch is one temporary
array, freed before returning. The sorted unsigned sequence retains every
word and its multiplicity, including duplicates and high bits. Pin collection,
reachability, cache invalidation and region retirement are unchanged.

Both pin collection paths use the same helper: direct pin gathering and the
pin collection performed by a suspended coroutine's integer-root scan.

```sh
python3 scripts/coro_pin_sort_check.py
```

The contract compares the entire output against an independent comparison
sort, including empty/singleton lists, the 255/256/257 boundary, full-width
random values, duplicate-heavy inputs, sorted/reverse order, common high bytes
and one varying byte at every position. Guard words must remain untouched;
large varying inputs must avoid `qsort`, fallback must work under forced
allocation failure, and scratch must be released after every call. Executable
and library runtime modes run at O2 and under ASan/UBSan.

Six mutations must each produce their specific assertion witness: skipping
the highest byte, an unstable digit pass, omitted copy-back, broken allocation
fallback, retained scratch, and replacing the large-list path with comparison
sorting. Crashes without that witness and timeouts do not count as detection.
CI runs this as its own required coroutine gate.

The same downstream source (`12ca1df2`) and O2 build were compared again on
arm64 macOS 26.7.1 with Apple Clang, using the previous snapshot-update runtime
(`40761fb8`) as control and adding only pin-word sorting. Three fresh processes
per size and compiler alternated control/candidate, reversing order in the
second repetition. The full regression workload finished before timing began.
All outputs matched Ruby 4.0.9, including the generator retained across the loop.

| Generators | Previous runtime median [range] seconds | With radix sorting median [range] seconds | Median peak RSS previous / radix MiB |
|---:|---:|---:|---:|
| 1,000 | 0.515 [0.502, 0.562] | 0.460 [0.408, 0.509] | 280.94 / 280.92 |
| 2,000 | 2.660 [2.657, 2.700] | 1.966 [1.914, 1.971] | 340.03 / 340.89 |
| 4,000 | 9.318 [9.192, 9.387] | 6.977 [6.855, 7.619] | 411.98 / 412.48 |

At 4,000 generators the median is 25.1% shorter than the already optimized
snapshot runtime, with comparable peak RSS. These fresh paired measurements
isolate the sorting change; the earlier snapshot table is a separate run.
Times include startup and still grow faster than linearly. No end-to-end CI
speedup or linear scaling is claimed.
