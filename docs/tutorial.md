# Tutorial (mere)

For readers with ML-family experience. About a 15-minute read.

## 0. Install and run

```sh
git clone git@github.com:284km/mere
cd mere
dune build
dune exec ./bin/mere.exe -- -e '1 + 2 * 3'   # → 7
dune exec ./bin/mere.exe -- -r               # REPL
```

Below, `mere` is shorthand for `dune exec ./bin/mere.exe --`.

## 1. Expressions and evaluation

```
> 1 + 2 * 3
- : int = 7

> "Hello, " ++ "World"
- : str = "Hello, World"

> if 1 < 2 then "yes" else "no"
- : str = "yes"

> 3.14 |> f_mul 2.0
- : float = 6.28
```

Integer arithmetic, string concat `++`, comparisons, logic `&& ||`, and `if-then-else` follow the ML tradition. `int` and `float` are different types — use the `f_add`/`f_sub`/`f_mul`/`f_div` builtins for float arithmetic (`float_of_int` / `int_of_float` for explicit conversion).

## 2. Variables (`let`) and functions (`fn`)

```
> let x = 5 in x * 2
- : int = 10

> let inc = fn x -> x + 1 in inc 41
- : int = 42

> let add = fn (a: int, b: int) -> a + b in add 3 4
- : int = 7
```

`fn (a, b) -> ...` is desugared into currying (`a -> b -> result`).

Partial application works naturally:
```
> let add5 = add 5 in add5 10
- : int = 15
```

## 3. Recursion and mutual recursion

```
> let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10
- : int = 3628800

> let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
  and     is_odd  = fn n -> if n == 0 then false else is_even (n - 1)
  in is_even 100
- : bool = true
```

## 4. Type inference

HM inference runs without annotations:
```
> fn x -> x
- : ('a -> 'a)                 # polymorphic id

> fn f -> fn g -> fn x -> f (g x)
- : (('a -> 'b) -> (('c -> 'a) -> ('c -> 'b)))

> let id = fn x -> x in if id true then id 1 else id 2
- : int = 1                    # let-poly: the same id works for bool and int
```

## 5. Pattern matching

### Integer / literal / guard
```
match n with
| 0            -> "zero"
| x when x < 0 -> "negative"
| _            -> "positive"
```

### Constructors (sum types)
```
type 'a opt = None | Some of 'a;

match Some 42 with
| None   -> 0
| Some n -> n + 1
```

### Tuples
```
match (1, 2) with
| (0, 0) -> "origin"
| (x, _) -> "x = " ++ show x
```

### Lists
```
type 'a list = Nil | Cons of 'a * 'a list;

match [1, 2, 3] with
| []          -> "empty"
| [a]         -> "single"
| [h, ...t]   -> "head: " ++ show h
```

### or-pattern / as-pattern
```
match day with
| 6 | 7              -> "weekend"          // or-pattern
| _                  -> "weekday"

match (1, 2) with
| (a, b) as whole    -> show whole         // as-pattern: bind whole tuple to `whole`
```

### Char literals (length-1 strs)
```
'A'                  // length-1 str "A"
'\n'                 // newline as a length-1 str

match char_at s i with
| 'a' | 'e' | 'i' | 'o' | 'u' -> "vowel"
| c when is_digit c           -> "digit"
| _                            -> "other"
```

`'X'` is just a length-1 str (Mere has no separate char type). Disambiguated from type-variable syntax (`'a` etc.) by the presence or absence of the closing quote.

## 6. Data types

### Sum type (variant)
```
type ('a, 'b) result = Ok of 'a | Err of 'b;

let safe_div = fn (a: int, b: int) ->
  if b == 0 then Err "div by zero"
  else Ok (a / b);

match safe_div 10 3 with
| Ok n  -> show n
| Err e -> "error: " ++ e
```

### Record
```
type Point = { x: int, y: int };

let p = Point { x = 3, y = 4 };
let dist_sq = p.x * p.x + p.y * p.y;

let p2 = { p | x = 100 };           // immutable update
```

### Type alias
```
type UserId = int;
type Pair = int * int;
type 'a Stack = 'a list;
```

## 7. Lists

Lists are "user-defined" but comfortable thanks to syntax sugar + stdlib:
```
type 'a list = Nil | Cons of 'a * 'a list;

let xs = [1, 2, 3, 4, 5];

let rec sum = fn xs -> match xs with
  | [] -> 0
  | [h, ...t] -> h + sum t;

sum xs                              // 15
```

## 8. Higher-order functions / pipes / composition

### Pipe `|>`
```
5 |> (fn x -> x + 1) |> (fn x -> x * 2)     // 12
42 |> str_of_int                            // "42"
```

