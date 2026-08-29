# Stdlib reference (mere)

221 builtins are always available via `initial_env`. Check a name's type with
`mere -te NAME`, and the count with `sh scripts/host_matrix.sh`, which
enumerates the environment rather than reading this document — a
hand-maintained tally rots, and this one had (it read 202 while the
environment held 226).

Legend:
- ⚡ = may raise `Eval_error`
- ★ = polymorphic (builtin-level polymorphism, not let-poly)
- 🌐 = works in all 4 backends (interp + C + LLVM + Wasm) — added incrementally through Phases 22-31

## Sugar / prelude added in Phase 36 (2026-06-22)

**Syntactic sugar (13)**: lexer / parser-level changes only; preserves 4-backend compatibility:
- `a..b` — range literal (desugars to `range a b`; inclusive on both ends)
- `(+ N)` / `(* N)` etc. — operator section (11 operators; `-` is excluded)
- `h :: t` — cons (sugar for `Cons (h, t)`; right-associative)
- `f <| x` — reverse pipe (`f x`; RHS accepts `fn` / `let`)
- `f @@ x` — OCaml-style alias for `<|`
- `\x -> body` / `\a b c -> body` — lambda shorthand (no type annotations)
- `"hello {expr}"` — string interpolation (desugars to `++ (expr) ++`; `\{` escapes a literal brace)
- `let x = e? in body` — Option early-return
- `let x = e?! in body` — Result early-return
- `[expr | x <- xs, cond, y <- ys, ...]` — list comprehension (multi-generator + filter in any order)
- `if let pat = e then ... else ...` — conditional destructure
- `for x in xs do body` — sugar for `list_iter`
- `while cond do body` — desugars to a recursive helper (codegen supported inside fn bodies only)

**Prelude additions (16 of 34 entries added in Phase 36)**:
- range / list_filter / list_take / list_drop / list_find / list_append
- list_concat / list_flat_map / list_zip / list_for_all / list_any
- list_member / list_sum / list_product / list_max / list_min

---

## I/O (12)

