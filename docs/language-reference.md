# Language reference (mere)

The syntax and semantics of Mere as currently implemented (as of 2026-06-24 / Phase 46). `&T` references / `region` / `view` / effects / FFI / 4-backend codegen are all implemented. Phase 36 added 13 kinds of syntactic sugar (range / op section / `::` / `<|` / `@@` / `\` lambda / string interp / `?` / `?!` / list comp / `if let` / `for-in-do` / `while-do`), substantially improving ergonomics in the ML-family tradition.

---

## 1. Lexical

### Comments
```
// Line comment (to end of line)
```

### Literals
| Kind | Example |
|---|---|
| Integer | `0`, `42`, `-5` (syntactically `Neg (Int_lit 5)`) |
| Float | `1.5`, `3.14`, `0.0` (digits.digits; bare `1.` is not a float) |
| Boolean | `true`, `false` |
| String | `"hello"`; escapes are `\n` `\t` `\\` `\"` |
| Char (length-1 str) | `'X'`; escapes are `'\n'` `'\t'` `'\\'` `'\''` `'\"'` |
| Unit | `()` |

A char literal `'X'` is just a length-1 str (Mere has no separate char type). Convenient for dispatch like `match c with | 'n' -> ...`. To avoid ambiguity with the type variable syntax (`'a opt` etc.), the lexer distinguishes `'X'` (closing quote present) from `'NAME` (no closing quote; alphabetic start).

### Identifiers
- Start with a lowercase letter or `_`; continue with alphanumerics / `_`.
- Uppercase-leading is recognized by the parser as "constructor / record / type name".
- Type variables: `'a`, `'b`, etc. (`'` + lowercase-leading ident).

### Keywords
```
let rec and in if then else true false fn type signature
match with when of as _ for do while
module open import extern using region view drop
```

### Operators and symbols
```
+ - * / %                arithmetic
== != < <= > >=          comparisons
&& ||                    logic (short-circuit)
++                       string concatenation
|> << >>                 pipe / function composition
<|                       reverse pipe (Phase 36): f <| x = f x
@@                       low-precedence apply (Phase 36): f @@ x = f x
::                       cons operator (Phase 36): h :: t = Cons (h, t)
..                       range literal (Phase 36): a..b = [a, ..., b-1]
?                        Option early return (Phase 36)
?!                       Result early return (Phase 36)
<-                       list comprehension generator (Phase 36)
\                        lambda shorthand (Phase 36): \x -> e
->                       function type / match-arm separator
=                        binding
: ; , .                  annotation / terminator / separator / field
( ) { } [ ]              grouping
...                      signature spread / list tail
|                        match separator / variant separator / record update / list comp
```

### String interpolation (Phase 36)

Inside string literals, `{expr}` is interpolation: the lexer tokenizes recursively, and the parser expands `"a {x} b"` into something like `"a " ++ show_or_str x ++ " b"` (actually a `++` chain depending on `expr`'s type). `\{` escapes a literal brace; nested string literals inside the interpolation are forbidden (work around by binding via `let` first).
```
let n = 42 in print "answer = {show n}"        // "answer = 42"
print "escape: \{not interpolated\}"            // "escape: {not interpolated}"
```

---

## 2. Types

### Primitives
```
int   float   bool   str   unit
```

`float` is IEEE 754 double. Literals with a decimal point and digits (e.g. `1.5`) are float; `1` is int (bare `1.` is not float but `1` + a potential `.field`). `int` and `float` are distinct types with no implicit coercion — use `float_of_int` / `int_of_float` explicitly; arithmetic uses `f_add` / `f_sub` / `f_mul` / `f_div`.

### Composite types
```
t1 -> t2         function type (right-assoc: a -> b -> c == a -> (b -> c))
t1 * t2 * ...    tuple type
t list           type constructor (postfix application)
(t1, t2) result  multi type-arg
'a               type parameter (in declaration / annotation)
&R t             region-tagged reference type (Phase 1: syntax only; semantic checks come later)
```

---

## 3. Expressions

### Literals / identifiers
```
42   true   "hi"   ()
x    (variable reference)
```

### Arithmetic / comparison / logic
```
1 + 2 * 3                7         (* / has higher precedence)
10 / 3                   3         (integer division; 0 div is Eval_error)
10 % 3                   1         (mod; 0 div is Eval_error)
"a" ++ "b"               "ab"      (string concat)
5 <= 5                   true
1 != 2                   true
true && false            false     (short-circuit: don't eval RHS if LHS is false)
false || true            true
not true                 false     (builtin)
```

### Phase 36 syntactic sugar at a glance

All desugar at the parser or lexer level, so the AST and beyond are unaffected. Per-form precedence is in §6.
```
0..5                     // range: [0, 1, 2, 3, 4] (parser directly generates this; effectively list_iota)
1 :: 2 :: []             // cons: Cons (1, Cons (2, Nil))
(+ 1)                    // op section: fn x -> x + 1
(* 2)                    // (- 1) is ambiguous with unary -, so parenthesize
(< 10)                   // comparison sections also work
\x -> x + 1              // lambda shorthand: = fn x -> x + 1
\(a, b) -> a + b         // tuple destructure OK
f <| x                   // reverse pipe: = f x
f @@ x                   // low-precedence apply: = f x; readable across line breaks
"x = {show n}"           // string interpolation (lexer level; see §1)

[expr | x <- xs, p x]                       // list comprehension (single gen + filter)
[expr | x <- xs, y <- ys, p x y]            // multi-generator (cartesian)
                                            // desugar: list_map / list_flat_map

if let pat = e then yes_branch else no_branch
  // = match e with | pat -> yes_branch | _ -> no_branch
  // (else is required; both branches share the same type)

for x in xs do body                         // = list_iter xs (\x -> body)
                                            // body must be unit-typed
while cond do body                          // = let rec __while_N = fn () ->
                                            //     if cond then (body; __while_N ()) else () in
                                            //   __while_N ()
                                            // Note: currently only runs inside an fn body (top-level is codegen-unsupported)
```

### Option / Result early-return (`?` / `?!`, Phase 36)

`let pat = e? in body` form:
- `e?` (Option): if `e` is `Some v`, bind `v` to `pat` and evaluate `body`; if `None`, the enclosing fn immediately returns `None`.
- `e?!` (Result): if `e` is `Ok v`, bind; if `Err e`, the enclosing fn immediately returns `Err e`.

Both desugar to Match in the parser:
```
let v = parse_int s ? in body
  ≈ match parse_int s with | Some v -> body | None -> None
```

### let bindings
```
let x = 5 in x + 1                 // ident
let _ = side_effect in 1           // wildcard
let (a, b) = (3, 4) in a + b       // tuple destructure
let (a, (b, c)) = (1, (2, 3)) in a + b + c
```

### let rec / mutual recursion
```
let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5

let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
and is_odd     = fn n -> if n == 0 then false else is_even (n - 1)
in is_even 10
```

### if-then-else / if-then
```
if cond then a else b               // standard if; a and b share the same type
if cond then print "msg"            // side-effect-only; body must be unit-typed
```

### with (scope-bound resources with Drop, Phase 3.1)

`with c = v in body` is for **resources with Drop** (DB connections / file handles / mutexes etc.). The bound value's type must be a `drop type ...`-declared Drop type (use `let` for Trivial values). At scope end, the value's `close: unit -> unit` field is invoked (no-op if absent). Multiple bindings close in **LIFO order**.
```
drop type Conn = { id: int, close: unit -> unit };
let mk_conn = fn id ->
  Conn { id = id, close = fn () -> print ("close " ++ show id) };

with c = mk_conn 1 in c.id
// Result: 1. At scope end, "close 1" is printed.

with c1 = mk_conn 1, c2 = mk_conn 2 in c1.id + c2.id
// Result: 3. Prints "close 2" → "close 1" (LIFO).

with x = 5 in x + 1    // ERROR: int isn't a Drop type. Use `let`.
```

Design notes: implements option (i) from the internal design notes — "region is strict-Trivial; Drop is managed via `with`".

### region (Phase 2: syntax + value expression `&R v` + escape check)

See [memory-model.md](memory-model.md) for the memory-management concepts, comparisons, and Mere's overall strategy.
```
region R { body }                   // bring R into scope as a region name; evaluate body
region R { region S { ... } }       // nesting OK

fn (x: &R int) -> x                  // `&R T` reference type (R is a region name)
&R 5                                 // value expression: tag 5 as `&R int`
let x: &R int = &R 5 in ...          // combined with explicit annotation
```

**Current semantics (Phase 2)**:
- `region R { body }` binds R into the inner scope and evaluates body. R itself is a unit-value placeholder.
- `&R T` is the region-tagged reference type as expressed in the type system.
- `&R v` is a value expression that wraps v at `&R T` (interpreter passes the value through).
- **Escape check active**: if R appears in the body's type of `region R { body }`, it's a compile-time error — `&R T` values can't leak out of the region.
- Future (Phase 3+): the `r.alloc(v)` method form (sugar for `&R v`), the `Trivial[R]` constraint, `with` + Drop integration, child regions and promotion, etc.

**Escape check examples**:
```
region R { 42 }                      // OK: int doesn't contain R
region R { let x = &R 5 in 42 }      // OK: `&R int` used inside, but result is int
region R { &R 5 }                    // ERROR: result is `&R int`; R leaks out
region R { (&R 1, 2) }               // ERROR: `&R int` inside a tuple
```

**`R.alloc(v)` sugar (Phase 2.5)**: inside a region, `R.alloc(expr)` is syntactic sugar for `&R expr`. The desugaring only happens when R is a lexically enclosing region name (ordinary `obj.alloc(...)` field accesses keep working).
```
region R {
  let x = R.alloc(5) in              // == let x = &R 5 in ...
  let p = R.alloc((1, 2)) in
  42
}
```

**`Trivial[R]` constraint (Phase 2.6)**: only types **without Drop semantics** (Trivial) can be placed in a region. Drop types are declared with `drop type Name = ...`; including such a type in a region (`&R v` / `R.alloc(v)` / view fields) is a type error. This is "a constraint that allows bulk region freeing"; caps that need Drop (DB connections / file handles etc.) are separately managed by a future `with` expression.
```
drop type Conn = { id: int };

let c = Conn { id = 1 } in c.id      // OK: Drop types are usable outside a region

region R {
  &R Conn { id = 1 }                  // ERROR: Trivial[R] violated
}

view Holder[R] { c: Conn };
region S { Holder { c = ... } }       // ERROR: view field has a Drop type

region R {
  &R (fn (c: Conn) -> c.id)           // OK: function types are Trivial (closure values)
}
```

**`Trivial[R]` is implicitly the default**: ordinary types (`int` / `str` / record / tuple / variant / `Vec[R, T]` / `&R T` / closure etc.) are **automatically `Trivial[R]`**. Users do **not** need to declare `impl Trivial[R] for X { }` (a future trait system may revisit this; see the internal design notes §3). The sole exception is types declared with `drop type` — they break Trivial[R] at every position they structurally appear (`contains_drop_type` walker in `lib/typer.ml`). So the judgment scheme is the simple "default-Trivial + drop-blacklist". Full trait-system rollout (DEFERRED §3.1) and explicit `impl Trivial[R]` syntax (§6.1) are linked in the design but don't affect the current implementation.

### view (Phase 2.4: declaration + region enforcement + type-tag propagation)

```
view V[R] of T { f1: T1, f2: T2, ... };   // view type over region R (with explicit inner type T)
view V[R] { f1: T1, ... };                // `of T` is optional
```

`view V[R] of T { ... }` is a **data declaration with a region parameter**. In Phase 2.4:

- View construction is only allowed inside a `region { ... }` block (writing `V { ... }` outside is a type error).
- At construction, the view's region parameter `R` is substituted with the innermost active region's name, and the view value's type becomes `V[<region>]`.
- Field access `v.f1` and record update `{ v | f1 = e1 }` work like records; `&R T` fields are retrieved with the type substituted to the construction-time region.
- The view value itself is subject to escape checking — cannot leave the construction region.

```
view Node[R] of int { value: int, next: int };
region R { let n = Node { value = 1, next = 0 } in n.value }       // 1
region MyArena { let n = Node { value = 7, next = 0 } in n.value } // 7 (R → MyArena)
let n = Node { value = 1, next = 0 } in ...                        // ERROR: must be inside a region block

view Slot[R] { item: &R int };
region S { 
  let s = Slot { item = &S 42 } in     // s : Slot[S]
  let take_s = fn (x: &S int) -> 99 in
  take_s s.item                         // s.item : &S int → 99
}

region S { Slot { item = &T 42 } }     // ERROR (region mismatch)
region S { Cell { v = 1 } }            // ERROR: Cell[S] cannot leave region S
```

**Planned tightening for later phases**:
- Cyclic construction within the same region (two-phase: mutable construction + immutable use).
- Q-009's "structural identity by region" axiom (identifying same-typed views inside a region).

See [memory-model.md](memory-model.md) and the internal design notes.

### Functions + `using [cap]` syntactic sugar

`using [cap1, cap2, ...]` is a sugar that eases the repeated partial-application patterns of cap-passing style. Caps are expanded as the outermost curried args.
```
fn x using [logger] -> body
// ≡ fn logger -> fn x -> body
```

Callers can immediately get a `T -> U` with the cap embedded via `f cap`, ready to pass to higher-order functions like `map`:
```
let log_x = fn x using [logger] -> logger (show x);
let bound = log_x my_logger;    // bound : int -> unit
iter bound [1, 2, 3];
```

- Type annotations OK: `fn x using [c: int -> int] -> c x`
- Multiple caps: `fn x using [logger: Logger, metrics: Metrics] -> ...`
- Combined with normal params: `fn (x: int) using [c: Logger] -> c.info (show x)`
- Empty `using []` is a parse error.

### Functions
```
fn x -> x + 1                       // single arg (type-inferred)
fn (x: int) -> x + 1                // single arg (annotated)
fn (x: int, y: int) -> x + y        // multi-arg (desugared to currying)
fn (a, b, c) -> a + b * c           // multi-arg, no annotations
fn () -> 42                         // no args (internally _u : unit)
```

### Application / partial application
```
inc 5
add 3 4                             // = (add 3) 4
let inc1 = (+) 1 in ...             // turning operators into functions is not yet supported (use a curried fn)
```

### Tuples / records / lists
```
(1, 2, 3)                           // tuple

type Point = { x: int, y: int };
let p = Point { x = 3, y = 4 } in p.x + p.y           // record
let p2 = { p | x = 100 } in p2.x                       // record update

type 'a list = Nil | Cons of 'a * 'a list;
[1, 2, 3]                           // list literal sugar = Cons (1, Cons (2, Cons (3, Nil)))
[1, 2, 3,]                          // trailing comma allowed (also in tuple / record literals)
[]                                  // = Nil
```

### Sum types / constructors / match
```
type 'a opt = None | Some of 'a;

match Some 42 with
| None -> 0
| Some n when n > 10 -> 1000
| Some n -> n + 1

match xs with
| []          -> "empty"
| [h, ...t]   -> "head + rest"
| [a, b, c]   -> "exactly three"

match x with
| (a, b) as p when a < b -> p         // as-pattern: bind whole to p
| _                      -> (0, 0)

match day with
| 1 | 2 | 3 | 4 | 5 -> "weekday"     // or-pattern
| 6 | 7             -> "weekend"
| _                 -> "invalid"
```

### Block / side-effect sequencing
```
{ }                                 // → unit
{ e1; e2; e3 }                      // → eN; e1..e_(N-1) are discarded (sugar for let _ = ... in chains)
```

### Function composition / pipe
```
5 |> inc |> dbl                     // = dbl (inc 5); left-assoc; lowest precedence
inc << dbl                          // = fn x -> inc (dbl x); right-assoc
inc >> dbl                          // = fn x -> dbl (inc x); right-assoc
```

### Type annotation
```
(42 : int)                          // expressive; must agree with the existing type
((fn x -> x + 1) : int -> int) 5    // function-typed annotation
```

### Signature alias (function-argument bundling)
```
signature ctx = (db: int, log: int);

let save = fn (...ctx, order: int) -> db + log + order in
save 100 10 5                       // 115
```

---

## 4. Patterns

| Kind | Syntax | Example |
|---|---|---|
| Wildcard | `_` | `_` |
| Variable | `name` | `n`, `xs` |
| Integer | `N` | `0`, `42` |
| Boolean | `true` / `false` | |
| String | `"..."` | `"foo"` |
| Unit | `()` | |
| Tuple | `(p1, p2, ...)` | `(a, b)`, `(a, (b, c))` |
| Constructor | `Name` or `Name sub_pat` | `None`, `Some x`, `Cons (h, t)` |
| List | `[]` / `[a, b, c]` / `[h, ...t]` / `[..._]` | |
| Record | `Name { f1 = p1, f2 = p2 }` | `Point { x = 0, y = py }`; partial OK |
| as | `pat as name` | `Cons (h, t) as whole` |
| or | `p1 | p2` | `1 | 2 | 3`; both branches bind the same names + types |

### Guards (in match)
```
match x with
| n when n > 0 -> "positive"
| _            -> "non-positive"
```

---

## 5. Top-level declarations

### let / let rec
```
let x = 5;                          // ident form
let (a, b) = (3, 4);                // pattern form
let _ = print "init";               // wildcard is fine

let rec fact = fn n -> ... ;
let rec is_even = ... and is_odd = ... ;
```

### Type declarations

```
// 1. Sum type (variant)
type 'a opt = None | Some of 'a;
type ('a, 'b) result = Ok of 'a | Err of 'b;

// 2. Record
type Point = { x: int, y: int };
type 'a Box = { value: 'a };

// 3. Type alias
type UserId = int;
type Pair = int * int;
type 'a Stack = 'a list;
```

Disambiguation:
- `=` followed by `{` → record.
- Leading `|`, or uppercase ident followed by `|` / `of` → variant.
- Otherwise → alias.

### signature

```
signature ctx = (db: int, log: int);
// Expanded by `fn (...ctx, x: int) -> ...` (parse-time)
```

---

## 6. Operator precedence (low → high)

| Precedence | Operators | Associativity |
|---|---|---|
| 1 (low) | `let`, `if`, `fn`, `match`, `with`, `for`, `while` | - |
| 2 | `@@` (low-precedence apply, Phase 36) | right |
| 3 | `|>` / `<|` (Phase 36) | left / right |
| 4 | `<<`, `>>` | right |
| 5 | `||` | left |
| 6 | `&&` | left |
| 7 | `==`, `!=`, `<`, `<=`, `>`, `>=` | non-associative |
| 8 | `::` (cons, Phase 36) | right |
| 9 | `..` (range, Phase 36) | non-associative |
| 10 | `+`, `-`, `++` | left |
| 11 | `*`, `/`, `%` | left |
| 12 | unary `-` | - |
| 13 | `?` / `?!` (postfix, Phase 36) | postfix |
| 14 | function application | left |
| 15 (high) | atom / `(...)` / `[...]` / `{...}` / `.field` / op section `(+ N)` / `\x -> e` / `"...{expr}..."` | - |

`expr : type` (annotation) is applied once at the outermost level.

---

## 7. Evaluation model

- **Strict (call-by-value)**; `&&` and `||` are short-circuit.
- **No mutation**; rebinding is not allowed; `with` also creates a new binding.
- **Closure capture** is by value-reference (the environment is closed in the closure).
- **Errors**: type errors are compile-time; `fail`/`assert`/`div by zero`/unmatched match etc. are runtime `Eval_error`.

### Copy semantics (implicitly default)

Mere has **no explicit "copyable" marker** like Rust's `Copy` trait. Instead, the following implicit rules:

- **Value types (int / float / bool / str / unit / list / tuple / variant / record / closure)**: free to rebind under the same or different names with `let x = v in ...`, pass repeatedly as arguments ("Copy" treatment). Implementation-wise this is **structural sharing + GC-less region alloc** of immutable values.
- **Region-bound reference types (`&R T` / `Vec[R, T]` / `Map[R, K, V]` / `StrBuf[R]`)**: freely duplicable during the region's lifetime (internally a pointer + bulk-freed with the region).
- **Drop types declared with `drop type ...` (`Conn` / `File` etc.)**: can't be placed in a region (Trivial[R] violation); managed scope-bound by `with`. Outside a region, **let rebind is permitted** (no Linear enforcement; close runs automatically at scope end).
- **`OwnedVec[T]`**: linear-ish. Phase 38.G-1 Level 1 added auto-Drop (`free` at lexical scope end). `let v2 = v1`-style aliasing is syntactically possible but problematic (double Drop), so users are encouraged to use idioms like `vec_to_owned` for explicit conversion.

So Mere's Copy/Linear distinction is realized via three layers — **Drop types / OwnedVec / everything else** — without explicit Copy/Linear trait annotations. Design room remains to introduce `T: Copy` / `T: Linear` type bounds later (linked to the trait system §3.1), but with no dogfood signal, it's confirmed-deferred (same §6.4).

---

## 8. Known constraints (2026-06-24)

Items previously listed as "not implemented" were implemented incrementally through Phases 14-36; the following remain:

- **Exhaustiveness check is Phase 1** (bool + variants only): non-exhaustive → **warning** to stderr; evaluation proceeds (case omissions become runtime fallthrough errors).
- **For int / str / float / tuple / record**, a wildcard arm is required (precise checks come later).
- **String escapes** are only `\n \t \\ \"` plus Phase 36's `\{` (interp brace escape). No Unicode escape (`\uXXXX`).
- **Integers are fixed-width**; no arbitrary precision. Per backend (v0.1.41): the **C backend uses 64-bit int** (`long long`; before v0.1.41 it was C `int`, which silently truncated values above 2^31 — found by a SHA-256 probe whose round constants didn't survive), the **interpreter uses OCaml's int** (host-dependent, normally 63 bits), and **LLVM and Wasm use i32** — an int literal outside `-2^31 .. 2^31-1` is a compile-time error on those backends rather than a silent truncation or a downstream wat2wasm failure. (An earlier revision of this note claimed LLVM was i64; measuring said otherwise. Widening the LLVM backend to i64 is a known deferred item with the SHA-256 example as its forcing program.) At the C FFI boundary (`extern fn`) int is deliberately C `int`, matching the libc/POSIX ABI.
- **Float**: IEEE 754 double. **The arithmetic and comparison operators are numeric-overloaded** — `+ - * /`, `< <= > >= == !=`, and unary `-` all work on floats (v0.1.44 corrected this entry: it long claimed prefix-only `f_add` style, which the Mandelbrot example disproved — the infix forms had worked on interp/C/Wasm for a while; the same probe found and fixed LLVM emitting invalid IR for them). The overload picks float only when an operand is *concretely* float, so unannotated fn params default to int — annotate (`fn (x: float) -> ...`) in float-heavy code. `%` stays int-only; the `f_add` family remains available as ordinary functions.
- **No nested string literals in interpolation**: `"x = {show \"abc\"}"` is a lexer error (work around via let).
- **`while` only inside fn bodies**: writing `while` directly under top-level main is codegen-unsupported (top-level Let_rec constraint).
- **REPL `:type EXPR` is value-expressions only**: type display of top-level decls is available via `:show NAME`.
- **FFI types are MVP**: `int / bool / str / unit` only (float / tuple / record / variant / callback deferred, Phase 32).
- **Polymorphism**: HM inference + let-polymorphism + per-instantiation specialization of polymorphic user let-recs (Phase 23.3 / 25.5 / 26.4). Phase 36 introduced a **narrow value restriction** (don't generalize on let-bind when the type contains a mutable container).

## 9. Status summary

- **1573 tests passing** (test/test_basic.ml).
- **4-backend feature parity**: interpreter + C / LLVM IR / Wasm runtime.
- 16 realistic examples (~1500 LoC + toy_sql 1165 LoC) match **diff = 0 PERFECT**.
- See [Changelog](changelog.md) / [Codegen](codegen.md) for details.

---

For detailed behavior, see `examples/` and `test/test_basic.ml`.
