# contrib/path — POSIX path manipulation helpers

POSIX (`/` separator) の path 操作 helper を `module Path { ... }` で提供。
Mere 純 (builtin 追加なし、 string ops のみ) で実装。

## ファイル

| file | export | 行数 |
|---|---|---|
| `path.mere` | `module Path { join, basename, dirname, ext, drop_ext, has_ext }` | 約 100 行 |

## API

| fn | signature | 動作 |
|---|---|---|
| `Path.join` | `str -> str -> str` | 2 path を `/` で結合、 重複 `/` 防止、 絶対 path 優先 |
| `Path.basename` | `str -> str` | 最後の `/` 以降を返す |
| `Path.dirname` | `str -> str` | 最後の `/` までを返す (separator 無しなら `""`) |
| `Path.ext` | `str -> str` | basename の最後の `.` 以降 (例 `.md`)。 dot-prefix (`.hidden`) は ext 無し扱い |
| `Path.drop_ext` | `str -> str` | ext を取り除く |
| `Path.has_ext` | `str -> str -> bool` | 指定 ext か |

## 使い方

```mere
import "contrib/path/path.mere";

Path.join "docs" "tutorial.md"           // "docs/tutorial.md"
Path.basename "docs/foo.md"              // "foo.md"
Path.dirname "docs/foo.md"               // "docs"
Path.ext "archive.tar.gz"                // ".gz"
Path.drop_ext "foo.md"                   // "foo"
Path.has_ext "foo.md" ".md"              // true
```

## 限定事項 (MVP)

- POSIX `/` separator only — Windows `\` は非対応
- normalization (`a/../b` → `b` 等) はサポートせず、 入力をそのまま操作
- absolute path detection は `/` 始まりで判定
- `Path.ext "archive.tar.gz"` は `.gz` を返す (`tar.gz` 等の複合 ext は呼出側で処理)

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-path` (別 repo、 pkg manager 完成後)。 normalization /
glob 等の機能追加は graduation 前候補。
