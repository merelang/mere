# lang-ml

新プログラミング言語 (仮称 **Lang**) の OCaml 実装。ML 系 mini lang として
実用域に到達し、メモリモデル (region/view/Trivial[R])・エフェクトシステム
(cap passing)・3 バックエンド (C / LLVM IR / Wasm) の codegen まで全部
feature-parity で動く段階。

## ステータス (2026-06-19 時点)

- **1033 tests passing**
- ツリーウォーキング interpreter + **C / LLVM IR / Wasm の 3 backend** が
  feature parity で動く (同じ Lang プログラムから 3 種のバイナリを出せる)
- メモリモデル: region / view / Trivial[R] / `with` Drop が型・interpreter・
  3 backend codegen すべてで動く
- エフェクトシステム: cap-passing パターン + `using [cap]` sugar + builtin Logger / Metrics
- 言語 surface: `module M { ... }` + `M.f` qualified access、`import "path";`
  によるファイル分割
- REPL: multi-line 入力、`:env` / `:show` / `:load` / `:reset`、Rust 風
  code frame でエラー表示
- 設計コンテキストは別リポ `aidocs/projects/lang/` (private)

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
| エフェクト | capability passing (cap = record の値)、`using [cap]` sugar、builtin Logger / Metrics |
| with Drop | `with c = ... in body` で scope 末に `close` field 自動呼出、複数 binding は LIFO |
| モジュール | `module M { ... }` で名前空間、`M.f` 参照、内部短縮名は parse 時 rewrite |
| import | `import "path";` で別ファイルの decls を取り込み、cycle guard あり |
| stdlib | 87 種の builtin: I/O 8 / 変換 7 / 文字列 20 / 数値 17 / 多相 helper 8 / float 12 / error 3 / システム / Logger・Metrics |
| codegen | C / LLVM IR / Wasm (WAT) の 3 backend が parity で動く (詳細は [codegen.md](docs/codegen.md)) |
| REPL | 永続 env、multi-line 入力、`:type` `:env` `:show NAME` `:load FILE` `:reset` `:help` |
| エラー UX | Rust 風 multi-line code frame、ANSI 色 (TTY 時)、Levenshtein による typo 提案、型変換 hint (`use show x`, `if b then 1 else 0` 等) |

## クイック例

```sh
$ dune exec ./bin/main.exe -- -e '5 |> (fn x -> x + 1) |> show'
"6"

$ dune exec ./bin/main.exe -- -e 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10'
3628800

$ dune exec ./bin/main.exe -- -e 'type opt = None | Some of int; match Some 42 with | None -> 0 | Some n -> n + 1'
43

$ dune exec ./bin/main.exe -- examples/module_basic.lang
# `module Math { ... }` + Math.inc / Math.square / Math.pow を呼ぶ

$ dune exec ./bin/main.exe -- examples/import_demo.lang
# import "examples/lib_list_ops.lang"; ListOps.sum [1..5] を計算

$ dune exec ./bin/main.exe -- examples/json_parser.lang
# JSON パーサ in Lang (140 行) のセルフテストが走る

$ dune exec ./bin/main.exe -- examples/pipeline.lang
# region/view/effect/with の全機能を組合せた realistic example
```

## ドキュメント

- **[Tutorial](docs/tutorial.md)** — 初めての方はここから (`module` / `import` / REPL 含む)
- **[Language reference](docs/language-reference.md)** — 構文と意味論
- **[Stdlib reference](docs/stdlib-reference.md)** — builtin の表
- **[Patterns / cookbook](docs/patterns.md)** — よくあるイディオム
- **[Memory model](docs/memory-model.md)** — メモリ管理の比較・region/view・現状と将来
- **[Codegen](docs/codegen.md)** — C / LLVM IR / Wasm の 3 backend 戦略 + slice 表
- **[Changelog](docs/changelog.md)** — 着手日 (2026-06-06) からの主要マイルストーン
- `examples/` — 動く .lang ファイル群 (FizzBuzz、JSON parser、word count、module/import 例 等)

## ビルド・実行

```sh
dune build
dune exec ./bin/main.exe -- examples/factorial.lang
dune exec ./bin/main.exe -- -e '1 + 2 * 3'
dune exec ./bin/main.exe -- -te 'fn x -> x + 1'      # 型表示
dune exec ./bin/main.exe -- -r                       # REPL
dune runtest                                         # 1033 tests

# C codegen
dune exec ./bin/main.exe -- -ce 'let x = 5 in x * 2' > out.c
clang out.c -o out && ./out                          # → 10

# LLVM IR codegen
dune exec ./bin/main.exe -- -lle '1 + 2 * 3' | llc - -o sum.s
clang sum.s -o sum && ./sum                          # → 7

# Wasm codegen (要 wabt / Node.js)
dune exec ./bin/main.exe -- -we '1 + 2 * 3' > sum.wat
wat2wasm sum.wat -o sum.wasm
node -e 'WebAssembly.instantiate(require("fs").readFileSync("sum.wasm"))
  .then(r => console.log(r.instance.exports.main()))'   # → 7
```

3 backend (C / LLVM / Wasm) はすべて feature parity で、int / 関数 / 文字列 /
tuple / record / variant / closure / 多相 / 再帰 variant / 複雑 pattern /
show / region / view / `with` Drop / list pretty-print まで通る。

## レイアウト

```
lang-ml/
├── bin/main.ml         # CLI エントリ
├── lib/                # コア処理系
│   ├── loc.ml / ast.ml / lexer.ml / parser.ml
│   ├── typer.ml        # HM 推論 + sum types + records + let-poly
│   ├── eval.ml         # ツリーウォーキング interpreter
│   ├── codegen_c.ml    # C codegen
│   ├── codegen_llvm.ml # LLVM IR codegen
│   ├── codegen_wasm.ml # Wasm (WAT) codegen
│   ├── pipeline.ml     # process / type_of
│   ├── repl.ml         # 対話実行 (multi-line / :env / :show / :load / :reset)
│   ├── diagnostic.ml   # Rust 風 code frame + ANSI 色付け
│   └── version.ml
├── test/test_basic.ml  # 1033 tests
├── examples/           # .lang サンプル群
└── docs/               # tutorial / language-reference / stdlib-reference / patterns / memory-model / codegen / changelog
```

## 設計コンテキスト (別リポ)

設計判断は `aidocs/projects/lang/` (private) で進行:

- `00_design_principles.md` — 言語哲学
- `01_memory_model.md` — 5 戦略 (owned / borrowed / region (= arena) / view / stack)
- `05_effect_system.md` — capability passing
- `OPEN_QUESTIONS.md` — Q-001〜Q-011 全 resolved / narrowed
- `implementation_status.md` — slice ごとの進捗
- `SUMMARY.md` — Phase 1〜9 の到達点を外向けに集約
- `11_region_vs_arena.md` 〜 `14_view_types.md` — メモリモデル deep dive

## 名前について

`lang-ml` は OCaml 実装中の仮称。本番名は設計の核 (effect / type / memory)
が動く頃に再考。

## ライセンス

未定 (private)
