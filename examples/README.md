# Mere examples

Mere の動く `.mere` プログラム群。`dune exec ./bin/mere.exe -- examples/<file>.mere`
で interpreter 実行、`-c` / `-ll` / `-w` flag で 3 backend のいずれかへ
codegen。

## カテゴリ

### 入門・言語の基本

| ファイル | 内容 |
|---|---|
| [hello.mere](hello.mere) | "Hello, world!" |
| [factorial.mere](factorial.mere) | 階乗 (recursive fn) |
| [fibonacci.mere](fibonacci.mere) | フィボナッチ |
| [fizzbuzz.mere](fizzbuzz.mere) | FizzBuzz |
| [mini_calc.mere](mini_calc.mere) | 簡易計算プログラム |
| [mutual_rec.mere](mutual_rec.mere) | `let rec f = ... and g = ...` の相互再帰 |
| [higher_order.mere](higher_order.mere) | 高階関数 |
| [pipe.mere](pipe.mere) | `|>` パイプ演算子 |
| [typed.mere](typed.mere) | 型注釈の例 |
| [let_pattern.mere](let_pattern.mere) | `let (a, b) = ...` パターン |
| [top_decls.mere](top_decls.mere) | top-level let / let-rec の使用例 |

### データ型

| ファイル | 内容 |
|---|---|
| [records.mere](records.mere) | record (mono / 多相) |
| [options.mere](options.mere) | `'a opt` / Option パターン |
| [list.mere](list.mere) | 単相 `intlist`、明示的 Cons / Nil |
| [list_lib.mere](list_lib.mere) | リスト操作ライブラリ |
| [list_literal.mere](list_literal.mere) | `[1, 2, 3]` 構文糖 |
| [poly_list.mere](poly_list.mere) | 多相 `'a list` |
| [tree.mere](tree.mere) | 二分木 (再帰 variant) |

### メモリモデル (region / Drop / 借用)

| ファイル | 内容 |
|---|---|
| [borrow_modes.mere](borrow_modes.mere) | 借用注釈 4 mode の realistic demo (Logger / DbHandle / Config) |
| [borrow_modes_typeerror.mere](borrow_modes_typeerror.mere) | 借用 mode mismatch の意図的型エラー |
| [borrow_conflict.mere](borrow_conflict.mere) | borrow checker の意図的衝突 demo |

### エフェクト

| ファイル | 内容 |
|---|---|
| [effects.mere](effects.mere) | capability passing パターン |
| [signature.mere](signature.mere) | signature alias で cap bundle |
| [with_caps.mere](with_caps.mere) | `with c = ... in body` で Drop cap |

### モジュール / import

| ファイル | 内容 |
|---|---|
| [module_basic.mere](module_basic.mere) | `module M { ... }` + `M.f` 参照 |
| [module_nested.mere](module_nested.mere) | 入れ子 module + `open M;` |
| [import_demo.mere](import_demo.mere) | `import "./lib_list_ops.mere";` (要 `lib_list_ops.mere`) |
| [lib_list_ops.mere](lib_list_ops.mere) | import 用のライブラリ |

### 実用プログラム

| ファイル | 内容 |
|---|---|
| [json_parser.mere](json_parser.mere) | JSON パーサ (140 行) のセルフテスト |
| [csv_parser.mere](csv_parser.mere) | CSV パーサ |
| [word_count.mere](word_count.mere) | 単語カウント |
| [pipeline.mere](pipeline.mere) | region / view / cap / with を組合せた realistic な処理 |
| [arith_eval.mere](arith_eval.mere) | mini functional lang (算術 + if + 1st-class fn + closure) を AST から評価。**interpreter only** (wildcard `let _` + 多相 user let-rec の codegen 未対応)。Phase 20.2 / examples roadmap C3 |
| [s_expression.mere](s_expression.mere) | S 式 (Lisp 風) parser + printer + 簡易 eval (`+ - * / = <`, `if`, `let`)。**interpreter only** (同上)。Phase 20.3 / examples roadmap I4 |
| [todo_app.mere](todo_app.mere) | TODO リスト管理 (OwnedVec[Task] + Logger + vec_map / fold)。Phase 16 第 1 スライスでの試作、Phase 16-17 fix で **4 backend 完全対応** |
| [word_freq.mere](word_freq.mere) | 単語頻度カウンタ (Map[R, str, int] + str_split + map_iter)。**interpreter only** (多相 let-rec の codegen 未対応)。Phase 19.1+19.2 後の摩擦炙り出し |
| [safe_div.mere](safe_div.mere) | `(int, str) result` を使った失敗を値で返すパターン。**interpreter only**。Phase 19.5 prelude の Result demo |
| [module_scoping.mere](module_scoping.mere) | 2 module で同名 ctor を qualified 形式で disambiguate + nested `open A.B;`。**interpreter only** (codegen が M-prefix pattern 未対応)。Phase 18 demo |
| [json_writer.mere](json_writer.mere) | StrBuf[R] + recursive variant (json ADT) で compact / pretty-print。**interpreter only** (多相 user 定義 let-rec の codegen 未対応、§1.7)。Phase 19.3 (StrBuf) demo |
| [cap_handler.mere](cap_handler.mere) | `&shared write` で複数 handler が同じ Logger / Metrics を共有書き込みする app 風 demo。**4 backend 対応** (Phase 19.x で borrow 越し Field_get を C/LLVM/Wasm に対応)。Phase 17 / borrow_modes 延長 |
| [inventory.mere](inventory.mere) | 在庫管理 (Map[R, str, int] + Vec[R, Tx] + tx_kind variant)。Phase 19.2 (map_iter) / 19.3 (vec_sort) を実用 task に投入。Phase 20.1 で **4 backend 完全対応** (variant→record field の typedef 順序 fix) |