| Name | Type | Description |
|---|---|---|
| `print` | `str -> unit` | Write to stdout with newline |
| `print_no_nl` | `str -> unit` | Without newline + flush (for prompts) |
| `print_int` | `int -> unit` | Print integer with newline |
| `print_bool` | `bool -> unit` | Print bool with newline |
| `print_err` | `str -> unit` | Write to stderr with newline |
| `read_line` | `unit -> str` | One line from stdin; empty string on EOF |
| `read_file` ⚡ | `str -> str` | Read the whole file **as text**; raises on failure. On the C backend the str is NUL-terminated, so binary data silently truncates at the first 0x00 byte (the interpreter's strings carry NULs) — use `read_file_bytes` for binary (v0.1.43) |
| `read_file_bytes` ⚡ | `str -> Vec[R, int]` | Read the whole file as raw bytes — one int (0..255) per byte, binary-safe on every supported backend. interp + C only (v0.1.43, CRC-32 probe). Costs eight bytes per byte; prefer `read_bytes` |
| `read_bytes` ⚡ | `str -> bytes` | The whole file as a `bytes`: one byte per byte, and no NUL hazard. interp + C (v0.1.216, mpng dogfood) |
| `write_bytes` ⚡ | `str -> bytes -> unit` | Write a `bytes` to a file. interp + C |
| `bytebuf_new` | `int -> ByteBuf[R]` | n zeroed bytes, region-bound and mutable. One byte per byte, with random access — which `bytes` (immutable) and `StrBuf` (append-only text) leave uncovered (v0.1.218, mpng dogfood) |
| `bytebuf_len` | `ByteBuf[R] -> int` | |
| `bytebuf_get` | `ByteBuf[R] -> int -> int` | The byte at an index; out of bounds is an error |
| `bytebuf_set` | `ByteBuf[R] -> int -> int -> unit` | Write a byte (masked to 0..255) |
| `bytebuf_push` | `ByteBuf[R] -> int -> unit` | Append, growing the buffer |
| `bytes_of_bytebuf` | `ByteBuf[R] -> bytes` | Freeze a copy, which can then leave the region |
| `bytebuf_of_bytes` | `bytes -> ByteBuf[R]` | The other way, for editing |
| `print_bytes` ⚡ | `bytes -> unit` | Write a `bytes` to stdout, unbuffered and with **no newline**. This is what `print_no_nl` cannot be: a `str` is NUL-terminated in the compiled backends, so a zero byte ended the output there and did not on the interpreter. **All four backends** (v0.1.216, Wasm in v0.1.219) |
| `write_file` ⚡ | `str -> str -> unit` | Write content to path (overwrite); raises on failure |

**The FFI byte arena's `bytes` bridge** (v0.1.282). `tcp_read` and friends write into
an integer-addressed arena, and `mem_to_str` cannot bring binary back out — it stops
at the first zero byte, which every binary protocol has. Declare these as `extern fn`
alongside the rest of the `mem_*` family:

```mere
extern fn mem_to_bytes: int -> int -> bytes;          // arena ptr, len -> bytes
extern fn mem_copy_bytes: int -> int -> bytes -> int; // arena ptr, offset, bytes -> written
```

Native (C) and a Wasm **component** both provide them; `scripts/socket_parity.sh`
requires the two backends to agree. In a plain Wasm build they become an `env` host
import like any other extern, so a host that does not provide them fails at
instantiation with a missing-import error rather than a wrong answer.
| `write_file_bytes` ⚡ | `str -> Vec[R, int] -> unit` | Write an int vec as raw bytes (each element 0..255) — the write half of the binary path; PPM P6 etc. interp + C only (v0.1.44, Mandelbrot probe) |
| `read_lines` ⚡ ★ | `str -> str list` | Read line by line, returns `str list` (Phase 19.6; depends on prelude) |
| `file_exists` | `str -> bool` | Whether path exists (Phase 19.6; on C native since v0.1.15) |
| `file_mtime` | `str -> float` | Modification time in seconds; raises if the path is missing (interp + C native) |
| `file_size` | `str -> int` | File size in bytes (stat); binary-safe length where `str_len` (strlen) stops at a NUL. interp + C native (v0.1.21) |
| `file_openrw` | `str -> File` | Open a read/write handle, creating the file if absent and **not** truncating it. The handle for everything below (v0.1.115, mbtree dogfood) |
| `file_pread` | `File -> int -> int -> Vec[R, int]` | Read at most `len` bytes starting at an offset; a read past the end comes back short rather than padded |
| `file_pwrite` | `File -> int -> Vec[R, int] -> int` | Write a byte vec (each element 0..255) at an offset, extending the file if it writes past the end; returns the count written |
| `file_pwrite_bytes` | `File -> int -> bytes -> int` | The same over `bytes`, without exploding a byte string into one boxed int per byte (v0.1.222, mraft dogfood) |
| `file_fsync` | `File -> unit` | Force the OS to commit this handle's writes to stable storage. The difference between "written" and "durable", and what a store calls at a commit point |
| `file_close` | `File -> unit` | Close the handle |
| `env_var` ★ | `str -> str option` | Fetch env var; `None` if unset (Phase 19.6; depends on prelude) |
| `args` ★ | `unit -> str list` | The program's own args (after the script path / binary name); consistent interp ↔ native since v0.1.12 |
| `run` | `str -> int` | Run a command line via the shell, inherit stdio, return its exit code (interp + C native; v0.1.13) |
| `stdin_byte` | `unit -> int` | One byte from stdin **without blocking**; -1 when nothing is ready. `read_key` blocks, which a device emulator polling a line-status register cannot afford (interp + C native) |

```
file_exists "/etc/hosts"            // → true
env_var "PATH"                      // → Some "..."
env_var "BOGUS"                     // → None
read_lines "data.txt"               // → ["line1", "line2", ...]
args ()                             // → ["foo", "bar"] (mere prog foo bar)
run "clang -O2 main.c -o app"       // → 0 on success, nonzero exit code otherwise
```

**Sockets** are `extern fn` declarations rather than builtins — the C backend defines
them when a program declares them (`native_ffi_names` in `codegen_c.ml`), which is why
they take flat-arena offsets rather than `bytes`. They are native-only in practice.

| name | type | notes |
|---|---|---|
| `tcp_listen` | `int -> int` | Bind a listener on a port (all interfaces), `SO_REUSEADDR`; the fd, or -1 |
| `tcp_accept` | `int -> int` | Accept one connection; the fd, or -1 |
| `tcp_connect` | `str -> int -> int` | Dial host:port; the fd, or -1 |
| `tcp_write` | `int -> int -> int -> int` | Write `len` bytes from an arena offset |
| `tcp_read` | `int -> int -> int -> int` | Read into an arena offset. **See the codes below** |
| `tcp_set_timeout` | `int -> int -> int` | `SO_RCVTIMEO` / `SO_SNDTIMEO` in milliseconds |
| `tcp_close` | `int -> unit` | Close the fd |

**What `tcp_read` returns** (v0.1.226, mraft dogfood). A count when it read something,
and `0` at end of stream — a peer that closed cleanly, which is information rather
than a failure. A negative result says *which* failure, because with a timeout set
these are opposite events for the caller:

| | meaning | what a caller does |
|---|---|---|
| `-1` | nothing arrived before the deadline | wait again |
| `-2` | the connection is gone | reconnect |
| `-3` | any other error | usually give up |

Before v0.1.226 every failure was `-1`, and a program that needed the difference had
to time the call and ask whether it had failed slowly enough to have been a timeout —
inferring a cause from a duration. Every existing `< 0` check is unaffected.
`scripts/tcp_read_codes.sh` produces all three rather than describing them.

**TLS**, both halves (v0.1.338). Also `extern fn` declarations, and declaring any of
them is what makes the C backend link OpenSSL — a program that never mentions TLS
does not need it installed.

| name | type | notes |
|---|---|---|
| `tcp_starttls` | `int -> str -> int` | Client: upgrade an established fd, SNI, **no certificate check** |
| `tcp_starttls_verified` | `int -> str -> str -> int` | Client: peer verification against a CA + hostname match |
| `tls_server_init` | `str -> str -> int` | Server: load a certificate chain and key, once per process. `0`, or negative |
| `tcp_accept_tls` | `int -> int` | Server: perform the handshake on an accepted fd. `0`, or negative |

After either call succeeds, `tcp_read` / `tcp_write` / `tcp_close` on that fd go
through TLS with no further change — which is why a plaintext handler becomes a TLS
handler by inserting one line.

The server side is two calls rather than one because a certificate is read once and a
handshake happens per connection. Folding them together would re-read the files on
every accept, and would make "your certificate is unusable" and "this particular
client failed" the same result — so a server with a bad certificate would look healthy
until a user arrived. `tls_server_init` returning non-zero is the whole difference.

Until v0.1.338 only the client half existed, so a Mere program could dial a TLS
connection but not answer one. Nothing announced this, and nothing worked around it
either -- no document in the project mentioned TLS for serving, so there was no
workaround to notice. `grep tcp_starttls` finds TLS and TLS is there.
`scripts/tls_server_check.sh` drives `test/tls/https_server.mere` with curl and
`openssl s_client` — two TLS implementations that are not ours.

**Not on every backend.** TLS is C-backend only, client half included: `mere -ll` and
`mere -w` have no lowering for any of the four, so a program that terminates TLS is a
program you build with `mere -c`.

**On Wasm** the whole family works — `scripts/socket_parity.sh` runs the same round
trip natively and under `wasmtime -S inherit-network=y` and compares — with two
differences:

- **A failed read returns `0`**, the same value C uses for a clean end of stream.
  Telling them apart means decoding WASI's `stream-error` variant rather than its
  is-error bit.
- **`tcp_set_timeout` is refused at codegen** (v0.1.227). It used to compile to a
  no-op that returned success, so a program that set a deadline blocked forever on
  the next read. A bounded wait needs the native backend.

**Positioned file I/O** (`file_openrw` through `file_close`) works on **all four**
backends: interp and C natively, Wasm over host imports since v0.1.153 (bytes cross
in the `mere_bytes` layout rather than one call per byte), LLVM since v0.1.163. It
is the group a paged store or a write-ahead log needs, and it was documented only in
the changelog until v0.1.222 — which is how the mraft dogfood came to write its log
through the Vec-taking call for a whole slice before noticing.

**★ Codegen status** (v0.1.246 for the first two): `print_no_nl` and `print_err` lower
on **interp + C + LLVM**; both were refused by LLVM until it grew a `write(fd, ...)`
for its own panic diagnostic, at which point they were three lines each. On **Wasm**
`print_err` is **refused**: it used to write to the same host sink as `print`, so a
diagnostic landed in the program's own output and nothing said so, and the JS host ABI
has no second sink to give it. `print` / `print_int` / `print_bool` / `read_file` /
`write_file` work in all 3 backends (Wasm goes through host imports; `scripts/run_wasm.js` provides puts / read_file / write_file). `print_int` / `print_bool` were the exception until v0.1.190 — this line claimed them for years while only the interpreter had them; C emitted a call to an undefined symbol and LLVM / Wasm refused outright. They now lower on all four (C through `printf`, LLVM and Wasm through the `str_of_int` they already had), locked by `test/parity/print_int_bool.mere`. `read_lines` / `env_var` are **interpreter-only** (codegen would need `'a list` / `'a option` construction + systematic outside-world access; not yet covered by Phases 22-31). `args` works on **all four** backends: C and LLVM read the argc/argv their `main` was handed, Wasm folds the host's `arg_count` / `arg_get` (v0.1.159 for Wasm, v0.1.169 for LLVM). The native-CLI / dogfood builtins `run` / `print_err` / `file_exists` / `file_mtime` / `file_size` / `tty_raw` / `tty_restore` / `read_key` / `random_int` also work on the **C native** backend (added for the `mk` / `mrog` / `mwasm` dogfoods, v0.1.13-v0.1.21).

```
let _ = print "Hello";
let _ = print_no_nl "Name: ";
let name = read_line () in print ("Hi, " ++ name);

// File round-trip
let _ = write_file "/tmp/out.txt" "hello lang";
let content = read_file "/tmp/out.txt" in print content;
```

---

## Value conversion (3)

| Name | Type | Description |
|---|---|---|
| `str_of_int` | `int -> str` | Integer to string |
| `int_of_str` ⚡ | `str -> int` | Parse after trim; raises on bad input |
| `bool_of_str` ⚡ | `str -> bool` | Trim then `"true"`/`"false"` only; raises otherwise |
| `float_of_int` | `int -> float` | int → float (no precision loss) |
| `int_of_float` | `float -> int` | float → int (truncation) |
| `float_bits_hi` ★ | `float -> int` | The top 32 bits of a double's IEEE-754 pattern (v0.1.281) |
| `float_bits_lo` ★ | `float -> int` | The bottom 32 bits (v0.1.281) |
| `float_of_bits` ★ | `int -> int -> float` | `float_of_bits hi lo` — the inverse of the two above (v0.1.281) |
| `f32_bits` ★ | `float -> int` | The 32-bit IEEE-754 pattern of the **float32** nearest this double. The narrowing *is* the rounding (round-to-nearest-even); a value with no float32 becomes ±inf rather than wrapping (v0.1.281) |
| `float_of_f32_bits` ★ | `int -> float` | A float32 pattern back to a double (v0.1.281) |

**Why the bits come out in two halves.** A double's pattern read as one signed
int64 does not fit the interpreter's native int — which is OCaml's, and 63-bit — for
a large share of ordinary values: `-1.5`, `1e308`, `inf` and `nan` all exceed it. A
single 64-bit accessor would therefore answer differently on the interpreter than on
every compiled backend, for a literal as plain as `1e308`. Each 32-bit half is
always below 2^32, so there is nothing left to diverge about. Pinned by
`test/parity/float_bits.mere` on all four backends.

These are the primitive the rest is built from: `contrib/proto/wire.mere` writes a
protobuf `double` as `put_double` and a `float` as `put_float` on top of them, and
neither the caller nor the generated codec learns about the split.
| `str_of_float` | `float -> str` | Float to string (OCaml semantics) |
| `float_of_str` ⚡ | `str -> float` | Parse after trim; raises on bad input |

```
str_of_int 42        // "42"
int_of_str "  -7  "  // -7
bool_of_str "true"   // true
```

---

## String operations (23)

| Name | Type | Description |
|---|---|---|
| `str_len` | `str -> int` | Byte length |
| `str_contains` | `str -> str -> bool` | Substring containment |
| `str_starts_with` | `str -> str -> bool` | Prefix test |
| `str_ends_with` | `str -> str -> bool` | Suffix test |
| `str_count` | `str -> str -> int` | Non-overlapping occurrence count |
| `str_index_of` ★ | `str -> str -> int` | First position of needle; -1 if not found. Empty needle returns 0 (Phase 19.1) |
| `str_last_index_of` ★ | `str -> str -> int` | **Last** position of needle; -1 if not found. Empty needle returns the haystack length — it occurs one past the final byte too, and that is the last such position (v0.1.302) |
| `str_split` ★ | `str -> str -> str list` | Split by delimiter; returns `str list`. Requires `type 'a list = ...` declared. Empty delimiter returns a single-element list (Phase 19.1) |
| `utf8_len` ★ | `str -> int` | Codepoint count (a `str` is bytes; `str_len` is the byte length). Invalid bytes count as single units (v0.1.38) |
| `utf8_chars` ★ | `str -> str list` | Split into codepoints — the building block for text processing (v0.1.38) |
| `utf8_at` | `str -> int -> str` | i-th codepoint (prelude, on `utf8_chars`) |
| `utf8_sub` | `str -> int -> int -> str` | Codepoint-indexed substring (prelude) |
| `utf8_rev` | `str -> str` | Codepoint-wise reverse — `str_rev` is byte-wise and scrambles multibyte text (prelude) |
| `utf8_width` | `str -> int` | **Display** width (East Asian Width, wcwidth-lite): CJK / fullwidth / emoji = 2 columns, combining marks = 0, halfwidth katakana = 1. `utf8_len` counts codepoints; terminals draw columns — use this for alignment (prelude, v0.1.45) |
| `pad_right` | `str -> int -> str` | Pad with spaces to a display width (table columns, left-aligned); no-op if already wide enough (prelude, v0.1.45) |
| `pad_left` | `str -> int -> str` | Right-align to a display width — numbers in table columns (prelude, v0.1.45) |
| `str_join` ★ | `str -> str list -> str` | Join with separator. Empty list → empty string (Phase 19.1) |
| `str_compare` 🌐 | `str -> str -> int` | Lexicographic -1 / 0 / 1 (Phase 31.0 ported to 3 backends; sign-normalized) |
| `str_repeat` ⚡ | `str -> int -> str` | Repeat N times; raises on N<0 |
| `str_replace` | `str -> str -> str -> str` | Replace all; empty needle = no change |
| `str_rev` | `str -> str` | Reverse string |
| `str_trim` | `str -> str` | Strip leading/trailing whitespace |
| `str_unescape` ⚡ | `str -> str` | Decode `\n` `\t` `\r` `\\` `\"` `\/`; raises on unknown escape |
| `substring` ⚡ | `str -> int -> int -> str` | `s[start:end_excl]`; raises on out of range |
| `char_at` ⚡ | `str -> int -> str` | Index access (length-1 str); raises on OOB |
| `chr` ⚡ | `int -> str` | int in 0..255 to single-char str; raises out of range |
| `ord` ⚡ | `str -> int` | Single-char str to int code point; raises if length != 1 |
| `to_upper` | `str -> str` | ASCII uppercase |
| `to_lower` | `str -> str` | ASCII lowercase |
| `is_digit` | `str -> bool` | True for single char in `'0'..'9'`; otherwise false |
| `is_alpha` | `str -> bool` | True for single char that's a letter |
| `is_space` | `str -> bool` | True for single char that's space/tab/\n/\r |

```
type 'a list = Nil | Cons of 'a * 'a list;
str_split "a,b,c" ","                          // ["a", "b", "c"]
str_join "-" ["alpha", "beta", "gamma"]        // "alpha-beta-gamma"
str_index_of "hello world" "world"             // 6
str_index_of "hello" "xyz"                     // -1
```

**★ Codegen status**: `str_index_of` / `str_last_index_of` / `str_split` / `str_join` / `str_count` / `str_compare` / `str_trim` / `str_starts_with` / `str_ends_with` / `str_contains` / `str_replace` / `str_repeat` / `str_rev` all work **across all 4 backends** (Phase 19.1.1 added str_index_of; Phase 22 added str_split / str_join; Phase 26.5 added all Wasm str ops; Phase 31.0 added str_compare; Phase 36 added str_trim / starts_with / ends_with / contains / replace / repeat / rev). `not` / `abs` / `min` / `max` / `clamp` / `chr` / `ord` / `to_upper` / `to_lower` / `even` / `odd` / `gcd` / `bool_of_str` also reached the 3 backends in Phase 36. The `fn (_: unit) -> body` wildcard parameter was also parser-fixed in Phase 36.

```
str_replace "foo bar foo" "foo" "X"           // "X bar X"
substring "hello world" 6 11                  // "world"
char_at "abcdef" 2                            // "c"
"world" |> str_contains "hello world"         // true (pipe + curry)
str_unescape "a\\nb"                          // a + newline + b (3 chars)
```

---

## Numeric operations (23)

| Name | Type | Description |
|---|---|---|
| `min` | `int -> int -> int` | Smaller |
| `max` | `int -> int -> int` | Larger |
| `abs` | `int -> int` | Absolute value |
| `sign` | `int -> int` | -1 / 0 / 1 |
| `clamp` | `int -> int -> int -> int` | `clamp lo hi x` restricts to `[lo, hi]` |
| `pow` ⚡ | `int -> int -> int` | base^exp by square-and-multiply; raises on negative exp |
| `square` | `int -> int` | x * x |
| `cube` | `int -> int` | x * x * x |
| `incr` | `int -> int` | +1 |
| `decr` | `int -> int` | -1 |
| `even` | `int -> bool` | n mod 2 == 0 |
| `odd` | `int -> bool` | n mod 2 != 0 |
| `gcd` | `int -> int -> int` | Euclid (handles negatives and 0 correctly) |
| `lcm` | `int -> int -> int` | `|a/gcd * b|`; 0 in input → 0 |
| `divmod` ⚡ | `int -> int -> (int * int)` | (quotient, remainder); raises on 0 div — the check is its own, because bare `/` by zero raises on interp and returns 0 on C and LLVM |
| `sum_range` | `int -> int -> int` | Sum over `lo..hi` (Gauss formula, O(1)); halves inside the product, so it is portable over the whole range its result can hold |
| `not` | `bool -> bool` | Logical negation |
| `bit_and` | `int -> int -> int` | Bitwise AND on the backend's native int width (v0.1.42) |
| `bit_or` | `int -> int -> int` | Bitwise OR (v0.1.42) |
| `bit_xor` | `int -> int -> int` | Bitwise XOR (v0.1.42) |
| `bit_not` | `int -> int` | Bitwise complement; numerically `-x - 1` on every backend (v0.1.42) |
| `bit_shl` | `int -> int -> int` | Shift left. Keep counts in `0..62` for portable code — int is 64-bit on C, LLVM and Wasm (widened in v0.1.96 / v0.1.127), 63-bit on interp |
| `bit_shr` | `int -> int -> int` | **Arithmetic** (sign-propagating) shift right; `bit_shr x n` equals floor division by 2^n on every backend (v0.1.42) |

**★ A transcendental is not correctly rounded by anybody** (v0.1.248). `exp` and
`log` reach C through libm, LLVM through `@llvm.exp.f64`, and Wasm through the host's
`Math.exp` — and measured, `exp -10` is `4.5399929762484854e-05` on three of those and
`4.539992976248485e-05` through JavaScript. That is not a bug in any of them.
`test/parity/exp_log.mere` therefore prints exact values only at the points that are
exact in binary floating point (`exp 0`, `log 1`) and asserts everything else as an
identity within a tolerance — which still fails an `exp` that returns its argument or a
`log` wired to log10, and does not report the C library's build options as a difference.

**★ Integer `/` and `%` by zero raise** (v0.1.247): `division by zero` and
`modulo by zero`, catchable with `try_or`, on the interpreter and the C, LLVM and
Wasm backends. It cost a branch per division to make that true, and it was worth it
because the alternative was not one behaviour but four: the interpreter raised, the
C backend emitted a bare `a / b` — **undefined behaviour in C**, which an arm64 build
answers with 0 and an x86-64 build answers with SIGFPE — LLVM emitted `sdiv`, which
is undefined in IR and licenses the optimizer to assume it cannot happen, and Wasm
trapped with no message at all. `INT_MIN / -1` is the other undefined case and wraps
now, which is what the interpreter already did.

**The `-rv` backend is the exception, and it is measured rather than assumed**: under
QEMU's `virt` board, `17 / 0` is `-1` and `17 % 0` is `17` there — the RISC-V
specification's non-trapping answer. That backend targets bare metal, where there is
no stream to write a diagnostic to and no process to exit: the platform's answer is
the answer. Float division is IEEE on every backend and keeps giving inf / nan.

**★ On the width these are actually computed at** (v0.1.245): a builtin can be
present on every backend, answer every small question correctly, and still be
implemented at a narrower width than the language's int. `gcd` was a
`static int __lang_gcd(int, int)` in the generated C — `gcd 3037000493 3037000493`
came back as `1257966803` — and `int_of_str` on LLVM parsed with `strtoll` and then
truncated the result to `i32`, so the largest int read back as `-1`. Both were
invisible to every existing test and to `host-matrix.md`, because the arguments
used to probe a builtin were all one or two digits.

`test/parity/int_width.mere` is the gate for this: every deterministic int builtin,
with arguments above 2^31, held to one answer on all four backends. It found the
second bug while being written for the first. Values there stay inside ±(2^62 − 1)
so that the interpreter's 63-bit int is not itself the difference — and note that
an *intermediate* counts: `sum_range` used to form a product twice the size of its
own answer, which made it portable over only half the range its result could hold.

### Float arithmetic (4)

> **Note (v0.1.44)**: the infix operators `+ - * /`, all comparisons, and
> unary `-` are numeric-overloaded and work directly on floats, on every
> backend — prefer them. The `f_` functions below remain as ordinary
> function values (useful for passing to higher-order functions). The
> overload resolves to float only when an operand is concretely float;
> annotate fn params (`fn (x: float) -> ...`) in float-heavy code.

| Name | Type | Description |
|---|---|---|
| `f_add` | `float -> float -> float` | Addition |
| `f_sub` | `float -> float -> float` | Subtraction |
| `f_mul` | `float -> float -> float` | Multiplication |
| `f_div` | `float -> float -> float` | Division (IEEE 754: 0 div is inf/nan) |
| `f_lt` | `float -> float -> bool` | Less than |
| `f_le` | `float -> float -> bool` | Less than or equal |
| `f_gt` | `float -> float -> bool` | Greater than |
| `f_ge` | `float -> float -> bool` | Greater than or equal |
| `f_neg` | `float -> float` | Unary minus (`Neg` is int-only, so use this for float) |
| `f_abs` | `float -> float` | Absolute value |
| `sqrt` | `float -> float` | Square root (NaN for negatives) |
| `floor` | `float -> float` | Floor |
| `ceil` | `float -> float` | Ceiling |
| `round` | `float -> float` | Round |
| `f_min` ★ | `float -> float -> float` | Smaller (Phase 19.7) |
| `f_max` ★ | `float -> float -> float` | Larger (Phase 19.7) |
| `f_pow` ★ | `float -> float -> float` | Power `base ^ exp` (Phase 19.7) |
| `log` ★ | `float -> float` | Natural log (Phase 19.7; all 4 backends in v0.1.248) |
| `exp` ★ | `float -> float` | e^x (Phase 19.7; all 4 backends in v0.1.248) |
| `sin` ★ | `float -> float` | Sine (radians; Phase 19.7) |
| `cos` ★ | `float -> float` | Cosine (Phase 19.7) |
| `tan` ★ | `float -> float` | Tangent (Phase 19.7) |
| `atan2` ★ | `float -> float -> float` | `atan2 y x` for angle (Phase 19.7) |
| `random_int` ★ ⚡ | `int -> int` | `random_int n` returns int in `0..n-1`; raises if n<=0 (Phase 19.7) |
| `random_float` ★ | `unit -> float` | Float in `[0.0, 1.0)` (Phase 19.7) |
| `pi` | `float` | π ≈ 3.14159265 (constant builtin) |
| `e` | `float` | e ≈ 2.71828183 (constant builtin) |

**★ Codegen status**: the 11 entries added in Phase 19.7 are **interpreter-only**. Codegen support requires libm linking or per-backend wiring of built-in math functions, planned for a follow-up slice (19.7.1).

```
f_add 1.5 2.5                    // 4.0
f_div 10.0 4.0                   // 2.5
3.14 |> f_mul 2.0                // 6.28
```

```
clamp 0 100 150                  // 100
pow 2 10                         // 1024
gcd 12 18                        // 6
sum_range 1 100                  // 5050
fst (divmod 100 7) + snd (divmod 100 7)   // 14 + 2
```

---

## Control / error (3)

| Name | Type | Description |
|---|---|---|
| `fail` ⚡ ★ | `str -> 'a` | Panic that unifies with any type |
| `assert` ⚡ | `bool -> str -> unit` | On false, raises "assertion failed: MSG" |
| `try_or` ★ | `(unit -> 'a) -> 'a -> 'a` | Evaluate the thunk; catch `Eval_error` and return default |

```
let safe = fn s -> try_or (fn () -> int_of_str s) (- 1);
safe "42"      // 42
safe "abc"     // -1

if x < 0 then fail "negative" else x
```

`fail` is polymorphic, so type inference works at branch merges (`if c then fail msg else int_val` → int).

**★ What an uncaught failure does** (v0.1.246): the program writes one line to
**stderr** and exits **1**, on every backend. The line is the message raised, tagged
`fail: ` when it came from the `fail` builtin — the tag belongs to the builtin, so a
backend's own failures (`int_of_str` on junk, an out-of-range index) are not tagged,
which is what the interpreter has always done. The interpreter additionally prefixes
the source file it is running; a compiled binary has none.

None of that was true before. The same program exited 1 on two backends and 134
(SIGABRT) on two others, wrote its diagnostic to stderr on two and stdout on two,
tagged the message on three and not on the fourth, and `int_of_str` on junk named the
offending input on two backends and not on the other two. It went unnoticed because
the parity harness compared stdout and nothing else, so **no parity test used `fail`
— none could have passed**. `test/parity/fail/*.mere` is the gate now: exit status,
the output written before the failure, and the message, on all four.

Two limitations remain, and both are pinned rather than described:

- **Wasm has one output sink.** The JS host ABI provides `env.puts` and nothing else,
  so the diagnostic lands in stdout there. The harness knows this and would break if
  it changed. Under `--component` the same backend writes through WASI.
- **`fail` on Wasm does not unwind.** It sets a flag that callers check on the way
  out, so statements *after* it in the same body still run: inside a `try_or` thunk,
  work that follows the failure happens. `test/parity/failure_caught.mere` holds the
  other three to one answer and declares Wasm's exact output in a
  `.wasm.expected` file next to it, so the day that backend learns to unwind, the
  declaration breaks and says so.

`try_or` catches all of these on all four backends, including the ones raised inside
the backend rather than by `fail`. What it hands back is the default — **not the
message**: the language can observe that something failed, not why.

---

## Polymorphic helpers (8)

| Name | Type | Where | Description |
|---|---|---|---|
| `show` ★ | `'a -> str` | builtin | Stringify any value via to_string |
| `fst` ★ | `('a * 'b) -> 'a` | builtin | Tuple first |
| `snd` ★ | `('a * 'b) -> 'b` | builtin | Tuple second |
| `id` | `'a -> 'a` | prelude | Identity function |
| `pair` | `'a -> 'b -> ('a * 'b)` | prelude | Tuple constructor (curried) |
| `swap` | `('a * 'b) -> ('b * 'a)` | prelude | Tuple swap |
| `const` | `'a -> 'b -> 'a` | prelude | Drop second arg, return first (`b` is still evaluated — Mere is call-by-value) |
| `flip` | `('a -> 'b -> 'c) -> ('b -> 'a -> 'c)` | prelude | Reverse arg order of a curried fn (higher-order) |

**All eight work on all four backends (v0.1.318).** The bottom five were
builtins with polymorphic schemes in the typer and implementations in the
interpreter, and nothing in any code generator — so they worked under
`mere file.mere` and nowhere else. LLVM and Wasm refused them by name; the C
backend emitted a reference to an undeclared `mu_pair` and left the diagnosis
to the C compiler, which reported it in terms of a symbol the author never
wrote. As prelude definitions they are ordinary closures: every backend
compiles them, partial application and use in value position work without a
special case in any emitter, and there is one implementation rather than one
per backend to keep in step. (The same migration `pow`, `lcm`, `divmod` and
`assert` already made.)

They are ordinary bindings, so a program may shadow them —
`test/parity/prelude_shadowing.mere` pins that. One Wasm limit is worth
knowing: a polymorphic function used at several types **and** passed as a
value is refused there by name ("no single value form on Wasm yet"), which
applies to these exactly as it does to any `let`-polymorphic function of your
own.

```
show 42                          // "42"
show (Some 5)                    // "Some 5"
show [1, 2, 3]                   // "[1, 2, 3]"   (Cons/Nil chains shown as [..])
show [Some 1, None, Some 3]      // "[Some 1, None, Some 3]"

fst (pair "hi" 42)               // "hi"
let always_7 = const 7 in always_7 "anything"   // 7
let sub = fn a -> fn b -> a - b in (flip sub) 3 10   // 7 (= sub 10 3)
```

---

## JSON, derive-style (5 ★)

Structural JSON, compile-time-specialized per type (no trait machinery),
like `show`. `to_json` works on **all four** backends — on LLVM it shares
the emitter with `show`, since the two differ only in literals (v0.1.184).
`of_json` and its siblings are interp / C / Wasm: decoding needs a JSON
parser in the target language, and LLVM has no hand-written one.

| Name | Type | Description |
|---|---|---|
| `to_json` ★ | `'a -> str` | Serialize any value to JSON structurally |
| `of_json` ★ | `str -> 'a` | Parse JSON into a typed value; **fails fast** on error (trusted input) |
| `of_json_opt` ★ | `str -> 'a option` | Same, but returns `None` on any error (safe for untrusted input) |
| `of_json_like` ★ | `'a -> str -> 'a` | Target type from a witness value instead of an annotation (v0.1.183) |
| `of_json_opt_like` ★ | `'a -> str -> 'a option` | The non-crashing witness form |

### Decoding inside a polymorphic function

`of_json` reads the target type off the call node, which is fine at a use
site with an annotation and impossible inside a generic helper: there the
node's type is a variable, and the interpreter has no runtime types to
resolve it with. So a generic "decode it back" had to name the record type,
and every record needed its own copy.

A witness supplies the type instead. The interpreter reads it off the
value's runtime shape — a record carries its type's name — and the compiled
backends read it off the witness's static type, which is the same variable
the result unifies with:

```mere
let with_field = fn (rec_) -> fn (name: str) -> fn (v: str) ->
  ... of_json_opt_like rec_ (rebuilt_json) ...
```

The witness is a value the caller already has whenever this comes up:
replacing one field of a record means holding the record. `contrib/schema`
is this, and `examples/claims` generates its whole form from it.

A polymorphic record still needs the annotation — a value carries its
type's name but not its type arguments, so a witness cannot describe
`Box[int]`.

The `of_json` result type comes from the use site — annotate the
expression: `(of_json s : T)`. A JSON object maps to a record's fields (by
name), an array to a list or tuple, `null`/value to `option` (`None` /
`Some`), and a string / `{"Ctor": payload}` to a variant. `to_json` uses
the same mapping in reverse, so `(of_json (to_json x) : T) == x`.

