# contrib/path — POSIX path manipulation helpers

Path operation helpers for POSIX (`/` separator) provided in
`module Path { ... }`. Implemented in pure Mere (no new builtins; string ops
only).

## Files

| file | export | lines |
|---|---|---|
| `path.mere` | `module Path { join, basename, dirname, ext, drop_ext, has_ext }` | ~75 |

## API

| fn | signature | behavior |
|---|---|---|
| `Path.join` | `str -> str -> str` | join 2 paths with `/`, dedupe `/`, absolute path wins |
| `Path.basename` | `str -> str` | text after the last `/` |
| `Path.dirname` | `str -> str` | text up to the last `/` (`""` if no separator) |
| `Path.ext` | `str -> str` | text after the last `.` in basename (e.g. `.md`). Dot-prefixed (`.hidden`) is treated as no ext |
| `Path.drop_ext` | `str -> str` | remove the ext |
| `Path.has_ext` | `str -> str -> bool` | whether it has the specified ext |

## Usage

```mere
import "contrib/path/path.mere";

Path.join "docs" "tutorial.md"           // "docs/tutorial.md"
Path.basename "docs/foo.md"              // "foo.md"
Path.dirname "docs/foo.md"               // "docs"
Path.ext "archive.tar.gz"                // ".gz"
Path.drop_ext "foo.md"                   // "foo"
Path.has_ext "foo.md" ".md"              // true
```

## MVP limits

- POSIX `/` separator only — Windows `\` not supported
- no normalization (`a/../b` → `b`); operates on input as-is
- absolute path detection by `/` prefix
- `Path.ext "archive.tar.gz"` returns `.gz` (compound exts like `tar.gz` are
  caller's responsibility)

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-path` (separate repo, after pkg manager lands).
Normalization / glob etc. are candidates for pre-graduation additions.
