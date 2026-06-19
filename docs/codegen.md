# コード生成 (codegen)

Lang のコード生成戦略と、現状の `lang-ml` 実装での扱い、将来の予定。設計の核となる **メモリモデル / エフェクトシステム** の "威力発揮" が codegen に依存しているため、Phase 4 として段階的に進めている。

---

## 1. codegen とは

ソース言語の AST (or 型付け済み AST) を **別の言語または機械命令** に変換する処理。

```
       parser              typer             codegen
ソース  ───▶  AST   ───▶  typed AST   ───▶  ターゲット
"1+2"        Bin(+,1,2)    .ty = TyInt        "1 + 2" (C)
                                              "i32.add" (Wasm)
                                              "addq" (x86 アセンブリ)
```

言語処理系の最終段。Lang-ml は parser → typer → **eval** (tree-walking interpreter) で完結していた状態から、**eval と並列で codegen** を持つ実装に拡張中。

---

## 2. なぜ必要か

### 性能

| 方式 | 実行モデル |
|---|---|
| tree-walking interpreter | AST を毎回 traverse、env lookup、closure 値の box/unbox、OCaml GC 経由 |
| C codegen (今) | C コンパイラが生成した native binary、レジスタ割当て、関数呼出は call 一発 |
| LLVM/Wasm (将来) | さらに最適化 (inlining、dead code elim、loop unroll) が乗る |

### 配布

interpreter 方式: `lang-ml` バイナリ + `program.lang` を一緒に配布が必要  
codegen 方式: `program.lang` を compile すれば単体実行可能なバイナリが手に入る

### メモリモデルの威力発揮

Lang の **region / view / Trivial[R] / `with` Drop** の設計 ([memory-model.md](memory-model.md)) は今、型レベルのラベルとしては動くが、実体は OCaml の GC が裏で管理している。

```
// 現状 (interpreter):
region R { let n = R.alloc(Node { ... }) in ... }
// 実態: OCaml heap に普通の object として alloc、GC が拾う

// codegen 後:
// region R は bump allocator を push/pop し、scope を抜けたら一括解放
// Drop の LIFO 実行も Drop list の機械化された逆順走査になる
```

memory-model.md で書いた通り:
> region の本来の威力 (bump allocator、一括解放、cache 局所性) は**ネイティブ codegen** が乗ったときに出る

### 自立した言語になる

interpreter 方式だと「Lang は OCaml の上で動く」状態。codegen で native binary を吐けるようになれば「Lang は Lang 単体で完結する言語」になる。設計目標の「ネイティブ (LLVM) + Wasm 両方」(`internal design notes`) のためにも必要。

---

## 3. Lang の codegen 戦略

### 多段アプローチ

| Phase | ターゲット | 状態 | 理由 |
|---|---|---|---|
| 4 (今) | **C** | 進行中 | 中間言語として最も簡単、clang/gcc が手元にある |
| 5 (将来) | **LLVM IR** | 未着手 | 最適化機会↑、native + JIT 両方サポート |
| or | **Wasm** | 未着手 | ブラウザ実行 + WASI で自立バイナリ |

### なぜ C を経由するか

- LLVM / Wasm を直接吐くより簡単 (C は「移植可能な assembly」と呼ばれる)
- C コンパイラが既に手元にある (clang/gcc が macOS/Linux 標準)
- region runtime や GC ヘルパを C で書いて FFI 接続できる
- 後で LLVM IR に切り替える際の「正解」になる (出力比較ができる)

### AST 型注釈基盤 (Phase 4 第五で導入)

`Ast.expr` に `mutable ty : ty option` を追加し、`Typer.infer` が各ノードに推論結果を記録するように。これにより codegen がノードごとの型を直接参照でき、tuple shape や fn signature の推論が cleanly に書ける。LLVM/Wasm 移行時にも同じ基盤が使える。

---

## 4. lang-ml での現状 (2026-06-18、Phase 4 を 16 slice まで進めた段階)

interpreter で書ける Lang プログラムの**主要構文ほぼ全て**が native compile + 実行可能。テスト 761 件 passing、E2E では factorial / fibonacci / 連結リスト sum / make_adder closure / 多相 variant + record / pattern match (nested / guard / or) 等が clang 経由で動く。

### 動くこと

