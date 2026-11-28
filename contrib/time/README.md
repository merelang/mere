# contrib/time — time format helpers

Small helpers that format elapsed seconds (float) into human-readable strings.
Namespaced as `module Time { format_elapsed, to_ms, to_us }`.

## Files

| file | export | lines |
|---|---|---|
| `time.mere` | `module Time { format_elapsed, to_ms, to_us }` | 52 |

## Usage

```mere
import "contrib/time/time.mere";

// Display elapsed seconds
print (Time.format_elapsed 1.25);   // "1.25s"
print (Time.format_elapsed 0.005);  // "5ms"
print (Time.format_elapsed 12.34);  // "12.34s"

// Integer conversion
print (show (Time.to_ms 1.5));        // 1500
print (show (Time.to_us 0.001234));   // 1234

// Real-time benchmark (the `time` builtin works on interp / C / LLVM / Wasm)
let t0 = time () in
... heavy work ...
let dt = f_sub (time ()) t0 in
print (Time.format_elapsed dt);
```

## API

| fn | signature | purpose |
|---|---|---|
| `format_elapsed` | `float -> str` | `< 1s` → `"Nms"`; `>= 1s` → `"N.NNs"` |
| `to_ms` | `float -> int` | float seconds → int in ms |
| `to_us` | `float -> int` | float seconds → int in us |

## Backend support

| backend | status |
|---|---|
| interp | ✓ |
| C | ✓ (Phase 43.1 fixed a typo where `TyFloat` was missing from `ty_is_concrete`) |
| LLVM | ✓ (same fix) |
| Wasm | ✓ |

## MVP limits

- `now` / `since` / `bench` (real-time measurement helpers) are not included
  in this lib — call the `time ()` builtin directly in user code (it is
  available on every backend).
- Date formatting (`YYYY-MM-DD HH:MM:SS` etc.) is also not supported —
  no `strftime` equivalent among Mere builtins.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
Graduation target is `mere-time` (separate repo, after pkg manager lands).
Date formatting is the remaining pre-graduation prerequisite.