### Compose `<<` / `>>`
```
let show_inc = str_of_int << (fn x -> x + 1);
show_inc 41                                 // "42"

(fn x -> x * 2) >> str_of_int               // = fn x -> str_of_int (x * 2)
```

## 8.5. Type-error UX

Type errors are displayed in a Rust-style code frame (`error: ...` header / `-->` location / source line + caret / `help:` / `note:`). Common typos are suggested via Levenshtein:

```
let factorial = ... in factrial 5
// type error: unbound variable: factrial
//   help: did you mean `factorial`?

type Pt = { name: str, value: int };
let p = Pt { name = "a", value = 1 } in p.namee
// type error: record Pt has no field: namee
//   help: did you mean `name`?

module M { let rec fact = ...; }; M.fct 5
// type error: unbound variable: M.fct
//   help: did you mean `M.fact`?
```

Suggestions cover: unbound variable / unknown constructor / unknown record type / record / view field typos / qualified module-path typos.

## 9. Error handling

```
fail "panic message"                // unifies with any type
assert (x > 0) "x must be positive";

let safe_parse = fn s ->
  try_or (fn () -> int_of_str s) (- 1);

safe_parse "42"                     // 42
safe_parse "abc"                    // -1
```

## 9.5. File I/O

```
let content = read_file "input.txt";       // whole file as str
let _ = write_file "out.txt" "hello lang"; // overwrite

// Process input is also available
let line = read_line ();                   // one line from stdin
let _ = print_no_nl "Name: ";              // prompt (no newline)
let _ = print_err "error message";         // stderr
```

Errors like "file not found" raise `Eval_error`. Use `try_or` for safe-parse patterns.

## 10. Signature alias (cap-passing pattern)

Reuse a "bundle" of multiple arguments:
```
signature ctx = (db: int, log: int);

let save_order = fn (...ctx, order: int) -> db + log + order;
let log_event  = fn (...ctx, evt: int)   -> log + evt;

save_order 100 10 5 + log_event 100 10 7    // 132
```

## 10.4. Borrow annotations (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`)

`&R T` is a reference to a value inside region R. **Borrow modes** let you write "what kind of access" into the type (introduced in Phase 11.1).

| Syntax | Mode | Intent |
|---|---|---|
| `&R T` (default = elided) | borrowed (shared read) | Configuration values / read cap |
| `&shared write R T` | shared write | Logger / Metrics etc. — concurrent writes by multiple callers (internal safety of the cap) |
| `&exclusive R T` | exclusive read | Exclusive read (rare) |
| `&mut R T` | exclusive write | Like a DB connection's transaction; equivalent to Rust's `&mut` |

```
type DbHandle = { id: int };

let db_exec = fn (db: &mut R DbHandle) -> fn (sql: str) ->
  "[exclusive] " ++ sql;

region R {
  let db = DbHandle { id = 1 } in
  let db_ref = &mut R db in
  db_exec db_ref "UPDATE ..."
}
```

If modes differ, unification is rejected:

```
let db_ref = &R db in           // shared read
db_exec db_ref "X"               // ← requires &mut → type error
// expected `&mut R DbHandle`, got `&R DbHandle`
```

This lets the design's **Logger problem** (`&borrowed` doesn't express write intent; `&mut` forbids concurrency) be written at the type level as `&shared write`.

**Phase 11.3 introduced auto-deref for field access through `&R T`**:

```
let logger = mk_logger "app" in
region R {
  let lg_ref = &shared write R logger in
  lg_ref.info "hi"     // → prints "app [INFO] hi"
}
```

Borrow mode stays a static contract; at runtime, the original record's fields are called directly (currently works in interpreter and all 3 backends).

**Phase 11.4: borrow checker (rejects conflicting borrows of the same variable)**

Trying to borrow the same variable inside a region with two conflicting modes is a static error:

```
region R {
  let v = 5 in
  let a = &R v in        // shared read
  let b = &mut R v in    // ← requires exclusive write → rejected
  42
}
// type error: borrow conflict: `v` is already borrowed as `&R v` here,
//   cannot reborrow as `&mut R v`
//   note: previous borrow at line N, col N
```

The only coexistable pairs are `&R` + `&R` (shared read) and `&shared write R` + `&shared write R`. All other combinations conflict. See [`examples/borrow_conflict.mere`](../examples/borrow_conflict.mere) for a runnable failure example.

**Phase 11.5 added complex place-expression tracking** — field-access paths like `&R p.x` are compared as identifiers (`"p.x"`, `"p.q.r"` etc.). Borrowing different fields in different modes is OK; borrowing the same field in incompatible modes is statically rejected:

