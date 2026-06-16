# lang-ml

新プログラミング言語 (仮称 **Lang**) の OCaml 実装。ML 系 mini lang として実用域に到達。本来の目標 (effect / memory model / region) はこれから。

## ステータス (2026-06-16 時点)

- 56 stdlib builtin、519 tests passing
- ツリーウォーキング interpreter (codegen なし)
- 設計コンテキストは別リポ `internal design notes` (private)

## 動く機能ハイライト

| カテゴリ | 内容 |
|---|---|
| 型システム | Hindley-Milner 推論、let-polymorphism、多相 builtin (1〜3-quantified) |
| データ | int / bool / str / unit、tuple、record、sum types、list 構文糖 `[1, 2, 3]` |
| 制御 | `if-then-else`、`if-then` (unit)、`match` + ガード `when` + as-pattern + or-pattern |
| パターン | wildcard / var / lit / tuple / constructor / list `[h, ...t]` / record / as / or |
| 関数 | 多引数型付き fn / `let rec ... and ...` 相互再帰 / 高階 / closure |
| 演算子 | `+ - * / % == != < <= > >= && \|\| ++ \|> << >>` |
| 名前管理 | `let _ = ...;` `let (a, b) = ...;` `signature`、`type X = T` (alias) |
| stdlib | I/O・文字列・数値・多相・higher-order(`flip`,`try_or`,`iter_n`) 56 種 |
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
```

## ドキュメント

- **[Tutorial](docs/tutorial.md)** — 初めての方はここから
- **[Language reference](docs/language-reference.md)** — 構文と意味論
- **[Stdlib reference](docs/stdlib-reference.md)** — 全 56 builtin の表
- **[Patterns / cookbook](docs/patterns.md)** — よくあるイディオム
- `examples/` — 動く .lang ファイル群 (FizzBuzz、relational、JSON parser 等)

## ビルド・実行

```sh
dune build
dune exec ./bin/main.exe -- examples/factorial.lang
dune exec ./bin/main.exe -- -e '1 + 2 * 3'
dune exec ./bin/main.exe -- -te 'fn x -> x + 1'    # 型表示
dune exec ./bin/main.exe -- -r                     # REPL
dune runtest
```

## レイアウト

```
lang-ml/
├── bin/main.ml         # CLI エントリ
├── lib/                # コア処理系
│   ├── loc.ml / ast.ml / lexer.ml / parser.ml
│   ├── typer.ml        # HM 推論 + sum types + records + let-poly
│   ├── eval.ml         # ツリーウォーキング interpreter
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
