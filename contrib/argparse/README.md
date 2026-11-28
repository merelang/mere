# contrib/argparse — minimal CLI argument parser

A minimal parser that splits the `str list` returned by Mere's `args()` builtin
into flags / options / positional. Namespaced as `module Argparse { ... }`.

## Files

| file | export | lines |
|---|---|---|
| `argparse.mere` | `module Argparse { parse, has_flag, get_opt, get_pos }` (plus the helpers `list_has`, `strip_double_dash`, `split_eq`) | 118 |

## Usage

```mere
import "contrib/argparse/argparse.mere";

let argv = args () in
let flag_specs = Cons ("verbose", Cons ("dry-run", Nil)) in
let opt_specs = Cons ("output", Cons ("config", Nil)) in
let r = Argparse.parse flag_specs opt_specs argv in

let _ = if Argparse.has_flag r "verbose" then print "verbose mode" else () in
let out = Argparse.get_opt r "output" "default.bin" in
let positional = Argparse.get_pos r in
...
```

The library file is main-free (importing it runs nothing); a runnable demo is
[examples/argparse_demo.mere](../../examples/argparse_demo.mere).

## Supported syntax

| syntax | meaning |
|---|---|
| `--verbose` | flag (if listed in flag_specs) |
| `--name value` | option (if listed in opt_specs; next token is value) |
| `--name=value` | option (= delimiter) |
| `--` | everything after treated as positional (POSIX convention) |
| `foo.txt` | positional |

## Return value (tuple)

```
(flags: Map[__heap, str, int],     // entry present = flag set (value is 1)
 opts:  Map[__heap, str, str],     // option name -> value
 pos:   str list)                  // positional, order preserved
```

## MVP limits

- short names (`-v`) not supported — long name (`--verbose`) only
- type conversion is up to the caller (e.g. `int_of_str (Argparse.get_opt r "n" "0")`)
- no auto-generated help message
- unknown `--foo` treated as positional (will become an error in the future)
- an option given last with no value (`--output` at the end of argv) is ignored

## Implementation notes

Initially an inner helper `let push_pos = fn s -> strbuf_push pos s` was used,
but DEFERRED §8 (inner-lifted fn's closure capture leaks through anonymous Fun)
caused failure in C codegen. Worked around by rewriting `strbuf_push` to inline
calls.

Also, using `default` as a function parameter name collides with C reserved
words and causes codegen failure ([docs/reserved-names.md](../../docs/reserved-names.md) §1.1).
In this lib, the `get_opt` argument is named `dflt` instead.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-argparse` (separate repo, after pkg manager lands).
`mere-argparse` will add short names / auto-generated help / sub-commands etc.
