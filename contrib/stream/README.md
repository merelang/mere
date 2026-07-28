# contrib/stream — region-scoped line streaming

`module Stream { each_line, count_lines }` — process a file one line at a time
in **O(longest line)** memory instead of O(file).

```mere
import "contrib/stream/stream.mere";

// grep-style: print matching lines (side effect inside the per-line scope)
Stream.each_line "big.txt" (fn line ->
  if str_contains line "needle" then print line else ());

// count lines satisfying a predicate
let n = Stream.count_lines "big.txt" (fn line -> str_len line > 80);
```

## Why it exists

A plain streaming loop keeps every line for the whole run: a `str` carries no
region tag, so the escape checker must assume each line may escape and keeps it
in the program-lifetime region. Over a large file that accumulates to O(file).

Each combinator instead reads and processes a line **inside a `region` block**
and returns only an escape-clean value (unit for `each_line`, an `int` count
for `count_lines`) from the block, so the existing region-reclaim machinery
frees each line before the next is read.

Measured on a 57 MB / 1,000,000-line input, native (C) backend:

| approach                       | peak RSS |
| ------------------------------ | -------- |
| plain streaming loop           | 61.7 MB  |
| `Stream.each_line` / `count_lines` | 1.4 MB   |

## Caveat

The callback must not let the line **escape** — e.g. storing it into an outer
`Vec` / `Map` / list. A `str` that leaves the block is deep-copied into the
enclosing region, which reintroduces O(file) growth. Side effects (`print`) and
escape-clean results (`int` / `bool`) are the intended shapes. A general fold
with an escape-clean accumulator follows the same pattern.

## Backends

interp + C. `file_open` / `file_read_line` / `file_close` are C+interp only;
the Wasm and LLVM backends do not implement per-line file input.
