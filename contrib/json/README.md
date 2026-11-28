# contrib/json — JSON parser / writer

JSON parse / serialize library written in Mere. Built on stdlib (`str_*` /
`is_digit` / `try_or` / `fail` / `StrBuf`) + recursive variant + pattern
matching with zero external dependencies.

## Files

| file | export | lines |
|---|---|---|
| `json.mere` | `module Json { type json = JNull \| JBool \| JNum \| JFloat \| JStr \| JArr \| JObj; parse_json: str -> json; to_json_str: json -> str; to_pretty_str: json -> str; escape_str: str -> str; as_float: json -> float }` | ~320 |

The parser and the writer live in the same module and share one `Json.json`
type, so a parsed value can be written back out directly.

## Usage (before pkg manager lands)

```mere
// Bring in via import (works since Phase 9.5)
import "contrib/json/json.mere";

let v = Json.parse_json "[1, 2, 3]" in
match v with
| Json.JArr xs -> ...
| Json.JNull -> ...
| _ -> ...

// Write it back: compact or pretty-printed
Json.to_json_str v      // "[1,2,3]"
Json.to_pretty_str v
```

Or **copy-paste** into a project:

```sh
cp contrib/json/json.mere    my_project/
```

`json.mere` is module-only: it has no self-test block, so importing it prints
nothing. The writer used to be a separate `writer.mere` with its own top-level
`type json`, which made parse-then-write impossible in one program; it has
been merged into `module Json`.

## Coverage

- atoms: `null` / `true` / `false` / number / string
- composite: array / object
- escape: `\"` `\\` `\n` `\t` `\r` `\/` decoded via `str_unescape`
- writer: `to_json_str` (compact) / `to_pretty_str` (two-space indented
  objects); `escape_str` escapes `"` and `\` only (a newline or other control
  character in a `JStr` is written raw, which is not valid JSON)
- **Unsupported**: unicode `\uXXXX`

### Two number constructors, on purpose

JSON has one number type and this has two. A number written with a decimal
point or an exponent parses as `JFloat of float`; one written as an integer
stays `JNum of int`. **Which one you get is decided by how the number was
written, not by its value** — `1.0` is a `JFloat` and `1` is a `JNum`.

Three reasons, and the third is the one that decided it:

1. A single float constructor would silently change every existing reader.
2. `to_json_str` would stop round-tripping: `12` would come back as `12.0`.
3. The documents this is pointed at distinguish the two. An array index, a byte
   offset and a glTF accessor's `count` are integers and have to stay exact; a
   colour component and a node's translation are not.

`Json.as_float` widens either, for readers that do not care.

**Adding `JFloat` made every existing `match` over `json` non-exhaustive**, and
the three in this tree were updated with it. A non-exhaustive `match` is now a
compile error on every backend, so a `match` in your own code that lacks a
`JFloat` arm is refused rather than failing at runtime — but a wildcard arm
returning a default still compiles, and will answer wrongly for a `JFloat`.

### Deviations from strict JSON

- **Leading zeros are accepted**: `01` parses as `1` where the grammar forbids
  it. Pre-existing, and left alone by the v0.1.446 float work rather than
  changed as a side effect of it — a parser getting *stricter* is a separate
  decision from a parser getting a feature, and belongs in its own change.
- An overflowing literal such as `1e400` becomes an infinity, which
  `to_json_str` would then write as `inf`, which is not JSON. Refusing at write
  time would be refusing in the wrong place.

## Known gotchas

- **String literal containing `{`**: Phase 36 string interpolation treats `"{"`
  as an interpolation start, so escape it with `"\{"` (the writer in json.mere
  already applies this workaround)
- **C reserved words**: top-level `let` names are prefixed by every backend,
  so a helper called `case` is fine; only a `type` named after a C keyword or
  libc name collides. See [docs/reserved-names.md](../../docs/reserved-names.md)
  for the full list.

## Position

Stage 2 contrib (incubation). See lifecycle in [contrib/README.md](../README.md).
After public release + pkg manager lands, graduation target is the separate
repo `mere-json`.
