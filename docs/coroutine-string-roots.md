# Candidate string roots

`coro_scan_strings c candidates visit` reports a conservative subset of an
immutable `str list` whose values may still be used by coroutine `c`.
Collectors supply names stored in their own metadata, such as class names.
The candidates must be built on the collector's stack, separately from the
suspended stack being inspected; otherwise the candidate registry is itself
a conservative root.

On C, a suspended coroutine reuses the pointer set already gathered for
arena pinning or integer-root discovery. Its reach follows live region
blocks, with the same ownership and foreign-hop bounds as `coro_scan_ints`.
Candidate strings match by their full byte content and length, so promotion
copies and embedded zero bytes are handled. Length headers and interior/end
pointers retained by optimization count too. Unknown machine words are
checked against allocated spans before any bytes are read. Values occurring
in compiled string literals are always retained conservatively.

All matches are gathered before callbacks run. Callbacks may allocate,
compact unrelated containers or fail. Candidate copies and scratch indexes
use the calling region; put a repeated collector pass in a scratch region.

A running C coroutine, the interpreter, LLVM and RISC-V conservatively report
all candidates. A finished or unstarted C coroutine reports none. Callers
must tolerate extra matches, including duplicate candidate entries. This API
does not promise precise liveness or inspect arbitrary foreign allocations.

`test/coro/scan_strings.mere` covers copied and binary names, static strings,
callback allocation and running stacks. Native sparse/header fixtures check
that unused registry entries do not keep themselves alive and that an
optimized length-only use still keeps its string. `scripts/coro_check.sh`
runs these with the existing coroutine and RSS gates.

The RISC-V gate executes `scan_strings.mere` at both widths, including its
allocating callback. `scan_strings_conservative.mere` checks the all-candidate
contract on the interpreter, LLVM, RV32 and RV64: unstarted, running,
suspended and finished targets, empty lists, duplicates, binary bytes
and partial application. C keeps its separate sparse-root contract. At both
RISC-V widths, poison probes omit the callback, omit the list tail or replace
candidate bytes; each must make the conservative fixture fail.

The native repeated-scan check runs `scan_strings_repeated.mere` with 1,000
and 4,000 unused candidates, one changing live name and 32 versus 256 rounds.
Each round switches the coroutine, scans strings, scans integer roots, then
scans strings again into a fresh result map. Named scratch regions enclose
candidate registries, results and scan storage. Measurements after warmup and
at completion bound registered region capacity and default-arena allocation;
O2 also compares peak RSS between short and long runs. RSS is diagnostic in
sanitizer runs because their allocation quarantine has a separate policy.

`python3 scripts/coro_scan_stability_check.py` runs O0, O2 and ASan/UBSan modes
and checks controls for scan storage escaping to the default arena, an omitted
scratch release, missing root matches and stale pin caches after a switch.
It runs inside the existing required coroutine CI gate.

The C walker consumes sorted pin words and visits overlapping header search
windows once. A valid header seen for an earlier word either contained that
word's address or ended before it; in the latter case it cannot match a later word. Allocation
span boundaries and current-region high-water marks still bound every read.
The cursor is local to one scan and does not survive coroutine switches or
callback execution.

See [the scan scaling benchmark](https://github.com/merelang/mere/tree/main/benchmarks/coro_scan) for phase
measurements and its independent reference walker. The required coroutine
gate runs its deterministic reference, operation-count and mutation checks;
timing differences do not decide whether CI passes.
