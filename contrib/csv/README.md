# contrib/csv — CSV parser / writer

A reduced RFC 4180 CSV parser and writer. Supports quote (`"..."`) and escape
(`""` → literal `"`); line break is `\n` only (no CRLF). Zero external deps;
self-contained on stdlib (`str_*` / `char_at` / `is_*`).

## Files

| file | export | lines |
|---|---|---|
| `parser.mere` | `module Csv { parse_csv: str -> str list list }` (plus the step functions `parse_row` / `parse_field` / `parse_quoted` / `parse_bare`) | 96 |
| `writer.mere` | `type Person` + `module CsvWriter { needs_quote, escape_field, row_of, header, render }` | 52 |

Both files are main-free. A runnable writer demo is
[examples/csv_writer_demo.mere](../../examples/csv_writer_demo.mere).

## Usage

```mere
import "contrib/csv/parser.mere";

let rows = Csv.parse_csv "id,name\n1,alice\n2,bob" in
match rows with
| Cons (header, body) -> ...
| Nil -> "empty"
```

Or copy-paste:

```sh
cp contrib/csv/parser.mere my_project/
```

## Scope

- field separator: `,`
- line separator: `\n` (CRLF not supported for now)
- quoted field: include `,` `\n` in a field by wrapping with `"foo,bar"`
- escaped quote: `""` represents literal `"`
- bare field: no trimming (whitespace preserved)

## Known limitations

- CRLF (`\r\n`) not supported
- the writer quotes a field only when it contains `,` or `"`; a field
  containing a newline is written unquoted
- `writer.mere` is bound to the fixed `Person { name; age; city }` record —
  generalization is future work (per-record polymorphism not implemented; a
  generic API like `record_to_csv` waits on trait / row poly). Since Phase 42
  unblocked record-type-in-module in C codegen, the helpers are wrapped in
  `module CsvWriter`.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-csv` (separate repo), after public release + pkg manager lands.