```
type Pt = { x: int, y: int };
region R {
  let p = Pt { x = 3, y = 4 } in
  let a = &R p.x in
  let b = &mut R p.x in 42   // conflict: borrow conflict: `p.x` is already ...
}

region R {
  let p = Pt { x = 3, y = 4 } in
  let a = &R p.x in
  let b = &mut R p.y in 42   // OK: different field
}
```

The whole `p` and `p.x` are treated as different places (current simple comparison). A more sophisticated place-subset analysis is a separate slice.

**Phase 11.6 added borrow propagation through if branches** — for cases where a borrow leaks out as an if-expression's result (`let r = if c then &R x else &R y in body`), both branches' borrows are added as a union to body's active set. Since the result depends on the runtime path, both are conservatively treated as active:

```
region R {
  let x = 1 in let y = 2 in
  let r = if 1 < 2 then &R x else &R y in
  let m = &mut R y in 0
  // type error: borrow conflict: `y` is already borrowed as `&R y` here,
  //   cannot reborrow as `&mut R y` (else branch from y)
}
```

This catches borrow leaks through `if` too. The remaining borrow-checker DEFERRED item is §2.3 NLL (a flow analysis that releases borrows that are no longer in use).

Runnable examples: [`examples/borrow_modes.mere`](../examples/borrow_modes.mere); deliberately-erroring side: [`examples/borrow_modes_typeerror.mere`](../examples/borrow_modes_typeerror.mere).

## 10.5. Modules and import

Group related bindings under `module M { ... }`. Refer to bindings externally as `M.name`.

```
module Math {
  let inc = fn x -> x + 1;
  let square = fn x -> x * x;
  let inc_then_square = fn x -> square (inc x);
};

Math.inc_then_square 4    // 25
```

Short names inside a module (`inc`, `square`) get parse-time rewritten to `Math.inc`, `Math.square`, so mutual references (like `inc_then_square` using `square (inc x)`) work naturally. `let rec` self-references work the same way.

Declarations split into another file are pulled in via `import "path";`.

```
// lib_list_ops.mere
type 'a list = Nil | Cons of 'a * 'a list;
module ListOps {
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t;
};
```

```
// main.mere
import "lib_list_ops.mere";
ListOps.sum [1, 2, 3, 4, 5]    // 15
```

The same path imported directly or transitively multiple times is loaded only once (cycle guard). Paths are resolved relative to cwd (slice 1).

**Phase 9.3 added nested modules and `open M;`**:

```
module Math {
  let inc = fn x -> x + 1;
  module Adv {
    let square = fn x -> x * x;
  };
  let inc_then_square = fn x -> Adv.square (inc x);
};

Math.Adv.square 7              // 49 (qualified nested access)

open Math;                      // direct bindings become unqualified
inc 5                           // 6 (after open)
Math.Adv.cube 2                 // 8 (nested ones stay qualified)
```

`open M;` is sugar that, for each direct (non-nested) binding of M, expands a `let name = M.name;` alias. Nested module exports are intended to be used as-is via qualified access.

**Phase 9.4 lets you `type` / `record` / `variant` declare inside a module**:

```
module M {
  type Pt = { x: int, y: int };
  type 'a opt = MyNone | MySome of 'a;
  let mk = fn p -> Pt { x = fst p, y = snd p };
  let unwrap = fn o -> match o with | MyNone -> 0 | MySome n -> n;
};

let p = M.mk (3, 4) in p.x + p.y          // 7
M.unwrap (MySome 35)                       // 35
```

Current limits (slice 1):
- Type / record / constructor names declared inside a module **go into the global registry without M-prefix**, so declaring the same name in different modules causes collisions. M-prefix scoping is in a later slice.
- `open M;` only opens M's direct bindings (`open M.N;` not yet supported).

**Phase 9.5 made import paths importer-relative**: a relative path like `./foo.mere` is resolved **relative to the file containing the import statement** (not cwd). `Unix.realpath` canonicalizes paths, so different relative forms referring to the same file get cycle-guarded correctly.

```
// sub/lib.mere
let helper = fn x -> x * 7;
```

```
// main.mere (one directory above sub/)
import "./sub/lib.mere";       // relative to main.mere
helper 6                       // → 42
```

## 10.6. Mutable-length Vector (`'a Vec`)

Mere's first **region-aware standard collection**. While `'a list` is a recursive immutable list, `'a Vec` is a growable vector (internally an array).

```
let nums = vec_new () in
{
  vec_push nums 10;
  vec_push nums 20;
  vec_push nums 30;
  vec_len nums              // → 3
}
```

Builtin API:

| Function | Type | Behavior |
|---|---|---|
| `vec_new` | `unit -> 'a Vec` | Make an empty Vec |
| `vec_push` | `'a Vec -> 'a -> unit` | Push to tail (in-place) |
| `vec_get` | `'a Vec -> int -> 'a` | Index access (out-of-range is eval error) |
| `vec_len` | `'a Vec -> int` | Element count |

**Placeable in a region**: if `'a` is Trivial[R] (contains no drop type), a Vec can sit in a region:

```
region R {
  let v = vec_new () in
  { vec_push v 1; vec_push v 2; &R v }   // OK
}
```

Drop-typed elements (`drop type Conn = { ... }`) break Trivial[R], so they can't be region-placed:

```
region R {
  let v = (vec_new () : Conn Vec) in &R v
}
// type error: Trivial[R] violated: cannot place value of type `Conn Vec`
//   into region — type contains a Drop type
```

**Phase 12.3 made the `Vec[R, T]` syntax meaningful with region**:

```
fn (v: Vec[R, int]) -> vec_len v    // Type: (Vec[R, int] -> int)

region R {
  let v = vec_new () in              // Type: Vec[R, int] (R auto-bound!)
  { vec_push v 1; vec_push v 2; vec_len v }
}

vec_new ()                           // Type: Vec[__heap, 'a] (default region)
```

Calling `vec_new ()` automatically returns a `Vec[R, T]`-typed (region-tagged) value if there's a surrounding `region R { ... }`; otherwise it carries the default region marker `__heap`. Trying to escape a region is statically rejected:

```
region R { vec_new () }
// type error: region escape: value of type `Vec[R, 'a]` cannot leave region `R`
```

The legacy `T Vec` (1-arg postfix) is writable too; it internally expands to `Vec[__heap, T]` (forward-compat).

**Phase 12.6 added polymorphic `len`** — an ad-hoc polymorphic builtin (same scheme as `show`) supporting multiple collection types under a single name:

```
len "hello world"                              // 11 (str)
let v = vec_new () in
  { vec_push v 1; vec_push v 2; len v }        // 2 (Vec[R, T])
let w = owned_vec_new () in
  { owned_vec_push w "x"; len w }              // 1 (OwnedVec[T])
len (1, 2, 3, 4)                               // 4 (tuple)
len (Cons (1, Cons (2, Cons (3, Nil))))        // 3 ('a list)
```

Type: `'a -> int`; runtime dispatch looks at the value's variant and returns the appropriate length. A minimal "one name working across many types" alternative to a trait system.

**Phase 12.5 added `OwnedVec[T]`** — in contrast to `Vec[R, T]` (Trivial in-region), `OwnedVec[T]` is heap-allocated and Drop-typed. Trying to place it in a region is statically rejected:

```
let lasting = owned_vec_new () in   // Type: int OwnedVec
{
  owned_vec_push lasting 100;
  owned_vec_len lasting              // → 1
}

region R {
  let v = owned_vec_new () in &R v
  // type error: Trivial[R] violated: cannot place value of type
  // `'a OwnedVec` into region — type contains a Drop type
}
```

"Short-lived / region scope" and "long-lived / heap" are written separately with the same Vector concept. See [`examples/vec_vs_owned_vec.mere`](../examples/vec_vs_owned_vec.mere) for a runnable comparison demo. The internal implementation is the same mutable array — only the type system distinguishes them.

**Phase 12.10 added `Map[R, K, V]`** — region-aware mutable map (associative array). Same construction-time binding pattern as Vec[R, T] / StrBuf[R]:

```
let counts = map_new () in
{
  map_set counts "apple" 3;
  map_set counts "banana" 5;
  map_get counts "apple"        // → 3
  + (if map_has counts "absent" then map_get counts "absent" else 0)
}