| カテゴリ | サポート |
|---|---|
| プリミティブ | int / bool / str / unit |
| 算術 | `+ - * / %` (int)、`-` (Neg) |
| 比較 | `== != < <= > >=` (int → int 0/1) |
| 論理 | `&& \|\|` (C の short-circuit にそのまま) |
| 文字列 | リテラル / `++` 連結 / `print` / `str_len` |
| 制御 | `if-then-else` (C ternary)、`let` (GCC/Clang `__auto_type` で型を吸収) |
| 関数 | top-level fn の lifting (`let f = ...` / `let rec f = ... and g = ...`)、forward decl で自己再帰 / 相互再帰、str を取る / 返す関数 |
| Region | `region R { body }` を bump allocator (`__lang_region`) で実装、`&R v` (および `R.alloc(v)` sugar) が region 内に値を allocate、scope を抜けると一括解放。escape check (typer) + 実体ある runtime で region の本領発揮 |
| with Drop | `with c = v in body` を codegen、scope 末で `c.close ()` 相当を自動呼出 (Drop 型に `close: unit -> unit` field があれば)。複数 with は AST が nested なので自然に LIFO 順 |
| View | `view V[R] of T { ... }` を region 上の bump alloc + ポインタ表現 (`V*`) に。Record_lit が `__lang_region_alloc(&__region_R, sizeof(V))` + copy + ptr return、field access は `->`。view 値の lifetime は region scope と一致 |
| Tuple | C struct (`tuple_int_str` 等を shape ごとに自動生成) + C99 compound literal、`fst` / `snd` builtin |
| Record | 単相 `type Point = { x: int, y: int }` → `typedef struct {...} Point;`、construction (`Point { x = 1, y = 2 }`) / field access / record update をサポート |
| Variant | 単相 `type Status = Ok \| Err of str` → tagged union (`typedef struct { int tag; union { ... } payload; } Status;`)、Constr emit に compound literal、match を ternary chain + statement expression に展開 (`P_constr` / `P_var` / `P_wild` / `P_tuple` sub、guard 不可) |
| 再帰 variant | 自己参照 payload を持つ variant (例: `type ilist = INil \| ICons of int * ilist`) は heap allocated + ポインタ表現 (`typedef ilist_node* ilist;`)。Constr が malloc して node を返し、match は `__scrut->tag` で dereference。tuple payload も `P_tuple (h, t)` で `.f0` / `.f1` を bind |
| 多相 variant の monomorphization | `type 'a list = Nil \| Cons of 'a * 'a list` 等の polymorphic variant を、AST + fn signatures から concrete instantiation を集めて instance ごとに specialized struct を emit (`list_int`, `opt_str` 等)。再帰性の判定も substitute 後の payload で行う。これで `[1, 2, 3]` リテラル + `'a list` の `sum` 等が native 実行可能 |
| 多相 record の monomorphization | `type 'a Box = { v: 'a }` 等を variant と同じパターンで specialize (`Box_int`, `Box_str` 等)。Record_lit emit が `.ty` から mono 名を引いて `((Box_int){.v = 42})` のように出力 |
| show 汎用 builtin | `show : 'a -> str` を AST から呼出ごとの引数型を集めて型ごとに specialized `show_T` C 関数を自動生成。int/bool/str/unit/tuple/record/variant (mono + 多相 instantiation) すべて対応。**`'a list` だけ特別 case 化 (`[1, 2, 3]` 形式で出力)**、その他の再帰 variant は `Cons (1, Cons (2, Nil))` 形式。`asprintf` ベースで heap allocation |
| Closure (defunct) | 関数本体内の `let n = fn x -> body` を defunctionalization で top-level に lift。free vars を C function param に prepend、call site を rewrite。captures は int/bool/str/unit のみ (tuple/record/関数値 capture は未対応)。多段ネスト OK |
| First-class fn (Phase A + B) | `T1 -> T2` 型を closure struct (`{ void* env; T2 (*fn)(void*, T1); }`) で表現。各 top-level fn に `_closure_fn` adapter + `_as_value` const、anonymous Fun in expression position は env struct (heap-alloc) + adapter (`__anon_N_fn`) + closure construction として lift され、capture は `__env_self->name` に rewrite される。closure dispatch は `({ __auto_type __c = e; __c.fn(__c.env, x); })`。Direct call (known top-level の Var head) は引き続き直接呼出の高速パス |

### 動かないこと (今のところ Codegen_error で reject)

- inner-lifted fn (`let h = fn ...`) を VALUE として使う (現状は直接呼出のみ。anonymous Fun として書き直せば動く)
- closure capture の非プリミティブ型 (tuple/record の capture。closure 値 capture は OK)
- float (`f_add` 等の float builtin と `Float_lit` / `f_neg` 全般)
- nested or-pattern (or 内に constructor / tuple / record)
- ほとんどの stdlib builtin (`print` / `str_len` / `fst` / `snd` / `show` のみ wired up)
- 文字列・closure env・variant node の GC (現状 malloc leak、短時間実行向け)

### CLI

```sh
# inline expression を C source に
dune exec ./bin/main.exe -- -ce '1 + 2 * 3'

# ファイルを C source に
dune exec ./bin/main.exe -- -c examples/sample.lang > sample.c

# clang で native binary に
clang sample.c -o sample
./sample
```

---

## 5. Phase 4 で進めてきた slice

