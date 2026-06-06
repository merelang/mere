# lang-ml

新プログラミング言語 (仮称 Lang) の OCaml 実装。

## ステータス

着手直後 (2026-06-06)。スケルトン作成済み、設計はこれから。

## 経緯

- ホスト言語として OCaml を採用 (Q-001 resolved 2026-06-06)
- 採用判断のための trial: `aidocs/projects/lang/trials/ocaml-expr/` (49 tests)

## 設計コンテキスト

設計判断の詳細は別リポ `aidocs` の以下を参照:

- `aidocs/projects/lang/00_design_principles.md`
- `aidocs/projects/lang/01_memory_model.md`
- `aidocs/projects/lang/02_json_parser_example.md`
- `aidocs/projects/lang/03_lifetime_and_mutability.md`
- `aidocs/projects/lang/04_fundamental_tradeoffs.md`
- `aidocs/projects/lang/05_effect_system.md`
- `aidocs/projects/lang/OPEN_QUESTIONS.md`

## レイアウト

```
lang-ml/
├── dune-project
├── bin/             # 実行ファイル (CLI エントリ)
│   ├── dune
│   └── main.ml
├── lib/             # ライブラリ本体 (lexer/parser/typer/etc.)
│   ├── dune
│   └── version.ml
└── test/            # テスト
    ├── dune
    └── test_basic.ml
```

## ビルド・実行

```
dune build
dune exec bin/main.exe
dune runtest
```

## 名前について

`lang-ml` は仮称。本番名は設計の核 (effect / type / memory model) が動くようになった頃に再考する。
