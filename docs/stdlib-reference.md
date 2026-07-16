# Stdlib reference (mere)

106 builtins that are always available via `initial_env`. Check a name's type with `mere -te NAME`.

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

## I/O (10)

| Name | Type | Description |
|---|---|---|
| `print` | `str -> unit` | Write to stdout with newline |
| `print_no_nl` | `str -> unit` | Without newline + flush (for prompts) |
| `print_int` | `int -> unit` | Print integer with newline |
| `print_bool` | `bool -> unit` | Print bool with newline |
| `print_err` | `str -> unit` | Write to stderr with newline |
| `read_line` | `unit -> str` | One line from stdin; empty string on EOF |
| `read_file` ⚡ | `str -> str` | Read the whole file; raises on failure |
| `write_file` ⚡ | `str -> str -> unit` | Write content to path (overwrite); raises on failure |
| `read_lines` ⚡ ★ | `str -> str list` | Read line by line, returns `str list` (Phase 19.6; depends on prelude) |
| `file_exists` | `str -> bool` | Whether path exists (Phase 19.6; on C native since v0.1.15) |
| `file_mtime` | `str -> float` | Modification time in seconds; raises if the path is missing (interp + C native) |
| `file_size` | `str -> int` | File size in bytes (stat); binary-safe length where `str_len` (strlen) stops at a NUL. interp + C native (v0.1.21) |
| `env_var` ★ | `str -> str option` | Fetch env var; `None` if unset (Phase 19.6; depends on prelude) |
| `args` ★ | `unit -> str list` | The program's own args (after the script path / binary name); consistent interp ↔ native since v0.1.12 |
| `run` | `str -> int` | Run a command line via the shell, inherit stdio, return its exit code (interp + C native; v0.1.13) |

```
file_exists "/etc/hosts"            // → true
env_var "PATH"                      // → Some "..."
env_var "BOGUS"                     // → None
read_lines "data.txt"               // → ["line1", "line2", ...]
args ()                             // → ["foo", "bar"] (mere prog foo bar)
run "clang -O2 main.c -o app"       // → 0 on success, nonzero exit code otherwise
```

**★ Codegen status**: `print` / `print_no_nl` / `print_int` / `print_bool` / `print_err` / `read_file` / `write_file` work in all 3 backends (Wasm goes through host imports; `scripts/run_wasm.js` provides puts / read_file / write_file). `read_lines` / `args` / `env_var` are **interpreter-only** (codegen would need `'a list` / `'a option` construction + systematic outside-world access; not yet covered by Phases 22-31). The native-CLI / dogfood builtins `run` / `print_err` / `file_exists` / `file_mtime` / `file_size` / `tty_raw` / `tty_restore` / `read_key` / `random_int` also work on the **C native** backend (added for the `mk` / `mrog` / `mwasm` dogfoods, v0.1.13-v0.1.21).

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
| `str_of_float` | `float -> str` | Float to string (OCaml semantics) |
| `float_of_str` ⚡ | `str -> float` | Parse after trim; raises on bad input |

```
str_of_int 42        // "42"
int_of_str "  -7  "  // -7
bool_of_str "true"   // true
```

---

## String operations (22)

| Name | Type | Description |
|---|---|---|
| `str_len` | `str -> int` | Byte length |
| `str_contains` | `str -> str -> bool` | Substring containment |
| `str_starts_with` | `str -> str -> bool` | Prefix test |
| `str_ends_with` | `str -> str -> bool` | Suffix test |
| `str_count` | `str -> str -> int` | Non-overlapping occurrence count |
| `str_index_of` ★ | `str -> str -> int` | First position of needle; -1 if not found. Empty needle returns 0 (Phase 19.1) |
| `str_split` ★ | `str -> str -> str list` | Split by delimiter; returns `str list`. Requires `type 'a list = ...` declared. Empty delimiter returns a single-element list (Phase 19.1) |
| `utf8_len` ★ | `str -> int` | Codepoint count (a `str` is bytes; `str_len` is the byte length). Invalid bytes count as single units (v0.1.38) |
| `utf8_chars` ★ | `str -> str list` | Split into codepoints — the building block for text processing (v0.1.38) |
| `utf8_at` | `str -> int -> str` | i-th codepoint (prelude, on `utf8_chars`) |
| `utf8_sub` | `str -> int -> int -> str` | Codepoint-indexed substring (prelude) |
| `utf8_rev` | `str -> str` | Codepoint-wise reverse — `str_rev` is byte-wise and scrambles multibyte text (prelude) |
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

**★ Codegen status**: `str_index_of` / `str_split` / `str_join` / `str_count` / `str_compare` / `str_trim` / `str_starts_with` / `str_ends_with` / `str_contains` / `str_replace` / `str_repeat` / `str_rev` all work **across all 4 backends** (Phase 19.1.1 added str_index_of; Phase 22 added str_split / str_join; Phase 26.5 added all Wasm str ops; Phase 31.0 added str_compare; Phase 36 added str_trim / starts_with / ends_with / contains / replace / repeat / rev). `not` / `abs` / `min` / `max` / `clamp` / `chr` / `ord` / `to_upper` / `to_lower` / `even` / `odd` / `gcd` / `bool_of_str` also reached the 3 backends in Phase 36. The `fn (_: unit) -> body` wildcard parameter was also parser-fixed in Phase 36.

