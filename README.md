# Mere

[![CI](https://github.com/merelang/mere/actions/workflows/ci.yml/badge.svg)](https://github.com/merelang/mere/actions/workflows/ci.yml)
[![Pages](https://github.com/merelang/mere/actions/workflows/pages.yml/badge.svg)](https://github.com/merelang/mere/actions/workflows/pages.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Docs / playground:** [merelang.github.io/mere](https://merelang.github.io/mere/) — tutorial, language reference, and a Wasm playground with an interactive [counter demo](https://merelang.github.io/mere/playground/counter.html) wired through the Phase 48 frontend FFI.

> *Make Explicit Region-bound Effects.*

OCaml implementation of **Mere**, a new programming language (Old English for "lake"; 4 letters; region metaphor). An ML-family mini language that has reached a practical level — its memory model (region / view / Trivial[R]), effect system (capability passing + refined borrow annotations), and three codegen backends (C / LLVM IR / Wasm) all work at feature parity.

Former tentative name: `lang-ml` (finalized as Mere on 2026-06-19).

## Status (as of 2026-07-02)

- **1778 tests passing**
- **🎉 Self-host bootstrap** (Phase 54, 2026-06-30 → 2026-07-01): the Mere source of the compiler compiles itself. Five major runtime components — `lexer`, `parser`, `evaluator`, `type inferencer`, `formatter` — are written in Mere, compiled through the self-host `parse_and_emit_file` pipeline to WAT, and confirmed running correctly under wasm at runtime (10 CI-verified bootstrap tests exercising parse / eval / infer / format on real inputs). The self-host codegen (`codegen_wasm.mere`) also compiles itself at compile-time (1.56 MB WAT, wat2wasm-verified). **All 18 contrib libraries** self-host-compilable: `ast` / `lexer` / `parser` / `typer` / `eval` / `fmt` / `json` / `path` / `option` / `regex` / `regex.engine` / `argparse` / `test` / `toml` / `markdown/to_html` / `markdown/to_text` / `markdown/toc` / `time`. 13 of the 18 have CI compile-time verification via `bootstrap_wat_ok` (wat2wasm-checks the emitted module).
- **🌐 Web backend Stage A** (Phase 54.35, 2026-07-02): `contrib/http/` adds Node-hosted HTTP server bindings via five extern fns (`http_serve` + `http_current_body` + `http_set_status` + `http_set_content_type` + `http_set_header`), sibling of `contrib/dom` for the server side. Real HTTP JSON REST APIs are now expressible in Mere — see `examples/http_todo_api.mere` (in-memory CRUD with routing, status codes, JSON, and top-level mutable `Map` state) and `examples/http_json_api.mere` (six endpoints incl. CORS).
- **4-backend feature parity**: interp + C / LLVM IR / Wasm runtime — all match interp **diff = 0 PERFECT** across 16 realistic examples (~1500 LoC) (Phase 24-27); subsequent phases grew the example set to 136.
- Memory model: region / view / Trivial[R] / `with` Drop work at the type level, in the interpreter, and in all three codegen backends.
- Effect system: capability-passing pattern + `signature ... = (...)` argument bundling + `using [cap]` sugar + builtin Logger / Metrics.
- Refined borrow annotations: 4 modes `&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T` + borrow checker (place expressions + if/match branch propagation + full conflict matrix coverage).
- Q-010 standard collections: `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` work in **interpreter + all 3 backends** (Phase 15.x).
- Polymorphism: HM inference + let-poly + **per-instantiation specialization of polymorphic user let-recs** (Phase 23.3 / 25.5 / 26.4) + Phase 36's narrow value restriction (don't generalize when let-binding a type that contains a mutable container).
- Inner-fn lifting: `let rec inner = fn ... -> ...` is lifted to top level with free variables prepended (Phase 25.3 / 26.3).
- Top-level value bindings: non-fn lets like `let total = mk_metrics();` are accessible from fn bodies (Phase 30.2 globalizes them across all 3 backends).
- Wasm runtime: validated at runtime via `scripts/run_wasm.js` (Node.js host harness — puts / read_file / write_file) (Phase 27.2).
- FFI: `extern fn <name>: <ty>;` calls libc functions directly from all 4 backends (Phase 32; supports curried multi-arg; MVP types are int/bool/str/unit only).
- Language surface: `module M { ... }` (nestable) + `M.f` qualified access; `import "./path";` (importer-relative + canonical) for file splitting; `open M;`.
- **Phase 36 syntactic sugar (13 kinds)**: range `a..b`, operator section `(+ 1)`, cons `1 :: xs`, reverse pipe `f <| x`, apply `f @@ x`, lambda shorthand `\x -> ...`, string interpolation `"x = {show n}"`, `?` (Option) / `?!` (Result) early-return, list comprehension `[f x | x <- xs, p x]`, `if let pat = e then ... else ...`, `for x in xs do body`, `while cond do body`.
- **Phase 36 prelude expansion (16 entries)**: `range` / `list_filter` / `list_take` / `list_drop` / `list_find` / `list_append` / `list_concat` / `list_flat_map` / `list_zip` / `list_for_all` / `list_any` / `list_member` / `list_sum` / `list_product` / `list_max` / `list_min` (34 entries total).
- REPL: multi-line input, `:env` / `:show` / `:load` / `:reset`, Rust-style code frame error display.
- Design context is kept in separate internal design notes.

## Feature highlights

| Category | Details |
|---|---|
| Type system | Hindley-Milner inference, let-polymorphism, polymorphic builtins |
| Primitives | `int`, `float` (IEEE 754), `bool`, `str`, `unit` |
| Data | tuple, record, sum types, list literal sugar `[1, 2, 3]` (also pretty-printed by `show`) |
| Control | `if-then-else`, `if-then` (unit), `match` + `when` guards + as-patterns + or-patterns |
| Patterns | wildcard / var / lit / char `'X'` / tuple / constructor / list `[h, ...t]` / record / as / or |
| Functions | multi-arg typed fn / mutually recursive `let rec ... and ...` / higher-order / closures |
| Operators | `+ - * / % == != < <= > >= && \|\| ++ \|> << >>` (int arithmetic); float uses `f_add` etc. |
| Name management | `let _ = ...;`, `let (a, b) = ...;`, `signature`, `type X = T` (alias) |
| Memory model | region (`region R { ... }`) / view (`view V[R] of T { ... }`) / `&R T` reference / escape check / Trivial[R] constraint / `R.alloc(v)` sugar |
| Borrow annotations | `&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T` + borrow checker (place + if/match propagation) |
| Effects | capability passing (cap = record value), `signature` argument bundling + spread, `using [cap]` sugar, builtin Logger / Metrics |
| with Drop | `with c = ... in body` auto-invokes the `close` field at scope end; multiple bindings close LIFO |
| Error handling | `Result` type + `result_map` / `result_and_then` / `result_or_else` (prelude); `fail "msg"` / `try_or default fn` for catchable failures |
| Modules | `module M { ... }` (nestable), `M.f` references, internal short-name rewrite, `open M;`, type/record decls allowed inside modules |
| import | `import "./path";` pulls in another file (importer-relative + canonical) |
| Collections | `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` + higher-order API (iter/map/fold/filter/to_list/to_owned) — **insertion-order Map iter** (Phase 27.1) |
| stdlib | 90+ builtins: I/O / conversion / strings (`str_split` / `str_join` / `str_compare` / `str_index_of` etc.) / numerics / polymorphic helpers / float / errors / Logger / Metrics |
| codegen | C / LLVM IR / Wasm (WAT) backends at parity + Wasm runtime validation (details in [codegen.md](docs/codegen.md)). Q-010 collections (4 kinds) + higher-order API + conversions + `len` ad-hoc poly + per-instantiation specialization of polymorphic user let-rec (Phase 23.3 / 25.5 / 26.4) + inner-fn lifting (Phase 25.3 / 26.3) + top-level value bindings globalized to file scope (Phase 30.2). |
| FFI | `extern fn <name>: <ty>;` calls libc functions from all 4 backends (interp + C / LLVM / Wasm). Curried multi-arg; types int / bool / str / unit (Phase 32). |
| REPL | persistent env, multi-line input, `:type` `:env` `:show NAME` `:load FILE` `:reset` `:help` |
| Error UX | Rust-style multi-line code frame, ANSI colors (TTY only), Levenshtein-based typo suggestions (including record fields and qualified names), type-conversion hints |

## Quick examples

```sh
$ dune exec ./bin/mere.exe -- -e '5 |> (fn x -> x + 1) |> show'
"6"

$ dune exec ./bin/mere.exe -- -e 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10'
3628800

$ dune exec ./bin/mere.exe -- -e 'type opt = None | Some of int; match Some 42 with | None -> 0 | Some n -> n + 1'
43

$ dune exec ./bin/mere.exe -- examples/module_basic.mere
# Calls Math.inc / Math.square / Math.pow from `module Math { ... }`

$ dune exec ./bin/mere.exe -- examples/import_demo.mere
# import "examples/lib_list_ops.mere"; computes ListOps.sum [1..5]

$ dune exec ./bin/mere.exe -- contrib/json/json.mere
# Runs the self-test of the JSON parser in Mere (140 lines; promoted to contrib/ in Phase 40)

$ dune exec ./bin/mere.exe -- examples/pipeline.mere
# A realistic example combining region / view / effects / `with`

$ dune exec ./bin/mere.exe -- examples/toy_sql.mere
# 1165-line toy SQL engine (tokenizer + parser + executor + JOIN);
# 59 tests pass with diff = 0 across all 4 backends (interp + C + LLVM + Wasm)

$ dune exec ./bin/mere.exe -- examples/calc.mere
# Phase 36: recursive-descent arithmetic parser + `?!` Result chain.
# `1 + 2 * 3` → 7; `(1 + 2) * 3` → 9; `10 / 0` → ERR division

$ dune exec ./bin/mere.exe -- examples/maze_solver.mere
# Phase 36: BFS pathfinding through an ASCII 8x12 maze + path visualization
```

### Self-host bootstrap (Phase 54)

The compiler compiles itself — Mere source is tokenized, parsed, and lowered to WAT by Mere code that itself runs under wasm.

```sh
# Self-emit: codegen_wasm.mere compiling itself
$ dune exec ./bin/mere.exe -e '
  import "contrib/codegen/codegen_wasm.mere";
  str_len (parse_and_emit_file "contrib/codegen/codegen_wasm.mere")'
1560495                            # 1.56 MB WAT output — wat2wasm accepts

# Runtime self-host: compile a tiny Mere program via the wasm-compiled
# lexer, then confirm it ran under wasm (see test/test_basic.ml
# "self-host bootstrap: lexer bootstrap tokenize count").
#
# tokenize "let x = 1 in x"      -> 7   tokens
# parse_decls ... "let x = 1;"   -> 1   decl
# parse_and_eval "let x = 5 in x + 1"          -> 6
# parse_and_eval "let rec fact ... in fact 5"  -> 120
# parse_and_infer "let x = 5 in x + 1"         -> "int"
# format_program (parse "1 + 2 * 3")           -> "1 + 2 * 3\n"
```

## Documentation

- **[Tutorial](docs/tutorial.md)** — start here (includes `module` / `import` / REPL)
- **[Language reference](docs/language-reference.md)** — syntax and semantics
- **[Stdlib reference](docs/stdlib-reference.md)** — builtin tables
- **[Patterns / cookbook](docs/patterns.md)** — common idioms
- **[Memory model](docs/memory-model.md)** — memory management options, region/view, current and future
- **[Codegen](docs/codegen.md)** — three-backend (C / LLVM IR / Wasm) strategy + per-slice table
- **[HTTP demos](docs/http-demos.md)** — twelve `examples/http_*.mere` servers, catalog + patterns
- **[Database](docs/db.md)** — pure-Mere Postgres client + pool + LISTEN/NOTIFY, 16 demos
- **[Packages](docs/packages.md)** — `.mere_modules/` package resolution (v0.1)
- **[Changelog](docs/changelog.md)** — milestones from project start (2026-06-06) onward
- **[Runbook](RUNBOOK.md)** — operational procedures (site deploy, merelang.org DNS/cert, Cloudflare Workers). Not published to the docs site.
- `examples/` — runnable `.mere` files ([examples/README.md](examples/README.md) has a categorized index). From basics (FizzBuzz / word count) and Q-010 collection codegen demos (`vec_codegen_*.mere` / `owned_vec_codegen.mere` / `strbuf_codegen.mere` / `map_codegen.mere`), to realistic applications (PERFECT diff = 0 on all 4 backends): `template_engine` / `word_freq` / `mini_shell` / `chained_parse` / `state_machine` / `ini_parser` / `regex_lite`; **a 1165-line `toy_sql`** (Phase 29 dogfood; 59 tests; 4-backend PERFECT); and the 47 sugar-dogfood examples added in Phase 36: `calc` / `maze_solver` (BFS) / `game_of_life` / `sudoku_check` / `tic_tac_toe` / `eight_queens` / `knapsack` / `roman_numerals` / `morse_code` / `luhn_check` / `caesar_cipher` / `csv_summary` / `comprehension` / `if_let_demo` / `for_loop_demo` / `while_loop_demo` / `sugar_showcase` and more.
- `contrib/` — **library candidates** ([contrib/README.md](contrib/README.md)). One step more "reuse-oriented" than `examples/`. Grew significantly with the Phase 49-54 self-host effort: `parser/` (lexer + AST + parser), `codegen/codegen_wasm.mere` (2800-line self-host WAT emitter), `eval/eval.mere`, `typer/typer.mere`, `fmt/fmt.mere`, plus `json/` / `path/` / `option/` / `regex/` / `argparse/` / `test/` / `toml/` / `markdown/` (HTML / text / TOC) / `time/` / `dom/` / `site/` (playground pages). These will graduate to separate repos once a package manager is in place.

## Build / run

```sh
dune build
dune exec ./bin/mere.exe -- examples/factorial.mere
dune exec ./bin/mere.exe -- -e '1 + 2 * 3'
dune exec ./bin/mere.exe -- -te 'fn x -> x + 1'      # print the type
dune exec ./bin/mere.exe -- -r                       # REPL
dune runtest                                         # 1778 tests

# C codegen
dune exec ./bin/mere.exe -- -ce 'let x = 5 in x * 2' > out.c
clang out.c -o out && ./out                          # → 10

# LLVM IR codegen
dune exec ./bin/mere.exe -- -lle '1 + 2 * 3' | llc - -o sum.s
clang sum.s -o sum && ./sum                          # → 7

# Wasm codegen (requires wabt / Node.js)
dune exec ./bin/mere.exe -- -we '1 + 2 * 3' > sum.wat
wat2wasm sum.wat -o sum.wasm
node scripts/run_wasm.js sum.wasm                    # → 7 (via the host harness)
```

All three backends (C / LLVM / Wasm) match at feature parity — ints, functions, strings, tuples, records, variants, closures, polymorphism, recursive variants, complex patterns, `show`, region, view, `with` Drop, list pretty-printing, the four Q-010 collections (Vec / OwnedVec / StrBuf / Map), polymorphic user let-recs, inner-fn lifting, top-level value bindings globalized, and `str_compare`'s sign-normalized output (parity reached incrementally through Phases 15.x → 31.0; 16 realistic examples retain diff = 0 PERFECT).

## Formatting (`mere fmt`)

A built-in pretty-printer normalizes source style — 2-space indent, operator-precedence-driven paren insertion, `else if` chain flattening, list / range / lambda-shorthand sugar reconstruction.

```sh
dune exec mere -- fmt examples/factorial.mere       # write formatted to stdout
dune exec mere -- fmt -i src/foo.mere src/bar.mere  # rewrite in place
dune exec mere -- fmt --check src/*.mere            # exit 1 if any file differs
```

`--check` lists files that would change and is suitable for CI / pre-commit:

```sh
# .git/hooks/pre-commit (example)
#!/bin/sh
files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.mere$')
[ -z "$files" ] || dune exec mere -- fmt --check $files
```

Known MVP limitations: comments are dropped (the lexer discards them), `module M { ... }` blocks are emitted as flat `M.foo` bindings, and a few Phase 36 sugars (operator sections, string interpolation) are emitted in their desugared form.

## Layout

```
mere/
├── bin/mere.ml         # CLI entry point
├── lib/                # Core (library: mere)
│   ├── loc.ml / ast.ml / lexer.ml / parser.ml
│   ├── typer.ml        # HM inference + sum types + records + let-poly + borrow checker
│   ├── eval.ml         # tree-walking interpreter
│   ├── codegen_c.ml    # C codegen
│   ├── codegen_llvm.ml # LLVM IR codegen
│   ├── codegen_wasm.ml # Wasm (WAT) codegen
│   ├── pipeline.ml     # process / type_of (?base_dir for importer-relative)
│   ├── repl.ml         # interactive REPL (multi-line / :env / :show / :load / :reset)
│   ├── formatter.ml    # `mere fmt` pretty-printer
│   ├── diagnostic.ml   # Rust-style code frame + ANSI colors
│   └── version.ml
├── test/test_basic.ml  # 1778 tests
├── scripts/run_wasm.js # Wasm runtime host harness (Node.js: puts / read_file / write_file)
├── examples/           # *.mere sample programs
└── docs/               # tutorial / language-reference / stdlib-reference / patterns / memory-model / codegen / changelog
```

## Name

**Mere** = Old English for "lake". The region metaphor (a body of water bounded from its surroundings), the minimal ML-family ring, and a modest "just a ..." nuance. The former tentative name `lang-ml` was finalized to Mere on 2026-06-19, at the milestone when the design core (effect / type / memory) all worked.

## License

**MIT License** (see [LICENSE](LICENSE)).

For contributions see [CONTRIBUTING.md](CONTRIBUTING.md) (contains language that leaves room for future MIT OR Apache-2.0 dual licensing).
