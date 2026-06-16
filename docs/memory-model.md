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

### 動くこと (Phase 2: 構文 + 値式 + escape check)
- `region R { body }` 式 — R を region 名としてスコープに導入
- `&R T` 参照型 — region-tagged reference
- `&R v` 値式 — 値を region tag 付きで表現
- **escape check** — `region R { body }` の body の型に R が漏れたらコンパイルエラー

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
```

### まだ動かないこと

- **`r.alloc(v)` method 形式** — `&R v` の syntactic sugar (Phase 3 で sugar 化予定)
- **Trivial[R] 制約** — Drop あり型を region に置く時のエラー
- **`view V[R] of T` 宣言** — 自己参照ビュー型
- **子 region (`region S of R { ... }`)** — 入れ子 region 間で promote
- **`with` + Drop の統合** — Drop あり cap のライフサイクル

### なぜ「構文のみ」なのか

`lang-ml` は OCaml で書いた**ツリーウォーキング interpreter**で、実際のメモリ管理は OCaml の GC が担っている。region の本来の威力 (bump allocator、一括解放、cache 局所性) は**ネイティブ codegen** が乗ったときに出る。

Phase 1 は「型システム上の領域ラベル」を確立する段階で、Phase 2 で escape check 等の静的検証を、将来の codegen フェーズで実際のメモリレイアウトを実装する。

---

## 5. ロードマップ

### Phase 2 (中サイズ、~600-800 LoC、複数 slice) — 進行中
- [x] `&R v` 値式 (Phase 2.1、2026-06-16)
- [x] region escape check (`&R T` が R の外に漏れないか、Phase 2.1)
- [ ] `view V[R] of T { ... }` 宣言 (Q-009 paper-validated)
- [ ] `r.alloc(v)` メソッド呼び出し (`&R v` の sugar)
- [ ] `Trivial[R]` 型制約

### Phase 3 (大型、設計再開も必要)
- [ ] 借用注釈の細分化 `&shared write` / `&exclusive write` (Q-004 narrowed)
- [ ] 子 region と promote (`region S of R`、`R.promote(...)`)
- [ ] `Vec[R, T]` / `StrBuf[R]` 等の region 版 std 型 (Q-010 narrowed)
- [ ] `with` + Drop ordering の統合実装 (Q-011 resolved の機械化)

### Phase 4 (codegen)
- [ ] ネイティブ codegen (LLVM or Wasm)
- [ ] 実際の bump allocator 実装
- [ ] cache 局所性最適化

---

## 6. 設計コンテキスト (詳細)

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

## 7. 学術的ルーツ

| 文献 | 内容 |
|---|---|
| Tofte & Talpin (1997) | "Region-Based Memory Management" — region calculus の原典 |
| Cyclone (2002) | C + lifetime + region の研究言語 |
| Cone (2018-) | region をプリミティブにしたモダン言語 |
| Vale (2020-) | region + generational references |
| Mike Acton et al. | "Data-Oriented Design" — フレーム arena の実践例 |

---

要点: Lang は「**メモリの寿命をプログラム構造に対応づける**」設計で、所有権より緩く GC より厳密、循環参照可能で予測可能。`lang-ml` の現状は Phase 1 (構文のみ) で、本来の威力は Phase 2 以降の静的検証 + codegen で出る。