**A repeated object key is refused** (v0.1.303). `{"id":1,"id":2}` does not
decode: `of_json` fails and `of_json_opt` answers `None`, at any nesting depth,
because the check belongs to the parser rather than to the decoder generated for
a particular type. Every decoder used to accept it and keep the *first* value,
which was not a decision anyone made — it fell out of looking up an assoc list
built in document order. Go's `encoding/json` v1 kept the *last* for an equally
accidental reason, and Go 1.27's v2 stopped picking. Two implementations
resolving the same bytes to different values is the argument: there is no right
one to choose, so the input is rejected.

**Invalid UTF-8 inside a string is refused too** (v0.1.306). The three
hand-written parsers process no `\uXXXX` escapes, so a decoded string is
exactly the raw bytes between the quotes — and until v0.1.306 nobody looked at
them. The validator (shortest form, no surrogates, max U+10FFFF) runs in the
parsers' string path, so keys and nested strings are covered without a per-type
rule. Go 1.27's `encoding/json/v2` made the same call; v1 silently rewrote bad
bytes to U+FFFD, which is a lossy edit nobody asked for. This is the parser's
rule, not `str`'s — `utf8_len` still counts an invalid byte as one unit on
purpose, because a str already in memory has no better answer.

```
type User = { id: int, name: str, bio: str option };
to_json (User { id = 1, name = "ada", bio = None })
                                 // {"id":1,"name":"ada","bio":null}
let u = (of_json body : User);   // fails fast if body is malformed
match (of_json_opt body : User option) with
| Some u -> u.name               // decoded
| None   -> "bad request"        // malformed / missing field — no crash
```

