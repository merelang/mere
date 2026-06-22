# Mere

[![CI](https://github.com/284km/mere/actions/workflows/ci.yml/badge.svg)](https://github.com/284km/mere/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> *Make Explicit Region-bound Effects.*

新プログラミング言語 **Mere** (古英語の「湖」、4 文字、region メタファー)
の OCaml 実装。ML 系 mini lang として実用域に到達し、メモリモデル
(region/view/Trivial[R])・エフェクトシステム (cap passing + 借用注釈
細分化)・3 バックエンド (C / LLVM IR / Wasm) の codegen まで全部
feature-parity で動く段階。

旧仮称: `lang-ml` (2026-06-19 に Mere に確定、NAMING.md 参照)。

## ステータス (2026-06-22 時点)

- **1498 tests passing**
- **4 backend feature parity**: interp + C / LLVM IR / Wasm runtime
  すべてが 16 realistic examples (~1500 LoC) で **diff = 0 PERFECT 一致**
  (Phase 24-27)、Phase 36 で実例集を 118 本まで拡張
- メモリモデル: region / view / Trivial[R] / `with` Drop が型・interpreter・
  3 codegen backend すべてで動く
- エフェクトシステム: cap-passing パターン + `signature ... = (...)` 引数束ね + `using [cap]` sugar + builtin Logger / Metrics
- 借用注釈の細分化: `&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T` の 4 mode + borrow checker (place expression + if/match 分岐の伝播 + conflict matrix 完全網羅)
- Q-010 標準コレクション: `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` が **interpreter + 3 backend** で動作 (Phase 15.x)
- ポリモーフィズム: HM 推論 + let-poly + **多相 user let-rec の per-instantiation 特殊化** (Phase 23.3 / 25.5 / 26.4) + Phase 36 で narrow value restriction (mutable container を含む型を let-bind した時は generalize しない)
- inner-fn lifting: `let rec inner = fn ... -> ...` を top-level に持ち上げ + 自由変数を prepend (Phase 25.3 / 26.3)
- top-level 値 binding: `let total = mk_metrics();` のような非-fn let を fn body から参照可 (Phase 30.2 で 3 backend に global 化)
- Wasm runtime: `scripts/run_wasm.js` (Node.js host harness, puts / read_file / write_file) で runtime 実行検証 (Phase 27.2)
- FFI: `extern fn <name>: <ty>;` で libc 関数を 4 backend から直接呼出 (Phase 32、curried multi-arg 対応、int/bool/str/unit 型のみ MVP)
- 言語 surface: `module M { ... }` (入れ子可) + `M.f` qualified access、`import "./path";` (importer-relative + canonical) によるファイル分割、`open M;`
- **Phase 36 syntactic sugar (13 種)**: range `a..b` / operator section `(+ 1)` / cons `1 :: xs` / reverse pipe `f <| x` / apply `f @@ x` / lambda shorthand `\x -> ...` / string interpolation `"x = {show n}"` / `?` (Option) / `?!` (Result) early-return / list comprehension `[f x | x <- xs, p x]` / `if let pat = e then ... else ...` / `for x in xs do body` / `while cond do body`
- **Phase 36 prelude 強化 (16 entry 追加)**: `range` / `list_filter` / `list_take` / `list_drop` / `list_find` / `list_append` / `list_concat` / `list_flat_map` / `list_zip` / `list_for_all` / `list_any` / `list_member` / `list_sum` / `list_product` / `list_max` / `list_min` (累計 34 entry)
- REPL: multi-line 入力、`:env` / `:show` / `:load` / `:reset`、Rust 風 code frame でエラー表示
- 設計コンテキストは別リポ `internal design notes` (private)

## 動く機能ハイライト

| カテゴリ | 内容 |
|---|---|
| 型システム | Hindley-Milner 推論、let-polymorphism、多相 builtin |
| プリミティブ | `int`、`float` (IEEE 754)、`bool`、`str`、`unit` |
| データ | tuple、record、sum types、list 構文糖 `[1, 2, 3]` (show 出力も `[..]` 形式) |
| 制御 | `if-then-else`、`if-then` (unit)、`match` + guard `when` + as-pattern + or-pattern |
| パターン | wildcard / var / lit / 文字 `'X'` / tuple / constructor / list `[h, ...t]` / record / as / or |
| 関数 | 多引数型付き fn / `let rec ... and ...` 相互再帰 / 高階 / closure |
| 演算子 | `+ - * / % == != < <= > >= && \|\| ++ \|> << >>` (int 算術)、float は `f_add` 等 |
| 名前管理 | `let _ = ...;` `let (a, b) = ...;` `signature`、`type X = T` (alias) |
| メモリモデル | region (`region R { ... }`) / view (`view V[R] of T { ... }`) / `&R T` 参照 / escape check / Trivial[R] 制約 / `R.alloc(v)` sugar |
| 借用注釈 | `&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T` + borrow checker (place + if/match 伝播) |
| エフェクト | capability passing (cap = record の値)、`signature` 引数束ね + spread、`using [cap]` sugar、builtin Logger / Metrics |
| with Drop | `with c = ... in body` で scope 末に `close` field 自動呼出、複数 binding は LIFO |
| エラー処理 | `Result` 型 + `result_map` / `result_and_then` / `result_or_else` (prelude)、`fail "msg"` / `try_or default fn` で例外的 fail catch |
| モジュール | `module M { ... }` (入れ子)・`M.f` 参照・内部短縮名 rewrite・`open M;`・module 内 type/record OK |
| import | `import "./path";` で別ファイル取込み (importer-relative + canonical) |
| collection | `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` + 高階 API (iter/map/fold/filter/to_list/to_owned) — **insertion-order な Map iter** (Phase 27.1) |
| stdlib | 90+ 種の builtin: I/O / 変換 / 文字列 (`str_split` / `str_join` / `str_compare` / `str_index_of` 等) / 数値 / 多相 helper / float / error / Logger・Metrics |
| codegen | C / LLVM IR / Wasm (WAT) の 3 backend が parity で動く + Wasm runtime 実行検証 (詳細は [codegen.md](docs/codegen.md))。Q-010 collection 4 種 + 高階 API + 変換 + `len` ad-hoc poly + 多相 user let-rec の per-instantiation 特殊化 (Phase 23.3 / 25.5 / 26.4) + inner-fn lifting (Phase 25.3 / 26.3) + top-level 値 binding を file-scope global 化 (Phase 30.2) |
| FFI | `extern fn <name>: <ty>;` で libc 関数を 4 backend (interp + C/LLVM/Wasm) から呼出。curried multi-arg、int / bool / str / unit 型 (Phase 32) |
| REPL | 永続 env、multi-line 入力、`:type` `:env` `:show NAME` `:load FILE` `:reset` `:help` |
| エラー UX | Rust 風 multi-line code frame、ANSI 色 (TTY 時)、Levenshtein による typo 提案 (record field / qualified name 含む)、型変換 hint |

## クイック例

```sh
$ dune exec ./bin/mere.exe -- -e '5 |> (fn x -> x + 1) |> show'
"6"

$ dune exec ./bin/mere.exe -- -e 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10'
3628800

$ dune exec ./bin/mere.exe -- -e 'type opt = None | Some of int; match Some 42 with | None -> 0 | Some n -> n + 1'
43

$ dune exec ./bin/mere.exe -- examples/module_basic.mere
# `module Math { ... }` + Math.inc / Math.square / Math.pow を呼ぶ

$ dune exec ./bin/mere.exe -- examples/import_demo.mere
# import "examples/lib_list_ops.mere"; ListOps.sum [1..5] を計算

$ dune exec ./bin/mere.exe -- examples/json_parser.mere
# JSON パーサ in Mere (140 行) のセルフテストが走る

$ dune exec ./bin/mere.exe -- examples/pipeline.mere
# region/view/effect/with の全機能を組合せた realistic example

$ dune exec ./bin/mere.exe -- examples/toy_sql.mere
# 1165 行の toy SQL engine (tokenizer + parser + executor + JOIN)、
# 4 backend (interp + C + LLVM + Wasm) で 59 tests を diff=0 一致

$ dune exec ./bin/mere.exe -- examples/calc.mere
# Phase 36: recursive descent な arithmetic parser + `?!` Result chain。
# `1 + 2 * 3` → 7、`(1 + 2) * 3` → 9、`10 / 0` → ERR division

$ dune exec ./bin/mere.exe -- examples/maze_solver.mere
# Phase 36: ASCII 8x12 maze の BFS pathfinding + path 可視化
```

## ドキュメント

- **[Tutorial](docs/tutorial.md)** — 初めての方はここから (`module` / `import` / REPL 含む)
- **[Language reference](docs/language-reference.md)** — 構文と意味論
- **[Stdlib reference](docs/stdlib-reference.md)** — builtin の表
- **[Patterns / cookbook](docs/patterns.md)** — よくあるイディオム
- **[Memory model](docs/memory-model.md)** — メモリ管理の比較・region/view・現状と将来
- **[Codegen](docs/codegen.md)** — C / LLVM IR / Wasm の 3 backend 戦略 + slice 表
- **[Changelog](docs/changelog.md)** — 着手日 (2026-06-06) からの主要マイルストーン
- `examples/` — 動く `.mere` ファイル群 (118 本、[examples/README.md](examples/README.md) で
  カテゴリ別索引)。基本的な FizzBuzz / JSON parser / word count から、
  Q-010 collection の codegen demo (`vec_codegen_*.mere` /
  `owned_vec_codegen.mere` / `strbuf_codegen.mere` / `map_codegen.mere`)、
  realistic application (16 examples が 4 backend で PERFECT 一致): `json_parser` /
  `template_engine` / `word_freq` / `mini_shell` / `json_writer` / `chained_parse` /
  `state_machine` / `ini_parser` / `regex_lite` まで、**1165 行の `toy_sql`**
  (toy SQL engine — Phase 29 dogfood で書いた 59 tests、4 backend PERFECT)、
  そして Phase 36 で追加した 47 本の sugar dogfood example: `calc` (recursive
  descent arithmetic parser + `?!` Result chain) / `maze_solver` (BFS) /
  `game_of_life` / `sudoku_check` / `tic_tac_toe` / `eight_queens` / `knapsack` /
  `roman_numerals` / `morse_code` / `luhn_check` / `caesar_cipher` /
  `csv_summary` / `markdown_to_text` / `comprehension` / `if_let_demo` /
  `for_loop_demo` / `while_loop_demo` / `sugar_showcase` ほか

## ビルド・実行

```sh
dune build
dune exec ./bin/mere.exe -- examples/factorial.mere
dune exec ./bin/mere.exe -- -e '1 + 2 * 3'
dune exec ./bin/mere.exe -- -te 'fn x -> x + 1'      # 型表示
dune exec ./bin/mere.exe -- -r                       # REPL
dune runtest                                         # 1498 tests

# C codegen
dune exec ./bin/mere.exe -- -ce 'let x = 5 in x * 2' > out.c
clang out.c -o out && ./out                          # → 10

# LLVM IR codegen
dune exec ./bin/mere.exe -- -lle '1 + 2 * 3' | llc - -o sum.s
clang sum.s -o sum && ./sum                          # → 7

# Wasm codegen (要 wabt / Node.js)
dune exec ./bin/mere.exe -- -we '1 + 2 * 3' > sum.wat
wat2wasm sum.wat -o sum.wasm
node scripts/run_wasm.js sum.wasm                    # → 7 (host harness 経由)
```

3 backend (C / LLVM / Wasm) はすべて feature parity で、int / 関数 / 文字列 /
tuple / record / variant / closure / 多相 / 再帰 variant / 複雑 pattern /
show / region / view / `with` Drop / list pretty-print / Q-010 collection 4 種
(Vec / OwnedVec / StrBuf / Map) / 多相 user let-rec / inner-fn lifting /
top-level 値 binding の global 化 / `str_compare` の sign-normalized 出力
まで通る (Phase 15.x 〜 31.0 で逐次 parity 化、16 realistic examples で
diff = 0 PERFECT 一致を維持)。

## レイアウト

```
mere/
├── bin/mere.ml         # CLI エントリ
├── lib/                # コア処理系 (library: mere)
│   ├── loc.ml / ast.ml / lexer.ml / parser.ml
│   ├── typer.ml        # HM 推論 + sum types + records + let-poly + borrow checker
│   ├── eval.ml         # ツリーウォーキング interpreter
│   ├── codegen_c.ml    # C codegen
│   ├── codegen_llvm.ml # LLVM IR codegen
│   ├── codegen_wasm.ml # Wasm (WAT) codegen
│   ├── pipeline.ml     # process / type_of (?base_dir for importer-relative)
│   ├── repl.ml         # 対話実行 (multi-line / :env / :show / :load / :reset)
│   ├── diagnostic.ml   # Rust 風 code frame + ANSI 色付け
│   └── version.ml
├── test/test_basic.ml  # 1498 tests
├── scripts/run_wasm.js # Wasm runtime host harness (Node.js, puts / read_file / write_file)
├── examples/           # *.mere サンプル群
└── docs/               # tutorial / language-reference / stdlib-reference / patterns / memory-model / codegen / changelog
```

## 設計コンテキスト (別リポ)

設計判断は `internal design notes` (private) で進行:

- `00_design_principles.md` — 言語哲学
- `01_memory_model.md` — 5 戦略 (owned / borrowed / region (= arena) / view / stack)
- `05_effect_system.md` — capability passing
- `OPEN_QUESTIONS.md` — Q-001〜Q-011 全 resolved / narrowed
- `implementation_status.md` — slice ごとの進捗
- `SUMMARY.md` — 到達点を外向けに集約
- `DEFERRED.md` — 後回しにした実装項目の一覧 (codegen / NLL / trait システム等)
- `NAMING.md` — 仮称 `lang-ml` から正式名 Mere への命名経緯
- `11_region_vs_arena.md` 〜 `14_view_types.md` — メモリモデル deep dive

## 名前

**Mere** = 古英語の "湖"。region (周囲から区切られた水域) のメタファー、
ML 系の minimal な響き、`mere = ただの〜` のニュアンスに込めた謙虚さ。
旧仮称 `lang-ml`、設計の核 (effect / type / memory) が動いた節目で
2026-06-19 に確定。

## ライセンス

**MIT License** ([LICENSE](LICENSE) 参照)。

contribution については [CONTRIBUTING.md](CONTRIBUTING.md) を参照
(将来の MIT OR Apache-2.0 dual license 化の余地を確保する文言あり)。
