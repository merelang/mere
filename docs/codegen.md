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

## 4. lang-ml での現状 (2026-06-18)

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
| Tuple | C struct (`tuple_int_str` 等を shape ごとに自動生成) + C99 compound literal、`fst` / `snd` builtin |
| Record | 単相 `type Point = { x: int, y: int }` → `typedef struct {...} Point;`、construction (`Point { x = 1, y = 2 }`) / field access / record update をサポート |
| Variant | 単相 `type Status = Ok \| Err of str` → tagged union (`typedef struct { int tag; union { ... } payload; } Status;`)、Constr emit に compound literal、match を ternary chain + statement expression に展開 (`P_constr` / `P_var` / `P_wild` / `P_tuple` sub、guard 不可) |
| 再帰 variant | 自己参照 payload を持つ variant (例: `type ilist = INil \| ICons of int * ilist`) は heap allocated + ポインタ表現 (`typedef ilist_node* ilist;`)。Constr が malloc して node を返し、match は `__scrut->tag` で dereference。tuple payload も `P_tuple (h, t)` で `.f0` / `.f1` を bind |
| 多相 variant の monomorphization | `type 'a list = Nil \| Cons of 'a * 'a list` 等の polymorphic variant を、AST + fn signatures から concrete instantiation を集めて instance ごとに specialized struct を emit (`list_int`, `opt_str` 等)。再帰性の判定も substitute 後の payload で行う。これで `[1, 2, 3]` リテラル + `'a list` の `sum` 等が native 実行可能 |
| 多相 record の monomorphization | `type 'a Box = { v: 'a }` 等を variant と同じパターンで specialize (`Box_int`, `Box_str` 等)。Record_lit emit が `.ty` から mono 名を引いて `((Box_int){.v = 42})` のように出力 |
| show 汎用 builtin | `show : 'a -> str` を AST から呼出ごとの引数型を集めて型ごとに specialized `show_T` C 関数を自動生成。int/bool/str/unit/tuple/record/variant (mono + 多相 instantiation) すべて対応。再帰 variant も対応 (collect は循環ガードあり、出力は `Cons (1, Cons (2, Nil))` 形式)。`asprintf` ベースで heap allocation |
| Closure (defunct) | 関数本体内の `let n = fn x -> body` を defunctionalization で top-level に lift。free vars を C function param に prepend、call site を rewrite。captures は int/bool/str/unit のみ (tuple/record/関数値 capture は未対応)。多段ネスト OK |
| First-class fn (Phase A + B) | `T1 -> T2` 型を closure struct (`{ void* env; T2 (*fn)(void*, T1); }`) で表現。各 top-level fn に `_closure_fn` adapter + `_as_value` const、anonymous Fun in expression position は env struct (heap-alloc) + adapter (`__anon_N_fn`) + closure construction として lift され、capture は `__env_self->name` に rewrite される。closure dispatch は `({ __auto_type __c = e; __c.fn(__c.env, x); })`。Direct call (known top-level の Var head) は引き続き直接呼出の高速パス |

### 動かないこと (今のところ Codegen_error で reject)

- inner-lifted fn (`let h = fn ...`) を VALUE として使う (現状は直接呼出のみ。anonymous Fun として書き直せば動く)
- closure capture の非プリミティブ型 (tuple/record の capture。closure 値 capture は OK)
- 多引数 curry (`fn x -> fn y -> ...` を `f x y` のように両方適用するときの中間段)
- float
- nested or-pattern (or 内に constructor/tuple/record)
- region / view / `&R T` / `with`
- `show` polymorphic builtin
- ほとんどの stdlib builtin (print と str_len のみ wired up)

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

slice ごとに **clang 経由で native binary 化して実行確認** している (例: factorial 10 → 3628800、`print (greet 5)` → "positive"、`fst ("hello", 42)` → "hello")。

詳細な変更履歴は [changelog.md](changelog.md) を参照。

---

## 6. ロードマップ

### Phase 4 で残る主要機能

| 機能 | 必要なもの |
|---|---|
| nested or-pattern | 内側 or の展開 |
| match guard | ternary chain ではなく if-else に切り替え |
| inner-lifted fn as value | `let h = fn ...` の `h` を値として使うときに closure-form を同時に生成 (現状は anonymous Fun として書き直す必要あり) |
| closure の複雑 capture | tuple/record/関数値の capture (現状は int/bool/str/unit のみ) |
| list / 任意の sum type | tagged union + heap alloc + ポインタ |
| polymorphic builtin (`show`) | dispatch table or 型ごとの specialization |
| region runtime | bump allocator、region pool、`with` の Drop list |
| 文字列の proper memory mgmt | malloc leak 解消、long-running program 対応 |

### Phase 5 (LLVM/Wasm 移行)

- LLVM IR 直接出力 (OCaml の llvm パッケージ or Rust の inkwell を FFI 経由)
- Wasm direct emit (`wasm-tools` 経由 or 直接 binary 出力)
- region runtime / GC 切り替えはここで本格化

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