```
str_replace "foo bar foo" "foo" "X"           // "X bar X"
substring "hello world" 6 11                  // "world"
char_at "abcdef" 2                            // "c"
"world" |> str_contains "hello world"         // true (pipe + curry)
str_unescape "a\\nb"                          // a + newline + b (3 chars)
```

---

## Numeric operations (17)

| Name | Type | Description |
|---|---|---|
| `min` | `int -> int -> int` | Smaller |
| `max` | `int -> int -> int` | Larger |
| `abs` | `int -> int` | Absolute value |
| `sign` | `int -> int` | -1 / 0 / 1 |
| `clamp` | `int -> int -> int -> int` | `clamp lo hi x` restricts to `[lo, hi]` |
| `pow` ⚡ | `int -> int -> int` | base^exp; raises on negative exp |
| `square` | `int -> int` | x * x |
| `cube` | `int -> int` | x * x * x |
| `incr` | `int -> int` | +1 |
| `decr` | `int -> int` | -1 |
| `even` | `int -> bool` | n mod 2 == 0 |
| `odd` | `int -> bool` | n mod 2 != 0 |
| `gcd` | `int -> int -> int` | Euclid (handles negatives and 0 correctly) |
| `lcm` | `int -> int -> int` | `|a/gcd * b|`; 0 in input → 0 |
| `divmod` ⚡ | `int -> int -> (int * int)` | (quotient, remainder); raises on 0 div |
| `sum_range` | `int -> int -> int` | Sum over `lo..hi` (Gauss formula, O(1)) |
| `not` | `bool -> bool` | Logical negation |

### Float arithmetic (4)

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
| `log` ★ | `float -> float` | Natural log (Phase 19.7) |
| `exp` ★ | `float -> float` | e^x (Phase 19.7) |
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

---

## Polymorphic helpers (8 ★)

| Name | Type | Description |
|---|---|---|
| `show` ★ | `'a -> str` | Stringify any value via to_string |
| `id` ★ | `'a -> 'a` | Identity function |
| `fst` ★ | `('a * 'b) -> 'a` | Tuple first |
| `snd` ★ | `('a * 'b) -> 'b` | Tuple second |
| `pair` ★ | `'a -> 'b -> ('a * 'b)` | Tuple constructor (curried) |
| `swap` ★ | `('a * 'b) -> ('b * 'a)` | Tuple swap |
| `const` ★ | `'a -> 'b -> 'a` | Drop second arg, return first |
| `flip` ★ | `('a -> 'b -> 'c) -> ('b -> 'a -> 'c)` | Reverse arg order of a curried fn (higher-order) |

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

## JSON, derive-style (3 ★)

Structural JSON, compile-time-specialized per type (no trait machinery),
like `show`. `to_json` works on interp / C / Wasm; `of_json` /
`of_json_opt` on interp / C (native).

| Name | Type | Description |
|---|---|---|
| `to_json` ★ | `'a -> str` | Serialize any value to JSON structurally |
| `of_json` ★ | `str -> 'a` | Parse JSON into a typed value; **fails fast** on error (trusted input) |
| `of_json_opt` ★ | `str -> 'a option` | Same, but returns `None` on any error (safe for untrusted input) |

The `of_json` result type comes from the use site — annotate the
expression: `(of_json s : T)`. A JSON object maps to a record's fields (by
name), an array to a list or tuple, `null`/value to `option` (`None` /
`Some`), and a string / `{"Ctor": payload}` to a variant. `to_json` uses
the same mapping in reverse, so `(of_json (to_json x) : T) == x`.

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

## All builtins (alphabetical, 106)

```
abs args assert atan2 bool_of_str ceil char_at chr clamp const
cos cube decr divmod e env_var even exit exp f_abs f_add
f_div f_ge f_gt f_le f_lt f_max f_min f_mul f_neg f_pow
f_sub fail file_exists flip float_of_int float_of_str floor
fst gcd id incr int_max int_min int_of_float int_of_str
is_alpha is_digit is_space iter_n lcm log max min mk_logger
mk_metrics not odd ord pair pi pow print print_bool
print_err print_int print_no_nl random_float random_int
read_file read_line read_lines round show sign sin snd sqrt
square str_compare str_contains str_count str_ends_with
str_index_of str_join str_len str_of_float str_of_int
str_repeat str_replace str_rev str_split str_starts_with
str_trim str_unescape substring sum_range swap tan time
to_lower to_upper try_or write_file
```

Q-010 collection builtins (`vec_*` / `owned_vec_*` / `strbuf_*` / `map_*` / `len`) are registered builtins outside this table; see language-reference / tutorial. Phase 19.2 added **`map_iter : Map[R, K, V] -> (K -> V -> unit) -> unit`** (works in all 4 backends).

---

## See also

- Operators (`+ * == ++ |> << >>` etc.) are **language syntax, not builtins**; see [language-reference.md](language-reference.md).
- Idioms: [patterns.md](patterns.md).
- Real-world example: `contrib/json/json.mere` combines many stdlib functions in a 140-line JSON parser (promoted from `examples/` to `contrib/` in Phase 40).
