# contrib/toml — TOML 1.0 reduced parser

A TOML parser written in Mere. Intended use is reading config files.

## Usage

```mere
import "contrib/toml/toml.mere";

let input =
  "title = \"My App\"\n" ++
  "[server]\n" ++
  "host = \"localhost\"\n" ++
  "port = 8080\n";

let doc = Toml.parse_toml input in
match Toml.get doc "server.host" with
| Toml.TStr s -> print s
| _ -> ()
```

`toml.mere` still carries its self-test at the bottom of the file, outside
`module Toml`, so a program that imports it also prints the self-test
report (`=== Toml === ... === Toml self-test done ===`) before its own
output.

## API

| fn | type | content |
|---|---|---|
| `Toml.parse_toml` | `str -> (str * toml_value) list` | input → list of fully-qualified key/value pairs (in source order) |
| `Toml.get` | `(str * toml_value) list -> str -> toml_value` | lookup by key; `fail` if not found |
| `Toml.has` | `(str * toml_value) list -> str -> bool` | check key presence |

`toml_value`:

```mere
type toml_value =
  | TInt  of int
  | TStr  of str
  | TBool of bool
  | TArr  of toml_value list;
```

## Supported subset

| feature | status |
|---|---|
| key/value (`key = value`) | ✓ |
| section header (`[section]`) | ✓ |
| dotted section (`[a.b.c]`) | ✓ (key flattened to `a.b.c.k`) |
| integer (`42` / `-7`) | ✓ |
| basic string (`"text"` + escape `\"` `\\` `\n` `\t`) | ✓ |
| bool (`true` / `false`) | ✓ |
| array (`[1, 2, 3]`, primitives + nested arrays) | ✓ |
| comment (`# ...` to EOL, ignored inside strings) | ✓ |
| empty line / leading whitespace | ✓ (skipped) |

## Unsupported (future Phase or separate lib)

- datetime (RFC 3339: `2026-06-23T19:30:00Z`)
- multi-line basic string (`"""..."""`)
- literal string (`'...'` raw, no escape interpretation)
- dotted key (`a.b = 1` treated as sub-key of top-level table)
- inline table (`{ k1 = v1, k2 = v2 }`)
- table array (`[[name]]` repeating same-named section)
- hex / octal / binary integer (`0xff` / `0o755` / `0b1010`)
- float (`3.14` / `1e10`)
- underscore separator (`1_000_000`)

These will be considered when there's a dogfood that needs them.

## Run example

```sh
dune exec mere -- contrib/toml/toml.mere
# entries: 8
#   title = TStr "My App"
#   ...
#   ✓ server.host == "localhost"
#   ...
```

## Backend support

| backend | status |
|---|---|
| interp | ✓ |
| C | ✓ |
| LLVM | ✓ |
| Wasm | ✓ |

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-toml` (separate repo, after pkg manager lands).
