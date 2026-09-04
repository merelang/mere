# Patterns / cookbook (mere)

Common idioms encountered when actually writing Mere programs.

---

## 1. Guarded defensive programming

```
let safe_div = fn (a: int, b: int) ->
  if b == 0 then fail "div by zero"
  else a / b;
```

`fail` is polymorphic (`str -> 'a`), so it unifies correctly at branch merges. `assert (cond) "msg"` serves a similar purpose.

---

## 2. Treat errors as values via the Result type

```
type ('a, 'b) result = Ok of 'a | Err of 'b;

let parse_age = fn (s: str) ->
  let n = try_or (fn () -> int_of_str s) (- 1) in
  if n < 0 then Err ("invalid: " ++ s)
  else if n > 150 then Err "unrealistic age"
  else Ok n;

match parse_age "42" with
| Ok n  -> "age: " ++ show n
| Err e -> "error: " ++ e
```

Catch panics with `try_or` and repack them into a Result type.

---

## 3. Typical list operations (recursion)

```
type 'a list = Nil | Cons of 'a * 'a list;

// sum
let rec sum = fn xs -> match xs with
  | [] -> 0
  | [h, ...t] -> h + sum t;

// length
let rec len = fn xs -> match xs with
  | [] -> 0
  | [_, ...t] -> 1 + len t;

// map (hand-written)
let rec map = fn (f, xs) -> match xs with
  | [] -> []
  | [h, ...t] -> Cons (f h, map f t);

map (fn x -> x * x) [1, 2, 3, 4]    // [1, 4, 9, 16]
```

Note: Phase 36 added general-purpose list helpers (`list_filter` / `list_map` / `list_fold` / `list_sum` / `list_max` etc.) to the prelude (34 entries total). See [stdlib-reference.md](stdlib-reference.md) for details.

---

## 4. Accumulator-style recursion (tail-recursive flavor)

When direct recursion accumulates in reverse, finish with `rev`:
```
let rec rev_aux = fn (xs, acc) -> match xs with
  | [] -> acc
  | [h, ...t] -> rev_aux t (Cons (h, acc));

let rev = fn xs -> rev_aux xs [];

let rec map_acc = fn (f, xs, acc) -> match xs with
  | [] -> rev acc
  | [h, ...t] -> map_acc f t (Cons (f h, acc));
```

---

## 5. Readable transformation chains via pipe

```
"  42  "
  |> str_trim       // "42"
  |> int_of_str     // 42
  |> incr           // 43
  |> show           // "43"
```

`|>` is left-associative and lowest precedence, so it works above let/if without parens.

---

## 6. Point-free style with function composition

```
let show_inc = str_of_int << (fn x -> x + 1);
show_inc 41                                  // "42"

let process = str_trim >> to_upper >> (str_replace " " "_");
process "  hello world  "                    // "HELLO_WORLD"
```

`<<` is right-to-left; `>>` is left-to-right. Both right-associative.

---

## 7. Cap-passing (capability) pattern

Bundle multiple dependencies in one go:
```
signature ctx = (db: int, log: int);

let save_user = fn (...ctx, name: str) ->
  // db and log come into scope
  print ("saving " ++ name ++ " (db=" ++ show db ++ ", log=" ++ show log ++ ")");

let log_event = fn (...ctx, evt: str) ->
  print ("event: " ++ evt ++ " (log=" ++ show log ++ ")");

// Call sites unroll via currying
save_user 100 10 "alice";
log_event 100 10 "logged-in";
```

`signature` declarations expand at parse time, so the call sites are ordinary curried applications.

---

## 8. Immutable record update

```
type Config = { name: str, port: int, debug: bool };

let default_cfg = Config { name = "app", port = 8080, debug = false };

let dev_cfg = { default_cfg | debug = true, port = 3000 };
let prod_cfg = { default_cfg | name = "app-prod" };
```