region R {
  let acc = map_new () in       // Map[R, str, int]
  map_set acc "k" 42;
  len acc                       // → 1 (polymorphic len works too)
}
```

| API | Type |
|---|---|
| `map_new` | `unit -> Map[R, K, V]` |
| `map_set` | `Map[R, K, V] -> K -> V -> unit` |
| `map_get` | `Map[R, K, V] -> K -> V` (absent key is eval error) |
| `map_has` | `Map[R, K, V] -> K -> bool` |
| `map_len` | `Map[R, K, V] -> int` |

Internally an OCaml Hashtbl (polymorphic hash/eq), so the recommended keys are primitives (int / str / bool / tuple-of-primitives). Closure / ref-containing keys are identified by reference identity (caveat). See [`examples/map_basics.mere`](../examples/map_basics.mere) for a real example.

**Phase 12.9 added Vec higher-order API** — `vec_iter` / `vec_map` / `vec_fold` / `vec_set`. `vec_map`'s result Vec is placed in the same region as the source (region-preserving):

```
let xs = vec_new () in
{
  vec_push xs 1; vec_push xs 2; vec_push xs 3;
  let squared = vec_map xs (fn x -> x * x) in    // Vec[R, int]
  let sum = vec_fold xs 0 (fn acc -> fn x -> acc + x) in  // 6
  vec_set xs 1 99;                                // in-place mutation
  vec_iter xs (fn x -> print (show x))            // side effect
}
```

| API | Type |
|---|---|
| `vec_iter` | `Vec[R, T] -> (T -> unit) -> unit` |
| `vec_map` | `Vec[R, T] -> (T -> U) -> Vec[R, U]` |
| `vec_fold` | `Vec[R, T] -> U -> (U -> T -> U) -> U` |
| `vec_set` | `Vec[R, T] -> int -> T -> unit` |
| `vec_filter` (Phase 12.11) | `Vec[R, T] -> (T -> bool) -> Vec[R, T]` (region-preserving) |
| `vec_to_list` (Phase 12.11) | `Vec[R, T] -> T list` (elements as `'a list` Nil/Cons chain) |
| `vec_to_owned` (Phase 12.11) | `Vec[R, T] -> T OwnedVec` (in-region → heap deep copy) |
| `owned_vec_to_vec` (Phase 12.12) | `T OwnedVec -> Vec[R, T]` (heap → in-region deep copy; R binds to the active region) |

See [`examples/vec_higher_order.mere`](../examples/vec_higher_order.mere) for a real example.

**Closure-arg type-annotation idiom** — when the closure arg of `vec_map` / `vec_iter` / `vec_fold` is **a record, use `(t: T) -> ...` explicit annotation**. HM doesn't reverse-engineer the closure-arg type from field accesses, so without an annotation, `t.done`-style field references produce a type error:

```
type Task = { id: int, text: str, done: bool };

vec_fold tasks 0 (fn acc -> fn (t: Task) ->         // ← explicit (t: Task)
  if t.done then acc else acc + 1)
```

The same applies to "functions that take a record cap (Logger / Metrics / custom caps)":

```
let dump_tasks = fn (lg: Logger) -> fn tasks ->     // ← explicit (lg: Logger)
  vec_iter tasks (fn (t: Task) ->
    lg.info (show t.id ++ ": " ++ t.text))
```

See [`examples/todo_app.mere`](../examples/todo_app.mere) for concrete usage (a small TODO app combining OwnedVec + Logger + vec_map / fold).

**Phase 12.7 added `StrBuf[R]`** — an in-region mutable string buffer. Works on the same construction-time binding pattern as `Vec[R, T]`:

```
region R {
  let buf = strbuf_new () in    // Type: StrBuf[R]
  {
    strbuf_push buf "Hello";
    strbuf_push buf ", ";
    strbuf_push buf "world!";
    strbuf_to_str buf            // → "Hello, world!" (extracted as str)
  }
}

strbuf_new ()                    // Type: StrBuf[__heap] (default region)
```

API: `strbuf_new`, `strbuf_push`, `strbuf_to_str`, `strbuf_len`. The polymorphic `len` also works on StrBuf. See [`examples/strbuf_basics.mere`](../examples/strbuf_basics.mere) for a real example.

**Phase 15 added 3-backend codegen support** — Vec / OwnedVec / StrBuf / Map + all higher-order API + conversions + len ad-hoc polymorphism + with-OwnedVec scope-Drop all work in C / LLVM IR / Wasm. Examples like `vec_codegen_c.mere` / `owned_vec_codegen.mere` / `strbuf_codegen.mere` / `map_codegen.mere` / `vec_higher_order_codegen.mere` can be run through codegen via `-c` / `-ll` / `-w` flags:

```sh
# Vec[R, int] to C codegen to native binary
mere -c examples/vec_codegen_c.mere | clang -x c - -o vec && ./vec   # → 95

# Map[R, str, int] to LLVM IR codegen
mere -ll examples/map_codegen.mere | clang -x ir - -o map && ./map   # → 640

# Wasm codegen (requires wabt / Node.js)
mere -w examples/vec_codegen_wasm_typed.mere > v.wat
wat2wasm v.wat -o v.wasm
node -e 'WebAssembly.instantiate(require("fs").readFileSync("v.wasm"),
  { env: { puts: () => 0 } }).then(r => console.log(r.instance.exports.main()))'
# → 252
```

Remaining work (see DEFERRED §1.2 / §1.3):

