# contrib/option — additional helpers for Option type

Mere prelude already provides `option_map` / `option_default` /
`option_is_some` / `option_and_then`. contrib/option bundles **helpers that
complement the prelude** into `module Option { ... }`.

## Files

| file | export | lines |
|---|---|---|
| `option.mere` | `module Option { zip, filter, or_else, is_none, unwrap_or_fail }` | ~60 |

## API (helpers not in prelude)

| fn | signature | use |
|---|---|---|
| `Option.zip` | `'a opt -> 'b opt -> ('a * 'b) opt` | both Some → tuple; either None → None |
| `Option.filter` | `'a opt -> ('a -> bool) -> 'a opt` | drop to None if predicate doesn't hold |
| `Option.or_else` | `'a opt -> 'a opt -> 'a opt` | if left is None, return right |
| `Option.is_none` | `'a opt -> bool` | inverse of `option_is_some` |
| `Option.unwrap_or_fail` | `'a opt -> str -> 'a` | None → `fail msg`; Some → unwrap |

## Usage

```mere
import "contrib/option/option.mere";

// both Some → tuple
let result = Option.zip (Some 1) (Some "a") in
match result with
| Some (n, s) -> ...
| None -> ...

// predicate filter
let big = Option.filter (Some 5) (fn n -> n > 3);   // Some 5
let no = Option.filter (Some 2) (fn n -> n > 3);    // None

// fallback chain
let val = Option.or_else (try1 ()) (try2 ());

// invariant check
let value = Option.unwrap_or_fail maybe_value "invariant violated";
```

## Known gotchas

- **A bare `None` used to need an annotation** on the compiled backends
  (`Option.is_none None` failed in C codegen with the type not pinned, and
  `(None: int option)` was the workaround). That is no longer the case:
  `Option.is_none None` compiles and runs on interp / C / LLVM / Wasm. The
  annotation is still accepted and harmless.

## Backend support

| backend | status |
|---|---|
| interp | ✓ |
| C | ✓ |
| LLVM | ✓ |
| Wasm | ✓ |

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-option` (separate repo) — or alternatively, fold
into prelude and drop the library (`zip` / `filter` / `or_else` are standard
in other functional languages).
