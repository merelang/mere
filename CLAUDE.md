# mere への指示

新プログラミング言語 (Mere) の OCaml 実装。

## 設計コンテキスト

設計判断の詳細は別リポ `aidocs` の以下を参照すること:

- `aidocs/projects/lang/00_design_principles.md` — 設計原則 (再開時の入口)
- `aidocs/projects/lang/01_memory_model.md` — メモリ管理 5 戦略
- `aidocs/projects/lang/02_json_parser_example.md` 〜 `04_fundamental_tradeoffs.md` — 思考記録
- `aidocs/projects/lang/05_effect_system.md` — エフェクトシステム未解決問題
- `aidocs/projects/lang/OPEN_QUESTIONS.md` — 進行中の未決事項
- `aidocs/projects/lang/trials/ocaml-expr/` — ホスト言語選定 trial (49 tests)

## 慣例

- コミットメッセージは日本語で簡潔に
- コミットに Co-Authored-By を含めない
- private リポなので個人情報・秘密情報の混入は警戒する (将来 public 化の可能性あり)
- OCaml モジュール名は `Lang_ml.*` (mere のハイフンを underscore 化)

## 着手予定

最初に通すべきは「最小の Mere 式を一行通す」ところ。trial (`aidocs/projects/lang/trials/ocaml-expr/`) の構造を雛形にしつつ、Mere 本来の構文に合わせて拡張する。
