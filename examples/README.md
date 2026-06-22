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
| **Phase 32 (2026-06-22) 追加 — FFI** | |
| [ffi_demo.mere](ffi_demo.mere) ⭐ | `extern fn <name>: <ty>;` で libc 関数 (getpid / getppid / setenv / getenv) を 4 backend から直接呼ぶ demo。multi-arg curried も対応 |
| **Phase 33 (2026-06-22) 追加 — Option / UX polish** | |
| [option_pipeline.mere](option_pipeline.mere) ⭐ | Option chain (option_map / option_and_then / option_default / option_is_some) を 3 段 lookup pipeline で dogfood。`option_and_then` を prelude に新規追加。D3 |
| [prime_sieve.mere](prime_sieve.mere) ⭐ | エラトステネスのふるい (Vec[R, bool] + vec_set + let rec loop、50 未満の素数 15 個を抽出)。H1 |
| [rate_limiter.mere](rate_limiter.mere) ⭐ | 固定 60 秒 window の rate limiter (2 つの Map で window_start + count を保持)。Phase 30.2 top-level global を 2 つ dogfood、4 backend で diff = 0。G5 |
| [stack_calc.mere](stack_calc.mere) ⭐ | RPN evaluator (tok variant + op_kind variant + `'a stk` linked list stack)。div-by-zero fallback、8 test cases。C4 |
| [markdown_toc.mere](markdown_toc.mere) ⭐ | Markdown heading 検出 + TOC 生成 (`#`/`##`/`###` … で depth 判定、region 内 StrBuf で組み立て)。G6 |
| [bank_account.mere](bank_account.mere) ⭐ | functional な銀行口座 (account variant + tx variant + state-passing replay + Vec[R, tx] ledger)。G4 |
| [graph_bfs.mere](graph_bfs.mere) ⭐ | 有向グラフの BFS (Map[int, int list] 隣接 + Map[int, bool] visited)。3 component シナリオを 4 backend で検証。H3 |
| **Phase 34 (2026-06-22) 追加 — float + libm** | |
| [math_demo.mere](math_demo.mere) ⭐ | float の四則演算 + sqrt / sin / cos / tan / f_pow / atan2 を combined で dogfood。Pythagorean / 三角恒等式 / 円周計算等。4 backend で diff = 0 |
| **Phase 35 (2026-06-22) 追加 — first-class builtin (DEFERRED §1.2 A1)** | |
| [factory_value.mere](factory_value.mere) ⭐ | nullary factory builtin (vec_new / owned_vec_new / strbuf_new / map_new) を first-class value として HOF に渡す。Phase 35 eta-wrap で 4 backend 対応 (MVP は HOF 引数注釈で ret_ty を固定する必要あり) |
| **Phase 36 (2026-06-22) 追加 — example batch** | |
| [histogram.mere](histogram.mere) ⭐ | Map[int, int] bucket カウンタ + 最頻 bucket 検出。10 単位 bucket に 20 件の観測値を accumulate、map_iter で線形 scan して mode を求める。Phase 36 で発掘した DEFERRED §1.13 (let-poly 'a 化) は **narrow value restriction を typer に入れて解消**、`(... : int)` 注釈不要に |
| [traffic_light.mere](traffic_light.mere) ⭐ | 最小 enum (`Red \| Yellow \| Green`) + `next` / `cycle` recursion。ADT 入門教材として最も単純な variant demo (C2) |
| [event_counter.mere](event_counter.mere) ⭐ | Map[event, int] — variant を Map key にする dogfood (Phase 15.15/15.16 機能の使用例)。Login / Click / Purchase / Logout の集計 (A2) |
| [html_builder.mere](html_builder.mere) ⭐ | StrBuf + tag 関数 helper で nested HTML 構築。region 内 StrBuf に `<ul><li>...</li></ul>` を畳み込む (B3) |
| [fallible_lookup.mere](fallible_lookup.mere) ⭐ | Map[str, str] 2 段を `result_and_then` で chain。user→email→role の連鎖 lookup と `result_default` の fallback パターン (D4) |
| [config_loader.mere](config_loader.mere) ⭐ | `key = value` 形式の text を Map[str, str] に load。コメント / 空行 / 前後 trim 対応。Phase 36 で `str_trim` / `str_starts_with` を 3 backend に追加したので、prelude の builtin を直接使う自然なコードに (A3) |
| [csv_writer.mere](csv_writer.mere) ⭐ | record list → CSV string via StrBuf。`,` `"` を含む field は `"..."` quote + 内部 `"` を `""` doubling。Phase 36 の `str_replace` 投入で 1 行に短縮 (B2) |
| [markdown_to_text.mere](markdown_to_text.mere) ⭐ | char_at 1 文字単位 scan + StrBuf で markdown 装飾 (`#` heading / `*` `_` 強調 / `` ` `` code / `>` quote) を剥がす。Phase 36 後は `str_starts_with` で `> ` 検出が短く書ける (B5) |
| [calendar_lite.mere](calendar_lite.mere) ⭐ | 年月から日曜始まりの月カレンダーを ASCII で出力。閏年判定 + Zeller の合同式 + StrBuf で 7 列 grid 組み立て (G3) |
| [matrix_2d.mere](matrix_2d.mere) ⭐ | 2D matrix を 1D OwnedVec[int] + `r * cols + c` index で表現。matrix add / transpose / pretty print。nested Vec[Vec[int]] は region escape が解けず本例では避けた (H2) |
| [borrow_chain.mere](borrow_chain.mere) | 同じ `&shared write R Logger` 借用を 3 つの helper を呼ぶ pipeline で再利用 (Phase 17.1 borrow tracking の demo)。**interp only** (`&shared write R` の codegen 未対応、borrow_modes.mere と同様、F3) |
| [cache_sim.mere](cache_sim.mere) ⭐ | capacity=3 の FIFO cache 擬似実装。`map_remove` / `owned_vec_set` を持たない制約下で、`alive` Vec + `evicted` Map を分けて FIFO eviction を表現。Phase 36 で発掘した DEFERRED §1.14 (lifted closure が global capture できない LLVM/Wasm bug) は **両 backend に load / global.get 経路を追加して解消**、自然なコードに戻った (A4) |
| [simple_query.mere](simple_query.mere) ⭐ | SELECT * FROM users WHERE col op value の最小実装 (tokenize / parse / execute、~150 LoC)。toy_sql.mere の 1165 LoC から大幅に削った教材版 (I3) |
| [caesar_cipher.mere](caesar_cipher.mere) ⭐ | 古典的シーザー暗号の encode / decode。`chr` / `ord` (Phase 36 新規) + char_at + StrBuf で 1 文字 transform、ROT13 / 負 shift / 大 shift も処理 |
| [fraction.mere](fraction.mere) ⭐ | 有理数 record `Frac { n, d }` の加減乗除 + 自動約分 (`gcd` 利用、Phase 36 新規)。canonical sign の正規化込み。注: 関数名は `divf` (C の `div` libc と衝突するため) |
| [roman_numerals.mere](roman_numerals.mere) ⭐ | 整数 ⇄ ローマ数字 (1..3999) の双方向変換。greedy で `(int * str) list` を消費する典型アルゴリズム + 文字単位パーサ |
| [password_strength.mere](password_strength.mere) ⭐ | パスワード強度 0..5 採点 (長さ / digit / lower / upper)。`is_digit` / `ord` / `char_at` の 1 文字単位走査 |
| [brackets_balance.mere](brackets_balance.mere) ⭐ | 括弧の対応チェック (`()` `[]` `{}`)。linked-list `'a stk` で stack を表現、char_at で 1 文字 scan + match で push/pop。非括弧文字は skip |
| [morse_code.mere](morse_code.mere) ⭐ | A-Z + 0-9 をモールス符号に encode / decode。Map[str, str] 2 つで往復辞書を構築。Phase 36 dogfood で C codegen の 2 つの摩擦 (§1.15 深い list literal、§1.16 region 内 strbuf escape) を発掘 |
| [luhn_check.mere](luhn_check.mere) ⭐ | クレジットカード番号の Luhn チェックサム。char_at + is_digit + ord で 1 桁 int 変換、非数字 (space / hyphen) skip 対応 |
| [tic_tac_toe.mere](tic_tac_toe.mere) ⭐ | 3x3 ボード + 勝敗判定 (8 ライン)。OwnedVec[cell] + variant + match の組合せ、5 シナリオを pretty print。Phase 36 dogfood で発掘した C codegen の §1.17 (`type result` rebind が List.combine で落ちる) は **後勝ち dedupe で解消** |
| [palindrome.mere](palindrome.mere) ⭐ | 回文判定。大文字小文字 / 記号 / スペースを無視、`str_rev` (Phase 36) + `to_lower` + `is_alpha` の組合せ |
| [anagram.mere](anagram.mere) ⭐ | 2 文字列がアナグラム関係か判定。Map[str, int] で文字頻度を集計、`map_iter` で両 freq を線形 scan |
| [base_conv.mere](base_conv.mere) ⭐ | int を 2/8/16 進文字列に変換 + 逆変換 (round-trip 確認)。`chr` / `ord` / `str_rev` / `char_at` の数値処理 dogfood、負数 prefix `-` 対応 |
| [rps_game.mere](rps_game.mere) ⭐ | じゃんけんの勝敗判定 + best-of-5 集計。variant + nested match の 3x3 dispatch demo |
| [scoreboard.mere](scoreboard.mere) ⭐ | Map[str, int] スコア集計 → 降順ランキング (selection scan)。Phase 36 dogfood で Phase 30.2 top-level global の初期化順 bug を発掘 (DEFERRED §1.18) |
| [eight_queens.mere](eight_queens.mere) ⭐ | N-Queens (N=4..8) の全解列挙 + backtracking。`safe` 関数 + mutually recursive `try_col` / `solve`、最初の 3 解を print。N=8 で 92 解 |
| [collatz.mere](collatz.mere) ⭐ | コラッツ予想の軌跡を文字列化 + step 数計測。`even` (Phase 36 新規) + recursive 関数の demo。1..20 で最も step 数が多い n も探索 |
| [bin_tree_traversal.mere](bin_tree_traversal.mere) ⭐ | 二分木 (recursive variant `btree`) の pre/in/post-order 走査 + height / count。`render` で walker fn を HOF で受ける |
| [knapsack.mere](knapsack.mere) ⭐ | 0/1 ナップサック問題を memoize DP で解く。Map[str, int] で `(i, w) → max_value` をキャッシュ、選択アイテムの復元 (`reconstruct`) も実装 |

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
