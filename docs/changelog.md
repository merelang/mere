# Changelog (lang-ml)

実装の主要なマイルストーンを slice 単位で記録 (新しいもの順)。詳細な commit メッセージは `git log` 参照。

---

## 2026-06-17

- **effect: `using [cap]` 構文糖** — `fn x using [logger] -> body` を `fn logger -> fn x -> body` に desugar (caps が outer-most curried args)。cap-passing スタイルで頻発する partial application 反復 (Q-003/Q-006 解の主要パターン) を緩和。型注釈可、複数 cap 可、通常 params との組合せ可。設計 doc `10_effect_trial_findings.md` の補助設計を実装。テスト 7 件追加 (661 passing)。examples/effects.lang も sugar 形で書き直し。
- **example: examples/effects.lang** — Capability passing パターンの実証例 (約 75 行)。`Logger` / `Metrics` cap 型を record として宣言、低階関数で直接使用 / バケツリレー / partial application で高階関数に渡すの 3 パターンを demo。設計 doc `05_effect_system.md` の「副作用 = ケイパビリティを値で渡す」が現状の Lang (HM + 関数引数 + record + curry) だけで動くことを実証 — エフェクトシステムのために新規構文を入れる必要なし。
- **region Phase 2.6**: `Trivial[R]` 制約 — `drop type Name = ...` で Drop 型を宣言できるように。`&R v` / `R.alloc(v)` / view フィールドの構築時に inner 型を walk して、`drop_types` registry に登録された型を含めば「Trivial[R] violated」型エラー。function 型は Trivial 扱い (closure 値自体は Drop ではない)。設計 doc 12_drop_and_with.md の案 (i) を構文化。`with` 式 + Drop 実行は Phase 3 で。テスト 7 件追加 (654 passing)。
- **region Phase 2.5**: `R.alloc(v)` syntactic sugar — `&R v` の method-call 風記法。parser が region_stack を保持し、`region NAME { ... }` の body 内では `NAME.alloc(EXPR)` を `Ref (NAME, EXPR)` に desugar。R がスコープ内 region でない場合は普通の field access として扱われるので、既存の `obj.alloc(...)` パターンは無影響。テスト 7 件追加 (647 passing)。
- **region Phase 2.4**: view 値の type-level region tag + field access / record update の region 伝播 — view 構築で `TyCon (name, [TyRef (target_region, TyUnit)])` を返すようにして value の型に region を埋め込み、`Field_get` / `Record_update` で view 名 + 埋め込み region を読み取って `subst_region` で field 型を実 region に置換。view 値そのものも escape check の対象になる (`Cell[S]` を region S の外に持ち出せない)。pp_ty に `Name[R]` 表記の heuristic を追加。テスト 5 件追加 (640 passing)。Phase 2.3 の "field access は raw R を返す" 既知制約を解消。

## 2026-06-16