### Q-010 collection (Phase 12 — interpreter)

| ファイル | 内容 |
|---|---|
| [vec_basics.mere](vec_basics.mere) | `'a Vec` の基本操作 (push / get / len / region 内) |
| [vec_vs_owned_vec.mere](vec_vs_owned_vec.mere) | `Vec[R, T]` (短命) vs `OwnedVec[T]` (長命) の対比 demo |
| [vec_higher_order.mere](vec_higher_order.mere) | `vec_iter` / `vec_map` / `vec_fold` / `vec_set` |
| [strbuf_basics.mere](strbuf_basics.mere) | `StrBuf[R]` の基本 |
| [map_basics.mere](map_basics.mere) | `Map[R, K, V]` の基本 |

### Q-010 collection codegen (Phase 15 — 3 backend)

| ファイル | 内容 |
|---|---|
| [vec_codegen_c.mere](vec_codegen_c.mere) | `Vec[R, int]` の C codegen (Phase 15.1、最小) |
| [vec_codegen_c_typed.mere](vec_codegen_c_typed.mere) | C codegen で int / str / tuple / variant 混在 |
| [vec_codegen_llvm_typed.mere](vec_codegen_llvm_typed.mere) | 同じく LLVM IR 版 |
| [vec_codegen_wasm_typed.mere](vec_codegen_wasm_typed.mere) | 同じく Wasm 版 |
| [vec_higher_order_codegen.mere](vec_higher_order_codegen.mere) | vec_set / iter / fold の 3 backend codegen demo |
| [vec_map_filter_codegen.mere](vec_map_filter_codegen.mere) | vec_map / vec_filter の 3 backend codegen demo |
| [owned_vec_codegen.mere](owned_vec_codegen.mere) | OwnedVec + Vec ⇄ OwnedVec 変換の codegen demo |
| [strbuf_codegen.mere](strbuf_codegen.mere) | StrBuf の codegen demo |
| [map_codegen.mere](map_codegen.mere) | Map の codegen demo (str→int / int→str / region 内) |

## codegen の試し方

```sh
# C source → native binary
dune exec ./bin/mere.exe -- -c examples/vec_codegen_c.mere > /tmp/v.c
clang /tmp/v.c -o /tmp/v && /tmp/v        # → 95

# LLVM IR → native binary
dune exec ./bin/mere.exe -- -ll examples/owned_vec_codegen.mere > /tmp/v.ll
clang /tmp/v.ll -o /tmp/v && /tmp/v       # → 67

# Wasm (要 wabt / Node.js)
dune exec ./bin/mere.exe -- -w examples/map_codegen.mere > /tmp/v.wat
wat2wasm /tmp/v.wat -o /tmp/v.wasm
node -e 'WebAssembly.instantiate(require("fs").readFileSync("/tmp/v.wasm"),
  { env: { puts: () => 0 } }).then(r => console.log(r.instance.exports.main()))'
# → 640
```

各 codegen example の冒頭コメントに、想定される実行結果を記載。

## REPL session の記録

| ファイル | 内容 |
|---|---|
| [repl_session.md](repl_session.md) | REPL の使用例 |