The base record doesn't change (immutable). Multiple fields can be updated at once.

---

## 8.4. A function whose body is a region

A `region R { ... }` is an expression, so **it can be the whole body of a
function** — and that is usually where you want it. Everything the body
allocates dies when the call returns; only the result is copied out.

```mere
let sum_scratch = fn (n: int) -> region R {
  let rec go = fn (i: int) -> fn (acc: int) ->
    if i == 0 then acc else go (i - 1) (acc + str_len (str_repeat "x" 32)) in
  go n 0
};
```

Measured on that function at n = 2000, twice over: with the region, the default
region takes **32 bytes** and the named arena takes 192,000 across two arenas.
Without it, all 192,032 bytes land in the default region and stay there for the
life of the process, because the default region is never freed.

That is the whole trade, and it is worth stating plainly: **Mere does not
reclaim by default.** A program that allocates in a loop and never says
`region` holds everything it ever allocated. The construct is not an
optimisation to reach for when something is slow; it is how you say "these
allocations are temporary", and nothing else says it for you.

Why the function boundary in particular: the cost of a region is entirely
what has to CROSS it. A block draws that boundary wherever you happened to
type `{`; a function draws it where the crossing set is already written down —
the parameters and the return type. On the `binarytrees` benchmark, wrapping
each batch in a block cost nothing at all (the result is an `int`) and cut peak
memory sixfold and wall clock by a third.

**What cannot cross.** The result may not mention `R`, which means a function
like this cannot RETURN a container built inside it:

```mere
let mk = fn (n: int) -> region R {
  let v = vec_new () in
  let _ = vec_push v n in
  v                      // ERROR: Vec[R, int] cannot leave region R
};
```

Nor can it store one into something that outlives the call — that is rejected
too, since v0.1.323:

```mere
let m = map_new () in
let _ = region R {
  let v = vec_new () in
  map_set m "k" v        // ERROR: `m` now holds a value from region `R`
} in ...
```

Values that are DEEP-COPIED on the way out are fine and need no thought: `str`,
records, tuples, recursive variants like `list`, and closures (their captured
environment is copied with them). It is containers — `Vec`, `Map`, `StrBuf` —
that are handles, and a handle copied out of a dead arena is a dangling
pointer. Build them outside the region, or copy their contents out.

**Where to draw it: around the expression whose answer is small.** On the
`binarytrees` benchmark, a block around each depth's whole batch peaks at
28 MiB; a block around the single expression `check (build d)` -- one tree in,
one int out -- peaks at 5.8 MiB, the same footprint as the Rust program and a
third of the C program's wall clock, while the naive program holds 169 MiB. The
loop that calls it stays a tail call because the region wraps the ARGUMENT of
the recursive call, not the call: `batch d (iters - 1) (acc + (region R {
check (build d) }))`. Wrapping the whole body of a tail-recursive function
would nest one open region per iteration instead.

**Do not materialise what you only walk once.** `str_split` on a 1.8 MB text
builds a 300,000-element list that costs 48 bytes a word -- 14 MB for words
that are read once and counted. Reading a line at a time inside a per-line
region (`file_read_line`, or `contrib/stream`) and splitting the line keeps
the footprint at the table plus one line: the `wordfreq` benchmark's streaming
row runs in 4.1 MiB and 23 ms where the one-shot program takes 26.9 MiB and
29 ms, and prints the same bytes.

**Ask the compiler where.** `mere --suggest-regions file.mere` lists the
expressions where a `region R { }` would bound the footprint -- calls,
comparisons and matches whose value is a scalar and whose operand is a
freshly built heap value, and non-recursive functions with a scalar result and
an allocating body. It infers nothing and edits nothing; on the binarytrees
program it names `check (build d)`, the one expression above. Treat it as a
report: every line is a true statement about garbage, and whether that garbage
matters is yours to decide.

