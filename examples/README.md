# Mere examples

Mere の動く `.mere` プログラム群 (61 本)。`dune exec ./bin/mere.exe -- examples/<file>.mere`
で interpreter 実行、`-c` / `-ll` / `-w` flag で C / LLVM IR / Wasm の 3
backend いずれかへ codegen。

**Phase 27 (2026-06-21) で 4 backend feature parity が完成**。16 examples が
**interp + C + LLVM + Wasm runtime** で diff = 0 PERFECT 一致 (印は ⭐)。

## カテゴリ

### 入門・言語の基本

| ファイル | 内容 |
|---|---|
| [hello.mere](hello.mere) | "Hello, world!" |
| [factorial.mere](factorial.mere) | 階乗 (recursive fn) |
| [fibonacci.mere](fibonacci.mere) | フィボナッチ |
| [fizzbuzz.mere](fizzbuzz.mere) | FizzBuzz |
| [mini_calc.mere](mini_calc.mere) ⭐ | 簡易計算プログラム |
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
| [state_machine.mere](state_machine.mere) ⭐ | variant + match transition (信号機 + 歩行者ボタン)、Phase 28.0 C1 |

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
| [cap_handler.mere](cap_handler.mere) ⭐ | `&shared write` で複数 handler が同じ Logger / Metrics を共有書き込み |

### モジュール / import

| ファイル | 内容 |
|---|---|
| [module_basic.mere](module_basic.mere) | `module M { ... }` + `M.f` 参照 |
| [module_nested.mere](module_nested.mere) | 入れ子 module + `open M;` |
| [module_scoping.mere](module_scoping.mere) | 2 module で同名 ctor を qualified 形式で disambiguate (Phase 18) |
| [import_demo.mere](import_demo.mere) | `import "./lib_list_ops.mere";` (要 `lib_list_ops.mere`) |
| [lib_list_ops.mere](lib_list_ops.mere) | import 用のライブラリ |

### 実用プログラム (16 examples が 4 backend で PERFECT 一致 ⭐)

| ファイル | 内容 |
|---|---|
| [arith_eval.mere](arith_eval.mere) ⭐ | mini functional lang (算術 + if + 1st-class fn + closure) を AST から評価 |
| [json_parser.mere](json_parser.mere) ⭐ | JSON パーサ (140 行) のセルフテスト |
| [s_expression.mere](s_expression.mere) ⭐ | S 式 (Lisp 風) parser + printer + 簡易 eval (`+ - * / = <`, `if`, `let`) |
| [csv_parser.mere](csv_parser.mere) ⭐ | CSV パーサ |
| [word_count.mere](word_count.mere) ⭐ | 単語カウント |
| [template_engine.mere](template_engine.mere) ⭐ | mustache 風 `{{KEY}}` 置換 engine (Map + StrBuf + str_index_of) |
| [json_writer.mere](json_writer.mere) ⭐ | StrBuf + 再帰 variant (json ADT) で compact / pretty-print |
| [inventory.mere](inventory.mere) ⭐ | 在庫管理 (Map + Vec + variant) |
| [word_freq.mere](word_freq.mere) ⭐ | 単語頻度カウンタ (Map + str_split + map_iter)、insertion order |
| [mini_shell.mere](mini_shell.mere) ⭐ | 簡易 shell batch evaluator (variant command + state) |
| [pipeline.mere](pipeline.mere) | region / view / cap / with を組合せた realistic な処理 (interp 主、3 backend 動作) |
| [todo_app.mere](todo_app.mere) | TODO リスト管理 (OwnedVec + Logger + vec_map / fold)、4 backend 対応 |
| [safe_div.mere](safe_div.mere) | `(int, str) result` を使った失敗を値で返すパターン |
| **Phase 28 (2026-06-21) 追加** | |
| [chained_parse.mere](chained_parse.mere) ⭐ | Result chain idiom (result_and_then / result_map / result_or_else)、D2 |
| [ini_parser.mere](ini_parser.mere) ⭐ | INI parser、Phase 27.1 Map insertion order dogfood、I1 |
| [regex_lite.mere](regex_lite.mere) ⭐ | minimal regex matcher (`. ^ $ * + ?` + concat + backtracking)、C5 |
| **Phase 29 (2026-06-22) 追加 — 大型 dogfood** | |
| [toy_sql.mere](toy_sql.mere) ⭐ | **1165 LoC toy SQL engine** (tokenizer + AST + parser + Catalog Map + Storage OwnedVec + INSERT / SELECT / WHERE / JOIN + 59 self-tests)。N1/N2/N3 dogfood で 4 件の codegen bug を発掘 + Phase 30 で fix |

### Q-010 collection 基本

| ファイル | 内容 |
|---|---|
| [vec_basics.mere](vec_basics.mere) | `'a Vec` の基本操作 (push / get / len / region 内) |
| [vec_vs_owned_vec.mere](vec_vs_owned_vec.mere) | `Vec[R, T]` (短命) vs `OwnedVec[T]` (長命) の対比 demo |
| [vec_higher_order.mere](vec_higher_order.mere) | `vec_iter` / `vec_map` / `vec_fold` / `vec_set` |
| [strbuf_basics.mere](strbuf_basics.mere) | `StrBuf[R]` の基本 |
| [map_basics.mere](map_basics.mere) | `Map[R, K, V]` の基本 |

### Q-010 collection codegen (3 backend)

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
dune exec ./bin/mere.exe -- -c examples/toy_sql.mere > /tmp/sql.c
clang /tmp/sql.c -o /tmp/sql && /tmp/sql

# LLVM IR → native binary
dune exec ./bin/mere.exe -- -ll examples/toy_sql.mere > /tmp/sql.ll
clang /tmp/sql.ll -o /tmp/sql && /tmp/sql

# Wasm (要 wabt / Node.js)。Phase 27.2 で scripts/run_wasm.js を追加
dune exec ./bin/mere.exe -- -w examples/toy_sql.mere > /tmp/sql.wat
wat2wasm /tmp/sql.wat -o /tmp/sql.wasm
node scripts/run_wasm.js /tmp/sql.wasm   # puts / read_file / write_file の env imports 付き
```

⭐ 印の 16 examples は **interp と 3 backend の出力が diff = 0 で一致**
することを `diff` で検証済 (Phase 27 完了 + Phase 28 追加 + Phase 30 codegen
fix 後維持)。

## REPL session の記録

| ファイル | 内容 |
|---|---|
| [repl_session.md](repl_session.md) | REPL の使用例 |