---

## Comparison, derive-style (v0.1.11)

`== / !=` (structural equality) and `< <= > >=` (structural **ordering**)
are compile-time-specialized per operand type — the same no-trait
mechanism as `show` / `to_json`. Both work on interp / C / Wasm.

- **Scalars**: `int` / `float` / `bool` / `str` compare directly (`str`
  lexicographically).
- **Compound**: tuples and records compare **field-by-field in declared
  order**; lists compare **element-wise** (a shorter prefix is smaller);
  variants order by **declaration order** (the constructor listed first is
  smallest), then by payload. All backends agree byte-for-byte, so a
  value sorts the same under the interpreter, a native binary, and Wasm.

```
(1, 2) < (1, 3)                        // true  (tuple, lexicographic)
[1,2] < [1,2,3]                        // true  (prefix is smaller)
type C = Red | Green | Blue; Red < Blue // true  (declaration order)
list_sort_by (fn (a: float) -> fn (b: float) -> a < b) [3.1, 1.2]  // [1.2, 3.1]
```

**Honest edges.** `float` uses a total order where `NaN` sorts as least.
Comparing two functions is defined but meaningless (they order as equal).
The bare default `list_sort` still bakes in an `int` comparison — its
comparator's type variables default to `int`, the same rule that keeps
`fn a -> fn b -> a < b` monomorphic — so sorting a non-`int` list needs
`list_sort_by` with an **annotated** comparator (as above). A
fully-polymorphic `list_sort` over any orderable element would need
ad-hoc-polymorphism resolution (deferred).

