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

interpreter 方式だと「Lang は OCaml の上で動く」状態。codegen で native binary を吐けるようになれば「Lang は Lang 単体で完結する言語」になる。設計目標の「ネイティブ (LLVM) + Wasm 両方」(`aidocs/00_design_principles.md`) のためにも必要。

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

#### 残りの Phase 5 作業

- 関数 lifting + recursion (Phase 4.2 に相当)
- 文字列対応 + printf 多態 (Phase 4.3-4)
- tuple / record / variant (Phase 4.5-7)
- closure 変換 (Phase 4.8-9)
- pattern match (Phase 4.10-15)
- show 汎用 builtin (Phase 4.12)
- region runtime / Drop / view (Phase 4.17-21)
- Wasm direct emit (`wasm-tools` 経由 or 直接 binary 出力) — LLVM 経由でも可

C codegen と LLVM codegen は parallel 実装。AST + 型注釈は共通基盤、emit 戦略のみ別 backend。

---

## 7. 参考

| doc | 内容 |
|---|---|
| [changelog.md](changelog.md) | slice ごとの変更履歴 |
| [memory-model.md](memory-model.md) | region/view/Trivial の概念。Phase 4 で実装が乗る予定の設計 |
| `lib/codegen_c.ml` | C codegen の実装本体 |
| `aidocs/00_design_principles.md` (private) | ネイティブ + Wasm 両対応の目標 |

---

要点: codegen は Lang を「設計通りの言語」にするための実装段階。設計 doc で「ネイティブ codegen が乗ったら...」と書いてた話を、ここから実際に作っていく工程。
