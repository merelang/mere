# メモリ管理モデル (lang-ml)

Lang のメモリ管理戦略と、現状の `lang-ml` 実装での扱い、将来の予定をまとめる。設計の深堀りは別リポ `internal design notes` 〜 `14_view_types.md` を参照。

---

## 1. メモリ管理の比較

| 戦略 | 解放のタイミング | 代表例 | 強み | 弱み |
|---|---|---|---|---|
| **手動 (malloc/free)** | プログラマが毎回 `free` を呼ぶ | C | 最大のコントロール | use-after-free / leak が頻発 |
| **GC** | 実行時にゴミ収集器が判断 | OCaml、Java、Go、Python | 安全、楽 | 停止時間、メモリ overhead、リアルタイム性× |
| **所有権 (move + borrow)** | スコープを抜けたら自動 | Rust | コンパイル時保証、ゼロコスト | 循環参照・自己参照が辛い、学習コスト |
| **region (領域単位一括)** | 領域スコープ全体を一括破棄 | Cone、Vale、Cyclone、ML/Talpin 研究 | 高速 alloc / 一括解放、循環参照 OK | 領域寿命の設計が必要 |
| **stack 限定** | スタックフレーム末で | C の auto、Rust の `let` | ゼロコスト | サイズ・寿命の制約大 |

Lang は **これらを使い分け可能にする** 設計で、プログラマが明示的に戦略を選び、コンパイラが安全を検証する。

---

## 2. Lang のメモリ戦略 (5 つ)

設計 doc `01_memory_model.md` に基づく:

### ① `owned T` — 単独所有
値は一つの所有者を持ち、所有者がスコープを抜けると解放。Rust の `T` と同等。
```
let x: owned String = String.from("hello")
let y: owned String = x    // ムーブ。x は使えなくなる
```

### ② `&borrowed T` — 借用
所有権を移さず参照だけを渡す。Rust の `&T` / `&mut T` と同等だが、Lang は**借用注釈を細分化**する予定 (`&shared write` 等、設計 Q-004)。

### ③ `region R { ... }` — 領域単位
領域 R 内に置いた値は領域破棄時に一括解放。bump allocator。Trivial 型 (Drop 持たない) のみ置ける。**Q-008 で `arena` と統合済み**。

### ④ `view V[R] of T` — 自己参照ビュー (Q-009)
領域内で構築・immutable・ムーブ不可な「束ね型」。自己参照を `unsafe` なしで表現できる。
```
view DocumentView[R] of Document {
  own:    &R Document,
  tokens: &R [&R str],    // own.text の中を指す
}
```

### ⑤ `stack { ... }` — スタック限定
スタック上にのみ存在することを保証。ヒープ alloc なし。

---

## 3. なぜ region か (詳細)

### 解決する問題

Rust の所有権モデルが苦手とする領域:
- **自己参照構造体** (`Pin<T>` + `unsafe`)
- **グラフ・循環構造** (Rc/RefCell に逃げる)
- **一時的な大量 alloc** (個別 free のオーバーヘッド)
- **async + lifetime** (関数間で lifetime を引き回す)

region はこれらを「**領域単位の一括解放**」で解決する。

### 動作原理

```
region R {
  // R は bump allocator (ポインタ + サイズだけ持つ)
  let a = R.alloc(Node {...})    // ポインタ加算 1 回
  let b = R.alloc(Node {...})    // 同上
  a.next = b                      // 領域内なら参照自由
  b.next = a                      // 循環 OK
  // 計算...
}  // R のメモリ全体を一気に破棄、個別 destruct なし
```

### 典型用途

- **パーサ・コンパイラ**: 入力 1 つ = 1 region、AST 構築後に一括破棄
- **ゲームの 1 フレーム**: フレーム単位 region、フレーム終わりで全部捨てる
- **リクエスト処理**: 1 リクエスト = 1 region、レスポンス後に解放
- **トランザクション**: トランザクション境界で領域を持つ

### Trivial 制約

region に置けるのは「Drop を持たない型」(Trivial)。理由: 個別 destruct を呼ばずに一括解放するため。Drop を持つ型 (DB connection、ファイルハンドル等) は `with` 式で別管理する (Q-011 resolved):

```
with db = Database.connect(...) in
  region R {
    let nodes = ...   // R に大量 alloc
    process(db, nodes)
  }
  // R 破棄 (Trivial のみ、destruct なし)
// db.drop() (Drop を持つので個別解放)
```

---

## 4. lang-ml での現状 (2026-06-16)