---

## Loop helper (1 ★)

| Name | Type | Description |
|---|---|---|
| `iter_n` ★ | `int -> (unit -> unit) -> unit` | Apply thunk N times (side-effect loop); no-op when N≤0 |

---

## Capability (2 + 2 builtin record types)

Used by the effect system (see [effects.mere](../examples/effects.mere)). The `Logger` and `Metrics` cap types are pre-registered as builtins. Users can also override with their own `type Logger = ...`.

```
type Logger  = { info: str -> unit, warn: str -> unit, error: str -> unit };
type Metrics = { inc: str -> unit, record: str -> int -> unit };
```

| Name | Type | Description |
|---|---|---|
| `mk_logger`  | `str -> Logger`   | Create a prefixed Logger. Each field prints as `prefix [LEVEL] msg` |
| `mk_metrics` | `unit -> Metrics` | Create a Metrics. `inc` / `record` print as `[METRIC] ...` |

```
let lg = mk_logger "app" in
{ lg.info "started";
  lg.warn "slow query";
  lg.error "abort" }

let m = mk_metrics () in
{ m.inc "users";
  m.record "latency_ms" 23 }
```

For a complete cap-passing example see [examples/effects.mere](../examples/effects.mere).

### Raw memory, CSRs, traps and tasks (14, RV32I bare-metal only)

