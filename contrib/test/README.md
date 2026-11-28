# contrib/test — minimal unit test framework

`assert_eq` / `assert_true` / `assert_false` + suite counters + aggregated
failure log. Uses the polymorphism of the `show` builtin to compare int / str
/ bool / variant / tuple all through the same API. Namespaced as
`module Test { ... }`.

## Files

| file | export | lines |
|---|---|---|
| `test.mere` | `module Test { new_suite, assert_eq, assert_true, assert_false, summary, exit_status }` | 86 |

## Usage

```mere
import "contrib/test/test.mere";

let s = Test.new_suite () in
let _ = Test.assert_eq s "1 + 1 = 2"   2 (1 + 1) in
let _ = Test.assert_eq s "concat"      "hi" ("h" ++ "i") in
let _ = Test.assert_true s "5 > 3"     (5 > 3) in
let _ = Test.assert_eq s "wrong value" 42 41 in
let _ = Test.summary s in
exit (Test.exit_status s)   // exit code: 0 if all pass, 1 if any fail
```

`exit_status` returns the code; it does not end the process. Leaving it as
the program's last value only prints it, so pass it to `exit` when the
exit code matters (CI, shell pipelines). A complete demo is
[examples/test_framework_demo.mere](../../examples/test_framework_demo.mere).

Example output:
```
  ok | 1 + 1 = 2
  ok | concat
  ok | 5 > 3
FAIL | wrong value

--- 3/4 passed ---
FAIL | wrong value
  expected: 42
  actual:   41
```

## API

| fn | signature | purpose |
|---|---|---|
| `new_suite` | `unit -> suite` | initialize suite (counters Map + StrBuf log) |
| `assert_eq` | `suite -> str -> 'a -> 'a -> unit` | compare via `show x == show y` |
| `assert_true` | `suite -> str -> bool -> unit` | passes if cond is true |
| `assert_false` | `suite -> str -> bool -> unit` | passes if cond is false |
| `summary` | `suite -> unit` | print pass/fail/total |
| `exit_status` | `suite -> int` | all pass = 0, any failure = 1 (for CI; pass it to `exit`) |

## Backend support

| backend | status |
|---|---|
| interp | ✓ |
| C | ✓ |
| LLVM | ✓ |
| Wasm | ✓ (Phase 43 added Map case to `ty_tag`; Map can be carried in closure env / tuple slot) |

## Limitations (MVP)

- Multi-instantiation: calling `assert_eq` with different types (int + str +
  bool) in one test program is OK (Phase 43 fixed DEFERRED §1.7 so chained
  poly inst follows through)
- No test grouping (describe/context)
- No parallel execution (assertions run in order on the calling thread)
- No setup/teardown hooks
- `fail` is not caught (if user code `fail`s, the runner also goes down) —
  wrap the code under test in `try_or` / `try_or_msg` yourself for now

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-test` (separate repo, after pkg manager lands).
Integration like OCaml's Alcotest or Rust's `cargo test` is future work.

Future ideas:
- snapshot tests (`assert_matches_snapshot`)
- property-based tests (QuickCheck-style)
- benchmark mode (measure via `time` builtin)
