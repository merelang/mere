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