### 動くこと (Phase 2: 構文 + 値式 + escape check + view 宣言 + 構築の region 強制 + field access の region 伝播)
- `region R { body }` 式 — R を region 名としてスコープに導入
- `&R T` 参照型 — region-tagged reference
- `&R v` 値式 — 値を region tag 付きで表現
- **escape check** — `region R { body }` の body の型に R が漏れたらコンパイルエラー
- `view V[R] of T { fields }` 宣言
- **view の region 強制** (Phase 2.3) — view 構築は region block 内のみ
- **view 値の type-level region tag + field access の region 伝播** (Phase 2.4) — view 値の型に構築時 region が `Name[R]` として埋め込まれ、field access / record update で実際の region に置換される。view 値そのものは escape check 対象 (region 外に出せない)

```
> region R { 42 }
- : int = 42

> fn (x: &R int) -> x
- : (&R int -> &R int)

> region R { let x = &R 5 in 42 }
- : int = 42                              // 内部で &R 使うが結果は int → OK

> region R { &R 5 }
ERROR: region escape: `&R int` cannot leave region `R`

> region R { region S { 100 } }            // ネスト OK
- : int = 100

> view Node[R] of int { value: int, next: int };
  region R { let n = Node { value = 1, next = 0 } in n.value }
- : int = 1                                // view 構築は region 内のみ

> view Slot[R] { item: &R int };
  region S { let s = Slot { item = &S 42 } in 100 }
- : int = 100                              // R は S に substitute される

> view Node[R] of int { value: int };
  let n = Node { value = 1 } in n.value    // region 外
ERROR: view Node must be constructed inside a region block
```

### まだ動かないこと

- **子 region (`region S of R { ... }`)** — 入れ子 region 間で promote
- **`with` + Drop の統合** — Drop あり cap のライフサイクル

### なぜ「構文のみ」なのか

`lang-ml` は OCaml で書いた**ツリーウォーキング interpreter**で、interpreter モードでは実際のメモリ管理は OCaml の GC が担っている。

**Phase 4 codegen (C出力) では region が実体ある bump allocator として動く** (2026-06-18 達成、Phase 4.17)。`region R { body }` が C runtime の `__lang_region` を init し、`&R v` (`R.alloc(v)` sugar) は region 内に bump-alloc して T* を返す、scope を抜けると一括 free。escape check (typer) と組合せて、region scope を超えるとメモリが解放されるが、その時点で `&R T` 値も型シグネチャ上漏れていないことが保証されている。詳細は [codegen.md](codegen.md) の Phase 4.17 を参照。

---

## 5. view 型 — 領域内の自己参照・循環構造

region は「同じ寿命を共有する箱」だが、その中で **データ同士が指し合う構造** (グラフ、リンクリスト、AST、JSON 木等) を安全に扱う機構が必要。これが **view 型**。

### 動機: 所有権モデルの苦手領域

```
// Rust だとほぼ書けない: 相互参照する 2 ノード
let a = Node { value = 1, next = ??? }  // ??? を b にしたい
let b = Node { value = 2, next = a }    // でも a も b を指したい
```

所有権言語では循環参照が原理的に困難 (`Rc<RefCell<T>>` への退避、`unsafe`、自前 arena 等)。region 内なら **全員が同じ寿命** なので循環 OK。view はこの「region 内の関係構造」を型として表現する。

### 3 公理 (Q-009 paper-validated)

| 公理 | 意味 |
|---|---|
| **immutable** | view 値は構築後変更不可。再代入も不可 |
| **region-scoped** | 必ずどこかの region R に属し、R の外に出せない (型に `[R]` が焼き付く) |
| **structural identity by region** | 同じ region 内の同型 view は同一視 — 循環参照が安全に成立する根拠 |

### record との違い

```
type Point = { x: int, y: int };       // 普通の record: 寿命は GC 任せ、領域非依存
view Node[R] of int { value: int };    // view: region R に縛られた束ね型
```

- record は単なるデータ。view は **region tag が型に焼き付いた** 構造 (`Node[R]` の `[R]`)
- フィールド型に `&R T` を持てる: `view Node[R] of int { next: &R Node[R] }` で自己参照
- view 値は `&R Node` 経由でしか触れない (構造の同一性は region 単位)

### なぜ「view」と呼ぶか

物理レイアウト (内部型 `of T`) とプログラマが触る型 (`Node`) を **別物として "見立てる"**。「内部は連番 int だが、view としては Node 構造体」のような表現を可能にする (将来的な機能)。

### 現状 (Phase 2.4、2026-06-17)

view 構築は **region block 内に限定**、宣言時の region パラメータ `R` は構築時に最内側の active region 名に置換、そして **view 値の型自体が `Name[R]` として region tag を持つ** 状態。field access / record update でも region が伝播し、view 値は escape check の対象になる。