- **First-class value use of builtins** (`let f = vec_new in ...`) is not yet codegen-supported — interpreter only. Workaround: write a wrapper like `fn v -> vec_push v x`.
- **Auto scope-bound Drop for OwnedVec** is not supported — explicit `with v = owned_vec_new () in body` frees at scope end; without it, bulk-freed at main exit.
- **The borrow checker doesn't track Vec internals at element granularity** — the mode at the point of borrowing the Vec is machine-checked; details like borrowing a `vec_get` result come later.
- **Payload-mixed variants as Map K on LLVM / Wasm** are restricted to uniform-payload (MVP); C allows mixed.

For the full Q-010 design see the internal design notes.

Runnable example: [`examples/vec_basics.mere`](../examples/vec_basics.mere).

## 10.7. Phase 36 syntactic sugar

Phase 36 added 13 kinds of syntactic sugar, substantially improving ergonomics in the ML-family tradition. All work in all **4 backends (interpreter + C + LLVM + Wasm)**.

### Ranges and collections

```mere
0..5                  // [0, 1, 2, 3, 4]
1..10                 // [1, 2, ..., 9]

1 :: 2 :: 3 :: []     // cons operator (= Cons (1, Cons (2, ...)))

// list comprehension (multi-generator + filter)
[x * 2 | x <- 1..5, x % 2 == 0]            // [4, 8]
[(r, c) | r <- 0..3, c <- 0..3, r != c]    // 9 pairs

// for / while loops (for side effects)
for x in 1..5 do print (show x);
while !done do step ();
```

### Operator section / lambda

```mere
(+ 1)                 // = fn x -> x + 1
(* 2)                 // = fn x -> x * 2
list_map xs (+ 1)     // = list_map xs (fn x -> x + 1)

\x -> x + 1           // = fn x -> x + 1
\(a, b) -> a + b      // tuple destructure OK
```

### Pipe variants

```mere
5 |> (+ 1)            // forward (existing)
(+ 1) <| 5            // reverse: f <| x = f x
print @@ show 42      // low-precedence apply: print (show 42)
```

### String interpolation

```mere
let n = 42 in
print "answer = {show n}, double = {show (n * 2)}";
// → "answer = 42, double = 84"

"escape: \{not interpolated\}"   // \{ for literal brace
```

### Early return (`?` / `?!`)

`?` for Option chains; `?!` for Result chains. On failure, immediately exit the enclosing fn as None / Err:

```mere
let safe_div = fn a -> fn b ->
  if b == 0 then None else Some (a / b);

let compute = fn x -> fn y -> fn z ->
  let a = safe_div x y ? in     // bind if Some _; return None if None
  let b = safe_div a z ? in
  Some (a + b);

// Result version
let parse_and_eval = fn s ->
  let toks = tokenize s in
  let v = parse_expr toks ?! in  // bind if Ok _; return Err if Err
  Ok v;
```

### `if let`

```mere
if let Some n = map_get m "key" then
  print "found {show n}"
else
  print "missing";
```

### All-in-one example

```mere
let stats = fn xs ->
  let positives = [x | x <- xs, x > 0] in
  let sum = list_sum positives in
  let max = if list_len positives == 0 then 0 else list_max positives in
  "sum = {show sum}, max = {show max}";
```

Dogfood examples: [`examples/sugar_showcase.mere`](../examples/sugar_showcase.mere), [`examples/calc.mere`](../examples/calc.mere) (138-line arithmetic parser, `?!` chain), [`examples/maze_solver.mere`](../examples/maze_solver.mere) (BFS), [`examples/comprehension.mere`](../examples/comprehension.mere).

### Phase 36 prelude (16 entries added)

`range` / `list_filter` / `list_take` / `list_drop` / `list_find` / `list_append` / `list_concat` / `list_flat_map` / `list_zip` / `list_for_all` / `list_any` / `list_member` / `list_sum` / `list_product` / `list_max` / `list_min` (34 entries total). See the Phase 36 section at the top of [stdlib-reference.md](stdlib-reference.md).

## 11. Block expressions (side-effect sequencing)

```
{
  print "step 1";
  print "step 2";
  42
}
```

Sugar for `let _ = ...; ...; final expression`.

## 11.5. Using the REPL

Start an interactive session with `mere -r`. Multi-line input, code-frame-styled type errors, and env-management commands are all available.

```
$ mere -r
mere REPL. Type :help for commands, :quit to exit.

> let rec fact = fn n ->
..>   if n < 1 then 1
..>   else n * fact (n - 1);
val fact : (int -> int)

> :show fact
val fact : (int -> int)
  = <closure:n>

> fact 10
- : int = 3628800
```

Main commands:

