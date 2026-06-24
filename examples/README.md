# Mere examples

A collection of runnable `.mere` programs for Mere (142 total: 47 in
Phase 36 + 5 in Phase 37/38 + 5 algorithms + 14 extended algorithms added
later). Run with `dune exec ./bin/mere.exe -- examples/<file>.mere`
to execute via the interpreter, or use the `-c` / `-ll` / `-w` flags to
codegen to one of the C / LLVM IR / Wasm backends.

**Phase 27 (2026-06-21) completed 4-backend feature parity**. 16 examples
have PERFECT diff = 0 across **interp + C + LLVM + Wasm runtime** (marked
with ⭐).

## Categories

### Introduction / language basics

| File | Content |
|---|---|
| [hello.mere](hello.mere) | "Hello, world!" |
| [factorial.mere](factorial.mere) | factorial (recursive fn) |
| [fibonacci.mere](fibonacci.mere) | Fibonacci |
| [fizzbuzz.mere](fizzbuzz.mere) | FizzBuzz |
| [mini_calc.mere](mini_calc.mere) ⭐ | small calculator program |
| [mutual_rec.mere](mutual_rec.mere) | mutual recursion via `let rec f = ... and g = ...` |
| [higher_order.mere](higher_order.mere) | higher-order functions |
| [pipe.mere](pipe.mere) | `|>` pipe operator |
| [typed.mere](typed.mere) | type annotation examples |
| [let_pattern.mere](let_pattern.mere) | `let (a, b) = ...` pattern |
| [top_decls.mere](top_decls.mere) | top-level let / let-rec usage |

### Data types

| File | Content |
|---|---|
| [records.mere](records.mere) | record (mono / polymorphic) |
| [options.mere](options.mere) | `'a opt` / Option pattern |
| [list.mere](list.mere) | monomorphic `intlist`, explicit Cons / Nil |
| [list_lib.mere](list_lib.mere) | list manipulation library |
| [list_literal.mere](list_literal.mere) | `[1, 2, 3]` sugar |
| [poly_list.mere](poly_list.mere) | polymorphic `'a list` |
| [tree.mere](tree.mere) | binary tree (recursive variant) |
| [state_machine.mere](state_machine.mere) ⭐ | variant + match transition (traffic light + pedestrian button), Phase 28.0 C1 |

### Memory model (region / Drop / borrow)

| File | Content |
|---|---|
| [borrow_modes.mere](borrow_modes.mere) | realistic demo of the 4 borrow annotation modes (Logger / DbHandle / Config) |
| [borrow_modes_typeerror.mere](borrow_modes_typeerror.mere) | intentional type error on borrow mode mismatch |
| [borrow_conflict.mere](borrow_conflict.mere) | intentional borrow checker conflict demo |

### Effects

| File | Content |
|---|---|
| [effects.mere](effects.mere) | capability-passing pattern |
| [signature.mere](signature.mere) | cap bundle via signature alias |
| [with_caps.mere](with_caps.mere) | Drop cap with `with c = ... in body` |
| [cap_handler.mere](cap_handler.mere) ⭐ | multiple handlers share-write the same Logger / Metrics via `&shared write` |

### Modules / import

| File | Content |
|---|---|
| [module_basic.mere](module_basic.mere) | `module M { ... }` + `M.f` reference |
| [module_nested.mere](module_nested.mere) | nested module + `open M;` |
| [module_scoping.mere](module_scoping.mere) | disambiguate same-name ctors across 2 modules via qualified form (Phase 18) |
| [import_demo.mere](import_demo.mere) | `import "./lib_list_ops.mere";` (needs `lib_list_ops.mere`) |
| [lib_list_ops.mere](lib_list_ops.mere) | a library for import |

### Practical programs (16 examples PERFECT-aligned on 4 backends ⭐)