- **region Phase 2.3**: view 構築の region 強制 + region パラメータ substitution — view を構築できるのは `region { ... }` block 内のみ。構築時に view 宣言の region パラメータ `R` が active region 名に置換され、フィールドに `&R T` がある場合、別名 region でも自動的にタグが揃う。typer に views Hashtbl と active_regions stack を追加、`Region_block` で push/pop、`Record_lit` で view dispatch + `subst_region`。memory-model.md の §5 「view 型」セクションと連携。
- **region Phase 2.2**: `view V[R] of T { fields };` 宣言 — Q-009 で確定した view 型を構文として導入。`view Node[R] of int { value: int, next: int };` のように region パラメータ `[R]` と (optional な) 内部型 `of T` を取り、`{ field: ty, ... }` でフィールドを宣言。Phase 2.2 では「region 付き record」として扱い (region は記録のみ、強制なし)、`Node { value = 1, next = 0 }` 構築と `n.value` アクセスが動く。意味論の厳格化 (region 内構築のみ、フィールド `&R T` 必須化) は将来 Phase で。設計 doc: `14_view_types.md` の 3 公理 (immutable / region-scoped / structural identity) のうち最初の 2 個を構文で表現する段階。
- **region Phase 2.1**: `&R v` 値式 + escape check — `&R 5` で値を region tag 付きの参照型に。`region R { body }` の出口で body の型に R が漏れていないかチェックし、漏れていればコンパイル時エラー。これで region は「型システム上のラベル」から「実際の安全性保証」に格上げ。
- **region / `&R T` Phase 1** — メモリモデル本丸への第一歩。`region R { body }` 式が R を region 名としてスコープに導入、`&R T` を参照型として AST/typer/eval に追加。Phase 1 は **構文** のみ — escape check や Trivial 制約、view 型、`r.alloc(v)` semantics は Phase 2 以降。設計 doc: 11_region_vs_arena.md / 14_view_types.md に対応。
- **網羅性検査 Phase 1** (Exhaustive モジュール) — bool と variant types の網羅性を warning として検出。`match Some x with | Some n -> ...` で「missing None」を stderr に出力、評価は継続。guarded arm は保守的に「カバーしてない」扱い、as-pattern と or-pattern は透過。lib/exhaustive.ml は Typer に依存しない逆方向 (Typer が register_variants を呼んで populate)。
- **数学 builtin 8 個** (`pi`/`e` 定数 + `sqrt`/`f_abs`/`f_neg`/`floor`/`ceil`/`round`) — float 算術が一通り揃った。
- **`int_max`/`int_min` 定数 builtin** — Lang 初の non-function builtin。
- **`time : unit -> float` + `exit : int -> 'a`** — Unix epoch とプロセス終了。
- **float 比較 4** (`f_lt`/`f_le`/`f_gt`/`f_ge`)。
- **CSV パーサ example** (~130 行、RFC 4180 縮小版)。
- **mini_calc.lang 拡張**: let バインディング + 変数 + env-based eval、shadowing 動作。
- **list_lib.lang** 追加: Lang 自身で書く list ユーティリティ 12 関数 (map/filter/fold_left/fold_right/length/rev/take/drop/range/replicate/for_all/any)。
- **float 型導入** — `TyFloat` プリミティブ + `Float_lit` (`1.5` リテラル) + V_float、変換 4 (`float_of_int` / `int_of_float` / `str_of_float` / `float_of_str`) + 算術 4 (`f_add` / `f_sub` / `f_mul` / `f_div`)。int と float の暗黙変換なし。既知制約「float なし」を解消。
- **file I/O** — `read_file : str -> str` / `write_file : str -> str -> unit`。CLI ツールが書けるように。`examples/word_count.lang` 追加。
- **`str_unescape` builtin** — `\n` `\t` `\r` `\\` `\"` `\/` を decode。JSON parser で escape 入り文字列対応。
- **文字リテラル `'X'`** — lexer のみ、長さ 1 の str に。tyvar `'a` と曖昧解消 (closing quote の有無)、`match c with | 'n' -> ...` でディスパッチ可。
- **list display 改善** — `to_string` で Cons/Nil chain を `[a, b, c]` 表示。JSON parser 出力が劇的に読みやすく。
- **ドキュメント整備** — README 刷新 + `docs/{tutorial, language-reference, stdlib-reference, patterns}.md` を新設 (1100+ 行)。
- **`divmod`** — Lang 初の tuple 戻り builtin (`int → int → (int * int)`)。
- **`square` / `cube`** — int → int の 2 乗 / 3 乗。
- **`sum_range`** — Gauss 公式で O(1) 総和。
- **`incr` / `decr`** — int → int の +1 / -1。
- **`iter_n`** — higher-order 副作用ループ。
- **多相 `const` / `flip`** — Lang 初の 3-quantified、higher-order 多相 builtin。`apply_value_ref` の forward-ref で実装。
- **多相 `id` / `swap` / `pair`** — tuple 操作の標準セット完成。
- **多相 `fst` / `snd`** — Lang 初の 2-quantified scheme builtin。
- **`try_or`** — Lang 初の error-handling builtin。
- **`fail` / `show`** — Lang 初の多相 builtin (scheme.quantified)。
- **as-pattern / or-pattern** — `(a, b) as p`、`| 1 | 2 | 3 -> ...` (binding names/型一致を typer 強制)。
- **構造的等価性** — `==` / `!=` がタプル / レコード / コンストラクタを再帰比較。
- **型エイリアス `type Name = T;`** — parse-time substitution、variant/record/alias を `|`/`of` で disambiguate。
- **関数合成 `<<` / `>>`** — 右結合、`|>` より高優先。
- **複数型パラメータ `('a, 'b) result`** — 既知制約「型パラメータ 1 個まで」を解消。
- **top-level let pattern** — `let _ = ...;`、`let (a, b) = ...;` 等が top-level でも、既知制約解消。
- **if without else** — `if cond then body` (body unit 型)。
- **マッチガード `| pat when expr -> body`** — 既知制約「ガードなし」を解消。
- **ブロック式 `{ e1; e2; eN }`** — Let(P_wild) chain への parser 糖。
- **リストパターン `[a, b, ...t]`** — リテラルと対称、parser 糖。
- **レコード更新 `{ p | x = 10 }`** — immutable update。
- **レコード型 `type Point = { x: int, y: int }`** — nominal records、多相、partial pattern。
- **相互再帰 `let rec ... and ...`** — 既知制約「相互再帰なし」を解消。
- **リスト リテラル `[1, 2, 3]`** — Cons/Nil chain への parser 糖。
- **パイプ `|>` / シグネチャエイリアス** — ergonomic 改善。
- **多引数型付き fn** — `fn (x: int, y: str) -> body` を curry に desugar。
- **stdlib 大量追加** — print_int / str_of_int / int_of_str / str_len / not / min / max / abs / pow / gcd / lcm / clamp / sign / even / odd / chr / ord / to_upper / to_lower / str_trim / str_rev / str_contains / str_count / str_replace / str_starts_with / str_ends_with / str_repeat / substring / char_at / is_digit / is_alpha / is_space / read_line / print_no_nl / print_err / assert / bool_of_str / str_compare 等多数。