| Command | Use |
|---|---|
| `:type EXPR` | Print only the inferred type (no eval) |
| `:env` | List current user bindings |
| `:show NAME` | Show NAME's type + value |
| `:load FILE` | Load FILE's decls into the REPL env |
| `:reset` | Clear all user bindings |
| `:quit` / `:q` | Exit |

During multi-line input, a blank line or a line starting with `:` discards the buffer with `(input aborted)`. For a detailed session example see [examples/repl_session.md](../examples/repl_session.md).

## 12. Reading runnable examples

From `examples/`:
- **`factorial.mere`** — simple recursion
- **`fibonacci.mere`** — same
- **`fizzbuzz.mere`** — operators and branches
- **`options.mere`** — sum types + match
- **`list_literal.mere`** — list sugar + recursion
- **`records.mere`** — records + patterns
- **`signature.mere`** — signature alias
- **`mutual_rec.mere`** — `let rec ... and ...`
- **`pipe.mere`** — `|>` `<<` `>>` chains
- **`word_count.mere`** — `wc`-style script using file I/O + str_count
- **`json_parser.mere`** — fully working JSON parser in 140 lines (atoms + array + object + nesting + escapes + errors, with char dispatch)
- **`csv_parser.mere`** — fully working CSV parser in 110 lines (RFC 4180 subset; quoted fields + `""` escape + empty fields + file round-trip)
- **`mini_calc.mere`** — 160-line expression evaluator (arithmetic + parens + unary minus + let bindings + variables + env-based eval, with shadowing)
- **`list_lib.mere`** — list utilities implemented in Mere itself (map/filter/fold_left/fold_right/length/rev/take/drop/range/replicate/for_all/any) — a showcase of the "no builtin needed" philosophy
- **`module_basic.mere`** — mini example of `module M { ... }` + qualified reference `M.f`
- **`lib_list_ops.mere`** + **`import_demo.mere`** — a decls-only library and a consumer using `import "path";`
- **`repl_session.md`** — a doc that walks through REPL usage as an interactive session
- **`borrow_modes.mere`** — combining the 4 borrow annotations (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`)
- **`borrow_modes_typeerror.mere`** — how borrow-mode mismatches get caught as type errors (intentionally-failing demo)
- **`borrow_conflict.mere`** — the borrow checker (Phase 11.4) rejecting conflicting borrows of the same variable (intentionally-failing demo)
- **`vec_basics.mere`** — basic `'a Vec` operations + region placement (Phase 12.1)
- **`vec_vs_owned_vec.mere`** — `Vec[R, T]` (region) vs `OwnedVec[T]` (heap, Drop) comparison demo (Phase 12.5)
- **`strbuf_basics.mere`** — basic `StrBuf[R]` operations + region placement (Phase 12.7)
- **`vec_higher_order.mere`** — higher-order Vec API demo: `vec_iter` / `vec_map` / `vec_fold` / `vec_set` (Phase 12.9)
- **`map_basics.mere`** — basic `Map[R, K, V]` operations + region placement (Phase 12.10)
- **`module_nested.mere`** — nested module (`M.N.f`) + `open M;` demo (Phase 9.3)

To try them interactively in the REPL:
```sh
mere -r
```

## 12.5. Calling C functions (FFI, Phase 32)

Mere can **directly call libc / libm / OS functions** via the `extern fn` syntax. One line — `extern fn time: ...;` — and you can call it in all 4 backends.

```mere
extern fn getpid:  unit -> int;
extern fn setenv:  str -> str -> int -> int;   // multi-arg curried
extern fn getenv:  str -> str;

let _ = setenv "MERE_VAR" "hello" 1 in
print (getenv "MERE_VAR")                       // → "hello"
```

How each backend implements it:
- **Interpreter**: `eval.ml`'s `lookup_extern` has OCaml-mirror implementations (via the Unix module). Hardcoded mocks so all 4 backends remain at parity.
- **C codegen**: `extern <ret> <name>(<args>);` declaration + direct call; clang auto-links from libc.
- **LLVM codegen**: `declare <ret> @<name>(<args>)` + LLVM call instruction.
- **Wasm codegen**: `(import "env" <name> ...)` env host import; `scripts/run_wasm.js` (Node.js host harness) injects the JS implementation.

MVP type scope: combinations (arrow chain) of `int` / `bool` / `str` / `unit`. `float` / `tuple` / `record` / `variant` / callbacks are deferred to later phases.

```mere
extern fn getppid: unit -> int;
let pid  = getpid () in
let ppid = getppid () in
print (show pid ++ " " ++ show ppid)             // → "<pid> <ppid>"
```

For details and design decisions see the internal design notes.

## 13. Native compilation (C / LLVM / Wasm — together with interp, 4-backend feature parity)

Mere programs can be emitted in three codegen backends, and combined with the interpreter, **all 4 backends (interp + C + LLVM + Wasm) work at feature parity**. Phases 24-27 brought 12 examples to PERFECT match; Phase 28 added 4 more; **16 realistic examples (~2500 LoC; toy_sql.mere alone is 1165 LoC) reached diff = 0 across all 4 backends** (2026-06-21 to 22).

| Flag | Backend | Output |
|---|---|---|
| `-c` / `-ce` | C source | Use `clang` to produce a native binary |
| `-ll` / `-lle` | LLVM IR | Use `clang` (or `llc` + `clang`) to produce a native binary |
| `-w` / `-we` | Wasm (WAT) | `wat2wasm` produces `.wasm`; run via `scripts/run_wasm.js` (Node.js) |

Producing C from a `*.mere` file:

```sh
mere -ce 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10' > fact.c
clang fact.c -o fact
./fact   # → 3628800
```

The supported range is broad — most major syntax can be natively compiled:

```sh
# closures + higher-order functions
mere -ce 'let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10' > a.c
clang a.c -o a && ./a   # → 15

# polymorphic variants + recursion + pattern match
mere -ce "type 'a list = Nil | Cons of 'a * 'a list;
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t
  in sum [1, 2, 3]" > sum.c
clang sum.c -o sum && ./sum   # → 6

# Polymorphic show + list display
mere -ce "type 'a list = Nil | Cons of 'a * 'a list;
  print (show [1, 2, 3])" > sh.c
clang sh.c -o sh && ./sh   # → [1, 2, 3]
```

Swap the flag for LLVM / Wasm:

```sh
# LLVM IR → native
mere -ll examples/factorial.mere | llc - -o fact.s && clang fact.s -o fact

# Wasm (WAT)
mere -w examples/factorial.mere > fact.wat
wat2wasm fact.wat -o fact.wasm    # wabt required separately
```

For details see [codegen.md](codegen.md).

Interpreter mode (`mere file.mere`) and codegen output match for the same program (including formatting like `[1, 2, 3]`). At **4-backend feature parity**, int / functions / strings / tuples / records / variants / closures / polymorphism / recursive variants / complex patterns / show / region / view / `with` Drop / list pretty-printing / Q-010 collections (Vec / OwnedVec / StrBuf / Map) + higher-order API + conversions + len + with-Drop / signature spread / Result helpers / try_or / inner-fn lifting / top-level value-binding globalization / str_compare / FFI (extern fn) all work (reached incrementally through Phases 15-32).

The **feature-parity gap** between interpreter and the 3 codegen backends is now nearly zero; remaining items:
- **First-class value use of builtins** (`let f = vec_new in ...`) is interpreter-only (DEFERRED §1.2; future).
- **Auto scope-bound Drop for OwnedVec** isn't supported (explicit `with` or main-exit bulk free only; DEFERRED §1.3; B1 NLL/Linear types is at the paper-trial stage).
- `float` / `'a list`-typed builtins (`read_lines` / `args` / `env_var` / `file_exists` etc.) are **interpreter-only** (codegen comes in a separate phase).
- LLVM / Wasm accept only **uniform payload for Map K with payload variants** (C allows mixed).

## 14. Formatting source (`mere fmt`)

The built-in pretty-printer normalizes style — 2-space indent, operator-precedence-driven paren insertion, `else if` chains flattened, `Cons` / `Nil` chains reconstructed into list literals, `range a b` rendered as `a..b`.

```sh
mere fmt foo.mere                 # write formatted source to stdout
mere fmt -i src/*.mere            # rewrite in place (one or more files)
mere fmt --check src/*.mere       # exit 1 if any file would change (CI / pre-commit)
```

`--check` prints the path of each file that would be reformatted but doesn't touch anything — convenient for a git pre-commit hook:

```sh
#!/bin/sh
files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.mere$')
[ -z "$files" ] || mere fmt --check $files
```

Known MVP limitations:
- **Comments are not preserved** (the lexer discards them).
- **`module M { ... }` blocks** are flattened to `M.foo` bindings.
- A handful of Phase 36 sugars (operator sections, string interpolation) are emitted in their desugared form. Common ones (`a..b`, list literals, `\x y -> ...` lambda shorthand) are reconstructed.

## Next steps

- Full feature reference: [language-reference.md](language-reference.md)
- Builtin list: [stdlib-reference.md](stdlib-reference.md)
- Common idioms: [patterns.md](patterns.md)
- C codegen details and remaining work: [codegen.md](codegen.md)