A `Raw` is a **window onto physical memory** — the one capability that is not a
record of functions, because its operations lower to load and store
instructions. It is the escape hatch a device driver needs, and it is a value
rather than an ambient builtin so that "this function cannot touch raw memory"
is something you read off a signature.

`Raw` is opaque: nothing constructs one, and there is no function that mints
one. The only source is the argument `mere -rv --bare` hands to the program's
top-level `main`, and `raw_window` can only **narrow** it. Offsets are relative
to the window, so a driver holding a UART window cannot express an address
outside it; every access bounds-checks the offset, and widening faults.

| Name | Type | Description |
|---|---|---|
| `raw_window` | `Raw -> int -> int -> Raw` | A window over `[off, off+len)` of another. Faults if that is not inside it |
| `csr_read` | `int -> int` | A machine CSR by number — the number must be a literal (it is an immediate field of the instruction) |
| `csr_write` | `int -> int -> unit` | Write a machine CSR. Not behind a capability: a CSR has no base and length to narrow, and the hardware's privilege modes are what separate a kernel from a user process |
| `raw_len` | `Raw -> int` | Its length — so a kernel can partition a window it was handed without hardcoding the runtime's geometry |
| `raw_base` | `Raw -> int` | A window's base as a number. Not authority — touching anything still needs a window — but a stack pointer is an address and hardware wants the number |
| `trap_save` | `Raw -> Raw` | The trap trampoline's 31-word register save area. A context switch is a copy through this: outgoing registers to a TCB, incoming registers back |
| `machine_scratch` | `Raw -> Raw` | Reserved RAM the runtime is not using — where task stacks come from. A bare program owns no fixed address of its own: the heap grows up from 2MB and the stack down from the top |
| `closure_code` | `(unit -> unit) -> int` | A closure's entry point. A task IS a closure, so starting one means building a context whose PC is this |
| `closure_env` | `(unit -> unit) -> int` | Its environment — the value the first argument register must hold when that PC is entered. ABI knowledge, which a kernel has |
| `set_trap_handler` | `(int -> int) -> unit` | Install a trap handler. The argument is `mcause`; the result is the PC to resume at. Anything else (`mepc` 0x341, `mtval` 0x343) is a `csr_read` away. **A closure, not a named function**: a handler needs the machine capability to do anything useful and an interrupt has no caller to hand it one, so it captures instead. Codegen emits the trampoline that saves the register set and returns with `mret` |
| `raw_peek8`  | `Raw -> int -> int` | The byte at that offset |
| `raw_peek32` | `Raw -> int -> int` | The 32-bit word at that offset |
| `raw_poke8`  | `Raw -> int -> int -> unit` | Store a byte |
| `raw_poke32` | `Raw -> int -> int -> unit` | Store a 32-bit word |