---

## 2026-06-15 〜 06-16 (週前半)

- 主要な拡張: 演算子拡充 (`/ %` `<= >= > !=` `&& ||`)、let pattern、`with` 式、多相型 (`'a opt`)、タプル、sum types + パターンマッチ。
- 設計 doc: Q-008 (region/arena 統合)、Q-009 (view 型 3 公理)、Q-010 (region 版 std)、Q-011 (Drop 順序)。Lang のメモリモデル設計地図が完成。

---

## 2026-06-06 (着手日)

- OCaml 4-phase trial を経てホスト言語 OCaml 決定 (Q-001 resolved)
- 1 日で「整数 + let + bool + if + 関数 + 再帰 + 双方向型検査 + REPL」の最小コア完成 (24 tests)
- 文字列 + print + `++` 連結 + unit (slice 1)、REPL (slice 2)、複数 top-level decl (slice 8)
- **Hindley-Milner 型推論 + let-polymorphism**: Algorithm W + occurs check + generalize/instantiate を実装。注釈なし関数の推論、多相 id、多相 compose、let-poly 全て動作 (slice 9、29 tests)。

---

## 累計 (2026-06-16 時点)

- 設計 doc 4 件 (Q-008/009/010/011)
- 実装スライス **62 個**
- テスト **567 個** (初回 35 → 567、16 倍)
- builtin **68 個**
- 既知制約 **8 個解消** (相互再帰 / ガード / 多 type param / top-level let pattern / list display / char literal / file I/O / float)

---

## 未着手 (将来)

- **`&T` 参照** — 借用注釈 (`&shared write` 等) → メモリモデル本丸
- **`region R { ... }` / `view V[R] of T`** — Q-008/009 の実装
- **エフェクトシステム** — capability 型と effect 追跡
- **ネイティブ codegen** — LLVM or Wasm
- **網羅性検査 Phase 2** — int/str/float/tuple/record の精密な網羅性、redundancy check
- **行内 unicode / Unicode source** — 現状 ASCII 限定
- **モジュールシステム** — ファイル分割 + namespace
- **依存型 / refinement types** — 04_fundamental_tradeoffs.md の段階導入
- **row polymorphism** — record update に annotation 不要にする
- **多行 REPL** — REPL は単一行のみ