**Build a list in order with `ListBuf`, not with an accumulator you reverse.**
`lb_new` / `lb_push` / `lb_to_list` produce a `T list` first-to-last for one
cell per element; the `Cons (x, acc)` + `list_rev` idiom pays a second cell per
element that is garbage the moment the reverse returns (23 MB on the JSON
benchmark). Push where the builder was created -- a push from inside a
`region` block that the builder was not born in is refused, because the cell
would outlive its value.

**Sort a `Vec`, not a list, when the list is large.** `list_sort_by` is a
stable merge sort over an immutable list, and an immutable list's merge sort
allocates about 3n log n cells plus one closure environment per comparison;
sorting 5,000 pairs allocated 8.3 MB. `vec_sort` is the same stable merge
sort in place, and its scratch buffer is malloc/free rather than arena, so it
leaves nothing behind. Both are in the stdlib reference.

---

## 8.5. "Update only one element" inside a collection of records

`Vec` / `OwnedVec` are append-only and records are immutable, so there's no direct way to mutate a specific record in a collection. Instead, **use `vec_map` + `{ t | f = v }` to build a "new collection with conditional elements replaced"**:

```mere
type Task = { id: int, text: str, done: bool };

let mark_done = fn tasks -> fn target_id ->
  region R {
    let src = owned_vec_to_vec tasks in
    let dst = vec_map src (fn (t: Task) ->
      if t.id == target_id then { t | done = true }   // ← targeted update
      else t) in
    vec_to_owned dst
  };
```

Points:

- `{ t | done = true }` is equivalent to `Task { id = t.id, text = t.text, done = true }` but skips the fields that don't change, making the update intent explicit.
- The result is a **new `OwnedVec`**, so the caller must rebind (see §8.6's same-name rebinding).
- The **explicit annotation `fn (t: Task) -> ...` is required**. HM doesn't reverse-engineer which record a closure parameter belongs to (from the field names used), so `t.done` would otherwise fail to type.

---

## 8.6. Chain immutable updates with same-name rebinding

When chaining functions that return a new collection (like `mark_done`), **rebinding with the same name** reads naturally:

```mere
let tasks = owned_vec_new () in
let __ = owned_vec_push tasks (Task { id = 1, text = "buy milk", done = false }) in
let __ = owned_vec_push tasks (Task { id = 2, text = "write report", done = false }) in

// Same-name rebinding to "mark tasks 1 and 2 done"
let tasks = mark_done tasks 1 in
let tasks = mark_done tasks 2 in
```

This is the natural ML-family style and works across all 4 backends — interpreter / C / LLVM / Wasm (codegen internally expands to a 2-step form to avoid C's `__auto_type` self-init constraint).

---

## 9. List construction idioms

```
// Sugar
let xs = [1, 2, 3, 4];

// Programmatic
let rec range = fn (lo: int, hi: int) ->
  if lo > hi then []
  else Cons (lo, range (lo + 1) hi);

range 1 5                                    // [1, 2, 3, 4, 5]
```

---

## 10. Destructuring nested structures

```
type 'a list = Nil | Cons of 'a * 'a list;
type 'a opt  = None | Some of 'a;

match [Some 1, None, Some 3] with
| [Some a, _, Some b] -> a + b              // deep destructure in a single arm
| _                   -> -1
```

Use `as-pattern` to bind a substructure and the whole at once:
```
match [1, 2, 3, 4] with
| [a, b, ...rest] as whole -> (a + b, whole)
| _                        -> (0, [])
```

---

## 11. Threading "next position" through a parser

```
// Parser takes (str, int), returns (value, next_int)
let parse_num = fn (s: str, i: int) ->
  let rec scan = fn (j: int) ->
    if j >= str_len s || not (is_digit (char_at s j)) then j
    else scan (j + 1)
  in
  let end_pos = scan i in
  if end_pos == i then fail "expected digit"
  else (int_of_str (substring s i end_pos), end_pos);

// Destructure to thread "next position" through the chain
let (a, i) = parse_num s 0 in
let (b, i) = parse_num s (i + 1) in
a + b
```

`contrib/json/json.mere` actually uses this pattern.

---

## 12. Debug print is `show`

```
let _ = print ("xs = " ++ show xs);              // "xs = [1, 2, 3]"
let _ = print ("user = " ++ show user);          // "user = User { name = ..., age = ... }"
let _ = print ("result = " ++ show (parse_json input));
```

`show : 'a -> str` is polymorphic, so records/sums/lists/tuples all stringify via the internal `to_string`. Cons/Nil chains print in the concise `[a, b, c]` form.

---

## 13. Side-effect loops via `iter_n`

```
iter_n 5 (fn () -> print "===");

// Print something some number of times
let echo = fn (n: int, s: str) ->
  iter_n n (fn () -> print s);

echo 3 "hello"
```

---

## 14. Ordered side effects with block expressions

```
{
  print_no_nl "Name: ";
  let n = read_line () in
  print ("Hi, " ++ n ++ "!");
  0
}
```

`{ e1; e2; ...; eN }` is sugar for `let _ = e1 in let _ = e2 in ... in eN`. The final expression is the value.

---

## 14.5. Phase 36 sugar idioms

### Flatten nested matches with `?` / `?!`

```mere
// Old: nested match for None / Err propagation
let safe = fn x ->
  match parse x with
  | None -> None
  | Some a ->
    match step1 a with
    | None -> None
    | Some b ->
      match step2 b with
      | None -> None
      | Some c -> Some (a + b + c);

// New: ? for early-return
let safe = fn x ->
  let a = parse x ? in
  let b = step1 a ? in
  let c = step2 b ? in
  Some (a + b + c);
```

Result version uses `?!` with the same pattern. `examples/calc.mere`'s parser is a good real example (138 lines / 5 `?!` chain sites).

### Combine filter + map with list comprehension

```mere
// Old: two stages
let xs = list_map (1..100) (fn x -> x * x) in
let ys = list_filter xs (fn x -> x % 2 == 0);

// New: in one shot
let ys = [x * x | x <- 1..100, (x * x) % 2 == 0];

// Multi-gen for cartesian
let pairs = [(a, b) | a <- 1..5, b <- 1..5, a + b == 6];
```

### `for-in-do` for side-effect loops; `while-do` for loops inside fn bodies

```mere
// Just print
for x in 1..10 do print (show x);

// Accumulating loops via map_set / owned_vec_push etc.
for x in xs do
  let _ = owned_vec_push buf (transform x) in ();

// while: usable inside an fn body
let consume_stream = fn stream ->
  while !(stream_eof stream) do
    let x = stream_next stream in
    let _ = process x in ();
```

Note: `while` currently has codegen support only inside fn bodies (top-level main is unsupported).

### Single-shot `Option` extraction with `if let`

```mere
if let Some n = map_get config "timeout" then
  use_timeout n
else
  use_default ();
```

### Simpler log output via string interpolation

```mere
// Old: ++ chain
print ("user=" ++ name ++ ", age=" ++ show age ++ ", role=" ++ role);

// New: interpolation
print "user={name}, age={show age}, role={role}";
```

Caveats:
- Nested string literals are forbidden (`"x = {show \"abc\"}"` → error). Escape via let.
- `\{` escapes a literal `{`.
- The interior of `{}` is any expr (function applications / arithmetic / match all OK).

### Range + ::, <|, @@ for readable expressions

```mere
// range + list_map
list_map (1..10) (* 2)                       // op section
0 :: 1 :: 2 :: 3 :: []                       // explicit list construction
print <| "result: " ++ show answer           // reverse pipe
print @@ "lengthy message that goes way " ++
  "over one line — @@ avoids needing parens"
```

---

## 15. Using polymorphic helpers

```
fst (pair "hello" 42)            // "hello"
snd (pair "hello" 42)            // 42
swap (1, 2)                      // (2, 1)
const "constant" "anything"      // "constant"
flip (fn a -> fn b -> a - b) 3 10   // 7 (= sub 10 3)
```

---

## Anti-patterns / gotchas

### 1. Passing the literal `-1` as a function argument

```
abs -1               // syntactically read as (abs - 1) (subtraction)
abs (- 1)            // OK: parens (with one space)
abs (-1)             // The current lexer doesn't recognize `-` followed by digits as a negative literal
```

### 2. ~~Verbose single-char comparisons~~ → fixed (char literals + match)

```
// Old:
if char_at s i == "n" then ... else if char_at s i == "t" then ...

// New: char literal `'X'` + match
match char_at s i with
| 'n' -> ...
| 't' -> ...
| _   -> ...
```

### 3. ~~Match exhaustiveness is checked at runtime~~ → Phase 1 added warnings

```
match opt with
| Some n -> n
// stderr: "line X, col Y: warning: non-exhaustive match (missing None)"
// Evaluation proceeds, but a runtime Eval_error occurs if None arrives
```

Exhaustiveness for bool and variants is detected at compile time as a warning. int/str/tuple/record still need a wildcard arm. To enforce full coverage, write `| _ -> default` or `| None -> fail "..."`.

### 4. Record update needs the base's type

```
fn p -> { p | x = 0 }                   // p's type is unknown → type error
fn (p: Point) -> { p | x = 0 }          // OK with annotation
```

Without row polymorphism, record-typed function args need annotations.

### 5. Top-level fn names collide with libc / libm / C keywords (C codegen)

C codegen emits top-level fns directly as C functions, so names that already exist in macOS / Linux's libc / libm or are C language keywords cause compile errors. Real collisions found in Phases 32-38:

| Mere name | Collides with |
|---|---|
| `div` | `stdlib.h`'s `div(int, int)` (returns quotient + remainder) |
| `mergesort` | macOS BSD `stdlib.h`'s `mergesort(...)` |
| `pow` / `sqrt` / `sin` / `cos` / `exp` / `log` | `math.h` libm functions |
| `system` / `getenv` / `setenv` / `rand` / `srand` | `stdlib.h` |
| `time` / `clock` | `time.h` |
| `read` / `write` / `open` / `close` | POSIX I/O |
| `short` / `long` / `int` / `char` / `float` / `double` | C keywords (`__auto_type short = ...` is a syntax error) |
| `signed` / `unsigned` / `register` / `static` / `auto` | C storage classes / modifiers |
| `goto` / `return` / `break` / `continue` | C control-flow keywords |

**Type names collide too, and for one more reason.** A `type` lowers to
`typedef struct <name> <name>;`, which claims C's **tag** namespace as well as its
ordinary one — so a type named `wait` collides with `union wait` in `<sys/wait.h>`
*and* with the `wait()` declared beside it. The list above applies unchanged (a
typedef is an ordinary identifier), plus the struct tags the emitted headers bring
in: `wait`, `tm`, `timeval`, `timespec`, `stat`, `dirent`, `sockaddr`, `addrinfo`,
`hostent`, `termios`, `winsize`, `sigaction`, `iovec`, `fd_set`, `div_t` and family.

The mraft dogfood named a type `wait` and found this from clang rather than from the
compiler: the check existed and had only ever looked at `let` names. **Warned about
since v0.1.223**, on the type name itself, on both the compiler's path and the
editor's.

**Workarounds**: shorten by 1-2 chars (`mergesort` → `msort`, `div` → `divi`, `short` → `small_doc`), use a verb phrase (`sort_list` / `power_int`), or add a prefix (`mere_sort`), etc. The interpreter is unaffected, so verification looks fine until codegen is attempted. **Phase 38.A3 added a linter that warns at parse time** ([lib/pipeline.ml:42-82](../lib/pipeline.ml)).

**The full reserved-name list (~110 names) is in [docs/reserved-names.md](reserved-names.md)**.

### 6. The empty list literal `[]` is polymorphic `'a list` and breaks codegen

```mere
let xs = [];          // inferred: 'a list
let _ = some_use xs;  // even if later inferred to int, codegen sees the 'a leak in xs's type
```

C / LLVM codegen need a concrete element type, but the narrow value restriction (Phase 36) still generalizes empty lists. **Workaround**:

```mere
let xs = (Nil: int list);                     // recommended: explicit annotation
let xs: int list = Nil;                       // equivalent (either works)
```

When binding an empty list, fix the element type with an annotation. Non-empty lists (`[1, 2, 3]`) are inferred from elements, so no annotation is needed.

### 7. `Map[K, V]` only takes two args; you need `Map[R, K, V]` (3 args)

Mere's Map has a region parameter, so type annotations must include R:

```mere
// NG
let f = fn (m: Map[str, int]) -> map_get m "k";
// type error: expected `Map['c, 'b, 'a]`, got `(str, int) Map`

// Works (write R as a type variable)
let f = fn (m: Map[R, str, int]) -> map_get m "k";
// → but mismatch with the actual region can still cause separate type errors

// Easiest: skip annotations and let inference handle it
let f = fn m -> map_get m "k";
```

ML-familiar users tend to write K and V only, but Mere requires the region — three args. This is a common stumbling block for first-time users, so it's documented in patterns / tutorial.

### 8. ~~Closure capture leaks for inner-lifted fns through anonymous Fun~~ ✅

✅ **Fully resolved by Phase 39.A2 + Phase 45 (2026-06-23)**:

- Phase 39.A2: in cases like `list_iter (...) visit` where inner-lifted fns are used in value position "outside an anonymous Fun", the 3 backends now work (env is allocated in the default region + a closure value calls the lifted fn through an adapter).
- Phase 45: **mutual references between inner-lifted fns** are resolved — added a **transitive capture closure** step at the end of `lift_inner_fns`. When lifted fn A calls B and B captures `base`, A also transitively captures `base` and puts it in the env. Also, inner-lifted fn names are excluded from direct captures (since they're not runtime values), aligning with emit_expr's existing dispatch (where `App (Var n, arg)` directly emits `__lifted_X(caps, arg)`). The same algorithm is implemented in C / LLVM / Wasm.

This makes patterns like `let rec helper = fn x -> ... let rec caller = fn y -> helper y ...` work in all 4 backends. The markdown_to_html workaround that wrote `find_double` / `find_single` as module-external top-level fns is **no longer needed** (the existing code is preserved as-is; a future refactor can move them back into the module).



When you define `let rec foo = fn ...` inside a function, reference outer-scope variables, and then call it via an anonymous closure (e.g. `list_iter ... (fn v -> foo v)`), C codegen couldn't carry `foo`'s closure captures into the anonymous closure's env, failing with `error: use of undeclared identifier 'x'`.

```mere
// NG (fails in C codegen)
let dfs = fn graph ->
  let visited = map_new () in
  let rec visit = fn u ->
    let _ = map_set visited (show u) 1 in        // visited is in outer scope
    list_iter (neighbors graph u) (fn v -> visit v) in   // anonymous Fun calls visit
  visit 0;
```

**Workarounds (three)**:

1. Rewrite as **iterative + explicit stack/queue** (managed via Map). The dfs_bfs.mere / topological_sort.mere implementation pattern.
2. **Explicit recursion to consume the list**: write a mutually recursive fn like `visit_list` instead of `list_iter (fn v -> visit v)`.
3. **Pass outer-scope state explicitly as an argument**: avoid closure capture entirely, e.g. `visit visited graph u`.

The cleanest would be `list_iter (neighbors xs u) visit` — pass the fn value directly to the builtin without making a closure. But using inner-lifted fns in value position is currently unsupported (DEFERRED §1.2 related); the partial-app synthesizer (Phase 38.C) is limited to builtins.

### 9. `substring s start end` — `end` is an exclusive position, not a length

Intuitively, you might write `substring s 4 (str_len s - 4)`, but the 3rd argument is a **position** (exclusive), not a length. Reversed ranges cause runtime errors.

```mere
// NG
substring "### Subsection" 4 (str_len "### Subsection" - 4)
// → substring 4 10 → eval error: range [4, 10) on "### Subsection" — not what you want
//   That's correct if you want chars 4..10, but if you want "Subsection"
//   (= chars 4..14) it's wrong

// Right
substring "### Subsection" 4 (str_len "### Subsection")
// → "Subsection" (from 4 to the end)
```

Signature: `substring : str -> int -> int -> str` taking `(s, start, end)`. `end` is exclusive — `s[start..end)`. Same as Python slicing.

### 10. Single-arg builtins (`int_of_str` etc.) used in value position become unbound in C codegen

```mere
list_map (str_split s ",") int_of_str
// codegen error: use of undeclared identifier 'int_of_str'
```

Phase 38.C made curried collection builtins like `vec_push` / `map_set` usable in value position via synthesis, but **single-arg builtins like `int_of_str` / `str_len` / `ord` / `show` aren't covered** (1-arg, so different from Phase 35's nullary factory eta-wrap path). They show up as undefined C functions.

**Workaround**:

```mere
list_map (str_split s ",") (fn x -> int_of_str x)
```

Wrapping in `fn x -> ...` lets the existing anonymous-Fun adapter machinery handle the closure conversion. Only one character extra — a light workaround.

A future extension of Phase 38.C's synthesize_curried_eta to 1-arg builtins would make this unnecessary (low priority; issue-driven).

### 12. Record literals inside list literals require `Type {…}` (the type prefix)

Record literals inside list literals **must always be written `TypeName { ... }`**. The field-only form `{ x = 1, y = 2 }` is parsed as if it were "middle of list structure" and cuts the literal short:

```mere
type Point = { x: int, y: int };

// NG (parse error or odd type errors)
let ps = [{ x = 1, y = 2 }, { x = 3, y = 4 }];

// OK: each record literal gets a Type prefix
let ps = [Point { x = 1, y = 2 }, Point { x = 3, y = 4 }];
```

Reason: the parser has no recovery path that interprets the `{ ... }` immediately after `[` as a standalone record literal. To reliably close a record literal as an expression, `TypeName {` is needed; mid-list records require the same prefix.

**Furthermore**: write record type names as **uppercase-starting** (`Point` / `Task` / `User`) to reduce ambiguity in literal-only contexts (list elements, the RHS of match arms) and to stay consistent with patterns / examples. Lowercase type names (`type point = { ... }`) are hard to distinguish from constructor syntax; task_scheduler.mere needed the rewrite `type task` → `type Task` (2026-06-23 dogfood).

### 11. Destructure 3-tuples or larger via `let (a, b, c) = ...`, not `fst`/`snd`

`fst` / `snd` are 2-tuple only. For 3-tuples and larger, destructure via patterns:

```mere
let r = ext_gcd 30 18;     // r: int * int * int
// NG (type error)
let g = fst r in
let x = fst (snd r) in     // snd : (int * int * int) -> ? — won't pass

// OK
let (g, x, y) = ext_gcd 30 18 in ...
```

A 3-tuple is internally one tuple (`int * int * int`), not a nested pair `(a, (b, c))`. fst/snd are defined as 2-tuple-only builtins in the OCaml tradition.

---

## See also

- Full syntax: [language-reference.md](language-reference.md)
- All builtins: [stdlib-reference.md](stdlib-reference.md)
- Getting started: [tutorial.md](tutorial.md)