```
view Node[R] of int { value: int, next: int };
region R { let n = Node { value = 1, next = 0 } in n.value }    // 1

view Slot[R] { item: &R int };
region S { 
  let s = Slot { item = &S 7 } in
  s.item                                                         // : &S int (R → S 伝播)
}                                                                // ERROR: &S int escape

region S { 
  let s = Slot { item = &S 7 } in
  let take_s = fn (x: &S int) -> 99 in
  take_s s.item                                                  // 99 (s.item は &S int)
}

region S { Cell { v = 1 } }    // ERROR: Cell[S] cannot leave region S
let n = Node { ... }            // ERROR: must be inside a region block
```

### 将来 Phase で厳格化される予定

- 同一 region 内の循環構築 (mutable な構築 phase + immutable な使用 phase の二段階)
- view 自身を `&R V` 経由でしか参照させない設計 (今は view 値が直接型に出る)
- Q-009 の "structural identity by region" 公理 (同型 view を同一視する厳密な意味論)

詳細設計は `internal design notes` (Q-009 resolved) を参照。

---

## 6. ロードマップ

### Phase 2 (中サイズ、~600-800 LoC、複数 slice) — 進行中
- [x] `&R v` 値式 (Phase 2.1、2026-06-16)
- [x] region escape check (`&R T` が R の外に漏れないか、Phase 2.1)
- [x] `view V[R] of T { ... }` 宣言 (Phase 2.2、2026-06-16、Q-009 paper-validated)
- [x] view の region 強制 (構築は region 内のみ + 構築時に R を active region に substitute、Phase 2.3、2026-06-16)
- [x] view 値の type-level region tag + field access / record update の region 伝播 + view の escape check (Phase 2.4、2026-06-17)
- [x] `R.alloc(v)` syntactic sugar (`&R v` 相当、parser が region_stack を見て desugar、Phase 2.5、2026-06-17)
- [x] `Trivial[R]` 型制約 (`drop type Name = ...` で Drop 型を宣言、region 配置時に Drop 型を含むと型エラー、Phase 2.6、2026-06-17)

### Phase 3 (大型、設計再開も必要)
- [ ] 借用注釈の細分化 `&shared write` / `&exclusive write` (Q-004 narrowed)
- [ ] 子 region と promote (`region S of R`、`R.promote(...)`)
- [ ] `Vec[R, T]` / `StrBuf[R]` 等の region 版 std 型 (Q-010 narrowed)
- [ ] `with` + Drop ordering の統合実装 (Q-011 resolved の機械化)

### Phase 4 (codegen)

進行中 — [codegen.md](codegen.md) 参照。

- [x] C codegen MVP (int + 算術 + if + let、2026-06-17)
- [x] 関数 lifting + 再帰 (factorial / fibonacci 動作、2026-06-17)
- [x] 文字列 + print + concat (hello world、2026-06-18)
- [x] str を取る / 返す関数 (2026-06-18)
- [x] tuple + AST 型注釈基盤 (2026-06-18)
- [x] record / variant / pattern match (2026-06-18、多相 monomorphization 含む)
- [x] closure conversion + 第一級関数 (2026-06-18)
- [x] **region runtime (bump allocator)** — メモリモデルの本領発揮、2026-06-18
- [ ] view runtime (`with` Drop 実行 / view 構築の region 化)
- [ ] LLVM IR or Wasm への移行

---

## 7. 設計コンテキスト (詳細)

具体的な設計判断は別リポ `internal design notes` (private) を参照:

| doc | 内容 | 状態 |
|---|---|---|
| `00_design_principles.md` | Lang 哲学・前提 | — |
| `01_memory_model.md` | 5 戦略の概観 | — |
| `02_json_parser_example.md` | region の典型ユースケース | — |
| `03_lifetime_and_mutability.md` | lifetime サブタイピング | — |
| `04_fundamental_tradeoffs.md` | 型注釈段階化等 | — |
| `08_effect_granularity.md` | Q-004 借用注釈細分化 | narrowed |
| `11_region_vs_arena.md` | Q-008 統合 | resolved |
| `12_drop_and_with.md` | Q-011 Drop ordering | resolved |
| `13_region_std_types.md` | Q-010 region 版 std | narrowed |
| `14_view_types.md` | Q-009 view 型 3 公理 | resolved |

---

## 8. 学術的ルーツ

| 文献 | 内容 |
|---|---|
| Tofte & Talpin (1997) | "Region-Based Memory Management" — region calculus の原典 |
| Cyclone (2002) | C + lifetime + region の研究言語 |
| Cone (2018-) | region をプリミティブにしたモダン言語 |
| Vale (2020-) | region + generational references |
| Mike Acton et al. | "Data-Oriented Design" — フレーム arena の実践例 |

---

要点: Lang は「**メモリの寿命をプログラム構造に対応づける**」設計で、所有権より緩く GC より厳密、循環参照可能で予測可能。`lang-ml` の現状は Phase 1 (構文のみ) で、本来の威力は Phase 2 以降の静的検証 + codegen で出る。