| slice | 内容 | 動くもの |
|---|---|---|
| 4.1 | C codegen MVP | int + 算術 + if + let |
| 4.2 | 関数 lifting + recursion | factorial / fibonacci / 相互再帰 |
| 4.3 | 文字列 + print + ++ | hello world |
| 4.4 | str を取る / 返す関数 + `str_len` | `let exclaim = fn s -> s ++ "!"` |
| 4.5 | tuple + AST 型注釈基盤 | tuple-returning fn まで |
| 4.6 | record (単相) | `type Point = { x: int, y: int }` の construction / field / update |
| 4.7 | variant + match (単相、簡易 pattern) | `type Status = Ok \| Err of str`、`match` を ternary chain に展開 |
| 4.8 | closure conversion (defunctionalization) | 関数本体内の `let h = fn ... in ...` を top-level に lift、free vars を param に prepend、call site rewrite |
| 4.9-a | first-class fns (Phase A、top-level fn as value) | `T1 -> T2` を `closure_T1_T2` struct に、top-level fn に adapter + `_as_value` const、HOF が closure 引数を受け取って `.fn(.env, x)` で dispatch |
| 4.9-b | first-class fns (Phase B、anonymous Fun + captures) | anonymous Fun in expression position を heap-allocated env struct + adapter + closure 構築に lift、capture を `__env_self->name` に rewrite、curried HOF (`apply f x = f x`)・`make_adder` クロージャまで動作 |
| 4.10 | 再帰 variant + P_tuple pattern | 自己参照 variant (`type ilist = INil \| ICons of int * ilist`) を heap-allocated node + ptr typedef に、Constr が malloc、match が `->` dereference、tuple sub-pattern を `.f0 / .f1` bind。連結リストの `sum` が clang 経由 native 実行可能 |
| 4.11 | 多相 variant の monomorphization | `type 'a opt = None \| Some of 'a` / `type 'a list = Nil \| Cons of 'a * 'a list` 等の polymorphic variant を、AST + fn signature から concrete instantiation を収集して instance ごとに specialized struct (`opt_int`, `list_int` 等) を emit。`[1, 2, 3]` リテラル + `'a list` の sum が動く |
| 4.12 | show 汎用 builtin | `show : 'a -> str` を呼出ごとに引数型から `show_T` を specialize。int/bool/str/unit/tuple/record/variant (mono + 多相 instantiation + 再帰) 対応。生成は `asprintf` ベース、循環ガード付き |
| 4.13 | 多相 record の monomorphization | `type 'a Box = { v: 'a }` 等を type ごとに specialize (`Box_int`, `Box_str`)。Record_lit emit が `.ty` から mono 名を引く |
| 4.14 | 複雑な pattern (P_int / P_str / P_bool / P_record / nested / P_as) | Match の pattern compilation を `compile_pattern` で fully recursive に書き直し。各 pattern を (test, bindings) に分解、constructor 内に constructor/tuple/record を nest 可能、record pattern も destructure 可能 |
| 4.15 | or-pattern + match guard | `\| pat1 \| pat2 -> body` を pre-pass で複数 arm に flatten (両 branch が同じ name set を bind する制約は typer が保証)、guard は arm の bindings スコープ内で評価して false ならフォールスルー |
| 4.16 | `'a list` show を `[1, 2, 3]` 形式に + 変種 payload の tuple shape 収集 | `type 'a list` を special-case して `show` が `[1, 2, 3]` を出力。変種 payload 内のタプル形 (`tuple_int_list_int` 等) を tuple shape 収集に含めて、空リスト等で payload に Cons が出てこなくても struct がちゃんと emit されるように |
| 4.17 | **region runtime** (bump allocator) | `region R { body }` を C で実装: `__lang_region` 構造体 (`{ char* base; char* top; size_t cap; }`) + `__lang_region_init/alloc/free` ヘルパを emit、`region R { ... }` は init + body 評価 + free のシーケンス、`&R v` は region 内に bump alloc して T* を返す。`c_type_of (TyRef _ inner)` を `inner*` (ポインタ型) に。escape check (typer) と組合せて region scope を抜けるとメモリが解放される — **メモリモデルが「型レベルラベル」から「実体ある bump allocator」になった** |
| 4.18 | `with` Drop 実行 + typedef 順序整理 | `with c = v in body` を codegen 化、scope 末で `c.close.fn(c.close.env, 0)` を自動呼出 (close field がある Drop 型のみ)。typedef 構造を「forward decl 全部 → closure typedef → struct body 全部」に再編成して、record / variant に `closure_T1_T2` 型の field (例: Drop type の `close: unit -> unit`) があっても closures が record 定義を function-pointer return として参照できるように |
| 4.19 | view 構築の region 化 (bump alloc + ポインタ表現) | view 値を `V*` (region 内のポインタ) として codegen。`is_view_type` ヘルパ、`c_type_of` で view 名を `V*` に、Record_lit が view の場合は `__lang_region_alloc(&__region_R, sizeof(V))` + 中身 copy + ポインタ return、Field_get が view 値に対して `->` を使う。view 値の lifetime は region scope に縛られる (Phase 2.1 escape check + region runtime と組合せ) |
| 4.20 | **closure env の default region 化** | program-lifetime arena (`__lang_default_region`) を file-scope に追加、`main` の先頭で 4MB 初期化 / 末尾で free。anonymous closure の env struct alloc を `malloc` から `__lang_region_alloc(&__lang_default_region, ...)` に切替。closure はユーザの `region R { ... }` を越えて生きうるため別系統の arena が必要 — bump alloc 化により closure 1 個あたりの alloc コストが下がり、`main` 抜けるときに一括解放 (valgrind clean) |
| 4.21 | **文字列 / 再帰 variant node も default region 化** | 残っていた 2 つの malloc サイトを default region に統合。`__lang_str_concat` の `malloc(la + lb + 1)` → `__lang_region_alloc(&__lang_default_region, la + lb + 1)`、再帰 variant の Constr emit (`Cons (h, t)` 等) の `malloc(sizeof(T_node))` → `__lang_region_alloc(&__lang_default_region, sizeof(T_node))`。emit 順を `region_runtime_helpers → str_concat_helper` に並べ替えて、str_concat helper が default region を参照できるように。これで C 側の malloc は **region の base buffer 確保** (`__lang_region_init` 内) のみになり、ユーザ可視な alloc サイトはすべて bump arena 上。`main` 終了で `__lang_region_free(&__lang_default_region)` が一括解放、valgrind clean |

slice ごとに **clang 経由で native binary 化して実行確認** している (例: factorial 10 → 3628800、`print (greet 5)` → "positive"、`fst ("hello", 42)` → "hello")。

詳細な変更履歴は [changelog.md](changelog.md) を参照。

---

## 6. ロードマップ

### Phase 4 で残る主要機能

| 機能 | 必要なもの |
|---|---|
| nested or-pattern | constructor 内の or を展開 |
| inner-lifted fn as value | `let h = fn ...` の `h` を値として使うときに closure-form を同時に生成 (現状は anonymous Fun として書き直す必要あり) |
| closure の複雑 capture | tuple / record の capture (現状は int / bool / str / unit / 関数値 のみ) |
| float | `Float_lit` / `f_add` 等の float builtin を C `double` + `%g` 系に |
| long-running program 対応 | 現状は arena 一括解放方式 (`main` 終了まで持つ)。長時間動くプロセス用には、show output 等の一時文字列を捨てられる sub-arena か、proper GC が要る |
| 残りの stdlib builtin | 約 80 個の builtin (sqrt, str_replace, ...) を C 対応 |

### Phase 5 (LLVM/Wasm 移行)