| File | Content |
|---|---|
| [arith_eval.mere](arith_eval.mere) ⭐ | evaluate a mini functional lang (arithmetic + if + 1st-class fn + closure) from AST |
| ~~`json_parser.mere`~~ | **Promoted in Phase 40 to [contrib/json/json.mere](../contrib/json/json.mere)** (moved under `contrib/` as a reusable lib) |
| [s_expression.mere](s_expression.mere) ⭐ | S-expression (Lisp-style) parser + printer + simple eval (`+ - * / = <`, `if`, `let`) |
| ~~`csv_parser.mere`~~ | **Promoted in Phase 41 to [contrib/csv/parser.mere](../contrib/csv/parser.mere)** (wrapped in module Csv) |
| [word_count.mere](word_count.mere) ⭐ | word count |
| [template_engine.mere](template_engine.mere) ⭐ | mustache-like `{{KEY}}` substitution engine (Map + StrBuf + str_index_of) |
| ~~`json_writer.mere`~~ | **Promoted in Phase 40 to [contrib/json/writer.mere](../contrib/json/writer.mere)** |
| [inventory.mere](inventory.mere) ⭐ | inventory management (Map + Vec + variant) |
| [word_freq.mere](word_freq.mere) ⭐ | word frequency counter (Map + str_split + map_iter), insertion order |
| [mini_shell.mere](mini_shell.mere) ⭐ | a simple shell batch evaluator (variant command + state) |
| [pipeline.mere](pipeline.mere) | realistic processing combining region / view / cap / with (mainly interp; runs on 3 backends) |
| [todo_app.mere](todo_app.mere) | TODO list management (OwnedVec + Logger + vec_map / fold), 4 backends |
| [safe_div.mere](safe_div.mere) | pattern for returning failure as a value using `(int, str) result` |
| **Phase 28 (2026-06-21) additions** | |
| [chained_parse.mere](chained_parse.mere) ⭐ | Result chain idiom (result_and_then / result_map / result_or_else), D2 |
| [ini_parser.mere](ini_parser.mere) ⭐ | INI parser, dogfooding Phase 27.1 Map insertion order, I1 |
| ~~`regex_lite.mere`~~ | **Promoted in Phase 42 to [contrib/regex/regex.mere](../contrib/regex/regex.mere)** (wrapped in module Regex) |
| **Phase 29 (2026-06-22) additions — large-scale dogfood** | |
| [toy_sql.mere](toy_sql.mere) ⭐ | **1165 LoC toy SQL engine** (tokenizer + AST + parser + Catalog Map + Storage OwnedVec + INSERT / SELECT / WHERE / JOIN + 59 self-tests). N1/N2/N3 dogfood uncovered 4 codegen bugs + fixed in Phase 30 |
| **Phase 32 (2026-06-22) additions — FFI** | |
| [ffi_demo.mere](ffi_demo.mere) ⭐ | demo calling libc functions (getpid / getppid / setenv / getenv) directly from 4 backends via `extern fn <name>: <ty>;`. Supports multi-arg curried |
| **Phase 33 (2026-06-22) additions — Option / UX polish** | |
| [option_pipeline.mere](option_pipeline.mere) ⭐ | dogfood Option chain (option_map / option_and_then / option_default / option_is_some) in a 3-stage lookup pipeline. Adds `option_and_then` to the prelude. D3 |
| [prime_sieve.mere](prime_sieve.mere) ⭐ | Sieve of Eratosthenes (Vec[R, bool] + vec_set + let rec loop; extracts the 15 primes under 50). H1 |
| [rate_limiter.mere](rate_limiter.mere) ⭐ | fixed 60-second window rate limiter (2 Maps holding window_start + count). Dogfoods 2 Phase 30.2 top-level globals; diff = 0 across 4 backends. G5 |
| [stack_calc.mere](stack_calc.mere) ⭐ | RPN evaluator (tok variant + op_kind variant + `'a stk` linked-list stack). div-by-zero fallback, 8 test cases. C4 |
| ~~`markdown_toc.mere`~~ | **Promoted in Phase 40 to [contrib/markdown/toc.mere](../contrib/markdown/toc.mere)** |
| [bank_account.mere](bank_account.mere) ⭐ | a functional bank account (account variant + tx variant + state-passing replay + Vec[R, tx] ledger). G4 |
| [graph_bfs.mere](graph_bfs.mere) ⭐ | BFS on a directed graph (Map[int, int list] adjacency + Map[int, bool] visited). 3 component scenarios verified on 4 backends. H3 |
| **Phase 34 (2026-06-22) additions — float + libm** | |
| [math_demo.mere](math_demo.mere) ⭐ | dogfood float arithmetic + sqrt / sin / cos / tan / f_pow / atan2 combined. Pythagorean / trig identities / circumference, etc. diff = 0 across 4 backends |
| **Phase 35 (2026-06-22) additions — first-class builtin (DEFERRED §1.2 A1)** | |
| [factory_value.mere](factory_value.mere) ⭐ | pass nullary factory builtins (vec_new / owned_vec_new / strbuf_new / map_new) as first-class values to HOFs. Phase 35 eta-wrap enables 4-backend support (MVP requires fixing ret_ty via HOF parameter annotation) |
| **Phase 36 (2026-06-22) additions — example batch** | |
| [histogram.mere](histogram.mere) ⭐ | Map[int, int] bucket counter + mode detection. Accumulates 20 observations into 10-unit buckets, then linear-scans with map_iter to find the mode. The DEFERRED §1.13 (let-poly 'a-ification) issue uncovered in Phase 36 was **resolved by adding a narrow value restriction to the typer**, eliminating the need for `(... : int)` annotation |
| [traffic_light.mere](traffic_light.mere) ⭐ | minimal enum (`Red \| Yellow \| Green`) + `next` / `cycle` recursion. The simplest variant demo as ADT introductory material (C2) |
| [event_counter.mere](event_counter.mere) ⭐ | Map[event, int] — dogfood using variants as Map keys (a usage example of Phase 15.15/15.16 features). Tallies Login / Click / Purchase / Logout (A2) |
| [html_builder.mere](html_builder.mere) ⭐ | build nested HTML with StrBuf + tag function helpers. Fold `<ul><li>...</li></ul>` into a StrBuf inside a region (B3) |
| [fallible_lookup.mere](fallible_lookup.mere) ⭐ | chain a 2-stage Map[str, str] with `result_and_then`. Chained lookup user->email->role and the `result_default` fallback pattern (D4) |
| [config_loader.mere](config_loader.mere) ⭐ | load `key = value` text into Map[str, str]. Handles comments / blank lines / leading-trailing trim. Phase 36 added `str_trim` / `str_starts_with` to 3 backends, so the code is now natural, directly using prelude builtins (A3) |
| ~~`csv_writer.mere`~~ | **Promoted in Phase 41 to [contrib/csv/writer.mere](../contrib/csv/writer.mere)** (top-level; module-wrapping is future work) |
| ~~`markdown_to_text.mere`~~ | **Promoted in Phase 40 to [contrib/markdown/to_text.mere](../contrib/markdown/to_text.mere)** |
| [calendar_lite.mere](calendar_lite.mere) ⭐ | print a Sunday-starting month calendar as ASCII from year + month. Leap year + Zeller's congruence + StrBuf to build a 7-column grid (G3) |
| [matrix_2d.mere](matrix_2d.mere) ⭐ | represent a 2D matrix via a 1D OwnedVec[int] + `r * cols + c` indexing. Matrix add / transpose / pretty-print. Nested Vec[Vec[int]] hits region escape; avoided here (H2) |
| [borrow_chain.mere](borrow_chain.mere) | reuse the same `&shared write R Logger` borrow across a pipeline calling 3 helpers (demo of Phase 17.1 borrow tracking). **interp only** (no codegen for `&shared write R`; same as borrow_modes.mere, F3) |
| [cache_sim.mere](cache_sim.mere) ⭐ | a mock FIFO cache with capacity=3. Without `map_remove` / `owned_vec_set`, it expresses FIFO eviction by separating an `alive` Vec + `evicted` Map. The DEFERRED §1.14 (lifted closure can't capture globals — LLVM/Wasm bug) uncovered in Phase 36 was **resolved by adding load / global.get paths to both backends**, allowing the natural code (A4) |
| [simple_query.mere](simple_query.mere) ⭐ | minimal SELECT * FROM users WHERE col op value (tokenize / parse / execute, ~150 LoC). A teaching version greatly trimmed from toy_sql.mere's 1165 LoC (I3) |
| [caesar_cipher.mere](caesar_cipher.mere) ⭐ | encode/decode the classic Caesar cipher. `chr` / `ord` (new in Phase 36) + char_at + StrBuf transform one character at a time; handles ROT13 / negative shifts / large shifts |
| [fraction.mere](fraction.mere) ⭐ | rational record `Frac { n, d }` add/sub/mul/div + auto reduction (via `gcd`, new in Phase 36). Includes canonical sign normalization. Note: the function is named `divf` (to avoid clashing with C's libc `div`) |
| [roman_numerals.mere](roman_numerals.mere) ⭐ | bidirectional conversion between int and Roman numerals (1..3999). A typical greedy algorithm consuming `(int * str) list` + a character-level parser |
| [password_strength.mere](password_strength.mere) ⭐ | rate password strength 0..5 (length / digit / lower / upper). Single-character traversal via `is_digit` / `ord` / `char_at` |
| [brackets_balance.mere](brackets_balance.mere) ⭐ | bracket balance check (`()` `[]` `{}`). Represent the stack with linked-list `'a stk`; scan char-by-char with char_at + push/pop via match. Skips non-bracket characters |
| [morse_code.mere](morse_code.mere) ⭐ | encode/decode A-Z + 0-9 as Morse code. Builds round-trip dictionaries with 2 Map[str, str]. Phase 36 dogfood uncovered 2 C codegen frictions (§1.15 deep list literal, §1.16 strbuf escape inside region) |
| [luhn_check.mere](luhn_check.mere) ⭐ | Luhn checksum for credit card numbers. char_at + is_digit + ord for single-digit int conversion; skips non-digits (space / hyphen) |
| [tic_tac_toe.mere](tic_tac_toe.mere) ⭐ | 3x3 board + win detection (8 lines). Combines OwnedVec[cell] + variant + match; pretty-prints 5 scenarios. The Phase 36 C-codegen issue §1.17 uncovered via dogfood (`type result` rebind fails in List.combine) was **resolved with later-wins dedupe** |
| [palindrome.mere](palindrome.mere) ⭐ | palindrome detection. Ignores case / punctuation / whitespace via `str_rev` (Phase 36) + `to_lower` + `is_alpha` |
| [anagram.mere](anagram.mere) ⭐ | judge whether two strings are anagrams. Tally character frequencies into Map[str, int]; linear-scan both freqs with `map_iter` |
| [base_conv.mere](base_conv.mere) ⭐ | convert int to base 2/8/16 string + reverse (round-trip check). Dogfoods numeric processing with `chr` / `ord` / `str_rev` / `char_at`; supports negative prefix `-` |
| [rps_game.mere](rps_game.mere) ⭐ | rock-paper-scissors outcome judgment + best-of-5 aggregation. variant + nested match 3x3 dispatch demo |
| [scoreboard.mere](scoreboard.mere) ⭐ | Map[str, int] score aggregation -> descending ranking (selection scan). Phase 36 dogfood uncovered an initialization-order bug for Phase 30.2 top-level globals (DEFERRED §1.18) |
| [eight_queens.mere](eight_queens.mere) ⭐ | enumerate all solutions to N-Queens (N=4..8) + backtracking. `safe` function + mutually recursive `try_col` / `solve`; print the first 3 solutions. N=8 yields 92 solutions |
| [collatz.mere](collatz.mere) ⭐ | stringify a Collatz trajectory + count steps. `even` (new in Phase 36) + recursive function demo. Also searches for the n in 1..20 with the most steps |
| [bin_tree_traversal.mere](bin_tree_traversal.mere) ⭐ | pre/in/post-order traversal + height / count for a binary tree (recursive variant `btree`). `render` takes the walker fn as an HOF |
| [knapsack.mere](knapsack.mere) ⭐ | solve the 0/1 knapsack problem with memoized DP. Cache `(i, w) -> max_value` in Map[str, int]; also implements selected-item reconstruction (`reconstruct`) |
| [range_demo.mere](range_demo.mere) ⭐ | demo of the **range literal `a..b`** introduced in Phase 36. `1..10` is syntactic sugar for `range 1 10`, returning an int list. Implements factorial / sum_sq, etc., via fold |
| [sections.mere](sections.mere) ⭐ | demo of **operator sections** introduced in Phase 36. `(+ 1)` is sugar for `fn x -> x + 1`. Combined with HOFs, concise map / filter is possible. Supports 11 operators: + * / % == != < <= > >= ++ |
| [cons_pipe_demo.mere](cons_pipe_demo.mere) ⭐ | demo of **`::` cons** + **`<|` reverse pipe** introduced in Phase 36. `h :: t` is sugar for `Cons (h, t)`; `f <| x` is sugar for `f x` (the right side can be fn/let/match) |
| [sugar_demo.mere](sugar_demo.mere) ⭐ | demo of **lambda shorthand `\x -> body`** / **`@@` low-precedence app** / **string interpolation `"hello {name}"`** added in Phase 36. Use `\{` to escape a literal brace |
| [question_demo.mere](question_demo.mere) ⭐ | demo of **`?` Option early-return** + **`?!` Result early-return** introduced in Phase 36. Allows writing Option / Result chains Rust-style with `?` |
| [sugar_showcase.mere](sugar_showcase.mere) ⭐ | a showcase using **all 9 sugars** (range / op section / `::` / `<|` / `@@` / `\` / string interp / `?` / `?!`) added in Phase 36, combined. prime sieve / inventory lookup / Result chain / 1-line fold |
| [comprehension.mere](comprehension.mere) ⭐ | demo of **list comprehension** `[expr \| x <- xs, cond, y <- ys, ...]` introduced in Phase 36. Haskell-style **multi-generator** + filter in any order; can express Pythagorean triples (3 gens + filter) |
| [statistics.mere](statistics.mere) ⭐ | dogfood the Phase 36 added **prelude helpers combined** for basic statistics of an int list. count / sum / mean / min / max / variance / stddev (Newton sqrt) / median (sort) / mode (Map) / outliers (filter). Also uses `list_zip` / `list_for_all` / `list_any` / `list_member` |
| [if_let_demo.mere](if_let_demo.mere) ⭐ | demo of **`if let pat = e then ... else ...`** introduced in Phase 36. Concise conditional branching for Option / Result + variant destructure (Circle / Square / Rect) |
| [for_loop_demo.mere](for_loop_demo.mere) ⭐ | demo of **`for x in xs do body`** introduced in Phase 36. range / string list / list comprehension result / nested for / Map accumulation in a procedural style. Sugar for `list_iter xs (\x -> body)` |
| [while_loop_demo.mere](while_loop_demo.mere) ⭐ | demo of **`while cond do body`** introduced in Phase 36. Use Map[str, int] as a mutable cell to express count up / powers of 2 / Collatz step counter procedurally. **Note: codegen only supports inside fn body** (top-level main can't lift inner let-rec) |
| [csv_summary.mere](csv_summary.mere) ⭐ | dogfood combining the Phase 36 added sugar / prelude helpers in realistic use. Parse CSV-like sales records (name, area, amount) (`Row opt` to mark failure) -> filter unwrap -> aggregate -> ranking output. The DEFERRED §1.20 uncovered in Phase 36 (forward decl bug for user record inside polymorphic variant) was **resolved by integrating mono struct into unified topo-sort** |
| [game_of_life.mere](game_of_life.mere) ⭐ | Conway's Game of Life (8x12 grid). Time evolution via 8-neighbor traversal of a 1D-flattened cell state in OwnedVec[int]. Visualizes the 4-step migration of a glider pattern (5 cells); also outputs each gen's live count |
| [sudoku_check.mere](sudoku_check.mere) ⭐ | validity check of a 9x9 sudoku board. Check that 1..9 are exhaustively present for 9 rows + 9 cols + 9 (3x3 boxes). Generate box cells via `list_for_all` + `list_member` + list comprehension; verify with 3 scenarios (correct / row dup / col dup) |
| [calc.mere](calc.mere) ⭐ | operator-precedence arithmetic parser + evaluator. tokenize -> recursive descent (expr / term / factor / primary) -> eval. Handles `+ - * /` precedence, unary minus, and nested parentheses. Error propagation via `?!` Result chain. Verifies 10 cases (incl. division by zero / syntax error) |
| [maze_solver.mere](maze_solver.mere) ⭐ | BFS pathfinding on an ASCII maze (8x12). `#` = wall, `S` = start, `G` = goal. OwnedVec[str] as queue, Maps for dist + prev. Computes shortest distance and visualizes path with `*` |

### Q-010 collection basics

| File | Content |
|---|---|
| [vec_basics.mere](vec_basics.mere) | basic operations on `'a Vec` (push / get / len / inside region) |
| [vec_vs_owned_vec.mere](vec_vs_owned_vec.mere) | demo contrasting `Vec[R, T]` (short-lived) vs `OwnedVec[T]` (long-lived) |
| [vec_higher_order.mere](vec_higher_order.mere) | `vec_iter` / `vec_map` / `vec_fold` / `vec_set` |
| [strbuf_basics.mere](strbuf_basics.mere) | basics of `StrBuf[R]` |
| [map_basics.mere](map_basics.mere) | basics of `Map[R, K, V]` |

### Q-010 collection codegen (3 backends)

| File | Content |
|---|---|
| [vec_codegen_c.mere](vec_codegen_c.mere) | `Vec[R, int]` C codegen (Phase 15.1, minimal) |
| [vec_codegen_c_typed.mere](vec_codegen_c_typed.mere) | C codegen with mixed int / str / tuple / variant |
| [vec_codegen_llvm_typed.mere](vec_codegen_llvm_typed.mere) | same in LLVM IR |
| [vec_codegen_wasm_typed.mere](vec_codegen_wasm_typed.mere) | same in Wasm |
| [vec_higher_order_codegen.mere](vec_higher_order_codegen.mere) | 3-backend codegen demo for vec_set / iter / fold |
| [vec_map_filter_codegen.mere](vec_map_filter_codegen.mere) | 3-backend codegen demo for vec_map / vec_filter |
| [owned_vec_codegen.mere](owned_vec_codegen.mere) | codegen demo for OwnedVec + Vec <-> OwnedVec conversion |
| [strbuf_codegen.mere](strbuf_codegen.mere) | StrBuf codegen demo |
| [map_codegen.mere](map_codegen.mere) | Map codegen demo (str->int / int->str / inside region) |

### Phase 36 — syntactic sugar dogfood (47 files)

A set of examples combined-dogfooding 13 syntactic sugars (range / op
section / `::` / `<|` / `@@` / `\` / string interp / `?` / `?!` / list
comp / `if let` / `for in do` / `while do`) with 16 prelude entries
(list_filter / range / list_sum, etc.). All have diff = 0 across 4
backends (interp + C + LLVM + Wasm).

#### sugar showcase

| File | Content |
|---|---|
| [range_demo.mere](range_demo.mere) | `0..n` range literal |
| [sections.mere](sections.mere) | operator section `(+ 1)` |
| [cons_pipe_demo.mere](cons_pipe_demo.mere) | `::` cons / `<|` reverse pipe / `@@` apply |
| [sugar_demo.mere](sugar_demo.mere) | lambda shorthand `\x -> ...` + string interp |
| [question_demo.mere](question_demo.mere) | `?` / `?!` early-return |
| [sugar_showcase.mere](sugar_showcase.mere) | combined demo of 13 sugars |
| [comprehension.mere](comprehension.mere) | list comprehension multi-gen |
| [if_let_demo.mere](if_let_demo.mere) | `if let pat = e then ... else ...` |
| [for_loop_demo.mere](for_loop_demo.mere) | `for x in xs do body` |
| [while_loop_demo.mere](while_loop_demo.mere) | `while cond do body` |
| [statistics.mere](statistics.mere) | Phase 36 prelude (list_sum / list_max / list_min, etc.) |

#### dogfood (algorithms / data processing)

| File | Content |
|---|---|
| [calc.mere](calc.mere) | operator-precedence recursive descent parser + evaluator (`?!` Result chain, 138 lines) |
| [maze_solver.mere](maze_solver.mere) | BFS pathfinding on an ASCII 8x12 maze + path visualization |
| [game_of_life.mere](game_of_life.mere) | Conway's Game of Life (8x12 grid, glider) |
| [sudoku_check.mere](sudoku_check.mere) | validity check for a 9x9 sudoku solution (row/col/box) |
| [tic_tac_toe.mere](tic_tac_toe.mere) | tic-tac-toe (board variant + win detection) |
| [eight_queens.mere](eight_queens.mere) | 8-queens solver (backtracking) |
| [knapsack.mere](knapsack.mere) | 0-1 knapsack DP |
| [collatz.mere](collatz.mere) | Collatz sequence |
| [bin_tree_traversal.mere](bin_tree_traversal.mere) | binary tree pre/in/post-order |
| [csv_summary.mere](csv_summary.mere) | CSV aggregation (Map + reduce) |
| ~~`markdown_to_text.mere`~~ | -> [contrib/markdown/to_text.mere](../contrib/markdown/to_text.mere) |
| [matrix_2d.mere](matrix_2d.mere) | 2D matrix operations (transpose / scale) |
| [borrow_chain.mere](borrow_chain.mere) | borrow mode chain demo |
| [cache_sim.mere](cache_sim.mere) | a simple LRU cache simulator |
| [simple_query.mere](simple_query.mere) | tiny query engine |
| [config_loader.mere](config_loader.mere) | parse key=value config |
| ~~`csv_writer.mere`~~ | -> [contrib/csv/writer.mere](../contrib/csv/writer.mere) |
| [calendar_lite.mere](calendar_lite.mere) | calendar output |
| [html_builder.mere](html_builder.mere) | HTML string via tag combinator |
| [event_counter.mere](event_counter.mere) | event log frequency aggregation |
| [traffic_light.mere](traffic_light.mere) | traffic light state transitions |
| [histogram.mere](histogram.mere) | ASCII histogram of an int list |
| [fallible_lookup.mere](fallible_lookup.mere) | Option chain demo |

#### dogfood (games / string processing)

| File | Content |
|---|---|
| [caesar_cipher.mere](caesar_cipher.mere) | Caesar cipher encode/decode |
| [fraction.mere](fraction.mere) | rational + reduce (uses `divf` to avoid clashing with C libc `div`) |
| [roman_numerals.mere](roman_numerals.mere) | int <-> roman numeral conversion |
| [password_strength.mere](password_strength.mere) | password strength evaluation |
| [brackets_balance.mere](brackets_balance.mere) | bracket balance check |
| [morse_code.mere](morse_code.mere) | text -> Morse code conversion |
| [luhn_check.mere](luhn_check.mere) | credit card number Luhn validation |
| [palindrome.mere](palindrome.mere) | palindrome detection |
| [anagram.mere](anagram.mere) | anagram detection |
| [base_conv.mere](base_conv.mere) | arbitrary base conversion |
| [rps_game.mere](rps_game.mere) | rock-paper-scissors |
| [scoreboard.mere](scoreboard.mere) | scoreboard update |
| [factory_value.mere](factory_value.mere) | Phase 35 — demo of first-class factory builtin (`let mk = map_new`) |

### Phase 37/38 — partial app + auto-Drop + while top-level dogfood (5 files)

A set of examples combined-dogfooding the new features of Phase 37.A
(`while` at top-level) / Phase 37.B (exhaustiveness Phase 2) / Phase 38.C
(multi-arg curried builtin first-class) / Phase 38.G-1 (OwnedVec auto
scope-bound Drop). All have diff = 0 across 4 backends
(interp + C + LLVM + Wasm).

| File | Content |
|---|---|
| [memo_fib.mere](memo_fib.mere) | memoized Fibonacci. Phase 38.C: partial-app `let lookup = map_get cache` / `let store = map_set cache` turns 2-arg / 3-arg curried builtins into closures |
| [process_queue.mere](process_queue.mere) | queue processing. Phase 37.A: can write `let _ = while (head < tail) do ...` directly under main |
| [event_aggregator.mere](event_aggregator.mere) | Phase 38.G-1: inside a function, create `let v = owned_vec_new ()`, return only statistics, auto-Drop at scope end. Also combines with Phase 38.C partial app |
| [poly_horner.mere](poly_horner.mere) | polynomial evaluation via Horner's method. partial app + auto-Drop combo |
| [histogram_buckets.mere](histogram_buckets.mere) | sequence bucket aggregation + ASCII bar chart. Update Map via closures |

### Algorithms / data structures (5 files)

A reference set of classical algorithms / data structures implemented in
Mere — "easy to compare with other languages". All have diff = 0 across 4
backends (interp + C + LLVM + Wasm).

| File | Content |
|---|---|
| [quicksort.mere](quicksort.mere) | classic quicksort (pivot + partition via list_filter). On `'a list` |
| [mergesort.mere](mergesort.mere) | stable merge sort (split + merge). Note: top-level fn name is `msort` (avoids macOS libc `mergesort` collision) |
| [bst.mere](bst.mere) | binary search tree (variant `btree`; insert / lookup / inorder / count / depth) |
| [heap.mere](heap.mere) | array-based min-heap (Map[str, int] as a pseudo-array. sift_up / sift_down / heap_sort) |
| [dijkstra.mere](dijkstra.mere) | single-source shortest path on a weighted graph (variant edge + Maps for dist/visited) |

### Extended algorithms / interpreters / data structures (14 files)

Further coverage of iconic algorithms. Number theory / string search /
graphs / lambda calculus interpreter / pretty printer / regex / markdown
converter.

#### Number theory (2 files)

| File | Content |
|---|---|
| [gcd.mere](gcd.mere) | gcd / lcm / extended Euclidean (compute Bézout coefficients) |
| [fast_pow.mere](fast_pow.mere) | fast power (squaring, O(log n)) + modular exponentiation (the core of RSA) |

#### String search (3 files)

| File | Content |
|---|---|
| [edit_distance.mere](edit_distance.mere) | Levenshtein edit distance (classic 2D DP, Map[str, int] table) |
| [kmp.mere](kmp.mere) | Knuth-Morris-Pratt search (precompute failure function, O(N+M)) |
| [rabin_karp.mere](rabin_karp.mere) | Rabin-Karp search (rolling hash; verify with str_eq_range on hash collision) |

#### Graphs (additional) (2 files)

| File | Content |
|---|---|
| [topological_sort.mere](topological_sort.mere) | Kahn's topological sort (Map for in-degree management + queue) |
| [dfs_bfs.mere](dfs_bfs.mere) | DFS vs BFS comparison (both implemented as iterative stack/queue) |

#### Data structures (2 files)

| File | Content |
|---|---|
| [trie.mere](trie.mere) | prefix tree (flat representation in Map[str, int]); insert / search / starts_with |
| [hashtable.mere](hashtable.mere) | hand-rolled hash table (chaining; buckets are int lists encoded as str) |

#### Interpreters / language processors (2 files)

| File | Content |
|---|---|
| [stack_machine.mere](stack_machine.mere) | simple RPN VM (variant instr + Map[str, int] stack). Push/Add/Sub/Mul/Div/Neg/Dup/Swap |
| [lambda_calc.mere](lambda_calc.mere) | pure untyped λ-calculus interpreter (substitution-based; Church numeral addition demo). Wasm traps on deep recursion (diff = 0 on interp + C + LLVM) |

#### Document processors (3 files)

| File | Content |
|---|---|
| ~~`markdown_to_html.mere`~~ | -> [contrib/markdown/to_html.mere](../contrib/markdown/to_html.mere) |
| [prettyprinter.mere](prettyprinter.mere) | Wadler-style pretty printer combinator (variant doc + group/nest/line) |
| ~~`regex_engine.mere`~~ | -> [contrib/regex/engine.mere](../contrib/regex/engine.mere) (NFA-based prototype) |

## How to try codegen

```sh
# C source -> native binary
dune exec ./bin/mere.exe -- -c examples/toy_sql.mere > /tmp/sql.c
clang /tmp/sql.c -o /tmp/sql && /tmp/sql

# LLVM IR -> native binary
dune exec ./bin/mere.exe -- -ll examples/toy_sql.mere > /tmp/sql.ll
clang /tmp/sql.ll -o /tmp/sql && /tmp/sql

# Wasm (requires wabt / Node.js). Phase 27.2 added scripts/run_wasm.js
dune exec ./bin/mere.exe -- -w examples/toy_sql.mere > /tmp/sql.wat
wat2wasm /tmp/sql.wat -o /tmp/sql.wasm
node scripts/run_wasm.js /tmp/sql.wasm   # with env imports for puts / read_file / write_file
```

The 16 ⭐ examples have been verified with `diff` to **produce output
matching across interp and all 3 backends with diff = 0** (preserved
after Phase 27 completion + Phase 28 additions + Phase 30 codegen fixes).

## REPL session record

| File | Content |
|---|---|
| [repl_session.md](repl_session.md) | REPL usage examples |
