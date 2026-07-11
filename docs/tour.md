# Tour of Mere

A fast, example-driven tour of the language — one scroll through every core
feature. Each snippet is a complete program (the last expression is the
program's result / what gets printed). For depth, see the
[language reference](language-reference.html) and the
[tutorial](tutorial.html).

Run any snippet three ways:

```sh
mere prog.mere                              # interpret
mere -c prog.mere > p.c && clang -O2 p.c -o p && ./p   # native binary
mere -w prog.mere > p.wat && wat2wasm --enable-tail-call p.wat -o p.wasm \
  && node scripts/run_wasm.js p.wasm        # WebAssembly
```

## Values and functions

Functions are curried; annotations are optional (Hindley–Milner infers types).

```mere
let add = fn (a: int) -> fn (b: int) -> a + b;
let inc = add 1;              // partial application
print (show (inc 41))          // 42
```

`let x = e in body` binds locally; a top-level `let x = e;` binds for the
rest of the file. The file's trailing expression is the program's result.

## Recursion, including mutual

```mere
let rec fib = fn (n: int) -> if n < 2 then n else fib (n - 1) + fib (n - 2);

let rec is_even = fn (n: int) -> if n == 0 then true else is_odd (n - 1)
and is_odd = fn (n: int) -> if n == 0 then false else is_even (n - 1);

print (show (fib 10) ++ " " ++ show (is_even 10))    // 55 true
```

## Algebraic data types and pattern matching

```mere
type 'a tree = Leaf | Node of 'a tree * int * 'a tree;

let rec sum = fn (t: int tree) ->
  match t with
  | Leaf -> 0
  | Node (l, v, r) -> sum l + v + sum r
  ;

print (show (sum (Node (Node (Leaf, 1, Leaf), 2, Leaf))))   // 3
```

## Records

Record types are capitalized; construct with `Name { … }`, read with `e.field`.

```mere
type Point = { x: int, y: int };
let p = Point { x = 3, y = 4 };
print (show (p.x * p.x + p.y * p.y))    // 25
```

## Lists: literals, comprehensions, patterns

`[a, b, c]` desugars to `Cons`/`Nil`; `[]` is `Nil`. List comprehensions and
list patterns (`[h, ...t]`) are built in.

```mere
let xs = [1, 2, 3, 4, 5];
let evens = [x * x | x <- xs, x % 2 == 0];   // [4, 16]

let rec total = fn (ys: int list) ->
  match ys with
  | []        -> 0
  | [h, ...t] -> h + total t
  ;

print (show evens ++ " sum=" ++ show (total xs))   // [4, 16] sum=15
```

## Tuples

```mere
let (q, r) = (17 / 5, 17 % 5);
print (show (q, r))    // (3, 2)
```

## Strings

`++` concatenates; `<` `<=` `>` `>=` compare lexicographically; `{expr}`
interpolates (write a literal brace as `\{`).

```mere
let name = "Mere";
let n = 42;
print "hello {name}, n={show n}";            // hello Mere, n=42
print (show ("apple" < "banana"))            // true
```

## show, to_json, and structural equality — derived, no boilerplate

`show` and `to_json` work on *any* value structurally (records, variants,
lists…), and `==` compares by value. No trait declarations or hand-written
serializers.

```mere
type Post = { id: int, title: str, published: bool };
let a = Post { id = 1, title = "hi", published = true };
let b = Post { id = 1, title = "hi", published = true };
print (to_json a);            // {"id":1,"title":"hi","published":true}
print (show (a == b))          // true
```

## Modules and imports

```mere
// contrib/option/option.mere provides `module Option { … }`
import "contrib/option/option.mere";
match Option.or_else None (Some 7) with
| Some v -> print (show v)      // 7
| None   -> print "none"
```

## Effects as capabilities

Mere has no hidden effect syntax: a side effect is a **capability value**
passed as an argument. `Logger` / `Metrics` are builtin capability types.

```mere
// A Logger is `{ info: str -> unit, warn: …, error: … }`; call log.info.
let greet = fn (log: Logger) -> fn (who: str) -> log.info ("hi " ++ who);
greet (mk_logger "app") "world"    // logs: app [INFO] hi world
```

## Where to go next

- [Language reference](language-reference.html) — full syntax and semantics
- [Tutorial](tutorial.html) — build something step by step
- Real apps written in Mere: a
  [REST API](tutorial-rest-api.html), a [Redis client](tutorial-redis-client.html),
  and a [type inferencer](tutorial-type-inference.html)
- [Memory model](memory-model.html), [packages](packages.html),
  [stdlib](stdlib-reference.html)
