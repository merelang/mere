# contrib/site — Mere docs site SSG (Static Site Generator) MVP

Mere 自身で書かれた docs site builder。 markdown 集合 → HTML pages + index
を生成する。 公開時に「Mere の docs は Mere 自身で生成」 と謳う dogfood の
中心的 lib。

## ファイル

| file | 内容 | 行数 |
|---|---|---|
| `build.mere` | SSG 本体 (CLI script、 input/output dir を args で受ける) | 約 145 行 |

## 使い方

```sh
dune exec mere -- contrib/site/build.mere <input_dir> <output_dir>
# 例:
dune exec mere -- contrib/site/build.mere docs _site
# → docs/ 配下の *.md を _site/*.html に変換 + _site/index.html 生成
```

引数省略時は `docs/` → `_site/` がデフォルト。

## MVP scope

| 機能 | 状態 |
|---|---|
| input dir の `*.md` 列挙 | ✓ (`list_dir` + `Path.has_ext`) |
| markdown → HTML 変換 | ✓ (`MarkdownHtml.render`) |
| page title 抽出 (先頭 `# Title` 行 or ファイル名) | ✓ |
| 共通 template (header / nav / footer) | ✓ (inline 100 行の CSS) |
| navigation menu (全 pages を横並び) | ✓ |
| `index.html` (page list) | ✓ |
| output dir 自動作成 | ✓ (`mkdir_p`) |

## 非 MVP (将来 Phase)

- front matter (YAML 縮小) で metadata
- `[X](foo.md)` → `<a href="foo.html">X</a>` link rewrite (現状 markdown converter が link 未対応のため pass-through)
- syntax highlight (code block)
- asset copy (`style.css` / images の static copy)
- 検索 index (lunr.js 風)
- multi-version / i18n
- live reload / dev server
- code block (` ``` ` fenced) 対応 (MarkdownHtml の課題)

## 構成

```
contrib/site/
  build.mere    # CLI script (本 lib)
  README.md     # 本ファイル
```

`import` で参照:
- `../markdown/to_html.mere` (`MarkdownHtml.render`)
- `../path/path.mere` (`Path.join` / `basename` / `drop_ext` / `has_ext`)

## backend サポート

| backend | 状態 |
|---|---|
| interp | ✓ |
| C | ✓ (Phase 44 で list_dir / mkdir_p を C codegen に追加) |
| LLVM | ✗ (list_dir / mkdir_p が LLVM 未実装) |
| Wasm | ✗ (list_dir / mkdir_p が Wasm 未実装) |

MVP は **interp 経由で実行** がメイン。 native binary 化したい時は C codegen 経由。

## 既知の制約

- imported lib (`MarkdownHtml` / `Path`) の **demo コードも実行される** (各 lib
  ファイルが top-level に self-test を持つため)。 build 時に余計な print が
  混ざるが、 SSG 出力には影響しない
- MarkdownHtml が code block (``` fenced ` ```) 非対応 — 将来 markdown lib
  自体を拡張する必要あり

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-site` (別 repo、 pkg manager 完成後)。 dogfood 中の
段階で公開準備にも使う想定 (Mere docs site の build に実用)。