```
let putc = fn (uart: Raw) -> fn (c: int) -> raw_poke8 uart 0 c;

let main = fn (mach: Raw) ->
  let uart = raw_window mach 0x10000000 256 in    // the UART, and nothing else
  putc uart 65;
```

A context switch needs no new mechanism: the trampoline saves the interrupted
register set to the area `trap_save` hands back and restores from it before
`mret`, so a handler swaps tasks by copying through it and returning the
incoming task's PC. Switch **every** register, `gp` included, and give each
task a heap arena of its own (carve it from `machine_scratch` — heap up from
the bottom, stack down from the top). Sharing one heap looks workable until a
`region R { }` in one task rolls the bump pointer back and frees what another
task allocated meanwhile; the rule that survives is that contexts share `gp`
only if they genuinely share a heap, and a context that uses regions must not.
See [examples/riscv_bare_sched.mere](../examples/riscv_bare_sched.mere).

Device MMIO sits above any RAM (the UART data register is at `0x10000000`, the
address QEMU's `virt` machine uses), so a device address does not move when
`--ram` does. On every other backend these refuse: there is no honest physical
address in a hosted process. See
[examples/riscv_bare_uart.mere](../examples/riscv_bare_uart.mere).

---

## Virtual clock (v0.1.305)

`MERE_VIRTUAL_CLOCK=1` makes the **interpreter** advance a virtual clock instead
of waiting: when every live thread is parked, time jumps to the earliest pending
deadline (Go 1.27 `testing/synctest`'s rule). Timer firing order becomes
deterministic and a minute of timers costs milliseconds — this is for tests.
Covered: `channel_recv` / `channel_recv_opt` / `channel_recv_timeout`,
`sleep_ms` / `sleep`, `join`, and `time` (reads the virtual clock; only
differences are deterministic). Not covered: `par_map`'s internal joins and
OS-level waits — a thread in those counts as running, so the clock refuses to
advance past it. All-blocked with no timer pending fails naming the deadlock
instead of hanging. Off by default; the C backend is untouched. See
`scripts/virtual_clock_check.sh`.

---

## Thread-leak report (v0.1.304)

`MERE_THREAD_REPORT=1` makes the **interpreter** print, at exit, the threads that
were neither `join`ed nor `detach`ed, and what each was blocked on. It goes to
stderr and is off unless the variable is set, so it never changes what a program
prints.

```
mere: 1 thread(s) neither joined nor detached at exit
  thread 1: blocked on channel_recv
```

`detach` is what marks a thread as *meant* to block forever (a server's accept
loop), so a detached thread is never reported. Not covered: the main thread, and
the C backend. See `scripts/thread_leak_check.sh`.

---

## Region stats (v0.1.307)

`MERE_REGION_STATS=1` makes a **C-backend** binary print, at exit, each arena's
block count, total block capacity and cumulative bytes handed out. Stderr only,
off unless the variable is set.

```
region-stats default: blocks=2 cap=272629776 alloc_total=272435592
region-stats named region R loop: arenas=42 alloc_total=62376872 peak_cap=3145728
region-stats named-total: sites=1 alloc_total=62376872
```

The `named` lines arrived in v0.1.319. Before them the meter saw the default
region only — so a program that did its allocating inside `region R { }` or
`region R loop`, which is to say a program managing its memory deliberately,
read as a few hundred bytes. The number that exists to replace peak RSS was
blind to the construct that exists to manage memory, and peak RSS was the only
figure left for exactly those programs.

Named arenas are created and destroyed during the run, so there is nothing to
walk at exit: each is charged to its source name as it is released. Hence
`arenas=` (how many were opened) and two different totals — `alloc_total` is
everything that arena's generations ever asked for, and `peak_cap` is the most
any single one held at once. A region loop *raises* the first and lowers the
second: it pays a copy per generation to bound what is resident. Only the
second half of that trade was measurable before.

Two limits worth knowing. An arena still live at exit is never released and so
is never charged — in practice a map's private arena between compactions.
And the table holds 32 distinct names; past that, releases are counted and
reported as a `region-stats WARNING` line rather than dropped silently, because
an undercount looks exactly like an improvement.

Capacity and allocation are functions of the program, not of the machine —
unlike peak RSS, which is quantized to powers of two and stops reproducing
above a few GB — so a gate can hold their ratio to a bound:
`scripts/region_slack_check.sh` does exactly that. `cap` far above
`alloc_total` names arena slack (stranded block tails, an inflated doubling
base); `alloc_total` itself is the number a collector has to attack. The
report fires through main's epilogue or through `exit()`, whichever comes
first, and only once.

---

## System / constants (4)

| Name | Type | Description |
|---|---|---|
| `time` | `unit -> float` | Unix epoch seconds (gettimeofday). For benchmarks / timestamps |
| `exit` ★ | `int -> 'a` | Exit the process with an exit code (never returns; polymorphic return) |
| `int_max` | `int` | Max int value (OCaml runtime dependent; 2^62-1 on 64-bit) — constant builtin |
| `int_min` | `int` | Min int value — constant builtin |

```
let start = time () in
{ run_heavy_computation ();
  print ("elapsed: " ++ str_of_float (f_sub (time ()) start) ++ " sec") }

if config_invalid then exit 1 else continue ()
```

```
iter_n 3 (fn () -> print "===")   // prints === three times
```

---

## The named builtins, alphabetical (122)

Not the whole 221: the `vec_*` / `owned_vec_*` / `strbuf_*` / `map_*` families
below are registered separately. `id` / `pair` / `swap` / `const` / `flip` left
this list in v0.1.318 — they are prelude definitions now (see Polymorphic
helpers above). The heading said 129 while the list held 127, before that.

```
abs args assert atan2 bit_and bit_not bit_or bit_shl bit_shr bit_xor
bool_of_str ceil char_at chr clamp
cos cube decr divmod e env_var even exit exp f_abs f_add
f_div f_ge f_gt f_le f_lt f_max f_min f_mul f_neg f_pow
f_sub fail file_exists float_of_int float_of_str floor
fst gcd incr int_max int_min int_of_float int_of_str
is_alpha is_digit is_space iter_n lcm log max min mk_logger
mk_metrics not odd ord pi pow print print_bool
print_err print_int print_no_nl random_float random_int
closure_code closure_env csr_read csr_write machine_scratch
raw_base raw_len raw_peek32 raw_peek8 raw_poke32 raw_poke8 raw_window trap_save
stdin_byte
read_file read_file_bytes read_line read_lines round show sign sin snd sqrt
square str_compare str_contains str_count str_ends_with
str_index_of str_join str_len str_of_float str_of_int
str_repeat str_replace str_rev str_split str_starts_with
set_trap_handler str_trim str_unescape substring sum_range tan time
to_lower to_upper try_or write_file write_file_bytes
```

Q-010 collection builtins (`vec_*` / `owned_vec_*` / `strbuf_*` / `map_*` / `len`) are registered builtins outside this table; see language-reference / tutorial.

**`vec_sort : Vec[R, T] -> (T -> T -> int) -> unit`** carries two guarantees that are
worth stating because a Mere program can observe both (v0.1.349). It is **stable** —
equal keys keep insertion order — and all four backends run the **same** bottom-up
merge sort, so the comparator is called the same number of times in the same order on
each of them; a comparator that counts or prints is a legitimate thing to write.
O(n log n) comparisons. It was an insertion sort on the compiled backends (O(n²), and
O(n²) memory too, because each comparison's curried application allocates in the
region) against `Array.sort` on the interpreter (O(n log n), unstable) — one program
with two asymptotics and two orderings, which
[`test/parity/vec_sort_stable.mere`](https://github.com/merelang/mere/blob/main/test/parity/vec_sort_stable.mere)
now pins by printing the comparison count.

The per-comparison allocation remains: applying a curried closure to its first
argument builds the intermediate closure's environment in the current region. It is
O(n log n) of them rather than O(n²), which is a rate rather than a leak, but a sort in
a hot loop still wants a `region R { … }` around it. Phase 19.2 added **`map_iter : Map[R, K, V] -> (K -> V -> unit) -> unit`** (works in all 4 backends).

---

## See also

- Operators (`+ * == ++ |> << >>` etc.) are **language syntax, not builtins**; see [language-reference.md](language-reference.md).
- Idioms: [patterns.md](patterns.md).
- Real-world example: `contrib/json/json.mere` combines many stdlib functions in a 140-line JSON parser (promoted from `examples/` to `contrib/` in Phase 40).