| slice | 内容 | 動くもの |
|---|---|---|
| 5.1 | **LLVM IR MVP** (自前 textual IR 生成) | int / bool / 算術 / 比較 / 論理 / Neg / If / Let (P_var) / Var / Annot を LLVM IR に変換、`-ll` / `-lle` CLI flag、`@printf` 経由で結果出力、`clang out.ll` で native binary。phi node 経由の If、icmp 経由の比較、zext で bool → i32 拡張 |
| 5.2 | **関数 lifting + recursion** | top-level `let f = fn x -> ...` および `let rec f = fn x -> ... and g = fn y -> ...` を `define iXX @f(iYY %x) { ... }` として lift。`App (Var name, arg)` を `call iZZ @name(iYY %arg)` に compile (known top-level fn のみ direct call、第一級関数は別 slice)。各 fn ごとに register/label counter をリセットして SSA 名衝突を回避。LLVM IR は同モジュール内で前方参照可なので C のような forward decl は不要。factorial 10 = 3628800、fibonacci 15 = 610、is_even 7 = 0 (相互再帰) が clang 経由で native 実行 |
| 5.3 | **文字列対応 + ++ + print + str_len + str-取る/返す関数** | `TyStr` → LLVM `ptr` (opaque pointer)。`Str_lit s` を private constant global (`@.str_N = private constant [N x i8] c"...\00"`) に lift、値として global シンボルを直接使う。`Bin (Concat, a, b)` を `call ptr @__lang_str_concat(ptr %a, ptr %b)` に。`__lang_str_concat` を LLVM IR 内に inline 定義 (malloc + strlen + memcpy + GEP + store 0 で組み立て)。`print s` を `call i32 @puts(ptr %s)` + 値は 0、`str_len s` を `call i64 @strlen(ptr %s)` + `trunc i64 ... to i32` に。`main_format_of` に `TyStr → ("ptr", "%s")` 対応、`@.fmt_s` global を生成。str を取る/返す関数も自然に動く (`define ptr @f(ptr %s)` 形式)。動作確認 (clang 経由 native): `print "Hello, LLVM!"` → "Hello, LLVM!"、`"hello, " ++ "world!"` → "hello, world!"、`str_len "Hello, world!"` → 13、`let greet = fn name -> "Hello, " ++ name ++ "!" in print (greet "world")` → "Hello, world!" |
| 5.4 | **tuple + AST 型注釈基盤の LLVM 版** | tuple を LLVM named struct `%tuple_int_str = type { i32, ptr }` に lower。shape ごとに `collect_tuple_shapes` が AST + fn signature を walk して使われた tuple 型を集めて typedef を emit。`Tuple [e1; e2; ...]` を `insertvalue` chain (`undef` から始めて各要素を `insertvalue %T %prev, Tn vn, idx`) に。`fst` / `snd` を `extractvalue %tuple_X %p, 0/1` に。nested tuple (`((1,2), 3)` → `%tuple_tuple_int_int_int`) も自動生成。tuple-arg / tuple-return 関数も自然に lower (`define %tuple_int_int @split(ptr %s)`、`define i32 @sum_pair(%tuple_int_int %p)`)。動作確認 (clang 経由 native): `let p = (1, 2) in fst p + snd p` → 3、`let p = ("hello", 42) in print (fst p)` → "hello"、`let split = fn s -> (s, str_len s) in print (fst (split "hello"))` → "hello"、`((1,2), 3)` の nested 和 → 6 |
| 5.5 | **record (単相)** | monomorphic record (`type Pt = { x: int, y: int }`) を LLVM named struct (`%Pt = type { i32, i32 }`) に lower。`collect_record_names` で AST + fn signature を walk して使われた record 型を全部集める (`r_params = []` なものだけ、多相は別 slice)。`record_fields` / `field_index` で `Typer.records` から field 順序を引いてくる。`Record_lit` は宣言順に `insertvalue` chain (source field 順は宣言順と違っても OK)、`Field_get` は `extractvalue %R %p, idx`、`Record_update` は base に対する `insertvalue` chain。record を取る / 返す関数も自然に lower (`define %Pt @mk(i32 %n)`)。compile_to_c と同じ infer_program ヘルパ経由で Typer.records を populate。動作確認 (clang 経由 native): `let p = Point { x = 3, y = 4 } in p.x + p.y` → 7、`Pt { x = 3, y = 4 } | x = 100` で x * y → 400、`let mk = fn x -> Pair { a = x, b = str_len x } in print ((mk "hello").a)` → "hello"。多相 record は引き続き Codegen_error |
| 5.6 | **variant + match (単相、payload 型 1 つ)** | 単相 variant を LLVM named struct に lower: 全コンストラクタが nullary なら `%V = type { i32 }`、payload がある場合は `%V = type { i32, T }` で T は全 payload-bearing コンストラクタが共有する単一の payload 型 (異なる型なら Codegen_error)。`variant_tags` ハッシュテーブルで constructor → 整数 tag を保持。`Constr cname (arg)` を `insertvalue %V undef, i32 tag, 0` → optional `insertvalue %V %t0, T arg, 1` の chain で構築。`Match` は scrutinee から `extractvalue %V %s, 0` で tag を取り出し、各 arm を `icmp eq i32 %tag, N` + `br i1` で順次テスト (P_constr / P_var / P_wild のみ)、fallthrough は `@abort()` + `unreachable`、最後に全 arm の結果を `phi` で merge。pattern 内で payload bind があれば `extractvalue %V %s, 1` で payload register を作って bindings に入れる。動作確認 (clang 経由 native): `match LG with | LR -> 0 | LG -> 1 | LB -> 2` → 1、`match LErr "x" with | LOk -> 0 | LErr m -> str_len m` → 1、`let v = ISome 42 in match v with | INone -> 0 | ISome n -> n` → 42。guard / 多相 variant / 再帰 variant / nested pattern / or-pattern は引き続き Codegen_error |
| 5.7-a | **first-class top-level fn** | `T1 -> T2` 型を `%closure_T1_T2 = type { ptr, ptr }` (env, fn ptr) として lower。`collect_arrow_types` で AST + fn signature を walk して使われた arrow 型を全部収集、`emit_closure_typedef` で typedef を生成。各 top-level fn に env-ignoring adapter `define T2 @<name>_closure_fn(ptr %env_unused, T1 %x) { ret T2 @<name>(T1 %x); }` を自動生成。`Var name` を値位置で評価する際、env に shadowing がなく `toplevel_fn_names` に登録済なら、`insertvalue %closure_T1_T2 undef, ptr null, 0` + `insertvalue ..., ptr @<name>_closure_fn, 1` の chain で inline に closure value を構築。indirect App (App の head が known top-level でないケース) は `extractvalue %closure %c, 0/1` で env/fn を取り出し、`call T2 %fn_ptr(ptr %env, T1 %arg)` で dispatch (LLVM の opaque pointer 経由なので fn pointer 型はそのまま渡せる)。Direct call は引き続き Phase 5.2 の `call T2 @name(T1 %arg)` 高速パス。`current_var_types` で fn body 内の polymorphic Var 型を resolve_fn_types 由来の concrete 型から recover (let-poly 後の param が `'a` のまま残るケース対策)。動作確認 (clang 経由 native): `let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc` → 6、`let apply2 = fn f -> f (f 5) in apply2 inc` → 7。anonymous Fun (inner `fn x -> ...`) と closure-with-captures は別 slice |
| 5.7-b | **anonymous Fun + closure-with-captures** | 内部 `fn x -> ...` を expression position で扱う: AST から free vars を計算 (`free_vars` ヘルパ、bound 名を除外)、`current_var_types` に登録済な名前にフィルタ (globals / builtins / top-level を除外)。capture ごとに型を `current_var_types` から取得、`%anon_N_env = type { T1, T2, ... }` の env struct typedef を生成、`anon_N_fn` adapter を `pending_closures` キューに積む。構築 site では `malloc(sizeof(%anon_N_env))` (`getelementptr null` + `ptrtoint` で sizeof) で env を確保、各 capture を `getelementptr` + `store` で env field に書き込み、`insertvalue %closure undef, ptr %env, 0` + `insertvalue ..., ptr @anon_N_fn, 1` で closure value を作る。`emit_anon_adapter` (emit_program で `pending_closures` を drain して呼出) の adapter body では、entry で各 capture を `getelementptr` + `load` で env_self から取り出して fresh register に入れ、それを使って Fun の元 body を emit。`current_expected_ty` を追加して、AST の Fun.ty が polymorphic な場合に parent context の型を fallback として使う (let-poly 後の `fn f -> fn x -> f (f x)` で内側 Fun の型が `'a -> 'a` のまま残るケースが解決)。Let case で current_var_types に value 型を加える。動作確認 (clang 経由 native): `let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10` → 15 (capture)、`let twice = fn f -> fn x -> f (f x) in twice inc 5` → 7 (curried HOF)、`let apply = fn f -> fn x -> f x in apply (fn n -> n * 3) 7` → 21 (anon Fun as arg)、`let compose = fn f -> fn g -> fn x -> f (g x) in ((compose inc) dbl) 5` → 11 (3 段ネスト)。env は今 `malloc` で leak — default region 化は将来の slice |
| 5.8 | **default region runtime + closure/文字列 alloc を region 経由に** | LLVM 版で C codegen の Phase 4.17 + 4.20 + 4.21 に相当する作業を一括: `%__lang_region = type { ptr, ptr, i64 }` 構造体定義 + `@__lang_default_region` を file-scope global として宣言 + `__lang_region_init/alloc/free` の 3 つのヘルパ関数を LLVM IR 内に inline 定義。`__lang_region_alloc` は 8 byte aligned bump pointer 方式 (`(n + 7) & -8`)。`@main` の冒頭で `__lang_region_init(@__lang_default_region, 4194304)` (4 MB)、末尾で `__lang_region_free`。`__lang_str_concat` の `malloc` を `__lang_region_alloc(@__lang_default_region, ...)` に置換。closure env (anonymous Fun) の `malloc(sizeof)` も同様に region 経由に。残る `malloc` は region init 内部の base buffer 確保のみで、`main` 終了時に `__lang_region_free` が一括で `@free` する。動作確認 (clang 経由 native): `make_adder`/`twice`/`compose` などの closure や `"hello, " ++ "world"` などの concat が全部動き、生成 IR 内の `malloc` 呼出は region init 内の 1 箇所のみ。テスト 8 件追加 (855 passing)。LLVM backend のメモリモデル整備が C backend に追いついた |
| 5.9 | **多相 variant / record の monomorphization** | `type 'a opt = None \| Some of 'a` 等の polymorphic variant や `type 'a Box = { v: 'a }` 等の polymorphic record を、AST + fn signature から concrete instantiation を収集して instance ごとに specialized struct (`%opt_int`, `%Box_str` 等) を emit。`polymorphic_variants` / `polymorphic_records` ハッシュテーブルで宣言を保留、`collect_mono_instances` で AST walk して使われた `(name, args)` ペアを発見、`mono_variant_instances` / `mono_record_instances` に蓄積。`subst_params` / `subst_variants` で param→arg 置換、`mono_variant_name n args` / `mono_record_name n args` で specialized 名 (`opt_int`, `Box_str` 等)。`emit_mono_variant_typedef` / `emit_mono_record_typedef` で substituted な field/payload を `llvm_ty_of` で具体化して typedef 生成。`llvm_ty_of (TyCon (n, args))` を `polymorphic_variants` / `polymorphic_records` の登録名に対しては mono name にマップ。`Constr` / `Record_lit` / `Field_get` / `Record_update` / `Match` emit が、scrutinee/literal の `.ty` から mono name を引いてくる (substituted な fields/payload で型を解決)。`Exhaustive.type_variants` + `Typer.constructors[*].params` から poly variant の params を復元、`Typer.records.r_params` から poly record の params を取得。動作確認 (clang 経由 native): `type 'a opt = LNone \| LSome of 'a; match LSome 42 with | LNone -> 0 | LSome n -> n` → 42、`type 'a Box = { v: 'a }; let b = Box { v = 42 } in b.v` → 42、両方 type で specialize: `let bi = Box { v = 42 } in let bs = Box { v = "hi" } in str_len bs.v + bi.v` → 44 (`%Box_int` と `%Box_str` の両方が emit)。再帰 polymorphic variant (`'a list`) は recursive variant 対応が要るので Phase 5.10 で |
| 5.10 | **再帰 variant + P_tuple sub-pattern** | 自己参照 payload を持つ variant (`type ilist = INil \| ICons of int * ilist`、`'a list = Nil \| Cons of 'a * 'a list` 等) を heap-allocated node + ptr 表現に切替。`recursive_variants` set で名前を track、`variant_is_recursive` (source-level) と `mono_variant_is_recursive` (substituted instance) で判定、emit_program 内で declaration 登録時 + mono instance 収集時の 2 段で populate。`emit_variant_typedef` / `emit_mono_variant_typedef` は recursive なら `%V_node = type { i32, T }` (on-heap node) を emit、value 型は `ptr` (`llvm_ty_of` が recursive_variants 登録名なら `ptr` を返す)。`Constr` 再帰の場合は `__lang_region_alloc` で node を allocate、`getelementptr` + `store` で tag + payload を書き込み、ptr を return。`Match` 再帰の場合は scrutinee の ptr に対して `getelementptr` + `load` で tag を取得、各 arm の payload も同様に load。pattern compile で `P_tuple` sub-pattern (`Cons (h, t)`) を payload tuple struct の `extractvalue` 連鎖に展開。`pattern_var_types` で pattern bind 名の concrete 型を current_var_types に追加 (polymorphic 再帰呼出で `'a list` のままにならないように)、Match scrutinee 型を Var なら current_var_types から fallback、App 直接呼出 arg 型も同様。typedef 順序を 1) collect mono instances + 2) mark recursive + 3) tuple/record/variant typedef emit (recursive_variants が tuple emit に効く) に並び替え。動作確認 (clang 経由 native): `type ilist = INil \| ICons of int * ilist; sum (ICons (1, ICons (2, ICons (3, INil))))` → 6、`type 'a list = Nil \| Cons of 'a * 'a list; sum [1,2,3,4,5]` → 15、`length ["a","b","c","d"]` → 4。テスト 5 件追加 (867 passing) |
| 5.11 | **複雑な pattern (P_int / P_str / P_bool / P_unit / P_record / P_as / or / guard) + nested ctor** | Phase 4.14 + 4.15 相当を LLVM 版で実装。`compile_pat` を fully recursive な `(test_cond, bindings, var_types)` 関数として書き直し、各パターンを LLVM IR の icmp / strcmp / extractvalue / load + bind に分解。P_int は `icmp eq i32`、P_bool は `icmp eq i1`、P_str は `@strcmp` + `icmp eq i32 result, 0`、P_unit は constant true。P_record は declared field 順に `extractvalue` + sub-pattern を recursive call。P_as は `inner` を compile した上で whole value を name に bind。P_tuple は各要素を `extractvalue` で取り出して sub-pattern recurse。P_constr の sub-pattern は payload extract 後に compile_pat に再帰、nested constructor (例 `Cons (SS 5, _)`) も `Some (P_constr (...))` 経由で自然に展開。複数の sub-test は `and_cond` ヘルパで `and i1` 連鎖。or-pattern は `expand_or` で arms を pre-flatten (typer が両 branch の bound 名一致を保証)。guard は arm の bindings スコープ内で評価し、true なら body へ、false なら同 arm の next_label へフォールスルー (= 次の arm を試す)。`@strcmp` を runtime_decls に追加。動作確認 (clang 経由 native): `match 3 with | 0 -> 100 | 1 -> 200 | _ -> 300` → 300、`match "hello" with | "hi" -> 1 | "hello" -> 2 | _ -> 9` → 2、`match Cons (SS 5, Nil) with | Nil -> 0 | Cons (NN, _) -> 1 | Cons (SS n, _) -> n` → 5、`match Pt { x = 3, y = 4 } with | Pt { x = a, y = b } -> a + b` → 7、`match (1, 2) with | (a, b) as p -> fst p + snd p + a + b` → 6、`match LCgB with | LCgA | LCgB -> 1 | LCgC -> 2` → 1 (or-pattern)、`match 7 with | n when n < 5 -> 100 | n when n < 10 -> 200 | _ -> 300` → 200 (guard)。テスト 8 件追加 (875 passing) |
| 5.12 | **show 汎用 builtin** | `show : 'a -> str` を呼出ごとに引数型から `show_<ty_tag>` を specialize、`@asprintf` 経由で型ごとに dedicated 関数を生成。`collect_show_types` で AST + fn signature を walk して `App (Var "show", arg)` を発見、`add_show_type` が引数型 + 依存型 (tuple elem / record field / variant payload) を再帰登録 (循環ガード: 既登録なら skip → 再帰 variant の `'a list` で無限ループしない)。`emit_show_fn` が `show_types` の各 entry に specialized fn を emit: int → `@asprintf("%d", x)`、bool → `select i1` で `@.s_true` / `@.s_false`、str → `@asprintf("\"%s\"", x)`、unit → const `@.s_unit`、tuple → 各要素の `show_T` を call して `@asprintf("(%s, ..., %s)", ...)` で合成、record → 各 field の `show_T` を call して `@asprintf("Type { f = %s, ... }", ...)` で合成、variant → tag dispatch (icmp eq + br i1 + phi) → 各 ctor で nullary なら `@.s_ctor_<name>`、payload あれば payload を再帰 show して `@asprintf("Ctor %s", ...)` で合成、再帰 variant も `getelementptr` + `load` で tag/payload 取得して同じ structure で。Format string と ctor 名 string は emit_program 冒頭で必要な分だけ pre-register。`App (Var "show", arg)` を `call ptr @show_<ty_tag arg.ty>(arg)` に dispatch。動作確認 (clang 経由 native): `show 42` → "42"、`show "hi"` → "\"hi\""、`show true` → "true"、`show (1, "hi")` → "(1, \"hi\")"、`show (SS 42)` → "SS 42"、`show (Pt { x = 3, y = 4 })` → "Pt { x = 3, y = 4 }"、`show (Cons (1, Cons (2, Cons (3, Nil))))` → "Cons (1, Cons (2, Cons (3, Nil)))"。テスト 9 件追加 (884 passing)。`'a list` の special-case `[1, 2, 3]` 形式は今後の slice |
| 5.13 | **Region_block + Ref + with Drop + view 構築 + Unit_lit** | Lang のメモリモデル機能を LLVM backend で一括実装 (Phase 4.17 region runtime の user-side + 4.18 + 4.19 相当)。`Region_block (R, body)` を `alloca %__lang_region` + `__lang_region_init(ptr, 1MB)` + body + `__lang_region_free` に compile、`current_regions : (name, ptr_reg)` で region 名 → SSA レジスタの対応を track。`Ref (R, v)` (`&R v`) を inner 評価 + sizeof (`getelementptr null` + `ptrtoint`) + `__lang_region_alloc` + `store` で region buffer に書き込み、`ptr` を返す。`With (c, v, body)` (`with c = v in body`) を `let c = v` + body 評価 + body 後に v の record に `close: unit -> unit` field があれば `c.close.fn(c.close.env, 0)` で auto-invoke (`extractvalue` 3 段)、body の値を返す。`Record_lit` で name が `Typer.views` 登録名なら view 構築: `e.Ast.ty` の `TyCon (V, [TyRef (R, ...)])` から region R を取得、宣言順に `insertvalue` で record value を組み立て、`__lang_region_alloc` + `store` で region buffer に書き込み、`ptr` を返す。`Field_get` で inner type が view (`is_view_type`) なら `getelementptr %V, ptr %x, i32 0, i32 idx` + `load` で field 取得。`llvm_ty_of` に `TyRef _ → ptr` と `TyCon (n, _) when Typer.views n → ptr` を追加。`Unit_lit` を `i32 0` に対応。動作確認 (clang 経由 native): `region R { let x = &R 5 in 42 }` → 42、`region R { let pair = &R (1, 2) in 99 }` → 99、`type Pt = { x: int }; region R { let p = &R Pt { x = 42 } in 100 }` → 100、`drop type Conn = { id, close }; with c = mk 7 in c.id * 10` → "close 7\n70"、`view Cell[R] of int { v: int }; region R { let c = Cell { v = 7 } in c.v }` → 7。テスト 7 件追加 (891 passing) — **LLVM backend がメモリモデル全機能をカバー、C backend (Phase 4.21) と完全並列に到達** |
| 5.14 | **`'a list` の show を `[a, b, c]` 形式に special-case** | C codegen の Phase 4.16 相当。`emit_show_fn` の variant branch の前に `Ast.TyCon ("list", [elem_ty])` for recursive list を special-case。Nil 単独なら `"[]"`、Cons は alloca/load/store + ループ (`loop_test` / `loop_body` / `loop_iter` / `loop_end` ラベル) で先頭から走査、各要素を `show_<elem_tag>` で文字列化して間に `", "` を挟みつつ `__lang_str_concat` で連結、最後に `"]"` を追加。`@.s_lbracket` / `@.s_rbracket` / `@.s_comma_space` を pre-register。副次として `add_show_type` で polymorphic TyCon に出会ったとき mono_variant_instances / mono_record_instances にも登録 (show が変な型を使うだけのケースで mono instance が漏れる問題に対処)、`collect_tuple_shapes` に「mono variant 払い (substituted payload) を walk する」処理を追加 (`int list` の payload `(int, int list)` の tuple shape が AST 上に Cons なしでも emit されるように)。動作確認 (clang 経由 native): `show [1, 2, 3]` → `[1, 2, 3]`、`show (Nil : int list)` → `[]`、`show ["hello", "world"]` → `["hello", "world"]`。テスト 4 件追加 (895 passing) |

