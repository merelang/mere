# Mere

> *Make Explicit Region-bound Effects.*

新プログラミング言語 **Mere** (古英語の「湖」、4 文字、region メタファー)
の OCaml 実装。ML 系 mini lang として実用域に到達し、メモリモデル
(region/view/Trivial[R])・エフェクトシステム (cap passing + 借用注釈
細分化)・3 バックエンド (C / LLVM IR / Wasm) の codegen まで全部
feature-parity で動く段階。

旧仮称: `lang-ml` (2026-06-19 に Mere に確定、NAMING.md 参照)。

## ステータス (2026-06-19 時点)

- **1185 tests passing**
- ツリーウォーキング interpreter + **C / LLVM IR / Wasm の 3 backend** が
  feature parity で動く (同じ Mere プログラムから 3 種のバイナリを出せる)
- メモリモデル: region / view / Trivial[R] / `with` Drop が型・interpreter・
  3 backend codegen すべてで動く
- エフェクトシステム: cap-passing パターン + `using [cap]` sugar + builtin Logger / Metrics
- 借用注釈の細分化: `&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T` の 4 mode + borrow checker (place expression + if/match 分岐の伝播)
- Q-010 標準コレクション: `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` (interpreter)
- 言語 surface: `module M { ... }` (入れ子可) + `M.f` qualified access、`import "./path";` (importer-relative + canonical) によるファイル分割、`open M;`
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
| エフェクト | capability passing (cap = record の値)、`using [cap]` sugar、builtin Logger / Metrics |
| with Drop | `with c = ... in body` で scope 末に `close` field 自動呼出、複数 binding は LIFO |
| モジュール | `module M { ... }` (入れ子)・`M.f` 参照・内部短縮名 rewrite・`open M;`・module 内 type/record OK |
| import | `import "./path";` で別ファイル取込み (importer-relative + canonical) |
| collection | `Vec[R, T]` / `OwnedVec[T]` / `StrBuf[R]` / `Map[R, K, V]` + 高階 API (iter/map/fold/filter/to_list/to_owned) |
| stdlib | 90+ 種の builtin: I/O / 変換 / 文字列 / 数値 / 多相 helper / float / error / Logger・Metrics |
| codegen | C / LLVM IR / Wasm (WAT) の 3 backend が parity で動く (詳細は [codegen.md](docs/codegen.md))。OwnedVec/StrBuf/Map は interpreter-only。`Vec[R, T]` は Phase 15.2 / 15.3 / 15.4 で **3 backend すべてで要素型一般化済み** — int / bool / str / tuple / record / variant 全対応 |
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
```

## ドキュメント

- **[Tutorial](docs/tutorial.md)** — 初めての方はここから (`module` / `import` / REPL 含む)
- **[Language reference](docs/language-reference.md)** — 構文と意味論
- **[Stdlib reference](docs/stdlib-reference.md)** — builtin の表
- **[Patterns / cookbook](docs/patterns.md)** — よくあるイディオム
- **[Memory model](docs/memory-model.md)** — メモリ管理の比較・region/view・現状と将来
- **[Codegen](docs/codegen.md)** — C / LLVM IR / Wasm の 3 backend 戦略 + slice 表
- **[Changelog](docs/changelog.md)** — 着手日 (2026-06-06) からの主要マイルストーン
- `examples/` — 動く `.mere` ファイル群 (FizzBuzz、JSON parser、word count、module/import 例 等)

## ビルド・実行

```sh
dune build
dune exec ./bin/mere.exe -- examples/factorial.mere
dune exec ./bin/mere.exe -- -e '1 + 2 * 3'
dune exec ./bin/mere.exe -- -te 'fn x -> x + 1'      # 型表示
dune exec ./bin/mere.exe -- -r                       # REPL
dune runtest                                         # 1185 tests

# C codegen
dune exec ./bin/mere.exe -- -ce 'let x = 5 in x * 2' > out.c
clang out.c -o out && ./out                          # → 10

# LLVM IR codegen
dune exec ./bin/mere.exe -- -lle '1 + 2 * 3' | llc - -o sum.s
clang sum.s -o sum && ./sum                          # → 7

# Wasm codegen (要 wabt / Node.js)
dune exec ./bin/mere.exe -- -we '1 + 2 * 3' > sum.wat
wat2wasm sum.wat -o sum.wasm
node -e 'WebAssembly.instantiate(require("fs").readFileSync("sum.wasm"))
  .then(r => console.log(r.instance.exports.main()))'   # → 7
```

3 backend (C / LLVM / Wasm) はすべて feature parity で、int / 関数 / 文字列 /
tuple / record / variant / closure / 多相 / 再帰 variant / 複雑 pattern /
show / region / view / `with` Drop / list pretty-print まで通る。
(OwnedVec / StrBuf / Map は interpreter-only。`Vec[R, T]` は Phase 15.2 / 15.3
/ 15.4 で **3 backend (C / LLVM / Wasm) すべて** が要素型 T を一般化 —
int / bool / str / tuple / record / variant 全対応。例:
`examples/vec_codegen_c.mere` / `vec_codegen_c_typed.mere` /
`vec_codegen_llvm_typed.mere` / `vec_codegen_wasm_typed.mere`)

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
├── test/test_basic.ml  # 1185 tests
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

未定 (private)
