# contrib/markdown — Markdown 部分集合 converter

Markdown を HTML / 平文 / TOC に変換する 3 ファイル。 CommonMark の subset で、
個人 README / ブログ生成 / doc 自動化を想定。

## ファイル

| file | export | 用途 |
|---|---|---|
| `to_html.mere` | `module MarkdownHtml { render, render_line, render_inline, starts_with }` (`__md_find_double` / `__md_find_single` は inner-fn 相互参照のため module 外) | Markdown 行 list を HTML に |
| `to_text.mere` | `strip_markdown: str -> str` | Markdown 装飾を剥がして plain text に |
| `toc.mere` | `extract_toc: str list -> str` | heading だけ抜き出して nested list TOC を生成 |

## 使い方

```sh
cp contrib/markdown/to_html.mere  my_project/
```

各ファイル末尾の demo は実 use 時に削除して良い。

## サポート Markdown subset

| 機能 | to_html | to_text | toc |
|---|---|---|---|
| heading `# ## ###` 〜 `######` | ✓ | ✓ | ✓ |
| unordered list `- foo` (`<ul>`/`<li>` wrapping) | ✓ | ✓ | ✗ |
| ordered list `1. foo` / `2. foo` (`<ol>`/`<li>` wrapping) | ✓ | ✗ | ✗ |
| nested list (2-space indent、 1 階層) | ✓ | ✗ | ✗ |
| **bold** (`**…**`) | ✓ | ✓ | ✗ |
| *italic* (`*…*` / `_…_`) | ✓ | ✓ | ✗ |
| inline code `` `…` `` | ✓ | ✓ | ✗ |
| blockquote `> …` | ✓ | ✓ | ✗ |
| fenced code block `` ``` `` | ✓ | ✗ | ✗ |
| link `[X](Y)` (`.md` → `.html` 自動 rewrite) | ✓ | ✗ | ✗ |
| image `![alt](url)` | ✓ | ✗ | ✗ |
| horizontal rule `---` / `***` / `___` | ✓ | ✗ | ✗ |
| table `\| col \| col \|` + separator row | ✓ | ✗ | ✗ |
| paragraph (空行区切り) | ✓ | ✓ | ✗ |
| **非対応** (将来拡張): 2 階層以上の nest / footnote / definition list / autolink | | | |

## 位置付け

stage 2 contrib (incubation)。 公開 + pkg manager 完成後、 graduation 候補として
別 repo `mere-markdown` に切り出す計画
(internal design notes §3.2)。
