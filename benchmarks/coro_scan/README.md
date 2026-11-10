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
