# contrib/prop — generated inputs for the differential gates

The suite's value-axis gates (`str_edges`, `coll_edges`, `index_edges`,
`refusals`) were written by enumerating interesting values by hand. That
enumeration found real defects, which is the argument for having done it. It is
also the part of the work a machine can do.

This module produces the values. It does not compare them: a property test
written with it is an ordinary parity case, so the other four backends are the
oracle and there is nothing to commit as an expected output.

## Files

| file | export | lines |
|---|---|---|
| `prop.mere` | `module Prop { int_at, small_at, str_at, list_at, digest, str_report, int_call, str_call, bool_call, line }` | ~170 |

## Usage

```mere
import "../../contrib/prop/prop.mere";

let rec loop = fn (i: int) ->
  if i >= 100 then 0
  else
    let s = Prop.str_at i in
    let _ = Prop.line i "in"  (Prop.str_report s) in
    let _ = Prop.line i "rev" (Prop.str_call (fn () -> str_rev s)) in
    loop (i + 1);
print (str_of_int (loop 0))
```

Put the file in `test/parity/` and the harness does the rest.

## Three decisions, each of which is a way this could measure nothing

**It does not use `random_int`.** That builtin asks the host. Five hosts would
draw five different sequences, so every line would report DIFF and the gate
would be reporting on itself.

**Values are a function of an index, not of a carried state.** `int_at i` is
reproducible on its own and threads nothing. Because each printed line carries
its index, a differing line in the parity diff already names the input that
produced it — which is why there is no shrinker here. The smallest reproducer is
`i`, and it is printed. A shrinker starts to earn its keep when an input is a
compound structure whose printed form is too large to read.

**Every intermediate stays below 2^45.** The interpreter's int is 63-bit and the
compiled backends' is 64-bit. A mix that overflowed would overflow differently
on the interpreter and the gate would be noise on every line rather than a
signal on one. For the same reason the gates using this module leave
multiplication and `list_product` out and say so: overflow is the width axis,
not the value axis, and a gate measuring two axes reports the wrong one when
either moves.

## Generators

| function | what it draws |
|---|---|
| `int_at i` | indices below 30 are a fixed table (0, ±1, ±2, either side of 2^7 / 2^8 / 2^15 / 2^16 / 2^31 / 2^32, and 2^32 + 65); beyond that a signed draw, wide or small |
| `small_at i` | 0..11, for counts and indices |
| `str_at i` | indices 0..3 are `""`, `" "`, `chr 0`, `"a\0b"`; beyond that 0..8 bytes drawn from a pool that includes NUL, backslash, quote, and UTF-8 lead and continuation bytes |
| `list_at i` | index 0 is `Nil`; beyond that 0..6 elements from `int_at` |

The edge tables are not a draw. Every integer defect this suite has found sat on
one of those values, and a uniform draw over the whole range reaches them with
probability about zero — a generator that only drew would be weaker than the
hand-written gates it extends.

NUL is in the byte pool on purpose. It was a real divergence for two backends,
and a corpus that leaves it out is the "reach agreement by declining to ask"
failure.

## Reporting

A generated string is never printed raw: control bytes and NUL would travel
through four different runners on the way to the diff and the gate would end up
measuring the runners. `str_report` prints `length:digest`.

`int_call` / `str_call` / `bool_call` wrap the call in `try_or`, because a
refusal is an answer and the four backends were only recently made to refuse in
the same words. A case one backend answers and three refuse is exactly the shape
this looks for; without `try_or` it would abort the run instead of printing a
difference. `str_call` asks whether the call succeeded before asking what it
returned, rather than substituting a marker string — a marker is itself a
string, and `str_unescape` over this pool can produce any byte at all.

## What the first run found

Five defects, all of the same family: code that was correct while a str ended at
its first NUL and silently wrong after v0.1.264 gave a str a length header.

- `str_contains` on C and LLVM (`strstr`) — a needle beginning with NUL matched
  every haystack
- `str_index_of` on LLVM (`strstr`) — same, answering 0 instead of -1
- `str_starts_with` on LLVM (`strncmp`, and no length check on the haystack) —
  the only one of the four starts/ends implementations across the two backends
  written that way
- `str_join` on C — the sizing pass asked `__lang_str_size` and the copying pass
  asked `strlen`, so an element containing a NUL was measured at its full length
  and copied only up to the NUL
- `str_ptr` and `__lang_read_lines` on C — found by sweeping every `strlen` in
  the backend after the first four, rather than waiting for a gate to point at
  them

And two that are recorded rather than fixed, each in its own pinned case:
`test/parity/prop_utf8.mere` (UTF-8 character splitting: the interpreter says
`"A" ++ chr 128` is two characters and the three compiled backends say one) and
`test/parity/llvm_loop_guard_global.mere` (a loop bounded by a top-level binding
stops after one iteration on LLVM).
