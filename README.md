# lang-ml

新プログラミング言語 (仮称 Lang) の OCaml 実装。

## ステータス

実装中 (2026-06-06 着手)。最小コア言語 (整数 / 真偽値 / let / let rec / if / 関数 / 双方向型検査) が動作。

詳しい実装ステータスは別リポ aidocs の [`aidocs/projects/lang/implementation_status.md`](https://github.com/284km/aidocs) を参照 (private)。

## 現在動く機能

| 機能 | 例 | 結果 |
|---|---|---|
| 整数算術 | `1 + 2 * 3` | `7` |
| let | `let x = 5 in x + 1` | `6` |
| 真偽値・比較・if | `if 1 < 2 then 100 else 200` | `100` |
| 第一級関数 | `let inc = fn x -> x + 1 in inc 5` | `6` |
| 高階関数 | `let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5` | `7` |
| 再帰 (let rec) | `let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10` | `3628800` |
| 型検査 | `((fn x -> x + 1) : int -> int) 5` | 型 `int`, 値 `6` |
| 行コメント | `1 + 2 // sum` | `3` |

## 使い方

```sh
# ファイル評価
lang-ml examples/factorial.lang
# → 3628800

# インライン評価
lang-ml -e '1 + 2 * 3'
# → 7

# 型表示
lang-ml -t examples/typed.lang
# → int

# inline 型表示
lang-ml -te '(fn x -> x + 1) : int -> int'
# → (int -> int)

# ヘルプ
lang-ml --help
```

エラー時はソース該当行と caret が表示される:

```
$ lang-ml -te '1 + true'
<inline>:1:5: type error: expected int, got bool
  1 + true
      ^
```

## 経緯

- ホスト言語として OCaml を採用 (Q-001 resolved 2026-06-06)
- 採用判断のための trial: `aidocs/projects/lang/trials/ocaml-expr/` (49 tests)

## 設計コンテキスト

設計判断の詳細は別リポ `aidocs` (private) の以下を参照:

- `aidocs/projects/lang/00_design_principles.md` (再開時の入口)
- `aidocs/projects/lang/implementation_status.md` (実装と設計の対応)
- `aidocs/projects/lang/OPEN_QUESTIONS.md`
- `aidocs/projects/lang/trials/ocaml-expr/` (採用判断 trial)

## レイアウト

```
lang-ml/
├── dune-project
├── bin/             # CLI エントリ (main.ml)
├── lib/             # コア処理系
│   ├── loc.ml          # 位置情報
│   ├── ast.ml          # AST + 型
│   ├── lexer.ml        # トークナイザ
│   ├── parser.ml       # 再帰下降パーサ
│   ├── typer.ml        # 双方向型検査
│   ├── eval.ml         # interpreter
│   ├── pipeline.ml     # process / type_of
│   ├── diagnostic.ml   # ソース付きエラー整形
│   └── version.ml
├── test/            # テスト (24 件)
└── examples/        # サンプル .lang ファイル (5 件)
```

## ビルド・実行

```sh
dune build
dune exec bin/main.exe -- examples/factorial.lang
dune runtest
```

## 既知の制約

- HM 型推論はまだない。関数アノテーションは都度書く必要あり
- 単一式プログラム (複数 top-level 定義は未対応)
- パターンマッチ・sum types なし
- 文字列・float なし
- ネイティブ codegen なし (全てインタプリタ)

## 名前について

`lang-ml` は仮称。本番名は設計の核 (effect / type / memory model) が動くようになった頃に再考する。