### Phase 6 (Wasm backend)

C / LLVM 両 backend が完成形 (Phase 4 / 5 並列カバー) になり、design 目標の三本目 (Wasm) に着手。Phase 5 と同様 textual format (WAT) を emit、`wat2wasm` (wabt) で `.wasm` binary に、Node.js の `WebAssembly.instantiate` で実行確認するパイプライン。

| slice | 内容 | 動くもの |
|---|---|---|
| 6.1 | **Wasm (WAT) MVP** (スタックベース emit) | int / bool / 算術 / 比較 / 論理 / Neg / If / Let (P_var) / Var / Annot を WAT に変換。`-w` / `-we` CLI flag、stack-based emission (LLVM の SSA とは違い operand を順に push して opcode 1 つでスタック消費 + 結果 push)。`If` を WAT の `if (result i32) ... else ... end` ブロックに、`Let (P_var)` を `(local i32)` 宣言 + `local.set N` / `local.get N` に。比較は `i32.lt_s` / `i32.eq` 等、bool は i32 ワイド化。動作確認 (wat2wasm + Node.js WebAssembly): `let a = 10 in let b = 20 in if a + b > 25 then a * b else 0` → 200、`if 3 > 2 then 100 else 200` → 100、`let x = 5 in x * x + 1` → 26、`true && (false || true)` → 1。テスト 14 件追加 (909 passing) |
| 6.2 | **関数 lifting + recursion** | top-level `let f = fn x -> ...` および `let rec` を `(func $f (param i32) (result i32) ...)` として lift。Phase 5.2 と同形の `fn_skel` / `lift_fn_skels` / `find_concrete_arrow` / `resolve_fn_types` を codegen_wasm に並列実装。`emit_fn_def` で各 fn を独立した locals / instrs scope として emit (param は slot 0、let bindings は slot 1, 2, ...)。`App (Var name, arg)` を `<arg push>; call $name` の連続に compile (`toplevel_fn_names` 登録済の名前のみ direct call)。Wasm は同モジュール内で前方参照可なので C のような forward decl は不要 — 相互再帰もそのまま動く。動作確認 (wat2wasm + Node.js): `factorial 10` → 3628800、`fibonacci 15` → 610、`is_even 7` (相互再帰) → 0。テスト 5 件追加 (914 passing)。クロージャ / 第一級関数 / 文字列 / record / variant 等は後続 slice |
| 6.3 | **文字列対応 + str_len + ++ + print + str-取る/返す関数** | 文字列を Wasm の linear memory に置くアーキテクチャ。`(memory (export "memory") 1)` で 1 page (64 KB) メモリを宣言 + export、`(global $__lang_bump (mut i32) (i32.const N))` で bump pointer (mutable global)。`Str_lit` を `(data (i32.const offset) "...\00")` の data セグメントに lift、`wasm_string_escape` で `\HH` エスケープ、値としては i32 offset を `i32.const N` で push。`$__lang_strlen` (block/loop で null byte 探索) と `$__lang_str_concat` (strlen 2 回 + 2 つの copy loop + null 終端 + bump 更新) を WAT 内に inline 定義。`print s` を host import `(import "env" "puts" (func $puts (param i32)))` 経由で host (Node.js) に委譲、値は i32 0。`str_len s` を `call $__lang_strlen`、`++` を `call $__lang_str_concat` に。str を取る / 返す関数も自然に動く (Wasm 上では str も i32 として扱うので signature 変更不要)。動作確認 (wat2wasm + Node.js with `puts: (off) => decode memory at off`): `str_len "Hello, world!"` → 13、`str_len ("hello, " ++ "world!")` → 13、`print "Hello, Wasm!"` → "Hello, Wasm!"、`let greet = fn name -> "Hello, " ++ name ++ "!" in print (greet "world")` → "Hello, world!"。テスト 9 件追加 (923 passing) |
| 6.4 | **tuple** | tuple を linear memory にレイアウト: 各要素 4 bytes (Lang 上の int / bool / str はすべて i32 / offset)、base offset を fresh local に保存して **bump pointer を即座に advance** (reserved 領域として確保) → 各要素を `i32.store offset=N*4` で base からの相対位置に書き込み → 最後に base を push。bump を先に進めるのが重要 — nested tuple や `++` の内側 emit がさらに bump を advance するので、後で reserve すると領域がオーバーラップする (Phase 6.4 開発中に nested で 22 (offsets 衝突) を返したのを fix)。`fst` / `snd` を `i32.load offset=0` / `offset=4` に dispatch、tuple-arg / tuple-return 関数も自然に動く (tuple は i32 offset なので signature 変更不要)。動作確認 (wat2wasm + Node.js): `let p = (1, 2) in fst p + snd p` → 3、`let p = ("hello", 42) in print (fst p)` → "hello"、`((1, 2), 3)` の nested 和 → 6、tuple-arg fn `sum_pair (10, 20)` → 30。テスト 5 件追加 (928 passing) |
| 6.5 | **record (単相)** | tuple と同じ linear memory レイアウト。`Record_lit (name, fields)` を `Typer.records.r_fields` の **宣言順** に store (source の field 順が違っても再構成) — bump を 4*N 即時 advance、各 field を `i32.store offset=i*4` で書き込み、最後に base を push。`Field_get` は field 名から index を引いて `i32.load offset=idx*4`。`Record_update` は新しい buffer を bump で確保、各 field について update に含まれていれば新値を、なければ source から `i32.load offset=...` でコピー、新 buffer の base を返す。record を取る/返す関数も自然に動く (record も i32 offset)。動作確認 (wat2wasm + Node.js): `type Pt = { x: int, y: int }; let p = Pt { x = 3, y = 4 } in p.x + p.y` → 7、`{ p | x = 100 }.x * .y` → 400、record-returning fn `let mk = fn x -> Pair { a = x, b = str_len x } in print ((mk "hello").a)` → "hello"。多相 record / view は引き続き Codegen_error。テスト 4 件追加 (932 passing) |
| 6.6 | **variant + match (単相、payload 型 1 つ)** | Variant も linear memory にレイアウト: nullary-only なら `{ i32 tag }` (4 bytes)、payload があれば `{ i32 tag, i32 payload }` (8 bytes、payload は i32 / offset)。`variant_tags : (cname, int)` ハッシュテーブルを `Exhaustive.type_variants` から populate (emit_program 冒頭で iter)、`variant_payload_ty` で全 payload-bearing コンストラクタが共有する単一型を検出。`Constr` を `i32.store offset=0` (tag) + 必要なら `i32.store offset=4` (payload) + base push に compile。`Match` は scrut を local に保存して tag/payload を `i32.load offset=0/4` で取り出し、各 arm を `local.get tag; i32.const N; i32.eq; if (result i32) ... else ... end` の入れ子チェーンに compile、fallthrough は `unreachable` で trap (typer exhaustiveness 想定)。Pattern: P_constr / P_var / P_wild、payload bind は payload local slot を使う。動作確認 (wat2wasm + Node.js): `type Color = R | G | B; match G with | R -> 0 | G -> 1 | B -> 2` → 1、`type Stat = Ok | Err of str; match Err "boom" with | Ok -> 0 | Err msg -> str_len msg` → 4、`let v = ISome 42 in match v with | INone -> 0 | ISome n -> n` → 42。テスト 6 件追加 (938 passing)。guard / 多相 / 再帰 / nested pattern / or-pattern は引き続き Codegen_error |
| 6.7 | **first-class fn + closure (top-level + anonymous Fun + captures)** | Wasm 特有の制約 — 関数ポインタはメモリ ptr ではなく **function table の index**、間接呼出は `call_indirect (type $sig)` 経由でテーブル経由。`(type $cl (func (param i32) (param i32) (result i32)))` を module 冒頭で宣言、`(table N funcref)` + `(elem (i32.const 0) $f1_closure ...)` で adapter 群を index 0 から登録。`closure value` は memory に置く 8 bytes `{ env_offset, fn_table_idx }`。各 top-level fn `f` に env-ignoring adapter `(func $f_closure (param i32) (param i32) ... local.get 1; call $f)` を自動生成して table に追加、`fn_closure_table_idx : (name, int) Hashtbl` に index を記録。`Var name` を value position で評価する際、`fn_closure_table_idx` 登録済なら closure value (`env=0, fn_idx=N`) を memory に alloc して push。indirect App は closure を local に save → load env / arg / load fn_idx → `call_indirect (type $cl)`。anonymous Fun は `free_vars` で自由変数計算 → `locals` 登録済 (= 親 fn の local slot) のみ capture → fresh adapter `anon_N_fn` を table 登録 → `pending_closures` キューに積む → 構築 site で env を memory に alloc (`{ c1, c2, ... }`)、closure value を alloc → push。adapter body の entry で env から各 capture を `i32.load offset=N*4` で local slot に load してから body を emit。emit_program で pending を drain loop で処理 (nested adapter で追加 pending が出る場合に対応)。`pattern_vars` + `free_vars` ヘルパを追加。動作確認 (wat2wasm + Node.js): `apply inc` → 6 (first-class top-level fn)、`(make_adder 5) 10` → 15 (capture)、`compose inc dbl 5` → 11 (3 段ネスト + 2 capture)、`twice inc 5` → 7 (curried HOF + 多相)。テスト 7 件追加 (945 passing) |

#### 残りの Phase 6 作業

- 関数 lifting + recursion (Phase 4.2 / 5.2 に相当): Wasm の `(func)` + `call $name` への lift
- 文字列対応: linear memory + WASI または独自 string runtime
- tuple / record / variant: linear memory にレイアウト + load/store
- closure 変換: env + fn pointer (Wasm では `table` + `call_indirect`)
- pattern match / show / region runtime

C codegen と LLVM codegen と Wasm codegen は parallel 実装。AST + 型注釈は共通基盤、emit 戦略のみ別 backend。

---

## 7. 参考

| doc | 内容 |
|---|---|
| [changelog.md](changelog.md) | slice ごとの変更履歴 |
| [memory-model.md](memory-model.md) | region/view/Trivial の概念。Phase 4 で実装が乗る予定の設計 |
| `lib/codegen_c.ml` | C codegen の実装本体 |
| `internal design notes` (private) | ネイティブ + Wasm 両対応の目標 |

---

要点: codegen は Lang を「設計通りの言語」にするための実装段階。設計 doc で「ネイティブ codegen が乗ったら...」と書いてた話を、ここから実際に作っていく工程。
