# contrib/json — JSON parser / writer

JSON parse / serialize library written in Mere. Built on stdlib (`str_*` /
`is_digit` / `try_or` / `fail` / `StrBuf`) + recursive variant + pattern
matching with zero external dependencies.

## Files

| file | export | lines |
|---|---|---|
| `json.mere` | `module Json { type json = JNull \| JBool \| JNum \| JFloat \| JStr \| JArr \| JObj; parse_json: str -> json; as_float: json -> float }` | ~220 |
| `writer.mere` | `type json` (top-level) + `module JsonWriter { to_json_str, to_pretty_str }` | ~135 |

## Usage (before pkg manager lands)

```mere
// Bring in via import (works since Phase 9.5)
import "contrib/json/json.mere";

let v = Json.parse_json "[1, 2, 3]" in
match v with
| Json.JArr xs -> ...
| Json.JNull -> ...
| _ -> ...
```

Or **copy-paste** into a project:

```sh
cp contrib/json/json.mere    my_project/
cp contrib/json/writer.mere  my_project/
```

The self-test block at the end of each file (`run_case` demo, `let doc = …`,
etc.) may be removed in real use.

`writer.mere` was wrapped in `module JsonWriter { ... }` in Phase 43. However,
`type json` is kept **outside the module** (it can't coexist with the parser's
`module Json { type json = ... }` inside a single file, but each file works
independently). To round-trip parser + writer in one program, the user must
avoid `type json` collision (using either parser or writer only is the expected
mode for now).

## Coverage

- atoms: `null` / `true` / `false` / number / string
- composite: array / object
- escape: `\"` `\\` `\n` `\t` `\r` `\/` decoded via `str_unescape`
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
the three in this tree were updated with it. Be aware that only the interpreter
prints that warning — `mere -c`, `-ll` and `-t` are silent — so a `match` in
your own code that this constructor broke will compile and then fail at
runtime, and a wildcard arm returning a default will answer wrongly instead.

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
  as an interpolation start, so escape it with `"\{"` (the json.mere /
  writer.mere demos already apply this workaround)
- **The name `case` collides with a C reserved word** in C codegen
  (libc/C keyword) — this lib renames its own test helper to `run_case`. See
  [docs/reserved-names.md](../../docs/reserved-names.md) for the full reserved-name list.

## Position

Stage 2 contrib (incubation). See lifecycle in [contrib/README.md](../README.md).
After public release + pkg manager lands, graduation target is the separate
repo `mere-json` (internal design notes §3.1).
