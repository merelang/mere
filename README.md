# lang-ml

新プログラミング言語 (仮称 **Lang**) の OCaml 実装。ML 系 mini lang として実用域に到達。本来の目標 (effect / memory model / region) はこれから。

## ステータス (2026-06-16 時点)

- **85 stdlib builtin、628 tests passing** (網羅性検査 Phase 1 + region/`&R T` Phase 2.1 含む)
- ツリーウォーキング interpreter (codegen なし)
- 設計コンテキストは別リポ `internal design notes` (private)

## 動く機能ハイライト

| カテゴリ | 内容 |
|---|---|
| 型システム | Hindley-Milner 推論、let-polymorphism、多相 builtin (1〜3-quantified) |
| プリミティブ | `int`、`float` (IEEE 754)、`bool`、`str`、`unit` |
| データ | tuple、record、sum types、list 構文糖 `[1, 2, 3]` (show 出力も `[..]` 形式) |
| 制御 | `if-then-else`、`if-then` (unit)、`match` + ガード `when` + as-pattern + or-pattern |
| パターン | wildcard / var / lit / 文字 `'X'` / tuple / constructor / list `[h, ...t]` / record / as / or |
| 関数 | 多引数型付き fn / `let rec ... and ...` 相互再帰 / 高階 / closure |
| 演算子 | `+ - * / % == != < <= > >= && \|\| ++ \|> << >>` (int 算術)、float は `f_add` 等 |
| 名前管理 | `let _ = ...;` `let (a, b) = ...;` `signature`、`type X = T` (alias) |
| stdlib | 75 種: I/O 8 / 変換 7 / 文字列 20 / 数値 17 / 多相 helper 8 / float 12 (算術 4 + 比較 4 + 変換 4) / error 3 / システム (time/exit) |
| REPL | 対話実行、永続 env、`:type`/`:help`/`:quit` |
| エラー | ソース該当行 + caret 表示 |

## クイック例

```sh
$ dune exec ./bin/main.exe -- -e '5 |> (fn x -> x + 1) |> show'
"6"

$ dune exec ./bin/main.exe -- -e 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10'
3628800

$ dune exec ./bin/main.exe -- -e 'type 'a opt = None | Some of 'a; match Some 42 with | None -> 0 | Some n -> n + 1'
43

$ dune exec ./bin/main.exe -- examples/json_parser.lang
# JSON パーサ in Lang (140 行) のセルフテストが走る

$ echo "hello lang world" > /tmp/input.txt
$ dune exec ./bin/main.exe -- examples/word_count.lang
# file: /tmp/input.txt / chars / lines / words を表示

$ dune exec ./bin/main.exe -- examples/pipeline.lang
# region/view/effect/with の全機能を組合せた realistic example。
# Drop ありの Session を with で開閉、各タスクを region 内で view で処理、
# Logger/Metrics の cap を using sugar で渡す。
```

## ドキュメント

- **[Tutorial](docs/tutorial.md)** — 初めての方はここから
- **[Language reference](docs/language-reference.md)** — 構文と意味論
- **[Stdlib reference](docs/stdlib-reference.md)** — 全 85 builtin の表
- **[Patterns / cookbook](docs/patterns.md)** — よくあるイディオム
- **[Memory model](docs/memory-model.md)** — メモリ管理の比較・region/view・現状と将来
- **[Changelog](docs/changelog.md)** — 着手日 (2026-06-06) からの主要マイルストーン
- `examples/` — 動く .lang ファイル群 (FizzBuzz、JSON parser、word count 等)

## ビルド・実行

```sh
dune build
dune exec ./bin/main.exe -- examples/factorial.lang
dune exec ./bin/main.exe -- -e '1 + 2 * 3'
dune exec ./bin/main.exe -- -te 'fn x -> x + 1'    # 型表示
dune exec ./bin/main.exe -- -r                     # REPL
dune runtest

# C codegen (Phase 4、int subset + 関数 lifting)
dune exec ./bin/main.exe -- -ce 'let x = 5 in x * 2' > out.c
clang out.c -o out && ./out                        # native 実行 → 10

dune exec ./bin/main.exe -- -ce 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10' > fact.c
clang fact.c -o fact && ./fact                     # → 3628800

dune exec ./bin/main.exe -- -ce 'print ("hello, " ++ "lang!")' > hello.c
clang hello.c -o hello && ./hello                  # → hello, lang!
```

## レイアウト

```
lang-ml/
├── bin/main.ml         # CLI エントリ
├── lib/                # コア処理系
│   ├── loc.ml / ast.ml / lexer.ml / parser.ml
│   ├── typer.ml        # HM 推論 + sum types + records + let-poly
│   ├── eval.ml         # ツリーウォーキング interpreter
│   ├── codegen_c.ml    # C codegen (Phase 4 MVP、int subset)
│   ├── pipeline.ml     # process / type_of
│   ├── repl.ml         # 対話実行
│   ├── diagnostic.ml   # ソース付きエラー整形
│   └── version.ml
├── test/test_basic.ml  # 519 tests
├── examples/           # .lang サンプル群
└── docs/               # tutorial / language-reference / stdlib-reference / patterns
```

## 設計コンテキスト (別リポ)

設計判断は `internal design notes` (private) で進行:

- `00_design_principles.md` — 言語哲学
- `01_memory_model.md` — 5 戦略 (owned / borrowed / region (= arena) / view / stack)
- `05_effect_system.md` — capability passing
- `OPEN_QUESTIONS.md` — Q-001〜Q-011 全 resolved / narrowed
- `implementation_status.md` — slice ごとの進捗
- `11_region_vs_arena.md` 〜 `14_view_types.md` — メモリモデル deep dive

## 名前について

`lang-ml` は OCaml 実装中の仮称。本番名は設計の核 (effect / type / memory) が動く頃に再考。

## ライセンス

未定 (private)
